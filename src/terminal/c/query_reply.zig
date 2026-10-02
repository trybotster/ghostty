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

    /// window_position: the position.
    x: i32,
    y: i32,

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

pub fn encode(
    reply_: ?*const Reply,
    out_: ?[*]u8,
    out_len: usize,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const reply = reply_ orelse return .invalid_value;
    const written = out_written orelse return .invalid_value;
    if (reply.size < @sizeOf(Reply)) return .invalid_value;

    var writer: std.Io.Writer = .fixed(if (out_) |out| out[0..out_len] else &.{});
    encodeReply(&writer, reply.*) catch |err| switch (err) {
        error.InvalidValue => return .invalid_value,
        error.WriteFailed => {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            encodeReply(&discarding.writer, reply.*) catch return .invalid_value;
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

test "pixel and character replies carry height before width and rows before columns" {
    var buf: [64]u8 = undefined;

    // The expected sequence is the one the terminal's own size encoder
    // writes for the same values, where that encoder has the form.
    const size_report = @import("../size_report.zig");
    const size: size_report.Size = .{ .rows = 24, .columns = 80, .cell_width = 9, .cell_height = 18 };

    var oracle: [64]u8 = undefined;
    {
        var w: std.Io.Writer = .fixed(&oracle);
        try size_report.encode(&w, .csi_14_t, size);
        var r = base(.pixels_text_area);
        r.width = 80 * 9;
        r.height = 24 * 18;
        try testing.expectEqualSlices(u8, w.buffered(), try encodeToSlice(&buf, r));
    }
    {
        var w: std.Io.Writer = .fixed(&oracle);
        try size_report.encode(&w, .csi_16_t, size);
        var r = base(.pixels_cell);
        r.width = 9;
        r.height = 18;
        try testing.expectEqualSlices(u8, w.buffered(), try encodeToSlice(&buf, r));
    }
}

test "pixels_screen, chars_screen, window state and position" {
    var buf: [64]u8 = undefined;

    // CSI 5 ; height ; width t differs from the CSI 4 form only in its first
    // parameter, so the text area reply with that parameter changed is the
    // expectation.
    var r = base(.pixels_screen);
    r.width = 1920;
    r.height = 1080;
    const screen = try encodeToSlice(&buf, r);
    var buf2: [64]u8 = undefined;
    r.kind = .pixels_text_area;
    const text_area = try encodeToSlice(&buf2, r);
    try testing.expectEqual(text_area.len, screen.len);
    try testing.expectEqual(@as(u8, '5'), screen[2]);
    try testing.expectEqual(@as(u8, '4'), text_area[2]);
    try testing.expectEqualSlices(u8, text_area[3..], screen[3..]);

    // chars_screen: CSI 9 ; rows ; cols t, rows first.
    var c = base(.chars_screen);
    c.rows = 24;
    c.cols = 80;
    const chars = try encodeToSlice(&buf, c);
    try testing.expectEqualStrings("\x1b[9;24;80t", chars);

    // Window state: one byte differs between the two answers.
    var s = base(.window_state);
    const open_state = try encodeToSlice(&buf, s);
    s.iconified = true;
    var buf3: [64]u8 = undefined;
    const iconified = try encodeToSlice(&buf3, s);
    try testing.expectEqual(open_state.len, iconified.len);
    try testing.expect(!std.mem.eql(u8, open_state, iconified));

    // Position: CSI 3 ; x ; y t, x first, and negative values keep their sign.
    var p = base(.window_position);
    p.x = -12;
    p.y = 34;
    try testing.expectEqualStrings("\x1b[3;-12;34t", try encodeToSlice(&buf, p));
}

test "title and icon label wrap the text and refuse control codepoints" {
    var buf: [128]u8 = undefined;

    var t = base(.window_title);
    t.text = .init(@as([]const u8, "héllo wörld"));
    const title = try encodeToSlice(&buf, t);
    try testing.expect(std.mem.startsWith(u8, title, "\x1b]l"));
    try testing.expect(std.mem.endsWith(u8, title, "\x1b\\"));
    try testing.expectEqualStrings("héllo wörld", title[3 .. title.len - 2]);

    var i = base(.icon_label);
    i.text = .init(@as([]const u8, "icon"));
    var buf2: [128]u8 = undefined;
    const icon = try encodeToSlice(&buf2, i);
    try testing.expect(std.mem.startsWith(u8, icon, "\x1b]L"));
    try testing.expectEqualStrings("icon", icon[3 .. icon.len - 2]);

    // Text that could end the OSC or start a sequence is refused: ESC, BEL,
    // DEL and a C1 codepoint, and bytes that are not UTF-8.
    const bad = [_][]const u8{ "a\x1b[31mb", "a\x07b", "a\x7fb", "a\u{85}b", "\xff\xfe" };
    for (bad) |text| {
        var r = base(.window_title);
        r.text = .init(text);
        var written: usize = 0;
        try testing.expectEqual(Result.invalid_value, encode(&r, &buf, buf.len, &written));
    }
}

test "clipboard reply carries the selection, base64 and the request terminator" {
    var buf: [256]u8 = undefined;

    for ([_]osc.Terminator.C{ .st, .bel }) |terminator| {
        var r = base(.clipboard);
        r.selection = .init(@as([]const u8, "c"));
        r.text = .init(@as([]const u8, "hello"));
        r.terminator = terminator;
        const out = try encodeToSlice(&buf, r);
        try testing.expect(std.mem.startsWith(u8, out, "\x1b]52;c;"));

        // The base64 part decodes to the bytes, and the terminator is the one
        // of the request.
        const terminator_bytes: []const u8 = switch (terminator) {
            .st => "\x1b\\",
            .bel => "\x07",
        };
        try testing.expect(std.mem.endsWith(u8, out, terminator_bytes));
        const b64 = out["\x1b]52;c;".len .. out.len - terminator_bytes.len];
        var decoded: [64]u8 = undefined;
        const len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
        try std.base64.standard.Decoder.decode(decoded[0..len], b64);
        try testing.expectEqualStrings("hello", decoded[0..len]);
    }

    // The selection is kept as given: the program that asked for "q" gets "q".
    var r = base(.clipboard);
    r.selection = .init(@as([]const u8, "s0"));
    const out = try encodeToSlice(&buf, r);
    try testing.expect(std.mem.startsWith(u8, out, "\x1b]52;s0;"));

    // An empty clipboard is an empty base64 part.
    var empty = base(.clipboard);
    empty.selection = .init(@as([]const u8, "c"));
    var written: usize = 0;
    try testing.expectEqual(Result.success, encode(&empty, &buf, buf.len, &written));
    try testing.expect(std.mem.startsWith(u8, buf[0..written], "\x1b]52;c;"));

    // A selection outside the allowed set is refused.
    var bad = base(.clipboard);
    bad.selection = .init(@as([]const u8, "c;x"));
    try testing.expectEqual(Result.invalid_value, encode(&bad, &buf, buf.len, &written));
}

test "clipboard base64 of a payload longer than one chunk" {
    var payload: [3000]u8 = undefined;
    for (&payload, 0..) |*b, n| b.* = @truncate(n *% 7);

    var out: [5000]u8 = undefined;
    var r = base(.clipboard);
    r.selection = .init(@as([]const u8, "c"));
    r.text = .init(@as([]const u8, &payload));
    var written: usize = 0;
    try testing.expectEqual(Result.success, encode(&r, &out, out.len, &written));

    const prefix = "\x1b]52;c;";
    const b64 = out[prefix.len .. written - 2];
    var decoded: [3000]u8 = undefined;
    try std.base64.standard.Decoder.decode(&decoded, b64);
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
