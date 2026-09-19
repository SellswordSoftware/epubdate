const std = @import("std");

/// Owns the single reusable DEFLATE backing workspace.  It models ownership
/// rather than storage so the caller can keep the large buffers in its
/// heap-owned state while making concurrent active/prefetch decoding
/// impossible to represent.
pub const DecodeWorkspace = struct {
    pub const Owner = enum { none, active, prefetch };
    pub const Acquire = enum { acquired, busy, active_not_at_eof };

    owner: Owner = .none,
    active_verified_eof: bool = false,

    pub fn beginActive(self: *DecodeWorkspace) Acquire {
        if (self.owner != .none) return .busy;
        self.owner = .active;
        self.active_verified_eof = false;
        return .acquired;
    }

    /// Only a fully consumed and CRC-validated active entry may yield its
    /// backing buffers to prefetch.  A partial page is not enough.
    pub fn markActiveVerifiedEof(self: *DecodeWorkspace) void {
        std.debug.assert(self.owner == .active);
        self.active_verified_eof = true;
    }

    pub fn beginPrefetch(self: *DecodeWorkspace) Acquire {
        if (self.owner == .prefetch) return .busy;
        if (self.owner != .active or !self.active_verified_eof) return .active_not_at_eof;
        self.owner = .prefetch;
        self.active_verified_eof = false;
        return .acquired;
    }

    /// A ready prefetch becomes the next active stream without ever exposing
    /// an unowned interval in which another decoder could start.
    pub fn activatePrefetch(self: *DecodeWorkspace) void {
        std.debug.assert(self.owner == .prefetch);
        self.owner = .active;
        self.active_verified_eof = false;
    }

    pub fn release(self: *DecodeWorkspace, expected: Owner) void {
        std.debug.assert(self.owner == expected);
        self.owner = .none;
        self.active_verified_eof = false;
    }
};

test "prefetch cannot lease active decode storage before verified EOF" {
    var workspace = DecodeWorkspace{};
    try std.testing.expectEqual(DecodeWorkspace.Acquire.acquired, workspace.beginActive());
    try std.testing.expectEqual(DecodeWorkspace.Acquire.active_not_at_eof, workspace.beginPrefetch());
    workspace.markActiveVerifiedEof();
    try std.testing.expectEqual(DecodeWorkspace.Acquire.acquired, workspace.beginPrefetch());
    try std.testing.expectEqual(DecodeWorkspace.Owner.prefetch, workspace.owner);
}

test "activation transfers the only lease and cancellation releases it" {
    var workspace = DecodeWorkspace{};
    _ = workspace.beginActive();
    workspace.markActiveVerifiedEof();
    _ = workspace.beginPrefetch();
    workspace.activatePrefetch();
    try std.testing.expectEqual(DecodeWorkspace.Owner.active, workspace.owner);
    try std.testing.expectEqual(DecodeWorkspace.Acquire.busy, workspace.beginActive());
    workspace.release(.active);
    try std.testing.expectEqual(DecodeWorkspace.Acquire.acquired, workspace.beginActive());
}
