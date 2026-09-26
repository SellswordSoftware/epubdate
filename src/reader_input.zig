const std = @import("std");

pub const Screen = enum { library, opening, reading, settings, statistics, chapter_browser };
pub const Readiness = enum { opening, ready, opening_failure, chapter_error };
pub const ReadingMode = enum { paged, rsvp };
pub const PagedPresentation = enum { pages, scroll };

pub const Buttons = struct {
    a: bool = false,
    b: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
};

pub const Snapshot = struct {
    screen: Screen,
    readiness: Readiness,
    mode: ReadingMode,
    paged_presentation: PagedPresentation = .pages,
    buttons: Buttons,
};

pub const Intent = enum {
    none,
    library_next,
    library_previous,
    open_selected_book,
    return_to_library,
    open_settings,
    open_statistics,
    close_settings,
    close_statistics,
    close_chapter_browser,
    chapter_browser_next,
    chapter_browser_previous,
    open_browser_chapter,
    settings_next,
    settings_previous,
    activate_setting,
    toggle_reading_mode,
    rsvp_toggle_autoplay,
    rsvp_wpm_up,
    rsvp_wpm_down,
    rsvp_previous_sentence,
    next_page,
    previous_page,
    next_chapter,
    previous_chapter,
};

pub fn intentFor(snapshot: Snapshot) Intent {
    if (snapshot.screen == .statistics) {
        if (snapshot.buttons.b or snapshot.buttons.down) return .close_statistics;
        return .none;
    }
    if (snapshot.screen == .settings) {
        if (snapshot.buttons.b) return .close_settings;
        if (snapshot.buttons.down) return .settings_next;
        if (snapshot.buttons.up) return .settings_previous;
        if (snapshot.buttons.a) return .activate_setting;
        return .none;
    }
    if (snapshot.screen == .chapter_browser) {
        if (snapshot.buttons.b) return .close_chapter_browser;
        if (snapshot.buttons.a) return .open_browser_chapter;
        if (snapshot.buttons.down or snapshot.buttons.right) return .chapter_browser_next;
        if (snapshot.buttons.up or snapshot.buttons.left) return .chapter_browser_previous;
        return .none;
    }
    if (snapshot.screen == .reading) {
        if (snapshot.buttons.b) return .toggle_reading_mode;
        if (snapshot.mode == .rsvp) {
            if (snapshot.buttons.up) return .rsvp_wpm_up;
            if (snapshot.buttons.down) return .rsvp_wpm_down;
        }
        if (snapshot.buttons.up) return .return_to_library;
        if (snapshot.buttons.down) return .open_statistics;
        if (snapshot.mode == .paged and snapshot.buttons.a) return .open_settings;
    }
    if (snapshot.screen == .library) {
        if (snapshot.buttons.down or snapshot.buttons.right) return .library_next;
        if (snapshot.buttons.up or snapshot.buttons.left) return .library_previous;
        if (snapshot.buttons.a) return .open_selected_book;
        return .none;
    }
    if (snapshot.readiness == .opening_failure) {
        if (snapshot.buttons.b or snapshot.buttons.up) return .return_to_library;
        return .none;
    }
    if (snapshot.readiness == .chapter_error) {
        if (snapshot.buttons.right or snapshot.buttons.down) return .next_chapter;
        if (snapshot.buttons.left or snapshot.buttons.up) return .previous_chapter;
        return .none;
    }
    if (snapshot.screen == .reading and snapshot.mode == .rsvp) {
        if (snapshot.buttons.a) return .rsvp_toggle_autoplay;
        if (snapshot.buttons.left) return .rsvp_previous_sentence;
        return .none;
    }
    if (snapshot.screen == .reading and snapshot.paged_presentation == .scroll) {
        if (snapshot.buttons.right) return .next_chapter;
        if (snapshot.buttons.left) return .previous_chapter;
        return .none;
    }
    if (snapshot.buttons.right or snapshot.buttons.down) return .next_page;
    if (snapshot.buttons.left or snapshot.buttons.up) return .previous_page;
    return .none;
}

test "Paged reading reserves Up and Down for library and statistics" {
    const base = Snapshot{ .screen = .reading, .readiness = .ready, .mode = .paged, .paged_presentation = .scroll, .buttons = .{} };
    var snapshot = base;
    snapshot.buttons.right = true;
    try std.testing.expectEqual(Intent.next_chapter, intentFor(snapshot));
    snapshot.buttons = .{ .left = true };
    try std.testing.expectEqual(Intent.previous_chapter, intentFor(snapshot));
    snapshot.buttons = .{ .up = true };
    try std.testing.expectEqual(Intent.return_to_library, intentFor(snapshot));
    snapshot.buttons = .{ .down = true };
    try std.testing.expectEqual(Intent.open_statistics, intentFor(snapshot));
    snapshot.buttons = .{ .a = true };
    try std.testing.expectEqual(Intent.open_settings, intentFor(snapshot));
    snapshot.mode = .rsvp;
    snapshot.buttons = .{ .a = true };
    try std.testing.expectEqual(Intent.rsvp_toggle_autoplay, intentFor(snapshot));
    snapshot.buttons = .{ .up = true };
    try std.testing.expectEqual(Intent.rsvp_wpm_up, intentFor(snapshot));
    snapshot.buttons = .{ .down = true };
    try std.testing.expectEqual(Intent.rsvp_wpm_down, intentFor(snapshot));
}

test "B and Down both dismiss reading statistics" {
    const base = Snapshot{ .screen = .statistics, .readiness = .ready, .mode = .paged, .buttons = .{} };
    var snapshot = base;
    snapshot.buttons.b = true;
    try std.testing.expectEqual(Intent.close_statistics, intentFor(snapshot));
    snapshot.buttons = .{ .down = true };
    try std.testing.expectEqual(Intent.close_statistics, intentFor(snapshot));
}

test "reading gives the mode toggle priority over page navigation" {
    const intent = intentFor(.{
        .screen = .reading,
        .readiness = .ready,
        .mode = .paged,
        .buttons = .{ .b = true, .right = true },
    });
    try std.testing.expectEqual(Intent.toggle_reading_mode, intent);
}

test "settings consumes its own controls before reader navigation" {
    const intent = intentFor(.{
        .screen = .settings,
        .readiness = .ready,
        .mode = .paged,
        .buttons = .{ .b = true, .down = true, .a = true },
    });
    try std.testing.expectEqual(Intent.close_settings, intent);
}

test "screen and reader state route the remaining navigation intents" {
    try std.testing.expectEqual(Intent.open_selected_book, intentFor(.{
        .screen = .library,
        .readiness = .opening,
        .mode = .paged,
        .buttons = .{ .a = true },
    }));
    try std.testing.expectEqual(Intent.chapter_browser_next, intentFor(.{
        .screen = .chapter_browser,
        .readiness = .ready,
        .mode = .paged,
        .buttons = .{ .right = true },
    }));
    try std.testing.expectEqual(Intent.next_chapter, intentFor(.{
        .screen = .reading,
        .readiness = .chapter_error,
        .mode = .paged,
        .buttons = .{ .right = true },
    }));
    try std.testing.expectEqual(Intent.rsvp_previous_sentence, intentFor(.{
        .screen = .reading,
        .readiness = .ready,
        .mode = .rsvp,
        .buttons = .{ .left = true },
    }));
    try std.testing.expectEqual(Intent.return_to_library, intentFor(.{
        .screen = .opening,
        .readiness = .opening_failure,
        .mode = .paged,
        .buttons = .{ .b = true },
    }));
    try std.testing.expectEqual(Intent.previous_page, intentFor(.{
        .screen = .opening,
        .readiness = .ready,
        .mode = .paged,
        .buttons = .{ .left = true },
    }));
}
