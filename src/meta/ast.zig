const std = @import("std");
const value_mod = @import("value.zig");

const Allocator = std.mem.Allocator;

pub const MetaType = value_mod.MetaType;
pub const MetaValue = value_mod.MetaValue;

pub const Span = struct {
    line: usize,
    col: usize,

    pub const start: Span = .{ .line = 1, .col = 1 };
};

pub const MetaErrorCode = enum {
    parse,
    type,
    runtime,
    match,
    bridge,

    pub fn asString(self: MetaErrorCode) []const u8 {
        return switch (self) {
            .parse => "E_PARSE",
            .type => "E_TYPE",
            .runtime => "E_RUNTIME",
            .match => "E_MATCH",
            .bridge => "E_BRIDGE",
        };
    }
};

pub const MetaError = struct {
    code: MetaErrorCode,
    message: []const u8,
    line: usize,
    col: usize,

    pub fn init(
        allocator: Allocator,
        code: MetaErrorCode,
        span: Span,
        message: []const u8,
    ) Allocator.Error!MetaError {
        return .{
            .code = code,
            .message = try allocator.dupe(u8, message),
            .line = span.line,
            .col = span.col,
        };
    }

    pub fn initFmt(
        allocator: Allocator,
        code: MetaErrorCode,
        span: Span,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!MetaError {
        return .{
            .code = code,
            .message = try std.fmt.allocPrint(allocator, fmt, args),
            .line = span.line,
            .col = span.col,
        };
    }

    pub fn deinit(self: *MetaError, allocator: Allocator) void {
        if (self.message.len > 0) allocator.free(self.message);
        self.* = .{
            .code = .parse,
            .message = "",
            .line = 0,
            .col = 0,
        };
    }
};

pub fn clearDiagnostic(allocator: Allocator, diagnostic: *?MetaError) void {
    if (diagnostic.*) |*err| err.deinit(allocator);
    diagnostic.* = null;
}

pub const UnaryOp = enum {
    neg,
    not,
    bit_not,
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    bit_and,
    bit_xor,
    bit_or,
    shl,
    shr,
    and_op,
    or_op,
};

pub const Pattern = union(enum) {
    wildcard,
    lit: MetaValue,
    type_guard: MetaType,
    tokens_prefix: []const []const u8,
    tokens_suffix: []const []const u8,
    token_capture: []const []const u8,

    pub fn deinit(self: *Pattern, allocator: Allocator) void {
        switch (self.*) {
            .wildcard, .type_guard => {},
            .lit => |*value| value.deinit(allocator),
            .tokens_prefix, .tokens_suffix, .token_capture => |tokens| freeTokenList(allocator, tokens),
        }
        self.* = .wildcard;
    }
};

pub const Expr = union(enum) {
    lit: MetaValue,
    ident: IdentExpr,
    unary: UnaryExpr,
    binary: BinaryExpr,
    call: CallExpr,
    index: IndexExpr,

    pub fn deinit(self: *Expr, allocator: Allocator) void {
        switch (self.*) {
            .lit => |*value| value.deinit(allocator),
            .ident => |expr| allocator.free(expr.name),
            .unary => |expr| destroyExpr(allocator, expr.expr),
            .binary => |expr| {
                destroyExpr(allocator, expr.lhs);
                destroyExpr(allocator, expr.rhs);
            },
            .call => |expr| {
                allocator.free(expr.name);
                for (expr.args) |arg| destroyExpr(allocator, arg);
                if (expr.args.len > 0) allocator.free(expr.args);
            },
            .index => |expr| {
                destroyExpr(allocator, expr.base);
                destroyExpr(allocator, expr.index);
            },
        }
        self.* = .{ .lit = .{ .void = {} } };
    }

    pub fn span(self: *const Expr) Span {
        return switch (self.*) {
            .lit => .start,
            .ident => |expr| expr.span,
            .unary => |expr| expr.span,
            .binary => |expr| expr.span,
            .call => |expr| expr.span,
            .index => |expr| expr.span,
        };
    }
};

pub const IdentExpr = struct {
    name: []const u8,
    span: Span,
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    expr: *Expr,
    span: Span,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    lhs: *Expr,
    rhs: *Expr,
    span: Span,
};

pub const CallExpr = struct {
    name: []const u8,
    args: []const *Expr,
    span: Span,
};

pub const IndexExpr = struct {
    base: *Expr,
    index: *Expr,
    span: Span,
};

pub const MetaParam = struct {
    name: []const u8,
    ty: ?MetaType,
    required_non_empty: bool,
    default_value: ?*Expr,
    rest: bool,

    pub fn deinit(self: *MetaParam, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.default_value) |expr| destroyExpr(allocator, expr);
        self.* = .{
            .name = "",
            .ty = null,
            .required_non_empty = false,
            .default_value = null,
            .rest = false,
        };
    }
};

pub const MetaFunction = struct {
    name: []const u8,
    params: []MetaParam,
    return_type: MetaType,
    body: []Stmt,
    span: Span,

    pub fn deinit(self: *MetaFunction, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.params) |*param| param.deinit(allocator);
        if (self.params.len > 0) allocator.free(self.params);
        deinitStmtSlice(allocator, self.body);
        self.* = .{
            .name = "",
            .params = &.{},
            .return_type = .void,
            .body = &.{},
            .span = .start,
        };
    }
};

pub const Stmt = union(enum) {
    fn_def: MetaFunction,
    let_stmt: LetStmt,
    assign: AssignStmt,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    match_stmt: MatchStmt,
    expr: *Expr,
    return_stmt: ReturnStmt,
    break_stmt: Span,
    continue_stmt: Span,

    pub fn deinit(self: *Stmt, allocator: Allocator) void {
        switch (self.*) {
            .fn_def => |*stmt| stmt.deinit(allocator),
            .let_stmt => |stmt| {
                allocator.free(stmt.name);
                if (stmt.value) |expr| destroyExpr(allocator, expr);
            },
            .assign => |stmt| {
                allocator.free(stmt.name);
                destroyExpr(allocator, stmt.value);
            },
            .if_stmt => |stmt| {
                destroyExpr(allocator, stmt.condition);
                deinitStmtSlice(allocator, stmt.then_body);
                deinitStmtSlice(allocator, stmt.else_body);
            },
            .while_stmt => |stmt| {
                destroyExpr(allocator, stmt.condition);
                deinitStmtSlice(allocator, stmt.body);
            },
            .match_stmt => |stmt| {
                destroyExpr(allocator, stmt.value);
                for (stmt.arms) |*arm| arm.deinit(allocator);
                if (stmt.arms.len > 0) allocator.free(stmt.arms);
            },
            .expr => |expr| destroyExpr(allocator, expr),
            .return_stmt => |stmt| {
                if (stmt.value) |expr| destroyExpr(allocator, expr);
            },
            .break_stmt, .continue_stmt => {},
        }
        self.* = .{ .break_stmt = .start };
    }
};

pub const LetStmt = struct {
    name: []const u8,
    ty: MetaType,
    value: ?*Expr,
    span: Span,
};

pub const AssignStmt = struct {
    name: []const u8,
    value: *Expr,
    span: Span,
};

pub const IfStmt = struct {
    condition: *Expr,
    then_body: []Stmt,
    else_body: []Stmt,
};

pub const WhileStmt = struct {
    condition: *Expr,
    body: []Stmt,
};

pub const MatchStmt = struct {
    value: *Expr,
    arms: []MatchArm,
    span: Span,
};

pub const MatchArm = struct {
    pattern: Pattern,
    body: []Stmt,

    pub fn deinit(self: *MatchArm, allocator: Allocator) void {
        self.pattern.deinit(allocator);
        deinitStmtSlice(allocator, self.body);
        self.* = .{
            .pattern = .wildcard,
            .body = &.{},
        };
    }
};

pub const ReturnStmt = struct {
    value: ?*Expr,
    span: Span,
};

pub const MetaProgram = struct {
    statements: []Stmt,

    pub fn deinit(self: *MetaProgram, allocator: Allocator) void {
        deinitStmtSlice(allocator, self.statements);
        self.* = .{ .statements = &.{} };
    }
};

pub fn destroyExpr(allocator: Allocator, expr: *Expr) void {
    expr.deinit(allocator);
    allocator.destroy(expr);
}

pub fn deinitStmtSlice(allocator: Allocator, statements: []Stmt) void {
    for (statements) |*stmt| stmt.deinit(allocator);
    if (statements.len > 0) allocator.free(statements);
}

pub fn freeTokenList(allocator: Allocator, tokens: []const []const u8) void {
    for (tokens) |token| allocator.free(token);
    if (tokens.len > 0) allocator.free(tokens);
}

test "MetaError owns its message" {
    const testing = std.testing;
    var err = try MetaError.init(testing.allocator, .parse, .start, "bad token");
    defer err.deinit(testing.allocator);
    try testing.expectEqualStrings("bad token", err.message);
}
