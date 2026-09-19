const std = @import("std");

const default_rsvp_wpm: u16 = 300;
const min_rsvp_wpm: u16 = 100;
const max_rsvp_wpm: u16 = 1000;
const rsvp_wpm_step: u16 = 25;

/// Global reader preferences are deliberately separate from the per-book
/// resume record.  More settings can extend this fixed, versioned record
/// without changing a saved chapter/page position.
pub const encoded_size = 8;

pub const ReadingMode = enum(u8) {
    paged = 0,
    rsvp = 1,
};

pub const Settings = struct {
    reading_mode: ReadingMode = .paged,
    rsvp_wpm: u16 = default_rsvp_wpm,
};

pub const Error = error{InvalidRecord};

pub fn encode(settings: Settings, output: *[encoded_size]u8) void {
    output.* = .{ 'E', 'P', 'S', 2, @intFromEnum(settings.reading_mode), 0, 0, 0 };
    std.mem.writeInt(u16, output[5..7], clampWpm(settings.rsvp_wpm), .little);
}

pub fn decode(input: *const [encoded_size]u8) Error!Settings {
    if (!std.mem.eql(u8, input[0..3], "EPS")) return error.InvalidRecord;
    const reading_mode: ReadingMode = switch (input[4]) {
        @intFromEnum(ReadingMode.paged) => .paged,
        @intFromEnum(ReadingMode.rsvp) => .rsvp,
        else => return error.InvalidRecord,
    };
    return switch (input[3]) {
        1 => .{ .reading_mode = reading_mode },
        2 => .{ .reading_mode = reading_mode, .rsvp_wpm = validateWpm(std.mem.readInt(u16, input[5..7], .little)) orelse return error.InvalidRecord },
        else => error.InvalidRecord,
    };
}

pub fn nextReadingMode(mode: ReadingMode) ReadingMode {
    return switch (mode) {
        .paged => .rsvp,
        .rsvp => .paged,
    };
}

test "round trips the persisted reading mode and WPM" {
    var bytes: [encoded_size]u8 = undefined;
    encode(.{ .reading_mode = .rsvp, .rsvp_wpm = 425 }, &bytes);
    const settings = try decode(&bytes);
    try std.testing.expectEqual(ReadingMode.rsvp, settings.reading_mode);
    try std.testing.expectEqual(@as(u16, 425), settings.rsvp_wpm);
}

test "migrates the original mode-only record to default WPM" {
    const bytes = [_]u8{ 'E', 'P', 'S', 1, @intFromEnum(ReadingMode.rsvp), 0, 0, 0 };
    const settings = try decode(&bytes);
    try std.testing.expectEqual(ReadingMode.rsvp, settings.reading_mode);
    try std.testing.expectEqual(default_rsvp_wpm, settings.rsvp_wpm);
}

test "rejects unknown settings versions and modes" {
    var bytes = [_]u8{ 'E', 'P', 'S', 1, 9, 0, 0, 0 };
    try std.testing.expectError(error.InvalidRecord, decode(&bytes));
    bytes[3] = 2;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes));
}

test "cycles between the currently supported reading modes" {
    try std.testing.expectEqual(ReadingMode.rsvp, nextReadingMode(.paged));
    try std.testing.expectEqual(ReadingMode.paged, nextReadingMode(.rsvp));
}

fn validateWpm(wpm: u16) ?u16 {
    if (wpm < min_rsvp_wpm or wpm > max_rsvp_wpm or (wpm - min_rsvp_wpm) % rsvp_wpm_step != 0) return null;
    return wpm;
}

fn clampWpm(wpm: u16) u16 {
    if (wpm <= min_rsvp_wpm) return min_rsvp_wpm;
    if (wpm >= max_rsvp_wpm) return max_rsvp_wpm;
    return min_rsvp_wpm + @divTrunc(wpm - min_rsvp_wpm, rsvp_wpm_step) * rsvp_wpm_step;
}
