const std = @import("std");

/// Pure page-navigation state.  It deliberately knows nothing about ZIP,
/// DEFLATE, rendering, or cache storage: callers answer cache-hit/miss and
/// execute the resulting stream/rescan action.
pub const State = struct {
    page: u32 = 0,
    stream_front: u32 = 0,
    viewing_cached_history: bool = false,

    pub fn opened(self: *State, page: u32) void {
        self.* = .{ .page = page, .stream_front = page };
    }

    /// Records a normal forward stream page turn.
    pub fn advancedStream(self: *State) void {
        self.page += 1;
        self.stream_front = self.page;
        self.viewing_cached_history = false;
    }

    pub fn beginCachedBack(self: *State) ?u32 {
        if (self.page == 0) return null;
        if (!self.viewing_cached_history) self.stream_front = self.page;
        self.page -= 1;
        self.viewing_cached_history = true;
        return self.page;
    }

    /// Advances while browsing pages behind the parked forward stream. Returns
    /// the requested cache page, including the stream-front page that resumes
    /// normal streaming, or null when history browsing is not active.
    pub fn forwardFromCache(self: *State) ?u32 {
        if (!self.viewing_cached_history) return null;
        self.page += 1;
        if (self.page == self.stream_front) {
            self.viewing_cached_history = false;
        }
        return self.page;
    }

    pub fn beginRescan(self: *State, target: u32) void {
        self.page = target;
        self.stream_front = target;
        self.viewing_cached_history = false;
    }
};

test "cached back and forward rejoin the parked stream" {
    var navigation = State{};
    navigation.opened(0);
    navigation.advancedStream();
    navigation.advancedStream();
    try std.testing.expectEqual(@as(?u32, 1), navigation.beginCachedBack());
    try std.testing.expectEqual(@as(u32, 1), navigation.page);
    try std.testing.expectEqual(@as(?u32, 2), navigation.forwardFromCache());
    try std.testing.expectEqual(@as(u32, 2), navigation.page);
    try std.testing.expect(!navigation.viewing_cached_history);
}

test "multiple cached backs retain the original stream front" {
    var navigation = State{};
    navigation.opened(3);
    try std.testing.expectEqual(@as(?u32, 2), navigation.beginCachedBack());
    try std.testing.expectEqual(@as(?u32, 1), navigation.beginCachedBack());
    try std.testing.expectEqual(@as(u32, 3), navigation.stream_front);
    try std.testing.expectEqual(@as(?u32, 2), navigation.forwardFromCache());
    try std.testing.expectEqual(@as(?u32, 3), navigation.forwardFromCache());
}

test "rescan becomes the new stream front" {
    var navigation = State{};
    navigation.opened(7);
    navigation.beginRescan(3);
    try std.testing.expectEqual(@as(u32, 3), navigation.page);
    try std.testing.expectEqual(@as(u32, 3), navigation.stream_front);
    try std.testing.expect(!navigation.viewing_cached_history);
}
