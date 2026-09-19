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
    /// the requested cache page, or null when the caller may resume streaming.
    pub fn forwardFromCache(self: *State) ?u32 {
        if (!self.viewing_cached_history) return null;
        self.page += 1;
        if (self.page == self.stream_front) {
            self.viewing_cached_history = false;
            return null;
        }
        return self.page;
    }

    pub fn beginRescan(self: *State, target: u32) void {
        self.page = target;
        self.stream_front = target;
        self.viewing_cached_history = false;
    }
};

/// The shared history slot has a different meaning while browsing backward:
/// normally it holds the immediately previous page, but during cached-history
/// navigation it holds the page immediately ahead of the current page.
pub fn canRestoreSharedPage(current_page: u32, requested_page: u32, browsing_cached_history: bool) bool {
    return if (browsing_cached_history)
        requested_page == current_page + 1
    else
        current_page != 0 and requested_page + 1 == current_page;
}

test "cached back and forward rejoin the parked stream" {
    var navigation = State{};
    navigation.opened(0);
    navigation.advancedStream();
    navigation.advancedStream();
    try std.testing.expectEqual(@as(?u32, 1), navigation.beginCachedBack());
    try std.testing.expectEqual(@as(u32, 1), navigation.page);
    try std.testing.expectEqual(@as(?u32, null), navigation.forwardFromCache());
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
    try std.testing.expectEqual(@as(?u32, null), navigation.forwardFromCache());
}

test "rescan becomes the new stream front" {
    var navigation = State{};
    navigation.opened(7);
    navigation.beginRescan(3);
    try std.testing.expectEqual(@as(u32, 3), navigation.page);
    try std.testing.expectEqual(@as(u32, 3), navigation.stream_front);
    try std.testing.expect(!navigation.viewing_cached_history);
}

test "shared history does not mistake a forward page for a second backward page" {
    // After p → p-1, the sole history slot holds p. A request for p-2 must
    // miss and schedule a rescan instead of swapping p back onto the screen.
    try std.testing.expect(!canRestoreSharedPage(4, 3, true));
    try std.testing.expect(canRestoreSharedPage(4, 5, true));
    try std.testing.expect(canRestoreSharedPage(4, 3, false));
}
