const std = @import("std");
const Assembler = @import("assembler.zig").Assembler;
const AssembleError = @import("assembler.zig").AssembleError;
const Allocator = std.mem.Allocator;

pub const DispatchResult = enum { completed, break_loop };

pub const Line = struct {
    text: []const u8,
    number: usize,
};

pub fn splitLines(allocator: Allocator, lines: *std.ArrayList(Line), source: []const u8) Allocator.Error!void {
    var line_start: usize = 0;
    var line_number: usize = 1;
    for (source, 0..) |ch, i| {
        if (ch == '\n') {
            try lines.append(allocator, .{ .text = source[line_start..i], .number = line_number });
            line_start = i + 1;
            line_number += 1;
        }
    }
    if (line_start < source.len) {
        try lines.append(allocator, .{ .text = source[line_start..], .number = line_number });
    }
}

pub fn stripCommentAndWhitespace(line: []const u8) []const u8 {
    var in_string = false;
    var in_char = false;
    var comment_start: ?usize = null;
    for (line, 0..) |ch, i| {
        switch (ch) {
            '\'' => {
                if (!in_string and !in_char) in_char = !in_char;
            },
            '"' => {
                if (!in_string and !in_char) in_string = !in_string;
            },
            ';' => {
                if (!in_string and !in_char) {
                    comment_start = i;
                    break;
                }
            },
            '/' => {
                if (!in_string and !in_char and i + 1 < line.len and line[i + 1] == '/') {
                    comment_start = i;
                    break;
                }
            },
            else => {},
        }
    }
    const effective = if (comment_start) |cs| line[0..cs] else line;
    return std.mem.trim(u8, effective, " \t\r\n");
}

pub fn splitLabelDefinition(assembler: *Assembler, line: []const u8) AssembleError!?[]const u8 {
    var in_single = false;
    var in_double = false;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;

    for (line, 0..) |ch, i| {
        switch (ch) {
            '\'' => {
                if (!in_double) in_single = !in_single;
            },
            '"' => {
                if (!in_single) in_double = !in_double;
            },
            '(' => {
                if (!in_single and !in_double) paren_depth += 1;
            },
            ')' => {
                if (!in_single and !in_double) paren_depth = paren_depth -| 1;
            },
            '[' => {
                if (!in_single and !in_double) bracket_depth += 1;
            },
            ']' => {
                if (!in_single and !in_double) bracket_depth = bracket_depth -| 1;
            },
            ':' => {
                if (in_single or in_double or paren_depth > 0 or bracket_depth > 0) continue;
                const label = std.mem.trim(u8, line[0..i], " \t\r\n");
                if (label.len == 0) return null;
                if (label[0] == '.' and label.len > 1) return error.InvalidInstruction;
                const current_addr = try assembler.currentEffectiveAddress();
                assembler.symbols.defineLabel(label, current_addr, 0, line) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidInstruction => return error.InvalidInstruction,
                    error.InvalidArgument => return error.InvalidArgument,
                    error.CannotRedefineConstant => return error.InvalidInstruction,
                    error.SymbolAlreadyDefined => return error.InvalidInstruction,
                };
                const remainder = std.mem.trim(u8, line[i + 1 ..], " \t\r\n");
                return remainder;
            },
            else => {},
        }
    }
    return null;
}

pub fn dispatchControlDirective(allocator: Allocator, assembler: *Assembler, line: []const u8) AssembleError!bool {
    if (stripLeadingKeyword(line, ".org") orelse stripLeadingKeyword(line, "org")) |args| {
        const value = try assembler.evaluateRelaxed(allocator, std.mem.trim(u8, args, " \t\r\n"));
        try assembler.output.setOrigin(value);
        return true;
    }
    if (stripLeadingKeyword(line, ".align") orelse stripLeadingKeyword(line, "align")) |args| {
        const boundary = try assembler.evaluateRelaxed(allocator, std.mem.trim(u8, args, " \t\r\n"));
        if (boundary < 2 or (boundary & (boundary - 1)) != 0) return error.InvalidArgument;
        const addr = try assembler.output.currentAddress();
        const mask = boundary - 1;
        const padding = (boundary - (addr & mask)) & mask;
        if (padding > 0) try assembler.reserveBytes(padding);
        return true;
    }
    if (stripLeadingKeyword(line, ".local") orelse stripLeadingKeyword(line, "local")) |args| {
        const name = std.mem.trim(u8, args, " \t\r\n");
        if (name.len == 0) return error.InvalidInstruction;
        const addr = try assembler.output.currentAddress();
        assembler.symbols.defineLabel(name, addr, 0, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidInstruction => return error.InvalidInstruction,
            error.InvalidArgument => return error.InvalidArgument,
            error.CannotRedefineConstant => return error.InvalidInstruction,
            error.SymbolAlreadyDefined => return error.InvalidInstruction,
        };
        return true;
    }
    return false;
}

pub fn dispatchDataDirective(allocator: Allocator, assembler: *Assembler, line: []const u8) AssembleError!bool {
    if (stripLeadingKeyword(line, "db")) |args| {
        try emitDataValues(allocator, assembler, args, 1);
        return true;
    }
    if (stripLeadingKeyword(line, "dw")) |args| {
        try emitDataValues(allocator, assembler, args, 2);
        return true;
    }
    if (stripLeadingKeyword(line, "dd")) |args| {
        try emitDataValues(allocator, assembler, args, 4);
        return true;
    }
    if (stripLeadingKeyword(line, "dq")) |args| {
        try emitDataValues(allocator, assembler, args, 8);
        return true;
    }
    if (stripLeadingKeyword(line, "rb")) |args| {
        try emitReserve(allocator, assembler, args, 1);
        return true;
    }
    if (stripLeadingKeyword(line, "rw")) |args| {
        try emitReserve(allocator, assembler, args, 2);
        return true;
    }
    if (stripLeadingKeyword(line, "rd")) |args| {
        try emitReserve(allocator, assembler, args, 4);
        return true;
    }
    if (stripLeadingKeyword(line, "rq")) |args| {
        try emitReserve(allocator, assembler, args, 8);
        return true;
    }
    return false;
}

pub fn stripLeadingKeyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    if (line.len < keyword.len) return null;
    if (!std.ascii.eqlIgnoreCase(line[0..keyword.len], keyword)) return null;
    if (line.len > keyword.len) {
        const next = line[keyword.len];
        if (next != ' ' and next != '\t') return null;
    }
    return std.mem.trim(u8, line[keyword.len..], " \t\r\n");
}

fn emitStringContent(assembler_ptr: *Assembler, content: []const u8) AssembleError!void {
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            const b = switch (content[i + 1]) {
                'n' => @as(u8, 0x0A),
                'r' => 0x0D,
                't' => 0x09,
                '\\' => 0x5C,
                '\'' => 0x27,
                '"' => 0x22,
                '0' => 0x00,
                'x' => {
                    if (i + 3 >= content.len) return error.InvalidCharacter;
                    const byte = std.fmt.parseInt(u8, content[i + 2 .. i + 4], 16) catch return error.InvalidCharacter;
                    i += 4;
                    try assembler_ptr.emitBytes(&[_]u8{byte});
                    continue;
                },
                else => return error.InvalidCharacter,
            };
            i += 2;
            try assembler_ptr.emitBytes(&[_]u8{b});
        } else {
            try assembler_ptr.emitBytes(&[_]u8{content[i]});
            i += 1;
        }
    }
}

pub fn emitDataValues(allocator: Allocator, assembler: *Assembler, args: []const u8, width: usize) AssembleError!void {
    var start: usize = 0;
    var in_single = false;
    var in_double = false;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;

    const process = struct {
        fn emit(assembler_ptr: *Assembler, alloc: Allocator, text: []const u8, w: usize) AssembleError!void {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len == 0) return;
            if (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') {
                try emitStringContent(assembler_ptr, trimmed[1 .. trimmed.len - 1]);
                return;
            }
            if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
                try emitStringContent(assembler_ptr, trimmed[1 .. trimmed.len - 1]);
                return;
            }
            const value = try assembler_ptr.evaluateRelaxed(alloc, trimmed);
            try assembler_ptr.output.emitValueLe(value, w);
        }
    }.emit;

    for (args, 0..) |ch, i| {
        switch (ch) {
            '\'' => {
                if (!in_double) in_single = !in_single;
            },
            '"' => {
                if (!in_single) in_double = !in_double;
            },
            '(' => {
                if (!in_single and !in_double) paren_depth += 1;
            },
            ')' => {
                if (!in_single and !in_double) paren_depth = paren_depth -| 1;
            },
            '[' => {
                if (!in_single and !in_double) bracket_depth += 1;
            },
            ']' => {
                if (!in_single and !in_double) bracket_depth = bracket_depth -| 1;
            },
            ',' => {
                if (in_single or in_double or paren_depth > 0 or bracket_depth > 0) continue;
                try process(assembler, allocator, args[start..i], width);
                start = i + 1;
            },
            else => {},
        }
    }
    if (start <= args.len) {
        try process(assembler, allocator, args[start..], width);
    }
}

pub fn emitReserve(allocator: Allocator, assembler: *Assembler, args: []const u8, width: usize) AssembleError!void {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidInstruction;
    const count = try assembler.evaluateRelaxed(allocator, trimmed);
    const total = std.math.mul(usize, count, width) catch return error.OutputOverflow;
    try assembler.reserveBytes(total);
}

pub fn dispatchSymbolDirective(allocator: Allocator, assembler: *Assembler, line: []const u8) AssembleError!bool {
    if (stripLeadingKeyword(line, "equ")) |args| {
        const eq_pos = std.mem.indexOfScalar(u8, args, '=') orelse return error.InvalidInstruction;
        const name = std.mem.trim(u8, args[0..eq_pos], " \t\r\n");
        const value_text = std.mem.trim(u8, args[eq_pos + 1 ..], " \t\r\n");
        if (name.len == 0) return error.InvalidInstruction;
        const value = try assembler.evaluateRelaxed(allocator, value_text);
        try assembler.symbols.defineValue(name, .constant, value, 0, null);
        return true;
    }
    return false;
}

// ─── Control directive expander ───

pub const MaxIterations: usize = 1_000_000;

const BlockKind = enum { repeat, iterate, while_, if_ };

const ExpansionResult = enum { completed, break_loop };

const RepeatParam = struct {
    name: []const u8,
    base_expr: ?[]const u8,
    case_insensitive: bool = false,
    required: bool = false,
};

const IterateParam = struct {
    name: []const u8,
    default_text: ?[]const u8 = null,
    case_insensitive: bool = false,
    required: bool = false,
};

const IterateHeader = struct {
    params: []IterateParam,
    items: [][]const u8,

    fn deinit(self: IterateHeader, allocator: Allocator) void {
        for (self.params) |param| {
            allocator.free(param.name);
            if (param.default_text) |text| allocator.free(text);
        }
        allocator.free(self.params);
        for (self.items) |item| allocator.free(item);
        allocator.free(self.items);
    }
};

const IterateRuntime = struct {
    header: *const IterateHeader,
    group_count: usize,
    group_index: usize,
};

fn parseBlockOpenerKind(line: []const u8) ?BlockKind {
    if (stripLeadingKeyword(line, "repeat") != null) return .repeat;
    if (stripLeadingKeyword(line, "rept") != null) return .repeat;
    if (stripLeadingKeyword(line, "iterate") != null) return .iterate;
    if (stripLeadingKeyword(line, "irp") != null) return .iterate;
    if (stripLeadingKeyword(line, "while") != null) return .while_;
    if (stripLeadingKeyword(line, "if") != null) return .if_;
    return null;
}

fn parseBlockCloserKind(line: []const u8) ?BlockKind {
    if (matchesAnyKeyword(line, &.{ "end repeat", "endrepeat", "end rept", "endrept" })) return .repeat;
    if (matchesAnyKeyword(line, &.{ "end iterate", "enditerate", "end irp", "endirp" })) return .iterate;
    if (matchesAnyKeyword(line, &.{ "end while", "endwhile" })) return .while_;
    if (matchesAnyKeyword(line, &.{ "end if", "endif" })) return .if_;
    return null;
}

fn matchesAnyKeyword(line: []const u8, keywords: []const []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    for (keywords) |kw| {
        if (std.ascii.eqlIgnoreCase(trimmed, kw)) return true;
    }
    return false;
}

fn isElseBranch(line: []const u8) bool {
    if (stripLeadingKeyword(line, "else")) |_| return true;
    if (stripLeadingKeyword(line, "elseif")) |_| return true;
    if (stripLeadingKeyword(line, "else if")) |_| return true;
    return false;
}

/// Collect body lines until a matching closer.
/// `start` points to the first body line (after the opener).
/// Returns the body as a slice of source text, and advances `*end` past the closer.
fn collectBlockBody(
    allocator: Allocator,
    source: []const u8,
    start: usize,
    opener_kind: BlockKind,
    end: *usize,
) AssembleError!struct { body: []const u8, closer_pos: usize } {
    var depth: usize = 0;
    var pos = start;
    const body_start = start;
    var closer_pos: usize = 0;
    var found_closer = false;
    var nested_kinds: std.ArrayList(BlockKind) = .empty;
    defer nested_kinds.deinit(allocator);

    while (pos < source.len) {
        const nl = std.mem.indexOfScalarPos(u8, source, pos, '\n') orelse source.len;
        const line = stripCommentAndWhitespace(source[pos..nl]);

        if (line.len > 0) {
            if (parseBlockOpenerKind(line)) |nested_kind| {
                try nested_kinds.append(allocator, nested_kind);
                depth += 1;
            } else if (parseBlockCloserKind(line)) |closer_kind| {
                if (depth == 0) {
                    if (closer_kind != opener_kind) return error.InvalidInstruction;
                    closer_pos = pos;
                    found_closer = true;
                    break;
                }
                const nested_kind = nested_kinds.pop() orelse return error.InvalidInstruction;
                if (nested_kind != closer_kind) return error.InvalidInstruction;
                depth -= 1;
            }
        }
        pos = nl + 1;
    }

    if (!found_closer) return error.InvalidInstruction;

    end.* = closer_pos;
    return .{
        .body = source[body_start..closer_pos],
        .closer_pos = closer_pos,
    };
}

fn skipLine(source: []const u8, pos: *usize) void {
    const nl = std.mem.indexOfScalarPos(u8, source, pos.*, '\n') orelse source.len;
    pos.* = nl + 1;
}

fn skipPastCloser(source: []const u8, closer_pos: usize, pos: *usize) void {
    pos.* = closer_pos;
    skipLine(source, pos);
}

/// Expand control directives (repeat, iterate, while, if) into flat source text.
pub fn expandControls(allocator: Allocator, assembler: *Assembler, source: []const u8) AssembleError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    const result = try expandControlsInto(allocator, assembler, source, &out);
    if (result == .break_loop) return error.InvalidInstruction;
    return out.toOwnedSlice(allocator);
}

fn expandControlsInto(allocator: Allocator, assembler: *Assembler, source: []const u8, out: *std.ArrayList(u8)) AssembleError!ExpansionResult {
    return expandControlsIntoIterate(allocator, assembler, source, out, null);
}

fn expandControlsIntoIterate(
    allocator: Allocator,
    assembler: *Assembler,
    source: []const u8,
    out: *std.ArrayList(u8),
    active_iterate: ?*IterateRuntime,
) AssembleError!ExpansionResult {
    var pos: usize = 0;
    while (pos < source.len) {
        const nl = std.mem.indexOfScalarPos(u8, source, pos, '\n') orelse source.len;
        const raw = source[pos..nl];
        const stripped = stripCommentAndWhitespace(raw);
        var active_line_storage: ?[]u8 = null;
        defer if (active_line_storage) |owned| allocator.free(owned);
        const line = if (stripped.len != 0) blk: {
            if (active_iterate) |runtime| {
                const expanded = try expandIterateLine(allocator, runtime, stripped);
                active_line_storage = expanded;
                break :blk expanded;
            }
            break :blk stripped;
        } else stripped;
        const is_comment_or_blank = line.len == 0;

        if (!is_comment_or_blank) {
            if (active_iterate) |runtime| {
                if (stripLeadingKeyword(line, "indx")) |expr| {
                    const trimmed = std.mem.trim(u8, expr, " \t\r\n");
                    if (trimmed.len == 0) return error.InvalidArgument;
                    const target_index = try assembler.evaluateRelaxed(allocator, trimmed);
                    if (target_index == 0 or target_index > runtime.group_count) return error.InvalidArgument;
                    runtime.group_index = target_index - 1;
                    pos = nl + 1;
                    continue;
                }
            }

            const Opener = struct { tag: ?BlockKind, args: []const u8 };
            const opener: Opener = blk: {
                if (stripLeadingKeyword(line, "repeat")) |a| break :blk .{ .tag = .repeat, .args = a };
                if (stripLeadingKeyword(line, "rept")) |a| break :blk .{ .tag = .repeat, .args = a };
                if (stripLeadingKeyword(line, "iterate")) |a| break :blk .{ .tag = .iterate, .args = a };
                if (stripLeadingKeyword(line, "irp")) |a| break :blk .{ .tag = .iterate, .args = a };
                if (stripLeadingKeyword(line, "while")) |a| break :blk .{ .tag = .while_, .args = a };
                if (stripLeadingKeyword(line, "if")) |a| break :blk .{ .tag = .if_, .args = a };
                break :blk Opener{ .tag = null, .args = "" };
            };

            if (opener.tag) |tag| switch (tag) {
                .repeat => {
                    var repeat_header = try parseRepeatHeader(allocator, opener.args);
                    defer repeat_header.deinit(allocator);

                    const count = try assembler.evaluateRelaxed(allocator, repeat_header.count_expr);
                    if (count > MaxIterations) return error.ExpansionDepthExceeded;

                    var end: usize = undefined;
                    const block = try collectBlockBody(allocator, source, nl + 1, .repeat, &end);
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        var expanded_source: std.ArrayList(u8) = .empty;
                        defer expanded_source.deinit(allocator);
                        try expandRepeatBodyText(allocator, assembler, &expanded_source, block.body, i, count, repeat_header.params);

                        switch (try expandControlsIntoIterate(allocator, assembler, expanded_source.items, out, active_iterate)) {
                            .completed => {},
                            .break_loop => {
                                break;
                            },
                        }
                    }
                    skipPastCloser(source, end, &pos);
                    continue;
                },

                .iterate => {
                    var end: usize = undefined;
                    const block = try collectBlockBody(allocator, source, nl + 1, .iterate, &end);
                    switch (try expandIterate(allocator, assembler, out, opener.args, block.body)) {
                        .completed => {},
                        .break_loop => {
                            skipPastCloser(source, end, &pos);
                            continue;
                        },
                    }
                    skipPastCloser(source, end, &pos);
                    continue;
                },

                .while_ => {
                    const cond_text = std.mem.trim(u8, opener.args, " \t\r\n");
                    if (cond_text.len == 0) return error.InvalidInstruction;
                    var end: usize = undefined;
                    const block = try collectBlockBody(allocator, source, nl + 1, .while_, &end);
                    var iterations: usize = 0;
                    while ((try assembler.evaluateRelaxed(allocator, cond_text)) != 0) {
                        iterations += 1;
                        if (iterations > MaxIterations) return error.ExpansionDepthExceeded;
                        switch (try expandControlsIntoIterate(allocator, assembler, block.body, out, active_iterate)) {
                            .completed => {},
                            .break_loop => break,
                        }
                    }
                    skipPastCloser(source, end, &pos);
                    continue;
                },

                .if_ => {
                    var end: usize = undefined;
                    switch (try expandIf(allocator, assembler, out, source, nl + 1, opener.args, &end)) {
                        .completed => {},
                        .break_loop => return .break_loop,
                    }
                    skipPastCloser(source, end, &pos);
                    continue;
                },
            };

            if (matchesAnyKeyword(line, &.{"break"})) {
                return .break_loop;
            }
            if (parseBlockCloserKind(line) != null) {
                return error.InvalidInstruction;
            }
        }

        if (active_line_storage) |owned| {
            try out.appendSlice(allocator, owned);
        } else {
            try out.appendSlice(allocator, source[pos..nl]);
        }
        try out.append(allocator, '\n');
        pos = nl + 1;
    }

    return .completed;
}

const RepeatHeader = struct {
    count_expr: []const u8,
    params: []RepeatParam,

    fn deinit(self: RepeatHeader, allocator: Allocator) void {
        allocator.free(self.count_expr);
        allocator.free(self.params);
    }
};

fn parseRepeatHeader(allocator: Allocator, args_text: []const u8) AssembleError!RepeatHeader {
    var args = try splitTopLevelCommaArguments(allocator, args_text);
    defer args.deinit(allocator);
    if (args.items.len == 0) return error.InvalidArgument;

    const count_expr = try allocator.dupe(u8, args.items[0]);
    errdefer allocator.free(count_expr);

    const params = try allocator.alloc(RepeatParam, args.items.len - 1);
    errdefer allocator.free(params);
    for (args.items[1..], 0..) |spec, index| {
        params[index] = try parseRepeatParamSpec(spec);
    }

    return .{
        .count_expr = count_expr,
        .params = params,
    };
}

fn parseRepeatParamSpec(spec: []const u8) AssembleError!RepeatParam {
    var raw = std.mem.trim(u8, spec, " \t\r\n");
    var base_expr: ?[]const u8 = null;

    if (std.mem.indexOfScalar(u8, raw, ':')) |index| {
        const name_only = std.mem.trim(u8, raw[0..index], " \t\r\n");
        const default_only = std.mem.trim(u8, raw[index + 1 ..], " \t\r\n");
        if (default_only.len != 0) base_expr = default_only;
        raw = name_only;
    }

    while (raw.len != 0) {
        const tail = raw[raw.len - 1];
        switch (tail) {
            '&', '*', '?' => raw = std.mem.trimEnd(u8, raw[0 .. raw.len - 1], " \t\r\n"),
            else => break,
        }
    }
    if (!isValidControlName(raw)) return error.InvalidInstruction;
    return .{ .name = raw, .base_expr = base_expr };
}

fn parseIterateHeader(allocator: Allocator, args_text: []const u8) AssembleError!IterateHeader {
    const trimmed = std.mem.trim(u8, args_text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidArgument;

    const first_comma = findTopLevelComma(trimmed) orelse return error.InvalidArgument;
    const params_text = std.mem.trim(u8, trimmed[0..first_comma], " \t\r\n");
    const items_text = std.mem.trim(u8, trimmed[first_comma + 1 ..], " \t\r\n");
    if (params_text.len == 0) return error.InvalidArgument;

    const params = try parseIterateParams(allocator, params_text);
    errdefer {
        for (params) |param| {
            allocator.free(param.name);
            if (param.default_text) |text| allocator.free(text);
        }
        allocator.free(params);
    }

    var item_args = try splitTopLevelCommaArguments(allocator, items_text);
    defer item_args.deinit(allocator);

    const items = try cloneNormalizedIterateItems(allocator, item_args.items);
    errdefer {
        for (items) |item| allocator.free(item);
        allocator.free(items);
    }

    return .{ .params = params, .items = items };
}

fn parseIterateParams(allocator: Allocator, params_text: []const u8) AssembleError![]IterateParam {
    const trimmed = std.mem.trim(u8, params_text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidArgument;
    const inner = if (trimmed[0] == '<') blk: {
        if (trimmed.len < 2 or trimmed[trimmed.len - 1] != '>') return error.InvalidArgument;
        break :blk trimmed[1 .. trimmed.len - 1];
    } else trimmed;

    var param_args = try splitTopLevelCommaArguments(allocator, inner);
    defer param_args.deinit(allocator);
    if (param_args.items.len == 0) return error.InvalidArgument;

    const params = try allocator.alloc(IterateParam, param_args.items.len);
    errdefer allocator.free(params);
    var initialized: usize = 0;
    errdefer {
        for (params[0..initialized]) |param| {
            allocator.free(param.name);
            if (param.default_text) |text| allocator.free(text);
        }
    }

    for (param_args.items, 0..) |spec, index| {
        params[index] = try parseIterateParamSpec(allocator, spec);
        initialized += 1;
    }
    return params;
}

fn parseIterateParamSpec(allocator: Allocator, spec: []const u8) AssembleError!IterateParam {
    var raw = std.mem.trim(u8, spec, " \t\r\n");
    var default_text: ?[]const u8 = null;

    if (std.mem.indexOfScalar(u8, raw, ':')) |index| {
        const name_only = std.mem.trim(u8, raw[0..index], " \t\r\n");
        const default_only = std.mem.trim(u8, raw[index + 1 ..], " \t\r\n");
        if (default_only.len != 0) default_text = try allocator.dupe(u8, default_only);
        raw = name_only;
    }
    errdefer if (default_text) |text| allocator.free(text);

    var required = false;
    var case_insensitive = false;
    while (raw.len != 0) {
        const tail = raw[raw.len - 1];
        switch (tail) {
            '&' => return error.InvalidInstruction,
            '*' => {
                required = true;
                raw = std.mem.trimEnd(u8, raw[0 .. raw.len - 1], " \t\r\n");
            },
            '?' => {
                case_insensitive = true;
                raw = std.mem.trimEnd(u8, raw[0 .. raw.len - 1], " \t\r\n");
            },
            else => break,
        }
    }
    if (!isValidControlName(raw)) return error.InvalidInstruction;
    return .{
        .name = try allocator.dupe(u8, raw),
        .default_text = default_text,
        .case_insensitive = case_insensitive,
        .required = required,
    };
}

fn cloneNormalizedIterateItems(allocator: Allocator, items: []const []const u8) AssembleError![][]const u8 {
    const owned = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(owned);

    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |item| allocator.free(item);
    }

    for (items, 0..) |item, index| {
        const normalized = if (item.len >= 2 and item[0] == '<' and item[item.len - 1] == '>')
            item[1 .. item.len - 1]
        else
            item;
        owned[index] = try allocator.dupe(u8, normalized);
        initialized += 1;
    }
    return owned;
}

fn expandRepeatBodyText(
    allocator: Allocator,
    assembler: *Assembler,
    out: *std.ArrayList(u8),
    body: []const u8,
    iteration: usize,
    count: usize,
    params: []const RepeatParam,
) AssembleError!void {
    const index1, const index_overflow = @addWithOverflow(iteration, 1);
    if (index_overflow != 0) return error.OutputOverflow;
    const index_text = try std.fmt.allocPrint(allocator, "{}", .{index1});
    defer allocator.free(index_text);
    const count_text = try std.fmt.allocPrint(allocator, "{}", .{count});
    defer allocator.free(count_text);

    var body_pos: usize = 0;
    while (body_pos < body.len) {
        const body_nl = std.mem.indexOfScalarPos(u8, body, body_pos, '\n') orelse body.len;
        var body_line = body[body_pos..body_nl];
        if (body_line.len > 0 and body_line[body_line.len - 1] == '\r') body_line = body_line[0 .. body_line.len - 1];

        var line = try replaceControlToken(allocator, body_line, "%%", count_text);
        defer allocator.free(line);

        var replaced = try replaceControlToken(allocator, line, "%", index_text);
        allocator.free(line);
        line = replaced;
        for (params) |param| {
            const base = if (param.base_expr) |expr| try assembler.evaluateRelaxed(allocator, expr) else 1;
            const value, const overflow = @addWithOverflow(base, iteration);
            if (overflow != 0) return error.OutputOverflow;
            const value_text = try std.fmt.allocPrint(allocator, "{}", .{value});
            defer allocator.free(value_text);
            replaced = try replaceControlToken(allocator, line, param.name, value_text);
            allocator.free(line);
            line = replaced;
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
        body_pos = body_nl + 1;
    }
}

fn replaceControlToken(allocator: Allocator, input: []const u8, name: []const u8, value: []const u8) Allocator.Error![]u8 {
    return replaceControlTokenCase(allocator, input, name, value, false);
}

fn replaceControlTokenCase(
    allocator: Allocator,
    input: []const u8,
    name: []const u8,
    value: []const u8,
    case_insensitive: bool,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var pos: usize = 0;
    var in_single = false;
    var in_double = false;
    while (pos < input.len) {
        const ch = input[pos];
        if (ch == '\'' and !in_double) {
            in_single = !in_single;
            try out.append(allocator, ch);
            pos += 1;
            continue;
        }
        if (ch == '"' and !in_single) {
            in_double = !in_double;
            try out.append(allocator, ch);
            pos += 1;
            continue;
        }
        if (!in_single and !in_double and tokenMatchesAt(input, pos, name, case_insensitive)) {
            try out.appendSlice(allocator, value);
            if (case_insensitive and pos + name.len < input.len and input[pos + name.len] == '?') {
                pos += name.len + 1;
            } else {
                pos += name.len;
            }
            continue;
        }
        try out.append(allocator, ch);
        pos += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn tokenMatchesAt(input: []const u8, pos: usize, name: []const u8, case_insensitive: bool) bool {
    if (name.len == 0 or pos + name.len > input.len) return false;
    var token_len = name.len;
    if (case_insensitive and pos + token_len < input.len and input[pos + token_len] == '?') {
        token_len += 1;
    }
    const candidate = input[pos .. pos + token_len];
    const lookup_candidate = if (case_insensitive and std.mem.endsWith(u8, candidate, "?"))
        candidate[0 .. candidate.len - 1]
    else
        candidate;
    if (case_insensitive) {
        if (!std.ascii.eqlIgnoreCase(lookup_candidate, name)) return false;
    } else if (!std.mem.eql(u8, lookup_candidate, name)) return false;
    const before = if (pos == 0) null else input[pos - 1];
    const after = if (pos + token_len >= input.len) null else input[pos + token_len];
    if (before) |ch| {
        if (isControlNameChar(ch)) return false;
    }
    if (after) |ch| {
        if (isControlNameChar(ch)) return false;
    }
    return true;
}

fn findTopLevelComma(text: []const u8) ?usize {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var angle_depth: usize = 0;
    var in_single = false;
    var in_double = false;

    for (text, 0..) |ch, index| {
        switch (ch) {
            '\'' => {
                if (!in_double) in_single = !in_single;
            },
            '"' => {
                if (!in_single) in_double = !in_double;
            },
            '(' => {
                if (!in_single and !in_double) paren_depth += 1;
            },
            ')' => {
                if (!in_single and !in_double) paren_depth = paren_depth -| 1;
            },
            '[' => {
                if (!in_single and !in_double) bracket_depth += 1;
            },
            ']' => {
                if (!in_single and !in_double) bracket_depth = bracket_depth -| 1;
            },
            '<' => {
                if (!in_single and !in_double) angle_depth += 1;
            },
            '>' => {
                if (!in_single and !in_double) angle_depth = angle_depth -| 1;
            },
            ',' => {
                if (!in_single and !in_double and paren_depth == 0 and bracket_depth == 0 and angle_depth == 0) {
                    return index;
                }
            },
            else => {},
        }
    }
    return null;
}

fn isValidControlName(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_' or first == '.' or first == '%' or first == '$' or first == '@' or first == '?')) {
        return false;
    }
    for (name[1..]) |ch| {
        if (!isControlNameChar(ch)) return false;
    }
    return true;
}

fn isControlNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == ':' or
        ch == '%' or ch == '$' or ch == '@' or ch == '?' or ch == '\'';
}

fn splitTopLevelCommaArguments(allocator: Allocator, text: []const u8) Allocator.Error!std.ArrayList([]const u8) {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);

    var start: usize = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var angle_depth: usize = 0;
    var in_single = false;
    var in_double = false;

    for (text, 0..) |ch, index| {
        switch (ch) {
            '\'' => {
                if (!in_double) in_single = !in_single;
            },
            '"' => {
                if (!in_single) in_double = !in_double;
            },
            '(' => {
                if (!in_single and !in_double) paren_depth += 1;
            },
            ')' => {
                if (!in_single and !in_double) paren_depth = paren_depth -| 1;
            },
            '[' => {
                if (!in_single and !in_double) bracket_depth += 1;
            },
            ']' => {
                if (!in_single and !in_double) bracket_depth = bracket_depth -| 1;
            },
            '<' => {
                if (!in_single and !in_double) angle_depth += 1;
            },
            '>' => {
                if (!in_single and !in_double) angle_depth = angle_depth -| 1;
            },
            ',' => {
                if (in_single or in_double or paren_depth != 0 or bracket_depth != 0 or angle_depth != 0) continue;
                const arg = std.mem.trim(u8, text[start..index], " \t\r\n");
                if (arg.len != 0) try args.append(allocator, arg);
                start = index + 1;
            },
            else => {},
        }
    }
    const arg = std.mem.trim(u8, text[start..], " \t\r\n");
    if (arg.len != 0) try args.append(allocator, arg);
    return args;
}

fn expandIterate(allocator: Allocator, assembler: *Assembler, out: *std.ArrayList(u8), args_text: []const u8, body: []const u8) AssembleError!ExpansionResult {
    var header = try parseIterateHeader(allocator, args_text);
    defer header.deinit(allocator);
    if (header.items.len == 0) return .completed;

    const group_count = @divFloor(header.items.len - 1, header.params.len) + 1;
    var gi: usize = 0;
    while (gi < group_count) : (gi += 1) {
        var runtime = IterateRuntime{ .header = &header, .group_count = group_count, .group_index = gi };
        switch (try expandIterateGroup(allocator, assembler, out, body, &runtime)) {
            .completed => {},
            .break_loop => return .completed,
        }
    }
    return .completed;
}

fn expandIterateGroup(
    allocator: Allocator,
    assembler: *Assembler,
    out: *std.ArrayList(u8),
    body: []const u8,
    runtime: *IterateRuntime,
) AssembleError!ExpansionResult {
    return expandControlsIntoIterate(allocator, assembler, body, out, runtime);
}

fn expandIterateLine(allocator: Allocator, runtime: *const IterateRuntime, line: []const u8) AssembleError![]u8 {
    const index1, const index_overflow = @addWithOverflow(runtime.group_index, 1);
    if (index_overflow != 0) return error.OutputOverflow;
    const index_text = try std.fmt.allocPrint(allocator, "{}", .{index1});
    defer allocator.free(index_text);
    const count_text = try std.fmt.allocPrint(allocator, "{}", .{runtime.group_count});
    defer allocator.free(count_text);

    var replaced = try replaceControlToken(allocator, line, "%%", count_text);
    errdefer allocator.free(replaced);

    var next = try replaceControlToken(allocator, replaced, "%", index_text);
    allocator.free(replaced);
    replaced = next;

    const base_index, const base_overflow = @mulWithOverflow(runtime.group_index, runtime.header.params.len);
    if (base_overflow != 0) return error.OutputOverflow;
    for (runtime.header.params, 0..) |param, param_index| {
        const item_index, const item_overflow = @addWithOverflow(base_index, param_index);
        if (item_overflow != 0) return error.OutputOverflow;
        const value = if (item_index < runtime.header.items.len)
            runtime.header.items[item_index]
        else if (param.default_text) |text|
            text
        else
            "";
        if (param.required and value.len == 0) return error.InvalidArgument;

        next = try replaceControlTokenCase(allocator, replaced, param.name, value, param.case_insensitive);
        allocator.free(replaced);
        replaced = next;
    }

    return replaced;
}

fn expandIf(allocator: Allocator, assembler: *Assembler, out: *std.ArrayList(u8), source: []const u8, search_start: usize, args_text: []const u8, end: *usize) AssembleError!ExpansionResult {
    var arms: std.ArrayList(struct { cond: []const u8, body: []const u8 }) = .empty;
    defer {
        for (arms.items) |a| allocator.free(a.cond);
        arms.deinit(allocator);
    }

    var depth: usize = 0;
    var search_pos = search_start;
    var current_cond: ?[]const u8 = null;
    var current_body_start: usize = search_start;
    var saw_else = false;
    var found_end = false;
    var nested_kinds: std.ArrayList(BlockKind) = .empty;
    defer nested_kinds.deinit(allocator);

    const if_cond = std.mem.trim(u8, args_text, " \t\r\n");
    if (if_cond.len == 0) return error.InvalidInstruction;
    current_cond = try allocator.dupe(u8, if_cond);
    current_body_start = search_start;

    while (search_pos < source.len) {
        const arm_nl = std.mem.indexOfScalarPos(u8, source, search_pos, '\n') orelse source.len;
        const arm_raw = source[search_pos..arm_nl];
        const arm_clean = stripCommentAndWhitespace(arm_raw);
        const arm_is_comment = arm_clean.len == 0;

        if (!arm_is_comment) {
            if (parseBlockOpenerKind(arm_clean)) |nested_kind| {
                try nested_kinds.append(allocator, nested_kind);
                depth += 1;
            } else if (depth > 0) {
                if (parseBlockCloserKind(arm_clean)) |closer_kind| {
                    const nested_kind = nested_kinds.pop() orelse return error.InvalidInstruction;
                    if (nested_kind != closer_kind) return error.InvalidInstruction;
                    depth -= 1;
                }
            } else if (depth == 0) {
                if (parseBlockCloserKind(arm_clean)) |closer_kind| {
                    if (closer_kind != .if_) return error.InvalidInstruction;
                    if (current_cond) |cond| {
                        const body_text = source[current_body_start..search_pos];
                        try arms.append(allocator, .{ .cond = cond, .body = body_text });
                        current_cond = null;
                    } else if (saw_else) {
                        const body_text = source[current_body_start..search_pos];
                        try arms.append(allocator, .{ .cond = "", .body = body_text });
                    }
                    end.* = arm_nl;
                    found_end = true;
                    break;
                }
                if (isElseBranch(arm_clean)) {
                    if (current_cond) |cond| {
                        const body_text = source[current_body_start..search_pos];
                        try arms.append(allocator, .{ .cond = cond, .body = body_text });
                        current_cond = null;
                    }
                    if (stripLeadingKeyword(arm_clean, "else")) |after_else| {
                        if (stripLeadingKeyword(after_else, "if")) |elif_cond_text| {
                            if (saw_else) return error.InvalidInstruction;
                            const elif_cond = std.mem.trim(u8, elif_cond_text, " \t\r\n");
                            if (elif_cond.len == 0) return error.InvalidInstruction;
                            current_cond = try allocator.dupe(u8, elif_cond);
                        } else {
                            if (saw_else) return error.InvalidInstruction;
                            saw_else = true;
                            current_cond = try allocator.dupe(u8, "1");
                        }
                    } else if (stripLeadingKeyword(arm_clean, "elseif")) |elif_cond_text| {
                        if (saw_else) return error.InvalidInstruction;
                        const elif_cond = std.mem.trim(u8, elif_cond_text, " \t\r\n");
                        if (elif_cond.len == 0) return error.InvalidInstruction;
                        current_cond = try allocator.dupe(u8, elif_cond);
                    }
                    current_body_start = arm_nl + 1;
                    search_pos = arm_nl + 1;
                    continue;
                }
            }
        }
        search_pos = arm_nl + 1;
    }

    if (!found_end) return error.InvalidInstruction;

    var selected: ?[]const u8 = null;
    for (arms.items) |arm| {
        if (arm.cond.len == 0) {
            selected = arm.body;
            break;
        }
        const val = try assembler.evaluateRelaxed(allocator, arm.cond);
        if (val != 0) {
            selected = arm.body;
            break;
        }
    }

    if (selected) |body| {
        if (body.len > 0) {
            return expandControlsInto(allocator, assembler, body, out);
        }
    }
    return .completed;
}
