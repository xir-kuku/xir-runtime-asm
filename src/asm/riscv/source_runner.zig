const std = @import("std");
const Assembler = @import("../assembler.zig").Assembler;
const AssembleError = @import("../assembler.zig").AssembleError;
const rv = @import("../../riscv_encoder/root.zig");
const shared = @import("../shared_source_runner.zig");
const Allocator = std.mem.Allocator;

pub fn run(allocator: Allocator, assembler: *Assembler, source: []const u8) AssembleError!void {
    var lines: std.ArrayList(shared.Line) = .empty;
    defer lines.deinit(allocator);
    try shared.splitLines(allocator, &lines, source);

    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        assembler.state.advanceLine();
        const stripped = shared.stripCommentAndWhitespace(line.text);
        if (stripped.len == 0) continue;

        try assembler.recordListing(stripped);
        const result = try dispatchLine(allocator, assembler, stripped);
        switch (result) {
            .completed => {},
            .break_loop => break,
        }
    }
}

fn dispatchLine(allocator: Allocator, assembler: *Assembler, line: []const u8) AssembleError!shared.DispatchResult {
    if (try shared.splitLabelDefinition(assembler, line)) |remainder| {
        if (remainder.len == 0) return .completed;
        return dispatchRemainder(allocator, assembler, remainder);
    }
    return dispatchRemainder(allocator, assembler, line);
}

fn dispatchRemainder(allocator: Allocator, assembler: *Assembler, line: []const u8) AssembleError!shared.DispatchResult {
    if (try shared.dispatchDataDirective(allocator, assembler, line)) return .completed;
    if (try shared.dispatchSymbolDirective(allocator, assembler, line)) return .completed;
    if (try shared.dispatchControlDirective(allocator, assembler, line)) return .completed;
    if (try dispatchRiscvInstruction(allocator, assembler, line)) return .completed;
    return error.InvalidInstruction;
}

fn dispatchRiscvInstruction(allocator: Allocator, assembler: *Assembler, line: []const u8) AssembleError!bool {
    const space_pos = std.mem.indexOfAny(u8, line, " \t") orelse return error.UnsupportedMnemonic;
    const mnemonic = line[0..space_pos];
    const args = std.mem.trim(u8, line[space_pos + 1 ..], " \t\r\n");

    const xlen: u8 = if (assembler.mode_bits & 16 != 0) 64 else 32;

    if (args.len == 0) {
        return encodeAndEmit(allocator, mnemonic, xlen, &[_][]const u8{}, assembler);
    }

    return encodeAndEmit(allocator, mnemonic, xlen, &[_][]const u8{args}, assembler);
}

fn encodeAndEmit(allocator: Allocator, mnemonic: []const u8, xlen: u8, arg_parts: []const []const u8, assembler: *Assembler) AssembleError!bool {
    var operands_buffer: [16]rv.Operand = undefined;
    var operand_count: usize = 0;

    for (arg_parts) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;

        var start: usize = 0;
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var in_char = false;

        for (trimmed, 0..) |ch, i| {
            switch (ch) {
                '(' => paren_depth += 1,
                ')' => paren_depth = paren_depth -| 1,
                '[' => bracket_depth += 1,
                ']' => bracket_depth = bracket_depth -| 1,
                '\'' => in_char = !in_char,
                ',' => {
                    if (paren_depth == 0 and bracket_depth == 0 and !in_char) {
                        if (i > start) {
                            const token = std.mem.trim(u8, trimmed[start..i], " \t\r\n");
                            if (token.len > 0) {
                                if (operand_count >= operands_buffer.len) return error.InvalidOperand;
                                operands_buffer[operand_count] = try parseOperand(allocator, token, assembler);
                                operand_count += 1;
                            }
                        }
                        start = i + 1;
                    }
                },
                else => {},
            }
        }
        if (start < trimmed.len) {
            const token = std.mem.trim(u8, trimmed[start..], " \t\r\n");
            if (token.len > 0) {
                if (operand_count >= operands_buffer.len) return error.InvalidOperand;
                operands_buffer[operand_count] = try parseOperand(allocator, token, assembler);
                operand_count += 1;
            }
        }
    }

    const operands = operands_buffer[0..operand_count];
    const result = rv.api.encodeMnemonic(mnemonic, xlen, operands) catch |err| switch (err) {
        error.UnsupportedInstruction, error.UnsupportedXLen => return error.UnsupportedMnemonic,
        error.UnsupportedInstructionWidth => return error.InvalidInstruction,
        error.MnemonicTooLong => return error.UnsupportedMnemonic,
        error.OperandCountMismatch, error.OperandKindMismatch => return error.InvalidOperand,
        error.ImmediateAlignment, error.ImmediateOutOfRange => return error.InvalidOperand,
        error.InvalidXLen => return error.InvalidArgument,
        error.RegisterOutOfRange => return error.InvalidOperand,
        else => |e| return e,
    };
    try assembler.emitBytes(result.asSlice());
    return true;
}

fn parseOperand(allocator: Allocator, token: []const u8, assembler: *Assembler) AssembleError!rv.Operand {
    if (rv.api.parseRegister(token)) |reg| {
        return rv.Operand{ .reg = reg };
    } else |_| {
        if (std.fmt.parseInt(i64, token, 0)) |imm| {
            return rv.Operand{ .imm = imm };
        } else |_| {}
        const value = try assembler.evaluateRelaxed(allocator, token);
        if (value > std.math.maxInt(i64)) return error.InvalidOperand;
        return rv.Operand{ .imm = @as(i64, @intCast(value)) };
    }
}
