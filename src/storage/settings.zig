const std = @import("std");

const default_rsvp_wpm: u16 = 300;
const min_rsvp_wpm: u16 = 100;
const max_rsvp_wpm: u16 = 1000;
const rsvp_wpm_step: u16 = 25;

/// Global reader preferences are deliberately separate from the per-book
/// resume record. The version-nine encoding remains fixed at eight bytes.
pub const encoded_size = 8;

pub const ReadingMode = enum(u8) { paged = 0, rsvp = 1 };
pub const Theme = enum(u8) { light = 0, dark = 1 };

pub const ReadingFont = enum(u8) {
    newsleak_serif = 0,
    sasser_slab = 1,
    asheville_sans_14_bold = 2,
    roobert_11_bold = 3,
    roobert_20_medium = 4,
    roobert_24_medium = 5,
    espy_serif_3 = 6,
    espy_serif_4 = 7,
    espy_sans_5 = 8,
    literata_36pt_medium_30 = 9,
};

pub const default_pages_font: ReadingFont = .newsleak_serif;
pub const default_rsvp_font: ReadingFont = .roobert_20_medium;

const LegacyFont = enum(u8) {
    roobert = 0,
    newsleak_serif = 1,
    asheville_sans = 2,
    bitmore = 3,
};

pub const ProgressVisibility = enum(u8) { off = 0, on = 1 };
pub const ProgressPosition = enum(u8) { top = 0, bottom = 1 };
pub const ProgressScope = enum(u8) { chapter = 0, book = 1, both = 2 };
pub const PagedPresentation = enum(u8) { pages = 0, scroll = 1 };

pub const Settings = struct {
    reading_mode: ReadingMode = .paged,
    rsvp_wpm: u16 = default_rsvp_wpm,
    theme: Theme = .light,
    pages_font: ReadingFont = default_pages_font,
    rsvp_font: ReadingFont = default_rsvp_font,
    progress_visibility: ProgressVisibility = .off,
    progress_position: ProgressPosition = .top,
    progress_scope: ProgressScope = .chapter,
    paged_presentation: PagedPresentation = .pages,
};

pub const Error = error{InvalidRecord};

pub fn encode(settings: Settings, output: *[encoded_size]u8) void {
    const pages_font = @intFromEnum(settings.pages_font);
    const rsvp_font = @intFromEnum(settings.rsvp_font);
    // Byte four: mode bit, each font's low three bits, then Pages bit four.
    const mode_and_fonts: u8 = @intFromEnum(settings.reading_mode) |
        ((pages_font & 0x7) << 1) |
        ((rsvp_font & 0x7) << 4) |
        ((pages_font & 0x8) << 4);
    // Byte seven: display options, RSVP bit four, and one reserved high bit.
    const display: u8 = @intFromEnum(settings.theme) |
        (@intFromEnum(settings.progress_visibility) << 1) |
        (@intFromEnum(settings.progress_position) << 2) |
        (@intFromEnum(settings.progress_scope) << 3) |
        (@intFromEnum(settings.paged_presentation) << 5) |
        ((rsvp_font & 0x8) << 3);
    output.* = .{ 'E', 'P', 'S', 9, mode_and_fonts, 0, 0, display };
    std.mem.writeInt(u16, output[5..7], clampWpm(settings.rsvp_wpm), .little);
}

pub fn decode(input: *const [encoded_size]u8) Error!Settings {
    if (!std.mem.eql(u8, input[0..3], "EPS")) return error.InvalidRecord;
    return switch (input[3]) {
        1 => .{ .reading_mode = try legacyReadingMode(input[4]) },
        2 => .{ .reading_mode = try legacyReadingMode(input[4]), .rsvp_wpm = try storedWpm(input) },
        3 => .{
            .reading_mode = try legacyReadingMode(input[4]),
            .rsvp_wpm = try storedWpm(input),
            .theme = try strictTheme(input[7]),
        },
        4 => try legacySettings(
            try legacyReadingMode(input[4]),
            try storedWpm(input),
            if (input[7] & 0x1 == 0) .light else .dark,
            input[7] >> 1,
        ),
        5 => decodeVersionFive(input),
        6 => decodeVersionSix(input),
        7 => decodeVersionSeven(input),
        8 => decodeVersionEight(input),
        9 => decodeVersionNine(input),
        else => error.InvalidRecord,
    };
}

pub fn nextReadingMode(mode: ReadingMode) ReadingMode {
    return switch (mode) {
        .paged => .rsvp,
        .rsvp => .paged,
    };
}

pub fn nextPagesFont(font: ReadingFont) ReadingFont {
    return switch (font) {
        .newsleak_serif => .sasser_slab,
        .sasser_slab => .asheville_sans_14_bold,
        .asheville_sans_14_bold => .roobert_11_bold,
        .roobert_11_bold => .espy_serif_3,
        .espy_serif_3 => .espy_serif_4,
        .espy_serif_4 => .espy_sans_5,
        .espy_sans_5 => .newsleak_serif,
        .roobert_20_medium, .roobert_24_medium, .literata_36pt_medium_30 => default_pages_font,
    };
}

pub fn nextRsvpFont(font: ReadingFont) ReadingFont {
    return switch (font) {
        .roobert_20_medium => .roobert_24_medium,
        .roobert_24_medium => .literata_36pt_medium_30,
        .literata_36pt_medium_30 => .roobert_20_medium,
        .newsleak_serif, .sasser_slab, .asheville_sans_14_bold, .roobert_11_bold, .espy_serif_3, .espy_serif_4, .espy_sans_5 => default_rsvp_font,
    };
}

pub fn normalizePagesFont(font: ReadingFont) ReadingFont {
    return switch (font) {
        .newsleak_serif, .sasser_slab, .asheville_sans_14_bold, .roobert_11_bold, .espy_serif_3, .espy_serif_4, .espy_sans_5 => font,
        .roobert_20_medium, .roobert_24_medium, .literata_36pt_medium_30 => default_pages_font,
    };
}

pub fn normalizeRsvpFont(font: ReadingFont) ReadingFont {
    return switch (font) {
        .roobert_20_medium, .roobert_24_medium, .literata_36pt_medium_30 => font,
        .newsleak_serif, .sasser_slab, .asheville_sans_14_bold, .roobert_11_bold, .espy_serif_3, .espy_serif_4, .espy_sans_5 => default_rsvp_font,
    };
}

fn decodeVersionFive(input: *const [encoded_size]u8) Error!Settings {
    if (input[7] & 0xc0 != 0) return error.InvalidRecord;
    var settings = try legacySettings(
        try legacyReadingMode(input[4]),
        try storedWpm(input),
        if (input[7] & 0x1 == 0) .light else .dark,
        (input[7] >> 1) & 0x1,
    );
    settings.progress_visibility = if ((input[7] >> 2) & 0x1 == 0) .off else .on;
    settings.progress_position = if ((input[7] >> 3) & 0x1 == 0) .top else .bottom;
    settings.progress_scope = try scopeFromBits((input[7] >> 4) & 0x3);
    return settings;
}

fn decodeVersionSix(input: *const [encoded_size]u8) Error!Settings {
    if (input[7] & 0x80 != 0) return error.InvalidRecord;
    var settings = try legacySettings(
        try legacyReadingMode(input[4]),
        try storedWpm(input),
        if (input[7] & 0x1 == 0) .light else .dark,
        (input[7] >> 1) & 0x3,
    );
    settings.progress_visibility = if ((input[7] >> 3) & 0x1 == 0) .off else .on;
    settings.progress_position = if ((input[7] >> 4) & 0x1 == 0) .top else .bottom;
    settings.progress_scope = try scopeFromBits((input[7] >> 5) & 0x3);
    return settings;
}

fn decodeVersionSeven(input: *const [encoded_size]u8) Error!Settings {
    var settings = try legacySettings(
        try legacyReadingMode(input[4]),
        try storedWpm(input),
        if (input[7] & 0x1 == 0) .light else .dark,
        (input[7] >> 1) & 0x3,
    );
    settings.progress_visibility = if ((input[7] >> 3) & 0x1 == 0) .off else .on;
    settings.progress_position = if ((input[7] >> 4) & 0x1 == 0) .top else .bottom;
    settings.progress_scope = try scopeFromBits((input[7] >> 5) & 0x3);
    settings.paged_presentation = if ((input[7] >> 7) & 0x1 == 0) .pages else .scroll;
    return settings;
}

fn decodeVersionEight(input: *const [encoded_size]u8) Error!Settings {
    if (input[4] & 0x80 != 0 or input[7] & 0xc0 != 0) return error.InvalidRecord;
    return .{
        .reading_mode = if (input[4] & 0x1 == 0) .paged else .rsvp,
        .rsvp_wpm = try storedWpm(input),
        .theme = if (input[7] & 0x1 == 0) .light else .dark,
        .pages_font = try versionEightReadingFontFromBits((input[4] >> 1) & 0x7),
        .rsvp_font = try versionEightReadingFontFromBits((input[4] >> 4) & 0x7),
        .progress_visibility = if ((input[7] >> 1) & 0x1 == 0) .off else .on,
        .progress_position = if ((input[7] >> 2) & 0x1 == 0) .top else .bottom,
        .progress_scope = try scopeFromBits((input[7] >> 3) & 0x3),
        .paged_presentation = if ((input[7] >> 5) & 0x1 == 0) .pages else .scroll,
    };
}

fn decodeVersionNine(input: *const [encoded_size]u8) Error!Settings {
    if (input[7] & 0x80 != 0) return error.InvalidRecord;
    return .{
        .reading_mode = if (input[4] & 0x1 == 0) .paged else .rsvp,
        .rsvp_wpm = try storedWpm(input),
        .theme = if (input[7] & 0x1 == 0) .light else .dark,
        .pages_font = try readingFontFromBits(((input[4] >> 1) & 0x7) | ((input[4] >> 4) & 0x8)),
        .rsvp_font = try readingFontFromBits(((input[4] >> 4) & 0x7) | ((input[7] >> 3) & 0x8)),
        .progress_visibility = if ((input[7] >> 1) & 0x1 == 0) .off else .on,
        .progress_position = if ((input[7] >> 2) & 0x1 == 0) .top else .bottom,
        .progress_scope = try scopeFromBits((input[7] >> 3) & 0x3),
        .paged_presentation = if ((input[7] >> 5) & 0x1 == 0) .pages else .scroll,
    };
}

fn legacySettings(reading_mode: ReadingMode, rsvp_wpm: u16, theme: Theme, legacy_font: u8) Error!Settings {
    const font = try legacyReadingFont(legacy_font);
    return .{
        .reading_mode = reading_mode,
        .rsvp_wpm = rsvp_wpm,
        .theme = theme,
        .pages_font = font,
        .rsvp_font = font,
    };
}

fn legacyReadingMode(value: u8) Error!ReadingMode {
    return switch (value) {
        @intFromEnum(ReadingMode.paged) => .paged,
        @intFromEnum(ReadingMode.rsvp) => .rsvp,
        else => error.InvalidRecord,
    };
}

fn strictTheme(value: u8) Error!Theme {
    return switch (value) {
        @intFromEnum(Theme.light) => .light,
        @intFromEnum(Theme.dark) => .dark,
        else => error.InvalidRecord,
    };
}

fn legacyReadingFont(value: u8) Error!ReadingFont {
    return switch (value) {
        @intFromEnum(LegacyFont.roobert) => .roobert_20_medium,
        @intFromEnum(LegacyFont.newsleak_serif) => .newsleak_serif,
        @intFromEnum(LegacyFont.asheville_sans) => .asheville_sans_14_bold,
        // Bitmore is not Sasser Slab, so retain a stable fallback instead of
        // silently substituting an unrelated face.
        @intFromEnum(LegacyFont.bitmore) => .roobert_20_medium,
        else => error.InvalidRecord,
    };
}

fn readingFontFromBits(value: u8) Error!ReadingFont {
    return switch (value) {
        @intFromEnum(ReadingFont.newsleak_serif) => .newsleak_serif,
        @intFromEnum(ReadingFont.sasser_slab) => .sasser_slab,
        @intFromEnum(ReadingFont.asheville_sans_14_bold) => .asheville_sans_14_bold,
        @intFromEnum(ReadingFont.roobert_11_bold) => .roobert_11_bold,
        @intFromEnum(ReadingFont.roobert_20_medium) => .roobert_20_medium,
        @intFromEnum(ReadingFont.roobert_24_medium) => .roobert_24_medium,
        @intFromEnum(ReadingFont.espy_serif_3) => .espy_serif_3,
        @intFromEnum(ReadingFont.espy_serif_4) => .espy_serif_4,
        @intFromEnum(ReadingFont.espy_sans_5) => .espy_sans_5,
        @intFromEnum(ReadingFont.literata_36pt_medium_30) => .literata_36pt_medium_30,
        else => error.InvalidRecord,
    };
}

fn versionEightReadingFontFromBits(value: u8) Error!ReadingFont {
    if (value > @intFromEnum(ReadingFont.roobert_24_medium)) return error.InvalidRecord;
    return readingFontFromBits(value);
}

fn scopeFromBits(value: u8) Error!ProgressScope {
    return switch (value) {
        0 => .chapter,
        1 => .book,
        2 => .both,
        else => error.InvalidRecord,
    };
}

fn storedWpm(input: *const [encoded_size]u8) Error!u16 {
    return validateWpm(std.mem.readInt(u16, input[5..7], .little)) orelse error.InvalidRecord;
}

test "version nine round trips every Pages and RSVP font pair" {
    const fonts = [_]ReadingFont{ .newsleak_serif, .sasser_slab, .asheville_sans_14_bold, .roobert_11_bold, .roobert_20_medium, .roobert_24_medium, .espy_serif_3, .espy_serif_4, .espy_sans_5, .literata_36pt_medium_30 };
    for (fonts) |pages_font| for (fonts) |rsvp_font| {
        var bytes: [encoded_size]u8 = undefined;
        encode(.{
            .reading_mode = .rsvp,
            .rsvp_wpm = 425,
            .theme = .dark,
            .pages_font = pages_font,
            .rsvp_font = rsvp_font,
            .progress_visibility = .on,
            .progress_position = .bottom,
            .progress_scope = .both,
            .paged_presentation = .scroll,
        }, &bytes);
        const settings = try decode(&bytes);
        try std.testing.expectEqual(pages_font, settings.pages_font);
        try std.testing.expectEqual(rsvp_font, settings.rsvp_font);
        try std.testing.expectEqual(PagedPresentation.scroll, settings.paged_presentation);
    };
}

test "legacy settings populate both reading font preferences" {
    var version_seven = [_]u8{ 'E', 'P', 'S', 7, @intFromEnum(ReadingMode.paged), 0, 0, @intFromEnum(Theme.dark) | (@intFromEnum(LegacyFont.asheville_sans) << 1) | (@intFromEnum(ProgressVisibility.on) << 3) | (@intFromEnum(PagedPresentation.scroll) << 7) };
    std.mem.writeInt(u16, version_seven[5..7], 425, .little);
    const asheville = try decode(&version_seven);
    try std.testing.expectEqual(ReadingFont.asheville_sans_14_bold, asheville.pages_font);
    try std.testing.expectEqual(asheville.pages_font, asheville.rsvp_font);
    try std.testing.expectEqual(PagedPresentation.scroll, asheville.paged_presentation);

    version_seven[7] = @intFromEnum(LegacyFont.bitmore) << 1;
    const bitmore = try decode(&version_seven);
    try std.testing.expectEqual(ReadingFont.roobert_20_medium, bitmore.pages_font);
    try std.testing.expectEqual(bitmore.pages_font, bitmore.rsvp_font);
}

test "version eight rejects reserved and unsupported font bits" {
    var bytes = [_]u8{ 'E', 'P', 'S', 8, 0, 0, 0, 0 };
    std.mem.writeInt(u16, bytes[5..7], default_rsvp_wpm, .little);
    bytes[4] = 0x80;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes));
    bytes[4] = 0x0c;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes));
    bytes[4] = 0;
    bytes[7] = 0x40;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes));
}

test "Pages and RSVP cycle through separate font sets" {
    try std.testing.expectEqual(ReadingFont.sasser_slab, nextPagesFont(.newsleak_serif));
    try std.testing.expectEqual(ReadingFont.newsleak_serif, nextPagesFont(.espy_sans_5));
    try std.testing.expectEqual(ReadingFont.newsleak_serif, nextPagesFont(.literata_36pt_medium_30));

    try std.testing.expectEqual(ReadingFont.roobert_24_medium, nextRsvpFont(.roobert_20_medium));
    try std.testing.expectEqual(ReadingFont.literata_36pt_medium_30, nextRsvpFont(.roobert_24_medium));
    try std.testing.expectEqual(ReadingFont.roobert_20_medium, nextRsvpFont(.literata_36pt_medium_30));
    try std.testing.expectEqual(ReadingFont.roobert_20_medium, nextRsvpFont(.espy_sans_5));

    try std.testing.expectEqual(ReadingFont.newsleak_serif, normalizePagesFont(.roobert_24_medium));
    try std.testing.expectEqual(ReadingFont.roobert_20_medium, normalizeRsvpFont(.espy_serif_4));
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
