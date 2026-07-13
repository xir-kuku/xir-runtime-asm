const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;

const BuiltinSizeEntry = struct {
    name: []const u8,
    size: usize,
};

const builtin_size_entries = [_]BuiltinSizeEntry{
    .{ .name = "byte", .size = 1 },
    .{ .name = "word", .size = 2 },
    .{ .name = "dword", .size = 4 },
    .{ .name = "pword", .size = 6 },
    .{ .name = "fword", .size = 6 },
    .{ .name = "qword", .size = 8 },
    .{ .name = "tbyte", .size = 10 },
    .{ .name = "tword", .size = 10 },
    .{ .name = "dqword", .size = 16 },
    .{ .name = "xword", .size = 16 },
    .{ .name = "qqword", .size = 32 },
    .{ .name = "yword", .size = 32 },
    .{ .name = "dqqword", .size = 64 },
    .{ .name = "zword", .size = 64 },
};

pub fn builtinSizeKeywordValue(name: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, name, " \t");
    for (builtin_size_entries) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry.name)) return entry.size;
    }
    return null;
}

pub const SymbolType = enum {
    variable,
    label,
    constant,
};

pub const RuntimeSnapshot = struct {
    current_address: usize,
    current_origin: usize,
    current_address_expression: ?[]const u8 = null,
    current_origin_expression: ?[]const u8 = null,
    file_offset: usize,
    file_size: usize,
    uninitialized_base: usize,
    line_number: usize,
};

pub const SymbolBinding = struct {
    symbol_type: SymbolType = .variable,
    value: usize = 0,
    size: usize = 0,
    text: ?[]const u8 = null,
    raw_text: ?[]const u8 = null,
    binary: ?[]const u8 = null,
    is_defined: bool = false,
    expandable: bool = false,
    is_runtime: bool = false,
    area_index: ?usize = null,
    area_is_virtual: bool = false,
    is_area_label: bool = false,
    area_variable: bool = false,
    area_bytes: ?[]const u8 = null,
    member_address: ?usize = null,
    member_area_index: ?usize = null,
    member_area_is_virtual: bool = false,
    member_value_symbol: bool = false,
    macro_arg_case_insensitive: bool = false,

    pub fn clone(self: SymbolBinding, allocator: Allocator) Allocator.Error!SymbolBinding {
        var cloned = SymbolBinding{
            .symbol_type = self.symbol_type,
            .value = self.value,
            .size = self.size,
            .is_defined = self.is_defined,
            .expandable = self.expandable,
            .is_runtime = self.is_runtime,
            .area_index = self.area_index,
            .area_is_virtual = self.area_is_virtual,
            .is_area_label = self.is_area_label,
            .area_variable = self.area_variable,
            .member_address = self.member_address,
            .member_area_index = self.member_area_index,
            .member_area_is_virtual = self.member_area_is_virtual,
            .member_value_symbol = self.member_value_symbol,
            .macro_arg_case_insensitive = self.macro_arg_case_insensitive,
        };
        errdefer cloned.deinit(allocator);

        cloned.text = if (self.text) |text| try allocator.dupe(u8, text) else null;
        cloned.raw_text = if (self.raw_text) |text| try allocator.dupe(u8, text) else null;
        cloned.binary = if (self.binary) |bytes| try allocator.dupe(u8, bytes) else null;
        cloned.area_bytes = if (self.area_bytes) |bytes| try allocator.dupe(u8, bytes) else null;
        return cloned;
    }

    pub fn deinit(self: *SymbolBinding, allocator: Allocator) void {
        if (self.text) |text| allocator.free(text);
        if (self.raw_text) |text| allocator.free(text);
        if (self.binary) |bytes| allocator.free(bytes);
        if (self.area_bytes) |bytes| allocator.free(bytes);
        self.* = .{};
    }

    pub fn eql(self: SymbolBinding, other: SymbolBinding) bool {
        return self.symbol_type == other.symbol_type and
            self.value == other.value and
            self.size == other.size and
            optionalTextEql(self.text, other.text) and
            optionalTextEql(self.raw_text, other.raw_text) and
            optionalBytesEql(self.binary, other.binary) and
            self.is_defined == other.is_defined and
            self.expandable == other.expandable and
            self.is_runtime == other.is_runtime and
            self.area_index == other.area_index and
            self.area_is_virtual == other.area_is_virtual and
            self.is_area_label == other.is_area_label and
            self.area_variable == other.area_variable and
            optionalBytesEql(self.area_bytes, other.area_bytes) and
            self.member_address == other.member_address and
            self.member_area_index == other.member_area_index and
            self.member_area_is_virtual == other.member_area_is_virtual and
            self.member_value_symbol == other.member_value_symbol;
    }
};

pub const MemberRuntimeAddress = struct {
    area_index: ?usize,
    area_is_virtual: bool = false,
    address: usize,
};

pub const DefineError = Allocator.Error || error{
    CannotRedefineConstant,
    SymbolAlreadyDefined,
};

pub const SymbolStateDiffCategory = enum {
    current,
    global,
    used,
};

pub const SymbolStateDiffChange = enum {
    added,
    removed,
    changed,
    count,
};

pub const SymbolStateDiff = struct {
    category: SymbolStateDiffCategory,
    change: SymbolStateDiffChange,
    name: ?[]const u8 = null,
    current_count: usize = 0,
    previous_count: usize = 0,
    current_value: ?usize = null,
    previous_value: ?usize = null,
    current_size: ?usize = null,
    previous_size: ?usize = null,
    current_type: ?SymbolType = null,
    previous_type: ?SymbolType = null,
};

const BindingMap = std.StringHashMap(SymbolBinding);
const MacroBindingMap = std.StringHashMap(SymbolBinding);
const UsedMap = std.StringHashMap(void);
const UsedQueryMap = std.StringHashMap(bool);
const DefinitionCountMap = std.StringHashMap(usize);

const BindingLookup = struct {
    key: []const u8,
    binding: SymbolBinding,
};

const TextDefinitionHistoryEntry = struct {
    name: []u8,
    binding: ?SymbolBinding = null,

    fn clone(self: TextDefinitionHistoryEntry, allocator: Allocator) Allocator.Error!TextDefinitionHistoryEntry {
        const owned_name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(owned_name);

        var cloned = TextDefinitionHistoryEntry{
            .name = owned_name,
        };
        errdefer cloned.deinit(allocator);

        if (self.binding) |binding| {
            cloned.binding = try binding.clone(allocator);
        }
        return cloned;
    }

    fn deinit(self: *TextDefinitionHistoryEntry, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.binding) |*binding| binding.deinit(allocator);
        self.* = undefined;
    }
};

const MacroFrame = struct {
    args: MacroBindingMap,

    fn init(allocator: Allocator) MacroFrame {
        return .{
            .args = MacroBindingMap.init(allocator),
        };
    }

    fn deinit(self: *MacroFrame, allocator: Allocator) void {
        releaseBindingMap(allocator, &self.args);
        self.* = undefined;
    }

    fn clone(self: *const MacroFrame, allocator: Allocator) Allocator.Error!MacroFrame {
        var cloned = MacroFrame.init(allocator);
        errdefer cloned.deinit(allocator);
        try cloneBindingMapInto(allocator, &cloned.args, &self.args);
        return cloned;
    }
};

pub const SymbolStore = struct {
    allocator: Allocator,
    current: BindingMap,
    global: BindingMap,
    previous_current: BindingMap,
    previous_global: BindingMap,
    used_current: UsedMap,
    used_previous: UsedMap,
    used_queries_current: UsedQueryMap,
    used_queries_previous: UsedQueryMap,
    variable_definition_counts_current: DefinitionCountMap,
    variable_definition_counts_previous: DefinitionCountMap,
    text_definition_history: std.ArrayList(TextDefinitionHistoryEntry) = .empty,
    macro_frames: std.ArrayList(MacroFrame) = .empty,
    structure_scopes: std.ArrayList([]const u8) = .empty,
    current_label_scope: ?[]const u8 = null,
    pending_state_queries: bool = false,
    has_previous_snapshot: bool = false,

    pub fn init(allocator: Allocator) Allocator.Error!SymbolStore {
        var store = SymbolStore{
            .allocator = allocator,
            .current = BindingMap.init(allocator),
            .global = BindingMap.init(allocator),
            .previous_current = BindingMap.init(allocator),
            .previous_global = BindingMap.init(allocator),
            .used_current = UsedMap.init(allocator),
            .used_previous = UsedMap.init(allocator),
            .used_queries_current = UsedQueryMap.init(allocator),
            .used_queries_previous = UsedQueryMap.init(allocator),
            .variable_definition_counts_current = DefinitionCountMap.init(allocator),
            .variable_definition_counts_previous = DefinitionCountMap.init(allocator),
            .text_definition_history = .empty,
            .macro_frames = .empty,
            .structure_scopes = .empty,
            .current_label_scope = null,
        };
        errdefer store.deinit();

        try store.initBuiltins();
        return store;
    }

    pub fn deinit(self: *SymbolStore) void {
        releaseBindingMap(self.allocator, &self.current);
        releaseBindingMap(self.allocator, &self.global);
        releaseBindingMap(self.allocator, &self.previous_current);
        releaseBindingMap(self.allocator, &self.previous_global);
        releaseUsedMap(self.allocator, &self.used_current);
        releaseUsedMap(self.allocator, &self.used_previous);
        releaseUsedQueryMap(self.allocator, &self.used_queries_current);
        releaseUsedQueryMap(self.allocator, &self.used_queries_previous);
        releaseDefinitionCountMap(self.allocator, &self.variable_definition_counts_current);
        releaseDefinitionCountMap(self.allocator, &self.variable_definition_counts_previous);
        self.clearTextDefinitionHistory();
        self.text_definition_history.deinit(self.allocator);
        self.clearMacroFrames();
        self.macro_frames.deinit(self.allocator);
        self.clearStructureScopes();
        self.structure_scopes.deinit(self.allocator);
        self.clearCurrentLabelScope();
        self.* = undefined;
    }

    pub fn clone(self: *const SymbolStore, allocator: Allocator) Allocator.Error!SymbolStore {
        var cloned = SymbolStore{
            .allocator = allocator,
            .current = BindingMap.init(allocator),
            .global = BindingMap.init(allocator),
            .previous_current = BindingMap.init(allocator),
            .previous_global = BindingMap.init(allocator),
            .used_current = UsedMap.init(allocator),
            .used_previous = UsedMap.init(allocator),
            .used_queries_current = UsedQueryMap.init(allocator),
            .used_queries_previous = UsedQueryMap.init(allocator),
            .variable_definition_counts_current = DefinitionCountMap.init(allocator),
            .variable_definition_counts_previous = DefinitionCountMap.init(allocator),
            .text_definition_history = .empty,
            .macro_frames = .empty,
            .structure_scopes = .empty,
            .current_label_scope = null,
            .pending_state_queries = self.pending_state_queries,
            .has_previous_snapshot = self.has_previous_snapshot,
        };
        errdefer cloned.deinit();

        try cloneBindingMapInto(allocator, &cloned.current, &self.current);
        try cloneBindingMapInto(allocator, &cloned.global, &self.global);
        try cloneBindingMapInto(allocator, &cloned.previous_current, &self.previous_current);
        try cloneBindingMapInto(allocator, &cloned.previous_global, &self.previous_global);
        try cloneUsedMapInto(allocator, &cloned.used_current, &self.used_current);
        try cloneUsedMapInto(allocator, &cloned.used_previous, &self.used_previous);
        try cloneUsedQueryMapInto(allocator, &cloned.used_queries_current, &self.used_queries_current);
        try cloneUsedQueryMapInto(allocator, &cloned.used_queries_previous, &self.used_queries_previous);
        try cloneDefinitionCountMapInto(allocator, &cloned.variable_definition_counts_current, &self.variable_definition_counts_current);
        try cloneDefinitionCountMapInto(allocator, &cloned.variable_definition_counts_previous, &self.variable_definition_counts_previous);
        for (self.text_definition_history.items) |entry| {
            var owned_entry = try entry.clone(allocator);
            errdefer owned_entry.deinit(allocator);
            try cloned.text_definition_history.append(allocator, owned_entry);
            owned_entry = undefined;
        }

        for (self.macro_frames.items) |*frame| {
            var owned_frame = try frame.clone(allocator);
            errdefer owned_frame.deinit(allocator);
            try cloned.macro_frames.append(allocator, owned_frame);
            owned_frame = undefined;
        }

        for (self.structure_scopes.items) |scope| {
            const owned_scope = try allocator.dupe(u8, scope);
            errdefer allocator.free(owned_scope);
            try cloned.structure_scopes.append(allocator, owned_scope);
        }

        cloned.current_label_scope = if (self.current_label_scope) |scope| try allocator.dupe(u8, scope) else null;
        return cloned;
    }

    pub fn resetForPass(self: *SymbolStore, carry_previous: bool) Allocator.Error!void {
        if (carry_previous) {
            var snapshot_committed = false;
            var next_previous_current = BindingMap.init(self.allocator);
            errdefer if (!snapshot_committed) releaseBindingMap(self.allocator, &next_previous_current);
            var next_previous_global = BindingMap.init(self.allocator);
            errdefer if (!snapshot_committed) releaseBindingMap(self.allocator, &next_previous_global);
            var next_used_previous = UsedMap.init(self.allocator);
            errdefer if (!snapshot_committed) releaseUsedMap(self.allocator, &next_used_previous);
            var next_used_queries_previous = UsedQueryMap.init(self.allocator);
            errdefer if (!snapshot_committed) releaseUsedQueryMap(self.allocator, &next_used_queries_previous);
            var next_variable_definition_counts_previous = DefinitionCountMap.init(self.allocator);
            errdefer if (!snapshot_committed) releaseDefinitionCountMap(self.allocator, &next_variable_definition_counts_previous);

            try cloneBindingMapInto(self.allocator, &next_previous_current, &self.current);
            try cloneBindingMapInto(self.allocator, &next_previous_global, &self.global);
            try cloneUsedMapInto(self.allocator, &next_used_previous, &self.used_current);
            try cloneUsedQueryMapInto(self.allocator, &next_used_queries_previous, &self.used_queries_current);
            try cloneDefinitionCountMapInto(
                self.allocator,
                &next_variable_definition_counts_previous,
                &self.variable_definition_counts_current,
            );

            releaseBindingMap(self.allocator, &self.previous_current);
            releaseBindingMap(self.allocator, &self.previous_global);
            releaseUsedMap(self.allocator, &self.used_previous);
            releaseUsedQueryMap(self.allocator, &self.used_queries_previous);
            releaseDefinitionCountMap(self.allocator, &self.variable_definition_counts_previous);

            self.previous_current = next_previous_current;
            self.previous_global = next_previous_global;
            self.used_previous = next_used_previous;
            self.used_queries_previous = next_used_queries_previous;
            self.variable_definition_counts_previous = next_variable_definition_counts_previous;
            snapshot_committed = true;
            self.has_previous_snapshot = true;
        } else {
            resetBindingMap(self.allocator, &self.previous_current);
            resetBindingMap(self.allocator, &self.previous_global);
            resetUsedMap(self.allocator, &self.used_previous);
            resetUsedQueryMap(self.allocator, &self.used_queries_previous);
            resetDefinitionCountMap(self.allocator, &self.variable_definition_counts_previous);
            self.has_previous_snapshot = false;
        }

        resetBindingMap(self.allocator, &self.current);
        resetBindingMap(self.allocator, &self.global);
        resetUsedMap(self.allocator, &self.used_current);
        resetUsedQueryMap(self.allocator, &self.used_queries_current);
        resetDefinitionCountMap(self.allocator, &self.variable_definition_counts_current);
        self.clearTextDefinitionHistory();
        self.clearMacroFrames();
        self.clearStructureScopes();
        self.clearCurrentLabelScope();
        self.pending_state_queries = false;

        try self.initBuiltins();
    }

    pub fn defineValue(
        self: *SymbolStore,
        name: []const u8,
        symbol_type: SymbolType,
        value: usize,
        size: usize,
        text: ?[]const u8,
    ) Allocator.Error!void {
        try self.putBinding(&self.current, name, .{
            .symbol_type = symbol_type,
            .value = value,
            .size = size,
            .text = text,
            .is_defined = true,
            .expandable = text != null,
        });
    }

    pub fn defineExpression(
        self: *SymbolStore,
        name: []const u8,
        symbol_type: SymbolType,
        value: usize,
        text: ?[]const u8,
    ) DefineError!void {
        return self.defineExpressionSized(name, symbol_type, value, 0, text);
    }

    pub fn defineExpressionSized(
        self: *SymbolStore,
        name: []const u8,
        symbol_type: SymbolType,
        value: usize,
        size: usize,
        text: ?[]const u8,
    ) DefineError!void {
        try self.validateCurrentRewrite(name, symbol_type);
        if (symbol_type == .variable) try self.incrementVariableDefinitionCount(name);
        try self.putBinding(&self.current, name, .{
            .symbol_type = symbol_type,
            .value = value,
            .size = size,
            .text = text,
            .is_defined = true,
            .expandable = text != null,
        });
    }

    pub fn defineText(
        self: *SymbolStore,
        name: []const u8,
        text: []const u8,
        expandable: bool,
    ) DefineError!void {
        try self.validateCurrentRewrite(name, .variable);
        const storage_name = self.textDefinitionStorageName(name);
        try self.pushTextDefinitionHistory(storage_name);
        errdefer self.discardLatestTextDefinitionHistory(storage_name);

        try self.putBinding(&self.current, storage_name, .{
            .symbol_type = .variable,
            .text = text,
            .raw_text = text,
            .is_defined = true,
            .expandable = expandable,
        });
    }

    pub fn redefineText(
        self: *SymbolStore,
        name: []const u8,
        text: []const u8,
        expandable: bool,
    ) DefineError!void {
        try self.validateCurrentRewrite(name, .variable);
        const storage_name = self.textDefinitionStorageName(name);
        try self.putBinding(&self.current, storage_name, .{
            .symbol_type = .variable,
            .text = text,
            .raw_text = text,
            .is_defined = true,
            .expandable = expandable,
        });
    }

    pub fn restoreSymbol(self: *SymbolStore, name: []const u8) Allocator.Error!void {
        if (self.takeLatestTextDefinitionHistory(name)) |entry_value| {
            var entry = entry_value;
            defer entry.deinit(self.allocator);

            removeConflictingBindingIfPresent(self.allocator, &self.current, entry.name);
            if (entry.binding) |binding| {
                try self.putBinding(&self.current, entry.name, binding);
            }
            return;
        }

        removeConflictingBindingIfPresent(self.allocator, &self.current, name);
    }

    pub fn defineLabel(
        self: *SymbolStore,
        name: []const u8,
        value: usize,
        size: usize,
        text: ?[]const u8,
    ) (DefineError || error{ InvalidInstruction, InvalidArgument })!void {
        return self.defineLabelInArea(name, value, size, text, null);
    }

    pub fn defineLabelInArea(
        self: *SymbolStore,
        name: []const u8,
        value: usize,
        size: usize,
        text: ?[]const u8,
        area_index: ?usize,
    ) (DefineError || error{ InvalidInstruction, InvalidArgument })!void {
        return self.defineLabelInOutputDomain(name, value, size, text, area_index, area_index != null);
    }

    pub fn defineLabelInOutputDomain(
        self: *SymbolStore,
        name: []const u8,
        value: usize,
        size: usize,
        text: ?[]const u8,
        area_index: ?usize,
        area_is_virtual: bool,
    ) (DefineError || error{ InvalidInstruction, InvalidArgument })!void {
        const resolved_name = try self.resolveLabelNameAlloc(self.allocator, name);
        defer self.allocator.free(resolved_name);

        const raw_name = std.mem.trim(u8, name, " \t");
        const should_set_scope = !std.mem.startsWith(u8, raw_name, ".") and self.currentStructureScopePath().len == 0;
        const owned_scope = if (should_set_scope) try self.allocator.dupe(u8, resolved_name) else null;
        errdefer if (owned_scope) |scope| self.allocator.free(scope);

        try self.validateNewLabel(resolved_name, text);
        try self.defineExactLabelInOutputDomain(resolved_name, value, size, text, area_index, area_is_virtual);
        if (owned_scope) |scope| self.setCurrentLabelScopeOwned(scope);
    }

    pub fn defineExactLabel(
        self: *SymbolStore,
        qualified_name: []const u8,
        value: usize,
        size: usize,
        text: ?[]const u8,
    ) DefineError!void {
        return self.defineExactLabelInArea(qualified_name, value, size, text, null);
    }

    pub fn defineExactLabelInArea(
        self: *SymbolStore,
        qualified_name: []const u8,
        value: usize,
        size: usize,
        text: ?[]const u8,
        area_index: ?usize,
    ) DefineError!void {
        return self.defineExactLabelInOutputDomain(
            qualified_name,
            value,
            size,
            text,
            area_index,
            area_index != null,
        );
    }

    pub fn defineExactLabelInOutputDomain(
        self: *SymbolStore,
        qualified_name: []const u8,
        value: usize,
        size: usize,
        text: ?[]const u8,
        area_index: ?usize,
        area_is_virtual: bool,
    ) DefineError!void {
        try self.validateCurrentRewrite(qualified_name, .label);
        try self.putBinding(&self.current, qualified_name, .{
            .symbol_type = .label,
            .value = value,
            .size = size,
            .text = text,
            .is_defined = true,
            .expandable = false,
            .area_index = area_index,
            .area_is_virtual = area_is_virtual,
        });
    }

    pub fn resolveLabelNameAlloc(
        self: *const SymbolStore,
        allocator: Allocator,
        name: []const u8,
    ) (Allocator.Error || error{ InvalidInstruction, InvalidArgument })![]const u8 {
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len == 0) return error.InvalidArgument;
        if (std.mem.startsWith(u8, trimmed, "..")) return error.InvalidInstruction;

        const dot_scope = self.currentDotScopePath();
        if (std.mem.eql(u8, trimmed, ".")) {
            if (dot_scope.len == 0) return error.InvalidArgument;
            return allocator.dupe(u8, dot_scope);
        }

        if (std.mem.startsWith(u8, trimmed, ".")) {
            if (dot_scope.len == 0) return error.InvalidInstruction;
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ dot_scope, trimmed });
        }

        const structure_scope = self.currentStructureScopePath();
        if (structure_scope.len != 0) {
            return std.fmt.allocPrint(allocator, "{s}.{s}", .{ structure_scope, trimmed });
        }

        return allocator.dupe(u8, trimmed);
    }

    pub fn defineBinary(
        self: *SymbolStore,
        name: []const u8,
        bytes: []const u8,
    ) DefineError!void {
        return self.defineBinarySized(name, bytes, bytes.len);
    }

    pub fn defineBinarySized(
        self: *SymbolStore,
        name: []const u8,
        bytes: []const u8,
        size: usize,
    ) DefineError!void {
        try self.validateCurrentRewrite(name, .variable);
        try self.putBinding(&self.current, name, .{
            .symbol_type = .variable,
            .value = binaryPrefixWord(bytes),
            .size = size,
            .binary = bytes,
            .is_defined = true,
            .expandable = false,
        });
    }

    pub fn setRuntimeValue(
        self: *SymbolStore,
        name: []const u8,
        value: usize,
    ) Allocator.Error!void {
        try self.putBinding(&self.global, name, .{
            .symbol_type = .variable,
            .value = value,
            .is_defined = true,
            .is_runtime = true,
        });
    }

    pub fn setRuntimeExpression(
        self: *SymbolStore,
        name: []const u8,
        value: usize,
        expression: ?[]const u8,
    ) Allocator.Error!void {
        try self.putBinding(&self.global, name, .{
            .symbol_type = .variable,
            .value = value,
            .text = expression,
            .is_defined = true,
            .expandable = expression != null,
            .is_runtime = true,
        });
    }

    pub fn setRuntimeText(
        self: *SymbolStore,
        name: []const u8,
        text: []const u8,
    ) Allocator.Error!void {
        try self.putBinding(&self.global, name, .{
            .symbol_type = .variable,
            .text = text,
            .is_defined = true,
            .expandable = true,
            .is_runtime = true,
        });
    }

    pub fn enterMacro(self: *SymbolStore) Allocator.Error!void {
        try self.macro_frames.append(self.allocator, MacroFrame.init(self.allocator));
    }

    pub fn macroFrameDepth(self: *const SymbolStore) usize {
        return self.macro_frames.items.len;
    }

    pub fn exitMacro(self: *SymbolStore) void {
        const frame = self.macro_frames.pop() orelse return;
        var owned_frame = frame;
        owned_frame.deinit(self.allocator);
    }

    pub fn hasMacroFrames(self: *const SymbolStore) bool {
        return self.macro_frames.items.len != 0;
    }

    pub fn enterStructureScope(
        self: *SymbolStore,
        qualified_label: []const u8,
    ) Allocator.Error!void {
        const owned_scope = try self.allocator.dupe(u8, qualified_label);
        errdefer self.allocator.free(owned_scope);
        try self.structure_scopes.append(self.allocator, owned_scope);
    }

    pub fn exitStructureScope(self: *SymbolStore) void {
        const scope = self.structure_scopes.pop() orelse return;
        self.allocator.free(scope);
    }

    pub fn currentStructureScopePath(self: *const SymbolStore) []const u8 {
        if (self.structure_scopes.items.len == 0) return "";
        return self.structure_scopes.items[self.structure_scopes.items.len - 1];
    }

    pub fn setMacroArgTextWithRaw(
        self: *SymbolStore,
        name: []const u8,
        text: []const u8,
        raw_text: []const u8,
    ) (Allocator.Error || error{InvalidInstruction})!void {
        return self.setMacroArgTextWithRawCase(name, text, raw_text, false);
    }

    pub fn setMacroArgTextWithRawCase(
        self: *SymbolStore,
        name: []const u8,
        text: []const u8,
        raw_text: []const u8,
        case_insensitive: bool,
    ) (Allocator.Error || error{InvalidInstruction})!void {
        if (self.macro_frames.items.len == 0) return error.InvalidInstruction;

        try self.setMacroArgTextInFrameWithRawCase(
            self.macro_frames.items.len - 1,
            name,
            text,
            raw_text,
            case_insensitive,
        );
    }

    pub fn setMacroArgTextInFrameWithRawCase(
        self: *SymbolStore,
        frame_index: usize,
        name: []const u8,
        text: []const u8,
        raw_text: []const u8,
        case_insensitive: bool,
    ) (Allocator.Error || error{InvalidInstruction})!void {
        if (frame_index >= self.macro_frames.items.len) return error.InvalidInstruction;

        const frame = &self.macro_frames.items[frame_index];
        try putClonedBinding(self.allocator, &frame.args, name, .{
            .symbol_type = .variable,
            .text = text,
            .raw_text = raw_text,
            .is_defined = true,
            .expandable = true,
            .macro_arg_case_insensitive = case_insensitive,
        });
    }

    pub fn defineInstanceMemberValue(
        self: *SymbolStore,
        name: []const u8,
        value: usize,
        size: usize,
        address: usize,
        area_index: ?usize,
    ) Allocator.Error!void {
        return self.defineInstanceMemberValueInOutputDomain(
            name,
            value,
            size,
            address,
            area_index,
            area_index != null,
        );
    }

    pub fn defineInstanceMemberValueInOutputDomain(
        self: *SymbolStore,
        name: []const u8,
        value: usize,
        size: usize,
        address: usize,
        area_index: ?usize,
        area_is_virtual: bool,
    ) Allocator.Error!void {
        try self.putBinding(&self.current, name, .{
            .symbol_type = .label,
            .value = value,
            .size = size,
            .is_defined = true,
            .member_address = address,
            .member_area_index = area_index,
            .member_area_is_virtual = area_is_virtual,
            .member_value_symbol = true,
        });
    }

    pub fn defineAreaLabel(
        self: *SymbolStore,
        name: []const u8,
        value: usize,
        area_size: usize,
        area_index: usize,
    ) DefineError!void {
        return self.defineAreaLabelInOutputDomain(name, value, area_size, area_index, true);
    }

    pub fn defineAreaLabelInOutputDomain(
        self: *SymbolStore,
        name: []const u8,
        value: usize,
        area_size: usize,
        area_index: usize,
        area_is_virtual: bool,
    ) DefineError!void {
        try self.validateNewLabel(name, null);
        try self.putBinding(&self.current, name, .{
            .symbol_type = .label,
            .value = value,
            .size = area_size,
            .is_defined = true,
            .area_index = area_index,
            .area_is_virtual = area_is_virtual,
            .is_area_label = true,
        });
    }

    pub fn updateAreaLabelSizes(self: *SymbolStore, area_index: usize, area_size: usize) void {
        self.updateAreaLabelSizesInOutputDomain(area_index, true, area_size);
    }

    pub fn updateAreaLabelSizesInOutputDomain(
        self: *SymbolStore,
        area_index: usize,
        area_is_virtual: bool,
        area_size: usize,
    ) void {
        updateAreaLabelSizesInMap(&self.current, area_index, area_is_virtual, area_size);
        updateAreaLabelSizesInMap(&self.global, area_index, area_is_virtual, area_size);
    }

    pub fn markAreaVariableInOutputDomain(
        self: *SymbolStore,
        area_index: usize,
        area_is_virtual: bool,
    ) void {
        markAreaVariableInMap(&self.current, area_index, area_is_virtual);
        markAreaVariableInMap(&self.global, area_index, area_is_virtual);
    }

    pub fn markUsed(self: *SymbolStore, name: []const u8) Allocator.Error!void {
        if (try self.resolveScopedDotLookupNameAlloc(self.allocator, name)) |qualified| {
            defer self.allocator.free(qualified);
            try putUsedKey(self.allocator, &self.used_current, qualified);
            return;
        }
        try putUsedKey(self.allocator, &self.used_current, name);
    }

    pub fn markDefinedQuery(self: *SymbolStore, name: []const u8) void {
        if (self.isDefinedInCurrentOrPreviousPass(name)) return;
        if (!self.has_previous_snapshot) self.deferStateQuery();
    }

    pub fn queryDefined(self: *SymbolStore, name: []const u8) bool {
        const defined = self.isDefinedInCurrentOrPreviousPass(name);
        if (!defined and !self.has_previous_snapshot) self.deferStateQuery();
        return defined;
    }

    fn isDefinedInCurrentOrPreviousPass(self: *const SymbolStore, name: []const u8) bool {
        if (self.findBinding(name, false) != null) return true;
        if (self.findPreviousBinding(name) != null) return true;
        return false;
    }

    pub fn queryDefinite(self: *const SymbolStore, name: []const u8) bool {
        return self.findBinding(name, false) != null;
    }

    pub fn queryUsed(self: *SymbolStore, name: []const u8) Allocator.Error!bool {
        const result = self.usedScopedDotLabel(name) or
            usedMapContainsSymbolName(&self.used_current, name) or
            usedMapContainsSymbolName(&self.used_previous, name);
        try putUsedQueryResult(self.allocator, &self.used_queries_current, name, result);
        if (!result and !self.has_previous_snapshot) self.deferStateQuery();
        return result;
    }

    pub fn lookupValue(self: *SymbolStore, name: []const u8) Allocator.Error!?usize {
        const binding = try self.lookupBinding(name, true) orelse return null;
        return binding.value;
    }

    pub fn lookupText(self: *SymbolStore, name: []const u8) Allocator.Error!?[]const u8 {
        const binding = try self.lookupBinding(name, true) orelse return null;
        return binding.text;
    }

    pub fn lookupRawText(self: *SymbolStore, name: []const u8) Allocator.Error!?[]const u8 {
        const binding = try self.lookupBinding(name, true) orelse return null;
        return binding.raw_text orelse binding.text;
    }

    pub fn lookupBinary(self: *SymbolStore, name: []const u8) Allocator.Error!?[]const u8 {
        const binding = try self.lookupBinding(name, true) orelse return null;
        return binding.binary;
    }

    pub fn lookupMacroArgText(self: *const SymbolStore, name: []const u8) ?[]const u8 {
        var index = self.macro_frames.items.len;
        while (index > 0) {
            index -= 1;
            if (findMacroArgBinding(&self.macro_frames.items[index], name)) |binding| {
                return binding.text;
            }
        }
        return null;
    }

    pub fn lookupMacroArgRawText(self: *const SymbolStore, name: []const u8) ?[]const u8 {
        var index = self.macro_frames.items.len;
        while (index > 0) {
            index -= 1;
            if (findMacroArgBinding(&self.macro_frames.items[index], name)) |binding| {
                return binding.raw_text orelse binding.text;
            }
        }
        return null;
    }

    pub fn lookupMemberRuntimeAddress(
        self: *const SymbolStore,
        name: []const u8,
    ) ?MemberRuntimeAddress {
        const binding = self.findBinding(name, true) orelse return null;
        const address = binding.member_address orelse return null;
        return .{
            .area_index = binding.member_area_index,
            .area_is_virtual = binding.member_area_is_virtual,
            .address = address,
        };
    }

    pub fn peekBinding(
        self: *const SymbolStore,
        name: []const u8,
        allow_previous: bool,
    ) ?SymbolBinding {
        return self.findBinding(name, allow_previous);
    }

    pub fn peekPreviousBinding(self: *const SymbolStore, name: []const u8) ?SymbolBinding {
        return self.findPreviousBinding(name);
    }

    pub fn lookupBinding(
        self: *SymbolStore,
        name: []const u8,
        allow_previous: bool,
    ) Allocator.Error!?SymbolBinding {
        const binding = self.findBinding(name, allow_previous) orelse return null;
        try self.markUsed(name);
        return binding;
    }

    pub fn hasPendingStateQueries(self: *const SymbolStore) bool {
        return self.pending_state_queries;
    }

    pub fn hasPreviousSnapshot(self: *const SymbolStore) bool {
        return self.has_previous_snapshot;
    }

    pub fn sameSymbolState(self: *const SymbolStore) bool {
        if (!self.has_previous_snapshot) return false;
        return bindingMapsEqual(&self.current, &self.previous_current) and
            bindingMapsEqual(&self.global, &self.previous_global) and
            usedQueryMapsEqual(&self.used_queries_current, &self.used_queries_previous);
    }

    pub fn firstSymbolStateDiff(self: *const SymbolStore) ?SymbolStateDiff {
        if (!self.has_previous_snapshot) return null;
        if (usedQueryMapDiff(&self.used_queries_current, &self.used_queries_previous)) |diff| return diff;
        if (bindingMapDiff(.current, &self.current, &self.previous_current)) |diff| return diff;
        return bindingMapDiff(.global, &self.global, &self.previous_global);
    }

    pub fn deferStateQuery(self: *SymbolStore) void {
        self.pending_state_queries = true;
    }

    pub fn setPendingStateQueries(self: *SymbolStore, pending: bool) void {
        self.pending_state_queries = pending;
    }

    pub fn removeIfPresent(self: *SymbolStore, name: []const u8) void {
        removeBindingIfPresent(self.allocator, &self.current, name);
        removeBindingIfPresent(self.allocator, &self.global, name);
    }

    pub fn removeWithPrefixIfPresent(self: *SymbolStore, prefix: []const u8) Allocator.Error!void {
        try removePrefixedBindings(self.allocator, &self.current, prefix);
        try removePrefixedBindings(self.allocator, &self.global, prefix);
    }

    pub fn refreshInstanceMemberValues(
        self: *SymbolStore,
        comptime ReadError: type,
        context: anytype,
        comptime read_value: fn (@TypeOf(context), ?usize, bool, usize, usize) ReadError!usize,
    ) ReadError!void {
        var it = self.current.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.member_value_symbol) continue;
            const address = entry.value_ptr.member_address orelse continue;
            if (entry.value_ptr.size == 0) continue;

            entry.value_ptr.value = try read_value(
                context,
                entry.value_ptr.member_area_index,
                entry.value_ptr.member_area_is_virtual,
                address,
                entry.value_ptr.size,
            );
        }
    }

    pub fn captureAreaLabelSnapshots(
        self: *SymbolStore,
        comptime ReadError: type,
        context: anytype,
        comptime read_area: fn (@TypeOf(context), usize, bool, usize, usize) ReadError![]u8,
    ) ReadError!void {
        var current_it = self.current.iterator();
        while (current_it.next()) |entry| {
            if (!entry.value_ptr.is_area_label) continue;
            const area_index = entry.value_ptr.area_index orelse continue;
            self.replaceAreaSnapshot(entry.value_ptr, try read_area(
                context,
                area_index,
                entry.value_ptr.area_is_virtual,
                entry.value_ptr.value,
                entry.value_ptr.size,
            ));
        }

        var global_it = self.global.iterator();
        while (global_it.next()) |entry| {
            if (!entry.value_ptr.is_area_label) continue;
            const area_index = entry.value_ptr.area_index orelse continue;
            self.replaceAreaSnapshot(entry.value_ptr, try read_area(
                context,
                area_index,
                entry.value_ptr.area_is_virtual,
                entry.value_ptr.value,
                entry.value_ptr.size,
            ));
        }
    }

    fn replaceAreaSnapshot(self: *SymbolStore, binding: *SymbolBinding, owned_bytes: []u8) void {
        if (binding.area_bytes) |bytes| self.allocator.free(bytes);
        binding.area_bytes = owned_bytes;
    }

    fn initBuiltins(self: *SymbolStore) Allocator.Error!void {
        for (builtin_size_entries) |entry| {
            try self.putBinding(&self.global, entry.name, .{
                .symbol_type = .constant,
                .value = entry.size,
                .size = entry.size,
                .is_defined = true,
            });
        }
    }

    fn findBinding(self: *const SymbolStore, name: []const u8, allow_previous: bool) ?SymbolBinding {
        if (findBindingInMap(&self.current, name)) |binding| return binding;
        if (findBindingInMap(&self.global, name)) |binding| return binding;
        if (self.findScopedDotBinding(name, false)) |binding| return binding;
        if (!allow_previous) return null;
        return self.findPreviousBinding(name);
    }

    fn findPreviousBinding(self: *const SymbolStore, name: []const u8) ?SymbolBinding {
        if (findPredictablePreviousBindingInMap(&self.previous_current, &self.variable_definition_counts_previous, name)) |binding| return binding;
        if (findBindingInMap(&self.previous_global, name)) |binding| return binding;
        if (self.findScopedDotBinding(name, true)) |binding| return binding;
        return null;
    }

    fn putBinding(
        self: *SymbolStore,
        map: *BindingMap,
        name: []const u8,
        binding: SymbolBinding,
    ) Allocator.Error!void {
        try putClonedBinding(self.allocator, map, name, binding);
    }

    fn textDefinitionStorageName(self: *const SymbolStore, name: []const u8) []const u8 {
        if (findBindingEntryInMap(&self.current, name)) |entry| return entry.key;
        return name;
    }

    fn pushTextDefinitionHistory(self: *SymbolStore, storage_name: []const u8) Allocator.Error!void {
        const owned_name = try self.allocator.dupe(u8, storage_name);

        var entry = TextDefinitionHistoryEntry{
            .name = owned_name,
        };
        errdefer entry.deinit(self.allocator);

        if (self.current.get(storage_name)) |binding| {
            entry.binding = try binding.clone(self.allocator);
        }

        try self.text_definition_history.append(self.allocator, entry);
        entry = undefined;
    }

    fn takeLatestTextDefinitionHistory(self: *SymbolStore, name: []const u8) ?TextDefinitionHistoryEntry {
        var index = self.text_definition_history.items.len;
        while (index > 0) {
            index -= 1;
            if (!symbolNamesConflict(self.text_definition_history.items[index].name, name)) continue;

            const entry = self.text_definition_history.items[index];
            const tail = self.text_definition_history.items[index + 1 ..];
            std.mem.copyForwards(
                TextDefinitionHistoryEntry,
                self.text_definition_history.items[index..][0..tail.len],
                tail,
            );
            self.text_definition_history.items.len -= 1;
            return entry;
        }
        return null;
    }

    fn discardLatestTextDefinitionHistory(self: *SymbolStore, name: []const u8) void {
        if (self.takeLatestTextDefinitionHistory(name)) |entry_value| {
            var entry = entry_value;
            entry.deinit(self.allocator);
        }
    }

    fn clearTextDefinitionHistory(self: *SymbolStore) void {
        for (self.text_definition_history.items) |*entry| entry.deinit(self.allocator);
        self.text_definition_history.clearRetainingCapacity();
    }

    fn validateCurrentRewrite(
        self: *const SymbolStore,
        name: []const u8,
        symbol_type: SymbolType,
    ) error{ CannotRedefineConstant, SymbolAlreadyDefined }!void {
        const existing = findConflictingBindingInMap(&self.current, name) orelse return;
        if (existing.symbol_type == .constant and existing.is_defined) {
            return error.CannotRedefineConstant;
        }
        if (symbol_type == .constant) {
            return error.SymbolAlreadyDefined;
        }
    }

    fn validateNewLabel(
        self: *const SymbolStore,
        name: []const u8,
        text: ?[]const u8,
    ) error{ CannotRedefineConstant, SymbolAlreadyDefined }!void {
        try self.validateCurrentRewrite(name, .label);
        const existing = self.current.get(name) orelse return;
        if (existing.symbol_type == .label and existing.is_defined) {
            if (existing.text != null and text == null) return;
            const structure_scope = self.currentStructureScopePath();
            if (structure_scope.len != 0 and std.mem.eql(u8, name, structure_scope)) return;
            return error.SymbolAlreadyDefined;
        }
    }

    fn replaceBindingMap(
        self: *SymbolStore,
        dest: *BindingMap,
        source: *const BindingMap,
    ) Allocator.Error!void {
        resetBindingMap(self.allocator, dest);
        var it = source.iterator();
        while (it.next()) |entry| {
            try putClonedBinding(self.allocator, dest, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn replaceUsedMap(
        self: *SymbolStore,
        dest: *UsedMap,
        source: *const UsedMap,
    ) Allocator.Error!void {
        resetUsedMap(self.allocator, dest);
        var it = source.iterator();
        while (it.next()) |entry| {
            try putUsedKey(self.allocator, dest, entry.key_ptr.*);
        }
    }

    fn replaceUsedQueryMap(
        self: *SymbolStore,
        dest: *UsedQueryMap,
        source: *const UsedQueryMap,
    ) Allocator.Error!void {
        resetUsedQueryMap(self.allocator, dest);
        var it = source.iterator();
        while (it.next()) |entry| {
            try putUsedQueryResult(self.allocator, dest, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn replaceDefinitionCountMap(
        self: *SymbolStore,
        dest: *DefinitionCountMap,
        source: *const DefinitionCountMap,
    ) Allocator.Error!void {
        resetDefinitionCountMap(self.allocator, dest);
        var it = source.iterator();
        while (it.next()) |entry| {
            try putDefinitionCount(self.allocator, dest, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn incrementVariableDefinitionCount(self: *SymbolStore, name: []const u8) Allocator.Error!void {
        var it = self.variable_definition_counts_current.iterator();
        while (it.next()) |entry| {
            if (symbolNamesConflict(entry.key_ptr.*, name)) {
                entry.value_ptr.* += 1;
                return;
            }
        }

        const entry = try self.variable_definition_counts_current.getOrPut(name);
        if (!entry.found_existing) {
            errdefer self.rollbackVariableDefinitionCountInsert(name);
            entry.key_ptr.* = try self.allocator.dupe(u8, name);
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
    }

    fn rollbackVariableDefinitionCountInsert(self: *SymbolStore, name: []const u8) void {
        std.debug.assert(self.variable_definition_counts_current.remove(name));
    }

    fn clearMacroFrames(self: *SymbolStore) void {
        while (self.macro_frames.pop()) |frame| {
            var owned_frame = frame;
            owned_frame.deinit(self.allocator);
        }
    }

    fn clearStructureScopes(self: *SymbolStore) void {
        while (self.structure_scopes.pop()) |scope| {
            self.allocator.free(scope);
        }
    }

    fn clearCurrentLabelScope(self: *SymbolStore) void {
        if (self.current_label_scope) |scope| {
            self.allocator.free(scope);
            self.current_label_scope = null;
        }
    }

    fn setCurrentLabelScopeOwned(self: *SymbolStore, owned_scope: []const u8) void {
        self.clearCurrentLabelScope();
        self.current_label_scope = owned_scope;
    }

    pub fn currentLocalLabelScopePath(self: *const SymbolStore) []const u8 {
        return self.current_label_scope orelse "";
    }

    fn currentDotScopePath(self: *const SymbolStore) []const u8 {
        const structure_scope = self.currentStructureScopePath();
        if (structure_scope.len != 0) return structure_scope;
        return self.currentLocalLabelScopePath();
    }

    fn resolveScopedDotLookupNameAlloc(
        self: *const SymbolStore,
        allocator: Allocator,
        name: []const u8,
    ) Allocator.Error!?[]const u8 {
        if (std.mem.eql(u8, name, ".")) {
            const scope = self.currentDotScopePath();
            if (scope.len == 0) return null;
            return try allocator.dupe(u8, scope);
        }
        if (!std.mem.startsWith(u8, name, ".")) return null;
        if (std.mem.startsWith(u8, name, "..")) return null;

        const scope = self.currentDotScopePath();
        if (scope.len == 0) return null;
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ scope, name });
    }

    fn findScopedDotBinding(
        self: *const SymbolStore,
        name: []const u8,
        allow_previous: bool,
    ) ?SymbolBinding {
        const scope = self.currentDotScopePath();
        if (scope.len == 0) return null;

        if (std.mem.eql(u8, name, ".")) {
            if (findBindingInMap(&self.current, scope)) |binding| return binding;
            if (findBindingInMap(&self.global, scope)) |binding| return binding;
            if (!allow_previous) return null;
            if (findPredictablePreviousBindingInMap(
                &self.previous_current,
                &self.variable_definition_counts_previous,
                scope,
            )) |binding| return binding;
            if (findBindingInMap(&self.previous_global, scope)) |binding| return binding;
            return null;
        }
        if (!std.mem.startsWith(u8, name, ".")) return null;
        if (std.mem.startsWith(u8, name, "..")) return null;

        if (findScopedDotBindingInMap(&self.current, scope, name)) |binding| return binding;
        if (findScopedDotBindingInMap(&self.global, scope, name)) |binding| return binding;
        if (!allow_previous) return null;
        if (findScopedDotBindingInMap(&self.previous_current, scope, name)) |binding| return binding;
        if (findScopedDotBindingInMap(&self.previous_global, scope, name)) |binding| return binding;
        return null;
    }

    fn usedScopedDotLabel(self: *const SymbolStore, name: []const u8) bool {
        const scope = self.currentDotScopePath();
        if (scope.len == 0) return false;

        if (std.mem.eql(u8, name, ".")) {
            return usedMapContainsSymbolName(&self.used_current, scope) or
                usedMapContainsSymbolName(&self.used_previous, scope);
        }
        if (!std.mem.startsWith(u8, name, ".")) return false;
        if (std.mem.startsWith(u8, name, "..")) return false;

        return usedMapContainsScopedDot(&self.used_current, scope, name) or
            usedMapContainsScopedDot(&self.used_previous, scope, name);
    }
};

fn findScopedDotBindingInMap(
    map: *const BindingMap,
    scope: []const u8,
    name: []const u8,
) ?SymbolBinding {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (scopedDotNameMatches(entry.key_ptr.*, scope, name)) return entry.value_ptr.*;
    }
    return null;
}

fn findBindingInMap(map: *const BindingMap, name: []const u8) ?SymbolBinding {
    return if (findBindingEntryInMap(map, name)) |entry| entry.binding else null;
}

fn findBindingEntryInMap(map: *const BindingMap, name: []const u8) ?BindingLookup {
    if (map.get(name)) |binding| {
        return .{
            .key = name,
            .binding = binding,
        };
    }

    var it = map.iterator();
    while (it.next()) |entry| {
        if (caseInsensitiveSymbolNameMatches(entry.key_ptr.*, name)) {
            return .{
                .key = entry.key_ptr.*,
                .binding = entry.value_ptr.*,
            };
        }
    }
    return null;
}

fn findPredictablePreviousBindingInMap(
    map: *const BindingMap,
    variable_definition_counts: *const DefinitionCountMap,
    name: []const u8,
) ?SymbolBinding {
    const entry = findBindingEntryInMap(map, name) orelse return null;
    if (entry.binding.symbol_type == .variable and definitionCount(variable_definition_counts, entry.key) > 1) {
        return null;
    }
    return entry.binding;
}

fn findConflictingBindingInMap(map: *const BindingMap, name: []const u8) ?SymbolBinding {
    if (map.get(name)) |binding| return binding;

    var it = map.iterator();
    while (it.next()) |entry| {
        if (symbolNamesConflict(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}

fn findMacroArgBinding(frame: *const MacroFrame, name: []const u8) ?SymbolBinding {
    if (frame.args.get(name)) |binding| return binding;
    if (std.mem.endsWith(u8, name, "?")) {
        const stripped = name[0 .. name.len - 1];
        if (frame.args.get(stripped)) |binding| return binding;
    }

    var it = frame.args.iterator();
    while (it.next()) |entry| {
        const binding = entry.value_ptr.*;
        if (!binding.macro_arg_case_insensitive) continue;
        if (macroArgNameMatches(entry.key_ptr.*, name)) return binding;
    }
    return null;
}

fn macroArgNameMatches(stored: []const u8, query: []const u8) bool {
    const normalized_query = if (std.mem.endsWith(u8, query, "?"))
        query[0 .. query.len - 1]
    else
        query;
    return std.ascii.eqlIgnoreCase(stored, normalized_query);
}

fn usedMapContainsScopedDot(
    map: *const UsedMap,
    scope: []const u8,
    name: []const u8,
) bool {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (scopedDotNameMatches(entry.key_ptr.*, scope, name)) return true;
    }
    return false;
}

fn usedMapContainsSymbolName(map: *const UsedMap, name: []const u8) bool {
    if (map.contains(name)) return true;

    var it = map.iterator();
    while (it.next()) |entry| {
        if (symbolNamesConflict(entry.key_ptr.*, name)) return true;
    }
    return false;
}

fn scopedDotNameMatches(
    candidate: []const u8,
    scope: []const u8,
    name: []const u8,
) bool {
    if (name.len <= 1 or name[0] != '.') return false;
    if (std.mem.startsWith(u8, name, "..")) return false;
    if (candidate.len < scope.len) return false;
    if (!std.mem.eql(u8, candidate[0..scope.len], scope)) return false;
    const suffix = candidate[scope.len..];
    return std.mem.eql(u8, suffix, name) or caseInsensitiveSymbolNameMatches(suffix, name);
}

fn caseInsensitiveSymbolNameMatches(stored: []const u8, query: []const u8) bool {
    if (!std.mem.endsWith(u8, stored, "?")) return false;
    const stored_base = stored[0 .. stored.len - 1];
    const query_base = if (std.mem.endsWith(u8, query, "?")) query[0 .. query.len - 1] else query;
    return std.ascii.eqlIgnoreCase(stored_base, query_base);
}

fn symbolNamesConflict(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return true;
    if (!std.mem.endsWith(u8, left, "?") and !std.mem.endsWith(u8, right, "?")) return false;

    const left_base = if (std.mem.endsWith(u8, left, "?")) left[0 .. left.len - 1] else left;
    const right_base = if (std.mem.endsWith(u8, right, "?")) right[0 .. right.len - 1] else right;
    return std.ascii.eqlIgnoreCase(left_base, right_base);
}

fn putClonedBinding(
    allocator: Allocator,
    map: *BindingMap,
    name: []const u8,
    binding: SymbolBinding,
) Allocator.Error!void {
    const key = try allocator.dupe(u8, name);
    errdefer allocator.free(key);

    const owned_binding = try binding.clone(allocator);
    errdefer {
        var cleanup = owned_binding;
        cleanup.deinit(allocator);
    }

    const entry = try map.getOrPut(key);
    if (entry.found_existing) {
        allocator.free(key);
        entry.value_ptr.deinit(allocator);
    }
    entry.value_ptr.* = owned_binding;
}

fn putUsedKey(
    allocator: Allocator,
    map: *UsedMap,
    name: []const u8,
) Allocator.Error!void {
    if (map.contains(name)) return;

    const key = try allocator.dupe(u8, name);
    errdefer allocator.free(key);

    try map.put(key, {});
}

fn putUsedQueryResult(
    allocator: Allocator,
    map: *UsedQueryMap,
    name: []const u8,
    result: bool,
) Allocator.Error!void {
    const entry = try map.getOrPut(name);
    if (!entry.found_existing) {
        errdefer rollbackUsedQueryInsert(map, name);
        entry.key_ptr.* = try allocator.dupe(u8, name);
    }
    entry.value_ptr.* = result;
}

fn rollbackUsedQueryInsert(map: *UsedQueryMap, name: []const u8) void {
    std.debug.assert(map.remove(name));
}

fn putDefinitionCount(
    allocator: Allocator,
    map: *DefinitionCountMap,
    name: []const u8,
    count: usize,
) Allocator.Error!void {
    const entry = try map.getOrPut(name);
    if (!entry.found_existing) {
        errdefer rollbackDefinitionCountInsert(map, name);
        entry.key_ptr.* = try allocator.dupe(u8, name);
    }
    entry.value_ptr.* = count;
}

fn rollbackDefinitionCountInsert(map: *DefinitionCountMap, name: []const u8) void {
    std.debug.assert(map.remove(name));
}

fn definitionCount(map: *const DefinitionCountMap, name: []const u8) usize {
    if (map.get(name)) |count| return count;

    var it = map.iterator();
    while (it.next()) |entry| {
        if (symbolNamesConflict(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return 0;
}

fn cloneBindingMapInto(
    allocator: Allocator,
    dest: *BindingMap,
    source: *const BindingMap,
) Allocator.Error!void {
    var it = source.iterator();
    while (it.next()) |entry| {
        try putClonedBinding(allocator, dest, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn cloneDefinitionCountMapInto(
    allocator: Allocator,
    dest: *DefinitionCountMap,
    source: *const DefinitionCountMap,
) Allocator.Error!void {
    var it = source.iterator();
    while (it.next()) |entry| {
        try putDefinitionCount(allocator, dest, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn cloneUsedMapInto(
    allocator: Allocator,
    dest: *UsedMap,
    source: *const UsedMap,
) Allocator.Error!void {
    var it = source.iterator();
    while (it.next()) |entry| {
        try putUsedKey(allocator, dest, entry.key_ptr.*);
    }
}

fn cloneUsedQueryMapInto(
    allocator: Allocator,
    dest: *UsedQueryMap,
    source: *const UsedQueryMap,
) Allocator.Error!void {
    var it = source.iterator();
    while (it.next()) |entry| {
        try putUsedQueryResult(allocator, dest, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn bindingMapsEqual(left: *const BindingMap, right: *const BindingMap) bool {
    if (left.count() != right.count()) return false;

    var it = left.iterator();
    while (it.next()) |entry| {
        const other = right.get(entry.key_ptr.*) orelse return false;
        if (!entry.value_ptr.*.eql(other)) return false;
    }

    return true;
}

fn bindingMapDiff(category: SymbolStateDiffCategory, left: *const BindingMap, right: *const BindingMap) ?SymbolStateDiff {
    var it = left.iterator();
    while (it.next()) |entry| {
        const other = right.get(entry.key_ptr.*) orelse {
            return .{
                .category = category,
                .change = .added,
                .name = entry.key_ptr.*,
                .current_count = left.count(),
                .previous_count = right.count(),
                .current_value = entry.value_ptr.value,
                .current_size = entry.value_ptr.size,
                .current_type = entry.value_ptr.symbol_type,
            };
        };
        if (!entry.value_ptr.*.eql(other)) {
            return .{
                .category = category,
                .change = .changed,
                .name = entry.key_ptr.*,
                .current_count = left.count(),
                .previous_count = right.count(),
                .current_value = entry.value_ptr.value,
                .previous_value = other.value,
                .current_size = entry.value_ptr.size,
                .previous_size = other.size,
                .current_type = entry.value_ptr.symbol_type,
                .previous_type = other.symbol_type,
            };
        }
    }

    var rit = right.iterator();
    while (rit.next()) |entry| {
        if (!left.contains(entry.key_ptr.*)) {
            return .{
                .category = category,
                .change = .removed,
                .name = entry.key_ptr.*,
                .current_count = left.count(),
                .previous_count = right.count(),
                .previous_value = entry.value_ptr.value,
                .previous_size = entry.value_ptr.size,
                .previous_type = entry.value_ptr.symbol_type,
            };
        }
    }

    if (left.count() != right.count()) {
        return .{
            .category = category,
            .change = .count,
            .current_count = left.count(),
            .previous_count = right.count(),
        };
    }
    return null;
}

fn usedQueryMapsEqual(left: *const UsedQueryMap, right: *const UsedQueryMap) bool {
    if (left.count() != right.count()) return false;

    var it = left.iterator();
    while (it.next()) |entry| {
        const other = right.get(entry.key_ptr.*) orelse return false;
        if (entry.value_ptr.* != other) return false;
    }

    return true;
}

fn usedQueryMapDiff(left: *const UsedQueryMap, right: *const UsedQueryMap) ?SymbolStateDiff {
    var it = left.iterator();
    while (it.next()) |entry| {
        const other = right.get(entry.key_ptr.*) orelse {
            return .{
                .category = .used,
                .change = .added,
                .name = entry.key_ptr.*,
                .current_count = left.count(),
                .previous_count = right.count(),
                .current_value = @intFromBool(entry.value_ptr.*),
            };
        };
        if (entry.value_ptr.* != other) {
            return .{
                .category = .used,
                .change = .changed,
                .name = entry.key_ptr.*,
                .current_count = left.count(),
                .previous_count = right.count(),
                .current_value = @intFromBool(entry.value_ptr.*),
                .previous_value = @intFromBool(other),
            };
        }
    }

    var rit = right.iterator();
    while (rit.next()) |entry| {
        if (!left.contains(entry.key_ptr.*)) {
            return .{
                .category = .used,
                .change = .removed,
                .name = entry.key_ptr.*,
                .current_count = left.count(),
                .previous_count = right.count(),
                .previous_value = @intFromBool(entry.value_ptr.*),
            };
        }
    }

    if (left.count() != right.count()) {
        return .{
            .category = .used,
            .change = .count,
            .current_count = left.count(),
            .previous_count = right.count(),
        };
    }
    return null;
}

fn removeBindingIfPresent(
    allocator: Allocator,
    map: *BindingMap,
    name: []const u8,
) void {
    const removed = map.fetchRemove(name) orelse return;
    allocator.free(removed.key);
    var binding = removed.value;
    binding.deinit(allocator);
}

fn removeConflictingBindingIfPresent(
    allocator: Allocator,
    map: *BindingMap,
    name: []const u8,
) void {
    const entry = findBindingEntryInMap(map, name) orelse return;
    removeBindingIfPresent(allocator, map, entry.key);
}

fn removePrefixedBindings(
    allocator: Allocator,
    map: *BindingMap,
    prefix: []const u8,
) Allocator.Error!void {
    var doomed: std.ArrayList([]const u8) = .empty;
    defer {
        for (doomed.items) |name| allocator.free(name);
        doomed.deinit(allocator);
    }

    var it = map.iterator();
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
        const owned_name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(owned_name);
        try doomed.append(allocator, owned_name);
    }

    for (doomed.items) |name| removeBindingIfPresent(allocator, map, name);
}

fn updateAreaLabelSizesInMap(
    map: *BindingMap,
    area_index: usize,
    area_is_virtual: bool,
    area_size: usize,
) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.is_area_label and
            entry.value_ptr.area_index == area_index and
            entry.value_ptr.area_is_virtual == area_is_virtual)
        {
            entry.value_ptr.size = area_size;
        }
    }
}

fn markAreaVariableInMap(
    map: *BindingMap,
    area_index: usize,
    area_is_virtual: bool,
) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.is_area_label and
            entry.value_ptr.area_index == area_index and
            entry.value_ptr.area_is_virtual == area_is_virtual)
        {
            entry.value_ptr.area_variable = true;
        }
    }
}

fn optionalTextEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_text| {
        const right_text = right orelse return false;
        return std.mem.eql(u8, left_text, right_text);
    }
    return right == null;
}

fn optionalBytesEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_bytes| {
        const right_bytes = right orelse return false;
        return std.mem.eql(u8, left_bytes, right_bytes);
    }
    return right == null;
}

fn binaryPrefixWord(bytes: []const u8) usize {
    var value: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (index >= @sizeOf(usize)) break;
        value |= @as(usize, byte) << @intCast(index * 8);
    }
    return value;
}

fn releaseBindingMap(allocator: Allocator, map: *BindingMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

fn resetBindingMap(allocator: Allocator, map: *BindingMap) void {
    releaseBindingMap(allocator, map);
    map.* = BindingMap.init(allocator);
}

fn releaseUsedMap(allocator: Allocator, map: *UsedMap) void {
    var it = map.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    map.deinit();
}

fn resetUsedMap(allocator: Allocator, map: *UsedMap) void {
    releaseUsedMap(allocator, map);
    map.* = UsedMap.init(allocator);
}

fn releaseUsedQueryMap(allocator: Allocator, map: *UsedQueryMap) void {
    var it = map.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    map.deinit();
}

fn resetUsedQueryMap(allocator: Allocator, map: *UsedQueryMap) void {
    releaseUsedQueryMap(allocator, map);
    map.* = UsedQueryMap.init(allocator);
}

fn releaseDefinitionCountMap(allocator: Allocator, map: *DefinitionCountMap) void {
    var it = map.iterator();
    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
    map.deinit();
}

fn resetDefinitionCountMap(allocator: Allocator, map: *DefinitionCountMap) void {
    releaseDefinitionCountMap(allocator, map);
    map.* = DefinitionCountMap.init(allocator);
}

test "SymbolStore carries defined and used state across passes" {
    const testing = std.testing;

    var store = try SymbolStore.init(testing.allocator);
    defer store.deinit();

    try store.resetForPass(false);
    try testing.expect(!store.queryDefined("future"));
    try testing.expect(!store.queryDefinite("future"));
    try testing.expect(store.hasPendingStateQueries());

    try store.defineValue("future", .label, 0x20, 0, null);
    try store.markUsed("future");

    try store.resetForPass(true);
    try testing.expect(store.queryDefined("future"));
    try testing.expect(!store.queryDefinite("future"));
    try testing.expect(try store.queryUsed("future"));
    try testing.expectEqual(@as(?usize, 0x20), try store.lookupValue("future"));
}

test "SymbolStore keeps used query result changes in pass convergence state" {
    const testing = std.testing;

    var store = try SymbolStore.init(testing.allocator);
    defer store.deinit();

    try store.resetForPass(false);
    try testing.expect(!(try store.queryUsed("lazy_slot")));
    try store.markUsed("lazy_slot");

    try store.resetForPass(true);
    try testing.expect(try store.queryUsed("lazy_slot"));
    try testing.expect(!store.sameSymbolState());

    try store.resetForPass(true);
    try store.markUsed("lazy_slot");
    try testing.expect(try store.queryUsed("lazy_slot"));
    try testing.expect(store.sameSymbolState());
}

test "SymbolStore injects builtins on every pass" {
    const testing = std.testing;

    var store = try SymbolStore.init(testing.allocator);
    defer store.deinit();

    try store.resetForPass(false);
    try testing.expectEqual(@as(?usize, 1), try store.lookupValue("byte"));
    try testing.expectEqual(@as(?usize, 6), try store.lookupValue("pword"));
    try testing.expectEqual(@as(?usize, 6), try store.lookupValue("fword"));
    try testing.expectEqual(@as(?usize, 8), try store.lookupValue("qword"));
    try testing.expectEqual(@as(?usize, 10), try store.lookupValue("tbyte"));
    try testing.expectEqual(@as(?usize, 10), try store.lookupValue("tword"));
    try testing.expectEqual(@as(?usize, 16), try store.lookupValue("xword"));
    try testing.expectEqual(@as(?usize, 32), try store.lookupValue("yword"));
    try testing.expectEqual(@as(?usize, 64), try store.lookupValue("zword"));

    try store.defineValue("byte", .variable, 9, 0, null);
    try testing.expectEqual(@as(?usize, 9), try store.lookupValue("byte"));

    try store.resetForPass(true);
    try testing.expectEqual(@as(?usize, 1), try store.lookupValue("byte"));
}

test "SymbolStore runtime text preserves text payloads" {
    const testing = std.testing;

    var store = try SymbolStore.init(testing.allocator);
    defer store.deinit();

    try store.resetForPass(false);
    try store.setRuntimeText("target.os", "'windows'");
    try testing.expectEqualStrings("'windows'", (try store.lookupText("target.os")).?);
    try testing.expectEqualStrings("'windows'", (try store.lookupRawText("target.os")).?);
}

test "SymbolStore macro frames preserve text and raw text lookup" {
    const testing = std.testing;

    var store = try SymbolStore.init(testing.allocator);
    defer store.deinit();

    try store.enterMacro();
    defer store.exitMacro();

    try store.setMacroArgTextWithRaw("arg", "env.OS", " env.OS ");
    try testing.expectEqualStrings("env.OS", store.lookupMacroArgText("arg").?);
    try testing.expectEqualStrings(" env.OS ", store.lookupMacroArgRawText("arg").?);
}

test "SymbolStore macro frames support case-insensitive parameter lookup with optional question mark" {
    const testing = std.testing;

    var store = try SymbolStore.init(testing.allocator);
    defer store.deinit();

    try store.enterMacro();
    defer store.exitMacro();

    try store.setMacroArgTextWithRawCase("Value", "7", "7", true);
    try testing.expectEqualStrings("7", store.lookupMacroArgText("value").?);
    try testing.expectEqualStrings("7", store.lookupMacroArgText("VALUE?").?);
    try testing.expectEqualStrings("7", store.lookupMacroArgRawText("vAlUe").?);
}

test "SymbolStore first pass clears stale previous snapshots" {
    const testing = std.testing;

    var store = try SymbolStore.init(testing.allocator);
    defer store.deinit();

    try store.resetForPass(false);
    try store.defineValue("future", .label, 0x20, 0, null);
    try store.resetForPass(true);
    try testing.expect(store.hasPreviousSnapshot());

    try store.resetForPass(false);
    try testing.expect(!store.hasPreviousSnapshot());
    try testing.expectEqual(@as(?usize, null), try store.lookupValue("future"));
    try testing.expect(!store.queryDefined("future"));
}

test "SymbolStore resetForPass keeps snapshots atomic when clone fails" {
    const testing = std.testing;

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var store = try SymbolStore.init(failing.allocator());
    defer store.deinit();

    try store.resetForPass(false);
    try store.defineExpressionSized("old_var", .variable, 0x10, 4, "old_var + 1");
    try store.setRuntimeValue("old.runtime", 0x11);
    try store.markUsed("old_used");
    try testing.expect(!(try store.queryUsed("old_query")));

    try store.resetForPass(true);
    try testing.expect(store.hasPreviousSnapshot());

    try store.defineExpressionSized("new_var", .variable, 0x20, 4, "new_var + 1");
    try store.setRuntimeValue("new.runtime", 0x21);
    try store.markUsed("new_used");
    try testing.expect(!(try store.queryUsed("new_query")));

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try testing.expectError(error.OutOfMemory, store.resetForPass(true));

    try testing.expect(store.hasPreviousSnapshot());
    try testing.expectEqual(@as(usize, 0x10), store.peekPreviousBinding("old_var").?.value);
    try testing.expectEqual(@as(usize, 0x11), store.peekPreviousBinding("old.runtime").?.value);
    try testing.expectEqual(@as(?SymbolBinding, null), store.peekPreviousBinding("new_var"));
    try testing.expect(store.used_previous.contains("old_used"));
    try testing.expect(!store.used_previous.contains("new_used"));
    try testing.expectEqual(false, store.used_queries_previous.get("old_query").?);
    try testing.expectEqual(@as(?bool, null), store.used_queries_previous.get("new_query"));
    try testing.expectEqual(@as(usize, 1), definitionCount(&store.variable_definition_counts_previous, "old_var"));
    try testing.expectEqual(@as(usize, 0), definitionCount(&store.variable_definition_counts_previous, "new_var"));

    try testing.expectEqual(@as(usize, 0x20), store.peekBinding("new_var", false).?.value);
    try testing.expectEqual(@as(usize, 0x21), store.peekBinding("new.runtime", false).?.value);
    try testing.expect(store.used_current.contains("new_used"));
    try testing.expectEqual(false, store.used_queries_current.get("new_query").?);
    try testing.expectEqual(@as(usize, 1), definitionCount(&store.variable_definition_counts_current, "new_var"));
}

test "SymbolStore compares semantic symbol state instead of allocation identity" {
    const testing = std.testing;

    var store = try SymbolStore.init(testing.allocator);
    defer store.deinit();

    try store.resetForPass(false);
    try store.defineValue("stable", .label, 0x20, 4, "org_base");
    try store.setRuntimeText("target.arch", "'x86_64'");
    try testing.expectEqual(@as(?usize, 0x20), try store.lookupValue("stable"));

    try store.resetForPass(true);
    try store.defineValue("stable", .label, 0x20, 4, "org_base");
    try store.setRuntimeText("target.arch", "'x86_64'");
    try testing.expectEqual(@as(?usize, 0x20), try store.lookupValue("stable"));

    try testing.expect(store.sameSymbolState());

    try store.setRuntimeText("target.arch", "'aarch64'");
    try testing.expect(!store.sameSymbolState());
}

test "SymbolStore applies constant and label write rules" {
    const testing = std.testing;

    var store = try SymbolStore.init(testing.allocator);
    defer store.deinit();

    try store.resetForPass(false);

    try store.defineExpression("step", .variable, 1, "1");
    try store.defineExpression("step", .variable, 2, "2");
    try testing.expectEqual(@as(?usize, 2), try store.lookupValue("step"));
    try testing.expectEqualStrings("2", (try store.lookupText("step")).?);

    try store.defineExpression("base", .constant, 1, "1");
    try testing.expectError(
        error.CannotRedefineConstant,
        store.defineExpression("base", .variable, 2, "2"),
    );

    try testing.expectError(
        error.SymbolAlreadyDefined,
        store.defineExpression("step", .constant, 3, "3"),
    );

    try store.defineLabel("anchor", 0x34, 2, "target");
    const anchor = store.peekBinding("anchor", false).?;
    try testing.expectEqual(SymbolType.label, anchor.symbol_type);
    try testing.expectEqual(@as(usize, 0x34), anchor.value);
    try testing.expectEqual(@as(usize, 2), anchor.size);
    try testing.expectEqualStrings("target", anchor.text.?);
    try testing.expect(!anchor.expandable);
}

test "SymbolStore keeps binary payloads for load/store and emitter reuse" {
    const testing = std.testing;

    var store = try SymbolStore.init(testing.allocator);
    defer store.deinit();

    try store.resetForPass(false);
    try store.defineBinary("blob", &.{ 0x11, 0x22, 0x33, 0x44, 0x55 });

    const blob = (try store.lookupBinary("blob")).?;
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44, 0x55 }, blob);

    const binding = store.peekBinding("blob", false).?;
    try testing.expectEqual(@as(usize, 5), binding.size);
    try testing.expectEqual(@as(usize, 0x5544332211), binding.value);
}

fn symbolBindingCloneAllocatorProbe(allocator: Allocator) !void {
    const binding = SymbolBinding{
        .symbol_type = .label,
        .value = 0x1234,
        .size = 4,
        .text = "target",
        .raw_text = " target ",
        .binary = &.{ 0x11, 0x22, 0x33 },
        .is_defined = true,
        .expandable = true,
        .is_runtime = true,
        .area_index = 2,
        .member_address = 0x40,
        .member_area_index = 3,
        .member_value_symbol = true,
        .macro_arg_case_insensitive = true,
    };

    var cloned = try binding.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expect(binding.eql(cloned));
}

test "SymbolBinding.clone releases partial ownership across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        symbolBindingCloneAllocatorProbe,
        .{},
    );
}

fn structureScopeAllocatorProbe(allocator: Allocator) !void {
    var store = try SymbolStore.init(allocator);
    defer store.deinit();

    try store.enterStructureScope("S");
    try store.enterStructureScope("S.inner");
    try std.testing.expectEqualStrings("S.inner", store.currentStructureScopePath());
}

test "SymbolStore structure scopes release partial ownership across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        structureScopeAllocatorProbe,
        .{},
    );
}

fn readMemberValueProbe(
    multiplier: *usize,
    area_index: ?usize,
    area_is_virtual: bool,
    address: usize,
    size: usize,
) error{}!usize {
    multiplier.* += 1;
    return address + size + if (area_is_virtual) if (area_index) |index| index else 0 else 0;
}

test "SymbolStore carries instance member address metadata and refresh hooks" {
    const testing = std.testing;

    var store = try SymbolStore.init(testing.allocator);
    defer store.deinit();

    try store.resetForPass(false);
    try store.defineInstanceMemberValue("pt.x", 0x11, 2, 0x40, null);
    try store.defineInstanceMemberValue("node.y", 0x22, 1, 0x80, 3);

    const pt_binding = store.peekBinding("pt.x", false).?;
    try testing.expect(pt_binding.member_value_symbol);
    try testing.expectEqual(@as(?usize, 0x40), pt_binding.member_address);
    try testing.expectEqual(@as(?usize, null), pt_binding.member_area_index);

    const node_address = store.lookupMemberRuntimeAddress("node.y").?;
    try testing.expectEqual(@as(?usize, 3), node_address.area_index);
    try testing.expect(node_address.area_is_virtual);
    try testing.expectEqual(@as(usize, 0x80), node_address.address);

    var reads: usize = 0;
    try store.refreshInstanceMemberValues(error{}, &reads, readMemberValueProbe);
    try testing.expectEqual(@as(usize, 2), reads);
    try testing.expectEqual(@as(?usize, 0x42), try store.lookupValue("pt.x"));
    try testing.expectEqual(@as(?usize, 0x84), try store.lookupValue("node.y"));

    try store.resetForPass(true);
    const previous_address = store.lookupMemberRuntimeAddress("node.y").?;
    try testing.expectEqual(@as(?usize, 3), previous_address.area_index);
    try testing.expect(previous_address.area_is_virtual);
    try testing.expectEqual(@as(usize, 0x80), previous_address.address);
}

test "SymbolStore updates area label sizes and compares metadata in convergence state" {
    const testing = std.testing;

    var store = try SymbolStore.init(testing.allocator);
    defer store.deinit();

    try store.resetForPass(false);
    try store.defineAreaLabel("Data::", 0x200, 4, 7);
    store.updateAreaLabelSizes(7, 9);

    const data_label = store.peekBinding("Data::", false).?;
    try testing.expectEqual(@as(usize, 9), data_label.size);
    try testing.expectEqual(@as(?usize, 7), data_label.area_index);

    try store.resetForPass(true);
    try store.defineAreaLabel("Data::", 0x200, 9, 7);
    try testing.expect(store.sameSymbolState());

    try store.defineInstanceMemberValue("Data.value", 0x33, 1, 0x220, 7);
    try testing.expect(!store.sameSymbolState());
}

test "SymbolStore peekBinding stays side-effect free while lookupBinding records usage" {
    const testing = std.testing;

    var store = try SymbolStore.init(testing.allocator);
    defer store.deinit();

    try store.resetForPass(false);
    try store.defineValue("tracked", .label, 0x20, 0, null);
    const peeked = store.peekBinding("tracked", true).?;
    try testing.expectEqual(@as(usize, 0x20), peeked.value);

    try store.resetForPass(true);
    try store.defineValue("tracked", .label, 0x20, 0, null);
    try testing.expect(!(try store.queryUsed("tracked")));

    const looked_up = (try store.lookupBinding("tracked", true)).?;
    try testing.expectEqual(@as(usize, 0x20), looked_up.value);
    try testing.expect(try store.queryUsed("tracked"));
}
