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
    pub const page_capacity: usize = 10;
    pub const SlotIndex = u8;
    pub const page_pool_reserved_bytes = page_capacity * @sizeOf(pagination.PageCache);
    pub const page_pool_byte_budget = 44 * 1024;
    pub const SelectionTarget = reader_transitions.PagedSelectionTarget;

    pub const SlotRole = enum { free, displayed, stream_front, history, building, ready_ahead, prefetch };
    pub const SlotState = struct {
        role: SlotRole = .free,
        chapter: u8 = 0,
        page: u32 = 0,
    };
    pub const PrefetchPage = struct {
        slot: SlotIndex,
        page: *pagination.PageCache,
    };

    comptime {
        std.debug.assert(page_capacity == 10);
        std.debug.assert(page_capacity <= @as(usize, std.math.maxInt(SlotIndex)) + 1);
        std.debug.assert(page_pool_reserved_bytes <= page_pool_byte_budget);
    }

    pub const BuildState = union(enum) {
        idle,
        building: SlotIndex,
        ready: SlotIndex,
    };

    /// A rescan always restarts decoding at the chapter beginning.  This is a
    /// semantic target, never a compressed-data offset.
    pub const Rescan = union(enum) {
        none,
        page: struct { target: u32, scanning: u32 },
        last_page: struct { scanning: u32, last_completed: SlotIndex },
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
    slots: [page_capacity]SlotState = [_]SlotState{.{}} ** page_capacity,
    prefetch_page: ?SlotIndex = null,
    current_page: SlotIndex = 0,
    next_page: SlotIndex = 1,
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
    reconstructing: bool = false,
    navigation_state: navigation.State = .{},
    checkpoints: cache_policy.Policy,
    prefetch: prefetch_session.Session = .{},

    /// Initializes directly in caller-owned storage.  Page caches are large,
    /// so constructing this by value would put a transient cache pool on the
    /// Playdate stack.
    pub fn initInPlace(self: *PagedReader, checkpoint_byte_budget: usize) void {
        self.* = undefined;
        for (&self.pages) |*page| page.clear();
        self.slots = [_]SlotState{.{}} ** page_capacity;
        self.prefetch_page = null;
        self.current_page = 0;
        self.next_page = 1;
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
        self.reconstructing = false;
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
        self.current_page = 0;
        self.next_page = 1;
        self.current_ready = false;
        self.next_ready = false;
        self.selected_word_ordinal = null;
        self.pending_selection = null;
        self.detent_backlog = 0;
        self.chapter_end = false;
        self.chapter_last_page = null;
        self.rescan = .none;
        self.reconstructing = false;
        self.navigation_state.opened(0);
        for (&self.pages) |*page| page.clear();
        self.slots = [_]SlotState{.{}} ** page_capacity;
        self.prefetch_page = null;
        self.setSlot(self.current_page, .building, chapter, 0);
        self.builder = pagination.EventPageBuilder.init(&self.pages[self.current_page], width, measure);
        self.extractor = xhtml.StreamExtractor.init(.{ .context = self, .emit = emitEvent });
        self.build = .{ .building = self.current_page };
    }

    pub fn beginRescan(self: *PagedReader, target: u32) void {
        self.reconstructing = true;
        self.navigation_state.beginRescan(target);
        self.rescan = .{ .page = .{ .target = target, .scanning = 0 } };
        self.current_ready = false;
        self.next_ready = false;
    }

    pub fn beginRescanToLastPage(self: *PagedReader) void {
        self.reconstructing = true;
        self.rescan = .{ .last_page = .{ .scanning = 0, .last_completed = 0 } };
        self.current_ready = false;
        self.next_ready = false;
    }

    pub fn beginWordRescan(self: *PagedReader, target: u32) void {
        self.reconstructing = true;
        self.pending_selection = .{ .ordinal = target };
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
                self.setSlot(state.last_completed, .history, self.chapter_index, state.scanning);
                state.scanning += 1;
                self.beginBuilding(self.freePage(), state.scanning);
            },
            .page => |*state| {
                if (state.scanning == state.target) {
                    self.setSlot(self.buildingPage(), .displayed, self.chapter_index, state.target);
                    self.current_ready = true;
                    self.current_page = self.buildingPage();
                    self.page_index = state.target;
                    self.navigation_state.beginRescan(state.target);
                    self.rescan = .none;
                    self.reconstructing = false;
                    self.beginBuilding(self.freePage(), state.target + 1);
                } else {
                    self.setSlot(self.buildingPage(), .history, self.chapter_index, state.scanning);
                    state.scanning += 1;
                    self.beginBuilding(self.freePage(), state.scanning);
                }
            },
            .none => if (!self.current_ready) {
                self.setSlot(self.current_page, .displayed, self.chapter_index, self.page_index);
                self.current_ready = true;
                self.beginBuilding(self.next_page, self.page_index + 1);
            } else {
                self.setSlot(self.next_page, .ready_ahead, self.chapter_index, self.page_index + 1);
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
                    self.releaseSlot(self.buildingPage());
                    self.current_page = state.last_completed;
                    self.page_index = state.scanning - 1;
                } else return .at_limit;
                self.setSlot(self.current_page, .displayed, self.chapter_index, self.page_index);
                self.current_ready = true;
                self.navigation_state.beginRescan(self.page_index);
                self.rescan = .none;
                self.reconstructing = false;
                self.chapter_last_page = self.page_index;
                self.build = .idle;
                self.trimHistory(8);
            },
            .page => |state| {
                const completed = self.buildingPage();
                if (state.scanning != state.target or self.pages[completed].line_count == 0) return .at_limit;
                self.current_page = completed;
                self.setSlot(self.current_page, .displayed, self.chapter_index, state.target);
                self.current_ready = true;
                self.page_index = state.target;
                self.navigation_state.beginRescan(state.target);
                self.rescan = .none;
                self.reconstructing = false;
                self.chapter_last_page = state.target;
                self.build = .idle;
                self.trimHistory(8);
            },
            .none => {
                if (!self.current_ready and self.pages[self.current_page].line_count != 0) {
                    self.current_ready = true;
                    self.setSlot(self.current_page, .displayed, self.chapter_index, self.page_index);
                    self.build = .idle;
                } else if (self.pages[self.next_page].line_count != 0) {
                    self.next_ready = true;
                    self.setSlot(self.next_page, .ready_ahead, self.chapter_index, self.page_index + 1);
                    self.build = .{ .ready = self.next_page };
                } else if (self.slots[self.next_page].role == .building) {
                    self.releaseSlot(self.next_page);
                    self.build = .idle;
                }
                self.chapter_last_page = self.page_index + (if (self.next_ready) @as(u32, 1) else 0);
            },
        }
        return .moved;
    }

    pub fn isRescanning(self: *const PagedReader) bool {
        return self.rescan != .none;
    }

    pub fn isReconstructing(self: *const PagedReader) bool {
        return self.reconstructing;
    }

    pub fn nextPage(self: *PagedReader) Move {
        if (self.navigation_state.viewing_cached_history) {
            const target = self.navigation_state.forwardFromCache() orelse return .waiting;
            return if (self.showCachedPage(target)) .moved else .needs_reconstruction;
        }
        if (self.chapter_end) {
            const target = self.page_index + 1;
            if (self.chapter_last_page) |last| {
                if (target > last) return .needs_next_chapter;
                // EOF can be discovered while the final drawable page is
                // already complete in the next slot. It is still a normal
                // stream-forward move, not a history reconstruction.
                if (!self.next_ready) return if (self.showCachedPage(target)) .moved else .needs_reconstruction;
            } else return .waiting;
        }
        if (!self.next_ready) return .waiting;
        const old_current = self.current_page;
        const old_next = self.next_page;
        self.setSlot(old_current, .history, self.chapter_index, self.page_index);
        self.current_page = old_next;
        self.setSlot(old_next, .displayed, self.chapter_index, self.page_index + 1);
        self.current_ready = true;
        self.next_ready = false;
        self.page_index += 1;
        self.navigation_state.advancedStream();
        // The page just entered is the verified final page. There cannot be
        // another page in this chapter, so do not clear a third slot merely
        // to start a builder that will never consume input. Prefetch may be
        // using that slot for the following chapter.
        if (self.chapter_end) {
            self.build = .idle;
            self.trimHistory(8);
            return .moved;
        }
        self.beginBuilding(self.freePage(), self.page_index + 1);
        return .moved;
    }

    pub fn previousPage(self: *PagedReader) Move {
        if (self.rescan != .none) return .waiting;
        if (self.page_index == 0) return .needs_previous_chapter;
        const target = self.navigation_state.beginCachedBack() orelse return .at_limit;
        return if (self.showCachedPage(target)) .moved else .needs_reconstruction;
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
                    self.reconstructing = false;
                    return true;
                }
                if ((self.navigation_state.viewing_cached_history and self.findCachedPage(self.page_index + 1) != null) or
                    (self.next_ready and (self.pages[self.next_page].wordSpan(ordinal) != null or self.pages[self.next_page].word_count == 0 or ordinal >= self.pages[self.next_page].first_word_ordinal)))
                {
                    _ = self.nextPage();
                    return self.fulfillPendingSelection();
                }
            },
            .last_word => if (self.chapter_end and page.word_count != 0) {
                self.selected_word_ordinal = page.first_word_ordinal + page.word_count - 1;
                self.pending_selection = null;
                self.reconstructing = false;
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

    fn beginBuilding(self: *PagedReader, slot: SlotIndex, page: u32) void {
        std.debug.assert(self.slots[slot].role == .free or self.slots[slot].role == .building or self.slots[slot].role == .history);
        self.next_page = slot;
        self.setSlot(slot, .building, self.chapter_index, page);
        self.builder.?.beginNextPage(&self.pages[slot]);
        self.build = .{ .building = slot };
    }

    pub fn buildingPage(self: *const PagedReader) SlotIndex {
        return switch (self.build) {
            .building => |slot| slot,
            .ready => |slot| slot,
            .idle => self.current_page,
        };
    }

    pub fn freePage(self: *PagedReader) SlotIndex {
        return self.allocateSlot() orelse unreachable;
    }

    fn showCachedPage(self: *PagedReader, target: u32) bool {
        const target_slot = self.findCachedPage(target) orelse return false;
        const old_current = self.current_page;
        const old_page = self.page_index;
        self.current_page = target_slot;
        self.setSlot(self.current_page, .displayed, self.chapter_index, target);
        self.setSlot(old_current, if (old_page == self.navigation_state.stream_front) .stream_front else .history, self.chapter_index, old_page);
        self.page_index = target;
        self.navigation_state.page = target;
        self.current_ready = true;
        return true;
    }

    fn findCachedPage(self: *const PagedReader, page: u32) ?SlotIndex {
        for (self.slots, 0..) |state, index| {
            if (state.chapter != self.chapter_index or state.page != page) continue;
            switch (state.role) {
                .displayed, .stream_front, .history => return @intCast(index),
                .free, .building, .ready_ahead, .prefetch => {},
            }
        }
        return null;
    }

    pub fn reservePrefetchPage(self: *PagedReader, chapter: u8) ?PrefetchPage {
        if (self.prefetch_page != null) return null;
        const slot = self.allocateSlot() orelse return null;
        self.setSlot(slot, .prefetch, chapter, 0);
        self.pages[slot].clear();
        self.prefetch_page = slot;
        return .{ .slot = slot, .page = &self.pages[slot] };
    }

    pub fn releasePrefetchPage(self: *PagedReader) void {
        const slot = self.prefetch_page orelse return;
        if (self.slots[slot].role == .prefetch) self.releaseSlot(slot);
        self.prefetch_page = null;
    }

    pub fn activatePrefetchedPage(self: *PagedReader, slot: SlotIndex, chapter: u8, ended: bool) void {
        std.debug.assert(self.prefetch_page == slot);
        std.debug.assert(self.slots[slot].role == .prefetch);
        for (&self.slots, 0..) |*state, index| {
            if (index != slot) state.* = .{};
        }
        self.prefetch_page = null;
        self.chapter_index = chapter;
        self.page_index = 0;
        self.current_page = slot;
        self.setSlot(slot, .displayed, chapter, 0);
        self.current_ready = true;
        self.selected_word_ordinal = null;
        self.next_ready = false;
        self.chapter_end = ended;
        self.chapter_last_page = if (ended) 0 else null;
        self.navigation_state.opened(0);
        if (ended) {
            self.build = .idle;
        } else {
            self.next_page = self.freePage();
            self.beginBuilding(self.next_page, 1);
        }
    }

    fn allocateSlot(self: *PagedReader) ?SlotIndex {
        for (self.slots, 0..) |state, index| {
            if (state.role == .free) return @intCast(index);
        }
        var oldest: ?SlotIndex = null;
        for (self.slots, 0..) |state, index| {
            if (state.role != .history) continue;
            if (oldest == null or state.page < self.slots[oldest.?].page) oldest = @intCast(index);
        }
        if (oldest) |slot| {
            self.releaseSlot(slot);
        }
        return oldest;
    }

    fn trimHistory(self: *PagedReader, maximum: usize) void {
        while (true) {
            var count: usize = 0;
            var oldest: ?SlotIndex = null;
            for (self.slots, 0..) |state, index| {
                if (state.role != .history) continue;
                count += 1;
                if (oldest == null or state.page < self.slots[oldest.?].page) oldest = @intCast(index);
            }
            if (count <= maximum) return;
            self.releaseSlot(oldest.?);
        }
    }

    fn setSlot(self: *PagedReader, slot: SlotIndex, role: SlotRole, chapter: u8, page: u32) void {
        self.slots[slot] = .{ .role = role, .chapter = chapter, .page = page };
    }

    fn releaseSlot(self: *PagedReader, slot: SlotIndex) void {
        self.slots[slot] = .{};
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

test "paged reader assigns explicit roles while preserving cached navigation" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    try std.testing.expectEqual(@as(usize, 10), PagedReader.page_capacity);
    try std.testing.expectEqual(PagedReader.SlotRole.building, reader.slots[reader.current_page].role);
    reader.pages[0] = makePage(0, 3);
    reader.pageCompleted(0, 0);
    try std.testing.expectEqual(PagedReader.SlotRole.displayed, reader.slots[reader.current_page].role);
    try std.testing.expectEqual(PagedReader.SlotRole.building, reader.slots[reader.next_page].role);
    reader.pages[reader.next_page] = makePage(3, 3);
    reader.pageCompleted(0, 0);
    try std.testing.expectEqual(PagedReader.SlotRole.ready_ahead, reader.slots[reader.next_page].role);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    try std.testing.expectEqual(@as(usize, PagedReader.page_capacity), reader.pages.len);
    try std.testing.expectEqual(PagedReader.SlotRole.history, reader.slots[reader.findCachedPage(0).?].role);
    try std.testing.expectEqual(PagedReader.SlotRole.displayed, reader.slots[reader.current_page].role);
    try std.testing.expectEqual(PagedReader.SlotRole.building, reader.slots[reader.next_page].role);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    try std.testing.expectEqual(@as(u32, 0), reader.page_index);
    try std.testing.expectEqual(PagedReader.SlotRole.displayed, reader.slots[reader.current_page].role);
    try std.testing.expectEqual(PagedReader.SlotRole.stream_front, reader.slots[reader.findCachedPage(1).?].role);
}

test "eight cached pages navigate backward and forward around a parked builder" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.pages[0] = makePage(0, 1);
    reader.pageCompleted(0, 0);
    for (1..10) |page| {
        reader.pages[reader.next_page] = makePage(@intCast(page), 1);
        reader.pageCompleted(0, 0);
        try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    }
    const parked_builder = reader.buildingPage();
    for (0..8) |_| try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    try std.testing.expectEqual(@as(u32, 1), reader.page_index);
    try std.testing.expectEqual(PagedReader.SlotRole.building, reader.slots[parked_builder].role);
    reader.selected_word_ordinal = 1;
    try std.testing.expectEqual(PagedReader.Move.moved, reader.moveSelection(1, false, false));
    try std.testing.expect(reader.fulfillPendingSelection());
    try std.testing.expectEqual(@as(u32, 2), reader.page_index);
    try std.testing.expectEqual(@as(?u32, 2), reader.selected_word_ordinal);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    for (0..8) |_| try std.testing.expectEqual(PagedReader.Move.moved, reader.nextPage());
    try std.testing.expectEqual(@as(u32, 9), reader.page_index);
    try std.testing.expect(!reader.navigation_state.viewing_cached_history);
    try std.testing.expectEqual(parked_builder, reader.buildingPage());
    for (0..8) |_| try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    try std.testing.expectEqual(PagedReader.Move.needs_reconstruction, reader.previousPage());
    try std.testing.expectEqual(@as(u32, 0), reader.navigation_state.page);
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
    try std.testing.expectEqual(@as(PagedReader.SlotIndex, 1), reader.current_page);
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
    try std.testing.expect(!reader.isReconstructing());
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
    try std.testing.expect(reader.isReconstructing());
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

test "checkpoint storage remains capped at its three-entry metadata budget" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    for (0..4) |index| reader.recordCheckpoint(@intCast(index), @intCast(index), 0);
    try std.testing.expect(reader.checkpoints.findAndTouch(0, 0) == null);
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(cache_policy.Entry)), reader.checkpoints.bytes_used);
}

test "target rescan retains the eight pages preceding its requested page" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(2, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.beginRescan(9);
    for (0..10) |page| {
        reader.pages[reader.buildingPage()] = makePage(@intCast(page), 1);
        reader.pageCompleted(@intCast(page * 10), @intCast(page * 100));
    }
    try std.testing.expect(!reader.isRescanning());
    try std.testing.expect(reader.current_ready);
    try std.testing.expectEqual(@as(u32, 9), reader.page_index);
    try std.testing.expect(reader.checkpoints.findAndTouch(2, 0) == null);
    try std.testing.expect(reader.checkpoints.findAndTouch(2, 9) != null);
    for (0..8) |_| try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    try std.testing.expectEqual(@as(u32, 1), reader.page_index);
    try std.testing.expectEqual(PagedReader.Move.needs_reconstruction, reader.previousPage());
}

test "last-page rescan retains its preceding page window" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(1, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.beginRescanToLastPage();
    for (0..10) |page| {
        reader.pages[reader.buildingPage()] = makePage(@intCast(page), 1);
        reader.pageCompleted(@intCast(page), @intCast(page));
    }
    reader.pages[reader.buildingPage()] = makePage(10, 1);
    try std.testing.expectEqual(PagedReader.Move.moved, reader.finishChapter());
    try std.testing.expect(!reader.isRescanning());
    try std.testing.expectEqual(@as(u32, 10), reader.page_index);
    try std.testing.expect(reader.current_ready);
    for (0..8) |_| try std.testing.expectEqual(PagedReader.Move.moved, reader.previousPage());
    try std.testing.expectEqual(@as(u32, 2), reader.page_index);
    try std.testing.expectEqual(PagedReader.Move.needs_reconstruction, reader.previousPage());
}
