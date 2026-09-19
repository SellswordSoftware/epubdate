const std = @import("std");
const limits = @import("limits").reader;
const epub = @import("epub.zig");

pub const Error = error{ MalformedXml, CapacityExceeded };

/// Incrementally parses the one EPUB 3 `nav epub:type="toc"` document needed
/// by the chapter browser. It retains no XML source: a completed link is
/// immediately matched to a spine entry and copied into that entry's label.
pub const Parser = struct {
    publication: *epub.Publication,
    source_directory: []const u8,
    tag: [limits.max_xml_tag_bytes]u8 = undefined,
    tag_len: usize = 0,
    in_tag: bool = false,
    quote: u8 = 0,
    toc_depth: u16 = 0,
    found_toc: bool = false,
    in_link: bool = false,
    href: [128]u8 = undefined,
    href_len: usize = 0,
    label: [epub.max_chapter_label_bytes]u8 = undefined,
    label_len: usize = 0,
    label_too_long: bool = false,
    pending_space: bool = false,
    entity: [limits.max_xml_entity_bytes]u8 = undefined,
    entity_len: usize = 0,
    in_entity: bool = false,

    pub fn init(publication: *epub.Publication, source_path: []const u8) Parser {
        return .{ .publication = publication, .source_directory = epub.packageDirectory(source_path) };
    }

    pub fn feed(self: *Parser, bytes: []const u8) Error!void {
        for (bytes) |byte| {
            if (self.in_tag) {
                try self.appendTagByte(byte);
                continue;
            }
            if (byte == '<') {
                self.in_tag = true;
                self.tag_len = 0;
                self.quote = 0;
                try self.appendTagByte(byte);
                continue;
            }
            if (self.in_link) try self.appendTextByte(byte);
        }
    }

    pub fn finish(self: *Parser) Error!void {
        if (self.in_tag or self.in_entity) return error.MalformedXml;
        if (self.in_link) return error.MalformedXml;
    }

    pub fn labelCount(self: *const Parser) u8 {
        var count: u8 = 0;
        for (self.publication.chapter_labels[0..self.publication.spine_len]) |label| {
            if (label.len != 0) count += 1;
        }
        return count;
    }

    fn appendTagByte(self: *Parser, byte: u8) Error!void {
        if (self.tag_len == self.tag.len) return error.CapacityExceeded;
        self.tag[self.tag_len] = byte;
        self.tag_len += 1;
        if (self.quote != 0) {
            if (byte == self.quote) self.quote = 0;
            return;
        }
        if (byte == '\'' or byte == '"') {
            self.quote = byte;
            return;
        }
        if (byte != '>') return;
        self.in_tag = false;
        try self.processTag(self.tag[0..self.tag_len]);
    }

    fn processTag(self: *Parser, raw: []const u8) Error!void {
        if (raw.len >= 2 and (raw[1] == '?' or raw[1] == '!')) return;
        const tag = parseTag(raw) orelse return error.MalformedXml;
        if (tag.closing) {
            if (self.in_link and std.mem.eql(u8, localName(tag.name), "a")) try self.finishLink();
            if (self.toc_depth != 0) self.toc_depth -= 1;
            return;
        }
        if (self.toc_depth == 0) {
            if (!self.found_toc and std.mem.eql(u8, localName(tag.name), "nav") and typeContains(tag.attributes, "epub:type", "toc")) {
                self.found_toc = true;
                if (!tag.self_closing) self.toc_depth = 1;
            }
            return;
        }
        if (std.mem.eql(u8, localName(tag.name), "a") and !self.in_link) self.startLink(tag.attributes);
        if (!tag.self_closing) self.toc_depth += 1;
    }

    fn startLink(self: *Parser, attributes: []const u8) void {
        const raw_href = attribute(attributes, "href") orelse return;
        self.in_link = true;
        self.href_len = decodeEntities(raw_href, &self.href) catch {
            self.href_len = 0;
            return;
        };
        self.label_len = 0;
        self.label_too_long = false;
        self.pending_space = false;
        self.entity_len = 0;
        self.in_entity = false;
    }

    fn finishLink(self: *Parser) Error!void {
        self.in_link = false;
        if (self.in_entity) return error.MalformedXml;
        if (self.href_len == 0 or self.label_len == 0 or self.label_too_long) return;
        var target: [128]u8 = undefined;
        var target_len: u8 = 0;
        epub.resolvePath(self.source_directory, self.href[0..self.href_len], &target, &target_len) catch return;
        for (self.publication.spine[0..self.publication.spine_len], 0..) |spine, index| {
            if (!std.mem.eql(u8, spine.slice(), target[0..target_len])) continue;
            const label = &self.publication.chapter_labels[index];
            if (label.len != 0) return;
            label.len = @intCast(self.label_len);
            @memcpy(label.bytes[0..self.label_len], self.label[0..self.label_len]);
            return;
        }
    }

    fn appendTextByte(self: *Parser, byte: u8) Error!void {
        if (!self.in_entity) {
            if (byte == '&') {
                self.in_entity = true;
                self.entity_len = 0;
                return;
            }
            self.appendLabelByte(byte);
            return;
        }
        if (byte == ';') {
            var decoded: [4]u8 = undefined;
            const decoded_len = try decodeEntity(self.entity[0..self.entity_len], &decoded);
            for (decoded[0..decoded_len]) |decoded_byte| self.appendLabelByte(decoded_byte);
            self.in_entity = false;
            return;
        }
        if (self.entity_len == self.entity.len) return error.CapacityExceeded;
        self.entity[self.entity_len] = byte;
        self.entity_len += 1;
    }

    fn appendLabelByte(self: *Parser, byte: u8) void {
        if (std.ascii.isWhitespace(byte)) {
            if (self.label_len != 0) self.pending_space = true;
            return;
        }
        if (self.pending_space) {
            if (self.label_len == self.label.len) {
                self.label_too_long = true;
                return;
            }
            self.label[self.label_len] = ' ';
            self.label_len += 1;
            self.pending_space = false;
        }
        if (self.label_len == self.label.len) {
            self.label_too_long = true;
            return;
        }
        self.label[self.label_len] = byte;
        self.label_len += 1;
    }
};

const max_ncx_depth = 12;

/// Incremental NCX fallback parser. It records each navPoint as soon as both
/// its label and target have appeared, preserving source order even for nested
/// points without retaining the hierarchy.
pub const NcxParser = struct {
    publication: *epub.Publication,
    source_directory: []const u8,
    tag: [limits.max_xml_tag_bytes]u8 = undefined,
    tag_len: usize = 0,
    in_tag: bool = false,
    quote: u8 = 0,
    points: [max_ncx_depth]Point = undefined,
    point_len: usize = 0,
    capturing_text: bool = false,
    entity: [limits.max_xml_entity_bytes]u8 = undefined,
    entity_len: usize = 0,
    in_entity: bool = false,

    const Point = struct {
        label: [epub.max_chapter_label_bytes]u8 = undefined,
        label_len: usize = 0,
        label_too_long: bool = false,
        pending_space: bool = false,
        href: [128]u8 = undefined,
        href_len: usize = 0,
        mapped: bool = false,
    };

    pub fn init(publication: *epub.Publication, source_path: []const u8) NcxParser {
        return .{ .publication = publication, .source_directory = epub.packageDirectory(source_path) };
    }

    pub fn feed(self: *NcxParser, bytes: []const u8) Error!void {
        for (bytes) |byte| {
            if (self.in_tag) {
                try self.appendTagByte(byte);
            } else if (byte == '<') {
                self.in_tag = true;
                self.tag_len = 0;
                self.quote = 0;
                try self.appendTagByte(byte);
            } else if (self.capturing_text) {
                try self.appendTextByte(byte);
            }
        }
    }

    pub fn finish(self: *NcxParser) Error!void {
        if (self.in_tag or self.in_entity or self.capturing_text or self.point_len != 0) return error.MalformedXml;
    }

    pub fn labelCount(self: *const NcxParser) u8 {
        var count: u8 = 0;
        for (self.publication.chapter_labels[0..self.publication.spine_len]) |label| {
            if (label.len != 0) count += 1;
        }
        return count;
    }

    fn appendTagByte(self: *NcxParser, byte: u8) Error!void {
        if (self.tag_len == self.tag.len) return error.CapacityExceeded;
        self.tag[self.tag_len] = byte;
        self.tag_len += 1;
        if (self.quote != 0) {
            if (byte == self.quote) self.quote = 0;
            return;
        }
        if (byte == '\'' or byte == '"') {
            self.quote = byte;
            return;
        }
        if (byte != '>') return;
        self.in_tag = false;
        try self.processTag(self.tag[0..self.tag_len]);
    }

    fn processTag(self: *NcxParser, raw: []const u8) Error!void {
        if (raw.len >= 2 and (raw[1] == '?' or raw[1] == '!')) return;
        const tag = parseTag(raw) orelse return error.MalformedXml;
        const name = localName(tag.name);
        if (tag.closing) {
            if (std.mem.eql(u8, name, "text") and self.capturing_text) {
                if (self.in_entity) return error.MalformedXml;
                self.capturing_text = false;
                try self.mapTop();
            } else if (std.mem.eql(u8, name, "navPoint")) {
                if (self.point_len == 0) return error.MalformedXml;
                self.point_len -= 1;
            }
            return;
        }
        if (std.mem.eql(u8, name, "navPoint")) {
            if (self.point_len == self.points.len) return error.CapacityExceeded;
            self.points[self.point_len] = .{};
            self.point_len += 1;
        } else if (self.point_len != 0 and std.mem.eql(u8, name, "text") and !self.capturing_text) {
            self.capturing_text = true;
            self.in_entity = false;
            self.entity_len = 0;
        } else if (self.point_len != 0 and std.mem.eql(u8, name, "content")) {
            const src = attribute(tag.attributes, "src") orelse return;
            const point = self.top();
            point.href_len = decodeEntities(src, &point.href) catch return;
            try self.mapTop();
        }
    }

    fn appendTextByte(self: *NcxParser, byte: u8) Error!void {
        if (!self.in_entity) {
            if (byte == '&') {
                self.in_entity = true;
                self.entity_len = 0;
            } else self.appendLabelByte(byte);
            return;
        }
        if (byte == ';') {
            var decoded: [4]u8 = undefined;
            const decoded_len = try decodeEntity(self.entity[0..self.entity_len], &decoded);
            for (decoded[0..decoded_len]) |decoded_byte| self.appendLabelByte(decoded_byte);
            self.in_entity = false;
            return;
        }
        if (self.entity_len == self.entity.len) return error.CapacityExceeded;
        self.entity[self.entity_len] = byte;
        self.entity_len += 1;
    }

    fn appendLabelByte(self: *NcxParser, byte: u8) void {
        const point = self.top();
        if (std.ascii.isWhitespace(byte)) {
            if (point.label_len != 0) point.pending_space = true;
            return;
        }
        if (point.pending_space) {
            if (point.label_len == point.label.len) {
                point.label_too_long = true;
                return;
            }
            point.label[point.label_len] = ' ';
            point.label_len += 1;
            point.pending_space = false;
        }
        if (point.label_len == point.label.len) {
            point.label_too_long = true;
            return;
        }
        point.label[point.label_len] = byte;
        point.label_len += 1;
    }

    fn mapTop(self: *NcxParser) Error!void {
        const point = self.top();
        if (point.mapped or point.href_len == 0 or point.label_len == 0 or point.label_too_long) return;
        var target: [128]u8 = undefined;
        var target_len: u8 = 0;
        epub.resolvePath(self.source_directory, point.href[0..point.href_len], &target, &target_len) catch return;
        for (self.publication.spine[0..self.publication.spine_len], 0..) |spine, index| {
            if (!std.mem.eql(u8, spine.slice(), target[0..target_len])) continue;
            const label = &self.publication.chapter_labels[index];
            if (label.len != 0) return;
            label.len = @intCast(point.label_len);
            @memcpy(label.bytes[0..point.label_len], point.label[0..point.label_len]);
            point.mapped = true;
            return;
        }
    }

    fn top(self: *NcxParser) *Point {
        return &self.points[self.point_len - 1];
    }
};

const Tag = struct {
    name: []const u8,
    attributes: []const u8,
    closing: bool,
    self_closing: bool,
};

fn parseTag(raw: []const u8) ?Tag {
    if (raw.len < 3 or raw[0] != '<' or raw[raw.len - 1] != '>') return null;
    var cursor: usize = 1;
    const closing = cursor < raw.len and raw[cursor] == '/';
    if (closing) cursor += 1;
    while (cursor < raw.len and std.ascii.isWhitespace(raw[cursor])) cursor += 1;
    const name_start = cursor;
    while (cursor < raw.len and isNameChar(raw[cursor])) cursor += 1;
    if (cursor == name_start) return null;
    const attributes_start = cursor;
    var end = raw.len - 1;
    while (end > attributes_start and std.ascii.isWhitespace(raw[end - 1])) end -= 1;
    const self_closing = !closing and end > attributes_start and raw[end - 1] == '/';
    if (self_closing) end -= 1;
    return .{ .name = raw[name_start..cursor], .attributes = raw[attributes_start..end], .closing = closing, .self_closing = self_closing };
}

fn attribute(attributes: []const u8, wanted: []const u8) ?[]const u8 {
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
        if (std.mem.eql(u8, name, wanted)) return value;
    }
    return null;
}

fn typeContains(attributes: []const u8, name: []const u8, wanted: []const u8) bool {
    const value = attribute(attributes, name) orelse return false;
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, wanted)) return true;
    }
    return false;
}

fn localName(name: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, name, ':')) |index| index + 1 else 0;
    return name[start..];
}

fn isNameChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == ':' or byte == '-' or byte == '_';
}

fn decodeEntities(source: []const u8, destination: []u8) Error!usize {
    var output_len: usize = 0;
    var cursor: usize = 0;
    while (cursor < source.len) {
        if (source[cursor] != '&') {
            if (output_len == destination.len) return error.CapacityExceeded;
            destination[output_len] = source[cursor];
            output_len += 1;
            cursor += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, source, cursor + 1, ';') orelse return error.MalformedXml;
        var decoded: [4]u8 = undefined;
        const decoded_len = try decodeEntity(source[cursor + 1 .. end], &decoded);
        if (destination.len - output_len < decoded_len) return error.CapacityExceeded;
        @memcpy(destination[output_len .. output_len + decoded_len], decoded[0..decoded_len]);
        output_len += decoded_len;
        cursor = end + 1;
    }
    return output_len;
}

fn decodeEntity(name: []const u8, destination: *[4]u8) Error!usize {
    const codepoint: u21 = if (std.mem.eql(u8, name, "amp")) '&' else if (std.mem.eql(u8, name, "lt")) '<' else if (std.mem.eql(u8, name, "gt")) '>' else if (std.mem.eql(u8, name, "quot")) '"' else if (std.mem.eql(u8, name, "apos")) '\'' else try parseNumericEntity(name);
    return std.unicode.utf8Encode(codepoint, destination) catch error.MalformedXml;
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

fn fixturePublication() epub.Publication {
    var publication: epub.Publication = undefined;
    @memset(std.mem.asBytes(&publication), 0);
    publication.spine_len = 3;
    const paths = [_][]const u8{ "OPS/text/one.xhtml", "OPS/text/two.xhtml", "OPS/text/three.xhtml" };
    for (paths, 0..) |path, index| {
        publication.spine[index].path_len = @intCast(path.len);
        @memcpy(publication.spine[index].path[0..path.len], path);
    }
    return publication;
}

test "maps chunked EPUB navigation links to the first matching spine labels" {
    var publication = fixturePublication();
    var parser = Parser.init(&publication, "OPS/toc.xhtml");
    const source =
        "<nav epub:type=\"landmarks\"><a href=\"text/three.xhtml\">Ignore</a></nav>" ++
        "<nav epub:type=\"toc\"><ol>" ++
        "<li><a href=\"text/one.xhtml#first\"> First &amp; <em>Only</em> </a></li>" ++
        "<li><a href=\"text/one.xhtml#second\">Duplicate</a></li>" ++
        "<li><a href=\"./text/two.xhtml?x=1\">Second</a></li>" ++
        "<li><a href=\"cover.xhtml\">Unknown</a></li>" ++
        "</ol></nav>";
    var start: usize = 0;
    while (start < source.len) {
        const end = @min(source.len, start + 7);
        try parser.feed(source[start..end]);
        start = end;
    }
    try parser.finish();
    try std.testing.expectEqualStrings("First & Only", publication.chapter_labels[0].slice());
    try std.testing.expectEqualStrings("Second", publication.chapter_labels[1].slice());
    try std.testing.expectEqual(@as(u8, 0), publication.chapter_labels[2].len);
    try std.testing.expectEqual(@as(u8, 2), parser.labelCount());
}

test "rejects malformed or overlong links without retaining labels" {
    var publication = fixturePublication();
    var parser = Parser.init(&publication, "OPS/toc.xhtml");
    try parser.feed("<nav epub:type=\"toc\"><a href=\"text/one.xhtml\">");
    var too_long: [epub.max_chapter_label_bytes + 1]u8 = undefined;
    @memset(&too_long, 'x');
    try parser.feed(&too_long);
    try parser.feed("</a></nav>");
    try parser.finish();
    try std.testing.expectEqual(@as(u8, 0), parser.labelCount());

    var malformed_publication = fixturePublication();
    var malformed = Parser.init(&malformed_publication, "OPS/toc.xhtml");
    try malformed.feed("<nav epub:type=\"toc\"><a href=\"text/two.xhtml\">broken &amp");
    try std.testing.expectError(error.MalformedXml, malformed.finish());
}

test "maps nested NCX points in source order" {
    var publication = fixturePublication();
    var parser = NcxParser.init(&publication, "OPS/toc.ncx");
    const source =
        "<ncx><navMap><navPoint><navLabel><text>One &amp; only</text></navLabel><content src=\"text/one.xhtml#x\"/>" ++
        "<navPoint><navLabel><text>Two</text></navLabel><content src=\"text/two.xhtml\"/></navPoint></navPoint>" ++
        "</navMap></ncx>";
    var start: usize = 0;
    while (start < source.len) {
        const end = @min(source.len, start + 5);
        try parser.feed(source[start..end]);
        start = end;
    }
    try parser.finish();
    try std.testing.expectEqualStrings("One & only", publication.chapter_labels[0].slice());
    try std.testing.expectEqualStrings("Two", publication.chapter_labels[1].slice());
}
