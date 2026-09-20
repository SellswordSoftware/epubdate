const std = @import("std");
const reader_layout = @import("reader_layout.zig");
const progress = @import("storage/progress.zig");
const settings = @import("storage/settings.zig");

pub const Rail = struct {
    y: u8,
    width: u16,
};

pub const Layout = struct {
    chapter: ?Rail = null,
    book: ?Rail = null,
};

pub fn layout(
    metrics: ?progress.View,
    visibility: settings.ProgressVisibility,
    position: settings.ProgressPosition,
    scope: settings.ProgressScope,
) Layout {
    if (visibility == .off) return .{};
    const view = metrics orelse return .{};
    const chapter_y: u8 = @intCast(if (position == .top) reader_layout.top_rail_edge_y else reader_layout.bottom_rail_edge_y);
    const book_y: u8 = @intCast(if (position == .top) reader_layout.top_rail_inner_y else reader_layout.bottom_rail_inner_y);
    return .{
        .chapter = switch (scope) {
            .chapter, .both => rail(view.chapter, chapter_y),
            .book => null,
        },
        .book = switch (scope) {
            .book, .both => rail(view.book, book_y),
            .chapter => null,
        },
    };
}

fn rail(metric: progress.Metric, y: u8) ?Rail {
    return switch (metric) {
        .pending, .unavailable => null,
        .exact => |fraction| .{ .y = y, .width = fractionWidth(fraction) },
    };
}

fn fractionWidth(fraction: progress.Fraction) u16 {
    const reached = wideToU64(fraction.reached);
    const total = wideToU64(fraction.total);
    if (total == 0) return 0;
    const clamped = @min(reached, total);
    const pixels = (clamped / total) * reader_layout.screen_width +
        (clamped % total) * reader_layout.screen_width / total;
    return @intCast(@min(pixels, reader_layout.screen_width));
}

fn wideToU64(value: progress.WideCount) u64 {
    return (@as(u64, value.hi) << 32) | value.lo;
}

test "rails clamp exact fractions and independently omit unavailable metrics" {
    const metrics = progress.View{
        .chapter = .{ .exact = .{
            .reached = progress.WideCount.fromU32(1),
            .total = progress.WideCount.fromU32(4),
            .remaining = progress.WideCount.fromU32(3),
        } },
        .book = .unavailable,
    };
    var rails = layout(metrics, .on, .top, .both);
    try std.testing.expectEqual(Rail{ .y = 0, .width = 100 }, rails.chapter.?);
    try std.testing.expect(rails.book == null);

    const limits = progress.View{
        .chapter = .{ .exact = .{
            .reached = .{},
            .total = progress.WideCount.fromU32(10),
            .remaining = progress.WideCount.fromU32(10),
        } },
        .book = .{ .exact = .{
            .reached = progress.WideCount.fromU32(11),
            .total = progress.WideCount.fromU32(10),
            .remaining = .{},
        } },
    };
    rails = layout(limits, .on, .bottom, .both);
    try std.testing.expectEqual(Rail{ .y = 239, .width = 0 }, rails.chapter.?);
    try std.testing.expectEqual(Rail{ .y = 237, .width = 400 }, rails.book.?);
    try std.testing.expectEqual(Layout{}, layout(limits, .off, .top, .both));
}
