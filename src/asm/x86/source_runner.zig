const std = @import("std");
const Assembler = @import("../assembler.zig").Assembler;
const AssembleError = @import("../assembler.zig").AssembleError;
const x86_dispatch = @import("dispatch.zig");
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
    if (try x86_dispatch.tryDispatch(allocator, assembler, line)) return .completed;
    return error.InvalidInstruction;
}
