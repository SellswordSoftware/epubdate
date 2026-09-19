const std = @import("std");
const input = @import("reader_input.zig");
const chapter_browser = @import("chapter_browser.zig");
const library_storage = @import("storage/library.zig");
const reading_pace = @import("storage/pace.zig");
const paged_reader = @import("paged_reader.zig");
const rsvp_reader = @import("rsvp_reader.zig");
const decode_workspace = @import("decode_workspace.zig");
const opening_session = @import("opening_session.zig");
const persistence = @import("storage/persistence.zig");
const zip = @import("archive/zip.zig");
const epub = @import("publication/epub.zig");
const deflate = @import("archive/deflate.zig");
const limits = @import("limits").reader;
const telemetry = @import("telemetry.zig");
const reader_host = @import("reader_host.zig");

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
pub const IntentPort = struct {
    context: *anyopaque,
    cancel_active_reading: *const fn (context: *anyopaque) void,
    perform: *const fn (context: *anyopaque, intent: input.Intent, now_ms: u32) void,
};

pub const WorkPort = struct {
    context: *anyopaque,
    advance_opening: *const fn (context: *anyopaque) void,
    advance_chapter: *const fn (context: *anyopaque) void,
    fulfill_paged_selection: *const fn (context: *anyopaque) void,
    drain_paged_detents: *const fn (context: *anyopaque) void,
    advance_prefetch: *const fn (context: *anyopaque) void,
    flush_persistence: *const fn (context: *anyopaque) void,
};
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
    rsvp_reader: rsvp_reader.RsvpReader = .{},
    decode_workspace: decode_workspace.DecodeWorkspace = .{},
    opening_job: ?opening_session.Session = null,
    /// A successful opener asks the platform façade to begin this chapter.
    /// The façade supplies only the stable chapter file lease; it does not
    /// decide whether opening succeeded or which navigation fallback won.
    opening_chapter_request: ?u8 = null,
    persistence: ?persistence.Service = null,
    chapter_open: ?ChapterOpenJob = null,
    chapter_index: u8 = 0,
    chapter_end: bool = false,
    pending_prefetch_transition: ?u8 = null,
    lifecycle: Lifecycle = .opening,
    chapter_failure: ChapterFailure = .archive,
    zip_entries: [epub.max_manifest_items]zip.IndexedEntry = undefined,
    archive_index: ?zip.DirectoryIndex = null,
    publication: epub.Publication = undefined,
    prefetch_scan_buffer: [1024]u8 = undefined,
    prefetch_filename_buffer: [limits.max_archive_filename_bytes]u8 = undefined,
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
    host: ?reader_host.ReaderHost = null,
    allocator: ?std.mem.Allocator = null,

    /// Initializes this large, heap-resident state directly in place.  Do not
    /// return it by value: that creates a roughly 125 KiB temporary on the
    /// Playdate's small callback stack.
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
        self.rsvp_reader = .{};
        self.decode_workspace = .{};
        self.opening_job = null;
        self.opening_chapter_request = null;
        self.persistence = null;
        self.chapter_open = null;
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

    pub fn beginOpening(self: *ReaderCoordinator) void {
        self.screen = .opening;
    }

    pub fn returnToLibrary(self: *ReaderCoordinator) void {
        self.screen = .library;
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
        job.releaseFileLease();
        if (self.allocator) |allocator| job.cancel(allocator);
        self.opening_job = null;
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

    /// Applies the screen-level portion of an input event. The returned
    /// intent is deliberately semantic: App executes only the operation that
    /// requires Playdate files, clocks, or a reader engine.
    pub fn handle(self: *ReaderCoordinator, snapshot: InputSnapshot) input.Intent {
        const intent = intentFor(snapshot);
        self.applyIntent(intent);
        return intent;
    }

    fn applyIntent(self: *ReaderCoordinator, intent: input.Intent) void {
        switch (intent) {
            .open_selected_book => self.beginOpening(),
            .return_to_library => self.returnToLibrary(),
            .close_settings => _ = self.closeSettings(),
            .open_browser_chapter => self.beginReading(),
            .close_chapter_browser => _ = self.closeChapterBrowser(),
            else => {},
        }
    }

    /// The coordinator owns intent selection and lifecycle transitions. A
    /// narrow adapter executes only intents requiring platform I/O or an
    /// engine operation.
    pub fn update(self: *ReaderCoordinator, snapshot: InputSnapshot, now_ms: u32, port: IntentPort) void {
        const intent = intentFor(snapshot);
        if (intent == .return_to_library) self.cancelAndReturn(port);
        self.applyIntent(intent);
        if (intent != .none and intent != .return_to_library) port.perform(port.context, intent, now_ms);
    }

    /// System-menu Library uses this directly; input-driven return uses the
    /// same operation before its lifecycle transition.
    pub fn cancelAndReturn(self: *ReaderCoordinator, port: IntentPort) void {
        port.cancel_active_reading(port.context);
        self.returnToLibrary();
    }

    /// Fixed bounded-work ordering for one reader frame. The platform adapter
    /// supplies file and clock operations; the coordinator owns their order.
    pub fn advanceWork(self: *ReaderCoordinator, port: WorkPort) void {
        port.advance_opening(port.context);
        port.advance_chapter(port.context);
        port.fulfill_paged_selection(port.context);
        if (self.mode == .paged) port.drain_paged_detents(port.context);
        port.advance_prefetch(port.context);
        port.flush_persistence(port.context);
    }

    pub fn renderModel(self: *const ReaderCoordinator) RenderModel {
        switch (self.screen) {
            .library => return .{ .library = .{ .selected = self.library.selected, .entries = self.library.len } },
            .settings => return .{ .settings = .{ .selected = self.settings_selected, .mode = self.mode, .wpm = self.rsvp_reader.wpm } },
            .chapter_browser => return .{ .chapters = .{ .selected = self.chapter_browser.selected, .entries = self.chapter_browser.entry_count } },
            else => {},
        }
        return switch (self.lifecycle) {
            .opening => .opening,
            .ready => switch (self.mode) {
                .paged => .{ .paged = .{ .page_index = self.paged.page_index, .waiting = self.paged.renderState().waiting_for_page } },
                .rsvp => blk: {
                    const state = self.rsvp_reader.renderState();
                    break :blk .{ .rsvp = .{ .word = state.word, .waiting = state.waiting, .playing = state.playing, .wpm = state.wpm } };
                },
            },
            .unavailable => .{ .failure = .unavailable },
            .invalid_archive => .{ .failure = .invalid_archive },
            .missing_mimetype => .{ .failure = .missing_mimetype },
            .invalid_mimetype => .{ .failure = .invalid_mimetype },
            .chapter_error => .{ .failure = .chapter },
        };
    }
};

fn closeOpeningHostLease(context: *anyopaque) void {
    const self: *ReaderCoordinator = @ptrCast(@alignCast(context));
    const files = self.host.?.files orelse return;
    files.close(files.context, .opening);
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

/// Data-only renderer inputs. The drawing adapter is the only layer allowed
/// to turn them into Playdate graphics calls.
pub const RenderModel = union(enum) {
    library: struct { selected: u8, entries: u8 },
    opening,
    paged: struct { page_index: u32, waiting: bool },
    rsvp: struct { word: ?[]const u8, waiting: bool, playing: bool, wpm: u16 },
    settings: struct { selected: u1, mode: ReadingMode, wpm: u16 },
    chapters: struct { selected: u8, entries: u8 },
    failure: ErrorView,
};

pub const ErrorView = enum { unavailable, invalid_archive, missing_mimetype, invalid_mimetype, chapter };

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

test "coordinator applies input-driven lifecycle transitions before dispatch" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    try std.testing.expectEqual(input.Intent.open_selected_book, coordinator.handle(.{
        .screen = coordinator.screen,
        .readiness = .ready,
        .mode = .paged,
        .buttons = .{ .a = true },
    }));
    try std.testing.expectEqual(Screen.opening, coordinator.screen);
    coordinator.beginReading();
    try std.testing.expect(coordinator.openChapterBrowser());
    try std.testing.expectEqual(input.Intent.close_chapter_browser, coordinator.handle(.{
        .screen = coordinator.screen,
        .readiness = .ready,
        .mode = .paged,
        .buttons = .{ .b = true },
    }));
    try std.testing.expectEqual(Screen.reading, coordinator.screen);
}

const RecordedIntent = struct {
    intent: input.Intent = .none,
    now_ms: u32 = 0,
    cancelled: bool = false,

    fn cancel(context: *anyopaque) void {
        const self: *RecordedIntent = @ptrCast(@alignCast(context));
        self.cancelled = true;
    }

    fn perform(context: *anyopaque, intent: input.Intent, now_ms: u32) void {
        const self: *RecordedIntent = @ptrCast(@alignCast(context));
        self.intent = intent;
        self.now_ms = now_ms;
    }
};

test "coordinator dispatches through a narrow fake port" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var recorded = RecordedIntent{};
    coordinator.update(.{
        .screen = .library,
        .readiness = .ready,
        .mode = .paged,
        .buttons = .{ .a = true },
    }, 123, .{ .context = &recorded, .cancel_active_reading = RecordedIntent.cancel, .perform = RecordedIntent.perform });
    try std.testing.expectEqual(input.Intent.open_selected_book, recorded.intent);
    try std.testing.expectEqual(@as(u32, 123), recorded.now_ms);
    try std.testing.expectEqual(Screen.opening, coordinator.screen);
}

test "library return cancels through the port before lifecycle transition" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    coordinator.beginReading();
    var recorded = RecordedIntent{};
    coordinator.cancelAndReturn(.{ .context = &recorded, .cancel_active_reading = RecordedIntent.cancel, .perform = RecordedIntent.perform });
    try std.testing.expect(recorded.cancelled);
    try std.testing.expectEqual(Screen.library, coordinator.screen);
}

const WorkTrace = struct {
    calls: [6]u8 = undefined,
    len: usize = 0,

    fn push(self: *WorkTrace, value: u8) void {
        self.calls[self.len] = value;
        self.len += 1;
    }
    fn opening(context: *anyopaque) void {
        (@as(*WorkTrace, @ptrCast(@alignCast(context)))).push(1);
    }
    fn chapter(context: *anyopaque) void {
        (@as(*WorkTrace, @ptrCast(@alignCast(context)))).push(2);
    }
    fn selection(context: *anyopaque) void {
        (@as(*WorkTrace, @ptrCast(@alignCast(context)))).push(3);
    }
    fn detents(context: *anyopaque) void {
        (@as(*WorkTrace, @ptrCast(@alignCast(context)))).push(4);
    }
    fn prefetch(context: *anyopaque) void {
        (@as(*WorkTrace, @ptrCast(@alignCast(context)))).push(5);
    }
    fn persistence(context: *anyopaque) void {
        (@as(*WorkTrace, @ptrCast(@alignCast(context)))).push(6);
    }
};

test "coordinator orders bounded work and skips paged-only detents for RSVP" {
    var coordinator: ReaderCoordinator = undefined;
    coordinator.initInPlace(128);
    var trace = WorkTrace{};
    const port = WorkPort{ .context = &trace, .advance_opening = WorkTrace.opening, .advance_chapter = WorkTrace.chapter, .fulfill_paged_selection = WorkTrace.selection, .drain_paged_detents = WorkTrace.detents, .advance_prefetch = WorkTrace.prefetch, .flush_persistence = WorkTrace.persistence };
    coordinator.advanceWork(port);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, trace.calls[0..trace.len]);
    trace.len = 0;
    coordinator.mode = .rsvp;
    coordinator.advanceWork(port);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 5, 6 }, trace.calls[0..trace.len]);
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
