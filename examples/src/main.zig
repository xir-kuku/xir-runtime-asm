const std = @import("std");
const builtin = @import("builtin");
const xir_asm = @import("xir_asm");
const Assembler = xir_asm.assembler.Assembler;
const ExecMemory = xir_asm.runtime.ExecMemory;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try demoNativeAssemble(alloc);
    try demoCAbi(alloc);
    try demoListing(alloc);
    try demoError(alloc);
    try demoExecMemory(alloc);
    try demoCallback(alloc);
    try demoRiscv(alloc);
    try demoSpirv(alloc);
}

// ─── Example 1: Native assemble + execute ───
fn demoNativeAssemble(alloc: std.mem.Allocator) !void {
    std.debug.print("=== Example 1: Zig native assemble + execute ===\n", .{});

    const src =
        \\mov eax, 42
        \\ret
    ;

    var a = try Assembler.init(alloc, 64);
    defer a.deinit();

    const result = try xir_asm.pass_driver.drive(alloc, &a, src);
    defer alloc.free(result.output_bytes);

    var mem = try ExecMemory.allocate(result.output_bytes);
    defer mem.deinit();

    const fn_ptr: *const fn () callconv(.c) i32 =
        @ptrCast(@alignCast(mem.code_ptr));

    std.debug.print("  result = {}  ({} bytes, {} passes, converged: {})\n", .{
        fn_ptr(),
        result.output_bytes.len,
        result.pass_count,
        result.converged,
    });
}

// ─── Example 2: C ABI single-call interface ───
fn demoCAbi(alloc: std.mem.Allocator) !void {
    _ = alloc;
    std.debug.print("=== Example 2: C ABI compile ===\n", .{});

    const src =
        \\mov rax, 99
        \\ret
    ;

    var out_size: usize = 0;
    const code = xir_asm.capi.xir_asm_compile(src, 64, &out_size) orelse {
        std.debug.print("  compile failed\n", .{});
        return;
    };
    defer xir_asm.capi.xir_asm_free(code);

    const fn_ptr: *const fn () callconv(.c) i64 =
        @ptrCast(@alignCast(code));

    std.debug.print("  result = {}  ({} bytes)\n", .{ fn_ptr(), out_size });
}

// ─── Example 3: Listing output + label symbols ───
fn demoListing(alloc: std.mem.Allocator) !void {
    std.debug.print("=== Example 3: Listing + symbols ===\n", .{});

    const src =
        \\start:
        \\  mov eax, 0x42
        \\  add eax, ebx
        \\  ret
    ;

    var a = try Assembler.init(alloc, 32);
    defer a.deinit();

    const result = try xir_asm.pass_driver.drive(alloc, &a, src);
    defer {
        alloc.free(result.output_bytes);
        alloc.free(result.listing);
    }

    std.debug.print("{s}", .{@as([]const u8, result.listing)});

    if (try a.symbols.lookupValue("start")) |v| {
        std.debug.print("  start = 0x{x}\n", .{v});
    }
    std.debug.print("  {} bytes, {} passes, converged: {}\n", .{
        result.output_bytes.len,
        result.pass_count,
        result.converged,
    });
}

// ─── Example 4: Error handling ───
fn demoError(alloc: std.mem.Allocator) !void {
    std.debug.print("=== Example 4: Error handling ===\n", .{});

    var a = try Assembler.init(alloc, 64);
    defer a.deinit();

    const result = xir_asm.pass_driver.drive(alloc, &a, "bad_instruction");
    if (result) |summary| {
        alloc.free(summary.output_bytes);
        alloc.free(summary.listing);
        std.debug.print("  unexpected success ({} bytes)\n", .{summary.output_bytes.len});
    } else |err| switch (err) {
        error.InvalidInstruction => std.debug.print("  caught InvalidInstruction\n", .{}),
        else => std.debug.print("  caught: {s}\n", .{@errorName(err)}),
    }
}

// ─── Example 5: ExecMemory raw code ───
fn demoExecMemory(alloc: std.mem.Allocator) !void {
    _ = alloc;
    std.debug.print("=== Example 5: ExecMemory raw code ===\n", .{});

    const code = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    var m = try ExecMemory.allocate(&code);
    defer m.deinit();

    const fn_ptr: *const fn () callconv(.c) i32 = @ptrCast(m.code_ptr);
    std.debug.print("  result = {}  (expected 42, code_len = {})\n", .{ fn_ptr(), m.code_len });
}

// ─── Example 6: Assembly calls Zig callback ───
fn demoCallback(alloc: std.mem.Allocator) !void {
    _ = alloc;
    std.debug.print("=== Example 6: assembly calls Zig callback ===\n", .{});

    // 汇编接收 2 个参数:
    //   arg1 = value  (Win:RCX / SysV:RDI)
    //   arg2 = callback fn ptr (Win:RDX / SysV:RSI)
    //
    // 汇编调用 callback(value), 返回值已在 RAX 中, 直接 pass through
    const src_win =
        \\push rbx
        \\mov  rbx, rdx     ; RBX = callback ptr
        \\sub  rsp, 32      ; shadow space
        \\call rbx          ; callback(RCX=value), 结果在 RAX
        \\add  rsp, 32
        \\pop  rbx
        \\ret
    ;
    const src_sysv =
        \\push rbx
        \\mov  rbx, rsi     ; RBX = callback ptr
        \\sub  rsp, 8       ; 对齐到 16 字节
        \\call rbx          ; callback(RDI=value), 结果在 RAX
        \\add  rsp, 8
        \\pop  rbx
        \\ret
    ;

    const src = if (builtin.os.tag == .windows) src_win else src_sysv;

    const code = xir_asm.capi.xir_asm_compile(src, 64, null) orelse {
        std.debug.print("  compile failed\n", .{});
        return;
    };
    defer xir_asm.capi.xir_asm_free(code);

    const fn_ptr: *const fn (i64, *const fn (i64) callconv(.c) i64) callconv(.c) i64 =
        @ptrCast(@alignCast(code));

    const double = struct {
        fn cb(x: i64) callconv(.c) i64 {
            return x * 2;
        }
    }.cb;
    const triple = struct {
        fn cb(x: i64) callconv(.c) i64 {
            return x * 3;
        }
    }.cb;

    std.debug.print("  fn(21, double) = {}  (期望 42)\n", .{fn_ptr(21, double)});
    std.debug.print("  fn(21, triple) = {}  (期望 63)\n", .{fn_ptr(21, triple)});
    std.debug.print("  fn(100, double) = {} (期望 200)\n", .{fn_ptr(100, double)});
}

// ─── Example 7: RISC-V (conditional) ───
fn demoRiscv(alloc: std.mem.Allocator) !void {
    _ = alloc;
    if (comptime @hasDecl(xir_asm, "riscv") and @hasDecl(xir_asm.riscv, "api")) {
        std.debug.print("=== Example 7: RISC-V ===\n", .{});

        const rv_src =
            \\addi x1, x2, 42
        ;

        const code = xir_asm.capi.xir_asm_compile_rv(rv_src, 64, null) orelse {
            std.debug.print("  compile failed\n", .{});
            return;
        };
        defer xir_asm.capi.xir_asm_free(code);

        const rv = xir_asm.riscv;
        const expected = try rv.api.encodeMnemonic("addi", 64, &.{
            rv.Operand{ .reg = 1 },
            rv.Operand{ .reg = 2 },
            rv.Operand{ .imm = 42 },
        });
        std.debug.print("  addi x1, x2, 42 → 0x{X:0>8}\n", .{expected.word});
    } else {
        std.debug.print("=== Example 7: RISC-V (excluded)\n", .{});
    }
}

// ─── Example 8: SPIR-V (conditional) ───
fn demoSpirv(alloc: std.mem.Allocator) !void {
    if (comptime @hasDecl(xir_asm, "spirv")) {
        std.debug.print("=== Example 8: SPIR-V ===\n", .{});

        const Section = xir_asm.spirv.section.Section;
        var section = Section{};
        defer section.deinit(alloc);

        try section.emitRaw(alloc, .op_nop, 0);

        const words = section.toWords();
        std.debug.print("  {} words", .{words.len});
        if (words.len > 0) std.debug.print(", word[0] = 0x{X:0>8}", .{words[0]});
        std.debug.print("\n", .{});
    } else {
        std.debug.print("=== Example 7: SPIR-V (excluded)\n", .{});
    }
}
