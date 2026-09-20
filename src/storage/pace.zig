const std = @import("std");

pub const encoded_size = 16;
pub const minimum_words_for_estimate: u32 = 20;
pub const minimum_active_ms_for_estimate: u32 = 5_000;
pub const minimum_manual_sample_ms: u32 = 250;
pub const maximum_manual_sample_ms: u32 = 5 * 60 * 1_000;

/// A bounded per-book aggregate. `active_ms` deliberately uses u32 so it can
/// live in the Playdate-aligned App state; values saturate after roughly 49
/// days of actual autoplay, which is sufficient for a stable pace estimate.
pub const Stats = struct {
    book_id: u32,
    completed_words: u32 = 0,
    active_ms: u32 = 0,
};

/// Tracks only an active autoplay interval. Paused time is represented by a
/// null start and therefore cannot enter a pace aggregate accidentally.
pub const ActiveSession = struct {
    started_at_ms: ?u32 = null,

    pub fn begin(self: *ActiveSession, now_ms: u32) void {
        self.started_at_ms = now_ms;
    }

    pub fn record(self: *ActiveSession, stats: *Stats, now_ms: u32, completed_words: u32) void {
        const started_at = self.started_at_ms orelse return;
        addInterval(stats, now_ms -% started_at, completed_words);
        self.started_at_ms = null;
    }
};

pub const ManualAnchor = union(enum) {
    paged: struct { chapter: u8, page: u32 },
    rsvp: struct { chapter: u8, word: u32 },
};

/// Tracks a single visible manual-reading interval. Observing a different
/// anchor discards the unfinished interval, which makes reverse movement,
/// jumps, rebuilds, and mode changes safe by default.
pub const ManualSampler = struct {
    anchor: ?ManualAnchor = null,
    started_at_ms: ?u32 = null,

    pub fn observe(self: *ManualSampler, anchor: ManualAnchor, now_ms: u32) void {
        if (self.anchor) |current| {
            if (std.meta.eql(current, anchor)) return;
        }
        self.anchor = anchor;
        self.started_at_ms = now_ms;
    }

    pub fn discard(self: *ManualSampler) void {
        self.* = .{};
    }

    pub fn recordForward(self: *ManualSampler, stats: *Stats, anchor: ManualAnchor, now_ms: u32, completed_words: u32) bool {
        const current = self.anchor orelse return false;
        const started_at = self.started_at_ms orelse return false;
        self.discard();
        if (!std.meta.eql(current, anchor) or completed_words == 0) return false;
        const elapsed = now_ms -% started_at;
        if (elapsed < minimum_manual_sample_ms or elapsed > maximum_manual_sample_ms) return false;
        addInterval(stats, elapsed, completed_words);
        return true;
    }
};

pub const Error = error{InvalidRecord};

pub fn encode(stats: Stats, output: *[encoded_size]u8) void {
    output.* = .{ 'E', 'P', 'A', 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, output[4..8], stats.book_id, .little);
    std.mem.writeInt(u32, output[8..12], stats.completed_words, .little);
    std.mem.writeInt(u32, output[12..16], stats.active_ms, .little);
}

pub fn decode(input: *const [encoded_size]u8) Error!Stats {
    if (!std.mem.eql(u8, input[0..4], "EPA\x01")) return error.InvalidRecord;
    return .{
        .book_id = std.mem.readInt(u32, input[4..8], .little),
        .completed_words = std.mem.readInt(u32, input[8..12], .little),
        .active_ms = std.mem.readInt(u32, input[12..16], .little),
    };
}

pub fn addInterval(stats: *Stats, elapsed_ms: u32, completed_words: u32) void {
    stats.active_ms = std.math.add(u32, stats.active_ms, elapsed_ms) catch std.math.maxInt(u32);
    stats.completed_words = std.math.add(u32, stats.completed_words, completed_words) catch std.math.maxInt(u32);
}

pub fn hasEstimate(stats: Stats) bool {
    return stats.completed_words >= minimum_words_for_estimate and stats.active_ms >= minimum_active_ms_for_estimate;
}

/// Returns no estimate until enough observed autoplay exists. Callers supply
/// an independently obtained unread word count; this module never requires a
/// whole-book scan or text retention to derive pace.
pub fn estimateMilliseconds(stats: Stats, remaining_words: u32) ?u32 {
    if (!hasEstimate(stats)) return null;
    const milliseconds: u64 = @as(u64, stats.active_ms) * remaining_words / stats.completed_words;
    return @intCast(@min(milliseconds, std.math.maxInt(u32)));
}

test "round trips a per-book pace record" {
    var bytes: [encoded_size]u8 = undefined;
    encode(.{ .book_id = 7, .completed_words = 32, .active_ms = 8_000 }, &bytes);
    try std.testing.expectEqual(Stats{ .book_id = 7, .completed_words = 32, .active_ms = 8_000 }, try decode(&bytes));
}

test "paused time is excluded from active autoplay accounting" {
    var stats = Stats{ .book_id = 7 };
    var session = ActiveSession{};
    session.begin(100);
    session.record(&stats, 300, 1);
    // From 300 to 1,000 playback is paused: the session has no start time.
    session.record(&stats, 1_000, 99);
    session.begin(1_000);
    session.record(&stats, 1_200, 1);
    try std.testing.expectEqual(@as(u32, 400), stats.active_ms);
    try std.testing.expectEqual(@as(u32, 2), stats.completed_words);
}

test "remaining-time estimates require sufficient observed history" {
    var stats = Stats{ .book_id = 7, .completed_words = 19, .active_ms = 5_000 };
    try std.testing.expect(estimateMilliseconds(stats, 100) == null);
    stats.completed_words = 20;
    try std.testing.expectEqual(@as(?u32, 25_000), estimateMilliseconds(stats, 100));
}

test "manual sampling accepts plausible forward intervals and discards navigation and idle outliers" {
    var stats = Stats{ .book_id = 7 };
    var sampler = ManualSampler{};
    const first = ManualAnchor{ .paged = .{ .chapter = 0, .page = 0 } };

    sampler.observe(first, 100);
    try std.testing.expect(!sampler.recordForward(&stats, first, 349, 10));
    sampler.observe(first, 1_000);
    try std.testing.expect(sampler.recordForward(&stats, first, 1_250, 10));
    sampler.observe(first, 2_000);
    sampler.observe(.{ .paged = .{ .chapter = 0, .page = 1 } }, 2_100);
    try std.testing.expect(!sampler.recordForward(&stats, first, 2_500, 10));
    sampler.observe(first, 3_000);
    try std.testing.expect(!sampler.recordForward(&stats, first, 3_000 + maximum_manual_sample_ms + 1, 10));
    try std.testing.expectEqual(@as(u32, 10), stats.completed_words);
    try std.testing.expectEqual(@as(u32, 250), stats.active_ms);
}
