const build_opts = @import("build_opts");

pub const capi = @import("asm/exports.zig");
pub const assembler = @import("asm/assembler.zig");
pub const pass_driver = @import("asm/pass_driver.zig");
pub const runtime = @import("asm/runtime.zig");
pub const x86 = @import("x86_encoder/root.zig");

pub const riscv = if (!build_opts.exclude_riscv) @import("riscv_encoder/root.zig") else struct {};
pub const spirv = if (!build_opts.exclude_spirv) @import("spirv_encoder/root.zig") else struct {};

comptime {
    @export(&capi.xir_new, .{ .name = "xir_new", .linkage = .strong });
    @export(&capi.xir_free, .{ .name = "xir_free", .linkage = .strong });
    @export(&capi.xir_assemble, .{ .name = "xir_assemble", .linkage = .strong });
    @export(&capi.xir_free_output, .{ .name = "xir_free_output", .linkage = .strong });
    @export(&capi.xir_symbol_value, .{ .name = "xir_symbol_value", .linkage = .strong });
    @export(&capi.xir_diagnostic_message, .{ .name = "xir_diagnostic_message", .linkage = .strong });
    @export(&capi.xir_get_listing, .{ .name = "xir_get_listing", .linkage = .strong });
    @export(&capi.xir_asm_compile, .{ .name = "xir_asm_compile", .linkage = .strong });
    if (!build_opts.exclude_riscv) {
        @export(&capi.xir_asm_compile_rv, .{ .name = "xir_asm_compile_rv", .linkage = .strong });
    }
    if (!build_opts.exclude_spirv) {
        @export(&capi.xir_asm_compile_spv, .{ .name = "xir_asm_compile_spv", .linkage = .strong });
        @export(&capi.xir_asm_free_spv, .{ .name = "xir_asm_free_spv", .linkage = .strong });
    }
    @export(&capi.xir_asm_free, .{ .name = "xir_asm_free", .linkage = .strong });
}
