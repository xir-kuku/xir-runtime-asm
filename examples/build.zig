const std = @import("std");

pub fn build(b: *std.Build) void {
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "exclude_spirv", false);
    build_opts.addOption(bool, "exclude_riscv", false);

    const cg_mod = b.createModule(.{
        .root_source_file = b.path("../src/xir_asm.zig"),
        .target = b.graph.host,
    });
    cg_mod.addOptions("build_opts", build_opts);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
    });
    exe_mod.addImport("xir_asm", cg_mod);

    const exe = b.addExecutable(.{
        .name = "xir-demo",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const directives_mod = b.createModule(.{
        .root_source_file = b.path("src/directives.zig"),
        .target = b.graph.host,
    });
    directives_mod.addImport("xir_asm", cg_mod);

    const directives_exe = b.addExecutable(.{
        .name = "xir-directives-demo",
        .root_module = directives_mod,
    });
    b.installArtifact(directives_exe);

    const showcase_mod = b.createModule(.{
        .root_source_file = b.path("src/showcase.zig"),
        .target = b.graph.host,
    });
    showcase_mod.addImport("xir_asm", cg_mod);

    const showcase_exe = b.addExecutable(.{
        .name = "xir-showcase",
        .root_module = showcase_mod,
    });
    b.installArtifact(showcase_exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_cmd.step);

    const run_directives = b.addRunArtifact(directives_exe);
    const directives_step = b.step("run-directives", "Run the assembler directive demo");
    directives_step.dependOn(&run_directives.step);

    const run_showcase = b.addRunArtifact(showcase_exe);
    const showcase_step = b.step("run-showcase", "Run the CPUID + AVX2 runtime assembler showcase");
    showcase_step.dependOn(&run_showcase.step);
}
