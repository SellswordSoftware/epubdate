const std = @import("std");
const reader_layout = @import("reader_layout.zig");

/// Scroll policy is deliberately independent of Playdate input and page-cache
/// ownership. Later slices translate crank detents and cache readiness into
/// these bounded integer operations.
pub const scroll_pixels_per_detent: u16 = 12;
pub const max_pending_detents: i16 = 64;

pub const Direction = enum { backward, forward };

/// The text rectangle is fixed even when rails are hidden. `bottom_y` is
/// exclusive so it can be used directly for clipping by a later renderer.
pub const Viewport = struct {
    top_y: u16,
    bottom_y: u16,

    pub fn height(self: Viewport) u16 {
        return self.bottom_y - self.top_y;
    }
};

pub const Geometry = struct {
    viewport: Viewport,
    line_advance: u16,

    pub fn init(font_height: usize) Geometry {
        return .{
            .viewport = .{
                .top_y = @intCast(reader_layout.text_y),
                .bottom_y = @intCast(reader_layout.screen_height - reader_layout.reserved_edge_rows),
            },
            .line_advance = @intCast(reader_layout.lineAdvance(font_height)),
        };
    }

    /// A page is a continuous run of line cells: there is no synthetic gap at
    /// a page boundary.
    pub fn pageExtent(self: Geometry, line_count: u8) u16 {
        return @as(u16, line_count) * self.line_advance;
    }
};

pub const PageExtent = struct {
    index: u32,
    extent_px: u16,
};

/// Page-relative, integral scroll state. A nonzero waiting displacement is
/// only placeholder space into an unavailable neighbor; it is not a guessed
/// page extent. Positive values wait after the current page, negative values
/// wait before it.
pub const Position = struct {
    top_page: u32 = 0,
    offset_px: u16 = 0,
    waiting_px: i16 = 0,
    pending_detents: i16 = 0,

    pub fn clearTransient(self: *Position) void {
        self.waiting_px = 0;
        self.pending_detents = 0;
    }

    pub fn queueDetents(self: *Position, detents: i16) void {
        const total: i32 = @as(i32, self.pending_detents) + @as(i32, detents);
        self.pending_detents = @intCast(std.math.clamp(total, -@as(i32, max_pending_detents), @as(i32, max_pending_detents)));
    }
};

pub const MoveResult = struct {
    /// Pixels applied to cached text or bounded placeholder displacement.
    applied_px: u16 = 0,
    /// A caller may refresh its bounded page window before applying this
    /// remainder. No position field is made invalid while it does so.
    remaining_px: u16 = 0,
    page_changed: bool = false,
    waiting_for_neighbor: bool = false,
    at_chapter_limit: bool = false,
};

/// Applies as much of one requested displacement as the current page and one
/// adjacent cached page can establish. It never invents the extent of a
/// missing page, and it never loops over an unbounded input backlog.
pub fn move(
    position: *Position,
    direction: Direction,
    pixels: u16,
    viewport: Viewport,
    current: PageExtent,
    adjacent: ?PageExtent,
    at_chapter_limit: bool,
) MoveResult {
    std.debug.assert(position.top_page == current.index);
    std.debug.assert(current.extent_px != 0);
    std.debug.assert(position.offset_px <= current.extent_px);
    if (adjacent) |page| std.debug.assert(page.extent_px != 0);

    const remaining = cancelOppositeWaiting(position, direction, pixels);
    if (remaining == 0) return .{ .applied_px = pixels };

    const waiting_in_direction = switch (direction) {
        .forward => position.waiting_px > 0,
        .backward => position.waiting_px < 0,
    };
    if (waiting_in_direction) return addWaiting(position, direction, remaining, viewport, pixels - remaining);

    return switch (direction) {
        .forward => moveForward(position, remaining, viewport, current, adjacent, at_chapter_limit, pixels - remaining),
        .backward => moveBackward(position, remaining, viewport, adjacent, at_chapter_limit, pixels - remaining),
    };
}

/// Replaces bounded placeholder displacement with real page-relative movement
/// once its neighboring page is cached. A later cache slice may call this at
/// most once per page-window refresh.
pub fn absorbWaiting(position: *Position, direction: Direction, viewport: Viewport, current: PageExtent, adjacent: ?PageExtent, at_chapter_limit: bool) MoveResult {
    const amount: u16 = switch (direction) {
        .forward => if (position.waiting_px > 0) @intCast(position.waiting_px) else return .{},
        .backward => if (position.waiting_px < 0) @intCast(-@as(i32, position.waiting_px)) else return .{},
    };
    position.waiting_px = 0;
    return move(position, direction, amount, viewport, current, adjacent, at_chapter_limit);
}

const EndClamp = struct {
    position: Position,
    needs_previous_page: bool,
};

/// Produces the bottom-aligned local chapter end from an ordered cached tail.
/// If the tail cannot fill the viewport, callers retain the known text and
/// request only the missing preceding page. A chapter that genuinely starts
/// inside this short tail remains clamped at offset zero.
pub fn chapterEndClamp(viewport: Viewport, tail: []const PageExtent) EndClamp {
    std.debug.assert(tail.len != 0);
    var needed = viewport.height();
    var index = tail.len;
    while (index != 0) {
        index -= 1;
        const page = tail[index];
        std.debug.assert(page.extent_px != 0);
        if (page.extent_px >= needed) {
            return .{ .position = .{ .top_page = page.index, .offset_px = page.extent_px - needed }, .needs_previous_page = false };
        }
        needed -= page.extent_px;
    }
    return .{
        .position = .{ .top_page = tail[0].index, .offset_px = 0 },
        .needs_previous_page = tail[0].index != 0,
    };
}

fn cancelOppositeWaiting(position: *Position, direction: Direction, pixels: u16) u16 {
    const opposite = switch (direction) {
        .forward => position.waiting_px < 0,
        .backward => position.waiting_px > 0,
    };
    if (!opposite) return pixels;
    const waiting: u16 = @intCast(@abs(position.waiting_px));
    const cancelled = @min(pixels, waiting);
    switch (direction) {
        .forward => position.waiting_px += @intCast(cancelled),
        .backward => position.waiting_px -= @intCast(cancelled),
    }
    return pixels - cancelled;
}

fn moveForward(position: *Position, pixels: u16, viewport: Viewport, current: PageExtent, adjacent: ?PageExtent, at_end: bool, already_applied: u16) MoveResult {
    const available = current.extent_px - position.offset_px;
    if (pixels < available) {
        position.offset_px += pixels;
        return .{ .applied_px = already_applied + pixels };
    }
    if (pixels == available and adjacent == null and !at_end) {
        position.offset_px = current.extent_px;
        return .{ .applied_px = already_applied + pixels, .waiting_for_neighbor = true };
    }
    position.offset_px = current.extent_px;
    const remainder = pixels - available;
    if (adjacent) |next| {
        position.top_page = next.index;
        position.offset_px = 0;
        return .{ .applied_px = already_applied + available, .remaining_px = remainder, .page_changed = true };
    }
    if (at_end) {
        position.offset_px = current.extent_px -| 1;
        return .{ .applied_px = already_applied + available -| 1, .remaining_px = remainder, .at_chapter_limit = true };
    }
    return addWaiting(position, .forward, remainder, viewport, already_applied + available);
}

fn moveBackward(position: *Position, pixels: u16, viewport: Viewport, adjacent: ?PageExtent, at_start: bool, already_applied: u16) MoveResult {
    if (pixels <= position.offset_px) {
        position.offset_px -= pixels;
        return .{ .applied_px = already_applied + pixels };
    }
    const remainder = pixels - position.offset_px;
    const applied = already_applied + position.offset_px;
    position.offset_px = 0;
    if (adjacent) |previous| {
        position.top_page = previous.index;
        position.offset_px = previous.extent_px;
        return .{ .applied_px = applied, .remaining_px = remainder, .page_changed = true };
    }
    if (at_start) return .{ .applied_px = applied, .remaining_px = remainder, .at_chapter_limit = true };
    return addWaiting(position, .backward, remainder, viewport, applied);
}

fn addWaiting(position: *Position, direction: Direction, pixels: u16, viewport: Viewport, already_applied: u16) MoveResult {
    const capacity: u16 = switch (direction) {
        .forward => viewport.height() - @as(u16, @intCast(@max(position.waiting_px, 0))),
        .backward => viewport.height() - @as(u16, @intCast(@max(-@as(i32, position.waiting_px), 0))),
    };
    const displaced = @min(pixels, capacity);
    switch (direction) {
        .forward => position.waiting_px += @intCast(displaced),
        .backward => position.waiting_px -= @intCast(displaced),
    }
    return .{
        .applied_px = already_applied + displaced,
        .remaining_px = pixels - displaced,
        .waiting_for_neighbor = true,
    };
}

test "scroll geometry derives extents and a rail-safe viewport from font metrics" {
    const geometry = Geometry.init(20);
    try std.testing.expectEqual(@as(u16, 21), geometry.line_advance);
    try std.testing.expectEqual(@as(u16, 4), geometry.viewport.top_y);
    try std.testing.expectEqual(@as(u16, 236), geometry.viewport.bottom_y);
    try std.testing.expectEqual(@as(u16, 232), geometry.viewport.height());
    try std.testing.expectEqual(@as(u16, 231), geometry.pageExtent(11));
    try std.testing.expectEqual(@as(u16, 63), geometry.pageExtent(3));
}

test "long known movement retains a page-relative offset" {
    const viewport = Geometry.init(20).viewport;
    var position = Position{};
    for (1..500) |page| {
        const result = move(&position, .forward, 231, viewport, .{ .index = @intCast(page - 1), .extent_px = 231 }, .{ .index = @intCast(page), .extent_px = 231 }, false);
        try std.testing.expect(result.page_changed);
        try std.testing.expectEqual(@as(u16, 0), result.remaining_px);
        try std.testing.expect(position.offset_px < 231);
    }
    try std.testing.expectEqual(@as(u32, 499), position.top_page);
}

test "missing neighbors use bounded placeholders and reversing cancels them first" {
    const viewport = Geometry.init(20).viewport;
    var position = Position{ .top_page = 7, .offset_px = 220 };
    const waiting = move(&position, .forward, 80, viewport, .{ .index = 7, .extent_px = 231 }, null, false);
    try std.testing.expect(waiting.waiting_for_neighbor);
    try std.testing.expectEqual(@as(i16, 69), position.waiting_px);
    try std.testing.expect(position.waiting_px <= @as(i16, @intCast(viewport.height())));

    _ = move(&position, .backward, 20, viewport, .{ .index = 7, .extent_px = 231 }, null, false);
    try std.testing.expectEqual(@as(i16, 49), position.waiting_px);
    try std.testing.expectEqual(@as(u16, 231), position.offset_px);

    position.queueDetents(100);
    position.queueDetents(-30);
    try std.testing.expectEqual(@as(i16, 34), position.pending_detents);

    var at_start = Position{};
    const clamped = move(&at_start, .backward, scroll_pixels_per_detent, viewport, .{ .index = 0, .extent_px = 231 }, null, true);
    try std.testing.expect(clamped.at_chapter_limit);
    try std.testing.expectEqual(@as(u16, 0), at_start.offset_px);
    try std.testing.expectEqual(@as(i16, 0), at_start.waiting_px);
}

test "chapter end bottom-clamps full and partial final pages" {
    const viewport = Geometry.init(20).viewport;
    const full = chapterEndClamp(viewport, &.{ .{ .index = 8, .extent_px = 231 }, .{ .index = 9, .extent_px = 231 } });
    try std.testing.expectEqual(@as(u32, 8), full.position.top_page);
    try std.testing.expectEqual(@as(u16, 230), full.position.offset_px);
    try std.testing.expect(!full.needs_previous_page);

    const partial = chapterEndClamp(viewport, &.{ .{ .index = 8, .extent_px = 231 }, .{ .index = 9, .extent_px = 63 } });
    try std.testing.expectEqual(@as(u32, 8), partial.position.top_page);
    try std.testing.expectEqual(@as(u16, 62), partial.position.offset_px);
    try std.testing.expect(!partial.needs_previous_page);

    const start = chapterEndClamp(viewport, &.{.{ .index = 0, .extent_px = 63 }});
    try std.testing.expectEqual(@as(u16, 0), start.position.offset_px);
    try std.testing.expect(!start.needs_previous_page);
}
