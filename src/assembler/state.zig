const std = @import("std");

pub const OutputFormat = enum {
    binary,
    executable,
    dos,
};

pub const State = struct {
    allocator: std.mem.Allocator,

    current_pass: usize = 0,
    current_line: usize = 0,
    output_format: OutputFormat = .binary,
    file_extension: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!State {
        var state: State = .{ .allocator = allocator };
        errdefer state.file_extension.deinit(allocator);
        try state.setFileExtension("bin");
        return state;
    }

    pub fn deinit(self: *State) void {
        self.file_extension.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clone(self: *const State, allocator: std.mem.Allocator) std.mem.Allocator.Error!State {
        var cloned: State = .{
            .allocator = allocator,
            .current_pass = self.current_pass,
            .current_line = self.current_line,
            .output_format = self.output_format,
            .file_extension = .empty,
        };
        errdefer cloned.file_extension.deinit(allocator);
        try cloned.file_extension.appendSlice(allocator, self.file_extension.items);
        return cloned;
    }

    pub fn resetForPass(self: *State, pass_index: usize) std.mem.Allocator.Error!void {
        self.current_pass = pass_index;
        self.current_line = 0;
        self.output_format = .binary;
        try self.setFileExtension("bin");
    }

    pub fn advanceLine(self: *State) void {
        self.current_line += 1;
    }

    pub fn setOutputFormat(self: *State, format: OutputFormat) void {
        self.output_format = format;
    }

    pub fn outputFormat(self: *const State) OutputFormat {
        return self.output_format;
    }

    pub fn setFileExtension(self: *State, ext: []const u8) std.mem.Allocator.Error!void {
        var replacement: std.ArrayListUnmanaged(u8) = .empty;
        errdefer replacement.deinit(self.allocator);
        try replacement.appendSlice(self.allocator, ext);

        self.file_extension.deinit(self.allocator);
        self.file_extension = replacement;
    }

    pub fn fileExtension(self: *const State) []const u8 {
        return self.file_extension.items;
    }
};

test "State reset restores per-pass counters" {
    const testing = @import("std").testing;

    var state = try State.init(testing.allocator);
    defer state.deinit();
    state.advanceLine();

    try state.resetForPass(4);

    try testing.expectEqual(@as(usize, 4), state.current_pass);
    try testing.expectEqual(@as(usize, 0), state.current_line);
    try testing.expectEqual(OutputFormat.binary, state.output_format);
    try testing.expectEqualStrings("bin", state.fileExtension());
}

test "State stores output format and file extension" {
    const testing = @import("std").testing;

    var state = try State.init(testing.allocator);
    defer state.deinit();
    state.setOutputFormat(.executable);
    try state.setFileExtension("rom");

    try testing.expectEqual(OutputFormat.executable, state.outputFormat());
    try testing.expectEqualStrings("rom", state.fileExtension());
}

test "State accepts an empty file extension" {
    const testing = @import("std").testing;

    var state = try State.init(testing.allocator);
    defer state.deinit();
    try state.setFileExtension("");

    try testing.expectEqualStrings("", state.fileExtension());
}

test "State grows file extensions past the old fixed buffer cap" {
    const testing = @import("std").testing;
    const extension = "abcdefghijklmnopqrstuvwxyz0123456789";

    var state = try State.init(testing.allocator);
    defer state.deinit();
    try state.setFileExtension(extension);

    try testing.expectEqualStrings(extension, state.fileExtension());
}

test "State keeps file extension unchanged when replacement allocation fails" {
    const testing = @import("std").testing;

    var state = try State.init(testing.allocator);
    defer state.deinit();
    try state.setFileExtension("stable");

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    const original_allocator = state.allocator;
    state.allocator = failing.allocator();
    defer state.allocator = original_allocator;

    try testing.expectError(error.OutOfMemory, state.setFileExtension("replacement"));
    try testing.expectEqualStrings("stable", state.fileExtension());
}
