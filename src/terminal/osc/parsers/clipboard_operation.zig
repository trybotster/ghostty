const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

/// Parse OSC 52
pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    assert(parser.state == .@"52");
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    cap.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    if (data.len == 1) {
        parser.state = .invalid;
        return null;
    }

    // The selection is everything up to the first semicolon, however many
    // characters it has ("s0", "cp"). The data follows that semicolon.
    // `data` ends with the NUL that was written above.
    const selection_end = std.mem.indexOfScalar(u8, data[0 .. data.len - 1], ';') orelse {
        parser.state = .invalid;
        return null;
    };
    const selection = data[0..selection_end];
    parser.command = .{
        .clipboard_contents = .{
            // The first selection character picks the destination. A program
            // that leaves the selection out gets the clipboard.
            .kind = if (selection.len == 0) 'c' else selection[0],
            .data = data[selection_end + 1 .. data.len - 1 :0],
            .terminator = .init(terminator_ch),
            .selection = selection,
        },
    };
    return &parser.command;
}

test "OSC 52: get/set clipboard" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "52;s;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 's');
    try testing.expectEqualStrings("?", cmd.clipboard_contents.data);
    try testing.expectEqual(.st, cmd.clipboard_contents.terminator);
}

test "OSC 52: get clipboard with BEL terminator" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "52;c;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end(0x07).?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expectEqual(.bel, cmd.clipboard_contents.terminator);
}

test "OSC 52: get/set clipboard (optional parameter)" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "52;;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 'c');
    try testing.expectEqualStrings("?", cmd.clipboard_contents.data);
}

test "OSC 52: get/set clipboard with allocator" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "52;s;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 's');
    try testing.expectEqualStrings("?", cmd.clipboard_contents.data);
}

test "OSC 52: clear clipboard" {
    const testing = std.testing;

    var p: Parser = .init(null);
    defer p.deinit();

    const input = "52;;";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 'c');
    try testing.expectEqualStrings("", cmd.clipboard_contents.data);
}

test "OSC 52: a selection of several characters is kept whole" {
    const testing = std.testing;

    inline for (.{ "s0", "cp", "cpqs01234567" }) |selection| {
        var p: Parser = .init(null);

        const input = "52;" ++ selection ++ ";?";
        for (input) |ch| p.next(ch);

        const cmd = p.end(null).?.*;
        try testing.expect(cmd == .clipboard_contents);
        try testing.expectEqualStrings(selection, cmd.clipboard_contents.selection);
        try testing.expectEqual(@as(u8, selection[0]), cmd.clipboard_contents.kind);
        try testing.expectEqualStrings("?", cmd.clipboard_contents.data);
    }
}

test "OSC 52: a selection with no semicolon after it is invalid" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "52;cp";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 52: the selection of a short form is empty or one character" {
    const testing = std.testing;

    var p: Parser = .init(null);
    for ("52;;?") |ch| p.next(ch);
    const empty = p.end(null).?.*;
    try testing.expectEqualStrings("", empty.clipboard_contents.selection);
    try testing.expectEqual(@as(u8, 'c'), empty.clipboard_contents.kind);

    var q: Parser = .init(null);
    for ("52;q;?") |ch| q.next(ch);
    const one = q.end(null).?.*;
    try testing.expectEqualStrings("q", one.clipboard_contents.selection);
}
