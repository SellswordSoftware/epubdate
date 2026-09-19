const std = @import("std");
const cache_policy = @import("content/cache_policy.zig");
const navigation = @import("content/navigation.zig");
const pagination = @import("content/pagination.zig");
const reader_transitions = @import("reader_transitions.zig");
const xhtml = @import("content/xhtml.zig");
const prefetch_session = @import("prefetch_session.zig");

/// Platform-free Paged-reader state. It owns page caches, semantic navigation,
/// and page construction; platform code supplies bounded stream work.
pub const PagedReader = struct {
    pub const page_capacity = 3;
    pub const SelectionTarget = reader_transitions.PagedSelectionTarget;

    pub const BuildState = union(enum) {
        idle,
        building: u2,
        ready: u2,
    };

    /// A rescan always restarts decoding at the chapter beginning.  This is a
    /// semantic target, never a compressed-data offset.
    pub const Rescan = union(enum) {
        none,
        page: struct { target: u32, scanning: u32 },
        last_page: struct { scanning: u32, last_completed: u2 },
    };

    pub const Move = enum {
        moved,
        waiting,
        needs_reconstruction,
        needs_previous_chapter,
        needs_next_chapter,
        at_limit,
    };

    pub const RenderState = struct {
        page: ?*const pagination.PageCache,
        selected_word_ordinal: ?u32,
        page_index: u32,
        waiting_for_page: bool,
    };

    pages: [page_capacity]pagination.PageCache = [_]pagination.PageCache{.{}} ** page_capacity,
    previous_page: u2 = 2,
    current_page: u2 = 0,
    next_page: u2 = 1,
    previous_ready: bool = false,
    current_ready: bool = false,
    next_ready: bool = false,
    build: BuildState = .idle,
    builder: ?pagination.EventPageBuilder = null,
    extractor: ?xhtml.StreamExtractor = null,
    selected_word_ordinal: ?u32 = null,
    pending_selection: ?SelectionTarget = null,
    detent_backlog: i16 = 0,
    chapter_index: u8 = 0,
    page_index: u32 = 0,
    chapter_end: bool = false,
    chapter_last_page: ?u32 = null,
    rescan: Rescan = .none,
    cache_navigation: bool = false,
    stream_front_page: u32 = 0,
    navigation_state: navigation.State = .{},
    checkpoints: cache_policy.Policy,
    prefetch: prefetch_session.Session = .{},

    /// Initializes directly in caller-owned storage.  Page caches are large,
    /// so constructing this by value would put a transient cache pool on the
    /// Playdate stack.
    pub fn initInPlace(self: *PagedReader, checkpoint_byte_budget: usize) void {
        self.* = undefined;
        for (&self.pages) |*page| page.clear();
        self.previous_page = 2;
        self.current_page = 0;
        self.next_page = 1;
        self.previous_ready = false;
        self.current_ready = false;
        self.next_ready = false;
        self.build = .idle;
        self.builder = null;
        self.extractor = null;
        self.selected_word_ordinal = null;
        self.pending_selection = null;
        self.detent_backlog = 0;
        self.chapter_index = 0;
        self.page_index = 0;
        self.chapter_end = false;
        self.chapter_last_page = null;
        self.rescan = .none;
        self.cache_navigation = false;
        self.stream_front_page = 0;
        self.navigation_state = .{};
        self.checkpoints = cache_policy.Policy.init(checkpoint_byte_budget);
        self.prefetch = .{};
    }

    /// Host-test convenience only. Device startup must use `initInPlace`.
    pub fn init(checkpoint_byte_budget: usize) PagedReader {
        var reader: PagedReader = undefined;
        reader.initInPlace(checkpoint_byte_budget);
        return reader;
    }

    pub fn begin(self: *PagedReader, chapter: u8, width: usize, measure: pagination.Measure) void {
        self.chapter_index = chapter;
        self.page_index = 0;
        self.previous_page = 2;
        self.current_page = 0;
        self.next_page = 1;
        self.previous_ready = false;
        self.current_ready = false;
        self.next_ready = false;
        self.selected_word_ordinal = null;
        self.pending_selection = null;
        self.detent_backlog = 0;
        self.chapter_end = false;
        self.chapter_last_page = null;
        self.rescan = .none;
        self.cache_navigation = false;
        self.stream_front_page = 0;
        self.navigation_state.opened(0);
        for (&self.pages) |*page| page.clear();
        self.builder = pagination.EventPageBuilder.init(&self.pages[self.current_page], width, measure);
        self.extractor = xhtml.StreamExtractor.init(.{ .context = self, .emit = emitEvent });
        self.build = .{ .building = self.current_page };
    }

    pub fn beginRescan(self: *PagedReader, target: u32) void {
        self.cache_navigation = false;
        self.navigation_state.beginRescan(target);
        self.rescan = .{ .page = .{ .target = target, .scanning = 0 } };
        self.previous_ready = false;
        self.current_ready = false;
        self.next_ready = false;
    }

    pub fn beginRescanToLastPage(self: *PagedReader) void {
        self.rescan = .{ .last_page = .{ .scanning = 0, .last_completed = 0 } };
        self.previous_ready = false;
        self.current_ready = false;
        self.next_ready = false;
    }

    pub fn current(self: *const PagedReader) ?*const pagination.PageCache {
        if (!self.current_ready) return null;
        return &self.pages[self.current_page];
    }

    /// Data-only rendering input.  The Playdate façade decides how to draw
    /// the lines and highlighted span, but does not inspect build/rescan
    /// internals to determine whether a page is drawable.
    pub fn renderState(self: *const PagedReader) RenderState {
        return .{
            .page = self.current(),
            .selected_word_ordinal = self.selected_word_ordinal,
            .page_index = self.page_index,
            .waiting_for_page = !self.current_ready or self.pending_selection != null,
        };
    }

    pub fn builderPtr(self: *PagedReader) ?*pagination.EventPageBuilder {
        return if (self.builder) |*builder| builder else null;
    }

    /// Feed a bounded decoded prefix. The tokenizer's source offset and all
    /// incomplete XHTML/page-builder state remain private to this engine.
    pub fn feed(self: *PagedReader, input: []const u8) anyerror!xhtml.StreamExtractor.FeedResult {
        return self.extractor.?.feed(input);
    }

    pub fn finishInput(self: *PagedReader) anyerror!void {
        try self.extractor.?.finish();
    }

    /// Takes prefetched tokenizer state while rebinding its events to this
    /// reader's active page builder.
    pub fn adoptExtractor(self: *PagedReader, extractor: xhtml.StreamExtractor) void {
        self.extractor = extractor;
        self.extractor.?.sink = .{ .context = self, .emit = emitEvent };
    }

    pub fn sourceOffset(self: *const PagedReader) u32 {
        return if (self.extractor) |extractor| extractor.source_offset else 0;
    }

    /// Advance page construction after a full page. Callers supply only
    /// accounting facts; slot rotation and tagged rescan transitions stay
    /// private to the engine.
    pub fn pageCompleted(self: *PagedReader, normalized_event: u32, decoded_offset: u32) void {
        const completed_page = switch (self.rescan) {
            .page => |state| state.scanning,
            .last_page => |state| state.scanning,
            .none => if (self.current_ready) self.page_index + 1 else self.page_index,
        };
        self.recordCheckpoint(completed_page, normalized_event, decoded_offset);

        switch (self.rescan) {
            .last_page => |*state| {
                state.last_completed = self.buildingPage();
                state.scanning += 1;
                const scratch: u2 = if (self.buildingPage() == 0) 1 else 0;
                self.beginBuilding(scratch);
            },
            .page => |*state| {
                if (state.scanning == state.target) {
                    self.current_ready = true;
                    self.page_index = state.target;
                    self.stream_front_page = state.target;
                    self.navigation_state.beginRescan(state.target);
                    self.rescan = .none;
                    self.next_page = 1;
                    self.pages[self.next_page].clear();
                    self.beginBuilding(self.next_page);
                } else {
                    state.scanning += 1;
                    self.beginBuilding(0);
                }
            },
            .none => if (!self.current_ready) {
                self.current_ready = true;
                self.beginBuilding(self.next_page);
            } else {
                self.next_ready = true;
                self.build = .{ .ready = self.next_page };
            },
        }
    }

    /// Finalize EOF after the caller has asked the builder to flush its line.
    pub fn finishChapter(self: *PagedReader) Move {
        self.chapter_end = true;
        switch (self.rescan) {
            .last_page => |state| {
                if (self.pages[self.buildingPage()].line_count != 0) {
                    self.current_page = self.buildingPage();
                    self.page_index = state.scanning;
                } else if (state.scanning != 0) {
                    self.current_page = state.last_completed;
                    self.page_index = state.scanning - 1;
                } else return .at_limit;
                self.current_ready = true;
                self.navigation_state.beginRescan(self.page_index);
                self.rescan = .none;
            },
            .page => |state| {
                if (state.scanning != state.target or self.pages[0].line_count == 0) return .at_limit;
                self.current_page = 0;
                self.current_ready = true;
                self.page_index = state.target;
                self.rescan = .none;
            },
            .none => {
                if (!self.current_ready and self.pages[self.current_page].line_count != 0) self.current_ready = true else if (self.pages[self.next_page].line_count != 0) {
                    self.next_ready = true;
                    self.build = .{ .ready = self.next_page };
                }
                self.chapter_last_page = self.page_index + (if (self.next_ready) @as(u32, 1) else 0);
            },
        }
        return .moved;
    }

    pub fn isRescanning(self: *const PagedReader) bool {
        return self.rescan != .none;
    }

    pub fn nextPage(self: *PagedReader) Move {
        if (self.chapter_end) {
            const target = self.page_index + 1;
            if (self.chapter_last_page) |last| {
                if (target > last) return .needs_next_chapter;
                // EOF can be discovered while the final drawable page is
                // already complete in the next slot. It is still a normal
                // stream-forward move, not a history reconstruction.
                if (!self.next_ready) return if (self.restoreActiveHistoryPage(target)) .moved else .needs_reconstruction;
            } else return .waiting;
        }
        if (self.cache_navigation) {
            _ = self.navigation_state.forwardFromCache();
            const target = self.navigation_state.page;
            if (target <= self.stream_front_page) {
                if (!self.restoreActiveHistoryPage(target)) return .needs_reconstruction;
                if (target == self.stream_front_page) self.cache_navigation = false;
                return .moved;
            }
            self.cache_navigation = false;
        }
        if (!self.next_ready) return .waiting;
        const old_current = self.current_page;
        const old_next = self.next_page;
        self.previous_page = old_current;
        self.previous_ready = true;
        self.current_page = old_next;
        self.current_ready = true;
        self.next_ready = false;
        self.page_index += 1;
        self.stream_front_page = self.page_index;
        self.navigation_state.advancedStream();
        // The page just entered is the verified final page. There cannot be
        // another page in this chapter, so do not clear a third slot merely
        // to start a builder that will never consume input. Prefetch may be
        // using that slot for the following chapter.
        if (self.chapter_end) {
            self.build = .idle;
            return .moved;
        }
        self.next_page = self.freePage();
        self.beginBuilding(self.next_page);
        return .moved;
    }

    pub fn previousPage(self: *PagedReader) Move {
        if (self.rescan != .none) return .waiting;
        if (self.page_index == 0) return .needs_previous_chapter;
        const target = self.navigation_state.beginCachedBack() orelse return .at_limit;
        if (self.chapter_end or self.cache_navigation) return if (self.restoreActiveHistoryPage(target)) .moved else .needs_reconstruction;
        if (!self.restoreActiveHistoryPage(target)) return .needs_reconstruction;
        self.cache_navigation = true;
        self.stream_front_page = self.page_index + 1;
        return .moved;
    }

    pub fn moveSelection(self: *PagedReader, direction: i8, has_previous_chapter: bool, has_next_chapter: bool) Move {
        const page = self.current() orelse return .waiting;
        const selected = page.moveSelection(self.selected_word_ordinal, 0) orelse return .at_limit;
        if (direction > 0 and selected - page.first_word_ordinal + 1 == page.word_count) {
            if (self.chapter_end and !self.next_ready and self.chapter_last_page != null and self.page_index == self.chapter_last_page.?) {
                if (!has_next_chapter) return .at_limit;
                self.pending_selection = .{ .ordinal = 0 };
                return .needs_next_chapter;
            }
            self.pending_selection = .{ .ordinal = selected + 1 };
            return self.nextPage();
        }
        if (direction < 0 and selected == page.first_word_ordinal) {
            if (self.page_index == 0) {
                if (!has_previous_chapter) return .at_limit;
                self.pending_selection = .last_word;
                return .needs_previous_chapter;
            }
            self.pending_selection = .{ .ordinal = selected - 1 };
            return self.previousPage();
        }
        self.selected_word_ordinal = page.moveSelection(selected, direction);
        return .moved;
    }

    pub fn fulfillPendingSelection(self: *PagedReader) bool {
        const target = self.pending_selection orelse return false;
        const page = self.current() orelse return false;
        switch (target) {
            .ordinal => |ordinal| {
                if (page.wordSpan(ordinal) != null) {
                    self.selected_word_ordinal = ordinal;
                    self.pending_selection = null;
                    return true;
                }
                if (self.next_ready and (self.pages[self.next_page].wordSpan(ordinal) != null or self.pages[self.next_page].word_count == 0 or ordinal >= self.pages[self.next_page].first_word_ordinal)) {
                    _ = self.nextPage();
                    return self.fulfillPendingSelection();
                }
            },
            .last_word => if (self.chapter_end and page.word_count != 0) {
                self.selected_word_ordinal = page.first_word_ordinal + page.word_count - 1;
                self.pending_selection = null;
                return true;
            },
        }
        return false;
    }

    pub fn queueDetents(self: *PagedReader, detents: i16) void {
        const sum: i32 = @as(i32, self.detent_backlog) + detents;
        self.detent_backlog = @intCast(std.math.clamp(sum, std.math.minInt(i16), std.math.maxInt(i16)));
    }

    /// Consume a fast physical turn as semantic word movements.  Work stops
    /// at the first page/chapter boundary that needs construction, so no
    /// intermediate highlight is replayed on later frames.
    pub fn drainDetents(self: *PagedReader, has_previous_chapter: bool, has_next_chapter: bool) Move {
        while (self.detent_backlog != 0) {
            if (self.pending_selection != null) return .waiting;
            const direction: i8 = if (self.detent_backlog > 0) 1 else -1;
            switch (self.moveSelection(direction, has_previous_chapter, has_next_chapter)) {
                .moved => {
                    self.detent_backlog -= direction;
                    _ = self.fulfillPendingSelection();
                },
                .at_limit => {
                    self.detent_backlog = 0;
                    return .at_limit;
                },
                else => |outcome| return outcome,
            }
        }
        return .moved;
    }

    fn beginBuilding(self: *PagedReader, slot: u2) void {
        self.next_page = slot;
        self.builder.?.beginNextPage(&self.pages[slot]);
        self.build = .{ .building = slot };
    }

    pub fn buildingPage(self: *const PagedReader) u2 {
        return switch (self.build) {
            .building => |slot| slot,
            .ready => |slot| slot,
            .idle => self.current_page,
        };
    }

    pub fn freePage(self: *const PagedReader) u2 {
        for (0..self.pages.len) |index| {
            if (index != self.current_page and (!self.previous_ready or index != self.previous_page)) return @intCast(index);
        }
        unreachable;
    }

    fn restoreActiveHistoryPage(self: *PagedReader, target: u32) bool {
        if (!self.previous_ready or !navigation.canRestoreSharedPage(self.page_index, target, self.cache_navigation)) return false;
        const old_current = self.current_page;
        self.current_page = self.previous_page;
        self.previous_page = old_current;
        self.page_index = target;
        self.navigation_state.page = target;
        self.current_ready = true;
        self.next_ready = false;
        return true;
    }

    /// Checkpoint metadata is deliberately accounting-only; callers cannot
    /// obtain a compressed stream position from it.
    pub fn recordCheckpoint(self: *PagedReader, page: u32, normalized_event: u32, decoded_offset: u32) void {
        _ = self.checkpoints.admit(self.chapter_index, page, normalized_event, decoded_offset, @sizeOf(cache_policy.Entry));
    }

    fn emitEvent(context: *anyopaque, event: xhtml.Event) anyerror!void {
        const self: *PagedReader = @ptrCast(@alignCast(context));
        try self.builderPtr().?.consume(event);
    }
};

fn makePage(first: u32, count: u32) pagination.PageCache {
    var result = pagination.PageCache{};
    result.line_count = 1;
    result.first_word_ordinal = first;
    result.word_count = count;
    result.line_word_counts[0] = @intCast(count);
    for (0..count) |index| {
        result.lines[0][index * 2] = 'w';
        if (index + 1 < count) result.lines[0][index * 2 + 1] = ' ';
    }
    result.lengths[0] = @intCast(count * 2 - 1);
    return result;
}

test "paged reader rotates exactly three slots and restores the retained previous page" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.pages[0] = makePage(0, 3);
    reader.pageCompleted(0, 0);
    reader.pages[reader.next_page] = makePage(3, 3);
    reader.pageCompleted(0, 0);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    try std.testing.expect(reader.previous_ready);
    try std.testing.expectEqual(@as(usize, PagedReader.page_capacity), reader.pages.len);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    try std.testing.expectEqual(@as(u32, 0), reader.page_index);
}

test "forward after a cached back restores the stream-front page without rebuilding" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.pages[0] = makePage(0, 1);
    reader.pageCompleted(0, 0);
    reader.pages[reader.next_page] = makePage(1, 1);
    reader.pageCompleted(0, 0);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    try std.testing.expect(reader.cache_navigation);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    try std.testing.expectEqual(@as(u32, 1), reader.page_index);
    try std.testing.expect(!reader.cache_navigation);
}

test "EOF advances from the second-to-last page into a prepared final page" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.pages[0] = makePage(0, 1);
    reader.pages[1] = makePage(1, 1);
    reader.pages[2] = makePage(99, 1);
    reader.current_ready = true;
    reader.next_ready = true;
    reader.page_index = 3;
    reader.chapter_end = true;
    reader.chapter_last_page = 4;
    reader.navigation_state.page = 3;

    try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    try std.testing.expectEqual(@as(u32, 4), reader.page_index);
    try std.testing.expectEqual(@as(u2, 1), reader.current_page);
    try std.testing.expectEqual(@as(u8, 1), reader.pages[2].line_count);
    try std.testing.expectEqual(PagedReader.BuildState.idle, reader.build);
    try std.testing.expectEqual(PagedReader.Move.needs_next_chapter, reader.nextPage());
}

test "pending selection waits for a page then follows it without a word queue" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.current_ready = true;
    reader.pages[0] = makePage(10, 2);
    reader.current_page = 0;
    reader.next_page = 1;
    reader.selected_word_ordinal = 11;
    try std.testing.expectEqual(PagedReader.Move.waiting, reader.moveSelection(1, false, false));
    try std.testing.expect(reader.pending_selection != null);
    reader.pages[1] = makePage(12, 2);
    reader.next_ready = true;
    try std.testing.expect(reader.fulfillPendingSelection());
    try std.testing.expectEqual(@as(?u32, 12), reader.selected_word_ordinal);
}

test "chapter-boundary selection reports semantic transition requests" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.current_ready = true;
    reader.chapter_end = true;
    reader.chapter_last_page = 0;
    reader.pages[0] = makePage(0, 1);
    try std.testing.expectEqual(PagedReader.Move.needs_next_chapter, reader.moveSelection(1, false, true));
    try std.testing.expectEqual(PagedReader.Move.at_limit, reader.moveSelection(1, false, false));
    reader.pending_selection = null;
    try std.testing.expectEqual(PagedReader.Move.at_limit, reader.moveSelection(-1, false, false));
    try std.testing.expectEqual(PagedReader.Move.needs_previous_chapter, reader.moveSelection(-1, true, false));
}

test "a cache miss requests reconstruction rather than a compressed seek" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.current_ready = true;
    reader.page_index = 4;
    reader.navigation_state.opened(4);
    try std.testing.expectEqual(PagedReader.Move.needs_reconstruction, reader.previousPage());
    reader.beginRescan(3);
    try std.testing.expectEqual(@as(u32, 3), reader.rescan.page.target);
    try std.testing.expectEqual(@as(u32, 0), reader.rescan.page.scanning);
}

test "fast detents coalesce to the final word without retaining a backlog" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.current_ready = true;
    reader.pages[0] = makePage(0, 5);
    reader.queueDetents(4);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.drainDetents(false, false));
    try std.testing.expectEqual(@as(?u32, 4), reader.selected_word_ordinal);
    try std.testing.expectEqual(@as(i16, 0), reader.detent_backlog);
}

test "render state exposes only drawable page data and semantic selection" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    try std.testing.expect(reader.renderState().page == null);
    reader.current_ready = true;
    reader.pages[0] = makePage(7, 1);
    reader.selected_word_ordinal = 7;
    const render = reader.renderState();
    try std.testing.expect(render.page != null);
    try std.testing.expectEqual(@as(?u32, 7), render.selected_word_ordinal);
    try std.testing.expect(!render.waiting_for_page);
}

test "bounded decoded input stays in the engine tokenizer and page builder" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    try std.testing.expectEqual(xhtml.StreamExtractor.FeedResult{ .consumed = 10 }, try reader.feed("<p>one</p>"));
    try reader.finishInput();
    try std.testing.expectEqual(@as(u32, 10), reader.sourceOffset());
    try std.testing.expectEqualStrings("one", reader.pages[0].line(0));
}

test "checkpoint storage remains capped at the three-page metadata budget" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    for (0..4) |index| reader.recordCheckpoint(@intCast(index), @intCast(index), 0);
    try std.testing.expect(reader.checkpoints.findAndTouch(0, 0) == null);
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(cache_policy.Entry)), reader.checkpoints.bytes_used);
}

test "target rescan rebuilds from page zero and promotes only the requested page" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(2, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.beginRescan(1);
    reader.pages[reader.buildingPage()] = makePage(0, 1);
    reader.pageCompleted(10, 100);
    try std.testing.expect(reader.isRescanning());
    reader.pages[reader.buildingPage()] = makePage(1, 1);
    reader.pageCompleted(20, 200);
    try std.testing.expect(!reader.isRescanning());
    try std.testing.expect(reader.current_ready);
    try std.testing.expectEqual(@as(u32, 1), reader.page_index);
    try std.testing.expect(reader.checkpoints.findAndTouch(2, 0) != null);
    try std.testing.expect(reader.checkpoints.findAndTouch(2, 1) != null);
}

test "last-page rescan retains only the final completed cache slot" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(1, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.beginRescanToLastPage();
    reader.pages[reader.buildingPage()] = makePage(0, 1);
    reader.pageCompleted(1, 1);
    reader.pages[reader.buildingPage()] = makePage(1, 1);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.finishChapter());
    try std.testing.expect(!reader.isRescanning());
    try std.testing.expectEqual(@as(u32, 1), reader.page_index);
    try std.testing.expect(reader.current_ready);
}
