const std = @import("std");

pub const capacity = 16;
pub const max_path_bytes = 128;
pub const visible_rows: u8 = 6;

pub const Book = struct {
    path: [max_path_bytes:0]u8 = [_:0]u8{0} ** max_path_bytes,
    len: u8 = 0,

    pub fn slice(self: *const Book) []const u8 {
        return self.path[0..self.len];
    }

    pub fn zSlice(self: *const Book) [:0]const u8 {
        return self.path[0..self.len :0];
    }
};

/// The library owns only EPUB paths, so the extension adds no useful reading
/// context in the constrained list UI.
pub fn displayTitle(path: []const u8) []const u8 {
    return if (isEpub(path)) path[0 .. path.len - 5] else path;
}

pub const Library = struct {
    books: [capacity]Book = [_]Book{.{}} ** capacity,
    len: u8 = 0,
    selected: u8 = 0,
    first_visible: u8 = 0,

    pub fn add(self: *Library, path: []const u8) void {
        if (self.len == capacity or path.len == 0 or path.len >= max_path_bytes or !isEpub(path)) return;
        const book = &self.books[self.len];
        @memcpy(book.path[0..path.len], path);
        book.path[path.len] = 0;
        book.len = @intCast(path.len);
        self.len += 1;
    }

    pub fn move(self: *Library, direction: i16) void {
        if (self.len == 0 or direction == 0) return;
        const target = @mod(@as(i32, self.selected) + @as(i32, direction), @as(i32, self.len));
        self.selected = @intCast(target);
        self.ensureSelectedVisible();
    }

    pub fn selectedBook(self: *const Library) ?*const Book {
        if (self.len == 0) return null;
        return &self.books[self.selected];
    }

    fn ensureSelectedVisible(self: *Library) void {
        if (self.selected < self.first_visible) {
            self.first_visible = self.selected;
            return;
        }
        const last_visible = self.first_visible +| visible_rows - 1;
        if (self.selected > last_visible) self.first_visible = self.selected - visible_rows + 1;
    }
};

fn isEpub(path: []const u8) bool {
    if (path.len < 5) return false;
    return std.ascii.eqlIgnoreCase(path[path.len - 5 ..], ".epub");
}

test "library retains bounded EPUB choices and cycles selection" {
    var library = Library{};
    library.add("notes.txt");
    library.add("books/one.epub");
    library.add("books/TWO.EPUB");
    try std.testing.expectEqual(@as(u8, 2), library.len);
    try std.testing.expectEqualStrings("books/one.epub", library.selectedBook().?.slice());
    library.move(1);
    try std.testing.expectEqualStrings("books/TWO.EPUB", library.selectedBook().?.slice());
    library.move(1);
    try std.testing.expectEqualStrings("books/one.epub", library.selectedBook().?.slice());
}

test "library scrolls only when selection crosses a viewport edge" {
    var library = Library{};
    for (0..8) |index| {
        var path: [16]u8 = undefined;
        library.add(try std.fmt.bufPrint(&path, "book-{d}.epub", .{index}));
    }

    for (0..6) |_| library.move(1);
    try std.testing.expectEqual(@as(u8, 6), library.selected);
    try std.testing.expectEqual(@as(u8, 1), library.first_visible);

    library.move(-1);
    try std.testing.expectEqual(@as(u8, 5), library.selected);
    try std.testing.expectEqual(@as(u8, 1), library.first_visible);

    for (0..5) |_| library.move(-1);
    try std.testing.expectEqual(@as(u8, 0), library.selected);
    try std.testing.expectEqual(@as(u8, 0), library.first_visible);
}

test "display title omits an EPUB extension case insensitively" {
    try std.testing.expectEqualStrings("books/one", displayTitle("books/one.epub"));
    try std.testing.expectEqualStrings("books/TWO", displayTitle("books/TWO.EPUB"));
    try std.testing.expectEqualStrings("notes.txt", displayTitle("notes.txt"));
}
