const std = @import("std");
const build_opts = @import("build_opts");
const Assembler = @import("assembler.zig").Assembler;
const AssembleError = @import("assembler.zig").AssembleError;
const shared = @import("shared_source_runner.zig");
const x86_runner = @import("x86/source_runner.zig");
const riscv_runner = if (!build_opts.exclude_riscv) @import("riscv/source_runner.zig") else struct {};

const Allocator = std.mem.Allocator;

pub const Summary = struct {
    pass_count: usize,
    converged: bool,
    output_bytes: []u8,
    listing: []u8,
};

pub fn drive(allocator: Allocator, assembler: *Assembler, source: []const u8) AssembleError!Summary {
    const max_passes = assembler.max_passes;
    var pass_index: usize = 1;
    while (pass_index <= max_passes) : (pass_index += 1) {
        try assembler.resetForPass(pass_index);
        const expanded = try shared.expandControls(allocator, assembler, source);
        defer allocator.free(expanded);

        if (assembler.mode_bits & 0x80 != 0) {
            if (build_opts.exclude_riscv) return error.InvalidInstruction;
            try riscv_runner.run(allocator, assembler, expanded);
        } else {
            try x86_runner.run(allocator, assembler, expanded);
        }
        if (assembler.converged()) {
            assembler.converged_flag = true;
            const bytes = try assembler.finalizeOutput(allocator);
            errdefer allocator.free(bytes);
            const listing = try assembler.formatListing(allocator);
            return .{
                .pass_count = pass_index,
                .converged = true,
                .output_bytes = bytes,
                .listing = listing,
            };
        }
    }
    assembler.converged_flag = false;
    const bytes = try assembler.finalizeOutput(allocator);
    errdefer allocator.free(bytes);
    const listing = try assembler.formatListing(allocator);
    return .{
        .pass_count = max_passes,
        .converged = false,
        .output_bytes = bytes,
        .listing = listing,
    };
}
