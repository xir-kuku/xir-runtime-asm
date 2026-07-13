const std = @import("std");
const page_allocator = std.heap.page_allocator;
const page_size = std.heap.page_size_min;

/// Executable memory backed by OS pages.
///
/// Cross-platform: uses `page_allocator` (mmap/VirtualAlloc) for allocation,
/// and `protectMemory` (mprotect/NtProtectVirtualMemory) for protection changes.
/// No `if (windows)` / `if (linux)` — Zig stdlib is the abstraction.
///
/// Stores allocation size at `alloc_start` (before `code_ptr`) so that
/// `deinit()` can free without the caller tracking size.
pub const ExecMemory = struct {
    code_ptr: [*]u8,
    code_len: usize,
    alloc_start: [*]u8,
    alloc_len: usize,

    pub fn allocate(code: []const u8) !ExecMemory {
        const header_size = @sizeOf(usize);
        const total = header_size + code.len;
        const aligned = std.mem.alignForward(usize, total, page_size);

        const raw = try page_allocator.alloc(u8, aligned);
        errdefer page_allocator.free(raw);

        const header_bytes = std.mem.asBytes(&aligned);
        if (header_size > 0) @memcpy(raw[0..header_size], header_bytes);
        if (code.len > 0) @memcpy(raw[header_size..][0..code.len], code);

        const page_aligned: []align(page_size) u8 = @alignCast(raw);
        try std.process.protectMemory(page_aligned, .{ .read = true, .execute = true });

        return .{
            .code_ptr = raw[header_size..].ptr,
            .code_len = code.len,
            .alloc_start = raw.ptr,
            .alloc_len = aligned,
        };
    }

    fn freeAllocation(alloc_start: [*]u8, alloc_len: usize) void {
        const slice: []align(page_size) u8 = @alignCast(alloc_start[0..alloc_len]);
        std.process.protectMemory(slice, .{ .read = true, .write = true }) catch {};
        // cleanup: must restore RW before free — Allocator.free @memset(undefined)
        // before rawFree, which crashes on RX pages. If protectMemory fails here
        // we're already in an unrecoverable state (OS denied permission on our own
        // allocation); the subsequent free will likely segfault.
        page_allocator.free(slice);
    }

    pub fn freeCodePtr(code: ?*anyopaque) void {
        const ptr = code orelse return;
        const bytes: [*]u8 = @ptrCast(ptr);
        const header_size = @sizeOf(usize);
        const alloc_start = bytes - header_size;
        const header_bytes = alloc_start[0..header_size];
        const alloc_len = std.mem.bytesAsSlice(usize, header_bytes)[0];
        freeAllocation(alloc_start, alloc_len);
    }

    pub fn deinit(self: *ExecMemory) void {
        freeAllocation(self.alloc_start, self.alloc_len);
        self.* = undefined;
    }
};
