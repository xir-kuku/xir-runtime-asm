const std = @import("std");
const Assembler = @import("assembler.zig").Assembler;
const pass_driver = @import("pass_driver.zig");
const ExecMemory = @import("runtime.zig").ExecMemory;
const spirv_encoder = @import("../spirv_encoder/root.zig");
const page_allocator = std.heap.page_allocator;

const Allocator = std.mem.Allocator;

const Ctx = struct {
    assembler: Assembler,
    arena: std.heap.ArenaAllocator,
    last_output: ?[]u8 = null,
    last_error: ?[]u8 = null,
    last_listing: ?[]u8 = null,
};

fn storeWithSentinel(allocator: Allocator, src: []const u8) ?[]u8 {
    const buf = allocator.alloc(u8, src.len + 1) catch return null;
    if (src.len > 0) @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;
    return buf;
}

fn toSentinelPtr(s: ?[]u8) ?[*:0]const u8 {
    const slice = s orelse return null;
    if (slice.len == 0) return null;
    return slice[0 .. slice.len - 1 :0].ptr;
}

pub fn xir_new(mode_bits: u32) callconv(std.builtin.CallingConvention.c) ?*Ctx {
    const allocator = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    const ctx = allocator.create(Ctx) catch {
        arena.deinit();
        return null;
    };
    const assembler = Assembler.init(arena.allocator(), @as(u8, @intCast(mode_bits & 0xFF))) catch |err| switch (err) {
        error.OutOfMemory => {
            allocator.destroy(ctx);
            arena.deinit();
            return null;
        },
    };
    ctx.* = .{
        .assembler = assembler,
        .arena = arena,
    };
    return ctx;
}

pub fn xir_free(ctx: ?*Ctx) callconv(std.builtin.CallingConvention.c) void {
    if (ctx) |c| {
        c.assembler.deinit();
        const arena = c.arena;
        page_allocator.destroy(c);
        arena.deinit();
    }
}

pub fn xir_assemble(ctx: ?*Ctx, source: ?[*:0]const u8, out_len: *usize, out_err: ?*i32) callconv(std.builtin.CallingConvention.c) ?*u8 {
    const c = ctx orelse {
        if (out_err) |e| e.* = @intFromEnum(Error.NullArg);
        out_len.* = 0;
        return null;
    };
    const src = source orelse {
        if (out_err) |e| e.* = @intFromEnum(Error.NullArg);
        out_len.* = 0;
        return null;
    };
    const src_slice = src[0..std.mem.len(src)];
    const allocator = c.arena.allocator();
    const bits = c.assembler.mode_bits;

    const new_assembler = Assembler.init(allocator, bits) catch {
        if (out_err) |e| e.* = @intFromEnum(Error.Alloc);
        out_len.* = 0;
        return null;
    };
    c.assembler.deinit();
    c.assembler = new_assembler;

    const result = pass_driver.drive(allocator, &c.assembler, src_slice) catch |err| {
        const msg = switch (err) {
            error.OutOfMemory => "out of memory",
            error.InvalidInstruction => "invalid instruction",
            error.UndefinedSymbol => "undefined symbol",
            else => "assembly error",
        };
        if (c.last_error) |prev| allocator.free(prev);
        c.last_error = storeWithSentinel(allocator, msg);
        if (c.last_listing) |prev| allocator.free(prev);
        c.last_listing = null;
        if (out_err) |e| e.* = @intFromEnum(if (err == error.OutOfMemory) Error.Alloc else Error.Assembly);
        out_len.* = 0;
        return null;
    };

    if (out_err) |e| e.* = @intFromEnum(Error.Ok);
    out_len.* = result.output_bytes.len;
    if (c.last_output) |prev| allocator.free(prev);
    c.last_output = result.output_bytes;
    if (c.last_listing) |prev| allocator.free(prev);
    c.last_listing = storeWithSentinel(allocator, result.listing);
    allocator.free(result.listing);
    return @ptrCast(result.output_bytes.ptr);
}

pub fn xir_free_output(ctx: ?*Ctx) callconv(std.builtin.CallingConvention.c) void {
    if (ctx) |c| {
        if (c.last_output) |prev| {
            c.arena.allocator().free(prev);
            c.last_output = null;
        }
    }
}

pub fn xir_symbol_value(ctx: ?*Ctx, name: ?[*:0]const u8, found: ?*i32) callconv(std.builtin.CallingConvention.c) u64 {
    const c = ctx orelse {
        if (found) |f| f.* = 0;
        return 0;
    };
    const n = name orelse {
        if (found) |f| f.* = 0;
        return 0;
    };
    const n_slice = n[0..std.mem.len(n)];
    const value = c.assembler.symbols.lookupValue(n_slice) catch return 0;
    if (value) |v| {
        if (found) |f| f.* = 1;
        return @intCast(v);
    }
    if (found) |f| f.* = 0;
    return 0;
}

pub fn xir_diagnostic_message(ctx: ?*Ctx) callconv(std.builtin.CallingConvention.c) ?[*:0]const u8 {
    if (ctx == null) return null;
    return toSentinelPtr(ctx.?.last_error);
}

pub fn xir_get_listing(ctx: ?*Ctx) callconv(std.builtin.CallingConvention.c) ?[*:0]const u8 {
    if (ctx == null) return null;
    return toSentinelPtr(ctx.?.last_listing);
}

const Error = enum(i32) {
    Ok = 0,
    Alloc = -1,
    Assembly = -2,
    NullArg = -3,
};

pub fn xir_asm_compile(source: ?[*:0]const u8, mode_bits: u8, out_size: ?*usize) callconv(std.builtin.CallingConvention.c) ?*anyopaque {
    const src = source orelse {
        if (out_size) |s| s.* = 0;
        return null;
    };
    const src_slice = src[0..std.mem.len(src)];

    var arena = std.heap.ArenaAllocator.init(page_allocator);
    const allocator = arena.allocator();

    var assembler = Assembler.init(allocator, mode_bits) catch {
        if (out_size) |s| s.* = 0;
        arena.deinit();
        return null;
    };

    const result = pass_driver.drive(allocator, &assembler, src_slice) catch {
        if (out_size) |s| s.* = 0;
        arena.deinit();
        return null;
    };

    const code = result.output_bytes;
    if (code.len == 0) {
        if (out_size) |s| s.* = 0;
        arena.deinit();
        return null;
    }

    const mem = ExecMemory.allocate(code) catch {
        if (out_size) |s| s.* = 0;
        arena.deinit();
        return null;
    };

    const code_len = code.len;
    arena.deinit();
    if (out_size) |s| s.* = code_len;
    return mem.code_ptr;
}

pub fn xir_asm_free(code: ?*anyopaque) callconv(std.builtin.CallingConvention.c) void {
    ExecMemory.freeCodePtr(code);
}

pub fn xir_asm_compile_rv(source: ?[*:0]const u8, xlen: u8, out_size: ?*usize) callconv(std.builtin.CallingConvention.c) ?*anyopaque {
    if (comptime @import("build_opts").exclude_riscv) {
        if (out_size) |s| s.* = 0;
        return null;
    }
    const mode_bits: u8 = 0x80 | if (xlen >= 64) @as(u8, 16) else @as(u8, 0);
    return xir_asm_compile(source, mode_bits, out_size);
}

pub fn xir_asm_compile_spv(source: ?[*:0]const u8, out_size: ?*usize) callconv(std.builtin.CallingConvention.c) ?*anyopaque {
    if (comptime @import("build_opts").exclude_spirv) {
        if (out_size) |s| s.* = 0;
        return null;
    }
    const src = source orelse {
        if (out_size) |s| s.* = 0;
        return null;
    };
    const src_slice = src[0..std.mem.len(src)];

    const bytes = spirv_encoder.text.parseSourceToOwnedBytes(page_allocator, src_slice, .{}) catch {
        if (out_size) |s| s.* = 0;
        return null;
    };
    if (bytes.len == 0) {
        page_allocator.free(bytes);
        if (out_size) |s| s.* = 0;
        return null;
    }

    if (out_size) |s| s.* = bytes.len;
    return bytes.ptr;
}

pub fn xir_asm_free_spv(bytes: ?*anyopaque, size: usize) callconv(std.builtin.CallingConvention.c) void {
    const ptr = bytes orelse return;
    if (size == 0) return;
    const raw: [*]u8 = @ptrCast(ptr);
    page_allocator.free(raw[0..size]);
}
