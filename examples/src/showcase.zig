const std = @import("std");
const xir_asm = @import("xir_asm");

const Assembler = xir_asm.assembler.Assembler;
const ExecMemory = xir_asm.runtime.ExecMemory;

const CpuidRegs = extern struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

const CpuidFn = *const fn (*CpuidRegs, u32, u32) callconv(.c) void;
const XgetbvFn = *const fn (u32) callconv(.c) u64;
const Copy64Fn = *const fn (*align(32) [64]u8, *align(32) const [64]u8) callconv(.c) void;

pub fn main() !void {
    if (comptime @import("builtin").cpu.arch != .x86_64) {
        std.debug.print("showcase requires x86_64 host\n", .{});
        return;
    }

    const allocator = std.heap.page_allocator;

    var cpuid_mem = try compile(allocator, cpuid_source);
    defer cpuid_mem.deinit();
    const cpuid_fn: CpuidFn = @ptrCast(@alignCast(cpuid_mem.code_ptr));

    var xgetbv_mem = try compile(allocator, xgetbv_source);
    defer xgetbv_mem.deinit();
    const xgetbv_fn: XgetbvFn = @ptrCast(@alignCast(xgetbv_mem.code_ptr));

    const features = detectFeatures(cpuid_fn, xgetbv_fn);
    std.debug.print(
        "cpuid: vendor={s}, avx2={}, avx512f={}, os_ymm={}, os_zmm={}\n",
        .{ features.vendor, features.avx2, features.avx512f, features.os_ymm, features.os_zmm },
    );

    if (!features.avx2 or !features.os_ymm) {
        std.debug.print("avx2 memcpy showcase skipped: CPU/OS did not enable YMM state\n", .{});
        return;
    }

    var copy_mem = try compile(allocator, copy64_avx2_source);
    defer copy_mem.deinit();
    const copy64: Copy64Fn = @ptrCast(@alignCast(copy_mem.code_ptr));

    var src: [64]u8 align(32) = undefined;
    var dst: [64]u8 align(32) = @splat(0);
    for (&src, 0..) |*byte, index| {
        byte.* = @intCast((index * 13 + 7) & 0xFF);
    }

    copy64(&dst, &src);
    try std.testing.expectEqualSlices(u8, &src, &dst);

    const digest = checksum(&dst);
    std.debug.print(
        "avx2 memcpy64: dst == src, checksum=0x{x:0>8}, first=0x{x:0>2}, last=0x{x:0>2}\n",
        .{ digest, dst[0], dst[63] },
    );
}

fn compile(allocator: std.mem.Allocator, source: []const u8) !ExecMemory {
    var assembler = try Assembler.init(allocator, 64);
    defer assembler.deinit();

    const result = try xir_asm.pass_driver.drive(allocator, &assembler, source);
    defer allocator.free(result.output_bytes);
    defer allocator.free(result.listing);

    if (!result.converged) return error.AssemblyDidNotConverge;
    return ExecMemory.allocate(result.output_bytes);
}

const Features = struct {
    vendor: [12]u8,
    os_ymm: bool,
    os_zmm: bool,
    avx2: bool,
    avx512f: bool,
};

fn detectFeatures(cpuid_fn: CpuidFn, xgetbv_fn: XgetbvFn) Features {
    var leaf0: CpuidRegs = undefined;
    cpuid_fn(&leaf0, 0, 0);

    var vendor: [12]u8 = undefined;
    std.mem.writeInt(u32, vendor[0..4], leaf0.ebx, .little);
    std.mem.writeInt(u32, vendor[4..8], leaf0.edx, .little);
    std.mem.writeInt(u32, vendor[8..12], leaf0.ecx, .little);

    var leaf1: CpuidRegs = undefined;
    cpuid_fn(&leaf1, 1, 0);
    const osxsave = (leaf1.ecx & (@as(u32, 1) << 27)) != 0;
    const avx = (leaf1.ecx & (@as(u32, 1) << 28)) != 0;
    const xcr0 = if (osxsave) xgetbv_fn(0) else 0;
    const os_ymm = (xcr0 & 0b110) == 0b110;
    const os_zmm = (xcr0 & 0b1110_0110) == 0b1110_0110;

    var leaf7: CpuidRegs = .{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 };
    if (leaf0.eax >= 7) cpuid_fn(&leaf7, 7, 0);

    return .{
        .vendor = vendor,
        .os_ymm = os_ymm,
        .os_zmm = os_zmm,
        .avx2 = avx and os_ymm and ((leaf7.ebx & (@as(u32, 1) << 5)) != 0),
        .avx512f = os_zmm and ((leaf7.ebx & (@as(u32, 1) << 16)) != 0),
    };
}

fn checksum(bytes: []const u8) u32 {
    var sum: u32 = 0;
    for (bytes) |byte| {
        sum +%= @as(u32, byte);
    }
    return sum;
}

const cpuid_source = if (@import("builtin").os.tag == .windows)
    \\push rbx
    \\mov r10, rcx
    \\mov eax, edx
    \\mov ecx, r8d
    \\cpuid
    \\mov [r10], eax
    \\mov [r10+4], ebx
    \\mov [r10+8], ecx
    \\mov [r10+12], edx
    \\pop rbx
    \\ret
else
    \\push rbx
    \\mov r10, rdi
    \\mov eax, esi
    \\mov ecx, edx
    \\cpuid
    \\mov [r10], eax
    \\mov [r10+4], ebx
    \\mov [r10+8], ecx
    \\mov [r10+12], edx
    \\pop rbx
    \\ret
;

const xgetbv_source = if (@import("builtin").os.tag == .windows)
    \\xgetbv
    \\shl rdx, 32
    \\or rax, rdx
    \\ret
else
    \\mov ecx, edi
    \\xgetbv
    \\shl rdx, 32
    \\or rax, rdx
    \\ret
;

const copy64_avx2_source = if (@import("builtin").os.tag == .windows)
    \\.align 16
    \\vmovdqa ymm0, [rdx]
    \\vmovdqa ymm1, [rdx+32]
    \\vmovdqa [rcx], ymm0
    \\vmovdqa [rcx+32], ymm1
    \\vzeroupper
    \\ret
else
    \\.align 16
    \\vmovdqa ymm0, [rsi]
    \\vmovdqa ymm1, [rsi+32]
    \\vmovdqa [rdi], ymm0
    \\vmovdqa [rdi+32], ymm1
    \\vzeroupper
    \\ret
;
