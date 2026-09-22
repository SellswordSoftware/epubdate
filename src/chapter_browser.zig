const std = @import("std");
const epub = @import("publication/epub.zig");

/// The browser keeps indices into Publication's bounded spine list; it never
/// copies chapter paths or retains a separate table of labels.
pub const visible_rows: u8 = 9;

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
    var output_len = prefix.len;
    appendNormalized(output, &output_len, text);
    return output[0..output_len];
}

/// Computes one allocation-free browser boundary from already-parsed EPUB
/// navigation metadata. The complete spine remains untouched.
pub const Visibility = struct {
    final_labeled_spine: ?u8,

    pub fn init(publication: *const epub.Publication) Visibility {
        var index = publication.spine_len;
        while (index != 0) {
            index -= 1;
            if (publication.chapter_labels[index].len != 0) return .{ .final_labeled_spine = index };
        }
        return .{ .final_labeled_spine = null };
    }

    pub fn includes(self: Visibility, publication: *const epub.Publication, index: u8) bool {
        if (index >= publication.spine_len) return false;
        if (isGutenbergCoverWrapper(publication.spine[index].slice())) return false;
        return if (self.final_labeled_spine) |last| index <= last else true;
    }
};

fn isGutenbergCoverWrapper(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(withoutMarkupExtension(basename(path)), "wrap0000");
}

fn appendNormalized(output: []u8, output_len: *usize, text: []const u8) void {
    var source_index: usize = 0;
    while (source_index < text.len and output_len.* < output.len) {
        const byte = text[source_index];
        if (byte < 0x80) {
            appendBytes(output, output_len, &[_]u8{byte});
            source_index += 1;
            continue;
        }
        const sequence_len: usize = std.unicode.utf8ByteSequenceLength(byte) catch {
            appendBytes(output, output_len, "?");
            source_index += 1;
            continue;
        };
        if (sequence_len > text.len - source_index) {
            appendBytes(output, output_len, "?");
            break;
        }
        const codepoint = std.unicode.utf8Decode(text[source_index .. source_index + sequence_len]) catch {
            appendBytes(output, output_len, "?");
            source_index += 1;
            continue;
        };
        appendBytes(output, output_len, switch (codepoint) {
            0x2018, 0x2019 => "'",
            0x201c, 0x201d => "\"",
            0x2013 => "-",
            0x2014 => "--",
            0x2026 => "...",
            else => "?",
        });
        source_index += sequence_len;
    }
}

fn appendBytes(output: []u8, output_len: *usize, bytes: []const u8) void {
    const copied = @min(output.len - output_len.*, bytes.len);
    @memcpy(output[output_len.* .. output_len.* + copied], bytes[0..copied]);
    output_len.* += copied;
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
    try std.testing.expectEqual(@as(u8, 2), browser.first_visible);
    browser.move(7);
    try std.testing.expectEqual(@as(u8, 17), browser.selected);
    try std.testing.expectEqual(@as(u8, 9), browser.first_visible);
    browser.move(-99);
    try std.testing.expectEqual(@as(u8, 0), browser.selected);
    try std.testing.expectEqual(@as(u8, 0), browser.first_visible);
}

test "browser model opens at a final current chapter and coalesces beyond both bounds" {
    var browser = Model.init(18, 17);
    try std.testing.expectEqual(@as(u8, 17), browser.selected);
    try std.testing.expectEqual(@as(u8, 9), browser.first_visible);
    try std.testing.expectEqual(@as(u8, 9), browser.displayedCount());
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

test "browser labels normalize display punctuation" {
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1. Don't--wait...", formatLabel(&output, 0, "Don’t—wait…", "ignored.xhtml"));
}

test "TOC boundary preserves gaps and fallback while hiding trailing entries" {
    var publication: epub.Publication = undefined;
    @memset(std.mem.asBytes(&publication), 0);
    const paths = [_][]const u8{
        "OEBPS/wrap0000.xhtml",
        "OEBPS/chapter0001.xhtml",
        "OEBPS/unlisted-middle.xhtml",
        "OEBPS/chapter0003.xhtml",
        "OEBPS/image-wrapper-1.xhtml",
        "OEBPS/image-wrapper-2.xhtml",
    };
    publication.spine_len = @intCast(paths.len);
    for (paths, 0..) |path, index| {
        publication.spine[index].path_len = @intCast(path.len);
        @memcpy(publication.spine[index].path[0..path.len], path);
    }
    publication.chapter_labels[1].len = 1;
    publication.chapter_labels[3].len = 1;

    const bounded = Visibility.init(&publication);
    try std.testing.expect(!bounded.includes(&publication, 0));
    try std.testing.expect(bounded.includes(&publication, 1));
    try std.testing.expect(bounded.includes(&publication, 2));
    try std.testing.expect(bounded.includes(&publication, 3));
    try std.testing.expect(!bounded.includes(&publication, 4));
    try std.testing.expect(!bounded.includes(&publication, 5));

    @memset(std.mem.asBytes(&publication.chapter_labels), 0);
    const fallback = Visibility.init(&publication);
    try std.testing.expect(fallback.includes(&publication, 4));
    try std.testing.expect(!fallback.includes(&publication, 0));
}
