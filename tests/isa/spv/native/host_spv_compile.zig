const std = @import("std");
const xir = @import("xir_asm");

fn readWordLe(bytes: []const u8, word_index: usize) u32 {
    const start = word_index * @sizeOf(u32);
    return std.mem.readInt(u32, bytes[start..][0..@sizeOf(u32)], .little);
}

pub fn main() !void {
    const source =
        \\OpCapability Shader
        \\OpMemoryModel Logical GLSL450
        \\%1 = OpTypeVoid
        \\OpName %1 "main"
    ;

    var out_size: usize = 0;
    const ptr = xir.capi.xir_asm_compile_spv(source, &out_size) orelse return error.CompileFailed;
    defer xir.capi.xir_asm_free_spv(ptr, out_size);

    const raw: [*]const u8 = @ptrCast(ptr);
    const bytes = raw[0..out_size];

    if (bytes.len != 16 * @sizeOf(u32)) return error.WrongSize;
    if (readWordLe(bytes, 0) != xir.spirv.module.magic_number) return error.BadMagic;
    if (readWordLe(bytes, 1) != xir.spirv.module.Version.v1_6.toWord()) return error.BadVersion;
    if (readWordLe(bytes, 3) != 2) return error.BadBound;
    if (readWordLe(bytes, 5) != 0x00020011) return error.BadCapability;
    if (readWordLe(bytes, 7) != 0x0003000e) return error.BadMemoryModel;
    if (readWordLe(bytes, 10) != 0x00020013) return error.BadTypeVoid;
    if (readWordLe(bytes, 12) != 0x00040005) return error.BadName;
}
