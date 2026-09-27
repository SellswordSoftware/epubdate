const std = @import("std");

pub const window_ms: u32 = 2_000;
const capacity: usize = 8;

/// Fixed-memory, recent-only rate tracker for forward manual RSVP advances.
/// It intentionally has no persistence or relationship to reading statistics.
pub const Tracker = struct {
    timestamps: [capacity]u32 = undefined,
    first: u3 = 0,
    count: u4 = 0,

    pub fn clear(self: *Tracker) void {
        self.* = .{};
    }

    pub fn record(self: *Tracker, now_ms: u32) void {
        if (self.count < capacity) {
            self.timestamps[self.index(self.count)] = now_ms;
            self.count += 1;
            return;
        }
        self.timestamps[self.first] = now_ms;
        self.first = @intCast((@as(usize, self.first) + 1) % capacity);
    }

    /// Returns no value until at least two advances occur in the rolling
    /// window. Once the newest sample ages out, the UI naturally disappears.
    pub fn wpm(self: *const Tracker, now_ms: u32) ?u16 {
        var oldest: ?u32 = null;
        var newest: u32 = 0;
        var samples: u8 = 0;
        for (0..self.count) |offset| {
            const timestamp = self.timestamps[self.index(@intCast(offset))];
            if (now_ms -% timestamp > window_ms) continue;
            if (oldest == null) oldest = timestamp;
            newest = timestamp;
            samples += 1;
        }
        if (samples < 2) return null;
        const elapsed = newest -% oldest.?;
        if (elapsed == 0) return null;
        const value: u32 = (@as(u32, samples - 1) * 60_000) / elapsed;
        if (value == 0) return null;
        return @intCast(@min(value, std.math.maxInt(u16)));
    }

    fn index(self: *const Tracker, offset: u4) usize {
        return (@as(usize, self.first) + offset) % capacity;
    }
};

test "recent forward advances produce WPM and expire after the short window" {
    var tracker: Tracker = .{};
    tracker.record(1_000);
    tracker.record(1_100);
    try std.testing.expectEqual(@as(?u16, 600), tracker.wpm(1_200));
    try std.testing.expect(tracker.wpm(3_101) == null);
}

test "clearing a manual session removes its live rate" {
    var tracker: Tracker = .{};
    tracker.record(1_000);
    tracker.record(1_200);
    tracker.clear();
    try std.testing.expect(tracker.wpm(1_300) == null);
}
