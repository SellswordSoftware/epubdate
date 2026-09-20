const std = @import("std");
const chapter_browser = @import("../chapter_browser.zig");
const pdapi = @import("../playdate_api_definitions.zig");
const AllocatorStats = @import("playdate_allocator.zig").Stats;
const reader_coordinator = @import("../reader_coordinator.zig");
const reader_layout = @import("../reader_layout.zig");
const TelemetrySnapshot = @import("../telemetry.zig").Telemetry.Snapshot;

/// The only layer that translates reader drawing primitives into Playdate
/// graphics calls. Higher layers provide already-selected text and geometry.
pub const Renderer = struct {
    playdate: *pdapi.PlaydateAPI,
    body_font: *pdapi.LCDFont,

    pub fn init(playdate: *pdapi.PlaydateAPI, body_font: *pdapi.LCDFont) Renderer {
        return .{ .playdate = playdate, .body_font = body_font };
    }

    pub fn beginFrame(self: *Renderer) void {
        self.playdate.graphics.setFont(self.body_font);
        self.playdate.graphics.clear(@intCast(@intFromEnum(pdapi.LCDSolidColor.ColorWhite)));
    }

    pub fn draw(self: *Renderer, model: reader_coordinator.RenderModel) void {
        switch (model) {
            .library => |view| self.drawLibrary(view),
            .settings => |view| self.drawSettings(view),
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
        self.playdate.graphics.fillRect(rect_x, rect_y, width, height, @intCast(@intFromEnum(pdapi.LCDSolidColor.ColorBlack)));
        self.playdate.graphics.setDrawMode(.DrawModeInverted);
        self.text(value, text_x, text_y);
        self.playdate.graphics.setDrawMode(.DrawModeCopy);
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

    fn drawSettings(self: *Renderer, view: anytype) void {
        self.text("Settings", 12, 12);
        self.text(if (view.selected == 0) "> Reading mode" else "  Reading mode", 12, 52);
        self.text(switch (view.mode) {
            .paged => "Paged",
            .rsvp => "RSVP",
        }, 32, 76);
        self.text(if (view.selected == 1) "> RSVP WPM" else "  RSVP WPM", 12, 112);
        var buffer: [8]u8 = undefined;
        self.text(std.fmt.bufPrint(&buffer, "{d}", .{view.wpm}) catch "", 32, 136);
        self.text("A: change   B: back", 12, 220);
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
        if (view.line_count == 0) {
            self.text("Loading chapter...", 12, 12);
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
        self.text(if (view.playing) "RSVP - playing" else "RSVP - paused", 12, 12);
        var buffer: [16]u8 = undefined;
        self.text(std.fmt.bufPrint(&buffer, "WPM: {d}", .{view.wpm}) catch "", 12, 36);
        const word = view.word orelse {
            self.text(if (view.reconstructing) "Rebuilding word..." else "Loading chapter...", 12, 76);
            return;
        };
        if (view.anchor) |anchor| {
            const prefix_width = self.textWidth(word[0..anchor.start]);
            const anchor_width = self.textWidth(word[anchor.start..anchor.end]);
            self.text(word, 200 - prefix_width - @divTrunc(anchor_width, 2), 100);
        } else self.text(word, 12, 100);
        self.text("A: play  Up/Down: WPM", 12, 196);
        self.text("Left: sentence  B: Paged", 12, 220);
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
