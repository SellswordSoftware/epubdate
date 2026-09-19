const std = @import("std");
const reading_position = @import("resume.zig");
const reading_state = @import("reading_state.zig");
const reading_pace = @import("pace.zig");
const reader_settings = @import("settings.zig");
const write_schedule = @import("write_schedule.zig");

pub const ReadingSnapshot = reading_state.ReadingSnapshot;
pub const RestoredPosition = reading_state.RestoredPosition;
pub const Settings = reader_settings.Settings;
pub const Pace = reading_pace.Stats;
pub const WriteKind = write_schedule.Kind;

/// The only persistence I/O contract required by reader code. Platform
/// adapters own handles, flags, and flushing; this layer owns record names,
/// validation, and format selection.
pub const FileStore = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, name: []const u8, output: []u8) bool,
    write: *const fn (context: *anyopaque, name: []const u8, input: []const u8) bool,
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

    pub fn loadPosition(self: *const Service, book_id: u32, layout_revision: u16) ?RestoredPosition {
        var name: [24]u8 = undefined;
        const filename = positionFilename(&name, book_id) orelse return null;
        var bytes: [reading_position.encoded_size]u8 = undefined;
        if (!self.files.read(self.files.context, filename, &bytes)) return null;
        return reading_state.restoreResume(&bytes, book_id, layout_revision);
    }

    pub fn savePosition(self: *const Service, snapshot: ReadingSnapshot) bool {
        var name: [24]u8 = undefined;
        const filename = positionFilename(&name, snapshot.book_id) orelse return false;
        var bytes: [reading_position.encoded_size]u8 = undefined;
        reading_state.encodeResume(snapshot, &bytes);
        return self.files.write(self.files.context, filename, &bytes);
    }

    pub fn loadPace(self: *Service, book_id: u32) Pace {
        self.schedule.clear(.pace);
        var name: [24]u8 = undefined;
        const filename = paceFilename(&name, book_id) orelse return .{ .book_id = book_id };
        var bytes: [reading_pace.encoded_size]u8 = undefined;
        if (!self.files.read(self.files.context, filename, &bytes)) return .{ .book_id = book_id };
        const stored = reading_pace.decode(&bytes) catch return .{ .book_id = book_id };
        return if (stored.book_id == book_id) stored else .{ .book_id = book_id };
    }

    pub fn savePace(self: *const Service, pace: Pace) bool {
        var name: [24]u8 = undefined;
        const filename = paceFilename(&name, pace.book_id) orelse return false;
        var bytes: [reading_pace.encoded_size]u8 = undefined;
        reading_pace.encode(pace, &bytes);
        return self.files.write(self.files.context, filename, &bytes);
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
    pub fn flushPositionIfDue(self: *Service, snapshot: ReadingSnapshot) bool {
        if (!self.writeDue(.position)) return false;
        self.completeWrite(.position);
        return self.savePosition(snapshot);
    }

    pub fn flushPositionNow(self: *Service, snapshot: ReadingSnapshot) bool {
        self.completeWrite(.position);
        return self.savePosition(snapshot);
    }

    /// Pace keeps its due request after failure, allowing a later frame or a
    /// library return to retry without losing accumulated autoplay data.
    pub fn flushPaceIfDue(self: *Service, pace: Pace) bool {
        if (!self.writeDue(.pace)) return false;
        if (!self.savePace(pace)) return false;
        self.completeWrite(.pace);
        return true;
    }

    pub fn flushPendingPace(self: *Service, pace: Pace) bool {
        if (!self.writePending(.pace)) return false;
        if (!self.savePace(pace)) return false;
        self.completeWrite(.pace);
        return true;
    }
};

const settings_filename = "settings.bin";

fn positionFilename(buffer: []u8, book_id: u32) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "resume-{x}.bin", .{book_id}) catch null;
}

fn paceFilename(buffer: []u8, book_id: u32) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "pace-{x}.bin", .{book_id}) catch null;
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

    try std.testing.expect(service.savePosition(snapshot));
    const restored = service.loadPosition(7, 2) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(snapshot, restored.snapshot);
    try std.testing.expect(service.loadPosition(8, 2) == null);
}

test "a failed due pace write stays pending until it can be persisted" {
    var files = MemoryFiles{ .fail_writes = true };
    var service = Service.init(files.port());
    service.requestWrite(.pace, 0);

    try std.testing.expect(!service.flushPaceIfDue(.{ .book_id = 7 }));
    try std.testing.expect(service.writePending(.pace));

    files.fail_writes = false;
    try std.testing.expect(service.flushPaceIfDue(.{ .book_id = 7 }));
    try std.testing.expect(!service.writePending(.pace));
}

test "settings persist independently of per-book records" {
    var files = MemoryFiles{};
    var service = Service.init(files.port());
    try std.testing.expect(service.saveSettings(.{ .reading_mode = .rsvp, .rsvp_wpm = 425 }));
    try std.testing.expectEqual(Settings{ .reading_mode = .rsvp, .rsvp_wpm = 425 }, service.loadSettings());
}

const MemoryFiles = struct {
    name: [32]u8 = undefined,
    name_len: usize = 0,
    bytes: [16]u8 = undefined,
    bytes_len: usize = 0,
    fail_writes: bool = false,

    fn port(self: *MemoryFiles) FileStore {
        return .{ .context = self, .read = read, .write = write };
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
};
