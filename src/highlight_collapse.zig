const std = @import("std");

pub const total_ms: u16 = 140;
pub const complete: u16 = 1_000;

pub const State = struct {
    started_at: u32 = 0,
    active: bool = false,

    pub fn begin(self: *State, now_ms: u32) void {
        self.* = .{ .started_at = now_ms, .active = true };
    }

    pub fn cancel(self: *State) void {
        self.active = false;
    }

    /// Remaining visible fraction, from 1000 to 0.
    pub fn remaining(self: *State, now_ms: u32) ?u16 {
        if (!self.active) return null;
        const elapsed = now_ms -% self.started_at;
        if (elapsed >= total_ms) {
            self.active = false;
            return null;
        }
        return @intCast(complete - (@as(u32, elapsed) * complete) / total_ms);
    }
};

pub fn height(full_height: c_int, remaining_fraction: u16) c_int {
    return @intCast(@divTrunc(@as(i32, full_height) * remaining_fraction, complete));
}

test "highlight collapse reaches zero in 140ms" {
    var state: State = .{};
    state.begin(100);
    try std.testing.expectEqual(@as(u16, complete), state.remaining(100).?);
    try std.testing.expect(height(20, state.remaining(170).?) < 20);
    try std.testing.expect(state.remaining(240) == null);
}
