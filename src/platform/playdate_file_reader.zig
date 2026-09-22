const pdapi = @import("../playdate_api_definitions.zig");
const zip = @import("../archive/zip.zig");

pub const Error = error{
    OpenFailed,
    SeekFailed,
    TellFailed,
    FileTooLarge,
    ReadFailed,
};

/// Random-access adapter for an SDK-owned file handle. The caller owns this
/// value and must call close exactly once after all ZIP reads are complete.
pub const PlaydateFileReader = struct {
    file_api: *const pdapi.PlaydateFile,
    file: *pdapi.SDFile,
    size: u32,
    current_offset: u32,

    pub fn open(file_api: *const pdapi.PlaydateFile, path: [*:0]const u8) Error!PlaydateFileReader {
        const file = file_api.open(path, pdapi.FILE_READ | pdapi.FILE_READ_DATA) orelse return error.OpenFailed;
        errdefer _ = file_api.close(file);

        if (file_api.seek(file, 0, pdapi.SEEK_END) != 0) return error.SeekFailed;
        const end = file_api.tell(file);
        if (end < 0) return error.TellFailed;
        if (file_api.seek(file, 0, pdapi.SEEK_SET) != 0) return error.SeekFailed;

        return .{
            .file_api = file_api,
            .file = file,
            .size = @intCast(end),
            .current_offset = 0,
        };
    }

    pub fn close(self: *PlaydateFileReader) void {
        _ = self.file_api.close(self.file);
    }

    pub fn reader(self: *PlaydateFileReader) zip.Reader {
        return .{
            .context = self,
            .size = self.size,
            .read_at = readAt,
        };
    }

    fn readAt(context: *anyopaque, offset: u32, destination: []u8) zip.Error!void {
        const self: *PlaydateFileReader = @ptrCast(@alignCast(context));
        if (offset != self.current_offset) {
            if (self.file_api.seek(self.file, @intCast(offset), pdapi.SEEK_SET) != 0) return error.ReadFailed;
        }
        const bytes_read = self.file_api.read(self.file, destination.ptr, @intCast(destination.len));
        if (bytes_read < 0 or @as(usize, @intCast(bytes_read)) != destination.len) return error.UnexpectedEof;
        self.current_offset = offset + @as(u32, @intCast(destination.len));
    }
};
