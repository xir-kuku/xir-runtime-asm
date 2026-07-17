<p align="center">
  <a href="#english">English</a> | <a href="#chinese">中文</a>
</p>

---

<a id="english"></a>

# XIR Runtime ASM

Runtime assembly for host languages. Pass assembly source text from Zig, C,
Rust, Bun/Deno FFI, Python/ctypes, or another native host, then get machine code
bytes or callable x86/x86-64 executable memory in the same process.

No external assembler. No subprocess. No object-file round trip.

## What You Get

- **x86/x86-64 runtime assembly** with near-full generated instruction coverage:
  2639 mnemonics and 36k+ encoding templates.
- **C ABI for host integration**: `xir_asm_compile`, `xir_assemble`,
  `xir_asm_compile_rv`, and related free/diagnostic helpers.
- **Zig native API**: typed errors, direct `Assembler`/`pass_driver` access,
  x86/RISC-V encoders, SPIR-V Section builder, and SPIR-V text compiler.
- **Executable memory helper**: write bytes, switch pages to read+execute, call
  through a typed function pointer.
- **Runtime assembler directives**: data emission, reserves, labels, `equ`,
  `.org`, `.align`, `.local`, `repeat`, `iterate`, `while`, `if`, `break`,
  and `indx`.

XIR Runtime ASM is the host-facing runtime assembly library in the XIRASM
project. It focuses on a compact path: source text in, encoded bytes or callable
x86/x86-64 memory out.

## Quick Start

```powershell
zig build
zig build test
zig build -Doptimize=ReleaseSafe
```

Optional lean build:

```powershell
zig build -Dexclude-riscv=true -Dexclude-spirv=true
```

## Zig Example

### Add as a Zig package

For a released archive or git URL, let Zig write the dependency entry:

```powershell
zig fetch --save https://github.com/XIRASM/xir-runtime-asm/archive/refs/tags/v0.1.3.tar.gz
```

This adds a `.dependencies.xir_runtime_asm` entry to your `build.zig.zon`
with a content hash. For local development, use a relative `.path` instead:

```zig
.dependencies = .{
    .xir_runtime_asm = .{
        .path = "../xir-runtime-asm",
    },
},
```

Then wire the module in `build.zig`:

```zig
const dep = b.dependency("xir_runtime_asm", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("xir_asm", dep.module("xir_asm"));
```

Build options can be passed through the dependency when you do not need every
ISA:

```zig
const dep = b.dependency("xir_runtime_asm", .{
    .target = target,
    .optimize = optimize,
    .@"exclude-riscv" = true,
    .@"exclude-spirv" = true,
});
```

This is the basic flow used by [examples/src/main.zig](examples/src/main.zig):
assemble source text, allocate executable memory, cast to the ABI-correct
function type, call it, then free the owned buffers.

```zig
const std = @import("std");
const xir_asm = @import("xir_asm");
const Assembler = xir_asm.assembler.Assembler;
const ExecMemory = xir_asm.runtime.ExecMemory;

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

## C ABI Example

The one-shot C ABI compiles x86/x86-64 source into executable memory. The
returned pointer must be released with `xir_asm_free`.

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

For symbol lookup, listings, or diagnostics, use the stateful C ABI:
`xir_new`, `xir_assemble`, `xir_symbol_value`,
`xir_diagnostic_message`, `xir_get_listing`, and `xir_free`.

## Runnable Examples

Run from `examples/`:

```powershell
zig build run
zig build run-directives
zig build run-showcase
```

| Example | What it verifies |
| --- | --- |
| [examples/src/main.zig](examples/src/main.zig) | Zig API, C ABI from Zig, callbacks, RISC-V compile, SPIR-V Section builder |
| [examples/src/directives.zig](examples/src/directives.zig) | Directive syntax and exact output bytes |
| [examples/src/showcase.zig](examples/src/showcase.zig) | CPUID/XGETBV feature probes and an AVX2 64-byte copy routine |

The showcase checks CPU and OS feature state before executing AVX2 code.
Output varies by machine:

```text
cpuid: vendor=AuthenticAMD, avx2=true, avx512f=false, os_ymm=true, os_zmm=false
avx2 memcpy64: dst == src, checksum=0x00001e20, first=0x07, last=0x3a
```

## Throughput Snapshot

The benchmark measures assembly text parsing and encoding, not execution speed.
In one ReleaseFast run, the 100K AVX2 bare-instruction benchmark assembled
expanded source in about 70 ms, roughly 1.4M instructions/sec:

```powershell
zig build bench -Doptimize=ReleaseFast -Dexclude-riscv=true -Dexclude-spirv=true
```

```text
expanded: source=4112500 bytes, output=787500 bytes, passes=1, converged=true
  time=70 ms (70709 us), throughput=1414245.1 instructions/sec
repeat: source=352 bytes, output=787500 bytes, passes=1, converged=true
  time=116 ms (116210 us), throughput=860506.0 instructions/sec
```

## ISA Support

| ISA | Public surface |
| --- | --- |
| x86/x86-64 | Runtime text assembler, Zig encoder API, C ABI executable compile |
| RISC-V RV32/RV64 | Zig encoder API and `xir_asm_compile_rv` text compile |
| SPIR-V | Zig Section builder and `xir_asm_compile_spv` text-to-module C ABI |

SPIR-V C ABI returns ordinary heap-owned module bytes; free them with
`xir_asm_free_spv(ptr, size)`. RISC-V C ABI currently returns generated
bytes; it does not make those bytes executable on a non-RISC-V host.

## Comparison Scope

| Capability | XIR Runtime ASM | Keystone | AsmJit | Raw OS allocation |
| --- | --- | --- | --- | --- |
| Host input | Assembly text string or loaded `.asm` text | Assembly text string | C++ emitter/builder API | Manual bytes |
| x86 executable memory helper | Yes | Host-managed after `ks_asm` | Yes, through C++ runtime APIs | Host-managed |
| Zig integration | Native module | C ABI binding needed | C++ binding needed | Not an assembler |
| C ABI | Included | Included | Not the primary interface | N/A |
| RISC-V text compile | Included | Included | No | N/A |
| License | Apache-2.0 | GPLv2 or commercial | Zlib | N/A |

This table is limited to integration boundaries visible from the public APIs.

## Documentation

| Document | Contents |
| --- | --- |
| [docs/asm-api.md](docs/asm-api.md) | Zig API, C ABI, ownership, executable memory |
| [docs/asm-directives.md](docs/asm-directives.md) | Runtime assembler directives and tested examples |
| [docs/riscv-encoder-api.md](docs/riscv-encoder-api.md) | RISC-V encoder API |
| [docs/spirv-encoder-api.md](docs/spirv-encoder-api.md) | SPIR-V Section builder and text compiler API |
| [docs/zh/README.md](docs/zh/README.md) | Chinese documentation index |

## Requirements

- Zig 0.17.0-dev available as `zig`
- No external assembler
- No external C/C++ library dependency

## License

Project source is distributed under **Apache-2.0**.

Generated ISA tables include data derived from upstream specification projects:

- **RISC-V**: generated from `riscv-opcodes` data, licensed under
  **BSD-3-Clause**.
- **SPIR-V**: generated from Khronos `SPIRV-Headers` unified1 grammar. The
  grammar/header material is covered by the Khronos permissive MIT-style
  license; other non-code files in that upstream repository may use separate
  documentation licenses.

Redistributions should keep this project's Apache-2.0 license and the required
upstream notices for generated RISC-V and SPIR-V tables.

---

<a id="chinese"></a>

<p align="center">
  <a href="#english">English</a> | <a href="#chinese">中文</a>
</p>

# XIR Runtime ASM

面向宿主语言的运行时汇编库。Zig、C、Rust、Bun/Deno FFI、Python/ctypes
或其他原生宿主都可以传入汇编源码字符串，在当前进程里得到机器码字节，或
得到可直接调用的 x86/x86-64 可执行内存。

无需外部汇编器。无需子进程。无需目标文件往返。

## 你能得到什么

- **x86/x86-64 运行时汇编**：接近全量的生成式指令覆盖，2639 个助记符、
  36k+ 编码模板。
- **C ABI 宿主集成**：`xir_asm_compile`、`xir_assemble`、
  `xir_asm_compile_rv` 以及释放和诊断辅助函数。
- **Zig 原生 API**：类型化错误、直接访问 `Assembler`/`pass_driver`、
  x86/RISC-V 编码器、SPIR-V Section builder 和 SPIR-V 文本编译器。
- **可执行内存辅助**：写入字节、切换到读+执行权限，再通过类型化函数指针调用。
- **运行时汇编伪指令**：数据发射、保留空间、标签、`equ`、`.org`、
  `.align`、`.local`、`repeat`、`iterate`、`while`、`if`、`break`、
  `indx`。

XIR Runtime ASM 是 XIRASM 项目面向宿主语言的运行时汇编库。它专注一条
紧凑路径：输入汇编源码文本，输出编码字节；x86/x86-64 还可以直接返回
可调用的可执行内存。跨语言调用时，调用者仍需遵守目标平台 ABI。

## 快速开始

```powershell
zig build
zig build test
zig build -Doptimize=ReleaseSafe
```

精简构建：

```powershell
zig build -Dexclude-riscv=true -Dexclude-spirv=true
```

## Zig 示例

### 作为 Zig 包添加

对发布归档或 git URL，让 Zig 自动写入依赖项：

```powershell
zig fetch --save https://github.com/XIRASM/xir-runtime-asm/archive/refs/tags/v0.1.3.tar.gz
```

这会在你的 `build.zig.zon` 中加入带内容 hash 的
`.dependencies.xir_runtime_asm`。本地开发时使用相对 `.path`：

```zig
.dependencies = .{
    .xir_runtime_asm = .{
        .path = "../xir-runtime-asm",
    },
},
```

然后在 `build.zig` 里接入模块：

```zig
const dep = b.dependency("xir_runtime_asm", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("xir_asm", dep.module("xir_asm"));
```

不需要全部 ISA 时，可以把构建选项传给依赖：

```zig
const dep = b.dependency("xir_runtime_asm", .{
    .target = target,
    .optimize = optimize,
    .@"exclude-riscv" = true,
    .@"exclude-spirv" = true,
});
```

这是 [examples/src/main.zig](examples/src/main.zig) 使用的基础流程：
汇编源码、分配可执行内存、转成 ABI 匹配的函数类型、调用，然后释放输出缓冲。

```zig
const std = @import("std");
const xir_asm = @import("xir_asm");
const Assembler = xir_asm.assembler.Assembler;
const ExecMemory = xir_asm.runtime.ExecMemory;

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

## C ABI 示例

一次性 C ABI 会把 x86/x86-64 源码编译为可执行内存。返回指针必须用
`xir_asm_free` 释放。

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

需要符号查询、listing 或诊断信息时，用有状态 C ABI：
`xir_new`、`xir_assemble`、`xir_symbol_value`、
`xir_diagnostic_message`、`xir_get_listing`、`xir_free`。

## 可运行示例

进入 `examples/` 运行：

```powershell
zig build run
zig build run-directives
zig build run-showcase
```

| 示例 | 验证内容 |
| --- | --- |
| [examples/src/main.zig](examples/src/main.zig) | Zig API、从 Zig 调 C ABI、回调、RISC-V 编译、SPIR-V Section builder |
| [examples/src/directives.zig](examples/src/directives.zig) | 伪指令语法和精确输出字节 |
| [examples/src/showcase.zig](examples/src/showcase.zig) | CPUID/XGETBV 特性检测和 AVX2 64 字节 copy 例子 |

showcase 会先检查 CPU 和 OS 特性状态，再执行 AVX2 代码。输出因机器而异：

```text
cpuid: vendor=AuthenticAMD, avx2=true, avx512f=false, os_ymm=true, os_zmm=false
avx2 memcpy64: dst == src, checksum=0x00001e20, first=0x07, last=0x3a
```

## 吞吐快照

benchmark 测的是汇编文本解析和编码，不是机器码执行速度。一次 ReleaseFast
运行中，100K 条 AVX2 裸指令 expanded source 约 70 ms 完成，约 140 万条
指令/秒：

```powershell
zig build bench -Doptimize=ReleaseFast -Dexclude-riscv=true -Dexclude-spirv=true
```

```text
expanded: source=4112500 bytes, output=787500 bytes, passes=1, converged=true
  time=70 ms (70709 us), throughput=1414245.1 instructions/sec
repeat: source=352 bytes, output=787500 bytes, passes=1, converged=true
  time=116 ms (116210 us), throughput=860506.0 instructions/sec
```

## ISA 支持

| ISA | 公开能力 |
| --- | --- |
| x86/x86-64 | 运行时文本汇编器、Zig 编码器 API、C ABI 可执行编译 |
| RISC-V RV32/RV64 | Zig 编码器 API 和 `xir_asm_compile_rv` 文本编译 |
| SPIR-V | Zig Section builder，以及 `xir_asm_compile_spv` 文本到模块 C ABI |

SPIR-V C ABI 返回普通堆内存中的模块字节；用
`xir_asm_free_spv(ptr, size)` 释放。RISC-V C ABI 当前返回生成字节；在非 RISC-V
宿主上不会把这些字节变成可执行函数。

## 对比边界

| 能力 | XIR Runtime ASM | Keystone | AsmJit | 裸 OS 分配 |
| --- | --- | --- | --- | --- |
| 宿主输入 | 汇编源码字符串或加载后的 `.asm` 文本 | 汇编源码字符串 | C++ emitter/builder API | 手写字节 |
| x86 可执行内存辅助 | 有 | `ks_asm` 后由宿主管理 | 通过 C++ runtime API 提供 | 宿主管理 |
| Zig 集成 | 原生模块 | 需要 C ABI binding | 需要 C++ binding | 不是汇编器 |
| C ABI | 内置 | 内置 | 不是主要接口 | N/A |
| RISC-V 文本编译 | 内置 | 内置 | 无 | N/A |
| 许可证 | Apache-2.0 | GPLv2 或商业授权 | Zlib | N/A |

此表只比较公开 API 能核验的集成边界。

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/zh/README.md](docs/zh/README.md) | 中文文档入口 |
| [docs/zh/asm-api.md](docs/zh/asm-api.md) | Zig API、C ABI、所有权、可执行内存 |
| [docs/zh/asm-directives.md](docs/zh/asm-directives.md) | 运行时汇编伪指令和已测试示例 |
| [docs/zh/riscv-encoder-api.md](docs/zh/riscv-encoder-api.md) | RISC-V 编码器 API |
| [docs/zh/spirv-encoder-api.md](docs/zh/spirv-encoder-api.md) | SPIR-V Section builder 和文本编译 API |

## 环境要求

- Zig 0.17.0-dev，可通过 `zig` 命令调用
- 无需外部汇编器
- 无需外部 C/C++ 库依赖

## 许可

项目源码采用 **Apache-2.0**。

生成的 ISA 表包含来自上游规范项目的数据：

- **RISC-V**：由 `riscv-opcodes` 数据生成，上游许可证为 **BSD-3-Clause**。
- **SPIR-V**：由 Khronos `SPIRV-Headers` unified1 grammar 生成。grammar/header
  材料使用 Khronos 宽松 MIT-style 许可证；该上游仓库中的其他非代码文档文件
  可能使用独立文档许可证。

重新分发源码或二进制时，应保留本项目 Apache-2.0 许可证，以及生成的
RISC-V / SPIR-V 表对应的上游 notice。
