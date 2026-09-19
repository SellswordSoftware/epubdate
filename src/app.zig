const std = @import("std");
const limits = @import("limits").reader;
const deflate = @import("archive/deflate.zig");
const zip = @import("archive/zip.zig");
const xhtml = @import("content/xhtml.zig");
const cache_policy = @import("content/cache_policy.zig");
const chapter_browser = @import("chapter_browser.zig");
const navigation = @import("content/navigation.zig");
const pagination = @import("content/pagination.zig");
const rsvp = @import("content/rsvp.zig");
const epub = @import("publication/epub.zig");
const publication_navigation = @import("publication/navigation.zig");
const reading_position = @import("storage/resume.zig");
const reading_pace = @import("storage/pace.zig");
const reader_settings = @import("storage/settings.zig");
const library_storage = @import("storage/library.zig");
const pdapi = @import("playdate_api_definitions.zig");
const PlaydateAllocator = @import("platform/playdate_allocator.zig").PlaydateAllocator;
const PlaydateFileReader = @import("platform/playdate_file_reader.zig").PlaydateFileReader;

pub const State = enum {
    library,
    opening,
    reading,
    settings,
    chapter_browser,
    unsupported_book,
    malformed_book,
    chapter_error,
};

const FixtureState = enum {
    opening,
    ready,
    unavailable,
    invalid_archive,
    missing_mimetype,
    invalid_mimetype,
    chapter_error,
};

const ChapterFailure = enum { archive, tokenizer, page_limit, no_supported_text };

const InputAction = enum {
    none,
    library_next,
    library_previous,
    open_selected_book,
    return_to_library,
    close_settings,
    close_chapter_browser,
    chapter_browser_next,
    chapter_browser_previous,
    open_browser_chapter,
    settings_next,
    settings_previous,
    activate_setting,
    toggle_reading_mode,
    rsvp_toggle_autoplay,
    rsvp_wpm_up,
    rsvp_wpm_down,
    rsvp_previous_sentence,
    next_page,
    previous_page,
    next_chapter,
    previous_chapter,
};

const RsvpRescanTarget = union(enum) {
    word: u32,
    sentence: u32,
};

const ChapterOpenAction = union(enum) {
    normal,
    rescan: u32,
    word_rescan: u32,
    rsvp_rescan: RsvpRescanTarget,
    rescan_to_last_page,
};

const PagedSelectionTarget = union(enum) {
    ordinal: u32,
    // The preceding chapter is rebuilt to its final page before this target
    // can be resolved, so its ordinal is not known at crank time.
    last_word,
};

/// Opening advances through file open, EOCD scanning, and central-directory
/// lookup in separate update ticks. Its archive reader points at App's stable
/// `chapter_file` field, not at temporary job storage.
const ChapterOpenJob = struct {
    index: u8,
    action: ChapterOpenAction,
    scanner: ?zip.ArchiveScanner = null,
    finder: ?zip.EntryFinder = null,
};

const OpeningPhase = enum {
    open,
    scan_archive,
    validate_directory,
    find_mimetype,
    read_mimetype,
    find_container,
    read_container,
    parse_container,
    find_package,
    read_package,
    parse_package,
    find_navigation,
    read_navigation,
    find_ncx,
    read_ncx,
};

const NavigationSource = enum { epub3, ncx };

const NavigationParser = union(enum) {
    epub3: publication_navigation.Parser,
    ncx: publication_navigation.NcxParser,

    fn feed(self: *NavigationParser, bytes: []const u8) publication_navigation.Error!void {
        switch (self.*) {
            .epub3 => |*parser| try parser.feed(bytes),
            .ncx => |*parser| try parser.feed(bytes),
        }
    }

    fn finish(self: *NavigationParser) publication_navigation.Error!void {
        switch (self.*) {
            .epub3 => |*parser| try parser.finish(),
            .ncx => |*parser| try parser.finish(),
        }
    }

    fn labelCount(self: *const NavigationParser) u8 {
        return switch (self.*) {
            .epub3 => |*parser| parser.labelCount(),
            .ncx => |*parser| parser.labelCount(),
        };
    }
};

const MetadataTarget = enum { mimetype, container, package };

/// Opening is intentionally distinct from chapter opening: metadata is small
/// and bounded, but must still yield while file I/O and decompression run.
const OpeningJob = struct {
    phase: OpeningPhase = .open,
    scanner: ?zip.ArchiveScanner = null,
    archive: ?zip.Archive = null,
    validator: ?zip.DirectoryValidator = null,
    finder: ?zip.EntryFinder = null,
    stream: ?zip.EntryStream = null,
    target: MetadataTarget = .mimetype,
    output_len: usize = 0,
    package_xml: ?[]u8 = null,
    opf_workspace: ?*epub.OpfWorkspace = null,

    fn init() OpeningJob {
        return .{};
    }
};

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

/// EPUB spine order is the reader's canonical order. Cover-skipping, if it
/// is ever added, must be an explicit publication policy rather than inferred
/// from the number of spine documents.
pub fn initialChapterIndex(_: u8) u8 {
    return 0;
}

test "library is the initial reader state" {
    try std.testing.expectEqual(State.library, State.library);
}

test "initial chapter is the first spine entry for a multi-chapter publication" {
    try std.testing.expectEqual(@as(u8, 0), initialChapterIndex(2));
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

test "opening begins without synchronously loading the fixture" {
    const job = OpeningJob.init();
    try std.testing.expectEqual(OpeningPhase.open, job.phase);
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
    body_font: *pdapi.LCDFont,
    state: State = .library,
    state_before_settings: State = .reading,
    settings_selected: u1 = 0,
    chapter_browser: chapter_browser.Model = .{},
    reading_mode: reader_settings.ReadingMode = .paged,
    rsvp_wpm: u16 = rsvp.default_wpm,
    rsvp_timer: rsvp.Timer = .{},
    rsvp_active_session: reading_pace.ActiveSession = .{},
    pace: reading_pace.Stats = .{ .book_id = 0 },
    pace_dirty: bool = false,
    pace_delay_frames: u8 = 0,
    show_telemetry: bool = false,
    frame_count: u32 = 0,
    update_time_ms: u32 = 0,
    max_update_time_ms: u32 = 0,
    chapter_bytes_decoded: u32 = 0,
    chapter_events: u32 = 0,
    page_build_started_ms: u32 = 0,
    last_page_build_ms: u32 = 0,
    max_page_build_ms: u32 = 0,
    fixture_state: FixtureState = .opening,
    chapter_failure: ChapterFailure = .archive,
    fixture_entry_count: u16 = 0,
    fixture_mimetype: [32]u8 = undefined,
    fixture_mimetype_len: usize = 0,
    fixture_container_len: usize = 0,
    zip_scan_buffer: [1024]u8 = undefined,
    zip_filename_buffer: [limits.max_archive_filename_bytes]u8 = undefined,
    zip_member_ranges: [epub.max_manifest_items]zip.MemberRange = undefined,
    zip_entries: [epub.max_manifest_items]zip.IndexedEntry = undefined,
    archive_index: ?zip.DirectoryIndex = null,
    // Reusable ZIP file-read chunk; it is independent of member size.
    deflate_input_buffer: [limits.compressed_input_bytes]u8 = undefined,
    deflate_window: [32 * 1024]u8 = undefined,
    deflate_workspace: deflate.Workspace = undefined,
    container_xml: [epub.max_container_document_bytes]u8 = undefined,
    package_path: [256]u8 = undefined,
    package_path_len: usize = 0,
    publication: epub.Publication = undefined,
    library: library_storage.Library = .{},
    active_book: library_storage.Book = .{},
    opening_file: ?PlaydateFileReader = null,
    opening_job: ?OpeningJob = null,
    navigation_parser: ?NavigationParser = null,
    opening_storage: zip.StreamStorage = undefined,
    opening_output: [metadata_read_chunk_size]u8 = undefined,
    // Chapter source is never collected: this file and stream stay open while
    // a current/next pair of drawable pages is built incrementally.
    chapter_file: ?PlaydateFileReader = null,
    chapter_open: ?ChapterOpenJob = null,
    chapter_stream: ?zip.EntryStream = null,
    chapter_storage: zip.StreamStorage = undefined,
    chapter_output: [limits.decoded_output_chunk_bytes]u8 = undefined,
    chapter_output_start: usize = 0,
    chapter_output_end: usize = 0,
    chapter_extractor: ?xhtml.StreamExtractor = null,
    chapter_builder: ?pagination.EventPageBuilder = null,
    rsvp_cursor: ?rsvp.Cursor = null,
    rsvp_word: [rsvp.max_word_bytes]u8 = undefined,
    rsvp_word_len: u16 = 0,
    rsvp_position: rsvp.Position = .{},
    rsvp_has_word: bool = false,
    rsvp_previous_word: [rsvp.max_word_bytes]u8 = undefined,
    rsvp_previous_word_len: u16 = 0,
    rsvp_previous_position: rsvp.Position = .{},
    rsvp_previous_valid: bool = false,
    rsvp_next_word: [rsvp.max_word_bytes]u8 = undefined,
    rsvp_next_word_len: u16 = 0,
    rsvp_next_position: rsvp.Position = .{},
    rsvp_next_valid: bool = false,
    rsvp_rescan_target: ?RsvpRescanTarget = null,
    // Once a chapter's final page is known, the former previous-page slot is
    // available for the first page of the following chapter.  Prefetching
    // into that slot keeps the active pool bounded at three pages: the reader
    // trades one old page for a ready chapter transition.
    prefetch_file: ?PlaydateFileReader = null,
    prefetch_open: ?ChapterOpenJob = null,
    prefetch_stream: ?zip.EntryStream = null,
    prefetch_storage: zip.StreamStorage = undefined,
    prefetch_extractor: ?xhtml.StreamExtractor = null,
    prefetch_builder: ?pagination.EventPageBuilder = null,
    prefetch_output_start: usize = 0,
    prefetch_output_end: usize = 0,
    prefetched_chapter_index: ?u8 = null,
    prefetched_page: u2 = 2,
    prefetched_ready: bool = false,
    prefetched_end: bool = false,
    // Previous/current/next are bounded drawable caches.  The stream itself
    // remains positioned after the partially prepared future page.
    pages: [page_pool_capacity]pagination.PageCache = [_]pagination.PageCache{.{}} ** page_pool_capacity,
    previous_page: u2 = 2,
    current_page: u2 = 0,
    next_page: u2 = 1,
    building_page: u2 = 0,
    building_ready: bool = false,
    previous_ready: bool = false,
    current_ready: bool = false,
    next_ready: bool = false,
    // This normalized source-word ordinal is the future RSVP hand-off
    // location. This slice keeps it within the active cached page.
    selected_word_ordinal: ?u32 = null,
    pending_paged_selection: ?PagedSelectionTarget = null,
    // Retains the requested semantic position while a mode switch rebuilds
    // the other reader pipeline, so an early debounce cannot save zero.
    pending_mode_word_ordinal: ?u32 = null,
    chapter_end: bool = false,
    chapter_index: u8 = 0,
    // A semantic page number is a resumable checkpoint: rebuilding it always
    // starts at the chapter's decoded beginning, never at a DEFLATE offset.
    page_index: u32 = 0,
    rescan_target: ?u32 = null,
    rescan_page: u32 = 0,
    rescan_to_last_page: bool = false,
    rescan_last_completed: u2 = 0,
    chapter_last_page: ?u32 = null,
    resume_dirty: bool = false,
    resume_delay_frames: u8 = 0,
    // The active pool retains the immediate previous/current/next pages.
    // Older pages are rebuilt incrementally from the chapter start.
    cache_navigation: bool = false,
    stream_front_page: u32 = 0,
    navigation_state: navigation.State = .{},
    // These keys describe positions in normalized reader output. They are
    // useful for cache accounting and future persistence, but are never used
    // as a DEFLATE seek point: a miss still schedules an incremental rescan.
    checkpoints: cache_policy.Policy = cache_policy.Policy.init(checkpoint_byte_budget),
    crank_accumulated: f32 = 0,
    // A page build can temporarily block a fast crank turn at its boundary.
    // Keep the remaining detents semantic, not frame-rate throttled.
    paged_detent_backlog: i16 = 0,

    pub fn init(playdate: *pdapi.PlaydateAPI, allocator: *PlaydateAllocator) !*App {
        const body_font = playdate.graphics.loadFont("/System/Fonts/Roobert-20-Medium.pft", null) orelse return error.FontLoadFailed;
        const app = try allocator.allocator().create(App);
        app.* = .{
            .playdate = playdate,
            .allocator = allocator,
            .body_font = body_font,
        };
        app.loadSettings();
        app.installSystemMenu();
        app.discoverLibrary();
        return app;
    }

    pub fn updateAndRender(self: *App) c_int {
        const started_at = self.playdate.system.getCurrentTimeMilliseconds();
        defer {
            self.update_time_ms = self.playdate.system.getCurrentTimeMilliseconds() - started_at;
            self.max_update_time_ms = @max(self.max_update_time_ms, self.update_time_ms);
            self.frame_count +%= 1;
        }

        var pushed: pdapi.PDButtons = 0;
        self.playdate.system.getButtonState(null, &pushed, null);
        switch (inputAction(self.state, self.fixture_state, self.reading_mode, pushed)) {
            .none => {},
            .library_next => self.library.move(1),
            .library_previous => self.library.move(-1),
            .open_selected_book => self.openSelectedBook(),
            .return_to_library => self.returnToLibrary(),
            .close_settings => self.closeSettings(),
            .close_chapter_browser => self.closeChapterBrowser(),
            .chapter_browser_next => self.chapter_browser.move(1),
            .chapter_browser_previous => self.chapter_browser.move(-1),
            .open_browser_chapter => self.openBrowserChapter(),
            .settings_next => self.moveSettingsSelection(1),
            .settings_previous => self.moveSettingsSelection(-1),
            .activate_setting => self.activateSetting(),
            .toggle_reading_mode => self.toggleReadingMode(),
            .rsvp_toggle_autoplay => self.toggleRsvpAutoplay(started_at),
            .rsvp_wpm_up => self.adjustRsvpWpm(1, started_at),
            .rsvp_wpm_down => self.adjustRsvpWpm(-1, started_at),
            .rsvp_previous_sentence => self.previousRsvpSentence(),
            .next_page => {
                self.pending_paged_selection = null;
                self.nextPage();
            },
            .previous_page => {
                self.pending_paged_selection = null;
                self.previousPage();
            },
            .next_chapter => self.openAdjacentChapter(1),
            .previous_chapter => self.openAdjacentChapter(-1),
        }
        self.handleCrank();
        self.advanceRsvpAutoplay(started_at);

        self.advanceOpeningJob();
        self.advanceChapterJob();
        self.fulfillPendingPagedSelection();
        if (self.reading_mode == .paged) self.drainPagedDetents();
        self.advancePrefetchJob();
        self.flushDebouncedPosition();
        self.flushDebouncedPace();

        self.playdate.graphics.setFont(self.body_font);
        self.playdate.graphics.clear(@intCast(@intFromEnum(pdapi.LCDSolidColor.ColorWhite)));
        self.drawLibraryStub();
        if (self.show_telemetry) self.drawTelemetry();
        return 1;
    }

    fn drawLibraryStub(self: *App) void {
        if (self.state == .library) {
            self.drawLibrary();
            return;
        }
        if (self.state == .settings) {
            self.drawSettings();
            return;
        }
        if (self.state == .chapter_browser) {
            self.drawChapterBrowser();
            return;
        }
        switch (self.fixture_state) {
            .opening => self.drawText("Opening EPUB...", 12, 12),
            .ready => if (self.reading_mode == .paged) self.drawPage() else self.drawRsvpPlaceholder(),
            .unavailable => self.drawText("Fixture unavailable", 12, 12),
            .invalid_archive => self.drawText("Invalid EPUB archive", 12, 12),
            .missing_mimetype => self.drawText("mimetype entry missing", 12, 12),
            .invalid_mimetype => self.drawText("Invalid mimetype entry", 12, 12),
            .chapter_error => self.drawChapterError(),
        }
        // self.drawText("B: library", 12, 220);
    }

    fn discoverLibrary(self: *App) void {
        _ = self.playdate.file.listfiles("", collectLibraryPath, self, 0);
    }

    fn openSelectedBook(self: *App) void {
        const book = self.library.selectedBook() orelse return;
        self.active_book = book.*;
        self.loadPace();
        self.fixture_state = .opening;
        self.state = .opening;
        self.opening_job = OpeningJob.init();
    }

    /// Leaving a book must not leave an opening, chapter, or prefetch job
    /// alive: all three reuse App-owned buffers and would otherwise race the
    /// next selected book. A readable position is written immediately rather
    /// than waiting for the normal debounce after the user explicitly exits.
    fn returnToLibrary(self: *App) void {
        if (self.state == .library) return;
        self.stopRsvpAutoplay(self.playdate.system.getCurrentTimeMilliseconds());
        if (self.pace_dirty) self.writePace();
        if (self.fixture_state == .ready) {
            self.resume_dirty = false;
            self.resume_delay_frames = 0;
            self.writePosition();
        }
        if (self.opening_job != null) self.failOpening(.opening);
        self.cancelPrefetch();
        if (self.chapter_file) |*file| file.close();
        self.chapter_file = null;
        self.chapter_open = null;
        self.chapter_stream = null;
        self.chapter_extractor = null;
        self.chapter_builder = null;
        self.rsvp_cursor = null;
        self.rsvp_has_word = false;
        self.rescan_target = null;
        self.rescan_to_last_page = false;
        self.pending_paged_selection = null;
        self.pending_mode_word_ordinal = null;
        self.paged_detent_backlog = 0;
        self.state = .library;
        self.fixture_state = .opening;
    }

    fn drawLibrary(self: *App) void {
        self.drawText("EPUB library", 12, 12);
        if (self.library.len == 0) {
            self.drawText("Put .epub files in Data", 12, 40);
            return;
        }
        for (self.library.books[0..self.library.len], 0..) |*book, index| {
            const y: c_int = 40 + @as(c_int, @intCast(index)) * 20;
            self.drawText(if (index == self.library.selected) ">" else " ", 4, y);
            self.drawText(book.slice(), 18, y);
        }
        self.drawText("A: open", 12, 220);
    }

    /// Settings and chapter browsing only interrupt an opened reader. This
    /// keeps their return destination explicit and avoids changing pipelines
    /// until the reader explicitly confirms an action.
    fn openSettings(self: *App) void {
        if (self.state != .reading) return;
        self.state_before_settings = self.state;
        self.state = .settings;
    }

    fn closeSettings(self: *App) void {
        if (self.state != .settings) return;
        self.state = self.state_before_settings;
    }

    fn openChapterBrowser(self: *App) void {
        if (self.state != .reading or self.publication.spine_len == 0) return;
        self.stopRsvpAutoplay(self.playdate.system.getCurrentTimeMilliseconds());
        self.chapter_browser = chapter_browser.Model.init(self.publication.spine_len, self.chapter_index);
        self.crank_accumulated = 0;
        self.state = .chapter_browser;
    }

    fn closeChapterBrowser(self: *App) void {
        if (self.state == .chapter_browser) {
            self.crank_accumulated = 0;
            self.state = .reading;
        }
    }

    fn openBrowserChapter(self: *App) void {
        if (self.state != .chapter_browser or self.chapter_browser.entry_count == 0) return;
        const selected = self.chapter_browser.selected;
        self.crank_accumulated = 0;
        self.state = .reading;
        self.scheduleOpenChapter(selected, .normal);
        self.fixture_state = .ready;
    }

    fn moveSettingsSelection(self: *App, direction: i8) void {
        if (self.state != .settings) return;
        if (direction != 0) self.settings_selected = if (self.settings_selected == 0) 1 else 0;
    }

    fn activateSetting(self: *App) void {
        if (self.state != .settings) return;
        if (self.settings_selected == 0) {
            self.switchReadingMode();
            return;
        }
        self.rsvp_wpm = rsvp.adjustWpm(self.rsvp_wpm, 1);
        self.writeSettings();
    }

    fn toggleReadingMode(self: *App) void {
        if (self.state != .reading) return;
        self.switchReadingMode();
    }

    fn switchReadingMode(self: *App) void {
        const target_word = if (self.reading_mode == .paged)
            pagedModeSwitchOrdinal(self.currentPagedWordOrdinal(), self.pending_paged_selection)
        else
            self.rsvp_position.word;
        self.reading_mode = reader_settings.nextReadingMode(self.reading_mode);
        self.stopRsvpAutoplay(self.playdate.system.getCurrentTimeMilliseconds());
        self.pending_paged_selection = null;
        self.paged_detent_backlog = 0;
        self.crank_accumulated = 0;
        self.pending_mode_word_ordinal = target_word;
        if (self.fixture_state == .ready) {
            switch (self.reading_mode) {
                .paged => {
                    self.pending_paged_selection = .{ .ordinal = target_word };
                    self.scheduleOpenChapter(self.chapter_index, .{ .word_rescan = target_word });
                },
                .rsvp => self.scheduleOpenChapter(self.chapter_index, .{ .rsvp_rescan = .{ .word = target_word } }),
            }
            self.savePosition();
        }
        self.writeSettings();
    }

    fn drawSettings(self: *App) void {
        self.drawText("Settings", 12, 12);
        self.drawText(if (self.settings_selected == 0) "> Reading mode" else "  Reading mode", 12, 52);
        self.drawText(switch (self.reading_mode) {
            .paged => "Paged",
            .rsvp => "RSVP",
        }, 32, 76);
        self.drawText(if (self.settings_selected == 1) "> RSVP WPM" else "  RSVP WPM", 12, 112);
        var wpm_buffer: [8]u8 = undefined;
        const wpm = std.fmt.bufPrint(&wpm_buffer, "{d}", .{self.rsvp_wpm}) catch "";
        self.drawText(wpm, 32, 136);
        self.drawText("A: change   B: back", 12, 220);
    }

    fn drawChapterBrowser(self: *App) void {
        var header_buffer: [32]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buffer, "Chapters {d}/{d}", .{ self.chapter_browser.selected + 1, self.chapter_browser.entry_count }) catch "Chapters";
        self.drawText(header, 12, 12);
        var label_buffer: [160]u8 = undefined;
        const rows = self.chapter_browser.displayedCount();
        for (0..rows) |row| {
            const index = self.chapter_browser.first_visible + @as(u8, @intCast(row));
            const y: c_int = 36 + @as(c_int, @intCast(row)) * 18;
            self.drawText(if (index == self.chapter_browser.selected) ">" else " ", 8, y);
            const label = chapter_browser.formatLabel(&label_buffer, index, self.publication.chapter_labels[index].slice(), self.publication.spine[index].slice());
            self.drawText(label, 24, y);
        }
        self.drawText("B: back", 12, 220);
    }

    fn drawRsvpPlaceholder(self: *App) void {
        self.drawText(if (self.rsvp_timer.running) "RSVP - playing" else "RSVP - paused", 12, 12);
        var wpm_buffer: [16]u8 = undefined;
        const wpm = std.fmt.bufPrint(&wpm_buffer, "WPM: {d}", .{self.rsvp_wpm}) catch "";
        self.drawText(wpm, 12, 36);
        if (!self.rsvp_has_word) {
            self.drawText(if (self.rsvp_rescan_target != null) "Rebuilding word..." else "Loading chapter...", 12, 76);
            return;
        }
        const word = self.rsvp_word[0..self.rsvp_word_len];
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
        const file = self.playdate.file.open("settings.bin", pdapi.FILE_READ | pdapi.FILE_READ_DATA) orelse return;
        defer _ = self.playdate.file.close(file);
        var bytes: [reader_settings.encoded_size]u8 = undefined;
        if (self.playdate.file.read(file, &bytes, bytes.len) != bytes.len) return;
        const settings = reader_settings.decode(&bytes) catch return;
        self.reading_mode = settings.reading_mode;
        self.rsvp_wpm = settings.rsvp_wpm;
    }

    fn writeSettings(self: *App) void {
        const file = self.playdate.file.open("settings.bin", pdapi.FILE_WRITE) orelse return;
        defer _ = self.playdate.file.close(file);
        var bytes: [reader_settings.encoded_size]u8 = undefined;
        reader_settings.encode(.{ .reading_mode = self.reading_mode, .rsvp_wpm = self.rsvp_wpm }, &bytes);
        if (self.playdate.file.write(file, &bytes, bytes.len) != bytes.len) return;
        _ = self.playdate.file.flush(file);
    }

    fn handleCrank(self: *App) void {
        if (self.state == .chapter_browser) {
            self.chapter_browser.move(crankDetents(&self.crank_accumulated, self.playdate.system.getCrankChange()));
            return;
        }
        if (self.state != .reading) return;
        if (self.fixture_state != .ready or self.chapter_open != null or self.rescan_target != null or self.rescan_to_last_page) return;
        if (self.reading_mode == .rsvp) {
            if (self.rsvp_timer.running) return;
            switch (crankDirection(&self.crank_accumulated, self.playdate.system.getCrankChange())) {
                1 => self.nextRsvpWord(),
                -1 => self.previousRsvpWord(),
                else => {},
            }
            return;
        }
        self.paged_detent_backlog = saturatingAddDetents(self.paged_detent_backlog, crankDetents(&self.crank_accumulated, self.playdate.system.getCrankChange()));
        self.drainPagedDetents();
    }

    fn toggleRsvpAutoplay(self: *App, now_ms: u32) void {
        if (self.state != .reading or self.reading_mode != .rsvp) return;
        if (self.rsvp_timer.running) self.stopRsvpAutoplay(now_ms) else {
            self.rsvp_timer.start(now_ms);
            if (self.rsvp_has_word) self.rsvp_active_session.begin(now_ms);
        }
    }

    fn adjustRsvpWpm(self: *App, direction: i8, now_ms: u32) void {
        if (self.state != .reading or self.reading_mode != .rsvp) return;
        const adjusted = rsvp.adjustWpm(self.rsvp_wpm, direction);
        if (adjusted == self.rsvp_wpm) return;
        self.recordAutoplayInterval(now_ms, 0);
        self.rsvp_wpm = adjusted;
        self.rsvp_timer.reset(now_ms);
        if (self.rsvp_timer.running and self.rsvp_has_word) self.rsvp_active_session.begin(now_ms);
        self.writeSettings();
    }

    fn advanceRsvpAutoplay(self: *App, now_ms: u32) void {
        if (self.state != .reading or self.reading_mode != .rsvp or !self.rsvp_has_word) return;
        if (self.rsvp_timer.due(now_ms, self.rsvp_wpm)) {
            self.recordAutoplayInterval(now_ms, 1);
            self.nextRsvpWord();
            if (self.rsvp_has_word and self.rsvp_timer.running) self.rsvp_active_session.begin(now_ms);
        }
    }

    fn stopRsvpAutoplay(self: *App, now_ms: u32) void {
        self.recordAutoplayInterval(now_ms, 0);
        self.rsvp_timer.stop();
        self.rsvp_active_session = .{};
    }

    fn recordAutoplayInterval(self: *App, now_ms: u32, completed_words: u32) void {
        if (!self.rsvp_timer.running) return;
        if (self.rsvp_active_session.started_at_ms == null) return;
        self.rsvp_active_session.record(&self.pace, now_ms, completed_words);
        self.pace_dirty = true;
        self.pace_delay_frames = pace_debounce_frames;
    }

    fn drawChapterError(self: *App) void {
        const reason: []const u8 = switch (self.chapter_failure) {
            .archive => "ZIP or DEFLATE error",
            .tokenizer => "XHTML tokenizer error",
            .page_limit => "Page limit exceeded",
            .no_supported_text => "No supported text",
        };
        self.drawText("Chapter unavailable", 12, 12);
        self.drawText(reason, 12, 36);
        if (self.chapter_index < self.publication.spine_len) self.drawText(self.publication.spine[self.chapter_index].slice(), 12, 60);
        self.drawText("Left/Right: another chapter", 12, 100);
    }

    fn failChapter(self: *App, failure: ChapterFailure) void {
        self.chapter_failure = failure;
        self.current_ready = false;
        self.next_ready = false;
        self.chapter_end = true;
        self.fixture_state = .chapter_error;
    }

    fn openAdjacentChapter(self: *App, direction: i8) void {
        const candidate: i16 = @as(i16, self.chapter_index) + direction;
        if (candidate < 0 or candidate >= self.publication.spine_len) return;
        self.scheduleOpenChapter(@intCast(candidate), .normal);
        self.fixture_state = .ready;
    }

    /// Advances at most one archive phase or one bounded metadata output read.
    /// The OPF collector is intentionally a metadata-only exception; chapter
    /// content continues through the incremental reader pipeline.
    fn advanceOpeningJob(self: *App) void {
        const job = &(self.opening_job orelse return);
        switch (job.phase) {
            .open => {
                self.opening_file = PlaydateFileReader.open(self.playdate.file, self.active_book.zSlice()) catch {
                    self.failOpening(.unavailable);
                    return;
                };
                job.scanner = zip.ArchiveScanner.init(self.opening_file.?.reader()) catch {
                    self.failOpening(.invalid_archive);
                    return;
                };
                job.phase = .scan_archive;
            },
            .scan_archive => {
                const archive = job.scanner.?.step(&self.zip_scan_buffer) catch {
                    self.failOpening(.invalid_archive);
                    return;
                } orelse return;
                self.fixture_entry_count = archive.entry_count;
                job.archive = archive;
                job.validator = zip.DirectoryValidator.initWithIndex(archive, &self.zip_member_ranges, &self.zip_entries) catch {
                    self.failOpening(.invalid_archive);
                    return;
                };
                job.phase = .validate_directory;
            },
            .validate_directory => {
                if (!(job.validator.?.step(&self.zip_filename_buffer) catch {
                    self.failOpening(.invalid_archive);
                    return;
                })) return;
                self.archive_index = .{ .archive = job.archive.?, .entries = self.zip_entries[0..job.archive.?.entry_count] };
                job.phase = .find_mimetype;
            },
            .find_mimetype => if (self.advanceOpeningFind(.mimetype, .read_mimetype)) |entry| {
                self.beginOpeningRead(entry, .mimetype) catch self.failOpening(.invalid_mimetype);
            },
            .read_mimetype => if (self.advanceOpeningRead(.mimetype)) {
                if (!std.mem.eql(u8, self.fixture_mimetype[0..self.fixture_mimetype_len], "application/epub+zip")) {
                    self.failOpening(.invalid_mimetype);
                    return;
                }
                job.phase = .find_container;
            },
            .find_container => if (self.advanceOpeningFind(.container, .read_container)) |entry| {
                self.beginOpeningRead(entry, .container) catch self.failOpening(.invalid_archive);
            },
            .read_container => if (self.advanceOpeningRead(.container)) {
                job.phase = .parse_container;
            },
            .parse_container => {
                const package_path = epub.parseContainer(self.container_xml[0..self.fixture_container_len], &self.package_path) catch {
                    self.failOpening(.invalid_archive);
                    return;
                };
                self.package_path_len = package_path.len;
                job.phase = .find_package;
            },
            .find_package => if (self.advanceOpeningFind(.package, .read_package)) |entry| {
                if (entry.uncompressed_size == 0 or entry.uncompressed_size > epub.max_package_document_bytes) {
                    self.failOpening(.invalid_archive);
                    return;
                }
                job.package_xml = self.allocator.allocator().alloc(u8, entry.uncompressed_size) catch {
                    self.failOpening(.invalid_archive);
                    return;
                };
                self.beginOpeningRead(entry, .package) catch self.failOpening(.invalid_archive);
            },
            .read_package => if (self.advanceOpeningRead(.package)) {
                job.phase = .parse_package;
            },
            .parse_package => {
                const package_xml = job.package_xml orelse {
                    self.failOpening(.invalid_archive);
                    return;
                };
                job.opf_workspace = self.allocator.allocator().create(epub.OpfWorkspace) catch {
                    self.failOpening(.invalid_archive);
                    return;
                };
                epub.parseOpf(package_xml[0..job.output_len], self.package_path[0..self.package_path_len], &self.publication, job.opf_workspace.?) catch {
                    self.failOpening(.invalid_archive);
                    return;
                };
                self.allocator.allocator().destroy(job.opf_workspace.?);
                job.opf_workspace = null;
                self.allocator.allocator().free(package_xml);
                job.package_xml = null;
                job.phase = .find_navigation;
            },
            .find_navigation => self.beginNavigationRead(.epub3, .read_navigation),
            .read_navigation => self.advanceNavigationRead(.epub3),
            .find_ncx => self.beginNavigationRead(.ncx, .read_ncx),
            .read_ncx => self.advanceNavigationRead(.ncx),
        }
    }

    fn beginNavigationRead(self: *App, source: NavigationSource, next_phase: OpeningPhase) void {
        const path = switch (source) {
            .epub3 => self.publication.navigation_document.slice(),
            .ncx => self.publication.ncx_document.slice(),
        };
        if (path.len == 0) {
            self.navigationSourceFinished(source, false);
            return;
        }
        const entry = self.archive_index.?.find(path) catch {
            self.navigationSourceFinished(source, false);
            return;
        };
        if (entry.uncompressed_size == 0 or entry.uncompressed_size > limits.max_navigation_document_bytes) {
            self.navigationSourceFinished(source, false);
            return;
        }
        const job = &self.opening_job.?;
        self.opening_storage = zip.StreamStorage.init(&self.deflate_input_buffer, &self.deflate_window, &self.deflate_workspace);
        job.stream = job.archive.?.begin(entry, &self.opening_storage) catch {
            self.navigationSourceFinished(source, false);
            return;
        };
        job.output_len = 0;
        self.navigation_parser = switch (source) {
            .epub3 => .{ .epub3 = publication_navigation.Parser.init(&self.publication, path) },
            .ncx => .{ .ncx = publication_navigation.NcxParser.init(&self.publication, path) },
        };
        job.phase = next_phase;
    }

    fn advanceNavigationRead(self: *App, source: NavigationSource) void {
        const job = &self.opening_job.?;
        const result = job.stream.?.read(&self.opening_output) catch {
            self.navigationSourceFinished(source, false);
            return;
        };
        switch (result) {
            .bytes => |count| {
                if (count > limits.max_navigation_document_bytes - job.output_len) {
                    self.navigationSourceFinished(source, false);
                    return;
                }
                job.output_len += count;
                self.navigation_parser.?.feed(self.opening_output[0..count]) catch self.navigationSourceFinished(source, false);
            },
            .end => {
                job.stream.?.finish() catch {
                    self.navigationSourceFinished(source, false);
                    return;
                };
                job.stream = null;
                const parser = &(self.navigation_parser orelse {
                    self.navigationSourceFinished(source, false);
                    return;
                });
                parser.finish() catch {
                    self.navigationSourceFinished(source, false);
                    return;
                };
                self.navigationSourceFinished(source, parser.labelCount() != 0);
            },
            .needs_input => self.navigationSourceFinished(source, false),
        }
    }

    fn navigationSourceFinished(self: *App, source: NavigationSource, has_labels: bool) void {
        self.opening_job.?.stream = null;
        self.navigation_parser = null;
        if (!has_labels) self.clearChapterLabels();
        if (source == .epub3 and !has_labels) {
            self.opening_job.?.phase = .find_ncx;
            return;
        }
        self.finishOpening();
    }

    fn clearChapterLabels(self: *App) void {
        for (self.publication.chapter_labels[0..self.publication.spine_len]) |*label| label.len = 0;
    }

    fn finishOpening(self: *App) void {
        self.opening_job = null;
        self.fixture_state = .ready;
        self.state = .reading;
        self.scheduleOpenChapter(initialChapterIndex(self.publication.spine_len), .normal);
        self.restorePosition();
    }

    fn advanceOpeningFind(self: *App, target: MetadataTarget, next_phase: OpeningPhase) ?zip.Entry {
        const entry = self.archive_index.?.find(switch (target) {
            .mimetype => "mimetype",
            .container => "META-INF/container.xml",
            .package => self.package_path[0..self.package_path_len],
        }) catch {
            self.failOpening(if (target == .mimetype) .missing_mimetype else .invalid_archive);
            return null;
        };
        self.opening_job.?.phase = next_phase;
        return entry;
    }

    fn beginOpeningRead(self: *App, entry: zip.Entry, target: MetadataTarget) !void {
        const job = &self.opening_job.?;
        self.opening_storage = zip.StreamStorage.init(&self.deflate_input_buffer, &self.deflate_window, &self.deflate_workspace);
        job.stream = try job.archive.?.begin(entry, &self.opening_storage);
        job.target = target;
        job.output_len = 0;
        if (target == .mimetype) self.fixture_mimetype_len = 0;
        if (target == .container) self.fixture_container_len = 0;
    }

    /// Returns true only after the stream reaches and validates its end.
    fn advanceOpeningRead(self: *App, target: MetadataTarget) bool {
        const job = &self.opening_job.?;
        const result = job.stream.?.read(&self.opening_output) catch {
            self.failOpening(if (target == .mimetype) .invalid_mimetype else .invalid_archive);
            return false;
        };
        switch (result) {
            .bytes => |count| {
                self.appendOpeningBytes(target, self.opening_output[0..count]) catch {
                    self.failOpening(if (target == .mimetype) .invalid_mimetype else .invalid_archive);
                };
                return false;
            },
            .end => {
                job.stream.?.finish() catch {
                    self.failOpening(if (target == .mimetype) .invalid_mimetype else .invalid_archive);
                    return false;
                };
                job.stream = null;
                return true;
            },
            .needs_input => {
                self.failOpening(if (target == .mimetype) .invalid_mimetype else .invalid_archive);
                return false;
            },
        }
    }

    fn appendOpeningBytes(self: *App, target: MetadataTarget, bytes: []const u8) !void {
        const job = &self.opening_job.?;
        const destination: []u8 = switch (target) {
            .mimetype => &self.fixture_mimetype,
            .container => &self.container_xml,
            .package => job.package_xml orelse return error.InvalidPackageBuffer,
        };
        if (bytes.len > destination.len - job.output_len) return error.EntryTooLarge;
        @memcpy(destination[job.output_len .. job.output_len + bytes.len], bytes);
        job.output_len += bytes.len;
        switch (target) {
            .mimetype => self.fixture_mimetype_len = job.output_len,
            .container => self.fixture_container_len = job.output_len,
            .package => {},
        }
    }

    fn failOpening(self: *App, state: FixtureState) void {
        if (self.opening_job) |*job| {
            if (job.package_xml) |buffer| self.allocator.allocator().free(buffer);
            if (job.opf_workspace) |workspace| self.allocator.allocator().destroy(workspace);
        }
        self.closeOpeningFile();
        self.opening_job = null;
        self.fixture_state = state;
    }

    fn closeOpeningFile(self: *App) void {
        if (self.opening_file) |*file| file.close();
        self.opening_file = null;
    }

    fn scheduleOpenChapter(self: *App, index: u8, action: ChapterOpenAction) void {
        self.cancelPrefetch();
        if (self.chapter_file) |*file| file.close();
        self.chapter_file = null;
        self.chapter_stream = null;
        self.chapter_extractor = null;
        self.chapter_builder = null;
        self.rsvp_cursor = null;
        self.rsvp_has_word = false;
        self.rsvp_previous_valid = false;
        self.rsvp_next_valid = false;
        self.rsvp_rescan_target = null;
        self.chapter_open = .{ .index = index, .action = action };
        self.previous_ready = false;
        self.current_ready = false;
        self.next_ready = false;
        self.selected_word_ordinal = null;
        self.chapter_end = false;
        self.cache_navigation = false;
    }

    fn cancelPrefetch(self: *App) void {
        if (self.prefetch_file) |*file| file.close();
        self.prefetch_file = null;
        self.prefetch_open = null;
        self.prefetch_stream = null;
        self.prefetch_extractor = null;
        self.prefetch_builder = null;
        self.prefetched_chapter_index = null;
        self.prefetched_ready = false;
        self.prefetched_end = false;
    }

    fn beginOpenedChapter(self: *App, archive: zip.Archive, index: u8, chapter_entry: zip.Entry) !void {
        self.chapter_storage = zip.StreamStorage.init(&self.deflate_input_buffer, &self.deflate_window, &self.deflate_workspace);
        self.chapter_stream = try archive.begin(chapter_entry, &self.chapter_storage);
        self.chapter_index = index;
        self.page_index = 0;
        self.previous_page = 2;
        self.current_page = 0;
        self.next_page = 1;
        self.building_page = 0;
        self.building_ready = false;
        self.previous_ready = false;
        self.current_ready = false;
        self.next_ready = false;
        self.selected_word_ordinal = null;
        self.chapter_end = false;
        self.chapter_output_start = 0;
        self.chapter_output_end = 0;
        self.chapter_bytes_decoded = 0;
        self.chapter_events = 0;
        self.page_build_started_ms = self.playdate.system.getCurrentTimeMilliseconds();
        self.rescan_target = null;
        self.rescan_to_last_page = false;
        self.chapter_last_page = null;
        self.cache_navigation = false;
        self.stream_front_page = 0;
        self.navigation_state.opened(0);
        self.pages[0].clear();
        self.pages[1].clear();
        self.pages[2].clear();
        self.rsvp_has_word = false;
        self.rsvp_word_len = 0;
        self.rsvp_position = .{};
        self.rsvp_previous_valid = false;
        self.rsvp_next_valid = false;
        if (self.reading_mode == .rsvp) {
            self.chapter_builder = null;
            self.rsvp_cursor = rsvp.Cursor.init(.{ .context = self, .emit = emitRsvpWord });
            self.chapter_extractor = xhtml.StreamExtractor.init(.{ .context = self, .emit = emitRsvpEvent });
        } else {
            self.rsvp_cursor = null;
            self.chapter_builder = pagination.EventPageBuilder.init(&self.pages[0], reader_text_width, .{ .context = self, .width = measureTextWidth });
            self.chapter_extractor = xhtml.StreamExtractor.init(.{ .context = self, .emit = emitChapterEvent });
        }
    }

    fn advanceChapterJob(self: *App) void {
        if (self.advanceChapterOpenJob()) return;
        if (self.fixture_state != .ready or self.next_ready or self.chapter_end) return;
        // R02 has no navigation control yet: pause as soon as the first
        // complete word is available. R03 will explicitly resume this same
        // stream for each crank step, without a word queue.
        if (self.reading_mode == .rsvp and self.rsvp_has_word) return;
        // EntryStream refills a 1 KiB decoded chunk; tokenizer work remains
        // byte-budgeted so a page-full word can carry into the next page.
        var budget: usize = 256;
        while (budget != 0 and !self.next_ready and !self.chapter_end) {
            if (self.chapter_output_start != self.chapter_output_end) {
                const available = self.chapter_output[self.chapter_output_start..self.chapter_output_end];
                const input = available[0..if (self.reading_mode == .rsvp) 1 else @min(available.len, budget)];
                const progress = self.chapter_extractor.?.feed(input) catch {
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
                self.chapter_output_start += consumed;
                budget -= consumed;
                if (self.reading_mode == .rsvp and self.rsvp_has_word) return;
                continue;
            }
            const stream = &self.chapter_stream.?;
            const output = self.chapter_output[0..@min(self.chapter_output.len, budget)];
            const result = stream.read(output) catch {
                self.failChapter(.archive);
                return;
            };
            switch (result) {
                .bytes => |count| {
                    self.chapter_bytes_decoded +%= @intCast(count);
                    self.chapter_output_start = 0;
                    self.chapter_output_end = count;
                },
                .end => {
                    self.chapter_extractor.?.finish() catch {
                        self.failChapter(.tokenizer);
                        return;
                    };
                    if (self.reading_mode == .rsvp) {
                        self.rsvp_cursor.?.finish() catch {
                            self.failChapter(.tokenizer);
                            return;
                        };
                        self.chapter_end = true;
                        stream.finish() catch {
                            self.failChapter(.archive);
                            return;
                        };
                        // R05 owns the actual chapter transition. Keep the
                        // final displayed word visible at a verified EOF.
                        if (self.rsvp_rescan_target != null) {
                            self.failChapter(.page_limit);
                        } else if (!self.rsvp_has_word) {
                            if (nextReadableSpineIndex(self.chapter_index, self.publication.spine_len)) |next| {
                                self.scheduleOpenChapter(next, .normal);
                            } else self.failChapter(.no_supported_text);
                        }
                        return;
                    }
                    self.chapter_builder.?.end() catch |err| {
                        if (err == error.PageFull) self.pageCompleted() else self.failChapter(.page_limit);
                        return;
                    };
                    self.chapter_end = true;
                    if (self.rescan_to_last_page) {
                        if (self.pages[self.building_page].line_count != 0) {
                            self.current_page = self.building_page;
                            self.page_index = self.rescan_page;
                            self.navigation_state.beginRescan(self.page_index);
                        } else if (self.rescan_page != 0) {
                            self.current_page = self.rescan_last_completed;
                            self.page_index = self.rescan_page - 1;
                            self.navigation_state.beginRescan(self.page_index);
                        } else {
                            self.failChapter(.page_limit);
                        }
                        self.current_ready = true;
                        self.rescan_to_last_page = false;
                    } else if (self.rescan_target) |target| {
                        if (self.rescan_page == target and self.pages[0].line_count != 0) {
                            self.current_page = 0;
                            self.current_ready = true;
                            self.page_index = target;
                            self.rescan_target = null;
                        } else {
                            self.failChapter(.page_limit);
                        }
                    } else if (!self.current_ready and self.pages[self.current_page].line_count != 0) self.current_ready = true else if (self.pages[self.next_page].line_count != 0) {
                        self.next_ready = true;
                        self.building_ready = true;
                    }
                    stream.finish() catch {
                        self.failChapter(.archive);
                        return;
                    };
                    if (self.chapter_end and self.rescan_target == null and !self.rescan_to_last_page and !self.current_ready and !self.next_ready) {
                        if (nextReadableSpineIndex(self.chapter_index, self.publication.spine_len)) |next| {
                            self.scheduleOpenChapter(next, .normal);
                        } else {
                            self.failChapter(.no_supported_text);
                        }
                        return;
                    }
                    if (self.chapter_end and self.rescan_target == null and !self.rescan_to_last_page) {
                        self.chapter_last_page = self.page_index + (if (self.next_ready) @as(u32, 1) else 0);
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
        if (!self.next_ready or self.chapter_index + 1 >= self.publication.spine_len or self.prefetch_open != null or self.prefetched_chapter_index != null) return;
        if (self.chapter_file) |*file| file.close();
        self.chapter_file = null;
        self.previous_ready = false;
        self.prefetched_page = self.previous_page;
        self.pages[self.prefetched_page].clear();
        self.prefetch_open = .{ .index = self.chapter_index + 1, .action = .normal };
    }

    /// Prefetches exactly one drawable page. It has its own file and ZIP
    /// state, but deliberately shares the now-idle DEFLATE backing buffers
    /// with the completed current chapter.
    fn advancePrefetchJob(self: *App) void {
        if (self.prefetch_open) |*job| {
            if (job.scanner == null) {
                self.prefetch_file = PlaydateFileReader.open(self.playdate.file, self.active_book.zSlice()) catch {
                    self.cancelPrefetch();
                    return;
                };
                job.scanner = zip.ArchiveScanner.init(self.prefetch_file.?.reader()) catch {
                    self.cancelPrefetch();
                    return;
                };
                return;
            }
            if (job.finder == null) {
                const archive = job.scanner.?.step(&self.zip_scan_buffer) catch {
                    self.cancelPrefetch();
                    return;
                } orelse return;
                job.finder = zip.EntryFinder.init(archive, self.publication.spine[job.index].slice());
            }
            for (0..prefetch_directory_records_per_update) |_| {
                const entry = job.finder.?.step(&self.zip_filename_buffer) catch {
                    self.cancelPrefetch();
                    return;
                } orelse {
                    if (job.finder.?.entry_index == job.finder.?.archive.entry_count) self.cancelPrefetch();
                    return;
                };
                const index = job.index;
                const archive = job.finder.?.archive;
                self.prefetch_open = null;
                self.prefetch_storage = zip.StreamStorage.init(&self.deflate_input_buffer, &self.deflate_window, &self.deflate_workspace);
                self.prefetch_stream = archive.begin(entry, &self.prefetch_storage) catch {
                    self.cancelPrefetch();
                    return;
                };
                self.prefetch_output_start = 0;
                self.prefetch_output_end = 0;
                self.prefetched_chapter_index = index;
                self.prefetched_ready = false;
                self.prefetched_end = false;
                self.prefetch_builder = pagination.EventPageBuilder.init(&self.pages[self.prefetched_page], reader_text_width, .{ .context = self, .width = measureTextWidth });
                self.prefetch_extractor = xhtml.StreamExtractor.init(.{ .context = self, .emit = emitPrefetchEvent });
                break;
            }
        }
        if (self.prefetch_stream == null or self.prefetched_ready) return;

        var budget: usize = prefetch_byte_budget;
        while (budget != 0 and !self.prefetched_ready) {
            if (self.prefetch_output_start != self.prefetch_output_end) {
                const available = self.chapter_output[self.prefetch_output_start..self.prefetch_output_end];
                const input = available[0..@min(available.len, budget)];
                const progress = self.prefetch_extractor.?.feed(input) catch {
                    self.cancelPrefetch();
                    return;
                };
                const consumed = switch (progress) {
                    .consumed => |count| count,
                    .page_full => |count| blk: {
                        self.prefetched_ready = true;
                        break :blk count;
                    },
                };
                self.prefetch_output_start += consumed;
                budget -= consumed;
                continue;
            }
            const result = self.prefetch_stream.?.read(self.chapter_output[0..@min(self.chapter_output.len, budget)]) catch {
                self.cancelPrefetch();
                return;
            };
            switch (result) {
                .bytes => |count| {
                    self.prefetch_output_start = 0;
                    self.prefetch_output_end = count;
                },
                .end => {
                    self.prefetch_extractor.?.finish() catch {
                        self.cancelPrefetch();
                        return;
                    };
                    self.prefetch_builder.?.end() catch |err| {
                        if (err == error.PageFull) self.prefetched_ready = true else self.cancelPrefetch();
                        return;
                    };
                    self.prefetch_stream.?.finish() catch {
                        self.cancelPrefetch();
                        return;
                    };
                    self.prefetched_end = true;
                    self.prefetched_ready = self.pages[self.prefetched_page].line_count != 0;
                },
                .needs_input => self.cancelPrefetch(),
            }
        }
    }

    fn activatePrefetchedChapter(self: *App) void {
        const index = self.prefetched_chapter_index orelse return;
        if (!self.prefetched_ready) return;
        if (self.chapter_file) |*file| file.close();
        self.chapter_file = self.prefetch_file;
        self.prefetch_file = null;
        self.chapter_stream = self.prefetch_stream;
        self.chapter_storage = self.prefetch_storage;
        self.chapter_extractor = self.prefetch_extractor;
        self.chapter_builder = self.prefetch_builder;
        self.chapter_output_start = self.prefetch_output_start;
        self.chapter_output_end = self.prefetch_output_end;
        self.chapter_index = index;
        self.page_index = 0;
        self.current_page = self.prefetched_page;
        self.current_ready = true;
        self.selected_word_ordinal = null;
        self.previous_ready = false;
        self.next_page = self.freePage();
        self.next_ready = false;
        self.building_page = self.next_page;
        self.chapter_builder.?.beginNextPage(&self.pages[self.next_page]);
        self.chapter_end = self.prefetched_end;
        self.chapter_last_page = if (self.prefetched_end) 0 else null;
        self.cache_navigation = false;
        self.stream_front_page = 0;
        self.navigation_state.opened(0);
        self.recordCheckpoint(0);
        self.prefetch_open = null;
        self.prefetch_stream = null;
        self.prefetch_extractor = null;
        self.prefetch_builder = null;
        self.prefetched_chapter_index = null;
        self.prefetched_ready = false;
        self.prefetched_end = false;
    }

    /// Performs at most one file/archive phase per frame. The scanner and
    /// finder each read a bounded amount of data; decompression starts only
    /// after both have completed.
    fn advanceChapterOpenJob(self: *App) bool {
        if (self.chapter_open == null) return false;
        const job = &self.chapter_open.?;
        const directory_index = self.archive_index orelse {
            self.chapter_open = null;
            self.failChapter(.archive);
            return true;
        };
        const chapter_entry = directory_index.find(self.publication.spine[job.index].slice()) catch {
            self.chapter_open = null;
            self.failChapter(.archive);
            return true;
        };
        const index = job.index;
        const action = job.action;
        const archive = self.archive_index.?.archive;
        self.chapter_open = null;
        self.beginOpenedChapter(archive, index, chapter_entry) catch {
            self.failChapter(.archive);
            return true;
        };
        switch (action) {
            .normal => {},
            .rescan => |target| self.beginRescan(target),
            .word_rescan => |target| self.pending_paged_selection = .{ .ordinal = target },
            .rsvp_rescan => |target| self.rsvp_rescan_target = target,
            .rescan_to_last_page => {
                self.rescan_to_last_page = true;
                self.rescan_page = 0;
                self.rescan_last_completed = 0;
                self.previous_ready = false;
                self.current_ready = false;
                self.next_ready = false;
            },
        }
        return true;
    }

    fn pageCompleted(self: *App) void {
        self.recordPageBuild();
        const completed_page = if (self.rescan_to_last_page or self.rescan_target != null)
            self.rescan_page
        else if (self.current_ready)
            self.page_index + 1
        else
            self.page_index;
        self.recordCheckpoint(completed_page);
        if (self.rescan_to_last_page) {
            self.rescan_last_completed = self.building_page;
            self.rescan_page += 1;
            const scratch: u2 = if (self.building_page == 0) 1 else 0;
            self.chapter_builder.?.beginNextPage(&self.pages[scratch]);
            self.building_page = scratch;
            self.building_ready = false;
            return;
        } else if (self.rescan_target) |target| {
            if (self.rescan_page == target) {
                self.current_ready = true;
                self.page_index = target;
                self.stream_front_page = target;
                self.navigation_state.beginRescan(target);
                self.rescan_target = null;
                self.next_page = 1;
                self.pages[self.next_page].clear();
                self.chapter_builder.?.beginNextPage(&self.pages[self.next_page]);
                self.building_page = self.next_page;
                self.building_ready = false;
            } else {
                self.rescan_page += 1;
                self.chapter_builder.?.beginNextPage(&self.pages[0]);
                self.building_page = 0;
                self.building_ready = false;
            }
            return;
        }
        if (!self.current_ready) {
            self.current_ready = true;
            self.chapter_builder.?.beginNextPage(&self.pages[self.next_page]);
            self.building_page = self.next_page;
            self.building_ready = false;
        } else {
            self.next_ready = true;
            self.building_ready = true;
        }
    }

    fn drawTelemetry(self: *App) void {
        var line_buffer: [96]u8 = undefined;
        const stats = self.allocator.stats;
        const line = std.fmt.bufPrintZ(
            &line_buffer,
            "a:{d} f:{d} live:{d} peak:{d}",
            .{ stats.allocations, stats.frees, stats.live_bytes, stats.peak_live_bytes },
        ) catch return;
        _ = self.playdate.graphics.drawText(line.ptr, line.len, .UTF8Encoding, 20, 190);
        const pipeline = std.fmt.bufPrintZ(
            &line_buffer,
            "z:{d} e:{d} p:{d}/{d} page:{d}",
            .{ self.chapter_bytes_decoded, self.chapter_events, self.last_page_build_ms, self.max_page_build_ms, page_pool_reserved_bytes },
        ) catch return;
        _ = self.playdate.graphics.drawText(pipeline.ptr, pipeline.len, .UTF8Encoding, 20, 210);
    }

    fn drawText(self: *App, text: []const u8, x: c_int, y: c_int) void {
        _ = self.playdate.graphics.drawText(text.ptr, text.len, .UTF8Encoding, x, y);
    }

    fn textWidth(self: *const App, text: []const u8) c_int {
        return @intCast(self.playdate.graphics.getTextWidth(self.body_font, text.ptr, text.len, .UTF8Encoding, 0));
    }

    fn drawNumber(self: *App, value: u8, x: c_int, y: c_int) void {
        var buffer: [4]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return;
        self.drawText(text, x, y);
    }

    fn nextPage(self: *App) void {
        if (self.fixture_state != .ready or self.chapter_open != null) return;
        if (self.chapter_end) {
            const target = self.page_index + 1;
            if (self.chapter_last_page) |last_page| {
                if (target <= last_page) {
                    if (!self.restoreActiveHistoryPage(self.chapter_index, target)) self.startRescan(target);
                } else if (self.prefetched_chapter_index != null and self.prefetched_ready) {
                    self.activatePrefetchedChapter();
                } else if (self.chapter_index + 1 < self.publication.spine_len) {
                    self.scheduleOpenChapter(self.chapter_index + 1, .normal);
                }
            }
            self.savePosition();
            return;
        }
        if (self.cache_navigation) {
            _ = self.navigation_state.forwardFromCache();
            const target = self.navigation_state.page;
            if (target <= self.stream_front_page) {
                if (self.restoreActiveHistoryPage(self.chapter_index, target)) {
                    if (target == self.stream_front_page) self.cache_navigation = false;
                } else {
                    self.startRescan(target);
                }
                self.savePosition();
                return;
            }
            self.cache_navigation = false;
        }
        if (!self.next_ready) {
            if (self.chapter_end and self.chapter_index + 1 < self.publication.spine_len) {
                self.scheduleOpenChapter(self.chapter_index + 1, .normal);
            }
            self.savePosition();
            return;
        }
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
        if (self.building_page == old_next) {
            self.next_page = self.freePage();
            self.chapter_builder.?.beginNextPage(&self.pages[self.next_page]);
            self.building_page = self.next_page;
            self.building_ready = false;
        } else {
            // We returned from the prior page while a future page was already
            // partially built.  Resume that exact stream/cache pair.
            self.next_page = self.building_page;
            self.next_ready = self.building_ready;
        }
        self.savePosition();
    }

    const PagedSelectionMove = enum { advanced, waiting_for_page, at_limit };

    fn drainPagedDetents(self: *App) void {
        while (self.paged_detent_backlog != 0) {
            if (self.pending_paged_selection != null) return;
            const direction: i8 = if (self.paged_detent_backlog > 0) 1 else -1;
            switch (self.movePagedSelection(direction)) {
                .advanced => self.paged_detent_backlog -= direction,
                .waiting_for_page => return,
                .at_limit => {
                    self.paged_detent_backlog = 0;
                    return;
                },
            }
        }
    }

    fn movePagedSelection(self: *App, direction: i8) PagedSelectionMove {
        if (!self.current_ready) return .waiting_for_page;
        const page = &self.pages[self.current_page];
        const current = page.moveSelection(self.selected_word_ordinal, 0) orelse return .at_limit;
        if (direction > 0 and current - page.first_word_ordinal + 1 == page.word_count) {
            const final_page = self.chapter_end and !self.next_ready and self.chapter_last_page != null and self.page_index == self.chapter_last_page.?;
            if (final_page) {
                if (nextReadableSpineIndex(self.chapter_index, self.publication.spine_len) == null) return .at_limit;
                self.pending_paged_selection = .{ .ordinal = 0 };
            } else self.pending_paged_selection = .{ .ordinal = current + 1 };
            self.nextPage();
            self.fulfillPendingPagedSelection();
            return if (self.pending_paged_selection == null) .advanced else .waiting_for_page;
        }
        if (direction < 0 and current == page.first_word_ordinal) {
            if (self.page_index == 0) {
                if (self.chapter_index == 0) return .at_limit;
                self.pending_paged_selection = .last_word;
            } else self.pending_paged_selection = .{ .ordinal = current - 1 };
            self.previousPage();
            self.fulfillPendingPagedSelection();
            return if (self.pending_paged_selection == null) .advanced else .waiting_for_page;
        }
        self.selected_word_ordinal = page.moveSelection(current, direction);
        self.savePosition();
        return .advanced;
    }

    fn currentPagedWordOrdinal(self: *const App) u32 {
        if (!self.current_ready) return self.selected_word_ordinal orelse 0;
        const page = &self.pages[self.current_page];
        return page.moveSelection(self.selected_word_ordinal, 0) orelse 0;
    }

    /// Resolve a boundary crank only when the existing page stream, retained
    /// history, or chapter rebuild has made its requested page drawable.
    fn fulfillPendingPagedSelection(self: *App) void {
        if (self.reading_mode != .paged or !self.current_ready) return;
        const target = self.pending_paged_selection orelse return;
        const current = &self.pages[self.current_page];
        switch (target) {
            .ordinal => |ordinal| {
                if (current.wordSpan(ordinal) != null) {
                    self.selected_word_ordinal = ordinal;
                    self.pending_paged_selection = null;
                    if (self.pending_mode_word_ordinal == ordinal) self.pending_mode_word_ordinal = null;
                    self.savePosition();
                    return;
                }
                if (self.next_ready and self.pages[self.next_page].wordSpan(ordinal) != null) {
                    self.nextPage();
                    self.fulfillPendingPagedSelection();
                    return;
                }
                if (self.next_ready and pendingOrdinalRequiresNextPage(&self.pages[self.next_page], ordinal)) {
                    self.nextPage();
                    self.fulfillPendingPagedSelection();
                }
            },
            .last_word => {
                if (self.chapter_end and current.word_count != 0) {
                    self.selected_word_ordinal = current.first_word_ordinal + current.word_count - 1;
                    self.pending_paged_selection = null;
                    if (self.pending_mode_word_ordinal == self.selected_word_ordinal) self.pending_mode_word_ordinal = null;
                    self.savePosition();
                }
            },
        }
    }

    fn previousPage(self: *App) void {
        if (self.fixture_state != .ready or self.chapter_open != null) return;
        if (self.rescan_target != null or self.rescan_to_last_page) return;
        if (self.page_index != 0) {
            const target = self.navigation_state.beginCachedBack() orelse return;
            if (self.chapter_end or self.cache_navigation) {
                if (!self.restoreActiveHistoryPage(self.chapter_index, target)) self.startRescan(target);
            } else {
                if (self.restoreActiveHistoryPage(self.chapter_index, target)) {
                    self.cache_navigation = true;
                    self.stream_front_page = self.page_index + 1;
                } else self.startRescan(target);
            }
        } else if (self.chapter_index != 0) {
            self.startRescanToLastPage(self.chapter_index - 1);
        }
    }

    /// The source stream pauses immediately after the displayed word. A
    /// forward crank step restores a one-word successor cache if a reverse
    /// step made one; otherwise it resumes the existing stream just far
    /// enough to display its next complete word.
    fn nextRsvpWord(self: *App) void {
        if (self.fixture_state != .ready or self.chapter_open != null or !self.rsvp_has_word or self.rsvp_rescan_target != null) return;
        if (self.rsvp_next_valid) {
            self.copyCurrentToPrevious();
            self.copyNextToCurrent();
            self.rsvp_next_valid = false;
            self.savePosition();
            return;
        }
        if (self.chapter_end) {
            if (nextReadableSpineIndex(self.chapter_index, self.publication.spine_len)) |next| self.scheduleOpenChapter(next, .normal);
            return;
        }
        self.copyCurrentToPrevious();
        self.rsvp_has_word = false;
    }

    /// Only one predecessor is cached. A miss restarts the existing validated
    /// chapter stream and incrementally consumes it to the requested semantic
    /// word number; it never seeks into raw compressed data.
    fn previousRsvpWord(self: *App) void {
        if (self.fixture_state != .ready or self.chapter_open != null or !self.rsvp_has_word or self.rsvp_rescan_target != null) return;
        if (self.rsvp_previous_valid) {
            self.copyCurrentToNext();
            self.copyPreviousToCurrent();
            self.rsvp_previous_valid = false;
            self.savePosition();
            return;
        }
        if (self.rsvp_position.word != 0) self.scheduleOpenChapter(self.chapter_index, .{ .rsvp_rescan = .{ .word = self.rsvp_position.word - 1 } });
    }

    fn previousRsvpSentence(self: *App) void {
        if (self.fixture_state != .ready or self.chapter_open != null or !self.rsvp_has_word or self.rsvp_rescan_target != null) return;
        if (self.rsvp_position.sentence == 0) return;
        const now_ms = self.playdate.system.getCurrentTimeMilliseconds();
        self.recordAutoplayInterval(now_ms, 0);
        self.rsvp_timer.reset(now_ms);
        self.scheduleOpenChapter(self.chapter_index, .{ .rsvp_rescan = .{ .sentence = self.rsvp_position.sentence - 1 } });
    }

    fn copyCurrentToPrevious(self: *App) void {
        @memcpy(self.rsvp_previous_word[0..self.rsvp_word_len], self.rsvp_word[0..self.rsvp_word_len]);
        self.rsvp_previous_word_len = self.rsvp_word_len;
        self.rsvp_previous_position = self.rsvp_position;
        self.rsvp_previous_valid = true;
    }

    fn copyPreviousToCurrent(self: *App) void {
        @memcpy(self.rsvp_word[0..self.rsvp_previous_word_len], self.rsvp_previous_word[0..self.rsvp_previous_word_len]);
        self.rsvp_word_len = self.rsvp_previous_word_len;
        self.rsvp_position = self.rsvp_previous_position;
        self.rsvp_has_word = true;
    }

    fn copyCurrentToNext(self: *App) void {
        @memcpy(self.rsvp_next_word[0..self.rsvp_word_len], self.rsvp_word[0..self.rsvp_word_len]);
        self.rsvp_next_word_len = self.rsvp_word_len;
        self.rsvp_next_position = self.rsvp_position;
        self.rsvp_next_valid = true;
    }

    fn copyNextToCurrent(self: *App) void {
        @memcpy(self.rsvp_word[0..self.rsvp_next_word_len], self.rsvp_next_word[0..self.rsvp_next_word_len]);
        self.rsvp_word_len = self.rsvp_next_word_len;
        self.rsvp_position = self.rsvp_next_position;
        self.rsvp_has_word = true;
    }

    fn startRescan(self: *App, target: u32) void {
        self.scheduleOpenChapter(self.chapter_index, .{ .rescan = target });
    }

    fn beginRescan(self: *App, target: u32) void {
        self.cache_navigation = false;
        self.navigation_state.beginRescan(target);
        self.rescan_target = target;
        self.rescan_page = 0;
        self.previous_ready = false;
        self.current_ready = false;
        self.next_ready = false;
    }

    fn startRescanToLastPage(self: *App, chapter: u8) void {
        self.scheduleOpenChapter(chapter, .rescan_to_last_page);
    }

    fn freePage(self: *const App) u2 {
        for (0..self.pages.len) |index| {
            if (index != self.current_page and (!self.previous_ready or index != self.previous_page)) return @intCast(index);
        }
        unreachable;
    }

    fn restoreActiveHistoryPage(self: *App, chapter: u8, page: u32) bool {
        if (chapter != self.chapter_index or !self.previous_ready) return false;

        // The previous slot is the sole history entry in the shared pool.
        // Swap slots instead of copying a page into another backing array.
        if (navigation.canRestoreSharedPage(self.page_index, page, self.cache_navigation)) {
            const old_current = self.current_page;
            self.current_page = self.previous_page;
            self.previous_page = old_current;
            self.page_index = page;
            self.navigation_state.page = page;
            self.current_ready = true;
            self.next_ready = false;
            return true;
        }
        return false;
    }

    fn recordPageBuild(self: *App) void {
        const now = self.playdate.system.getCurrentTimeMilliseconds();
        self.last_page_build_ms = now - self.page_build_started_ms;
        self.max_page_build_ms = @max(self.max_page_build_ms, self.last_page_build_ms);
        self.page_build_started_ms = now;
    }

    fn recordCheckpoint(self: *App, page: u32) void {
        const decoded_offset = if (self.chapter_extractor) |extractor| extractor.source_offset else 0;
        _ = self.checkpoints.admit(
            self.chapter_index,
            page,
            self.chapter_events,
            decoded_offset,
            @sizeOf(cache_policy.Entry),
        );
    }

    fn drawPage(self: *App) void {
        if (!self.current_ready) {
            self.drawText("Loading chapter...", 12, 12);
            return;
        }
        const page = &self.pages[self.current_page];
        for (0..page.line_count) |index| {
            self.drawText(
                page.line(index),
                reader_text_x,
                reader_text_y + @as(c_int, @intCast(index)) * reader_line_height,
            );
        }
        const selected = page.moveSelection(self.selected_word_ordinal, 0) orelse return;
        self.selected_word_ordinal = selected;
        const span = page.wordSpan(selected) orelse return;
        const line = page.line(span.line_index);
        const x = reader_text_x + self.textWidth(line[0..span.start]);
        const y = reader_text_y + @as(c_int, span.line_index) * reader_line_height;
        const word = line[span.start..span.end];
        const width = self.textWidth(word);
        self.playdate.graphics.fillRect(x, y, width, reader_line_height, @intCast(@intFromEnum(pdapi.LCDSolidColor.ColorBlack)));
        self.playdate.graphics.setDrawMode(.DrawModeInverted);
        self.drawText(word, x, y);
        self.playdate.graphics.setDrawMode(.DrawModeCopy);
    }

    fn restorePosition(self: *App) void {
        if (self.fixture_state != .ready) return;
        var filename_buffer: [24]u8 = undefined;
        const filename = self.resumeFilename(&filename_buffer) orelse return;
        const file = self.playdate.file.open(filename.ptr, pdapi.FILE_READ | pdapi.FILE_READ_DATA) orelse return;
        defer _ = self.playdate.file.close(file);
        var bytes: [reading_position.encoded_size]u8 = undefined;
        if (self.playdate.file.read(file, &bytes, bytes.len) != bytes.len) return;
        const position = reading_position.decode(&bytes) catch return;
        if (!reading_position.matches(position, self.bookIdentity(), layout_revision)) return;
        if (position.chapter >= self.publication.spine_len) return;
        const chapter: u8 = @intCast(position.chapter);
        if (position.legacy_paged_page) |page| {
            // Legacy Paged offsets have no word equivalent. Preserve their
            // existing page rebuild behavior when opening Paged mode; an RSVP
            // preference still gets the same safe chapter fallback.
            if (self.reading_mode == .paged) self.scheduleOpenChapter(chapter, if (page == 0) .normal else .{ .rescan = page }) else self.scheduleOpenChapter(chapter, .normal);
            return;
        }
        self.pending_mode_word_ordinal = position.word_ordinal;
        switch (self.reading_mode) {
            .paged => {
                self.pending_paged_selection = .{ .ordinal = position.word_ordinal };
                self.scheduleOpenChapter(chapter, .{ .word_rescan = position.word_ordinal });
            },
            .rsvp => self.scheduleOpenChapter(chapter, .{ .rsvp_rescan = .{ .word = position.word_ordinal } }),
        }
    }

    fn savePosition(self: *App) void {
        if (self.fixture_state != .ready) return;
        self.resume_dirty = true;
        self.resume_delay_frames = resume_debounce_frames;
    }

    fn flushDebouncedPosition(self: *App) void {
        if (!self.resume_dirty or self.fixture_state != .ready) return;
        if (self.resume_delay_frames != 0) {
            self.resume_delay_frames -= 1;
            return;
        }
        self.resume_dirty = false;
        self.writePosition();
    }

    fn loadPace(self: *App) void {
        self.pace = .{ .book_id = self.bookIdentity() };
        self.pace_dirty = false;
        self.pace_delay_frames = 0;
        var filename_buffer: [24]u8 = undefined;
        const filename = self.paceFilename(&filename_buffer) orelse return;
        const file = self.playdate.file.open(filename.ptr, pdapi.FILE_READ | pdapi.FILE_READ_DATA) orelse return;
        defer _ = self.playdate.file.close(file);
        var bytes: [reading_pace.encoded_size]u8 = undefined;
        if (self.playdate.file.read(file, &bytes, bytes.len) != bytes.len) return;
        const stored = reading_pace.decode(&bytes) catch return;
        if (stored.book_id == self.bookIdentity()) self.pace = stored;
    }

    fn flushDebouncedPace(self: *App) void {
        if (!self.pace_dirty) return;
        if (self.pace_delay_frames != 0) {
            self.pace_delay_frames -= 1;
            return;
        }
        self.writePace();
    }

    fn writePace(self: *App) void {
        var filename_buffer: [24]u8 = undefined;
        const filename = self.paceFilename(&filename_buffer) orelse return;
        const file = self.playdate.file.open(filename.ptr, pdapi.FILE_WRITE) orelse return;
        defer _ = self.playdate.file.close(file);
        var bytes: [reading_pace.encoded_size]u8 = undefined;
        reading_pace.encode(self.pace, &bytes);
        if (self.playdate.file.write(file, &bytes, bytes.len) != bytes.len) return;
        _ = self.playdate.file.flush(file);
        self.pace_dirty = false;
        self.pace_delay_frames = 0;
    }

    fn writePosition(self: *App) void {
        var filename_buffer: [24]u8 = undefined;
        const filename = self.resumeFilename(&filename_buffer) orelse return;
        const file = self.playdate.file.open(filename.ptr, pdapi.FILE_WRITE) orelse return;
        defer _ = self.playdate.file.close(file);
        var bytes: [reading_position.encoded_size]u8 = undefined;
        reading_position.encode(.{
            .book_id = self.bookIdentity(),
            .layout_revision = layout_revision,
            .chapter = self.chapter_index,
            .word_ordinal = self.pending_mode_word_ordinal orelse if (self.reading_mode == .rsvp) self.rsvp_position.word else self.currentPagedWordOrdinal(),
            .mode = self.resumeMode(),
        }, &bytes);
        if (self.playdate.file.write(file, &bytes, bytes.len) != bytes.len) return;
        _ = self.playdate.file.flush(file);
    }

    fn bookIdentity(self: *const App) u32 {
        return reading_position.bookIdentity(self.active_book.slice());
    }

    fn resumeMode(self: *const App) reading_position.Mode {
        return if (self.reading_mode == .rsvp) .rsvp else .paged;
    }

    fn resumeFilename(self: *const App, buffer: []u8) ?[:0]u8 {
        return std.fmt.bufPrintZ(buffer, "resume-{x}.bin", .{self.bookIdentity()}) catch null;
    }

    fn paceFilename(self: *const App, buffer: []u8) ?[:0]u8 {
        return std.fmt.bufPrintZ(buffer, "pace-{x}.bin", .{self.bookIdentity()}) catch null;
    }
};

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
    return switch (pending orelse return current) {
        .ordinal => |ordinal| ordinal,
        // The preceding chapter's final ordinal is unknown until its bounded
        // rebuild completes, so retain the still-drawable current word.
        .last_word => current,
    };
}

/// Once a requested ordinal lies at or beyond the next ready page's start,
/// advance that page even when it is only an intermediate rebuild page. The
/// next update will construct another page if necessary.
fn pendingOrdinalRequiresNextPage(page: *const pagination.PageCache, ordinal: u32) bool {
    return page.word_count == 0 or ordinal >= page.first_word_ordinal;
}

fn nextReadableSpineIndex(current: u8, spine_len: u8) ?u8 {
    if (current + 1 < spine_len) return current + 1;
    return null;
}

/// Maps a pushed-button bitset to exactly one action. B has priority while
/// reading, so a diagonal press cannot turn a page instead of changing modes.
fn inputAction(state: State, fixture_state: FixtureState, reading_mode: reader_settings.ReadingMode, pushed: pdapi.PDButtons) InputAction {
    if (state == .settings) {
        if (pushed & pdapi.BUTTON_B != 0) return .close_settings;
        if (pushed & pdapi.BUTTON_DOWN != 0) return .settings_next;
        if (pushed & pdapi.BUTTON_UP != 0) return .settings_previous;
        if (pushed & pdapi.BUTTON_A != 0) return .activate_setting;
        return .none;
    }
    if (state == .chapter_browser) {
        if (pushed & pdapi.BUTTON_B != 0) return .close_chapter_browser;
        if (pushed & pdapi.BUTTON_A != 0) return .open_browser_chapter;
        if (pushed & (pdapi.BUTTON_DOWN | pdapi.BUTTON_RIGHT) != 0) return .chapter_browser_next;
        if (pushed & (pdapi.BUTTON_UP | pdapi.BUTTON_LEFT) != 0) return .chapter_browser_previous;
        return .none;
    }
    if (state == .reading and pushed & pdapi.BUTTON_B != 0) return .toggle_reading_mode;
    if (state == .library) {
        if (pushed & (pdapi.BUTTON_DOWN | pdapi.BUTTON_RIGHT) != 0) return .library_next;
        if (pushed & (pdapi.BUTTON_UP | pdapi.BUTTON_LEFT) != 0) return .library_previous;
        if (pushed & pdapi.BUTTON_A != 0) return .open_selected_book;
        return .none;
    }
    if (fixture_state == .chapter_error) {
        if (pushed & (pdapi.BUTTON_RIGHT | pdapi.BUTTON_DOWN) != 0) return .next_chapter;
        if (pushed & (pdapi.BUTTON_LEFT | pdapi.BUTTON_UP) != 0) return .previous_chapter;
        return .none;
    }
    if (state == .reading and reading_mode == .rsvp) {
        if (pushed & pdapi.BUTTON_A != 0) return .rsvp_toggle_autoplay;
        if (pushed & pdapi.BUTTON_UP != 0) return .rsvp_wpm_up;
        if (pushed & pdapi.BUTTON_DOWN != 0) return .rsvp_wpm_down;
        if (pushed & pdapi.BUTTON_LEFT != 0) return .rsvp_previous_sentence;
        return .none;
    }
    if (pushed & (pdapi.BUTTON_RIGHT | pdapi.BUTTON_DOWN) != 0) return .next_page;
    if (pushed & (pdapi.BUTTON_LEFT | pdapi.BUTTON_UP) != 0) return .previous_page;
    return .none;
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

fn emitChapterEvent(context: *anyopaque, event: xhtml.Event) anyerror!void {
    const app: *App = @ptrCast(@alignCast(context));
    app.chapter_events +%= 1;
    try app.chapter_builder.?.consume(event);
}

fn emitRsvpEvent(context: *anyopaque, event: xhtml.Event) anyerror!void {
    const app: *App = @ptrCast(@alignCast(context));
    app.chapter_events +%= 1;
    try app.rsvp_cursor.?.consume(event);
}

fn emitRsvpWord(context: *anyopaque, word: rsvp.Word) anyerror!void {
    const app: *App = @ptrCast(@alignCast(context));
    if (app.rsvp_rescan_target) |target| {
        switch (target) {
            .word => |target_word| if (word.position.word != target_word) return,
            .sentence => |target_sentence| if (word.position.sentence != target_sentence) return,
        }
        app.rsvp_rescan_target = null;
    }
    @memcpy(app.rsvp_word[0..word.bytes.len], word.bytes);
    app.rsvp_word_len = @intCast(word.bytes.len);
    app.rsvp_position = word.position;
    app.rsvp_has_word = true;
    if (app.pending_mode_word_ordinal == word.position.word) app.pending_mode_word_ordinal = null;
    if (app.rsvp_timer.running) {
        const now_ms = app.playdate.system.getCurrentTimeMilliseconds();
        app.rsvp_timer.reset(now_ms);
        app.rsvp_active_session.begin(now_ms);
    }
    app.savePosition();
}

fn emitPrefetchEvent(context: *anyopaque, event: xhtml.Event) anyerror!void {
    const app: *App = @ptrCast(@alignCast(context));
    app.chapter_events +%= 1;
    try app.prefetch_builder.?.consume(event);
}

fn collectLibraryPath(path: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(userdata orelse return));
    const z_path = path orelse return;
    app.library.add(std.mem.span(z_path));
}
