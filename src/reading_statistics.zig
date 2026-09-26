const std = @import("std");
const pace = @import("storage/pace.zig");
const progress = @import("storage/progress.zig");
const progress_indexer = @import("progress_indexer.zig");

pub const sheet_enter_ms: u16 = 220;
pub const sheet_exit_ms: u16 = 160;
pub const SheetPhase = enum { entering, exiting };

/// Returns the remaining downward displacement for a cubic ease-out entrance.
pub fn sheetDisplacement(elapsed_ms: u16, travel: u16) u16 {
    if (elapsed_ms >= sheet_enter_ms) return 0;
    const remaining: u32 = sheet_enter_ms - elapsed_ms;
    const duration: u32 = sheet_enter_ms;
    return @intCast(@as(u32, travel) * remaining * remaining * remaining / (duration * duration * duration));
}

/// Returns an increasing downward displacement for a cubic ease-in exit.
pub fn sheetExitDisplacement(elapsed_ms: u16, travel: u16) u16 {
    if (elapsed_ms >= sheet_exit_ms) return travel;
    const elapsed: u32 = elapsed_ms;
    const duration: u32 = sheet_exit_ms;
    return @intCast(@as(u32, travel) * elapsed * elapsed * elapsed / (duration * duration * duration));
}

pub const Text = struct {
    bytes: [64]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }

    fn set(self: *Text, comptime template: []const u8, args: anytype) void {
        const rendered = std.fmt.bufPrint(&self.bytes, template, args) catch {
            const fallback = "Statistics unavailable";
            @memcpy(self.bytes[0..fallback.len], fallback);
            self.len = fallback.len;
            return;
        };
        self.len = @intCast(rendered.len);
    }
};

pub const View = struct {
    chapter_progress: Text,
    chapter_eta: Text,
    book_progress: Text,
    book_eta: Text,
    pace: Text,
    index: Text,
};

pub fn format(metrics: ?progress.View, learned_pace: pace.Stats, status: progress_indexer.Status, chapter_count: u8) View {
    var view: View = undefined;
    formatMetric("Chapter", if (metrics) |value| value.chapter else null, learned_pace, &view.chapter_progress, &view.chapter_eta);
    formatMetric("Book", if (metrics) |value| value.book else null, learned_pace, &view.book_progress, &view.book_eta);
    formatPace(learned_pace, &view.pace);
    formatIndex(metrics, status, chapter_count, &view.index);
    return view;
}

fn formatMetric(label: []const u8, metric: ?progress.Metric, learned_pace: pace.Stats, summary: *Text, eta: *Text) void {
    const value = metric orelse {
        summary.set("{s}: unavailable", .{label});
        eta.set("{s} left: unavailable", .{label});
        return;
    };
    switch (value) {
        .pending => {
            summary.set("{s}: indexing", .{label});
            eta.set("{s} left: indexing", .{label});
        },
        .unavailable => {
            summary.set("{s}: unavailable", .{label});
            eta.set("{s} left: unavailable", .{label});
        },
        .exact => |fraction| {
            const reached = wideToU64(fraction.reached);
            const total = wideToU64(fraction.total);
            const remaining = wideToU64(fraction.remaining);
            if (total == 0) {
                summary.set("{s}: empty (0 words)", .{label});
                eta.set("{s} left: none", .{label});
                return;
            }
            const percent = @min(@as(u64, 100), reached * 100 / total);
            summary.set("{s}: {d}/{d} words ({d}%)", .{ label, reached, total, percent });
            if (remaining == 0) {
                eta.set("{s} left: complete", .{label});
            } else if (estimateMilliseconds(learned_pace, remaining)) |milliseconds| {
                formatEta(label, milliseconds, eta);
            } else {
                eta.set("{s} left: learning pace", .{label});
            }
        },
    }
}

fn formatPace(learned_pace: pace.Stats, output: *Text) void {
    if (!pace.hasEstimate(learned_pace)) {
        output.set("Pace: learning (more samples needed)", .{});
        return;
    }
    const words_per_minute = @as(u64, learned_pace.completed_words) * 60_000 / learned_pace.active_ms;
    output.set("Pace: {d} wpm", .{words_per_minute});
}

fn formatIndex(metrics: ?progress.View, status: progress_indexer.Status, chapter_count: u8, output: *Text) void {
    if (metrics) |value| {
        if (value.chapter == .unavailable or value.book == .unavailable) {
            output.set("Index: failed ({d}/{d} chapters)", .{ status.indexed_chapters, chapter_count });
            return;
        }
        if (value.chapter == .exact and value.book == .exact) {
            output.set("Index: complete ({d}/{d} chapters)", .{ chapter_count, chapter_count });
            return;
        }
    }
    switch (status.phase) {
        .complete => output.set("Index: complete ({d}/{d} chapters)", .{ status.indexed_chapters, chapter_count }),
        .failed => output.set("Index: failed ({d}/{d} chapters)", .{ status.indexed_chapters, chapter_count }),
        .retryable_failure => output.set("Index: paused by I/O ({d}/{d})", .{ status.indexed_chapters, chapter_count }),
        .idle => output.set("Index: unavailable", .{}),
        else => output.set("Index: indexing ({d}/{d} chapters)", .{ status.indexed_chapters, chapter_count }),
    }
}

fn estimateMilliseconds(learned_pace: pace.Stats, remaining_words: u64) ?u64 {
    if (!pace.hasEstimate(learned_pace)) return null;
    const completed = learned_pace.completed_words;
    const active = learned_pace.active_ms;
    const whole = std.math.mul(u64, remaining_words / completed, active) catch std.math.maxInt(u64);
    const partial = (remaining_words % completed) * active / completed;
    return std.math.add(u64, whole, partial) catch std.math.maxInt(u64);
}

fn formatEta(label: []const u8, milliseconds: u64, output: *Text) void {
    const minutes = milliseconds / 60_000 + @intFromBool(milliseconds % 60_000 != 0);
    if (minutes < 60) {
        output.set("{s} left: {d} min", .{ label, @max(minutes, 1) });
        return;
    }
    const hours = minutes / 60;
    if (hours < 24) {
        output.set("{s} left: {d}h {d}m", .{ label, hours, minutes % 60 });
        return;
    }
    const days = hours / 24;
    if (days >= 1000) {
        output.set("{s} left: 1000+ days", .{label});
        return;
    }
    output.set("{s} left: {d}d {d}h", .{ label, days, hours % 24 });
}

fn wideToU64(value: progress.WideCount) u64 {
    return (@as(u64, value.hi) << 32) | value.lo;
}

test "statistics formatting distinguishes exact pending failed empty learning and long estimates" {
    const status = progress_indexer.Status{
        .phase = .complete,
        .current_chapter = 0,
        .target_chapter = null,
        .indexed_chapters = 2,
        .decoded_last_update = 0,
        .last_failure = null,
        .dirty = false,
    };
    const exact = progress.View{
        .chapter = .{ .exact = .{
            .reached = progress.WideCount.fromU32(25),
            .total = progress.WideCount.fromU32(100),
            .remaining = progress.WideCount.fromU32(75),
        } },
        .book = .{ .exact = .{
            .reached = progress.WideCount.fromU32(100),
            .total = progress.WideCount.fromU32(400),
            .remaining = progress.WideCount.fromU32(300),
        } },
    };
    var view = format(exact, .{ .book_id = 1 }, status, 2);
    try std.testing.expectEqualStrings("Chapter: 25/100 words (25%)", view.chapter_progress.slice());
    try std.testing.expectEqualStrings("Chapter left: learning pace", view.chapter_eta.slice());
    try std.testing.expectEqualStrings("Index: complete (2/2 chapters)", view.index.slice());

    const edge_cases = progress.View{
        .chapter = .{ .exact = .{ .reached = .{}, .total = .{}, .remaining = .{} } },
        .book = .{ .exact = .{
            .reached = .{},
            .total = progress.WideCount.fromU32(std.math.maxInt(u32)),
            .remaining = progress.WideCount.fromU32(std.math.maxInt(u32)),
        } },
    };
    view = format(edge_cases, .{ .book_id = 1, .completed_words = 20, .active_ms = 5_000 }, status, 2);
    try std.testing.expectEqualStrings("Chapter: empty (0 words)", view.chapter_progress.slice());
    try std.testing.expectEqualStrings("Book left: 1000+ days", view.book_eta.slice());

    const unavailable = progress.View{ .chapter = .pending, .book = .unavailable };
    view = format(unavailable, .{ .book_id = 1 }, status, 2);
    try std.testing.expectEqualStrings("Chapter: indexing", view.chapter_progress.slice());
    try std.testing.expectEqualStrings("Book: unavailable", view.book_progress.slice());
    try std.testing.expectEqualStrings("Index: failed (2/2 chapters)", view.index.slice());
}

test "statistics sheet eases from fully hidden to its resting position" {
    try std.testing.expectEqual(@as(u16, 204), sheetDisplacement(0, 204));
    try std.testing.expect(sheetDisplacement(sheet_enter_ms / 2, 204) < 102);
    try std.testing.expectEqual(@as(u16, 0), sheetDisplacement(sheet_enter_ms, 204));

    try std.testing.expectEqual(@as(u16, 0), sheetExitDisplacement(0, 204));
    try std.testing.expect(sheetExitDisplacement(sheet_exit_ms / 2, 204) < 102);
    try std.testing.expectEqual(@as(u16, 204), sheetExitDisplacement(sheet_exit_ms, 204));
}
