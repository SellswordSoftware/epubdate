const std = @import("std");
const cache_policy = @import("content/cache_policy.zig");
const navigation = @import("content/navigation.zig");
const pagination = @import("content/pagination.zig");
const reader_transitions = @import("reader_transitions.zig");
const xhtml = @import("content/xhtml.zig");
const prefetch_session = @import("prefetch_session.zig");
const scroll_geometry = @import("scroll_geometry.zig");

/// Platform-free Paged-reader state. It owns page caches, semantic navigation,
/// and page construction; platform code supplies bounded stream work.
pub const PagedReader = struct {
    pub const page_capacity: usize = 10;
    pub const max_scroll_detents_per_update: u8 = 8;
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
        reconstructing: bool,
    };

    pub const ScrollMove = enum { moved, waiting, at_start, at_end, needs_reconstruction };

    const ScrollRescan = struct {
        target: u32,
        scanning: u32,
        resume_page: u32,
    };

    /// A Scroll tile borrows an existing page cache for one render frame. The
    /// placeholder variants carry their viewport origin only; they never
    /// acquire text storage or semantic word metadata.
    pub const ScrollTile = union(enum) {
        page: struct {
            cache: *const pagination.PageCache,
            origin_y: i16,
        },
        loading_before: i16,
        loading_after: i16,
        unavailable_before: i16,
        unavailable_after: i16,
    };

    pub const ScrollRenderState = struct {
        tiles: [3]ScrollTile = [_]ScrollTile{.{ .loading_after = 0 }} ** 3,
        tile_count: u2 = 0,
        at_chapter_start: bool = false,
        at_chapter_end: bool = false,
    };

    pages: [page_capacity]pagination.PageCache = [_]pagination.PageCache{.{}} ** page_capacity,
    slots: [page_capacity]SlotState = [_]SlotState{.{}} ** page_capacity,
    /// Pins are bounded render-frame metadata, not a new cache tier. Only
    /// history slots are evictable, and a window-owned history page stays put
    /// until the next window replaces these pins.
    scroll_pins: [page_capacity]bool = [_]bool{false} ** page_capacity,
    scroll_position: scroll_geometry.Position = .{},
    scroll_rescan: ?ScrollRescan = null,
    scroll_previous_unavailable: bool = false,
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
        self.scroll_pins = [_]bool{false} ** page_capacity;
        self.scroll_position = .{};
        self.scroll_rescan = null;
        self.scroll_previous_unavailable = false;
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

    /// Clears all presentation and reconstruction state at a book boundary
    /// while preserving the configured checkpoint budget.
    pub fn resetForBook(self: *PagedReader) void {
        const checkpoint_byte_budget = self.checkpoints.byte_budget;
        self.initInPlace(checkpoint_byte_budget);
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
        self.scroll_pins = [_]bool{false} ** page_capacity;
        self.scroll_position = .{};
        self.scroll_rescan = null;
        self.scroll_previous_unavailable = false;
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

    /// Borrows an already-cached page for a short renderer transition. It
    /// never changes cache roles or pins storage.
    pub fn cachedPage(self: *const PagedReader, page: u32) ?*const pagination.PageCache {
        const slot = self.findCachedPage(page) orelse return null;
        return &self.pages[slot];
    }

    /// Data-only rendering input.  The Playdate façade decides how to draw
    /// the lines and highlighted span, but does not inspect build/rescan
    /// internals to determine whether a page is drawable.
    pub fn renderState(self: *const PagedReader) RenderState {
        return .{
            // Reconstruction advances through real pages internally, but none
            // is the requested destination until the semantic target resolves.
            .page = if (self.reconstructing) null else self.current(),
            .selected_word_ordinal = self.selected_word_ordinal,
            .page_index = self.page_index,
            .waiting_for_page = !self.current_ready or self.pending_selection != null,
            .reconstructing = self.reconstructing,
        };
    }

    /// Returns a borrowed, fixed-size view of cached pages surrounding a
    /// Scroll position. This is read-only with respect to text and streaming;
    /// its only mutation is the replacement of bounded eviction pins.
    pub fn scrollRenderState(self: *PagedReader, position: scroll_geometry.Position, geometry: scroll_geometry.Geometry) ScrollRenderState {
        self.clearScrollPins();
        var result = ScrollRenderState{};
        const top_slot = self.findDrawablePage(position.top_page) orelse {
            self.appendScrollTile(&result, .{ .loading_after = @intCast(geometry.viewport.top_y) });
            return result;
        };

        const waiting_before: u16 = if (position.waiting_px < 0) @intCast(-@as(i32, position.waiting_px)) else 0;
        const origin = scrollTopOrigin(geometry.viewport.top_y, position.offset_px, waiting_before);
        if (waiting_before != 0) self.appendScrollTile(&result, if (self.scroll_previous_unavailable)
            .{ .unavailable_before = scrollTopOrigin(geometry.viewport.top_y, position.offset_px, 0) }
        else
            .{ .loading_before = scrollTopOrigin(geometry.viewport.top_y, position.offset_px, 0) });
        self.appendScrollPage(&result, top_slot, origin);

        if (position.waiting_px > 0) {
            self.appendScrollTile(&result, .{ .loading_after = advanceScrollOrigin(origin, pageExtent(geometry, &self.pages[top_slot])) });
            return result;
        }

        var page = position.top_page;
        var page_slot = top_slot;
        var page_origin = origin;
        while (result.tile_count < 3) {
            const bottom = advanceScrollOrigin(page_origin, pageExtent(geometry, &self.pages[page_slot]));
            if (bottom >= @as(i16, @intCast(geometry.viewport.bottom_y))) break;
            if (self.chapter_end and self.chapter_last_page != null and page >= self.chapter_last_page.?) break;
            page += 1;
            const next_slot = self.findDrawablePage(page) orelse {
                self.appendScrollTile(&result, .{ .loading_after = bottom });
                break;
            };
            self.appendScrollPage(&result, next_slot, bottom);
            page_slot = next_slot;
            page_origin = bottom;
        }
        result.at_chapter_start = position.top_page == 0 and position.offset_px == 0 and position.waiting_px >= 0;
        result.at_chapter_end = self.chapter_end and self.chapter_last_page != null and page >= self.chapter_last_page.?;
        return result;
    }

    /// Scroll starts from the current Paged page when no semantic cursor is
    /// available (for example, while the first page is still being built).
    pub fn beginScroll(self: *PagedReader) void {
        self.scroll_position = .{ .top_page = self.page_index };
    }

    /// Aligns the source line containing `ordinal` to the text viewport top.
    /// It borrows an already-cached page and never starts a decode operation.
    pub fn beginScrollAtWord(self: *PagedReader, ordinal: u32, geometry: scroll_geometry.Geometry) void {
        for (self.slots, 0..) |state, index| {
            if (state.chapter != self.chapter_index or ordinal < self.pages[index].first_word_ordinal or ordinal >= self.pages[index].first_word_ordinal + self.pages[index].word_count) continue;
            switch (state.role) {
                .displayed, .stream_front, .history => {
                    var line: u8 = 0;
                    var words = self.pages[index].first_word_ordinal;
                    while (line < self.pages[index].line_count) : (line += 1) {
                        const count = self.pages[index].line_word_counts[line];
                        if (ordinal < words + count) break;
                        words += count;
                    }
                    self.scroll_position = .{ .top_page = state.page, .offset_px = @as(u16, line) * geometry.line_advance };
                    if (self.chapter_end and self.chapter_last_page != null and state.page == self.chapter_last_page.?) self.clampScrollAtChapterEnd(geometry);
                    return;
                },
                .free, .building, .ready_ahead, .prefetch => {},
            }
        }
        self.beginScroll();
    }

    /// The first source word on or below the viewport's top edge is the
    /// semantic Scroll cursor used for resume, progress, and mode transfer.
    pub fn scrollFirstVisibleWord(self: *const PagedReader, geometry: scroll_geometry.Geometry) ?u32 {
        const slot = self.findDrawablePage(self.scroll_position.top_page) orelse return null;
        const page = &self.pages[slot];
        var line: u8 = @intCast(@min(@as(u16, page.line_count), self.scroll_position.offset_px / geometry.line_advance));
        var ordinal = page.first_word_ordinal;
        for (0..line) |index| ordinal += page.line_word_counts[index];
        while (line < page.line_count) : (line += 1) {
            if (page.line_word_counts[line] != 0) return ordinal;
            ordinal += page.line_word_counts[line];
        }
        return null;
    }

    /// Drops motion accumulated for a now-inactive presentation without
    /// changing the normalized visible location.
    pub fn clearScrollTransient(self: *PagedReader) void {
        self.scroll_position.waiting_px = 0;
        self.scroll_position.pending_detents = 0;
    }

    pub fn scrollViewport(self: *PagedReader, direction: scroll_geometry.Direction, geometry: scroll_geometry.Geometry) ScrollMove {
        return switch (direction) {
            .forward => self.scrollForwardPixels(geometry, geometry.viewport.height()),
            .backward => self.scrollBackwardPixels(geometry, geometry.viewport.height()),
        };
    }

    /// Applies an integral Scroll displacement without creating a second
    /// coordinate system. The caller turns device crank input into pixels;
    /// this engine still owns page-relative normalization and cache waits.
    pub fn scrollPixels(self: *PagedReader, direction: scroll_geometry.Direction, geometry: scroll_geometry.Geometry, pixels: u16) ScrollMove {
        if (pixels == 0) return .moved;
        return switch (direction) {
            .forward => self.scrollForwardRequested(geometry, pixels),
            .backward => self.scrollBackwardRequested(geometry, pixels),
        };
    }

    /// Makes the Page presentation show the cached page containing Scroll's
    /// first visible source word. It has no streaming or allocation side
    /// effects.
    pub fn showScrollTopPage(self: *PagedReader) bool {
        return self.showCachedPage(self.scroll_position.top_page);
    }

    pub fn scrollPosition(self: *const PagedReader) scroll_geometry.Position {
        return self.scroll_position;
    }

    pub fn queueScrollDetents(self: *PagedReader, detents: i16) void {
        self.scroll_position.queueDetents(detents);
    }

    pub fn scrollPreviousRescanTarget(self: *const PagedReader) ?u32 {
        if (self.scroll_rescan != null or self.scroll_previous_unavailable or self.scroll_position.top_page == 0) return null;
        const target = self.scroll_position.top_page - 1;
        return if (self.findDrawablePage(target) == null) target else null;
    }

    /// Resets only the decode-side builder for a Scroll reconstruction. The
    /// current viewport slots remain intact and pinned by the render window.
    pub fn beginScrollRescan(self: *PagedReader, width: usize, measure: pagination.Measure, target: u32) bool {
        if (self.scroll_rescan != null or target >= self.scroll_position.top_page) return false;
        if (self.findDrawablePage(target) != null) return false;
        switch (self.build) {
            .building => |slot| self.releaseSlot(slot),
            .ready => |slot| if (!self.scroll_pins[slot]) self.releaseSlot(slot),
            .idle => {},
        }
        if (self.next_ready and !self.scroll_pins[self.next_page]) self.releaseSlot(self.next_page);
        const slot = self.allocateSlot() orelse return false;
        self.pages[slot].clear();
        self.setSlot(slot, .building, self.chapter_index, 0);
        self.builder = pagination.EventPageBuilder.init(&self.pages[slot], width, measure);
        self.extractor = xhtml.StreamExtractor.init(.{ .context = self, .emit = emitEvent });
        self.build = .{ .building = slot };
        self.next_ready = false;
        self.reconstructing = true;
        self.scroll_rescan = .{ .target = target, .scanning = 0, .resume_page = self.page_index };
        self.scroll_previous_unavailable = false;
        return true;
    }

    pub fn markScrollPreviousUnavailable(self: *PagedReader) void {
        self.scroll_rescan = null;
        self.reconstructing = false;
        self.scroll_previous_unavailable = true;
        self.scroll_position.pending_detents = 0;
    }

    pub fn isScrollRescanning(self: *const PagedReader) bool {
        return self.scroll_rescan != null;
    }

    /// Drains only a fixed number of forward detents. The first unavailable
    /// neighbor consumes one detent into bounded placeholder displacement;
    /// later detents stay coalesced until the builder makes that page ready.
    pub fn drainScrollForward(self: *PagedReader, geometry: scroll_geometry.Geometry) ScrollMove {
        var drained: u8 = 0;
        while (self.scroll_position.pending_detents > 0 and drained < max_scroll_detents_per_update) {
            const already_waiting = self.scroll_position.waiting_px > 0;
            switch (self.scrollForwardDetent(geometry)) {
                .moved => {
                    self.scroll_position.pending_detents -= 1;
                    drained += 1;
                },
                .waiting => {
                    if (!already_waiting) {
                        self.scroll_position.pending_detents -= 1;
                        drained += 1;
                    }
                    return .waiting;
                },
                .at_end => {
                    self.scroll_position.pending_detents = 0;
                    return .at_end;
                },
                else => |outcome| return outcome,
            }
        }
        return .moved;
    }

    /// Backward movement is immediate inside the cached window. A miss leaves
    /// the known viewport in place with loading-before and requests one
    /// bounded beginning-of-chapter reconstruction target.
    pub fn drainScrollBackward(self: *PagedReader, geometry: scroll_geometry.Geometry) ScrollMove {
        var drained: u8 = 0;
        while (self.scroll_position.pending_detents < 0 and drained < max_scroll_detents_per_update) {
            const already_waiting = self.scroll_position.waiting_px < 0;
            switch (self.scrollBackwardDetent(geometry)) {
                .moved => {
                    self.scroll_position.pending_detents += 1;
                    drained += 1;
                },
                .at_start => {
                    self.scroll_position.pending_detents = 0;
                    return .at_start;
                },
                .needs_reconstruction => {
                    if (!already_waiting) {
                        self.scroll_position.pending_detents += 1;
                        drained += 1;
                    }
                    return .needs_reconstruction;
                },
                else => |outcome| return outcome,
            }
        }
        return .moved;
    }

    /// Called after bounded reconstruction work publishes a predecessor. It
    /// consumes only the already-visible loading-before displacement and does
    /// not invent a new crank detent.
    pub fn resumeScrollBackward(self: *PagedReader, geometry: scroll_geometry.Geometry) ScrollMove {
        if (self.scroll_position.waiting_px >= 0) return .moved;
        return self.scrollBackwardDetent(geometry);
    }

    /// Repositions the cached tail so verified chapter EOF places the final
    /// line at the viewport bottom. Missing history becomes only a bounded
    /// loading-before displacement; no prior page is synthesized.
    pub fn clampScrollAtChapterEnd(self: *PagedReader, geometry: scroll_geometry.Geometry) void {
        self.scroll_position = self.chapterEndPosition(geometry) orelse return;
    }

    fn chapterEndPosition(self: *const PagedReader, geometry: scroll_geometry.Geometry) ?scroll_geometry.Position {
        const last = self.chapter_last_page orelse return null;
        var reverse_tail: [page_capacity]scroll_geometry.PageExtent = undefined;
        var reverse_count: usize = 0;
        var page = last;
        while (true) {
            const slot = self.findDrawablePage(page) orelse break;
            const extent = pageExtent(geometry, &self.pages[slot]);
            if (extent == 0) break;
            reverse_tail[reverse_count] = .{ .index = page, .extent_px = extent };
            reverse_count += 1;
            if (page == 0 or reverse_count == reverse_tail.len) break;
            page -= 1;
        }
        if (reverse_count == 0) return null;

        var tail: [page_capacity]scroll_geometry.PageExtent = undefined;
        for (0..reverse_count) |index| tail[index] = reverse_tail[reverse_count - index - 1];
        const clamp = scroll_geometry.chapterEndClamp(geometry.viewport, tail[0..reverse_count]);
        var position = clamp.position;
        if (clamp.needs_previous_page) {
            var known_height: u16 = 0;
            for (tail[0..reverse_count]) |cached| known_height += cached.extent_px;
            position.waiting_px = -@as(i16, @intCast(geometry.viewport.height() - known_height));
        }
        return position;
    }

    fn scrollForwardDetent(self: *PagedReader, geometry: scroll_geometry.Geometry) ScrollMove {
        return self.scrollForwardRequested(geometry, scroll_geometry.scroll_pixels_per_detent);
    }

    fn scrollBackwardDetent(self: *PagedReader, geometry: scroll_geometry.Geometry) ScrollMove {
        return self.scrollBackwardRequested(geometry, scroll_geometry.scroll_pixels_per_detent);
    }

    fn scrollForwardRequested(self: *PagedReader, geometry: scroll_geometry.Geometry, pixels: u16) ScrollMove {
        if (self.scroll_position.waiting_px > 0) {
            const waiting: u16 = @intCast(self.scroll_position.waiting_px);
            self.scroll_position.waiting_px = 0;
            switch (self.scrollForwardPixels(geometry, waiting)) {
                .moved => {},
                else => |outcome| return outcome,
            }
        }
        return self.scrollForwardPixels(geometry, pixels);
    }

    fn scrollBackwardRequested(self: *PagedReader, geometry: scroll_geometry.Geometry, pixels: u16) ScrollMove {
        if (self.scroll_position.waiting_px < 0) {
            const waiting: u16 = @intCast(-@as(i32, self.scroll_position.waiting_px));
            self.scroll_position.waiting_px = 0;
            return self.scrollBackwardPixels(geometry, waiting);
        }
        return self.scrollBackwardPixels(geometry, pixels);
    }

    /// Applies one bounded forward displacement through cached ready-ahead
    /// pages only. The page pool is fixed, so this loop has a compile-time
    /// ceiling even for unusually short pages.
    fn scrollForwardPixels(self: *PagedReader, geometry: scroll_geometry.Geometry, pixels: u16) ScrollMove {
        var remaining = pixels;
        var crossings: usize = 0;
        while (remaining != 0 and crossings < page_capacity) {
            const current_slot = self.findDrawablePage(self.scroll_position.top_page) orelse return .waiting;
            const extent = pageExtent(geometry, &self.pages[current_slot]);
            if (extent == 0) return .waiting;
            const current_page = self.scroll_position.top_page;
            const next = self.scrollForwardNeighbor(geometry);
            const at_end = self.chapter_end and self.chapter_last_page != null and self.scroll_position.top_page == self.chapter_last_page.?;
            const result = scroll_geometry.move(
                &self.scroll_position,
                .forward,
                remaining,
                geometry.viewport,
                .{ .index = current_page, .extent_px = extent },
                next,
                at_end,
            );
            if (result.page_changed) {
                if (current_page == self.page_index and !self.promoteScrollReadyAhead()) return .waiting;
                crossings += 1;
            }
            if (self.chapter_end) if (self.chapterEndPosition(geometry)) |end_position| {
                if (scrollPositionAtOrBeyond(self.scroll_position, end_position)) {
                    self.scroll_position = end_position;
                    return .at_end;
                }
            };
            if (result.at_chapter_limit) {
                self.clampScrollAtChapterEnd(geometry);
                return .at_end;
            }
            if (result.waiting_for_neighbor) return .waiting;
            remaining = result.remaining_px;
        }
        if (remaining != 0) {
            // This can occur only after traversing every slot in the fixed
            // pool. Retain the request as a bounded loading displacement;
            // never spin over an input-dependent number of pages.
            self.scroll_position.waiting_px = @intCast(@min(remaining, geometry.viewport.height()));
            return .waiting;
        }
        return .moved;
    }

    fn scrollBackwardPixels(self: *PagedReader, geometry: scroll_geometry.Geometry, pixels: u16) ScrollMove {
        var remaining = pixels;
        var crossings: usize = 0;
        while (remaining != 0 and crossings < page_capacity) {
            const current_page = self.scroll_position.top_page;
            const current_slot = self.findDrawablePage(current_page) orelse return .needs_reconstruction;
            const extent = pageExtent(geometry, &self.pages[current_slot]);
            if (extent == 0) return .needs_reconstruction;
            const previous = self.scrollBackwardNeighbor(geometry);
            const result = scroll_geometry.move(
                &self.scroll_position,
                .backward,
                remaining,
                geometry.viewport,
                .{ .index = current_page, .extent_px = extent },
                previous,
                current_page == 0,
            );
            if (result.at_chapter_limit) return .at_start;
            if (result.waiting_for_neighbor) return if (self.scroll_previous_unavailable) .at_start else .needs_reconstruction;
            remaining = result.remaining_px;
            if (result.page_changed) crossings += 1;
        }
        return if (remaining == 0) .moved else .needs_reconstruction;
    }

    fn scrollForwardNeighbor(self: *const PagedReader, geometry: scroll_geometry.Geometry) ?scroll_geometry.PageExtent {
        const next_page = self.scroll_position.top_page +| 1;
        const slot = self.findDrawablePage(next_page) orelse return null;
        const extent = pageExtent(geometry, &self.pages[slot]);
        if (extent == 0) return null;
        return .{ .index = next_page, .extent_px = extent };
    }

    fn scrollBackwardNeighbor(self: *const PagedReader, geometry: scroll_geometry.Geometry) ?scroll_geometry.PageExtent {
        if (self.scroll_position.top_page == 0) return null;
        const previous_page = self.scroll_position.top_page - 1;
        const slot = self.findDrawablePage(previous_page) orelse return null;
        const extent = pageExtent(geometry, &self.pages[slot]);
        if (extent == 0) return null;
        return .{ .index = previous_page, .extent_px = extent };
    }

    fn promoteScrollReadyAhead(self: *PagedReader) bool {
        return self.nextPage() == .moved;
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

    pub fn wordCount(self: *const PagedReader) u32 {
        return if (self.builder) |builder| builder.wordCount() else 0;
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
        if (self.scroll_rescan != null) {
            self.scrollRescanPageCompleted(normalized_event, decoded_offset);
            return;
        }
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
        if (self.scroll_rescan != null) {
            if (self.pages[self.buildingPage()].line_count != 0) self.scrollRescanPageCompleted(0, 0);
            if (self.build == .building) self.releaseSlot(self.buildingPage());
            self.scroll_rescan = null;
            self.reconstructing = false;
            self.build = .idle;
            return .moved;
        }
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

    fn scrollRescanPageCompleted(self: *PagedReader, normalized_event: u32, decoded_offset: u32) void {
        const state = &self.scroll_rescan.?;
        const completed_page = state.scanning;
        const completed_slot = self.buildingPage();
        self.recordCheckpoint(completed_page, normalized_event, decoded_offset);
        // Existing viewport text wins over the duplicate page decoded during
        // the rescan. Only the missing history page is retained from the
        // duplicate stream.
        if (self.findDrawablePage(completed_page) == null) {
            self.setSlot(completed_slot, .history, self.chapter_index, completed_page);
            // The render window still shows loading-before until the
            // coordinator consumes its waiting displacement. Keep the exact
            // requested predecessor alive through the immediately following
            // builder allocation; otherwise a full pool evicts page zero as
            // the oldest unpinned history before it can become visible.
            if (completed_page == state.target) self.scroll_pins[completed_slot] = true;
        } else self.releaseSlot(completed_slot);

        state.scanning += 1;
        if (state.scanning > state.resume_page) {
            const next = self.freePage();
            self.beginBuilding(next, state.scanning);
            self.scroll_rescan = null;
            self.reconstructing = false;
            return;
        }
        self.beginBuilding(self.freePage(), state.scanning);
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
        // A saved ordinal can become unreachable when the EPUB at the same
        // path is replaced or edited. At verified EOF, land on the last valid
        // word instead of leaving the restoration barrier up forever.
        if (self.reconstructing and self.chapter_end and page.word_count != 0) {
            self.selected_word_ordinal = page.first_word_ordinal + page.word_count - 1;
            self.pending_selection = null;
            self.reconstructing = false;
            return true;
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

    fn findDrawablePage(self: *const PagedReader, page: u32) ?SlotIndex {
        for (self.slots, 0..) |state, index| {
            if (state.chapter != self.chapter_index or state.page != page) continue;
            switch (state.role) {
                .displayed, .stream_front, .history, .ready_ahead => return @intCast(index),
                .free, .building, .prefetch => {},
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
        self.clearScrollPins();
        self.prefetch_page = null;
        self.chapter_index = chapter;
        self.page_index = 0;
        self.scroll_position = .{};
        self.scroll_rescan = null;
        self.scroll_previous_unavailable = false;
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
            if (state.role != .history or self.scroll_pins[index]) continue;
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
                if (self.scroll_pins[index]) continue;
                if (oldest == null or state.page < self.slots[oldest.?].page) oldest = @intCast(index);
            }
            if (count <= maximum or oldest == null) return;
            self.releaseSlot(oldest.?);
        }
    }

    fn setSlot(self: *PagedReader, slot: SlotIndex, role: SlotRole, chapter: u8, page: u32) void {
        self.slots[slot] = .{ .role = role, .chapter = chapter, .page = page };
    }

    fn releaseSlot(self: *PagedReader, slot: SlotIndex) void {
        self.slots[slot] = .{};
        self.scroll_pins[slot] = false;
    }

    fn clearScrollPins(self: *PagedReader) void {
        @memset(&self.scroll_pins, false);
    }

    fn appendScrollPage(self: *PagedReader, result: *ScrollRenderState, slot: SlotIndex, origin_y: i16) void {
        self.scroll_pins[slot] = true;
        self.appendScrollTile(result, .{ .page = .{ .cache = &self.pages[slot], .origin_y = origin_y } });
    }

    fn appendScrollTile(_: *PagedReader, result: *ScrollRenderState, tile: ScrollTile) void {
        if (result.tile_count == result.tiles.len) return;
        result.tiles[result.tile_count] = tile;
        result.tile_count += 1;
    }

    fn pageExtent(geometry: scroll_geometry.Geometry, page: *const pagination.PageCache) u16 {
        return geometry.pageExtent(page.line_count);
    }

    fn scrollTopOrigin(top_y: u16, offset_px: u16, waiting_before: u16) i16 {
        return clampScrollOrigin(@as(i32, top_y) - @as(i32, offset_px) + @as(i32, waiting_before));
    }

    fn advanceScrollOrigin(origin_y: i16, extent_px: u16) i16 {
        return clampScrollOrigin(@as(i32, origin_y) + @as(i32, extent_px));
    }

    fn clampScrollOrigin(value: i32) i16 {
        return @intCast(std.math.clamp(value, @as(i32, std.math.minInt(i16)), @as(i32, std.math.maxInt(i16))));
    }

    fn scrollPositionAtOrBeyond(position: scroll_geometry.Position, limit: scroll_geometry.Position) bool {
        return position.top_page > limit.top_page or (position.top_page == limit.top_page and position.offset_px >= limit.offset_px);
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

test "scroll window borrows ordered cached pages and pins their slots" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 2;
    reader.pages[0].line_count = 11;
    reader.pages[1].line_count = 11;
    reader.setSlot(0, .displayed, 2, 4);
    reader.setSlot(1, .history, 2, 5);

    const window = reader.scrollRenderState(.{ .top_page = 4, .offset_px = 10 }, scroll_geometry.Geometry.init(20));
    try std.testing.expectEqual(@as(u2, 2), window.tile_count);
    switch (window.tiles[0]) {
        .page => |tile| {
            try std.testing.expect(tile.cache == &reader.pages[0]);
            try std.testing.expectEqual(@as(i16, -6), tile.origin_y);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (window.tiles[1]) {
        .page => |tile| {
            try std.testing.expect(tile.cache == &reader.pages[1]);
            try std.testing.expectEqual(@as(i16, 225), tile.origin_y);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(reader.scroll_pins[0]);
    try std.testing.expect(reader.scroll_pins[1]);
    try std.testing.expectEqual(@as(usize, PagedReader.page_capacity * @sizeOf(pagination.PageCache)), PagedReader.page_pool_reserved_bytes);
}

test "scroll window describes missing sides without copying or constructing text" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.pages[0].line_count = 1;
    reader.setSlot(0, .displayed, 0, 0);
    const build_before = reader.build;

    const after = reader.scrollRenderState(.{}, scroll_geometry.Geometry.init(20));
    try std.testing.expectEqual(@as(u2, 2), after.tile_count);
    switch (after.tiles[0]) {
        .page => |tile| try std.testing.expect(tile.cache == &reader.pages[0]),
        else => return error.TestUnexpectedResult,
    }
    switch (after.tiles[1]) {
        .loading_after => |origin_y| try std.testing.expectEqual(@as(i16, 25), origin_y),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(std.meta.eql(build_before, reader.build));

    reader.slots[0].page = 1;
    reader.chapter_end = true;
    reader.chapter_last_page = 1;
    const before = reader.scrollRenderState(.{ .top_page = 1, .waiting_px = -12 }, scroll_geometry.Geometry.init(20));
    try std.testing.expectEqual(@as(u2, 2), before.tile_count);
    switch (before.tiles[0]) {
        .loading_before => |origin_y| try std.testing.expectEqual(@as(i16, 4), origin_y),
        else => return error.TestUnexpectedResult,
    }
    switch (before.tiles[1]) {
        .page => |tile| try std.testing.expectEqual(@as(i16, 16), tile.origin_y),
        else => return error.TestUnexpectedResult,
    }
}

test "pinned history slots are excluded from page-pool eviction" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    for (&reader.slots, 0..) |*slot, index| slot.* = .{ .role = .history, .page = @intCast(index) };
    reader.scroll_pins[0] = true;

    const allocated = reader.allocateSlot().?;
    try std.testing.expectEqual(@as(PagedReader.SlotIndex, 1), allocated);
    try std.testing.expectEqual(PagedReader.SlotRole.history, reader.slots[0].role);
    try std.testing.expectEqual(PagedReader.SlotRole.free, reader.slots[allocated].role);
}

test "forward Scroll consumes ready-ahead pages and resumes the existing builder" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.pages[0] = makePage(0, 1);
    reader.pages[0].line_count = 11;
    reader.pageCompleted(0, 0);
    reader.pages[reader.next_page] = makePage(1, 1);
    reader.pages[reader.next_page].line_count = 11;
    reader.pageCompleted(0, 0);
    reader.beginScroll();
    reader.scroll_position.offset_px = 225;
    reader.queueScrollDetents(1);

    try std.testing.expectEqual(PagedReader.ScrollMove.moved, reader.drainScrollForward(scroll_geometry.Geometry.init(20)));
    try std.testing.expectEqual(@as(u32, 1), reader.page_index);
    try std.testing.expectEqual(@as(u32, 1), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(u16, 6), reader.scrollPosition().offset_px);
    try std.testing.expectEqual(PagedReader.SlotRole.history, reader.slots[reader.findCachedPage(0).?].role);
    try std.testing.expectEqual(PagedReader.SlotRole.building, reader.slots[reader.next_page].role);
}

test "fast forward Scroll input waits once then drains a bounded backlog" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    var context: u8 = 0;
    reader.begin(0, 10, .{ .context = &context, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width });
    reader.pages[0] = makePage(0, 1);
    reader.pages[0].line_count = 11;
    reader.pageCompleted(0, 0);
    reader.beginScroll();
    reader.scroll_position.offset_px = 225;
    reader.queueScrollDetents(100);

    try std.testing.expectEqual(PagedReader.ScrollMove.waiting, reader.drainScrollForward(scroll_geometry.Geometry.init(20)));
    try std.testing.expectEqual(@as(i16, 6), reader.scrollPosition().waiting_px);
    try std.testing.expectEqual(@as(i16, 63), reader.scrollPosition().pending_detents);

    reader.pages[reader.next_page] = makePage(1, 1);
    reader.pages[reader.next_page].line_count = 11;
    reader.pageCompleted(0, 0);
    try std.testing.expectEqual(PagedReader.ScrollMove.moved, reader.drainScrollForward(scroll_geometry.Geometry.init(20)));
    try std.testing.expectEqual(@as(u32, 1), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(i16, 55), reader.scrollPosition().pending_detents);
    try std.testing.expectEqual(@as(u16, 102), reader.scrollPosition().offset_px);
}

test "Scroll EOF bottom clamp uses cached history or loading-before space" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 0;
    reader.pages[0].line_count = 11;
    reader.pages[1].line_count = 3;
    reader.setSlot(0, .history, 0, 0);
    reader.setSlot(1, .displayed, 0, 1);
    reader.current_page = 1;
    reader.page_index = 1;
    reader.chapter_end = true;
    reader.chapter_last_page = 1;
    reader.scroll_position = .{ .top_page = 1 };

    reader.clampScrollAtChapterEnd(geometry);
    try std.testing.expectEqual(@as(u32, 0), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(u16, 62), reader.scrollPosition().offset_px);
    try std.testing.expectEqual(@as(i16, 0), reader.scrollPosition().waiting_px);

    reader.slots[0] = .{};
    reader.scroll_position = .{ .top_page = 1 };
    reader.clampScrollAtChapterEnd(geometry);
    try std.testing.expectEqual(@as(u32, 1), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(i16, -169), reader.scrollPosition().waiting_px);
    const window = reader.scrollRenderState(reader.scrollPosition(), geometry);
    switch (window.tiles[0]) {
        .loading_before => |origin_y| try std.testing.expectEqual(@as(i16, 4), origin_y),
        else => return error.TestUnexpectedResult,
    }
    switch (window.tiles[1]) {
        .page => |tile| try std.testing.expectEqual(@as(i16, 173), tile.origin_y),
        else => return error.TestUnexpectedResult,
    }
}

test "Scroll stops at the bottom alignment before a partial final page exposes blank space" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 0;
    reader.pages[0].line_count = 11;
    reader.pages[1].line_count = 3;
    reader.setSlot(0, .displayed, 0, 0);
    reader.setSlot(1, .history, 0, 1);
    reader.current_page = 0;
    reader.page_index = 0;
    reader.current_ready = true;
    reader.chapter_end = true;
    reader.chapter_last_page = 1;
    reader.scroll_position = .{ .top_page = 0, .offset_px = 50 };

    try std.testing.expectEqual(PagedReader.ScrollMove.at_end, reader.scrollPixels(.forward, geometry, 20));
    try std.testing.expectEqual(@as(u32, 0), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(u16, 62), reader.scrollPosition().offset_px);
}

test "Scroll presentation transfer uses the first visible normalized word" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 0;
    reader.current_page = 0;
    reader.page_index = 4;
    reader.current_ready = true;
    reader.pages[0].first_word_ordinal = 20;
    reader.pages[0].word_count = 3;
    try reader.pages[0].appendLineWithMetadata("one", 0, 1);
    try reader.pages[0].appendLineWithMetadata("two", 0, 1);
    try reader.pages[0].appendLineWithMetadata("three", 0, 1);
    reader.setSlot(0, .displayed, 0, 4);

    reader.beginScrollAtWord(21, geometry);
    try std.testing.expectEqual(@as(u32, 4), reader.scrollPosition().top_page);
    try std.testing.expectEqual(geometry.line_advance, reader.scrollPosition().offset_px);
    try std.testing.expectEqual(@as(?u32, 21), reader.scrollFirstVisibleWord(geometry));
    try std.testing.expect(reader.showScrollTopPage());
    try std.testing.expectEqual(@as(u32, 4), reader.page_index);
}

test "Scroll backward reconstruction preserves the viewport and reconnects the builder" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 0;
    reader.page_index = 5;
    reader.current_page = 0;
    reader.current_ready = true;
    reader.pages[0].line_count = 11;
    reader.pages[1].line_count = 11;
    reader.setSlot(0, .displayed, 0, 5);
    reader.setSlot(1, .ready_ahead, 0, 6);
    reader.next_page = 1;
    reader.next_ready = true;
    reader.beginScroll();

    reader.queueScrollDetents(-1);
    try std.testing.expectEqual(PagedReader.ScrollMove.needs_reconstruction, reader.drainScrollBackward(geometry));
    try std.testing.expectEqual(@as(i16, -12), reader.scrollPosition().waiting_px);
    const visible = &reader.pages[0];
    const loading = reader.scrollRenderState(reader.scrollPosition(), geometry);
    switch (loading.tiles[0]) {
        .loading_before => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(reader.scroll_pins[0]);

    try std.testing.expectEqual(@as(?u32, 4), reader.scrollPreviousRescanTarget());
    try std.testing.expect(reader.beginScrollRescan(10, .{ .context = &reader, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width }, 4));
    try std.testing.expect(reader.isScrollRescanning());
    try std.testing.expect(reader.pages[0].line_count == 11);
    try std.testing.expect(visible == &reader.pages[0]);

    for (0..5) |_| {
        reader.pages[reader.buildingPage()].line_count = 11;
        reader.pageCompleted(0, 0);
    }
    try std.testing.expect(reader.findDrawablePage(4) != null);
    try std.testing.expect(reader.isScrollRescanning());
    try std.testing.expectEqual(PagedReader.ScrollMove.moved, reader.resumeScrollBackward(geometry));
    try std.testing.expectEqual(@as(u32, 4), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(u16, 219), reader.scrollPosition().offset_px);
    try std.testing.expect(visible == &reader.pages[0]);

    reader.pages[reader.buildingPage()].line_count = 11;
    reader.pageCompleted(0, 0);
    try std.testing.expect(!reader.isScrollRescanning());
    try std.testing.expectEqual(@as(u32, 5), reader.page_index);
    try std.testing.expectEqual(PagedReader.SlotRole.building, reader.slots[reader.next_page].role);
}

test "Scroll reconstruction retains page zero through a full-pool builder allocation" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 0;
    reader.page_index = 5;
    reader.current_page = 4;
    reader.current_ready = true;
    for (0..PagedReader.page_capacity) |index| {
        reader.pages[index].line_count = 11;
        reader.setSlot(@intCast(index), .history, 0, @intCast(index + 1));
    }
    reader.setSlot(4, .displayed, 0, 5);
    reader.scroll_position = .{ .top_page = 1, .waiting_px = -12 };
    _ = reader.scrollRenderState(reader.scrollPosition(), geometry);

    try std.testing.expect(reader.beginScrollRescan(10, .{ .context = &reader, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width }, 0));
    reader.pages[reader.buildingPage()].line_count = 11;
    reader.pageCompleted(0, 0);

    const page_zero = reader.findDrawablePage(0) orelse return error.TestExpectedEqual;
    try std.testing.expect(reader.scroll_pins[page_zero]);
    try std.testing.expectEqual(PagedReader.ScrollMove.moved, reader.resumeScrollBackward(geometry));
    try std.testing.expectEqual(@as(u32, 0), reader.scrollPosition().top_page);
    try std.testing.expectEqual(@as(u16, 219), reader.scrollPosition().offset_px);
}

test "Scroll reconstruction failure changes only loading-before to unavailable" {
    const geometry = scroll_geometry.Geometry.init(20);
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.chapter_index = 0;
    reader.page_index = 1;
    reader.current_page = 0;
    reader.current_ready = true;
    reader.pages[0].line_count = 11;
    reader.setSlot(0, .displayed, 0, 1);
    reader.beginScroll();
    reader.queueScrollDetents(-1);
    try std.testing.expectEqual(PagedReader.ScrollMove.needs_reconstruction, reader.drainScrollBackward(geometry));
    try std.testing.expect(reader.beginScrollRescan(10, .{ .context = &reader, .width = struct {
        fn width(_: *anyopaque, text: []const u8) usize {
            return text.len;
        }
    }.width }, 0));

    reader.markScrollPreviousUnavailable();
    const window = reader.scrollRenderState(reader.scrollPosition(), geometry);
    switch (window.tiles[0]) {
        .unavailable_before => {},
        else => return error.TestUnexpectedResult,
    }
    switch (window.tiles[1]) {
        .page => |tile| try std.testing.expect(tile.cache == &reader.pages[0]),
        else => return error.TestUnexpectedResult,
    }
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

    reader.beginWordRescan(7);
    const restoring = reader.renderState();
    try std.testing.expect(restoring.page == null);
    try std.testing.expect(restoring.reconstructing);
}

test "word restoration clamps a stale ordinal at verified chapter end" {
    var reader = PagedReader.init(3 * @sizeOf(cache_policy.Entry));
    reader.current_ready = true;
    reader.chapter_end = true;
    reader.pages[0] = makePage(10, 2);
    reader.beginWordRescan(99);

    try std.testing.expect(reader.fulfillPendingSelection());
    try std.testing.expectEqual(@as(?u32, 11), reader.selected_word_ordinal);
    try std.testing.expect(!reader.isReconstructing());
    try std.testing.expect(reader.renderState().page != null);
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
