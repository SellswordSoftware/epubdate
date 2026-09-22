const std = @import("std");
const chapter_browser = @import("../chapter_browser.zig");
const pagination = @import("../content/pagination.zig");
const pdapi = @import("../playdate_api_definitions.zig");
const AllocatorStats = @import("playdate_allocator.zig").Stats;
const reader_coordinator = @import("../reader_coordinator.zig");
const reader_layout = @import("../reader_layout.zig");
const progress_rail = @import("../progress_rail.zig");
const page_transition = @import("../page_transition.zig");
const TelemetrySnapshot = @import("../telemetry.zig").Telemetry.Snapshot;

/// The only layer that translates reader drawing primitives into Playdate
/// graphics calls. Higher layers provide already-selected text and geometry.
pub const Renderer = struct {
    playdate: *pdapi.PlaydateAPI,
    ui_regular_font: *pdapi.LCDFont,
    ui_bold_font: *pdapi.LCDFont,
    sasser_slab_font: *pdapi.LCDFont,
    asheville_sans_font: *pdapi.LCDFont,
    espy_serif_3_font: *pdapi.LCDFont,
    espy_serif_4_font: *pdapi.LCDFont,
    espy_sans_5_font: *pdapi.LCDFont,
    literata_36pt_medium_30_font: *pdapi.LCDFont,
    roobert_11_bold_font: *pdapi.LCDFont,
    roobert_20_medium_font: *pdapi.LCDFont,
    roobert_24_medium_font: *pdapi.LCDFont,
    pages_font: reader_coordinator.ReadingFont = .newsleak_serif,
    rsvp_font: reader_coordinator.ReadingFont = .roobert_20_medium,
    theme: reader_coordinator.Theme,
    library_marquee_hash: u32 = 0,
    library_marquee_len: usize = 0,
    library_marquee_width: c_int = 0,
    library_marquee_frame: u16 = 0,

    pub fn init(
        playdate: *pdapi.PlaydateAPI,
        ui_regular_font: *pdapi.LCDFont,
        ui_bold_font: *pdapi.LCDFont,
        sasser_slab_font: *pdapi.LCDFont,
        asheville_sans_font: *pdapi.LCDFont,
        espy_serif_3_font: *pdapi.LCDFont,
        espy_serif_4_font: *pdapi.LCDFont,
        espy_sans_5_font: *pdapi.LCDFont,
        literata_36pt_medium_30_font: *pdapi.LCDFont,
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
            .espy_serif_3_font = espy_serif_3_font,
            .espy_serif_4_font = espy_serif_4_font,
            .espy_sans_5_font = espy_sans_5_font,
            .literata_36pt_medium_30_font = literata_36pt_medium_30_font,
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
            .espy_serif_3 => self.espy_serif_3_font,
            .espy_serif_4 => self.espy_serif_4_font,
            .espy_sans_5 => self.espy_sans_5_font,
            .literata_36pt_medium_30 => self.literata_36pt_medium_30_font,
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

    pub fn draw(self: *Renderer, model: reader_coordinator.RenderModel, allocator_stats: AllocatorStats) void {
        switch (model) {
            .library => |view| self.drawLibrary(view),
            .settings => |view| self.drawSettings(view),
            .statistics => |view| self.drawStatistics(view),
            .chapters => |view| self.drawChapters(view),
            .opening => self.emphasizedText("Opening EPUB...", 12, 12),
            .paged => |view| self.drawPage(view),
            .scroll => |view| self.drawScroll(view),
            .rsvp => |view| self.drawRsvp(view),
            .failure => |view| self.drawFailure(view, allocator_stats),
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

    fn filledTextDrawMode(self: *const Renderer) pdapi.LCDBitmapDrawMode {
        return if (self.theme == .dark) .DrawModeCopy else .DrawModeInverted;
    }

    fn drawLibrary(self: *Renderer, view: reader_coordinator.LibraryView) void {
        self.emphasizedText("Readr Library", 12, 12);
        self.playdate.graphics.fillRect(0, 35, @intCast(reader_layout.screen_width), 1, solidColor(self.foregroundColor()));
        self.playdate.graphics.setDrawMode(.DrawModeCopy);
        self.playdate.graphics.fillRect(0, 36, @intCast(reader_layout.screen_width), @intCast(reader_layout.screen_height - 36), self.libraryBodyPatternColor());
        self.playdate.graphics.setDrawMode(self.textDrawMode());
        if (view.count == 0) {
            self.text("Put books in Data", 12, 45);
            return;
        }
        const visible_rows = reader_coordinator.library_visible_rows;
        const first: usize = view.first_visible;
        const end = @min(@as(usize, view.count), first + visible_rows);
        for (first..end) |index| {
            const y: c_int = 43 + @as(c_int, @intCast(index - first)) * 32;
            self.drawLibraryItem(view.paths[index], view.progress[index], index == view.selected, y);
        }
        self.drawRoundedScrollbar(394, 43, 4, 187, first, visible_rows, @intCast(view.count));
    }

    fn drawLibraryItem(self: *Renderer, title: []const u8, progress: ?u8, selected: bool, y: c_int) void {
        const x: c_int = 12;
        const width: c_int = @intCast(reader_layout.screen_width - 24);
        const height: c_int = 27;
        const inset: c_int = 12;
        const inner_width = width - 2;
        const fill_width: c_int = if (progress) |value| @divTrunc(inner_width * @as(c_int, value), 100) else 0;
        const border_width: c_int = if (selected) 2 else 1;

        self.playdate.graphics.fillRoundRect(x, y, width, height, 5, solidColor(self.backgroundColor()));
        if (fill_width == inner_width) {
            self.playdate.graphics.fillRoundRect(x + 1, y + 1, inner_width, height - 2, 4, solidColor(self.foregroundColor()));
        } else if (fill_width > 0) {
            self.playdate.graphics.fillRect(x + 1, y + 1, fill_width, height - 2, solidColor(self.foregroundColor()));
        }
        self.playdate.graphics.drawRoundRect(x, y, width, height, 5, border_width, solidColor(self.foregroundColor()));

        const title_x = x + inset;
        const right = x + width - inset;
        const text_y = y + 5;
        const bold = selected;
        var title_buffer: [128]u8 = undefined;
        if (progress) |value| {
            var percent_buffer: [4]u8 = undefined;
            const percent = std.fmt.bufPrint(&percent_buffer, "{d}%", .{value}) catch return;
            const percent_x = right - self.uiTextWidth(percent, bold);
            const title_width = percent_x - title_x - inset;
            self.drawLibraryTitle(title, &title_buffer, title_x, text_y, bold, selected, title_width, x, y, fill_width, height);
            self.drawLibraryLabel(percent, percent_x, text_y, bold, percent_x, right - percent_x, x, y, fill_width, height);
        } else {
            self.drawLibraryTitle(title, &title_buffer, title_x, text_y, bold, selected, right - title_x, x, y, fill_width, height);
        }
    }

    fn drawLibraryTitle(self: *Renderer, title: []const u8, buffer: []u8, text_x: c_int, text_y: c_int, bold: bool, selected: bool, width: c_int, item_x: c_int, item_y: c_int, fill_width: c_int, item_height: c_int) void {
        if (width <= 0) return;
        const displayed = if (selected) title else self.truncatedLibraryTitle(title, width, bold, buffer);
        const marquee_offset = if (selected) self.libraryMarqueeOffset(title, width, bold) else 0;
        self.drawLibraryLabel(displayed, text_x - marquee_offset, text_y, bold, text_x, width, item_x, item_y, fill_width, item_height);
    }

    fn truncatedLibraryTitle(self: *const Renderer, title: []const u8, width: c_int, bold: bool, buffer: []u8) []const u8 {
        if (self.uiTextWidth(title, bold) <= width) return title;
        const ellipsis = "...";
        const limit = @min(title.len, buffer.len - ellipsis.len);
        var end: usize = 0;
        while (end < limit) {
            const next = nextUtf8Boundary(title, end, limit);
            if (self.uiTextWidth(title[0..next], bold) + self.uiTextWidth(ellipsis, bold) > width) break;
            end = next;
        }
        @memcpy(buffer[0..end], title[0..end]);
        @memcpy(buffer[end .. end + ellipsis.len], ellipsis);
        return buffer[0 .. end + ellipsis.len];
    }

    fn libraryMarqueeOffset(self: *Renderer, title: []const u8, width: c_int, bold: bool) c_int {
        const distance = self.uiTextWidth(title, bold) - width;
        if (distance <= 0) {
            self.library_marquee_frame = 0;
            return 0;
        }
        const hash = libraryTitleHash(title);
        if (self.library_marquee_hash != hash or self.library_marquee_len != title.len or self.library_marquee_width != width) {
            self.library_marquee_hash = hash;
            self.library_marquee_len = title.len;
            self.library_marquee_width = width;
            self.library_marquee_frame = 0;
        }
        const pause_frames: u16 = 18;
        const travel_frames: u16 = @intCast(@divTrunc(distance + 1, 2));
        const cycle = pause_frames * 2 + travel_frames * 2;
        const phase = self.library_marquee_frame % cycle;
        self.library_marquee_frame +%= 1;
        if (phase < pause_frames) return 0;
        if (phase < pause_frames + travel_frames) return @min(distance, @as(c_int, phase - pause_frames) * 2);
        if (phase < pause_frames * 2 + travel_frames) return distance;
        return @max(@as(c_int, 0), distance - @as(c_int, phase - (pause_frames * 2 + travel_frames)) * 2);
    }

    fn drawLibraryLabel(self: *Renderer, value: []const u8, text_x: c_int, text_y: c_int, bold: bool, clip_x: c_int, clip_width: c_int, item_x: c_int, item_y: c_int, fill_width: c_int, item_height: c_int) void {
        if (clip_width <= 0) return;
        const clip_y = item_y + 1;
        const clip_height = item_height - 2;
        self.playdate.graphics.setClipRect(clip_x, clip_y, clip_width, clip_height);
        self.drawUiLabel(value, text_x, text_y, bold);

        const fill_left = item_x + 1;
        const fill_right = fill_left + fill_width;
        const overlap_left = @max(clip_x, fill_left);
        const overlap_right = @min(clip_x + clip_width, fill_right);
        if (overlap_right > overlap_left) {
            self.playdate.graphics.setClipRect(overlap_left, clip_y, overlap_right - overlap_left, clip_height);
            self.playdate.graphics.setDrawMode(self.filledTextDrawMode());
            self.drawUiLabel(value, text_x, text_y, bold);
        }
        self.playdate.graphics.setDrawMode(self.textDrawMode());
        self.playdate.graphics.setClipRect(0, 0, @intCast(reader_layout.screen_width), @intCast(reader_layout.screen_height));
    }

    fn drawUiLabel(self: *Renderer, value: []const u8, x: c_int, y: c_int, bold: bool) void {
        self.selectUiFont(bold);
        _ = self.playdate.graphics.drawText(value.ptr, value.len, .UTF8Encoding, x, y);
    }

    fn libraryBodyPatternColor(self: *const Renderer) pdapi.LCDColor {
        return patternColor(if (self.theme == .dark) &library_body_pattern_dark else &library_body_pattern_light);
    }

    fn drawSettings(self: *Renderer, view: reader_coordinator.SettingsView) void {
        self.emphasizedText("Settings", 12, 12);
        const row_advance = @max(reader_layout.lineAdvance(self.uiFontHeight()), 24);
        for (0..view.row_count) |visible_index| {
            const row: reader_coordinator.SettingsRow = @enumFromInt(view.first_visible + @as(u4, @intCast(visible_index)));
            const y: c_int = @intCast(36 + visible_index * row_advance);
            self.text(if (row == view.selected) ">" else " ", 6, y);
            const label = switch (row) {
                .paged_presentation => "Progression",
                .theme => "Theme",
                .pages_font => "Pages/Scroll font",
                .rsvp_font => "RSVP font",
                .progress_visibility => "Progress bar",
                .progress_position => "Progress position",
                .progress_scope => "Progress scope",
                .reset_progress => "Reset progress",
            };
            if (row == view.selected) self.emphasizedText(label, 24, y) else self.text(label, 24, y);
            const value: []const u8 = switch (row) {
                .paged_presentation => if (view.paged_presentation == .scroll) "Scroll" else "Pages",
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
                .reset_progress => "Hold A 3s",
            };
            self.rightAlignedUiText(value, y, row == view.selected);
        }
        self.drawSettingsScrollbar(view);

        if (view.selected == .reset_progress and view.reset_hold_ms != 0) {
            const bar_x: c_int = 12;
            const bar_y: c_int = 203;
            const bar_width: c_int = 376;
            self.playdate.graphics.drawRect(bar_x, bar_y, bar_width, 7, solidColor(self.foregroundColor()));
            const progress: c_int = @intCast((@as(u32, view.reset_hold_ms) * @as(u32, @intCast(bar_width - 2))) / reader_coordinator.reset_hold_duration_ms);
            if (progress > 0) self.playdate.graphics.fillRect(bar_x + 1, bar_y + 1, progress, 5, solidColor(self.foregroundColor()));
        }
        self.text(if (view.selected == .reset_progress) "Hold A: reset   B: back" else "A: change   B: back", 12, 216);
    }

    fn drawSettingsScrollbar(self: *Renderer, view: reader_coordinator.SettingsView) void {
        self.drawRoundedScrollbar(394, 35, 4, 167, @intCast(view.first_visible), @intCast(view.row_count), @intCast(view.total_rows));
    }

    fn drawRoundedScrollbar(self: *Renderer, track_x: c_int, track_y: c_int, track_width: c_int, track_height: c_int, first_visible: usize, visible_rows: usize, total_rows: usize) void {
        if (total_rows <= visible_rows) return;
        const inner_height = track_height - 2;
        const thumb_height = @max(@as(c_int, 8), @divTrunc(inner_height * @as(c_int, @intCast(visible_rows)), @as(c_int, @intCast(total_rows))));
        const max_first: c_int = @intCast(total_rows - visible_rows);
        const thumb_y = track_y + 1 + @divTrunc((inner_height - thumb_height) * @as(c_int, @intCast(first_visible)), max_first);

        self.playdate.graphics.drawRoundRect(track_x, track_y, track_width, track_height, 2, 1, solidColor(self.foregroundColor()));
        self.playdate.graphics.fillRoundRect(track_x + 1, thumb_y, track_width - 2, thumb_height, 1, solidColor(self.foregroundColor()));
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
        self.drawRoundedScrollbar(394, 35, 4, 167, view.first_visible, chapter_browser.visible_rows, view.entries);
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
        if (view.transition) |transition| {
            self.drawPageTransition(view, transition, font, line_advance);
            return;
        }
        self.drawPageLines(&view.lines, view.line_count, font, line_advance, 0);
        const span = view.selected_span orelse return;
        const line = view.lines[span.line_index];
        const x = reader_layout.text_x + @as(usize, @intCast(self.readingTextWidth(font, line[0..span.start])));
        const y = reader_layout.text_y + @as(usize, span.line_index) * line_advance;
        const word = line[span.start..span.end];
        const rect = reader_layout.highlightRect(x, y, @intCast(self.readingTextWidth(font, word)), font_height);
        self.invertedReadingText(font, word, @intCast(x), @intCast(y), @intCast(rect.x), @intCast(rect.y), @intCast(rect.width), @intCast(rect.height));
    }

    fn drawPageTransition(self: *Renderer, view: reader_coordinator.PagedView, transition: reader_coordinator.PageTransitionView, font: reader_coordinator.ReadingFont, line_advance: usize) void {
        const screen_width: c_int = @intCast(reader_layout.screen_width);
        const band_height: c_int = @intCast(reader_layout.screen_height / page_transition.band_count);
        for (0..page_transition.band_count) |band_index| {
            const band: u8 = @intCast(band_index);
            const offset: c_int = @intCast(page_transition.bandOffset(transition.elapsed_ms, band, transition.direction, @intCast(reader_layout.screen_width)));
            const y = @as(c_int, @intCast(band_index)) * band_height;
            self.playdate.graphics.setClipRect(0, y, screen_width, band_height);
            const outgoing_x = switch (transition.direction) {
                .forward => -offset,
                .backward => offset,
            };
            const incoming_x = switch (transition.direction) {
                .forward => screen_width - offset,
                .backward => -screen_width + offset,
            };
            self.drawPageLines(&transition.lines, transition.line_count, font, line_advance, outgoing_x);
            self.drawPageLines(&view.lines, view.line_count, font, line_advance, incoming_x);
        }
        self.playdate.graphics.clearClipRect();
    }

    fn drawPageLines(self: *Renderer, lines: *const [pagination.max_lines][]const u8, line_count: u8, font: reader_coordinator.ReadingFont, line_advance: usize, x_offset: c_int) void {
        for (lines.*[0..line_count], 0..) |line, index| {
            const y = reader_layout.text_y + index * line_advance;
            self.readingText(font, line, @as(c_int, @intCast(reader_layout.text_x)) + x_offset, @intCast(y));
        }
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

    fn drawFailure(self: *Renderer, view: reader_coordinator.ErrorView, allocator_stats: AllocatorStats) void {
        switch (view) {
            .unavailable => self.emphasizedText("EPUB unavailable", 12, 12),
            .invalid_archive => |detail| self.drawOpeningFailure(detail, allocator_stats),
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
        if (view != .chapter) self.text("B: library", 12, 216);
    }

    fn drawOpeningFailure(self: *Renderer, detail: reader_coordinator.OpeningFailure, allocator_stats: AllocatorStats) void {
        self.emphasizedText("EPUB opening failed", 12, 12);
        var buffer: [96]u8 = undefined;
        switch (detail) {
            .opening_allocation => |bytes| self.drawAllocationFailure("Opening state allocation", bytes, allocator_stats, &buffer),
            .archive_initialization => |err| self.drawOpeningError("Archive initialization", err, &buffer),
            .archive_scan => |failure| {
                self.drawOpeningError("Archive scan", failure.cause, &buffer);
                const size_line = std.fmt.bufPrint(&buffer, "File size: {d} bytes", .{failure.file_size}) catch return;
                self.text(size_line, 12, 90);
                const tail_line = std.fmt.bufPrint(&buffer, "Tail: {X:0>2} {X:0>2} {X:0>2} {X:0>2}", .{
                    failure.tail_signature[0],
                    failure.tail_signature[1],
                    failure.tail_signature[2],
                    failure.tail_signature[3],
                }) catch return;
                self.text(tail_line, 12, 114);
                if (failure.nonzero_through) |offset| {
                    const readable_line = std.fmt.bufPrint(&buffer, "Non-zero through: {d}", .{offset}) catch return;
                    self.text(readable_line, 12, 138);
                }
                if (failure.zero_from) |offset| {
                    const zero_line = std.fmt.bufPrint(&buffer, "Zero from: {d}", .{offset}) catch return;
                    self.text(zero_line, 12, 162);
                }
            },
            .directory_validation => |err| self.drawOpeningError("Directory validation", err, &buffer),
            .directory_index => self.text("Stage: directory index", 12, 42),
            .container_lookup => |err| self.drawOpeningError("Container lookup", err, &buffer),
            .container_stream => |err| self.drawOpeningError("Container stream", err, &buffer),
            .container_read => |err| self.drawOpeningError("Container read", err, &buffer),
            .container_buffer => self.text("Stage: container buffer", 12, 42),
            .container_finish => |err| self.drawOpeningError("Container checksum", err, &buffer),
            .container_parse => |err| self.drawOpeningError("Container parse", err, &buffer),
            .package_lookup => |err| self.drawOpeningError("OPF lookup", err, &buffer),
            .package_size => |bytes| {
                const line = std.fmt.bufPrint(&buffer, "Stage: OPF size ({d} bytes)", .{bytes}) catch return;
                self.text(line, 12, 42);
                self.text("Cause: outside supported range", 12, 66);
            },
            .package_allocation => |bytes| self.drawAllocationFailure("OPF allocation", bytes, allocator_stats, &buffer),
            .package_stream => |err| self.drawOpeningError("OPF stream", err, &buffer),
            .package_read => |err| self.drawOpeningError("OPF read/inflate", err, &buffer),
            .package_buffer => self.text("Stage: OPF buffer", 12, 42),
            .package_finish => |err| self.drawOpeningError("OPF checksum", err, &buffer),
            .package_parse => |err| self.drawOpeningError("OPF parse", err, &buffer),
        }
    }

    fn drawOpeningError(self: *Renderer, stage: []const u8, err: anyerror, buffer: *[96]u8) void {
        const stage_line = std.fmt.bufPrint(buffer, "Stage: {s}", .{stage}) catch return;
        self.text(stage_line, 12, 42);
        const cause_line = std.fmt.bufPrint(buffer, "Cause: {s}", .{@errorName(err)}) catch return;
        self.text(cause_line, 12, 66);
    }

    fn drawAllocationFailure(self: *Renderer, stage: []const u8, requested: usize, stats: AllocatorStats, buffer: *[96]u8) void {
        const stage_line = std.fmt.bufPrint(buffer, "Stage: {s}", .{stage}) catch return;
        self.text(stage_line, 12, 42);
        const request_line = std.fmt.bufPrint(buffer, "Requested: {d} bytes", .{requested}) catch return;
        self.text(request_line, 12, 66);
        const memory_line = std.fmt.bufPrint(buffer, "Live: {d}  Peak: {d}", .{ stats.live_bytes, stats.peak_live_bytes }) catch return;
        self.text(memory_line, 12, 90);
    }
};

fn solidColor(color: pdapi.LCDSolidColor) pdapi.LCDColor {
    return @intCast(@intFromEnum(color));
}

const library_body_pattern_light = pdapi.LCDPattern{
    0b11111111,
    0b00000000,
    0b11111111,
    0b00000000,
    0b11111111,
    0b00000000,
    0b11111111,
    0b00000000,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
};

const library_body_pattern_dark = pdapi.LCDPattern{
    0b11111111,
    0b00000000,
    0b11111111,
    0b00000000,
    0b11111111,
    0b00000000,
    0b11111111,
    0b00000000,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
};

fn patternColor(pattern: *const pdapi.LCDPattern) pdapi.LCDColor {
    return @intFromPtr(pattern);
}

fn nextUtf8Boundary(value: []const u8, start: usize, limit: usize) usize {
    var next = start + 1;
    while (next < limit and value[next] & 0xc0 == 0x80) : (next += 1) {}
    return next;
}

fn libraryTitleHash(title: []const u8) u32 {
    var hash: u32 = 2_166_136_261;
    for (title) |byte| hash = (hash ^ byte) *% 16_777_619;
    return hash;
}

fn fontName(font: reader_coordinator.ReadingFont) []const u8 {
    return switch (font) {
        .newsleak_serif => "Newsleak Serif",
        .sasser_slab => "Sasser Slab",
        .asheville_sans_14_bold => "Asheville Sans 14 Bold",
        .roobert_11_bold => "Roobert 11 Bold",
        .roobert_20_medium => "Roobert 20 Medium",
        .roobert_24_medium => "Roobert 24 Medium",
        .espy_serif_3 => "Espy Serif 3",
        .espy_serif_4 => "Espy Serif 4",
        .espy_sans_5 => "Espy Sans 5",
        .literata_36pt_medium_30 => "Literata 30 Medium",
    };
}
