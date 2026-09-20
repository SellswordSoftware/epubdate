const std = @import("std");

pub const screen_width: usize = 400;
pub const screen_height: usize = 240;
pub const text_x: usize = 8;
pub const text_y: usize = 4;
pub const text_width: usize = screen_width - (text_x * 2);
pub const minimum_line_gap: usize = 1;
pub const highlight_padding_x: usize = 1;

pub const HighlightRect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub fn lineAdvance(font_height: usize) usize {
    return @max(font_height, 1) + minimum_line_gap;
}

pub fn pageLineLimit(font_height: usize, storage_capacity: usize) u8 {
    const available_height = screen_height - text_y;
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

test "font metrics leave a clear pixel between reader lines" {
    try std.testing.expectEqual(@as(usize, 21), lineAdvance(20));
    try std.testing.expectEqual(@as(u8, 11), pageLineLimit(20, 11));
}
