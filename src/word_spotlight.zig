const std = @import("std");

pub const total_ms: u16 = 350;
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

    /// A fast ease-out produces a decisive focus pull toward the word.
    pub fn progress(self: *State, now_ms: u32) ?u16 {
        if (!self.active) return null;
        const elapsed = now_ms -% self.started_at;
        if (elapsed >= total_ms) {
            self.active = false;
            return null;
        }
        const linear: u32 = (@as(u32, elapsed) * complete) / total_ms;
        const remaining = complete - linear;
        return @intCast(complete - (remaining * remaining) / complete);
    }
};

pub fn diameter(start: c_int, finish: c_int, progress: u16) c_int {
    return finish + @divTrunc((start - finish) * @as(c_int, complete - progress), complete);
}

test "spotlight begins screen-sized and settles on its target" {
    var state: State = .{};
    state.begin(100);
    try std.testing.expectEqual(@as(u16, 0), state.progress(100).?);
    try std.testing.expect(diameter(1_200, 24, state.progress(275).?) < 400);
    try std.testing.expect(state.progress(450) == null);
}
