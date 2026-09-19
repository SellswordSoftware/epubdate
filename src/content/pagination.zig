const std = @import("std");
const xhtml = @import("xhtml.zig");
const word_index = @import("word_index.zig");
const limits = @import("limits").reader;

pub const max_lines = limits.page_line_count;
pub const max_cached_line_bytes = limits.page_line_bytes;

test "full-screen reader pages hold eleven body lines" {
    try std.testing.expectEqual(@as(u8, 11), max_lines);
}

/// A drawable page that owns its text, so a streamed extractor may discard
/// source chunks after contributing their completed lines.
pub const PageCache = struct {
    lines: [max_lines][max_cached_line_bytes]u8 = undefined,
    lengths: [max_lines]u16 = [_]u16{0} ** max_lines,
    // Pagination adds a few presentational bytes (list markers and dividers)
    // which deliberately have no normalized word ordinal. Retaining the
    // per-line source metadata lets selection find the actual source word.
    line_synthetic_prefix_bytes: [max_lines]u16 = [_]u16{0} ** max_lines,
    line_word_counts: [max_lines]u16 = [_]u16{0} ** max_lines,
    line_count: u8 = 0,
    first_word_ordinal: u32 = 0,
    word_count: u32 = 0,

    pub fn clear(self: *PageCache) void {
        self.line_count = 0;
        @memset(&self.lengths, 0);
        @memset(&self.line_synthetic_prefix_bytes, 0);
        @memset(&self.line_word_counts, 0);
        self.first_word_ordinal = 0;
        self.word_count = 0;
    }

    pub fn appendLine(self: *PageCache, text: []const u8) error{ PageFull, LineTooLong }!void {
        try self.appendLineWithMetadata(text, 0, 0);
    }

    pub fn appendLineWithMetadata(self: *PageCache, text: []const u8, synthetic_prefix_bytes: u16, source_word_count: u16) error{ PageFull, LineTooLong }!void {
        if (self.line_count == max_lines) return error.PageFull;
        if (text.len > max_cached_line_bytes) return error.LineTooLong;
        if (synthetic_prefix_bytes > text.len) return error.LineTooLong;
        const index: usize = self.line_count;
        @memcpy(self.lines[index][0..text.len], text);
        self.lengths[index] = @intCast(text.len);
        self.line_synthetic_prefix_bytes[index] = synthetic_prefix_bytes;
        self.line_word_counts[index] = source_word_count;
        self.line_count += 1;
    }

    pub fn line(self: *const PageCache, index: usize) []const u8 {
        return self.lines[index][0..self.lengths[index]];
    }

    pub const WordSpan = struct {
        line_index: u8,
        start: u16,
        end: u16,
    };

    /// Finds the bytes that draw one normalized source word. Synthetic list
    /// markers and dividers are omitted by the builder's per-line metadata.
    pub fn wordSpan(self: *const PageCache, ordinal: u32) ?WordSpan {
        if (ordinal < self.first_word_ordinal) return null;
        var local_ordinal = ordinal - self.first_word_ordinal;
        if (local_ordinal >= self.word_count) return null;

        for (0..self.line_count) |line_index| {
            const count = self.line_word_counts[line_index];
            if (local_ordinal >= count) {
                local_ordinal -= count;
                continue;
            }
            const text = self.line(line_index);
            var offset: usize = self.line_synthetic_prefix_bytes[line_index];
            var found: u16 = 0;
            while (offset < text.len) {
                while (offset < text.len and word_index.isBoundary(text[offset])) : (offset += 1) {}
                const start = offset;
                while (offset < text.len and !word_index.isBoundary(text[offset])) : (offset += 1) {}
                if (start == offset) break;
                if (found == local_ordinal) return .{ .line_index = @intCast(line_index), .start = @intCast(start), .end = @intCast(offset) };
                found += 1;
            }
            return null;
        }
        return null;
    }

    /// Returns the new selection only when it remains in this cached page.
    /// PagedReader handles selection that crosses a page boundary.
    pub fn moveSelection(self: *const PageCache, selected: ?u32, direction: i8) ?u32 {
        if (self.word_count == 0) return null;
        const first = self.first_word_ordinal;
        const current = selected orelse return first;
        if (current < first or current - first >= self.word_count) return first;
        if (direction > 0 and current - first + 1 < self.word_count) return current + 1;
        if (direction < 0 and current > first) return current - 1;
        return current;
    }
};

/// Incrementally converts normalized XHTML events into one owned, drawable
/// page.  Its only retained input is the unfinished word and line, both with
/// explicit caps; completed lines are copied to PageCache.
pub const EventPageBuilder = struct {
    const PendingSemantic = enum { line_break, paragraph_break, heading, block_quote, list_item, divider };

    cache: *PageCache,
    measure: Measure,
    max_width: usize,
    word: [max_cached_line_bytes]u8 = undefined,
    word_len: usize = 0,
    line: [max_cached_line_bytes]u8 = undefined,
    line_len: usize = 0,
    page_full: bool = false,
    source_word: bool = false,
    word_ordinals: word_index.Counter = .{},
    line_first_word_ordinal: ?u32 = null,
    line_source_word_count: u32 = 0,
    line_synthetic_prefix_bytes: u16 = 0,
    // A semantic event can arrive after the page is full. Keep it until the
    // carried line has been emitted on the next page, rather than consuming
    // the XHTML tag and silently dropping its meaning.
    pending_semantic: ?PendingSemantic = null,

    pub fn init(cache: *PageCache, max_width: usize, measure: Measure) EventPageBuilder {
        cache.clear();
        return .{ .cache = cache, .measure = measure, .max_width = max_width };
    }

    pub fn consume(self: *EventPageBuilder, event: xhtml.Event) error{ PageFull, LineTooLong }!void {
        if (self.page_full) return error.PageFull;
        switch (event) {
            .text => |bytes| for (bytes) |byte| {
                if (word_index.isBoundary(byte)) try self.finishWord() else {
                    if (self.word_len == self.word.len) return error.LineTooLong;
                    if (self.word_len == 0) self.source_word = true;
                    self.word[self.word_len] = byte;
                    self.word_len += 1;
                }
            },
            .line_break => try self.consumeSemantic(.line_break),
            .paragraph_break => try self.consumeSemantic(.paragraph_break),
            .heading => try self.consumeSemantic(.heading),
            .block_quote => try self.consumeSemantic(.block_quote),
            .list_item => try self.consumeSemantic(.list_item),
            .divider => try self.consumeSemantic(.divider),
        }
    }

    pub fn end(self: *EventPageBuilder) error{ PageFull, LineTooLong }!void {
        try self.finishLine();
    }

    /// Starts another owned page without discarding an unfinished word or
    /// line which caused the preceding page to fill.
    pub fn beginNextPage(self: *EventPageBuilder, cache: *PageCache) void {
        self.cache = cache;
        self.cache.clear();
        self.page_full = false;
        // The tokenizer reports the boundary whitespace as consumed when the
        // preceding page fills. Finalize the carried word before it sees the
        // next source byte, otherwise the two words would merge and every
        // following page's ordinal range would drift by one.
        self.finishWord() catch unreachable;
        if (self.pending_semantic) |event| {
            self.pending_semantic = null;
            self.applySemantic(event) catch unreachable;
        }
    }

    fn consumeSemantic(self: *EventPageBuilder, event: PendingSemantic) error{ PageFull, LineTooLong }!void {
        self.applySemantic(event) catch |err| switch (err) {
            error.PageFull => {
                self.pending_semantic = event;
                return error.PageFull;
            },
            error.LineTooLong => return error.LineTooLong,
        };
    }

    fn applySemantic(self: *EventPageBuilder, event: PendingSemantic) error{ PageFull, LineTooLong }!void {
        switch (event) {
            .line_break => try self.finishLine(),
            .paragraph_break => {
                try self.finishLine();
                if (!self.page_full and self.cache.line_count != 0) try self.appendLine("");
            },
            .heading, .block_quote => try self.finishLine(),
            .list_item => {
                try self.finishLine();
                try self.addSyntheticWord("- ");
            },
            .divider => {
                try self.finishLine();
                try self.appendLine("---");
            },
        }
    }

    fn addSyntheticWord(self: *EventPageBuilder, bytes: []const u8) error{ PageFull, LineTooLong }!void {
        // The following XHTML text completes this drawable token ("- item"),
        // but its ordinal belongs only to the item. The prefix length lets
        // PageCache select the item bytes rather than the marker.
        self.source_word = true;
        self.line_synthetic_prefix_bytes = @intCast(bytes.len);
        for (bytes) |byte| {
            if (self.word_len == self.word.len) return error.LineTooLong;
            self.word[self.word_len] = byte;
            self.word_len += 1;
        }
    }

    fn finishWord(self: *EventPageBuilder) error{ PageFull, LineTooLong }!void {
        if (self.word_len == 0) return;
        const line_was_empty = self.line_len == 0;
        const extra: usize = if (self.line_len == 0) 0 else 1;
        if (self.line_len + extra + self.word_len > self.line.len) return error.LineTooLong;
        var candidate: [max_cached_line_bytes]u8 = undefined;
        @memcpy(candidate[0..self.line_len], self.line[0..self.line_len]);
        if (extra != 0) candidate[self.line_len] = ' ';
        @memcpy(candidate[self.line_len + extra .. self.line_len + extra + self.word_len], self.word[0..self.word_len]);
        if (self.line_len != 0 and self.measure.width(self.measure.context, candidate[0 .. self.line_len + extra + self.word_len]) > self.max_width) {
            try self.appendLine(self.line[0..self.line_len]);
            if (self.page_full) return error.PageFull;
            @memcpy(self.line[0..self.word_len], self.word[0..self.word_len]);
            self.line_len = self.word_len;
        } else {
            @memcpy(self.line[0 .. self.line_len + extra + self.word_len], candidate[0 .. self.line_len + extra + self.word_len]);
            self.line_len += extra + self.word_len;
        }
        if (self.source_word) self.recordSourceWord();
        if (!self.source_word and line_was_empty) self.line_synthetic_prefix_bytes = @intCast(self.line_len);
        self.word_len = 0;
        self.source_word = false;
    }

    fn recordSourceWord(self: *EventPageBuilder) void {
        const ordinal = self.word_ordinals.accept();
        if (self.line_source_word_count == 0) self.line_first_word_ordinal = ordinal;
        self.line_source_word_count += 1;
    }

    fn finishLine(self: *EventPageBuilder) error{ PageFull, LineTooLong }!void {
        try self.finishWord();
        if (self.line_len != 0) try self.appendLine(self.line[0..self.line_len]);
    }

    fn appendLine(self: *EventPageBuilder, text: []const u8) error{ PageFull, LineTooLong }!void {
        self.cache.appendLineWithMetadata(text, self.line_synthetic_prefix_bytes, @intCast(self.line_source_word_count)) catch |err| switch (err) {
            error.PageFull => {
                self.page_full = true;
                return error.PageFull;
            },
            error.LineTooLong => return error.LineTooLong,
        };
        if (self.line_source_word_count != 0) {
            if (self.cache.word_count == 0) self.cache.first_word_ordinal = self.line_first_word_ordinal.?;
            self.cache.word_count += self.line_source_word_count;
            self.line_first_word_ordinal = null;
            self.line_source_word_count = 0;
        }
        self.line_synthetic_prefix_bytes = 0;
        self.line_len = 0;
    }
};

pub const Measure = struct {
    context: *anyopaque,
    width: *const fn (context: *anyopaque, text: []const u8) usize,
};

fn monospaceWidth(_: *anyopaque, text: []const u8) usize {
    return text.len;
}

const BuilderEvents = struct {
    builder: *EventPageBuilder,

    fn emit(context: *anyopaque, event: xhtml.Event) anyerror!void {
        const self: *BuilderEvents = @ptrCast(@alignCast(context));
        try self.builder.consume(event);
    }
};

test "page cache owns completed lines without chapter source storage" {
    var cache = PageCache{};
    try cache.appendLine("First line");
    try cache.appendLine("Second line");
    try std.testing.expectEqual(@as(u8, 2), cache.line_count);
    try std.testing.expectEqualStrings("First line", cache.line(0));
    try std.testing.expectEqualStrings("Second line", cache.line(1));
}

test "event page builder owns wrapped lines" {
    var context: u8 = 0;
    var cache = PageCache{};
    var builder = EventPageBuilder.init(&cache, 7, .{ .context = &context, .width = monospaceWidth });
    try builder.consume(.{ .text = "one two three" });
    try builder.end();
    try std.testing.expectEqualStrings("one two", cache.line(0));
    try std.testing.expectEqualStrings("three", cache.line(1));
    try std.testing.expectEqual(@as(u32, 0), cache.first_word_ordinal);
    try std.testing.expectEqual(@as(u32, 3), cache.word_count);
}

test "page ordinal metadata survives text chunk boundaries" {
    var context: u8 = 0;
    var cache = PageCache{};
    var builder = EventPageBuilder.init(&cache, 80, .{ .context = &context, .width = monospaceWidth });
    try builder.consume(.{ .text = "one " });
    try builder.consume(.{ .text = "two" });
    try builder.consume(.paragraph_break);
    try builder.consume(.{ .text = "three" });
    try builder.end();
    try std.testing.expectEqual(@as(u32, 0), cache.first_word_ordinal);
    try std.testing.expectEqual(@as(u32, 3), cache.word_count);
}

test "page cache derives the selected source-word span" {
    var context: u8 = 0;
    var cache = PageCache{};
    var builder = EventPageBuilder.init(&cache, 7, .{ .context = &context, .width = monospaceWidth });
    try builder.consume(.{ .text = "one two three" });
    try builder.end();

    const first = cache.wordSpan(0).?;
    try std.testing.expectEqual(@as(u8, 0), first.line_index);
    try std.testing.expectEqualStrings("one", cache.line(first.line_index)[first.start..first.end]);
    const last = cache.wordSpan(2).?;
    try std.testing.expectEqual(@as(u8, 1), last.line_index);
    try std.testing.expectEqualStrings("three", cache.line(last.line_index)[last.start..last.end]);
    try std.testing.expect(cache.wordSpan(3) == null);
}

test "selection moves one word without leaving the cached page" {
    var cache = PageCache{ .first_word_ordinal = 7, .word_count = 3 };
    try std.testing.expectEqual(@as(?u32, 7), cache.moveSelection(null, 1));
    try std.testing.expectEqual(@as(?u32, 8), cache.moveSelection(7, 1));
    try std.testing.expectEqual(@as(?u32, 9), cache.moveSelection(9, 1));
    try std.testing.expectEqual(@as(?u32, 7), cache.moveSelection(7, -1));
    try std.testing.expectEqual(@as(?u32, 8), cache.moveSelection(9, -1));
}

test "a carried line assigns its words to the next page ordinal range" {
    var context: u8 = 0;
    var current = PageCache{};
    var next = PageCache{};
    var builder = EventPageBuilder.init(&current, 1, .{ .context = &context, .width = monospaceWidth });
    const words = [_][]const u8{ "a ", "b ", "c ", "d ", "e ", "f ", "g ", "h ", "i ", "j ", "k ", "l ", "m " };
    for (words[0..12]) |chunk| try builder.consume(.{ .text = chunk });
    try std.testing.expectError(error.PageFull, builder.consume(.{ .text = words[12] }));
    try std.testing.expectEqual(@as(u8, max_lines), current.line_count);
    try std.testing.expectEqual(@as(u32, max_lines), current.word_count);
    try std.testing.expectEqual(@as(u32, 0), current.first_word_ordinal);

    builder.beginNextPage(&next);
    try builder.end();
    try std.testing.expectEqualStrings("l", next.line(0));
    try std.testing.expectEqualStrings("m", next.line(1));
    try std.testing.expectEqual(@as(u32, max_lines), next.first_word_ordinal);
    try std.testing.expectEqual(@as(u32, 2), next.word_count);
    const first_next = next.wordSpan(max_lines).?;
    try std.testing.expectEqualStrings("l", next.line(first_next.line_index)[first_next.start..first_next.end]);
}

test "tokenizer page boundaries preserve every carried word ordinal" {
    var context: u8 = 0;
    var pages: [3]PageCache = undefined;
    var builder = EventPageBuilder.init(&pages[0], 1, .{ .context = &context, .width = monospaceWidth });
    var events = BuilderEvents{ .builder = &builder };
    var extractor = xhtml.StreamExtractor.init(.{ .context = &events, .emit = BuilderEvents.emit });
    const source = "a b c d e f g h i j k l m n o p q r s t u v w x y";
    var page_index: usize = 0;
    for (source) |byte| {
        switch (try extractor.feed(&[_]u8{byte})) {
            .consumed => {},
            .page_full => {
                page_index += 1;
                try std.testing.expect(page_index < pages.len);
                builder.beginNextPage(&pages[page_index]);
            },
        }
    }
    try extractor.finish();
    try builder.end();

    try std.testing.expectEqual(@as(u32, 0), pages[0].first_word_ordinal);
    try std.testing.expectEqual(@as(u32, max_lines), pages[0].word_count);
    try std.testing.expectEqual(@as(u32, max_lines), pages[1].first_word_ordinal);
    try std.testing.expectEqual(@as(u32, max_lines), pages[1].word_count);
    try std.testing.expectEqual(@as(u32, max_lines * 2), pages[2].first_word_ordinal);
    try std.testing.expectEqual(@as(u32, 3), pages[2].word_count);
    const first_second = pages[1].wordSpan(max_lines).?;
    try std.testing.expectEqualStrings("l", pages[1].line(first_second.line_index)[first_second.start..first_second.end]);
    const first_third = pages[2].wordSpan(max_lines * 2).?;
    try std.testing.expectEqualStrings("w", pages[2].line(first_third.line_index)[first_third.start..first_third.end]);
}

test "replays a list marker after a page-full carried line" {
    var context: u8 = 0;
    var current = PageCache{};
    var next = PageCache{};
    var builder = EventPageBuilder.init(&current, 80, .{ .context = &context, .width = monospaceWidth });
    for (0..max_lines) |_| try current.appendLine("filled");
    try builder.consume(.{ .text = "before" });
    try std.testing.expectError(error.PageFull, builder.consume(.list_item));

    builder.beginNextPage(&next);
    try builder.consume(.{ .text = "item" });
    try builder.end();
    try std.testing.expectEqualStrings("before", next.line(0));
    try std.testing.expectEqualStrings("- item", next.line(1));
    try std.testing.expectEqual(@as(u32, 2), next.word_count);
    const item = next.wordSpan(1).?;
    try std.testing.expectEqualStrings("item", next.line(item.line_index)[item.start..item.end]);
}

test "replays a divider after a page-full carried line" {
    var context: u8 = 0;
    var current = PageCache{};
    var next = PageCache{};
    var builder = EventPageBuilder.init(&current, 80, .{ .context = &context, .width = monospaceWidth });
    for (0..max_lines) |_| try current.appendLine("filled");
    try builder.consume(.{ .text = "before" });
    try std.testing.expectError(error.PageFull, builder.consume(.divider));

    builder.beginNextPage(&next);
    try std.testing.expectEqualStrings("before", next.line(0));
    try std.testing.expectEqualStrings("---", next.line(1));
}
