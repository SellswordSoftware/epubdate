const std = @import("std");
const deflate = @import("archive/deflate.zig");
const zip = @import("archive/zip.zig");
const pagination = @import("content/pagination.zig");
const xhtml = @import("content/xhtml.zig");

pub const PageSlot = u8;

/// Bounded preparation of one next-chapter page. File opening and central
/// directory lookup are deliberately outside this type; after an entry is
/// selected, all decoding and page-construction state belongs here.
pub const Session = struct {
    pub const State = union(enum) {
        idle,
        looking_up: struct { chapter: u8, scanner: zip.ArchiveScanner, finder: ?zip.EntryFinder = null },
        decoding: struct { chapter: u8, page: PageSlot },
        ready: struct { chapter: u8, page: PageSlot, ended: bool },
        active,
        failed,
    };

    pub const Step = enum { working, ready, failed };
    pub const Activation = struct { chapter: u8, page: PageSlot, ended: bool };
    pub const FileLease = struct {
        context: *anyopaque,
        close: *const fn (context: *anyopaque) void,
    };
    pub const Lookup = union(enum) {
        working,
        found: struct { chapter: u8, archive: zip.Archive, entry: zip.Entry },
        missing,
        failed,
    };

    state: State = .idle,
    stream: ?zip.EntryStream = null,
    storage: zip.StreamStorage = undefined,
    extractor: ?xhtml.StreamExtractor = null,
    builder: ?pagination.EventPageBuilder = null,
    output_start: usize = 0,
    output_end: usize = 0,
    file_lease: ?FileLease = null,

    pub fn attachFile(self: *Session, lease: FileLease) void {
        std.debug.assert(self.file_lease == null);
        self.file_lease = lease;
    }

    /// The file becomes the active chapter's ownership on activation, so the
    /// session must no longer close it during later prefetch cleanup.
    pub fn detachFile(self: *Session) void {
        self.file_lease = null;
    }

    pub fn startLookup(self: *Session, chapter: u8, reader: zip.Reader) zip.Error!void {
        self.state = .{ .looking_up = .{ .chapter = chapter, .scanner = try zip.ArchiveScanner.init(reader) } };
    }

    /// Performs only bounded archive metadata work. The filename and scanner
    /// staging buffers remain caller-owned fixed storage.
    pub fn stepLookup(self: *Session, scan_buffer: []u8, filename_buffer: []u8, name: []const u8, records: usize) Lookup {
        if (self.state != .looking_up) return .failed;
        const lookup = &self.state.looking_up;
        if (lookup.finder == null) {
            const archive = lookup.scanner.step(scan_buffer) catch {
                self.state = .failed;
                return .failed;
            } orelse return .working;
            lookup.finder = zip.EntryFinder.init(archive, name);
        }
        for (0..records) |_| {
            const entry = lookup.finder.?.step(filename_buffer) catch {
                self.state = .failed;
                return .failed;
            } orelse {
                if (lookup.finder.?.entry_index == lookup.finder.?.archive.entry_count) {
                    self.state = .idle;
                    return .missing;
                }
                return .working;
            };
            const found = Lookup{ .found = .{ .chapter = lookup.chapter, .archive = lookup.finder.?.archive, .entry = entry } };
            self.state = .idle;
            return found;
        }
        return .working;
    }

    pub fn begin(
        self: *Session,
        archive: zip.Archive,
        entry: zip.Entry,
        chapter: u8,
        page_slot: PageSlot,
        page: *pagination.PageCache,
        compressed_input: []u8,
        window: []u8,
        workspace: *deflate.Workspace,
        width: usize,
        measure: pagination.Measure,
    ) zip.Error!void {
        self.storage = zip.StreamStorage.init(compressed_input, window, workspace);
        self.stream = try archive.begin(entry, &self.storage);
        self.builder = pagination.EventPageBuilder.init(page, width, measure);
        self.extractor = xhtml.StreamExtractor.init(.{ .context = self, .emit = emitEvent });
        self.output_start = 0;
        self.output_end = 0;
        self.state = .{ .decoding = .{ .chapter = chapter, .page = page_slot } };
    }

    /// Uses no more than `budget` bytes of the caller-owned decoded buffer.
    /// The caller may safely reuse that buffer because only cursor positions
    /// are retained after the call returns.
    pub fn step(self: *Session, output: []u8, budget: usize) Step {
        if (self.state != .decoding) return if (self.state == .ready) .ready else .failed;
        var remaining = budget;
        while (remaining != 0) {
            if (self.output_start != self.output_end) {
                const available = output[self.output_start..self.output_end];
                const progress = self.extractor.?.feed(available[0..@min(available.len, remaining)]) catch {
                    self.state = .failed;
                    return .failed;
                };
                const consumed = switch (progress) {
                    .consumed => |count| count,
                    .page_full => |count| {
                        self.output_start += count;
                        self.markReady(false);
                        return .ready;
                    },
                };
                self.output_start += consumed;
                remaining -= consumed;
                continue;
            }
            const read = self.stream.?.read(output[0..@min(output.len, remaining)]) catch {
                self.state = .failed;
                return .failed;
            };
            switch (read) {
                .bytes => |count| {
                    self.output_start = 0;
                    self.output_end = count;
                },
                .end => {
                    self.extractor.?.finish() catch {
                        self.state = .failed;
                        return .failed;
                    };
                    self.builder.?.end() catch |err| switch (err) {
                        // The entry is already at EOF; keep decoding state
                        // until `finish` verifies its CRC, then mark ready.
                        error.PageFull => {},
                        error.LineTooLong => {
                            self.state = .failed;
                            return .failed;
                        },
                    };
                    self.stream.?.finish() catch {
                        self.state = .failed;
                        return .failed;
                    };
                    if (self.builder.?.cache.line_count == 0) {
                        self.state = .failed;
                        return .failed;
                    }
                    self.markReady(true);
                    return .ready;
                },
                .needs_input => {
                    self.state = .failed;
                    return .failed;
                },
            }
        }
        return .working;
    }

    pub fn cancel(self: *Session) void {
        // The prepared stream has become the active chapter stream. Its
        // storage must remain intact until that chapter reaches verified EOF.
        if (self.state == .active) return;
        if (self.file_lease) |lease| lease.close(lease.context);
        self.file_lease = null;
        self.stream = null;
        self.extractor = null;
        self.builder = null;
        self.output_start = 0;
        self.output_end = 0;
        self.state = .idle;
    }

    pub fn isPrefetching(self: *const Session) bool {
        return self.state == .looking_up or self.state == .decoding or self.state == .ready;
    }

    pub fn isReady(self: *const Session) bool {
        return self.state == .ready;
    }

    pub fn activate(self: *Session) ?Activation {
        const ready = switch (self.state) {
            .ready => |value| value,
            else => return null,
        };
        self.state = .active;
        return .{ .chapter = ready.chapter, .page = ready.page, .ended = ready.ended };
    }

    /// The app has stopped the activated stream and closed its stable file
    /// backing. Clear the session before it starts another prefetch; unlike
    /// `cancel`, this deliberately does not invoke a file lease callback.
    pub fn releaseActive(self: *Session) void {
        std.debug.assert(self.state == .active);
        std.debug.assert(self.file_lease == null);
        self.stream = null;
        self.extractor = null;
        self.builder = null;
        self.output_start = 0;
        self.output_end = 0;
        self.state = .idle;
    }

    pub fn readyChapter(self: *const Session) ?u8 {
        return switch (self.state) {
            .ready => |ready| ready.chapter,
            else => null,
        };
    }

    pub fn readyPage(self: *const Session) ?PageSlot {
        return switch (self.state) {
            .ready => |ready| ready.page,
            else => null,
        };
    }

    pub fn ended(self: *const Session) bool {
        return switch (self.state) {
            .ready => |ready| ready.ended,
            else => false,
        };
    }

    fn markReady(self: *Session, at_eof: bool) void {
        const decoding = switch (self.state) {
            .decoding => |value| value,
            else => unreachable,
        };
        self.state = .{ .ready = .{ .chapter = decoding.chapter, .page = decoding.page, .ended = at_eof } };
    }

    fn emitEvent(context: *anyopaque, event: xhtml.Event) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(context));
        try self.builder.?.consume(event);
    }
};

test "cancellation clears all decode state" {
    var session = Session{};
    session.output_start = 2;
    session.output_end = 9;
    session.state = .failed;
    session.cancel();
    try std.testing.expectEqual(Session.State.idle, session.state);
    try std.testing.expect(session.stream == null);
    try std.testing.expect(session.extractor == null);
    try std.testing.expect(session.builder == null);
    try std.testing.expectEqual(@as(usize, 0), session.output_start);
    try std.testing.expectEqual(@as(usize, 0), session.output_end);
}

test "activation preserves the prepared first page and makes cancellation harmless" {
    var session = Session{};
    session.state = .{ .ready = .{ .chapter = 3, .page = 2, .ended = false } };
    session.output_start = 4;
    session.output_end = 8;
    const activation = session.activate().?;
    try std.testing.expectEqual(@as(u8, 3), activation.chapter);
    try std.testing.expectEqual(@as(PageSlot, 2), activation.page);
    try std.testing.expect(!activation.ended);
    session.cancel();
    try std.testing.expectEqual(Session.State.active, session.state);
    try std.testing.expectEqual(@as(usize, 4), session.output_start);
    try std.testing.expectEqual(@as(usize, 8), session.output_end);
}

test "releasing an activated session clears decode state without a file lease" {
    var session = Session{};
    session.state = .active;
    session.output_start = 4;
    session.output_end = 8;
    session.releaseActive();
    try std.testing.expectEqual(Session.State.idle, session.state);
    try std.testing.expectEqual(@as(usize, 0), session.output_start);
    try std.testing.expectEqual(@as(usize, 0), session.output_end);
}

const LeaseProbe = struct {
    closed: bool = false,

    fn close(context: *anyopaque) void {
        const probe: *LeaseProbe = @ptrCast(@alignCast(context));
        probe.closed = true;
    }
};

test "cancellation closes an attached file lease before activation" {
    var probe = LeaseProbe{};
    var session = Session{};
    session.attachFile(.{ .context = &probe, .close = LeaseProbe.close });
    session.cancel();
    try std.testing.expect(probe.closed);
    try std.testing.expect(session.file_lease == null);
}
