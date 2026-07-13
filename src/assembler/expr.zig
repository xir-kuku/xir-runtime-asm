const std = @import("std");

const symbols_mod = @import("symbols.zig");

const Allocator = std.mem.Allocator;
const SymbolStore = symbols_mod.SymbolStore;

pub const ExpressionError = Allocator.Error || error{
    CircularReference,
    ExpansionDepthExceeded,
    InvalidCharacter,
    InvalidNumber,
    InvalidOperand,
    InvalidToken,
    UndefinedSymbol,
    UnexpectedEof,
};

const Precedence = enum(u8) {
    bit_or = 1,
    bit_and = 2,
    add_sub = 3,
    shl_shr = 4,
    mul_div_mod = 5,
    unary_high = 6,

    fn next(self: Precedence) Precedence {
        return switch (self) {
            .bit_or => .bit_and,
            .bit_and => .add_sub,
            .add_sub => .shl_shr,
            .shl_shr => .mul_div_mod,
            .mul_div_mod, .unary_high => .unary_high,
        };
    }
};

const Operator = enum {
    add,
    sub,
    mul,
    shl,
    shr,
    bit_and,
    bit_or,
    bit_xor,
    bit_not,

    fn precedence(self: Operator) Precedence {
        return switch (self) {
            .add, .sub => .add_sub,
            .mul => .mul_div_mod,
            .shl, .shr => .shl_shr,
            .bit_and => .bit_and,
            .bit_or, .bit_xor => .bit_or,
            .bit_not => .unary_high,
        };
    }
};

const Node = union(enum) {
    number: usize,
    symbol: []const u8,
    unary: struct { op: Operator, operand: *Node },
    binary: struct { op: Operator, left: *Node, right: *Node },

    fn evaluate(self: *const Node, ctx: *EvalContext) ExpressionError!usize {
        return switch (self.*) {
            .number => |value| value,
            .symbol => |name| try resolveSymbolValue(ctx, name),
            .unary => |payload| try evalUnary(payload.op, payload.operand, ctx),
            .binary => |payload| try evalBinary(payload.op, payload.left, payload.right, ctx),
        };
    }
};

const EvalContext = struct {
    allocator: Allocator,
    symbols: *SymbolStore,
    expansion_stack: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *EvalContext) void {
        self.expansion_stack.deinit(self.allocator);
        self.* = undefined;
    }

    fn pushSymbol(self: *EvalContext, name: []const u8) ExpressionError!void {
        if (self.expansion_stack.items.len >= 256) return error.ExpansionDepthExceeded;

        for (self.expansion_stack.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return error.CircularReference;
        }

        try self.expansion_stack.append(self.allocator, name);
    }

    fn popSymbol(self: *EvalContext) void {
        std.debug.assert(self.expansion_stack.items.len != 0);
        self.expansion_stack.items.len -= 1;
    }
};

const ExpressionParser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize = 0,

    fn init(allocator: Allocator, input: []const u8) ExpressionParser {
        return .{
            .allocator = allocator,
            .input = trimWhitespace(input),
        };
    }

    fn parse(self: *ExpressionParser) ExpressionError!*Node {
        const expr = try self.parseExpression(.bit_or);
        self.skipWhitespace();
        if (self.peekByte() != null) return error.InvalidToken;
        return expr;
    }

    fn allocNode(self: *ExpressionParser, value: Node) ExpressionError!*Node {
        const node = try self.allocator.create(Node);
        node.* = value;
        return node;
    }

    fn peekByte(self: *const ExpressionParser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn consumeByte(self: *ExpressionParser) ?u8 {
        const byte = self.peekByte() orelse return null;
        self.pos += 1;
        return byte;
    }

    fn requireByte(self: *ExpressionParser) ExpressionError!u8 {
        return self.consumeByte() orelse error.UnexpectedEof;
    }

    fn consumeExpectedByte(self: *ExpressionParser, expected: u8) ExpressionError!void {
        const byte = try self.requireByte();
        if (byte != expected) return error.InvalidToken;
    }

    fn skipWhitespace(self: *ExpressionParser) void {
        while (self.peekByte()) |byte| {
            if (!std.ascii.isWhitespace(byte)) break;
            self.pos += 1;
        }
    }

    fn parseExpression(self: *ExpressionParser, min_precedence: Precedence) ExpressionError!*Node {
        var left = try self.parseUnary();

        while (self.peekOperator()) |op| {
            const precedence = op.precedence();
            if (@intFromEnum(precedence) < @intFromEnum(min_precedence)) break;

            self.consumeOperator(op);
            const right = try self.parseExpression(precedence.next());
            left = try self.allocNode(.{
                .binary = .{
                    .op = op,
                    .left = left,
                    .right = right,
                },
            });
        }

        return left;
    }

    fn parseUnary(self: *ExpressionParser) ExpressionError!*Node {
        const byte = self.peekByte() orelse return try self.parsePrimary();
        return switch (byte) {
            '+' => blk: {
                try self.consumeExpectedByte('+');
                break :blk try self.parseUnary();
            },
            '-' => blk: {
                try self.consumeExpectedByte('-');
                const expr = try self.parseUnary();
                break :blk try self.allocNode(.{
                    .binary = .{
                        .op = .sub,
                        .left = try self.allocNode(.{ .number = 0 }),
                        .right = expr,
                    },
                });
            },
            '~' => blk: {
                try self.consumeExpectedByte('~');
                break :blk try self.allocNode(.{
                    .unary = .{
                        .op = .bit_not,
                        .operand = try self.parseUnary(),
                    },
                });
            },
            else => try self.parsePrimary(),
        };
    }

    fn parsePrimary(self: *ExpressionParser) ExpressionError!*Node {
        const byte = self.peekByte() orelse return error.UnexpectedEof;

        if (std.ascii.isDigit(byte)) {
            return self.parseNumber();
        }
        if (std.ascii.isAlphabetic(byte) or byte == '_' or byte == '@' or byte == '%' or byte == '.' or byte == '$' or byte == '?') {
            return self.parseIdentifier();
        }
        if (byte == '(') {
            try self.consumeExpectedByte('(');
            const expr = try self.parseExpression(.bit_or);
            self.skipWhitespace();
            if (self.peekByte() != ')') return error.InvalidToken;
            try self.consumeExpectedByte(')');
            return expr;
        }

        return error.InvalidCharacter;
    }

    fn parseNumber(self: *ExpressionParser) ExpressionError!*Node {
        var token: std.ArrayList(u8) = .empty;
        defer token.deinit(self.allocator);

        try token.append(self.allocator, try self.requireByte());
        if (token.items[0] == '0') {
            if (self.peekByte()) |next| {
                const lower = std.ascii.toLower(next);
                if (lower == 'x' or lower == 'h' or lower == 'b' or lower == 'o') {
                    try token.append(self.allocator, try self.requireByte());
                }
            }
        }

        while (self.peekByte()) |next| {
            if (std.ascii.isAlphanumeric(next) or next == '_' or next == '\'') {
                try token.append(self.allocator, try self.requireByte());
            } else {
                break;
            }
        }

        const value = try parseIntegerLiteral(self.allocator, token.items);
        return try self.allocNode(.{ .number = value });
    }

    fn parseIdentifier(self: *ExpressionParser) ExpressionError!*Node {
        var token: std.ArrayList(u8) = .empty;
        defer token.deinit(self.allocator);

        while (self.peekByte()) |byte| {
            if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == ':' or byte == '%' or byte == '$' or byte == '@' or byte == '?' or byte == '\'') {
                try token.append(self.allocator, try self.requireByte());
            } else {
                break;
            }
        }

        if (token.items.len == 0) return error.InvalidToken;

        const lower = try asciiLowerOwned(self.allocator, token.items);
        defer self.allocator.free(lower);
        switch (loweredKeyword(lower)) {
            .not => {
                self.skipWhitespace();
                return try self.allocNode(.{
                    .unary = .{
                        .op = .bit_not,
                        .operand = try self.parseUnary(),
                    },
                });
            },
            .symbol => {
                const owned = try self.allocator.dupe(u8, token.items);
                return try self.allocNode(.{ .symbol = owned });
            },
        }
    }

    fn peekOperator(self: *ExpressionParser) ?Operator {
        self.skipWhitespace();
        const rest = self.input[self.pos..];
        if (rest.len == 0) return null;

        if (std.mem.startsWith(u8, rest, "<<")) return .shl;
        if (std.mem.startsWith(u8, rest, ">>")) return .shr;
        if (matchesWordOperator(rest, "shl")) return .shl;
        if (matchesWordOperator(rest, "shr")) return .shr;
        if (matchesWordOperator(rest, "and")) return .bit_and;
        if (matchesWordOperator(rest, "or")) return .bit_or;
        if (matchesWordOperator(rest, "xor")) return .bit_xor;

        return switch (rest[0]) {
            '+' => .add,
            '-' => .sub,
            '*' => .mul,
            '&' => .bit_and,
            '|' => .bit_or,
            '^' => .bit_xor,
            else => null,
        };
    }

    fn consumeOperator(self: *ExpressionParser, op: Operator) void {
        const rest = self.input[self.pos..];
        switch (op) {
            .add, .sub, .mul => self.pos += 1,
            .shl => {
                self.pos += if (std.mem.startsWith(u8, rest, "<<")) 2 else 3;
            },
            .shr => {
                self.pos += if (std.mem.startsWith(u8, rest, ">>")) 2 else 3;
            },
            .bit_and => self.pos += if (std.mem.startsWith(u8, rest, "&")) 1 else 3,
            .bit_or => self.pos += if (std.mem.startsWith(u8, rest, "|")) 1 else 2,
            .bit_xor => self.pos += if (std.mem.startsWith(u8, rest, "^")) 1 else 3,
            .bit_not => unreachable,
        }
        self.skipWhitespace();
    }
};

const IdentifierKeyword = enum {
    symbol,
    not,
};

pub fn evaluate(
    allocator: Allocator,
    input: []const u8,
    symbols: *SymbolStore,
) ExpressionError!usize {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    var ctx = EvalContext{
        .allocator = arena_state.allocator(),
        .symbols = symbols,
    };
    defer ctx.deinit();

    const expr = try parseExpressionWithContext(&ctx, input);
    return expr.evaluate(&ctx);
}

fn parseExpressionWithContext(ctx: *EvalContext, input: []const u8) ExpressionError!*Node {
    var parser = ExpressionParser.init(ctx.allocator, input);
    return parser.parse();
}

fn resolveSymbolValue(ctx: *EvalContext, name: []const u8) ExpressionError!usize {
    const binding = try ctx.symbols.lookupBinding(name, true) orelse {
        try ctx.symbols.markUsed(name);
        return error.UndefinedSymbol;
    };

    if (binding.expandable and binding.text != null and !isSnapshotRuntimeSymbol(name)) {
        try ctx.pushSymbol(name);
        defer ctx.popSymbol();
        const expr = try parseExpressionWithContext(ctx, trimWhitespace(binding.text.?));
        return expr.evaluate(ctx);
    }

    return binding.value;
}

fn isSnapshotRuntimeSymbol(name: []const u8) bool {
    return std.mem.eql(u8, name, "$") or
        std.mem.eql(u8, name, "$$") or
        std.mem.eql(u8, name, "__line__");
}

fn evalUnary(op: Operator, operand: *const Node, ctx: *EvalContext) ExpressionError!usize {
    const value = try operand.evaluate(ctx);
    return switch (op) {
        .bit_not => ~value,
        else => error.InvalidOperand,
    };
}

fn evalBinary(op: Operator, left: *const Node, right: *const Node, ctx: *EvalContext) ExpressionError!usize {
    return switch (op) {
        .add => (try left.evaluate(ctx)) +% (try right.evaluate(ctx)),
        .sub => (try left.evaluate(ctx)) -% (try right.evaluate(ctx)),
        .mul => (try left.evaluate(ctx)) *% (try right.evaluate(ctx)),
        .shl => blk: {
            const amount = try right.evaluate(ctx);
            if (amount >= @bitSizeOf(usize)) return 0;
            const shift: std.math.Log2Int(usize) = @intCast(amount);
            break :blk (try left.evaluate(ctx)) << shift;
        },
        .shr => blk: {
            const amount = try right.evaluate(ctx);
            if (amount >= @bitSizeOf(usize)) return 0;
            const shift: std.math.Log2Int(usize) = @intCast(amount);
            break :blk (try left.evaluate(ctx)) >> shift;
        },
        .bit_and => (try left.evaluate(ctx)) & (try right.evaluate(ctx)),
        .bit_or => (try left.evaluate(ctx)) | (try right.evaluate(ctx)),
        .bit_xor => (try left.evaluate(ctx)) ^ (try right.evaluate(ctx)),
        else => error.InvalidOperand,
    };
}

fn loweredKeyword(lower: []const u8) IdentifierKeyword {
    if (std.mem.eql(u8, lower, "not")) return .not;
    return .symbol;
}

fn parseIntegerLiteral(allocator: Allocator, token: []const u8) ExpressionError!usize {
    const normalized = try normalizeNumberToken(allocator, token);
    if (normalized.len == 0) return error.InvalidNumber;

    if (std.mem.startsWith(u8, normalized, "0x") or std.mem.startsWith(u8, normalized, "0h")) {
        return std.fmt.parseInt(usize, normalized[2..], 16) catch error.InvalidNumber;
    }
    if (std.mem.endsWith(u8, normalized, "b")) {
        return std.fmt.parseInt(usize, normalized[0 .. normalized.len - 1], 2) catch error.InvalidNumber;
    }
    if (std.mem.endsWith(u8, normalized, "h")) {
        return std.fmt.parseInt(usize, normalized[0 .. normalized.len - 1], 16) catch error.InvalidNumber;
    }
    if (std.mem.endsWith(u8, normalized, "o")) {
        return std.fmt.parseInt(usize, normalized[0 .. normalized.len - 1], 8) catch error.InvalidNumber;
    }
    if (std.mem.startsWith(u8, normalized, "0b")) {
        return std.fmt.parseInt(usize, normalized[2..], 2) catch error.InvalidNumber;
    }
    if (std.mem.startsWith(u8, normalized, "0o")) {
        return std.fmt.parseInt(usize, normalized[2..], 8) catch error.InvalidNumber;
    }
    if (normalized.len > 1 and normalized[0] == '0') {
        return std.fmt.parseInt(usize, normalized[1..], 8) catch std.fmt.parseInt(usize, normalized, 10) catch error.InvalidNumber;
    }
    return std.fmt.parseInt(usize, normalized, 10) catch error.InvalidNumber;
}

fn normalizeNumberToken(allocator: Allocator, token: []const u8) Allocator.Error![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    for (token) |byte| {
        if (byte == '_' or byte == '\'') continue;
        try normalized.append(allocator, std.ascii.toLower(byte));
    }
    return normalized.toOwnedSlice(allocator);
}

fn asciiLowerOwned(allocator: Allocator, input: []const u8) Allocator.Error![]u8 {
    var lower: std.ArrayList(u8) = .empty;
    for (input) |byte| {
        try lower.append(allocator, std.ascii.toLower(byte));
    }
    return lower.toOwnedSlice(allocator);
}

fn trimWhitespace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

fn matchesWordOperator(rest: []const u8, keyword: []const u8) bool {
    if (rest.len < keyword.len) return false;
    if (!std.ascii.eqlIgnoreCase(rest[0..keyword.len], keyword)) return false;
    if (rest.len == keyword.len) return true;

    const next = rest[keyword.len];
    return !std.ascii.isAlphanumeric(next) and next != '_';
}
