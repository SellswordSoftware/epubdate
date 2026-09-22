pub const Row = enum(u4) {
    paged_presentation,
    theme,
    pages_font,
    rsvp_font,
    progress_visibility,
    progress_position,
    progress_scope,
    reset_progress,
};

pub const row_count: u4 = 8;
pub const global_row_count: u4 = @intFromEnum(Row.reset_progress);
pub const visible_capacity: u4 = 7;

test "Progression is the first settings row" {
    try @import("std").testing.expectEqual(@as(u4, 0), @intFromEnum(Row.paged_presentation));
    try @import("std").testing.expectEqual(@as(u4, 8), row_count);
}

test "settings keep seven rows visible while the final row scrolls into view" {
    var model = Model{};
    try @import("std").testing.expectEqual(@as(u4, 7), model.displayedCount());
    for (0..row_count - 1) |_| model.move(1);
    try @import("std").testing.expectEqual(Row.reset_progress, model.selected);
    try @import("std").testing.expectEqual(@as(u4, 1), model.first_visible);
    try @import("std").testing.expectEqual(@as(u4, 7), model.displayedCount());
}

pub const Model = struct {
    selected: Row = .paged_presentation,
    first_visible: u4 = 0,
    available_rows: u4 = row_count,

    pub fn setAvailableRows(self: *Model, count: u4) void {
        self.available_rows = @max(@as(u4, 1), @min(row_count, count));
        if (@intFromEnum(self.selected) >= self.available_rows) self.selected = @enumFromInt(self.available_rows - 1);
        const displayed = @min(visible_capacity, self.available_rows);
        self.first_visible = @min(self.first_visible, self.available_rows - displayed);
        self.ensureVisible();
    }

    pub fn move(self: *Model, direction: i8) void {
        if (direction == 0) return;
        const selected: u4 = @intFromEnum(self.selected);
        const next: u4 = if (direction > 0)
            if (selected + 1 == self.available_rows) 0 else selected + 1
        else if (selected == 0)
            self.available_rows - 1
        else
            selected - 1;
        self.selected = @enumFromInt(next);
        self.ensureVisible();
    }

    pub fn displayedCount(self: *const Model) u4 {
        return @min(visible_capacity, self.available_rows - self.first_visible);
    }

    fn ensureVisible(self: *Model) void {
        const selected: u4 = @intFromEnum(self.selected);
        if (selected < self.first_visible) {
            self.first_visible = selected;
        } else if (selected >= self.first_visible + visible_capacity) {
            self.first_visible = selected - visible_capacity + 1;
        }
    }
};

test "global settings omit only book-specific progress reset" {
    var model = Model{};
    model.setAvailableRows(global_row_count);
    model.move(-1);
    try @import("std").testing.expectEqual(Row.progress_scope, model.selected);
    try @import("std").testing.expectEqual(global_row_count, model.displayedCount());
}
