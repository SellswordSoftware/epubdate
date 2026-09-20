const std = @import("std");

pub const max_chapters: usize = 64;
pub const encoded_size: usize = 304;

const counts_offset: usize = 44;
const checksum_offset: usize = encoded_size - @sizeOf(u32);
const encoded_size_units: u8 = encoded_size / 16;

pub const Error = error{
    InvalidRecord,
    InvalidSpine,
    InvalidChapter,
    CountOverflow,
};

pub const Key = struct {
    book_id: u32,
    publication_fingerprint: [16]u8,
    word_semantics_revision: u16,
    spine_len: u8,
};

pub const Mask = struct {
    words: [2]u32 = .{ 0, 0 },

    pub fn contains(self: Mask, chapter: u8) bool {
        if (chapter >= max_chapters) return false;
        const word: usize = chapter / 32;
        const bit: u5 = @intCast(chapter % 32);
        return self.words[word] & (@as(u32, 1) << bit) != 0;
    }

    fn set(self: *Mask, chapter: u8, enabled: bool) void {
        std.debug.assert(chapter < max_chapters);
        const word: usize = chapter / 32;
        const bit: u5 = @intCast(chapter % 32);
        const flag = @as(u32, 1) << bit;
        if (enabled) {
            self.words[word] |= flag;
        } else {
            self.words[word] &= ~flag;
        }
    }

    fn intersects(self: Mask, other: Mask) bool {
        return self.words[0] & other.words[0] != 0 or self.words[1] & other.words[1] != 0;
    }

    fn hasBitsOutside(self: Mask, spine_len: u8) bool {
        for (spine_len..max_chapters) |chapter| {
            if (self.contains(@intCast(chapter))) return true;
        }
        return false;
    }
};

/// A retained 64-bit count represented as two 32-bit words. This keeps the
/// heap-owned application state at four-byte alignment on Playdate ARM.
pub const WideCount = struct {
    lo: u32 = 0,
    hi: u32 = 0,

    pub fn fromU32(value: u32) WideCount {
        return .{ .lo = value };
    }

    pub fn add(self: WideCount, other: WideCount) Error!WideCount {
        const lo = self.lo +% other.lo;
        const carry: u32 = @intFromBool(lo < self.lo);
        const hi_without_carry = std.math.add(u32, self.hi, other.hi) catch return error.CountOverflow;
        return .{
            .lo = lo,
            .hi = std.math.add(u32, hi_without_carry, carry) catch return error.CountOverflow,
        };
    }

    pub fn subtract(self: WideCount, other: WideCount) Error!WideCount {
        if (self.lessThan(other)) return error.CountOverflow;
        const borrow: u32 = @intFromBool(self.lo < other.lo);
        return .{
            .lo = self.lo -% other.lo,
            .hi = self.hi - other.hi - borrow,
        };
    }

    pub fn lessThan(self: WideCount, other: WideCount) bool {
        return self.hi < other.hi or (self.hi == other.hi and self.lo < other.lo);
    }
};

pub const Cursor = struct {
    chapter: u8,
    word_ordinal: u32,
};

pub const Fraction = struct {
    reached: WideCount,
    total: WideCount,
    remaining: WideCount,
};

pub const Metric = union(enum) {
    pending,
    unavailable,
    exact: Fraction,
};

pub const View = struct {
    chapter: Metric,
    book: Metric,
};

pub const Index = struct {
    key: Key,
    exact: Mask = .{},
    failed: Mask = .{},
    chapter_words: [max_chapters]u32 = [_]u32{0} ** max_chapters,

    pub fn init(key: Key) Error!Index {
        try validateKey(key);
        return .{ .key = key };
    }

    pub fn setExact(self: *Index, chapter: u8, words: u32) Error!void {
        try self.validateChapter(chapter);
        self.chapter_words[chapter] = words;
        self.exact.set(chapter, true);
        self.failed.set(chapter, false);
    }

    pub fn setFailed(self: *Index, chapter: u8) Error!void {
        try self.validateChapter(chapter);
        self.chapter_words[chapter] = 0;
        self.exact.set(chapter, false);
        self.failed.set(chapter, true);
    }

    pub fn view(self: *const Index, cursor: Cursor) Error!View {
        try self.validateChapter(cursor.chapter);
        const chapter_metric = try self.chapterMetric(cursor);

        if (self.failed.words[0] != 0 or self.failed.words[1] != 0) {
            return .{ .chapter = chapter_metric, .book = .unavailable };
        }
        for (0..self.key.spine_len) |chapter| {
            if (!self.exact.contains(@intCast(chapter))) {
                return .{ .chapter = chapter_metric, .book = .pending };
            }
        }

        var total = WideCount{};
        var reached = WideCount{};
        for (0..self.key.spine_len) |chapter| {
            const words = self.chapter_words[chapter];
            total = try total.add(WideCount.fromU32(words));
            if (chapter < cursor.chapter) {
                reached = try reached.add(WideCount.fromU32(words));
            } else if (chapter == cursor.chapter) {
                reached = try reached.add(WideCount.fromU32(reachedInChapter(words, cursor.word_ordinal)));
            }
        }
        return .{
            .chapter = chapter_metric,
            .book = .{ .exact = .{
                .reached = reached,
                .total = total,
                .remaining = try total.subtract(reached),
            } },
        };
    }

    fn chapterMetric(self: *const Index, cursor: Cursor) Error!Metric {
        if (self.failed.contains(cursor.chapter)) return .unavailable;
        if (!self.exact.contains(cursor.chapter)) return .pending;
        const total = self.chapter_words[cursor.chapter];
        const reached = reachedInChapter(total, cursor.word_ordinal);
        return .{ .exact = .{
            .reached = WideCount.fromU32(reached),
            .total = WideCount.fromU32(total),
            .remaining = WideCount.fromU32(total - reached),
        } };
    }

    fn validateChapter(self: *const Index, chapter: u8) Error!void {
        if (chapter >= self.key.spine_len) return error.InvalidChapter;
    }
};

pub fn encode(index: Index, output: *[encoded_size]u8) Error!void {
    try validateIndex(index);
    @memset(output, 0);
    @memcpy(output[0..4], "EPI\x01");
    std.mem.writeInt(u32, output[4..8], index.key.book_id, .little);
    @memcpy(output[8..24], &index.key.publication_fingerprint);
    std.mem.writeInt(u16, output[24..26], index.key.word_semantics_revision, .little);
    output[26] = index.key.spine_len;
    output[27] = encoded_size_units;
    std.mem.writeInt(u32, output[28..32], index.exact.words[0], .little);
    std.mem.writeInt(u32, output[32..36], index.exact.words[1], .little);
    std.mem.writeInt(u32, output[36..40], index.failed.words[0], .little);
    std.mem.writeInt(u32, output[40..44], index.failed.words[1], .little);
    for (index.chapter_words, 0..) |count, chapter| {
        const offset = counts_offset + chapter * @sizeOf(u32);
        writeU32(output, offset, count);
    }
    std.mem.writeInt(u32, output[checksum_offset..encoded_size], checksum(output[0..checksum_offset]), .little);
}

pub fn decode(input: *const [encoded_size]u8, expected: Key) Error!Index {
    try validateKey(expected);
    if (!std.mem.eql(u8, input[0..4], "EPI\x01")) return error.InvalidRecord;
    if (input[27] != encoded_size_units) return error.InvalidRecord;
    if (std.mem.readInt(u32, input[checksum_offset..encoded_size], .little) != checksum(input[0..checksum_offset])) return error.InvalidRecord;

    const key = Key{
        .book_id = std.mem.readInt(u32, input[4..8], .little),
        .publication_fingerprint = input[8..24].*,
        .word_semantics_revision = std.mem.readInt(u16, input[24..26], .little),
        .spine_len = input[26],
    };
    if (!std.meta.eql(key, expected)) return error.InvalidRecord;

    var index = try Index.init(key);
    index.exact.words[0] = std.mem.readInt(u32, input[28..32], .little);
    index.exact.words[1] = std.mem.readInt(u32, input[32..36], .little);
    index.failed.words[0] = std.mem.readInt(u32, input[36..40], .little);
    index.failed.words[1] = std.mem.readInt(u32, input[40..44], .little);
    for (&index.chapter_words, 0..) |*count, chapter| {
        const offset = counts_offset + chapter * @sizeOf(u32);
        count.* = readU32(input, offset);
    }
    try validateIndex(index);
    return index;
}

fn validateKey(key: Key) Error!void {
    if (key.spine_len == 0 or key.spine_len > max_chapters or key.word_semantics_revision == 0) return error.InvalidSpine;
}

fn validateIndex(index: Index) Error!void {
    try validateKey(index.key);
    if (index.exact.intersects(index.failed)) return error.InvalidRecord;
    if (index.exact.hasBitsOutside(index.key.spine_len) or index.failed.hasBitsOutside(index.key.spine_len)) return error.InvalidRecord;
    for (index.chapter_words, 0..) |count, chapter| {
        if (!index.exact.contains(@intCast(chapter)) and count != 0) return error.InvalidRecord;
    }
}

fn reachedInChapter(total: u32, word_ordinal: u32) u32 {
    if (total == 0) return 0;
    if (word_ordinal >= total - 1) return total;
    return word_ordinal + 1;
}

fn checksum(bytes: []const u8) u32 {
    return std.hash.crc.Crc32.hash(bytes);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

comptime {
    std.debug.assert(encoded_size == 304);
    std.debug.assert(@alignOf(Index) <= @alignOf(u32));
    std.debug.assert(@sizeOf(Index) <= encoded_size);
}

const test_key = Key{
    .book_id = 7,
    .publication_fingerprint = [_]u8{0x5a} ** 16,
    .word_semantics_revision = 1,
    .spine_len = 3,
};

test "index record round trips partial zero and failed chapters" {
    var index = try Index.init(test_key);
    try index.setExact(0, 10);
    try index.setExact(1, 0);
    try index.setFailed(2);

    var bytes: [encoded_size]u8 = undefined;
    try encode(index, &bytes);
    const restored = try decode(&bytes, test_key);
    try std.testing.expect(restored.exact.contains(0));
    try std.testing.expect(restored.exact.contains(1));
    try std.testing.expectEqual(@as(u32, 0), restored.chapter_words[1]);
    try std.testing.expect(restored.failed.contains(2));
}

test "record rejects key mask checksum and count inconsistencies" {
    var index = try Index.init(test_key);
    try index.setExact(0, 10);
    var bytes: [encoded_size]u8 = undefined;
    try encode(index, &bytes);

    var wrong = test_key;
    wrong.publication_fingerprint[0] ^= 1;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes, wrong));
    wrong = test_key;
    wrong.book_id += 1;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes, wrong));
    wrong = test_key;
    wrong.word_semantics_revision += 1;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes, wrong));
    wrong = test_key;
    wrong.spine_len -= 1;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes, wrong));

    bytes[27] = 0;
    std.mem.writeInt(u32, bytes[checksum_offset..encoded_size], checksum(bytes[0..checksum_offset]), .little);
    try std.testing.expectError(error.InvalidRecord, decode(&bytes, test_key));

    try encode(index, &bytes);
    bytes[31] |= 0x80;
    std.mem.writeInt(u32, bytes[checksum_offset..encoded_size], checksum(bytes[0..checksum_offset]), .little);
    try std.testing.expectError(error.InvalidRecord, decode(&bytes, test_key));

    try encode(index, &bytes);
    bytes[counts_offset + 4] = 1;
    std.mem.writeInt(u32, bytes[checksum_offset..encoded_size], checksum(bytes[0..checksum_offset]), .little);
    try std.testing.expectError(error.InvalidRecord, decode(&bytes, test_key));

    try encode(index, &bytes);
    bytes[checksum_offset - 1] ^= 1;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes, test_key));
}

test "chapter and book fractions are exact at first middle and final words" {
    var index = try Index.init(test_key);
    try index.setExact(0, 10);
    try index.setExact(1, 20);
    try index.setExact(2, 30);
    var bytes: [encoded_size]u8 = undefined;
    try encode(index, &bytes);
    index = try decode(&bytes, test_key);

    const first = (try index.view(.{ .chapter = 1, .word_ordinal = 0 })).book.exact;
    try std.testing.expectEqual(WideCount.fromU32(11), first.reached);
    try std.testing.expectEqual(WideCount.fromU32(60), first.total);
    try std.testing.expectEqual(WideCount.fromU32(49), first.remaining);

    const middle = (try index.view(.{ .chapter = 1, .word_ordinal = 9 })).chapter.exact;
    try std.testing.expectEqual(WideCount.fromU32(10), middle.reached);
    try std.testing.expectEqual(WideCount.fromU32(10), middle.remaining);

    const final = (try index.view(.{ .chapter = 2, .word_ordinal = 29 })).book.exact;
    try std.testing.expectEqual(final.total, final.reached);
    try std.testing.expectEqual(WideCount{}, final.remaining);
}

test "wide counts report overflow instead of wrapping" {
    try std.testing.expectError(error.CountOverflow, (WideCount{ .lo = std.math.maxInt(u32), .hi = std.math.maxInt(u32) }).add(WideCount.fromU32(1)));
}
