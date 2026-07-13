# XIR Runtime ASM API

## 这个库做什么

XIR Runtime ASM 在当前进程里把汇编源码字符串转成机器码字节。对 x86-64，
它还可以分配可执行内存，并返回可直接调用的函数指针。

公开 API 分两层：

| 层级 | 入口 | 适合场景 |
| --- | --- | --- |
| Zig API | `@import("xir_asm")` | Zig 项目，需要类型化错误和直接访问编码器 |
| C ABI | `xir_asm_compile`、`xir_new`、`xir_assemble` | C、Rust、Bun/Deno FFI、Python/ctypes、原生包装 |

可运行示例从这里看：

- [examples/src/main.zig](../../examples/src/main.zig)：Zig API、从 Zig 调 C ABI、回调、RISC-V、SPIR-V
- [examples/src/showcase.zig](../../examples/src/showcase.zig)：CPUID/XGETBV，加一个 AVX2 64 字节 copy 例子
- [examples/src/directives.zig](../../examples/src/directives.zig)：伪指令示例，并校验真实输出字节

## Zig API

导入模块：

```zig
const std = @import("std");
const xir_asm = @import("xir_asm");
const Assembler = xir_asm.assembler.Assembler;
const ExecMemory = xir_asm.runtime.ExecMemory;
```

编译 x86-64 源码并调用：

```zig
fn compileAndCall(allocator: std.mem.Allocator) !i32 {
    const source =
        \\mov eax, 42
        \\ret
    ;

    var assembler = try Assembler.init(allocator, 64);
    defer assembler.deinit();

    const result = try xir_asm.pass_driver.drive(allocator, &assembler, source);
    defer allocator.free(result.output_bytes);
    defer allocator.free(result.listing);

    if (!result.converged) return error.AssemblyDidNotConverge;

    var mem = try ExecMemory.allocate(result.output_bytes);
    defer mem.deinit();

    const fn_ptr: *const fn () callconv(.c) i32 =
        @ptrCast(@alignCast(mem.code_ptr));
    return fn_ptr();
}
```

这就是示例程序使用的基本流程：

1. 用目标模式创建 `Assembler`。
2. 把源码传给 `pass_driver.drive`。
3. `result.output_bytes` 和 `result.listing` 用传给 `drive` 的 allocator 释放。
4. 对 x86 可执行代码，把输出字节传给 `ExecMemory.allocate`。
5. 把 `mem.code_ptr` 转成与汇编 ABI 匹配的函数类型。

### 目标模式

`Assembler.init(allocator, mode_bits)` 选择源码模式：

| `mode_bits` | 目标 |
| --- | --- |
| `32` | x86 32 位 |
| `64` | x86-64 |
| `0x80 \| 0` | RISC-V RV32 |
| `0x80 \| 16` | RISC-V RV64 |

### 返回值所有权

`pass_driver.drive` 返回：

```zig
pub const Summary = struct {
    pass_count: usize,
    converged: bool,
    output_bytes: []u8,
    listing: []u8,
};
```

`output_bytes` 和 `listing` 都归调用者所有。`drive` 成功后，两者都要释放。

### 调用约定

生成的 x86-64 代码就是普通机器码。通过 `callconv(.c)` 调用时，汇编必须遵守
平台 C ABI：

| 平台 | 整数/指针参数 |
| --- | --- |
| Windows x64 | `rcx`、`rdx`、`r8`、`r9`，之后走栈 |
| Linux/macOS x86-64 | `rdi`、`rsi`、`rdx`、`rcx`、`r8`、`r9`，之后走栈 |

一个参数的例子：

```zig
const source = if (@import("builtin").os.tag == .windows)
    \\mov rax, rcx
    \\ret
else
    \\mov rax, rdi
    \\ret
;
```

寄存器保存、栈对齐、Windows shadow space，以及执行 AVX2/AVX-512 前的 CPU
特性检测，都由宿主和汇编源码负责。经过测试的 CPUID/XGETBV 写法见
`examples/src/showcase.zig`。

## C ABI

C ABI 用于动态链接和 FFI。它使用空指针和整数错误码，因为这些形式更容易跨
语言传递。

### 一次性编译为可执行内存

```c
#include <stdint.h>
#include <stddef.h>

void* xir_asm_compile(const char* source, uint8_t mode_bits, size_t* out_size);
void  xir_asm_free(void* code);

int call_asm(void) {
    size_t size = 0;
    void* code = xir_asm_compile(
        "mov eax, 42\n"
        "ret", 64, &size);
    if (!code) return -1;

    int32_t (*fn)(void) = (int32_t (*)(void))code;
    int32_t result = fn();

    xir_asm_free(code);
    return result;
}
```

`xir_asm_compile` 对 x86/x86-64 返回可执行内存。调用者必须用
`xir_asm_free` 释放。

```c
void* xir_asm_compile(
    const char* source,
    uint8_t mode_bits,
    size_t* out_size
);
```

| 参数 | 含义 |
| --- | --- |
| `source` | 以 null 结尾的汇编源码，不能为 `NULL`。 |
| `mode_bits` | `32` 或 `64`。 |
| `out_size` | 可选输出字节数。失败时写入 0。 |

### RISC-V 文本编译

```c
void* xir_asm_compile_rv(
    const char* source,
    uint8_t xlen,
    size_t* out_size
);
```

它把 RISC-V 源码编译为字节缓冲区，使用同一套运行时分配器。`xlen` 为
`32` 或 `64`。返回指针同样用 `xir_asm_free` 释放。

RISC-V 字节不能在 x86 主机上直接执行；它们用于生成 RISC-V 目标机器码或交给
模拟器。

### SPIR-V 文本编译

```c
void* xir_asm_compile_spv(const char* source, size_t* out_size);
void  xir_asm_free_spv(void* bytes, size_t size);
```

它把 SPIRV-Tools 风格的 `Op*` 源码编译为 SPIR-V 模块字节缓冲区。结果是普通
堆内存数据，不是可执行内存。使用 `xir_asm_free_spv(ptr, size)` 释放。

### 有状态汇编上下文

需要输出字节、符号值、listing 或诊断信息，但不想立刻变成可执行内存时，
使用有状态 API。

```c
void* ctx = xir_new(64);
if (!ctx) return 1;

size_t out_len = 0;
int32_t err = 0;
uint8_t* out = xir_assemble(ctx, "equ MAGIC = 0x42\ndb MAGIC", &out_len, &err);
if (!out) {
    const char* msg = xir_diagnostic_message(ctx);
    xir_free(ctx);
    return 1;
}

int32_t found = 0;
uint64_t magic = xir_symbol_value(ctx, "MAGIC", &found);

xir_free_output(ctx);
xir_free(ctx);
```

导出函数：

```c
void*       xir_new(uint32_t mode_bits);
void        xir_free(void* ctx);
uint8_t*    xir_assemble(void* ctx, const char* source, size_t* out_len, int32_t* out_err);
void        xir_free_output(void* ctx);
uint64_t    xir_symbol_value(void* ctx, const char* name, int32_t* found);
const char* xir_diagnostic_message(void* ctx);
const char* xir_get_listing(void* ctx);
```

`xir_assemble` 的输出由 context 拥有。它在下一次 `xir_assemble`、
`xir_free_output` 或 `xir_free` 之前有效。

`out_err` 错误码：

| 值 | 含义 |
| --- | --- |
| `0` | 成功 |
| `-1` | 分配失败 |
| `-2` | 汇编错误 |
| `-3` | 空参数 |

## 构建集成

对发布归档或 git URL，让 Zig 自动把包写入 manifest：

```powershell
zig fetch --save https://github.com/XIRASM/xir-runtime-asm/archive/refs/tags/v0.1.0.tar.gz
```

本地开发时，在 `build.zig.zon` 里添加相对 `.path` 依赖：

```zig
.dependencies = .{
    .xir_runtime_asm = .{
        .path = "../xir-runtime-asm",
    },
},
```

然后在 `build.zig` 中导入模块：

```zig
const dep = b.dependency("xir_runtime_asm", .{});
exe.root_module.addImport("xir_asm", dep.module("xir_asm"));
```

如果依赖需要继承你的 target 和 optimize：

```zig
const dep = b.dependency("xir_runtime_asm", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("xir_asm", dep.module("xir_asm"));
```

不需要某些 ISA 时可传入构建选项：

```zig
const dep = b.dependency("xir_runtime_asm", .{
    .target = target,
    .optimize = optimize,
    .@"exclude-riscv" = true,
    .@"exclude-spirv" = true,
});
```

为 C ABI 用户构建动态库：

```powershell
zig build -Doptimize=ReleaseSafe
```

常用选项：

| 选项 | 含义 |
| --- | --- |
| `-Dexclude-riscv=true` | 排除 RISC-V 编码器和对应 C ABI 导出。 |
| `-Dexclude-spirv=true` | 排除 SPIR-V 编码器。 |
| `-Doptimize=ReleaseFast` | 用于吞吐 benchmark。 |
| `-Doptimize=ReleaseSafe` | release 构建保留安全检查。 |

## 线程和内存规则

| 操作 | 规则 |
| --- | --- |
| 并发 `xir_asm_compile` | 安全。每次调用创建独立状态。 |
| 不同 context 上并发 `xir_assemble` | 安全。 |
| 同一 context 上并发 `xir_assemble` | 不安全。context 是可变状态。 |
| 并发执行已编译代码 | 取决于你的汇编是否线程安全。页面本身是 RX。 |
| 同一 code 指针释放两次 | 不安全。按普通 double-free bug 处理。 |

可执行内存采用先写后执行：代码复制时页面可写，返回前切换为读+执行。

## ISA 模块

顶层 Zig 模块还暴露编码器模块：

| 模块 | 状态 |
| --- | --- |
| `xir_asm.x86` | x86/x86-64 编码器，也是运行时汇编器使用的核心。 |
| `xir_asm.riscv` | RISC-V 编码器和文本编译；构建时排除后为空。 |
| `xir_asm.spirv` | Zig 侧 SPIR-V Section builder 和文本编译；C ABI 为 `xir_asm_compile_spv` / `xir_asm_free_spv`。 |

伪指令语法见 [asm-directives.md](asm-directives.md)。
