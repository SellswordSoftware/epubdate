const std = @import("std");

pub const total_ms: u16 = 600;
pub const complete: u16 = 1_000;
pub const card_stagger_ms: u16 = 35;
pub const card_travel_ms: u16 = 400;

/// A short ease-out entrance shared by the Library chrome and its rows.
pub const State = struct {
    started_at: u32 = 0,
    active: bool = false,

    pub fn begin(self: *State, now_ms: u32) void {
        self.* = .{ .started_at = now_ms, .active = true };
    }

    pub fn cancel(self: *State) void {
        self.active = false;
    }

    /// Returns 0..1000. A quadratic ease-out gets the Library responsive
    /// quickly while leaving a small, soft settle at the end.
    pub fn progress(self: *State, now_ms: u32) u16 {
        if (!self.active) return complete;
        const elapsed = now_ms -% self.started_at;
        if (elapsed >= total_ms) {
            self.active = false;
            return complete;
        }
        return easedProgress(@intCast(elapsed), total_ms);
    }

    /// Delays one card while retaining a fixed travel time. The top card lands
    /// first and each lower card lands later, all within the shared entrance.
    pub fn staggeredProgress(self: *const State, now_ms: u32, delay_ms: u16) u16 {
        if (!self.active) return complete;
        const elapsed: u16 = @intCast(@min(now_ms -% self.started_at, @as(u32, total_ms)));
        if (elapsed <= delay_ms) return 0;
        const travel = elapsed - delay_ms;
        if (travel >= card_travel_ms) return complete;
        return easedProgress(travel, card_travel_ms);
    }
};

fn easedProgress(elapsed: u16, duration: u16) u16 {
    const linear: u32 = (@as(u32, elapsed) * complete) / duration;
    const remaining = complete - linear;
    return @intCast(complete - (remaining * remaining) / complete);
}

test "Library entrance reaches its destination in 600ms with a fast ease-out" {
    var state: State = .{};
    state.begin(100);
    try std.testing.expectEqual(@as(u16, 0), state.progress(100));
    try std.testing.expect(state.progress(400) > 700);
    try std.testing.expectEqual(complete, state.progress(700));
    try std.testing.expect(!state.active);
}

test "lower Library cards start and finish later" {
    var state: State = .{};
    state.begin(100);
    try std.testing.expectEqual(@as(u16, 0), state.staggeredProgress(130, card_stagger_ms));
    try std.testing.expect(state.staggeredProgress(300, card_stagger_ms) > state.staggeredProgress(300, card_stagger_ms * 4));
    try std.testing.expectEqual(complete, state.staggeredProgress(500, 0));
    try std.testing.expect(state.staggeredProgress(500, card_stagger_ms * 5) < complete);
    try std.testing.expectEqual(complete, state.staggeredProgress(700, card_stagger_ms * 6));
}
