# XIR Runtime ASM API

## What this library does

XIR Runtime ASM turns assembly source text into bytes in the current process.
For x86-64 it can also allocate executable memory and return a callable
function pointer.

The public API has two layers:

| Layer | Entry point | Best for |
| --- | --- | --- |
| Zig API | `@import("xir_asm")` | Zig projects that want typed errors and direct access to encoders |
| C ABI | `xir_asm_compile`, `xir_new`, `xir_assemble` | C, Rust, Bun/Deno FFI, Python/ctypes, native wrappers |

For runnable code, start with:

- [examples/src/main.zig](../examples/src/main.zig): Zig API, C ABI calls from Zig, callbacks, RISC-V, SPIR-V
- [examples/src/showcase.zig](../examples/src/showcase.zig): CPUID/XGETBV plus an AVX2 64-byte copy routine
- [examples/src/directives.zig](../examples/src/directives.zig): directive examples with expected output bytes

## Zig API

Import the module:

```zig
const std = @import("std");
const xir_asm = @import("xir_asm");
const Assembler = xir_asm.assembler.Assembler;
const ExecMemory = xir_asm.runtime.ExecMemory;
```

Compile x86-64 source and call it:

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

This is the same flow used by the examples:

1. Create an `Assembler` with a target mode.
2. Call `pass_driver.drive` with source text.
3. Free `result.output_bytes` and `result.listing` with the allocator passed to `drive`.
4. For executable x86 code, pass the bytes to `ExecMemory.allocate`.
5. Cast `mem.code_ptr` to the function type that matches your assembly ABI.

### Target mode

`Assembler.init(allocator, mode_bits)` selects the source mode:

| `mode_bits` | Target |
| --- | --- |
| `32` | x86 32-bit |
| `64` | x86-64 |
| `0x80 \| 0` | RISC-V RV32 |
| `0x80 \| 16` | RISC-V RV64 |

### Result ownership

`pass_driver.drive` returns:

```zig
pub const Summary = struct {
    pass_count: usize,
    converged: bool,
    output_bytes: []u8,
    listing: []u8,
};
```

`output_bytes` and `listing` are owned by the caller. Always free both after a
successful `drive` call.

### Calling convention

The emitted x86-64 code is ordinary machine code. If you call it through
`callconv(.c)`, your assembly must follow the platform C ABI:

| Platform | Integer/pointer arguments |
| --- | --- |
| Windows x64 | `rcx`, `rdx`, `r8`, `r9`, then stack |
| Linux/macOS x86-64 | `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`, then stack |

Example with one argument:

```zig
const source = if (@import("builtin").os.tag == .windows)
    \\mov rax, rcx
    \\ret
else
    \\mov rax, rdi
    \\ret
;
```

The host is responsible for register preservation, stack alignment, shadow
space on Windows, and any CPU feature checks before executing instructions such
as AVX2 or AVX-512. See `examples/src/showcase.zig` for a tested CPUID/XGETBV
pattern.

## C ABI

The C ABI is exported for dynamic linking and FFI. It uses null pointers and
integer error codes because those are portable across host languages.

### One-shot executable compile

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

`xir_asm_compile` returns executable memory for x86/x86-64. The caller must
release it with `xir_asm_free`.

```c
void* xir_asm_compile(
    const char* source,
    uint8_t mode_bits,
    size_t* out_size
);
```

| Parameter | Meaning |
| --- | --- |
| `source` | Null-terminated assembly source. Must not be `NULL`. |
| `mode_bits` | `32` or `64`. |
| `out_size` | Optional output byte count. Set to zero on failure. |

### RISC-V text compile

```c
void* xir_asm_compile_rv(
    const char* source,
    uint8_t xlen,
    size_t* out_size
);
```

This compiles RISC-V source text to a byte buffer allocated with the same
runtime allocator. `xlen` is `32` or `64`. Free the returned pointer with
`xir_asm_free`.

RISC-V bytes are not executable on an x86 host; use them as generated machine
code for a RISC-V target or emulator.

### SPIR-V text compile

```c
void* xir_asm_compile_spv(const char* source, size_t* out_size);
void  xir_asm_free_spv(void* bytes, size_t size);
```

This compiles SPIRV-Tools-style `Op*` source text to a SPIR-V module byte
buffer. The result is ordinary heap-owned data, not executable memory. Free it
with `xir_asm_free_spv(ptr, size)`.

### Stateful assembly context

Use the stateful API when you need output bytes, symbol values, listings, or
diagnostics without making the result executable immediately.

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

Exported functions:

```c
void*       xir_new(uint32_t mode_bits);
void        xir_free(void* ctx);
uint8_t*    xir_assemble(void* ctx, const char* source, size_t* out_len, int32_t* out_err);
void        xir_free_output(void* ctx);
uint64_t    xir_symbol_value(void* ctx, const char* name, int32_t* found);
const char* xir_diagnostic_message(void* ctx);
const char* xir_get_listing(void* ctx);
```

`xir_assemble` output is owned by the context. It remains valid until the next
`xir_assemble`, `xir_free_output`, or `xir_free`.

Error codes returned through `out_err`:

| Value | Meaning |
| --- | --- |
| `0` | success |
| `-1` | allocation failure |
| `-2` | assembly error |
| `-3` | null argument |

## Build integration

For a released archive or git URL, let Zig add the package to your manifest:

```powershell
zig fetch --save https://github.com/XIRASM/xir-runtime-asm/archive/refs/tags/v0.1.1.tar.gz
```

For local development, add a relative `.path` dependency in `build.zig.zon`:

```zig
.dependencies = .{
    .xir_runtime_asm = .{
        .path = "../xir-runtime-asm",
    },
},
```

Then import the module in `build.zig`:

```zig
const dep = b.dependency("xir_runtime_asm", .{});
exe.root_module.addImport("xir_asm", dep.module("xir_asm"));
```

If the dependency should inherit your target and optimization mode:

```zig
const dep = b.dependency("xir_runtime_asm", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("xir_asm", dep.module("xir_asm"));
```

To omit unused ISA modules:

```zig
const dep = b.dependency("xir_runtime_asm", .{
    .target = target,
    .optimize = optimize,
    .@"exclude-riscv" = true,
    .@"exclude-spirv" = true,
});
```

Build the shared library for C ABI users:

```powershell
zig build -Doptimize=ReleaseSafe
```

Useful options:

| Option | Meaning |
| --- | --- |
| `-Dexclude-riscv=true` | Leave out the RISC-V encoder and C ABI export. |
| `-Dexclude-spirv=true` | Leave out the SPIR-V encoder. |
| `-Doptimize=ReleaseFast` | Optimize throughput benchmarks. |
| `-Doptimize=ReleaseSafe` | Keep safety checks in release builds. |

## Threading and memory rules

| Operation | Rule |
| --- | --- |
| Concurrent `xir_asm_compile` | Safe. Each call creates independent state. |
| Concurrent `xir_assemble` on different contexts | Safe. |
| Concurrent `xir_assemble` on the same context | Not safe. The context is mutable. |
| Concurrent execution of compiled code | Safe if your code is thread-safe. The page is RX. |
| Freeing the same code pointer twice | Not safe. Treat as a normal double-free bug. |

Executable memory uses a write-then-execute flow: pages are writable while code
is copied, then switched to read+execute before the pointer is returned.

## ISA modules

The top-level Zig module also exposes encoder modules:

| Module | Status |
| --- | --- |
| `xir_asm.x86` | x86/x86-64 encoder used by the runtime assembler. |
| `xir_asm.riscv` | RISC-V encoder and text compiler, absent when excluded at build time. |
| `xir_asm.spirv` | Zig Section builder and text compiler for SPIR-V; C ABI: `xir_asm_compile_spv` / `xir_asm_free_spv`. |

For directive syntax, see [asm-directives.md](asm-directives.md).
