const std = @import("std");

pub const band_count: u8 = 10;
pub const stagger_ms: u16 = 15;
pub const total_ms: u16 = 300;
pub const travel_ms: u16 = total_ms - stagger_ms * (band_count - 1);

pub const Direction = enum { forward, backward };

pub const State = struct {
    source_page: ?u32 = null,
    direction: Direction = .forward,
    started_at: u32 = 0,
    active: bool = false,

    pub fn begin(self: *State, source_page: ?u32, direction: Direction, now_ms: u32) void {
        self.* = .{ .source_page = source_page, .direction = direction, .started_at = now_ms, .active = true };
    }

    pub fn cancel(self: *State) void {
        self.active = false;
    }

    pub fn elapsed(self: *State, now_ms: u32) ?u16 {
        if (!self.active) return null;
        const value = now_ms -% self.started_at;
        if (value >= total_ms) {
            self.active = false;
            return null;
        }
        return @intCast(value);
    }
};

/// Returns 0..screen_width for one band's horizontal travel. Forward begins
/// at the bottom; backward begins at the top.
pub fn bandOffset(elapsed_ms: u16, band: u8, direction: Direction, screen_width: u16) u16 {
    std.debug.assert(band < band_count);
    const order: u16 = switch (direction) {
        .forward => band_count - 1 - band,
        .backward => band,
    };
    const delay = order * stagger_ms;
    if (elapsed_ms <= delay) return 0;
    const local = @min(elapsed_ms - delay, travel_ms);
    return @intCast((@as(u32, screen_width) * local) / travel_ms);
}

test "ten bands stagger within one 300ms transition" {
    try std.testing.expectEqual(@as(u16, 165), travel_ms);
    try std.testing.expectEqual(@as(u16, 0), bandOffset(1, 0, .forward, 400));
    try std.testing.expect(bandOffset(1, 9, .forward, 400) > 0);
    try std.testing.expect(bandOffset(1, 0, .backward, 400) > 0);
    try std.testing.expectEqual(@as(u16, 0), bandOffset(1, 9, .backward, 400));
    try std.testing.expectEqual(@as(u16, 400), bandOffset(300, 0, .forward, 400));
    try std.testing.expectEqual(@as(u16, 400), bandOffset(300, 9, .forward, 400));
}
