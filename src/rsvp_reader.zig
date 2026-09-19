const std = @import("std");
const xhtml = @import("content/xhtml.zig");
const rsvp = @import("content/rsvp.zig");
const pace = @import("storage/pace.zig");

/// Platform-free RSVP state. It retains exactly the displayed word and one
/// predecessor/successor; reconstruction is always expressed as a semantic
/// target for a new forward-only chapter stream.
pub const RsvpReader = struct {
    pub const RescanTarget = union(enum) { word: u32, sentence: u32 };
    pub const Move = union(enum) {
        moved,
        needs_word,
        needs_rescan: RescanTarget,
        needs_next_chapter,
        waiting,
        at_limit,
    };
    pub const RenderState = struct {
        word: ?[]const u8,
        position: rsvp.Position,
        waiting: bool,
        playing: bool,
        wpm: u16,
    };

    const Slot = struct {
        bytes: [rsvp.max_word_bytes]u8 = undefined,
        len: u16 = 0,
        position: rsvp.Position = .{},

        fn slice(self: *const Slot) []const u8 {
            return self.bytes[0..self.len];
        }

        fn copyFromWord(self: *Slot, word: rsvp.Word) void {
            @memcpy(self.bytes[0..word.bytes.len], word.bytes);
            self.len = @intCast(word.bytes.len);
            self.position = word.position;
        }

        fn copyFrom(self: *Slot, other: *const Slot) void {
            @memcpy(self.bytes[0..other.len], other.slice());
            self.len = other.len;
            self.position = other.position;
        }
    };

    chapter: u8 = 0,
    cursor: ?rsvp.Cursor = null,
    extractor: ?xhtml.StreamExtractor = null,
    current: Slot = .{},
    previous: Slot = .{},
    next: Slot = .{},
    has_current: bool = false,
    has_previous: bool = false,
    has_next: bool = false,
    rescan_target: ?RescanTarget = null,
    chapter_end: bool = false,
    timer: rsvp.Timer = .{},
    active_session: pace.ActiveSession = .{},
    wpm: u16 = rsvp.default_wpm,
    event_count: u32 = 0,

    pub fn begin(self: *RsvpReader, chapter: u8) void {
        self.chapter = chapter;
        self.cursor = rsvp.Cursor.init(.{ .context = self, .emit = emitWord });
        self.extractor = xhtml.StreamExtractor.init(.{ .context = self, .emit = emitEvent });
        self.current = .{};
        self.previous = .{};
        self.next = .{};
        self.has_current = false;
        self.has_previous = false;
        self.has_next = false;
        self.rescan_target = null;
        self.chapter_end = false;
        self.event_count = 0;
    }

    pub fn beginAtWord(self: *RsvpReader, chapter: u8, word: u32) void {
        self.begin(chapter);
        self.rescan_target = .{ .word = word };
    }

    pub fn reconstruct(self: *RsvpReader, target: RescanTarget) void {
        self.rescan_target = target;
    }

    pub fn feed(self: *RsvpReader, input: []const u8) anyerror!xhtml.StreamExtractor.FeedResult {
        return self.extractor.?.feed(input);
    }

    pub fn finishInput(self: *RsvpReader) anyerror!void {
        try self.extractor.?.finish();
        try self.cursor.?.finish();
        self.chapter_end = true;
    }

    pub fn renderState(self: *const RsvpReader) RenderState {
        return .{
            .word = if (self.has_current) self.current.slice() else null,
            .position = self.current.position,
            .waiting = !self.has_current or self.rescan_target != null,
            .playing = self.timer.running,
            .wpm = self.wpm,
        };
    }

    pub fn position(self: *const RsvpReader) rsvp.Position {
        return self.current.position;
    }

    pub fn hasWord(self: *const RsvpReader) bool {
        return self.has_current;
    }

    pub fn isReconstructing(self: *const RsvpReader) bool {
        return self.rescan_target != null;
    }

    pub fn targetUnresolved(self: *const RsvpReader) bool {
        return self.rescan_target != null;
    }

    pub fn nextWord(self: *RsvpReader) Move {
        if (!self.has_current or self.rescan_target != null) return .waiting;
        if (self.has_next) {
            self.previous.copyFrom(&self.current);
            self.has_previous = true;
            self.current.copyFrom(&self.next);
            self.has_next = false;
            return .moved;
        }
        if (self.chapter_end) return .needs_next_chapter;
        self.previous.copyFrom(&self.current);
        self.has_previous = true;
        self.has_current = false;
        return .needs_word;
    }

    pub fn previousWord(self: *RsvpReader) Move {
        if (!self.has_current or self.rescan_target != null) return .waiting;
        if (self.has_previous) {
            self.next.copyFrom(&self.current);
            self.has_next = true;
            self.current.copyFrom(&self.previous);
            self.has_previous = false;
            return .moved;
        }
        if (self.current.position.word == 0) return .at_limit;
        return .{ .needs_rescan = .{ .word = self.current.position.word - 1 } };
    }

    pub fn previousSentence(self: *const RsvpReader) Move {
        if (!self.has_current or self.rescan_target != null) return .waiting;
        if (self.current.position.sentence == 0) return .at_limit;
        return .{ .needs_rescan = .{ .sentence = self.current.position.sentence - 1 } };
    }

    pub fn toggleAutoplay(self: *RsvpReader, now_ms: u32, stats: *pace.Stats) void {
        if (self.timer.running) self.stopAutoplay(now_ms, stats) else {
            self.timer.start(now_ms);
            if (self.has_current) self.active_session.begin(now_ms);
        }
    }

    pub fn stopAutoplay(self: *RsvpReader, now_ms: u32, stats: *pace.Stats) void {
        self.recordAutoplay(now_ms, 0, stats);
        self.timer.stop();
        self.active_session = .{};
    }

    pub fn adjustWpm(self: *RsvpReader, direction: i8, now_ms: u32, stats: *pace.Stats) bool {
        const adjusted = rsvp.adjustWpm(self.wpm, direction);
        if (adjusted == self.wpm) return false;
        self.recordAutoplay(now_ms, 0, stats);
        self.wpm = adjusted;
        self.timer.reset(now_ms);
        if (self.timer.running and self.has_current) self.active_session.begin(now_ms);
        return true;
    }

    /// A due tick records one completed automatic word and returns the same
    /// semantic movement request as a manual forward action.
    pub fn autoplay(self: *RsvpReader, now_ms: u32, stats: *pace.Stats) ?Move {
        if (!self.has_current or !self.timer.due(now_ms, self.wpm)) return null;
        self.recordAutoplay(now_ms, 1, stats);
        const move = self.nextWord();
        if (self.has_current and self.timer.running) self.active_session.begin(now_ms);
        return move;
    }

    pub fn recordAutoplay(self: *RsvpReader, now_ms: u32, completed_words: u32, stats: *pace.Stats) void {
        if (!self.timer.running or self.active_session.started_at_ms == null) return;
        self.active_session.record(stats, now_ms, completed_words);
    }

    /// The coordinator calls this when bounded decoding makes a new current
    /// word drawable. It deliberately restarts the interval at presentation,
    /// rather than at the earlier input action that requested the word.
    pub fn wordBecameDrawable(self: *RsvpReader, now_ms: u32) void {
        if (!self.timer.running or !self.has_current) return;
        self.timer.reset(now_ms);
        self.active_session.begin(now_ms);
    }

    fn acceptWord(self: *RsvpReader, word: rsvp.Word) void {
        if (self.rescan_target) |target| {
            switch (target) {
                .word => |wanted| if (word.position.word != wanted) return,
                .sentence => |wanted| if (word.position.sentence != wanted) return,
            }
            self.rescan_target = null;
        }
        self.current.copyFromWord(word);
        self.has_current = true;
    }
};

fn emitEvent(context: *anyopaque, event: xhtml.Event) anyerror!void {
    const self: *RsvpReader = @ptrCast(@alignCast(context));
    self.event_count +%= 1;
    try self.cursor.?.consume(event);
}

fn emitWord(context: *anyopaque, word: rsvp.Word) anyerror!void {
    const self: *RsvpReader = @ptrCast(@alignCast(context));
    self.acceptWord(word);
}

fn feedAll(reader: *RsvpReader, source: []const u8) !void {
    for (source) |byte| {
        _ = try reader.feed(&[_]u8{byte});
        if (reader.hasWord()) return;
    }
}

test "RSVP retains current plus two neighbor slots and reconstructs a cache miss" {
    var reader = RsvpReader{};
    reader.begin(2);
    try feedAll(&reader, "one two three");
    try std.testing.expectEqualStrings("one", reader.renderState().word.?);
    try std.testing.expectEqual(RsvpReader.Move.needs_word, reader.nextWord());
    try feedAll(&reader, "two three");
    try std.testing.expectEqualStrings("two", reader.renderState().word.?);
    try std.testing.expectEqual(RsvpReader.Move.moved, reader.previousWord());
    try std.testing.expectEqualStrings("one", reader.renderState().word.?);
    try std.testing.expectEqual(RsvpReader.Move.moved, reader.nextWord());
    try std.testing.expectEqual(RsvpReader.Move.needs_word, reader.nextWord());
    try feedAll(&reader, "three ");
    try std.testing.expectEqualStrings("three", reader.renderState().word.?);
    try std.testing.expectEqual(RsvpReader.Move.moved, reader.previousWord());
    try std.testing.expect(reader.previousWord() == .needs_rescan);
    try std.testing.expect(@as(usize, @intFromBool(reader.has_current)) + @as(usize, @intFromBool(reader.has_previous)) + @as(usize, @intFromBool(reader.has_next)) <= 3);
}

test "RSVP timing, WPM bounds, sentence rewind, and final word are semantic outcomes" {
    var reader = RsvpReader{};
    var stats = pace.Stats{ .book_id = 1 };
    reader.begin(0);
    try feedAll(&reader, "One. ");
    try std.testing.expectEqual(RsvpReader.Move.at_limit, reader.previousSentence());
    try std.testing.expectEqual(RsvpReader.Move.needs_word, reader.nextWord());
    try feedAll(&reader, "two ");
    const rewind = reader.previousSentence();
    try std.testing.expect(rewind == .needs_rescan);
    try std.testing.expectEqual(@as(u32, 0), rewind.needs_rescan.sentence);
    reader.toggleAutoplay(0, &stats);
    try std.testing.expect(reader.autoplay(199, &stats) == null);
    try std.testing.expect(reader.autoplay(200, &stats) != null);
    _ = reader.adjustWpm(-1, 200, &stats);
    while (reader.adjustWpm(-1, 200, &stats)) {}
    try std.testing.expectEqual(rsvp.min_wpm, reader.wpm);
    while (reader.adjustWpm(1, 200, &stats)) {}
    try std.testing.expectEqual(rsvp.max_wpm, reader.wpm);
    reader.stopAutoplay(300, &stats);

    var final_word = RsvpReader{};
    final_word.begin(0);
    try feedAll(&final_word, "last");
    try final_word.finishInput();
    try std.testing.expectEqualStrings("last", final_word.renderState().word.?);
    try std.testing.expectEqual(RsvpReader.Move.needs_next_chapter, final_word.nextWord());
}
