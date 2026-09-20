const std = @import("std");

pub const Kind = enum { position, pace, progress };

/// Debounces independent position and pace writes without knowing how either
/// record is encoded or persisted. A due request remains pending until its
/// owner explicitly clears it.
pub const WriteSchedule = struct {
    position_delay: ?u8 = null,
    pace_delay: ?u8 = null,
    progress_delay: ?u8 = null,

    pub fn request(self: *WriteSchedule, kind: Kind, delay_frames: u8) void {
        self.delay(kind).* = delay_frames;
    }

    /// Advances one request by one frame and reports whether its owner should
    /// attempt a write now. The caller clears only after applying its own
    /// success/failure policy.
    pub fn advance(self: *WriteSchedule, kind: Kind) bool {
        const slot = self.delay(kind);
        const remaining = slot.* orelse return false;
        if (remaining != 0) {
            slot.* = remaining - 1;
            return false;
        }
        return true;
    }

    pub fn clear(self: *WriteSchedule, kind: Kind) void {
        self.delay(kind).* = null;
    }

    pub fn pending(self: *const WriteSchedule, kind: Kind) bool {
        return self.delayConst(kind).* != null;
    }

    fn delay(self: *WriteSchedule, kind: Kind) *?u8 {
        return switch (kind) {
            .position => &self.position_delay,
            .pace => &self.pace_delay,
            .progress => &self.progress_delay,
        };
    }

    fn delayConst(self: *const WriteSchedule, kind: Kind) *const ?u8 {
        return switch (kind) {
            .position => &self.position_delay,
            .pace => &self.pace_delay,
            .progress => &self.progress_delay,
        };
    }
};

test "a requested save becomes due after its complete frame delay" {
    var schedule = WriteSchedule{};
    schedule.request(.position, 2);
    try std.testing.expect(!schedule.advance(.position));
    try std.testing.expect(!schedule.advance(.position));
    try std.testing.expect(schedule.advance(.position));
}
