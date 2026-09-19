const std = @import("std");

// Page text is stored in fixed PageCache slots rather than dynamically packed.
// This separate index holds only semantic checkpoints: it never stores a ZIP
// offset or DEFLATE state, so a cache miss must restart at the chapter start.
pub const capacity = 3;

pub const Entry = struct {
    valid: bool = false,
    chapter: u8 = 0,
    page: u32 = 0,
    normalized_event: u32 = 0,
    decoded_offset: u32 = 0,
    byte_count: usize = 0,
    last_used: u32 = 0,
};

/// Metadata-only LRU.  Page pixels/text remain caller-owned; this policy is
/// host-testable without Playdate APIs or a ZIP stream.
pub const Policy = struct {
    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
    byte_budget: usize,
    bytes_used: usize = 0,
    clock: u32 = 0,
    evictions: u32 = 0,

    pub fn init(byte_budget: usize) Policy {
        return .{ .byte_budget = byte_budget };
    }

    pub fn findAndTouch(self: *Policy, chapter: u8, page: u32) ?usize {
        for (&self.entries, 0..) |*entry, index| {
            if (entry.valid and entry.chapter == chapter and entry.page == page) {
                entry.last_used = self.tick();
                return index;
            }
        }
        return null;
    }

    /// Makes room and returns the slot assigned to the key.  Returns null
    /// only when a single page itself exceeds the configured byte budget.
    pub fn admit(self: *Policy, chapter: u8, page: u32, normalized_event: u32, decoded_offset: u32, byte_count: usize) ?usize {
        if (byte_count > self.byte_budget) return null;
        if (self.findAndTouch(chapter, page)) |index| {
            const entry = &self.entries[index];
            self.bytes_used -= entry.byte_count;
            entry.byte_count = byte_count;
            entry.normalized_event = normalized_event;
            entry.decoded_offset = decoded_offset;
            self.bytes_used += byte_count;
            while (self.bytes_used > self.byte_budget) self.evictOldest();
            return index;
        }
        while (self.bytes_used + byte_count > self.byte_budget) self.evictOldest();
        var slot: ?usize = null;
        for (self.entries, 0..) |entry, index| {
            if (!entry.valid) {
                slot = index;
                break;
            }
        }
        if (slot == null) {
            self.evictOldest();
            for (self.entries, 0..) |entry, index| {
                if (!entry.valid) {
                    slot = index;
                    break;
                }
            }
        }
        const index = slot orelse unreachable;
        self.entries[index] = .{
            .valid = true,
            .chapter = chapter,
            .page = page,
            .normalized_event = normalized_event,
            .decoded_offset = decoded_offset,
            .byte_count = byte_count,
            .last_used = self.tick(),
        };
        self.bytes_used += byte_count;
        return index;
    }

    fn evictOldest(self: *Policy) void {
        var oldest: ?usize = null;
        for (self.entries, 0..) |entry, index| {
            if (!entry.valid) continue;
            if (oldest == null or entry.last_used < self.entries[oldest.?].last_used) oldest = index;
        }
        const index = oldest orelse unreachable;
        self.bytes_used -= self.entries[index].byte_count;
        self.entries[index].valid = false;
        self.entries[index].byte_count = 0;
        self.evictions += 1;
    }

    fn tick(self: *Policy) u32 {
        self.clock +%= 1;
        return self.clock;
    }
};

test "evicts least recently used pages to satisfy the byte budget" {
    var policy = Policy.init(10);
    _ = policy.admit(0, 1, 10, 100, 4);
    _ = policy.admit(0, 2, 20, 200, 4);
    _ = policy.findAndTouch(0, 1);
    _ = policy.admit(0, 3, 30, 300, 4);
    try std.testing.expect(policy.findAndTouch(0, 1) != null);
    try std.testing.expect(policy.findAndTouch(0, 2) == null);
    try std.testing.expect(policy.findAndTouch(0, 3) != null);
    try std.testing.expectEqual(@as(usize, 8), policy.bytes_used);
    try std.testing.expectEqual(@as(u32, 1), policy.evictions);
}

test "updates a page in place and rejects an oversized page" {
    var policy = Policy.init(8);
    const first = policy.admit(2, 9, 90, 900, 3).?;
    const updated = policy.admit(2, 9, 91, 901, 6).?;
    try std.testing.expectEqual(first, updated);
    try std.testing.expectEqual(@as(usize, 6), policy.bytes_used);
    try std.testing.expectEqual(@as(u32, 91), policy.entries[updated].normalized_event);
    try std.testing.expectEqual(@as(u32, 901), policy.entries[updated].decoded_offset);
    try std.testing.expect(policy.admit(2, 10, 0, 0, 9) == null);
}
