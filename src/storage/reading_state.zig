const std = @import("std");
const reading_position = @import("resume.zig");

pub const Mode = reading_position.Mode;

/// The reader's durable semantic location, independent of file naming and
/// platform I/O. A save always converts this value to the existing record.
pub const ReadingSnapshot = struct {
    book_id: u32,
    layout_revision: u16,
    chapter: u16,
    word_ordinal: u32,
    mode: Mode,
};

pub fn encodeResume(snapshot: ReadingSnapshot, output: *[reading_position.encoded_size]u8) void {
    reading_position.encode(.{
        .book_id = snapshot.book_id,
        .layout_revision = snapshot.layout_revision,
        .chapter = snapshot.chapter,
        .word_ordinal = snapshot.word_ordinal,
        .mode = snapshot.mode,
    }, output);
}

pub const RestoredPosition = union(enum) {
    snapshot: ReadingSnapshot,
    legacy_paged_page: struct {
        chapter: u16,
        page: u32,
    },
};

/// Decodes only a record belonging to the requested book and layout. Legacy
/// Paged page records remain explicit so a caller can retain their rebuild
/// path rather than treating a page number as a word ordinal.
pub fn restoreResume(input: *const [reading_position.encoded_size]u8, book_id: u32, layout_revision: u16) ?RestoredPosition {
    const position = reading_position.decode(input) catch return null;
    if (!reading_position.matches(position, book_id, layout_revision)) return null;
    if (position.legacy_paged_page) |page| return .{ .legacy_paged_page = .{
        .chapter = position.chapter,
        .page = page,
    } };
    return .{ .snapshot = .{
        .book_id = position.book_id,
        .layout_revision = position.layout_revision,
        .chapter = position.chapter,
        .word_ordinal = position.word_ordinal,
        .mode = position.mode,
    } };
}

test "a reading snapshot preserves the version 4 resume record bytes" {
    const snapshot = ReadingSnapshot{
        .book_id = 0x12_34_56_78,
        .layout_revision = 7,
        .chapter = 3,
        .word_ordinal = 42,
        .mode = .rsvp,
    };
    var actual: [reading_position.encoded_size]u8 = undefined;
    encodeResume(snapshot, &actual);

    var expected: [reading_position.encoded_size]u8 = undefined;
    reading_position.encode(.{
        .book_id = snapshot.book_id,
        .layout_revision = snapshot.layout_revision,
        .chapter = snapshot.chapter,
        .word_ordinal = snapshot.word_ordinal,
        .mode = snapshot.mode,
    }, &expected);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "restore rejects a snapshot for another book or layout" {
    var bytes: [reading_position.encoded_size]u8 = undefined;
    encodeResume(.{
        .book_id = 7,
        .layout_revision = 2,
        .chapter = 3,
        .word_ordinal = 42,
        .mode = .paged,
    }, &bytes);

    try std.testing.expect(restoreResume(&bytes, 8, 2) == null);
    try std.testing.expect(restoreResume(&bytes, 7, 3) == null);
}
