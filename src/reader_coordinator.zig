const std = @import("std");
const input = @import("reader_input.zig");
const chapter_browser = @import("chapter_browser.zig");
const library_storage = @import("storage/library.zig");
const reading_pace = @import("storage/pace.zig");
const paged_reader = @import("paged_reader.zig");
const rsvp_reader = @import("rsvp_reader.zig");
const pagination = @import("content/pagination.zig");
const rsvp = @import("content/rsvp.zig");
const cache_policy = @import("content/cache_policy.zig");
const decode_workspace = @import("decode_workspace.zig");
const opening_session = @import("opening_session.zig");
const persistence = @import("storage/persistence.zig");
const zip = @import("archive/zip.zig");
const epub = @import("publication/epub.zig");
const deflate = @import("archive/deflate.zig");
const limits = @import("limits").reader;
const telemetry = @import("telemetry.zig");
const reader_host = @import("reader_host.zig");
const reader_transitions = @import("reader_transitions.zig");
const reader_layout = @import("reader_layout.zig");

const prefetch_directory_records_per_step: usize = 8;
const layout_revision: u16 = 1;
const resume_debounce_frames: u8 = 60;
const pace_debounce_frames: u8 = 60;
const crank_degrees_per_word: f32 = 15;
pub const default_checkpoint_byte_budget = cache_policy.capacity * @sizeOf(cache_policy.Entry);
pub const page_pool_reserved_bytes = paged_reader.PagedReader.page_pool_reserved_bytes;
pub const word_pool_reserved_bytes = rsvp_reader.RsvpReader.word_pool_reserved_bytes;
pub const reader_cache_reserved_bytes = page_pool_reserved_bytes + word_pool_reserved_bytes;

fn paginationMeasure(measure: reader_host.TextMeasure) pagination.Measure {
    const font_height = if (measure.font_height) |height| height(measure.context) else 20;
    return .{
        .context = measure.context,
        .width = measure.width,
        .line_limit = reader_layout.pageLineLimit(font_height, pagination.max_lines),
    };
}

/// Platform-independent vocabulary at the boundary between the Playdate
/// façade and reader behavior. ZIP, XHTML, persistence, and graphics handles
/// are intentionally absent from these types.
pub const Screen = enum {
    library,
    opening,
    reading,
    settings,
    chapter_browser,
    unsupported_book,
    malformed_book,
    chapter_error,
};

pub const ReadingMode = enum { paged, rsvp };
pub const Readiness = enum { opening, ready, chapter_error };
pub const Lifecycle = enum {
    opening,
    ready,
    unavailable,
    invalid_archive,
    missing_mimetype,
    invalid_mimetype,
    chapter_error,
};
pub const ChapterFailure = enum { archive, tokenizer, page_limit, no_supported_text };

pub const ChapterOpenAction = union(enum) {
    normal,
    rescan: u32,
    word_rescan: u32,
    rsvp_rescan: rsvp_reader.RsvpReader.RescanTarget,
    rescan_to_last_page,
};

pub const ChapterOpenJob = struct {
    index: u8,
    action: ChapterOpenAction,
    scanner: ?zip.ArchiveScanner = null,
    finder: ?zip.EntryFinder = null,
};

pub const ChapterStep = struct {
    worked: bool = false,
    position_changed: bool = false,
    request_prefetch: bool = false,
};

pub const FrameInput = struct {
    buttons: input.Buttons = .{},
    crank_change: f32 = 0,
    crank_docked: bool = false,
};

pub const SystemAction = enum { library, settings, chapters };
const PagedSelectionMove = enum { advanced, waiting_for_page, at_limit };

/// Owns UI lifecycle transitions. Reader engines report readiness and semantic
/// navigation; the coordinator owns which screen is currently active.
pub const ReaderCoordinator = struct {
    screen: Screen = .library,
    screen_before_settings: Screen = .reading,
    mode: ReadingMode = .paged,
    settings_selected: u1 = 0,
    library: library_storage.Library = .{},
    active_book: library_storage.Book = .{},
    pace: reading_pace.Stats = .{ .book_id = 0 },
    pending_mode_word_ordinal: ?u32 = null,
    chapter_browser: chapter_browser.Model = .{},
    paged: paged_reader.PagedReader,
    rsvp_reader: rsvp_reader.RsvpReader,
    decode_workspace: decode_workspace.DecodeWorkspace = .{},
    opening_job: ?opening_session.Session = null,
    /// A successful opener asks the platform façade to begin this chapter.
    /// The façade supplies only the stable chapter file lease; it does not
    /// decide whether opening succeeded or which navigation fallback won.
    opening_chapter_request: ?u8 = null,
    persistence: ?persistence.Service = null,
    chapter_open: ?ChapterOpenJob = null,
    chapter_lease_open: bool = false,
    active_prefetch_lease: bool = false,
    chapter_index: u8 = 0,
    chapter_end: bool = false,
    pending_prefetch_transition: ?u8 = null,
    lifecycle: Lifecycle = .opening,
    chapter_failure: ChapterFailure = .archive,
    zip_entries: [epub.max_manifest_items]zip.IndexedEntry = undefined,
    archive_index: ?zip.DirectoryIndex = null,
    publication: epub.Publication = undefined,
    archive_scan_buffer: [1024]u8 = undefined,
    archive_filename_buffer: [limits.max_archive_filename_bytes]u8 = undefined,
    deflate_input_buffer: [limits.compressed_input_bytes]u8 = undefined,
    deflate_window: [32 * 1024]u8 = undefined,
    deflate_workspace: deflate.Workspace = undefined,
    opening_storage: zip.StreamStorage = undefined,
    chapter_stream: ?zip.EntryStream = null,
    chapter_storage: zip.StreamStorage = undefined,
    chapter_output: [limits.decoded_output_chunk_bytes]u8 = undefined,
    chapter_output_start: usize = 0,
    chapter_output_end: usize = 0,
    telemetry: telemetry.Telemetry = .{},
    crank_accumulated: f32 = 0,
    crank_docked: bool = false,
    host: ?reader_host.ReaderHost = null,
    allocator: ?std.mem.Allocator = null,

    /// Initializes this large, heap-resident state directly in place.  Do not
    /// return it by value: that creates a large temporary on the Playdate's
    /// small callback stack.
    pub fn initInPlace(self: *ReaderCoordinator, checkpoint_byte_budget: usize) void {
        self.* = undefined;
        self.screen = .library;
        self.screen_before_settings = .reading;
        self.mode = .paged;
        self.settings_selected = 0;
        self.library = .{};
        self.active_book = .{};
        self.pace = .{ .book_id = 0 };
        self.pending_mode_word_ordinal = null;
        self.chapter_browser = .{};
        self.paged.initInPlace(checkpoint_byte_budget);
        self.rsvp_reader.initInPlace();
        self.decode_workspace = .{};
        self.opening_job = null;
        self.opening_chapter_request = null;
        self.persistence = null;
        self.chapter_open = null;
        self.chapter_lease_open = false;
        self.active_prefetch_lease = false;
        self.chapter_index = 0;
        self.chapter_end = false;
        self.pending_prefetch_transition = null;
        self.lifecycle = .opening;
        self.chapter_failure = .archive;
        self.archive_index = null;
        self.chapter_stream = null;
        self.chapter_output_start = 0;
        self.chapter_output_end = 0;
        self.telemetry = .{};
        self.crank_accumulated = 0;
        self.crank_docked = false;
        self.host = null;
        self.allocator = null;
    }

    /// Attaches stable, platform-neutral capabilities for reader work. The
    /// host context must outlive this coordinator.
    pub fn attachHost(self: *ReaderCoordinator, host: reader_host.ReaderHost) void {
        self.host = host;
    }

    /// Opening owns temporary package storage through this allocator. It is
    /// intentionally separate from ReaderHost because allocation is not a
    /// platform-reader capability.
    pub fn attachAllocator(self: *ReaderCoordinator, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
    }

    pub fn measureText(self: *const ReaderCoordinator, text: []const u8) usize {
        const measure = self.host.?.measure;
        return measure.width(measure.context, text);
    }

    /// Rebuilds the bounded library through the platform-neutral file lister.
    pub fn discoverLibrary(self: *ReaderCoordinator) void {
        const files = self.host.?.files orelse return;
        self.library = .{};
        files.list_epubs(files.context, &self.library);
    }

    pub fn attachPersistence(self: *ReaderCoordinator, service: persistence.Service) void {
        self.persistence = service;
    }

    pub fn loadSettings(self: *ReaderCoordinator) void {
        const settings = self.persistence.?.loadSettings();
        self.mode = if (settings.reading_mode == .rsvp) .rsvp else .paged;
        self.rsvp_reader.wpm = settings.rsvp_wpm;
    }

    pub fn saveSettings(self: *ReaderCoordinator) void {
        _ = self.persistence.?.saveSettings(.{
            .reading_mode = if (self.mode == .rsvp) .rsvp else .paged,
            .rsvp_wpm = self.rsvp_reader.wpm,
        });
    }

    pub fn requestPositionSave(self: *ReaderCoordinator) void {
        if (self.lifecycle == .ready) self.persistence.?.requestWrite(.position, resume_debounce_frames);
    }

    pub fn requestPaceSave(self: *ReaderCoordinator) void {
        self.persistence.?.requestWrite(.pace, pace_debounce_frames);
    }

    pub fn flushPersistence(self: *ReaderCoordinator) void {
        if (self.persistence) |*service| {
            if (self.lifecycle == .ready) _ = service.flushPositionIfDue(self.positionSnapshot());
            _ = service.flushPaceIfDue(self.pace);
        }
    }

    pub fn flushPositionNow(self: *ReaderCoordinator) void {
        if (self.persistence) |*service| _ = service.flushPositionNow(self.positionSnapshot());
    }

    pub fn flushPaceNow(self: *ReaderCoordinator) void {
        if (self.persistence) |*service| _ = service.flushPendingPace(self.pace);
    }

    pub fn restorePosition(self: *ReaderCoordinator) void {
        if (self.lifecycle != .ready) return;
        const service = &(self.persistence orelse return);
        const restored = service.loadPosition(self.bookIdentity(), layout_revision) orelse return;
        switch (restored) {
            .legacy_paged_page => |legacy| {
                if (legacy.chapter >= self.publication.spine_len) return;
                const chapter: u8 = @intCast(legacy.chapter);
                if (self.mode == .paged) self.openChapter(chapter, if (legacy.page == 0) .normal else .{ .rescan = legacy.page }) else self.openChapter(chapter, .normal);
            },
            .snapshot => |snapshot| {
                if (snapshot.chapter >= self.publication.spine_len) return;
                const chapter: u8 = @intCast(snapshot.chapter);
                self.pending_mode_word_ordinal = snapshot.word_ordinal;
                switch (self.mode) {
                    .paged => {
                        self.paged.pending_selection = .{ .ordinal = snapshot.word_ordinal };
                        self.openChapter(chapter, .{ .word_rescan = snapshot.word_ordinal });
                    },
                    .rsvp => self.openChapter(chapter, .{ .rsvp_rescan = .{ .word = snapshot.word_ordinal } }),
                }
            },
        }
    }

    pub fn positionSnapshot(self: *const ReaderCoordinator) persistence.ReadingSnapshot {
        return .{
            .book_id = self.bookIdentity(),
            .layout_revision = layout_revision,
            .chapter = self.chapter_index,
            .word_ordinal = self.pending_mode_word_ordinal orelse if (self.mode == .rsvp) self.rsvp_reader.position().word else self.currentPagedWordOrdinal(),
            .mode = if (self.mode == .rsvp) .rsvp else .paged,
        };
    }

    fn currentPagedWordOrdinal(self: *const ReaderCoordinator) u32 {
        const page = self.paged.current() orelse return self.paged.selected_word_ordinal orelse 0;
        return page.moveSelection(self.paged.selected_word_ordinal, 0) orelse 0;
    }

    fn bookIdentity(self: *const ReaderCoordinator) u32 {
        return persistence.Service.bookIdentity(self.active_book.slice());
    }

    pub fn beginOpening(self: *ReaderCoordinator) void {
        self.screen = .opening;
    }

    pub fn returnToLibrary(self: *ReaderCoordinator) void {
        self.screen = .library;
    }

    /// Performs the complete semantic exit from a book. Stable platform file
    /// handles are released through ReaderHost slot callbacks.
    pub fn leaveBook(self: *ReaderCoordinator, now_ms: u32) void {
        self.rsvp_reader.stopAutoplay(now_ms, &self.pace);
        self.flushPaceNow();
        if (self.lifecycle == .ready) self.flushPositionNow();
        self.cancelOpening();
        self.cancelPrefetch();
        self.cancelChapter();
        self.paged.builder = null;
        self.archive_index = null;
        self.paged.rescan = .none;
        self.paged.pending_selection = null;
        self.pending_mode_word_ordinal = null;
        self.pending_prefetch_transition = null;
        self.paged.detent_backlog = 0;
        self.returnToLibrary();
        self.lifecycle = .opening;
    }

    pub fn openSettings(self: *ReaderCoordinator) bool {
        if (self.screen != .reading) return false;
        self.screen_before_settings = self.screen;
        self.screen = .settings;
        return true;
    }

    pub fn closeSettings(self: *ReaderCoordinator) bool {
        if (self.screen != .settings) return false;
        self.screen = self.screen_before_settings;
        return true;
    }

    pub fn openChapterBrowser(self: *ReaderCoordinator) bool {
        if (self.screen != .reading) return false;
        self.screen = .chapter_browser;
        return true;
    }

    pub fn closeChapterBrowser(self: *ReaderCoordinator) bool {
        if (self.screen != .chapter_browser) return false;
        self.screen = .reading;
        return true;
    }

    pub fn beginReading(self: *ReaderCoordinator) void {
        self.screen = .reading;
    }

    pub fn toggleMode(self: *ReaderCoordinator) void {
        self.mode = switch (self.mode) {
            .paged => .rsvp,
            .rsvp => .paged,
        };
    }

    pub fn moveSettingsSelection(self: *ReaderCoordinator, direction: i8) void {
        if (self.screen != .settings or direction == 0) return;
        self.settings_selected = if (self.settings_selected == 0) 1 else 0;
    }

    pub fn openChapters(self: *ReaderCoordinator, entry_count: u8, current: u8) bool {
        if (entry_count == 0 or !self.openChapterBrowser()) return false;
        self.chapter_browser = chapter_browser.Model.init(entry_count, current);
        return true;
    }

    pub fn selectBook(self: *ReaderCoordinator) ?*const library_storage.Book {
        const selected = self.library.selectedBook() orelse return null;
        self.active_book = selected.*;
        return &self.active_book;
    }

    /// Starts a fresh opening workflow for the selected library entry.
    pub fn openSelectedBook(self: *ReaderCoordinator) bool {
        _ = self.selectBook() orelse return false;
        if (self.persistence) |*service| self.pace = service.loadPace(persistence.Service.bookIdentity(self.active_book.slice()));
        self.lifecycle = .opening;
        self.beginOpening();
        self.opening_job = opening_session.Session.start();
        self.opening_chapter_request = null;
        return true;
    }

    /// Advances a bounded opening phase owned by the coordinator. Later
    /// metadata phases remain bounded and are migrated separately.
    pub fn advanceOpening(self: *ReaderCoordinator) void {
        const job = &(self.opening_job orelse return);
        switch (job.phase) {
            .open => {
                const files = self.host.?.files orelse {
                    self.failOpening(.unavailable);
                    return;
                };
                const reader = files.open(files.context, .opening, self.active_book.zSlice()) catch {
                    self.failOpening(.unavailable);
                    return;
                };
                job.beginArchiveScan(.{ .context = self, .close = closeOpeningHostLease }, reader) catch {
                    self.failOpening(.invalid_archive);
                };
            },
            .scan_archive => {
                _ = job.stepArchiveScan() catch {
                    self.failOpening(.invalid_archive);
                };
            },
            .validate_directory => {
                const complete = job.stepDirectoryValidation() catch {
                    self.failOpening(.invalid_archive);
                    return;
                };
                if (!complete) return;
                self.archive_index = job.copyDirectoryIndex(&self.zip_entries) catch {
                    self.failOpening(.invalid_archive);
                    return;
                };
            },
            .find_mimetype => {
                const entry = self.archive_index.?.find("mimetype") catch {
                    self.failOpening(.missing_mimetype);
                    return;
                };
                self.beginMetadataRead(job, entry, .mimetype) catch {
                    self.failOpening(.invalid_mimetype);
                };
            },
            .read_mimetype => if (self.advanceMetadataRead(job, .invalid_mimetype)) {
                if (!job.mimetypeIsValid()) {
                    self.failOpening(.invalid_mimetype);
                    return;
                }
                job.finishMetadataRead(.mimetype);
            },
            .find_container => {
                const entry = self.archive_index.?.find("META-INF/container.xml") catch {
                    self.failOpening(.invalid_archive);
                    return;
                };
                self.beginMetadataRead(job, entry, .container) catch {
                    self.failOpening(.invalid_archive);
                };
            },
            .read_container => if (self.advanceMetadataRead(job, .invalid_archive)) {
                job.finishMetadataRead(.container);
            },
            .parse_container => job.parseContainer() catch {
                self.failOpening(.invalid_archive);
            },
            .find_package => {
                const entry = self.archive_index.?.find(job.packagePath()) catch {
                    self.failOpening(.invalid_archive);
                    return;
                };
                if (entry.uncompressed_size == 0 or entry.uncompressed_size > epub.max_package_document_bytes) {
                    self.failOpening(.invalid_archive);
                    return;
                }
                const allocator = self.allocator orelse {
                    self.failOpening(.invalid_archive);
                    return;
                };
                job.package_xml = allocator.alloc(u8, entry.uncompressed_size) catch {
                    self.failOpening(.invalid_archive);
                    return;
                };
                self.beginMetadataRead(job, entry, .package) catch {
                    self.failOpening(.invalid_archive);
                };
            },
            .read_package => if (self.advanceMetadataRead(job, .invalid_archive)) {
                job.finishMetadataRead(.package);
            },
            .parse_package => {
                const package_xml = job.package_xml orelse {
                    self.failOpening(.invalid_archive);
                    return;
                };
                const allocator = self.allocator orelse {
                    self.failOpening(.invalid_archive);
                    return;
                };
                job.opf_workspace = allocator.create(epub.OpfWorkspace) catch {
                    self.failOpening(.invalid_archive);
                    return;
                };
                epub.parseOpf(package_xml[0..job.output_len], job.packagePath(), &self.publication, job.opf_workspace.?) catch {
                    self.failOpening(.invalid_archive);
                    return;
                };
                job.finishPackageParsing(allocator);
            },
            .find_navigation => self.beginNavigationRead(job, .epub3),
            .read_navigation => self.advanceNavigationRead(job, .epub3),
            .find_ncx => self.beginNavigationRead(job, .ncx),
            .read_ncx => self.advanceNavigationRead(job, .ncx),
        }
    }

    fn beginNavigationRead(self: *ReaderCoordinator, job: *opening_session.Session, source: opening_session.NavigationSource) void {
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
        self.opening_storage = zip.StreamStorage.init(&self.deflate_input_buffer, &self.deflate_window, &self.deflate_workspace);
        job.stream = job.archive.?.begin(entry, &self.opening_storage) catch {
            self.navigationSourceFinished(source, false);
            return;
        };
        job.beginNavigationRead(source, &self.publication, path);
    }

    fn advanceNavigationRead(self: *ReaderCoordinator, job: *opening_session.Session, source: opening_session.NavigationSource) void {
        const result = job.stream.?.read(&job.output) catch {
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
                job.navigation_parser.?.feed(job.output[0..count]) catch self.navigationSourceFinished(source, false);
            },
            .end => {
                job.stream.?.finish() catch {
                    self.navigationSourceFinished(source, false);
                    return;
                };
                job.stream = null;
                const parser = &(job.navigation_parser orelse {
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

    fn navigationSourceFinished(self: *ReaderCoordinator, source: opening_session.NavigationSource, has_labels: bool) void {
        const completion = self.opening_job.?.finishNavigation(source, has_labels);
        if (!has_labels) self.clearChapterLabels();
        if (completion == .opened) self.finishOpening();
    }

    fn clearChapterLabels(self: *ReaderCoordinator) void {
        for (self.publication.chapter_labels[0..self.publication.spine_len]) |*label| label.len = 0;
    }

    fn finishOpening(self: *ReaderCoordinator) void {
        const job = &(self.opening_job orelse return);
        const result = job.takeResult() orelse return;
        switch (result) {
            .opened => {},
            .failed => unreachable,
        }
        if (self.allocator) |allocator| {
            job.cancel(allocator);
        } else {
            job.closeFileLease();
        }
        self.opening_job = null;
        self.archive_index = null;
        self.lifecycle = .ready;
        self.beginReading();
        self.chapter_index = 0;
        self.opening_chapter_request = 0;
    }

    /// Consumes the semantic chapter-opening request made by a successful
    /// opener. The caller may only provide the platform-backed chapter slot.
    pub fn takeOpeningChapterRequest(self: *ReaderCoordinator) ?u8 {
        const request = self.opening_chapter_request;
        self.opening_chapter_request = null;
        return request;
    }

    /// Cancels an in-flight opener without inventing an opening error. This
    /// is used when the user leaves for the library.
    pub fn cancelOpening(self: *ReaderCoordinator) void {
        if (self.opening_job) |*job| {
            if (self.allocator) |allocator| {
                job.cancel(allocator);
            } else {
                job.closeFileLease();
            }
        }
        self.opening_job = null;
        self.opening_chapter_request = null;
    }

    /// Begins a bounded chapter open through the stable chapter host slot.
    /// Replacing a request first releases the prior stream and its lease.
    pub fn openChapter(self: *ReaderCoordinator, index: u8, action: ChapterOpenAction) void {
        self.pending_prefetch_transition = null;
        self.cancelPrefetch();
        self.cancelChapter();
        self.chapter_open = .{ .index = index, .action = action };
        self.paged.builder = null;
        self.paged.current_ready = false;
        self.paged.next_ready = false;
        self.paged.selected_word_ordinal = null;
        self.chapter_end = false;
        self.paged.chapter_end = false;
    }

    /// Advances one bounded chapter-open or stream step. Later migration
    /// stages consume the returned save/prefetch requests in the coordinator.
    pub fn stepChapter(self: *ReaderCoordinator, now_ms: u32) ChapterStep {
        const job = &(self.chapter_open orelse return self.stepChapterStream(now_ms));
        if (job.scanner == null) {
            const files = self.host.?.files orelse {
                self.failChapter(.archive);
                return .{ .worked = true };
            };
            const reader = files.open(files.context, .chapter, self.active_book.zSlice()) catch {
                self.failChapter(.archive);
                return .{ .worked = true };
            };
            self.chapter_lease_open = true;
            job.scanner = zip.ArchiveScanner.init(reader) catch {
                self.failChapter(.archive);
                return .{ .worked = true };
            };
            return .{ .worked = true };
        }
        if (job.finder == null) {
            const archive = job.scanner.?.step(&self.archive_scan_buffer) catch {
                self.failChapter(.archive);
                return .{ .worked = true };
            } orelse return .{ .worked = true };
            if (job.index >= self.publication.spine_len) {
                self.failChapter(.archive);
                return .{ .worked = true };
            }
            job.finder = zip.EntryFinder.init(archive, self.publication.spine[job.index].slice());
            return .{ .worked = true };
        }
        const entry = job.finder.?.step(&self.archive_filename_buffer) catch {
            self.failChapter(.archive);
            return .{ .worked = true };
        } orelse {
            if (job.finder.?.entry_index == job.finder.?.archive.entry_count) self.failChapter(.archive);
            return .{ .worked = true };
        };
        const archive = job.finder.?.archive;
        const index = job.index;
        const action = job.action;
        self.chapter_open = null;
        self.beginOpenedChapter(archive, index, entry, now_ms) catch {
            self.failChapter(.archive);
            return .{ .worked = true };
        };
        switch (action) {
            .normal => {},
            .rescan => |target| self.paged.beginRescan(target),
            .word_rescan => |target| self.paged.beginWordRescan(target),
            .rsvp_rescan => |target| self.rsvp_reader.reconstruct(target),
            .rescan_to_last_page => self.paged.beginRescanToLastPage(),
        }
        return .{ .worked = true };
    }

    fn stepChapterStream(self: *ReaderCoordinator, now_ms: u32) ChapterStep {
        if (self.lifecycle != .ready or self.paged.next_ready or self.chapter_end or self.chapter_stream == null) return .{};
        if (self.mode == .rsvp and self.rsvp_reader.hasWord()) return .{};

        const reconstructing = self.chapterIsReconstructing();
        var budget = self.chapterWorkBudget();
        while (budget != 0 and !self.paged.next_ready and !self.chapter_end) {
            if (self.chapter_output_start != self.chapter_output_end) {
                const available = self.chapter_output[self.chapter_output_start..self.chapter_output_end];
                const input_bytes = available[0..if (self.mode == .rsvp) 1 else @min(available.len, budget)];
                const progress = (if (self.mode == .rsvp) self.rsvp_reader.feed(input_bytes) else self.paged.feed(input_bytes)) catch {
                    self.failChapter(.tokenizer);
                    return .{ .worked = true };
                };
                var page_completed = false;
                const consumed = switch (progress) {
                    .consumed => |count| count,
                    .page_full => |count| blk: {
                        self.pageCompleted(now_ms);
                        page_completed = true;
                        break :blk count;
                    },
                };
                self.chapter_output_start += consumed;
                budget -= consumed;
                if (reconstructing and page_completed) return .{ .worked = true };
                if (self.mode == .rsvp and self.rsvp_reader.hasWord()) {
                    self.telemetry.setChapterEvents(self.rsvp_reader.event_count);
                    if (self.pending_mode_word_ordinal == self.rsvp_reader.position().word) self.pending_mode_word_ordinal = null;
                    self.rsvp_reader.wordBecameDrawable(now_ms);
                    return .{ .worked = true, .position_changed = true };
                }
                continue;
            }

            const stream = &self.chapter_stream.?;
            const output = self.chapter_output[0..@min(self.chapter_output.len, budget)];
            const result = stream.read(output) catch {
                self.failChapter(.archive);
                return .{ .worked = true };
            };
            switch (result) {
                .bytes => |count| {
                    self.telemetry.decodedBytes(count);
                    self.chapter_output_start = 0;
                    self.chapter_output_end = count;
                },
                .end => {
                    if (self.mode != .rsvp) self.paged.finishInput() catch {
                        self.failChapter(.tokenizer);
                        return .{ .worked = true };
                    };
                    if (self.mode == .rsvp) {
                        self.rsvp_reader.finishInput() catch {
                            self.failChapter(.tokenizer);
                            return .{ .worked = true };
                        };
                        self.chapter_end = true;
                        stream.finish() catch {
                            self.failChapter(.archive);
                            return .{ .worked = true };
                        };
                        self.telemetry.setChapterEvents(self.rsvp_reader.event_count);
                        var position_changed = false;
                        if (self.rsvp_reader.hasWord()) {
                            if (self.pending_mode_word_ordinal == self.rsvp_reader.position().word) self.pending_mode_word_ordinal = null;
                            self.rsvp_reader.wordBecameDrawable(now_ms);
                            position_changed = true;
                        }
                        if (self.rsvp_reader.targetUnresolved()) {
                            self.failChapter(.page_limit);
                        } else if (!self.rsvp_reader.hasWord()) {
                            if (self.nextReadableChapter()) |next| {
                                self.openChapter(next, .normal);
                            } else self.failChapter(.no_supported_text);
                        }
                        return .{ .worked = true, .position_changed = position_changed };
                    }
                    self.paged.builderPtr().?.end() catch |err| {
                        if (err == error.PageFull) self.pageCompleted(now_ms) else self.failChapter(.page_limit);
                        return .{ .worked = true };
                    };
                    self.chapter_end = true;
                    self.paged.chapter_end = true;
                    if (self.paged.finishChapter() == .at_limit) {
                        self.failChapter(.page_limit);
                        return .{ .worked = true };
                    }
                    stream.finish() catch {
                        self.failChapter(.archive);
                        return .{ .worked = true };
                    };
                    self.decode_workspace.markActiveVerifiedEof();
                    if (!self.paged.isRescanning() and !self.paged.current_ready and !self.paged.next_ready) {
                        if (self.nextReadableChapter()) |next| {
                            self.openChapter(next, .normal);
                        } else self.failChapter(.no_supported_text);
                        return .{ .worked = true };
                    }
                    return .{ .worked = true, .request_prefetch = !self.paged.isRescanning() };
                },
                .needs_input => {
                    self.failChapter(.archive);
                    return .{ .worked = true };
                },
            }
        }
        return .{ .worked = true };
    }

    fn chapterIsReconstructing(self: *const ReaderCoordinator) bool {
        return switch (self.mode) {
            .paged => self.paged.isReconstructing(),
            .rsvp => self.rsvp_reader.isReconstructing(),
        };
    }

    fn chapterWorkBudget(self: *const ReaderCoordinator) usize {
        return if (self.chapterIsReconstructing()) limits.reconstruction_bytes_per_update else limits.forward_chapter_bytes_per_update;
    }

    fn pageCompleted(self: *ReaderCoordinator, now_ms: u32) void {
        self.telemetry.pageCompleted(now_ms);
        self.paged.pageCompleted(self.telemetry.chapter_events, self.paged.sourceOffset());
    }

    fn nextReadableChapter(self: *const ReaderCoordinator) ?u8 {
        return if (self.chapter_index + 1 < self.publication.spine_len) self.chapter_index + 1 else null;
    }

    fn beginOpenedChapter(self: *ReaderCoordinator, archive: zip.Archive, index: u8, entry: zip.Entry, now_ms: u32) !void {
        if (self.decode_workspace.beginActive() != .acquired) return error.DecodeWorkspaceBusy;
        self.chapter_storage = zip.StreamStorage.init(&self.deflate_input_buffer, &self.deflate_window, &self.deflate_workspace);
        self.chapter_stream = archive.begin(entry, &self.chapter_storage) catch |err| {
            self.decode_workspace.release(.active);
            return err;
        };
        self.chapter_index = index;
        const measure = self.host.?.measure;
        self.paged.begin(index, reader_layout.text_width, paginationMeasure(measure));
        self.chapter_end = false;
        self.chapter_output_start = 0;
        self.chapter_output_end = 0;
        self.telemetry.chapterStarted(now_ms);
        if (self.mode == .rsvp) {
            self.paged.builder = null;
            self.paged.extractor = null;
            self.rsvp_reader.begin(index);
        }
    }

    /// Cancels chapter lookup/decoding and releases its stable host slot once.
    pub fn cancelChapter(self: *ReaderCoordinator) void {
        self.chapter_open = null;
        self.chapter_stream = null;
        if (self.decode_workspace.owner == .active) self.decode_workspace.release(.active);
        self.releaseChapterLease();
    }

    /// Releases the stable chapter file after its stream reached verified
    /// EOF. Prefetch may then lease the shared decode workspace safely.
    pub fn releaseChapterLease(self: *ReaderCoordinator) void {
        if (!self.chapter_lease_open) return;
        if (self.host) |host| if (host.files) |files| files.close(files.context, .chapter);
        self.chapter_lease_open = false;
    }

    /// Starts bounded preparation of the next chapter only after the active
    /// decoder has reached verified EOF and yielded the shared workspace.
    pub fn startPrefetch(self: *ReaderCoordinator) bool {
        if (!self.paged.next_ready or self.chapter_index + 1 >= self.publication.spine_len or self.paged.prefetch.isPrefetching()) return false;
        if (self.decode_workspace.beginPrefetch() != .acquired) return false;
        self.releaseActivePrefetch();
        self.releaseChapterLease();
        const files = self.host.?.files orelse {
            self.decode_workspace.release(.prefetch);
            return false;
        };
        const reader = files.open(files.context, .prefetch, self.active_book.zSlice()) catch {
            self.decode_workspace.release(.prefetch);
            return false;
        };
        self.paged.prefetch.attachFile(.{ .context = self, .close = closePrefetchHostLease });
        self.paged.prefetch.startLookup(self.chapter_index + 1, reader) catch {
            self.cancelPrefetch();
            return false;
        };
        return true;
    }

    pub fn cancelPrefetch(self: *ReaderCoordinator) void {
        if (self.paged.prefetch.state == .active) {
            self.releaseActivePrefetch();
            return;
        }
        self.paged.prefetch.cancel();
        self.paged.releasePrefetchPage();
        if (self.decode_workspace.owner == .prefetch) self.decode_workspace.release(.prefetch);
    }

    /// Advances bounded central-directory lookup or one bounded decode step.
    /// Failure is recoverable; a waiting boundary request falls back to a
    /// normal chapter open through the typed chapter slot.
    pub fn stepPrefetch(self: *ReaderCoordinator) void {
        if (self.paged.prefetch.state == .looking_up) {
            const next = self.chapter_index + 1;
            if (next >= self.publication.spine_len) {
                self.cancelPrefetch();
                self.openPendingPrefetchTransition();
                return;
            }
            switch (self.paged.prefetch.stepLookup(&self.archive_scan_buffer, &self.archive_filename_buffer, self.publication.spine[next].slice(), prefetch_directory_records_per_step)) {
                .working => return,
                .missing, .failed => {
                    self.cancelPrefetch();
                    self.openPendingPrefetchTransition();
                    return;
                },
                .found => |found| {
                    const reserved = self.paged.reservePrefetchPage(found.chapter) orelse {
                        self.cancelPrefetch();
                        self.openPendingPrefetchTransition();
                        return;
                    };
                    const measure = self.host.?.measure;
                    self.paged.prefetch.begin(
                        found.archive,
                        found.entry,
                        found.chapter,
                        reserved.slot,
                        reserved.page,
                        &self.deflate_input_buffer,
                        &self.deflate_window,
                        &self.deflate_workspace,
                        reader_layout.text_width,
                        paginationMeasure(measure),
                    ) catch {
                        self.cancelPrefetch();
                        self.openPendingPrefetchTransition();
                        return;
                    };
                },
            }
        }
        if (!self.paged.prefetch.isPrefetching()) return;
        switch (self.paged.prefetch.step(&self.chapter_output, limits.prefetch_bytes_per_update)) {
            .working => {},
            .ready => {
                if (self.pending_prefetch_transition != null) _ = self.activatePrefetch();
            },
            .failed => {
                self.cancelPrefetch();
                self.openPendingPrefetchTransition();
            },
        }
    }

    pub fn prefetchedChapter(self: *const ReaderCoordinator) ?u8 {
        return self.paged.prefetch.readyChapter();
    }

    /// Resolves the semantic next-chapter boundary against prepared,
    /// in-flight, or absent prefetch state.
    pub fn requestNextChapter(self: *ReaderCoordinator) void {
        if (self.chapter_index + 1 >= self.publication.spine_len) return;
        const next = self.chapter_index + 1;
        if (self.paged.prefetch.isReady()) {
            _ = self.activatePrefetch();
        } else if (self.paged.prefetch.isPrefetching()) {
            self.pending_prefetch_transition = next;
        } else {
            self.openChapter(next, .normal);
        }
    }

    pub fn requestedChapter(self: *const ReaderCoordinator) ?u8 {
        return if (self.chapter_open) |job| job.index else null;
    }

    /// Promotes a prepared page and its retained stream without copying the
    /// platform file handle whose address backs the ZIP reader.
    pub fn activatePrefetch(self: *ReaderCoordinator) bool {
        const prepared = self.paged.prefetch.activate() orelse return false;
        self.pending_prefetch_transition = null;
        self.decode_workspace.activatePrefetch();
        self.releaseChapterLease();
        self.paged.prefetch.detachFile();
        self.active_prefetch_lease = true;
        self.chapter_stream = self.paged.prefetch.stream;
        self.paged.builder = self.paged.prefetch.builder;
        self.paged.adoptExtractor(self.paged.prefetch.extractor.?);
        self.chapter_output_start = self.paged.prefetch.output_start;
        self.chapter_output_end = self.paged.prefetch.output_end;
        self.chapter_index = prepared.chapter;
        self.paged.activatePrefetchedPage(prepared.page, prepared.chapter, prepared.ended);
        self.chapter_end = prepared.ended;
        self.paged.recordCheckpoint(0, self.telemetry.chapter_events, self.paged.sourceOffset());
        if (prepared.ended) self.decode_workspace.markActiveVerifiedEof();
        return true;
    }

    fn openPendingPrefetchTransition(self: *ReaderCoordinator) void {
        const index = self.pending_prefetch_transition orelse return;
        self.pending_prefetch_transition = null;
        if (index < self.publication.spine_len and index == self.chapter_index + 1) self.openChapter(index, .normal);
    }

    fn releaseActivePrefetch(self: *ReaderCoordinator) void {
        if (self.paged.prefetch.state != .active) return;
        if (self.active_prefetch_lease) {
            if (self.host) |host| if (host.files) |files| files.close(files.context, .prefetch);
            self.active_prefetch_lease = false;
        }
        self.paged.prefetch.releaseActive();
        if (self.decode_workspace.owner == .active) self.decode_workspace.release(.active);
    }

    pub fn activeChapter(self: *const ReaderCoordinator) ?u8 {
        return if (self.chapter_stream != null and self.chapter_open == null) self.chapter_index else null;
    }

    fn failChapter(self: *ReaderCoordinator, failure: ChapterFailure) void {
        self.chapter_failure = failure;
        self.paged.current_ready = false;
        self.paged.next_ready = false;
        self.chapter_end = true;
        self.lifecycle = .chapter_error;
        self.cancelChapter();
    }

    fn beginMetadataRead(self: *ReaderCoordinator, job: *opening_session.Session, entry: zip.Entry, target: opening_session.MetadataTarget) zip.Error!void {
        self.opening_storage = zip.StreamStorage.init(&self.deflate_input_buffer, &self.deflate_window, &self.deflate_workspace);
        job.stream = try job.archive.?.begin(entry, &self.opening_storage);
        job.beginMetadataRead(target);
    }

    fn advanceMetadataRead(self: *ReaderCoordinator, job: *opening_session.Session, failure: Lifecycle) bool {
        const result = job.stream.?.read(&job.output) catch {
            self.failOpening(failure);
            return false;
        };
        switch (result) {
            .bytes => |count| {
                job.appendMetadataBytes(job.output[0..count]) catch {
                    self.failOpening(failure);
                };
                return false;
            },
            .end => {
                job.stream.?.finish() catch {
                    self.failOpening(failure);
                    return false;
                };
                return true;
            },
            .needs_input => {
                self.failOpening(failure);
                return false;
            },
        }
    }

    fn failOpening(self: *ReaderCoordinator, failure: Lifecycle) void {
        if (self.opening_job) |*job| {
            if (self.allocator) |allocator| {
                job.cancel(allocator);
            } else {
                job.closeFileLease();
            }
        }
        self.opening_job = null;
        self.opening_chapter_request = null;
        self.lifecycle = failure;
    }

    /// Owns one complete reader frame: intent selection, crank/autoplay,
    /// bounded workflows, and due persistence. Time and input are plain data;
    /// all platform I/O remains behind ReaderHost.
    pub fn update(self: *ReaderCoordinator, frame: FrameInput, now_ms: u32) void {
        self.updateCrankDockState(frame.crank_docked);
        const intent = intentFor(.{
            .screen = self.screen,
            .readiness = if (self.lifecycle == .chapter_error) .chapter_error else if (self.lifecycle == .opening) .opening else .ready,
            .mode = self.mode,
            .buttons = frame.buttons,
        });
        self.performIntent(intent, now_ms);
        self.handleCrank(frame.crank_change);
        self.advanceAutoplay(now_ms);

        self.advanceOpening();
        if (self.takeOpeningChapterRequest()) |chapter| {
            self.openChapter(chapter, .normal);
            self.restorePosition();
        }
        const chapter = self.stepChapter(now_ms);
        if (chapter.position_changed) self.requestPositionSave();
        if (chapter.request_prefetch) _ = self.startPrefetch();
        self.fulfillPendingPagedSelection();
        if (self.mode == .paged and !self.crank_docked) self.drainPagedDetents();
        self.stepPrefetch();
        self.flushPersistence();
    }

    pub fn handleSystemAction(self: *ReaderCoordinator, action: SystemAction, now_ms: u32) void {
        switch (action) {
            .library => self.leaveBook(now_ms),
            .settings => _ = self.openSettings(),
            .chapters => {
                if (self.screen != .reading or self.publication.spine_len == 0) return;
                self.rsvp_reader.stopAutoplay(now_ms, &self.pace);
                self.crank_accumulated = 0;
                _ = self.openChapters(self.publication.spine_len, self.chapter_index);
            },
        }
    }

    fn performIntent(self: *ReaderCoordinator, intent: input.Intent, now_ms: u32) void {
        switch (intent) {
            .none => {},
            .library_next => self.library.move(1),
            .library_previous => self.library.move(-1),
            .open_selected_book => _ = self.openSelectedBook(),
            .return_to_library => self.leaveBook(now_ms),
            .close_settings => _ = self.closeSettings(),
            .close_chapter_browser => {
                _ = self.closeChapterBrowser();
                self.crank_accumulated = 0;
            },
            .chapter_browser_next => self.chapter_browser.move(1),
            .chapter_browser_previous => self.chapter_browser.move(-1),
            .open_browser_chapter => {
                if (self.chapter_browser.entry_count == 0) return;
                const selected = self.chapter_browser.selected;
                self.crank_accumulated = 0;
                self.beginReading();
                self.openChapter(selected, .normal);
                self.lifecycle = .ready;
            },
            .settings_next => self.moveSettingsSelection(1),
            .settings_previous => self.moveSettingsSelection(-1),
            .activate_setting => if (self.settings_selected == 0) self.switchReadingMode(now_ms) else {
                _ = self.rsvp_reader.adjustWpm(1, now_ms, &self.pace);
                self.saveSettings();
            },
            .toggle_reading_mode => self.switchReadingMode(now_ms),
            .rsvp_toggle_autoplay => if (self.screen == .reading and self.mode == .rsvp) self.rsvp_reader.toggleAutoplay(now_ms, &self.pace),
            .rsvp_wpm_up => self.adjustRsvpWpm(1, now_ms),
            .rsvp_wpm_down => self.adjustRsvpWpm(-1, now_ms),
            .rsvp_previous_sentence => self.previousRsvpSentence(now_ms),
            .next_page => {
                self.paged.pending_selection = null;
                if (self.lifecycle == .ready and self.chapter_open == null) {
                    self.handlePagedMove(self.paged.nextPage());
                    self.requestPositionSave();
                }
            },
            .previous_page => {
                self.paged.pending_selection = null;
                if (self.lifecycle == .ready and self.chapter_open == null) self.handlePagedMove(self.paged.previousPage());
            },
            .next_chapter => self.openAdjacentChapter(1),
            .previous_chapter => self.openAdjacentChapter(-1),
        }
    }

    fn switchReadingMode(self: *ReaderCoordinator, now_ms: u32) void {
        const target_word = if (self.mode == .paged)
            reader_transitions.pagedModeSwitchOrdinal(self.currentPagedWordOrdinal(), self.paged.pending_selection)
        else
            self.rsvp_reader.position().word;
        self.toggleMode();
        self.rsvp_reader.stopAutoplay(now_ms, &self.pace);
        self.paged.pending_selection = null;
        self.paged.detent_backlog = 0;
        self.crank_accumulated = 0;
        self.pending_mode_word_ordinal = target_word;
        if (self.lifecycle == .ready) {
            switch (self.mode) {
                .paged => {
                    self.paged.pending_selection = .{ .ordinal = target_word };
                    self.openChapter(self.chapter_index, .{ .word_rescan = target_word });
                },
                .rsvp => self.openChapter(self.chapter_index, .{ .rsvp_rescan = .{ .word = target_word } }),
            }
            self.requestPositionSave();
        }
        self.saveSettings();
    }

    fn adjustRsvpWpm(self: *ReaderCoordinator, direction: i8, now_ms: u32) void {
        if (self.screen != .reading or self.mode != .rsvp) return;
        if (!self.rsvp_reader.adjustWpm(direction, now_ms, &self.pace)) return;
        self.requestPaceSave();
        self.saveSettings();
    }

    fn advanceAutoplay(self: *ReaderCoordinator, now_ms: u32) void {
        if (self.screen != .reading or self.mode != .rsvp) return;
        if (self.rsvp_reader.autoplay(now_ms, &self.pace)) |move| {
            self.requestPaceSave();
            self.handleRsvpMove(move);
        }
    }

    fn previousRsvpSentence(self: *ReaderCoordinator, now_ms: u32) void {
        if (self.lifecycle != .ready or self.chapter_open != null) return;
        self.rsvp_reader.recordAutoplay(now_ms, 0, &self.pace);
        self.requestPaceSave();
        self.rsvp_reader.timer.reset(now_ms);
        self.handleRsvpMove(self.rsvp_reader.previousSentence());
    }

    fn handleCrank(self: *ReaderCoordinator, change: f32) void {
        if (self.screen == .chapter_browser) {
            self.chapter_browser.move(crankDetents(&self.crank_accumulated, change));
            return;
        }
        if (self.crank_docked) return;
        if (self.screen != .reading or self.lifecycle != .ready or self.chapter_open != null or self.paged.isRescanning()) return;
        if (self.mode == .rsvp) {
            if (self.rsvp_reader.timer.running) return;
            const move = switch (crankDirection(&self.crank_accumulated, change)) {
                1 => self.rsvp_reader.nextWord(),
                -1 => self.rsvp_reader.previousWord(),
                else => return,
            };
            self.handleRsvpMove(move);
            return;
        }
        self.paged.detent_backlog = saturatingAddDetents(self.paged.detent_backlog, crankDetents(&self.crank_accumulated, change));
        self.drainPagedDetents();
    }

    fn updateCrankDockState(self: *ReaderCoordinator, docked: bool) void {
        if (self.crank_docked == docked) return;
        self.crank_docked = docked;
        self.crank_accumulated = 0;
        if (docked) self.paged.detent_backlog = 0;
    }

    fn handlePagedMove(self: *ReaderCoordinator, move: paged_reader.PagedReader.Move) void {
        switch (move) {
            .needs_reconstruction => self.openChapter(self.chapter_index, .{ .rescan = self.paged.navigation_state.page }),
            .needs_previous_chapter => if (self.chapter_index != 0) self.openChapter(self.chapter_index - 1, .rescan_to_last_page),
            .needs_next_chapter => self.requestNextChapter(),
            .moved, .waiting, .at_limit => {},
        }
    }

    fn drainPagedDetents(self: *ReaderCoordinator) void {
        while (self.paged.detent_backlog != 0) {
            if (self.paged.pending_selection != null) return;
            const direction: i8 = if (self.paged.detent_backlog > 0) 1 else -1;
            switch (self.movePagedSelection(direction)) {
                .advanced => self.paged.detent_backlog -= direction,
                .waiting_for_page => return,
                .at_limit => {
                    self.paged.detent_backlog = 0;
                    return;
                },
            }
        }
    }

    fn movePagedSelection(self: *ReaderCoordinator, direction: i8) PagedSelectionMove {
        const move = self.paged.moveSelection(direction, self.chapter_index != 0, self.chapter_index + 1 < self.publication.spine_len);
        self.handlePagedMove(move);
        return switch (move) {
            .moved => blk: {
                self.fulfillPendingPagedSelection();
                if (self.paged.pending_selection == null) {
                    self.requestPositionSave();
                    break :blk .advanced;
                }
                break :blk .waiting_for_page;
            },
            .at_limit => .at_limit,
            .waiting, .needs_reconstruction, .needs_previous_chapter, .needs_next_chapter => .waiting_for_page,
        };
    }

    fn fulfillPendingPagedSelection(self: *ReaderCoordinator) void {
        if (self.mode != .paged or !self.paged.current_ready) return;
        if (!self.paged.fulfillPendingSelection()) return;
        if (self.pending_mode_word_ordinal == self.paged.selected_word_ordinal) self.pending_mode_word_ordinal = null;
        self.requestPositionSave();
    }

    fn handleRsvpMove(self: *ReaderCoordinator, move: rsvp_reader.RsvpReader.Move) void {
        switch (move) {
            .moved => self.requestPositionSave(),
            .needs_word, .waiting, .at_limit => {},
            .needs_rescan => |target| self.openChapter(self.chapter_index, .{ .rsvp_rescan = target }),
            .needs_next_chapter => if (self.nextReadableChapter()) |next| self.openChapter(next, .normal),
        }
    }

    fn openAdjacentChapter(self: *ReaderCoordinator, direction: i8) void {
        const candidate: i16 = @as(i16, self.chapter_index) + direction;
        if (candidate < 0 or candidate >= self.publication.spine_len) return;
        self.openChapter(@intCast(candidate), .normal);
        self.lifecycle = .ready;
    }

    pub fn renderModel(self: *ReaderCoordinator) RenderModel {
        switch (self.screen) {
            .library => {
                var paths = [_][]const u8{""} ** library_storage.capacity;
                for (self.library.books[0..self.library.len], 0..) |*book, index| paths[index] = book.slice();
                return .{ .library = .{ .paths = paths, .count = self.library.len, .selected = self.library.selected } };
            },
            .settings => return .{ .settings = .{ .selected = self.settings_selected, .mode = self.mode, .wpm = self.rsvp_reader.wpm } },
            .chapter_browser => {
                var rows = [_]ChapterRowView{.{}} ** chapter_browser.visible_rows;
                const count = self.chapter_browser.displayedCount();
                for (0..count) |row_index| {
                    const index = self.chapter_browser.first_visible + @as(u8, @intCast(row_index));
                    rows[row_index] = .{
                        .index = index,
                        .selected = index == self.chapter_browser.selected,
                        .label = self.publication.chapter_labels[index].slice(),
                        .path = self.publication.spine[index].slice(),
                    };
                }
                return .{ .chapters = .{
                    .selected = self.chapter_browser.selected,
                    .entries = self.chapter_browser.entry_count,
                    .rows = rows,
                    .row_count = count,
                } };
            },
            else => {},
        }
        return switch (self.lifecycle) {
            .opening => .opening,
            .ready => switch (self.mode) {
                .paged => blk: {
                    const state = self.paged.renderState();
                    var lines = [_][]const u8{""} ** pagination.max_lines;
                    var line_count: u8 = 0;
                    var selected_span: ?pagination.PageCache.WordSpan = null;
                    if (state.page) |page| {
                        line_count = page.line_count;
                        for (0..page.line_count) |index| lines[index] = page.line(index);
                        if (page.moveSelection(state.selected_word_ordinal, 0)) |selected| {
                            self.paged.selected_word_ordinal = selected;
                            if (!self.crank_docked) selected_span = page.wordSpan(selected);
                        }
                    }
                    break :blk .{ .paged = .{
                        .lines = lines,
                        .line_count = line_count,
                        .selected_span = selected_span,
                        .page_index = state.page_index,
                        .waiting = state.waiting_for_page,
                    } };
                },
                .rsvp => blk: {
                    const state = self.rsvp_reader.renderState();
                    const anchor = if (state.word) |word| rsvp.anchorBytes(word) else null;
                    break :blk .{ .rsvp = .{
                        .word = state.word,
                        .anchor = if (anchor) |span| .{ .start = span.start, .end = span.end } else null,
                        .waiting = state.waiting,
                        .reconstructing = self.rsvp_reader.isReconstructing(),
                        .playing = state.playing,
                        .wpm = state.wpm,
                    } };
                },
            },
            .unavailable => .{ .failure = .unavailable },
            .invalid_archive => .{ .failure = .invalid_archive },
            .missing_mimetype => .{ .failure = .missing_mimetype },
            .invalid_mimetype => .{ .failure = .invalid_mimetype },
            .chapter_error => .{ .failure = .{ .chapter = .{
                .reason = self.chapter_failure,
                .path = if (self.chapter_index < self.publication.spine_len) self.publication.spine[self.chapter_index].slice() else null,
            } } },
        };
    }

    pub fn frameFinished(self: *ReaderCoordinator, started_at_ms: u32, now_ms: u32) void {
        self.telemetry.frameFinished(started_at_ms, now_ms);
    }

    pub fn telemetrySnapshot(self: *const ReaderCoordinator) ?telemetry.Telemetry.Snapshot {
        return if (self.telemetry.enabled) self.telemetry.snapshot() else null;
    }

    pub fn setTelemetryEnabled(self: *ReaderCoordinator, enabled: bool) void {
        self.telemetry.setEnabled(enabled);
    }
};

fn closeOpeningHostLease(context: *anyopaque) void {
    const self: *ReaderCoordinator = @ptrCast(@alignCast(context));
    const files = self.host.?.files orelse return;
    files.close(files.context, .opening);
}

fn closePrefetchHostLease(context: *anyopaque) void {
    const self: *ReaderCoordinator = @ptrCast(@alignCast(context));
    const files = self.host.?.files orelse return;
    files.close(files.context, .prefetch);
}

pub const InputSnapshot = struct {
    screen: Screen,
    readiness: Readiness,
    mode: ReadingMode,
    buttons: input.Buttons,
};

/// The façade supplies buttons as a data snapshot; intent priority remains
/// host-testable and does not depend on Playdate button constants.
pub fn intentFor(snapshot: InputSnapshot) input.Intent {
    return input.intentFor(.{
        .screen = switch (snapshot.screen) {
            .library => .library,
            .opening, .unsupported_book, .malformed_book => .opening,
            .reading, .chapter_error => .reading,
            .settings => .settings,
            .chapter_browser => .chapter_browser,
        },
        .readiness = switch (snapshot.readiness) {
            .opening => .opening,
            .ready => .ready,
            .chapter_error => .chapter_error,
        },
        .mode = switch (snapshot.mode) {
            .paged => .paged,
            .rsvp => .rsvp,
        },
        .buttons = snapshot.buttons,
    });
}

fn crankDirection(accumulated: *f32, change: f32) i8 {
    accumulated.* += change;
    if (accumulated.* >= crank_degrees_per_word) {
        accumulated.* -= crank_degrees_per_word;
        return 1;
    }
    if (accumulated.* <= -crank_degrees_per_word) {
        accumulated.* += crank_degrees_per_word;
        return -1;
    }
    return 0;
}

fn crankDetents(accumulated: *f32, change: f32) i16 {
    accumulated.* += change;
    var detents: i16 = 0;
    while (accumulated.* >= crank_degrees_per_word and detents != std.math.maxInt(i16)) {
        accumulated.* -= crank_degrees_per_word;
        detents += 1;
    }
    while (accumulated.* <= -crank_degrees_per_word and detents != std.math.minInt(i16)) {
        accumulated.* += crank_degrees_per_word;
        detents -= 1;
    }
    return detents;
}

fn saturatingAddDetents(existing: i16, incoming: i16) i16 {
    const total: i32 = @as(i32, existing) + @as(i32, incoming);
    return @intCast(@max(@as(i32, std.math.minInt(i16)), @min(@as(i32, std.math.maxInt(i16)), total)));
}

/// Data-only renderer inputs. The drawing adapter is the only layer allowed
/// to turn them into Playdate graphics calls.
pub const LibraryView = struct {
    paths: [library_storage.capacity][]const u8,
    count: u8,
    selected: u8,
};

pub const ChapterRowView = struct {
    index: u8 = 0,
    selected: bool = false,
    label: []const u8 = "",
    path: []const u8 = "",
};

pub const ChaptersView = struct {
    selected: u8,
    entries: u8,
    rows: [chapter_browser.visible_rows]ChapterRowView,
    row_count: u8,
};

pub const PagedView = struct {
    lines: [pagination.max_lines][]const u8,
    line_count: u8,
    selected_span: ?pagination.PageCache.WordSpan,
    page_index: u32,
    waiting: bool,
};

pub const ByteSpan = struct { start: usize, end: usize };

pub const RsvpView = struct {
    word: ?[]const u8,
    anchor: ?ByteSpan = null,
    waiting: bool,
    reconstructing: bool = false,
    playing: bool,
    wpm: u16,
};

pub const ChapterErrorView = struct {
    reason: ChapterFailure,
    path: ?[]const u8,
};

pub const RenderModel = union(enum) {
    library: LibraryView,
    opening,
    paged: PagedView,
    rsvp: RsvpView,
    settings: struct { selected: u1, mode: ReadingMode, wpm: u16 },
    chapters: ChaptersView,
    failure: ErrorView,
};

pub const ErrorView = union(enum) {
    unavailable,
    invalid_archive,
    missing_mimetype,
    invalid_mimetype,
    chapter: ChapterErrorView,
};

test "coordinator maps platform-free snapshots through existing input priority" {
    try std.testing.expectEqual(input.Intent.toggle_reading_mode, intentFor(.{
        .screen = .reading,
        .readiness = .ready,
        .mode = .paged,
        .buttons = .{ .b = true, .right = true },
    }));
    try std.testing.expectEqual(input.Intent.next_chapter, intentFor(.{
        .screen = .chapter_error,
        .readiness = .chapter_error,
        .mode = .rsvp,
        .buttons = .{ .right = true },
    }));
    try std.testing.expectEqual(input.Intent.none, intentFor(.{
        .screen = .opening,
        .readiness = .opening,
        .mode = .paged,
        .buttons = .{ .a = true },
    }));
}

test "docking hides paged focus without discarding its selected word" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.screen = .reading;
    coordinator.lifecycle = .ready;
    coordinator.paged.current_ready = true;
    coordinator.paged.current_page = 0;
    try coordinator.paged.pages[0].appendLineWithMetadata("one two", 0, 2);
    coordinator.paged.pages[0].word_count = 2;
    coordinator.paged.selected_word_ordinal = 1;

    coordinator.paged.detent_backlog = 3;
    coordinator.crank_accumulated = 7;
    coordinator.updateCrankDockState(true);
    try std.testing.expectEqual(@as(i16, 0), coordinator.paged.detent_backlog);
    try std.testing.expectEqual(@as(f32, 0), coordinator.crank_accumulated);
    switch (coordinator.renderModel()) {
        .paged => |view| try std.testing.expect(view.selected_span == null),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(?u32, 1), coordinator.paged.selected_word_ordinal);

    coordinator.updateCrankDockState(false);
    switch (coordinator.renderModel()) {
        .paged => |view| try std.testing.expect(view.selected_span != null),
        else => return error.TestUnexpectedResult,
    }
}

const MeasurementFake = struct {
    calls: u8 = 0,

    fn width(context: *anyopaque, text: []const u8) usize {
        const self: *MeasurementFake = @ptrCast(@alignCast(context));
        self.calls += 1;
        return text.len + 3;
    }
};

test "coordinator measures text through its typed host" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = MeasurementFake{};
    coordinator.attachHost(.{ .measure = .{ .context = &fake, .width = MeasurementFake.width } });
    try std.testing.expectEqual(@as(usize, 7), coordinator.measureText("EPUB"));
    try std.testing.expectEqual(@as(u8, 1), fake.calls);
}

test "coordinator raises only semantic reconstruction work to the reconstruction ceiling" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    try std.testing.expectEqual(limits.forward_chapter_bytes_per_update, coordinator.chapterWorkBudget());

    coordinator.paged.beginWordRescan(12);
    try std.testing.expectEqual(limits.reconstruction_bytes_per_update, coordinator.chapterWorkBudget());

    coordinator.mode = .rsvp;
    coordinator.rsvp_reader.reconstruct(.{ .word = 12 });
    try std.testing.expectEqual(limits.reconstruction_bytes_per_update, coordinator.chapterWorkBudget());
}

const LibraryHostFake = struct {
    fn open(_: *anyopaque, _: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        return error.OpenFailed;
    }

    fn close(_: *anyopaque, _: reader_host.FileSlot) void {}

    fn list(_: *anyopaque, library: *reader_host.Library) void {
        library.add("first.epub");
        library.add("notes.txt");
        library.add("SECOND.EPUB");
    }

    fn width(_: *anyopaque, text: []const u8) usize {
        return text.len;
    }
};

test "coordinator discovers only EPUB paths through its typed host" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = LibraryHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = LibraryHostFake.open, .close = LibraryHostFake.close, .list_epubs = LibraryHostFake.list },
        .measure = .{ .context = &fake, .width = LibraryHostFake.width },
    });
    coordinator.discoverLibrary();
    try std.testing.expectEqual(@as(u8, 2), coordinator.library.len);
    try std.testing.expectEqualStrings("first.epub", coordinator.library.books[0].slice());
    try std.testing.expectEqualStrings("SECOND.EPUB", coordinator.library.books[1].slice());
}

test "coordinator opens the selected book into a fresh opening session" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.library.add("book.epub");
    try std.testing.expect(coordinator.openSelectedBook());
    try std.testing.expectEqual(Screen.opening, coordinator.screen);
    try std.testing.expectEqual(Lifecycle.opening, coordinator.lifecycle);
    try std.testing.expect(coordinator.opening_job != null);
    try std.testing.expectEqualStrings("book.epub", coordinator.active_book.slice());
}

const OpeningHostFake = struct {
    open_calls: u8 = 0,

    fn open(context: *anyopaque, _: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        const self: *OpeningHostFake = @ptrCast(@alignCast(context));
        self.open_calls += 1;
        return error.OpenFailed;
    }

    fn close(_: *anyopaque, _: reader_host.FileSlot) void {}
    fn list(_: *anyopaque, _: *reader_host.Library) void {}
    fn width(_: *anyopaque, text: []const u8) usize {
        return text.len;
    }
};

test "coordinator reports an unavailable book when opening slot acquisition fails" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.library.add("missing.epub");
    _ = coordinator.openSelectedBook();
    var fake = OpeningHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = OpeningHostFake.open, .close = OpeningHostFake.close, .list_epubs = OpeningHostFake.list },
        .measure = .{ .context = &fake, .width = OpeningHostFake.width },
    });
    coordinator.advanceOpening();
    try std.testing.expectEqual(@as(u8, 1), fake.open_calls);
    try std.testing.expectEqual(Lifecycle.unavailable, coordinator.lifecycle);
    try std.testing.expect(coordinator.opening_job == null);
}

const MalformedArchiveHostFake = struct {
    close_calls: u8 = 0,

    fn readAt(_: *anyopaque, _: u32, destination: []u8) zip.Error!void {
        @memset(destination, 0);
    }

    fn open(_: *anyopaque, _: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        return .{ .context = undefined, .size = 22, .read_at = readAt };
    }

    fn close(context: *anyopaque, _: reader_host.FileSlot) void {
        const self: *MalformedArchiveHostFake = @ptrCast(@alignCast(context));
        self.close_calls += 1;
    }

    fn list(_: *anyopaque, _: *reader_host.Library) void {}
    fn width(_: *anyopaque, text: []const u8) usize {
        return text.len;
    }
};

test "coordinator closes the opening slot when archive scanning rejects a book" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.library.add("broken.epub");
    _ = coordinator.openSelectedBook();
    var fake = MalformedArchiveHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = MalformedArchiveHostFake.open, .close = MalformedArchiveHostFake.close, .list_epubs = MalformedArchiveHostFake.list },
        .measure = .{ .context = &fake, .width = MalformedArchiveHostFake.width },
    });
    coordinator.advanceOpening();
    coordinator.advanceOpening();
    try std.testing.expectEqual(Lifecycle.invalid_archive, coordinator.lifecycle);
    try std.testing.expectEqual(@as(u8, 1), fake.close_calls);
    try std.testing.expect(coordinator.opening_job == null);
}

const EmptyArchiveHostFake = struct {
    fn readAt(_: *anyopaque, offset: u32, destination: []u8) zip.Error!void {
        const bytes = [_]u8{ 0x50, 0x4b, 0x05, 0x06 } ++ [_]u8{0} ** 18;
        const start: usize = @intCast(offset);
        if (start + destination.len > bytes.len) return error.UnexpectedEof;
        @memcpy(destination, bytes[start..][0..destination.len]);
    }

    fn open(_: *anyopaque, _: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        return .{ .context = undefined, .size = 22, .read_at = readAt };
    }

    fn close(_: *anyopaque, _: reader_host.FileSlot) void {}
    fn list(_: *anyopaque, _: *reader_host.Library) void {}
    fn width(_: *anyopaque, text: []const u8) usize {
        return text.len;
    }
};

test "coordinator validates a scanned archive before exposing its directory index" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.library.add("empty.epub");
    _ = coordinator.openSelectedBook();
    var fake = EmptyArchiveHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = EmptyArchiveHostFake.open, .close = EmptyArchiveHostFake.close, .list_epubs = EmptyArchiveHostFake.list },
        .measure = .{ .context = &fake, .width = EmptyArchiveHostFake.width },
    });
    coordinator.advanceOpening();
    coordinator.advanceOpening();
    coordinator.advanceOpening();
    try std.testing.expectEqual(opening_session.Phase.find_mimetype, coordinator.opening_job.?.phase);
    try std.testing.expectEqual(@as(usize, 0), coordinator.archive_index.?.entries.len);
}

test "coordinator reports a missing mimetype after validating an empty archive" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.library.add("empty.epub");
    _ = coordinator.openSelectedBook();
    var fake = EmptyArchiveHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = EmptyArchiveHostFake.open, .close = EmptyArchiveHostFake.close, .list_epubs = EmptyArchiveHostFake.list },
        .measure = .{ .context = &fake, .width = EmptyArchiveHostFake.width },
    });
    for (0..4) |_| coordinator.advanceOpening();
    try std.testing.expectEqual(Lifecycle.missing_mimetype, coordinator.lifecycle);
    try std.testing.expect(coordinator.opening_job == null);
}

const StoredMimetypeHostFake = struct {
    bytes: [134]u8 = undefined,

    fn init() StoredMimetypeHostFake {
        var self: StoredMimetypeHostFake = undefined;
        @memset(&self.bytes, 0);
        const name = "mimetype";
        const contents = "application/epub+zip";
        const crc: u32 = 0x2cab_616f;
        const directory_offset = 58;
        const directory_size = 54;
        const end_offset = directory_offset + directory_size;

        std.mem.writeInt(u32, self.bytes[0..4], 0x0403_4b50, .little);
        std.mem.writeInt(u16, self.bytes[4..6], 20, .little);
        std.mem.writeInt(u32, self.bytes[14..18], crc, .little);
        std.mem.writeInt(u32, self.bytes[18..22], contents.len, .little);
        std.mem.writeInt(u32, self.bytes[22..26], contents.len, .little);
        std.mem.writeInt(u16, self.bytes[26..28], name.len, .little);
        @memcpy(self.bytes[30 .. 30 + name.len], name);
        @memcpy(self.bytes[30 + name.len .. directory_offset], contents);

        std.mem.writeInt(u32, self.bytes[directory_offset..][0..4], 0x0201_4b50, .little);
        std.mem.writeInt(u16, self.bytes[directory_offset + 4 ..][0..2], 20, .little);
        std.mem.writeInt(u16, self.bytes[directory_offset + 6 ..][0..2], 20, .little);
        std.mem.writeInt(u32, self.bytes[directory_offset + 16 ..][0..4], crc, .little);
        std.mem.writeInt(u32, self.bytes[directory_offset + 20 ..][0..4], contents.len, .little);
        std.mem.writeInt(u32, self.bytes[directory_offset + 24 ..][0..4], contents.len, .little);
        std.mem.writeInt(u16, self.bytes[directory_offset + 28 ..][0..2], name.len, .little);
        @memcpy(self.bytes[directory_offset + 46 .. end_offset], name);

        std.mem.writeInt(u32, self.bytes[end_offset..][0..4], 0x0605_4b50, .little);
        std.mem.writeInt(u16, self.bytes[end_offset + 8 ..][0..2], 1, .little);
        std.mem.writeInt(u16, self.bytes[end_offset + 10 ..][0..2], 1, .little);
        std.mem.writeInt(u32, self.bytes[end_offset + 12 ..][0..4], directory_size, .little);
        std.mem.writeInt(u32, self.bytes[end_offset + 16 ..][0..4], directory_offset, .little);
        return self;
    }

    fn readAt(context: *anyopaque, offset: u32, destination: []u8) zip.Error!void {
        const self: *StoredMimetypeHostFake = @ptrCast(@alignCast(context));
        const start: usize = @intCast(offset);
        if (start + destination.len > self.bytes.len) return error.UnexpectedEof;
        @memcpy(destination, self.bytes[start..][0..destination.len]);
    }

    fn open(context: *anyopaque, _: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        const self: *StoredMimetypeHostFake = @ptrCast(@alignCast(context));
        return .{ .context = self, .size = self.bytes.len, .read_at = readAt };
    }

    fn close(_: *anyopaque, _: reader_host.FileSlot) void {}
    fn list(_: *anyopaque, _: *reader_host.Library) void {}
    fn width(_: *anyopaque, text: []const u8) usize {
        return text.len;
    }
};

test "coordinator reads and validates the EPUB mimetype before finding its container" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.library.add("book.epub");
    _ = coordinator.openSelectedBook();
    var fake = StoredMimetypeHostFake.init();
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = StoredMimetypeHostFake.open, .close = StoredMimetypeHostFake.close, .list_epubs = StoredMimetypeHostFake.list },
        .measure = .{ .context = &fake, .width = StoredMimetypeHostFake.width },
    });
    for (0..6) |_| coordinator.advanceOpening();
    try std.testing.expectEqual(opening_session.Phase.find_container, coordinator.opening_job.?.phase);
    try std.testing.expect(coordinator.opening_job.?.mimetypeIsValid());
}

test "coordinator parses container metadata before package lookup" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.opening_job = opening_session.Session.start();
    const job = &coordinator.opening_job.?;
    job.beginMetadataRead(.container);
    try job.appendMetadataBytes("<container><rootfiles><rootfile full-path=\"OPS/book.opf\"/></rootfiles></container>");
    job.finishMetadataRead(.container);

    coordinator.advanceOpening();

    try std.testing.expectEqual(opening_session.Phase.find_package, coordinator.opening_job.?.phase);
    try std.testing.expectEqualStrings("OPS/book.opf", coordinator.opening_job.?.packagePath());
}

test "coordinator failure releases opening package storage through its allocator" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.attachAllocator(std.testing.allocator);
    coordinator.opening_job = opening_session.Session.start();
    coordinator.opening_job.?.package_xml = try std.testing.allocator.alloc(u8, 12);

    coordinator.failOpening(.invalid_archive);

    try std.testing.expect(coordinator.opening_job == null);
    try std.testing.expectEqual(Lifecycle.invalid_archive, coordinator.lifecycle);
}

test "coordinator turns a successful navigation result into a chapter request" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.attachAllocator(std.testing.allocator);
    coordinator.opening_job = opening_session.Session.start();
    coordinator.opening_job.?.succeed();

    coordinator.finishOpening();

    try std.testing.expect(coordinator.opening_job == null);
    try std.testing.expectEqual(Lifecycle.ready, coordinator.lifecycle);
    try std.testing.expectEqual(Screen.reading, coordinator.screen);
    try std.testing.expectEqual(@as(?u8, 0), coordinator.takeOpeningChapterRequest());
    try std.testing.expect(coordinator.takeOpeningChapterRequest() == null);
}

test "coordinator completes opening after both optional navigation sources are absent" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    @memset(std.mem.asBytes(&coordinator.publication), 0);
    coordinator.publication.spine_len = 1;
    coordinator.opening_job = opening_session.Session.start();
    coordinator.opening_job.?.phase = .find_navigation;

    coordinator.advanceOpening();
    try std.testing.expectEqual(opening_session.Phase.find_ncx, coordinator.opening_job.?.phase);
    coordinator.advanceOpening();

    try std.testing.expectEqual(Lifecycle.ready, coordinator.lifecycle);
    try std.testing.expectEqual(@as(?u8, 0), coordinator.takeOpeningChapterRequest());
}

test "coordinator cancellation clears an unconsumed opening chapter request" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.opening_chapter_request = 0;

    coordinator.cancelOpening();

    try std.testing.expect(coordinator.takeOpeningChapterRequest() == null);
}

test "coordinator rejects a validated archive without its container document" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.library.add("empty.epub");
    _ = coordinator.openSelectedBook();
    var fake = EmptyArchiveHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = EmptyArchiveHostFake.open, .close = EmptyArchiveHostFake.close, .list_epubs = EmptyArchiveHostFake.list },
        .measure = .{ .context = &fake, .width = EmptyArchiveHostFake.width },
    });
    for (0..3) |_| coordinator.advanceOpening();
    coordinator.opening_job.?.phase = .find_container;
    coordinator.advanceOpening();
    try std.testing.expectEqual(Lifecycle.invalid_archive, coordinator.lifecycle);
    try std.testing.expect(coordinator.opening_job == null);
}

test "render models carry UI data only" {
    const model = RenderModel{ .rsvp = .{ .word = "word", .waiting = false, .playing = true, .wpm = 300 } };
    switch (model) {
        .rsvp => |view| {
            try std.testing.expectEqualStrings("word", view.word.?);
            try std.testing.expect(view.playing);
        },
        else => unreachable,
    }
}

test "coordinator owns screen lifecycle without reader or platform state" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.beginOpening();
    try std.testing.expectEqual(Screen.opening, coordinator.screen);
    coordinator.beginReading();
    try std.testing.expect(coordinator.openSettings());
    try std.testing.expectEqual(Screen.settings, coordinator.screen);
    try std.testing.expect(coordinator.closeSettings());
    try std.testing.expect(coordinator.openChapterBrowser());
    try std.testing.expect(coordinator.closeChapterBrowser());
    coordinator.returnToLibrary();
    try std.testing.expectEqual(Screen.library, coordinator.screen);
}

test "coordinator owns mode and settings selection" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.beginReading();
    coordinator.toggleMode();
    try std.testing.expectEqual(ReadingMode.rsvp, coordinator.mode);
    try std.testing.expect(coordinator.openSettings());
    coordinator.moveSettingsSelection(1);
    try std.testing.expectEqual(@as(u1, 1), coordinator.settings_selected);
}

test "coordinator retains bounded library and chapter-browser navigation state" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.library.add("one.epub");
    coordinator.library.add("two.epub");
    coordinator.library.move(1);
    try std.testing.expectEqual(@as(u8, 1), coordinator.library.selected);
    _ = coordinator.selectBook();
    try std.testing.expectEqualStrings("two.epub", coordinator.active_book.slice());
    coordinator.pending_mode_word_ordinal = 42;
    try std.testing.expectEqual(@as(?u32, 42), coordinator.pending_mode_word_ordinal);
    coordinator.beginReading();
    try std.testing.expect(coordinator.openChapters(3, 1));
    coordinator.chapter_browser.move(1);
    try std.testing.expectEqual(@as(u8, 2), coordinator.chapter_browser.selected);
}

const ChapterSlotHostFake = struct {
    open_calls: u8 = 0,
    close_calls: u8 = 0,
    last_slot: ?reader_host.FileSlot = null,

    fn readAt(_: *anyopaque, _: u32, destination: []u8) zip.Error!void {
        @memset(destination, 0);
    }

    fn open(context: *anyopaque, slot: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        const self: *ChapterSlotHostFake = @ptrCast(@alignCast(context));
        self.open_calls += 1;
        self.last_slot = slot;
        return .{ .context = self, .size = 22, .read_at = readAt };
    }

    fn close(context: *anyopaque, slot: reader_host.FileSlot) void {
        const self: *ChapterSlotHostFake = @ptrCast(@alignCast(context));
        self.close_calls += 1;
        self.last_slot = slot;
    }

    fn list(_: *anyopaque, _: *reader_host.Library) void {}
    fn width(_: *anyopaque, text: []const u8) usize {
        return text.len;
    }
};

const StoredChapterHostFake = struct {
    const name = "chapter.xhtml";
    const contents = "<p>Hello chapter</p>";
    const local_size = 30 + name.len + contents.len;
    const directory_size = 46 + name.len;
    const archive_size = local_size + directory_size + 22;

    bytes: [archive_size]u8 = undefined,
    open_calls: u8 = 0,
    last_slot: ?reader_host.FileSlot = null,

    fn init() StoredChapterHostFake {
        var self: StoredChapterHostFake = undefined;
        @memset(&self.bytes, 0);
        self.open_calls = 0;
        self.last_slot = null;
        const crc = std.hash.crc.Crc32.hash(contents);

        std.mem.writeInt(u32, self.bytes[0..4], 0x0403_4b50, .little);
        std.mem.writeInt(u16, self.bytes[4..6], 20, .little);
        std.mem.writeInt(u32, self.bytes[14..18], crc, .little);
        std.mem.writeInt(u32, self.bytes[18..22], contents.len, .little);
        std.mem.writeInt(u32, self.bytes[22..26], contents.len, .little);
        std.mem.writeInt(u16, self.bytes[26..28], name.len, .little);
        @memcpy(self.bytes[30 .. 30 + name.len], name);
        @memcpy(self.bytes[30 + name.len .. local_size], contents);

        std.mem.writeInt(u32, self.bytes[local_size..][0..4], 0x0201_4b50, .little);
        std.mem.writeInt(u16, self.bytes[local_size + 4 ..][0..2], 20, .little);
        std.mem.writeInt(u16, self.bytes[local_size + 6 ..][0..2], 20, .little);
        std.mem.writeInt(u32, self.bytes[local_size + 16 ..][0..4], crc, .little);
        std.mem.writeInt(u32, self.bytes[local_size + 20 ..][0..4], contents.len, .little);
        std.mem.writeInt(u32, self.bytes[local_size + 24 ..][0..4], contents.len, .little);
        std.mem.writeInt(u16, self.bytes[local_size + 28 ..][0..2], name.len, .little);
        @memcpy(self.bytes[local_size + 46 .. local_size + directory_size], name);

        const end = local_size + directory_size;
        std.mem.writeInt(u32, self.bytes[end..][0..4], 0x0605_4b50, .little);
        std.mem.writeInt(u16, self.bytes[end + 8 ..][0..2], 1, .little);
        std.mem.writeInt(u16, self.bytes[end + 10 ..][0..2], 1, .little);
        std.mem.writeInt(u32, self.bytes[end + 12 ..][0..4], directory_size, .little);
        std.mem.writeInt(u32, self.bytes[end + 16 ..][0..4], local_size, .little);
        return self;
    }

    fn readAt(context: *anyopaque, offset: u32, destination: []u8) zip.Error!void {
        const self: *StoredChapterHostFake = @ptrCast(@alignCast(context));
        const start: usize = @intCast(offset);
        if (start + destination.len > self.bytes.len) return error.UnexpectedEof;
        @memcpy(destination, self.bytes[start..][0..destination.len]);
    }

    fn open(context: *anyopaque, slot: reader_host.FileSlot, _: [:0]const u8) reader_host.FileError!zip.Reader {
        const self: *StoredChapterHostFake = @ptrCast(@alignCast(context));
        self.open_calls += 1;
        self.last_slot = slot;
        return .{ .context = self, .size = archive_size, .read_at = readAt };
    }

    fn close(_: *anyopaque, _: reader_host.FileSlot) void {}
    fn list(_: *anyopaque, _: *reader_host.Library) void {}
    fn width(_: *anyopaque, text: []const u8) usize {
        return text.len * 8;
    }
};

test "chapter work acquires and cancellation releases the typed chapter slot" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = ChapterSlotHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = ChapterSlotHostFake.open, .close = ChapterSlotHostFake.close, .list_epubs = ChapterSlotHostFake.list },
        .measure = .{ .context = &fake, .width = ChapterSlotHostFake.width },
    });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();

    coordinator.openChapter(0, .normal);
    _ = coordinator.stepChapter(10);
    try std.testing.expectEqual(@as(u8, 1), fake.open_calls);
    try std.testing.expectEqual(reader_host.FileSlot.chapter, fake.last_slot.?);

    coordinator.cancelChapter();
    try std.testing.expectEqual(@as(u8, 1), fake.close_calls);
    coordinator.cancelChapter();
    try std.testing.expectEqual(@as(u8, 1), fake.close_calls);
}

test "prefetch acquires its typed slot only after verified chapter EOF and cancels once" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = ChapterSlotHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = ChapterSlotHostFake.open, .close = ChapterSlotHostFake.close, .list_epubs = ChapterSlotHostFake.list },
        .measure = .{ .context = &fake, .width = ChapterSlotHostFake.width },
    });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();
    coordinator.publication.spine_len = 2;
    coordinator.chapter_index = 0;
    coordinator.paged.next_ready = true;

    try std.testing.expect(!coordinator.startPrefetch());
    try std.testing.expectEqual(@as(u8, 0), fake.open_calls);

    _ = coordinator.decode_workspace.beginActive();
    coordinator.decode_workspace.markActiveVerifiedEof();
    try std.testing.expect(coordinator.startPrefetch());
    try std.testing.expectEqual(@as(u8, 1), fake.open_calls);
    try std.testing.expectEqual(reader_host.FileSlot.prefetch, fake.last_slot.?);

    coordinator.cancelPrefetch();
    try std.testing.expectEqual(@as(u8, 1), fake.close_calls);
    coordinator.cancelPrefetch();
    try std.testing.expectEqual(@as(u8, 1), fake.close_calls);
}

test "bounded prefetch work prepares and activates the next chapter first page" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = StoredChapterHostFake.init();
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = StoredChapterHostFake.open, .close = StoredChapterHostFake.close, .list_epubs = StoredChapterHostFake.list },
        .measure = .{ .context = &fake, .width = StoredChapterHostFake.width },
    });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();
    @memset(std.mem.asBytes(&coordinator.publication), 0);
    for (coordinator.publication.spine[0..2]) |*spine| {
        @memcpy(spine.path[0..StoredChapterHostFake.name.len], StoredChapterHostFake.name);
        spine.path_len = StoredChapterHostFake.name.len;
    }
    coordinator.publication.spine_len = 2;
    coordinator.chapter_index = 0;
    coordinator.paged.next_ready = true;
    coordinator.lifecycle = .ready;
    coordinator.beginReading();
    _ = coordinator.decode_workspace.beginActive();
    coordinator.decode_workspace.markActiveVerifiedEof();

    try std.testing.expect(coordinator.startPrefetch());
    for (0..32) |_| {
        coordinator.stepPrefetch();
        if (coordinator.prefetchedChapter() != null) break;
    }
    try std.testing.expectEqual(@as(?u8, 1), coordinator.prefetchedChapter());
    try std.testing.expectEqual(reader_host.FileSlot.prefetch, fake.last_slot.?);
    const reserved = coordinator.paged.prefetch_page.?;
    try std.testing.expectEqual(paged_reader.PagedReader.SlotRole.prefetch, coordinator.paged.slots[reserved].role);

    try std.testing.expect(coordinator.activatePrefetch());
    try std.testing.expectEqual(@as(?u8, 1), coordinator.activeChapter());
    try std.testing.expect(coordinator.paged.prefetch_page == null);
    try std.testing.expectEqual(paged_reader.PagedReader.SlotRole.displayed, coordinator.paged.slots[coordinator.paged.current_page].role);
    try std.testing.expectEqual(paged_reader.PagedReader.BuildState.idle, coordinator.paged.build);
    switch (coordinator.renderModel()) {
        .paged => |view| try std.testing.expect(!view.waiting),
        else => return error.TestUnexpectedResult,
    }
}

test "failed prefetch converts a waiting boundary into a normal chapter request" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = ChapterSlotHostFake{};
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = ChapterSlotHostFake.open, .close = ChapterSlotHostFake.close, .list_epubs = ChapterSlotHostFake.list },
        .measure = .{ .context = &fake, .width = ChapterSlotHostFake.width },
    });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();
    @memset(std.mem.asBytes(&coordinator.publication), 0);
    coordinator.publication.spine_len = 2;
    coordinator.chapter_index = 0;
    coordinator.paged.next_ready = true;
    _ = coordinator.decode_workspace.beginActive();
    coordinator.decode_workspace.markActiveVerifiedEof();

    try std.testing.expect(coordinator.startPrefetch());
    coordinator.requestNextChapter();
    coordinator.stepPrefetch();

    try std.testing.expectEqual(@as(?u8, 1), coordinator.requestedChapter());
}

test "bounded chapter work finds the requested spine entry and starts its stream" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = StoredChapterHostFake.init();
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = StoredChapterHostFake.open, .close = StoredChapterHostFake.close, .list_epubs = StoredChapterHostFake.list },
        .measure = .{ .context = &fake, .width = StoredChapterHostFake.width },
    });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();
    @memset(std.mem.asBytes(&coordinator.publication), 0);
    const path = StoredChapterHostFake.name;
    @memcpy(coordinator.publication.spine[0].path[0..path.len], path);
    coordinator.publication.spine[0].path_len = path.len;
    coordinator.publication.spine_len = 1;
    coordinator.lifecycle = .ready;

    coordinator.openChapter(0, .normal);
    for (0..32) |_| {
        _ = coordinator.stepChapter(20);
        if (coordinator.activeChapter() != null) break;
    }

    try std.testing.expectEqual(@as(?u8, 0), coordinator.activeChapter());
    try std.testing.expectEqual(@as(u8, 1), fake.open_calls);
}

test "bounded chapter work streams a requested chapter into the paged render view" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var fake = StoredChapterHostFake.init();
    coordinator.attachHost(.{
        .files = .{ .context = &fake, .open = StoredChapterHostFake.open, .close = StoredChapterHostFake.close, .list_epubs = StoredChapterHostFake.list },
        .measure = .{ .context = &fake, .width = StoredChapterHostFake.width },
    });
    coordinator.library.add("book.epub");
    _ = coordinator.selectBook();
    @memset(std.mem.asBytes(&coordinator.publication), 0);
    const path = StoredChapterHostFake.name;
    @memcpy(coordinator.publication.spine[0].path[0..path.len], path);
    coordinator.publication.spine[0].path_len = path.len;
    coordinator.publication.spine_len = 1;
    coordinator.lifecycle = .ready;
    coordinator.beginReading();

    coordinator.openChapter(0, .normal);
    for (0..64) |_| _ = coordinator.stepChapter(20);

    switch (coordinator.renderModel()) {
        .paged => |view| try std.testing.expect(!view.waiting),
        else => return error.TestUnexpectedResult,
    }
}
