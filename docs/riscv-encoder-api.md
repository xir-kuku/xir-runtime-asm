# RISC-V Encoder API Reference

## Overview

The RISC-V encoder (`src/riscv_encoder/`) is a standalone Zig module that
encodes RISC-V instructions (RV32/RV64) from a mnemonic string and operand
list into an instruction word. It includes generated coverage for the imported
riscv-opcodes set, including base RV32/RV64, common standard extensions,
pseudo-instructions, and compressed (16-bit) instructions.

1700 total instructions.

### Public API — 6 functions, 5 types

| Category | Item | Description |
|----------|------|-------------|
| **Encode** | `encodeMnemonic` | Mnemonic string + xlen + operands → encoded instruction |
| | `encodeRawMnemonic` | Same but raw field encoding (no semantic operand mapping) |
| | `encode` | `EncodeRequest` struct → encoded instruction |
| | `encodeRaw` | `EncodeRequest` struct → raw encoded instruction |
| **Lookup** | `instructionByMnemonic` | Find instruction metadata by mnemonic name |
| **Parse** | `parseRegister` | Parse register name string → register index |
| **Types** | `EncodeError` | Error set (10 variants) |
| | `EncodedInstruction` | `.word` (u32), `.bytes[4]` (u8), `.len` (u8), `.asSlice()` |
| | `EncodeRequest` | `.mnemonic` + `.xlen` + `.operands` |
| | `Operand` | Union: `.reg: u5` or `.imm: i64` |
| | `Register` | `u5` (0–31) |

---

## Quick Start (Zig)

```zig
const rv_encoder = @import("riscv_encoder");
const Operand = rv_encoder.Operand;

const inst = try rv_encoder.encodeMnemonic("addi", 64, &.{
    Operand{ .reg = 1 },   // ra
    Operand{ .reg = 2 },   // sp
    Operand{ .imm = 42 },
});
// inst.word == 0x02A10093
// inst.bytes[0..inst.len] == &[_]u8{ 0x93, 0x00, 0xA1, 0x02 }
```

---

## Functions

### `encodeMnemonic`

```zig
pub fn encodeMnemonic(
    mnemonic: []const u8,
    xlen: u8,
    operands: []const Operand,
) EncodeError!EncodedInstruction
```

High-level entry point. Looks up `mnemonic` in the instruction table,
validates it supports the given `xlen` (32 or 64), maps operands according
to the instruction's semantic definition, and produces the encoded word.

Equivalent to `encode(.{ .mnemonic = mnemonic, .xlen = xlen, .operands = operands })`.

### `encodeRawMnemonic`

```zig
pub fn encodeRawMnemonic(
    mnemonic: []const u8,
    xlen: u8,
    operands: []const Operand,
) EncodeError!EncodedInstruction
```

Like `encodeMnemonic` but no semantic operand mapping. Each operand is
placed directly into successive fields of the instruction in order.
`.reg` operands supply the raw field value; `.imm` operands supply the
raw immediate value (must be non-negative and within the field width).

### `encode`

```zig
pub fn encode(request: EncodeRequest) EncodeError!EncodedInstruction
```

Takes a pre-built `EncodeRequest` struct and produces the encoded instruction
using semantic operand mapping.

### `encodeRaw`

```zig
pub fn encodeRaw(request: EncodeRequest) EncodeError!EncodedInstruction
```

Takes a pre-built `EncodeRequest` struct and produces the encoded instruction
using raw field encoding (no semantic mapping).

### `instructionByMnemonic`

```zig
pub fn instructionByMnemonic(mnemonic: []const u8) EncodeError!?*const InstructionSpec
```

Looks up an instruction by mnemonic name (case-sensitive). Returns
`null` if not found (e.g., for an unrecognized pseudo-instruction).

`InstructionSpec` contains:
- `name`, `source_name`, `source_file` — identification
- `match`, `mask` — disassembly pattern
- `format` — `Format` enum (r, i, s, b, u, j, csr, compressed, vector, scalar_other)
- `semantic` — `Semantic` enum (operand layout)
- `bit_width` — 16 (compressed) or 32 (standard)
- `min_xlen`, `max_xlen` — supported XLEN range
- `fields` — slice of `FieldSpec` (name, lsb, width)

### `parseRegister`

```zig
pub fn parseRegister(text: []const u8) EncodeError!Register
```

Parse a register name into a 5-bit register index. Supports:

| Pattern | Examples |
|---------|----------|
| xN | `x0`–`x31` |
| fN | `f0`–`f31` |
| vN | `v0`–`v31` |
| ABI (integer) | `zero`, `ra`, `sp`, `gp`, `tp`, `t0`–`t6`, `s0`–`s11`, `a0`–`a7`, `fp` |
| ABI (float) | `ft0`–`ft11`, `fs0`–`fs11`, `fa0`–`fa7` |

Names are case-insensitive.

---

## Types

### `EncodeRequest`

```zig
pub const EncodeRequest = struct {
    mnemonic: []const u8,
    xlen: u8,          // 32 or 64
    operands: []const Operand,
};
```

### `Operand`

```zig
pub const Operand = union(enum) {
    reg: u5,   // register index 0–31
    imm: i64,  // immediate value
};
```

- `.reg` — a register operand (for rd, rs1, rs2, vd, vs1, vs2, vs3, etc.)
- `.imm` — an immediate value (signed; range checked at encode time)

### `EncodedInstruction`

```zig
pub const EncodedInstruction = struct {
    word: u32,
    bytes: [4]u8,     // little-endian byte representation
    len: u8,           // 2 (compressed) or 4 (standard)

    pub fn asSlice(self: *const EncodedInstruction) []const u8;
};
```

`.asSlice()` returns `bytes[0..len]` for direct file/buffer emission.

### `EncodeError`

```zig
pub const EncodeError = error{
    ImmediateAlignment,     // immediate not aligned (branch/jump targets)
    ImmediateOutOfRange,    // immediate exceeds field width
    InvalidXLen,            // xlen not 32 or 64
    MnemonicTooLong,        // mnemonic string exceeds table limit
    OperandCountMismatch,   // wrong number of operands
    OperandKindMismatch,    // .reg when .imm expected or vice versa
    RegisterOutOfRange,     // compressed register constraints (rd≠x0, rd≠sp)
    UnsupportedInstruction, // unknown mnemonic
    UnsupportedInstructionWidth, // internal: unexpected bit_width
    UnsupportedXLen,        // instruction not valid for requested XLEN
};
```

### `Register`

```zig
pub const Register = u5;
```

A 5-bit integer (0–31). Direct integer register index; no structural
wrapper. Pass `u5` values directly as `.reg` operands.

---

## Usage Patterns

### Encode with register ABI names

```zig
const rv = @import("riscv_encoder");

// add t0, t1, t2  (R-type)
const inst = try rv.encodeMnemonic("add", 64, &.{
    .{ .reg = try rv.parseRegister("t0") },
    .{ .reg = try rv.parseRegister("t1") },
    .{ .reg = try rv.parseRegister("t2") },
});
```

### Encode an immediate instruction

```zig
// addi sp, sp, -16  (I-type)
const inst = try rv.encodeMnemonic("addi", 64, &.{
    .{ .reg = 2 },   // sp
    .{ .reg = 2 },   // sp
    .{ .imm = -16 },
});
```

### Compressed instructions automatically selected

```zig
// c.addi sp, -16  (16-bit compressed form of addi sp, sp, -16)
// — selected automatically when the mnemonic + constraints match
const inst = try rv.encodeMnemonic("c.addi", 64, &.{
    .{ .reg = 2 },
    .{ .imm = -16 },
});
assert(inst.len == 2);  // 16-bit compressed instruction
```

### Using `encode` with pre-built request

```zig
const request = rv.EncodeRequest{
    .mnemonic = "lw",
    .xlen = 32,
    .operands = &.{
        .{ .reg = try rv.parseRegister("a0") },
        .{ .reg = try rv.parseRegister("a1") },
        .{ .imm = 0 },
    },
};
const inst = try rv.encode(request);
```

### Raw encoding for custom/pseudo instructions

```zig
// Raw encoding: operands map directly to field order in the instruction spec
// For a 32-bit instruction with 4 fields: each operand fills one field
const inst = try rv.encodeRaw(.{
    .mnemonic = "custom0",
    .xlen = 64,
    .operands = &.{
        .{ .reg = 5 },  // field 0
        .{ .imm = 12 }, // field 1
    },
});
```

### Error handling

```zig
const inst = rv.encodeMnemonic("addi", 64, &.{
    .{ .reg = 1 },
    .{ .imm = 42 },
}) catch |err| switch (err) {
    error.OperandCountMismatch => {
        // expected 3 operands (rd, rs1, imm), got 2
    },
    error.UnsupportedXLen => {
        // instruction not available for RV64
    },
    else => {
        // other encoding error
    },
};
```

---

## C API

The RISC-V encoder module itself is **Zig-only** — it has no direct C ABI
exports (the comptime operand dispatch does not map to a fixed C signature).

RISC-V assembly can be compiled at runtime via the xir_asm library's C API:

### `xir_asm_compile_rv`

```c
void* xir_asm_compile_rv(
    const char* source,   // null-terminated RISC-V assembly source
    uint8_t     xlen,     // 32 or 64
    size_t*     out_size  // [out] code size in bytes, or NULL
);
```

One-shot compile: parses RISC-V assembly, encodes via the RISC-V encoder,
allocates a runtime-owned byte buffer, and returns an opaque pointer. Free
with `xir_asm_free`.

```c
void* code = xir_asm_compile_rv(
    "addi x1, x2, 42", 64, &size);
if (!code) { /* assembly error */ }
/* bytes now contain RISC-V machine code for the target CPU or emulator. */
xir_asm_free(code);
```

**Returns:** pointer to generated bytes, or NULL on failure.

**Errors:** returns NULL — use `xir_diagnostic_message` (stateful API)
for details.

**Thread safety:** safe for concurrent calls.

### Link

```powershell
zig build       # -> zig-out/bin/xir_asm.dll
```

See [`asm-api.md`](asm-api.md) for the full stateful C API
(`xir_new`, `xir_assemble`, etc.) which also supports RISC-V via
`mode_bits & 0x80`.

---

## Architecture

```
                     ┌─────────────────────┐
                     │   root.zig (public)  │
                     │  encodeMnemonic,     │
                     │  encodeRawMnemonic,  │
                     │  instructionBy...    │
                     │  parseRegister, etc. │
                     └──────┬──────────────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
       ┌──────▼──────┐ ┌───▼───┐ ┌──────▼─────┐
       │  api.zig    │ │types. │ │  regs.zig  │
       │  (public    │ │ zig   │ │  (register │
       │   functions,│ │ (type │ │  parsing,  │
       │   error def)│ │ defs) │ │  ABI names)│
       └──────┬──────┘ └───────┘ └────────────┘
              │
       ┌──────▼──────────────────────┐
       │  encode.zig                 │
       │  (field encoding, packing,  │
       │   range checking, semantic  │
       │   → field value mapping)    │
       └──────────┬──────────────────┘
                  │
       ┌──────────▼──────────────────┐
        │  generated_core.zig         │
        │  (1700 instruction specs    │
        │   auto-generated from       │
       │   canonical riscv-opcodes)  │
       └─────────────────────────────┘
```

---

## Build & Test

```powershell
zig build test          # all tests including RISC-V encoder
zig build               # DLL build (includes riscv encoder)
```

The RISC-V encoder is also re-exported from the xir_asm root module:

```zig
const xir_asm = @import("xir_asm");
const rv = xir_asm.riscv;
```
