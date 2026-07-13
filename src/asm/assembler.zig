const std = @import("std");

const symbols_mod = @import("../assembler/symbols.zig");
const state_mod = @import("../assembler/state.zig");
const output_mod = @import("../assembler/output_buffer.zig");
const expressions = @import("../assembler/expr.zig");

const Allocator = std.mem.Allocator;
const SymbolStore = symbols_mod.SymbolStore;
const State = state_mod.State;
const OutputBuffer = output_mod.OutputBuffer;

pub const AssembleError = Allocator.Error || error{
    CircularReference,
    DivisionByZero,
    ExpansionDepthExceeded,
    InvalidArgument,
    InvalidCharacter,
    InvalidInstruction,
    InvalidNumber,
    InvalidOperand,
    InvalidToken,
    MissingRegisterMetadata,
    OutputOverflow,
    UndefinedSymbol,
    UnexpectedEof,
    UnsupportedMnemonic,
    UnsupportedOperands,
};

const x86_encoder = @import("../x86_encoder/root.zig");
pub const X86BranchRelaxationDecision = x86_encoder.BranchRelaxationDecision;

const ListingEntry = struct {
    offset: usize,
    line: []const u8,
};

pub const Assembler = struct {
    allocator: Allocator,
    mode_bits: u8,
    symbols: SymbolStore,
    state: State,
    output: OutputBuffer,

    x86_branch_relaxation_cache: std.StringHashMap(X86BranchRelaxationDecision),
    x86_fixed_bytes_cache: std.StringHashMap([]const u8),

    listing_entries: std.ArrayListUnmanaged(ListingEntry),

    deferred_expressions: usize,
    max_passes: usize,
    pass_count: usize,
    converged_flag: bool,

    pub fn init(allocator: Allocator, mode_bits: u8) Allocator.Error!Assembler {
        var symbol_store = try SymbolStore.init(allocator);
        errdefer symbol_store.deinit();
        var assembler_state = try State.init(allocator);
        errdefer assembler_state.deinit();
        var output = try OutputBuffer.init(allocator);
        errdefer output.deinit();

        return .{
            .allocator = allocator,
            .mode_bits = mode_bits,
            .symbols = symbol_store,
            .state = assembler_state,
            .output = output,
            .x86_branch_relaxation_cache = std.StringHashMap(X86BranchRelaxationDecision).init(allocator),
            .x86_fixed_bytes_cache = std.StringHashMap([]const u8).init(allocator),
            .listing_entries = .empty,
            .deferred_expressions = 0,
            .max_passes = 100,
            .pass_count = 0,
            .converged_flag = false,
        };
    }

    pub fn deinit(self: *Assembler) void {
        self.clearBranchRelaxationCache();
        self.x86_branch_relaxation_cache.deinit();
        self.clearFixedBytesCache();
        self.x86_fixed_bytes_cache.deinit();
        for (self.listing_entries.items) |entry| self.allocator.free(entry.line);
        self.listing_entries.deinit(self.allocator);
        self.output.deinit();
        self.state.deinit();
        self.symbols.deinit();
        self.* = undefined;
    }

    pub fn resetForPass(self: *Assembler, pass_index: usize) Allocator.Error!void {
        self.pass_count = pass_index;
        self.deferred_expressions = 0;
        self.converged_flag = false;
        for (self.listing_entries.items) |*entry| self.allocator.free(entry.line);
        self.listing_entries.clearRetainingCapacity();
        try self.state.resetForPass(pass_index);
        try self.symbols.resetForPass(pass_index > 1);
        try self.output.reset();
    }

    pub fn recordListing(self: *Assembler, line: []const u8) AssembleError!void {
        const offset = try self.output.currentAddress();
        const owned = try self.allocator.dupe(u8, line);
        errdefer self.allocator.free(owned);
        try self.listing_entries.append(self.allocator, .{ .offset = offset, .line = owned });
    }

    pub fn formatListing(self: *const Assembler, allocator: Allocator) (Allocator.Error || error{OutputOverflow})![]u8 {
        const entries = self.listing_entries.items;
        if (entries.len == 0) return allocator.dupe(u8, "");
        const view = self.output.mainAreaView(0) catch |err| switch (err) {
            error.InvalidAddress => return allocator.dupe(u8, ""),
            error.OutputOverflow => return error.OutputOverflow,
            error.OutOfMemory => return error.OutOfMemory,
        };
        const base = view.base_address;
        const bytes = view.bytes;

        var buf = std.ArrayListUnmanaged(u8).empty;
        errdefer buf.deinit(allocator);
        for (entries, 0..) |entry, i| {
            const next_off = if (i + 1 < entries.len) entries[i + 1].offset else entry.offset +| (bytes.len -| (entry.offset -| base));
            const seg_start = @min(entry.offset -| base, bytes.len);
            const seg_end = @min(next_off -| base, bytes.len);

            const offset_str = try std.fmt.allocPrint(allocator, "{X:0>8}  ", .{entry.offset});
            defer allocator.free(offset_str);
            try buf.appendSlice(allocator, offset_str);
            const seg = bytes[seg_start..seg_end];
            for (seg) |b| {
                const byte_str = try std.fmt.allocPrint(allocator, "{X:0>2} ", .{b});
                defer allocator.free(byte_str);
                try buf.appendSlice(allocator, byte_str);
            }
            try buf.appendNTimes(allocator, ' ', 30 -| seg.len * 3);
            try buf.appendSlice(allocator, entry.line);
            try buf.appendSlice(allocator, "\n");
        }
        return buf.toOwnedSlice(allocator);
    }

    pub fn emitBytes(self: *Assembler, values: []const u8) AssembleError!void {
        try self.output.emitBytes(values);
    }

    pub fn reserveBytes(self: *Assembler, count: usize) AssembleError!void {
        try self.output.reserveBytes(count);
    }

    pub fn evaluateRelaxed(self: *Assembler, allocator: Allocator, input: []const u8) AssembleError!usize {
        return expressions.evaluate(allocator, input, &self.symbols) catch |err| switch (err) {
            error.UndefinedSymbol => {
                self.deferred_expressions += 1;
                return 0;
            },
            else => return error.InvalidOperand,
        };
    }

    pub fn currentEffectiveAddress(self: *const Assembler) AssembleError!usize {
        return try self.output.currentEffectiveAddress();
    }

    pub fn cachedX86BranchRelaxation(
        self: *Assembler,
        mnemonic: []const u8,
        operands: []const []const u8,
        line_number: usize,
    ) Allocator.Error!?X86BranchRelaxationDecision {
        const joined = try std.mem.join(self.allocator, ",", operands);
        defer self.allocator.free(joined);
        const key = try std.fmt.allocPrint(self.allocator, "{d}\x00{s}\x00{s}", .{ line_number, mnemonic, joined });
        defer self.allocator.free(key);
        return self.x86_branch_relaxation_cache.get(key);
    }

    pub fn rememberX86BranchRelaxation(
        self: *Assembler,
        mnemonic: []const u8,
        operands: []const []const u8,
        line_number: usize,
        decision: X86BranchRelaxationDecision,
    ) Allocator.Error!void {
        const joined = try std.mem.join(self.allocator, ",", operands);
        defer self.allocator.free(joined);
        const key = try std.fmt.allocPrint(self.allocator, "{d}\x00{s}\x00{s}", .{ line_number, mnemonic, joined });
        defer self.allocator.free(key);
        const gop = try self.x86_branch_relaxation_cache.getOrPut(key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
        }
        gop.value_ptr.* = decision;
    }

    pub fn cachedX86FixedBytes(self: *Assembler, key: []const u8) ?[]const u8 {
        return self.x86_fixed_bytes_cache.get(key);
    }

    pub fn rememberX86FixedBytes(self: *Assembler, key: []const u8, bytes: []const u8) Allocator.Error!void {
        const gop = try self.x86_fixed_bytes_cache.getOrPut(key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
        } else {
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = try self.allocator.dupe(u8, bytes);
    }

    fn clearBranchRelaxationCache(self: *Assembler) void {
        var it = self.x86_branch_relaxation_cache.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.x86_branch_relaxation_cache.clearRetainingCapacity();
    }

    fn clearFixedBytesCache(self: *Assembler) void {
        var it = self.x86_fixed_bytes_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.x86_fixed_bytes_cache.clearRetainingCapacity();
    }

    pub fn converged(self: *const Assembler) bool {
        const symbols_stable = self.state.current_pass == 1 or self.symbols.sameSymbolState();
        return self.deferred_expressions == 0 and !self.symbols.hasPendingStateQueries() and symbols_stable;
    }

    pub fn finalizeOutput(self: *Assembler, allocator: Allocator) AssembleError![]u8 {
        try self.output.materializeAllPendingReserves();
        const view = self.output.mainAreaView(0) catch |err| switch (err) {
            error.InvalidAddress => return error.InvalidArgument,
            error.OutOfMemory => return error.OutOfMemory,
            error.OutputOverflow => return error.OutputOverflow,
        };
        return try allocator.dupe(u8, view.bytes);
    }

    pub fn writeOutputToFilePath(self: *Assembler, io: std.Io, path: []const u8) !void {
        const bytes = try self.finalizeOutput(self.allocator);
        defer self.allocator.free(bytes);
        const dir = std.Io.Dir.cwd();
        var file = try dir.createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
    }
};
