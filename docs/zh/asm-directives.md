# XIR Runtime ASM 伪指令参考

## 概述

XIR Runtime ASM 为宿主应用提供聚焦的运行时源码语言：数据与保留指令、
标签、符号常量，以及基础控制指令（`repeat`/`iterate`/`while`/`if`）。
更完整的编译期 DSL、格式写入和对象链接职责属于 XIRASM，不属于这个
运行时库。

## 目录

- [数据发射指令](#数据发射指令)
- [保留空间指令](#保留空间指令)
- [可运行的伪指令示例](#可运行的伪指令示例)
- [控制指令](#控制指令)
- [符号常量指令](#符号常量指令)
- [标签](#标签)
- [注释](#注释)
- [运行时子集与宿主侧替代方案](#运行时子集与宿主侧替代方案)

---

## 数据发射指令

将常量数据直接嵌入输出字节流。所有数值按**小端序**编码。

| 指令   | 元素大小 | 示例                            |
| ------ | -------- | ------------------------------- |
| `db` | 1 字节   | `db 0xAB, 'A', "hello", 0x00` |
| `dw` | 2 字节   | `dw 0x1234, 0x5678`           |
| `dd` | 4 字节   | `dd 0x12345678`               |
| `dq` | 8 字节   | `dq 0x0102030405060708`       |

### 语法

```
db  <expr> [, <expr> ...]
dw  <expr> [, <expr> ...]
dd  <expr> [, <expr> ...]
dq  <expr> [, <expr> ...]
```

每个 `<expr>` 可以是：

- **整数表达式**：`42`, `0xFF`, `1 + 2`, `label - start`, `MAGIC`
- **字符字面量**：`'A'`（单引号，支持转义）
- **字符串字面量**：`"hello"`（双引号，支持转义）

### 字符串转义序列

| 序列     | 含义         |
| -------- | ------------ |
| `\n`   | 换行 0x0A    |
| `\r`   | 回车 0x0D    |
| `\t`   | TAB 0x09     |
| `\\`   | 反斜杠 0x5C  |
| `\'`   | 单引号 0x27  |
| `\"`   | 双引号 0x22  |
| `\0`   | 空字符 0x00  |
| `\xNN` | 十六进制字节 |

### 示例

```asm
; 整数
db 0xAB, 0xCD, 0xEF
dw 0x1234, 0x5678
dd 0x12345678
dq 0x0102030405060708

; 字符 / 字符串
db 'A', 0x00
db "Hello", 0x00

; 表达式
dd target - start
db MAGIC

; 混合
db 0x01, "flag: ", 0x00
```

---

## 保留空间指令

在输出中保留 N 个元素的零填充空间。用于变量/缓冲区的占位。

运行时汇编会把这些保留空间实际物化为 `0x00` 字节。这一点不同于
离线可执行格式输出：离线格式里，尾部 reserve 有时可由 section size
元数据表示，而不必真实写入文件。

| 指令   | 元素大小 | 示例                      |
| ------ | -------- | ------------------------- |
| `rb` | 1 字节   | `rb 16`（保留 16 字节） |
| `rw` | 2 字节   | `rw 4`（保留 8 字节）   |
| `rd` | 4 字节   | `rd 2`（保留 8 字节）   |
| `rq` | 8 字节   | `rq 1`（保留 8 字节）   |

```
rb <count_expr>
rw <count_expr>
rd <count_expr>
rq <count_expr>
```

`<count_expr>` 可以是常数或符号表达式（但必须在第一遍能求值）。

### 示例

```asm
buffer: rb 64            ; 64 字节缓冲区
stack:  rw 32            ; 32 words = 64 字节
table:  rd 256           ; 256 dwords = 1024 字节
pml4:   rq 512           ; 512 qwords = 4096 字节
```

---

## 可运行的伪指令示例

见 `examples/src/directives.zig`。这是一个完整 Zig 程序，会实际汇编并
校验输出字节，覆盖数据指令、运行时 reserve、标签、`equ`、`.org`、
`.align`、`.local`、`repeat`、`iterate`、`indx`、`if`、`elseif`、
`while` 和 `break`。

使用 Zig 0.17 运行：

```powershell
cd examples
zig build run-directives
```

---

## 控制指令

### `.org` / `org` — 设置输出地址

将当前输出位置（VMA，即虚拟地址）设置到指定值。后续字节从该地址开始。

```
.org <expr>
org  <expr>
```

`<expr>` 必须可在第一遍求值。

`.org` 会改变标签、表达式、对齐和 listing 使用的地址。它不会从地址 0
到 origin 之间写入零字节。

### `.align` / `align` — 对齐

向前填充零直到地址对齐到指定的边界（必须是 2 的幂）。

```
.align <boundary>
align  <boundary>
```

- `<boundary>`：2 的幂（2, 4, 8, 16, ...）
- 如果对齐边界 < 2 或不是 2 的幂，返回错误。

### `.local` / `local` — 局部标签

在当前地址定义一个标签。与冒号标签的区别：`.local` 不隐式绑定到当前地址区段，在某些多段场景下更安全。

```
.local <name>
local  <name>
```

**注意：** `.local` 只定义标签，不含栈帧管理。RSP 偏移由宿主自行计算（或使用 `equ` 手动管理）。

### `repeat` / `end repeat` — 固定次数重复

按指定次数重复一个文本块。

```
repeat <count>
  <body>
end repeat
```

**别名：** `rept` / `endrept`；闭合也接受 `end rept` 和 `endrepeat`。

- `<count>`：整数表达式（每遍重新求值，必须收敛）
- 最大次数：1,000,000
- `%` 展开为 1-based 迭代序号。
- `%%` 展开为 repeat 总次数。
- 可选命名计数器写作 `repeat <count>, name[:base]`。

```asm
repeat 3, i:0
  db i, %, %%
end repeat
; bytes: 00 01 03  01 02 03  02 03 03
```

### `iterate` / `end iterate` — 参数替换循环

对值列表中的每个值，替换参数名后输出一次 body。

```
iterate <param>, <value1>, <value2>, ...
  <body>
end iterate
```

**别名：** `irp` / `endirp`；闭合也接受 `end irp` 和 `enditerate`。

**替换标记：**

| 标记      | 含义                    |
| --------- | ----------------------- |
| `<param>` | 替换为当前值            |
| `%`       | 替换为 1-based 迭代序号 |
| `%%`      | 替换为分组总数          |

多参数示例：

```asm
iterate <lo, hi>, 1, 10h, 2, 20h
  <body>
end iterate
```

多个参数必须写成一个尖括号包裹的参数列表。后续值按参数数量分组。

参数默认值会填充最后一组缺失的值：

```asm
iterate <a, b:9>, 1, 2, 3
  db a, b
end iterate
; bytes: 01 02  03 09
```

当一个参数需要展开成逗号分隔的参数列表时，用尖括号包裹该值组：

```asm
iterate pair, <1,2>, <3,4>, 5
  db pair
end iterate
; bytes: 01 02  03 04  05
```

参数名后追加 `?` 可让替换大小写不敏感。body 中的 token 也使用 `?`
后缀：

```asm
iterate value?, 7, 9
  db VaLuE?
end iterate
; bytes: 07 09
```

在活跃的 `iterate` 内，`indx <expr>` 会切换当前分组选择。表达式是
1-based，并且可以使用 `%` 和 `%%`：

```asm
iterate value, 1, 2, 3
  indx 1+%%-%
  db value
end iterate
; bytes: 03 02 01
```

### `while` / `end while` — 条件包含（遍相关）

当 `<expr>` 非零时包含 body。每遍汇编重新求值。

```
while <expr>
  <body>
end while
```

也接受 `endwhile`。

`<expr>` 在每遍汇编开始时求值。适用于多遍收敛模式（例如，在标签值收敛之前不断生成指令）。
在 body 内使用 `break` 可以停止当前循环。常真 `while` 如果没有可达的
`break`，最终会返回 `ExpansionDepthExceeded`。

### `if` / `elseif` / `else` / `endif` — 条件包含

基于表达式的值选择一个分支输出。

```
if <expr>
  <body>
elseif <expr>
  <body>
else
  <body>
endif
```

- 条件每遍汇编重新求值（符号重新解析）
- 第一个非零条件对应的分支被输出
- 没有条件为真时执行 `else`
- 最多一个 `else`；`elseif` 可出现在 `else` 之前
- 也接受 `else if <expr>` 和 `end if`。

---

## 符号常量指令

### `equ` — 定义常量

定义一个编译期常量。

```
equ  <name> = <expr>
```

- `<name>` 不能重复定义（与标签命名空间冲突则报错）
- `<expr>` 可以是任何可求值的表达式（支持前向引用）

### 示例

```asm
equ MAGIC  = 0x42
equ BASE   = 0x1000
equ OFFSET = 0x20
dw BASE + OFFSET
db MAGIC
```

---

## 标签

### 冒号标签

```
<name>:
```

- 定义一个标签，值为当前输出地址
- 标签作用域是全局汇编单元
- 标签名不能以 `.` 开头（这点与 NASM 不同——使用 `.local` 指令代替）
- 前向引用会被多遍汇编解析

```asm
start:
    mov rax, 42
    ret

target:
    dd start - target
```

---

## 注释

分号 `;` 或 `//` 开始注释直到行尾。注释在字符串/字符字面量内部无效。

```asm
mov rax, 42   ; 这行设置 rax = 42
; 整行都是注释
db "hello;world"  ; 分号在字符串内不是注释
db "http://example"  // 字符串内的斜杠不是注释
```

---

## 运行时子集与宿主侧替代方案

此表描述当前运行时汇编器子集。所谓“宿主侧替代方案”，表示该功能目前
有意不放进这个小型运行时 API；它并不表示原始 XIR 功能总能被一行
宿主代码完全等价替代。

| 功能                                | XIR Runtime ASM | 宿主替代方案                                                 |
| ----------------------------------- | --------- | ------------------------------------------------------------ |
| `db` / `dw` / `dd` / `dq`           | yes       | —                                                            |
| `rb` / `rw` / `rd` / `rq`           | yes       | —                                                            |
| `.org` / `org`                     | yes       | —                                                            |
| `.align` / `align`                 | yes       | —                                                            |
| `.local` / `local`                 | yes       | —                                                            |
| `equ`                               | yes       | —                                                            |
| 冒号标签 `name:`                    | yes       | —                                                            |
| 注释 `;` 和 `//`                    | yes       | —                                                            |
| DSL 源级转换                        | no        | 宿主语言 `string.replace` / regex                            |
| `%define` / `%assign`               | no        | 宿主常量 / `zig comptime`                                    |
| `%macro` / `%endm`                  | no        | 生成汇编源码字符串的宿主函数                                 |
| `if` / `elseif` / `else` / `endif`  | yes       | —                                                            |
| `include` / `%include`              | no        | 宿主侧文件加载或语言导入                                     |
| `section` / `.section`              | no        | 单段模式；需要时配合 `.org`                                  |
| `global` / `globl`                  | no        | 宿主管理符号可见性                                           |
| `struc` / `struct` / `endstruc`     | no        | 宿主计算偏移并发射为 `equ`                                   |
| `locals` / `endlocals`              | no        | 宿主计算 RSP 偏移并发射为 `equ`，或手动管理栈帧              |
| `repeat` / `end repeat`             | yes       | —                                                            |
| `while` / `end while`               | yes       | —                                                            |
| `iterate` / `end iterate`           | yes       | —                                                            |
| `break`                             | yes       | 停止当前控制循环                                             |
| `indx`                              | yes       | 切换当前 `iterate` 分组                                      |
| `%rep` / `%endrep`                  | no        | `zig inline for` / 循环展开                                  |
| `.type` / `.size`                   | no        | 非此运行时库目标                                             |

### 关于 `struc` / `struct`

对于由宿主语言生成的运行时汇编，推荐模式是在宿主侧计算布局，再把偏移
发布为常量：

```asm
equ MyStruct.field_a = 0
equ MyStruct.field_b = 8
equ MyStruct.size = 16
```

在 Zig 中，如果布局必须匹配 ABI 或宿主数据结构，应从 `extern struct`、
`packed struct`、`@offsetOf`、`@alignOf` 和 `@sizeOf` 推导这些值。

这不等同于实现原始 XIR `struc` 系统。该功能拥有源码级布局 DSL、
成员命名空间规则、默认值、嵌套/union 行为和实例发射语义。如果
运行时库未来要提高对既有 XIR 源码的兼容性，可以再评估是否加入窄版
`struc` 实现；它不属于当前运行时子集。
