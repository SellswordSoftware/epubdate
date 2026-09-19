const std = @import("std");
const pdapi = @import("../playdate_api_definitions.zig");
const persistence = @import("../storage/persistence.zig");

/// Adapts the SDK's handle-based file API to the persistence service's small,
/// whole-record port. Record names and bytes stay in the storage layer.
pub fn fileStore(file_api: *const pdapi.PlaydateFile) persistence.FileStore {
    return .{
        .context = @ptrCast(@constCast(file_api)),
        .read = read,
        .write = write,
    };
}

fn read(context: *anyopaque, name: []const u8, output: []u8) bool {
    const file_api: *const pdapi.PlaydateFile = @ptrCast(@alignCast(context));
    var filename_buffer: [32]u8 = undefined;
    const filename = std.fmt.bufPrintZ(&filename_buffer, "{s}", .{name}) catch return false;
    const file = file_api.open(filename.ptr, pdapi.FILE_READ | pdapi.FILE_READ_DATA) orelse return false;
    defer _ = file_api.close(file);
    return file_api.read(file, output.ptr, @intCast(output.len)) == @as(c_int, @intCast(output.len));
}

fn write(context: *anyopaque, name: []const u8, input: []const u8) bool {
    const file_api: *const pdapi.PlaydateFile = @ptrCast(@alignCast(context));
    var filename_buffer: [32]u8 = undefined;
    const filename = std.fmt.bufPrintZ(&filename_buffer, "{s}", .{name}) catch return false;
    const file = file_api.open(filename.ptr, pdapi.FILE_WRITE) orelse return false;
    defer _ = file_api.close(file);
    if (file_api.write(file, input.ptr, @intCast(input.len)) != @as(c_int, @intCast(input.len))) return false;
    return file_api.flush(file) == 0;
}
