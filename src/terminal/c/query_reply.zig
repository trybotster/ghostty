//! Encoders for the replies that a client gives to a terminal query.
//!
//! The terminal itself answers some queries (see size_report.zig and
//! device_status.zig). A host that offers a query to another party, and that
//! then gets structured values back, needs the bytes of the reply that the
//! program expects. This module writes them, so the host never writes
//! terminal protocol bytes itself.

const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const osc = @import("../osc.zig");
const Result = @import("result.zig").Result;

/// What the reply answers.
///
/// C: GhosttyQueryReplyKind
pub const Kind = lib.Enum(lib.target, &.{
    // Never valid. This exists so that a zeroed C value is not mistaken for
    // a real reply.
    "invalid",

    // CSI 4 ; height ; width t. The answer to CSI 14 t (text area size in
    // pixels) and to CSI 14 ; 2 t (window size in pixels): both use this
    // form.
    "pixels_text_area",

    // CSI 6 ; height ; width t. The answer to CSI 16 t (cell size).
    "pixels_cell",

    // CSI 5 ; height ; width t. The answer to CSI 15 t (screen size).
    "pixels_screen",

    // CSI 9 ; rows ; cols t. The answer to CSI 19 t (screen size in cells).
    "chars_screen",

    // CSI 2 t when iconified, CSI 1 t otherwise. The answer to CSI 11 t.
    "window_state",

    // CSI 3 ; x ; y t. The answer to CSI 13 t and CSI 13 ; 2 t.
    "window_position",

    // OSC l text ST. The answer to CSI 21 t.
    "window_title",

    // OSC L text ST. The answer to CSI 20 t.
    "icon_label",

    // OSC 52 ; selection ; base64 terminator. The answer to an OSC 52
    // read.
    "clipboard",
});

/// A reply. Each kind reads only the fields that it names.
///
/// C: GhosttyQueryReply
pub const Reply = extern struct {
    size: usize,
    kind: Kind,

    /// pixels_*: the width in pixels.
    width: u32,
    /// pixels_*: the height in pixels.
    height: u32,

    /// chars_screen: the number of rows.
    rows: u32,
    /// chars_screen: the number of columns.
    cols: u32,

    /// window_position: the position, 0 to 65535 as on the wire.
    x: u16,
    y: u16,

    /// window_state: whether the window is iconified.
    iconified: bool,

    /// window_title and icon_label: the UTF-8 text. clipboard: the raw
    /// bytes, which are base64 encoded.
    text: lib.String,

    /// clipboard: the selection of the request, characters from
    /// `c p q s 0 1 2 3 4 5 6 7`.
    selection: lib.String,

    /// clipboard: the terminator of the request.
    terminator: osc.Terminator.C,
};

pub const EncodeError = std.Io.Writer.Error || error{InvalidValue};

fn slice(s: lib.String) []const u8 {
    return if (s.len == 0) "" else s.ptr[0..s.len];
}

/// Window title and icon label text: valid UTF-8 with no control codepoint,
/// so that the text cannot end the OSC sequence or start another one.
fn validText(text: []const u8) bool {
    const view = std.unicode.Utf8View.init(text) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F)) return false;
    }
    return true;
}

fn validSelection(selection: []const u8) bool {
    for (selection) |c| switch (c) {
        'c', 'p', 'q', 's', '0'...'7' => {},
        else => return false,
    };
    return true;
}

pub fn encodeReply(writer: *std.Io.Writer, reply: Reply) EncodeError!void {
    switch (reply.kind) {
        .invalid => return error.InvalidValue,

        .pixels_text_area => try writer.print("\x1b[4;{d};{d}t", .{ reply.height, reply.width }),
        .pixels_cell => try writer.print("\x1b[6;{d};{d}t", .{ reply.height, reply.width }),
        .pixels_screen => try writer.print("\x1b[5;{d};{d}t", .{ reply.height, reply.width }),
        .chars_screen => try writer.print("\x1b[9;{d};{d}t", .{ reply.rows, reply.cols }),

        .window_state => try writer.writeAll(if (reply.iconified) "\x1b[2t" else "\x1b[1t"),

        .window_position => try writer.print("\x1b[3;{d};{d}t", .{ reply.x, reply.y }),

        .window_title, .icon_label => {
            const text = slice(reply.text);
            if (!validText(text)) return error.InvalidValue;
            try writer.writeAll(if (reply.kind == .window_title) "\x1b]l" else "\x1b]L");
            try writer.writeAll(text);
            try writer.writeAll("\x1b\\");
        },

        .clipboard => {
            const selection = slice(reply.selection);
            if (!validSelection(selection)) return error.InvalidValue;

            try writer.writeAll("\x1b]52;");
            try writer.writeAll(selection);
            try writer.writeByte(';');

            // Base64 in chunks, so that no allocation is needed.
            const encoder = std.base64.standard.Encoder;
            var chunk: [3 * 256]u8 = undefined;
            var out: [4 * 256]u8 = undefined;
            _ = &chunk;
            var rest = slice(reply.text);
            while (rest.len > 0) {
                const n = @min(rest.len, chunk.len);
                try writer.writeAll(encoder.encode(&out, rest[0..n]));
                rest = rest[n..];
            }

            try writer.writeAll(switch (reply.terminator) {
                .st => "\x1b\\",
                .bel => "\x07",
            });
        },
    }
}

/// The layout of `Reply` with every enum and bool read as an integer, so
/// that an argument with an unknown value is refused instead of read as an
/// invalid enum.
const RawReply = extern struct {
    size: usize,
    kind: c_int,
    width: u32,
    height: u32,
    rows: u32,
    cols: u32,
    x: u16,
    y: u16,
    iconified: u8,
    text: lib.String,
    selection: lib.String,
    terminator: c_int,
};

comptime {
    std.debug.assert(@sizeOf(RawReply) == @sizeOf(Reply));
    std.debug.assert(@alignOf(RawReply) == @alignOf(Reply));
    for (@typeInfo(Reply).@"struct".fields) |field| {
        std.debug.assert(@offsetOf(RawReply, field.name) == @offsetOf(Reply, field.name));
    }
}

pub fn encode(
    reply_: ?*const Reply,
    out_: ?[*]u8,
    out_len: usize,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const raw: *const RawReply = @ptrCast(reply_ orelse return .invalid_value);
    const written = out_written orelse return .invalid_value;
    if (raw.size < @sizeOf(RawReply)) return .invalid_value;

    // Check every enum and bool before it becomes a typed value.
    const kind = std.enums.fromInt(Kind, raw.kind) orelse return .invalid_value;
    const terminator = std.enums.fromInt(osc.Terminator.C, raw.terminator) orelse
        return .invalid_value;
    if (raw.iconified > 1) return .invalid_value;

    const reply: Reply = .{
        .size = raw.size,
        .kind = kind,
        .width = raw.width,
        .height = raw.height,
        .rows = raw.rows,
        .cols = raw.cols,
        .x = raw.x,
        .y = raw.y,
        .iconified = raw.iconified == 1,
        .text = raw.text,
        .selection = raw.selection,
        .terminator = terminator,
    };

    var writer: std.Io.Writer = .fixed(if (out_) |out| out[0..out_len] else &.{});
    encodeReply(&writer, reply) catch |err| switch (err) {
        error.InvalidValue => return .invalid_value,
        error.WriteFailed => {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            encodeReply(&discarding.writer, reply) catch return .invalid_value;
            written.* = @intCast(discarding.count);
            return .out_of_space;
        },
    };

    written.* = writer.end;
    return .success;
}

fn base(kind: Kind) Reply {
    return .{
        .size = @sizeOf(Reply),
        .kind = kind,
        .width = 0,
        .height = 0,
        .rows = 0,
        .cols = 0,
        .x = 0,
        .y = 0,
        .iconified = false,
        .text = .init(@as([]const u8, "")),
        .selection = .init(@as([]const u8, "")),
        .terminator = .st,
    };
}

fn encodeToSlice(buf: []u8, reply: Reply) ![]const u8 {
    var written: usize = 0;
    try testing.expectEqual(Result.success, encode(&reply, buf.ptr, buf.len, &written));
    return buf[0..written];
}

const Parser = @import("../Parser.zig");

/// What the terminal's own parser reads from the bytes of a reply. The tests
/// check replies through it, so no test writes terminal bytes by hand.
const Parsed = struct {
    csi_params: [8]u16 = undefined,
    csi_len: usize = 0,
    csi_final: ?u8 = null,

    osc_unknown: [256]u8 = undefined,
    osc_unknown_len: usize = 0,
    osc_terminator: ?osc.Terminator = null,

    clipboard_kind: ?u8 = null,
    clipboard_data: [4096]u8 = undefined,
    clipboard_len: usize = 0,
    clipboard_terminator: ?osc.Terminator = null,

    fn params(self: *const Parsed) []const u16 {
        return self.csi_params[0..self.csi_len];
    }

    fn unknown(self: *const Parsed) []const u8 {
        return self.osc_unknown[0..self.osc_unknown_len];
    }

    fn clipboard(self: *const Parsed) []const u8 {
        return self.clipboard_data[0..self.clipboard_len];
    }
};

fn parse(bytes: []const u8) !Parsed {
    var parser: Parser = .init();
    defer parser.deinit();
    parser.osc_parser.unknown_max_bytes = 1024;

    var result: Parsed = .{};
    for (bytes) |c| {
        for (parser.next(c)) |maybe| {
            const action = maybe orelse continue;
            switch (action) {
                .csi_dispatch => |csi| {
                    try testing.expect(result.csi_final == null);
                    try testing.expect(csi.params.len <= result.csi_params.len);
                    @memcpy(result.csi_params[0..csi.params.len], csi.params);
                    result.csi_len = csi.params.len;
                    result.csi_final = csi.final;
                },
                .osc_dispatch => |cmd| switch (cmd) {
                    .unknown => |u| {
                        try testing.expect(u.content.len <= result.osc_unknown.len);
                        @memcpy(result.osc_unknown[0..u.content.len], u.content);
                        result.osc_unknown_len = u.content.len;
                        result.osc_terminator = u.terminator;
                    },
                    .clipboard_contents => |clip| {
                        result.clipboard_kind = clip.kind;
                        try testing.expect(clip.data.len <= result.clipboard_data.len);
                        @memcpy(result.clipboard_data[0..clip.data.len], clip.data);
                        result.clipboard_len = clip.data.len;
                        result.clipboard_terminator = clip.terminator;
                    },
                    else => return error.UnexpectedCommand,
                },
                // The backslash of an ST arrives as an ESC dispatch after the OSC
                // was dispatched at the ESC.
                .esc_dispatch => {},
                else => return error.UnexpectedAction,
            }
        }
    }
    return result;
}

test "pixel replies match the terminal's own size reports and carry height before width" {
    var buf: [64]u8 = undefined;
    const size_report = @import("../size_report.zig");
    const size: size_report.Size = .{ .rows = 24, .columns = 80, .cell_width = 9, .cell_height = 18 };

    // Text area and cell pixels: the terminal's encoder writes the same
    // form, so its parsed output is the expectation.
    const cases = [_]struct { kind: Kind, style: size_report.Style, width: u32, height: u32 }{
        .{ .kind = .pixels_text_area, .style = .csi_14_t, .width = 80 * 9, .height = 24 * 18 },
        .{ .kind = .pixels_cell, .style = .csi_16_t, .width = 9, .height = 18 },
    };
    for (cases) |case| {
        var oracle: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&oracle);
        try size_report.encode(&w, case.style, size);
        const expected = try parse(w.buffered());

        var r = base(case.kind);
        r.width = case.width;
        r.height = case.height;
        const actual = try parse(try encodeToSlice(&buf, r));
        try testing.expectEqual(expected.csi_final, actual.csi_final);
        try testing.expectEqualSlices(u16, expected.params(), actual.params());
    }
}

test "screen pixels and screen chars differ from their neighbours in the first parameter only" {
    var buf: [64]u8 = undefined;
    const size_report = @import("../size_report.zig");
    const size: size_report.Size = .{ .rows = 24, .columns = 80, .cell_width = 9, .cell_height = 18 };

    // Screen pixels: the text area form with another first parameter.
    var text_area = base(.pixels_text_area);
    text_area.width = 1920;
    text_area.height = 1080;
    const a = try parse(try encodeToSlice(&buf, text_area));
    var screen = text_area;
    screen.kind = .pixels_screen;
    var buf2: [64]u8 = undefined;
    const b = try parse(try encodeToSlice(&buf2, screen));
    try testing.expectEqual(a.csi_final, b.csi_final);
    try testing.expectEqual(@as(usize, 3), b.params().len);
    try testing.expect(a.params()[0] != b.params()[0]);
    try testing.expectEqualSlices(u16, a.params()[1..], b.params()[1..]);

    // Screen chars: the terminal's own text area chars report (rows, then
    // columns) with another first parameter.
    var oracle: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&oracle);
    try size_report.encode(&w, .csi_18_t, size);
    const chars_oracle = try parse(w.buffered());

    var chars = base(.chars_screen);
    chars.rows = 24;
    chars.cols = 80;
    var buf3: [64]u8 = undefined;
    const c = try parse(try encodeToSlice(&buf3, chars));
    try testing.expectEqual(chars_oracle.csi_final, c.csi_final);
    try testing.expect(chars_oracle.params()[0] != c.params()[0]);
    try testing.expectEqualSlices(u16, chars_oracle.params()[1..], c.params()[1..]);
}

test "window state and position" {
    var buf: [64]u8 = undefined;

    // The two window states are the same form with another parameter.
    var s = base(.window_state);
    const open_state = try parse(try encodeToSlice(&buf, s));
    s.iconified = true;
    var buf2: [64]u8 = undefined;
    const iconified = try parse(try encodeToSlice(&buf2, s));
    try testing.expectEqual(open_state.csi_final, iconified.csi_final);
    try testing.expectEqual(@as(usize, 1), open_state.params().len);
    try testing.expectEqual(@as(usize, 1), iconified.params().len);
    try testing.expect(open_state.params()[0] != iconified.params()[0]);

    // Position: the form of the size reports, x first and then y.
    const size_report = @import("../size_report.zig");
    var oracle: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&oracle);
    try size_report.encode(&w, .csi_14_t, .{ .rows = 1, .columns = 1, .cell_width = 1, .cell_height = 1 });
    const form = try parse(w.buffered());

    var p = base(.window_position);
    p.x = 65535;
    p.y = 34;
    var buf3: [64]u8 = undefined;
    const pos = try parse(try encodeToSlice(&buf3, p));
    try testing.expectEqual(form.csi_final, pos.csi_final);
    try testing.expectEqual(@as(usize, 3), pos.params().len);
    try testing.expectEqual(@as(u16, 65535), pos.params()[1]);
    try testing.expectEqual(@as(u16, 34), pos.params()[2]);
}

test "title and icon label wrap the text and refuse control codepoints" {
    var buf: [128]u8 = undefined;
    const text = "héllo wörld";

    var t = base(.window_title);
    t.text = .init(@as([]const u8, text));
    const title = try parse(try encodeToSlice(&buf, t));

    var i = base(.icon_label);
    i.text = .init(@as([]const u8, text));
    var buf2: [128]u8 = undefined;
    const icon = try parse(try encodeToSlice(&buf2, i));

    // One letter names the reply, then the text, and the sequence ends with
    // ST. The two kinds differ in the letter only.
    try testing.expectEqualStrings(text, title.unknown()[1..]);
    try testing.expectEqualStrings(text, icon.unknown()[1..]);
    try testing.expect(title.unknown()[0] != icon.unknown()[0]);
    try testing.expectEqual(std.ascii.toUpper(title.unknown()[0]), icon.unknown()[0]);
    try testing.expectEqual(osc.Terminator.st, title.osc_terminator.?);
    try testing.expectEqual(osc.Terminator.st, icon.osc_terminator.?);

    // Text that could end the OSC or start a sequence is refused: ESC, BEL,
    // DEL and a C1 codepoint, and bytes that are not UTF-8.
    const bad = [_][]const u8{ "a\x1b[31mb", "a\x07b", "a\x7fb", "a\u{85}b", "\xff\xfe" };
    for (bad) |bad_text| {
        var r = base(.window_title);
        r.text = .init(bad_text);
        var written: usize = 0;
        try testing.expectEqual(Result.invalid_value, encode(&r, &buf, buf.len, &written));
    }
}

test "clipboard reply carries the selection, base64 and the request terminator" {
    var buf: [256]u8 = undefined;
    const payload = "hello";

    for ([_]osc.Terminator.C{ .st, .bel }) |terminator| {
        var r = base(.clipboard);
        r.selection = .init(@as([]const u8, "q"));
        r.text = .init(@as([]const u8, payload));
        r.terminator = terminator;
        const parsed = try parse(try encodeToSlice(&buf, r));

        // The native OSC 52 parser reads the selection, the data and the
        // terminator back.
        try testing.expectEqual(@as(?u8, 'q'), parsed.clipboard_kind);
        try testing.expectEqual(switch (terminator) {
            .st => osc.Terminator.st,
            .bel => osc.Terminator.bel,
        }, parsed.clipboard_terminator.?);
        var decoded: [64]u8 = undefined;
        const len = try std.base64.standard.Decoder.calcSizeForSlice(parsed.clipboard());
        try std.base64.standard.Decoder.decode(decoded[0..len], parsed.clipboard());
        try testing.expectEqualStrings(payload, decoded[0..len]);
    }

    // The selection of the request is kept: each allowed character is read
    // back as the same character.
    for ("cpqs01234567") |sel| {
        var r = base(.clipboard);
        r.selection = .init(@as([]const u8, &[_]u8{sel}));
        r.text = .init(@as([]const u8, payload));
        var b: [256]u8 = undefined;
        const parsed = try parse(try encodeToSlice(&b, r));
        try testing.expectEqual(@as(?u8, sel), parsed.clipboard_kind);
    }

    // A two character selection is the one character form with one more
    // byte after the selection (the native parser reads only one character).
    var one = base(.clipboard);
    one.selection = .init(@as([]const u8, "s"));
    one.text = .init(@as([]const u8, payload));
    var two = one;
    two.selection = .init(@as([]const u8, "s0"));
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const one_bytes = try encodeToSlice(&b1, one);
    const two_bytes = try encodeToSlice(&b2, two);
    try testing.expectEqual(one_bytes.len + 1, two_bytes.len);
    const sel_end = std.mem.indexOfScalar(u8, one_bytes, 's').? + 1;
    try testing.expectEqualSlices(u8, one_bytes[0..sel_end], two_bytes[0..sel_end]);
    try testing.expectEqualSlices(u8, one_bytes[sel_end..], two_bytes[sel_end + 1 ..]);

    // An empty clipboard is an empty data part.
    var empty = base(.clipboard);
    empty.selection = .init(@as([]const u8, "c"));
    var b3: [256]u8 = undefined;
    const parsed_empty = try parse(try encodeToSlice(&b3, empty));
    try testing.expectEqual(@as(usize, 0), parsed_empty.clipboard_len);

    // A selection outside the allowed set is refused.
    var bad = base(.clipboard);
    bad.selection = .init(@as([]const u8, "c;x"));
    var written: usize = 0;
    try testing.expectEqual(Result.invalid_value, encode(&bad, &buf, buf.len, &written));
}

test "clipboard base64 of a payload longer than one chunk" {
    // 1000 bytes is more than one 768 byte chunk, and its base64 text still
    // fits the fixed OSC buffer of a parser without an allocator.
    var payload: [1000]u8 = undefined;
    for (&payload, 0..) |*b, n| b.* = @truncate(n *% 7);

    var out: [2000]u8 = undefined;
    var r = base(.clipboard);
    r.selection = .init(@as([]const u8, "c"));
    r.text = .init(@as([]const u8, &payload));
    const parsed = try parse(try encodeToSlice(&out, r));

    var decoded: [1000]u8 = undefined;
    try testing.expectEqual(@as(usize, 1000), try std.base64.standard.Decoder.calcSizeForSlice(parsed.clipboard()));
    try std.base64.standard.Decoder.decode(&decoded, parsed.clipboard());
    try testing.expectEqualSlices(u8, &payload, &decoded);
}

test "encode reports the size needed and refuses bad arguments" {
    var r = base(.pixels_screen);
    r.width = 1;
    r.height = 2;
    var written: usize = 0;
    var tiny: [2]u8 = undefined;
    try testing.expectEqual(Result.out_of_space, encode(&r, &tiny, tiny.len, &written));
    try testing.expect(written > tiny.len);

    try testing.expectEqual(Result.out_of_space, encode(&r, null, 0, &written));
    try testing.expectEqual(Result.invalid_value, encode(null, &tiny, tiny.len, &written));
    try testing.expectEqual(Result.invalid_value, encode(&r, &tiny, tiny.len, null));
    try testing.expectEqual(Result.invalid_value, encode(&base(.invalid), &tiny, tiny.len, &written));

    var small = base(.pixels_screen);
    small.size = 1;
    try testing.expectEqual(Result.invalid_value, encode(&small, &tiny, tiny.len, &written));
}

test "encode refuses unknown enum values and bad bools" {
    var buf: [64]u8 = undefined;
    var written: usize = 0;

    // The values are written through the raw layout, as a C caller would.
    var raw: RawReply = @bitCast(base(.pixels_screen));
    try testing.expectEqual(Result.success, encode(@ptrCast(&raw), &buf, buf.len, &written));

    raw.kind = 9999;
    try testing.expectEqual(Result.invalid_value, encode(@ptrCast(&raw), &buf, buf.len, &written));
    raw.kind = -1;
    try testing.expectEqual(Result.invalid_value, encode(@ptrCast(&raw), &buf, buf.len, &written));

    raw = @bitCast(base(.clipboard));
    raw.selection = .init(@as([]const u8, "c"));
    try testing.expectEqual(Result.success, encode(@ptrCast(&raw), &buf, buf.len, &written));
    raw.terminator = 7;
    try testing.expectEqual(Result.invalid_value, encode(@ptrCast(&raw), &buf, buf.len, &written));

    raw = @bitCast(base(.window_state));
    raw.iconified = 2;
    try testing.expectEqual(Result.invalid_value, encode(@ptrCast(&raw), &buf, buf.len, &written));
}
