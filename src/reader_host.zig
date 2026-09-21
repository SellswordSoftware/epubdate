const zip = @import("archive/zip.zig");
const library_storage = @import("storage/library.zig");
const settings = @import("storage/settings.zig");

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
    /// New platform adapters must provide these callbacks. The legacy fields
    /// remain as a host-test and adapter compatibility fallback until reading
    /// font persistence is split into its two independent settings.
    width_for_font: ?*const fn (context: *anyopaque, font: settings.ReadingFont, text: []const u8) usize = null,
    font_height_for_font: ?*const fn (context: *anyopaque, font: settings.ReadingFont) usize = null,
};

/// The only platform capabilities available to reader orchestration. It holds
/// callbacks and opaque contexts, never Playdate API types.
pub const ReaderHost = struct {
    files: ?Files = null,
    measure: TextMeasure,
};
