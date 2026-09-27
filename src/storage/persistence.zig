const std = @import("std");
const reading_position = @import("resume.zig");
const reading_state = @import("reading_state.zig");
const reading_pace = @import("pace.zig");
const reading_progress = @import("progress.zig");
const reader_settings = @import("settings.zig");
const write_schedule = @import("write_schedule.zig");

pub const ReadingSnapshot = reading_state.ReadingSnapshot;
pub const RestoredPosition = reading_state.RestoredPosition;
pub const Settings = reader_settings.Settings;
pub const Theme = reader_settings.Theme;
pub const ReadingFont = reader_settings.ReadingFont;
pub const nextPagesFont = reader_settings.nextPagesFont;
pub const nextRsvpFont = reader_settings.nextRsvpFont;
pub const normalizePagesFont = reader_settings.normalizePagesFont;
pub const normalizeRsvpFont = reader_settings.normalizeRsvpFont;
pub const ProgressVisibility = reader_settings.ProgressVisibility;
pub const ProgressPosition = reader_settings.ProgressPosition;
pub const ProgressScope = reader_settings.ProgressScope;
pub const PagedPresentation = reader_settings.PagedPresentation;
pub const Pace = reading_pace.Stats;
pub const ProgressKey = reading_progress.Key;
pub const ProgressIndex = reading_progress.Index;
pub const WriteKind = write_schedule.Kind;

/// The only persistence I/O contract required by reader code. Platform
/// adapters own handles, flags, and flushing; this layer owns record names,
/// validation, and format selection.
pub const FileStore = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, name: []const u8, output: []u8) bool,
    write: *const fn (context: *anyopaque, name: []const u8, input: []const u8) bool,
    delete: *const fn (context: *anyopaque, name: []const u8) bool,
    ensure_directory: *const fn (context: *anyopaque, name: []const u8) bool,
};

pub const Service = struct {
    files: FileStore,
    schedule: write_schedule.WriteSchedule = .{},

    pub fn init(files: FileStore) Service {
        return .{ .files = files };
    }

    pub fn bookIdentity(path: []const u8) u32 {
        return reading_position.bookIdentity(path);
    }

    pub fn loadSettings(self: *const Service) Settings {
        var bytes: [reader_settings.encoded_size]u8 = undefined;
        if (!self.files.read(self.files.context, settings_filename, &bytes)) return .{};
        return reader_settings.decode(&bytes) catch .{};
    }

    pub fn saveSettings(self: *const Service, settings: Settings) bool {
        var bytes: [reader_settings.encoded_size]u8 = undefined;
        reader_settings.encode(settings, &bytes);
        return self.files.write(self.files.context, settings_filename, &bytes);
    }

    pub fn loadPosition(self: *const Service, book_path: []const u8, book_id: u32, layout_revision: u16) ?RestoredPosition {
        var name: [max_record_path_len]u8 = undefined;
        var legacy_name: [legacy_filename_len]u8 = undefined;
        const filename = recordFilename(&name, book_path, book_id, resume_filename) orelse return null;
        const legacy = legacyPositionFilename(&legacy_name, book_id) orelse return null;
        var bytes: [reading_position.encoded_size]u8 = undefined;
        if (!self.files.read(self.files.context, filename, &bytes) and !self.files.read(self.files.context, legacy, &bytes)) return null;
        return reading_state.restoreResume(&bytes, book_id, layout_revision);
    }

    pub fn savePosition(self: *const Service, book_path: []const u8, snapshot: ReadingSnapshot) bool {
        var bytes: [reading_position.encoded_size]u8 = undefined;
        reading_state.encodeResume(snapshot, &bytes);
        return writeBookRecord(self, book_path, snapshot.book_id, resume_filename, &bytes, LegacyKind.position);
    }

    pub fn deletePosition(self: *Service, book_path: []const u8, book_id: u32) bool {
        self.schedule.clear(.position);
        var name: [max_record_path_len]u8 = undefined;
        var legacy_name: [legacy_filename_len]u8 = undefined;
        const filename = recordFilename(&name, book_path, book_id, resume_filename) orelse return false;
        const legacy = legacyPositionFilename(&legacy_name, book_id) orelse return false;
        const deleted = self.files.delete(self.files.context, filename);
        return self.files.delete(self.files.context, legacy) or deleted;
    }

    pub fn loadPace(self: *Service, book_path: []const u8, book_id: u32) Pace {
        self.schedule.clear(.pace);
        var name: [max_record_path_len]u8 = undefined;
        var legacy_name: [legacy_filename_len]u8 = undefined;
        const filename = recordFilename(&name, book_path, book_id, pace_filename) orelse return .{ .book_id = book_id };
        const legacy = legacyPaceFilename(&legacy_name, book_id) orelse return .{ .book_id = book_id };
        var bytes: [reading_pace.encoded_size]u8 = undefined;
        if (!self.files.read(self.files.context, filename, &bytes) and !self.files.read(self.files.context, legacy, &bytes)) return .{ .book_id = book_id };
        const stored = reading_pace.decode(&bytes) catch return .{ .book_id = book_id };
        return if (stored.book_id == book_id) stored else .{ .book_id = book_id };
    }

    pub fn savePace(self: *const Service, book_path: []const u8, pace: Pace) bool {
        var bytes: [reading_pace.encoded_size]u8 = undefined;
        reading_pace.encode(pace, &bytes);
        return writeBookRecord(self, book_path, pace.book_id, pace_filename, &bytes, LegacyKind.pace);
    }

    pub fn loadProgress(self: *Service, book_path: []const u8, key: ProgressKey) ?ProgressIndex {
        self.schedule.clear(.progress);
        var name: [max_record_path_len]u8 = undefined;
        var legacy_name: [legacy_filename_len]u8 = undefined;
        const filename = recordFilename(&name, book_path, key.book_id, progress_filename) orelse return null;
        const legacy = legacyProgressFilename(&legacy_name, key.book_id) orelse return null;
        var bytes: [reading_progress.encoded_size]u8 = undefined;
        if (self.files.read(self.files.context, filename, &bytes)) return reading_progress.decode(&bytes, key) catch null;
        if (self.files.read(self.files.context, legacy, &bytes)) return reading_progress.decode(&bytes, key) catch null;
        var legacy_bytes: [reading_progress.legacy_encoded_size]u8 = undefined;
        if (!self.files.read(self.files.context, legacy, &legacy_bytes)) return null;
        return reading_progress.decodeLegacy(&legacy_bytes, key) catch null;
    }

    /// Reads the last self-validating progress record for a library entry.
    /// Opening the book still performs the stricter fingerprint check above.
    pub fn loadLibraryProgress(self: *const Service, book_path: []const u8, book_id: u32) ?ProgressIndex {
        var name: [max_record_path_len]u8 = undefined;
        var legacy_name: [legacy_filename_len]u8 = undefined;
        const filename = recordFilename(&name, book_path, book_id, progress_filename) orelse return null;
        const legacy = legacyProgressFilename(&legacy_name, book_id) orelse return null;
        var bytes: [reading_progress.encoded_size]u8 = undefined;
        const index = if (self.files.read(self.files.context, filename, &bytes))
            reading_progress.decodeStored(&bytes) catch return null
        else if (self.files.read(self.files.context, legacy, &bytes))
            reading_progress.decodeStored(&bytes) catch return null
        else blk: {
            var legacy_bytes: [reading_progress.legacy_encoded_size]u8 = undefined;
            if (!self.files.read(self.files.context, legacy, &legacy_bytes)) return null;
            break :blk reading_progress.decodeLegacyStored(&legacy_bytes) catch return null;
        };
        return if (index.key.book_id == book_id) index else null;
    }

    pub fn saveProgress(self: *const Service, book_path: []const u8, index: ProgressIndex) bool {
        var bytes: [reading_progress.encoded_size]u8 = undefined;
        reading_progress.encode(index, &bytes) catch return false;
        return writeBookRecord(self, book_path, index.key.book_id, progress_filename, &bytes, LegacyKind.progress);
    }

    pub fn requestWrite(self: *Service, kind: WriteKind, delay_frames: u8) void {
        self.schedule.request(kind, delay_frames);
    }

    pub fn writeDue(self: *Service, kind: WriteKind) bool {
        return self.schedule.advance(kind);
    }

    pub fn writePending(self: *const Service, kind: WriteKind) bool {
        return self.schedule.pending(kind);
    }

    pub fn completeWrite(self: *Service, kind: WriteKind) void {
        self.schedule.clear(kind);
    }

    /// Position writes preserve the existing best-effort policy: a due save
    /// is consumed before the I/O attempt, so a failed position write waits
    /// for the next semantic position change to schedule another attempt.
    pub fn flushPositionIfDue(self: *Service, book_path: []const u8, snapshot: ReadingSnapshot) bool {
        if (!self.writeDue(.position)) return false;
        self.completeWrite(.position);
        return self.savePosition(book_path, snapshot);
    }

    pub fn flushPositionNow(self: *Service, book_path: []const u8, snapshot: ReadingSnapshot) bool {
        self.completeWrite(.position);
        return self.savePosition(book_path, snapshot);
    }

    /// Pace keeps its due request after failure, allowing a later frame or a
    /// library return to retry without losing accumulated autoplay data.
    pub fn flushPaceIfDue(self: *Service, book_path: []const u8, pace: Pace) bool {
        if (!self.writeDue(.pace)) return false;
        if (!self.savePace(book_path, pace)) return false;
        self.completeWrite(.pace);
        return true;
    }

    pub fn flushPendingPace(self: *Service, book_path: []const u8, pace: Pace) bool {
        if (!self.writePending(.pace)) return false;
        if (!self.savePace(book_path, pace)) return false;
        self.completeWrite(.pace);
        return true;
    }

    /// Partial progress indexes retain their request after an I/O failure so
    /// verified chapter counts are retried without rescanning content.
    pub fn flushProgressIfDue(self: *Service, book_path: []const u8, index: ProgressIndex) bool {
        if (!self.writeDue(.progress)) return false;
        if (!self.saveProgress(book_path, index)) return false;
        self.completeWrite(.progress);
        return true;
    }

    pub fn flushPendingProgress(self: *Service, book_path: []const u8, index: ProgressIndex) bool {
        if (!self.writePending(.progress)) return false;
        if (!self.saveProgress(book_path, index)) return false;
        self.completeWrite(.progress);
        return true;
    }
};

const settings_filename = "settings.bin";
const book_data_root = "book-data";
const max_book_label_len = 40;
const max_record_path_len = 80;
const legacy_filename_len = 24;
const resume_filename = "resume.bin";
const pace_filename = "pace.bin";
const progress_filename = "progress.bin";

fn legacyPositionFilename(buffer: []u8, book_id: u32) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "resume-{x}.bin", .{book_id}) catch null;
}

fn legacyPaceFilename(buffer: []u8, book_id: u32) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "pace-{x}.bin", .{book_id}) catch null;
}

fn legacyProgressFilename(buffer: []u8, book_id: u32) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "progress-{x}.bin", .{book_id}) catch null;
}

const LegacyKind = enum { position, pace, progress };

fn recordFilename(buffer: []u8, book_path: []const u8, book_id: u32, leaf: []const u8) ?[]const u8 {
    var folder: [max_record_path_len]u8 = undefined;
    const folder_name = bookFolder(&folder, book_path, book_id) orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ folder_name, leaf }) catch null;
}

fn bookFolder(buffer: []u8, book_path: []const u8, book_id: u32) ?[]const u8 {
    const filename = if (std.mem.lastIndexOfScalar(u8, book_path, '/')) |slash| book_path[slash + 1 ..] else book_path;
    const stem = if (filename.len >= 5 and std.ascii.eqlIgnoreCase(filename[filename.len - 5 ..], ".epub")) filename[0 .. filename.len - 5] else filename;
    var label: [max_book_label_len]u8 = undefined;
    const label_len = sanitizeBookLabel(stem, &label);
    return std.fmt.bufPrint(buffer, "{s}/{s}--{x}", .{ book_data_root, label[0..label_len], book_id }) catch null;
}

fn sanitizeBookLabel(input: []const u8, output: *[max_book_label_len]u8) usize {
    var len: usize = 0;
    var pending_separator = false;
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') {
            if (pending_separator and len != 0 and len < output.len) {
                output[len] = '-';
                len += 1;
            }
            pending_separator = false;
            if (len == output.len) break;
            output[len] = byte;
            len += 1;
        } else {
            pending_separator = len != 0;
        }
    }
    while (len != 0 and output[len - 1] == '-') len -= 1;
    if (len != 0) return len;
    @memcpy(output[0..4], "book");
    return 4;
}

fn legacyFilename(buffer: []u8, kind: LegacyKind, book_id: u32) ?[]const u8 {
    return switch (kind) {
        .position => legacyPositionFilename(buffer, book_id),
        .pace => legacyPaceFilename(buffer, book_id),
        .progress => legacyProgressFilename(buffer, book_id),
    };
}

fn writeBookRecord(self: *const Service, book_path: []const u8, book_id: u32, leaf: []const u8, bytes: []const u8, kind: LegacyKind) bool {
    var folder: [max_record_path_len]u8 = undefined;
    const directory = bookFolder(&folder, book_path, book_id) orelse return false;
    if (!self.files.ensure_directory(self.files.context, book_data_root)) return false;
    if (!self.files.ensure_directory(self.files.context, directory)) return false;
    var name: [max_record_path_len]u8 = undefined;
    const filename = recordFilename(&name, book_path, book_id, leaf) orelse return false;
    if (!self.files.write(self.files.context, filename, bytes)) return false;
    var legacy_name: [legacy_filename_len]u8 = undefined;
    if (legacyFilename(&legacy_name, kind, book_id)) |legacy| _ = self.files.delete(self.files.context, legacy);
    return true;
}

test "a service saves and restores an isolated book snapshot" {
    var files = MemoryFiles{};
    var service = Service.init(files.port());
    const snapshot = ReadingSnapshot{
        .book_id = 7,
        .layout_revision = 2,
        .chapter = 3,
        .word_ordinal = 42,
        .mode = .rsvp,
    };

    try std.testing.expect(service.savePosition("Example Book.epub", snapshot));
    const restored = service.loadPosition("Example Book.epub", 7, 2) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(snapshot, restored.snapshot);
    try std.testing.expect(service.loadPosition("Other Book.epub", 8, 2) == null);
}

test "book folders use a bounded readable EPUB stem and stable identity" {
    var folder: [max_record_path_len]u8 = undefined;
    const name = bookFolder(&folder, "Library/A very, very, very, very, very long title!!!.EPUB", 0xa18c42f7) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.startsWith(u8, name, "book-data/A-very-very-very-very-very-long-title--a18c42f7"));
    try std.testing.expect(name.len < max_record_path_len);
}

test "legacy flat records load before their first folder-format save" {
    var files = MemoryFiles{};
    var service = Service.init(files.port());
    const snapshot = ReadingSnapshot{ .book_id = 7, .layout_revision = 2, .chapter = 3, .word_ordinal = 42, .mode = .rsvp };
    var bytes: [reading_position.encoded_size]u8 = undefined;
    reading_state.encodeResume(snapshot, &bytes);
    files.seed("resume-7.bin", &bytes);

    const restored = service.loadPosition("Example Book.epub", 7, 2) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(snapshot, restored.snapshot);
    try std.testing.expect(service.savePosition("Example Book.epub", snapshot));
    try std.testing.expect(std.mem.startsWith(u8, files.name[0..files.name_len], "book-data/Example-Book--7/resume.bin"));
}

test "current-format legacy progress indexes load from their flat filenames" {
    var files = MemoryFiles{};
    var service = Service.init(files.port());
    const key = ProgressKey{ .book_id = 7, .publication_fingerprint = [_]u8{0xa5} ** 16, .word_semantics_revision = 1, .spine_len = 2 };
    var index = reading_progress.Index.init(key) catch unreachable;
    index.setExact(0, 42) catch unreachable;
    var bytes: [reading_progress.encoded_size]u8 = undefined;
    reading_progress.encode(index, &bytes) catch unreachable;
    files.seed("progress-7.bin", &bytes);

    const restored = service.loadProgress("Example Book.epub", key) orelse return error.TestExpectedEqual;
    try std.testing.expect(restored.exact.contains(0));
    try std.testing.expectEqual(@as(u32, 42), restored.chapter_words[0]);
}

test "deleting a position clears its pending write and saved resume" {
    var files = MemoryFiles{};
    var service = Service.init(files.port());
    const snapshot = ReadingSnapshot{
        .book_id = 7,
        .layout_revision = 2,
        .chapter = 3,
        .word_ordinal = 42,
        .mode = .paged,
    };

    try std.testing.expect(service.savePosition("Example Book.epub", snapshot));
    service.requestWrite(.position, 10);
    try std.testing.expect(service.deletePosition("Example Book.epub", 7));
    try std.testing.expect(!service.writePending(.position));
    try std.testing.expect(service.loadPosition("Example Book.epub", 7, 2) == null);
}

test "a failed due pace write stays pending until it can be persisted" {
    var files = MemoryFiles{ .fail_writes = true };
    var service = Service.init(files.port());
    service.requestWrite(.pace, 0);

    try std.testing.expect(!service.flushPaceIfDue("Example Book.epub", .{ .book_id = 7 }));
    try std.testing.expect(service.writePending(.pace));

    files.fail_writes = false;
    try std.testing.expect(service.flushPaceIfDue("Example Book.epub", .{ .book_id = 7 }));
    try std.testing.expect(!service.writePending(.pace));
}

test "settings persist independently of per-book records" {
    var files = MemoryFiles{};
    var service = Service.init(files.port());
    const settings = Settings{ .reading_mode = .rsvp, .rsvp_wpm = 425, .theme = .dark, .pages_font = .newsleak_serif, .rsvp_font = .roobert_24_medium };
    try std.testing.expect(service.saveSettings(settings));
    try std.testing.expectEqual(settings, service.loadSettings());
}

test "independent reading fonts round trip through the settings record" {
    var files = MemoryFiles{};
    var service = Service.init(files.port());
    const settings = Settings{ .reading_mode = .paged, .rsvp_wpm = 300, .theme = .light, .pages_font = .asheville_sans_14_bold, .rsvp_font = .sasser_slab };
    try std.testing.expect(service.saveSettings(settings));
    try std.testing.expectEqual(settings, service.loadSettings());
}

test "progress indexes persist by book identity and retry failed writes" {
    var files = MemoryFiles{};
    var service = Service.init(files.port());
    const key = ProgressKey{
        .book_id = 7,
        .publication_fingerprint = [_]u8{0xa5} ** 16,
        .word_semantics_revision = 1,
        .spine_len = 2,
    };
    var index = reading_progress.Index.init(key) catch unreachable;
    index.setExact(0, 42) catch unreachable;

    service.requestWrite(.progress, 0);
    files.fail_writes = true;
    try std.testing.expect(!service.flushProgressIfDue("Example Book.epub", index));
    try std.testing.expect(service.writePending(.progress));
    files.fail_writes = false;
    try std.testing.expect(service.flushProgressIfDue("Example Book.epub", index));
    try std.testing.expect(!service.writePending(.progress));

    const restored = service.loadProgress("Example Book.epub", key) orelse return error.TestExpectedEqual;
    try std.testing.expect(restored.exact.contains(0));
    try std.testing.expectEqual(@as(u32, 42), restored.chapter_words[0]);
}

const MemoryFiles = struct {
    name: [96]u8 = undefined,
    name_len: usize = 0,
    bytes: [reading_progress.encoded_size]u8 = undefined,
    bytes_len: usize = 0,
    fail_writes: bool = false,

    fn port(self: *MemoryFiles) FileStore {
        return .{ .context = self, .read = read, .write = write, .delete = delete, .ensure_directory = ensureDirectory };
    }

    fn read(context: *anyopaque, name: []const u8, output: []u8) bool {
        const self: *MemoryFiles = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, name, self.name[0..self.name_len]) or output.len != self.bytes_len) return false;
        @memcpy(output, self.bytes[0..self.bytes_len]);
        return true;
    }

    fn write(context: *anyopaque, name: []const u8, input: []const u8) bool {
        const self: *MemoryFiles = @ptrCast(@alignCast(context));
        if (self.fail_writes) return false;
        if (name.len > self.name.len or input.len > self.bytes.len) return false;
        @memcpy(self.name[0..name.len], name);
        @memcpy(self.bytes[0..input.len], input);
        self.name_len = name.len;
        self.bytes_len = input.len;
        return true;
    }

    fn delete(context: *anyopaque, name: []const u8) bool {
        const self: *MemoryFiles = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, name, self.name[0..self.name_len])) return false;
        self.name_len = 0;
        self.bytes_len = 0;
        return true;
    }

    fn seed(self: *MemoryFiles, name: []const u8, input: []const u8) void {
        std.debug.assert(name.len <= self.name.len and input.len <= self.bytes.len);
        @memcpy(self.name[0..name.len], name);
        @memcpy(self.bytes[0..input.len], input);
        self.name_len = name.len;
        self.bytes_len = input.len;
    }

    fn ensureDirectory(_: *anyopaque, _: []const u8) bool {
        return true;
    }
};
