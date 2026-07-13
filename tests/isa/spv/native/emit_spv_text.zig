const std = @import("std");
const spirv = @import("xir_asm").spirv;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    _ = args.next() orelse return error.InvalidArgument;
    const input_path = args.next() orelse return error.InvalidArgument;
    const output_path = args.next() orelse return error.InvalidArgument;
    if (args.next() != null) return error.InvalidArgument;

    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const source = try cwd.readFileAlloc(io, input_path, allocator, .unlimited);
    const bytes = try spirv.text.parseSourceToOwnedBytes(allocator, source, .{});

    var out = try cwd.createFile(io, output_path, .{});
    defer out.close(io);
    try out.writeStreamingAll(io, bytes);
}
