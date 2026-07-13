const std = @import("std");
const x86_encoder = @import("../../x86_encoder/root.zig");
const Assembler = @import("../assembler.zig").Assembler;
const AssembleError = @import("../assembler.zig").AssembleError;

const Allocator = std.mem.Allocator;

const max_operands: usize = 5;

const PrefixOptions = struct {
    has_lock: bool = false,

    fn applyTo(self: PrefixOptions, context: x86_encoder.EncodeContext) x86_encoder.EncodeContext {
        var ctx = context;
        if (self.has_lock) ctx = ctx.withLock(true);
        return ctx;
    }
};

const ParsedInstruction = struct {
    mnemonic: []const u8 = "",
    owned_mnemonic: ?[]u8 = null,
    operands: []const []const u8 = &.{},
    operand_storage: [max_operands][]const u8 = @splat(""),
    operand_count: usize = 0,
    prefixes: PrefixOptions = .{},

    fn deinit(self: *ParsedInstruction, allocator: Allocator) void {
        if (self.owned_mnemonic) |m| allocator.free(m);
        self.* = undefined;
    }
};

fn leadingToken(src: []const u8) []const u8 {
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == ',' or c == ';') break;
    }
    return src[0..i];
}

fn tryApplySourcePrefix(token: []const u8, prefixes: *PrefixOptions) bool {
    if (std.ascii.eqlIgnoreCase(token, "lock")) {
        prefixes.has_lock = true;
        return true;
    }
    return false;
}

fn stripCombinedPrefixes(raw: []const u8) []const u8 {
    return raw;
}

fn stripX86MnemonicDecorators(raw: []const u8) []const u8 {
    return raw;
}

fn resolveModeBits(assembler: *const Assembler) u8 {
    return assembler.mode_bits;
}

fn resolveDefaultRel() bool {
    return true;
}

fn currentOutputPosition(assembler: *const Assembler) AssembleError!i64 {
    const addr = try assembler.currentEffectiveAddress();
    if (addr > std.math.maxInt(i64)) return error.OutputOverflow;
    return @as(i64, @intCast(addr));
}

fn operandsMayNeedDefaultRel(operands: []const []const u8) bool {
    for (operands) |op| {
        if (op.len == 0) continue;
        if (op[0] == '[') return true;
    }
    return false;
}

fn mayUseBranchRelaxation(mnemonic: []const u8) bool {
    return std.ascii.eqlIgnoreCase(mnemonic, "jmp") or
        std.ascii.eqlIgnoreCase(mnemonic, "call") or
        (mnemonic.len > 1 and (mnemonic[0] == 'j' or mnemonic[0] == 'J'));
}

const ResolverContext = struct {
    assembler: *Assembler,
    current_known: bool = true,
};

const SymbolDefinitionState = struct {
    known: bool,
    current_known: bool,
    stable: bool,
};

const SymbolScan = struct {
    symbolic: bool = false,
    definition_state: SymbolDefinitionState = knownCurrent(true),
};

const ResolverFn = struct {
    fn resolve(context: *anyopaque, text: []const u8) x86_encoder.ExpressionResolveError!?x86_encoder.ResolvedExpr {
        // Safety: context is &resolver_context (stack variable in tryDispatch),
        // correctly aligned for ResolverContext.
        const self: *ResolverContext = @ptrCast(@alignCast(context));
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        const symbol_scan = scanExpressionSymbols(self.assembler, trimmed);
        const expr_result = self.assembler.evaluateRelaxed(self.assembler.allocator, text) catch |err| switch (err) {
            else => return error.ExpressionResolutionFailed,
        };
        const has_alpha = for (text) |c| {
            if (std.ascii.isAlphabetic(c)) break true;
        } else false;
        const is_simple = !has_alpha;
        if (!symbol_scan.definition_state.current_known) self.current_known = false;
        const resolved = x86_encoder.ResolvedExpr{
            .value = @intCast(expr_result),
            .known = symbol_scan.definition_state.known,
            .current_known = symbol_scan.definition_state.current_known,
            .simple = symbol_scan.definition_state.known and is_simple,
            .symbolic = symbol_scan.symbolic or has_alpha,
        };
        return resolved;
    }
};

fn scanExpressionSymbols(assembler: *Assembler, text: []const u8) SymbolScan {
    var scan = SymbolScan{};
    var start: ?usize = null;
    var in_single = false;
    var in_double = false;
    for (text, 0..) |char, index| {
        if (char == '\'' and !in_double) {
            scanSymbolCandidate(assembler, text, &start, index, &scan);
            in_single = !in_single;
            continue;
        }
        if (char == '"' and !in_single) {
            scanSymbolCandidate(assembler, text, &start, index, &scan);
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;
        if (isSymbolNameChar(char)) {
            if (start == null) start = index;
            continue;
        }
        scanSymbolCandidate(assembler, text, &start, index, &scan);
        if (scan.symbolic and !scan.definition_state.known) return scan;
    }
    scanSymbolCandidate(assembler, text, &start, text.len, &scan);
    if (!scan.symbolic and isPlainSymbolName(text)) {
        scan.definition_state = symbolIsDefined(assembler, text);
    }
    return scan;
}

fn scanSymbolCandidate(
    assembler: *Assembler,
    text: []const u8,
    start: *?usize,
    end: usize,
    scan: *SymbolScan,
) void {
    const first = start.* orelse return;
    start.* = null;
    const current = text[first..end];
    if (current.len == 0) return;
    if (std.ascii.isDigit(current[0]) or isReservedSymbolWord(current) or x86_encoder.tables.registerByName(current) != null) {
        return;
    }

    const state = symbolIsDefined(assembler, current);
    const needs_fixup = if (assembler.symbols.peekBinding(current, true)) |binding|
        binding.symbol_type == .label
    else
        true;
    scan.symbolic = scan.symbolic or !state.known or needs_fixup;
    scan.definition_state.known = scan.definition_state.known and state.known;
    scan.definition_state.current_known = scan.definition_state.current_known and state.current_known and state.stable;
    scan.definition_state.stable = scan.definition_state.stable and state.stable;
}

fn symbolIsDefined(assembler: *Assembler, name: []const u8) SymbolDefinitionState {
    const current_binding = assembler.symbols.peekBinding(name, false);
    const previous_binding = assembler.symbols.peekPreviousBinding(name);
    const current_defined = current_binding != null;
    const stable = symbolBindingStableAcrossPass(
        assembler.symbols.hasPreviousSnapshot(),
        current_binding,
        previous_binding,
    );
    const binding = assembler.symbols.peekBinding(name, true);
    if (binding) |value| {
        return .{
            .known = value.is_defined,
            .current_known = current_defined and stable,
            .stable = stable,
        };
    }
    assembler.symbols.markDefinedQuery(name);
    return .{
        .known = false,
        .current_known = false,
        .stable = stable,
    };
}

fn knownCurrent(known: bool) SymbolDefinitionState {
    return .{
        .known = known,
        .current_known = known,
        .stable = true,
    };
}

fn symbolBindingStableAcrossPass(
    has_previous_snapshot: bool,
    current: ?@import("../../assembler/symbols.zig").SymbolBinding,
    previous: ?@import("../../assembler/symbols.zig").SymbolBinding,
) bool {
    if (!has_previous_snapshot) return true;
    const current_binding = current orelse return previous == null;
    const previous_binding = previous orelse return false;
    return current_binding.is_defined == previous_binding.is_defined and
        current_binding.symbol_type == previous_binding.symbol_type and
        current_binding.value == previous_binding.value and
        current_binding.size == previous_binding.size;
}

fn isSymbolNameChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_' or char == '.' or char == ':' or
        char == '%' or char == '$' or char == '@' or char == '?' or char == '\'';
}

fn isPlainSymbolName(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |char| {
        if (!isSymbolNameChar(char)) return false;
    }
    return !std.ascii.isDigit(text[0]);
}

fn isReservedSymbolWord(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "not");
}

fn emitUnits(allocator: Allocator, assembler: *Assembler, units: []const x86_encoder.EncodeUnit) AssembleError!void {
    for (units) |unit| {
        if (unit.reserve_len != 0) return error.InvalidInstruction;
        const bytes = if (unit.fixup) |fixup| blk: {
            const materialized = x86_encoder.materializeFixup(allocator, fixup) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidInstruction,
            };
            break :blk materialized;
        } else unit.bytes;
        defer if (unit.fixup != null and bytes.len > 0) allocator.free(bytes);
        try assembler.emitBytes(bytes);
    }
}

fn fixedBytesCacheKey(allocator: Allocator, mnemonic: []const u8, operands: []const []const u8) AssembleError!?[]u8 {
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    errdefer parts.deinit(allocator);
    try parts.appendSlice(allocator, mnemonic);
    for (operands) |op| {
        try parts.append(allocator, ',');
        try parts.appendSlice(allocator, op);
    }
    const bytes = try parts.toOwnedSlice(allocator);
    return @as(?[]u8, bytes);
}

fn fixedEncodedBytes(allocator: Allocator, units: []const x86_encoder.EncodeUnit) AssembleError!?[]u8 {
    var has_fixup = false;
    for (units) |u| {
        if (u.fixup != null or u.reserve_len != 0) {
            has_fixup = true;
            break;
        }
    }
    if (has_fixup) return null;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (units) |u| {
        try buf.appendSlice(allocator, u.bytes);
    }
    const bytes = try buf.toOwnedSlice(allocator);
    return @as(?[]u8, bytes);
}

pub fn tryDispatch(allocator: Allocator, assembler: *Assembler, line: []const u8) AssembleError!bool {
    var parsed = try parseInstruction(allocator, line);
    defer parsed.deinit(allocator);
    parsed.operands = parsed.operand_storage[0..parsed.operand_count];
    if (parsed.mnemonic.len == 0) return false;
    return tryDispatchParsed(allocator, assembler, &parsed);
}

pub fn tryDispatchParsed(allocator: Allocator, assembler: *Assembler, parsed: *const ParsedInstruction) AssembleError!bool {
    const mode_bits = resolveModeBits(assembler);

    var context = parsed.prefixes
        .applyTo(x86_encoder.EncodeContext.init(mode_bits))
        .withOutputPosition(try currentOutputPosition(assembler));
    if (operandsMayNeedDefaultRel(parsed.operands)) {
        context = context.withDefaultRel(resolveDefaultRel());
    }
    const branch_relaxation_candidate = mayUseBranchRelaxation(parsed.mnemonic);
    if (branch_relaxation_candidate) {
        context = context.withBranchRelaxationHint(
            try assembler.cachedX86BranchRelaxation(parsed.mnemonic, parsed.operands, assembler.state.current_line) orelse .near,
        );
    }

    const fixed_key = try fixedBytesCacheKey(allocator, parsed.mnemonic, parsed.operands);
    defer if (fixed_key) |key| allocator.free(key);
    if (!branch_relaxation_candidate) {
        if (fixed_key) |key| {
            if (assembler.cachedX86FixedBytes(key)) |bytes| {
                const units = [_]x86_encoder.EncodeUnit{.{ .kind = "raw", .bytes = bytes }};
                try emitUnits(allocator, assembler, &units);
                return true;
            }
        }
    }

    var resolver_context: ResolverContext = .{
        .assembler = assembler,
    };
    if (branch_relaxation_candidate) {
        context = context.withBranchRelaxationCurrentKnown(&resolver_context.current_known);
    }
    const resolver = x86_encoder.ExpressionResolver{
        .context = &resolver_context,
        .resolveFn = ResolverFn.resolve,
    };

    var encoded = x86_encoder.encodeBuiltinUnitsWithResolver(
        allocator,
        parsed.mnemonic,
        parsed.operands,
        context,
        false,
        resolver,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedMnemonic => return false,
        error.ExpressionResolutionFailed => return error.InvalidInstruction,
        else => return error.InvalidInstruction,
    };
    defer encoded.deinit(allocator);
    try emitUnits(allocator, assembler, encoded.units());
    if (!branch_relaxation_candidate) {
        if (fixed_key) |key| {
            if (try fixedEncodedBytes(allocator, encoded.units())) |bytes| {
                defer allocator.free(bytes);
                try assembler.rememberX86FixedBytes(key, bytes);
            }
        }
    }
    if (encoded.branch_relaxation_decision) |decision| {
        const stable_decision: x86_encoder.BranchRelaxationDecision =
            if (branch_relaxation_candidate and context.branch_relaxation_hint == .near) .near else decision;
        try assembler.rememberX86BranchRelaxation(
            parsed.mnemonic,
            parsed.operands,
            assembler.state.current_line,
            stable_decision,
        );
    }
    return true;
}

fn parseInstruction(allocator: Allocator, line: []const u8) AssembleError!ParsedInstruction {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    var result = ParsedInstruction{};
    errdefer result.deinit(allocator);

    var cursor = trimmed;
    while (true) {
        const token = leadingToken(cursor);
        if (token.len == 0) return result;
        const after = std.mem.trimStart(u8, cursor[token.len..], " \t\r\n");
        if (after.len == 0) break;
        if (!tryApplySourcePrefix(token, &result.prefixes)) break;
        cursor = after;
    }

    const raw_token = leadingToken(cursor);
    var raw_mnemonic = stripCombinedPrefixes(raw_token);
    raw_mnemonic = stripX86MnemonicDecorators(raw_mnemonic);

    result.owned_mnemonic = try allocator.dupe(u8, raw_mnemonic);
    for (result.owned_mnemonic.?) |*ch| ch.* = std.ascii.toLower(ch.*);
    result.mnemonic = result.owned_mnemonic.?;

    const rest = std.mem.trim(u8, cursor[raw_token.len..], " \t\r\n");
    if (rest.len == 0) return result;

    var count: usize = 0;
    var start: usize = 0;
    var in_single = false;
    var in_double = false;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var angle_depth: usize = 0;
    var brace_depth: usize = 0;

    for (rest, 0..) |ch, index| {
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
            '{' => {
                if (!in_single and !in_double) brace_depth += 1;
            },
            '}' => {
                if (!in_single and !in_double) brace_depth = brace_depth -| 1;
            },
            ',' => {
                if (in_single or in_double or paren_depth > 0 or bracket_depth > 0 or angle_depth > 0 or brace_depth > 0) continue;
                const operand = std.mem.trim(u8, rest[start..index], " \t\r\n");
                if (operand.len > 0) {
                    if (count >= max_operands) return error.InvalidInstruction;
                    result.operand_storage[count] = operand;
                    count += 1;
                }
                start = index + 1;
            },
            else => {},
        }
    }
    const operand = std.mem.trim(u8, rest[start..], " \t\r\n");
    if (operand.len > 0) {
        if (count >= max_operands) return error.InvalidInstruction;
        result.operand_storage[count] = operand;
        count += 1;
    }
    result.operand_count = count;
    return result;
}
