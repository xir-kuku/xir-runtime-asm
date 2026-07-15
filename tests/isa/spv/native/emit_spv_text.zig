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
    const target_env = args.next() orelse "spv1.6";
    if (args.next() != null) return error.InvalidArgument;

    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const source = try cwd.readFileAlloc(io, input_path, allocator, .unlimited);
    const bytes = try spirv.text.parseSourceToOwnedBytes(allocator, source, .{
        .version = try parseVersion(target_env),
    });

    var out = try cwd.createFile(io, output_path, .{});
    defer out.close(io);
    try out.writeStreamingAll(io, bytes);
}

fn parseVersion(target_env: []const u8) !spirv.module.Version {
    if (std.mem.eql(u8, target_env, "spv1.0")) return .v1_0;
    if (std.mem.eql(u8, target_env, "spv1.1")) return .v1_1;
    if (std.mem.eql(u8, target_env, "spv1.2")) return .v1_2;
    if (std.mem.eql(u8, target_env, "spv1.3")) return .v1_3;
    if (std.mem.eql(u8, target_env, "spv1.4")) return .v1_4;
    if (std.mem.eql(u8, target_env, "spv1.5")) return .v1_5;
    if (std.mem.eql(u8, target_env, "spv1.6")) return .v1_6;
    return error.InvalidArgument;
}
