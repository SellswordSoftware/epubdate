const std = @import("std");

pub const capacity = 16;
pub const max_path_bytes = 128;

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

pub const Library = struct {
    books: [capacity]Book = [_]Book{.{}} ** capacity,
    len: u8 = 0,
    selected: u8 = 0,

    pub fn add(self: *Library, path: []const u8) void {
        if (self.len == capacity or path.len == 0 or path.len >= max_path_bytes or !isEpub(path)) return;
        const book = &self.books[self.len];
        @memcpy(book.path[0..path.len], path);
        book.path[path.len] = 0;
        book.len = @intCast(path.len);
        self.len += 1;
    }

    pub fn move(self: *Library, direction: i8) void {
        if (self.len == 0) return;
        if (direction < 0) self.selected = if (self.selected == 0) self.len - 1 else self.selected - 1 else self.selected = if (self.selected + 1 == self.len) 0 else self.selected + 1;
    }

    pub fn selectedBook(self: *const Library) ?*const Book {
        if (self.len == 0) return null;
        return &self.books[self.selected];
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
