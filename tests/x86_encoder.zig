const std = @import("std");
const x86 = @import("xir_asm").x86;

fn resolveUnknown(_: *anyopaque, _: []const u8) x86.ExpressionResolveError!?x86.ResolvedExpr {
    return .{
        .value = 0,
        .known = false,
        .current_known = false,
        .simple = true,
        .symbolic = true,
    };
}

test "materializeFixup rejects zero-width absolute fixups" {
    const fixup: x86.Fixup = .{
        .kind = .absolute,
        .size = 0,
        .flags = 0,
        .toffset = 0,
        .tsegment = x86.match.no_seg,
        .twrt = x86.match.no_seg,
        .relbase = 0,
    };
    try std.testing.expectError(
        error.InvalidFixupSize,
        x86.materializeFixup(std.testing.allocator, fixup),
    );
}

test "symbolic near Jcc preserves relative fixup at nonzero origin" {
    var resolver_context: u8 = 0;
    const resolver: x86.ExpressionResolver = .{
        .context = &resolver_context,
        .resolveFn = resolveUnknown,
    };
    const current_known = false;

    var result = try x86.encodeBuiltinUnitsWithResolver(
        std.testing.allocator,
        "jne",
        &.{"target"},
        x86.EncodeContext.init(64)
            .withOutputPosition(0x0040_1000)
            .withBranchRelaxationHint(.near)
            .withBranchRelaxationCurrentKnown(&current_known),
        false,
        resolver,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.units().len);
    try std.testing.expectEqualSlices(u8, &.{0x0F}, result.units()[0].bytes);
    try std.testing.expectEqualSlices(u8, &.{0x85}, result.units()[1].bytes);
    const fixup = result.units()[2].fixup orelse return error.UnexpectedTestResult;
    try std.testing.expectEqual(x86.FixupKind.relative, fixup.kind);
    try std.testing.expectEqual(@as(u8, 4), fixup.size);
    try std.testing.expectEqual(@as(i64, 0x0040_1006), fixup.relbase);
}

test "symbolic RIP-relative memory preserves relative fixup" {
    var resolver_context: u8 = 0;
    const resolver: x86.ExpressionResolver = .{
        .context = &resolver_context,
        .resolveFn = resolveUnknown,
    };

    var result = try x86.encodeBuiltinUnitsWithResolver(
        std.testing.allocator,
        "mov",
        &.{ "eax", "[rel target]" },
        x86.EncodeContext.init(64).withOutputPosition(0x0050_2000),
        false,
        resolver,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.units().len);
    try std.testing.expectEqualSlices(u8, &.{0x8B}, result.units()[0].bytes);
    try std.testing.expectEqualSlices(u8, &.{0x05}, result.units()[1].bytes);
    const fixup = result.units()[2].fixup orelse return error.UnexpectedTestResult;
    try std.testing.expectEqual(x86.FixupKind.relative, fixup.kind);
    try std.testing.expectEqual(@as(u8, 4), fixup.size);
    try std.testing.expectEqual(@as(i64, 0x0050_2006), fixup.relbase);
}
