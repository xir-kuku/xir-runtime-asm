const std = @import("std");

const symbols_mod = @import("symbols.zig");

const Allocator = std.mem.Allocator;
const RuntimeSnapshot = symbols_mod.RuntimeSnapshot;

pub const OutputWriteError = Allocator.Error || error{
    OutputOverflow,
};

pub const OutputError = OutputWriteError || error{
    InvalidAddress,
};

pub const VirtualLabelRef = struct {
    index: usize,
    absolute_address: usize,
};

pub const ExtraOutputFile = struct {
    extension: []u8,
    bytes: []u8,
};

pub const MainSectionView = struct {
    index: usize,
    base_address: usize,
    file_offset: usize,
    bytes: []const u8,
};

fn addUsize(left: usize, right: usize) OutputWriteError!usize {
    const sum, const overflow = @addWithOverflow(left, right);
    if (overflow != 0) return error.OutputOverflow;
    return sum;
}

fn validateScalarByteCount(size: usize) OutputError!void {
    if (size > @sizeOf(usize)) return error.InvalidAddress;
}

fn writeScalarLe(buffer: []u8, value: usize) void {
    // Safety: buffer.len ≤ @sizeOf(usize) — enforced by all callers via
    // validateScalarByteCount or explicit fixed-size array. This bounds index*8
    // to ≤ 56, which fits in Log2Int(usize) (= u6). Without this, a caller
    // passing a larger buffer would cause @intCast UB in ReleaseFast.
    std.debug.assert(buffer.len <= @sizeOf(usize));
    for (buffer, 0..) |*byte, index| {
        byte.* = @truncate(value >> @as(std.math.Log2Int(usize), @intCast(index * 8)));
    }
}

const Section = struct {
    bytes: std.ArrayList(u8) = .empty,
    base_address: usize = 0,
    file_offset: usize = 0,
    current_offset: usize = 0,
    pending_reserve: usize = 0,
    base_expression: ?[]const u8 = null,

    fn init(base_address: usize, base_expression: ?[]const u8, file_offset: usize) Section {
        return .{
            .base_address = base_address,
            .base_expression = base_expression,
            .file_offset = file_offset,
        };
    }

    fn deinit(self: *Section, allocator: Allocator) void {
        self.bytes.deinit(allocator);
        if (self.base_expression) |expr| allocator.free(expr);
        self.* = undefined;
    }

    fn committedLen(self: *const Section) usize {
        return self.bytes.items.len;
    }

    fn futureFileLen(self: *const Section) OutputWriteError!usize {
        return try addUsize(self.bytes.items.len, self.pending_reserve);
    }

    fn initializedPosition(self: *const Section) OutputWriteError!usize {
        return try addUsize(self.base_address, self.bytes.items.len);
    }

    fn position(self: *const Section) OutputWriteError!usize {
        return try addUsize(self.base_address, self.current_offset);
    }

    fn uninitializedBase(self: *const Section) OutputWriteError!usize {
        return (try self.position()) -| self.pending_reserve;
    }

    fn advanceOffset(self: *Section, count: usize) OutputWriteError!void {
        const next, const overflow = @addWithOverflow(self.current_offset, count);
        if (overflow != 0) return error.OutputOverflow;
        self.current_offset = next;
    }

    fn materializePendingReserve(self: *Section, allocator: Allocator) OutputWriteError!void {
        if (self.pending_reserve == 0) return;
        try self.ensurePendingReserveCapacity(allocator);
        self.materializePendingReserveAssumeCapacity();
    }

    fn ensurePendingReserveCapacity(self: *Section, allocator: Allocator) OutputWriteError!void {
        if (self.pending_reserve == 0) return;
        try self.bytes.ensureUnusedCapacity(allocator, self.pending_reserve);
    }

    fn materializePendingReserveAssumeCapacity(self: *Section) void {
        if (self.pending_reserve == 0) return;
        self.bytes.appendNTimesAssumeCapacity(0, self.pending_reserve);
        self.pending_reserve = 0;
    }

    fn trimPendingReserve(self: *Section) void {
        self.pending_reserve = 0;
    }

    fn writeByte(self: *Section, allocator: Allocator, byte: u8) OutputWriteError!void {
        try self.materializePendingReserve(allocator);
        try self.bytes.append(allocator, byte);
        try self.advanceOffset(1);
    }

    fn writeBytes(self: *Section, allocator: Allocator, bytes: []const u8) OutputWriteError!void {
        if (bytes.len == 0) return;
        try self.materializePendingReserve(allocator);
        try self.bytes.appendSlice(allocator, bytes);
        try self.advanceOffset(bytes.len);
    }

    fn reserveBytes(self: *Section, count: usize) OutputWriteError!void {
        if (count == 0) return;
        const next_offset, const offset_overflow = @addWithOverflow(self.current_offset, count);
        if (offset_overflow != 0) return error.OutputOverflow;
        const next_pending, const overflow = @addWithOverflow(self.pending_reserve, count);
        if (overflow != 0) return error.OutputOverflow;
        self.current_offset = next_offset;
        self.pending_reserve = next_pending;
    }

    fn readVisibleByte(self: *const Section, relative_address: usize) OutputWriteError!?u8 {
        if (relative_address < self.bytes.items.len) {
            return self.bytes.items[relative_address];
        }
        if (relative_address < try self.futureFileLen()) return 0;
        return null;
    }

    fn validateVisibleRange(self: *const Section, relative_address: usize, size: usize) OutputError!void {
        const end, const overflow = @addWithOverflow(relative_address, size);
        if (overflow != 0 or end > try self.futureFileLen()) return error.InvalidAddress;
    }

    fn storeByteAt(
        self: *Section,
        allocator: Allocator,
        relative_address: usize,
        byte: u8,
    ) OutputError!void {
        try self.validateVisibleRange(relative_address, 1);
        if (relative_address >= self.bytes.items.len) {
            try self.materializePendingReserve(allocator);
        }
        self.bytes.items[relative_address] = byte;
    }

    fn storeBytesAt(
        self: *Section,
        allocator: Allocator,
        relative_address: usize,
        bytes: []const u8,
    ) OutputError!void {
        if (bytes.len == 0) return;
        try self.validateVisibleRange(relative_address, bytes.len);

        const end = relative_address + bytes.len;
        if (end > self.bytes.items.len) {
            try self.materializePendingReserve(allocator);
        }

        @memcpy(self.bytes.items[relative_address..end], bytes);
    }
};

const VirtualLabelMap = std.StringHashMap(usize);

const VirtualSection = struct {
    sections: std.ArrayList(Section) = .empty,
    current_section_index: usize = 0,
    output_extension: ?[]const u8 = null,
    labels: VirtualLabelMap,

    fn init(
        allocator: Allocator,
        offset: usize,
        expression: ?[]const u8,
        extension: ?[]const u8,
    ) Allocator.Error!VirtualSection {
        var owned_expression = try dupeOptionalText(allocator, expression);
        errdefer if (owned_expression) |text| allocator.free(text);
        var owned_output_extension = try dupeOptionalText(allocator, extension);
        errdefer if (owned_output_extension) |text| allocator.free(text);

        var section = VirtualSection{
            .output_extension = owned_output_extension,
            .labels = VirtualLabelMap.init(allocator),
        };
        owned_output_extension = null;
        errdefer section.deinit(allocator);

        try section.sections.append(allocator, Section.init(offset, owned_expression, 0));
        owned_expression = null;
        return section;
    }

    fn deinit(self: *VirtualSection, allocator: Allocator) void {
        for (self.sections.items) |*section| section.deinit(allocator);
        self.sections.deinit(allocator);
        if (self.output_extension) |extension| allocator.free(extension);
        var it = self.labels.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.labels.deinit();
        self.* = undefined;
    }

    fn position(self: *const VirtualSection) OutputWriteError!usize {
        return try self.currentSection().position();
    }

    fn origin(self: *const VirtualSection) usize {
        return self.currentSection().base_address;
    }

    fn originExpression(self: *const VirtualSection) ?[]const u8 {
        return self.currentSection().base_expression;
    }

    fn addressExpression(self: *const VirtualSection) ?[]const u8 {
        const section = self.currentSection();
        if (section.current_offset == 0) return section.base_expression;
        return null;
    }

    fn fileOffset(self: *const VirtualSection) OutputWriteError!usize {
        const section = self.currentSection();
        return try addUsize(section.file_offset, try section.futureFileLen());
    }

    fn actualFileSize(self: *const VirtualSection) OutputWriteError!usize {
        var total: usize = 0;
        for (self.sections.items) |section| {
            if (section.bytes.items.len == 0) continue;
            const end = try addUsize(section.file_offset, section.committedLen());
            if (end > total) total = end;
        }
        return total;
    }

    fn uninitializedBase(self: *const VirtualSection) OutputWriteError!usize {
        return try self.currentSection().uninitializedBase();
    }

    fn setOriginWithExpression(
        self: *VirtualSection,
        allocator: Allocator,
        base: usize,
        expression: ?[]const u8,
    ) OutputWriteError!void {
        const file_offset = try self.fileOffset();
        const owned_expression = try dupeOptionalText(allocator, expression);
        errdefer if (owned_expression) |text| allocator.free(text);

        try self.sections.append(allocator, Section.init(base, owned_expression, file_offset));
        self.current_section_index = self.sections.items.len - 1;
    }

    fn createSectionWithExpression(
        self: *VirtualSection,
        allocator: Allocator,
        base: usize,
        expression: ?[]const u8,
    ) OutputWriteError!void {
        self.trimTrailingReserve();
        const file_offset = try self.actualFileSize();
        const owned_expression = try dupeOptionalText(allocator, expression);
        errdefer if (owned_expression) |text| allocator.free(text);

        try self.sections.append(allocator, Section.init(base, owned_expression, file_offset));
        self.current_section_index = self.sections.items.len - 1;
    }

    fn writeByte(self: *VirtualSection, allocator: Allocator, byte: u8) OutputWriteError!void {
        try self.currentSectionMut().writeByte(allocator, byte);
    }

    fn writeBytes(self: *VirtualSection, allocator: Allocator, bytes: []const u8) OutputWriteError!void {
        try self.currentSectionMut().writeBytes(allocator, bytes);
    }

    fn reserveBytes(self: *VirtualSection, count: usize) OutputWriteError!void {
        if (count == 0) return;
        try self.currentSectionMut().reserveBytes(count);
    }

    fn loadN(
        self: *const VirtualSection,
        absolute_address: usize,
        size: usize,
    ) OutputError!usize {
        try validateScalarByteCount(size);
        var value: usize = 0;
        var index: usize = 0;
        while (index < size) : (index += 1) {
            const address = try addUsize(absolute_address, index);
            const location = try self.sectionLocationFromAbsolute(address, true);
            const byte = try self.sections.items[location.section_index].readVisibleByte(location.relative_address) orelse return error.InvalidAddress;
            value |= @as(usize, byte) << @intCast(index * 8);
        }
        return value;
    }

    fn loadBytes(
        self: *const VirtualSection,
        allocator: Allocator,
        absolute_address: usize,
        size: usize,
    ) OutputError![]u8 {
        const bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);

        for (bytes, 0..) |*byte, index| {
            const address = try addUsize(absolute_address, index);
            const location = try self.sectionLocationFromAbsolute(address, true);
            byte.* = try self.sections.items[location.section_index].readVisibleByte(location.relative_address) orelse return error.InvalidAddress;
        }
        return bytes;
    }

    fn validateStoreRange(self: *const VirtualSection, absolute_address: usize, size: usize) OutputError!void {
        var index: usize = 0;
        while (index < size) : (index += 1) {
            const address = try addUsize(absolute_address, index);
            const location = try self.sectionLocationFromAbsolute(address, true);
            if (location.section_index >= self.sections.items.len) return error.InvalidAddress;
        }
    }

    fn storeByteAt(
        self: *VirtualSection,
        allocator: Allocator,
        absolute_address: usize,
        byte: u8,
    ) OutputError!void {
        const location = try self.sectionLocationFromAbsolute(absolute_address, true);
        try self.sections.items[location.section_index].storeByteAt(allocator, location.relative_address, byte);
    }

    fn storeBytesAt(
        self: *VirtualSection,
        allocator: Allocator,
        absolute_address: usize,
        bytes: []const u8,
    ) OutputError!void {
        if (bytes.len == 0) return;
        try self.validateStoreRange(absolute_address, bytes.len);

        for (bytes, 0..) |_, index| {
            const address = try addUsize(absolute_address, index);
            const location = try self.sectionLocationFromAbsolute(address, true);
            const section = &self.sections.items[location.section_index];
            if (location.relative_address >= section.bytes.items.len) {
                try section.ensurePendingReserveCapacity(allocator);
            }
        }

        for (bytes, 0..) |_, index| {
            const address = try addUsize(absolute_address, index);
            const location = try self.sectionLocationFromAbsolute(address, true);
            const section = &self.sections.items[location.section_index];
            if (location.relative_address >= section.bytes.items.len) {
                section.materializePendingReserveAssumeCapacity();
            }
        }

        for (bytes, 0..) |byte, index| {
            const address = try addUsize(absolute_address, index);
            const location = try self.sectionLocationFromAbsolute(address, true);
            self.sections.items[location.section_index].bytes.items[location.relative_address] = byte;
        }
    }

    fn defineLabel(
        self: *VirtualSection,
        allocator: Allocator,
        name: []const u8,
        absolute_address: usize,
    ) Allocator.Error!void {
        const key = try allocator.dupe(u8, name);
        errdefer allocator.free(key);

        const entry = try self.labels.getOrPut(key);
        if (entry.found_existing) {
            allocator.free(key);
        }
        entry.value_ptr.* = absolute_address;
    }

    fn finalizedBytes(self: *const VirtualSection, allocator: Allocator) Allocator.Error![]u8 {
        var finalized: std.ArrayList(u8) = .empty;
        defer finalized.deinit(allocator);

        for (self.sections.items) |section| {
            if (section.bytes.items.len == 0) continue;
            if (section.file_offset > finalized.items.len) {
                try finalized.appendNTimes(allocator, 0, section.file_offset - finalized.items.len);
            }
            try finalized.appendSlice(allocator, section.bytes.items);
        }

        return finalized.toOwnedSlice(allocator);
    }

    fn currentSection(self: *const VirtualSection) *const Section {
        return &self.sections.items[self.current_section_index];
    }

    fn currentSectionMut(self: *VirtualSection) *Section {
        return &self.sections.items[self.current_section_index];
    }

    fn sectionLocationFromAbsolute(
        self: *const VirtualSection,
        absolute_address: usize,
        include_pending_reserve: bool,
    ) OutputError!struct { section_index: usize, relative_address: usize } {
        for (self.sections.items, 0..) |section, index| {
            const start = section.base_address;
            const end = if (include_pending_reserve)
                try section.position()
            else
                try section.initializedPosition();

            if (absolute_address < start or absolute_address >= end) continue;
            return .{
                .section_index = index,
                .relative_address = absolute_address - start,
            };
        }
        return error.InvalidAddress;
    }

    fn trimTrailingReserve(self: *VirtualSection) void {
        var index = self.current_section_index + 1;
        while (index > 0) {
            index -= 1;
            const section = &self.sections.items[index];
            section.trimPendingReserve();
            if (section.committedLen() != 0 or index == 0) break;
        }
    }
};

/// Output-domain backend for the current main assembler.
///
/// It now models:
/// - main output sections with `org` vs `section` trailing-reserve rules
/// - a single active virtual section with reopen-by-label support
/// - runtime snapshots that distinguish effective address/origin from file-position symbols
pub const OutputBuffer = struct {
    allocator: Allocator,
    sections: std.ArrayList(Section) = .empty,
    current_section_index: usize = 0,
    virtual_sections: std.ArrayList(VirtualSection) = .empty,
    current_virtual_index: ?usize = null,
    virtual_index_stack: std.ArrayList(?usize) = .empty,

    pub fn init(allocator: Allocator) Allocator.Error!OutputBuffer {
        var output = OutputBuffer{
            .allocator = allocator,
        };
        errdefer output.deinit();

        try output.sections.append(allocator, Section.init(0, null, 0));
        return output;
    }

    pub fn deinit(self: *OutputBuffer) void {
        self.releaseStorage();
        self.* = undefined;
    }

    pub fn reset(self: *OutputBuffer) Allocator.Error!void {
        self.releaseStorage();
        self.sections = .empty;
        self.virtual_sections = .empty;
        self.current_section_index = 0;
        self.current_virtual_index = null;
        self.virtual_index_stack = .empty;
        try self.sections.append(self.allocator, Section.init(0, null, 0));
    }

    pub fn materializeAllPendingReserves(self: *OutputBuffer) OutputWriteError!void {
        for (self.sections.items) |*section| {
            if (section.pending_reserve > 0) {
                try section.materializePendingReserve(self.allocator);
            }
        }
    }

    pub fn setOrigin(self: *OutputBuffer, origin: usize) OutputWriteError!void {
        if (self.sections.items.len == 1 and
            self.current_section_index == 0 and
            self.current_virtual_index == null and
            self.currentSection().committedLen() == 0 and
            self.currentSection().current_offset == 0 and
            self.currentSection().pending_reserve == 0)
        {
            self.currentSectionMut().base_address = origin;
            return;
        }

        try self.setOriginWithExpression(origin, null);
    }

    pub fn setOriginWithExpression(
        self: *OutputBuffer,
        origin: usize,
        expression: ?[]const u8,
    ) OutputWriteError!void {
        const file_offset = try self.currentFileOffset();
        const owned_expression = try dupeOptionalText(self.allocator, expression);
        errdefer if (owned_expression) |text| self.allocator.free(text);

        // Reserved-output areas keep RES/RB as uninitialized output
        // state. `org` changes the logical address base, but it must not
        // immediately turn a trailing reserve into raw zero bytes; a later
        // initialized write at this file position is what makes the gap real.
        try self.sections.append(self.allocator, Section.init(origin, owned_expression, file_offset));
        self.current_section_index = self.sections.items.len - 1;
    }

    pub fn createSectionWithExpression(
        self: *OutputBuffer,
        base: usize,
        expression: ?[]const u8,
    ) OutputWriteError!void {
        self.trimTrailingReserve();
        const file_offset = try self.actualFileSize();
        const owned_expression = try dupeOptionalText(self.allocator, expression);
        errdefer if (owned_expression) |text| self.allocator.free(text);

        try self.sections.append(self.allocator, Section.init(base, owned_expression, file_offset));
        self.current_section_index = self.sections.items.len - 1;
    }

    pub fn createVirtual(
        self: *OutputBuffer,
        offset: usize,
        expression: ?[]const u8,
        output_extension: ?[]const u8,
    ) Allocator.Error!void {
        try self.virtual_index_stack.append(self.allocator, self.current_virtual_index);
        errdefer self.rollbackVirtualIndexStackPush();

        var virtual_section = try VirtualSection.init(
            self.allocator,
            offset,
            expression,
            output_extension,
        );
        errdefer virtual_section.deinit(self.allocator);

        try self.virtual_sections.append(self.allocator, virtual_section);
        virtual_section = undefined;
        self.current_virtual_index = self.virtual_sections.items.len - 1;
    }

    pub fn setVirtualOriginWithExpression(
        self: *OutputBuffer,
        origin: usize,
        expression: ?[]const u8,
    ) OutputError!void {
        var section = self.currentVirtualSectionMut() orelse return error.InvalidAddress;
        try section.setOriginWithExpression(self.allocator, origin, expression);
    }

    pub fn createVirtualSectionWithExpression(
        self: *OutputBuffer,
        base: usize,
        expression: ?[]const u8,
    ) OutputError!void {
        var section = self.currentVirtualSectionMut() orelse return error.InvalidAddress;
        try section.createSectionWithExpression(self.allocator, base, expression);
    }

    fn rollbackVirtualIndexStackPush(self: *OutputBuffer) void {
        std.debug.assert(self.virtual_index_stack.items.len != 0);
        self.virtual_index_stack.items.len -= 1;
    }

    pub fn endVirtual(self: *OutputBuffer) void {
        self.current_virtual_index = self.virtual_index_stack.pop() orelse null;
    }

    pub fn restartOut(self: *OutputBuffer, base: usize) Allocator.Error!void {
        self.releaseMainStorage();
        self.sections = .empty;
        self.current_section_index = 0;
        self.current_virtual_index = null;
        self.virtual_index_stack.clearRetainingCapacity();
        try self.sections.append(self.allocator, Section.init(base, null, 0));
    }

    pub fn defineVirtualLabel(
        self: *OutputBuffer,
        name: []const u8,
        absolute_address: usize,
    ) (Allocator.Error || error{InvalidInstruction})!void {
        var section = self.currentVirtualSectionMut() orelse return error.InvalidInstruction;
        try section.defineLabel(self.allocator, name, absolute_address);
    }

    pub fn findVirtualLabel(self: *const OutputBuffer, name: []const u8) ?VirtualLabelRef {
        var index = self.virtual_sections.items.len;
        while (index > 0) {
            index -= 1;
            const section = &self.virtual_sections.items[index];
            if (section.labels.get(name)) |absolute_address| {
                return .{
                    .index = index,
                    .absolute_address = absolute_address,
                };
            }
        }
        return null;
    }

    pub fn resolveVirtualLabel(self: *const OutputBuffer, name: []const u8) ?VirtualLabelRef {
        return self.findVirtualLabel(name);
    }

    pub fn reopenVirtualByLabel(self: *OutputBuffer, name: []const u8) bool {
        const resolved = self.resolveVirtualLabel(name) orelse return false;
        self.current_virtual_index = resolved.index;
        return true;
    }

    pub fn emitByte(self: *OutputBuffer, value: u8) OutputWriteError!void {
        if (self.currentVirtualSectionMut()) |section| {
            return section.writeByte(self.allocator, value);
        }
        return self.currentSectionMut().writeByte(self.allocator, value);
    }

    pub fn emitBytes(self: *OutputBuffer, values: []const u8) OutputWriteError!void {
        if (values.len == 0) return;
        if (self.currentVirtualSectionMut()) |section| {
            return section.writeBytes(self.allocator, values);
        }
        return self.currentSectionMut().writeBytes(self.allocator, values);
    }

    pub fn emitValueLe(self: *OutputBuffer, value: usize, width: usize) OutputWriteError!void {
        if (width == 0) return error.OutputOverflow;
        if (width < @sizeOf(usize)) {
            const value_mask = (@as(usize, 1) << @intCast(width * 8)) - 1;
            const extension_mask = ~value_mask;
            const extension_bits = value & extension_mask;
            if (extension_bits != 0 and extension_bits != extension_mask) return error.OutputOverflow;
        }

        const bytes = try self.allocator.alloc(u8, width);
        defer self.allocator.free(bytes);

        for (bytes, 0..) |*byte, index| {
            byte.* = if (index < @sizeOf(usize))
                @truncate(value >> @intCast(index * 8))
            else
                0;
        }

        try self.emitBytes(bytes);
    }

    pub fn emitF32Le(self: *OutputBuffer, value: f64) OutputWriteError!void {
        const narrowed: f32 = @floatCast(value);
        const bits: u32 = @bitCast(narrowed);
        return self.emitValueLe(bits, 4);
    }

    pub fn emitF64Le(self: *OutputBuffer, value: f64) OutputWriteError!void {
        const bits: u64 = @bitCast(value);
        return self.emitValueLe(bits, 8);
    }

    pub fn reserveBytes(self: *OutputBuffer, count: usize) OutputWriteError!void {
        if (count == 0) return;
        if (self.currentVirtualSectionMut()) |section| {
            return section.reserveBytes(count);
        }
        return self.currentSectionMut().reserveBytes(count);
    }

    pub fn currentVirtualIndex(self: *const OutputBuffer) ?usize {
        return self.current_virtual_index;
    }

    pub fn currentMainAreaIndex(self: *const OutputBuffer) usize {
        return self.current_section_index;
    }

    pub fn mainAreaCount(self: *const OutputBuffer) usize {
        return self.sections.items.len;
    }

    pub fn mainAreaView(self: *const OutputBuffer, index: usize) OutputError!MainSectionView {
        if (index >= self.sections.items.len) return error.InvalidAddress;
        const section = &self.sections.items[index];
        return .{
            .index = index,
            .base_address = section.base_address,
            .file_offset = section.file_offset,
            .bytes = section.bytes.items,
        };
    }

    pub fn latestVirtualIndex(self: *const OutputBuffer) ?usize {
        if (self.virtual_sections.items.len == 0) return null;
        return self.virtual_sections.items.len - 1;
    }

    pub fn currentOrLatestVirtualIndex(self: *const OutputBuffer) ?usize {
        return self.current_virtual_index orelse self.latestVirtualIndex();
    }

    pub fn virtualOrigin(self: *const OutputBuffer, index: usize) OutputError!usize {
        const section = try self.virtualSectionAt(index);
        return section.origin();
    }

    pub fn virtualLength(self: *const OutputBuffer, index: usize) OutputError!usize {
        const section = try self.virtualSectionAt(index);
        return try section.fileOffset();
    }

    pub fn mainAreaLength(self: *const OutputBuffer, index: usize) OutputError!usize {
        if (index >= self.sections.items.len) return error.InvalidAddress;
        return try self.sections.items[index].futureFileLen();
    }

    pub fn loadNFromCurrentArea(
        self: *const OutputBuffer,
        absolute_address: usize,
        size: usize,
    ) OutputError!usize {
        try validateScalarByteCount(size);
        const location = try self.sectionLocationFromAbsolute(absolute_address, true);
        const section = &self.sections.items[location.section_index];

        const end, const overflow = @addWithOverflow(location.relative_address, size);
        if (overflow != 0 or end > try section.futureFileLen()) return error.InvalidAddress;

        var value: usize = 0;
        var index: usize = 0;
        while (index < size) : (index += 1) {
            const target = try addUsize(location.relative_address, index);
            const byte = try section.readVisibleByte(target) orelse return error.InvalidAddress;
            value |= @as(usize, byte) << @intCast(index * 8);
        }
        return value;
    }

    pub fn loadNFromMainAreaIndex(
        self: *const OutputBuffer,
        section_index: usize,
        absolute_address: usize,
        size: usize,
    ) OutputError!usize {
        try validateScalarByteCount(size);
        const location = try self.sectionLocationFromAbsoluteInSection(section_index, absolute_address, true);
        const section = &self.sections.items[location.section_index];

        const end, const overflow = @addWithOverflow(location.relative_address, size);
        if (overflow != 0 or end > try section.futureFileLen()) return error.InvalidAddress;

        var value: usize = 0;
        var index: usize = 0;
        while (index < size) : (index += 1) {
            const target = try addUsize(location.relative_address, index);
            const byte = try section.readVisibleByte(target) orelse return error.InvalidAddress;
            value |= @as(usize, byte) << @intCast(index * 8);
        }
        return value;
    }

    pub fn loadBytesFromCurrentArea(
        self: *const OutputBuffer,
        allocator: Allocator,
        absolute_address: usize,
        size: usize,
    ) OutputError![]u8 {
        const location = try self.sectionLocationFromAbsolute(absolute_address, true);
        const section = &self.sections.items[location.section_index];

        const end, const overflow = @addWithOverflow(location.relative_address, size);
        if (overflow != 0 or end > try section.futureFileLen()) return error.InvalidAddress;

        const bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);

        for (bytes, 0..) |*byte, index| {
            const target = try addUsize(location.relative_address, index);
            byte.* = try section.readVisibleByte(target) orelse return error.InvalidAddress;
        }
        return bytes;
    }

    pub fn loadBytesFromMainAreaIndex(
        self: *const OutputBuffer,
        allocator: Allocator,
        section_index: usize,
        absolute_address: usize,
        size: usize,
    ) OutputError![]u8 {
        const location = try self.sectionLocationFromAbsoluteInSection(section_index, absolute_address, true);
        const section = &self.sections.items[location.section_index];

        const end, const overflow = @addWithOverflow(location.relative_address, size);
        if (overflow != 0 or end > try section.futureFileLen()) return error.InvalidAddress;

        const bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);

        for (bytes, 0..) |*byte, index| {
            const target = try addUsize(location.relative_address, index);
            byte.* = try section.readVisibleByte(target) orelse return error.InvalidAddress;
        }
        return bytes;
    }

    pub fn storeNToCurrentArea(
        self: *OutputBuffer,
        absolute_address: usize,
        value: usize,
        size: usize,
    ) OutputError!void {
        try validateScalarByteCount(size);
        const location = try self.sectionLocationFromAbsolute(absolute_address, true);
        const section = &self.sections.items[location.section_index];
        var bytes: [@sizeOf(usize)]u8 = undefined;
        const scalar = bytes[0..size];
        writeScalarLe(scalar, value);
        try section.storeBytesAt(self.allocator, location.relative_address, scalar);
    }

    pub fn storeNToMainAreaIndex(
        self: *OutputBuffer,
        section_index: usize,
        absolute_address: usize,
        value: usize,
        size: usize,
    ) OutputError!void {
        try validateScalarByteCount(size);
        const location = try self.sectionLocationFromAbsoluteInSection(section_index, absolute_address, true);
        const section = &self.sections.items[location.section_index];
        var bytes: [@sizeOf(usize)]u8 = undefined;
        const scalar = bytes[0..size];
        writeScalarLe(scalar, value);
        try section.storeBytesAt(self.allocator, location.relative_address, scalar);
    }

    pub fn storeBytesToCurrentArea(
        self: *OutputBuffer,
        absolute_address: usize,
        bytes: []const u8,
    ) OutputError!void {
        if (bytes.len == 0) return;
        const location = try self.sectionLocationFromAbsolute(absolute_address, true);
        try self.sections.items[location.section_index].validateVisibleRange(location.relative_address, bytes.len);
        try self.sections.items[location.section_index].storeBytesAt(
            self.allocator,
            location.relative_address,
            bytes,
        );
    }

    pub fn storeBytesToMainAreaIndex(
        self: *OutputBuffer,
        section_index: usize,
        absolute_address: usize,
        bytes: []const u8,
    ) OutputError!void {
        if (bytes.len == 0) return;
        const location = try self.sectionLocationFromAbsoluteInSection(section_index, absolute_address, true);
        try self.sections.items[location.section_index].validateVisibleRange(location.relative_address, bytes.len);
        try self.sections.items[location.section_index].storeBytesAt(
            self.allocator,
            location.relative_address,
            bytes,
        );
    }

    pub fn loadNFromFileOffset(
        self: *const OutputBuffer,
        file_offset: usize,
        size: usize,
    ) OutputError!usize {
        try validateScalarByteCount(size);
        var value: usize = 0;
        var index: usize = 0;
        while (index < size) : (index += 1) {
            const target = try addUsize(file_offset, index);
            const location = try self.sectionLocationFromFileOffset(target);
            value |= @as(usize, self.sections.items[location.section_index].bytes.items[location.relative_address]) << @intCast(index * 8);
        }
        return value;
    }

    pub fn loadBytesFromFileOffset(
        self: *const OutputBuffer,
        allocator: Allocator,
        file_offset: usize,
        size: usize,
    ) OutputError![]u8 {
        try self.validateFileOffsetRange(file_offset, size);

        const bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);

        for (bytes, 0..) |*byte, index| {
            const target = try addUsize(file_offset, index);
            const location = try self.sectionLocationFromFileOffset(target);
            byte.* = self.sections.items[location.section_index].bytes.items[location.relative_address];
        }
        return bytes;
    }

    pub fn storeNToFileOffset(
        self: *OutputBuffer,
        file_offset: usize,
        value: usize,
        size: usize,
    ) OutputError!void {
        try validateScalarByteCount(size);
        try self.validateFileOffsetRange(file_offset, size);
        var index: usize = 0;
        while (index < size) : (index += 1) {
            const target = try addUsize(file_offset, index);
            const location = try self.sectionLocationFromFileOffset(target);
            self.sections.items[location.section_index].bytes.items[location.relative_address] =
                @truncate(value >> @intCast(index * 8));
        }
    }

    pub fn storeBytesToFileOffset(
        self: *OutputBuffer,
        file_offset: usize,
        bytes: []const u8,
    ) OutputError!void {
        try self.validateFileOffsetRange(file_offset, bytes.len);
        for (bytes, 0..) |byte, index| {
            const target = try addUsize(file_offset, index);
            const location = try self.sectionLocationFromFileOffset(target);
            self.sections.items[location.section_index].bytes.items[location.relative_address] = byte;
        }
    }

    pub fn mainAreaIndexForFileOffset(
        self: *const OutputBuffer,
        file_offset: usize,
    ) OutputError!usize {
        const location = try self.sectionLocationFromFileOffset(file_offset);
        return location.section_index;
    }

    pub fn loadNFromVirtualIndex(
        self: *const OutputBuffer,
        index: usize,
        absolute_address: usize,
        size: usize,
    ) OutputError!usize {
        const section = try self.virtualSectionAt(index);
        return section.loadN(absolute_address, size);
    }

    pub fn loadBytesFromVirtualIndex(
        self: *const OutputBuffer,
        allocator: Allocator,
        index: usize,
        absolute_address: usize,
        size: usize,
    ) OutputError![]u8 {
        const section = try self.virtualSectionAt(index);
        return section.loadBytes(allocator, absolute_address, size);
    }

    pub fn storeNToVirtualIndex(
        self: *OutputBuffer,
        index: usize,
        absolute_address: usize,
        value: usize,
        size: usize,
    ) OutputError!void {
        try validateScalarByteCount(size);
        const section = try self.virtualSectionMutAt(index);
        var bytes: [@sizeOf(usize)]u8 = undefined;
        const scalar = bytes[0..size];
        writeScalarLe(scalar, value);
        try section.storeBytesAt(self.allocator, absolute_address, scalar);
    }

    pub fn storeBytesToVirtualIndex(
        self: *OutputBuffer,
        index: usize,
        absolute_address: usize,
        bytes: []const u8,
    ) OutputError!void {
        const section = try self.virtualSectionMutAt(index);
        try section.storeBytesAt(self.allocator, absolute_address, bytes);
    }

    pub fn finalize(self: *const OutputBuffer, allocator: Allocator) Allocator.Error![]u8 {
        var finalized: std.ArrayList(u8) = .empty;
        defer finalized.deinit(allocator);

        for (self.sections.items) |section| {
            if (section.bytes.items.len == 0) continue;
            if (section.file_offset > finalized.items.len) {
                try finalized.appendNTimes(allocator, 0, section.file_offset - finalized.items.len);
            }
            try finalized.appendSlice(allocator, section.bytes.items);
        }

        return finalized.toOwnedSlice(allocator);
    }

    pub fn finalizeForExtension(
        self: *const OutputBuffer,
        allocator: Allocator,
        extension: []const u8,
    ) Allocator.Error![]u8 {
        if (try self.extraOutputForExtension(allocator, extension)) |bytes| return bytes;
        return self.finalize(allocator);
    }

    pub fn extraOutputFiles(self: *const OutputBuffer, allocator: Allocator) OutputWriteError![]ExtraOutputFile {
        var files: std.ArrayList(ExtraOutputFile) = .empty;
        errdefer files.deinit(allocator);
        errdefer deinitExtraOutputFileItems(allocator, files.items);

        for (self.virtual_sections.items) |section| {
            const section_extension = section.output_extension orelse continue;
            const section_bytes = try section.finalizedBytes(allocator);
            defer allocator.free(section_bytes);

            for (files.items) |*file| {
                if (!std.mem.eql(u8, file.extension, section_extension)) continue;

                const current_len = file.bytes.len;
                const next_len, const overflow = @addWithOverflow(current_len, section_bytes.len);
                if (overflow != 0) return error.OutputOverflow;
                file.bytes = try allocator.realloc(file.bytes, next_len);
                @memcpy(file.bytes[current_len..], section_bytes);
                break;
            } else {
                const owned_extension = try allocator.dupe(u8, section_extension);
                var file_appended = false;
                errdefer if (!file_appended) allocator.free(owned_extension);
                const owned_bytes = try allocator.dupe(u8, section_bytes);
                errdefer if (!file_appended) allocator.free(owned_bytes);
                try files.append(allocator, .{
                    .extension = owned_extension,
                    .bytes = owned_bytes,
                });
                file_appended = true;
            }
        }

        return files.toOwnedSlice(allocator);
    }

    pub fn currentAddress(self: *const OutputBuffer) OutputWriteError!usize {
        return try self.currentSection().position();
    }

    pub fn currentOrigin(self: *const OutputBuffer) usize {
        return self.currentSection().base_address;
    }

    pub fn currentFileOffset(self: *const OutputBuffer) OutputWriteError!usize {
        return try addUsize(
            self.currentSection().file_offset,
            try self.currentSection().futureFileLen(),
        );
    }

    pub fn actualFileSize(self: *const OutputBuffer) OutputWriteError!usize {
        var total: usize = 0;
        for (self.sections.items) |section| {
            if (section.bytes.items.len == 0) continue;
            const end = try addUsize(section.file_offset, section.committedLen());
            if (end > total) total = end;
        }
        return total;
    }

    pub fn currentUninitializedBase(self: *const OutputBuffer) OutputWriteError!usize {
        return try self.currentSection().uninitializedBase();
    }

    pub fn currentVirtualAddress(self: *const OutputBuffer) OutputWriteError!?usize {
        const section = self.currentVirtualSection() orelse return null;
        return try section.position();
    }

    pub fn currentVirtualOrigin(self: *const OutputBuffer) ?usize {
        const section = self.currentVirtualSection() orelse return null;
        return section.origin();
    }

    pub fn currentEffectiveAddress(self: *const OutputBuffer) OutputWriteError!usize {
        if (try self.currentVirtualAddress()) |address| return address;
        return try self.currentAddress();
    }

    pub fn currentEffectiveOrigin(self: *const OutputBuffer) usize {
        if (self.currentVirtualOrigin()) |origin| return origin;
        return self.currentOrigin();
    }

    pub fn currentOriginExpression(self: *const OutputBuffer) ?[]const u8 {
        return self.currentSection().base_expression;
    }

    pub fn currentAddressExpression(self: *const OutputBuffer) ?[]const u8 {
        if (self.currentSection().current_offset == 0) return self.currentOriginExpression();
        return null;
    }

    pub fn currentVirtualOriginExpression(self: *const OutputBuffer) ?[]const u8 {
        const section = self.currentVirtualSection() orelse return null;
        return section.originExpression();
    }

    pub fn currentVirtualAddressExpression(self: *const OutputBuffer) ?[]const u8 {
        const section = self.currentVirtualSection() orelse return null;
        return section.addressExpression();
    }

    pub fn currentEffectiveAddressExpression(self: *const OutputBuffer) ?[]const u8 {
        if (self.currentVirtualIndex() != null) return self.currentVirtualAddressExpression();
        return self.currentAddressExpression();
    }

    pub fn currentEffectiveOriginExpression(self: *const OutputBuffer) ?[]const u8 {
        if (self.currentVirtualIndex() != null) return self.currentVirtualOriginExpression();
        return self.currentOriginExpression();
    }

    pub fn runtimeSnapshot(self: *const OutputBuffer, line_number: usize) OutputWriteError!RuntimeSnapshot {
        if (self.currentVirtualSection()) |section| {
            return .{
                .current_address = try section.position(),
                .current_origin = section.origin(),
                .current_address_expression = section.addressExpression(),
                .current_origin_expression = section.originExpression(),
                .file_offset = try section.fileOffset(),
                .file_size = try section.actualFileSize(),
                .uninitialized_base = try section.uninitializedBase(),
                .line_number = line_number,
            };
        }

        return .{
            .current_address = try self.currentEffectiveAddress(),
            .current_origin = self.currentEffectiveOrigin(),
            .current_address_expression = self.currentEffectiveAddressExpression(),
            .current_origin_expression = self.currentEffectiveOriginExpression(),
            .file_offset = try self.currentFileOffset(),
            .file_size = try self.actualFileSize(),
            .uninitialized_base = try self.currentUninitializedBase(),
            .line_number = line_number,
        };
    }

    fn currentSection(self: *const OutputBuffer) *const Section {
        return &self.sections.items[self.current_section_index];
    }

    fn currentSectionMut(self: *OutputBuffer) *Section {
        return &self.sections.items[self.current_section_index];
    }

    fn currentVirtualSection(self: *const OutputBuffer) ?*const VirtualSection {
        const index = self.current_virtual_index orelse return null;
        return &self.virtual_sections.items[index];
    }

    fn currentVirtualSectionMut(self: *OutputBuffer) ?*VirtualSection {
        const index = self.current_virtual_index orelse return null;
        return &self.virtual_sections.items[index];
    }

    fn virtualSectionAt(self: *const OutputBuffer, index: usize) OutputError!*const VirtualSection {
        if (index >= self.virtual_sections.items.len) return error.InvalidAddress;
        return &self.virtual_sections.items[index];
    }

    fn virtualSectionMutAt(self: *OutputBuffer, index: usize) OutputError!*VirtualSection {
        if (index >= self.virtual_sections.items.len) return error.InvalidAddress;
        return &self.virtual_sections.items[index];
    }

    fn sectionLocationFromAbsolute(
        self: *const OutputBuffer,
        absolute_address: usize,
        include_pending_reserve: bool,
    ) OutputError!struct { section_index: usize, relative_address: usize } {
        for (self.sections.items, 0..) |section, index| {
            const start = section.base_address;
            const end = if (include_pending_reserve)
                try section.position()
            else
                try section.initializedPosition();

            if (absolute_address < start or absolute_address >= end) continue;
            return .{
                .section_index = index,
                .relative_address = absolute_address - start,
            };
        }
        return error.InvalidAddress;
    }

    fn sectionLocationFromAbsoluteInSection(
        self: *const OutputBuffer,
        section_index: usize,
        absolute_address: usize,
        include_pending_reserve: bool,
    ) OutputError!struct { section_index: usize, relative_address: usize } {
        if (section_index >= self.sections.items.len) return error.InvalidAddress;
        const section = &self.sections.items[section_index];
        const start = section.base_address;
        const end = if (include_pending_reserve)
            try section.position()
        else
            try section.initializedPosition();

        if (absolute_address < start or absolute_address >= end) return error.InvalidAddress;
        return .{
            .section_index = section_index,
            .relative_address = absolute_address - start,
        };
    }

    fn sectionLocationFromFileOffset(
        self: *const OutputBuffer,
        file_offset: usize,
    ) OutputError!struct { section_index: usize, relative_address: usize } {
        for (self.sections.items, 0..) |section, index| {
            if (file_offset < section.file_offset) continue;
            const relative_address = file_offset - section.file_offset;
            if (relative_address < section.committedLen()) {
                return .{
                    .section_index = index,
                    .relative_address = relative_address,
                };
            }
        }
        return error.InvalidAddress;
    }

    fn validateFileOffsetRange(self: *const OutputBuffer, file_offset: usize, size: usize) OutputError!void {
        var index: usize = 0;
        while (index < size) : (index += 1) {
            const target = try addUsize(file_offset, index);
            const location = try self.sectionLocationFromFileOffset(target);
            if (location.section_index >= self.sections.items.len) return error.InvalidAddress;
        }
    }

    fn trimTrailingReserve(self: *OutputBuffer) void {
        var index = self.current_section_index + 1;
        while (index > 0) {
            index -= 1;
            const section = &self.sections.items[index];
            section.trimPendingReserve();
            if (section.committedLen() != 0 or index == 0) break;
        }
    }

    fn releaseStorage(self: *OutputBuffer) void {
        self.releaseMainStorage();

        for (self.virtual_sections.items) |*section| section.deinit(self.allocator);
        self.virtual_sections.deinit(self.allocator);
        self.virtual_index_stack.deinit(self.allocator);
    }

    fn releaseMainStorage(self: *OutputBuffer) void {
        for (self.sections.items) |*section| section.deinit(self.allocator);
        self.sections.deinit(self.allocator);
    }

    fn extraOutputForExtension(
        self: *const OutputBuffer,
        allocator: Allocator,
        extension: []const u8,
    ) Allocator.Error!?[]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);

        for (self.virtual_sections.items) |section| {
            const section_extension = section.output_extension orelse continue;
            if (!std.mem.eql(u8, section_extension, extension)) continue;
            const section_bytes = try section.finalizedBytes(allocator);
            defer allocator.free(section_bytes);
            try bytes.appendSlice(allocator, section_bytes);
        }

        if (bytes.items.len == 0) return null;
        return @as(?[]u8, try bytes.toOwnedSlice(allocator));
    }
};

pub fn deinitExtraOutputFiles(allocator: Allocator, files: []ExtraOutputFile) void {
    deinitExtraOutputFileItems(allocator, files);
    allocator.free(files);
}

fn deinitExtraOutputFileItems(allocator: Allocator, files: []const ExtraOutputFile) void {
    for (files) |file| {
        allocator.free(file.extension);
        allocator.free(file.bytes);
    }
}

fn dupeOptionalText(allocator: Allocator, text: ?[]const u8) Allocator.Error!?[]const u8 {
    if (text) |value| return @as(?[]const u8, try allocator.dupe(u8, value));
    return null;
}

test "OutputBuffer keeps trailing reserve out of finalized file" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitBytes("MZ");
    try output.reserveBytes(2);

    const finalized = try output.finalize(testing.allocator);
    defer testing.allocator.free(finalized);

    try testing.expectEqualSlices(u8, "MZ", finalized);
}

test "OutputBuffer fills crossed reserve gaps with zeros" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitByte('A');
    try output.reserveBytes(3);
    try output.emitByte(4);
    try output.emitByte('B');

    const finalized = try output.finalize(testing.allocator);
    defer testing.allocator.free(finalized);

    try testing.expectEqualSlices(
        u8,
        &.{ 'A', 0, 0, 0, 4, 'B' },
        finalized,
    );
}

test "OutputBuffer runtime snapshot tracks reserve base while gap is active" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitByte(0);
    try output.emitByte(1);
    try output.emitByte(2);
    try output.reserveBytes(2);

    const snapshot = try output.runtimeSnapshot(5);

    try testing.expectEqual(@as(usize, 5), snapshot.current_address);
    try testing.expectEqual(@as(usize, 5), snapshot.file_offset);
    try testing.expectEqual(@as(usize, 3), snapshot.file_size);
    try testing.expectEqual(@as(usize, 3), snapshot.uninitialized_base);
    try testing.expectEqual(@as(usize, 5), snapshot.line_number);
}

test "OutputBuffer emits wider little-endian integer widths with zero extension" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitValueLe(0x1234, 6);
    try output.emitValueLe(0x55AA, 10);

    const finalized = try output.finalize(testing.allocator);
    defer testing.allocator.free(finalized);

    try testing.expectEqualSlices(
        u8,
        &.{
            0x34, 0x12, 0x00, 0x00, 0x00, 0x00,
            0xAA, 0x55, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        },
        finalized,
    );
}

test "OutputBuffer org preserves trailing reserve until later initialized output needs it" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitByte('A');
    try output.reserveBytes(2);
    try output.createSectionWithExpression(0x10, "10h");
    try output.emitByte('B');
    try output.reserveBytes(2);
    try output.setOriginWithExpression(0x20, "20h");
    try output.emitByte('C');

    const finalized = try output.finalize(testing.allocator);
    defer testing.allocator.free(finalized);

    try testing.expectEqualSlices(u8, &.{ 'A', 'B', 0, 0, 'C' }, finalized);
}

test "OutputBuffer section can still trim reserve across an empty org area" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitByte('A');
    try output.reserveBytes(0x1000);
    try output.setOriginWithExpression(0x400000, "400000h");
    try output.createSectionWithExpression(0x200, "200h");
    try output.emitByte('B');

    const finalized = try output.finalize(testing.allocator);
    defer testing.allocator.free(finalized);

    try testing.expectEqualSlices(u8, "AB", finalized);
    try testing.expectEqual(@as(usize, 2), try output.actualFileSize());
}

test "OutputBuffer virtual writes stay out of main output and drive effective snapshots" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitByte('M');
    try output.createVirtual(0x1000, "1000h", null);
    try output.emitByte(0x11);
    try output.reserveBytes(2);
    try output.emitByte(0x22);

    const snapshot = try output.runtimeSnapshot(7);
    output.endVirtual();

    const finalized = try output.finalize(testing.allocator);
    defer testing.allocator.free(finalized);

    try testing.expectEqualSlices(u8, "M", finalized);
    try testing.expectEqual(@as(usize, 0x1004), snapshot.current_address);
    try testing.expectEqual(@as(usize, 0x1000), snapshot.current_origin);
    try testing.expectEqual(@as(usize, 4), snapshot.file_offset);
    try testing.expectEqual(@as(usize, 4), snapshot.file_size);
}

test "OutputBuffer active virtual expressions do not fall back to main output expressions" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.setOriginWithExpression(0x40, "40h");
    try output.createVirtual(0x1000, null, null);

    const snapshot = try output.runtimeSnapshot(3);

    try testing.expectEqual(@as(?[]const u8, null), snapshot.current_address_expression);
    try testing.expectEqual(@as(?[]const u8, null), snapshot.current_origin_expression);
}

test "OutputBuffer current-area load and store treat sparse reserve as output gaps" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitByte('A');
    try output.reserveBytes(2);

    try testing.expectEqual(@as(usize, 0), try output.loadNFromCurrentArea(1, 2));

    try output.storeBytesToCurrentArea(1, &.{ 'B', 'C' });

    const finalized = try output.finalize(testing.allocator);
    defer testing.allocator.free(finalized);

    try testing.expectEqualSlices(u8, "ABC", finalized);
}

test "OutputBuffer store into committed prefix does not materialize trailing reserve" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitByte(0);
    try output.reserveBytes(0x100);
    try output.storeNToCurrentArea(0, 1, 1);
    try output.createSectionWithExpression(0x20, "20h");
    try output.emitByte(0x22);

    const finalized = try output.finalize(testing.allocator);
    defer testing.allocator.free(finalized);

    try testing.expectEqualSlices(u8, &.{ 0x01, 0x22 }, finalized);
}

test "OutputBuffer finalizes matching virtual-as binary extension output" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitBytes(&.{0xAA});

    try output.createVirtual(0, null, "bin");
    try output.emitBytes(&.{0x11});
    output.endVirtual();

    try output.createVirtual(0x1000, "1000h", "bin");
    try output.emitBytes(&.{0x22});
    output.endVirtual();

    const finalized = try output.finalizeForExtension(testing.allocator, "bin");
    defer testing.allocator.free(finalized);

    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22 }, finalized);
}

test "OutputBuffer restartOut preserves existing virtual extra outputs" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitByte(0xAA);
    try output.createVirtual(0, null, "bin");
    try output.emitByte(0x11);
    output.endVirtual();

    try output.restartOut(0);
    try output.emitByte(0xBB);

    const main = try output.finalize(testing.allocator);
    defer testing.allocator.free(main);
    try testing.expectEqualSlices(u8, &.{0xBB}, main);

    const extra = try output.finalizeForExtension(testing.allocator, "bin");
    defer testing.allocator.free(extra);
    try testing.expectEqualSlices(u8, &.{0x11}, extra);
}

test "OutputBuffer extraOutputFiles merges matching extensions and preserves distinct ones" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitBytes(&.{0xAA});

    try output.createVirtual(0, null, "bin");
    try output.emitBytes(&.{0x11});
    output.endVirtual();

    try output.createVirtual(0x1000, "1000h", "rom");
    try output.emitBytes(&.{0x22});
    output.endVirtual();

    try output.createVirtual(0x2000, "2000h", "bin");
    try output.emitBytes(&.{0x33});
    output.endVirtual();

    const files = try output.extraOutputFiles(testing.allocator);
    defer deinitExtraOutputFiles(testing.allocator, files);

    try testing.expectEqual(@as(usize, 2), files.len);

    for (files) |file| {
        if (std.mem.eql(u8, file.extension, "bin")) {
            try testing.expectEqualSlices(u8, &.{ 0x11, 0x33 }, file.bytes);
        } else if (std.mem.eql(u8, file.extension, "rom")) {
            try testing.expectEqualSlices(u8, &.{0x22}, file.bytes);
        } else {
            return error.UnexpectedResult;
        }
    }
}

fn extraOutputFilesAllocatorProbe(allocator: Allocator) !void {
    var output = try OutputBuffer.init(allocator);
    defer output.deinit();

    try output.createVirtual(0, null, "bin");
    try output.emitBytes(&.{0x11});
    output.endVirtual();

    try output.createVirtual(0x1000, "1000h", "rom");
    try output.emitBytes(&.{ 0x22, 0x33 });
    output.endVirtual();

    try output.createVirtual(0x2000, "2000h", "bin");
    try output.emitBytes(&.{0x44});
    output.endVirtual();

    const files = try output.extraOutputFiles(allocator);
    defer deinitExtraOutputFiles(allocator, files);

    try std.testing.expectEqual(@as(usize, 2), files.len);
}

test "OutputBuffer extraOutputFiles releases partial ownership across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        extraOutputFilesAllocatorProbe,
        .{},
    );
}

test "OutputBuffer size math reports overflow as layout overflow" {
    try std.testing.expectError(error.OutputOverflow, addUsize(std.math.maxInt(usize), 1));
}

test "OutputBuffer file-offset patching rewrites committed output bytes only" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitBytes(&.{ 0x00, 0x00 });
    try output.storeNToFileOffset(0, 0xBBAA, 2);

    const pair = try output.loadNFromFileOffset(0, 2);
    try testing.expectEqual(@as(usize, 0xBBAA), pair);

    const finalized = try output.finalize(testing.allocator);
    defer testing.allocator.free(finalized);

    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, finalized);
}

test "OutputBuffer file-offset byte loads validate full range before allocation" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitByte(0xAA);

    try testing.expectError(
        error.InvalidAddress,
        output.loadBytesFromFileOffset(testing.failing_allocator, 0, 2),
    );
}

test "OutputBuffer store failures do not partially mutate output state" {
    const testing = std.testing;

    var current = try OutputBuffer.init(testing.allocator);
    defer current.deinit();

    try current.emitByte('A');
    try current.reserveBytes(2);
    try testing.expectError(error.InvalidAddress, current.storeBytesToCurrentArea(2, &.{ 'B', 'C' }));

    const current_finalized = try current.finalize(testing.allocator);
    defer testing.allocator.free(current_finalized);
    try testing.expectEqualSlices(u8, "A", current_finalized);

    var by_file = try OutputBuffer.init(testing.allocator);
    defer by_file.deinit();

    try by_file.emitByte(0);
    try testing.expectError(error.InvalidAddress, by_file.storeNToFileOffset(0, 0xBBAA, 2));

    const by_file_finalized = try by_file.finalize(testing.allocator);
    defer testing.allocator.free(by_file_finalized);
    try testing.expectEqualSlices(u8, &.{0}, by_file_finalized);

    var virtual = try OutputBuffer.init(testing.allocator);
    defer virtual.deinit();

    try virtual.createVirtual(0, null, null);
    const area_index = virtual.currentVirtualIndex().?;
    try virtual.emitByte(0);
    try testing.expectError(error.InvalidAddress, virtual.storeNToVirtualIndex(area_index, 0, 0xBBAA, 2));
    try testing.expectEqual(@as(usize, 0), try virtual.loadNFromVirtualIndex(area_index, 0, 1));
}

test "OutputBuffer scalar main-area stores crossing pending reserve are OOM-atomic" {
    const testing = std.testing;

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var output = try OutputBuffer.init(failing.allocator());
    defer output.deinit();

    try output.emitByte('A');
    output.sections.items[0].bytes.shrinkAndFree(output.allocator, output.sections.items[0].bytes.items.len);
    try output.reserveBytes(2);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try testing.expectError(error.OutOfMemory, output.storeNToCurrentArea(0, 0x434258, 3));

    const finalized = try output.finalize(testing.allocator);
    defer testing.allocator.free(finalized);
    try testing.expectEqualSlices(u8, "A", finalized);
}

test "OutputBuffer scalar virtual stores crossing pending reserve are OOM-atomic" {
    const testing = std.testing;

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var output = try OutputBuffer.init(failing.allocator());
    defer output.deinit();

    try output.createVirtual(0, null, null);
    const area_index = output.currentVirtualIndex().?;
    try output.emitByte('A');
    output.virtual_sections.items[area_index].sections.items[0].bytes.shrinkAndFree(
        output.allocator,
        output.virtual_sections.items[area_index].sections.items[0].bytes.items.len,
    );
    try output.reserveBytes(2);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try testing.expectError(error.OutOfMemory, output.storeNToVirtualIndex(area_index, 0, 0x434258, 3));

    const bytes = try output.loadBytesFromVirtualIndex(testing.allocator, area_index, 0, 1);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "A", bytes);
}

test "OutputBuffer scalar load and store reject widths wider than usize" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.emitByte(0);

    try testing.expectError(error.InvalidAddress, output.loadNFromCurrentArea(0, @sizeOf(usize) + 1));
    try testing.expectError(error.InvalidAddress, output.storeNToCurrentArea(0, 0, @sizeOf(usize) + 1));
    try testing.expectError(error.InvalidAddress, output.loadNFromFileOffset(0, @sizeOf(usize) + 1));
    try testing.expectError(error.InvalidAddress, output.storeNToFileOffset(0, 0, @sizeOf(usize) + 1));

    try output.createVirtual(0, null, null);
    const area_index = output.currentVirtualIndex().?;
    try output.emitByte(0);

    try testing.expectError(error.InvalidAddress, output.loadNFromVirtualIndex(area_index, 0, @sizeOf(usize) + 1));
    try testing.expectError(error.InvalidAddress, output.storeNToVirtualIndex(area_index, 0, 0, @sizeOf(usize) + 1));
}

test "OutputBuffer reports overflow instead of build-mode-dependent main address wrap" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.setOrigin(std.math.maxInt(usize));
    try output.emitByte(0x11);

    try testing.expectError(error.OutputOverflow, output.currentEffectiveAddress());
    try testing.expectError(error.OutputOverflow, output.runtimeSnapshot(1));
}

test "OutputBuffer reports overflow instead of build-mode-dependent virtual address wrap" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.createVirtual(std.math.maxInt(usize), "max", null);
    try output.emitByte(0x11);

    try testing.expectError(error.OutputOverflow, output.currentEffectiveAddress());
    try testing.expectError(error.OutputOverflow, output.runtimeSnapshot(2));
}

test "OutputBuffer virtual store rejects addresses outside generated virtual data" {
    const testing = std.testing;

    var output = try OutputBuffer.init(testing.allocator);
    defer output.deinit();

    try output.createVirtual(0, null, null);
    const area_index = output.currentVirtualIndex().?;

    try testing.expectError(error.InvalidAddress, output.storeNToVirtualIndex(area_index, std.math.maxInt(usize), 0x11, 1));
    try testing.expectError(
        error.InvalidAddress,
        output.storeBytesToVirtualIndex(area_index, std.math.maxInt(usize), &.{ 0x22, 0x33 }),
    );
}
