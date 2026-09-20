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

pub const Theme = enum(u8) {
    light = 0,
    dark = 1,
};

pub const Font = enum(u8) {
    roobert = 0,
    newsleak_serif = 1,
    asheville_sans = 2,
};

pub const ProgressVisibility = enum(u8) { off = 0, on = 1 };
pub const ProgressPosition = enum(u8) { top = 0, bottom = 1 };
pub const ProgressScope = enum(u8) { chapter = 0, book = 1, both = 2 };

pub const Settings = struct {
    reading_mode: ReadingMode = .paged,
    rsvp_wpm: u16 = default_rsvp_wpm,
    theme: Theme = .light,
    font: Font = .roobert,
    progress_visibility: ProgressVisibility = .off,
    progress_position: ProgressPosition = .top,
    progress_scope: ProgressScope = .chapter,
};

pub const Error = error{InvalidRecord};

pub fn encode(settings: Settings, output: *[encoded_size]u8) void {
    // Version six widens the font field from one bit to two so the Asheville
    // font fits beside Roobert and Newsleak; older versions stay decodable.
    const display: u8 = @intFromEnum(settings.theme) |
        (@intFromEnum(settings.font) << 1) |
        (@intFromEnum(settings.progress_visibility) << 3) |
        (@intFromEnum(settings.progress_position) << 4) |
        (@intFromEnum(settings.progress_scope) << 5);
    output.* = .{ 'E', 'P', 'S', 6, @intFromEnum(settings.reading_mode), 0, 0, display };
    std.mem.writeInt(u16, output[5..7], clampWpm(settings.rsvp_wpm), .little);
}

pub fn decode(input: *const [encoded_size]u8) Error!Settings {
    if (!std.mem.eql(u8, input[0..3], "EPS")) return error.InvalidRecord;
    if (input[3] == 5 and input[7] & 0xc0 != 0) return error.InvalidRecord;
    if (input[3] == 6 and input[7] & 0x80 != 0) return error.InvalidRecord;
    const reading_mode: ReadingMode = switch (input[4]) {
        @intFromEnum(ReadingMode.paged) => .paged,
        @intFromEnum(ReadingMode.rsvp) => .rsvp,
        else => return error.InvalidRecord,
    };
    return switch (input[3]) {
        1 => .{ .reading_mode = reading_mode },
        2 => .{ .reading_mode = reading_mode, .rsvp_wpm = validateWpm(std.mem.readInt(u16, input[5..7], .little)) orelse return error.InvalidRecord },
        3 => .{
            .reading_mode = reading_mode,
            .rsvp_wpm = validateWpm(std.mem.readInt(u16, input[5..7], .little)) orelse return error.InvalidRecord,
            .theme = switch (input[7]) {
                @intFromEnum(Theme.light) => .light,
                @intFromEnum(Theme.dark) => .dark,
                else => return error.InvalidRecord,
            },
        },
        4 => .{
            .reading_mode = reading_mode,
            .rsvp_wpm = validateWpm(std.mem.readInt(u16, input[5..7], .little)) orelse return error.InvalidRecord,
            .theme = switch (input[7] & 0x1) {
                @intFromEnum(Theme.light) => .light,
                @intFromEnum(Theme.dark) => .dark,
                else => unreachable,
            },
            .font = switch (input[7] >> 1) {
                @intFromEnum(Font.roobert) => .roobert,
                @intFromEnum(Font.newsleak_serif) => .newsleak_serif,
                else => return error.InvalidRecord,
            },
        },
        5 => .{
            .reading_mode = reading_mode,
            .rsvp_wpm = validateWpm(std.mem.readInt(u16, input[5..7], .little)) orelse return error.InvalidRecord,
            .theme = if (input[7] & 0x1 == 0) .light else .dark,
            .font = if ((input[7] >> 1) & 0x1 == 0) .roobert else .newsleak_serif,
            .progress_visibility = if ((input[7] >> 2) & 0x1 == 0) .off else .on,
            .progress_position = if ((input[7] >> 3) & 0x1 == 0) .top else .bottom,
            .progress_scope = switch ((input[7] >> 4) & 0x3) {
                0 => .chapter,
                1 => .book,
                2 => .both,
                else => return error.InvalidRecord,
            },
        },
        6 => .{
            .reading_mode = reading_mode,
            .rsvp_wpm = validateWpm(std.mem.readInt(u16, input[5..7], .little)) orelse return error.InvalidRecord,
            .theme = if (input[7] & 0x1 == 0) .light else .dark,
            .font = switch ((input[7] >> 1) & 0x3) {
                @intFromEnum(Font.roobert) => .roobert,
                @intFromEnum(Font.newsleak_serif) => .newsleak_serif,
                @intFromEnum(Font.asheville_sans) => .asheville_sans,
                else => return error.InvalidRecord,
            },
            .progress_visibility = if ((input[7] >> 3) & 0x1 == 0) .off else .on,
            .progress_position = if ((input[7] >> 4) & 0x1 == 0) .top else .bottom,
            .progress_scope = switch ((input[7] >> 5) & 0x3) {
                0 => .chapter,
                1 => .book,
                2 => .both,
                else => return error.InvalidRecord,
            },
        },
        else => error.InvalidRecord,
    };
}

pub fn nextReadingMode(mode: ReadingMode) ReadingMode {
    return switch (mode) {
        .paged => .rsvp,
        .rsvp => .paged,
    };
}

test "round trips reader and progress display settings" {
    var bytes: [encoded_size]u8 = undefined;
    encode(.{
        .reading_mode = .rsvp,
        .rsvp_wpm = 425,
        .theme = .dark,
        .font = .newsleak_serif,
        .progress_visibility = .on,
        .progress_position = .bottom,
        .progress_scope = .both,
    }, &bytes);
    const settings = try decode(&bytes);
    try std.testing.expectEqual(ReadingMode.rsvp, settings.reading_mode);
    try std.testing.expectEqual(@as(u16, 425), settings.rsvp_wpm);
    try std.testing.expectEqual(Theme.dark, settings.theme);
    try std.testing.expectEqual(Font.newsleak_serif, settings.font);
    try std.testing.expectEqual(ProgressVisibility.on, settings.progress_visibility);
    try std.testing.expectEqual(ProgressPosition.bottom, settings.progress_position);
    try std.testing.expectEqual(ProgressScope.both, settings.progress_scope);
}

test "migrates the original mode-only record to default WPM" {
    const bytes = [_]u8{ 'E', 'P', 'S', 1, @intFromEnum(ReadingMode.rsvp), 0, 0, 0 };
    const settings = try decode(&bytes);
    try std.testing.expectEqual(ReadingMode.rsvp, settings.reading_mode);
    try std.testing.expectEqual(default_rsvp_wpm, settings.rsvp_wpm);
    try std.testing.expectEqual(Theme.light, settings.theme);
    try std.testing.expectEqual(Font.roobert, settings.font);
}

test "migrates WPM records to the light theme" {
    var bytes = [_]u8{ 'E', 'P', 'S', 2, @intFromEnum(ReadingMode.paged), 0, 0, 0 };
    std.mem.writeInt(u16, bytes[5..7], 425, .little);
    const settings = try decode(&bytes);
    try std.testing.expectEqual(@as(u16, 425), settings.rsvp_wpm);
    try std.testing.expectEqual(Theme.light, settings.theme);
    try std.testing.expectEqual(Font.roobert, settings.font);
}

test "migrates theme records to the Roobert font" {
    var bytes = [_]u8{ 'E', 'P', 'S', 3, @intFromEnum(ReadingMode.rsvp), 0, 0, @intFromEnum(Theme.dark) };
    std.mem.writeInt(u16, bytes[5..7], 425, .little);
    const settings = try decode(&bytes);
    try std.testing.expectEqual(Theme.dark, settings.theme);
    try std.testing.expectEqual(Font.roobert, settings.font);
}

test "round trips the Asheville font at the current record version" {
    var bytes: [encoded_size]u8 = undefined;
    encode(.{
        .reading_mode = .paged,
        .rsvp_wpm = 350,
        .theme = .dark,
        .font = .asheville_sans,
        .progress_visibility = .on,
        .progress_position = .bottom,
        .progress_scope = .book,
    }, &bytes);
    const settings = try decode(&bytes);
    try std.testing.expectEqual(ReadingMode.paged, settings.reading_mode);
    try std.testing.expectEqual(@as(u16, 350), settings.rsvp_wpm);
    try std.testing.expectEqual(Theme.dark, settings.theme);
    try std.testing.expectEqual(Font.asheville_sans, settings.font);
    try std.testing.expectEqual(ProgressVisibility.on, settings.progress_visibility);
    try std.testing.expectEqual(ProgressPosition.bottom, settings.progress_position);
    try std.testing.expectEqual(ProgressScope.book, settings.progress_scope);
}

test "migrates version five records to the wider font field" {
    var bytes = [_]u8{ 'E', 'P', 'S', 5, @intFromEnum(ReadingMode.paged), 0, 0, @intFromEnum(Theme.dark) | (@intFromEnum(Font.newsleak_serif) << 1) | (@intFromEnum(ProgressVisibility.on) << 2) | (@intFromEnum(ProgressScope.book) << 4) };
    std.mem.writeInt(u16, bytes[5..7], 425, .little);
    const settings = try decode(&bytes);
    try std.testing.expectEqual(Theme.dark, settings.theme);
    try std.testing.expectEqual(Font.newsleak_serif, settings.font);
    try std.testing.expectEqual(ProgressVisibility.on, settings.progress_visibility);
    try std.testing.expectEqual(ProgressPosition.top, settings.progress_position);
    try std.testing.expectEqual(ProgressScope.book, settings.progress_scope);
}

test "migrates version four records to default progress display settings" {
    var bytes = [_]u8{ 'E', 'P', 'S', 4, @intFromEnum(ReadingMode.paged), 0, 0, @intFromEnum(Theme.dark) | (@intFromEnum(Font.newsleak_serif) << 1) };
    std.mem.writeInt(u16, bytes[5..7], 425, .little);
    const settings = try decode(&bytes);
    try std.testing.expectEqual(ProgressVisibility.off, settings.progress_visibility);
    try std.testing.expectEqual(ProgressPosition.top, settings.progress_position);
    try std.testing.expectEqual(ProgressScope.chapter, settings.progress_scope);
}

test "rejects unknown settings versions and modes" {
    var bytes = [_]u8{ 'E', 'P', 'S', 1, 9, 0, 0, 0 };
    try std.testing.expectError(error.InvalidRecord, decode(&bytes));
    bytes[3] = 2;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes));
    bytes[3] = 3;
    bytes[4] = @intFromEnum(ReadingMode.paged);
    bytes[5] = 44;
    bytes[6] = 1;
    bytes[7] = 9;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes));
    bytes[3] = 4;
    bytes[7] = 4;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes));
    bytes[3] = 5;
    bytes[7] = 0x30;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes));
    bytes[3] = 6;
    bytes[7] = 0x80;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes));
    bytes[7] = 0x6;
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
