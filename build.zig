const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exclude_spirv = b.option(bool, "exclude-spirv", "Exclude SPIR-V encoder (no C ABI)") orelse false;
    const exclude_riscv = b.option(bool, "exclude-riscv", "Exclude RISC-V encoder (no C ABI)") orelse false;

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "exclude_spirv", exclude_spirv);
    build_opts.addOption(bool, "exclude_riscv", exclude_riscv);

    const cg_mod = b.addModule("xir_asm", .{
        .root_source_file = b.path("src/xir_asm.zig"),
        .target = target,
        .optimize = optimize,
    });
    cg_mod.addOptions("build_opts", build_opts);

    const cg_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "xir_asm",
        .root_module = cg_mod,
    });
    b.installArtifact(cg_lib);

    const cg_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/src/main.zig"),
        .target = b.graph.host,
    });
    cg_example_mod.addImport("xir_asm", cg_mod);
    const cg_example = b.addExecutable(.{
        .name = "xir_examples",
        .root_module = cg_example_mod,
    });
    const run_example = b.addRunArtifact(cg_example);
    const example_step = b.step("run-examples", "Run examples");
    example_step.dependOn(&run_example.step);

    const cg_bench_mod = b.createModule(.{
        .root_source_file = b.path("tests/bench/avx2_100k.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    cg_bench_mod.addImport("xir_asm", cg_mod);
    const cg_bench = b.addExecutable(.{
        .name = "xir_bench",
        .root_module = cg_bench_mod,
    });
    const run_bench = b.addRunArtifact(cg_bench);
    const bench_step = b.step("bench", "Benchmark 100K-line assembly");
    bench_step.dependOn(&run_bench.step);

    const cg_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/asm.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    cg_test_mod.addImport("xir_asm", cg_mod);
    const cg_test = b.addTest(.{ .root_module = cg_test_mod });
    const run_cg_test = b.addRunArtifact(cg_test);
    const test_step = b.step("test", "Run asm tests");
    test_step.dependOn(&run_cg_test.step);

    const x86_encoder_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/x86_encoder.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    x86_encoder_test_mod.addImport("xir_asm", cg_mod);
    const x86_encoder_test = b.addTest(.{ .root_module = x86_encoder_test_mod });
    const run_x86_encoder_test = b.addRunArtifact(x86_encoder_test);
    test_step.dependOn(&run_x86_encoder_test.step);

    if (!exclude_riscv and !exclude_spirv) {
        const isa_coverage_mod = b.createModule(.{
            .root_source_file = b.path("tests/isa_coverage.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        });
        isa_coverage_mod.addImport("xir_asm", cg_mod);
        const isa_coverage_test = b.addTest(.{ .root_module = isa_coverage_mod });
        const run_isa_coverage_test = b.addRunArtifact(isa_coverage_test);
        test_step.dependOn(&run_isa_coverage_test.step);
    }

    if (!exclude_riscv) {
        const riscv_source_parser_mod = b.createModule(.{
            .root_source_file = b.path("tests/isa/riscv/source_text_parser.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        });
        riscv_source_parser_mod.addImport("xir_asm", cg_mod);
        const riscv_source_parser_test = b.addTest(.{ .root_module = riscv_source_parser_mod });
        const run_riscv_source_parser_test = b.addRunArtifact(riscv_source_parser_test);
        test_step.dependOn(&run_riscv_source_parser_test.step);

        const riscv_source_fixtures_mod = b.createModule(.{
            .root_source_file = b.path("tests/isa/riscv/source_text_fixtures.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        });
        riscv_source_fixtures_mod.addImport("xir_asm", cg_mod);
        const riscv_source_fixtures_test = b.addTest(.{ .root_module = riscv_source_fixtures_mod });
        const run_riscv_source_fixtures_test = b.addRunArtifact(riscv_source_fixtures_test);
        test_step.dependOn(&run_riscv_source_fixtures_test.step);
    }

    if (!exclude_spirv) {
        const spirv_text_mod = b.createModule(.{
            .root_source_file = b.path("src/spirv_encoder/text.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        });
        const spirv_text_test = b.addTest(.{ .root_module = spirv_text_mod });
        test_step.dependOn(&b.addRunArtifact(spirv_text_test).step);

        const spirv_encoder_mod = b.createModule(.{
            .root_source_file = b.path("tests/spirv_encoder.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        });
        spirv_encoder_mod.addImport("xir_asm", cg_mod);
        const spirv_encoder_test = b.addTest(.{ .root_module = spirv_encoder_mod });
        const run_spirv_encoder_test = b.addRunArtifact(spirv_encoder_test);
        test_step.dependOn(&run_spirv_encoder_test.step);

        const spv_text_emit_mod = b.createModule(.{
            .root_source_file = b.path("tests/isa/spv/native/emit_spv_text.zig"),
            .target = b.graph.host,
        });
        spv_text_emit_mod.addImport("xir_asm", cg_mod);
        const spv_text_emit = b.addExecutable(.{
            .name = "emit_spv_text",
            .root_module = spv_text_emit_mod,
        });
        b.installArtifact(spv_text_emit);

        const spv_host_mod = b.createModule(.{
            .root_source_file = b.path("tests/isa/spv/native/host_spv_compile.zig"),
            .target = b.graph.host,
        });
        spv_host_mod.addImport("xir_asm", cg_mod);
        const spv_host = b.addExecutable(.{
            .name = "host_spv_compile",
            .root_module = spv_host_mod,
        });
        const run_spv_host = b.addRunArtifact(spv_host);
        test_step.dependOn(&run_spv_host.step);
        const spv_host_step = b.step("spv-host", "Run SPIR-V host C ABI smoke test");
        spv_host_step.dependOn(&run_spv_host.step);
    }
}
