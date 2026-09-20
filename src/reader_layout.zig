const std = @import("std");

pub const screen_width: usize = 400;
pub const screen_height: usize = 240;
/// Reader content always leaves these lanes free, even while progress is off,
/// so changing visibility or placement never changes pagination.
pub const reserved_edge_rows: usize = 4;
pub const top_rail_edge_y: usize = 0;
pub const top_rail_inner_y: usize = 2;
pub const bottom_rail_edge_y: usize = screen_height - 1;
pub const bottom_rail_inner_y: usize = screen_height - 3;
pub const text_x: usize = 8;
pub const text_y: usize = reserved_edge_rows;
pub const text_width: usize = screen_width - (text_x * 2);
pub const minimum_line_gap: usize = 1;
pub const highlight_padding_x: usize = 1;
/// Slightly left of center so the longer post-ORP suffix has more room.
pub const rsvp_anchor_x: usize = 180;

pub const HighlightRect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const RsvpGeometry = struct {
    word_y: usize,
    guide_top_y: usize,
    guide_bottom_y: usize,
    top_tick_start_y: usize,
    bottom_tick_end_y: usize,
};

pub fn lineAdvance(font_height: usize) usize {
    return @max(font_height, 1) + minimum_line_gap;
}

pub fn pageLineLimit(font_height: usize, storage_capacity: usize) u8 {
    const available_height = screen_height - text_y - reserved_edge_rows;
    const fitting_lines = (available_height + minimum_line_gap) / lineAdvance(font_height);
    return @intCast(@max(@as(usize, 1), @min(fitting_lines, storage_capacity)));
}

/// The padding covers glyph edge pixels that may extend to the edge of their
/// measured advance while preserving the exact text origin and baseline.
pub fn highlightRect(word_x: usize, line_y: usize, word_width: usize, font_height: usize) HighlightRect {
    const x = word_x -| highlight_padding_x;
    const right = @min(screen_width, word_x +| word_width +| highlight_padding_x);
    return .{
        .x = x,
        .y = line_y,
        .width = right - x,
        .height = @max(font_height, 1),
    };
}

pub fn rsvpGeometry(font_height_value: usize) RsvpGeometry {
    const font_height = @max(font_height_value, 1);
    const word_y = (screen_height -| font_height) / 2;
    const clearance = @max(@as(usize, 2), font_height / 4);
    const tick_length = @max(@as(usize, 4), font_height / 2);
    const guide_top_y = word_y -| clearance;
    const guide_bottom_y = @min(screen_height - 1, word_y +| font_height +| clearance);
    return .{
        .word_y = word_y,
        .guide_top_y = guide_top_y,
        .guide_bottom_y = guide_bottom_y,
        .top_tick_start_y = guide_top_y -| tick_length,
        .bottom_tick_end_y = @min(screen_height - 1, guide_bottom_y +| tick_length),
    };
}

test "font metrics leave a clear pixel between reader lines" {
    try std.testing.expectEqual(@as(usize, 21), lineAdvance(20));
    try std.testing.expectEqual(@as(u8, 11), pageLineLimit(20, 11));
}

test "RSVP guides derive clearance and ticks from the font cell" {
    const geometry = rsvpGeometry(20);
    try std.testing.expectEqual(@as(usize, 110), geometry.word_y);
    try std.testing.expectEqual(@as(usize, 105), geometry.guide_top_y);
    try std.testing.expectEqual(@as(usize, 135), geometry.guide_bottom_y);
    try std.testing.expectEqual(@as(usize, 95), geometry.top_tick_start_y);
    try std.testing.expectEqual(@as(usize, 145), geometry.bottom_tick_end_y);
}
