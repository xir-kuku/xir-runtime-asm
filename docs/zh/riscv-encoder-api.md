# RISC-V 编码器 API 参考 (XIR Runtime ASM)

## 概述

RISC-V 编码器（`src/riscv_encoder/`）是一个独立 Zig 模块，将助记符字符串和操作数列表编码为指令字。它基于导入的 riscv-opcodes 数据生成，覆盖 RV32/RV64、常见标准扩展、伪指令和压缩（16 位）指令。

共 1700 条指令。

### 公开 API — 6 个函数、5 种类型

| 类别           | 项                        | 描述                                                                  |
| -------------- | ------------------------- | --------------------------------------------------------------------- |
| **编码** | `encodeMnemonic`        | 助记符 + xlen + 操作数 → 编码指令                                    |
|                | `encodeRawMnemonic`     | 同上，但使用原始字段编码（无语义操作数映射）                          |
|                | `encode`                | `EncodeRequest` 结构体 → 编码指令                                  |
|                | `encodeRaw`             | `EncodeRequest` 结构体 → 原始编码指令                              |
| **查找** | `instructionByMnemonic` | 按助记符名称查找指令元数据                                            |
| **解析** | `parseRegister`         | 寄存器名称字符串 → 寄存器索引                                        |
| **类型** | `EncodeError`           | 错误集（10 种变体）                                                   |
|                | `EncodedInstruction`    | `.word`（u32）、`.bytes[4]`（u8）、`.len`（u8）、`.asSlice()` |
|                | `EncodeRequest`         | `.mnemonic` + `.xlen` + `.operands`                             |
|                | `Operand`               | 联合体：`.reg: u5` 或 `.imm: i64`                                 |
|                | `Register`              | `u5`（0–31）                                                       |

---

## 快速开始（Zig）

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

## 函数

### `encodeMnemonic`

```zig
pub fn encodeMnemonic(
    mnemonic: []const u8,
    xlen: u8,
    operands: []const Operand,
) EncodeError!EncodedInstruction
```

高级入口。在指令表中查找 `mnemonic`，验证 `xlen`（32 或 64）支持，根据指令的语义定义映射操作数，生成编码字。

等价于 `encode(.{ .mnemonic = mnemonic, .xlen = xlen, .operands = operands })`。

### `encodeRawMnemonic`

```zig
pub fn encodeRawMnemonic(
    mnemonic: []const u8,
    xlen: u8,
    operands: []const Operand,
) EncodeError!EncodedInstruction
```

类似 `encodeMnemonic` 但无语义操作数映射。每个操作数按顺序直接放入指令的连续字段。`.reg` 操作数提供原始字段值；`.imm` 操作数提供原始立即数值（必须非负且在字段宽度内）。

### `encode`

```zig
pub fn encode(request: EncodeRequest) EncodeError!EncodedInstruction
```

接收预构建的 `EncodeRequest` 结构体，使用语义操作数映射生成编码指令。

### `encodeRaw`

```zig
pub fn encodeRaw(request: EncodeRequest) EncodeError!EncodedInstruction
```

接收预构建的 `EncodeRequest` 结构体，使用原始字段编码生成编码指令。

### `instructionByMnemonic`

```zig
pub fn instructionByMnemonic(mnemonic: []const u8) EncodeError!?*const InstructionSpec
```

按助记符名称查找指令（区分大小写）。未找到时返回 `null`。

`InstructionSpec` 包含：

- `name`、`source_name`、`source_file` — 标识
- `match`、`mask` — 反汇编模式
- `format` — `Format` 枚举（r、i、s、b、u、j、csr、compressed、vector、scalar_other）
- `semantic` — `Semantic` 枚举（操作数布局）
- `bit_width` — 16（压缩）或 32（标准）
- `min_xlen`、`max_xlen` — 支持的 XLEN 范围
- `fields` — `FieldSpec`（名称、最低位、宽度）切片

### `parseRegister`

```zig
pub fn parseRegister(text: []const u8) EncodeError!Register
```

将寄存器名称解析为 5 位寄存器索引。支持：

| 模式        | 示例                                                                                              |
| ----------- | ------------------------------------------------------------------------------------------------- |
| xN          | `x0`–`x31`                                                                                   |
| fN          | `f0`–`f31`                                                                                   |
| vN          | `v0`–`v31`                                                                                   |
| ABI（整数） | `zero`、`ra`、`sp`、`gp`、`tp`、`t0`–`t6`、`s0`–`s11`、`a0`–`a7`、`fp` |
| ABI（浮点） | `ft0`–`ft11`、`fs0`–`fs11`、`fa0`–`fa7`                                            |

名称不区分大小写。

---

## 类型

### `EncodeRequest`

```zig
pub const EncodeRequest = struct {
    mnemonic: []const u8,
    xlen: u8,           // 32 或 64
    operands: []const Operand,
};
```

### `Operand`

```zig
pub const Operand = union(enum) {
    reg: u5,   // 寄存器索引 0–31
    imm: i64,  // 立即数值（有符号，编码时检查范围）
};
```

### `EncodedInstruction`

```zig
pub const EncodedInstruction = struct {
    word: u32,
    bytes: [4]u8,      // 小端字节表示
    len: u8,            // 2（压缩）或 4（标准）

    pub fn asSlice(self: *const EncodedInstruction) []const u8;
};
```

`.asSlice()` 返回 `bytes[0..len]`，用于直接写入文件或缓冲区。

### `EncodeError`

```zig
pub const EncodeError = error{
    ImmediateAlignment,      // 立即数未对齐（分支/跳转目标）
    ImmediateOutOfRange,     // 立即数超出字段宽度
    InvalidXLen,             // xlen 不是 32 或 64
    MnemonicTooLong,         // 助记符超出表限制
    OperandCountMismatch,    // 操作数数量不匹配
    OperandKindMismatch,     // .reg 但需要 .imm，反之亦然
    RegisterOutOfRange,      // 压缩寄存器约束（rd≠x0、rd≠sp）
    UnsupportedInstruction,  // 未知助记符
    UnsupportedInstructionWidth, // 内部错误：意外的 bit_width
    UnsupportedXLen,         // 指令不支持请求的 XLEN
};
```

### `Register`

```zig
pub const Register = u5;
```

5 位整数（0–31）。直接整数寄存器索引，无结构包装。将 `u5` 值作为 `.reg` 操作数传入。

---

## 使用模式

### 使用 ABI 寄存器名称编码

```zig
const rv = @import("riscv_encoder");

const inst = try rv.encodeMnemonic("add", 64, &.{
    .{ .reg = try rv.parseRegister("t0") },
    .{ .reg = try rv.parseRegister("t1") },
    .{ .reg = try rv.parseRegister("t2") },
});
```

### 编码立即数指令

```zig
const inst = try rv.encodeMnemonic("addi", 64, &.{
    .{ .reg = 2 },   // sp
    .{ .reg = 2 },   // sp
    .{ .imm = -16 },
});
```

### 压缩指令自动选择

```zig
const inst = try rv.encodeMnemonic("c.addi", 64, &.{
    .{ .reg = 2 },
    .{ .imm = -16 },
});
assert(inst.len == 2);
```

### 使用预构建请求编码

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

### 原始编码用于自定义/伪指令

```zig
const inst = try rv.encodeRaw(.{
    .mnemonic = "custom0",
    .xlen = 64,
    .operands = &.{
        .{ .reg = 5 },  // 字段 0
        .{ .imm = 12 }, // 字段 1
    },
});
```

### 错误处理

```zig
const inst = rv.encodeMnemonic("addi", 64, &.{
    .{ .reg = 1 },
    .{ .imm = 42 },
}) catch |err| switch (err) {
    error.OperandCountMismatch => {
        // 需要 3 个操作数（rd、rs1、imm），收到 2 个
    },
    error.UnsupportedXLen => {
        // 指令不支持 RV64
    },
    else => {
        // 其他编码错误
    },
};
```

---

## C API

RISC-V 编码器模块本身是 **Zig 专用**——没有直接的 C ABI 导出（编译期操作数分发无法映射为固定 C 签名）。

RISC-V 汇编可通过 xir_asm 库的 C API 在运行时编译：

### `xir_asm_compile_rv`

```c
void* xir_asm_compile_rv(
    const char* source,   // 以 null 结尾的 RISC-V 汇编源码
    uint8_t     xlen,     // 32 或 64
    size_t*     out_size  // [输出] 代码字节数，可为 NULL
);
```

一次性编译：解析 RISC-V 汇编、通过 RISC-V 编码器编码、分配运行时拥有的
字节缓冲区并返回不透明指针。使用 `xir_asm_free` 释放。

```c
void* code = xir_asm_compile_rv(
    "addi x1, x2, 42", 64, &size);
if (!code) { /* 汇编错误 */ }
/* bytes 是目标 CPU 或模拟器使用的 RISC-V 机器码。 */
xir_asm_free(code);
```

**返回值：** 指向生成字节的指针，失败返回 NULL。

**错误：** 返回 NULL——可使用 `xir_diagnostic_message`（有状态 API）获取详情。

**线程安全：** 并发调用安全。

### 链接

```powershell
zig build       # -> zig-out/bin/xir_asm.dll
```

完整有状态 C API（`xir_new`、`xir_assemble` 等）同样支持 RISC-V（通过 `mode_bits & 0x80`），参见 [`asm-api.md`](asm-api.md)。

---

## 架构

```
                      ┌─────────────────────┐
                      │   root.zig（公开）    │
                      │  encodeMnemonic、    │
                      │  encodeRawMnemonic、 │
                      │  instructionBy...    │
                      │  parseRegister 等    │
                      └──────┬──────────────┘
                             │
               ┌─────────────┼─────────────┐
               │             │             │
        ┌──────▼──────┐ ┌───▼───┐ ┌──────▼─────┐
        │  api.zig    │ │types. │ │  regs.zig  │
        │  （公开函数、 │ │ zig   │ │  （寄存器   │
        │  错误定义）   │ │（类型  │ │  解析、     │
        │             │ │ 定义） │ │  ABI 名）   │
        └──────┬──────┘ └───────┘ └────────────┘
               │
        ┌──────▼──────────────────────┐
        │  encode.zig                 │
        │  （字段编码、打包、          │
        │   范围检查、语义→字段值映射） │
        └──────────┬──────────────────┘
                   │
        ┌──────────▼──────────────────┐
        │  generated_core.zig         │
        │  （1700 条指令规范          │
        │   根据规范 riscv-opcodes     │
        │   自动生成）                  │
        └─────────────────────────────┘
```

---

## 构建与测试

```powershell
zig build test          # 全部测试，含 RISC-V 编码器
zig build               # DLL构建DEBUG版（包含 RISC-V 编码器）
```

RISC-V 编码器也从 xir_asm 根模块重新导出：

```zig
const xir_asm = @import("xir_asm");
const rv = xir_asm.riscv;
```
