const zip = @import("archive/zip.zig");
const library_storage = @import("storage/library.zig");

pub const Library = library_storage.Library;

/// Stable file leases belong to the platform adapter. The coordinator refers
/// to them by role and receives only a platform-neutral ZIP reader.
pub const FileSlot = enum { opening, chapter, prefetch, progress };
pub const FileError = error{OpenFailed};

pub const Files = struct {
    context: *anyopaque,
    open: *const fn (context: *anyopaque, slot: FileSlot, path: [:0]const u8) FileError!zip.Reader,
    close: *const fn (context: *anyopaque, slot: FileSlot) void,
    list_epubs: *const fn (context: *anyopaque, library: *Library) void,
};

pub const TextMeasure = struct {
    context: *anyopaque,
    width: *const fn (context: *anyopaque, text: []const u8) usize,
    font_height: ?*const fn (context: *anyopaque) usize = null,
};

/// The only platform capabilities available to reader orchestration. It holds
/// callbacks and opaque contexts, never Playdate API types.
pub const ReaderHost = struct {
    files: ?Files = null,
    measure: TextMeasure,
};
