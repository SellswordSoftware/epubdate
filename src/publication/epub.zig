const std = @import("std");
const limits = @import("limits").reader;

pub const Error = error{ MalformedXml, CapacityExceeded, MissingManifestItem };

pub const max_manifest_items = limits.max_archive_entries;
pub const max_spine_items = limits.max_archive_entries;
/// A browser row has room for a short human label. Keep every label bounded so
/// publication metadata stays independent of the size of an EPUB TOC.
pub const max_chapter_label_bytes = 48;
/// Metadata is a bounded exception to the streamed chapter path. Keep these
/// limits visible at the publication boundary and free the OPF buffer after
/// parsing rather than reserving it for the reader's entire lifetime.
pub const max_container_document_bytes = limits.max_container_document_bytes;
pub const max_package_document_bytes = limits.max_package_document_bytes;

pub const SpineEntry = struct {
    path: [128]u8 = undefined,
    path_len: u8 = 0,

    pub fn slice(self: *const SpineEntry) []const u8 {
        return self.path[0..self.path_len];
    }
};

pub const ChapterLabel = struct {
    bytes: [max_chapter_label_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const ChapterLabel) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// The parsed OPF retains only resolved archive paths. A zero-length path
/// means that source was absent or unusable, which is a recoverable metadata
/// condition rather than a book-opening error.
pub const NavigationSource = struct {
    path: [128]u8 = undefined,
    path_len: u8 = 0,

    pub fn slice(self: *const NavigationSource) []const u8 {
        return self.path[0..self.path_len];
    }
};

const ManifestItem = struct {
    id: [64]u8 = undefined,
    id_len: u8 = 0,
    href: [128]u8 = undefined,
    href_len: u8 = 0,
    is_readable: bool = false,
    is_navigation_document: bool = false,
};

pub const Publication = struct {
    title: [128]u8 = undefined,
    title_len: u8 = 0,
    spine: [max_spine_items]SpineEntry = undefined,
    spine_len: u8 = 0,
    chapter_labels: [max_spine_items]ChapterLabel = undefined,
    navigation_document: NavigationSource = .{},
    ncx_document: NavigationSource = .{},

    pub fn titleSlice(self: *const Publication) []const u8 {
        return self.title[0..self.title_len];
    }
};

/// Parser-only state. It resolves OPF `itemref` values into persistent spine
/// paths, then the caller releases it with the OPF XML buffer.
pub const OpfWorkspace = struct {
    manifest: [max_manifest_items]ManifestItem = undefined,
    manifest_len: u8 = 0,
};

test "persistent publication excludes transient OPF manifest storage" {
    try std.testing.expect(@sizeOf(Publication) < @sizeOf(OpfWorkspace));
}

pub fn parseContainer(xml: []const u8, destination: []u8) Error![]const u8 {
    var cursor: usize = 0;
    while (nextElement(xml, &cursor)) |element| {
        if (std.mem.eql(u8, localName(element.name), "rootfile")) {
            const full_path = attribute(element.attributes, "full-path") orelse return error.MalformedXml;
            return copyPath(full_path, destination);
        }
    }
    return error.MalformedXml;
}

pub fn parseOpf(xml: []const u8, package_path: []const u8, publication: *Publication, workspace: *OpfWorkspace) Error!void {
    @memset(std.mem.asBytes(publication), 0);
    @memset(std.mem.asBytes(workspace), 0);
    const prefix = packageDirectory(package_path);

    var cursor: usize = 0;
    while (nextElement(xml, &cursor)) |element| {
        const name = localName(element.name);
        if (std.mem.eql(u8, name, "title") and publication.title_len == 0) {
            const text_end = std.mem.indexOfPos(u8, xml, cursor, "<") orelse return error.MalformedXml;
            try copyValue(xml[cursor..text_end], &publication.title, &publication.title_len);
        } else if (std.mem.eql(u8, name, "item")) {
            const id = attribute(element.attributes, "id") orelse continue;
            const href = attribute(element.attributes, "href") orelse continue;
            const media_type = attribute(element.attributes, "media-type") orelse continue;
            if (workspace.manifest_len == max_manifest_items) return error.CapacityExceeded;
            const item = &workspace.manifest[workspace.manifest_len];
            try copyValue(id, &item.id, &item.id_len);
            try copyValue(href, &item.href, &item.href_len);
            item.is_readable = std.mem.eql(u8, media_type, "application/xhtml+xml");
            item.is_navigation_document = propertiesContain(attribute(element.attributes, "properties"), "nav");
            workspace.manifest_len += 1;
        }
    }

    for (workspace.manifest[0..workspace.manifest_len]) |*item| {
        if (item.is_navigation_document) setNavigationSource(&publication.navigation_document, prefix, item.href[0..item.href_len]);
    }

    cursor = 0;
    var idref_buffer: [64]u8 = undefined;
    var idref_len: u8 = 0;
    var ncx_id: [64]u8 = undefined;
    var ncx_id_len: u8 = 0;
    while (nextElement(xml, &cursor)) |element| {
        const name = localName(element.name);
        if (std.mem.eql(u8, name, "spine")) {
            if (attribute(element.attributes, "toc")) |toc| try copyValue(toc, &ncx_id, &ncx_id_len);
            continue;
        }
        if (!std.mem.eql(u8, name, "itemref")) continue;
        const raw_idref = attribute(element.attributes, "idref") orelse return error.MalformedXml;
        try copyValue(raw_idref, &idref_buffer, &idref_len);
        const item = findManifestItem(workspace, idref_buffer[0..idref_len]) orelse return error.MissingManifestItem;
        if (!item.is_readable) return error.MissingManifestItem;
        if (publication.spine_len == max_spine_items) return error.CapacityExceeded;
        const spine_entry = &publication.spine[publication.spine_len];
        try joinPath(prefix, item.href[0..item.href_len], &spine_entry.path, &spine_entry.path_len);
        publication.spine_len += 1;
    }
    if (publication.spine_len == 0) return error.MalformedXml;
    if (findManifestItem(workspace, ncx_id[0..ncx_id_len])) |item| {
        setNavigationSource(&publication.ncx_document, prefix, item.href[0..item.href_len]);
    }
}

fn setNavigationSource(destination: *NavigationSource, prefix: []const u8, href: []const u8) void {
    if (destination.path_len != 0) return;
    var path_len: u8 = 0;
    joinPath(prefix, href, &destination.path, &path_len) catch return;
    destination.path_len = path_len;
}

fn propertiesContain(properties: ?[]const u8, wanted: []const u8) bool {
    const source = properties orelse return false;
    var tokens = std.mem.tokenizeAny(u8, source, " \t\r\n");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, wanted)) return true;
    }
    return false;
}

fn findManifestItem(workspace: *const OpfWorkspace, id: []const u8) ?*const ManifestItem {
    for (workspace.manifest[0..workspace.manifest_len]) |*item| {
        if (std.mem.eql(u8, item.id[0..item.id_len], id)) return item;
    }
    return null;
}

pub fn packageDirectory(path: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0 .. separator + 1];
}

pub fn resolvePath(prefix: []const u8, href: []const u8, destination: []u8, destination_len: *u8) Error!void {
    if (href.len == 0 or href[0] == '/' or std.mem.indexOf(u8, href, "\\") != null) return error.MalformedXml;
    const href_end = firstUriDelimiter(href);
    if (href_end == 0) return error.MalformedXml;

    var len: usize = 0;
    try appendPathSegments(prefix, destination, &len);
    try appendPathSegments(href[0..href_end], destination, &len);
    if (len == 0) return error.MalformedXml;
    destination_len.* = @intCast(len);
}

fn joinPath(prefix: []const u8, href: []const u8, destination: []u8, destination_len: *u8) Error!void {
    try resolvePath(prefix, href, destination, destination_len);
}

fn firstUriDelimiter(path: []const u8) usize {
    const fragment = std.mem.indexOfScalar(u8, path, '#') orelse path.len;
    const query = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
    return @min(fragment, query);
}

fn appendPathSegments(source: []const u8, destination: []u8, destination_len: *usize) Error!void {
    var segments = std.mem.splitScalar(u8, source, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (destination_len.* == 0) return error.MalformedXml;
            while (destination_len.* != 0 and destination[destination_len.* - 1] != '/') destination_len.* -= 1;
            if (destination_len.* != 0) destination_len.* -= 1;
            continue;
        }
        const separator: usize = if (destination_len.* == 0) 0 else 1;
        if (destination_len.* + separator + segment.len > destination.len) return error.CapacityExceeded;
        if (separator != 0) destination[destination_len.*] = '/';
        @memmove(destination[destination_len.* + separator .. destination_len.* + separator + segment.len], segment);
        destination_len.* += separator + segment.len;
    }
}

fn copyValue(source: []const u8, destination: []u8, destination_len: *u8) Error!void {
    if (source.len == 0) return error.MalformedXml;
    var source_index: usize = 0;
    var output_len: usize = 0;
    while (source_index < source.len) {
        if (source[source_index] != '&') {
            try appendByte(destination, &output_len, source[source_index]);
            source_index += 1;
            continue;
        }
        const entity_end = std.mem.indexOfScalarPos(u8, source, source_index + 1, ';') orelse return error.MalformedXml;
        if (entity_end - source_index > 16) return error.MalformedXml;
        try appendXmlEntity(source[source_index + 1 .. entity_end], destination, &output_len);
        source_index = entity_end + 1;
    }
    destination_len.* = @intCast(output_len);
}

fn appendByte(destination: []u8, output_len: *usize, byte: u8) Error!void {
    if (output_len.* == destination.len) return error.CapacityExceeded;
    destination[output_len.*] = byte;
    output_len.* += 1;
}

fn appendXmlEntity(name: []const u8, destination: []u8, output_len: *usize) Error!void {
    const codepoint: u21 = if (std.mem.eql(u8, name, "amp")) '&' else if (std.mem.eql(u8, name, "lt")) '<' else if (std.mem.eql(u8, name, "gt")) '>' else if (std.mem.eql(u8, name, "quot")) '"' else if (std.mem.eql(u8, name, "apos")) '\'' else try parseNumericEntity(name);
    var bytes: [4]u8 = undefined;
    const byte_len = std.unicode.utf8Encode(codepoint, &bytes) catch return error.MalformedXml;
    if (destination.len - output_len.* < byte_len) return error.CapacityExceeded;
    @memcpy(destination[output_len.* .. output_len.* + byte_len], bytes[0..byte_len]);
    output_len.* += byte_len;
}

fn parseNumericEntity(name: []const u8) Error!u21 {
    if (name.len < 2 or name[0] != '#') return error.MalformedXml;
    const base: u8 = if (name[1] == 'x' or name[1] == 'X') 16 else 10;
    const digits = name[if (base == 16) 2 else 1..];
    if (digits.len == 0) return error.MalformedXml;
    var value: u32 = 0;
    for (digits) |digit| {
        const amount: u8 = if (digit >= '0' and digit <= '9') digit - '0' else if (base == 16 and digit >= 'a' and digit <= 'f') digit - 'a' + 10 else if (base == 16 and digit >= 'A' and digit <= 'F') digit - 'A' + 10 else return error.MalformedXml;
        if (amount >= base or value > (0x10ffff - @as(u32, amount)) / base) return error.MalformedXml;
        value = value * base + amount;
    }
    return @intCast(value);
}

const Element = struct {
    name: []const u8,
    attributes: []const u8,
};

fn nextElement(xml: []const u8, cursor: *usize) ?Element {
    while (std.mem.indexOfPos(u8, xml, cursor.*, "<")) |start| {
        cursor.* = start + 1;
        if (cursor.* >= xml.len) return null;
        if (xml[cursor.*] == '?' or xml[cursor.*] == '!' or xml[cursor.*] == '/') {
            const end = std.mem.indexOfPos(u8, xml, cursor.*, ">") orelse return null;
            cursor.* = end + 1;
            continue;
        }
        const name_start = cursor.*;
        while (cursor.* < xml.len and isNameChar(xml[cursor.*])) cursor.* += 1;
        if (cursor.* == name_start) continue;
        const name = xml[name_start..cursor.*];
        const attributes_start = cursor.*;
        var quote: u8 = 0;
        while (cursor.* < xml.len) : (cursor.* += 1) {
            const byte = xml[cursor.*];
            if (quote != 0) {
                if (byte == quote) quote = 0;
            } else if (byte == '\'' or byte == '"') {
                quote = byte;
            } else if (byte == '>') {
                const attributes_end = cursor.*;
                cursor.* += 1;
                return .{ .name = name, .attributes = xml[attributes_start..attributes_end] };
            }
        }
        return null;
    }
    return null;
}

fn attribute(attributes: []const u8, wanted_name: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < attributes.len) {
        while (cursor < attributes.len and (std.ascii.isWhitespace(attributes[cursor]) or attributes[cursor] == '/')) cursor += 1;
        const name_start = cursor;
        while (cursor < attributes.len and isNameChar(attributes[cursor])) cursor += 1;
        if (cursor == name_start) return null;
        const name = attributes[name_start..cursor];
        while (cursor < attributes.len and std.ascii.isWhitespace(attributes[cursor])) cursor += 1;
        if (cursor == attributes.len or attributes[cursor] != '=') return null;
        cursor += 1;
        while (cursor < attributes.len and std.ascii.isWhitespace(attributes[cursor])) cursor += 1;
        if (cursor == attributes.len or (attributes[cursor] != '\'' and attributes[cursor] != '"')) return null;
        const quote = attributes[cursor];
        cursor += 1;
        const value_start = cursor;
        while (cursor < attributes.len and attributes[cursor] != quote) cursor += 1;
        if (cursor == attributes.len) return null;
        const value = attributes[value_start..cursor];
        cursor += 1;
        if (std.mem.eql(u8, localName(name), wanted_name)) return value;
    }
    return null;
}

fn copyPath(source: []const u8, destination: []u8) Error![]const u8 {
    var len: u8 = 0;
    try copyValue(source, destination, &len);
    const decoded = destination[0..len];
    try joinPath("", decoded, destination, &len);
    return destination[0..len];
}

fn localName(name: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, name, ':')) |index| index + 1 else 0;
    return name[start..];
}

fn isNameChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == ':' or byte == '-' or byte == '_';
}

test "extracts the package path from an EPUB container" {
    const xml =
        \\<?xml version="1.0"?>
        \\<container><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    ;
    var path: [64]u8 = undefined;
    const result = try parseContainer(xml, &path);
    try std.testing.expectEqualStrings("OPS/book.opf", result);
}

test "decodes and normalizes the package path from an EPUB container" {
    const xml = "<container><rootfiles><rootfile full-path=\"OPS/./book&amp;one.opf\"/></rootfiles></container>";
    var path: [64]u8 = undefined;
    const result = try parseContainer(xml, &path);
    try std.testing.expectEqualStrings("OPS/book&one.opf", result);
}

test "resolves OPF manifest and spine in reading order" {
    const opf =
        \\<package><metadata><dc:title>Example Book</dc:title></metadata>
        \\<manifest><item id="one" href="first.xhtml" media-type="application/xhtml+xml"/><item id="two" href="second.xhtml" media-type="application/xhtml+xml"/></manifest>
        \\<spine><itemref idref="two"/><itemref idref="one"/></spine></package>
    ;
    var publication: Publication = undefined;
    var workspace: OpfWorkspace = undefined;
    try parseOpf(opf, "OPS/book.opf", &publication, &workspace);
    try std.testing.expectEqualStrings("Example Book", publication.titleSlice());
    try std.testing.expectEqual(@as(u8, 2), publication.spine_len);
    try std.testing.expectEqualStrings("OPS/second.xhtml", publication.spine[0].slice());
    try std.testing.expectEqualStrings("OPS/first.xhtml", publication.spine[1].slice());
}

test "normalizes relative manifest hrefs and removes fragments" {
    const opf =
        \\<package><manifest><item id="one" href="./text/../chapter.xhtml#start" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/></spine></package>
    ;
    var publication: Publication = undefined;
    var workspace: OpfWorkspace = undefined;
    try parseOpf(opf, "OPS/book.opf", &publication, &workspace);
    try std.testing.expectEqualStrings("OPS/chapter.xhtml", publication.spine[0].slice());
}

test "decodes XML entities in manifest hrefs" {
    const opf =
        \\<package><manifest><item id="one" href="chapter&amp;one.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/></spine></package>
    ;
    var publication: Publication = undefined;
    var workspace: OpfWorkspace = undefined;
    try parseOpf(opf, "OPS/book.opf", &publication, &workspace);
    try std.testing.expectEqualStrings("OPS/chapter&one.xhtml", publication.spine[0].slice());
}

test "discovers a resolved EPUB 3 navigation document and its NCX fallback" {
    const opf =
        \\<package><manifest>
        \\<item id="chapter" href="text/chapter.xhtml" media-type="application/xhtml+xml"/>
        \\<item id="nav" href="./navigation/toc.xhtml#contents" media-type="application/xhtml+xml" properties="cover-image nav scripted"/>
        \\<item id="ncx" href="legacy/../toc.ncx?cache=1" media-type="application/x-dtbncx+xml"/>
        \\</manifest><spine toc="ncx"><itemref idref="chapter"/></spine></package>
    ;
    var publication: Publication = undefined;
    var workspace: OpfWorkspace = undefined;
    try parseOpf(opf, "OPS/package/book.opf", &publication, &workspace);
    try std.testing.expectEqualStrings("OPS/package/navigation/toc.xhtml", publication.navigation_document.slice());
    try std.testing.expectEqualStrings("OPS/package/toc.ncx", publication.ncx_document.slice());
    try std.testing.expectEqual(@as(u8, 0), publication.chapter_labels[0].len);
}

test "discovers an NCX source when EPUB 3 navigation is absent" {
    const opf =
        \\<package><manifest>
        \\<item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
        \\<item id="contents" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        \\</manifest><spine toc="contents"><itemref idref="chapter"/></spine></package>
    ;
    var publication: Publication = undefined;
    var workspace: OpfWorkspace = undefined;
    try parseOpf(opf, "OPS/book.opf", &publication, &workspace);
    try std.testing.expectEqual(@as(usize, 0), publication.navigation_document.slice().len);
    try std.testing.expectEqualStrings("OPS/toc.ncx", publication.ncx_document.slice());
}

test "keeps navigation sources empty when the OPF declares neither" {
    const opf =
        \\<package><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
        \\<spine><itemref idref="chapter"/></spine></package>
    ;
    var publication: Publication = undefined;
    var workspace: OpfWorkspace = undefined;
    try parseOpf(opf, "OPS/book.opf", &publication, &workspace);
    try std.testing.expectEqual(@as(usize, 0), publication.navigation_document.slice().len);
    try std.testing.expectEqual(@as(usize, 0), publication.ncx_document.slice().len);
}
