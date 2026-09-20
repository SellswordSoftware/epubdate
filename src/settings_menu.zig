pub const Row = enum(u4) {
    reading_mode,
    rsvp_wpm,
    theme,
    font,
    progress_visibility,
    progress_position,
    progress_scope,
    statistics,
    reset_progress,
};

pub const row_count: u4 = 9;
pub const visible_capacity: u4 = 6;

pub const Model = struct {
    selected: Row = .reading_mode,
    first_visible: u4 = 0,

    pub fn move(self: *Model, direction: i8) void {
        if (direction == 0) return;
        const selected: u4 = @intFromEnum(self.selected);
        const next: u4 = if (direction > 0)
            if (selected + 1 == row_count) 0 else selected + 1
        else if (selected == 0)
            row_count - 1
        else
            selected - 1;
        self.selected = @enumFromInt(next);
        self.ensureVisible();
    }

    pub fn displayedCount(self: *const Model) u4 {
        return @min(visible_capacity, row_count - self.first_visible);
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
