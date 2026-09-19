const std = @import("std");
const xhtml = @import("xhtml.zig");
const word_index = @import("word_index.zig");

/// One displayed word is the only input-derived text RSVP retains.  A later
/// backward seek rebuilds this position by replaying the chapter stream.
pub const max_word_bytes = 384;
pub const default_wpm: u16 = 300;
pub const min_wpm: u16 = 100;
pub const max_wpm: u16 = 1000;
pub const wpm_step: u16 = 25;

pub fn validateWpm(wpm: u16) ?u16 {
    if (wpm < min_wpm or wpm > max_wpm or (wpm - min_wpm) % wpm_step != 0) return null;
    return wpm;
}

pub fn clampWpm(wpm: u16) u16 {
    if (wpm <= min_wpm) return min_wpm;
    if (wpm >= max_wpm) return max_wpm;
    return min_wpm + @divTrunc(wpm - min_wpm, wpm_step) * wpm_step;
}

pub fn adjustWpm(wpm: u16, direction: i8) u16 {
    const value = clampWpm(wpm);
    if (direction > 0) return @min(max_wpm, value + wpm_step);
    if (direction < 0) return @max(min_wpm, value - wpm_step);
    return value;
}

/// Wall-clock scheduler. A due interval advances at most one word; repeated
/// frame updates without elapsed time cannot manufacture reading progress.
pub const Timer = struct {
    running: bool = false,
    last_ms: u32 = 0,

    pub fn start(self: *Timer, now_ms: u32) void {
        self.running = true;
        self.last_ms = now_ms;
    }

    pub fn stop(self: *Timer) void {
        self.running = false;
    }

    pub fn reset(self: *Timer, now_ms: u32) void {
        self.last_ms = now_ms;
    }

    pub fn due(self: *Timer, now_ms: u32, wpm: u16) bool {
        if (!self.running) return false;
        const interval_ms: u32 = @divTrunc(60_000, clampWpm(wpm));
        if (now_ms -% self.last_ms < interval_ms) return false;
        self.last_ms = now_ms;
        return true;
    }
};

pub const Position = struct {
    word: u32 = 0,
    sentence: u32 = 0,
};

pub const Word = struct {
    bytes: []const u8,
    position: Position,
};

pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, word: Word) anyerror!void,

    pub fn write(self: Sink, word: Word) !void {
        try self.emit(self.context, word);
    }
};

/// Converts normalized XHTML text events into a forward-only word stream.
/// Semantic breaks are word boundaries but are otherwise intentionally not
/// stored; `Position` is enough to reconstruct this cursor by replaying it.
pub const Cursor = struct {
    sink: Sink,
    word: [max_word_bytes]u8 = undefined,
    word_len: usize = 0,
    next_position: Position = .{},
    word_ordinals: word_index.Counter = .{},

    pub fn init(sink: Sink) Cursor {
        return .{ .sink = sink };
    }

    pub fn consume(self: *Cursor, event: xhtml.Event) !void {
        switch (event) {
            .text => |bytes| try self.text(bytes),
            else => try self.finishWord(),
        }
    }

    pub fn finish(self: *Cursor) !void {
        try self.finishWord();
    }

    fn text(self: *Cursor, bytes: []const u8) !void {
        for (bytes) |byte| {
            if (word_index.isBoundary(byte)) {
                try self.finishWord();
            } else {
                if (self.word_len == self.word.len) return error.WordTooLong;
                self.word[self.word_len] = byte;
                self.word_len += 1;
            }
        }
    }

    fn finishWord(self: *Cursor) !void {
        if (self.word_len == 0) return;
        const bytes = self.word[0..self.word_len];
        self.next_position.word = self.word_ordinals.accept();
        try self.sink.write(.{ .bytes = bytes, .position = self.next_position });
        if (endsSentence(bytes)) self.next_position.sentence += 1;
        self.word_len = 0;
    }
};

/// The product's anchor rule counts letters, not UTF-8 bytes or punctuation.
/// ASCII punctuation is ignored and non-ASCII codepoints count as letters so
/// a valid UTF-8 word remains visually stable even with a future Unicode font.
pub fn anchorIndex(word: []const u8) u8 {
    const letters = letterCount(word);
    return if (letters <= 3) 1 else if (letters <= 5) 2 else if (letters <= 9) 3 else if (letters <= 13) 4 else 5;
}

/// Byte span of the selected anchor glyph. This keeps the renderer from
/// splitting a UTF-8 sequence while measuring the anchor's fixed center.
pub fn anchorBytes(word: []const u8) ?struct { start: usize, end: usize } {
    const wanted = anchorIndex(word);
    var seen: u8 = 0;
    var index: usize = 0;
    while (index < word.len) {
        const length = utf8SequenceLength(word[index]);
        const end = @min(word.len, index + length);
        if (isLetter(word[index..end])) {
            seen += 1;
            if (seen == wanted) return .{ .start = index, .end = end };
        }
        index = end;
    }
    return null;
}

fn letterCount(word: []const u8) u8 {
    var count: u8 = 0;
    var index: usize = 0;
    while (index < word.len) {
        const end = @min(word.len, index + utf8SequenceLength(word[index]));
        if (isLetter(word[index..end]) and count != std.math.maxInt(u8)) count += 1;
        index = end;
    }
    return count;
}

fn utf8SequenceLength(first: u8) usize {
    return if (first < 0x80) 1 else if (first & 0xe0 == 0xc0) 2 else if (first & 0xf0 == 0xe0) 3 else if (first & 0xf8 == 0xf0) 4 else 1;
}

fn isLetter(bytes: []const u8) bool {
    return if (bytes.len == 1) std.ascii.isAlphabetic(bytes[0]) else true;
}

fn endsSentence(bytes: []const u8) bool {
    var index = bytes.len;
    while (index != 0) {
        index -= 1;
        switch (bytes[index]) {
            '.', '!', '?' => return true,
            '"', '\'', ')', ']', '}' => {},
            else => return false,
        }
    }
    return false;
}

const Collected = struct {
    words: [8][max_word_bytes]u8 = undefined,
    lengths: [8]u16 = [_]u16{0} ** 8,
    positions: [8]Position = undefined,
    len: usize = 0,

    fn emit(context: *anyopaque, emitted_word: Word) !void {
        const self: *Collected = @ptrCast(@alignCast(context));
        if (self.len == self.words.len) return error.TestOverflow;
        @memcpy(self.words[self.len][0..emitted_word.bytes.len], emitted_word.bytes);
        self.lengths[self.len] = @intCast(emitted_word.bytes.len);
        self.positions[self.len] = emitted_word.position;
        self.len += 1;
    }

    fn word(self: *const Collected, index: usize) []const u8 {
        return self.words[index][0..self.lengths[index]];
    }
};

fn forwardXhtmlEvent(context: *anyopaque, event: xhtml.Event) anyerror!void {
    const cursor: *Cursor = @ptrCast(@alignCast(context));
    try cursor.consume(event);
}

test "cursor reconstructs sentence and word positions from chunked XHTML events" {
    var collected = Collected{};
    var cursor = Cursor.init(.{ .context = &collected, .emit = Collected.emit });
    try cursor.consume(.{ .text = "One" });
    try cursor.consume(.{ .text = "! two" });
    try cursor.consume(.paragraph_break);
    try cursor.consume(.{ .text = "three?" });
    try cursor.finish();
    try std.testing.expectEqual(@as(usize, 3), collected.len);
    try std.testing.expectEqualStrings("One!", collected.word(0));
    try std.testing.expectEqual(Position{ .word = 0, .sentence = 0 }, collected.positions[0]);
    try std.testing.expectEqual(Position{ .word = 1, .sentence = 1 }, collected.positions[1]);
    try std.testing.expectEqual(Position{ .word = 2, .sentence = 1 }, collected.positions[2]);
}

test "cursor accepts text split through UTF-8 and preserves punctuation" {
    var collected = Collected{};
    var cursor = Cursor.init(.{ .context = &collected, .emit = Collected.emit });
    try cursor.consume(.{ .text = "caf\xc3" });
    try cursor.consume(.{ .text = "\xa9, next." });
    try cursor.finish();
    try std.testing.expectEqualStrings("caf\xc3\xa9,", collected.word(0));
    try std.testing.expectEqualStrings("next.", collected.word(1));
}

test "XHTML split at every byte reaches the same bounded word cursor" {
    var collected = Collected{};
    var cursor = Cursor.init(.{ .context = &collected, .emit = Collected.emit });
    var extractor = xhtml.StreamExtractor.init(.{ .context = &cursor, .emit = forwardXhtmlEvent });
    const source = "<p>One! caf\xc3\xa9, <em>next.</em></p>";
    for (source) |byte| _ = try extractor.feed(&[_]u8{byte});
    try extractor.finish();
    try cursor.finish();
    try std.testing.expectEqual(@as(usize, 3), collected.len);
    try std.testing.expectEqualStrings("One!", collected.word(0));
    // The current system-font XHTML policy maps unsupported Unicode to '?',
    // but the word boundary and punctuation remain intact across chunks.
    try std.testing.expectEqualStrings("caf?,", collected.word(1));
    try std.testing.expectEqualStrings("next.", collected.word(2));
}

test "anchor bands count letters and return complete UTF-8 glyph spans" {
    const cases = [_]struct { word: []const u8, anchor: u8 }{
        .{ .word = "a", .anchor = 1 },
        .{ .word = "four", .anchor = 2 },
        .{ .word = "sixsix", .anchor = 3 },
        .{ .word = "tenletters", .anchor = 4 },
        .{ .word = "fourteenletters", .anchor = 5 },
        .{ .word = "\xc3\xa9clair", .anchor = 3 },
    };
    for (cases) |case| try std.testing.expectEqual(case.anchor, anchorIndex(case.word));
    const span = anchorBytes("\xc3\xa9clair").?;
    try std.testing.expectEqualStrings("l", "\xc3\xa9clair"[span.start..span.end]);
}

test "WPM settings clamp, step, and validate their configured bounds" {
    try std.testing.expectEqual(default_wpm, clampWpm(default_wpm));
    try std.testing.expectEqual(@as(u16, 325), adjustWpm(default_wpm, 1));
    try std.testing.expectEqual(@as(u16, 275), adjustWpm(default_wpm, -1));
    try std.testing.expectEqual(min_wpm, adjustWpm(min_wpm, -1));
    try std.testing.expectEqual(max_wpm, adjustWpm(max_wpm, 1));
    try std.testing.expect(validateWpm(425) != null);
    try std.testing.expect(validateWpm(426) == null);
}

test "autoplay timing is elapsed-time based, not frame-count based" {
    var timer = Timer{};
    timer.start(1_000);
    for (0..100) |_| try std.testing.expect(!timer.due(1_199, 300));
    try std.testing.expect(timer.due(1_200, 300));
    try std.testing.expect(!timer.due(1_200, 300));
    try std.testing.expect(timer.due(1_260, 1_000));
    timer.stop();
    try std.testing.expect(!timer.due(99_999, 1_000));
}
