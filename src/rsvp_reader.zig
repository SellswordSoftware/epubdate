const std = @import("std");
const xhtml = @import("content/xhtml.zig");
const rsvp = @import("content/rsvp.zig");
const pace = @import("storage/pace.zig");

/// Platform-free RSVP state. It retains a bounded ordered word window while
/// reconstruction remains a semantic target for a new forward-only stream.
pub const RsvpReader = struct {
    pub const history_capacity: usize = 64;
    pub const slot_capacity: usize = history_capacity + 2;
    pub const retained_capacity: usize = history_capacity + 1;
    pub const SlotIndex = u8;
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
        first_in_sentence: bool = false,

        fn slice(self: *const Slot) []const u8 {
            return self.bytes[0..self.len];
        }

        fn copyFromWord(self: *Slot, word: rsvp.Word, first_in_sentence: bool) void {
            @memcpy(self.bytes[0..word.bytes.len], word.bytes);
            self.len = @intCast(word.bytes.len);
            self.position = word.position;
            self.first_in_sentence = first_in_sentence;
        }
    };

    pub const word_pool_reserved_bytes = slot_capacity * @sizeOf(Slot);
    pub const word_pool_byte_budget = 27 * 1024;

    comptime {
        std.debug.assert(slot_capacity == 66);
        std.debug.assert(slot_capacity <= @as(usize, std.math.maxInt(SlotIndex)) + 1);
        std.debug.assert(word_pool_reserved_bytes <= word_pool_byte_budget);
    }

    chapter: u8 = 0,
    cursor: ?rsvp.Cursor = null,
    extractor: ?xhtml.StreamExtractor = null,
    slots: [slot_capacity]Slot = [_]Slot{.{}} ** slot_capacity,
    oldest: SlotIndex = 0,
    valid_count: SlotIndex = 0,
    displayed_offset: SlotIndex = 0,
    waiting_for_word: bool = false,
    rescan_target: ?RescanTarget = null,
    chapter_end: bool = false,
    timer: rsvp.Timer = .{},
    active_session: pace.ActiveSession = .{},
    wpm: u16 = rsvp.default_wpm,
    event_count: u32 = 0,

    pub fn initInPlace(self: *RsvpReader) void {
        self.slots = undefined;
        self.chapter = 0;
        self.cursor = null;
        self.extractor = null;
        self.resetWindow();
        self.rescan_target = null;
        self.chapter_end = false;
        self.timer = .{};
        self.active_session = .{};
        self.wpm = rsvp.default_wpm;
        self.event_count = 0;
    }

    pub fn begin(self: *RsvpReader, chapter: u8) void {
        self.chapter = chapter;
        self.cursor = rsvp.Cursor.init(.{ .context = self, .emit = emitWord });
        self.extractor = xhtml.StreamExtractor.init(.{ .context = self, .emit = emitEvent });
        self.resetWindow();
        self.rescan_target = null;
        self.chapter_end = false;
        self.event_count = 0;
    }

    pub fn beginAtWord(self: *RsvpReader, chapter: u8, word: u32) void {
        self.begin(chapter);
        self.rescan_target = .{ .word = word };
    }

    pub fn reconstruct(self: *RsvpReader, target: RescanTarget) void {
        self.resetWindow();
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
        const current = self.drawableSlot();
        return .{
            .word = if (current) |slot| slot.slice() else null,
            .position = self.position(),
            .waiting = current == null,
            .playing = self.timer.running,
            .wpm = self.wpm,
        };
    }

    pub fn position(self: *const RsvpReader) rsvp.Position {
        return if (self.currentSlot()) |slot| slot.position else .{};
    }

    pub fn hasWord(self: *const RsvpReader) bool {
        return self.drawableSlot() != null;
    }

    pub fn isReconstructing(self: *const RsvpReader) bool {
        return self.rescan_target != null;
    }

    pub fn targetUnresolved(self: *const RsvpReader) bool {
        return self.rescan_target != null;
    }

    pub fn nextWord(self: *RsvpReader) Move {
        if (!self.hasWord()) return .waiting;
        if (@as(usize, self.displayed_offset) + 1 < self.valid_count) {
            self.displayed_offset += 1;
            return .moved;
        }
        if (self.chapter_end) return .needs_next_chapter;
        self.waiting_for_word = true;
        return .needs_word;
    }

    pub fn previousWord(self: *RsvpReader) Move {
        if (!self.hasWord()) return .waiting;
        if (self.displayed_offset != 0) {
            self.displayed_offset -= 1;
            return .moved;
        }
        if (self.position().word == 0) return .at_limit;
        return .{ .needs_rescan = .{ .word = self.position().word - 1 } };
    }

    pub fn previousSentence(self: *RsvpReader) Move {
        if (!self.hasWord()) return .waiting;
        const current_sentence = self.position().sentence;
        if (current_sentence == 0) return .at_limit;
        const wanted = current_sentence - 1;
        var offset = self.displayed_offset;
        while (offset != 0) {
            offset -= 1;
            const slot = self.slotAt(offset);
            if (slot.position.sentence == wanted and slot.first_in_sentence) {
                self.displayed_offset = offset;
                return .moved;
            }
        }
        return .{ .needs_rescan = .{ .sentence = wanted } };
    }

    pub fn toggleAutoplay(self: *RsvpReader, now_ms: u32, stats: *pace.Stats) void {
        if (self.timer.running) self.stopAutoplay(now_ms, stats) else {
            self.timer.start(now_ms);
            if (self.hasWord()) self.active_session.begin(now_ms);
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
        if (self.timer.running and self.hasWord()) self.active_session.begin(now_ms);
        return true;
    }

    /// A due tick records one completed automatic word and returns the same
    /// semantic movement request as a manual forward action.
    pub fn autoplay(self: *RsvpReader, now_ms: u32, stats: *pace.Stats) ?Move {
        if (!self.hasWord() or !self.timer.due(now_ms, self.wpm)) return null;
        self.recordAutoplay(now_ms, 1, stats);
        const move = self.nextWord();
        if (self.hasWord() and self.timer.running) self.active_session.begin(now_ms);
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
        if (!self.timer.running or !self.hasWord()) return;
        self.timer.reset(now_ms);
        self.active_session.begin(now_ms);
    }

    fn acceptWord(self: *RsvpReader, word: rsvp.Word) void {
        self.appendWord(word);
        if (self.rescan_target) |target| {
            switch (target) {
                .word => |wanted| if (word.position.word != wanted) return,
                .sentence => |wanted| if (word.position.sentence != wanted) return,
            }
            self.rescan_target = null;
        }
        self.displayed_offset = self.valid_count - 1;
        self.waiting_for_word = false;
    }

    fn resetWindow(self: *RsvpReader) void {
        self.oldest = 0;
        self.valid_count = 0;
        self.displayed_offset = 0;
        self.waiting_for_word = false;
    }

    fn appendWord(self: *RsvpReader, word: rsvp.Word) void {
        const first_in_sentence = if (self.valid_count == 0)
            word.position.word == 0
        else
            self.slotAt(self.valid_count - 1).position.sentence != word.position.sentence;
        const destination = self.physicalIndex(self.valid_count);
        self.slots[destination].copyFromWord(word, first_in_sentence);
        self.valid_count += 1;
        if (self.valid_count > retained_capacity) {
            self.oldest = @intCast((@as(usize, self.oldest) + 1) % slot_capacity);
            self.valid_count -= 1;
        }
        self.displayed_offset = self.valid_count - 1;
    }

    fn drawableSlot(self: *const RsvpReader) ?*const Slot {
        if (self.waiting_for_word or self.rescan_target != null) return null;
        return self.currentSlot();
    }

    fn currentSlot(self: *const RsvpReader) ?*const Slot {
        if (self.valid_count == 0) return null;
        return self.slotAt(self.displayed_offset);
    }

    fn slotAt(self: *const RsvpReader, logical_offset: SlotIndex) *const Slot {
        std.debug.assert(logical_offset < self.valid_count);
        return &self.slots[self.physicalIndex(logical_offset)];
    }

    fn physicalIndex(self: *const RsvpReader, logical_offset: SlotIndex) usize {
        return (@as(usize, self.oldest) + @as(usize, logical_offset)) % slot_capacity;
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

test "RSVP streams into its ordered cache and reuses newer words" {
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
    try std.testing.expectEqual(RsvpReader.Move.moved, reader.previousWord());
    try std.testing.expectEqualStrings("one", reader.renderState().word.?);
    try std.testing.expectEqual(RsvpReader.Move.at_limit, reader.previousWord());
    try std.testing.expectEqual(@as(RsvpReader.SlotIndex, 3), reader.valid_count);
}

test "RSVP reconstruction retains 64 prior words and sentence misses stay semantic" {
    var reader = RsvpReader{};
    reader.begin(0);
    reader.reconstruct(.{ .word = 69 });
    var buffer: [16]u8 = undefined;
    for (0..70) |index| {
        const text = try std.fmt.bufPrint(&buffer, "w{d}", .{index});
        reader.acceptWord(.{ .bytes = text, .position = .{ .word = @intCast(index), .sentence = 0 } });
    }
    try std.testing.expect(reader.hasWord());
    try std.testing.expectEqual(@as(u32, 69), reader.position().word);
    try std.testing.expectEqual(@as(RsvpReader.SlotIndex, 65), reader.valid_count);
    for (0..64) |_| try std.testing.expectEqual(RsvpReader.Move.moved, reader.previousWord());
    try std.testing.expectEqual(@as(u32, 5), reader.position().word);
    const miss = reader.previousWord();
    try std.testing.expect(miss == .needs_rescan);
    try std.testing.expectEqual(@as(u32, 4), miss.needs_rescan.word);
    for (0..64) |_| try std.testing.expectEqual(RsvpReader.Move.moved, reader.nextWord());
    try std.testing.expectEqual(@as(u32, 69), reader.position().word);

    reader.begin(0);
    for (0..66) |index| {
        const sentence: u32 = if (index == 65) 1 else 0;
        reader.acceptWord(.{ .bytes = "word", .position = .{ .word = @intCast(index), .sentence = sentence } });
    }
    const sentence_miss = reader.previousSentence();
    try std.testing.expect(sentence_miss == .needs_rescan);
    try std.testing.expectEqual(@as(u32, 0), sentence_miss.needs_rescan.sentence);

    reader.begin(0);
    var utf8_word: [rsvp.max_word_bytes]u8 = undefined;
    for (0..utf8_word.len / 2) |index| {
        utf8_word[index * 2] = 0xc3;
        utf8_word[index * 2 + 1] = 0xa9;
    }
    reader.acceptWord(.{ .bytes = &utf8_word, .position = .{} });
    try std.testing.expectEqualSlices(u8, &utf8_word, reader.renderState().word.?);
}

test "RSVP timing, WPM bounds, sentence rewind, and final word are semantic outcomes" {
    var reader = RsvpReader{};
    var stats = pace.Stats{ .book_id = 1 };
    reader.begin(0);
    try feedAll(&reader, "One. ");
    try std.testing.expectEqual(RsvpReader.Move.at_limit, reader.previousSentence());
    try std.testing.expectEqual(RsvpReader.Move.needs_word, reader.nextWord());
    try feedAll(&reader, "two ");
    try std.testing.expectEqual(RsvpReader.Move.moved, reader.previousSentence());
    try std.testing.expectEqual(@as(u32, 0), reader.position().sentence);
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
