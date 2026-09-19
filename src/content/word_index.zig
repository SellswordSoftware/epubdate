const std = @import("std");

/// Normalized XHTML already folds ordinary whitespace. Both Paged and RSVP
/// use this single boundary rule so their chapter-relative ordinals cannot
/// drift because of different token splitting behavior.
pub fn isBoundary(byte: u8) bool {
    return std.ascii.isWhitespace(byte);
}

/// Monotonic chapter-relative word ordinal assignment. It never represents a
/// source byte or compressed offset. Saturation preserves ordering without a
/// wraparound location on an unusually long chapter.
pub const Counter = struct {
    next: u32 = 0,

    pub fn accept(self: *Counter) u32 {
        const ordinal = self.next;
        if (self.next != std.math.maxInt(u32)) self.next += 1;
        return ordinal;
    }
};

test "word boundaries are whitespace-only after XHTML normalization" {
    try std.testing.expect(isBoundary(' '));
    try std.testing.expect(isBoundary('\n'));
    try std.testing.expect(!isBoundary('.'));
    try std.testing.expect(!isBoundary('\''));
}

test "word ordinals are monotonic and do not wrap" {
    var counter = Counter{};
    try std.testing.expectEqual(@as(u32, 0), counter.accept());
    try std.testing.expectEqual(@as(u32, 1), counter.accept());
    counter.next = std.math.maxInt(u32);
    try std.testing.expectEqual(std.math.maxInt(u32), counter.accept());
    try std.testing.expectEqual(std.math.maxInt(u32), counter.accept());
}
