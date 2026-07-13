const std = @import("std");
const cg = @import("xir_asm");
const Assembler = cg.assembler.Assembler;
const pass_driver = cg.pass_driver;
const testing = std.testing;
const allocator = testing.allocator;
const builtin = @import("builtin");

const Result = struct {
    bytes: []u8,
    listing: []u8,
    pass_count: usize,
    converged: bool,

    fn deinit(r: *Result) void {
        allocator.free(r.bytes);
        allocator.free(r.listing);
    }
};

fn assemble(source: []const u8, mode_bits: u8) !Result {
    var assembler = try Assembler.init(allocator, mode_bits);
    defer assembler.deinit();
    const summary = try pass_driver.drive(allocator, &assembler, source);
    return Result{
        .bytes = summary.output_bytes,
        .listing = summary.listing,
        .pass_count = summary.pass_count,
        .converged = summary.converged,
    };
}

fn assembleOwned(source: []const u8, mode_bits: u8) !Result {
    var assembler = try Assembler.init(allocator, mode_bits);
    defer assembler.deinit();
    const summary = try pass_driver.drive(allocator, &assembler, source);
    const bytes = try allocator.dupe(u8, summary.output_bytes);
    errdefer allocator.free(bytes);
    const listing = try allocator.dupe(u8, summary.listing);
    errdefer allocator.free(listing);
    allocator.free(summary.output_bytes);
    allocator.free(summary.listing);
    return Result{
        .bytes = bytes,
        .listing = listing,
        .pass_count = summary.pass_count,
        .converged = summary.converged,
    };
}

test "empty source" {
    var result = try assemble("", 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.bytes.len);
    try testing.expect(result.converged);
}

test "single nop" {
    var result = try assemble("nop", 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x90), result.bytes[0]);
    try testing.expect(result.converged);
}

test "label definition" {
    var result = try assemble("label:", 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.bytes.len);
    try testing.expect(result.converged);
}

test "label defined before use" {
    var result = try assemble(
        \\start:
        \\nop
        \\nop
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.bytes.len);
    try testing.expect(result.converged);
}

test "forward reference resolved over multiple passes" {
    var result = try assemble(
        \\  nop
        \\  jmp target
        \\  nop
        \\target:
        \\  nop
    , 64);
    defer result.deinit();
    try testing.expectEqualSlices(u8, &.{ 0x90, 0xE9, 0x01, 0x00, 0x00, 0x00, 0x90, 0x90 }, result.bytes);
    try testing.expect(result.converged);
}

test "forward long jmp resolves to near rel32 after relaxation" {
    var result = try assemble(
        \\  jmp target
        \\  rb 200
        \\target:
        \\  ret
    , 64);
    defer result.deinit();

    try testing.expect(result.converged);
    try testing.expectEqual(@as(usize, 206), result.bytes.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xE9, 0xC8, 0x00, 0x00, 0x00 }, result.bytes[0..5]);
    try testing.expectEqual(@as(u8, 0xC3), result.bytes[result.bytes.len - 1]);
}

test "db byte values" {
    var result = try assemble("db 0xAB, 0xCD, 0xEF", 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.bytes.len);
    try testing.expectEqual(@as(u8, 0xAB), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0xCD), result.bytes[1]);
    try testing.expectEqual(@as(u8, 0xEF), result.bytes[2]);
    try testing.expect(result.converged);
}

test "dw word values" {
    var result = try assemble("dw 0x1234, 0x5678", 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 4), result.bytes.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x34, 0x12, 0x78, 0x56 }, result.bytes);
    try testing.expect(result.converged);
}

test "dd dword values" {
    var result = try assemble("dd 0x12345678", 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 4), result.bytes.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x78, 0x56, 0x34, 0x12 }, result.bytes);
    try testing.expect(result.converged);
}

test "dq qword values" {
    var result = try assemble("dq 0x0102030405060708", 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 8), result.bytes.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 }, result.bytes);
    try testing.expect(result.converged);
}

test "db character literal" {
    var result = try assemble("db 'Hello', 0x00", 64);
    defer result.deinit();
    try testing.expect(result.bytes.len >= 6);
    try testing.expectEqual(@as(u8, 'H'), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0x00), result.bytes[5]);
    try testing.expect(result.converged);
}

test "db string literal" {
    var result = try assemble("db \"Hello\", 0x00", 64);
    defer result.deinit();
    try testing.expect(result.bytes.len >= 6);
    try testing.expectEqual(@as(u8, 'H'), result.bytes[0]);
    try testing.expect(result.converged);
}

test "reserve bytes rb" {
    var result = try assemble("rb 16", 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 16), result.bytes.len);
    for (result.bytes) |b| try testing.expectEqual(@as(u8, 0), b);
    try testing.expect(result.converged);
}

test "reserve words rw" {
    var result = try assemble("rw 4", 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 8), result.bytes.len);
    try testing.expect(result.converged);
}

test ".org directive" {
    var result = try assemble(
        \\.org 0x1000
        \\db 0xAA
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.bytes.len);
    try testing.expectEqual(@as(u8, 0xAA), result.bytes[0]);
    try testing.expect(result.converged);
}

test ".align directive" {
    var result = try assemble(
        \\db 0x01
        \\.align 4
        \\db 0x02
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 5), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x01), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0x02), result.bytes[4]);
    try testing.expect(result.converged);
}

test "equ and use constant" {
    var result = try assemble(
        \\equ MAGIC = 0x42
        \\db MAGIC
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x42), result.bytes[0]);
    try testing.expect(result.converged);
}

test ".local label" {
    var result = try assemble(
        \\.local my_var
        \\db 0xFF
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.bytes.len);
    try testing.expectEqual(@as(u8, 0xFF), result.bytes[0]);
    try testing.expect(result.converged);
}

test "mov immediate" {
    var result = try assemble("mov eax, 0x12345678", 32);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 5), result.bytes.len);
    try testing.expectEqual(@as(u8, 0xB8), result.bytes[0]);
    try testing.expect(result.converged);
}

test "mov register to register (64-bit)" {
    var result = try assemble("mov rax, rbx", 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x48), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0x89), result.bytes[1]);
    try testing.expectEqual(@as(u8, 0xD8), result.bytes[2]);
    try testing.expect(result.converged);
}

test "add register (32-bit)" {
    var result = try assemble("add eax, ecx", 32);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x01), result.bytes[0]);
    try testing.expect(result.converged);
}

test "sub register" {
    var result = try assemble("sub rsp, 8", 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 4), result.bytes.len);
    try testing.expect(result.converged);
}

test "push/pop" {
    var result = try assemble("push rax\npop rbx", 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x50), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0x5B), result.bytes[1]);
    try testing.expect(result.converged);
}

test "ret instruction" {
    var result = try assemble("ret", 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.bytes.len);
    try testing.expectEqual(@as(u8, 0xC3), result.bytes[0]);
    try testing.expect(result.converged);
}

test "xchg instruction" {
    var result = try assemble("xchg eax, ebx", 32);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x93), result.bytes[0]);
    try testing.expect(result.converged);
}

test "multiple instructions with label" {
    var result = try assemble(
        \\start:
        \\  mov eax, 0x42
        \\  add eax, ebx
        \\  ret
    , 32);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 8), result.bytes.len);
    try testing.expect(result.converged);
}

test "forward jmp with label" {
    var result = try assemble(
        \\  jmp target
        \\  nop
        \\  nop
        \\target:
        \\  ret
    , 64);
    defer result.deinit();
    try testing.expect(result.converged);
    try testing.expect(result.bytes.len > 1);
}

test "listing contains source lines" {
    const source =
        \\nop
        \\nop
        \\ret
    ;
    var result = try assemble(source, 64);
    defer result.deinit();
    try testing.expect(result.listing.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.listing, "nop") != null);
    try testing.expect(std.mem.indexOf(u8, result.listing, "ret") != null);
}

test "invalid instruction returns error" {
    var assembler = try Assembler.init(allocator, 64);
    defer assembler.deinit();
    const result = pass_driver.drive(allocator, &assembler, "foobarbaz");
    try testing.expectError(error.InvalidInstruction, result);
}

test "comments are ignored" {
    var result = try assemble(
        \\nop ; this is a comment
        \\; another comment
        \\ret
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.bytes.len);
    try testing.expect(result.converged);
}

test "expression with forward reference" {
    var result = try assemble(
        \\  dd target - start
        \\start:
        \\  nop
        \\target:
        \\  ret
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 6), result.bytes.len);
    try testing.expect(result.converged);
}

test "32-bit vs 64-bit mode affects encoding" {
    var result32 = try assemble("inc eax", 32);
    defer result32.deinit();
    var result64 = try assemble("inc eax", 64);
    defer result64.deinit();
    try testing.expectEqual(@as(usize, 1), result32.bytes.len);
    try testing.expectEqual(@as(usize, 2), result64.bytes.len);
    try testing.expectEqual(@as(u8, 0x40), result32.bytes[0]);
    try testing.expectEqual(@as(u8, 0xFF), result64.bytes[0]);
}

test "multiple passes converge" {
    var result = try assemble(
        \\  jmp skip
        \\  nop
        \\skip:
        \\  mov eax, 0xFF
        \\  ret
    , 32);
    defer result.deinit();
    try testing.expect(result.converged);
    try testing.expect(result.pass_count <= 100);
    try testing.expect(result.pass_count >= 1);
}

test "complex expression" {
    var result = try assemble(
        \\equ BASE = 0x1000
        \\equ OFFSET = 0x20
        \\dw BASE + OFFSET
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x20), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0x10), result.bytes[1]);
}

test "stack manipulation" {
    var result = try assemble(
        \\push rbp
        \\mov rbp, rsp
        \\sub rsp, 0x20
        \\mov rsp, rbp
        \\pop rbp
        \\ret
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 13), result.bytes.len);
    try testing.expect(result.converged);
}

test "consistent output on reassembly" {
    const source =
        \\mov eax, 0x42
        \\mov ebx, eax
        \\ret
    ;
    var a = try assembleOwned(source, 32);
    defer a.deinit();
    var b = try assembleOwned(source, 32);
    defer b.deinit();
    try testing.expectEqualSlices(u8, a.bytes, b.bytes);
}

test "align with zero bytes" {
    var result = try assemble(
        \\db 0xFF
        \\.align 8
        \\db 0xEE
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 9), result.bytes.len);
    try testing.expectEqual(@as(u8, 0xFF), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0xEE), result.bytes[8]);
    for (result.bytes[1..8]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "mov eax, [ebx] indirect" {
    var result = try assemble("mov eax, [ebx]", 32);
    defer result.deinit();
    try testing.expectEqual(@as(u8, 0x8B), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0x03), result.bytes[1]);
}

test "lea instruction" {
    var result = try assemble("lea eax, [ebx+ecx]", 32);
    defer result.deinit();
    try testing.expectEqualSlices(u8, &.{ 0x8D, 0x04, 0x0B }, result.bytes);
}

test "and/or/xor" {
    var result = try assemble(
        \\and eax, ebx
        \\or  ecx, edx
        \\xor esi, edi
    , 32);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 6), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x21), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0x09), result.bytes[2]);
    try testing.expectEqual(@as(u8, 0x31), result.bytes[4]);
}

test "immediate to memory" {
    var result = try assemble("mov byte [ebx], 0xAA", 32);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.bytes.len);
    try testing.expectEqual(@as(u8, 0xC6), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0x03), result.bytes[1]);
    try testing.expectEqual(@as(u8, 0xAA), result.bytes[2]);
}

test "conditional jump" {
    var result = try assemble(
        \\  cmp eax, 0
        \\  je  equal
        \\  mov eax, 1
        \\equal:
        \\  ret
    , 32);
    defer result.deinit();
    try testing.expectEqualSlices(u8, &.{ 0x83, 0xF8, 0x00, 0x0F, 0x84, 0x05, 0x00, 0x00, 0x00, 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3 }, result.bytes);
    try testing.expect(result.converged);
}

test "ExecMemory allocate and free" {
    const ExecMemory = cg.runtime.ExecMemory;
    const code = [_]u8{0xC3};
    var m = try ExecMemory.allocate(&code);
    defer m.deinit();
    try testing.expect(m.code_len == 1);
    try testing.expect(m.code_ptr[0] == 0xC3);
}

test "ExecMemory allocate larger code" {
    const ExecMemory = cg.runtime.ExecMemory;
    const code = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    var m = try ExecMemory.allocate(&code);
    defer m.deinit();
    try testing.expect(m.code_len == 6);
    try testing.expectEqualSlices(u8, &code, m.code_ptr[0..m.code_len]);
}

test "ExecMemory allocate zero-length code" {
    const ExecMemory = cg.runtime.ExecMemory;
    const code = [_]u8{};
    var m = try ExecMemory.allocate(&code);
    defer m.deinit();
    try testing.expect(m.code_len == 0);
}

test "xir_asm_compile basic" {
    const code_ptr = cg.capi.xir_asm_compile("mov eax, 42\nret", 64, null) orelse
        return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code_ptr);
    try testing.expect(@as([*]u8, @ptrCast(code_ptr))[0] == 0xB8);
}

test "xir_asm_compile with size" {
    var out_size: usize = 0;
    const code_ptr = cg.capi.xir_asm_compile("nop\nnop\nret", 64, &out_size) orelse
        return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code_ptr);
    try testing.expect(out_size == 3);
}

test "xir_asm_compile null source returns null" {
    var out_size: usize = 0xAA;
    const result = cg.capi.xir_asm_compile(null, 64, &out_size);
    try testing.expect(result == null);
    try testing.expect(out_size == 0);
}

test "xir_asm_compile invalid instruction" {
    const result = cg.capi.xir_asm_compile("badinstruction", 64, null);
    try testing.expect(result == null);
}

test "xir_asm_free null is no-op" {
    cg.capi.xir_asm_free(null);
}

test "ExecMemory execute simple ret function" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const ExecMemory = cg.runtime.ExecMemory;
    const code = [_]u8{0xC3};
    var m = try ExecMemory.allocate(&code);
    defer m.deinit();

    const func: *const fn () callconv(std.builtin.CallingConvention.c) void = @ptrCast(m.code_ptr);
    func();
}

test "ExecMemory execute mov eax and ret" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const ExecMemory = cg.runtime.ExecMemory;
    const code = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    var m = try ExecMemory.allocate(&code);
    defer m.deinit();

    const func: *const fn () callconv(std.builtin.CallingConvention.c) i32 = @ptrCast(m.code_ptr);
    try testing.expectEqual(@as(i32, 42), func());
}

test "xir_asm_compile execute mov rax and ret" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const code_ptr = cg.capi.xir_asm_compile("mov rax, 42\nret", 64, null) orelse
        return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code_ptr);

    const func: *const fn () callconv(std.builtin.CallingConvention.c) i64 = @ptrCast(code_ptr);
    try testing.expectEqual(@as(i64, 42), func());
}

test "ExecMemory allocate multiple independent blocks" {
    const ExecMemory = cg.runtime.ExecMemory;
    const code_a = [_]u8{0xC3};
    const code_b = [_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3 };

    var m_a = try ExecMemory.allocate(&code_a);
    defer m_a.deinit();
    var m_b = try ExecMemory.allocate(&code_b);
    defer m_b.deinit();

    try testing.expect(m_a.code_ptr != m_b.code_ptr);
    try testing.expect(m_a.code_len == 1);
    try testing.expect(m_b.code_len == 6);
}

// ─── Host interaction: function pointer calling ───

test "host: call blank fn (just ret)" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const ExecMemory = cg.runtime.ExecMemory;
    var m = try ExecMemory.allocate(&[_]u8{0xC3});
    defer m.deinit();

    const fn_ptr: *const fn () callconv(std.builtin.CallingConvention.c) void = @ptrCast(m.code_ptr);
    fn_ptr();
}

test "host: call fn returning i64 constant" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const ExecMemory = cg.runtime.ExecMemory;
    const code = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    var m = try ExecMemory.allocate(&code);
    defer m.deinit();

    const fn_ptr: *const fn () callconv(std.builtin.CallingConvention.c) i32 = @ptrCast(m.code_ptr);
    try testing.expectEqual(@as(i32, 42), fn_ptr());
}

test "host: call fn returning 64-bit value" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const code_ptr = cg.capi.xir_asm_compile("mov rax, 0x123456789A\nret", 64, null) orelse
        return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code_ptr);

    const fn_ptr: *const fn () callconv(std.builtin.CallingConvention.c) u64 = @ptrCast(code_ptr);
    try testing.expectEqual(@as(u64, 0x123456789A), fn_ptr());
}

test "host: call fn with one arg (cdecl)" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    // On x64 Windows: 1st arg = RCX
    // On x64 Linux:   1st arg = RDI
    // Compile identity function: just return the first argument
    const src =
        if (builtin.os.tag == .windows)
            \\mov rax, rcx
            \\ret
        else
            \\mov rax, rdi
            \\ret
        ;

    const code_ptr = cg.capi.xir_asm_compile(src, 64, null) orelse
        return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code_ptr);

    const fn_ptr: *const fn (i64) callconv(std.builtin.CallingConvention.c) i64 = @ptrCast(code_ptr);
    try testing.expectEqual(@as(i64, 99), fn_ptr(99));
    try testing.expectEqual(@as(i64, -1), fn_ptr(-1));
}

test "host: call fn with two args" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    // Windows: arg1=RCX, arg2=RDX
    // Linux:   arg1=RDI, arg2=RSI
    const src =
        if (builtin.os.tag == .windows)
            \\mov rax, rcx
            \\add rax, rdx
            \\ret
        else
            \\mov rax, rdi
            \\add rax, rsi
            \\ret
        ;

    const code_ptr = cg.capi.xir_asm_compile(src, 64, null) orelse
        return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code_ptr);

    const fn_ptr: *const fn (i64, i64) callconv(std.builtin.CallingConvention.c) i64 = @ptrCast(code_ptr);
    try testing.expectEqual(@as(i64, 30), fn_ptr(10, 20));
    try testing.expectEqual(@as(i64, 0), fn_ptr(-5, 5));
}

test "host: compile via stateful API + ExecMemory execution" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    // Use stateful API to assemble, then load into ExecMemory manually
    var result = try assemble("mov eax, 0x42\nret", 32);
    defer result.deinit();

    const ExecMemory = cg.runtime.ExecMemory;
    var m = try ExecMemory.allocate(result.bytes);
    defer m.deinit();

    const fn_ptr: *const fn () callconv(std.builtin.CallingConvention.c) i32 = @ptrCast(m.code_ptr);
    try testing.expectEqual(@as(i32, 0x42), fn_ptr());
}

test "host: xir_asm_compile null safety" {
    const code_ptr = cg.capi.xir_asm_compile(null, 64, null);
    try testing.expect(code_ptr == null);
}

test "host: xir_asm_free null safety" {
    cg.capi.xir_asm_free(null);
}

test "host: multiple asm blocks coexist" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const a = cg.capi.xir_asm_compile("mov rax, 10\nret", 64, null) orelse
        return error.SkipZigTest;
    defer cg.capi.xir_asm_free(a);

    const b = cg.capi.xir_asm_compile("mov rax, 20\nret", 64, null) orelse
        return error.SkipZigTest;
    defer cg.capi.xir_asm_free(b);

    const fn_a: *const fn () callconv(std.builtin.CallingConvention.c) i64 = @ptrCast(a);
    const fn_b: *const fn () callconv(std.builtin.CallingConvention.c) i64 = @ptrCast(b);

    try testing.expectEqual(@as(i64, 10), fn_a());
    try testing.expectEqual(@as(i64, 20), fn_b());
}

// ─── Host Interop: ABI, Callbacks, Data Pointers ───
// These tests serve as documentation for the platform C ABI.
//
// KEY INSIGHT: The generated assembly accesses the host ONLY through
// function parameters (registers) and data pointers (memory). There are
// no extern symbols, no linker, no import tables — it's raw binary.
//
// On x86-64, the C ABI depends on the OS:
//   Windows x64: RCX, RDX, R8, R9, [RSP+32], [RSP+40], ...  (shadow space)
//   System V:    RDI, RSI, RDX, RCX, R8, R9, [RSP], [RSP+8], ...
//
// On RISC-V RV64 (LP64): a0-a7 = x10-x17, then stack.

/// Temporary RW memory for passing data between host and assembly.
const DataBlock = struct {
    field_a: i64 = 0,
    field_b: i64 = 0,
    sum: i64 = 0,
    flag: i64 = 0,
};

test "host interop: identity — 1 arg in, same value out" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const src = comptime if (builtin.os.tag == .windows) "mov rax, rcx\nret" else "mov rax, rdi\nret";
    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);
    const fn_ptr: *const fn (i64) callconv(.c) i64 = @ptrCast(@alignCast(code));
    try testing.expectEqual(@as(i64, 42), fn_ptr(42));
    try testing.expectEqual(@as(i64, -1), fn_ptr(-1));
    try testing.expectEqual(@as(i64, 0x7FFF_FFFF_FFFF_FFFF), fn_ptr(0x7FFF_FFFF_FFFF_FFFF));
}

test "host interop: add — 2 args sum" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const reg1 = comptime if (builtin.os.tag == .windows) "rcx" else "rdi";
    const reg2 = comptime if (builtin.os.tag == .windows) "rdx" else "rsi";
    const src = comptime "mov rax, " ++ reg1 ++ "\nadd rax, " ++ reg2 ++ "\nret";
    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);
    const fn_ptr: *const fn (i64, i64) callconv(.c) i64 = @ptrCast(@alignCast(code));
    try testing.expectEqual(@as(i64, 30), fn_ptr(10, 20));
    try testing.expectEqual(@as(i64, -10), fn_ptr(-30, 20));
    try testing.expectEqual(@as(i64, 0), fn_ptr(100, -100));
}

test "host interop: 4 args — multiply and sum" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const src = comptime blk: {
        const r1 = if (builtin.os.tag == .windows) "rcx" else "rdi";
        const r2 = if (builtin.os.tag == .windows) "rdx" else "rsi";
        const r3 = if (builtin.os.tag == .windows) "r8" else "rdx";
        const r4 = if (builtin.os.tag == .windows) "r9" else "rcx";
        break :blk "mov rax, " ++ r1 ++ "\nimul rax, " ++ r2 ++ "\nmov r10, " ++ r3 ++ "\nimul r10, " ++ r4 ++ "\nadd rax, r10\nret";
    };
    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);
    const fn_ptr: *const fn (i64, i64, i64, i64) callconv(.c) i64 = @ptrCast(@alignCast(code));
    try testing.expectEqual(@as(i64, 26), fn_ptr(2, 3, 4, 5));
    try testing.expectEqual(@as(i64, 1400), fn_ptr(10, 20, 30, 40));
}

test "host interop: 6 args — all register, no stack" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const src = blk: {
        if (builtin.os.tag == .windows) {
            // Win64: args 1-4 in RCX,RDX,R8,R9; args 5-6 on stack at [rsp+40],[rsp+48]
            // (shadow space 32 bytes occupies [rsp+8]..[rsp+40]; ret addr at [rsp])
            break :blk
            \\mov rax, rcx
            \\imul rax, rdx
            \\mov r10, r8
            \\imul r10, r9
            \\add rax, r10
            \\mov r10, [rsp + 40]
            \\imul r10, [rsp + 48]
            \\add rax, r10
            \\ret
            ;
        } else {
            break :blk
            \\mov rax, rdi
            \\imul rax, rsi
            \\mov r10, rdx
            \\imul r10, rcx
            \\add rax, r10
            \\mov r10, r8
            \\imul r10, r9
            \\add rax, r10
            \\ret
            ;
        }
    };
    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);
    const fn_ptr: *const fn (i64, i64, i64, i64, i64, i64) callconv(.c) i64 = @ptrCast(@alignCast(code));
    try testing.expectEqual(@as(i64, 68), fn_ptr(2, 3, 4, 5, 6, 7));
    try testing.expectEqual(@as(i64, 44), fn_ptr(1, 2, 3, 4, 5, 6));
}

test "host interop: call callback — assembly calls a Zig function" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    // The assembly receives TWO args:
    //   arg1 = a value to pass to the callback
    //   arg2 = function pointer to call
    //
    // The assembly calls the callback with arg1, then returns the result.
    //
    // Win:   arg1=RCX, arg2=RDX, call target in RDX (must save to non-volatile)
    // SysV:  arg1=RDI, arg2=RSI, call target in RSI
    //
    // IMPORTANT: The call instruction expects the target address in a register
    // or memory. On Win64, the caller must allocate 32 bytes of shadow space
    // before `call`. We use `sub rsp, 32` / `add rsp, 32` for safety.
    //
    // Non-volatile registers MUST be preserved (RBX, RBP, RDI, RSI, R12-R15 on Win;
    // RBX, RBP, R12-R15 on SysV). We save RBX before using it.

    const src = blk: {
        if (builtin.os.tag == .windows) {
            break :blk
            \\push rbx
            \\mov rcx, rcx    ; arg1 = RCX (value for callback)
            \\mov rbx, rdx    ; arg2 = RDX → RBX (callback ptr, save to non-volatile)
            \\sub rsp, 32     ; allocate shadow space
            \\call rbx        ; call the callback
            \\add rsp, 32     ; restore shadow space
            \\pop rbx
            \\ret
            ;
        } else {
            break :blk
            \\push rbx
            \\mov rdi, rdi    ; arg1 = RDI (value for callback)
            \\mov rbx, rsi    ; arg2 = RSI → RBX (callback ptr, save to non-volatile)
            \\sub rsp, 8      ; align stack to 16 bytes (RSP will be 16-byte aligned at call)
            \\call rbx        ; call the callback
            \\add rsp, 8
            \\pop rbx
            \\ret
            ;
        }
    };

    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);

    const fn_ptr: *const fn (i64, *const fn (i64) callconv(.c) i64) callconv(.c) i64 =
        @ptrCast(@alignCast(code));

    // Zig callback: double the input
    const double = struct {
        fn cb(x: i64) callconv(.c) i64 {
            return x * 2;
        }
    }.cb;

    // Zig callback: negate the input
    const negate = struct {
        fn cb(x: i64) callconv(.c) i64 {
            return -x;
        }
    }.cb;

    try testing.expectEqual(@as(i64, 84), fn_ptr(42, double));
    try testing.expectEqual(@as(i64, -42), fn_ptr(42, negate));
    try testing.expectEqual(@as(i64, 200), fn_ptr(100, double));
}

test "host interop: callback with 3 args — full round trip" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    // Assembly receives 4 args:
    //   arg1, arg2, arg3 = values to pass to callback
    //   arg4 = callback function pointer
    // Assembly calls: callback(arg1, arg2, arg3) and returns the result.
    //
    // Win: RCX=v1, RDX=v2, R8=v3, R9=fn_ptr
    //      call requires shadow space (sub rsp, 32)
    // SysV: RDI=v1, RSI=v2, RDX=v3, RCX=fn_ptr
    //      call requires 16-byte aligned RSP

    const src = blk: {
        if (builtin.os.tag == .windows) {
            break :blk
            \\push rbx
            \\mov rbx, r9     ; save callback ptr to non-volatile
            \\sub rsp, 32     ; shadow space for call
            \\; arg1 already in RCX, arg2 in RDX, arg3 in R8
            \\call rbx
            \\add rsp, 32
            \\pop rbx
            \\ret
            ;
        } else {
            break :blk
            \\push rbx
            \\mov rbx, rcx    ; save callback ptr (arg4=RCX) to non-volatile
            \\; arg1 in RDI, arg2 in RSI, arg3 in RDX — already set
            \\sub rsp, 8
            \\call rbx
            \\add rsp, 8
            \\pop rbx
            \\ret
            ;
        }
    };

    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);

    const fn_ptr: *const fn (i64, i64, i64, *const fn (i64, i64, i64) callconv(.c) i64) callconv(.c) i64 =
        @ptrCast(@alignCast(code));

    const sum3 = struct {
        fn cb(a: i64, b: i64, c: i64) callconv(.c) i64 {
            return a + b + c;
        }
    }.cb;

    try testing.expectEqual(@as(i64, 6), fn_ptr(1, 2, 3, sum3));
    try testing.expectEqual(@as(i64, 60), fn_ptr(10, 20, 30, sum3));
}

test "host interop: data pointer — assembly reads/writes through ptr" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    // Assembly receives ONE arg: a pointer to a DataBlock struct.
    // It reads field_a and field_b, computes field_a + field_b,
    // stores the result in .sum, and sets .flag = 1.
    //
    // The pointer arrives in arg1 (RCX or RDI).
    // struct fields are at offsets:
    //   field_a @ 0
    //   field_b @ 8
    //   sum     @ 16
    //   flag    @ 24

    const src = blk: {
        if (builtin.os.tag == .windows) {
            break :blk
            \\mov rax, rcx
            \\mov rcx, [rax + 0]
            \\mov rdx, [rax + 8]
            \\add rcx, rdx
            \\mov [rax + 16], rcx
            \\mov qword [rax + 24], 1
            \\ret
            ;
        } else {
            break :blk
            \\mov rax, rdi
            \\mov rcx, [rax + 0]
            \\mov rdx, [rax + 8]
            \\add rcx, rdx
            \\mov [rax + 16], rcx
            \\mov qword [rax + 24], 1
            \\ret
            ;
        }
    };

    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);

    const fn_ptr: *const fn (*DataBlock) callconv(.c) void = @ptrCast(@alignCast(code));

    var db = DataBlock{ .field_a = 100, .field_b = 200 };
    fn_ptr(&db);
    try testing.expectEqual(@as(i64, 300), db.sum);
    try testing.expectEqual(@as(i64, 1), db.flag);

    var db2 = DataBlock{ .field_a = -50, .field_b = 25 };
    fn_ptr(&db2);
    try testing.expectEqual(@as(i64, -25), db2.sum);
    try testing.expectEqual(@as(i64, 1), db2.flag);
}

test "host interop: callback + data — assembly calls Zig with a pointer" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    // Assembly receives TWO args:
    //   arg1 = pointer to a DataBlock
    //   arg2 = callback function (which takes a *DataBlock)
    //
    // Assembly calls: callback(ptr), then returns.

    const src = blk: {
        if (builtin.os.tag == .windows) {
            break :blk
            \\push rbx
            \\mov rbx, rdx     ; save callback ptr (arg2=RDX)
            \\sub rsp, 32
            \\; arg1=RCX already has the data pointer
            \\call rbx
            \\add rsp, 32
            \\pop rbx
            \\ret
            ;
        } else {
            break :blk
            \\push rbx
            \\mov rbx, rsi     ; save callback ptr (arg2=RSI)
            \\sub rsp, 8
            \\; arg1=RDI already has the data pointer
            \\call rbx
            \\add rsp, 8
            \\pop rbx
            \\ret
            ;
        }
    };

    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);

    const fn_ptr: *const fn (*DataBlock, *const fn (*DataBlock) callconv(.c) void) callconv(.c) void =
        @ptrCast(@alignCast(code));

    var db = DataBlock{ .field_a = 7, .field_b = 3 };
    const processor = struct {
        fn process(ptr: *DataBlock) callconv(.c) void {
            ptr.sum = ptr.field_a * ptr.field_b;
            ptr.flag = 1;
        }
    }.process;

    fn_ptr(&db, processor);
    try testing.expectEqual(@as(i64, 21), db.sum);
    try testing.expectEqual(@as(i64, 1), db.flag);
}

test "host interop: indirect call via memory — dispatch table" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    // Pattern: assembly receives a dispatch table pointer + function index.
    // It reads the function pointer from the table and calls it.
    //
    // const DispatchTable = struct {
    //     fns: [4]*const fn (i64) callconv(.c) i64,
    // };
    //
    // Assembly: fn_ptr = table[index]; return fn_ptr(value);

    const src = blk: {
        if (builtin.os.tag == .windows) {
            break :blk
            \\; arg1=RCX = *DispatchTable
            \\; arg2=RDX = index
            \\; arg3=R8  = value to pass to dispatch function
            \\push rbx
            \\mov rbx, [rcx + rdx*8]  ; load fn pointer from table
            \\mov rcx, r8              ; pass value as arg1
            \\sub rsp, 32
            \\call rbx
            \\add rsp, 32
            \\pop rbx
            \\ret
            ;
        } else {
            break :blk
            \\; arg1=RDI = *DispatchTable
            \\; arg2=RSI = index
            \\; arg3=RDX = value to pass to dispatch function
            \\push rbx
            \\mov rbx, [rdi + rsi*8]  ; load fn pointer from table
            \\mov rdi, rdx              ; pass value as arg1
            \\sub rsp, 8
            \\call rbx
            \\add rsp, 8
            \\pop rbx
            \\ret
            ;
        }
    };

    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);

    const Fn = *const fn (i64) callconv(.c) i64;
    const fn_ptr: *const fn (*const [4]Fn, usize, i64) callconv(.c) i64 =
        @ptrCast(@alignCast(code));

    const add10 = struct {
        fn f(x: i64) callconv(.c) i64 {
            return x + 10;
        }
    }.f;
    const mul2 = struct {
        fn f(x: i64) callconv(.c) i64 {
            return x * 2;
        }
    }.f;
    const sub5 = struct {
        fn f(x: i64) callconv(.c) i64 {
            return x - 5;
        }
    }.f;
    const neg = struct {
        fn f(x: i64) callconv(.c) i64 {
            return -x;
        }
    }.f;
    const table = [4]Fn{ add10, mul2, sub5, neg };

    try testing.expectEqual(@as(i64, 52), fn_ptr(&table, 0, 42)); // add10(42)
    try testing.expectEqual(@as(i64, 84), fn_ptr(&table, 1, 42)); // mul2(42)
    try testing.expectEqual(@as(i64, 37), fn_ptr(&table, 2, 42)); // sub5(42)
    try testing.expectEqual(@as(i64, -42), fn_ptr(&table, 3, 42)); // neg(42)
}

test "host interop: stack alignment is correct" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    // The platform C ABI requires RSP to be 16-byte aligned at the
    // point of the `call` instruction. This assembly checks the
    // alignment by returning RSP & 0xF. If aligned, result is 0.
    //
    // After the platform ABI prologue (call pushes return address),
    // RSP = 8 mod 16 inside the callee. The callee must ensure
    // RSP is 16-byte aligned before calling any other function.

    const src =
        \\mov rax, rsp
        \\and rax, 0xF
        \\ret
    ;

    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);

    // At function entry (after `call` pushed return addr), RSP should be 8 mod 16
    const fn_ptr: *const fn () callconv(.c) i64 = @ptrCast(@alignCast(code));
    try testing.expectEqual(@as(i64, 8), fn_ptr());
}

test "host interop: callback preserves non-volatile registers" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    // CALLEE-SAVED (non-volatile) registers on x86-64:
    //   Win:  RBX, RBP, RDI, RSI, R12-R15, XMM6-XMM15
    //   SysV: RBX, RBP, R12-R15
    //
    // This assembly: sets R12 to a magic value, calls a callback
    // (which may clobber R12), then checks R12 is preserved.
    //
    // If R12 still has the magic value, return 1; else return 0.

    const src = blk: {
        if (builtin.os.tag == .windows) {
            break :blk
            \\push r12
            \\mov r12, 0x7EADBEEF
            \\push rbx
            \\mov rbx, rdx     ; callback ptr in arg2=RDX
            \\mov rcx, rcx     ; arg1 value to pass
            \\sub rsp, 32
            \\call rbx
            \\add rsp, 32
            \\pop rbx
            \\xor rax, rax
            \\cmp r12, 0x7EADBEEF
            \\sete al
            \\pop r12
            \\ret
            ;
        } else {
            break :blk
            \\push r12
            \\mov r12, 0x7EADBEEF
            \\push rbx
            \\mov rbx, rsi     ; callback ptr in arg2=RSI
            \\mov rdi, rdi     ; arg1 value
            \\sub rsp, 8
            \\call rbx
            \\add rsp, 8
            \\pop rbx
            \\xor rax, rax
            \\cmp r12, 0x7EADBEEF
            \\sete al
            \\pop r12
            \\ret
            ;
        }
    };

    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);

    const fn_ptr: *const fn (i64, *const fn (i64) callconv(.c) i64) callconv(.c) i64 =
        @ptrCast(@alignCast(code));

    const identity = struct {
        fn cb(x: i64) callconv(.c) i64 {
            return x;
        }
    }.cb;

    try testing.expectEqual(@as(i64, 1), fn_ptr(42, identity));
}

test "host interop: struct return via hidden pointer" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    // On x86-64 C ABI, structs larger than 16 bytes are returned via
    // a hidden pointer: the caller allocates space and passes the
    // address as a "shadow arg" at the front (before all regular args).
    //
    // For this test, assembly receives a hidden pointer in arg1 (RAX
    // return convention) + regular args, and constructs a struct in
    // the caller-allocated space.
    //
    // On SysV: hidden pointer in RDI, then regular args shift right by 1.
    // On Win:  hidden pointer in RCX, then regular args shift right by 1.
    //
    // We test with a 32-byte struct: { a: i64, b: i64, c: i64, d: i64 }

    const Large = extern struct { a: i64, b: i64, c: i64, d: i64 };

    // The hidden pointer arrives in the first arg register.
    // The regular arg shifts to the next register.
    //
    // Win:  RCX = hidden ptr, RDX = regular arg (value)
    // SysV: RDI = hidden ptr, RSI = regular arg (value)
    const src = blk: {
        if (builtin.os.tag == .windows) {
            break :blk
            \\mov rax, rdx    ; the value to fill in
            \\mov [rcx + 0], rax  ; .a = value
            \\mov [rcx + 8], rax  ; .b = value
            \\mov [rcx + 16], rax ; .c = value
            \\mov [rcx + 24], rax ; .d = value
            \\mov rax, rcx        ; return the hidden pointer in RAX
            \\ret
            ;
        } else {
            break :blk
            \\mov rax, rsi    ; the value to fill in
            \\mov [rdi + 0], rax  ; .a = value
            \\mov [rdi + 8], rax  ; .b = value
            \\mov [rdi + 16], rax ; .c = value
            \\mov [rdi + 24], rax ; .d = value
            \\mov rax, rdi        ; return the hidden pointer in RAX
            \\ret
            ;
        }
    };

    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);

    // Zig handles the hidden pointer automatically for struct returns
    const fn_ptr: *const fn (i64) callconv(.c) Large = @ptrCast(@alignCast(code));

    const result = fn_ptr(42);
    try testing.expectEqual(@as(i64, 42), result.a);
    try testing.expectEqual(@as(i64, 42), result.b);
    try testing.expectEqual(@as(i64, 42), result.c);
    try testing.expectEqual(@as(i64, 42), result.d);

    const result2 = fn_ptr(-1);
    try testing.expectEqual(@as(i64, -1), result2.a);
    try testing.expectEqual(@as(i64, -1), result2.d);
}

test "host interop: void callback modifies state via pointer" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    // Pattern: assembly receives a data pointer + callback pointer.
    // It calls callback(data_ptr), then reads data_ptr->result.
    //
    // This demonstrates the "context pointer" pattern used by runtime
    // code generators.

    const Context = struct {
        input: i64,
        result: i64,
        called: bool,
    };

    const src = blk: {
        if (builtin.os.tag == .windows) {
            break :blk
            \\push rbx
            \\push rdi         ; save non-volatile to hold ctx ptr
            \\mov rbx, rdx     ; save callback ptr (arg2=RDX)
            \\mov rdi, rcx     ; save ctx ptr (arg1=RCX → non-volatile RDI)
            \\sub rsp, 32
            \\mov rcx, rdi     ; ctx pointer back to arg1
            \\call rbx
            \\add rsp, 32
            \\mov rax, [rdi + 8]  ; read ctx.result (RDI preserved across call)
            \\pop rdi
            \\pop rbx
            \\ret
            ;
        } else {
            break :blk
            \\push rbx
            \\push r12         ; save non-volatile to hold ctx ptr
            \\mov rbx, rsi     ; save callback ptr (arg2=RSI)
            \\mov r12, rdi     ; save ctx ptr (arg1=RDI → non-volatile R12)
            \\sub rsp, 8
            \\mov rdi, r12     ; ctx pointer back to arg1
            \\call rbx
            \\add rsp, 8
            \\mov rax, [r12 + 8]  ; read ctx.result (R12 preserved across call)
            \\pop r12
            \\pop rbx
            \\ret
            ;
        }
    };

    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);

    const fn_ptr: *const fn (*Context, *const fn (*Context) callconv(.c) void) callconv(.c) i64 =
        @ptrCast(@alignCast(code));

    const doubler = struct {
        fn cb(ctx: *Context) callconv(.c) void {
            ctx.result = ctx.input * 2;
            ctx.called = true;
        }
    }.cb;

    var ctx = Context{ .input = 21, .result = 0, .called = false };
    const result = fn_ptr(&ctx, doubler);
    try testing.expectEqual(@as(i64, 42), result);
    try testing.expectEqual(true, ctx.called);
}

test "host interop: chain callbacks — dispatch table with context" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    // Advanced pattern: assembly receives a context pointer, and calls
    // the callback pointer stored *inside* the context. This is the
    // standard runtime codegen calling pattern (like a vtable).
    //
    // struct Handler {
    //     callback: *const fn (i64) callconv(.c) i64,
    //     value: i64,
    // }

    const Handler = struct {
        callback: *const fn (i64) callconv(.c) i64,
        value: i64,
    };

    // arg1 = *Handler (pointer read from there)
    // The handler has callback at offset 0, value at offset 8.
    // Load callback, pass value to it, return result.

    const src = blk: {
        if (builtin.os.tag == .windows) {
            break :blk
            \\push rbx
            \\mov rbx, [rcx + 0]  ; load callback from handler+0
            \\mov rcx, [rcx + 8]  ; load value from handler+8
            \\sub rsp, 32
            \\call rbx
            \\add rsp, 32
            \\pop rbx
            \\ret
            ;
        } else {
            break :blk
            \\push rbx
            \\mov rbx, [rdi + 0]  ; load callback from handler+0
            \\mov rdi, [rdi + 8]  ; load value from handler+8
            \\sub rsp, 8
            \\call rbx
            \\add rsp, 8
            \\pop rbx
            \\ret
            ;
        }
    };

    const code = cg.capi.xir_asm_compile(src, 64, null) orelse return error.SkipZigTest;
    defer cg.capi.xir_asm_free(code);

    const fn_ptr: *const fn (*Handler) callconv(.c) i64 = @ptrCast(@alignCast(code));

    const triple = struct {
        fn cb(x: i64) callconv(.c) i64 {
            return x * 3;
        }
    }.cb;

    var h = Handler{ .callback = triple, .value = 14 };
    try testing.expectEqual(@as(i64, 42), fn_ptr(&h));
}

// ── RISC-V encoder tests ──

const riscv_tests = if (@hasDecl(cg.riscv, "api")) struct {
    test "riscv: module decls" {
        testing.refAllDecls(cg.riscv);
    }

    test "riscv: encode addi" {
        const rv = cg.riscv;
        const result = try rv.api.encodeMnemonic("addi", 64, &.{
            rv.Operand{ .reg = 1 },
            rv.Operand{ .reg = 2 },
            rv.Operand{ .imm = 42 },
        });
        const expected = [_]u8{ 0x93, 0x00, 0xA1, 0x02 };
        try testing.expectEqualSlices(u8, &expected, result.asSlice());
    }

    test "riscv: encode add" {
        const rv = cg.riscv;
        const result = try rv.api.encodeMnemonic("add", 64, &.{
            rv.Operand{ .reg = 1 },
            rv.Operand{ .reg = 2 },
            rv.Operand{ .reg = 3 },
        });
        const expected = [_]u8{ 0xB3, 0x00, 0x31, 0x00 };
        try testing.expectEqualSlices(u8, &expected, result.asSlice());
    }

    test "riscv: parse register ABI names" {
        const rv = cg.riscv;
        try testing.expectEqual(@as(u5, 0), try rv.api.parseRegister("zero"));
        try testing.expectEqual(@as(u5, 1), try rv.api.parseRegister("ra"));
        try testing.expectEqual(@as(u5, 2), try rv.api.parseRegister("sp"));
        try testing.expectEqual(@as(u5, 10), try rv.api.parseRegister("a0"));
        try testing.expectEqual(@as(u5, 8), try rv.api.parseRegister("s0"));
        try testing.expectEqual(@as(u5, 5), try rv.api.parseRegister("t0"));
    }

    test "riscv: parse register numeric" {
        const rv = cg.riscv;
        try testing.expectEqual(@as(u5, 0), try rv.api.parseRegister("x0"));
        try testing.expectEqual(@as(u5, 5), try rv.api.parseRegister("x5"));
        try testing.expectEqual(@as(u5, 31), try rv.api.parseRegister("x31"));
        try testing.expectEqual(@as(u5, 0), try rv.api.parseRegister("f0"));
        try testing.expectEqual(@as(u5, 3), try rv.api.parseRegister("v3"));
    }

    test "riscv: encode lui" {
        const rv = cg.riscv;
        const result = try rv.api.encodeMnemonic("lui", 64, &.{
            rv.Operand{ .reg = 1 },
            rv.Operand{ .imm = 0x12345 },
        });
        const word = @as(u32, 0x12345 << 12) | (@as(u32, 1) << 7) | 0x37;
        try testing.expectEqual(word, result.word);
    }

    test "riscv: compile addi via compile_rv" {
        if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
        const code = cg.capi.xir_asm_compile_rv("addi x1, x2, 42", 64, null) orelse return error.UnexpectedNull;
        defer cg.capi.xir_asm_free(code);
        const result = try cg.riscv.api.encodeMnemonic("addi", 64, &.{
            cg.riscv.Operand{ .reg = 1 },
            cg.riscv.Operand{ .reg = 2 },
            cg.riscv.Operand{ .imm = 42 },
        });
        const expected = result.asSlice();
        const code_bytes = @as([*]const u8, @ptrCast(code))[0..expected.len];
        try testing.expectEqualSlices(u8, expected, code_bytes);
    }

    test "riscv: assemble multi-line via compile_rv" {
        if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
        const code = cg.capi.xir_asm_compile_rv(
            \\addi  x1, x2, 10
            \\addi  x1, x1, 32
            \\add   x1, x1, x3
        , 64, null) orelse return error.UnexpectedNull;
        defer cg.capi.xir_asm_free(code);
    }

    test "riscv: assemble with label and data directive" {
        if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
        const code = cg.capi.xir_asm_compile_rv(
            \\my_data:
            \\dd 42, 100
            \\addi x1, x2, 10
        , 64, null) orelse return error.UnexpectedNull;
        defer cg.capi.xir_asm_free(code);
    }

    test "riscv: encode invalid mnemonic returns error" {
        const rv = cg.riscv;
        const result = rv.api.encodeMnemonic("not_a_real_instruction", 64, &.{});
        try testing.expectError(error.UnsupportedInstruction, result);
    }

    test "riscv: encode with wrong operand count" {
        const rv = cg.riscv;
        const result = rv.api.encodeMnemonic("addi", 64, &.{
            rv.Operand{ .reg = 1 },
        });
        try testing.expectError(error.OperandCountMismatch, result);
    }
} else struct {};

test "assembler write output to file" {
    var assm = try Assembler.init(allocator, 0);
    defer assm.deinit();

    try assm.emitBytes(&.{ 0x90, 0x90 });

    const io = testing.io;
    const cwd = std.Io.Dir.cwd();
    const tmp = "asm_write_test.tmp";
    defer cwd.deleteFile(io, tmp) catch {};

    try assm.writeOutputToFilePath(io, tmp);

    const content = try cwd.readFileAlloc(io, tmp, allocator, .unlimited);
    defer allocator.free(content);

    try testing.expectEqual(@as(usize, 2), content.len);
    try testing.expectEqual(@as(u8, 0x90), content[0]);
    try testing.expectEqual(@as(u8, 0x90), content[1]);
}

// ─── Control directive tests ───

test "repeat basic" {
    var result = try assemble(
        \\repeat 3
        \\nop
        \\end repeat
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.bytes.len);
    for (result.bytes) |b| try testing.expectEqual(@as(u8, 0x90), b);
    try testing.expect(result.converged);
}

test "repeat exposes percent counters" {
    var result = try assemble(
        \\repeat 3
        \\db %, %%
        \\end repeat
    , 64);
    defer result.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 3, 2, 3, 3, 3 }, result.bytes);
    try testing.expect(result.converged);
}

test "repeat named counter with base expression" {
    var result = try assemble(
        \\repeat 4, i:0
        \\db i
        \\end repeat
    , 64);
    defer result.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3 }, result.bytes);
    try testing.expect(result.converged);
}

test "repeat rept alias" {
    var result = try assemble(
        \\rept 2
        \\nop
        \\endrept
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.bytes.len);
    for (result.bytes) |b| try testing.expectEqual(@as(u8, 0x90), b);
    try testing.expect(result.converged);
}

test "repeat zero" {
    var result = try assemble(
        \\repeat 0
        \\nop
        \\end repeat
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.bytes.len);
    try testing.expect(result.converged);
}

test "iterate basic" {
    var result = try assemble(
        \\iterate val, 0x90, 0xC3
        \\db val
        \\end iterate
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x90), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0xC3), result.bytes[1]);
    try testing.expect(result.converged);
}

test "iterate irp alias" {
    var result = try assemble(
        \\irp val, 0x90, 0xC3
        \\db val
        \\endirp
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x90), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0xC3), result.bytes[1]);
    try testing.expect(result.converged);
}

test "while truthy with break" {
    var result = try assemble(
        \\while 1
        \\nop
        \\break
        \\end while
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x90), result.bytes[0]);
    try testing.expect(result.converged);
}

test "while truthy without break reaches expansion limit" {
    try testing.expectError(error.ExpansionDepthExceeded, assemble(
        \\while 1
        \\nop
        \\end while
    , 64));
}

test "while falsy" {
    var result = try assemble(
        \\while 0
        \\nop
        \\end while
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.bytes.len);
    try testing.expect(result.converged);
}

test "if truthy" {
    var result = try assemble(
        \\if 1
        \\nop
        \\endif
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x90), result.bytes[0]);
    try testing.expect(result.converged);
}

test "if falsy with else" {
    var result = try assemble(
        \\if 0
        \\nop
        \\else
        \\ret
        \\endif
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.bytes.len);
    try testing.expectEqual(@as(u8, 0xC3), result.bytes[0]);
    try testing.expect(result.converged);
}

test "if elseif else" {
    var result = try assemble(
        \\if 0
        \\db 0x01
        \\elseif 0
        \\db 0x02
        \\else
        \\db 0x03
        \\endif
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x03), result.bytes[0]);
    try testing.expect(result.converged);
}

test "iterate multiple params" {
    var result = try assemble(
        \\iterate <low, high>, 0x90, 0xC3
        \\db low
        \\db high
        \\end iterate
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x90), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0xC3), result.bytes[1]);
    try testing.expect(result.converged);
}

test "iterate percent substitution" {
    var result = try assemble(
        \\iterate val, 0x90, 0xC3
        \\db val + %
        \\end iterate
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x91), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0xC5), result.bytes[1]);
    try testing.expect(result.converged);
}

test "iterate double percent" {
    var result = try assemble(
        \\iterate val, 0x90, 0xC3
        \\db %%
        \\end iterate
    , 64);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 2), result.bytes.len);
    try testing.expectEqual(@as(u8, 2), result.bytes[0]);
    try testing.expectEqual(@as(u8, 2), result.bytes[1]);
    try testing.expect(result.converged);
}

test "iterate grouped params and default values" {
    var result = try assemble(
        \\iterate <a,b:9>, 1,2, 3
        \\db a, b
        \\end iterate
    , 64);
    defer result.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 9 }, result.bytes);
    try testing.expect(result.converged);
}

test "iterate wrapped value groups expand as one argument" {
    var result = try assemble(
        \\iterate pair, <1,2>, <3,4>, 5
        \\db pair
        \\end iterate
    , 64);
    defer result.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4, 5 }, result.bytes);
    try testing.expect(result.converged);
}

test "iterate case insensitive parameter marker" {
    var result = try assemble(
        \\iterate value?, 7, 9
        \\db VaLuE?
        \\end iterate
    , 64);
    defer result.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 7, 9 }, result.bytes);
    try testing.expect(result.converged);
}

test "iterate indx can reverse current item selection" {
    var result = try assemble(
        \\iterate value, 1, 2, 3
        \\indx 1+%%-%
        \\db value
        \\end iterate
    , 64);
    defer result.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 3, 2, 1 }, result.bytes);
    try testing.expect(result.converged);
}

test "iterate indx inside nested repeat changes nearest iterate" {
    var result = try assemble(
        \\iterate value, 1, 2, 3
        \\repeat 1
        \\indx 3
        \\end repeat
        \\db value
        \\end iterate
    , 64);
    defer result.deinit();
    try testing.expectEqualSlices(u8, &[_]u8{ 3, 3, 3 }, result.bytes);
    try testing.expect(result.converged);
}

test "if control is re-expanded per pass after forward symbol resolves" {
    var result = try assemble(
        \\if target - start
        \\db 0xAA
        \\else
        \\db 0xBB
        \\endif
        \\start:
        \\nop
        \\target:
    , 64);
    defer result.deinit();

    try testing.expect(result.converged);
    try testing.expectEqual(@as(usize, 2), result.bytes.len);
    try testing.expectEqual(@as(u8, 0xAA), result.bytes[0]);
    try testing.expectEqual(@as(u8, 0x90), result.bytes[1]);
}

test "repeat stops at top-level break" {
    var result = try assemble(
        \\repeat 5
        \\nop
        \\break
        \\end repeat
    , 64);
    defer result.deinit();

    try testing.expect(result.converged);
    try testing.expectEqual(@as(usize, 1), result.bytes.len);
    try testing.expectEqual(@as(u8, 0x90), result.bytes[0]);
}

test "mismatched nested control closer is rejected" {
    try testing.expectError(error.InvalidInstruction, assemble(
        \\repeat 1
        \\if 1
        \\nop
        \\end repeat
        \\endif
    , 64));
}
