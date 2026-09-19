const std = @import("std");

pub fn adjacentChapter(current: u8, spine_len: u8, direction: i8) ?u8 {
    if (direction == 0) return null;
    const candidate: i16 = @as(i16, current) + direction;
    if (candidate < 0 or candidate >= spine_len) return null;
    return @intCast(candidate);
}

pub const PagedSelectionTarget = union(enum) {
    ordinal: u32,
    // The preceding chapter must be rebuilt before its final ordinal is known.
    last_word,
};

pub fn pagedModeSwitchOrdinal(current: u32, pending: ?PagedSelectionTarget) u32 {
    return switch (pending orelse return current) {
        .ordinal => |ordinal| ordinal,
        .last_word => current,
    };
}

test "mode switching preserves a pending ordinal but not an unresolved last word" {
    try std.testing.expectEqual(@as(u32, 42), pagedModeSwitchOrdinal(41, .{ .ordinal = 42 }));
    try std.testing.expectEqual(@as(u32, 41), pagedModeSwitchOrdinal(41, .last_word));
    try std.testing.expectEqual(@as(u32, 41), pagedModeSwitchOrdinal(41, null));
}

test "adjacent chapter rejects boundaries and selects an in-range neighbor" {
    try std.testing.expectEqual(@as(?u8, 1), adjacentChapter(0, 2, 1));
    try std.testing.expectEqual(@as(?u8, 0), adjacentChapter(1, 2, -1));
    try std.testing.expectEqual(@as(?u8, null), adjacentChapter(0, 2, -1));
    try std.testing.expectEqual(@as(?u8, null), adjacentChapter(1, 2, 1));
    try std.testing.expectEqual(@as(?u8, null), adjacentChapter(0, 2, 0));
    try std.testing.expectEqual(@as(?u8, null), adjacentChapter(0, 0, 1));
}
