# SPIR-V 编码器 API 参考 (XIR Runtime ASM)

## 概述

SPIR-V 编码器（`src/spirv_encoder/`）是一个纯 Zig 模块，可通过 Section 构建器或 SPIR-V 文本源码生成 SPIR-V 二进制。文本路径接受 SPIRV-Tools 风格的 `Op*` 汇编；构建器路径通过编译期类型化操作数结构体发射指令。

根据 Khronos [SPIRV-Headers][SPIRV-Headers] unified1 语法自动生成。当前生成规格包含 877 条操作码，覆盖导入语法中出现的 SPIR-V 1.0 至 1.6、Khronos 扩展和厂商扩展枚举。

### 公开 API

| 模块                          | 重新导出     | 描述                                                                     |
| ----------------------------- | ------------ | ------------------------------------------------------------------------ |
| **`types`**           | `.types`   | 核心 SPIR-V 类型：`Word`、`Id`、`Literal*`、配对类型               |
| **`spec`**            | `.spec`    | 全部 SPIR-V 枚举：`Opcode`（877 变体）、41 个 ValueEnum、16 个 BitEnum |
| **`section.Section`** | `.section` | 类型化 word stream 发射引擎：`emit`、`emitRaw`、大小计算              |
| **`module.Module`**   | `.module`  | 完整 SPIR-V 模块头和 body 组装                                      |
| **`text`**            | `.text`    | SPIRV-Tools 风格源码解析和文本到模块编译                             |


## 快速开始（Zig）

```zig
const spirv = @import("xir_asm").spirv;
const Section = spirv.section.Section;

var section = Section{};
defer section.deinit(std.testing.allocator);

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

const bytes = try spirv.text.parseSourceToOwnedBytes(allocator, source, .{});
defer allocator.free(bytes);

const words = section.toWords();
```

---

## 核心类型：`Section`

```zig
pub const Section = struct {
    instructions: std.ArrayListUnmanaged(Word),
};
```

`Section` 是一个可增长的字缓冲区。所有指令按顺序追加。内存手动管理：调用 `section.deinit(allocator)` 释放。

### `deinit`

```zig
pub fn deinit(self: *Section, allocator: Allocator) void
```

释放所有内存并将结构体标记为无效。

### `reset`

```zig
pub fn reset(self: *Section) void
```

清空字缓冲区但不释放容量。可在不重新分配的情况下重用 Section 构建新的 SPIR-V 模块。

### `toWords` / `toBytes`

```zig
pub fn toWords(self: Section) []const Word
pub fn toBytes(self: Section) []const u8
```

将累积的字作为 `[]const u32` 或底层 `[]const u8` 返回。返回的切片在下次修改前有效。

---

## 发射

### `emit`（编译期安全）

```zig
pub fn emit(
    self: *Section,
    allocator: Allocator,
    comptime opcode: spec.Opcode,
    operands: opcode.Operands(),
) !void
```

主要发射函数。`operands` 必须是与操作码操作数布局匹配的结构体。结构体类型通过 `Opcode.Operands()` 在编译期派生，因此字段不匹配会在编译期捕获。

示例——`op_type_int` 需要 `{ id_result: Id, width: LiteralInteger, signedness: LiteralInteger }`：

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

类似 `emit`，但假设已通过 `ensureUnusedCapacity` 预留容量。不分配内存。

### `emitRaw`

```zig
pub fn emitRaw(
    self: *Section,
    allocator: Allocator,
    opcode: spec.Opcode,
    operand_words: usize,
) !void
```

发射操作码字和指定数量的尾随操作数字（初始为零）。用于延迟操作数修补。

### `emitRawInstruction`

```zig
pub fn emitRawInstruction(
    self: *Section,
    allocator: Allocator,
    opcode: spec.Opcode,
    operands: []const Word,
) !void
```

发射操作码后跟原始 `Word` 值。跳过编译期操作数类型检查。用于动态或不透明指令发射。

---

## 模块与文本输出

`Section` 只保存指令 word stream。需要完整 SPIR-V 模块时，使用 `module.Module` 生成五字头、body 和 id bound。

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

宿主传入 SPIRV-Tools 风格文本时，使用 native text compiler：

```zig
const bytes = try spirv.text.parseSourceToOwnedBytes(allocator, source, .{});
defer allocator.free(bytes);
```

---

## 大小计算

### `instructionSize`

```zig
pub fn instructionSize(
    comptime opcode: spec.Opcode,
    operands: opcode.Operands(),
) usize
```

返回指令的总字数（含操作码字）。可在编译期求值，用于静态大小计算。

### `operandsSize` / `operandSize`

```zig
pub fn operandsSize(comptime Operands: type, operands: Operands) usize
pub fn operandSize(comptime Operand: type, operand: Operand) usize
```

底层大小辅助函数。`operandsSize` 返回操作数结构体的字数；`operandSize` 返回单个操作数的字数。内部由 `emit` 使用，在写入前计算容量。

---

## 底层写入

### `writeWord` / `writeWords`

```zig
pub fn writeWord(self: *Section, word: Word) void
pub fn writeWords(self: *Section, words: []const Word) void
```

追加原始字（假设容量已预留）。由 `emitRawInstruction` 和 `writeExtendedMask` 使用。

### `writeDoubleWord`

```zig
pub fn writeDoubleWord(self: *Section, dword: u64) void
```

将 64 位值作为两个小端字追加。

### `writeString`

```zig
pub fn writeString(section: *Section, str: []const u8) void
```

写入以 null 结尾、按字对齐的 UTF-8 字符串。用于 `LiteralString` 操作数（`OpEntryPoint.name`、`OpString.string` 等）。

### `writeContextDependentNumber`

```zig
pub fn writeContextDependentNumber(
    section: *Section,
    operand: types.LiteralContextDependentNumber,
) void
```

写入上下文相关的字面量。32 位类型（`.int32`、`.uint32`、`.float32`）发射 1 字，64 位类型（`.int64`、`.uint64`、`.float64`）发射 2 字。用于 `OpConstant` 等。

---

## 规范类型

### `Opcode` 枚举

```zig
pub const Opcode = enum(u16) {
    op_nop = 0,
    op_undef = 1,
    // ... 877 变体 ...
    op_decorate_string_google = 5632,

    pub fn Operands(comptime self: Opcode) type { ... }
};
```

核心类型。每个变体映射到 XIR `op_*` 名称（转为小写蛇形加厂商后缀）。`Operands()` 返回操作码的编译期操作数结构体类型。

### ValueEnum 类型

所有 SPIR-V 值枚举为 `enum(u32)`。示例：

```zig
pub const Capability = enum(u32) { matrix = 0, shader = 1, ..., _ };
pub const StorageClass = enum(u32) { uniform_constant = 0, function = 7, ..., _ };
pub const Decoration = enum(u32) { relaxed_precision = 0, location = 30, ..., _ };
```

每个包含尾部 `_,` 通配符以兼容未来 SPIR-V 版本。

### BitEnum 类型（掩码操作数）

位掩码操作数使用 `packed struct(Word)`，每位一个 `bool` 字段：

```zig
pub const MemoryAccess = packed struct(Word) {
    volatile: bool = false,
    aligned: bool = false,
    nontemporal: bool = false,

    pub const Extended = struct {
        volatile: bool = false,
        aligned: ?struct { alignment: LiteralInteger } = null,
    };
};
```

内部的 `Extended` 结构体为每个位携带参数负载，使用 `?struct { ... } = null` 表示参数化标志。

### 参数化 Decoration / ExecutionMode

`Decoration` 和 `ExecutionMode` 各有 `Extended` 标签联合，将每个枚举值映射到其参数负载：

```zig
try section.emit(allocator, .op_decorate, .{
    .target = @enumFromInt(14),
    .decoration = .{ .location = .{ .location = 0 } },
});
```

---

## 类型

### `Word`

```zig
pub const Word = u32;
```

SPIR-V 基本单位。所有指令和值按字对齐。

### `Id`

```zig
pub const Id = enum(Word) { none, _, ... };
```

SPIR-V 结果/类型 ID。使用 `@enumFromInt(n)` 创建 ID，`@intFromEnum(id)` 提取字值。`.none` 哨兵为 `0`（非有效 SPIR-V Id）。

### `LiteralInteger` / `LiteralFloat` / `LiteralString`

```zig
pub const LiteralInteger = Word;
pub const LiteralFloat = Word;
pub const LiteralString = []const u8;
```

基本 SPIR-V 字面量类型别名。`LiteralString` 在发射时以 null 终止并补足字对齐。

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

用于 `OpConstant` 等字面量宽度取决于结果类型的指令。

### 配对类型

```zig
pub const PairLiteralIntegerIdRef = struct { value: LiteralInteger, label: Id };
pub const PairIdRefLiteralInteger = struct { target: Id, member: LiteralInteger };
pub const PairIdRefIdRef = [2]Id;
```

用于结构化控制流指令（`OpSwitch`、`OpPhi`、`OpLoopMerge` 等）。

### `IdRange`

```zig
pub const IdRange = struct { base: u32, len: u32, pub fn at(self, i: usize) Id };
```

用于分配连续 ID 的工具。`at(i)` 返回偏移 `i` 处的 `Id`。

### `EncodeError`

```zig
pub const EncodeError = error{
    InvalidOpcode,
    InvalidOperand,
    UnsupportedInstruction,
};
```

编码器模块的错误集。

---

## 使用模式

### 模块头部

```zig
var module = spirv.module.Module{};
defer module.deinit(allocator);

try module.setIdBound(10);
const bytes = try module.toOwnedBytes(allocator);
defer allocator.free(bytes);
```

### 类型与常量

```zig
// %1 = TypeInt 32, 0（有符号）
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

### 函数定义

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

### 参数化 Decoration

```zig
try section.emit(allocator, .op_decorate, .{
    .target = @enumFromInt(14),
    .decoration = .{ .location = .{ .location = 0 } },
});
```

### 动态操作码的原始发射

```zig
const opcode: spec.Opcode = lookupOpcode(name);
const op_words = computeOperandWords();
try section.emitRawInstruction(allocator, opcode, op_words);
```

## C API

SPIR-V 编码器同时提供 Zig API 和文本编译 C ABI：

```c
void *xir_asm_compile_spv(const char *source, size_t *out_size);
void xir_asm_free_spv(void *bytes, size_t size);
```

`xir_asm_compile_spv(source, &out_size)` 接受 SPIRV-Tools 风格的 `Op*`
源码并返回普通堆内存中的 SPIR-V 模块字节；返回指针不是可执行内存，使用
`xir_asm_free_spv(ptr, out_size)` 释放。

typed Section builder 仍是 Zig 专用接口；C ABI 走文本源码编译路径，因此不需要暴露每条 opcode 的结构体 ABI。

### 同一 DLL 中的现有 C 导出

共享库 `libxir_asm` 还导出：

- `xir_asm_compile` / `xir_asm_compile_rv` — x86/RISC-V 运行时编译
- `xir_asm_free` — 释放 x86 可执行内存
- `xir_new` / `xir_assemble` / ... — 有状态汇编器

详见 [`asm-api.md`](asm-api.md)。

---

## 架构

```
        ┌─────────────────────────────────────┐
        │  root.zig（pub const 重新导出）       │
        │  types、spec、section、module、text  │
        └──────┬──────────┬──────────┬────────┘
               │          │          │
        ┌──────▼──┐ ┌─────▼──────┐ ┌▼──────────────┐
        │ types.  │ │ spec.zig   │ │ section.zig    │
        │ zig     │ │ (877       │ │ Section 构建器  │
        │ Word、  │ │  opcodes,  │ │ emit/emitRaw,  │
        │ Id、    │ │  41        │ │ Module/text,  │
        │ Literal │ │  ValueEnums│ │ 大小计算、       │
        │ 类型、   │ │  16 BitEnums│ │ 字符串编码      │
        │ 配对类型 │ │  +Extended)│ │                │
        └─────────┘ └────────────┘ └────────────────┘
```

---

## 构建与测试

```powershell
zig build test          # 全部测试，含 SPIR-V 编码器
zig build               # DLL 构建
```

`spec.zig` 由 Khronos `SPIRV-Headers` unified1 grammar 生成，并随源码提交。

SPIR-V 编码器从 xir_asm 根模块重新导出：

```zig
const xir_asm = @import("xir_asm");
const spirv = xir_asm.spirv;
const Section = spirv.section.Section;
```
