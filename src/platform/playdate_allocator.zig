const std = @import("std");
const pdapi = @import("../playdate_api_definitions.zig");

pub const Stats = struct {
    allocations: usize = 0,
    frees: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,
};

/// Adapts the Playdate-owned heap to Zig's allocator interface.
///
/// This owns no memory itself. Every allocation returned here must be released
/// through the same allocator. The adapter intentionally refuses alignments the
/// Playdate C allocator cannot promise, rather than returning a misaligned
/// pointer to Zig code.
pub const PlaydateAllocator = struct {
    system: *const pdapi.PlaydateSys,
    stats: Stats = .{},

    pub fn init(system: *const pdapi.PlaydateSys) PlaydateAllocator {
        return .{ .system = system };
    }

    pub fn allocator(self: *PlaydateAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *PlaydateAllocator = @ptrCast(@alignCast(ctx));
        if (!supportsAlignment(alignment)) return null;

        const memory = self.system.realloc(null, len) orelse return null;
        self.recordAllocation(len);
        return @ptrCast(memory);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        // realloc() may move memory, so only remap() can safely use it.
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *PlaydateAllocator = @ptrCast(@alignCast(ctx));
        if (!supportsAlignment(alignment)) return null;

        const resized = self.system.realloc(memory.ptr, new_len) orelse return null;
        if (new_len >= memory.len) {
            self.recordAllocation(new_len - memory.len);
        } else {
            self.stats.live_bytes -= memory.len - new_len;
        }
        return @ptrCast(resized);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const self: *PlaydateAllocator = @ptrCast(@alignCast(ctx));
        _ = self.system.realloc(memory.ptr, 0);
        self.stats.frees += 1;
        self.stats.live_bytes -= memory.len;
    }

    fn supportsAlignment(alignment: std.mem.Alignment) bool {
        return alignment.toByteUnits() <= @alignOf(usize);
    }

    fn recordAllocation(self: *PlaydateAllocator, byte_count: usize) void {
        self.stats.allocations += 1;
        self.stats.live_bytes += byte_count;
        self.stats.peak_live_bytes = @max(self.stats.peak_live_bytes, self.stats.live_bytes);
    }
};
