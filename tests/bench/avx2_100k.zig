const std = @import("std");
const cg = @import("xir_asm");
const windows = std.os.windows;

const qpc = windows.ntdll.RtlQueryPerformanceCounter;
const qpf = windows.ntdll.RtlQueryPerformanceFrequency;

const groups = 12_500;
const lines_per_group = templates.len;
const instruction_count = groups * lines_per_group;
const expected_output_bytes = groups * bytes_per_group;

const bytes_per_group = 63;

const templates = [_][]const u8{
    "vmovdqu ymm0, yword [rax + rbx*4 + 64]\n",
    "vpxor ymm1, ymm0, yword [rax + rbx*4 + 96]\n",
    "vpaddd ymm2, ymm1, yword [rax + rbx*4 + 128]\n",
    "vpshufb ymm3, ymm2, yword [rax + rbx*4 + 160]\n",
    "vperm2i128 ymm4, ymm2, ymm3, 031h\n",
    "vpalignr ymm5, ymm4, ymm1, 8\n",
    "vpblendd ymm6, ymm5, yword [rax + rbx*4 + 192], 0AAh\n",
    "vmovdqu yword [rax + rbx*4 + 224], ymm6\n",
};

const repeat_source =
    \\repeat 12500
    \\vmovdqu ymm0, yword [rax + rbx*4 + 64]
    \\vpxor ymm1, ymm0, yword [rax + rbx*4 + 96]
    \\vpaddd ymm2, ymm1, yword [rax + rbx*4 + 128]
    \\vpshufb ymm3, ymm2, yword [rax + rbx*4 + 160]
    \\vperm2i128 ymm4, ymm2, ymm3, 031h
    \\vpalignr ymm5, ymm4, ymm1, 8
    \\vpblendd ymm6, ymm5, yword [rax + rbx*4 + 192], 0AAh
    \\vmovdqu yword [rax + rbx*4 + 224], ymm6
    \\end repeat
;

const BenchmarkCase = struct {
    name: []const u8,
    source: []const u8,
};

const BenchmarkResult = struct {
    elapsed_ns: u64,
    output_len: usize,
    pass_count: usize,
    converged: bool,
};

fn now() !i64 {
    var pc: i64 = undefined;
    if (!qpc(&pc).toBool()) return error.TimerUnavailable;
    return pc;
}

fn frequency() !i64 {
    var freq: i64 = undefined;
    if (!qpf(&freq).toBool() or freq <= 0) return error.TimerUnavailable;
    return freq;
}

fn counterToNs(counter: i64, freq: i64) u64 {
    const ticks: i128 = @intCast(counter);
    const ns: i128 = @divTrunc(ticks * std.time.ns_per_s, freq);
    return @intCast(ns);
}

fn buildExpandedSource(allocator: std.mem.Allocator) ![]u8 {
    var total: usize = 0;
    for (templates) |line| {
        total += line.len;
    }
    const source = try allocator.alloc(u8, total * groups);
    errdefer allocator.free(source);

    var offset: usize = 0;
    var group_index: usize = 0;
    while (group_index < groups) : (group_index += 1) {
        for (templates) |line| {
            @memcpy(source[offset..][0..line.len], line);
            offset += line.len;
        }
    }
    return source[0..offset];
}

fn runCase(allocator: std.mem.Allocator, freq: i64, case: BenchmarkCase) !BenchmarkResult {
    var assembler = try cg.assembler.Assembler.init(allocator, 64);
    defer assembler.deinit();

    const start = try now();
    const result = try cg.pass_driver.drive(allocator, &assembler, case.source);
    const end = try now();
    defer {
        allocator.free(result.output_bytes);
        allocator.free(result.listing);
    }

    return .{
        .elapsed_ns = counterToNs(end - start, freq),
        .output_len = result.output_bytes.len,
        .pass_count = result.pass_count,
        .converged = result.converged,
    };
}

fn printResult(case: BenchmarkCase, result: BenchmarkResult) void {
    const elapsed_us = result.elapsed_ns / std.time.ns_per_us;
    const elapsed_ms = result.elapsed_ns / std.time.ns_per_ms;
    const rate = @as(f64, @floatFromInt(instruction_count)) /
        (@as(f64, @floatFromInt(result.elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s)));

    std.debug.print(
        "{s}: source={} bytes, output={} bytes, passes={}, converged={}\n",
        .{ case.name, case.source.len, result.output_len, result.pass_count, result.converged },
    );
    std.debug.print(
        "  time={} ms ({} us), throughput={d:.1} instructions/sec\n",
        .{ elapsed_ms, elapsed_us, rate },
    );
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const freq = try frequency();
    const expanded_source = try buildExpandedSource(allocator);

    std.debug.print(
        "AVX2 bare-instruction benchmark: {} instructions, expected {} output bytes\n",
        .{ instruction_count, expected_output_bytes },
    );

    const cases = [_]BenchmarkCase{
        .{ .name = "expanded", .source = expanded_source },
        .{ .name = "repeat", .source = repeat_source },
    };

    var reference_len: ?usize = null;
    for (cases) |case| {
        const result = try runCase(allocator, freq, case);
        if (result.output_len != expected_output_bytes) return error.UnexpectedOutputSize;
        if (!result.converged) return error.AssemblyDidNotConverge;
        if (reference_len) |len| {
            if (result.output_len != len) return error.OutputSizeMismatch;
        } else {
            reference_len = result.output_len;
        }
        printResult(case, result);
    }
}
