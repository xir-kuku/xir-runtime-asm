const std = @import("std");

const Allocator = std.mem.Allocator;

/// Meta values become XIR-owned once they are cloned or created via the
/// allocator-backed helpers here. Borrowed values may be used as clone sources,
/// but only owned values may be passed to `deinit`.
pub const MetaValue = union(enum) {
    int: i64,
    bool: bool,
    string: []const u8,
    bytes: []const u8,
    tokens: []const []const u8,
    args: []const MetaValue,
    object: MetaObject,
    void: void,

    pub fn ty(self: *const MetaValue) MetaType {
        return switch (self.*) {
            .int => .int,
            .bool => .bool,
            .string => .string,
            .bytes => .bytes,
            .tokens => .tokens,
            .args => .args,
            .object => .object,
            .void => .void,
        };
    }

    pub fn clone(self: *const MetaValue, allocator: Allocator) Allocator.Error!MetaValue {
        return switch (self.*) {
            .int => |value| .{ .int = value },
            .bool => |value| .{ .bool = value },
            .string => |value| .{ .string = try allocator.dupe(u8, value) },
            .bytes => |value| .{ .bytes = try allocator.dupe(u8, value) },
            .tokens => |value| .{ .tokens = try cloneTokenSlice(allocator, value) },
            .args => |value| .{ .args = try cloneArgs(allocator, value) },
            .object => |value| .{ .object = try value.clone(allocator) },
            .void => .{ .void = {} },
        };
    }

    pub fn deinit(self: *MetaValue, allocator: Allocator) void {
        switch (self.*) {
            .int, .bool, .void => {},
            .string => |value| {
                if (value.len > 0) allocator.free(value);
            },
            .bytes => |value| {
                if (value.len > 0) allocator.free(value);
            },
            .tokens => |value| {
                for (value) |token| allocator.free(token);
                if (value.len > 0) allocator.free(value);
            },
            .args => |value| {
                for (value) |entry| {
                    var owned = entry;
                    owned.deinit(allocator);
                }
                if (value.len > 0) allocator.free(value);
            },
            .object => |value| {
                var owned = value;
                owned.deinit(allocator);
            },
        }
        self.* = .{ .void = {} };
    }

    pub fn take(self: *MetaValue) MetaValue {
        const out = self.*;
        self.* = .{ .void = {} };
        return out;
    }

    pub fn dupeString(allocator: Allocator, text: []const u8) Allocator.Error!MetaValue {
        return .{ .string = try allocator.dupe(u8, text) };
    }

    pub fn dupeBytes(allocator: Allocator, bytes: []const u8) Allocator.Error!MetaValue {
        return .{ .bytes = try allocator.dupe(u8, bytes) };
    }

    pub fn dupeTokens(
        allocator: Allocator,
        tokens: []const []const u8,
    ) Allocator.Error!MetaValue {
        return .{ .tokens = try cloneTokenSlice(allocator, tokens) };
    }
};

pub const MetaType = enum {
    int,
    bool,
    string,
    bytes,
    tokens,
    args,
    object,
    void,

    pub fn asString(self: MetaType) []const u8 {
        return switch (self) {
            .int => "int",
            .bool => "bool",
            .string => "string",
            .bytes => "bytes",
            .tokens => "tokens",
            .args => "args",
            .object => "object",
            .void => "void",
        };
    }
};

pub const MetaObjectEntry = struct {
    key: []const u8,
    value: MetaValue,
};

pub const MetaObject = struct {
    entries: []const MetaObjectEntry,

    pub const empty: MetaObject = .{ .entries = &.{} };

    pub fn get(self: MetaObject, key: []const u8) ?*const MetaValue {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) return &entry.value;
        }
        return null;
    }

    pub fn clone(self: MetaObject, allocator: Allocator) Allocator.Error!MetaObject {
        const out = try allocator.alloc(MetaObjectEntry, self.entries.len);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |entry| {
                var owned = entry.value;
                owned.deinit(allocator);
                allocator.free(entry.key);
            }
            if (out.len > 0) allocator.free(out);
        }

        for (self.entries, 0..) |entry, index| {
            const key = try allocator.dupe(u8, entry.key);
            const value = entry.value.clone(allocator) catch |err| {
                allocator.free(key);
                return err;
            };
            out[index] = .{
                .key = key,
                .value = value,
            };
            initialized += 1;
        }

        return .{ .entries = out };
    }

    pub fn deinit(self: *MetaObject, allocator: Allocator) void {
        for (self.entries) |entry| {
            var owned = entry.value;
            owned.deinit(allocator);
            allocator.free(entry.key);
        }
        if (self.entries.len > 0) allocator.free(self.entries);
        self.* = .empty;
    }
};

fn cloneTokenSlice(
    allocator: Allocator,
    tokens: []const []const u8,
) Allocator.Error![]const []const u8 {
    const out = try allocator.alloc([]const u8, tokens.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |token| allocator.free(token);
        if (out.len > 0) allocator.free(out);
    }

    for (tokens, 0..) |token, index| {
        out[index] = try allocator.dupe(u8, token);
        initialized += 1;
    }
    return out;
}

fn cloneArgs(allocator: Allocator, args: []const MetaValue) Allocator.Error![]MetaValue {
    const out = try allocator.alloc(MetaValue, args.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |*entry| entry.deinit(allocator);
        if (out.len > 0) allocator.free(out);
    }

    for (args, 0..) |entry, index| {
        out[index] = try entry.clone(allocator);
        initialized += 1;
    }
    return out;
}

test "MetaValue clones nested payloads" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const children = [_]MetaValue{
        .{ .string = "eax" },
        .{ .bytes = "AZ" },
        .{ .tokens = &.{ "mov", "reg" } },
    };
    const root = MetaValue{
        .args = children[0..],
    };

    var cloned = try root.clone(gpa);
    defer cloned.deinit(gpa);

    try testing.expectEqual(MetaType.args, cloned.ty());

    switch (cloned) {
        .args => |items| {
            try testing.expectEqual(@as(usize, 3), items.len);
            try testing.expectEqualStrings("eax", items[0].string);
            try testing.expectEqualSlices(u8, "AZ", items[1].bytes);
            try testing.expectEqualStrings("mov", items[2].tokens[0]);
            try testing.expectEqualStrings("reg", items[2].tokens[1]);
        },
        else => return error.UnexpectedTestResult,
    }
}
