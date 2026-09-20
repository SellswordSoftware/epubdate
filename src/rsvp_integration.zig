const std = @import("std");
const xhtml = @import("content/xhtml.zig");
const pagination = @import("content/pagination.zig");
const rsvp = @import("content/rsvp.zig");
const reading_position = @import("storage/resume.zig");
const settings = @import("storage/settings.zig");

/// Test-only fixture storage. Production RSVP uses its fixed history ring;
/// this fixture records tiny scripted chapters so assertions can span the
/// chapter and resume boundaries.
const Words = struct {
    text: [8][rsvp.max_word_bytes]u8 = undefined,
    lengths: [8]u16 = [_]u16{0} ** 8,
    positions: [8]rsvp.Position = undefined,
    len: usize = 0,

    fn emit(context: *anyopaque, emitted_word: rsvp.Word) !void {
        const self: *Words = @ptrCast(@alignCast(context));
        if (self.len == self.text.len) return error.FixtureOverflow;
        @memcpy(self.text[self.len][0..emitted_word.bytes.len], emitted_word.bytes);
        self.lengths[self.len] = @intCast(emitted_word.bytes.len);
        self.positions[self.len] = emitted_word.position;
        self.len += 1;
    }

    fn word(self: *const Words, index: usize) []const u8 {
        return self.text[index][0..self.lengths[index]];
    }
};

fn forwardEvent(context: *anyopaque, event: xhtml.Event) anyerror!void {
    const cursor: *rsvp.Cursor = @ptrCast(@alignCast(context));
    try cursor.consume(event);
}

fn streamChapter(source: []const u8, words: *Words) !void {
    var cursor = rsvp.Cursor.init(.{ .context = words, .emit = Words.emit });
    var extractor = xhtml.StreamExtractor.init(.{ .context = &cursor, .emit = forwardEvent });
    // One-byte feeds exercise arbitrary ZIP-decoded chunk boundaries without
    // requiring a whole chapter buffer in the reader implementation.
    for (source) |byte| _ = try extractor.feed(&[_]u8{byte});
    try extractor.finish();
    try cursor.finish();
}

const PageEvents = struct {
    builder: *pagination.EventPageBuilder,

    fn emit(context: *anyopaque, event: xhtml.Event) !void {
        const self: *PageEvents = @ptrCast(@alignCast(context));
        try self.builder.consume(event);
    }
};

fn monospaceWidth(_: *anyopaque, text: []const u8) usize {
    return text.len;
}

fn renderChapterPage(source: []const u8, cache: *pagination.PageCache) !void {
    var measure_context: u8 = 0;
    var builder = pagination.EventPageBuilder.init(cache, 80, .{ .context = &measure_context, .width = monospaceWidth });
    var events = PageEvents{ .builder = &builder };
    var extractor = xhtml.StreamExtractor.init(.{ .context = &events, .emit = PageEvents.emit });
    for (source) |byte| _ = try extractor.feed(&[_]u8{byte});
    try extractor.finish();
    try builder.end();
}

test "RSVP fixture covers stream entry, sentence rewind target, handoff, resume, and paged return" {
    var chapter_one = Words{};
    try streamChapter("<p>One. Two three.</p>", &chapter_one);
    try std.testing.expectEqual(@as(usize, 3), chapter_one.len);
    try std.testing.expectEqualStrings("One.", chapter_one.word(0));
    try std.testing.expectEqualStrings("Two", chapter_one.word(1));
    try std.testing.expectEqual(rsvp.Position{ .word = 1, .sentence = 1 }, chapter_one.positions[1]);

    // Manual forward and reverse operate on semantic word positions. A Left
    // sentence rewind from "three." targets sentence 0, word 0.
    const displayed = chapter_one.positions[2];
    try std.testing.expectEqual(@as(u32, 2), displayed.word);
    try std.testing.expectEqual(@as(u32, 1), displayed.sentence);
    const preceding_sentence = displayed.sentence - 1;
    try std.testing.expectEqual(@as(u32, 0), preceding_sentence);
    try std.testing.expectEqual(rsvp.Position{ .word = 0, .sentence = 0 }, chapter_one.positions[0]);

    // The final word remains in the first chapter's fixture output before
    // the next chapter begins its independent, incremental stream.
    try std.testing.expectEqualStrings("three.", chapter_one.word(2));
    var chapter_two = Words{};
    try streamChapter("<p>Next chapter.</p>", &chapter_two);
    try std.testing.expectEqualStrings("Next", chapter_two.word(0));

    var record: [reading_position.encoded_size]u8 = undefined;
    reading_position.encode(.{
        .book_id = 99,
        .layout_revision = 1,
        .chapter = 0,
        .word_ordinal = displayed.word,
        .mode = .rsvp,
    }, &record);
    const restored = try reading_position.decode(&record);
    try std.testing.expect(reading_position.matchesExact(restored, 99, 1, .rsvp));
    try std.testing.expectEqual(displayed.word, restored.word_ordinal);

    // Returning to Paged preserves a valid mode selection; the production
    // reader invalidates incompatible word caches and rebuilds the chapter.
    try std.testing.expectEqual(settings.ReadingMode.paged, settings.nextReadingMode(.rsvp));
}

test "Paged selection and RSVP hand-offs retain the same normalized word" {
    const source = "<p>One. Two three.</p>";
    var rsvp_words = Words{};
    try streamChapter(source, &rsvp_words);

    var page = pagination.PageCache{};
    try renderChapterPage(source, &page);
    try std.testing.expectEqual(@as(u32, 3), page.word_count);

    // A Paged crank stops on ordinal 2, whose cached drawable span is the
    // same semantic word RSVP emits at word position 2.
    const selected = page.moveSelection(1, 1).?;
    const span = page.wordSpan(selected).?;
    try std.testing.expectEqual(@as(u32, 2), selected);
    try std.testing.expectEqualStrings(rsvp_words.word(@intCast(selected)), page.line(span.line_index)[span.start..span.end]);

    // The word payload is independent of the active display mode: reopening
    // either Paged or RSVP from this record identifies the same word.
    var record: [reading_position.encoded_size]u8 = undefined;
    reading_position.encode(.{ .book_id = 99, .layout_revision = 1, .chapter = 0, .word_ordinal = selected, .mode = .paged }, &record);
    const restored = try reading_position.decode(&record);
    try std.testing.expect(restored.legacy_paged_page == null);
    try std.testing.expectEqual(selected, restored.word_ordinal);
    const restored_span = page.wordSpan(restored.word_ordinal).?;
    try std.testing.expectEqualStrings(rsvp_words.word(@intCast(restored.word_ordinal)), page.line(restored_span.line_index)[restored_span.start..restored_span.end]);
}

test "RSVP fixture anchor and elapsed autoplay hold across 100, 300, and 1000 WPM" {
    try std.testing.expectEqual(@as(u8, 1), rsvp.anchorIndex("word"));
    for ([_]u16{ 100, 300, 1_000 }) |wpm| {
        var timer = rsvp.Timer{};
        timer.start(10_000);
        const interval = @divTrunc(@as(u32, 60_000), wpm);
        try std.testing.expect(!timer.due(10_000 + interval - 1, wpm));
        try std.testing.expect(timer.due(10_000 + interval, wpm));
    }
}
