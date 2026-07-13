const std = @import("std");
const xir_asm = @import("xir_asm");

const Assembler = xir_asm.assembler.Assembler;

const ExampleError = error{
    DidNotConverge,
    UnexpectedBytes,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    try expectBytes(allocator, "data literals", data_source, &.{
        0xAB, 0x41, 0x48, 0x69, 0x0A, 0x00,
        0x34, 0x12, 0x78, 0x56, 0x34, 0x12,
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03,
        0x02, 0x01,
    });

    try expectBytes(allocator, "runtime reserves write zeros", reserve_source, &.{
        0x11,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0x22,
    });

    try expectBytes(allocator, "labels, equ, and forward branch", labels_source, &.{
        0x42, 0xE9, 0x03, 0,    0,    0,
        0,    0,    0,    0x09, 0xC3,
    });

    try expectBytes(allocator, ".org, .align, and .local", origin_source, &.{
        0x01, 0, 0, 0, 0x04,
    });

    try expectBytes(allocator, "repeat counters", repeat_source, &.{
        0, 1, 3,
        1, 2, 3,
        2, 3, 3,
    });

    try expectBytes(allocator, "iterate grouped parameters", iterate_group_source, &.{
        1, 2, 3, 9,
    });

    try expectBytes(allocator, "iterate wrapped argument groups", iterate_wrapped_source, &.{
        1, 2, 3, 4, 5,
    });

    try expectBytes(allocator, "iterate case marker and counters", iterate_case_source, &.{
        7, 1, 2,
        9, 2, 2,
    });

    try expectBytes(allocator, "iterate indx selection", iterate_indx_source, &.{
        3, 2, 1,
    });

    try expectBytes(allocator, "if, elseif, while, and break", flow_source, &.{
        0xAA, 0xCC,
    });

    std.debug.print("all directive examples passed\n", .{});
}

fn expectBytes(
    allocator: std.mem.Allocator,
    title: []const u8,
    source: []const u8,
    expected: []const u8,
) !void {
    var assembler = try Assembler.init(allocator, 64);
    defer assembler.deinit();

    const result = try xir_asm.pass_driver.drive(allocator, &assembler, source);
    defer allocator.free(result.output_bytes);
    defer allocator.free(result.listing);

    if (!result.converged) return ExampleError.DidNotConverge;
    if (!std.mem.eql(u8, expected, result.output_bytes)) {
        std.debug.print("{s}: expected ", .{title});
        printHex(expected);
        std.debug.print("{s}: actual   ", .{title});
        printHex(result.output_bytes);
        return ExampleError.UnexpectedBytes;
    }

    std.debug.print("{s}: {} bytes, {} passes, ", .{
        title,
        result.output_bytes.len,
        result.pass_count,
    });
    printHex(result.output_bytes);
}

fn printHex(bytes: []const u8) void {
    for (bytes, 0..) |byte, index| {
        if (index != 0) std.debug.print(" ", .{});
        std.debug.print("{X:0>2}", .{byte});
    }
    std.debug.print("\n", .{});
}

const data_source =
    \\db 0xAB, 'A', "Hi", "\n", 0
    \\dw 0x1234
    \\dd 0x12345678
    \\dq 0x0102030405060708
;

const reserve_source =
    \\db 0x11
    \\rb 2
    \\rw 1
    \\rd 1
    \\rq 1
    \\db 0x22
;

const labels_source =
    \\equ MAGIC = 0x42
    \\start:
    \\db MAGIC
    \\jmp target
    \\rb 3
    \\target:
    \\db target - start
    \\ret
;

const origin_source =
    \\.org 0x1000
    \\base:
    \\db 1
    \\.align 4
    \\.local local_here
    \\db local_here - base
;

const repeat_source =
    \\repeat 3, i:0
    \\db i, %, %%
    \\end repeat
;

const iterate_group_source =
    \\iterate <lo, hi:9>, 1, 2, 3
    \\db lo, hi
    \\end iterate
;

const iterate_wrapped_source =
    \\iterate pair, <1,2>, <3,4>, 5
    \\db pair
    \\end iterate
;

const iterate_case_source =
    \\iterate value?, 7, 9
    \\db VaLuE?, %, %%
    \\end iterate
;

const iterate_indx_source =
    \\iterate value, 1, 2, 3
    \\indx 1+%%-%
    \\db value
    \\end iterate
;

const flow_source =
    \\if 0
    \\db 0xEE
    \\elseif 1
    \\db 0xAA
    \\else
    \\db 0xBB
    \\endif
    \\while 1
    \\db 0xCC
    \\break
    \\end while
;
