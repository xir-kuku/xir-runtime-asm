# SPIR-V Encoder API Reference

## Overview

The SPIR-V encoder (`src/spirv_encoder/`) is a pure-Zig module that emits
SPIR-V binary from Zig code using either a Section builder or SPIR-V text
source. The text path accepts SPIRV-Tools-style `Op*` assembly; the builder path
uses comptime-typed operand structs — one Zig `struct` per SPIR-V opcode.

Generated from the Khronos [SPIRV-Headers][SPIRV-Headers] unified1 grammar.
The generated spec currently includes 877 opcodes from SPIR-V 1.0 through 1.6,
including Khronos and vendor extension enumerants present in the imported
grammar.

### Public API

| Module                        | Re-export    | Description                                                            |
| ----------------------------- | ------------ | ---------------------------------------------------------------------- |
| **`types`**           | `.types`   | Core SPIR-V types:`Word`, `Id`, `Literal*`, pair types           |
| **`spec`**            | `.spec`    | All SPIR-V enums:`Opcode` (877 variants), 41 ValueEnums, 16 BitEnums |
| **`section.Section`** | `.section` | Typed word-stream emission engine: `emit`, `emitRaw`, sizing        |
| **`module.Module`**   | `.module`  | Complete SPIR-V module header/body assembly                         |
| **`text`**            | `.text`    | SPIRV-Tools-style source parser and text-to-module compiler          |
---

## Quick Start (Zig)

```zig
const spirv = @import("xir_asm").spirv;
const Section = spirv.section.Section;

var section = Section{};
defer section.deinit(std.testing.allocator);

// --- Emit instructions via comptime-typed calls ---
try section.emit(std.testing.allocator, .op_capability, .{
    .capability = .shader,
});
try section.emit(std.testing.allocator, .op_memory_model, .{
    .addressing_model = .logical,
    .memory_model = .glsl450,
});
try section.emit(std.testing.allocator, .op_entry_point, .{
    .execution_model = .vertex,
    .entry_point = @enumFromInt(1),
    .name = "main",
});

// --- Compile SPIR-V text source directly ---
const bytes = try spirv.text.parseSourceToOwnedBytes(allocator, source, .{});
defer allocator.free(bytes);

// --- Or access raw words ---
const words = section.toWords(); // []const u32
```

---

## Core Type: `Section`

```zig
pub const Section = struct {
    instructions: std.ArrayListUnmanaged(Word),
    // ...
};
```

A `Section` is a growable word buffer. All instructions are appended in
sequence. Ownership is manual: call `section.deinit(allocator)` to free.

### `deinit`

```zig
pub fn deinit(self: *Section, allocator: Allocator) void
```

Frees all memory and poisons the struct.

### `reset`

```zig
pub fn reset(self: *Section) void
```

Clears the word buffer without freeing capacity. Reuse the Section for a
new SPIR-V module without reallocation.

### `toWords` / `toBytes`

```zig
pub fn toWords(self: Section) []const Word
pub fn toBytes(self: Section) []const u8
```

View the accumulated words as `[]const u32` or the underlying `[]const u8`.
The returned slice is valid until the next mutation.

---

## Emission

### `emit` (comptime-safe)

```zig
pub fn emit(
    self: *Section,
    allocator: Allocator,
    comptime opcode: spec.Opcode,
    operands: opcode.Operands(),
) !void
```

The primary emission function. `operands` must be a struct matching the
opcode's operand layout. The struct type is derived at compile time via
`Opcode.Operands()`, so mismatched fields are caught at compile time.

Example — `op_type_int` expects `{ id_result: Id, width: LiteralInteger, signedness: LiteralInteger }`:

```zig
try section.emit(allocator, .op_type_int, .{
    .id_result = @enumFromInt(3),
    .width = 32,
    .signedness = 0,
});
```

### `emitAssumeCapacity`

```zig
pub fn emitAssumeCapacity(
    self: *Section,
    comptime opcode: spec.Opcode,
    operands: opcode.Operands(),
) void
```

Like `emit` but assumes capacity has been reserved via
`ensureUnusedCapacity`. Does not allocate.

### `emitRaw`

```zig
pub fn emitRaw(
    self: *Section,
    allocator: Allocator,
    opcode: spec.Opcode,
    operand_words: usize,
) !void
```

Emit an opcode word with a given number of trailing operand words (set to
zero). Useful for deferred operand patching.

### `emitRawInstruction`

```zig
pub fn emitRawInstruction(
    self: *Section,
    allocator: Allocator,
    opcode: spec.Opcode,
    operands: []const Word,
) !void
```

Emit an opcode followed by raw `Word` values. Skips comptime operand type
checking. Use for dynamic or opaque instruction emission.

---

## Module And Text Output

`Section` owns only a word stream. Use `module.Module` when you want a complete
SPIR-V module with the five-word header, logical sections, and id bound.

```zig
var module = spirv.module.Module{};
defer module.deinit(allocator);

try module.sections.capabilities.emit(allocator, .op_capability, .{
    .capability = .shader,
});
try module.sections.memory_model.emit(allocator, .op_memory_model, .{
    .addressing_model = .logical,
    .memory_model = .glsl450,
});

const bytes = try module.toOwnedBytes(allocator);
defer allocator.free(bytes);
```

For host-provided SPIRV-Tools-style text, use the native text compiler:

```zig
const bytes = try spirv.text.parseSourceToOwnedBytes(allocator, source, .{});
defer allocator.free(bytes);
```

---

## Sizing

### `instructionSize`

```zig
pub fn instructionSize(
    comptime opcode: spec.Opcode,
    operands: opcode.Operands(),
) usize
```

Returns the total word count for an instruction, including the opcode word.
Comptime-evaluable for static sizing.

### `operandsSize` / `operandSize`

```zig
pub fn operandsSize(comptime Operands: type, operands: Operands) usize
pub fn operandSize(comptime Operand: type, operand: Operand) usize
```

Low-level sizing helpers. `operandsSize` returns word count for a struct of
operand fields; `operandSize` returns word count for a single operand. Used
internally by `emit` to compute capacity before writing.

---

## Low-Level Word Writing

### `writeWord` / `writeWords`

```zig
pub fn writeWord(self: *Section, word: Word) void
pub fn writeWords(self: *Section, words: []const Word) void
```

Append raw words (assumes capacity reserved). Used by `emitRawInstruction`
and `writeExtendedMask`.

### `writeDoubleWord`

```zig
pub fn writeDoubleWord(self: *Section, dword: u64) void
```

Append a 64-bit value as two little-endian words.

### `writeString`

```zig
pub fn writeString(section: *Section, str: []const u8) void
```

Write a null-terminated UTF-8 string padded to word alignment. Used for
`LiteralString` operands (`OpEntryPoint.name`, `OpString.string`, etc.).

### `writeContextDependentNumber`

```zig
pub fn writeContextDependentNumber(
    section: *Section,
    operand: types.LiteralContextDependentNumber,
) void
```

Write a context-dependent literal. Emits 1 word for 32-bit types
(`.int32`, `.uint32`, `.float32`) or 2 words for 64-bit types
(`.int64`, `.uint64`, `.float64`). Used by `OpConstant` variants.

---

## Spec Types

### `Opcode` enum

```zig
pub const Opcode = enum(u16) {
    op_nop = 0,
    op_undef = 1,
    // ... 877 variants total ...
    op_execute_callable_khr = 4446,
    op_type_untyped_pointer_khr = 4417,
    op_hit_object_get_shader_table_data_nv = 5446,
    op_cooperative_matrix_load_amd = 6020,
    op_decorate_string_google = 5632,
    op_ext_ract_sub_array_qcom = 4542,
    // ...

    pub fn Operands(comptime self: Opcode) type { ... }
};
```

The central type. Every variant maps to a XIR `op_*` name matching the
SPIR-V canonical name (converted to lower_snake_case with vendor suffix).
`Operands()` returns the comptime operand struct type for the opcode.

### ValueEnum types

All SPIR-V value enumerants are `enum(u32)`. Examples:

```zig
pub const Capability = enum(u32) { matrix = 0, shader = 1, ..., _ };
pub const StorageClass = enum(u32) { uniform_constant = 11, function = 12, ..., _ };
pub const Decoration = enum(u32) { relaxed_precision = 0, ..., _ };
```

Each includes a trailing `_,` catch-all for forward compatibility with
future SPIR-V versions.

### BitEnum types (mask operands)

Bitmask operands use `packed struct(Word)` with one `bool` field per bit:

```zig
pub const MemoryAccess = packed struct(Word) {
    volatile: bool = false,
    aligned: bool = false,
    nv_memory: bool = false,
    // ...
    _reserved_bit_4: bool = false,
    // ...
    pub const Extended = struct {
        volatile: bool = false,
        aligned: ?struct { alignment: LiteralInteger } = null,
        // ...
    };
};
```

The inner `Extended` struct carries parameter payloads for each bit, using
`?struct { ... } = null` for parameterized flags.

### Parameter-bearing Decoration / ExecutionMode

`Decoration` and `ExecutionMode` each have an `Extended` tagged union
mapping every enumerant to its parameter payload:

```zig
// Using Decorate with a parameter-bearing decoration
try section.emit(allocator, .op_decorate, .{
    .target = @enumFromInt(14),
    .decoration = .{ .location = .{ .location = 0 } },
});
```

---

## Types

### `Word`

```zig
pub const Word = u32;
```

Fundamental SPIR-V unit. All instructions and values are word-aligned.

### `Id`

```zig
pub const Id = enum(Word) { none, _, ... };
```

SPIR-V result/type ID. Use `@enumFromInt(n)` to create IDs and
`@intFromEnum(id)` to extract the word value. The `.none` sentinel is `0`
(not a valid SPIR-V Id). Supports `std.fmt` formatting via `"%none"`
or `"%{d}"`.

### `LiteralInteger` / `LiteralFloat` / `LiteralString`

```zig
pub const LiteralInteger = Word;
pub const LiteralFloat = Word;
pub const LiteralString = []const u8;
```

Type aliases for basic SPIR-V literal types. `LiteralInteger` is a `u32`,
`LiteralString` is a Zig slice (null-terminated and word-padded at emit
time).

### `LiteralContextDependentNumber`

```zig
pub const LiteralContextDependentNumber = union(enum) {
    int32: i32,
    uint32: u32,
    int64: i64,
    uint64: u64,
    float32: f32,
    float64: f64,
};
```

For `OpConstant` and similar instructions where the literal width depends
on the result type:

```zig
// 32-bit integer constant
try section.emit(allocator, .op_constant, .{
    .id_result_type = @enumFromInt(3),  // op_type_int 32
    .id_result = @enumFromInt(10),
    .value = .{ .uint32 = 42 },
});
```

### Pair types

```zig
pub const PairLiteralIntegerIdRef = struct { value: LiteralInteger, label: Id };
pub const PairIdRefLiteralInteger = struct { target: Id, member: LiteralInteger };
pub const PairIdRefIdRef = [2]Id;
```

Used by structured control-flow instructions (`OpSwitch`, `OpPhi`,
`OpLoopMerge`, etc.).

### `IdRange`

```zig
pub const IdRange = struct { base: u32, len: u32, pub fn at(self, i: usize) Id };
```

Utility for allocating sequential IDs. `at(i)` returns `Id` at offset `i`.

### `EncodeError`

```zig
pub const EncodeError = error{
    InvalidOpcode,
    InvalidOperand,
    UnsupportedInstruction,
};
```

Error set for the encoder module.

---

## Usage Patterns

### Module header

```zig
var module = spirv.module.Module{};
defer module.deinit(allocator);

try module.setIdBound(10);
const bytes = try module.toOwnedBytes(allocator);
defer allocator.free(bytes);
```

### Types and constants

```zig
// %1 = TypeInt 32, 0 (signed)
try section.emit(allocator, .op_type_int, .{
    .id_result = @enumFromInt(1),
    .width = 32,
    .signedness = 0,
});
// %2 = TypeFloat 32
try section.emit(allocator, .op_type_float, .{
    .id_result = @enumFromInt(2),
    .width = 32,
});
// %3 = Constant %2 3.14
try section.emit(allocator, .op_constant, .{
    .id_result_type = @enumFromInt(2),
    .id_result = @enumFromInt(3),
    .value = .{ .float32 = 3.14 },
});
```

### Function definition

```zig
// %4 = TypeFunction %1 (%1, %1)
try section.emit(allocator, .op_type_function, .{
    .id_result = @enumFromInt(4),
    .return_type = @enumFromInt(1),
    .param_types = &.{ @enumFromInt(1), @enumFromInt(1) },
});

// %5 = Function %1 %6 None %4
try section.emit(allocator, .op_function, .{
    .id_result_type = @enumFromInt(1),
    .id_result = @enumFromInt(5),
    .function_control = .{},
    .function_type = @enumFromInt(4),
});

// %6 = Label
try section.emit(allocator, .op_label, .{
    .id_result = @enumFromInt(6),
});

// %7 = FAdd %1 %3 %3
try section.emit(allocator, .op_f_add, .{
    .id_result_type = @enumFromInt(2),
    .id_result = @enumFromInt(7),
    .operand_1 = @enumFromInt(3),
    .operand_2 = @enumFromInt(3),
});

// Return %7
try section.emit(allocator, .op_return_value, .{
    .value = @enumFromInt(7),
});

// FunctionEnd
try section.emit(allocator, .op_function_end, {});
```

### Decoration with parameters

```zig
// Decorate %14 Location 0
try section.emit(allocator, .op_decorate, .{
    .target = @enumFromInt(14),
    .decoration = .{ .location = .{ .location = 0 } },
});
```

### Using raw emission for dynamic opcodes

```zig
// Emit an opcode whose operands are computed at runtime
const opcode: spec.Opcode = lookupOpcode(name);
const op_words = computeOperandWords();
try section.emitRawInstruction(allocator, opcode, op_words);
```

## C API

The shared library exports a SPIR-V text compiler for host languages:

```c
void *xir_asm_compile_spv(const char *source, size_t *out_size);
void xir_asm_free_spv(void *bytes, size_t size);
```

`xir_asm_compile_spv` accepts SPIRV-Tools-style `Op*` source and returns
ordinary heap-owned SPIR-V module bytes. The returned pointer is not executable
memory; free it with `xir_asm_free_spv(ptr, size)`.

The typed `Section.emit` builder remains a Zig-native API because it relies on
comptime operand structs (`opcode.Operands()`). Host languages should use the
text compiler unless they add their own narrow Zig wrapper.

### Existing C exports in the same DLL

The shared library `libxir_asm` also exports:

- `xir_asm_compile` / `xir_asm_compile_rv` — x86/RISC-V runtime compile
- `xir_asm_free` — free compiled x86 executable memory
- `xir_new` / `xir_assemble` / ... — stateful assembler

See [`asm-api.md`](asm-api.md) for details.

---

## Architecture

```
        ┌─────────────────────────────────────┐
        │  root.zig (pub const re-exports)   │
        │  types, spec, section, module, text                │
        └──────┬──────────┬──────────┬────────┘
               │          │          │
        ┌──────▼──┐ ┌─────▼──────┐ ┌▼──────────────┐
        │ types.  │ │ spec.zig   │ │ section.zig    │
        │ zig     │ │ (877       │ │ Section builder │
        │ Word,   │ │  opcodes,  │ │ emit/emitRaw,  │
        │ Id,     │ │  41       │ │ Module/text,│
        │ Literal │ │  ValueEnums│ │ sizing, string │
        │ types,  │ │  16 BitEnums│ │ encoding       │
        │ pairs   │ │  +Extended)│ │                │
        └─────────┘ └────────────┘ └────────────────┘
```

---

## Build & Test

```powershell
zig build test          # all tests including SPIR-V encoder
zig build               # DLL build
```

`spec.zig` is generated from Khronos `SPIRV-Headers` unified1 grammar and is
committed with the source distribution.

The SPIR-V encoder is re-exported from the xir_asm root module:

```zig
const xir_asm = @import("xir_asm");
const spirv = xir_asm.spirv;
const Section = spirv.section.Section;
```
