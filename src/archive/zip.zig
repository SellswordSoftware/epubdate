const std = @import("std");
const deflate = @import("deflate.zig");
const limits = @import("limits").reader;

pub const Error = error{
    ReadFailed,
    UnexpectedEof,
    FileTooSmall,
    EndOfCentralDirectoryNotFound,
    InvalidEndOfCentralDirectory,
    UnsupportedMultiDisk,
    UnsupportedZip64,
    InvalidCentralDirectory,
    UnsupportedFilenameLength,
    TooManyEntries,
    UnsafePath,
    OverlappingEntries,
    EntryNotFound,
    EncryptedEntry,
    UnsupportedDataDescriptor,
    UnsupportedCompression,
    InvalidLocalHeader,
    EmptyReadBuffer,
    EntryNotFullyRead,
    ChecksumMismatch,
    EntryTooLarge,
    InflateFailed,
};

pub const Reader = struct {
    context: *anyopaque,
    size: u32,
    read_at: *const fn (context: *anyopaque, offset: u32, destination: []u8) Error!void,

    pub fn readAt(self: Reader, offset: u32, destination: []u8) Error!void {
        const end = std.math.add(u32, offset, @intCast(destination.len)) catch return error.UnexpectedEof;
        if (end > self.size) return error.UnexpectedEof;
        return self.read_at(self.context, offset, destination);
    }
};

pub const Archive = struct {
    reader: Reader,
    central_directory_offset: u32,
    central_directory_size: u32,
    entry_count: u16,

    pub fn find(self: Archive, name: []const u8, filename_buffer: []u8) Error!Entry {
        var finder = EntryFinder.init(self, name);
        while (finder.entry_index < self.entry_count) {
            if (try finder.step(filename_buffer)) |entry| return entry;
        }
        return error.EntryNotFound;
    }

    pub fn openStored(self: Archive, entry: Entry) Error!StoredEntry {
        if (entry.flags & 0x0001 != 0) return error.EncryptedEntry;
        if (entry.flags & 0x0008 != 0) return error.UnsupportedDataDescriptor;
        if (entry.compression != .stored) return error.UnsupportedCompression;
        if (entry.compressed_size != entry.uncompressed_size) return error.InvalidLocalHeader;

        const data_offset = try self.entryDataOffset(entry);
        const data_end = std.math.add(u32, data_offset, entry.compressed_size) catch return error.InvalidLocalHeader;
        if (data_end > self.reader.size) return error.InvalidLocalHeader;

        return .{
            .reader = self.reader,
            .next_offset = data_offset,
            .end_offset = data_end,
            .expected_crc32 = entry.crc32,
        };
    }

    /// Opens an entry through the bounded streaming interface.  Stored members
    /// are fully supported now; DEFLATE members will use the supplied storage
    /// once the resumable inflater lands.  Keeping the storage in this API
    /// prevents a future implementation from quietly allocating per entry.
    pub fn begin(self: Archive, entry: Entry, storage: *StreamStorage) Error!EntryStream {
        return switch (entry.compression) {
            .stored => .{ .storage = storage, .kind = .{ .stored = try self.openStored(entry) } },
            .deflated => .{ .storage = storage, .kind = .{ .deflated = try self.openDeflated(entry, storage) } },
            else => error.UnsupportedCompression,
        };
    }

    fn openDeflated(self: Archive, entry: Entry, storage: *StreamStorage) Error!DeflatedEntry {
        if (entry.flags & 0x0001 != 0) return error.EncryptedEntry;
        if (entry.flags & 0x0008 != 0) return error.UnsupportedDataDescriptor;
        if (storage.compressed_input.len == 0 or storage.window.len < 32 * 1024) return error.EntryTooLarge;
        const data_offset = try self.entryDataOffset(entry);
        const compressed_end_offset = std.math.add(u32, data_offset, entry.compressed_size) catch return error.InvalidLocalHeader;
        storage.reset();
        return .{
            .reader = self.reader,
            .next_compressed_offset = data_offset,
            .compressed_end_offset = compressed_end_offset,
            .expected_uncompressed_size = entry.uncompressed_size,
            .expected_crc32 = entry.crc32,
        };
    }

    fn entryDataOffset(self: Archive, entry: Entry) Error!u32 {
        const local_header_end = std.math.add(u32, entry.local_header_offset, 30) catch return error.InvalidLocalHeader;
        // ZIP metadata belongs after all local members. Do this range check
        // before reading the local header so central-directory bytes can never
        // be interpreted as a member header or payload.
        if (entry.local_header_offset >= self.central_directory_offset or local_header_end > self.central_directory_offset) return error.InvalidLocalHeader;

        var header: [30]u8 = undefined;
        try self.reader.readAt(entry.local_header_offset, &header);
        if (readU32(header[0..4]) != local_file_header_signature) return error.InvalidLocalHeader;
        if (readU16(header[6..8]) != entry.flags or @as(Compression, @enumFromInt(readU16(header[8..10]))) != entry.compression) return error.InvalidLocalHeader;
        if (readU32(header[14..18]) != entry.crc32 or readU32(header[18..22]) != entry.compressed_size or readU32(header[22..26]) != entry.uncompressed_size) return error.InvalidLocalHeader;

        const filename_length = readU16(header[26..28]);
        const extra_length = readU16(header[28..30]);
        const data_offset = std.math.add(u32, entry.local_header_offset, 30 + filename_length + extra_length) catch return error.InvalidLocalHeader;
        const data_end = std.math.add(u32, data_offset, entry.compressed_size) catch return error.InvalidLocalHeader;
        if (data_end > self.central_directory_offset or data_end > self.reader.size) return error.InvalidLocalHeader;
        return data_offset;
    }

    pub fn open(reader: Reader, scan_buffer: []u8) Error!Archive {
        var scanner = try ArchiveScanner.init(reader);
        while (try scanner.step(scan_buffer)) |archive| return archive;
        return error.EndOfCentralDirectoryNotFound;
    }
};

/// Resumable EOCD scan. Each `step` reads and searches at most one caller-
/// supplied chunk, allowing UI callers to budget archive opening per frame.
pub const ArchiveScanner = struct {
    pub const ReadBoundary = struct { nonzero: u32, zero: u32 };

    reader: Reader,
    earliest_offset: u32,
    scan_end: u32,
    finished: bool = false,
    tail_checked: bool = false,
    tail_signature: [4]u8 = [_]u8{0} ** 4,
    read_boundary: ?ReadBoundary = null,

    pub fn init(reader: Reader) Error!ArchiveScanner {
        if (reader.size < 22) return error.FileTooSmall;
        return .{
            .reader = reader,
            .earliest_offset = reader.size - @min(reader.size, 22 + 65_535),
            .scan_end = reader.size,
        };
    }

    /// Returns `null` while more chunks must be scanned. Once exhausted, it
    /// returns `EndOfCentralDirectoryNotFound` rather than spinning forever.
    pub fn step(self: *ArchiveScanner, scan_buffer: []u8) Error!?Archive {
        if (scan_buffer.len < 4) return error.FileTooSmall;
        if (self.finished) return error.EndOfCentralDirectoryNotFound;

        // Most ZIPs have no comment, so their EOCD is the final 22 bytes.
        // Probe that exact record before using larger backward scan reads.
        // Besides being cheaper, this avoids device filesystem edge cases on
        // large, unaligned reads near the end of a file.
        if (!self.tail_checked) {
            self.tail_checked = true;
            const candidate_offset = self.reader.size - 22;
            var header: [22]u8 = undefined;
            try self.reader.readAt(candidate_offset, &header);
            self.tail_signature = header[0..4].*;
            if (readU32(header[0..4]) == end_of_central_directory_signature and readU16(header[20..22]) == 0) {
                self.finished = true;
                return try parseEndOfCentralDirectory(self.reader, header, candidate_offset);
            }
        }
        if (self.read_boundary != null) return self.stepReadBoundaryDiagnostic(scan_buffer);

        const chunk_start = @max(self.earliest_offset, self.scan_end - @min(self.scan_end - self.earliest_offset, @as(u32, @intCast(scan_buffer.len))));
        const chunk_len: usize = self.scan_end - chunk_start;
        try self.reader.readAt(chunk_start, scan_buffer[0..chunk_len]);

        var index = chunk_len - 4;
        while (true) {
            if (readU32(scan_buffer[index..][0..4]) == end_of_central_directory_signature) {
                const candidate_offset = chunk_start + @as(u32, @intCast(index));
                if (candidate_offset <= self.reader.size - 22) {
                    var header: [22]u8 = undefined;
                    try self.reader.readAt(candidate_offset, &header);
                    if (readU16(header[20..22]) == self.reader.size - candidate_offset - 22) {
                        self.finished = true;
                        return try parseEndOfCentralDirectory(self.reader, header, candidate_offset);
                    }
                }
            }
            if (index == 0) break;
            index -= 1;
        }
        if (chunk_start == self.earliest_offset) {
            if (std.mem.allEqual(u8, &self.tail_signature, 0) and self.reader.size > @as(u32, @intCast(scan_buffer.len * 2))) {
                return self.stepReadBoundaryDiagnostic(scan_buffer);
            }
            self.finished = true;
            return error.EndOfCentralDirectoryNotFound;
        }
        // Retain three bytes of overlap so an EOCD signature straddling two
        // chunks is still discovered on the next step.
        self.scan_end = chunk_start + 3;
        return null;
    }

    /// Narrows a device read boundary one bounded probe per opening frame.
    /// This is diagnostic only: an all-zero block is not proof of EOF, so the
    /// caller reports the resulting bracket rather than treating it as data.
    fn stepReadBoundaryDiagnostic(self: *ArchiveScanner, buffer: []u8) Error!?Archive {
        const probe_len: u32 = @intCast(buffer.len);
        if (self.read_boundary == null) {
            self.read_boundary = .{ .nonzero = 0, .zero = self.reader.size - probe_len };
            return null;
        }
        const boundary = &self.read_boundary.?;
        if (boundary.zero - boundary.nonzero <= probe_len) {
            self.finished = true;
            return error.EndOfCentralDirectoryNotFound;
        }
        const probe_offset = boundary.nonzero + (boundary.zero - boundary.nonzero) / 2;
        try self.reader.readAt(probe_offset, buffer);
        if (std.mem.allEqual(u8, buffer, 0)) {
            boundary.zero = probe_offset;
        } else {
            boundary.nonzero = probe_offset;
        }
        return null;
    }
};

/// Resumable central-directory lookup. Each step reads one directory record
/// and its filename, so callers need not scan a whole large spine in a frame.
pub const EntryFinder = struct {
    archive: Archive,
    name: []const u8,
    cursor: u32,
    entry_index: u16 = 0,

    pub fn init(archive: Archive, name: []const u8) EntryFinder {
        return .{ .archive = archive, .name = name, .cursor = archive.central_directory_offset };
    }

    pub fn step(self: *EntryFinder, filename_buffer: []u8) Error!?Entry {
        if (self.entry_index == self.archive.entry_count) return null;
        const central_directory_end = self.archive.central_directory_offset + self.archive.central_directory_size;
        if (self.cursor > central_directory_end or 46 > central_directory_end - self.cursor) return error.InvalidCentralDirectory;

        var header: [46]u8 = undefined;
        try self.archive.reader.readAt(self.cursor, &header);
        if (readU32(header[0..4]) != central_directory_signature) return error.InvalidCentralDirectory;
        const filename_length = readU16(header[28..30]);
        const extra_length = readU16(header[30..32]);
        const comment_length = readU16(header[32..34]);
        const record_size: u32 = 46 + filename_length + extra_length + comment_length;
        if (record_size > central_directory_end - self.cursor) return error.InvalidCentralDirectory;
        if (filename_length > filename_buffer.len) return error.UnsupportedFilenameLength;
        try self.archive.reader.readAt(self.cursor + 46, filename_buffer[0..filename_length]);
        self.cursor += record_size;
        self.entry_index += 1;
        if (!std.mem.eql(u8, self.name, filename_buffer[0..filename_length])) return null;
        return .{
            .flags = readU16(header[8..10]),
            .compression = @enumFromInt(readU16(header[10..12])),
            .crc32 = readU32(header[16..20]),
            .compressed_size = readU32(header[20..24]),
            .uncompressed_size = readU32(header[24..28]),
            .local_header_offset = readU32(header[42..46]),
        };
    }
};

/// Caller-owned local-member interval retained while validating a directory.
/// Keeping this state outside Archive avoids hidden heap allocation and lets
/// the application apply its explicit entry-count policy.
pub const MemberRange = struct { start: u32, end: u32 };

/// Compact member metadata retained after validation. A cryptographic name
/// digest avoids reserving 256 bytes per filename for image-heavy EPUBs.
pub const IndexedEntry = struct {
    name_hash: [16]u8,
    entry: Entry,
};

pub fn indexedEntry(name: []const u8, entry: Entry) IndexedEntry {
    return .{ .name_hash = nameHash(name), .entry = entry };
}

/// A caller-owned, bounded directory index. Names are represented by a
/// 128-bit digest, keeping lookup and progress fingerprints stable without
/// retaining full member paths.
pub const DirectoryIndex = struct {
    archive: Archive,
    entries: []const IndexedEntry,

    pub fn find(self: *const DirectoryIndex, name: []const u8) Error!Entry {
        const wanted = nameHash(name);
        for (self.entries) |indexed| {
            if (std.mem.eql(u8, &wanted, &indexed.name_hash)) return indexed.entry;
        }
        return error.EntryNotFound;
    }
};

fn nameHash(name: []const u8) [16]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    return digest[0..16].*;
}

/// Incrementally validates every central-directory record before an EPUB
/// caller resolves entries. One step reads at most one filename/header pair.
pub const DirectoryValidator = struct {
    archive: Archive,
    ranges: []MemberRange,
    indexed_entries: ?[]IndexedEntry = null,
    cursor: u32,
    entry_index: u16 = 0,

    pub fn init(archive: Archive, ranges: []MemberRange) Error!DirectoryValidator {
        if (archive.entry_count > ranges.len) return error.TooManyEntries;
        return .{ .archive = archive, .ranges = ranges, .cursor = archive.central_directory_offset };
    }

    pub fn initWithIndex(archive: Archive, ranges: []MemberRange, indexed_entries: []IndexedEntry) Error!DirectoryValidator {
        if (archive.entry_count > ranges.len or archive.entry_count > indexed_entries.len) return error.TooManyEntries;
        return .{ .archive = archive, .ranges = ranges, .indexed_entries = indexed_entries, .cursor = archive.central_directory_offset };
    }

    /// Returns true only after every declared record has been checked and the
    /// cursor exactly reaches the declared central-directory end.
    pub fn step(self: *DirectoryValidator, filename_buffer: []u8) Error!bool {
        const directory_end = self.archive.central_directory_offset + self.archive.central_directory_size;
        if (self.entry_index == self.archive.entry_count) {
            if (self.cursor != directory_end) return error.InvalidCentralDirectory;
            return true;
        }
        if (self.cursor > directory_end or 46 > directory_end - self.cursor) return error.InvalidCentralDirectory;

        var header: [46]u8 = undefined;
        try self.archive.reader.readAt(self.cursor, &header);
        if (readU32(header[0..4]) != central_directory_signature) return error.InvalidCentralDirectory;
        const filename_length = readU16(header[28..30]);
        const extra_length = readU16(header[30..32]);
        const comment_length = readU16(header[32..34]);
        const record_size: u32 = 46 + filename_length + extra_length + comment_length;
        if (record_size > directory_end - self.cursor) return error.InvalidCentralDirectory;
        if (filename_length == 0 or filename_length > filename_buffer.len) return error.UnsupportedFilenameLength;
        try self.archive.reader.readAt(self.cursor + 46, filename_buffer[0..filename_length]);
        try validateArchivePath(filename_buffer[0..filename_length]);

        const entry = Entry{
            .flags = readU16(header[8..10]),
            .compression = @enumFromInt(readU16(header[10..12])),
            .crc32 = readU32(header[16..20]),
            .compressed_size = readU32(header[20..24]),
            .uncompressed_size = readU32(header[24..28]),
            .local_header_offset = readU32(header[42..46]),
        };
        const start = try self.archive.entryDataOffset(entry);
        const end = std.math.add(u32, start, entry.compressed_size) catch return error.InvalidLocalHeader;
        for (self.ranges[0..self.entry_index]) |range| {
            if (start < range.end and range.start < end) return error.OverlappingEntries;
        }
        self.ranges[self.entry_index] = .{ .start = start, .end = end };
        if (self.indexed_entries) |indexed_entries| {
            indexed_entries[self.entry_index] = indexedEntry(filename_buffer[0..filename_length], entry);
        }
        self.cursor += record_size;
        self.entry_index += 1;
        if (self.entry_index == self.archive.entry_count and self.cursor != directory_end) return error.InvalidCentralDirectory;
        return self.entry_index == self.archive.entry_count;
    }
};

fn validateArchivePath(path: []const u8) Error!void {
    if (path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return error.UnsafePath;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        // A final empty segment is a conventional directory entry; empty
        // interior segments, dot segments, and traversal are rejected.
        if (segment.len == 0) {
            if (segments.rest().len == 0) return;
            return error.UnsafePath;
        }
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.UnsafePath;
    }
}

const end_of_central_directory_signature = 0x0605_4b50;
const central_directory_signature = 0x0201_4b50;
const local_file_header_signature = 0x0403_4b50;

pub const Compression = enum(u16) {
    stored = 0,
    deflated = 8,
    _,
};

pub const Entry = struct {
    flags: u16,
    compression: Compression,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    local_header_offset: u32,
};

/// Caller-owned reusable state for an archive entry.  The slices are kept
/// separate from the stream so the application can place all substantial
/// storage on the heap instead of the Playdate stack.  The stored path does
/// not yet consume them; the DEFLATE implementation will use all three.
pub const StreamStorage = struct {
    compressed_input: []u8,
    window: []u8,
    workspace: *deflate.Workspace,
    inflater: deflate.InflateState,
    input_start: usize = 0,
    input_end: usize = 0,

    pub fn init(compressed_input: []u8, window: []u8, workspace: *deflate.Workspace) StreamStorage {
        const storage: StreamStorage = .{
            .compressed_input = compressed_input,
            .window = window,
            .workspace = workspace,
            .inflater = deflate.InflateState.init(window, workspace),
        };
        return storage;
    }

    fn reset(self: *StreamStorage) void {
        self.inflater = deflate.InflateState.init(self.window, self.workspace);
        self.input_start = 0;
        self.input_end = 0;
    }
};

pub const ReadResult = union(enum) {
    bytes: usize,
    end,
    needs_input,
};

/// One active ZIP member.  `read` either produces bytes, reaches `end`, or
/// reports that a future compressed implementation needs another file chunk;
/// it never returns a zero-byte progress result.
pub const EntryStream = struct {
    storage: *StreamStorage,
    kind: union(enum) {
        stored: StoredEntry,
        deflated: DeflatedEntry,
    },

    pub fn read(self: *EntryStream, output: []u8) Error!ReadResult {
        if (output.len == 0) return error.EmptyReadBuffer;
        return switch (self.kind) {
            .stored => |*stored| if (try stored.read(output)) |len| .{ .bytes = len } else .end,
            .deflated => |*deflated| try deflated.read(self.storage, output),
        };
    }

    pub fn finish(self: *EntryStream) Error!void {
        _ = self.storage;
        switch (self.kind) {
            .stored => |*stored| try stored.finish(),
            .deflated => |*deflated| try deflated.finish(),
        }
    }
};

const DeflatedEntry = struct {
    reader: Reader,
    next_compressed_offset: u32,
    compressed_end_offset: u32,
    expected_uncompressed_size: u32,
    expected_crc32: u32,
    crc32: u32 = 0xffff_ffff,
    output_count: u32 = 0,
    ended: bool = false,

    fn read(self: *DeflatedEntry, storage: *StreamStorage, output: []u8) Error!ReadResult {
        var output_written: usize = 0;
        while (true) {
            if (self.ended) return if (output_written == 0) .end else .{ .bytes = output_written };
            if (storage.input_start == storage.input_end and self.next_compressed_offset < self.compressed_end_offset) {
                const remaining = self.compressed_end_offset - self.next_compressed_offset;
                const amount: usize = @min(storage.compressed_input.len, remaining);
                try self.reader.readAt(self.next_compressed_offset, storage.compressed_input[0..amount]);
                self.next_compressed_offset += @intCast(amount);
                storage.input_start = 0;
                storage.input_end = amount;
            }
            const step = storage.inflater.step(storage.compressed_input[storage.input_start..storage.input_end], output[output_written..]) catch return error.InflateFailed;
            storage.input_start += step.input_used;
            if (step.output_written != 0) {
                const new_count = std.math.add(u32, self.output_count, @intCast(step.output_written)) catch return error.InflateFailed;
                if (new_count > self.expected_uncompressed_size) return error.InflateFailed;
                self.crc32 = crc32Update(self.crc32, output[output_written .. output_written + step.output_written]);
                self.output_count = new_count;
                output_written += step.output_written;
            }
            switch (step.status) {
                .needs_output => return .{ .bytes = output_written },
                .needs_input => {
                    if (storage.input_start != storage.input_end) return error.InflateFailed;
                    if (self.next_compressed_offset == self.compressed_end_offset) return error.InflateFailed;
                },
                .end => {
                    if (storage.input_start != storage.input_end or self.next_compressed_offset != self.compressed_end_offset) return error.InflateFailed;
                    if (self.output_count != self.expected_uncompressed_size) return error.InflateFailed;
                    self.ended = true;
                    return if (output_written == 0) .end else .{ .bytes = output_written };
                },
            }
        }
    }

    fn finish(self: *const DeflatedEntry) Error!void {
        if (!self.ended) return error.EntryNotFullyRead;
        if (~self.crc32 != self.expected_crc32) return error.ChecksumMismatch;
    }
};

pub const StoredEntry = struct {
    reader: Reader,
    next_offset: u32,
    end_offset: u32,
    expected_crc32: u32,
    crc32: u32 = 0xffff_ffff,

    /// Returns null at end-of-entry. `finish` must be called after null to
    /// validate the entry checksum.
    pub fn read(self: *StoredEntry, destination: []u8) Error!?usize {
        if (destination.len == 0) return error.EmptyReadBuffer;
        if (self.next_offset == self.end_offset) return null;

        const remaining = self.end_offset - self.next_offset;
        const read_len: usize = @min(destination.len, remaining);
        try self.reader.readAt(self.next_offset, destination[0..read_len]);
        self.crc32 = crc32Update(self.crc32, destination[0..read_len]);
        self.next_offset += @intCast(read_len);
        return read_len;
    }

    pub fn finish(self: StoredEntry) Error!void {
        if (self.next_offset != self.end_offset) return error.EntryNotFullyRead;
        if (~self.crc32 != self.expected_crc32) return error.ChecksumMismatch;
    }
};

fn parseEndOfCentralDirectory(reader: Reader, header: [22]u8, end_record_offset: u32) Error!Archive {
    if (readU32(header[0..4]) != end_of_central_directory_signature) return error.InvalidEndOfCentralDirectory;
    if (readU16(header[4..6]) != 0 or readU16(header[6..8]) != 0) return error.UnsupportedMultiDisk;

    const entry_count = readU16(header[10..12]);
    const central_directory_size = readU32(header[12..16]);
    const central_directory_offset = readU32(header[16..20]);
    if (entry_count == 0xffff or central_directory_size == 0xffff_ffff or central_directory_offset == 0xffff_ffff) return error.UnsupportedZip64;
    if (central_directory_offset > end_record_offset or central_directory_size > end_record_offset - central_directory_offset) return error.InvalidEndOfCentralDirectory;

    return .{
        .reader = reader,
        .central_directory_offset = central_directory_offset,
        .central_directory_size = central_directory_size,
        .entry_count = entry_count,
    };
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn crc32Update(crc: u32, bytes: []const u8) u32 {
    var result = crc;
    for (bytes) |byte| {
        result = (result >> 8) ^ crc32_table[(result ^ byte) & 0xff];
    }
    return result;
}

/// Standard reflected CRC-32 table. It lives in read-only program storage, so
/// streamed entry validation avoids eight branchy iterations per output byte
/// without consuming Playdate heap or stack.
const crc32_table = blk: {
    @setEvalBranchQuota(3_000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, index| {
        var value: u32 = @intCast(index);
        for (0..8) |_| value = if (value & 1 != 0) (value >> 1) ^ 0xedb8_8320 else value >> 1;
        entry.* = value;
    }
    break :blk table;
};

test "computes the standard CRC-32 value" {
    try std.testing.expectEqual(@as(u32, 0xcbf4_3926), ~crc32Update(0xffff_ffff, "123456789"));
}

test "opens a single stored entry archive" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    try std.testing.expectEqual(@as(u16, 1), archive.entry_count);
}

test "directory validator accepts a complete ordinary archive" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var ranges: [1]MemberRange = undefined;
    const archive = try Archive.open(source.reader(), &scan_buffer);
    var validator = try DirectoryValidator.init(archive, &ranges);
    try std.testing.expect(try validator.step(&filename_buffer));
}

test "validated directory index resolves entries through compact hashes" {
    var archive_bytes: [194]u8 = undefined;
    const archive_len = makeTwoStoredEntriesArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var ranges: [2]MemberRange = undefined;
    var indexed_entries: [2]IndexedEntry = undefined;
    const archive = try Archive.open(source.reader(), &scan_buffer);
    var validator = try DirectoryValidator.initWithIndex(archive, &ranges, &indexed_entries);
    while (!try validator.step(&filename_buffer)) {}
    const index = DirectoryIndex{ .archive = archive, .entries = &indexed_entries };
    const entry = try index.find("second");
    var stored = try archive.openStored(entry);
    var output: [1]u8 = undefined;
    _ = try stored.read(&output);
    try stored.finish();
    try std.testing.expectEqualStrings("b", &output);
}

test "directory validator rejects traversal member names before lookup" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    @memcpy(archive_bytes[58 + 46 .. 58 + 46 + "../evil!".len], "../evil!");
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var ranges: [1]MemberRange = undefined;
    const archive = try Archive.open(source.reader(), &scan_buffer);
    var validator = try DirectoryValidator.init(archive, &ranges);
    try std.testing.expectError(error.UnsafePath, validator.step(&filename_buffer));
}

test "scans the end record incrementally" {
    var archive_bytes: [138]u8 = undefined;
    const end_record_len = makeStoredMimetypeArchive(&archive_bytes);
    writeU16(&archive_bytes, end_record_len - 2, 4);
    @memcpy(archive_bytes[end_record_len .. end_record_len + 4], "note");
    const archive_len = end_record_len + 4;
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [4]u8 = undefined;
    var scanner = try ArchiveScanner.init(source.reader());
    var steps: usize = 0;
    var archive: ?Archive = null;
    while (archive == null) {
        archive = try scanner.step(&scan_buffer);
        steps += 1;
    }
    try std.testing.expect(steps > 1);
    try std.testing.expectEqual(@as(u16, 1), archive.?.entry_count);
}

test "zero-tail scan failure narrows the readable offset boundary" {
    const ZeroBoundaryReader = struct {
        const size = 4 * 1024 * 1024;
        const boundary = 2 * 1024 * 1024;

        fn readAt(_: *anyopaque, offset: u32, destination: []u8) Error!void {
            @memset(destination, if (offset < boundary) 0x7f else 0);
        }
    };
    var context: u8 = 0;
    const reader = Reader{
        .context = &context,
        .size = ZeroBoundaryReader.size,
        .read_at = ZeroBoundaryReader.readAt,
    };
    var scan_buffer: [1024]u8 = undefined;
    var scanner = try ArchiveScanner.init(reader);
    while (true) {
        const result = scanner.step(&scan_buffer) catch |err| {
            try std.testing.expectEqual(error.EndOfCentralDirectoryNotFound, err);
            break;
        };
        try std.testing.expect(result == null);
    }
    const boundary = scanner.read_boundary.?;
    try std.testing.expect(boundary.nonzero < ZeroBoundaryReader.boundary);
    try std.testing.expect(boundary.zero >= ZeroBoundaryReader.boundary);
    try std.testing.expect(boundary.zero - boundary.nonzero <= scan_buffer.len);
}

test "finds the stored mimetype entry by archive name" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("mimetype", &filename_buffer);
    try std.testing.expectEqual(Compression.stored, entry.compression);
    try std.testing.expectEqual(@as(u32, 20), entry.uncompressed_size);
}

test "find scans past nonmatching central-directory entries" {
    var archive_bytes: [194]u8 = undefined;
    const archive_len = makeTwoStoredEntriesArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("second", &filename_buffer);
    try std.testing.expectEqual(@as(u32, 1), entry.uncompressed_size);
    var stored = try archive.openStored(entry);
    var output: [1]u8 = undefined;
    _ = try stored.read(&output);
    try stored.finish();
    try std.testing.expectEqualStrings("b", &output);
}

test "finds a central-directory entry one record at a time" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    var finder = EntryFinder.init(archive, "mimetype");
    const entry = (try finder.step(&filename_buffer)).?;
    try std.testing.expectEqual(@as(u16, 1), finder.entry_index);
    try std.testing.expectEqual(@as(u32, 20), entry.uncompressed_size);
}

test "streams and validates a stored entry" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var output: [20]u8 = undefined;
    var read_buffer: [5]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("mimetype", &filename_buffer);
    var stored = try archive.openStored(entry);
    var output_len: usize = 0;
    while (try stored.read(&read_buffer)) |read_len| {
        @memcpy(output[output_len .. output_len + read_len], read_buffer[0..read_len]);
        output_len += read_len;
    }
    try stored.finish();
    try std.testing.expectEqualStrings("application/epub+zip", output[0..output_len]);
}

test "EntryStream reads stored entries in bounded caller buffers" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var compressed_input: [4]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = StreamStorage.init(&compressed_input, &window, &workspace);
    var output: [20]u8 = undefined;
    var read_buffer: [3]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("mimetype", &filename_buffer);
    var stream = try archive.begin(entry, &storage);
    var output_len: usize = 0;
    while (true) {
        switch (try stream.read(&read_buffer)) {
            .bytes => |len| {
                try std.testing.expect(len != 0);
                @memcpy(output[output_len .. output_len + len], read_buffer[0..len]);
                output_len += len;
            },
            .end => break,
            .needs_input => return error.TestUnexpectedResult,
        }
    }
    try stream.finish();
    try std.testing.expectEqualStrings("application/epub+zip", output[0..output_len]);
}

test "EntryStream reports end after an exact-sized output read" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var compressed_input: [4]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = StreamStorage.init(&compressed_input, &window, &workspace);
    var output: [20]u8 = undefined;
    var terminal_buffer: [1]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("mimetype", &filename_buffer);
    var stream = try archive.begin(entry, &storage);
    try std.testing.expectEqual(ReadResult{ .bytes = output.len }, try stream.read(&output));
    try std.testing.expectEqual(ReadResult.end, try stream.read(&terminal_buffer));
    try stream.finish();
    try std.testing.expectEqualStrings("application/epub+zip", &output);
}

test "EntryStream rejects an empty output buffer" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var compressed_input: [4]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = StreamStorage.init(&compressed_input, &window, &workspace);

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("mimetype", &filename_buffer);
    var stream = try archive.begin(entry, &storage);
    try std.testing.expectError(error.EmptyReadBuffer, stream.read(&.{}));
}

test "EntryStream inflates a DEFLATE member from small file chunks" {
    var archive_bytes: [122]u8 = undefined;
    const archive_len = makeDeflatedStoredBlockArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var compressed_input: [2]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = StreamStorage.init(&compressed_input, &window, &workspace);
    var output: [3]u8 = undefined;
    var output_chunk: [1]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("chapter", &filename_buffer);
    var stream = try archive.begin(entry, &storage);
    var output_len: usize = 0;
    while (true) {
        switch (try stream.read(&output_chunk)) {
            .bytes => |len| {
                @memcpy(output[output_len .. output_len + len], output_chunk[0..len]);
                output_len += len;
            },
            .end => break,
            .needs_input => return error.TestUnexpectedResult,
        }
    }
    try stream.finish();
    try std.testing.expectEqualStrings("cat", output[0..output_len]);
}

test "EntryStream inflates fixed-Huffman members from small file chunks" {
    var archive_bytes: [119]u8 = undefined;
    const archive_len = makeFixedDeflatedArchive(&archive_bytes);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;
    var compressed_input: [2]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = StreamStorage.init(&compressed_input, &window, &workspace);
    var output: [18]u8 = undefined;
    var output_chunk: [2]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("chapter", &filename_buffer);
    var stream = try archive.begin(entry, &storage);
    var output_len: usize = 0;
    while (true) {
        switch (try stream.read(&output_chunk)) {
            .bytes => |len| {
                @memcpy(output[output_len .. output_len + len], output_chunk[0..len]);
                output_len += len;
            },
            .end => break,
            .needs_input => return error.TestUnexpectedResult,
        }
    }
    try stream.finish();
    try std.testing.expectEqualStrings("abcabcabcabcabcabc", output[0..output_len]);
}

test "rejects a central directory that overlaps its end record" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    writeU32(&archive_bytes, 112 + 12, 55);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;

    try std.testing.expectError(error.InvalidEndOfCentralDirectory, Archive.open(source.reader(), &scan_buffer));
}

test "rejects member data that overlaps the central directory" {
    var archive_bytes: [134]u8 = undefined;
    const archive_len = makeStoredMimetypeArchive(&archive_bytes);
    const central_directory_offset = 58;
    // Keep the central-directory size fields internally consistent while
    // extending the member one byte into the directory.
    writeU32(&archive_bytes, 18, 21);
    writeU32(&archive_bytes, 22, 21);
    writeU32(&archive_bytes, central_directory_offset + 20, 21);
    writeU32(&archive_bytes, central_directory_offset + 24, 21);
    var source = MemoryReader{ .bytes = archive_bytes[0..archive_len] };
    var scan_buffer: [64]u8 = undefined;
    var filename_buffer: [32]u8 = undefined;

    const archive = try Archive.open(source.reader(), &scan_buffer);
    const entry = try archive.find("mimetype", &filename_buffer);
    try std.testing.expectError(error.InvalidLocalHeader, archive.openStored(entry));
}

const MemoryReader = struct {
    bytes: []const u8,

    fn reader(self: *MemoryReader) Reader {
        return .{
            .context = self,
            .size = @intCast(self.bytes.len),
            .read_at = readAt,
        };
    }

    fn readAt(context: *anyopaque, offset: u32, destination: []u8) Error!void {
        const self: *MemoryReader = @ptrCast(@alignCast(context));
        const start: usize = offset;
        const end = std.math.add(usize, start, destination.len) catch return error.UnexpectedEof;
        if (end > self.bytes.len) return error.UnexpectedEof;
        @memcpy(destination, self.bytes[start..end]);
    }
};

fn makeStoredMimetypeArchive(buffer: []u8) usize {
    @memset(buffer, 0);
    const name = "mimetype";
    const contents = "application/epub+zip";
    const crc: u32 = 0x2cab_616f;
    const local_header_size = 30 + name.len + contents.len;
    const central_directory_offset = local_header_size;
    const central_directory_size = 46 + name.len;
    const end_of_central_directory_offset = central_directory_offset + central_directory_size;

    writeU32(buffer, 0, 0x0403_4b50);
    writeU16(buffer, 4, 20);
    writeU32(buffer, 14, crc);
    writeU32(buffer, 18, contents.len);
    writeU32(buffer, 22, contents.len);
    writeU16(buffer, 26, name.len);
    @memcpy(buffer[30 .. 30 + name.len], name);
    @memcpy(buffer[30 + name.len .. local_header_size], contents);

    writeU32(buffer, central_directory_offset, 0x0201_4b50);
    writeU16(buffer, central_directory_offset + 4, 20);
    writeU16(buffer, central_directory_offset + 6, 20);
    writeU32(buffer, central_directory_offset + 16, crc);
    writeU32(buffer, central_directory_offset + 20, contents.len);
    writeU32(buffer, central_directory_offset + 24, contents.len);
    writeU16(buffer, central_directory_offset + 28, name.len);
    @memcpy(buffer[central_directory_offset + 46 .. central_directory_offset + 46 + name.len], name);

    writeU32(buffer, end_of_central_directory_offset, end_of_central_directory_signature);
    writeU16(buffer, end_of_central_directory_offset + 8, 1);
    writeU16(buffer, end_of_central_directory_offset + 10, 1);
    writeU32(buffer, end_of_central_directory_offset + 12, central_directory_size);
    writeU32(buffer, end_of_central_directory_offset + 16, central_directory_offset);
    return end_of_central_directory_offset + 22;
}

fn makeTwoStoredEntriesArchive(buffer: []u8) usize {
    @memset(buffer, 0);
    const first_name = "one";
    const second_name = "second";
    const first_contents = "a";
    const second_contents = "b";
    const first_local_size = 30 + first_name.len + first_contents.len;
    const second_local_offset = first_local_size;
    const second_local_size = 30 + second_name.len + second_contents.len;
    const central_directory_offset = second_local_offset + second_local_size;
    const first_record_size = 46 + first_name.len;
    const second_record_offset = central_directory_offset + first_record_size;
    const central_directory_size = first_record_size + 46 + second_name.len;
    const end_offset = central_directory_offset + central_directory_size;

    writeU32(buffer, 0, local_file_header_signature);
    writeU16(buffer, 4, 20);
    writeU32(buffer, 14, ~crc32Update(0xffff_ffff, first_contents));
    writeU32(buffer, 18, first_contents.len);
    writeU32(buffer, 22, first_contents.len);
    writeU16(buffer, 26, first_name.len);
    @memcpy(buffer[30 .. 30 + first_name.len], first_name);
    @memcpy(buffer[30 + first_name.len .. first_local_size], first_contents);

    writeU32(buffer, second_local_offset, local_file_header_signature);
    writeU16(buffer, second_local_offset + 4, 20);
    writeU32(buffer, second_local_offset + 14, ~crc32Update(0xffff_ffff, second_contents));
    writeU32(buffer, second_local_offset + 18, second_contents.len);
    writeU32(buffer, second_local_offset + 22, second_contents.len);
    writeU16(buffer, second_local_offset + 26, second_name.len);
    @memcpy(buffer[second_local_offset + 30 .. second_local_offset + 30 + second_name.len], second_name);
    @memcpy(buffer[second_local_offset + 30 + second_name.len .. central_directory_offset], second_contents);

    writeU32(buffer, central_directory_offset, central_directory_signature);
    writeU16(buffer, central_directory_offset + 4, 20);
    writeU16(buffer, central_directory_offset + 6, 20);
    writeU32(buffer, central_directory_offset + 16, ~crc32Update(0xffff_ffff, first_contents));
    writeU32(buffer, central_directory_offset + 20, first_contents.len);
    writeU32(buffer, central_directory_offset + 24, first_contents.len);
    writeU16(buffer, central_directory_offset + 28, first_name.len);
    @memcpy(buffer[central_directory_offset + 46 .. central_directory_offset + 46 + first_name.len], first_name);

    writeU32(buffer, second_record_offset, central_directory_signature);
    writeU16(buffer, second_record_offset + 4, 20);
    writeU16(buffer, second_record_offset + 6, 20);
    writeU32(buffer, second_record_offset + 16, ~crc32Update(0xffff_ffff, second_contents));
    writeU32(buffer, second_record_offset + 20, second_contents.len);
    writeU32(buffer, second_record_offset + 24, second_contents.len);
    writeU16(buffer, second_record_offset + 28, second_name.len);
    writeU32(buffer, second_record_offset + 42, second_local_offset);
    @memcpy(buffer[second_record_offset + 46 .. second_record_offset + 46 + second_name.len], second_name);

    writeU32(buffer, end_offset, end_of_central_directory_signature);
    writeU16(buffer, end_offset + 8, 2);
    writeU16(buffer, end_offset + 10, 2);
    writeU32(buffer, end_offset + 12, central_directory_size);
    writeU32(buffer, end_offset + 16, central_directory_offset);
    return end_offset + 22;
}

fn makeDeflatedStoredBlockArchive(buffer: []u8) usize {
    @memset(buffer, 0);
    const name = "chapter";
    const compressed = [_]u8{ 0x01, 0x03, 0x00, 0xfc, 0xff, 'c', 'a', 't' };
    const crc = ~crc32Update(0xffff_ffff, "cat");
    const local_header_size = 30 + name.len + compressed.len;
    const central_directory_offset = local_header_size;
    const central_directory_size = 46 + name.len;
    const end_of_central_directory_offset = central_directory_offset + central_directory_size;

    writeU32(buffer, 0, local_file_header_signature);
    writeU16(buffer, 4, 20);
    writeU16(buffer, 8, @intFromEnum(Compression.deflated));
    writeU32(buffer, 14, crc);
    writeU32(buffer, 18, compressed.len);
    writeU32(buffer, 22, 3);
    writeU16(buffer, 26, name.len);
    @memcpy(buffer[30 .. 30 + name.len], name);
    @memcpy(buffer[30 + name.len .. local_header_size], &compressed);

    writeU32(buffer, central_directory_offset, central_directory_signature);
    writeU16(buffer, central_directory_offset + 4, 20);
    writeU16(buffer, central_directory_offset + 6, 20);
    writeU16(buffer, central_directory_offset + 10, @intFromEnum(Compression.deflated));
    writeU32(buffer, central_directory_offset + 16, crc);
    writeU32(buffer, central_directory_offset + 20, compressed.len);
    writeU32(buffer, central_directory_offset + 24, 3);
    writeU16(buffer, central_directory_offset + 28, name.len);
    @memcpy(buffer[central_directory_offset + 46 .. central_directory_offset + 46 + name.len], name);

    writeU32(buffer, end_of_central_directory_offset, end_of_central_directory_signature);
    writeU16(buffer, end_of_central_directory_offset + 8, 1);
    writeU16(buffer, end_of_central_directory_offset + 10, 1);
    writeU32(buffer, end_of_central_directory_offset + 12, central_directory_size);
    writeU32(buffer, end_of_central_directory_offset + 16, central_directory_offset);
    return end_of_central_directory_offset + 22;
}

fn makeFixedDeflatedArchive(buffer: []u8) usize {
    @memset(buffer, 0);
    const name = "chapter";
    const compressed = [_]u8{ 0x4b, 0x4c, 0x4a, 0x4e, 0x44, 0x45, 0x00 };
    const contents = "abcabcabcabcabcabc";
    const crc = ~crc32Update(0xffff_ffff, contents);
    const local_header_size = 30 + name.len + compressed.len;
    const central_directory_offset = local_header_size;
    const central_directory_size = 46 + name.len;
    const end_of_central_directory_offset = central_directory_offset + central_directory_size;

    writeU32(buffer, 0, local_file_header_signature);
    writeU16(buffer, 4, 20);
    writeU16(buffer, 8, @intFromEnum(Compression.deflated));
    writeU32(buffer, 14, crc);
    writeU32(buffer, 18, compressed.len);
    writeU32(buffer, 22, contents.len);
    writeU16(buffer, 26, name.len);
    @memcpy(buffer[30 .. 30 + name.len], name);
    @memcpy(buffer[30 + name.len .. local_header_size], &compressed);

    writeU32(buffer, central_directory_offset, central_directory_signature);
    writeU16(buffer, central_directory_offset + 4, 20);
    writeU16(buffer, central_directory_offset + 6, 20);
    writeU16(buffer, central_directory_offset + 10, @intFromEnum(Compression.deflated));
    writeU32(buffer, central_directory_offset + 16, crc);
    writeU32(buffer, central_directory_offset + 20, compressed.len);
    writeU32(buffer, central_directory_offset + 24, contents.len);
    writeU16(buffer, central_directory_offset + 28, name.len);
    @memcpy(buffer[central_directory_offset + 46 .. central_directory_offset + 46 + name.len], name);

    writeU32(buffer, end_of_central_directory_offset, end_of_central_directory_signature);
    writeU16(buffer, end_of_central_directory_offset + 8, 1);
    writeU16(buffer, end_of_central_directory_offset + 10, 1);
    writeU32(buffer, end_of_central_directory_offset + 12, central_directory_size);
    writeU32(buffer, end_of_central_directory_offset + 16, central_directory_offset);
    return end_of_central_directory_offset + 22;
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
