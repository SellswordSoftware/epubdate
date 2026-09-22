const std = @import("std");
const deflate = @import("archive/deflate.zig");
const zip = @import("archive/zip.zig");
const rsvp = @import("content/rsvp.zig");
const xhtml = @import("content/xhtml.zig");
const epub = @import("publication/epub.zig");
const progress = @import("storage/progress.zig");
const limits = @import("limits").reader;

pub const default_byte_budget = limits.progress_index_bytes_per_update;
pub const fixed_byte_budget = 64 * 1024;

pub const FileLease = struct {
    context: *anyopaque,
    close: *const fn (context: *anyopaque) void,
};

pub const Phase = enum {
    idle,
    scanning_archive,
    validating_directory,
    selecting_chapter,
    finding_entry,
    counting,
    complete,
    retryable_failure,
    failed,
};

pub const Failure = enum {
    io,
    archive,
    tokenizer,
    count_overflow,
};

pub const Step = union(enum) {
    idle,
    working,
    chapter_complete: u8,
    chapter_failed: u8,
    complete,
    retryable_failure,
    failed: Failure,
};

pub const Status = struct {
    phase: Phase,
    current_chapter: u8,
    target_chapter: ?u8,
    indexed_chapters: u8,
    decoded_last_update: u16,
    last_failure: ?Failure,
    dirty: bool,
};

/// Independently scans one open EPUB using only fixed storage. Initialize this
/// object in its final heap location before calling `open`: its tokenizer and
/// word cursor retain callbacks to the object while a chapter is counted.
pub const Indexer = struct {
    phase: Phase = .idle,
    index: ?progress.Index = null,
    publication: ?*const epub.Publication = null,
    current_chapter: u8 = 0,
    target_chapter: ?u8 = null,
    dirty: bool = false,
    last_failure: ?Failure = null,
    decoded_last_update: u16 = 0,
    file_lease: ?FileLease = null,

    scanner: ?zip.ArchiveScanner = null,
    archive: ?zip.Archive = null,
    validator: ?zip.DirectoryValidator = null,
    finder: ?zip.EntryFinder = null,
    stream: ?zip.EntryStream = null,
    cursor: ?rsvp.Cursor = null,
    extractor: ?xhtml.StreamExtractor = null,
    chapter_word_count: u32 = 0,
    output_start: usize = 0,
    output_end: usize = 0,

    ranges: [limits.max_archive_entries]zip.MemberRange = undefined,
    archive_scan_buffer: [1024]u8 = undefined,
    archive_filename_buffer: [limits.max_archive_filename_bytes]u8 = undefined,
    compressed_input_buffer: [limits.compressed_input_bytes]u8 = undefined,
    deflate_window: [32 * 1024]u8 = undefined,
    deflate_workspace: deflate.Workspace = undefined,
    stream_storage: zip.StreamStorage = undefined,
    decoded_output: [limits.decoded_output_chunk_bytes]u8 = undefined,

    pub fn initInPlace(self: *Indexer) void {
        self.* = undefined;
        self.phase = .idle;
        self.index = null;
        self.publication = null;
        self.current_chapter = 0;
        self.target_chapter = null;
        self.dirty = false;
        self.last_failure = null;
        self.decoded_last_update = 0;
        self.file_lease = null;
        self.clearJobs();
    }

    pub fn open(
        self: *Indexer,
        index: progress.Index,
        publication: *const epub.Publication,
        current_chapter: u8,
        reader: zip.Reader,
        lease: FileLease,
    ) (zip.Error || error{InvalidPublication})!void {
        self.releaseFile();
        self.clearJobs();
        if (publication.spine_len != index.key.spine_len or current_chapter >= publication.spine_len) {
            lease.close(lease.context);
            return error.InvalidPublication;
        }

        self.index = index;
        self.publication = publication;
        self.current_chapter = current_chapter;
        self.dirty = false;
        self.last_failure = null;
        self.decoded_last_update = 0;
        self.file_lease = lease;
        self.scanner = zip.ArchiveScanner.init(reader) catch |err| {
            self.releaseFile();
            return err;
        };
        self.phase = .scanning_archive;
    }

    pub fn close(self: *Indexer) void {
        self.releaseFile();
        self.clearJobs();
        self.index = null;
        self.publication = null;
        self.current_chapter = 0;
        self.dirty = false;
        self.last_failure = null;
        self.decoded_last_update = 0;
        self.phase = .idle;
    }

    pub fn setCurrentChapter(self: *Indexer, chapter: u8) error{InvalidChapter}!void {
        const index = if (self.index) |*value| value else return error.InvalidChapter;
        if (chapter >= index.key.spine_len) return error.InvalidChapter;
        self.current_chapter = chapter;
    }

    pub fn observeChapterTotal(self: *Indexer, chapter: u8, words: u32) progress.Error!bool {
        const index = if (self.index) |*value| value else return error.InvalidChapter;
        if (index.exact.contains(chapter) and index.chapter_words[chapter] == words) return false;
        try index.setExact(chapter, words);
        self.dirty = true;
        if (self.target_chapter == chapter) {
            self.clearChapterJob();
            self.phase = .selecting_chapter;
        }
        return true;
    }

    pub fn clearDirty(self: *Indexer) void {
        self.dirty = false;
    }

    pub fn snapshot(self: *const Indexer) ?progress.Index {
        return self.index;
    }

    pub fn status(self: *const Indexer) Status {
        return .{
            .phase = self.phase,
            .current_chapter = self.current_chapter,
            .target_chapter = self.target_chapter,
            .indexed_chapters = if (self.index) |index| indexedCount(index) else 0,
            .decoded_last_update = self.decoded_last_update,
            .last_failure = self.last_failure,
            .dirty = self.dirty,
        };
    }

    pub fn update(self: *Indexer, byte_budget: usize) Step {
        self.decoded_last_update = 0;
        return switch (self.phase) {
            .idle => .idle,
            .scanning_archive => self.stepArchiveScan(),
            .validating_directory => self.stepDirectoryValidation(),
            .selecting_chapter => self.selectChapter(),
            .finding_entry => self.stepEntryLookup(),
            .counting => self.stepCounting(byte_budget),
            .complete => .complete,
            .retryable_failure => .retryable_failure,
            .failed => .{ .failed = self.last_failure orelse .archive },
        };
    }

    fn stepArchiveScan(self: *Indexer) Step {
        const found = self.scanner.?.step(&self.archive_scan_buffer) catch |err| return self.failGlobal(zipFailure(err));
        const archive = found orelse return .working;
        self.archive = archive;
        self.validator = zip.DirectoryValidator.init(archive, &self.ranges) catch |err| return self.failGlobal(zipFailure(err));
        self.phase = .validating_directory;
        return .working;
    }

    fn stepDirectoryValidation(self: *Indexer) Step {
        for (0..limits.progress_directory_records_per_update) |_| {
            const complete = self.validator.?.step(&self.archive_filename_buffer) catch |err| return self.failGlobal(zipFailure(err));
            if (!complete) continue;
            self.validator = null;
            self.phase = .selecting_chapter;
            return .working;
        }
        return .working;
    }

    fn selectChapter(self: *Indexer) Step {
        const index = &(self.index orelse return self.failGlobal(.archive));
        const target = nextUnknown(index.*, self.current_chapter) orelse {
            self.phase = .complete;
            self.releaseFile();
            return .complete;
        };
        self.target_chapter = target;
        self.finder = zip.EntryFinder.init(self.archive orelse return self.failGlobal(.archive), self.publication.?.spine[target].slice());
        self.phase = .finding_entry;
        return .working;
    }

    fn stepEntryLookup(self: *Indexer) Step {
        for (0..limits.progress_directory_records_per_update) |_| {
            const entry = self.finder.?.step(&self.archive_filename_buffer) catch |err| {
                if (err == error.ReadFailed) return self.failGlobal(.io);
                return self.failTarget(.archive);
            };
            if (entry) |found| {
                self.beginCounting(found) catch |err| {
                    if (err == error.ReadFailed) return self.failGlobal(.io);
                    return self.failTarget(.archive);
                };
                return .working;
            }
            if (self.finder.?.entry_index == self.archive.?.entry_count) return self.failTarget(.archive);
        }
        return .working;
    }

    fn beginCounting(self: *Indexer, entry: zip.Entry) zip.Error!void {
        self.stream_storage = zip.StreamStorage.init(&self.compressed_input_buffer, &self.deflate_window, &self.deflate_workspace);
        self.stream = try self.archive.?.begin(entry, &self.stream_storage);
        self.chapter_word_count = 0;
        self.cursor = rsvp.Cursor.init(.{ .context = self, .emit = emitWord });
        self.extractor = xhtml.StreamExtractor.init(.{ .context = self, .emit = emitEvent });
        self.output_start = 0;
        self.output_end = 0;
        self.phase = .counting;
    }

    fn stepCounting(self: *Indexer, byte_budget: usize) Step {
        var remaining: usize = @min(byte_budget, default_byte_budget);
        while (remaining != 0) {
            if (self.output_start != self.output_end) {
                const available = self.decoded_output[self.output_start..self.output_end];
                const allowed = @min(available.len, remaining);
                const consumed = switch (self.extractor.?.feed(available[0..allowed]) catch |err| return self.failTarget(contentFailure(err))) {
                    .consumed => |count| count,
                    .page_full => |count| count,
                };
                self.output_start += consumed;
                remaining -= consumed;
                self.decoded_last_update += @intCast(consumed);
                continue;
            }

            const read = self.stream.?.read(self.decoded_output[0..@min(self.decoded_output.len, remaining)]) catch |err| {
                if (err == error.ReadFailed) return self.failGlobal(.io);
                return self.failTarget(.archive);
            };
            switch (read) {
                .bytes => |count| {
                    self.output_start = 0;
                    self.output_end = count;
                },
                .end => return self.finishChapter(),
                .needs_input => return self.failTarget(.archive),
            }
        }
        return .working;
    }

    fn finishChapter(self: *Indexer) Step {
        self.extractor.?.finish() catch |err| return self.failTarget(contentFailure(err));
        self.cursor.?.finish() catch |err| return self.failTarget(contentFailure(err));
        self.stream.?.finish() catch |err| {
            if (err == error.ReadFailed) return self.failGlobal(.io);
            return self.failTarget(.archive);
        };

        const completed = self.target_chapter.?;
        self.index.?.setExact(completed, self.chapter_word_count) catch return self.failGlobal(.count_overflow);
        self.dirty = true;
        self.clearChapterJob();
        self.phase = .selecting_chapter;
        return .{ .chapter_complete = completed };
    }

    fn failTarget(self: *Indexer, failure: Failure) Step {
        const failed = self.target_chapter orelse return self.failGlobal(failure);
        self.index.?.setFailed(failed) catch return self.failGlobal(.count_overflow);
        self.dirty = true;
        self.last_failure = failure;
        self.clearChapterJob();
        self.phase = .selecting_chapter;
        return .{ .chapter_failed = failed };
    }

    fn failGlobal(self: *Indexer, failure: Failure) Step {
        self.last_failure = failure;
        self.phase = if (failure == .io) .retryable_failure else .failed;
        self.releaseFile();
        self.clearJobs();
        return if (failure == .io) .retryable_failure else .{ .failed = failure };
    }

    fn clearChapterJob(self: *Indexer) void {
        self.target_chapter = null;
        self.finder = null;
        self.stream = null;
        self.cursor = null;
        self.extractor = null;
        self.chapter_word_count = 0;
        self.output_start = 0;
        self.output_end = 0;
    }

    fn clearJobs(self: *Indexer) void {
        self.scanner = null;
        self.archive = null;
        self.validator = null;
        self.clearChapterJob();
    }

    fn releaseFile(self: *Indexer) void {
        if (self.file_lease) |lease| lease.close(lease.context);
        self.file_lease = null;
    }

    fn emitEvent(context: *anyopaque, event: xhtml.Event) anyerror!void {
        const self: *Indexer = @ptrCast(@alignCast(context));
        try self.cursor.?.consume(event);
    }

    fn emitWord(context: *anyopaque, _: rsvp.Word) anyerror!void {
        const self: *Indexer = @ptrCast(@alignCast(context));
        self.chapter_word_count = std.math.add(u32, self.chapter_word_count, 1) catch return error.CountOverflow;
    }
};

pub const fixed_reserved_bytes = @sizeOf(Indexer);

comptime {
    std.debug.assert(fixed_reserved_bytes <= fixed_byte_budget);
}

fn nextUnknown(index: progress.Index, current_chapter: u8) ?u8 {
    for (0..index.key.spine_len) |offset| {
        const chapter: u8 = @intCast((@as(usize, current_chapter) + offset) % index.key.spine_len);
        if (!index.exact.contains(chapter) and !index.failed.contains(chapter)) return chapter;
    }
    return null;
}

fn indexedCount(index: progress.Index) u8 {
    return @intCast(@popCount(index.exact.words[0]) + @popCount(index.exact.words[1]));
}

fn zipFailure(err: zip.Error) Failure {
    return if (err == error.ReadFailed) .io else .archive;
}

fn contentFailure(err: anyerror) Failure {
    return if (err == error.CountOverflow) .count_overflow else .tokenizer;
}

const TestEntry = struct {
    name: []const u8,
    contents: []const u8,
};

const TestArchiveOffsets = struct {
    local: [4]usize = undefined,
    data: [4]usize = undefined,
    central: [4]usize = undefined,
};

const TestSource = struct {
    bytes: []const u8,
    fail_reads: bool = false,
    close_count: usize = 0,

    fn reader(self: *TestSource) zip.Reader {
        return .{ .context = self, .size = @intCast(self.bytes.len), .read_at = readAt };
    }

    fn lease(self: *TestSource) FileLease {
        return .{ .context = self, .close = close };
    }

    fn readAt(context: *anyopaque, offset: u32, destination: []u8) zip.Error!void {
        const self: *TestSource = @ptrCast(@alignCast(context));
        if (self.fail_reads) return error.ReadFailed;
        const start: usize = offset;
        const end = std.math.add(usize, start, destination.len) catch return error.UnexpectedEof;
        if (end > self.bytes.len) return error.UnexpectedEof;
        @memcpy(destination, self.bytes[start..end]);
    }

    fn close(context: *anyopaque) void {
        const self: *TestSource = @ptrCast(@alignCast(context));
        self.close_count += 1;
    }
};

test "indexing is bounded current-first and commits only validated chapters" {
    const good = "<p>one two</p>";
    var malformed: [xhtml.StreamExtractor.max_tag_bytes + 1]u8 = [_]u8{'a'} ** (xhtml.StreamExtractor.max_tag_bytes + 1);
    malformed[0] = '<';
    const entries = [_]TestEntry{
        .{ .name = "chapter-0.xhtml", .contents = good },
        .{ .name = "chapter-1.xhtml", .contents = &malformed },
        .{ .name = "chapter-2.xhtml", .contents = "<p>bad crc</p>" },
        .{ .name = "chapter-3.xhtml", .contents = "<p>bad size</p>" },
    };
    var archive_bytes: [4096]u8 = undefined;
    var offsets: TestArchiveOffsets = .{};
    const archive_len = makeStoredArchive(&archive_bytes, &entries, &offsets);

    // Content no longer matches the CRC retained by both headers.
    archive_bytes[offsets.data[2] + 3] ^= 1;
    // Locally consistent metadata still describes an impossible stored entry.
    writeTestU32(&archive_bytes, offsets.local[3] + 22, entries[3].contents.len + 1);
    writeTestU32(&archive_bytes, offsets.central[3] + 24, entries[3].contents.len + 1);

    var publication: epub.Publication = undefined;
    publication.spine_len = entries.len;
    for (entries, 0..) |entry, chapter| {
        publication.spine[chapter].path_len = @intCast(entry.name.len);
        @memcpy(publication.spine[chapter].path[0..entry.name.len], entry.name);
    }
    const key = progress.Key{
        .book_id = 9,
        .publication_fingerprint = [_]u8{0xa5} ** 16,
        .word_semantics_revision = 1,
        .spine_len = entries.len,
    };
    const index = try progress.Index.init(key);
    var source = TestSource{ .bytes = archive_bytes[0..archive_len] };
    var indexer: Indexer = undefined;
    indexer.initInPlace();
    try indexer.open(index, &publication, 1, source.reader(), source.lease());

    var order: [4]u8 = undefined;
    var order_len: usize = 0;
    for (0..1000) |_| {
        const step = indexer.update(default_byte_budget * 4);
        try std.testing.expect(indexer.status().decoded_last_update <= default_byte_budget);
        switch (step) {
            .chapter_complete => |chapter| {
                order[order_len] = chapter;
                order_len += 1;
            },
            .chapter_failed => |chapter| {
                order[order_len] = chapter;
                order_len += 1;
            },
            .complete => break,
            .failed, .retryable_failure => return error.TestUnexpectedResult,
            else => {},
        }
    }

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0 }, order[0..order_len]);
    const result = indexer.snapshot().?;
    try std.testing.expect(result.exact.contains(0));
    try std.testing.expectEqual(@as(u32, 2), result.chapter_words[0]);
    try std.testing.expect(result.failed.contains(1));
    try std.testing.expect(result.failed.contains(2));
    try std.testing.expect(result.failed.contains(3));
    try std.testing.expectEqual(Phase.complete, indexer.status().phase);
    try std.testing.expectEqual(@as(usize, 1), source.close_count);
}

test "file read failures are retryable and release the independent lease" {
    var bytes: [22]u8 = [_]u8{0} ** 22;
    var source = TestSource{ .bytes = &bytes, .fail_reads = true };
    var publication: epub.Publication = undefined;
    publication.spine_len = 1;
    publication.spine[0].path_len = 1;
    publication.spine[0].path[0] = 'x';
    const index = try progress.Index.init(.{
        .book_id = 1,
        .publication_fingerprint = [_]u8{0} ** 16,
        .word_semantics_revision = 1,
        .spine_len = 1,
    });
    var indexer: Indexer = undefined;
    indexer.initInPlace();
    try indexer.open(index, &publication, 0, source.reader(), source.lease());

    try std.testing.expectEqual(Step.retryable_failure, indexer.update(default_byte_budget));
    try std.testing.expectEqual(Phase.retryable_failure, indexer.status().phase);
    try std.testing.expectEqual(@as(usize, 1), source.close_count);
}

fn makeStoredArchive(buffer: []u8, entries: []const TestEntry, offsets: *TestArchiveOffsets) usize {
    @memset(buffer, 0);
    var cursor: usize = 0;
    for (entries, 0..) |entry, index| {
        const crc = std.hash.crc.Crc32.hash(entry.contents);
        offsets.local[index] = cursor;
        writeTestU32(buffer, cursor, 0x0403_4b50);
        writeTestU16(buffer, cursor + 4, 20);
        writeTestU32(buffer, cursor + 14, crc);
        writeTestU32(buffer, cursor + 18, entry.contents.len);
        writeTestU32(buffer, cursor + 22, entry.contents.len);
        writeTestU16(buffer, cursor + 26, entry.name.len);
        @memcpy(buffer[cursor + 30 .. cursor + 30 + entry.name.len], entry.name);
        offsets.data[index] = cursor + 30 + entry.name.len;
        @memcpy(buffer[offsets.data[index] .. offsets.data[index] + entry.contents.len], entry.contents);
        cursor = offsets.data[index] + entry.contents.len;
    }

    const central_directory_offset = cursor;
    for (entries, 0..) |entry, index| {
        const crc = std.hash.crc.Crc32.hash(entry.contents);
        offsets.central[index] = cursor;
        writeTestU32(buffer, cursor, 0x0201_4b50);
        writeTestU16(buffer, cursor + 4, 20);
        writeTestU16(buffer, cursor + 6, 20);
        writeTestU32(buffer, cursor + 16, crc);
        writeTestU32(buffer, cursor + 20, entry.contents.len);
        writeTestU32(buffer, cursor + 24, entry.contents.len);
        writeTestU16(buffer, cursor + 28, entry.name.len);
        writeTestU32(buffer, cursor + 42, offsets.local[index]);
        @memcpy(buffer[cursor + 46 .. cursor + 46 + entry.name.len], entry.name);
        cursor += 46 + entry.name.len;
    }

    const central_directory_size = cursor - central_directory_offset;
    writeTestU32(buffer, cursor, 0x0605_4b50);
    writeTestU16(buffer, cursor + 8, entries.len);
    writeTestU16(buffer, cursor + 10, entries.len);
    writeTestU32(buffer, cursor + 12, central_directory_size);
    writeTestU32(buffer, cursor + 16, central_directory_offset);
    return cursor + 22;
}

fn writeTestU16(bytes: []u8, offset: usize, value: anytype) void {
    const narrowed: u16 = @intCast(value);
    bytes[offset] = @truncate(narrowed);
    bytes[offset + 1] = @truncate(narrowed >> 8);
}

fn writeTestU32(bytes: []u8, offset: usize, value: anytype) void {
    const narrowed: u32 = @intCast(value);
    bytes[offset] = @truncate(narrowed);
    bytes[offset + 1] = @truncate(narrowed >> 8);
    bytes[offset + 2] = @truncate(narrowed >> 16);
    bytes[offset + 3] = @truncate(narrowed >> 24);
}
