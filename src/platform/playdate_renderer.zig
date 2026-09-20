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
    roobert_font: *pdapi.LCDFont,
    newsleak_serif_font: *pdapi.LCDFont,
    asheville_sans_font: *pdapi.LCDFont,
    body_font: *pdapi.LCDFont,
    theme: reader_coordinator.Theme,

    pub fn init(playdate: *pdapi.PlaydateAPI, roobert_font: *pdapi.LCDFont, newsleak_serif_font: *pdapi.LCDFont, asheville_sans_font: *pdapi.LCDFont) Renderer {
        return .{
            .playdate = playdate,
            .roobert_font = roobert_font,
            .newsleak_serif_font = newsleak_serif_font,
            .asheville_sans_font = asheville_sans_font,
            .body_font = roobert_font,
            .theme = .light,
        };
    }

    pub fn beginFrame(self: *Renderer, theme: reader_coordinator.Theme, font: reader_coordinator.Font) void {
        self.theme = theme;
        self.selectFont(font);
        self.playdate.graphics.setFont(self.body_font);
        self.playdate.graphics.setBackgroundColor(self.backgroundColor());
        self.playdate.graphics.setDrawMode(self.textDrawMode());
        self.playdate.graphics.clear(solidColor(self.backgroundColor()));
    }

    pub fn selectFont(self: *Renderer, font: reader_coordinator.Font) void {
        self.body_font = switch (font) {
            .roobert => self.roobert_font,
            .newsleak_serif => self.newsleak_serif_font,
            .asheville_sans => self.asheville_sans_font,
        };
    }

    pub fn draw(self: *Renderer, model: reader_coordinator.RenderModel) void {
        switch (model) {
            .library => |view| self.drawLibrary(view),
            .settings => |view| self.drawSettings(view),
            .statistics => |view| self.drawStatistics(view),
            .chapters => |view| self.drawChapters(view),
            .opening => self.text("Opening EPUB...", 12, 12),
            .paged => |view| self.drawPage(view),
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

    pub fn text(self: *const Renderer, value: []const u8, x: c_int, y: c_int) void {
        _ = self.playdate.graphics.drawText(value.ptr, value.len, .UTF8Encoding, x, y);
    }

    pub fn textWidth(self: *const Renderer, value: []const u8) c_int {
        return @intCast(self.playdate.graphics.getTextWidth(self.body_font, value.ptr, value.len, .UTF8Encoding, 0));
    }

    pub fn fontHeight(self: *const Renderer) usize {
        return self.playdate.graphics.getFontHeight(self.body_font);
    }

    pub fn invertedText(self: *Renderer, value: []const u8, text_x: c_int, text_y: c_int, rect_x: c_int, rect_y: c_int, width: c_int, height: c_int) void {
        self.playdate.graphics.fillRect(rect_x, rect_y, width, height, solidColor(self.foregroundColor()));
        self.playdate.graphics.setDrawMode(switch (self.theme) {
            .light => .DrawModeInverted,
            .dark => .DrawModeCopy,
        });
        self.text(value, text_x, text_y);
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
        self.text("EPUB library", 12, 12);
        if (view.count == 0) {
            self.text("Put .epub files in Data", 12, 40);
            return;
        }
        for (view.paths[0..view.count], 0..) |path, index| {
            const y: c_int = 40 + @as(c_int, @intCast(index)) * 20;
            self.text(if (index == view.selected) ">" else " ", 4, y);
            self.text(path, 18, y);
        }
        self.text("A: open", 12, 220);
    }

    fn drawSettings(self: *Renderer, view: reader_coordinator.SettingsView) void {
        self.text("Settings", 12, 12);
        var buffer: [8]u8 = undefined;
        const row_advance = @max(reader_layout.lineAdvance(self.fontHeight()), 24);
        for (0..view.row_count) |visible_index| {
            const row: reader_coordinator.SettingsRow = @enumFromInt(view.first_visible + @as(u4, @intCast(visible_index)));
            const y: c_int = @intCast(36 + visible_index * row_advance);
            self.text(if (row == view.selected) ">" else " ", 6, y);
            self.text(switch (row) {
                .reading_mode => "Reading mode",
                .rsvp_wpm => "RSVP WPM",
                .theme => "Theme",
                .font => "Font",
                .progress_visibility => "Progress bar",
                .progress_position => "Progress position",
                .progress_scope => "Progress scope",
                .statistics => "Reading statistics",
                .reset_progress => "Reset progress",
            }, 24, y);
            const value: []const u8 = switch (row) {
                .reading_mode => if (view.mode == .rsvp) "RSVP" else "Paged",
                .rsvp_wpm => std.fmt.bufPrint(&buffer, "{d}", .{view.wpm}) catch "",
                .theme => if (view.theme == .dark) "Dark" else "Light",
                .font => switch (view.font) {
                    .roobert => "Roobert",
                    .newsleak_serif => "Newsleak Serif",
                    .asheville_sans => "Asheville Sans",
                },
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
            self.text(value, 250, y);
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
        self.text("Reading statistics", 12, 12);
        const lines = [_][]const u8{
            view.chapter_progress.slice(),
            view.chapter_eta.slice(),
            view.book_progress.slice(),
            view.book_eta.slice(),
            view.pace.slice(),
            view.index.slice(),
        };
        const row_advance = @max(reader_layout.lineAdvance(self.fontHeight()), 25);
        for (lines, 0..) |line, index| {
            self.text(line, 12, @intCast(38 + index * row_advance));
        }
        self.text("B: back", 12, 216);
    }

    fn drawChapters(self: *Renderer, view: reader_coordinator.ChaptersView) void {
        var header_buffer: [32]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buffer, "Chapters {d}/{d}", .{ view.selected + 1, view.entries }) catch "Chapters";
        self.text(header, 12, 12);
        var label_buffer: [160]u8 = undefined;
        for (view.rows[0..view.row_count], 0..) |row, row_index| {
            const y: c_int = 36 + @as(c_int, @intCast(row_index)) * 18;
            self.text(if (row.selected) ">" else " ", 8, y);
            self.text(chapter_browser.formatLabel(&label_buffer, row.index, row.label, row.path), 24, y);
        }
        self.text("B: back", 12, 220);
    }

    fn drawPage(self: *Renderer, view: reader_coordinator.PagedView) void {
        self.drawProgressRails(view.progress, view.progress_visibility, view.progress_position, view.progress_scope);
        if (view.line_count == 0) {
            self.text(if (view.reconstructing) "Restoring position..." else "Loading chapter...", 12, 12);
            return;
        }
        const font_height = self.fontHeight();
        const line_advance = reader_layout.lineAdvance(font_height);
        for (view.lines[0..view.line_count], 0..) |line, index| {
            const y = reader_layout.text_y + index * line_advance;
            self.text(line, @intCast(reader_layout.text_x), @intCast(y));
        }
        const span = view.selected_span orelse return;
        const line = view.lines[span.line_index];
        const x = reader_layout.text_x + @as(usize, @intCast(self.textWidth(line[0..span.start])));
        const y = reader_layout.text_y + @as(usize, span.line_index) * line_advance;
        const word = line[span.start..span.end];
        const rect = reader_layout.highlightRect(x, y, @intCast(self.textWidth(word)), font_height);
        self.invertedText(word, @intCast(x), @intCast(y), @intCast(rect.x), @intCast(rect.y), @intCast(rect.width), @intCast(rect.height));
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
        const geometry = reader_layout.rsvpGeometry(self.fontHeight());
        self.rule(0, geometry.guide_top_y, reader_layout.screen_width - 1, geometry.guide_top_y);
        self.rule(0, geometry.guide_bottom_y, reader_layout.screen_width - 1, geometry.guide_bottom_y);
        self.rule(reader_layout.rsvp_anchor_x, geometry.top_tick_start_y, reader_layout.rsvp_anchor_x, geometry.guide_top_y);
        self.rule(reader_layout.rsvp_anchor_x, geometry.guide_bottom_y, reader_layout.rsvp_anchor_x, geometry.bottom_tick_end_y);
        if (view.anchor) |anchor| {
            const prefix_width = self.textWidth(word[0..anchor.start]);
            const anchor_width = self.textWidth(word[0..anchor.end]) - prefix_width;
            const x = @as(c_int, @intCast(reader_layout.rsvp_anchor_x)) - prefix_width - @divTrunc(anchor_width, 2);
            self.text(word, x, @intCast(geometry.word_y));
        } else self.text(word, @intCast(reader_layout.text_x), @intCast(geometry.word_y));
        self.text("A: play  Up/Down: WPM", 12, 192);
        self.text("Left: sentence  B: Paged", 12, 216);
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
            .unavailable => self.text("EPUB unavailable", 12, 12),
            .invalid_archive => self.text("Invalid EPUB archive", 12, 12),
            .missing_mimetype => self.text("mimetype entry missing", 12, 12),
            .invalid_mimetype => self.text("Invalid mimetype entry", 12, 12),
            .chapter => |chapter| {
                const reason: []const u8 = switch (chapter.reason) {
                    .archive => "ZIP or DEFLATE error",
                    .tokenizer => "XHTML tokenizer error",
                    .page_limit => "Page limit exceeded",
                    .no_supported_text => "No supported text",
                };
                self.text("Chapter unavailable", 12, 12);
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
