const std = @import("std");
const riscv = @import("riscv");

fn emit(label: []const u8, text: []const u8, xlen: u8) !void {
    const encoded = try riscv.encodeInstructionText(text, xlen, null);
    std.debug.print("{s} {x:0>8}\n", .{ label, encoded.word });
}

pub fn main(_: std.process.Init) !void {
    try emit("rv64_add", "add x1, x2, x3", 64);
    try emit("rv64_addi_neg", "addi x10, x2, -16", 64);
    try emit("rv64_lui", "lui x5, 0x12345", 64);
    try emit("rv64_sw", "sw x10, 12(x2)", 64);
    try emit("rv64_beq_forward", "beq x1, x2, 8", 64);
    try emit("rv64_jal_zero", "jal x1, 0", 64);
    try emit("rv32_slli_31", "slli x5, x6, 31", 32);
    try emit("rv64_slli_32", "slli x5, x6, 32", 64);
    try emit("rv64_slliw_31", "slliw x5, x6, 31", 64);
    try emit("rv64_fadd_s_rne", "fadd.s ft1, ft2, ft3, rne", 64);
    try emit("rv64_csrrw_mstatus", "csrrw x1, mstatus, x2", 64);
    try emit("rv64_fence_rw", "fence rw, rw", 64);
}
