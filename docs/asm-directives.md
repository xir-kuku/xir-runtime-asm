# XIR Runtime ASM Directive Reference

## Overview

XIR Runtime ASM provides a focused runtime source language for host
applications: data and reserve directives, labels, symbol constants, and basic
control directives (`repeat`/`iterate`/`while`/`if`). Broader compile-time DSL,
format-writing, and object-linking responsibilities belong to XIRASM rather
than this runtime library.

## Contents

- [Data emission directives](#data-emission-directives)
- [Reserve space directives](#reserve-space-directives)
- [Runnable directive example](#runnable-directive-example)
- [Control directives](#control-directives)
- [Symbol constant directives](#symbol-constant-directives)
- [Labels](#labels)
- [Comments](#comments)
- [Features replaceable by host](#features-replaceable-by-host)

---

## Data emission directives

Embed constant data directly into the output byte stream. All values are
encoded in **little-endian** order.

| Directive | Element size | Example                          |
| --------- | ------------ | -------------------------------- |
| `db`      | 1 byte       | `db 0xAB, 'A', "hello", 0x00`    |
| `dw`      | 2 bytes      | `dw 0x1234, 0x5678`              |
| `dd`      | 4 bytes      | `dd 0x12345678`                  |
| `dq`      | 8 bytes      | `dq 0x0102030405060708`          |

### Syntax

```
db  <expr> [, <expr> ...]
dw  <expr> [, <expr> ...]
dd  <expr> [, <expr> ...]
dq  <expr> [, <expr> ...]
```

Each `<expr>` can be:

- **Integer expression**: `42`, `0xFF`, `1 + 2`, `label - start`, `MAGIC`
- **Character literal**: `'A'` (single quotes, escape sequences supported)
- **String literal**: `"hello"` (double quotes, escape sequences supported)

### String escape sequences

| Sequence | Meaning              |
| -------- | -------------------- |
| `\n`     | newline 0x0A         |
| `\r`     | carriage return 0x0D |
| `\t`     | TAB 0x09             |
| `\\`     | backslash 0x5C       |
| `\'`     | single quote 0x27    |
| `\"`     | double quote 0x22    |
| `\0`     | null 0x00            |
| `\xNN`   | hex byte             |

### Examples

```asm
; Integers
db 0xAB, 0xCD, 0xEF
dw 0x1234, 0x5678
dd 0x12345678
dq 0x0102030405060708

; Characters / strings
db 'A', 0x00
db "Hello", 0x00

; Expressions
dd target - start
db MAGIC

; Mixed
db 0x01, "flag: ", 0x00
```

---

## Reserve space directives

Reserve N elements of zero-filled space in the output. Useful for variable/
buffer placeholders.

Runtime assembly materializes these reserved bytes as real `0x00` bytes. This
differs from offline executable-format emission, where a trailing reserve may be
represented by section size metadata instead of physically written bytes.

| Directive | Element size | Example                    |
| --------- | ------------ | -------------------------- |
| `rb`      | 1 byte       | `rb 16` (reserve 16 bytes) |
| `rw`      | 2 bytes      | `rw 4` (reserve 8 bytes)   |
| `rd`      | 4 bytes      | `rd 2` (reserve 8 bytes)   |
| `rq`      | 8 bytes      | `rq 1` (reserve 8 bytes)   |

```
rb <count_expr>
rw <count_expr>
rd <count_expr>
rq <count_expr>
```

`<count_expr>` may be a constant or a symbolic expression (must evaluate
during pass one).

### Examples

```asm
buffer: rb 64            ; 64-byte buffer
stack:  rw 32            ; 32 words = 64 bytes
table:  rd 256           ; 256 dwords = 1024 bytes
pml4:   rq 512           ; 512 qwords = 4096 bytes
```

---

## Runnable directive example

See `examples/src/directives.zig` for a complete Zig program that assembles and
checks real output bytes for data directives, runtime reserves, labels, `equ`,
`.org`, `.align`, `.local`, `repeat`, `iterate`, `indx`, `if`, `elseif`,
`while`, and `break`.

Run it with Zig 0.17:

```powershell
cd examples
zig build run-directives
```

---

## Control directives

### `.org` / `org` — Set output address

Set the current output position (VMA, virtual address) to a given value.
Subsequent bytes are emitted from that address onward.

```
.org <expr>
org  <expr>
```

`<expr>` must be evaluable during pass one.

`.org` changes the address used for labels, expressions, alignment, and
listing. It does not write zero bytes from address 0 up to the origin.

### `.align` / `align` — Alignment

Pad forward with zeros until the address reaches the specified boundary
(must be a power of two).

```
.align <boundary>
align  <boundary>
```

- `<boundary>`: power of two (2, 4, 8, 16, ...)
- Returns an error if boundary < 2 or not a power of two.

### `.local` / `local` — Local label

Define a label at the current address. Unlike colon labels, `.local` does
not implicitly bind to the current address segment.

```
.local <name>
local  <name>
```

**Note:** `.local` only defines a label — it does not manage stack frames.
RSP offsets must be managed by the host or manually via `equ`.

### `repeat` / `end repeat` — Static repetition

Repeat a block a fixed number of times.

```
repeat <count>
  <body>
end repeat
```

**Alias:** `rept` / `endrept`; closers also accept `end rept` and
`endrepeat`.

- `<count>`: integer expression (evaluated each pass, must converge)
- Maximum count: 1,000,000
- `%` expands to the 1-based iteration index.
- `%%` expands to the total repeat count.
- Optional named counters use `repeat <count>, name[:base]`.

```asm
repeat 3, i:0
  db i, %, %%
end repeat
; bytes: 00 01 03  01 02 03  02 03 03
```

### `iterate` / `end iterate` — Parameter substitution loop

Emit the body once per value, substituting a parameter name.

```
iterate <param>, <value1>, <value2>, ...
  <body>
end iterate
```

**Alias:** `irp` / `endirp`; closers also accept `end irp` and
`enditerate`.

**Substitution tokens:**

| Token     | Meaning                               |
| --------- | ------------------------------------- |
| `<param>` | Replaced with the current value       |
| `%`       | Replaced with 1-based iteration index |
| `%%`      | Replaced with total group count       |

Multiple parameters:

```asm
iterate <lo, hi>, 1, 10h, 2, 20h
  <body>
end iterate
```

Multiple parameters are written as a single bracketed parameter list. Values
are grouped by parameter count.

Parameter defaults fill missing values in the last group:

```asm
iterate <a, b:9>, 1, 2, 3
  db a, b
end iterate
; bytes: 01 02  03 09
```

Wrap a value group in angle brackets when one parameter should expand to a
comma-separated argument list:

```asm
iterate pair, <1,2>, <3,4>, 5
  db pair
end iterate
; bytes: 01 02  03 04  05
```

Append `?` to the parameter name to make replacement case-insensitive. The
body token also uses the `?` suffix:

```asm
iterate value?, 7, 9
  db VaLuE?
end iterate
; bytes: 07 09
```

Inside an active `iterate`, `indx <expr>` changes the current group selection.
The expression is 1-based and can use `%` and `%%`:

```asm
iterate value, 1, 2, 3
  indx 1+%%-%
  db value
end iterate
; bytes: 03 02 01
```

### `while` / `end while` — Conditional inclusion (pass-dependent)

Include the body when `<expr>` is non-zero. Re-evaluated each pass.

```
while <expr>
  <body>
end while
```

`endwhile` is also accepted.

`<expr>` is evaluated once per assembly pass. Useful for multi-pass
convergence patterns (e.g., generating instructions until a label converges).
Use `break` inside the body to stop the current loop. A constant-true `while`
without a reachable `break` eventually returns `ExpansionDepthExceeded`.

### `if` / `elseif` / `else` / `endif` — Conditional inclusion

Select one block among alternatives based on expression values.

```
if <expr>
  <body>
elseif <expr>
  <body>
else
  <body>
endif
```

- Conditions are evaluated each pass (symbols re-resolved)
- The first arm with a non-zero condition is emitted
- `else` is taken when no prior condition is true
- At most one `else`; `elseif` may appear before `else`
- `else if <expr>` and `end if` are also accepted.

---

## Symbol constant directives

### `equ` — Define constant

Define a compile-time constant.

```
equ  <name> = <expr>
```

- `<name>` cannot be redefined (conflicts with the label namespace)
- `<expr>` can be any evaluable expression (forward references supported)

### Examples

```asm
equ MAGIC  = 0x42
equ BASE   = 0x1000
equ OFFSET = 0x20
dw BASE + OFFSET
db MAGIC
```

---

## Labels

### Colon labels

```
<name>:
```

- Defines a label with value equal to the current output address
- Label scope is the entire assembly unit
- Label names cannot start with `.` (use the `.local` directive instead)
- Forward references are resolved across multiple passes

```asm
start:
    mov rax, 42
    ret

target:
    dd start - target
```

---

## Comments

A semicolon `;` or `//` begins a comment that runs to the end of the line.
Comments are not recognized inside string or character literals.

```asm
mov rax, 42   ; this sets rax = 42
; whole line comment
db "hello;world"  ; semicolons inside strings are not comments
db "http://example"  // slashes inside strings are not comments
```

---

## Runtime subset and host-side alternatives

This table describes the current runtime-assembler subset. A host-side
alternative means the feature is intentionally outside this small runtime API
today; it does not mean the original XIR feature is always semantically
equivalent to a one-line host replacement.

| Feature                             | XIR Runtime ASM | Host alternative                                             |
| ----------------------------------- | --------- | ------------------------------------------------------------ |
| `db` / `dw` / `dd` / `dq`           | yes       | —                                                            |
| `rb` / `rw` / `rd` / `rq`           | yes       | —                                                            |
| `.org` / `org`                     | yes       | —                                                            |
| `.align` / `align`                 | yes       | —                                                            |
| `.local` / `local`                 | yes       | —                                                            |
| `equ`                               | yes       | —                                                            |
| colon label `name:`                 | yes       | —                                                            |
| comments `;` and `//`               | yes       | —                                                            |
| DSL source transforms               | no        | host `string.replace` / regex                                |
| `%define` / `%assign`               | no        | host constants / `zig comptime`                              |
| `%macro` / `%endm`                  | no        | host functions that generate source text                     |
| `if` / `elseif` / `else` / `endif`  | yes       | —                                                            |
| `include` / `%include`              | no        | host file loading or language imports                        |
| `section` / `.section`              | no        | single segment plus `.org` when needed                       |
| `global` / `globl`                  | no        | host-managed symbol visibility                               |
| `struc` / `struct` / `endstruc`     | no        | host-computed offsets emitted as `equ`                       |
| `locals` / `endlocals`              | no        | host-computed RSP offsets plus `equ`, or manual stack frames |
| `repeat` / `end repeat`             | yes       | —                                                            |
| `while` / `end while`               | yes       | —                                                            |
| `iterate` / `end iterate`           | yes       | —                                                            |
| `break`                             | yes       | stops current control loop                                   |
| `indx`                              | yes       | changes current `iterate` group                              |
| `%rep` / `%endrep`                  | no        | `zig inline for` / loop unrolling                            |
| `.type` / `.size`                   | no        | not a target of this runtime library                         |

### About `struc` / `struct`

For runtime assembly generated by a host language, the preferred pattern is to
compute layout in the host and publish offsets as constants:

```asm
equ MyStruct.field_a = 0
equ MyStruct.field_b = 8
equ MyStruct.size = 16
```

In Zig, derive those values from `extern struct`, `packed struct`,
`@offsetOf`, `@alignOf`, and `@sizeOf` when the layout must match an ABI or a
host data structure.

This is not the same as implementing the original XIR `struc` system.
That feature owns a source-level layout DSL, member namespace rules,
defaults, nesting/union behavior, and instance emission semantics. If the
runtime library later targets higher source compatibility with existing XIR
programs, a narrow `struc` implementation may be worth adding; it is simply not
part of the current small runtime subset.
