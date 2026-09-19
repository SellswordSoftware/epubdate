const std = @import("std");

/// Development-only reader measurements. This contains no Playdate handles;
/// App remains responsible solely for drawing a snapshot when enabled.
pub const Telemetry = struct {
    enabled: bool = false,
    frame_count: u32 = 0,
    update_time_ms: u32 = 0,
    max_update_time_ms: u32 = 0,
    chapter_bytes_decoded: u32 = 0,
    chapter_events: u32 = 0,
    page_build_started_ms: u32 = 0,
    last_page_build_ms: u32 = 0,
    max_page_build_ms: u32 = 0,

    pub const Snapshot = struct {
        chapter_bytes_decoded: u32,
        chapter_events: u32,
        last_page_build_ms: u32,
        max_page_build_ms: u32,
    };

    pub fn frameFinished(self: *Telemetry, started_at_ms: u32, now_ms: u32) void {
        self.update_time_ms = now_ms -% started_at_ms;
        self.max_update_time_ms = @max(self.max_update_time_ms, self.update_time_ms);
        self.frame_count +%= 1;
    }

    pub fn chapterStarted(self: *Telemetry, now_ms: u32) void {
        self.chapter_bytes_decoded = 0;
        self.chapter_events = 0;
        self.page_build_started_ms = now_ms;
    }

    pub fn decodedBytes(self: *Telemetry, count: usize) void {
        self.chapter_bytes_decoded +%= @intCast(count);
    }

    pub fn setChapterEvents(self: *Telemetry, count: u32) void {
        self.chapter_events = count;
    }

    pub fn pageCompleted(self: *Telemetry, now_ms: u32) void {
        self.last_page_build_ms = now_ms -% self.page_build_started_ms;
        self.max_page_build_ms = @max(self.max_page_build_ms, self.last_page_build_ms);
        self.page_build_started_ms = now_ms;
    }

    pub fn snapshot(self: *const Telemetry) Snapshot {
        return .{
            .chapter_bytes_decoded = self.chapter_bytes_decoded,
            .chapter_events = self.chapter_events,
            .last_page_build_ms = self.last_page_build_ms,
            .max_page_build_ms = self.max_page_build_ms,
        };
    }
};

test "telemetry resets chapter data and retains frame and page high water marks" {
    var telemetry = Telemetry{};
    telemetry.frameFinished(100, 112);
    telemetry.frameFinished(200, 218);
    telemetry.chapterStarted(300);
    telemetry.decodedBytes(10);
    telemetry.setChapterEvents(4);
    telemetry.pageCompleted(325);
    telemetry.pageCompleted(340);
    const snapshot = telemetry.snapshot();
    try std.testing.expectEqual(@as(u32, 18), telemetry.max_update_time_ms);
    try std.testing.expectEqual(@as(u32, 25), snapshot.max_page_build_ms);
    try std.testing.expectEqual(@as(u32, 10), snapshot.chapter_bytes_decoded);
    try std.testing.expectEqual(@as(u32, 4), snapshot.chapter_events);
}
