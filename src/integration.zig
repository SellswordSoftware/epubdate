const std = @import("std");
const deflate = @import("archive/deflate.zig");
const zip = @import("archive/zip.zig");
const xhtml = @import("content/xhtml.zig");
const pagination = @import("content/pagination.zig");
const epub = @import("publication/epub.zig");
const publication_navigation = @import("publication/navigation.zig");

const FixtureReader = struct {
    io: std.Io,
    file: std.Io.File,
    size: u32,

    fn reader(self: *FixtureReader) zip.Reader {
        return .{
            .context = self,
            .size = self.size,
            .read_at = readAt,
        };
    }

    fn readAt(context: *anyopaque, offset: u32, destination: []u8) zip.Error!void {
        const self: *FixtureReader = @ptrCast(@alignCast(context));
        const count = self.file.readPositionalAll(self.io, destination, offset) catch return error.ReadFailed;
        if (count != destination.len) return error.UnexpectedEof;
    }
};

fn validateDirectory(archive: zip.Archive) !void {
    var ranges: [epub.max_manifest_items]zip.MemberRange = undefined;
    var filename: [256]u8 = undefined;
    var validator = try zip.DirectoryValidator.init(archive, &ranges);
    while (!try validator.step(&filename)) {}
}

fn readEntry(allocator: std.mem.Allocator, archive: zip.Archive, name: []const u8) ![]u8 {
    var filename: [256]u8 = undefined;
    const entry = try archive.find(name, &filename);
    var result = try allocator.alloc(u8, entry.uncompressed_size);
    errdefer allocator.free(result);

    var compressed_input: [1024]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = zip.StreamStorage.init(&compressed_input, &window, &workspace);
    var stream = try archive.begin(entry, &storage);
    var chunk: [257]u8 = undefined;
    var len: usize = 0;
    while (true) {
        switch (try stream.read(&chunk)) {
            .bytes => |count| {
                if (count > result.len - len) return error.TestUnexpectedResult;
                @memcpy(result[len .. len + count], chunk[0..count]);
                len += count;
            },
            .end => break,
            .needs_input => return error.TestUnexpectedResult,
        }
    }
    try stream.finish();
    if (len != result.len) return error.TestUnexpectedResult;
    return result;
}

const PageSink = struct {
    builder: *pagination.EventPageBuilder,

    fn emit(context: *anyopaque, event: xhtml.Event) !void {
        const self: *PageSink = @ptrCast(@alignCast(context));
        try self.builder.consume(event);
    }
};

fn monospaceWidth(_: *anyopaque, text: []const u8) usize {
    return text.len;
}

/// Streams the entire ZIP member through the XHTML tokenizer while retaining
/// only one page. After that page is filled, the remaining bytes are drained
/// solely to assert the ZIP output count and CRC are valid.
fn renderFirstPage(archive: zip.Archive, name: []const u8, cache: *pagination.PageCache) !void {
    var filename: [256]u8 = undefined;
    const entry = try archive.find(name, &filename);
    var compressed_input: [1024]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: deflate.Workspace = undefined;
    var storage = zip.StreamStorage.init(&compressed_input, &window, &workspace);
    var stream = try archive.begin(entry, &storage);

    var measure_context: u8 = 0;
    var builder = pagination.EventPageBuilder.init(cache, 64, .{ .context = &measure_context, .width = monospaceWidth });
    var sink = PageSink{ .builder = &builder };
    var extractor = xhtml.StreamExtractor.init(.{ .context = &sink, .emit = PageSink.emit });
    var output: [257]u8 = undefined;
    var page_full = false;

    while (true) {
        switch (try stream.read(&output)) {
            .bytes => |count| {
                if (page_full) continue;
                const progress = try extractor.feed(output[0..count]);
                if (progress == .page_full) page_full = true;
            },
            .end => break,
            .needs_input => return error.TestUnexpectedResult,
        }
    }
    try stream.finish();
    if (!page_full) {
        try extractor.finish();
        builder.end() catch |err| switch (err) {
            error.PageFull => {},
            else => return err,
        };
    }
}

fn pageContains(cache: *const pagination.PageCache, needle: []const u8) bool {
    for (0..cache.line_count) |index| {
        if (std.mem.indexOf(u8, cache.line(index), needle) != null) return true;
    }
    return false;
}

test "bundled EPUB traverses archive, publication, streamed pages, and first chapter transition" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try std.Io.Dir.cwd().openFile(io, "assets/images/book.epub", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    var source = FixtureReader{ .io = io, .file = file, .size = @intCast(stat.size) };
    var scan_buffer: [1024]u8 = undefined;
    const archive = try zip.Archive.open(source.reader(), &scan_buffer);
    try validateDirectory(archive);

    const allocator = std.testing.allocator;
    const mimetype = try readEntry(allocator, archive, "mimetype");
    defer allocator.free(mimetype);
    try std.testing.expectEqualStrings("application/epub+zip", mimetype);

    const container = try readEntry(allocator, archive, "META-INF/container.xml");
    defer allocator.free(container);
    var package_path: [256]u8 = undefined;
    const opf_path = try epub.parseContainer(container, &package_path);
    try std.testing.expectEqualStrings("OEBPS/content.opf", opf_path);

    const opf = try readEntry(allocator, archive, opf_path);
    defer allocator.free(opf);
    var publication: epub.Publication = undefined;
    var workspace: epub.OpfWorkspace = undefined;
    try epub.parseOpf(opf, opf_path, &publication, &workspace);
    try std.testing.expectEqualStrings("Crime and Punishment", publication.titleSlice());
    try std.testing.expect(publication.spine_len > 2);
    try std.testing.expectEqualStrings("OEBPS/wrap0000.xhtml", publication.spine[0].slice());
    try std.testing.expectEqualStrings("OEBPS/753786768251737877_2554-h-0.htm.xhtml", publication.spine[1].slice());
    try std.testing.expectEqualStrings("OEBPS/753786768251737877_2554-h-1.htm.xhtml", publication.spine[2].slice());

    const navigation_document = try readEntry(allocator, archive, publication.navigation_document.slice());
    defer allocator.free(navigation_document);
    var navigation_parser = publication_navigation.Parser.init(&publication, publication.navigation_document.slice());
    var navigation_offset: usize = 0;
    while (navigation_offset < navigation_document.len) {
        const end = @min(navigation_document.len, navigation_offset + 257);
        try navigation_parser.feed(navigation_document[navigation_offset..end]);
        navigation_offset = end;
    }
    try navigation_parser.finish();
    try std.testing.expectEqualStrings("TRANSLATOR’S PREFACE", publication.chapter_labels[2].slice());

    var header_page = pagination.PageCache{};
    try renderFirstPage(archive, publication.spine[1].slice(), &header_page);
    try std.testing.expect(header_page.line_count != 0);
    try std.testing.expect(pageContains(&header_page, "Project Gutenberg"));

    var next_page = pagination.PageCache{};
    try renderFirstPage(archive, publication.spine[2].slice(), &next_page);
    try std.testing.expect(next_page.line_count != 0);
    try std.testing.expect(pageContains(&next_page, "TRANSLATOR"));
}
