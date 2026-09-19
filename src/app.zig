const std = @import("std");
const limits = @import("limits").reader;
const deflate = @import("archive/deflate.zig");
const zip = @import("archive/zip.zig");
const xhtml = @import("content/xhtml.zig");
const cache_policy = @import("content/cache_policy.zig");
const chapter_browser = @import("chapter_browser.zig");
const pagination = @import("content/pagination.zig");
const paged_reader = @import("paged_reader.zig");
const rsvp = @import("content/rsvp.zig");
const rsvp_reader = @import("rsvp_reader.zig");
const epub = @import("publication/epub.zig");
const reading_state = @import("storage/reading_state.zig");
const persistence = @import("storage/persistence.zig");
const reader_transitions = @import("reader_transitions.zig");
const reader_input = @import("reader_input.zig");
const reader_coordinator = @import("reader_coordinator.zig");
const reader_host = @import("reader_host.zig");
const telemetry = @import("telemetry.zig");
const pdapi = @import("playdate_api_definitions.zig");
const PlaydateAllocator = @import("platform/playdate_allocator.zig").PlaydateAllocator;
const PlaydateFileReader = @import("platform/playdate_file_reader.zig").PlaydateFileReader;
const playdate_persistence = @import("platform/playdate_persistence.zig");
const PlaydateRenderer = @import("platform/playdate_renderer.zig").Renderer;

pub const State = reader_coordinator.Screen;

const Lifecycle = reader_coordinator.Lifecycle;
const ChapterFailure = reader_coordinator.ChapterFailure;

const InputAction = reader_input.Intent;

const RsvpRescanTarget = rsvp_reader.RsvpReader.RescanTarget;

const ChapterOpenAction = reader_coordinator.ChapterOpenAction;

const PagedSelectionTarget = reader_transitions.PagedSelectionTarget;

/// A boundary press must not discard an in-flight prefetch merely because its
/// first page needs another update tick. The old chapter stays drawable while
/// that work completes; a normal open is reserved for when no session exists.
const ChapterTransitionDisposition = enum { activate, wait_for_prefetch, open };

fn chapterTransitionDisposition(prefetch_ready: bool, prefetching: bool) ChapterTransitionDisposition {
    if (prefetch_ready) return .activate;
    return if (prefetching) .wait_for_prefetch else .open;
}

/// Opening advances through file open, EOCD scanning, metadata, navigation,
/// and central-directory lookup in separate coordinator-owned update ticks.
/// Its archive reader points at App's stable `opening_file` field, not at
/// temporary job storage.
const page_pool_capacity = 3;
// Eleven 384-byte lines in each of three active slots reserve just under
// 13 KiB; keep the budget tied to the actual drawable viewport.
const page_pool_byte_budget = 13 * 1024;
const metadata_read_chunk_size = limits.metadata_read_chunk_bytes;
// Prefetch work is intentionally larger than the normal reading budget: it
// runs while the already-drawable final page remains on screen. Both limits
// remain fixed so a long central directory cannot monopolize a frame.
const prefetch_directory_records_per_update = 8;
const prefetch_byte_budget = 1024;
const checkpoint_byte_budget = cache_policy.capacity * @sizeOf(cache_policy.Entry);
const crank_degrees_per_page: f32 = 15;
const layout_revision: u16 = 1;
const resume_debounce_frames: u8 = 60;
const pace_debounce_frames: u8 = 60;
const page_pool_reserved_bytes = page_pool_capacity * @sizeOf(pagination.PageCache);
const reader_text_x: c_int = 12;
const reader_text_y: c_int = 8;
const reader_text_width = 376;
const reader_line_height: c_int = 20;

test "library is the initial reader state" {
    try std.testing.expectEqual(State.library, State.library);
}

test "a requested boundary waits for an in-flight prefetch instead of replacing it" {
    try std.testing.expectEqual(ChapterTransitionDisposition.activate, chapterTransitionDisposition(true, true));
    try std.testing.expectEqual(ChapterTransitionDisposition.wait_for_prefetch, chapterTransitionDisposition(false, true));
    try std.testing.expectEqual(ChapterTransitionDisposition.open, chapterTransitionDisposition(false, false));
}

test "the active page pool fits its fixed memory budget" {
    try std.testing.expect(page_pool_reserved_bytes <= page_pool_byte_budget);
}

test "the active page pool is the complete reserved page cache" {
    try std.testing.expectEqual(@as(usize, page_pool_capacity) * @sizeOf(pagination.PageCache), page_pool_reserved_bytes);
}

test "the reader layout fits eleven body lines on the display" {
    const final_baseline = reader_text_y + @as(c_int, pagination.max_lines - 1) * reader_line_height;
    try std.testing.expect(final_baseline + reader_line_height <= 240);
}

test "opening reads metadata through a bounded staging buffer" {
    try std.testing.expect(metadata_read_chunk_size <= 4 * 1024);
}

test "semantic checkpoint metadata has a fixed byte budget" {
    try std.testing.expectEqual(cache_policy.capacity * @sizeOf(cache_policy.Entry), checkpoint_byte_budget);
}

test "RSVP crank detents schedule one direction at a time" {
    var accumulated: f32 = 0;
    try std.testing.expectEqual(@as(i8, 0), crankDirection(&accumulated, 10));
    try std.testing.expectEqual(@as(i8, 1), crankDirection(&accumulated, 5));
    try std.testing.expectEqual(@as(i8, -1), crankDirection(&accumulated, -15));
}

test "paged crank detents coalesce a fast turn without leaving a backlog" {
    var accumulated: f32 = 0;
    try std.testing.expectEqual(@as(i16, 3), crankDetents(&accumulated, 50));
    try std.testing.expectApproxEqAbs(@as(f32, 5), accumulated, 0.001);
    try std.testing.expectEqual(@as(i16, -2), crankDetents(&accumulated, -35));
    try std.testing.expectApproxEqAbs(@as(f32, 0), accumulated, 0.001);
}

test "an empty spine document advances only when another entry exists" {
    try std.testing.expectEqual(@as(?u8, 1), nextReadableSpineIndex(0, 2));
    try std.testing.expectEqual(@as(?u8, null), nextReadableSpineIndex(1, 2));
}

test "B toggles reading mode and does not leave the book" {
    try std.testing.expectEqual(InputAction.toggle_reading_mode, inputAction(.reading, .ready, .paged, pdapi.BUTTON_B | pdapi.BUTTON_RIGHT));
    try std.testing.expectEqual(InputAction.toggle_reading_mode, inputAction(.reading, .ready, .rsvp, pdapi.BUTTON_B));
    try std.testing.expectEqual(InputAction.none, inputAction(.opening, .opening, .paged, pdapi.BUTTON_B));
    try std.testing.expectEqual(InputAction.none, inputAction(.library, .opening, .paged, pdapi.BUTTON_B));
}

test "settings controls do not use reader page navigation" {
    try std.testing.expectEqual(InputAction.close_settings, inputAction(.settings, .ready, .paged, pdapi.BUTTON_B));
    try std.testing.expectEqual(InputAction.activate_setting, inputAction(.settings, .ready, .paged, pdapi.BUTTON_A));
    try std.testing.expectEqual(InputAction.settings_next, inputAction(.settings, .ready, .paged, pdapi.BUTTON_DOWN));
}

test "chapter browser B returns to reading before reader controls" {
    try std.testing.expectEqual(InputAction.close_chapter_browser, inputAction(.chapter_browser, .ready, .paged, pdapi.BUTTON_B | pdapi.BUTTON_RIGHT));
}

test "chapter browser maps directional controls and A without reader paging" {
    try std.testing.expectEqual(InputAction.chapter_browser_next, inputAction(.chapter_browser, .ready, .paged, pdapi.BUTTON_RIGHT));
    try std.testing.expectEqual(InputAction.chapter_browser_previous, inputAction(.chapter_browser, .ready, .paged, pdapi.BUTTON_UP));
    try std.testing.expectEqual(InputAction.open_browser_chapter, inputAction(.chapter_browser, .ready, .paged, pdapi.BUTTON_A));
}

test "settings and chapter browser controls remain isolated" {
    try std.testing.expectEqual(InputAction.none, inputAction(.settings, .ready, .paged, pdapi.BUTTON_RIGHT));
    try std.testing.expectEqual(InputAction.chapter_browser_previous, inputAction(.chapter_browser, .ready, .rsvp, pdapi.BUTTON_LEFT));
}

test "RSVP entry leaves paged navigation unavailable until its word cursor exists" {
    try std.testing.expectEqual(InputAction.rsvp_toggle_autoplay, inputAction(.reading, .ready, .rsvp, pdapi.BUTTON_A));
    try std.testing.expectEqual(InputAction.rsvp_wpm_up, inputAction(.reading, .ready, .rsvp, pdapi.BUTTON_UP));
    try std.testing.expectEqual(InputAction.rsvp_previous_sentence, inputAction(.reading, .ready, .rsvp, pdapi.BUTTON_LEFT));
    try std.testing.expectEqual(InputAction.next_page, inputAction(.reading, .ready, .paged, pdapi.BUTTON_RIGHT));
}

test "mode switching preserves a pending paged cross-page destination" {
    try std.testing.expectEqual(@as(u32, 42), pagedModeSwitchOrdinal(41, .{ .ordinal = 42 }));
    try std.testing.expectEqual(@as(u32, 41), pagedModeSwitchOrdinal(41, .last_word));
    try std.testing.expectEqual(@as(u32, 41), pagedModeSwitchOrdinal(41, null));
}

test "paged selection rebuild advances through an intermediate page" {
    var intermediate: pagination.PageCache = .{};
    intermediate.first_word_ordinal = 20;
    intermediate.word_count = 10;
    var target_page: pagination.PageCache = .{};
    target_page.first_word_ordinal = 30;
    target_page.word_count = 10;
    try std.testing.expect(pendingOrdinalRequiresNextPage(&intermediate, 35));
    try std.testing.expect(pendingOrdinalRequiresNextPage(&target_page, 35));
    try std.testing.expect(!pendingOrdinalRequiresNextPage(&target_page, 29));
}

test "chapter errors retain directional chapter recovery controls" {
    try std.testing.expectEqual(InputAction.next_chapter, inputAction(.chapter_error, .chapter_error, .paged, pdapi.BUTTON_RIGHT));
    try std.testing.expectEqual(InputAction.previous_chapter, inputAction(.chapter_error, .chapter_error, .paged, pdapi.BUTTON_UP));
}

pub const App = struct {
    playdate: *pdapi.PlaydateAPI,
    allocator: *PlaydateAllocator,
    renderer: PlaydateRenderer,
    coordinator: reader_coordinator.ReaderCoordinator,
    opening_file: ?PlaydateFileReader = null,
    // Chapter source is never collected: this file and stream stay open while
    // a current/next pair of drawable pages is built incrementally.
    chapter_file: ?PlaydateFileReader = null,
    // Once a chapter's final page is known, the former previous-page slot is
    // available for the first page of the following chapter.  Prefetching
    // into that slot keeps the active pool bounded at three pages: the reader
    // trades one old page for a ready chapter transition.
    prefetch_file: ?PlaydateFileReader = null,

    pub fn init(playdate: *pdapi.PlaydateAPI, allocator: *PlaydateAllocator) !*App {
        const body_font = playdate.graphics.loadFont("/System/Fonts/Roobert-20-Medium.pft", null) orelse return error.FontLoadFailed;
        const app = try allocator.allocator().create(App);
        app.playdate = playdate;
        app.allocator = allocator;
        app.renderer = PlaydateRenderer.init(playdate, body_font);
        app.opening_file = null;
        app.chapter_file = null;
        app.prefetch_file = null;
        app.coordinator.initInPlace(checkpoint_byte_budget);
        app.coordinator.attachAllocator(allocator.allocator());
        app.coordinator.attachPersistence(persistence.Service.init(playdate_persistence.fileStore(playdate.file)));
        app.coordinator.attachHost(app.readerHost());
        app.loadSettings();
        app.installSystemMenu();
        app.discoverLibrary();
        return app;
    }

    pub fn updateAndRender(self: *App) c_int {
        const started_at = self.playdate.system.getCurrentTimeMilliseconds();
        defer {
            self.coordinator.telemetry.frameFinished(started_at, self.playdate.system.getCurrentTimeMilliseconds());
        }

        var pushed: pdapi.PDButtons = 0;
        self.playdate.system.getButtonState(null, &pushed, null);
        self.coordinator.update(
            inputSnapshot(self.coordinator.screen, self.coordinator.lifecycle, self.coordinator.mode, pushed),
            started_at,
            .{ .context = self, .cancel_active_reading = cancelActiveReading, .perform = performReaderIntent },
        );
        self.handleCrank();
        self.advanceRsvpAutoplay(started_at);

        self.coordinator.advanceWork(.{
            .context = self,
            .advance_opening = advanceOpeningWork,
            .advance_chapter = advanceChapterWork,
            .fulfill_paged_selection = fulfillPagedSelectionWork,
            .drain_paged_detents = drainPagedDetentsWork,
            .advance_prefetch = advancePrefetchWork,
            .flush_persistence = flushPersistenceWork,
        });

        self.renderer.beginFrame();
        self.drawCurrentScreen();
        if (self.coordinator.telemetry.enabled) self.drawTelemetry();
        return 1;
    }

    fn drawCurrentScreen(self: *App) void {
        switch (self.coordinator.renderModel()) {
            .library => self.drawLibrary(),
            .settings => self.drawSettings(),
            .chapters => self.drawChapterBrowser(),
            .opening => self.drawText("Opening EPUB...", 12, 12),
            .paged => self.drawPage(),
            .rsvp => self.drawRsvpPlaceholder(),
            .failure => |failure| switch (failure) {
                .unavailable => self.drawText("EPUB unavailable", 12, 12),
                .invalid_archive => self.drawText("Invalid EPUB archive", 12, 12),
                .missing_mimetype => self.drawText("mimetype entry missing", 12, 12),
                .invalid_mimetype => self.drawText("Invalid mimetype entry", 12, 12),
                .chapter => self.drawChapterError(),
            },
        }
        // self.drawText("B: library", 12, 220);
    }

    fn discoverLibrary(self: *App) void {
        self.coordinator.discoverLibrary();
    }

    fn readerHost(self: *App) reader_host.ReaderHost {
        return .{
            .files = .{ .context = self, .open = openReaderFile, .close = closeReaderFile, .list_epubs = listEpubs },
            .measure = .{ .context = self, .width = measureTextWidth },
        };
    }

    fn openSelectedBook(self: *App) void {
        _ = self.coordinator.openSelectedBook();
    }

    /// Leaving a book must not leave an opening, chapter, or prefetch job
    /// alive: all three reuse App-owned buffers and would otherwise race the
    /// next selected book. A readable position is written immediately rather
    /// than waiting for the normal debounce after the user explicitly exits.
    fn returnToLibrary(self: *App) void {
        self.stopRsvpAutoplay(self.playdate.system.getCurrentTimeMilliseconds());
        _ = self.coordinator.persistence.?.flushPendingPace(self.coordinator.pace);
        if (self.coordinator.lifecycle == .ready) {
            self.writePosition();
        }
        self.coordinator.cancelOpening();
        self.cancelPrefetch();
        self.releaseActivePrefetchBacking();
        if (self.chapter_file) |*file| file.close();
        self.chapter_file = null;
        self.coordinator.chapter_open = null;
        self.coordinator.chapter_stream = null;
        if (self.coordinator.decode_workspace.owner == .active) self.coordinator.decode_workspace.release(.active);
        self.coordinator.paged.builder = null;
        self.closeOpeningFile();
        self.coordinator.archive_index = null;
        self.coordinator.paged.rescan = .none;
        self.coordinator.paged.pending_selection = null;
        self.coordinator.pending_mode_word_ordinal = null;
        self.coordinator.pending_prefetch_transition = null;
        self.coordinator.paged.detent_backlog = 0;
        self.coordinator.returnToLibrary();
        self.coordinator.lifecycle = .opening;
    }

    fn drawLibrary(self: *App) void {
        self.drawText("EPUB library", 12, 12);
        if (self.coordinator.library.len == 0) {
            self.drawText("Put .epub files in Data", 12, 40);
            return;
        }
        for (self.coordinator.library.books[0..self.coordinator.library.len], 0..) |*book, index| {
            const y: c_int = 40 + @as(c_int, @intCast(index)) * 20;
            self.drawText(if (index == self.coordinator.library.selected) ">" else " ", 4, y);
            self.drawText(book.slice(), 18, y);
        }
        self.drawText("A: open", 12, 220);
    }

    /// Settings and chapter browsing only interrupt an opened reader. This
    /// keeps their return destination explicit and avoids changing pipelines
    /// until the reader explicitly confirms an action.
    fn openSettings(self: *App) void {
        _ = self.coordinator.openSettings();
    }

    fn openChapterBrowser(self: *App) void {
        if (self.coordinator.screen != .reading or self.coordinator.publication.spine_len == 0) return;
        self.stopRsvpAutoplay(self.playdate.system.getCurrentTimeMilliseconds());
        self.coordinator.crank_accumulated = 0;
        _ = self.coordinator.openChapters(self.coordinator.publication.spine_len, self.coordinator.chapter_index);
    }

    fn closeChapterBrowser(self: *App) void {
        _ = self.coordinator.closeChapterBrowser();
        self.coordinator.crank_accumulated = 0;
    }

    fn openBrowserChapter(self: *App) void {
        if (self.coordinator.chapter_browser.entry_count == 0) return;
        const selected = self.coordinator.chapter_browser.selected;
        self.coordinator.crank_accumulated = 0;
        self.scheduleOpenChapter(selected, .normal);
        self.coordinator.lifecycle = .ready;
    }

    fn moveSettingsSelection(self: *App, direction: i8) void {
        if (self.coordinator.screen != .settings) return;
        self.coordinator.moveSettingsSelection(direction);
    }

    fn activateSetting(self: *App) void {
        if (self.coordinator.screen != .settings) return;
        if (self.coordinator.settings_selected == 0) {
            self.switchReadingMode();
            return;
        }
        _ = self.coordinator.rsvp_reader.adjustWpm(1, self.playdate.system.getCurrentTimeMilliseconds(), &self.coordinator.pace);
        self.writeSettings();
    }

    fn toggleReadingMode(self: *App) void {
        if (self.coordinator.screen != .reading) return;
        self.switchReadingMode();
    }

    fn switchReadingMode(self: *App) void {
        const target_word = if (self.coordinator.mode == .paged)
            pagedModeSwitchOrdinal(self.currentPagedWordOrdinal(), self.coordinator.paged.pending_selection)
        else
            self.coordinator.rsvp_reader.position().word;
        self.coordinator.toggleMode();
        self.stopRsvpAutoplay(self.playdate.system.getCurrentTimeMilliseconds());
        self.coordinator.paged.pending_selection = null;
        self.coordinator.paged.detent_backlog = 0;
        self.coordinator.crank_accumulated = 0;
        self.coordinator.pending_mode_word_ordinal = target_word;
        if (self.coordinator.lifecycle == .ready) {
            switch (self.coordinator.mode) {
                .paged => {
                    self.coordinator.paged.pending_selection = .{ .ordinal = target_word };
                    self.scheduleOpenChapter(self.coordinator.chapter_index, .{ .word_rescan = target_word });
                },
                .rsvp => self.scheduleOpenChapter(self.coordinator.chapter_index, .{ .rsvp_rescan = .{ .word = target_word } }),
            }
            self.savePosition();
        }
        self.writeSettings();
    }

    fn drawSettings(self: *App) void {
        self.drawText("Settings", 12, 12);
        self.drawText(if (self.coordinator.settings_selected == 0) "> Reading mode" else "  Reading mode", 12, 52);
        self.drawText(switch (self.coordinator.mode) {
            .paged => "Paged",
            .rsvp => "RSVP",
        }, 32, 76);
        self.drawText(if (self.coordinator.settings_selected == 1) "> RSVP WPM" else "  RSVP WPM", 12, 112);
        var wpm_buffer: [8]u8 = undefined;
        const wpm = std.fmt.bufPrint(&wpm_buffer, "{d}", .{self.coordinator.rsvp_reader.wpm}) catch "";
        self.drawText(wpm, 32, 136);
        self.drawText("A: change   B: back", 12, 220);
    }

    fn drawChapterBrowser(self: *App) void {
        var header_buffer: [32]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buffer, "Chapters {d}/{d}", .{ self.coordinator.chapter_browser.selected + 1, self.coordinator.chapter_browser.entry_count }) catch "Chapters";
        self.drawText(header, 12, 12);
        var label_buffer: [160]u8 = undefined;
        const rows = self.coordinator.chapter_browser.displayedCount();
        for (0..rows) |row| {
            const index = self.coordinator.chapter_browser.first_visible + @as(u8, @intCast(row));
            const y: c_int = 36 + @as(c_int, @intCast(row)) * 18;
            self.drawText(if (index == self.coordinator.chapter_browser.selected) ">" else " ", 8, y);
            const label = chapter_browser.formatLabel(&label_buffer, index, self.coordinator.publication.chapter_labels[index].slice(), self.coordinator.publication.spine[index].slice());
            self.drawText(label, 24, y);
        }
        self.drawText("B: back", 12, 220);
    }

    fn drawRsvpPlaceholder(self: *App) void {
        const render = self.coordinator.rsvp_reader.renderState();
        self.drawText(if (render.playing) "RSVP - playing" else "RSVP - paused", 12, 12);
        var wpm_buffer: [16]u8 = undefined;
        const wpm = std.fmt.bufPrint(&wpm_buffer, "WPM: {d}", .{render.wpm}) catch "";
        self.drawText(wpm, 12, 36);
        if (render.word == null) {
            self.drawText(if (self.coordinator.rsvp_reader.isReconstructing()) "Rebuilding word..." else "Loading chapter...", 12, 76);
            return;
        }
        const word = render.word.?;
        if (rsvp.anchorBytes(word)) |anchor| {
            const prefix_width = self.textWidth(word[0..anchor.start]);
            const anchor_width = self.textWidth(word[anchor.start..anchor.end]);
            const x: c_int = 200 - prefix_width - @divTrunc(anchor_width, 2);
            self.drawText(word, x, 100);
        } else {
            self.drawText(word, 12, 100);
        }
        self.drawText("A: play  Up/Down: WPM", 12, 196);
        self.drawText("Left: sentence  B: Paged", 12, 220);
    }

    fn installSystemMenu(self: *App) void {
        _ = self.playdate.system.addMenuItem("Library", libraryMenuSelected, self);
        _ = self.playdate.system.addMenuItem("Settings", settingsMenuSelected, self);
        _ = self.playdate.system.addMenuItem("Chapters", chaptersMenuSelected, self);
    }

    fn loadSettings(self: *App) void {
        const settings = self.coordinator.persistence.?.loadSettings();
        self.coordinator.mode = if (settings.reading_mode == .rsvp) .rsvp else .paged;
        self.coordinator.rsvp_reader.wpm = settings.rsvp_wpm;
    }

    fn writeSettings(self: *App) void {
        _ = self.coordinator.persistence.?.saveSettings(.{ .reading_mode = if (self.coordinator.mode == .rsvp) .rsvp else .paged, .rsvp_wpm = self.coordinator.rsvp_reader.wpm });
    }

    fn handleCrank(self: *App) void {
        if (self.coordinator.screen == .chapter_browser) {
            self.coordinator.chapter_browser.move(crankDetents(&self.coordinator.crank_accumulated, self.playdate.system.getCrankChange()));
            return;
        }
        if (self.coordinator.screen != .reading) return;
        if (self.coordinator.lifecycle != .ready or self.coordinator.chapter_open != null or self.coordinator.paged.isRescanning()) return;
        if (self.coordinator.mode == .rsvp) {
            if (self.coordinator.rsvp_reader.timer.running) return;
            switch (crankDirection(&self.coordinator.crank_accumulated, self.playdate.system.getCrankChange())) {
                1 => self.nextRsvpWord(),
                -1 => self.previousRsvpWord(),
                else => {},
            }
            return;
        }
        self.coordinator.paged.detent_backlog = saturatingAddDetents(self.coordinator.paged.detent_backlog, crankDetents(&self.coordinator.crank_accumulated, self.playdate.system.getCrankChange()));
        self.drainPagedDetents();
    }

    fn toggleRsvpAutoplay(self: *App, now_ms: u32) void {
        if (self.coordinator.screen != .reading or self.coordinator.mode != .rsvp) return;
        self.coordinator.rsvp_reader.toggleAutoplay(now_ms, &self.coordinator.pace);
    }

    fn adjustRsvpWpm(self: *App, direction: i8, now_ms: u32) void {
        if (self.coordinator.screen != .reading or self.coordinator.mode != .rsvp) return;
        if (!self.coordinator.rsvp_reader.adjustWpm(direction, now_ms, &self.coordinator.pace)) return;
        self.coordinator.persistence.?.requestWrite(.pace, pace_debounce_frames);
        self.writeSettings();
    }

    fn advanceRsvpAutoplay(self: *App, now_ms: u32) void {
        if (self.coordinator.screen != .reading or self.coordinator.mode != .rsvp) return;
        if (self.coordinator.rsvp_reader.autoplay(now_ms, &self.coordinator.pace)) |move| {
            self.coordinator.persistence.?.requestWrite(.pace, pace_debounce_frames);
            self.handleRsvpMove(move);
        }
    }

    fn stopRsvpAutoplay(self: *App, now_ms: u32) void {
        self.coordinator.rsvp_reader.stopAutoplay(now_ms, &self.coordinator.pace);
    }

    fn recordAutoplayInterval(self: *App, now_ms: u32, completed_words: u32) void {
        self.coordinator.rsvp_reader.recordAutoplay(now_ms, completed_words, &self.coordinator.pace);
        self.coordinator.persistence.?.requestWrite(.pace, pace_debounce_frames);
    }

    fn drawChapterError(self: *App) void {
        const reason: []const u8 = switch (self.coordinator.chapter_failure) {
            .archive => "ZIP or DEFLATE error",
            .tokenizer => "XHTML tokenizer error",
            .page_limit => "Page limit exceeded",
            .no_supported_text => "No supported text",
        };
        self.drawText("Chapter unavailable", 12, 12);
        self.drawText(reason, 12, 36);
        if (self.coordinator.chapter_index < self.coordinator.publication.spine_len) self.drawText(self.coordinator.publication.spine[self.coordinator.chapter_index].slice(), 12, 60);
        self.drawText("Left/Right: another chapter", 12, 100);
    }

    fn failChapter(self: *App, failure: ChapterFailure) void {
        self.coordinator.chapter_failure = failure;
        self.coordinator.paged.current_ready = false;
        self.coordinator.paged.next_ready = false;
        self.coordinator.chapter_end = true;
        self.coordinator.lifecycle = .chapter_error;
    }

    fn openAdjacentChapter(self: *App, direction: i8) void {
        const candidate: i16 = @as(i16, self.coordinator.chapter_index) + direction;
        if (candidate < 0 or candidate >= self.coordinator.publication.spine_len) return;
        self.scheduleOpenChapter(@intCast(candidate), .normal);
        self.coordinator.lifecycle = .ready;
    }

    /// Advances at most one archive phase or one bounded metadata output read.
    /// The OPF collector is intentionally a metadata-only exception; chapter
    /// content continues through the incremental reader pipeline.
    fn advanceOpeningJob(self: *App) void {
        self.coordinator.advanceOpening();
        if (self.coordinator.takeOpeningChapterRequest()) |chapter| {
            self.scheduleOpenChapter(chapter, .normal);
            self.restorePosition();
        }
    }

    fn closeOpeningFile(self: *App) void {
        if (self.opening_file) |*file| file.close();
        self.opening_file = null;
    }

    fn scheduleOpenChapter(self: *App, index: u8, action: ChapterOpenAction) void {
        self.coordinator.pending_prefetch_transition = null;
        self.cancelPrefetch();
        self.releaseActivePrefetchBacking();
        if (self.coordinator.decode_workspace.owner == .active) self.coordinator.decode_workspace.release(.active);
        if (self.chapter_file) |*file| file.close();
        self.chapter_file = null;
        self.coordinator.chapter_stream = null;
        self.coordinator.paged.builder = null;
        self.coordinator.chapter_open = .{ .index = index, .action = action };
        self.coordinator.paged.previous_ready = false;
        self.coordinator.paged.current_ready = false;
        self.coordinator.paged.next_ready = false;
        self.coordinator.paged.selected_word_ordinal = null;
        self.coordinator.chapter_end = false;
        self.coordinator.paged.chapter_end = false;
        self.coordinator.paged.cache_navigation = false;
    }

    fn cancelPrefetch(self: *App) void {
        self.coordinator.paged.prefetch.cancel();
        if (self.coordinator.decode_workspace.owner == .prefetch) self.coordinator.decode_workspace.release(.prefetch);
    }

    fn beginOpenedChapter(self: *App, archive: zip.Archive, index: u8, chapter_entry: zip.Entry) !void {
        if (self.coordinator.decode_workspace.beginActive() != .acquired) return error.DecodeWorkspaceBusy;
        self.coordinator.chapter_storage = zip.StreamStorage.init(&self.coordinator.deflate_input_buffer, &self.coordinator.deflate_window, &self.coordinator.deflate_workspace);
        self.coordinator.chapter_stream = archive.begin(chapter_entry, &self.coordinator.chapter_storage) catch |err| {
            self.coordinator.decode_workspace.release(.active);
            return err;
        };
        self.coordinator.chapter_index = index;
        self.coordinator.paged.begin(index, reader_text_width, .{ .context = self, .width = measureTextWidth });
        self.coordinator.chapter_end = false;
        self.coordinator.chapter_output_start = 0;
        self.coordinator.chapter_output_end = 0;
        self.coordinator.telemetry.chapterStarted(self.playdate.system.getCurrentTimeMilliseconds());
        if (self.coordinator.mode == .rsvp) {
            self.coordinator.paged.builder = null;
            self.coordinator.paged.extractor = null;
            self.coordinator.rsvp_reader.begin(index);
        }
    }

    fn advanceChapterJob(self: *App) void {
        if (self.advanceChapterOpenJob()) return;
        if (self.coordinator.lifecycle != .ready or self.coordinator.paged.next_ready or self.coordinator.chapter_end) return;
        // R02 has no navigation control yet: pause as soon as the first
        // complete word is available. R03 will explicitly resume this same
        // stream for each crank step, without a word queue.
        if (self.coordinator.mode == .rsvp and self.coordinator.rsvp_reader.hasWord()) return;
        // EntryStream refills a 1 KiB decoded chunk; tokenizer work remains
        // byte-budgeted so a page-full word can carry into the next page.
        var budget: usize = 256;
        while (budget != 0 and !self.coordinator.paged.next_ready and !self.coordinator.chapter_end) {
            if (self.coordinator.chapter_output_start != self.coordinator.chapter_output_end) {
                const available = self.coordinator.chapter_output[self.coordinator.chapter_output_start..self.coordinator.chapter_output_end];
                const input = available[0..if (self.coordinator.mode == .rsvp) 1 else @min(available.len, budget)];
                const progress = (if (self.coordinator.mode == .rsvp) self.coordinator.rsvp_reader.feed(input) else self.coordinator.paged.feed(input)) catch {
                    self.failChapter(.tokenizer);
                    return;
                };
                const consumed = switch (progress) {
                    .consumed => |count| count,
                    .page_full => |count| blk: {
                        self.pageCompleted();
                        break :blk count;
                    },
                };
                self.coordinator.chapter_output_start += consumed;
                budget -= consumed;
                if (self.coordinator.mode == .rsvp and self.coordinator.rsvp_reader.hasWord()) {
                    self.coordinator.telemetry.setChapterEvents(self.coordinator.rsvp_reader.event_count);
                    if (self.coordinator.pending_mode_word_ordinal == self.coordinator.rsvp_reader.position().word) self.coordinator.pending_mode_word_ordinal = null;
                    self.coordinator.rsvp_reader.wordBecameDrawable(self.playdate.system.getCurrentTimeMilliseconds());
                    self.savePosition();
                    return;
                }
                continue;
            }
            const stream = &self.coordinator.chapter_stream.?;
            const output = self.coordinator.chapter_output[0..@min(self.coordinator.chapter_output.len, budget)];
            const result = stream.read(output) catch {
                self.failChapter(.archive);
                return;
            };
            switch (result) {
                .bytes => |count| {
                    self.coordinator.telemetry.decodedBytes(count);
                    self.coordinator.chapter_output_start = 0;
                    self.coordinator.chapter_output_end = count;
                },
                .end => {
                    if (self.coordinator.mode != .rsvp) {
                        self.coordinator.paged.finishInput() catch {
                            self.failChapter(.tokenizer);
                            return;
                        };
                    }
                    if (self.coordinator.mode == .rsvp) {
                        self.coordinator.rsvp_reader.finishInput() catch {
                            self.failChapter(.tokenizer);
                            return;
                        };
                        self.coordinator.chapter_end = true;
                        stream.finish() catch {
                            self.failChapter(.archive);
                            return;
                        };
                        self.coordinator.telemetry.setChapterEvents(self.coordinator.rsvp_reader.event_count);
                        if (self.coordinator.rsvp_reader.hasWord()) {
                            if (self.coordinator.pending_mode_word_ordinal == self.coordinator.rsvp_reader.position().word) self.coordinator.pending_mode_word_ordinal = null;
                            self.coordinator.rsvp_reader.wordBecameDrawable(self.playdate.system.getCurrentTimeMilliseconds());
                            self.savePosition();
                        }
                        // R05 owns the actual chapter transition. Keep the
                        // final displayed word visible at a verified EOF.
                        if (self.coordinator.rsvp_reader.targetUnresolved()) {
                            self.failChapter(.page_limit);
                        } else if (!self.coordinator.rsvp_reader.hasWord()) {
                            if (nextReadableSpineIndex(self.coordinator.chapter_index, self.coordinator.publication.spine_len)) |next| {
                                self.scheduleOpenChapter(next, .normal);
                            } else self.failChapter(.no_supported_text);
                        }
                        return;
                    }
                    self.coordinator.paged.builderPtr().?.end() catch |err| {
                        if (err == error.PageFull) self.pageCompleted() else self.failChapter(.page_limit);
                        return;
                    };
                    self.coordinator.chapter_end = true;
                    self.coordinator.paged.chapter_end = true;
                    if (self.coordinator.paged.finishChapter() == .at_limit) {
                        self.failChapter(.page_limit);
                        return;
                    }
                    stream.finish() catch {
                        self.failChapter(.archive);
                        return;
                    };
                    self.coordinator.decode_workspace.markActiveVerifiedEof();
                    if (self.coordinator.chapter_end and !self.coordinator.paged.isRescanning() and !self.coordinator.paged.current_ready and !self.coordinator.paged.next_ready) {
                        if (nextReadableSpineIndex(self.coordinator.chapter_index, self.coordinator.publication.spine_len)) |next| {
                            self.scheduleOpenChapter(next, .normal);
                        } else {
                            self.failChapter(.no_supported_text);
                        }
                        return;
                    }
                    if (self.coordinator.chapter_end and !self.coordinator.paged.isRescanning()) {
                        self.schedulePrefetch();
                    }
                },
                .needs_input => self.failChapter(.archive),
            }
        }
    }

    /// Starts finding the next spine entry only after the current stream has
    /// reached a verified end. At that point the DEFLATE buffers are idle, and
    /// the previous-page slot can be reused without adding a fourth page.
    fn schedulePrefetch(self: *App) void {
        if (!self.coordinator.paged.next_ready or self.coordinator.chapter_index + 1 >= self.coordinator.publication.spine_len or self.coordinator.paged.prefetch.isPrefetching()) return;
        if (self.coordinator.decode_workspace.beginPrefetch() != .acquired) return;
        // An activated prefetch keeps its file in `prefetch_file`: the ZIP
        // reader embedded in its EntryStream points at that stable field.
        // At verified EOF it is safe to close it before opening the next one.
        self.releaseActivePrefetchBacking();
        if (self.chapter_file) |*file| file.close();
        self.chapter_file = null;
        self.coordinator.paged.previous_ready = false;
        self.prefetch_file = PlaydateFileReader.open(self.playdate.file, self.coordinator.active_book.zSlice()) catch {
            self.cancelPrefetch();
            return;
        };
        self.coordinator.paged.prefetch.attachFile(.{ .context = self, .close = closePrefetchFileLease });
        self.coordinator.paged.prefetch.startLookup(self.coordinator.chapter_index + 1, self.prefetch_file.?.reader()) catch {
            self.cancelPrefetch();
        };
    }

    /// Prefetches exactly one drawable page. It has its own file and ZIP
    /// state, but deliberately shares the now-idle DEFLATE backing buffers
    /// with the completed current chapter.
    fn advancePrefetchJob(self: *App) void {
        if (self.coordinator.paged.prefetch.state == .looking_up) {
            switch (self.coordinator.paged.prefetch.stepLookup(&self.coordinator.prefetch_scan_buffer, &self.coordinator.prefetch_filename_buffer, self.coordinator.publication.spine[self.coordinator.chapter_index + 1].slice(), prefetch_directory_records_per_update)) {
                .working => return,
                .missing, .failed => {
                    self.cancelPrefetch();
                    self.openPendingPrefetchTransition();
                    return;
                },
                .found => |found| {
                    const page = self.coordinator.paged.previous_page;
                    self.coordinator.paged.pages[page].clear();
                    self.coordinator.paged.prefetch.begin(
                        found.archive,
                        found.entry,
                        found.chapter,
                        page,
                        &self.coordinator.paged.pages[page],
                        &self.coordinator.deflate_input_buffer,
                        &self.coordinator.deflate_window,
                        &self.coordinator.deflate_workspace,
                        reader_text_width,
                        .{ .context = self, .width = measureTextWidth },
                    ) catch {
                        self.cancelPrefetch();
                        return;
                    };
                },
            }
        }
        if (!self.coordinator.paged.prefetch.isPrefetching()) return;
        switch (self.coordinator.paged.prefetch.step(&self.coordinator.chapter_output, prefetch_byte_budget)) {
            .working => {},
            .ready => if (self.coordinator.pending_prefetch_transition != null) self.activatePrefetchedChapter(),
            .failed => {
                self.cancelPrefetch();
                self.openPendingPrefetchTransition();
            },
        }
    }

    fn activatePrefetchedChapter(self: *App) void {
        const prepared = self.coordinator.paged.prefetch.activate() orelse return;
        self.coordinator.pending_prefetch_transition = null;
        self.coordinator.decode_workspace.activatePrefetch();
        if (self.chapter_file) |*file| file.close();
        self.chapter_file = null;
        // Do not move `prefetch_file`: `EntryStream`'s ZIP reader retained a
        // pointer to this exact optional field when the session began.
        self.coordinator.paged.prefetch.detachFile();
        self.coordinator.chapter_stream = self.coordinator.paged.prefetch.stream;
        self.coordinator.paged.builder = self.coordinator.paged.prefetch.builder;
        self.coordinator.paged.adoptExtractor(self.coordinator.paged.prefetch.extractor.?);
        self.coordinator.chapter_output_start = self.coordinator.paged.prefetch.output_start;
        self.coordinator.chapter_output_end = self.coordinator.paged.prefetch.output_end;
        self.coordinator.chapter_index = prepared.chapter;
        self.coordinator.paged.chapter_index = prepared.chapter;
        self.coordinator.paged.page_index = 0;
        self.coordinator.paged.current_page = prepared.page;
        self.coordinator.paged.current_ready = true;
        self.coordinator.paged.selected_word_ordinal = null;
        self.coordinator.paged.previous_ready = false;
        self.coordinator.paged.next_page = self.coordinator.paged.freePage();
        self.coordinator.paged.next_ready = false;
        self.coordinator.paged.build = .{ .building = self.coordinator.paged.next_page };
        self.coordinator.paged.builderPtr().?.beginNextPage(&self.coordinator.paged.pages[self.coordinator.paged.next_page]);
        self.coordinator.chapter_end = prepared.ended;
        self.coordinator.paged.chapter_end = prepared.ended;
        self.coordinator.paged.chapter_last_page = if (prepared.ended) 0 else null;
        self.coordinator.paged.cache_navigation = false;
        self.coordinator.paged.stream_front_page = 0;
        self.coordinator.paged.navigation_state.opened(0);
        self.recordCheckpoint(0);
    }

    /// Activated prefetch streams retain a ZIP reader whose context points to
    /// `prefetch_file`. Close that backing only after the stream is no longer
    /// needed, never by moving the value into `chapter_file`.
    fn releaseActivePrefetchBacking(self: *App) void {
        if (self.coordinator.paged.prefetch.state != .active) return;
        if (self.prefetch_file) |*file| file.close();
        self.prefetch_file = null;
        self.coordinator.paged.prefetch.releaseActive();
    }

    /// If the prefetch cannot finish, retain the established normal-open
    /// behavior rather than leaving a boundary request stranded forever.
    fn openPendingPrefetchTransition(self: *App) void {
        const index = self.coordinator.pending_prefetch_transition orelse return;
        self.coordinator.pending_prefetch_transition = null;
        if (index < self.coordinator.publication.spine_len and index == self.coordinator.chapter_index + 1) self.scheduleOpenChapter(index, .normal);
    }

    /// Performs at most one file/archive phase per frame. The scanner and
    /// finder each read a bounded amount of data; decompression starts only
    /// after both have completed.
    fn advanceChapterOpenJob(self: *App) bool {
        if (self.coordinator.chapter_open == null) return false;
        const job = &self.coordinator.chapter_open.?;
        const directory_index = self.coordinator.archive_index orelse {
            self.coordinator.chapter_open = null;
            self.failChapter(.archive);
            return true;
        };
        const chapter_entry = directory_index.find(self.coordinator.publication.spine[job.index].slice()) catch {
            self.coordinator.chapter_open = null;
            self.failChapter(.archive);
            return true;
        };
        const index = job.index;
        const action = job.action;
        const archive = self.coordinator.archive_index.?.archive;
        self.coordinator.chapter_open = null;
        self.beginOpenedChapter(archive, index, chapter_entry) catch {
            self.failChapter(.archive);
            return true;
        };
        switch (action) {
            .normal => {},
            .rescan => |target| self.beginRescan(target),
            .word_rescan => |target| self.coordinator.paged.pending_selection = .{ .ordinal = target },
            .rsvp_rescan => |target| self.coordinator.rsvp_reader.reconstruct(target),
            .rescan_to_last_page => self.coordinator.paged.beginRescanToLastPage(),
        }
        return true;
    }

    fn pageCompleted(self: *App) void {
        self.recordPageBuild();
        self.coordinator.paged.pageCompleted(self.coordinator.telemetry.chapter_events, self.coordinator.paged.sourceOffset());
    }

    fn drawTelemetry(self: *App) void {
        const snapshot = self.coordinator.telemetry.snapshot();
        var line_buffer: [96]u8 = undefined;
        const stats = self.allocator.stats;
        const line = std.fmt.bufPrintZ(
            &line_buffer,
            "a:{d} f:{d} live:{d} peak:{d}",
            .{ stats.allocations, stats.frees, stats.live_bytes, stats.peak_live_bytes },
        ) catch return;
        self.renderer.text(line, 20, 190);
        const pipeline = std.fmt.bufPrintZ(
            &line_buffer,
            "z:{d} e:{d} p:{d}/{d} page:{d}",
            .{ snapshot.chapter_bytes_decoded, snapshot.chapter_events, snapshot.last_page_build_ms, snapshot.max_page_build_ms, page_pool_reserved_bytes },
        ) catch return;
        self.renderer.text(pipeline, 20, 210);
    }

    fn drawText(self: *App, text: []const u8, x: c_int, y: c_int) void {
        self.renderer.text(text, x, y);
    }

    fn textWidth(self: *const App, text: []const u8) c_int {
        return self.renderer.textWidth(text);
    }

    fn drawNumber(self: *App, value: u8, x: c_int, y: c_int) void {
        var buffer: [4]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return;
        self.drawText(text, x, y);
    }

    fn nextPage(self: *App) void {
        if (self.coordinator.lifecycle != .ready or self.coordinator.chapter_open != null) return;
        self.handlePagedMove(self.coordinator.paged.nextPage());
        self.savePosition();
    }

    /// The engine reports semantic work outcomes. The façade adapts chapter
    /// opening and prefetch activation to platform-owned file handles.
    fn handlePagedMove(self: *App, move: paged_reader.PagedReader.Move) void {
        switch (move) {
            .needs_reconstruction => self.startRescan(self.coordinator.paged.navigation_state.page),
            .needs_previous_chapter => if (self.coordinator.chapter_index != 0) self.startRescanToLastPage(self.coordinator.chapter_index - 1),
            .needs_next_chapter => {
                if (self.coordinator.chapter_index + 1 >= self.coordinator.publication.spine_len) return;
                const next = self.coordinator.chapter_index + 1;
                switch (chapterTransitionDisposition(self.coordinator.paged.prefetch.isReady(), self.coordinator.paged.prefetch.isPrefetching())) {
                    .activate => self.activatePrefetchedChapter(),
                    .wait_for_prefetch => self.coordinator.pending_prefetch_transition = next,
                    .open => self.scheduleOpenChapter(next, .normal),
                }
            },
            .moved, .waiting, .at_limit => {},
        }
    }

    const PagedSelectionMove = enum { advanced, waiting_for_page, at_limit };

    fn drainPagedDetents(self: *App) void {
        while (self.coordinator.paged.detent_backlog != 0) {
            if (self.coordinator.paged.pending_selection != null) return;
            const direction: i8 = if (self.coordinator.paged.detent_backlog > 0) 1 else -1;
            switch (self.movePagedSelection(direction)) {
                .advanced => self.coordinator.paged.detent_backlog -= direction,
                .waiting_for_page => return,
                .at_limit => {
                    self.coordinator.paged.detent_backlog = 0;
                    return;
                },
            }
        }
    }

    fn movePagedSelection(self: *App, direction: i8) PagedSelectionMove {
        const move = self.coordinator.paged.moveSelection(direction, self.coordinator.chapter_index != 0, self.coordinator.chapter_index + 1 < self.coordinator.publication.spine_len);
        self.handlePagedMove(move);
        switch (move) {
            .moved => {
                self.fulfillPendingPagedSelection();
                if (self.coordinator.paged.pending_selection == null) {
                    self.savePosition();
                    return .advanced;
                }
                return .waiting_for_page;
            },
            .at_limit => return .at_limit,
            .waiting, .needs_reconstruction, .needs_previous_chapter, .needs_next_chapter => return .waiting_for_page,
        }
    }

    fn currentPagedWordOrdinal(self: *const App) u32 {
        if (!self.coordinator.paged.current_ready) return self.coordinator.paged.selected_word_ordinal orelse 0;
        const page = &self.coordinator.paged.pages[self.coordinator.paged.current_page];
        return page.moveSelection(self.coordinator.paged.selected_word_ordinal, 0) orelse 0;
    }

    /// Resolve a boundary crank only when the existing page stream, retained
    /// history, or chapter rebuild has made its requested page drawable.
    fn fulfillPendingPagedSelection(self: *App) void {
        if (self.coordinator.mode != .paged or !self.coordinator.paged.current_ready) return;
        if (!self.coordinator.paged.fulfillPendingSelection()) return;
        if (self.coordinator.pending_mode_word_ordinal == self.coordinator.paged.selected_word_ordinal) self.coordinator.pending_mode_word_ordinal = null;
        self.savePosition();
    }

    fn previousPage(self: *App) void {
        if (self.coordinator.lifecycle != .ready or self.coordinator.chapter_open != null) return;
        self.handlePagedMove(self.coordinator.paged.previousPage());
    }

    fn nextRsvpWord(self: *App) void {
        if (self.coordinator.lifecycle != .ready or self.coordinator.chapter_open != null) return;
        self.handleRsvpMove(self.coordinator.rsvp_reader.nextWord());
    }

    fn previousRsvpWord(self: *App) void {
        if (self.coordinator.lifecycle != .ready or self.coordinator.chapter_open != null) return;
        self.handleRsvpMove(self.coordinator.rsvp_reader.previousWord());
    }

    fn previousRsvpSentence(self: *App) void {
        if (self.coordinator.lifecycle != .ready or self.coordinator.chapter_open != null) return;
        const now_ms = self.playdate.system.getCurrentTimeMilliseconds();
        self.recordAutoplayInterval(now_ms, 0);
        self.coordinator.rsvp_reader.timer.reset(now_ms);
        self.handleRsvpMove(self.coordinator.rsvp_reader.previousSentence());
    }

    fn handleRsvpMove(self: *App, move: rsvp_reader.RsvpReader.Move) void {
        switch (move) {
            .moved => self.savePosition(),
            .needs_word, .waiting, .at_limit => {},
            .needs_rescan => |target| self.scheduleOpenChapter(self.coordinator.chapter_index, .{ .rsvp_rescan = target }),
            .needs_next_chapter => if (nextReadableSpineIndex(self.coordinator.chapter_index, self.coordinator.publication.spine_len)) |next| self.scheduleOpenChapter(next, .normal),
        }
    }

    fn startRescan(self: *App, target: u32) void {
        self.scheduleOpenChapter(self.coordinator.chapter_index, .{ .rescan = target });
    }

    fn beginRescan(self: *App, target: u32) void {
        self.coordinator.paged.beginRescan(target);
    }

    fn startRescanToLastPage(self: *App, chapter: u8) void {
        self.scheduleOpenChapter(chapter, .rescan_to_last_page);
    }

    fn recordPageBuild(self: *App) void {
        self.coordinator.telemetry.pageCompleted(self.playdate.system.getCurrentTimeMilliseconds());
    }

    fn recordCheckpoint(self: *App, page: u32) void {
        self.coordinator.paged.recordCheckpoint(page, self.coordinator.telemetry.chapter_events, self.coordinator.paged.sourceOffset());
    }

    fn drawPage(self: *App) void {
        const render = self.coordinator.paged.renderState();
        const page = render.page orelse {
            self.drawText("Loading chapter...", 12, 12);
            return;
        };
        for (0..page.line_count) |index| {
            self.drawText(
                page.line(index),
                reader_text_x,
                reader_text_y + @as(c_int, @intCast(index)) * reader_line_height,
            );
        }
        const selected = page.moveSelection(render.selected_word_ordinal, 0) orelse return;
        self.coordinator.paged.selected_word_ordinal = selected;
        const span = page.wordSpan(selected) orelse return;
        const line = page.line(span.line_index);
        const x = reader_text_x + self.textWidth(line[0..span.start]);
        const y = reader_text_y + @as(c_int, span.line_index) * reader_line_height;
        const word = line[span.start..span.end];
        const width = self.textWidth(word);
        self.renderer.invertedText(word, x, y, width, reader_line_height);
    }

    fn restorePosition(self: *App) void {
        if (self.coordinator.lifecycle != .ready) return;
        const restored = self.coordinator.persistence.?.loadPosition(self.bookIdentity(), layout_revision) orelse return;
        switch (restored) {
            .legacy_paged_page => |legacy| {
                if (legacy.chapter >= self.coordinator.publication.spine_len) return;
                const chapter: u8 = @intCast(legacy.chapter);
                // Legacy Paged offsets have no word equivalent. Preserve their
                // existing page rebuild behavior when opening Paged mode; an RSVP
                // preference still gets the same safe chapter fallback.
                if (self.coordinator.mode == .paged) self.scheduleOpenChapter(chapter, if (legacy.page == 0) .normal else .{ .rescan = legacy.page }) else self.scheduleOpenChapter(chapter, .normal);
            },
            .snapshot => |snapshot| {
                if (snapshot.chapter >= self.coordinator.publication.spine_len) return;
                const chapter: u8 = @intCast(snapshot.chapter);
                self.coordinator.pending_mode_word_ordinal = snapshot.word_ordinal;
                switch (self.coordinator.mode) {
                    .paged => {
                        self.coordinator.paged.pending_selection = .{ .ordinal = snapshot.word_ordinal };
                        self.scheduleOpenChapter(chapter, .{ .word_rescan = snapshot.word_ordinal });
                    },
                    .rsvp => self.scheduleOpenChapter(chapter, .{ .rsvp_rescan = .{ .word = snapshot.word_ordinal } }),
                }
            },
        }
    }

    fn savePosition(self: *App) void {
        if (self.coordinator.lifecycle != .ready) return;
        self.coordinator.persistence.?.requestWrite(.position, resume_debounce_frames);
    }

    fn flushDebouncedPosition(self: *App) void {
        if (self.coordinator.lifecycle == .ready) _ = self.coordinator.persistence.?.flushPositionIfDue(self.positionSnapshot());
    }

    fn loadPace(self: *App) void {
        self.coordinator.pace = self.coordinator.persistence.?.loadPace(self.bookIdentity());
    }

    fn flushDebouncedPace(self: *App) void {
        _ = self.coordinator.persistence.?.flushPaceIfDue(self.coordinator.pace);
    }

    fn writePace(self: *App) void {
        _ = self.coordinator.persistence.?.flushPendingPace(self.coordinator.pace);
    }

    fn writePosition(self: *App) void {
        _ = self.coordinator.persistence.?.flushPositionNow(self.positionSnapshot());
    }

    fn positionSnapshot(self: *const App) persistence.ReadingSnapshot {
        return .{
            .book_id = self.bookIdentity(),
            .layout_revision = layout_revision,
            .chapter = self.coordinator.chapter_index,
            .word_ordinal = self.coordinator.pending_mode_word_ordinal orelse if (self.coordinator.mode == .rsvp) self.coordinator.rsvp_reader.position().word else self.currentPagedWordOrdinal(),
            .mode = self.resumeMode(),
        };
    }

    fn bookIdentity(self: *const App) u32 {
        return persistence.Service.bookIdentity(self.coordinator.active_book.slice());
    }

    fn resumeMode(self: *const App) reading_state.Mode {
        return if (self.coordinator.mode == .rsvp) .rsvp else .paged;
    }
};

fn openReaderFile(context: *anyopaque, slot: reader_host.FileSlot, path: [:0]const u8) reader_host.FileError!zip.Reader {
    const app: *App = @ptrCast(@alignCast(context));
    closeReaderFile(context, slot);
    const opened = PlaydateFileReader.open(app.playdate.file, path) catch return error.OpenFailed;
    switch (slot) {
        .opening => app.opening_file = opened,
        .chapter => app.chapter_file = opened,
        .prefetch => app.prefetch_file = opened,
    }
    return switch (slot) {
        .opening => if (app.opening_file) |*file| file.reader() else unreachable,
        .chapter => if (app.chapter_file) |*file| file.reader() else unreachable,
        .prefetch => if (app.prefetch_file) |*file| file.reader() else unreachable,
    };
}

fn closeReaderFile(context: *anyopaque, slot: reader_host.FileSlot) void {
    const app: *App = @ptrCast(@alignCast(context));
    switch (slot) {
        .opening => app.closeOpeningFile(),
        .chapter => {
            if (app.chapter_file) |*file| file.close();
            app.chapter_file = null;
        },
        .prefetch => {
            if (app.prefetch_file) |*file| file.close();
            app.prefetch_file = null;
        },
    }
}

fn listEpubs(context: *anyopaque, library: *reader_host.Library) void {
    const app: *App = @ptrCast(@alignCast(context));
    _ = app.playdate.file.listfiles("", collectLibraryPath, library, 0);
}

fn closePrefetchFileLease(context: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context));
    if (app.prefetch_file) |*file| file.close();
    app.prefetch_file = null;
}

fn measureTextWidth(context: *anyopaque, text: []const u8) usize {
    const app: *App = @ptrCast(@alignCast(context));
    return @intCast(app.textWidth(text));
}

/// Accumulates physical crank motion until it crosses one reading detent.
/// The caller rate-limits the returned direction; no navigation work happens
/// here, which keeps this unit-testable without Playdate APIs.
fn crankDirection(accumulated: *f32, change: f32) i8 {
    accumulated.* += change;
    if (accumulated.* >= crank_degrees_per_page) {
        accumulated.* -= crank_degrees_per_page;
        return 1;
    }
    if (accumulated.* <= -crank_degrees_per_page) {
        accumulated.* += crank_degrees_per_page;
        return -1;
    }
    return 0;
}

/// Converts all currently accumulated crank motion into reader detents. Paged
/// selection consumes the complete result in one update, avoiding a visual
/// replay after the user has already stopped turning the crank.
fn crankDetents(accumulated: *f32, change: f32) i16 {
    accumulated.* += change;
    var detents: i16 = 0;
    while (accumulated.* >= crank_degrees_per_page and detents != std.math.maxInt(i16)) {
        accumulated.* -= crank_degrees_per_page;
        detents += 1;
    }
    while (accumulated.* <= -crank_degrees_per_page and detents != std.math.minInt(i16)) {
        accumulated.* += crank_degrees_per_page;
        detents -= 1;
    }
    return detents;
}

fn saturatingAddDetents(existing: i16, incoming: i16) i16 {
    const total: i32 = @as(i32, existing) + @as(i32, incoming);
    return @intCast(@max(@as(i32, std.math.minInt(i16)), @min(@as(i32, std.math.maxInt(i16)), total)));
}

/// During a page-crossing crank turn, the visible page can still contain the
/// former selection while the already-known successor ordinal waits for its
/// next page. A mode switch must preserve that semantic destination rather
/// than clearing it and handing RSVP the prior word.
fn pagedModeSwitchOrdinal(current: u32, pending: ?PagedSelectionTarget) u32 {
    return reader_transitions.pagedModeSwitchOrdinal(current, pending);
}

/// Once a requested ordinal lies at or beyond the next ready page's start,
/// advance that page even when it is only an intermediate rebuild page. The
/// next update will construct another page if necessary.
fn pendingOrdinalRequiresNextPage(page: *const pagination.PageCache, ordinal: u32) bool {
    return page.word_count == 0 or ordinal >= page.first_word_ordinal;
}

fn nextReadableSpineIndex(current: u8, spine_len: u8) ?u8 {
    return reader_transitions.adjacentChapter(current, spine_len, 1);
}

/// Maps a pushed-button bitset to exactly one action. B has priority while
/// reading, so a diagonal press cannot turn a page instead of changing modes.
fn inputAction(state: State, lifecycle: Lifecycle, reading_mode: reader_coordinator.ReadingMode, pushed: pdapi.PDButtons) InputAction {
    return reader_coordinator.intentFor(inputSnapshot(state, lifecycle, reading_mode, pushed));
}

fn inputSnapshot(state: State, lifecycle: Lifecycle, reading_mode: reader_coordinator.ReadingMode, pushed: pdapi.PDButtons) reader_coordinator.InputSnapshot {
    return .{
        .screen = state,
        .readiness = if (lifecycle == .chapter_error) .chapter_error else .ready,
        .mode = reading_mode,
        .buttons = .{
            .a = pushed & pdapi.BUTTON_A != 0,
            .b = pushed & pdapi.BUTTON_B != 0,
            .up = pushed & pdapi.BUTTON_UP != 0,
            .down = pushed & pdapi.BUTTON_DOWN != 0,
            .left = pushed & pdapi.BUTTON_LEFT != 0,
            .right = pushed & pdapi.BUTTON_RIGHT != 0,
        },
    };
}

/// Playdate adapter for intents selected by ReaderCoordinator. It deliberately
/// contains no button-priority or screen-transition policy.
fn cancelActiveReading(context: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context));
    app.returnToLibrary();
}

fn advanceOpeningWork(context: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context));
    app.advanceOpeningJob();
}

fn advanceChapterWork(context: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context));
    app.advanceChapterJob();
}

fn fulfillPagedSelectionWork(context: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context));
    app.fulfillPendingPagedSelection();
}

fn drainPagedDetentsWork(context: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context));
    app.drainPagedDetents();
}

fn advancePrefetchWork(context: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context));
    app.advancePrefetchJob();
}

fn flushPersistenceWork(context: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context));
    app.flushDebouncedPosition();
    app.flushDebouncedPace();
}

fn performReaderIntent(context: *anyopaque, intent: InputAction, now_ms: u32) void {
    const app: *App = @ptrCast(@alignCast(context));
    switch (intent) {
        .none, .return_to_library, .close_settings => {},
        .library_next => app.coordinator.library.move(1),
        .library_previous => app.coordinator.library.move(-1),
        .open_selected_book => app.openSelectedBook(),
        .close_chapter_browser => app.closeChapterBrowser(),
        .chapter_browser_next => app.coordinator.chapter_browser.move(1),
        .chapter_browser_previous => app.coordinator.chapter_browser.move(-1),
        .open_browser_chapter => app.openBrowserChapter(),
        .settings_next => app.moveSettingsSelection(1),
        .settings_previous => app.moveSettingsSelection(-1),
        .activate_setting => app.activateSetting(),
        .toggle_reading_mode => app.toggleReadingMode(),
        .rsvp_toggle_autoplay => app.toggleRsvpAutoplay(now_ms),
        .rsvp_wpm_up => app.adjustRsvpWpm(1, now_ms),
        .rsvp_wpm_down => app.adjustRsvpWpm(-1, now_ms),
        .rsvp_previous_sentence => app.previousRsvpSentence(),
        .next_page => {
            app.coordinator.paged.pending_selection = null;
            app.nextPage();
        },
        .previous_page => {
            app.coordinator.paged.pending_selection = null;
            app.previousPage();
        },
        .next_chapter => app.openAdjacentChapter(1),
        .previous_chapter => app.openAdjacentChapter(-1),
    }
}

fn settingsMenuSelected(userdata: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(userdata orelse return));
    app.openSettings();
}

fn libraryMenuSelected(userdata: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(userdata orelse return));
    app.returnToLibrary();
}

fn chaptersMenuSelected(userdata: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(userdata orelse return));
    app.openChapterBrowser();
}

fn collectLibraryPath(path: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
    const library: *reader_host.Library = @ptrCast(@alignCast(userdata orelse return));
    const z_path = path orelse return;
    library.add(std.mem.span(z_path));
}
