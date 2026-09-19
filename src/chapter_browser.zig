const std = @import("std");

/// The browser keeps indices into Publication's bounded spine list; it never
/// copies chapter paths or retains a separate table of labels.
pub const visible_rows: u8 = 10;

pub const Model = struct {
    entry_count: u8 = 0,
    selected: u8 = 0,
    first_visible: u8 = 0,

    pub fn init(entry_count: u8, current: u8) Model {
        if (entry_count == 0) return .{};
        var model = Model{ .entry_count = entry_count, .selected = @min(current, entry_count - 1) };
        model.ensureSelectedVisible();
        return model;
    }

    pub fn move(self: *Model, direction: i16) void {
        if (self.entry_count == 0 or direction == 0) return;
        const target: i32 = @as(i32, self.selected) + @as(i32, direction);
        self.selected = @intCast(@max(@as(i32, 0), @min(@as(i32, self.entry_count - 1), target)));
        self.ensureSelectedVisible();
    }

    pub fn displayedCount(self: *const Model) u8 {
        return @min(visible_rows, self.entry_count - self.first_visible);
    }

    fn ensureSelectedVisible(self: *Model) void {
        if (self.entry_count == 0) return;
        if (self.selected < self.first_visible) {
            self.first_visible = self.selected;
            return;
        }
        const last_visible = self.first_visible +| visible_rows - 1;
        if (self.selected > last_visible) self.first_visible = self.selected - visible_rows + 1;
    }
};

/// Formats a one-based chapter number and either a supplied EPUB navigation
/// label or a bounded filename fallback. The original spine path is never
/// mutated and no extension table is retained.
pub fn formatLabel(output: []u8, index: u8, navigation_label: []const u8, path: []const u8) []const u8 {
    const prefix = std.fmt.bufPrint(output, "{d}. ", .{@as(u16, index) + 1}) catch return "";
    const text = if (navigation_label.len != 0) navigation_label else withoutMarkupExtension(basename(path));
    const copied = @min(output.len - prefix.len, text.len);
    @memcpy(output[prefix.len .. prefix.len + copied], text[0..copied]);
    return output[0 .. prefix.len + copied];
}

fn basename(path: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[separator + 1 ..];
}

fn withoutMarkupExtension(name: []const u8) []const u8 {
    const extensions = [_][]const u8{ ".xhtml", ".html", ".htm" };
    for (extensions) |extension| {
        if (name.len > extension.len and std.ascii.eqlIgnoreCase(name[name.len - extension.len ..], extension)) return name[0 .. name.len - extension.len];
    }
    return name;
}

test "browser model clamps a one-entry spine" {
    var browser = Model.init(1, 0);
    browser.move(20);
    try std.testing.expectEqual(@as(u8, 0), browser.selected);
    try std.testing.expectEqual(@as(u8, 0), browser.first_visible);
    try std.testing.expectEqual(@as(u8, 1), browser.displayedCount());
}

test "browser model keeps the selected chapter inside its viewport" {
    var browser = Model.init(18, 0);
    browser.move(10);
    try std.testing.expectEqual(@as(u8, 10), browser.selected);
    try std.testing.expectEqual(@as(u8, 1), browser.first_visible);
    browser.move(7);
    try std.testing.expectEqual(@as(u8, 17), browser.selected);
    try std.testing.expectEqual(@as(u8, 8), browser.first_visible);
    browser.move(-99);
    try std.testing.expectEqual(@as(u8, 0), browser.selected);
    try std.testing.expectEqual(@as(u8, 0), browser.first_visible);
}

test "browser model opens at a final current chapter and coalesces beyond both bounds" {
    var browser = Model.init(18, 17);
    try std.testing.expectEqual(@as(u8, 17), browser.selected);
    try std.testing.expectEqual(@as(u8, 8), browser.first_visible);
    try std.testing.expectEqual(@as(u8, 10), browser.displayedCount());
    browser.move(120);
    try std.testing.expectEqual(@as(u8, 17), browser.selected);
    browser.move(-120);
    try std.testing.expectEqual(@as(u8, 0), browser.selected);
    try std.testing.expectEqual(@as(u8, 0), browser.first_visible);
}

test "empty browser model and label output are safe" {
    var browser = Model.init(0, 0);
    browser.move(1);
    try std.testing.expectEqual(@as(u8, 0), browser.displayedCount());
    var empty: [0]u8 = .{};
    try std.testing.expectEqualStrings("", formatLabel(&empty, 0, "", "chapter.xhtml"));
}

test "browser label uses a safe filename fallback and bounded output" {
    var output: [32]u8 = undefined;
    try std.testing.expectEqualStrings("4. chapter", formatLabel(&output, 3, "", "OEBPS/part/chapter.XHTML"));
    var short: [11]u8 = undefined;
    try std.testing.expectEqualStrings("3. a-very-l", formatLabel(&short, 2, "", "OEBPS/a-very-long-chapter.xhtml"));
    try std.testing.expectEqualStrings("1. ", formatLabel(&output, 0, "", "OPS/"));
}

test "browser label prefers a bounded EPUB navigation label" {
    var output: [13]u8 = undefined;
    try std.testing.expectEqualStrings("2. TRANSLATOR", formatLabel(&output, 1, "TRANSLATOR’S PREFACE", "nonsense.xhtml"));
    try std.testing.expectEqualStrings("2. nonsense", formatLabel(&output, 1, "", "nonsense.xhtml"));
}
