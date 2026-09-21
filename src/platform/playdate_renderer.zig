const std = @import("std");
const chapter_browser = @import("../chapter_browser.zig");
const pdapi = @import("../playdate_api_definitions.zig");
const AllocatorStats = @import("playdate_allocator.zig").Stats;
const reader_coordinator = @import("../reader_coordinator.zig");
const reader_layout = @import("../reader_layout.zig");
const progress_rail = @import("../progress_rail.zig");
const TelemetrySnapshot = @import("../telemetry.zig").Telemetry.Snapshot;

/// The only layer that translates reader drawing primitives into Playdate
/// graphics calls. Higher layers provide already-selected text and geometry.
pub const Renderer = struct {
    playdate: *pdapi.PlaydateAPI,
    ui_regular_font: *pdapi.LCDFont,
    ui_bold_font: *pdapi.LCDFont,
    sasser_slab_font: *pdapi.LCDFont,
    asheville_sans_font: *pdapi.LCDFont,
    roobert_11_bold_font: *pdapi.LCDFont,
    roobert_20_medium_font: *pdapi.LCDFont,
    roobert_24_medium_font: *pdapi.LCDFont,
    pages_font: reader_coordinator.ReadingFont = .roobert_20_medium,
    rsvp_font: reader_coordinator.ReadingFont = .roobert_20_medium,
    theme: reader_coordinator.Theme,

    pub fn init(
        playdate: *pdapi.PlaydateAPI,
        ui_regular_font: *pdapi.LCDFont,
        ui_bold_font: *pdapi.LCDFont,
        sasser_slab_font: *pdapi.LCDFont,
        asheville_sans_font: *pdapi.LCDFont,
        roobert_11_bold_font: *pdapi.LCDFont,
        roobert_20_medium_font: *pdapi.LCDFont,
        roobert_24_medium_font: *pdapi.LCDFont,
    ) Renderer {
        return .{
            .playdate = playdate,
            .ui_regular_font = ui_regular_font,
            .ui_bold_font = ui_bold_font,
            .sasser_slab_font = sasser_slab_font,
            .asheville_sans_font = asheville_sans_font,
            .roobert_11_bold_font = roobert_11_bold_font,
            .roobert_20_medium_font = roobert_20_medium_font,
            .roobert_24_medium_font = roobert_24_medium_font,
            .theme = .light,
        };
    }

    pub fn beginFrame(self: *Renderer, theme: reader_coordinator.Theme, pages_font: reader_coordinator.ReadingFont, rsvp_font: reader_coordinator.ReadingFont) void {
        self.theme = theme;
        self.pages_font = pages_font;
        self.rsvp_font = rsvp_font;
        self.selectUiFont(false);
        self.playdate.graphics.setBackgroundColor(self.backgroundColor());
        self.playdate.graphics.setDrawMode(self.textDrawMode());
        self.playdate.graphics.clear(solidColor(self.backgroundColor()));
    }

    fn readingFont(self: *const Renderer, font: reader_coordinator.ReadingFont) *pdapi.LCDFont {
        return switch (font) {
            .newsleak_serif => self.ui_regular_font,
            .sasser_slab => self.sasser_slab_font,
            .asheville_sans_14_bold => self.asheville_sans_font,
            .roobert_11_bold => self.roobert_11_bold_font,
            .roobert_20_medium => self.roobert_20_medium_font,
            .roobert_24_medium => self.roobert_24_medium_font,
        };
    }

    fn selectUiFont(self: *Renderer, bold: bool) void {
        self.playdate.graphics.setFont(if (bold) self.ui_bold_font else self.ui_regular_font);
    }

    fn selectReadingFont(self: *Renderer, font: reader_coordinator.ReadingFont) void {
        self.playdate.graphics.setFont(self.readingFont(font));
    }

    pub fn readingTextWidth(self: *const Renderer, font: reader_coordinator.ReadingFont, value: []const u8) c_int {
        return @intCast(self.playdate.graphics.getTextWidth(self.readingFont(font), value.ptr, value.len, .UTF8Encoding, 0));
    }

    pub fn readingFontHeight(self: *const Renderer, font: reader_coordinator.ReadingFont) usize {
        return self.playdate.graphics.getFontHeight(self.readingFont(font));
    }

    pub fn draw(self: *Renderer, model: reader_coordinator.RenderModel) void {
        switch (model) {
            .library => |view| self.drawLibrary(view),
            .settings => |view| self.drawSettings(view),
            .statistics => |view| self.drawStatistics(view),
            .chapters => |view| self.drawChapters(view),
            .opening => self.emphasizedText("Opening EPUB...", 12, 12),
            .paged => |view| self.drawPage(view),
            .scroll => |view| self.drawScroll(view),
            .rsvp => |view| self.drawRsvp(view),
            .failure => |view| self.drawFailure(view),
        }
    }

    pub fn drawTelemetry(self: *Renderer, snapshot: TelemetrySnapshot, stats: AllocatorStats) void {
        var line_buffer: [96]u8 = undefined;
        const pipeline_line = std.fmt.bufPrintZ(
            &line_buffer,
            "z:{d} events:{d}",
            .{ snapshot.chapter_bytes_decoded, snapshot.chapter_events },
        ) catch return;
        self.text(pipeline_line, 20, 170);
        const timing_line = std.fmt.bufPrintZ(
            &line_buffer,
            "frame:{d}/{d} page:{d}/{d}",
            .{ snapshot.update_time_ms, snapshot.max_update_time_ms, snapshot.last_page_build_ms, snapshot.max_page_build_ms },
        ) catch return;
        self.text(timing_line, 20, 190);
        const allocation_line = std.fmt.bufPrintZ(
            &line_buffer,
            "live:{d} peak:{d} cache:{d}",
            .{ stats.live_bytes, stats.peak_live_bytes, reader_coordinator.reader_cache_reserved_bytes },
        ) catch return;
        self.text(allocation_line, 20, 210);
    }

    pub fn text(self: *Renderer, value: []const u8, x: c_int, y: c_int) void {
        self.selectUiFont(false);
        _ = self.playdate.graphics.drawText(value.ptr, value.len, .UTF8Encoding, x, y);
    }

    pub fn emphasizedText(self: *Renderer, value: []const u8, x: c_int, y: c_int) void {
        self.selectUiFont(true);
        _ = self.playdate.graphics.drawText(value.ptr, value.len, .UTF8Encoding, x, y);
    }

    pub fn readingText(self: *Renderer, font: reader_coordinator.ReadingFont, value: []const u8, x: c_int, y: c_int) void {
        self.selectReadingFont(font);
        _ = self.playdate.graphics.drawText(value.ptr, value.len, .UTF8Encoding, x, y);
    }

    pub fn uiFontHeight(self: *const Renderer) usize {
        return self.playdate.graphics.getFontHeight(self.ui_regular_font);
    }

    fn uiTextWidth(self: *const Renderer, value: []const u8, bold: bool) c_int {
        const font = if (bold) self.ui_bold_font else self.ui_regular_font;
        return @intCast(self.playdate.graphics.getTextWidth(font, value.ptr, value.len, .UTF8Encoding, 0));
    }

    fn rightAlignedUiText(self: *Renderer, value: []const u8, y: c_int, bold: bool) void {
        const x = @max(@as(c_int, 24), @as(c_int, @intCast(reader_layout.screen_width)) - 12 - self.uiTextWidth(value, bold));
        if (bold) self.emphasizedText(value, x, y) else self.text(value, x, y);
    }

    pub fn invertedReadingText(self: *Renderer, font: reader_coordinator.ReadingFont, value: []const u8, text_x: c_int, text_y: c_int, rect_x: c_int, rect_y: c_int, width: c_int, height: c_int) void {
        self.playdate.graphics.fillRect(rect_x, rect_y, width, height, solidColor(self.foregroundColor()));
        self.playdate.graphics.setDrawMode(switch (self.theme) {
            .light => .DrawModeInverted,
            .dark => .DrawModeCopy,
        });
        self.selectReadingFont(font);
        _ = self.playdate.graphics.drawText(value.ptr, value.len, .UTF8Encoding, text_x, text_y);
        self.playdate.graphics.setDrawMode(self.textDrawMode());
    }

    fn backgroundColor(self: *const Renderer) pdapi.LCDSolidColor {
        return if (self.theme == .dark) .ColorBlack else .ColorWhite;
    }

    fn foregroundColor(self: *const Renderer) pdapi.LCDSolidColor {
        return if (self.theme == .dark) .ColorWhite else .ColorBlack;
    }

    fn textDrawMode(self: *const Renderer) pdapi.LCDBitmapDrawMode {
        return if (self.theme == .dark) .DrawModeInverted else .DrawModeCopy;
    }

    fn drawLibrary(self: *Renderer, view: reader_coordinator.LibraryView) void {
        self.emphasizedText("EPUB library", 12, 12);
        if (view.count == 0) {
            self.text("Put .epub files in Data", 12, 40);
            return;
        }
        for (view.paths[0..view.count], 0..) |path, index| {
            const y: c_int = 40 + @as(c_int, @intCast(index)) * 20;
            self.text(if (index == view.selected) ">" else " ", 4, y);
            if (index == view.selected) self.emphasizedText(path, 18, y) else self.text(path, 18, y);
        }
        self.text("A: open", 12, 220);
    }

    fn drawSettings(self: *Renderer, view: reader_coordinator.SettingsView) void {
        self.emphasizedText("Settings", 12, 12);
        var buffer: [8]u8 = undefined;
        const row_advance = @max(reader_layout.lineAdvance(self.uiFontHeight()), 24);
        for (0..view.row_count) |visible_index| {
            const row: reader_coordinator.SettingsRow = @enumFromInt(view.first_visible + @as(u4, @intCast(visible_index)));
            const y: c_int = @intCast(36 + visible_index * row_advance);
            self.text(if (row == view.selected) ">" else " ", 6, y);
            const label = switch (row) {
                .reading_mode => "Reading mode",
                .paged_presentation => "Paged display",
                .rsvp_wpm => "RSVP WPM",
                .theme => "Theme",
                .pages_font => "Pages/Scroll font",
                .rsvp_font => "RSVP font",
                .progress_visibility => "Progress bar",
                .progress_position => "Progress position",
                .progress_scope => "Progress scope",
                .statistics => "Reading statistics",
                .reset_progress => "Reset progress",
            };
            if (row == view.selected) self.emphasizedText(label, 24, y) else self.text(label, 24, y);
            const value: []const u8 = switch (row) {
                .reading_mode => if (view.mode == .rsvp) "RSVP" else "Paged",
                .paged_presentation => if (view.paged_presentation == .scroll) "Scroll" else "Pages",
                .rsvp_wpm => std.fmt.bufPrint(&buffer, "{d}", .{view.wpm}) catch "",
                .theme => if (view.theme == .dark) "Dark" else "Light",
                .pages_font => fontName(view.pages_font),
                .rsvp_font => fontName(view.rsvp_font),
                .progress_visibility => if (view.progress_visibility == .on) "On" else "Off",
                .progress_position => if (view.progress_position == .bottom) "Bottom" else "Top",
                .progress_scope => switch (view.progress_scope) {
                    .chapter => "Chapter",
                    .book => "Book",
                    .both => "Both",
                },
                .statistics => "",
                .reset_progress => "Hold A 3s",
            };
            self.rightAlignedUiText(value, y, row == view.selected);
        }

        if (view.selected == .reset_progress and view.reset_hold_ms != 0) {
            const bar_x: c_int = 12;
            const bar_y: c_int = 191;
            const bar_width: c_int = 376;
            self.playdate.graphics.drawRect(bar_x, bar_y, bar_width, 7, solidColor(self.foregroundColor()));
            const progress: c_int = @intCast((@as(u32, view.reset_hold_ms) * @as(u32, @intCast(bar_width - 2))) / reader_coordinator.reset_hold_duration_ms);
            if (progress > 0) self.playdate.graphics.fillRect(bar_x + 1, bar_y + 1, progress, 5, solidColor(self.foregroundColor()));
        }
        self.text(if (view.selected == .reset_progress) "Hold A: reset   B: back" else "A: change   B: back", 12, 216);
    }

    fn drawStatistics(self: *Renderer, view: reader_coordinator.StatisticsView) void {
        self.emphasizedText("Reading statistics", 12, 12);
        const lines = [_][]const u8{
            view.chapter_progress.slice(),
            view.chapter_eta.slice(),
            view.book_progress.slice(),
            view.book_eta.slice(),
            view.pace.slice(),
            view.index.slice(),
        };
        const row_advance = @max(reader_layout.lineAdvance(self.uiFontHeight()), 25);
        for (lines, 0..) |line, index| {
            self.text(line, 12, @intCast(38 + index * row_advance));
        }
        self.text("B: back", 12, 216);
    }

    fn drawChapters(self: *Renderer, view: reader_coordinator.ChaptersView) void {
        var header_buffer: [32]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buffer, "Chapters {d}/{d}", .{ view.selected + 1, view.entries }) catch "Chapters";
        self.emphasizedText(header, 12, 12);
        var label_buffer: [160]u8 = undefined;
        for (view.rows[0..view.row_count], 0..) |row, row_index| {
            const row_advance: c_int = @intCast(@max(reader_layout.lineAdvance(self.uiFontHeight()), 20));
            const y: c_int = 36 + @as(c_int, @intCast(row_index)) * row_advance;
            self.text(if (row.selected) ">" else " ", 8, y);
            const label = chapter_browser.formatLabel(&label_buffer, row.index, row.label, row.path);
            if (row.selected) self.emphasizedText(label, 24, y) else self.text(label, 24, y);
        }
        self.text("B: back", 12, 220);
    }

    fn drawPage(self: *Renderer, view: reader_coordinator.PagedView) void {
        self.drawProgressRails(view.progress, view.progress_visibility, view.progress_position, view.progress_scope);
        if (view.line_count == 0) {
            self.text(if (view.reconstructing) "Restoring position..." else "Loading chapter...", 12, 12);
            return;
        }
        const font = self.pages_font;
        const font_height = self.readingFontHeight(font);
        const line_advance = reader_layout.lineAdvance(font_height);
        for (view.lines[0..view.line_count], 0..) |line, index| {
            const y = reader_layout.text_y + index * line_advance;
            self.readingText(font, line, @intCast(reader_layout.text_x), @intCast(y));
        }
        const span = view.selected_span orelse return;
        const line = view.lines[span.line_index];
        const x = reader_layout.text_x + @as(usize, @intCast(self.readingTextWidth(font, line[0..span.start])));
        const y = reader_layout.text_y + @as(usize, span.line_index) * line_advance;
        const word = line[span.start..span.end];
        const rect = reader_layout.highlightRect(x, y, @intCast(self.readingTextWidth(font, word)), font_height);
        self.invertedReadingText(font, word, @intCast(x), @intCast(y), @intCast(rect.x), @intCast(rect.y), @intCast(rect.width), @intCast(rect.height));
    }

    fn drawRsvp(self: *Renderer, view: reader_coordinator.RsvpView) void {
        self.drawProgressRails(view.progress, view.progress_visibility, view.progress_position, view.progress_scope);
        self.text(if (view.playing) "RSVP - playing" else "RSVP - paused", 12, 12);
        var buffer: [16]u8 = undefined;
        self.text(std.fmt.bufPrint(&buffer, "WPM: {d}", .{view.wpm}) catch "", 12, 36);
        const word = view.word orelse {
            self.text(if (view.reconstructing) "Rebuilding word..." else "Loading chapter...", 12, 76);
            return;
        };
        const font = self.rsvp_font;
        const geometry = reader_layout.rsvpGeometry(self.readingFontHeight(font));
        self.rule(0, geometry.guide_top_y, reader_layout.screen_width - 1, geometry.guide_top_y);
        self.rule(0, geometry.guide_bottom_y, reader_layout.screen_width - 1, geometry.guide_bottom_y);
        self.rule(reader_layout.rsvp_anchor_x, geometry.top_tick_start_y, reader_layout.rsvp_anchor_x, geometry.guide_top_y);
        self.rule(reader_layout.rsvp_anchor_x, geometry.guide_bottom_y, reader_layout.rsvp_anchor_x, geometry.bottom_tick_end_y);
        if (view.anchor) |anchor| {
            const prefix_width = self.readingTextWidth(font, word[0..anchor.start]);
            const anchor_width = self.readingTextWidth(font, word[0..anchor.end]) - prefix_width;
            const x = @as(c_int, @intCast(reader_layout.rsvp_anchor_x)) - prefix_width - @divTrunc(anchor_width, 2);
            self.readingText(font, word, x, @intCast(geometry.word_y));
        } else self.readingText(font, word, @intCast(reader_layout.text_x), @intCast(geometry.word_y));
        self.text("A: play  Up/Down: WPM", 12, 192);
        self.text("Left: sentence  B: Paged", 12, 216);
    }

    fn drawScroll(self: *Renderer, view: reader_coordinator.ScrollView) void {
        self.drawProgressRails(view.progress, view.progress_visibility, view.progress_position, view.progress_scope);
        const top: c_int = @intCast(reader_layout.text_y);
        const height: c_int = @intCast(reader_layout.screen_height - reader_layout.text_y - reader_layout.reserved_edge_rows);
        self.playdate.graphics.setClipRect(@intCast(reader_layout.text_x), top, @intCast(reader_layout.text_width), height);
        const font = self.pages_font;
        const font_height = self.readingFontHeight(font);
        const advance: i32 = @intCast(reader_layout.lineAdvance(font_height));
        for (view.window.tiles[0..view.window.tile_count]) |tile| switch (tile) {
            .page => |page| {
                for (0..page.cache.line_count) |line_index| {
                    const y: i32 = @as(i32, page.origin_y) + @as(i32, @intCast(line_index)) * advance;
                    self.readingText(font, page.cache.line(line_index), @intCast(reader_layout.text_x), @intCast(y));
                }
            },
            .loading_before, .loading_after, .unavailable_before, .unavailable_after => |origin_y| {
                const last_y: i32 = @intCast(reader_layout.screen_height - reader_layout.reserved_edge_rows - font_height);
                const y = std.math.clamp(@as(i32, origin_y), @as(i32, reader_layout.text_y), last_y);
                self.text("...", @intCast(reader_layout.text_x), @intCast(y));
            },
        };
        self.playdate.graphics.setClipRect(0, 0, @intCast(reader_layout.screen_width), @intCast(reader_layout.screen_height));
    }

    fn drawProgressRails(
        self: *Renderer,
        metrics: ?reader_coordinator.ProgressView,
        visibility: reader_coordinator.ProgressVisibility,
        position: reader_coordinator.ProgressPosition,
        scope: reader_coordinator.ProgressScope,
    ) void {
        const rails = progress_rail.layout(metrics, visibility, position, scope);
        if (rails.chapter) |rail| self.drawProgressRail(rail);
        if (rails.book) |rail| self.drawProgressRail(rail);
    }

    fn drawProgressRail(self: *Renderer, rail: progress_rail.Rail) void {
        if (rail.width == 0) return;
        self.playdate.graphics.fillRect(0, rail.y, rail.width, 1, solidColor(self.foregroundColor()));
    }

    fn rule(self: *Renderer, x1: usize, y1: usize, x2: usize, y2: usize) void {
        self.playdate.graphics.drawLine(@intCast(x1), @intCast(y1), @intCast(x2), @intCast(y2), 1, solidColor(self.foregroundColor()));
    }

    fn drawFailure(self: *Renderer, view: reader_coordinator.ErrorView) void {
        switch (view) {
            .unavailable => self.emphasizedText("EPUB unavailable", 12, 12),
            .invalid_archive => self.emphasizedText("Invalid EPUB archive", 12, 12),
            .missing_mimetype => self.emphasizedText("mimetype entry missing", 12, 12),
            .invalid_mimetype => self.emphasizedText("Invalid mimetype entry", 12, 12),
            .chapter => |chapter| {
                const reason: []const u8 = switch (chapter.reason) {
                    .archive => "ZIP or DEFLATE error",
                    .tokenizer => "XHTML tokenizer error",
                    .page_limit => "Page limit exceeded",
                    .no_supported_text => "No supported text",
                };
                self.emphasizedText("Chapter unavailable", 12, 12);
                self.text(reason, 12, 36);
                if (chapter.path) |path| self.text(path, 12, 60);
                self.text("Left/Right: another chapter", 12, 100);
            },
        }
    }
};

fn solidColor(color: pdapi.LCDSolidColor) pdapi.LCDColor {
    return @intCast(@intFromEnum(color));
}

fn fontName(font: reader_coordinator.ReadingFont) []const u8 {
    return switch (font) {
        .newsleak_serif => "Newsleak Serif",
        .sasser_slab => "Sasser Slab",
        .asheville_sans_14_bold => "Asheville Sans 14 Bold",
        .roobert_11_bold => "Roobert 11 Bold",
        .roobert_20_medium => "Roobert 20 Medium",
        .roobert_24_medium => "Roobert 24 Medium",
    };
}
