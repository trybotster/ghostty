const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const terminfo = @import("../../terminfo/main.zig");

/// The terminfo source text of the `xterm-ghostty` entry, rendered once at
/// compile time from the same entry that `ghostty +terminfo` prints.
const source_text: [:0]const u8 = text: {
    @setEvalBranchQuota(4_000_000);

    var counter: std.Io.Writer.Discarding = .init(&.{});
    terminfo.ghostty.encode(&counter.writer) catch unreachable;
    const len: usize = @intCast(counter.count);

    var buf: [len + 1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(buf[0..len]);
    terminfo.ghostty.encode(&writer) catch unreachable;
    buf[len] = 0;

    const final = buf;
    break :text final[0..len :0];
};

/// The name that a program reads from TERM: the first name of the entry.
const term_name: [:0]const u8 = terminfo.ghostty.names[0];

pub fn name(out_: ?*lib.String) callconv(lib.calling_conv) void {
    const out = out_ orelse return;
    out.* = .init(@as([]const u8, term_name));
}

pub fn source(out_: ?*lib.String) callconv(lib.calling_conv) void {
    const out = out_ orelse return;
    out.* = .init(@as([]const u8, source_text));
}

test "name is the first name of the entry" {
    var out: lib.String = undefined;
    name(&out);
    try testing.expectEqualStrings(terminfo.ghostty.names[0], out.ptr[0..out.len]);
    // Core contract A2-8 and TI-1 name this entry as the terminal identity.
    try testing.expectEqualStrings("xterm-ghostty", out.ptr[0..out.len]);
}

test "source is the entry that the terminfo encoder writes" {
    var out: lib.String = undefined;
    source(&out);
    try testing.expect(out.len > 0);

    // The runtime encoder is the oracle for the compile-time text.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try terminfo.ghostty.encode(&aw.writer);
    try testing.expectEqualSlices(u8, aw.written(), out.ptr[0..out.len]);

    // The text starts with the name and is NUL terminated past its length.
    try testing.expect(std.mem.startsWith(u8, out.ptr[0..out.len], terminfo.ghostty.names[0]));
    try testing.expectEqual(@as(u8, 0), out.ptr[out.len]);
}

test "null output pointers are ignored" {
    name(null);
    source(null);
}
