const std = @import("std");

pub const Error = error{
    UnexpectedEof,
    OutputTooSmall,
    WindowTooSmall,
    UnsupportedBlockType,
    InvalidStoredBlock,
    InvalidHuffmanCode,
    InvalidDynamicHeader,
    MissingEndCode,
    InvalidLengthSymbol,
    InvalidDistance,
};

/// Inflates a complete raw-DEFLATE stream into caller-owned storage. The
/// history window is introduced now so fixed and dynamic blocks can reuse the
/// same no-allocation API in the next tracer bullets.
pub fn inflateRaw(input: []const u8, output: []u8, window: []u8, workspace: *Workspace) Error!usize {
    var bits = BitReader.init(input);
    var writer = OutputWriter.init(output, window);

    while (true) {
        const is_final = try bits.readBits(1);
        const block_type = try bits.readBits(2);
        switch (block_type) {
            0 => try inflateStoredBlock(&bits, &writer),
            1 => try inflateFixedBlock(&bits, &writer, workspace),
            2 => try inflateDynamicBlock(&bits, &writer, workspace),
            else => return error.UnsupportedBlockType,
        }
        if (is_final == 1) return writer.written;
    }
}

fn inflateStoredBlock(bits: *BitReader, writer: *OutputWriter) Error!void {
    bits.alignToByte();
    const block_len = try bits.readBits(16);
    const block_len_inverse = try bits.readBits(16);
    if (block_len ^ block_len_inverse != 0xffff) return error.InvalidStoredBlock;
    for (0..block_len) |_| try writer.writeByte(@intCast(try bits.readBits(8)));
}

fn inflateFixedBlock(bits: *BitReader, writer: *OutputWriter, workspace: *Workspace) Error!void {
    for (0..144) |index| workspace.lengths[index] = 8;
    for (144..256) |index| workspace.lengths[index] = 9;
    for (256..280) |index| workspace.lengths[index] = 7;
    for (280..288) |index| workspace.lengths[index] = 8;
    try workspace.literal_codes.init(workspace.lengths[0..288], &workspace.counts, &workspace.next_code);
    @memset(workspace.lengths[0..32], 5);
    try workspace.distance_codes.init(workspace.lengths[0..32], &workspace.counts, &workspace.next_code);
    return inflateCompressedBlock(bits, writer, &workspace.literal_codes, &workspace.distance_codes);
}

fn inflateDynamicBlock(bits: *BitReader, writer: *OutputWriter, workspace: *Workspace) Error!void {
    const literal_count: usize = 257 + try bits.readBits(5);
    const distance_count: usize = 1 + try bits.readBits(5);
    const code_length_count: usize = 4 + try bits.readBits(4);
    @memset(&workspace.code_length_lengths, 0);
    const code_length_order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    for (0..code_length_count) |index| {
        workspace.code_length_lengths[code_length_order[index]] = @intCast(try bits.readBits(3));
    }
    try workspace.code_length_codes.init(&workspace.code_length_lengths, &workspace.counts, &workspace.next_code);

    @memset(&workspace.lengths, 0);
    const total_count = literal_count + distance_count;
    var index: usize = 0;
    while (index < total_count) {
        const symbol = try workspace.code_length_codes.decode(bits);
        switch (symbol) {
            0...15 => {
                workspace.lengths[index] = @intCast(symbol);
                index += 1;
            },
            16 => {
                if (index == 0) return error.InvalidDynamicHeader;
                const repeat_count: usize = 3 + try bits.readBits(2);
                if (repeat_count > total_count - index) return error.InvalidDynamicHeader;
                @memset(workspace.lengths[index .. index + repeat_count], workspace.lengths[index - 1]);
                index += repeat_count;
            },
            17 => {
                const repeat_count: usize = 3 + try bits.readBits(3);
                if (repeat_count > total_count - index) return error.InvalidDynamicHeader;
                @memset(workspace.lengths[index .. index + repeat_count], 0);
                index += repeat_count;
            },
            18 => {
                const repeat_count: usize = 11 + try bits.readBits(7);
                if (repeat_count > total_count - index) return error.InvalidDynamicHeader;
                @memset(workspace.lengths[index .. index + repeat_count], 0);
                index += repeat_count;
            },
            else => return error.InvalidDynamicHeader,
        }
    }
    if (workspace.lengths[256] == 0) return error.MissingEndCode;

    try workspace.literal_codes.init(workspace.lengths[0..literal_count], &workspace.counts, &workspace.next_code);
    try workspace.distance_codes.init(workspace.lengths[literal_count..total_count], &workspace.counts, &workspace.next_code);
    return inflateCompressedBlock(bits, writer, &workspace.literal_codes, &workspace.distance_codes);
}

fn inflateCompressedBlock(bits: *BitReader, writer: *OutputWriter, literal_codes: *const Huffman, distance_codes: *const Huffman) Error!void {
    while (true) {
        const symbol = try literal_codes.decode(bits);
        if (symbol < 256) {
            try writer.writeByte(@intCast(symbol));
        } else if (symbol == 256) {
            return;
        } else {
            const length_index = symbol - 257;
            if (length_index >= length_bases.len) return error.InvalidLengthSymbol;
            const length = length_bases[length_index] + try bits.readBits(length_extra_bits[length_index]);
            const distance_symbol = try distance_codes.decode(bits);
            if (distance_symbol >= distance_bases.len) return error.InvalidDistance;
            const distance: u16 = @intCast(distance_bases[distance_symbol] + try bits.readBits(distance_extra_bits[distance_symbol]));
            try writer.copyMatch(distance, length);
        }
    }
}

const length_bases = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra_bits = [_]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const distance_bases = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const distance_extra_bits = [_]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

const OutputWriter = struct {
    output: []u8,
    window: []u8,
    written: usize = 0,
    window_next: usize = 0,
    window_filled: usize = 0,

    fn init(output: []u8, window: []u8) OutputWriter {
        return .{ .output = output, .window = window };
    }

    fn writeByte(self: *OutputWriter, byte: u8) Error!void {
        if (self.written == self.output.len) return error.OutputTooSmall;
        self.output[self.written] = byte;
        self.written += 1;
        if (self.window.len != 0) {
            self.window[self.window_next] = byte;
            self.window_next = (self.window_next + 1) % self.window.len;
            self.window_filled = @min(self.window_filled + 1, self.window.len);
        }
    }

    fn copyMatch(self: *OutputWriter, distance: u16, length: u32) Error!void {
        if (self.window.len < 32 * 1024) return error.WindowTooSmall;
        if (distance == 0 or distance > self.window_filled) return error.InvalidDistance;

        var source_index = (self.window_next + self.window.len - distance) % self.window.len;
        for (0..length) |_| {
            const byte = self.window[source_index];
            try self.writeByte(byte);
            source_index = (source_index + 1) % self.window.len;
        }
    }
};

const Huffman = struct {
    const no_child: i16 = std.math.minInt(i16);
    const Node = struct { child: [2]i16 = .{ no_child, no_child } };

    nodes: [640]Node = [_]Node{.{}} ** 640,
    node_count: usize = 1,

    fn init(self: *Huffman, lengths: []const u8, counts: *[16]u16, next_code: *[16]u16) Error!void {
        self.* = .{};
        @memset(counts, 0);
        for (lengths) |length| {
            if (length > 15) return error.InvalidHuffmanCode;
            if (length != 0) counts[length] += 1;
        }

        var remaining_codes: i32 = 1;
        for (1..16) |length| {
            remaining_codes = (remaining_codes << 1) - counts[length];
            if (remaining_codes < 0) return error.InvalidHuffmanCode;
        }

        var code: u16 = 0;
        @memset(next_code, 0);
        for (1..16) |length| {
            code = (code + counts[length - 1]) << 1;
            next_code[length] = code;
        }

        for (lengths, 0..) |length, symbol| {
            if (length == 0) continue;
            const canonical_code = next_code[length];
            next_code[length] += 1;
            var node_index: usize = 0;
            for (0..length) |bit_index| {
                const bit: usize = (canonical_code >> @intCast(length - 1 - bit_index)) & 1;
                const is_last_bit = bit_index + 1 == length;
                const child = self.nodes[node_index].child[bit];
                if (is_last_bit) {
                    if (child != no_child) return error.InvalidHuffmanCode;
                    self.nodes[node_index].child[bit] = -@as(i16, @intCast(symbol)) - 1;
                } else if (child == no_child) {
                    if (self.node_count == self.nodes.len) return error.InvalidHuffmanCode;
                    self.nodes[node_index].child[bit] = @intCast(self.node_count);
                    node_index = self.node_count;
                    self.node_count += 1;
                } else if (child < 0) {
                    return error.InvalidHuffmanCode;
                } else {
                    node_index = @intCast(child);
                }
            }
        }
    }

    fn decode(self: *const Huffman, bits: *BitReader) Error!u16 {
        var node_index: usize = 0;
        for (0..15) |_| {
            const bit: usize = @intCast(try bits.readBits(1));
            const child = self.nodes[node_index].child[bit];
            if (child == no_child) return error.InvalidHuffmanCode;
            if (child < 0) return @intCast(-child - 1);
            node_index = @intCast(child);
        }
        return error.InvalidHuffmanCode;
    }
};

/// Fixed-size scratch state for one inflater. Keep this with the reader state,
/// not on the Playdate's small call stack.
pub const Workspace = struct {
    code_length_codes: Huffman = undefined,
    literal_codes: Huffman = undefined,
    distance_codes: Huffman = undefined,
    code_length_lengths: [19]u8 = undefined,
    lengths: [320]u8 = undefined,
    counts: [16]u16 = undefined,
    next_code: [16]u16 = undefined,
};

pub const StreamStatus = enum { needs_input, needs_output, end };

pub const StepResult = struct {
    input_used: usize,
    output_written: usize,
    status: StreamStatus,
};

/// Persistent raw-DEFLATE state.  Stored, fixed-Huffman, and dynamic-Huffman
/// blocks all retain their bit, tree, and history state across chunk calls.
pub const InflateState = struct {
    const Phase = enum {
        block_final,
        block_type,
        stored_align,
        stored_length,
        stored_length_inverse,
        stored_bytes,
        compressed_symbol,
        literal_write,
        length_extra,
        distance_symbol,
        distance_extra,
        match_copy,
        dynamic_literal_count,
        dynamic_distance_count,
        dynamic_code_length_count,
        dynamic_code_length_lengths,
        dynamic_lengths,
        dynamic_repeat,
        done,
    };

    window: []u8,
    workspace: *Workspace,
    bits: u32 = 0,
    bit_count: u5 = 0,
    phase: Phase = .block_final,
    final_block: bool = false,
    stored_remaining: u16 = 0,
    decode_node: usize = 0,
    pending_literal: u8 = 0,
    pending_length: u16 = 0,
    pending_extra_bits: u5 = 0,
    pending_distance: u16 = 0,
    match_remaining: u16 = 0,
    match_source: usize = 0,
    dynamic_literal_count: usize = 0,
    dynamic_distance_count: usize = 0,
    dynamic_code_length_count: usize = 0,
    dynamic_index: usize = 0,
    dynamic_repeat_symbol: u16 = 0,
    window_next: usize = 0,
    window_filled: usize = 0,

    pub fn init(window: []u8, workspace: *Workspace) InflateState {
        return .{ .window = window, .workspace = workspace };
    }

    /// Consumes a prefix of `input` and fills a prefix of `output`.  A caller
    /// must retain only the unconsumed suffix before supplying the next file
    /// chunk; all bit and history state is retained here.
    pub fn step(self: *InflateState, input: []const u8, output: []u8) Error!StepResult {
        var input_index: usize = 0;
        var output_index: usize = 0;
        while (true) {
            switch (self.phase) {
                .block_final => {
                    const value = self.readBits(input, &input_index, 1) orelse return self.result(input_index, output_index, .needs_input);
                    self.final_block = value != 0;
                    self.phase = .block_type;
                },
                .block_type => {
                    const value = self.readBits(input, &input_index, 2) orelse return self.result(input_index, output_index, .needs_input);
                    switch (value) {
                        0 => self.phase = .stored_align,
                        1 => {
                            self.initFixedCodes();
                            self.phase = .compressed_symbol;
                        },
                        2 => self.phase = .dynamic_literal_count,
                        else => return error.UnsupportedBlockType,
                    }
                },
                .stored_align => {
                    self.bits = 0;
                    self.bit_count = 0;
                    self.phase = .stored_length;
                },
                .stored_length => {
                    const value = self.readBits(input, &input_index, 16) orelse return self.result(input_index, output_index, .needs_input);
                    self.stored_remaining = @intCast(value);
                    self.phase = .stored_length_inverse;
                },
                .stored_length_inverse => {
                    const value = self.readBits(input, &input_index, 16) orelse return self.result(input_index, output_index, .needs_input);
                    if (self.stored_remaining ^ @as(u16, @intCast(value)) != 0xffff) return error.InvalidStoredBlock;
                    self.phase = .stored_bytes;
                },
                .stored_bytes => {
                    if (self.stored_remaining == 0) {
                        self.phase = if (self.final_block) .done else .block_final;
                        continue;
                    }
                    if (output_index == output.len) return self.result(input_index, output_index, .needs_output);
                    const value = self.readBits(input, &input_index, 8) orelse return self.result(input_index, output_index, .needs_input);
                    self.writeByte(output, &output_index, @intCast(value));
                    self.stored_remaining -= 1;
                },
                .compressed_symbol => {
                    const symbol = try self.decode(&self.workspace.literal_codes, input, &input_index) orelse return self.result(input_index, output_index, .needs_input);
                    if (symbol < 256) {
                        self.pending_literal = @intCast(symbol);
                        self.phase = .literal_write;
                    } else if (symbol == 256) {
                        self.phase = if (self.final_block) .done else .block_final;
                    } else {
                        const length_index = symbol - 257;
                        if (length_index >= length_bases.len) return error.InvalidLengthSymbol;
                        self.pending_length = length_bases[length_index];
                        self.pending_extra_bits = length_extra_bits[length_index];
                        self.phase = .length_extra;
                    }
                },
                .literal_write => {
                    if (output_index == output.len) return self.result(input_index, output_index, .needs_output);
                    self.writeByte(output, &output_index, self.pending_literal);
                    self.phase = .compressed_symbol;
                },
                .length_extra => {
                    const extra = self.readBits(input, &input_index, self.pending_extra_bits) orelse return self.result(input_index, output_index, .needs_input);
                    self.pending_length += @intCast(extra);
                    self.phase = .distance_symbol;
                },
                .distance_symbol => {
                    const symbol = try self.decode(&self.workspace.distance_codes, input, &input_index) orelse return self.result(input_index, output_index, .needs_input);
                    if (symbol >= distance_bases.len) return error.InvalidDistance;
                    self.pending_distance = distance_bases[symbol];
                    self.pending_extra_bits = distance_extra_bits[symbol];
                    self.phase = .distance_extra;
                },
                .distance_extra => {
                    const extra = self.readBits(input, &input_index, self.pending_extra_bits) orelse return self.result(input_index, output_index, .needs_input);
                    const distance = std.math.add(u16, self.pending_distance, @intCast(extra)) catch return error.InvalidDistance;
                    if (self.window.len < 32 * 1024 or distance == 0 or distance > self.window_filled) return error.InvalidDistance;
                    self.match_remaining = self.pending_length;
                    self.match_source = (self.window_next + self.window.len - distance) % self.window.len;
                    self.phase = .match_copy;
                },
                .match_copy => {
                    if (self.match_remaining == 0) {
                        self.phase = .compressed_symbol;
                        continue;
                    }
                    if (output_index == output.len) return self.result(input_index, output_index, .needs_output);
                    const value = self.window[self.match_source];
                    self.writeByte(output, &output_index, value);
                    self.match_source = (self.match_source + 1) % self.window.len;
                    self.match_remaining -= 1;
                },
                .dynamic_literal_count => {
                    const value = self.readBits(input, &input_index, 5) orelse return self.result(input_index, output_index, .needs_input);
                    self.dynamic_literal_count = 257 + value;
                    self.phase = .dynamic_distance_count;
                },
                .dynamic_distance_count => {
                    const value = self.readBits(input, &input_index, 5) orelse return self.result(input_index, output_index, .needs_input);
                    self.dynamic_distance_count = 1 + value;
                    self.phase = .dynamic_code_length_count;
                },
                .dynamic_code_length_count => {
                    const value = self.readBits(input, &input_index, 4) orelse return self.result(input_index, output_index, .needs_input);
                    self.dynamic_code_length_count = 4 + value;
                    @memset(&self.workspace.code_length_lengths, 0);
                    @memset(&self.workspace.lengths, 0);
                    self.dynamic_index = 0;
                    self.phase = .dynamic_code_length_lengths;
                },
                .dynamic_code_length_lengths => {
                    if (self.dynamic_index == self.dynamic_code_length_count) {
                        try self.workspace.code_length_codes.init(&self.workspace.code_length_lengths, &self.workspace.counts, &self.workspace.next_code);
                        self.decode_node = 0;
                        self.dynamic_index = 0;
                        self.phase = .dynamic_lengths;
                        continue;
                    }
                    const value = self.readBits(input, &input_index, 3) orelse return self.result(input_index, output_index, .needs_input);
                    const order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
                    self.workspace.code_length_lengths[order[self.dynamic_index]] = @intCast(value);
                    self.dynamic_index += 1;
                },
                .dynamic_lengths => {
                    const total = self.dynamic_literal_count + self.dynamic_distance_count;
                    if (self.dynamic_index == total) {
                        if (self.workspace.lengths[256] == 0) return error.MissingEndCode;
                        try self.workspace.literal_codes.init(self.workspace.lengths[0..self.dynamic_literal_count], &self.workspace.counts, &self.workspace.next_code);
                        try self.workspace.distance_codes.init(self.workspace.lengths[self.dynamic_literal_count..total], &self.workspace.counts, &self.workspace.next_code);
                        self.decode_node = 0;
                        self.phase = .compressed_symbol;
                        continue;
                    }
                    const symbol = try self.decode(&self.workspace.code_length_codes, input, &input_index) orelse return self.result(input_index, output_index, .needs_input);
                    if (symbol <= 15) {
                        self.workspace.lengths[self.dynamic_index] = @intCast(symbol);
                        self.dynamic_index += 1;
                    } else if (symbol <= 18) {
                        if (symbol == 16 and self.dynamic_index == 0) return error.InvalidDynamicHeader;
                        self.dynamic_repeat_symbol = symbol;
                        self.phase = .dynamic_repeat;
                    } else return error.InvalidDynamicHeader;
                },
                .dynamic_repeat => {
                    const bits: u5 = switch (self.dynamic_repeat_symbol) { 16 => 2, 17 => 3, 18 => 7, else => return error.InvalidDynamicHeader };
                    const extra = self.readBits(input, &input_index, bits) orelse return self.result(input_index, output_index, .needs_input);
                    const count: usize = switch (self.dynamic_repeat_symbol) { 16 => 3 + extra, 17 => 3 + extra, 18 => 11 + extra, else => unreachable };
                    const total = self.dynamic_literal_count + self.dynamic_distance_count;
                    if (count > total - self.dynamic_index) return error.InvalidDynamicHeader;
                    const value: u8 = if (self.dynamic_repeat_symbol == 16) self.workspace.lengths[self.dynamic_index - 1] else 0;
                    @memset(self.workspace.lengths[self.dynamic_index .. self.dynamic_index + count], value);
                    self.dynamic_index += count;
                    self.phase = .dynamic_lengths;
                },
                .done => return self.result(input_index, output_index, .end),
            }
        }
    }

    fn result(_: *const InflateState, input_used: usize, output_written: usize, status: StreamStatus) StepResult {
        return .{ .input_used = input_used, .output_written = output_written, .status = status };
    }

    fn readBits(self: *InflateState, input: []const u8, input_index: *usize, count: u5) ?u32 {
        while (self.bit_count < count) {
            if (input_index.* == input.len) return null;
            self.bits |= @as(u32, input[input_index.*]) << self.bit_count;
            self.bit_count += 8;
            input_index.* += 1;
        }
        const mask = (@as(u32, 1) << count) - 1;
        const value = self.bits & mask;
        self.bits >>= count;
        self.bit_count -= count;
        return value;
    }

    fn initFixedCodes(self: *InflateState) void {
        for (0..144) |index| self.workspace.lengths[index] = 8;
        for (144..256) |index| self.workspace.lengths[index] = 9;
        for (256..280) |index| self.workspace.lengths[index] = 7;
        for (280..288) |index| self.workspace.lengths[index] = 8;
        self.workspace.literal_codes.init(self.workspace.lengths[0..288], &self.workspace.counts, &self.workspace.next_code) catch unreachable;
        @memset(self.workspace.lengths[0..32], 5);
        self.workspace.distance_codes.init(self.workspace.lengths[0..32], &self.workspace.counts, &self.workspace.next_code) catch unreachable;
    }

    /// `null` means a valid prefix needs another input byte. An absent branch
    /// is a malformed Huffman code and must not be treated as that condition.
    fn decode(self: *InflateState, codes: *const Huffman, input: []const u8, input_index: *usize) Error!?u16 {
        while (true) {
            const bit = self.readBits(input, input_index, 1) orelse return null;
            const child = codes.nodes[self.decode_node].child[bit];
            if (child == Huffman.no_child) return error.InvalidHuffmanCode;
            if (child < 0) {
                self.decode_node = 0;
                return @intCast(-child - 1);
            }
            self.decode_node = @intCast(child);
        }
    }

    fn writeByte(self: *InflateState, output: []u8, output_index: *usize, value: u8) void {
        output[output_index.*] = value;
        output_index.* += 1;
        if (self.window.len != 0) {
            self.window[self.window_next] = value;
            self.window_next = (self.window_next + 1) % self.window.len;
            self.window_filled = @min(self.window_filled + 1, self.window.len);
        }
    }
};

test "streaming inflater rejects an invalid Huffman branch" {
    var window: [32 * 1024]u8 = undefined;
    var workspace: Workspace = undefined;
    @memset(&workspace.lengths, 0);
    // A one-bit tree containing only code 0 leaves code 1 invalid.
    workspace.lengths[256] = 1;
    try workspace.literal_codes.init(workspace.lengths[0..288], &workspace.counts, &workspace.next_code);

    var state = InflateState.init(&window, &workspace);
    state.phase = .compressed_symbol;
    var output: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidHuffmanCode, state.step(&[_]u8{1}, &output));
}

test "streaming inflater distinguishes incomplete input from an invalid Huffman branch" {
    var window: [32 * 1024]u8 = undefined;
    var workspace: Workspace = undefined;
    @memset(&workspace.lengths, 0);
    workspace.lengths[256] = 1;
    try workspace.literal_codes.init(workspace.lengths[0..288], &workspace.counts, &workspace.next_code);

    var state = InflateState.init(&window, &workspace);
    state.phase = .compressed_symbol;
    var output: [1]u8 = undefined;
    const incomplete = try state.step(&.{}, &output);
    try std.testing.expectEqual(StreamStatus.needs_input, incomplete.status);
    try std.testing.expectEqual(@as(usize, 0), incomplete.input_used);
    try std.testing.expectError(error.InvalidHuffmanCode, state.step(&[_]u8{1}, &output));
}

test "resumes a stored DEFLATE block across input and output chunks" {
    const compressed = [_]u8{ 0x01, 0x03, 0x00, 0xfc, 0xff, 'c', 'a', 't' };
    var window: [32 * 1024]u8 = undefined;
    var workspace: Workspace = undefined;
    var state = InflateState.init(&window, &workspace);
    var output: [3]u8 = undefined;
    var output_chunk: [1]u8 = undefined;
    var input_offset: usize = 0;
    var output_offset: usize = 0;

    while (true) {
        const input_end = @min(input_offset + 1, compressed.len);
        const result = try state.step(compressed[input_offset..input_end], &output_chunk);
        input_offset += result.input_used;
        @memcpy(output[output_offset .. output_offset + result.output_written], output_chunk[0..result.output_written]);
        output_offset += result.output_written;
        switch (result.status) {
            .end => break,
            .needs_input => try std.testing.expectEqual(input_end, input_offset),
            .needs_output => try std.testing.expectEqual(@as(usize, 1), result.output_written),
        }
    }
    try std.testing.expectEqual(compressed.len, input_offset);
    try std.testing.expectEqualStrings("cat", &output);
}

test "resumes fixed-Huffman literals and matches across chunks" {
    const compressed = [_]u8{ 0x4b, 0x4c, 0x4a, 0x4e, 0x44, 0x45, 0x00 };
    var window: [32 * 1024]u8 = undefined;
    var workspace: Workspace = undefined;
    var state = InflateState.init(&window, &workspace);
    var output: [18]u8 = undefined;
    var output_chunk: [2]u8 = undefined;
    var input_offset: usize = 0;
    var output_offset: usize = 0;

    while (true) {
        const input_end = @min(input_offset + 1, compressed.len);
        const result = try state.step(compressed[input_offset..input_end], &output_chunk);
        input_offset += result.input_used;
        @memcpy(output[output_offset .. output_offset + result.output_written], output_chunk[0..result.output_written]);
        output_offset += result.output_written;
        if (result.status == .end) break;
    }
    try std.testing.expectEqual(compressed.len, input_offset);
    try std.testing.expectEqualStrings("abcabcabcabcabcabc", &output);
}

test "resumes dynamic-Huffman blocks across chunks" {
    const compressed = comptime hexBytes("edcd410dc3300c05502a1fc05424bd0d81175b95a5246e139bff0e83b14fe0bd33960df8bd6b40a3c7c2f6840ccb175acc6d2d2d6b41d46fdfcde705eb9e07dea6d08079ed118ab471c782cfe6ea5a3351892e9f5806cb1f6d18724d81747f4a0e9cbc79f3e6cd9b376fdebc79f3e6cdfbefee2f");
    const phrase = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. ";
    var expected: [phrase.len * 30]u8 = undefined;
    for (0..30) |index| @memcpy(expected[index * phrase.len ..][0..phrase.len], phrase);
    var output: [expected.len]u8 = undefined;
    var chunk: [7]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: Workspace = undefined;
    var state = InflateState.init(&window, &workspace);
    var input_offset: usize = 0;
    var output_offset: usize = 0;
    while (true) {
        const input_end = @min(input_offset + 1, compressed.len);
        const result = try state.step(compressed[input_offset..input_end], &chunk);
        input_offset += result.input_used;
        @memcpy(output[output_offset .. output_offset + result.output_written], chunk[0..result.output_written]);
        output_offset += result.output_written;
        if (result.status == .end) break;
    }
    try std.testing.expectEqualSlices(u8, &expected, &output);
}

const BitReader = struct {
    input: []const u8,
    next_byte: usize = 0,
    bits: u32 = 0,
    bit_count: u5 = 0,

    fn init(input: []const u8) BitReader {
        return .{ .input = input };
    }

    fn readBits(self: *BitReader, count: u5) Error!u32 {
        while (self.bit_count < count) {
            if (self.next_byte == self.input.len) return error.UnexpectedEof;
            self.bits |= @as(u32, self.input[self.next_byte]) << self.bit_count;
            self.bit_count += 8;
            self.next_byte += 1;
        }
        const mask = (@as(u32, 1) << count) - 1;
        const result = self.bits & mask;
        self.bits >>= count;
        self.bit_count -= count;
        return result;
    }

    fn alignToByte(self: *BitReader) void {
        self.bits = 0;
        self.bit_count = 0;
    }
};

test "inflates a final stored block" {
    const compressed = [_]u8{ 0x01, 0x03, 0x00, 0xfc, 0xff, 'c', 'a', 't' };
    var output: [3]u8 = undefined;
    var workspace: Workspace = undefined;

    const output_len = try inflateRaw(&compressed, &output, &.{}, &workspace);
    try std.testing.expectEqualStrings("cat", output[0..output_len]);
}

test "inflates a fixed-Huffman block" {
    const compressed = [_]u8{ 0x4b, 0xcb, 0xac, 0x48, 0x4d, 0x51, 0xc8, 0x28, 0x4d, 0x4b, 0xcb, 0x4d, 0xcc, 0x03, 0x00 };
    var output: [32]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: Workspace = undefined;

    const output_len = try inflateRaw(&compressed, &output, &window, &workspace);
    try std.testing.expectEqualStrings("fixed huffman", output[0..output_len]);
}

test "inflates fixed-Huffman length and distance matches" {
    const compressed = [_]u8{ 0x4b, 0x4c, 0x4a, 0x4e, 0x44, 0x45, 0x00 };
    var output: [32]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: Workspace = undefined;

    const output_len = try inflateRaw(&compressed, &output, &window, &workspace);
    try std.testing.expectEqualStrings("abcabcabcabcabcabc", output[0..output_len]);
}

test "inflates a dynamic-Huffman block" {
    const compressed = comptime hexBytes("edcd410dc3300c05502a1fc05424bd0d81175b95a5246e139bff0e83b14fe0bd33960df8bd6b40a3c7c2f6840ccb175acc6d2d2d6b41d46fdfcde705eb9e07dea6d08079ed118ab471c782cfe6ea5a3351892e9f5806cb1f6d18724d81747f4a0e9cbc79f3e6cd9b376fdebc79f3e6cdfbefee2f");
    const phrase = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. ";
    var expected: [phrase.len * 30]u8 = undefined;
    for (0..30) |index| @memcpy(expected[index * phrase.len ..][0..phrase.len], phrase);
    var output: [expected.len]u8 = undefined;
    var window: [32 * 1024]u8 = undefined;
    var workspace: Workspace = undefined;

    const output_len = try inflateRaw(&compressed, &output, &window, &workspace);
    try std.testing.expectEqual(expected.len, output_len);
    try std.testing.expectEqualSlices(u8, &expected, output[0..output_len]);
}

fn hexBytes(comptime text: []const u8) [text.len / 2]u8 {
    comptime std.debug.assert(text.len % 2 == 0);
    var result: [text.len / 2]u8 = undefined;
    for (0..result.len) |index| {
        result[index] = (hexNibble(text[index * 2]) << 4) | hexNibble(text[index * 2 + 1]);
    }
    return result;
}

fn hexNibble(comptime byte: u8) u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => @compileError("invalid hexadecimal digit"),
    };
}
