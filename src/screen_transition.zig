const std = @import("std");

/// A full screen fade uses the supplied 5%-through-95% LCD dither ramp in
/// each direction, with a single background-only frame between the views.
pub const half_ms: u16 = 200;
pub const total_ms: u16 = half_ms * 2;
pub const pattern_count: usize = 19;

pub const Phase = union(enum) {
    outgoing: u8,
    background,
    incoming: u8,
    complete,
};

pub const State = struct {
    started_at: u32 = 0,
    active: bool = false,

    pub fn begin(self: *State, now_ms: u32) void {
        self.* = .{ .started_at = now_ms, .active = true };
    }

    pub fn cancel(self: *State) void {
        self.active = false;
    }

    pub fn phase(self: *const State, now_ms: u32) Phase {
        if (!self.active) return .complete;
        const elapsed = now_ms -% self.started_at;
        if (elapsed >= total_ms) return .complete;
        if (elapsed == half_ms) return .background;
        if (elapsed < half_ms) return .{ .outgoing = rampIndex(@intCast(elapsed)) };
        // The incoming view starts at 95% background and ends at 5%.
        return .{ .incoming = @intCast(pattern_count - 1 - rampIndex(@intCast(elapsed - half_ms))) };
    }
};

fn rampIndex(elapsed_ms: u16) u8 {
    std.debug.assert(elapsed_ms < half_ms);
    return @intCast((@as(u32, elapsed_ms) * pattern_count) / half_ms);
}

/// Each row is the eight data bytes of an opaque Playdate LCDPattern. The
/// graphics API's trailing eight 0xff mask bytes are unnecessary here because
/// the renderer applies the data directly to the framebuffer.
pub const patterns = [pattern_count][8]u8{
    .{ 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11111111, 0b11101111, 0b11111111, 0b11111111 },
    .{ 0b11111111, 0b11111110, 0b11111111, 0b11111111, 0b11111111, 0b11101111, 0b11111111, 0b11111111 },
    .{ 0b11111111, 0b11101110, 0b11111111, 0b11111111, 0b11111111, 0b11101110, 0b11111111, 0b11111111 },
    .{ 0b11111111, 0b11101110, 0b11111111, 0b10111011, 0b11111111, 0b11101110, 0b11111111, 0b10111011 },
    .{ 0b11111111, 0b11101010, 0b11111111, 0b10111011, 0b11111111, 0b10101110, 0b11111111, 0b10111011 },
    .{ 0b11111111, 0b10101010, 0b11111111, 0b10101010, 0b11111111, 0b10101010, 0b11111111, 0b10101010 },
    .{ 0b11111111, 0b10101010, 0b01110111, 0b10101010, 0b11111111, 0b10101010, 0b01110111, 0b10101010 },
    .{ 0b01110111, 0b10101010, 0b11011101, 0b10101010, 0b01110111, 0b10101010, 0b11011101, 0b10101010 },
    .{ 0b01110111, 0b10101010, 0b01010101, 0b10101010, 0b01110111, 0b10101010, 0b01010101, 0b10101010 },
    .{ 0b10101010, 0b01010101, 0b10101010, 0b01010101, 0b10101010, 0b01010101, 0b10101010, 0b01010101 },
    .{ 0b10001000, 0b01010101, 0b10101010, 0b01010101, 0b10001000, 0b01010101, 0b10101010, 0b01010101 },
    .{ 0b10001000, 0b01010101, 0b00100010, 0b01010101, 0b10001000, 0b01010101, 0b00100010, 0b01010101 },
    .{ 0b00000000, 0b01010101, 0b10001000, 0b01010101, 0b00000000, 0b01010101, 0b10001000, 0b01010101 },
    .{ 0b00000000, 0b01010101, 0b00000000, 0b01010101, 0b00000000, 0b01010101, 0b00000000, 0b01010101 },
    .{ 0b00000000, 0b00010101, 0b00000000, 0b01000100, 0b00000000, 0b01010001, 0b00000000, 0b01000100 },
    .{ 0b00000000, 0b00010001, 0b00000000, 0b01000100, 0b00000000, 0b00010001, 0b00000000, 0b01000100 },
    .{ 0b00000000, 0b00010001, 0b00000000, 0b00000000, 0b00000000, 0b00010001, 0b00000000, 0b00000000 },
    .{ 0b00000000, 0b00000001, 0b00000000, 0b00000000, 0b00000000, 0b00010000, 0b00000000, 0b00000000 },
    .{ 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00000000, 0b00010000, 0b00000000, 0b00000000 },
};

test "fade visits the supplied dither ramp in both directions" {
    var state: State = .{};
    state.begin(1_000);
    try std.testing.expectEqual(Phase{ .outgoing = 0 }, state.phase(1_000));
    try std.testing.expectEqual(Phase{ .outgoing = 18 }, state.phase(1_199));
    try std.testing.expectEqual(Phase.background, state.phase(1_200));
    try std.testing.expectEqual(Phase{ .incoming = 18 }, state.phase(1_201));
    try std.testing.expectEqual(Phase{ .incoming = 0 }, state.phase(1_399));
    try std.testing.expectEqual(Phase.complete, state.phase(1_400));
}
