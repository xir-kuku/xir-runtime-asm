# XIR Runtime ASM 文档

XIR Runtime ASM 是面向宿主语言的运行时汇编库。宿主传入汇编源码字符串，
库在当前进程中完成解析和编码；x86/x86-64 路径可以直接返回可调用的可执行
内存。

## 先看哪里

| 文档 | 内容 |
| --- | --- |
| [asm-api.md](asm-api.md) | Zig API、C ABI、所有权、可执行内存、线程规则 |
| [asm-directives.md](asm-directives.md) | 数据、保留、标签、控制流等运行时伪指令 |
| [riscv-encoder-api.md](riscv-encoder-api.md) | RISC-V 编码器 API |
| [spirv-encoder-api.md](spirv-encoder-api.md) | SPIR-V Section builder 和文本编译 API |

英文首页在 [../../README.md](../../README.md)。

## 典型使用路径

| 场景 | 推荐入口 |
| --- | --- |
| Zig 项目内直接汇编并执行 x86-64 | `Assembler.init` -> `pass_driver.drive` -> `ExecMemory.allocate` |
| C/Rust/动态语言调用 | `xir_asm_compile` / `xir_asm_free` |
| 需要符号、listing、诊断 | `xir_new` / `xir_assemble` / `xir_symbol_value` |
| RISC-V 生成字节 | `xir_asm_compile_rv` 或 `xir_asm.riscv.api` |
| SPIR-V 生成模块字节 | `xir_asm.spirv.text.parseSourceToOwnedBytes` 或 `xir_asm_compile_spv` |

## 可运行示例

进入仓库的 `examples/` 目录：

```powershell
zig build run
zig build run-directives
zig build run-showcase
```

| 示例 | 覆盖内容 |
| --- | --- |
| `examples/src/main.zig` | Zig 原生 API、C ABI、回调、RISC-V、SPIR-V |
| `examples/src/directives.zig` | 伪指令语法和精确输出字节 |
| `examples/src/showcase.zig` | CPUID/XGETBV 检测和 AVX2 64 字节 copy |

## 构建

```powershell
zig build
zig build test
zig build -Doptimize=ReleaseSafe
```

如果只需要 x86/x86-64，可以排除暂时不用的 ISA：

```powershell
zig build -Dexclude-riscv=true -Dexclude-spirv=true
```

## 能力边界

- x86/x86-64：运行时文本汇编、Zig 编码器 API、C ABI 可执行编译。
- RISC-V：Zig 编码器 API 和 C ABI 文本编译，返回目标机器码字节。
- SPIR-V：Zig Section builder 和文本编译；C ABI 为 `xir_asm_compile_spv` / `xir_asm_free_spv`。
- 伪指令：当前运行时子集见 [asm-directives.md](asm-directives.md)。

完整 XIR 汇编器中的宏系统、Meta 运行时、格式写入和二进制反射不属于这个
运行时库的当前目标。

## 环境要求

- Zig 0.17.0-dev，可通过 `zig` 命令调用。
- 无需外部汇编器。
- 无需外部 C/C++ 库依赖。

## 许可

项目源码采用 Apache-2.0。生成的 RISC-V 表来自 `riscv-opcodes`
数据，上游许可证为 BSD-3-Clause。生成的 SPIR-V 表来自 Khronos
`SPIRV-Headers` unified1 grammar，需保留对应上游 notice。
