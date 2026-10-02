const std = @import("std");
const testing = std.testing;
const terminal = @import("../terminal/main.zig");
const Terminal = terminal.Terminal;
const renderer_size = @import("../renderer/size.zig");
const point = @import("../terminal/point.zig");
const key = @import("key.zig");
const mouse = @import("mouse.zig");

const log = std.log.scoped(.mouse_encode);

/// Options that affect mouse encoding behavior and provide runtime context.
pub const Options = struct {
    /// Terminal mouse reporting mode (X10, normal, button, any).
    event: terminal.MouseEvent = .none,

    /// Terminal mouse reporting format.
    format: terminal.MouseFormat = .x10,

    /// Full renderer size used to convert surface-space pixel positions
    /// into grid cell coordinates (for most formats) and terminal-space
    /// pixel coordinates (for SGR-Pixels), as well as to determine
    /// whether a position falls outside the visible viewport.
    size: renderer_size.Size,

    /// Whether any mouse button is currently pressed. When a motion
    /// event occurs outside the viewport, it is only reported if a
    /// button is held down and the event mode supports motion tracking.
    /// Without this, out-of-viewport motions are silently dropped.
    ///
    /// This should reflect the state of the current event as well, so
    /// if the encoded event is a button press, this should be true.
    any_button_pressed: bool = false,

    /// Last reported viewport cell for motion deduplication.
    /// If null, motion deduplication state is not tracked.
    last_cell: ?*?point.Coordinate = null,

    /// Initialize from terminal and renderer state. The caller may still
    /// set any_button_pressed and last_cell on the returned value.
    pub fn fromTerminal(
        t: *const Terminal,
        size: renderer_size.Size,
    ) Options {
        return .{
            .event = t.flags.mouse_event,
            .format = t.flags.mouse_format,
            .size = size,
        };
    }
};

/// A normalized mouse event for protocol encoding.
pub const Event = struct {
    /// The action of this mouse event.
    action: mouse.Action = .press,

    /// The button involved in this event. This can be null in the
    /// case of a motion action with no pressed buttons.
    button: ?mouse.Button = null,

    /// Keyboard modifiers held during this event.
    mods: key.Mods = .{},

    /// Mouse position in terminal-space pixels, with (0, 0) at the top-left
    /// of the terminal. Negative values are allowed and indicate positions
    /// above or to the left of the terminal. Values larger than the terminal
    /// size are also allowed and indicate right or below the terminal.
    pos: Pos = .{},

    /// The zero-based cell of the event, when the caller already knows it.
    ///
    /// A caller that has cell coordinates (and no pixel position for the
    /// cell formats) sets this. The encoder then uses the cell exactly as
    /// given: it is not converted from a pixel position, it is not clamped to
    /// the grid, and it is not tested against the viewport, so a release or
    /// motion outside the grid is reported at the cell that was given. A cell
    /// that the active format cannot express produces no output.
    ///
    /// SGR pixel reporting ignores the cell and uses `pos`.
    cell: ?Cell = null,

    /// Mouse position in surface-space pixels.
    pub const Pos = extern struct {
        x: f32 = 0,
        y: f32 = 0,
    };

    /// A zero-based terminal cell.
    pub const Cell = extern struct {
        col: u32,
        row: u32,
    };
};

/// Encode the mouse event to the writer according to the options.
///
/// Not all events result in output.
pub fn encode(
    writer: *std.Io.Writer,
    event: Event,
    opts: Options,
) std.Io.Writer.Error!void {
    if (!shouldReport(event, opts)) return;

    // A caller-supplied cell is used exactly as given (see Event.cell),
    // except for SGR pixels, which reports the pixel position.
    const supplied: ?Event.Cell = if (opts.format == .sgr_pixels) null else event.cell;

    var cell_x: u32 = undefined;
    var cell_y: u32 = undefined;
    // The cell that motion deduplication compares, if it can hold the cell.
    var tracked: ?point.Coordinate = null;
    if (supplied) |given| {
        cell_x = given.col;
        cell_y = given.row;
        if (given.col <= std.math.maxInt(terminal.size.CellCountInt)) {
            tracked = .{ .x = @intCast(given.col), .y = given.row };
        }
    } else {
        // Handle scenarios where the mouse position is outside the viewport.
        // We always report release events no matter where they happen.
        if (event.action != .release and
            posOutOfViewport(event.pos, opts.size))
        {
            // If we don't have a motion-tracking event mode, do nothing,
            // because events outside the viewport are never reported in
            // such cases.
            if (!terminal.mouse.eventSendsMotion(opts.event)) return;

            // For motion modes, we only report if a button is currently pressed.
            // This lets a TUI detect a click over the surface + drag out
            // of the surface.
            if (!opts.any_button_pressed) return;
        }

        const cell = posToCell(event.pos, opts.size);
        cell_x = cell.x;
        cell_y = cell.y;
        tracked = cell;
    }

    // We only send motion events when the cell changed unless
    // we're tracking raw pixels.
    if (event.action == .motion and opts.format != .sgr_pixels) {
        if (opts.last_cell) |last| {
            if (last.*) |last_cell| {
                if (tracked) |current| {
                    if (last_cell.eql(current)) return;
                }
            }
        }
    }

    // Update the last reported cell if we are tracking it.
    if (opts.last_cell) |last| last.* = tracked;

    const button_code = buttonCode(event, opts) orelse return;
    switch (opts.format) {
        .x10 => {
            if (cell_x > 222 or cell_y > 222) {
                log.info("X10 mouse format can only encode X/Y up to 223", .{});
                return;
            }

            // + 1 because our x/y are zero-indexed and the protocol uses 1-indexing.
            try writer.writeAll("\x1B[M");
            try writer.writeByte(32 + button_code);
            try writer.writeByte(32 + @as(u8, @intCast(cell_x)) + 1);
            try writer.writeByte(32 + @as(u8, @intCast(cell_y)) + 1);
        },

        .utf8 => {
            // The UTF-8 format has two bytes per coordinate, so the largest
            // code point is U+07FF (a cell of 2014).
            if (cell_x > 2014 or cell_y > 2014) {
                log.info("UTF-8 mouse format can only encode X/Y up to 2015", .{});
                return;
            }

            try writer.writeAll("\x1B[M");

            // The button code always fits in a single byte.
            try writer.writeByte(32 + button_code);

            var buf: [4]u8 = undefined;
            const x_cp: u21 = @intCast(cell_x + 33);
            const y_cp: u21 = @intCast(cell_y + 33);

            const x_len = std.unicode.utf8Encode(x_cp, &buf) catch unreachable;
            try writer.writeAll(buf[0..x_len]);

            const y_len = std.unicode.utf8Encode(y_cp, &buf) catch unreachable;
            try writer.writeAll(buf[0..y_len]);
        },

        .sgr => try writer.print("\x1B[<{d};{d};{d}{c}", .{
            button_code,
            @as(u64, cell_x) + 1,
            @as(u64, cell_y) + 1,
            @as(u8, if (event.action == .release) 'm' else 'M'),
        }),

        .urxvt => try writer.print("\x1B[{d};{d};{d}M", .{
            32 + button_code,
            @as(u64, cell_x) + 1,
            @as(u64, cell_y) + 1,
        }),

        .sgr_pixels => {
            const pixels = posToPixels(event.pos, opts.size);
            try writer.print("\x1B[<{d};{d};{d}{c}", .{
                button_code,
                pixels.x,
                pixels.y,
                @as(u8, if (event.action == .release) 'm' else 'M'),
            });
        },
    }
}

/// Returns true if this event should be reported for the given mouse
/// event mode.
fn shouldReport(event: Event, opts: Options) bool {
    return switch (opts.event) {
        .none => false,

        // X10 only reports button presses of left, middle, and right.
        .x10 => event.action == .press and
            event.button != null and
            (event.button.? == .left or
                event.button.? == .middle or
                event.button.? == .right),

        // Normal mode does not report motion.
        .normal => event.action != .motion,

        // Button mode requires an active button for motion events.
        .button => event.button != null,

        // Any mode reports everything.
        .any => true,
    };
}

fn buttonCode(event: Event, opts: Options) ?u8 {
    var acc: u8 = code: {
        if (event.button == null) {
            // Null button means motion with no pressed button.
            break :code 3;
        }

        if (event.action == .release and
            opts.format != .sgr and
            opts.format != .sgr_pixels)
        {
            // Legacy releases are always encoded as button 3.
            break :code 3;
        }

        break :code switch (event.button.?) {
            .left => 0,
            .middle => 1,
            .right => 2,
            .four => 64,
            .five => 65,
            .six => 66,
            .seven => 67,
            .eight => 128,
            .nine => 129,
            else => return null,
        };
    };

    // X10 does not include modifiers.
    if (opts.event != .x10) {
        if (event.mods.shift) acc += 4;
        if (event.mods.alt) acc += 8;
        if (event.mods.ctrl) acc += 16;
    }

    // Motion adds another bit.
    if (event.action == .motion) acc += 32;

    return acc;
}

/// Terminal-space pixel position for SGR pixel reporting.
const PixelPoint = struct {
    x: i32,
    y: i32,
};

/// Returns true if the surface-space pixel position is outside the
/// visible viewport bounds (negative or beyond screen dimensions).
fn posOutOfViewport(pos: Event.Pos, size: renderer_size.Size) bool {
    const max_x: f32 = @floatFromInt(size.screen.width);
    const max_y: f32 = @floatFromInt(size.screen.height);
    return pos.x < 0 or pos.y < 0 or pos.x > max_x or pos.y > max_y;
}

/// Converts a surface-space pixel position to a zero-based grid cell
/// coordinate (column, row) within the terminal viewport. Out-of-bounds
/// values are clamped to the valid grid range (0 to columns/rows - 1).
fn posToCell(pos: Event.Pos, size: renderer_size.Size) point.Coordinate {
    const coord: renderer_size.Coordinate = .{ .surface = .{
        .x = @as(f64, @floatCast(pos.x)),
        .y = @as(f64, @floatCast(pos.y)),
    } };
    const grid = coord.convert(.grid, size).grid;
    return .{ .x = grid.x, .y = grid.y };
}

/// Converts a surface-space pixel position to terminal-space pixel
/// coordinates (accounting for padding/scaling) used by SGR-Pixels mode.
/// Unlike grid conversion, terminal-space coordinates are not clamped
/// and may be negative or exceed the terminal dimensions.
fn posToPixels(pos: Event.Pos, size: renderer_size.Size) PixelPoint {
    const coord: renderer_size.Coordinate.Terminal = (renderer_size.Coordinate{ .surface = .{
        .x = @as(f64, @floatCast(pos.x)),
        .y = @as(f64, @floatCast(pos.y)),
    } }).convert(.terminal, size).terminal;

    return .{
        .x = @as(i32, @intFromFloat(@round(coord.x))),
        .y = @as(i32, @intFromFloat(@round(coord.y))),
    };
}

fn testSize() renderer_size.Size {
    return .{
        .screen = .{ .width = 1_000, .height = 1_000 },
        .cell = .{ .width = 1, .height = 1 },
        .padding = .{},
    };
}

test "shouldReport: none mode never reports" {
    const size = testSize();
    inline for ([_]mouse.Action{ .press, .release, .motion }) |action| {
        try testing.expect(!shouldReport(.{
            .button = .left,
            .action = action,
        }, .{ .event = .none, .size = size }));
    }
}

test "shouldReport: x10 reports only left/middle/right press" {
    const size = testSize();
    // Left, middle, right presses should report.
    inline for ([_]mouse.Button{ .left, .middle, .right }) |btn| {
        try testing.expect(shouldReport(.{
            .button = btn,
            .action = .press,
        }, .{ .event = .x10, .size = size }));
    }

    // Release is not reported.
    try testing.expect(!shouldReport(.{
        .button = .left,
        .action = .release,
    }, .{ .event = .x10, .size = size }));

    // Motion is not reported.
    try testing.expect(!shouldReport(.{
        .button = .left,
        .action = .motion,
    }, .{ .event = .x10, .size = size }));

    // Other buttons are not reported.
    try testing.expect(!shouldReport(.{
        .button = .four,
        .action = .press,
    }, .{ .event = .x10, .size = size }));

    // Null button is not reported.
    try testing.expect(!shouldReport(.{
        .button = null,
        .action = .press,
    }, .{ .event = .x10, .size = size }));
}

test "shouldReport: normal reports press and release but not motion" {
    const size = testSize();
    try testing.expect(shouldReport(.{
        .button = .left,
        .action = .press,
    }, .{ .event = .normal, .size = size }));

    try testing.expect(shouldReport(.{
        .button = .left,
        .action = .release,
    }, .{ .event = .normal, .size = size }));

    try testing.expect(!shouldReport(.{
        .button = .left,
        .action = .motion,
    }, .{ .event = .normal, .size = size }));
}

test "shouldReport: button mode requires a button" {
    const size = testSize();
    // With a button, all actions report.
    inline for ([_]mouse.Action{ .press, .release, .motion }) |action| {
        try testing.expect(shouldReport(.{
            .button = .left,
            .action = action,
        }, .{ .event = .button, .size = size }));
    }

    // Without a button (null), nothing reports.
    inline for ([_]mouse.Action{ .press, .release, .motion }) |action| {
        try testing.expect(!shouldReport(.{
            .button = null,
            .action = action,
        }, .{ .event = .button, .size = size }));
    }
}

test "shouldReport: any mode reports everything" {
    const size = testSize();
    inline for ([_]mouse.Action{ .press, .release, .motion }) |action| {
        try testing.expect(shouldReport(.{
            .button = .left,
            .action = action,
        }, .{ .event = .any, .size = size }));
    }

    // Even null button + motion reports.
    try testing.expect(shouldReport(.{
        .button = null,
        .action = .motion,
    }, .{ .event = .any, .size = size }));
}

test "x10 press left" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .press,
        .mods = .{ .shift = true, .alt = true, .ctrl = true },
        .pos = .{ .x = 0, .y = 0 },
    }, .{
        .event = .x10,
        .format = .x10,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualSlices(u8, &.{
        0x1B,
        '[',
        'M',
        32,
        33,
        33,
    }, writer.buffered());
}

test "x10 ignores release" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .release,
    }, .{
        .event = .x10,
        .format = .x10,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "normal ignores motion" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .motion,
    }, .{
        .event = .normal,
        .format = .sgr,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "button mode requires button" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = null,
        .action = .motion,
    }, .{
        .event = .button,
        .format = .sgr,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "sgr release keeps button identity" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .right,
        .action = .release,
        .pos = .{ .x = 4, .y = 5 },
    }, .{
        .event = .any,
        .format = .sgr,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[<2;5;6m", writer.buffered());
}

test "sgr motion with no button" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = null,
        .action = .motion,
        .pos = .{ .x = 1, .y = 2 },
    }, .{
        .event = .any,
        .format = .sgr,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[<35;2;3M", writer.buffered());
}

test "urxvt with modifiers" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .press,
        .mods = .{ .shift = true, .alt = true, .ctrl = true },
        .pos = .{ .x = 2, .y = 3 },
    }, .{
        .event = .any,
        .format = .urxvt,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[60;3;4M", writer.buffered());
}

test "utf8 encodes large coordinates" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .press,
        .pos = .{ .x = 300, .y = 400 },
    }, .{
        .event = .any,
        .format = .utf8,
        .size = testSize(),
        .last_cell = &last,
    });

    const out = writer.buffered();
    try testing.expectEqualSlices(u8, &.{ 0x1B, '[', 'M', 32 }, out[0..4]);

    const view = try std.unicode.Utf8View.init(out[4..]);
    var it = view.iterator();
    try testing.expectEqual(@as(u21, 333), it.nextCodepoint().?);
    try testing.expectEqual(@as(u21, 433), it.nextCodepoint().?);
    try testing.expectEqual(@as(?u21, null), it.nextCodepoint());
}

test "x10 coordinate limit" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .press,
        .pos = .{ .x = 223, .y = 0 },
    }, .{
        .event = .x10,
        .format = .x10,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "sgr wheel button mappings" {
    const Case = struct {
        button: mouse.Button,
        code: u8,
    };

    inline for ([_]Case{
        .{ .button = .four, .code = 64 },
        .{ .button = .five, .code = 65 },
        .{ .button = .six, .code = 66 },
        .{ .button = .seven, .code = 67 },
    }) |c| {
        var data: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        var last: ?point.Coordinate = null;
        try encode(&writer, .{
            .button = c.button,
            .action = .press,
            .pos = .{ .x = 0, .y = 0 },
        }, .{
            .event = .any,
            .format = .sgr,
            .size = testSize(),
            .last_cell = &last,
        });

        var expected: [32]u8 = undefined;
        const want = try std.fmt.bufPrint(&expected, "\x1B[<{d};1;1M", .{c.code});
        try testing.expectEqualStrings(want, writer.buffered());
    }
}

test "urxvt release uses legacy button 3 encoding" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .right,
        .action = .release,
        .pos = .{ .x = 2, .y = 3 },
    }, .{
        .event = .any,
        .format = .urxvt,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[35;3;4M", writer.buffered());
}

test "unsupported button is ignored" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .ten,
        .action = .press,
        .pos = .{ .x = 1, .y = 1 },
    }, .{
        .event = .any,
        .format = .sgr,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "sgr pixels uses terminal-space cursor coordinates" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .press,
        .pos = .{ .x = 10, .y = 20 },
    }, .{
        .event = .any,
        .format = .sgr_pixels,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[<0;10;20M", writer.buffered());
}

test "sgr pixels release keeps button identity" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .right,
        .action = .release,
        .pos = .{ .x = 10, .y = 20 },
    }, .{
        .event = .any,
        .format = .sgr_pixels,
        .size = testSize(),
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[<2;10;20m", writer.buffered());
}

test "position exactly at viewport boundary is encoded in final cell" {
    const size: renderer_size.Size = .{
        .screen = .{ .width = 10, .height = 10 },
        .cell = .{ .width = 2, .height = 2 },
        .padding = .{},
    };

    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .press,
        .pos = .{ .x = 10, .y = 10 },
    }, .{
        .event = .any,
        .format = .sgr,
        .size = size,
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[<0;5;5M", writer.buffered());
}

test "outside viewport motion with no pressed button is ignored" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .motion,
        .pos = .{ .x = -1, .y = -1 },
    }, .{
        .event = .any,
        .format = .sgr,
        .size = testSize(),
        .any_button_pressed = false,
        .last_cell = &last,
    });

    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "outside viewport motion with pressed button is reported" {
    var data: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?point.Coordinate = null;
    try encode(&writer, .{
        .button = .left,
        .action = .motion,
        .pos = .{ .x = -1, .y = -1 },
    }, .{
        .event = .any,
        .format = .sgr,
        .size = testSize(),
        .any_button_pressed = true,
        .last_cell = &last,
    });

    try testing.expectEqualStrings("\x1B[<32;1;1M", writer.buffered());
}

test "motion is deduped by last cell except sgr pixels" {
    var last: ?point.Coordinate = null;

    {
        var data: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        try encode(&writer, .{
            .button = .left,
            .action = .motion,
            .pos = .{ .x = 5, .y = 6 },
        }, .{
            .event = .any,
            .format = .sgr,
            .size = testSize(),
            .last_cell = &last,
        });
        try testing.expect(writer.buffered().len > 0);
    }

    {
        var data: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        try encode(&writer, .{
            .button = .left,
            .action = .motion,
            .pos = .{ .x = 5, .y = 6 },
        }, .{
            .event = .any,
            .format = .sgr,
            .size = testSize(),
            .last_cell = &last,
        });
        try testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }

    {
        var data: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&data);
        try encode(&writer, .{
            .button = .left,
            .action = .motion,
            .pos = .{ .x = 5, .y = 6 },
        }, .{
            .event = .any,
            .format = .sgr_pixels,
            .size = testSize(),
            .last_cell = &last,
        });
        try testing.expect(writer.buffered().len > 0);
    }
}

/// A size whose grid (60000 cells, below the u16 limit of a column) is large enough that a surface position over cell
/// (col, row) maps to that cell with no clamping. The cell is one pixel.
fn wideSize() renderer_size.Size {
    return .{
        .screen = .{ .width = 60_000, .height = 60_000 },
        .cell = .{ .width = 1, .height = 1 },
        .padding = .{},
    };
}

/// The pixel position that lies in the middle of a cell of `wideSize`.
fn cellCenter(col: u32, row: u32) Event.Pos {
    return .{
        .x = @as(f32, @floatFromInt(col)) + 0.5,
        .y = @as(f32, @floatFromInt(row)) + 0.5,
    };
}

fn encodeToBuf(buf: []u8, event: Event, opts: Options) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    try encode(&writer, event, opts);
    return writer.buffered();
}

test "cell: a supplied cell encodes like the pixel position over that cell" {
    // The pixel path is the oracle for the cell path, for every format and
    // action, at small and large coordinates.
    const formats = [_]terminal.MouseFormat{ .x10, .utf8, .sgr, .urxvt };
    const actions = [_]mouse.Action{ .press, .release, .motion };
    const cells = [_]Event.Cell{
        .{ .col = 0, .row = 0 },
        .{ .col = 5, .row = 7 },
        .{ .col = 222, .row = 100 },
    };
    for (formats) |format| {
        for (actions) |action| {
            for (cells) |cell| {
                var buf_a: [64]u8 = undefined;
                var buf_b: [64]u8 = undefined;
                const opts: Options = .{ .event = .any, .format = format, .size = wideSize(), .any_button_pressed = true };
                const by_cell = try encodeToBuf(&buf_a, .{
                    .action = action,
                    .button = .left,
                    .cell = cell,
                }, opts);
                const by_pixel = try encodeToBuf(&buf_b, .{
                    .action = action,
                    .button = .left,
                    .pos = cellCenter(cell.col, cell.row),
                }, opts);
                try testing.expect(by_pixel.len > 0);
                try testing.expectEqualSlices(u8, by_pixel, by_cell);
            }
        }
    }
}

test "cell: a cell outside the grid is reported as given, with no clamping" {
    // The grid of this size is small, so the pixel path would clamp.
    const small: renderer_size.Size = .{
        .screen = .{ .width = 100, .height = 100 },
        .cell = .{ .width = 10, .height = 10 },
        .padding = .{},
    };
    const outside: Event.Cell = .{ .col = 5000, .row = 4000 };

    // For each action, including a release: the cell is the one given.
    for ([_]mouse.Action{ .press, .release, .motion }) |action| {
        var buf_a: [64]u8 = undefined;
        var buf_b: [64]u8 = undefined;
        const by_cell = try encodeToBuf(&buf_a, .{
            .action = action,
            .button = .left,
            .cell = outside,
        }, .{ .event = .any, .format = .sgr, .size = small, .any_button_pressed = true });
        const by_pixel = try encodeToBuf(&buf_b, .{
            .action = action,
            .button = .left,
            .pos = cellCenter(outside.col, outside.row),
        }, .{ .event = .any, .format = .sgr, .size = wideSize(), .any_button_pressed = true });
        try testing.expect(by_cell.len > 0);
        try testing.expectEqualSlices(u8, by_pixel, by_cell);
    }

    // Without a cell the same release is clamped by the pixel path: the
    // clamped cell differs from the given one.
    var buf_c: [64]u8 = undefined;
    var buf_d: [64]u8 = undefined;
    const clamped = try encodeToBuf(&buf_c, .{
        .action = .release,
        .button = .left,
        .pos = cellCenter(outside.col, outside.row),
    }, .{ .event = .any, .format = .sgr, .size = small });
    const given = try encodeToBuf(&buf_d, .{
        .action = .release,
        .button = .left,
        .cell = outside,
    }, .{ .event = .any, .format = .sgr, .size = small });
    try testing.expect(!std.mem.eql(u8, clamped, given));
}

test "cell: a cell that the format cannot express produces no output" {
    var buf: [64]u8 = undefined;

    // X10: the last cell is 222.
    {
        const opts: Options = .{ .event = .any, .format = .x10, .size = wideSize() };
        try testing.expect((try encodeToBuf(&buf, .{ .button = .left, .cell = .{ .col = 222, .row = 0 } }, opts)).len > 0);
        try testing.expectEqual(@as(usize, 0), (try encodeToBuf(&buf, .{ .button = .left, .cell = .{ .col = 223, .row = 0 } }, opts)).len);
        try testing.expectEqual(@as(usize, 0), (try encodeToBuf(&buf, .{ .button = .left, .cell = .{ .col = 0, .row = 223 } }, opts)).len);
    }

    // UTF-8: two bytes per coordinate, so the last cell is 2014.
    {
        const opts: Options = .{ .event = .any, .format = .utf8, .size = wideSize() };
        try testing.expect((try encodeToBuf(&buf, .{ .button = .left, .cell = .{ .col = 2014, .row = 2014 } }, opts)).len > 0);
        try testing.expectEqual(@as(usize, 0), (try encodeToBuf(&buf, .{ .button = .left, .cell = .{ .col = 2015, .row = 0 } }, opts)).len);
        try testing.expectEqual(@as(usize, 0), (try encodeToBuf(&buf, .{ .button = .left, .cell = .{ .col = 0, .row = 2015 } }, opts)).len);
    }

    // SGR and URXVT have no limit, and the largest cell does not overflow.
    for ([_]terminal.MouseFormat{ .sgr, .urxvt }) |format| {
        const opts: Options = .{ .event = .any, .format = format, .size = wideSize() };
        const max = std.math.maxInt(u32);
        try testing.expect((try encodeToBuf(&buf, .{ .button = .left, .cell = .{ .col = max, .row = max } }, opts)).len > 0);
    }
}

test "cell: motion deduplication follows the supplied cell" {
    var last: ?point.Coordinate = null;
    const opts: Options = .{ .event = .any, .format = .sgr, .size = wideSize(), .last_cell = &last };
    var buf: [64]u8 = undefined;

    const first = try encodeToBuf(&buf, .{ .action = .motion, .cell = .{ .col = 3, .row = 4 } }, opts);
    try testing.expect(first.len > 0);

    // The same cell again: nothing.
    try testing.expectEqual(@as(usize, 0), (try encodeToBuf(&buf, .{ .action = .motion, .cell = .{ .col = 3, .row = 4 } }, opts)).len);

    // A different cell: reported.
    try testing.expect((try encodeToBuf(&buf, .{ .action = .motion, .cell = .{ .col = 4, .row = 4 } }, opts)).len > 0);
}

test "cell: SGR pixels ignores the cell and reports the pixel position" {
    const opts: Options = .{ .event = .any, .format = .sgr_pixels, .size = wideSize() };
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const with_cell = try encodeToBuf(&buf_a, .{
        .button = .left,
        .pos = .{ .x = 41, .y = 17 },
        .cell = .{ .col = 9, .row = 9 },
    }, opts);
    const without_cell = try encodeToBuf(&buf_b, .{
        .button = .left,
        .pos = .{ .x = 41, .y = 17 },
    }, opts);
    try testing.expect(with_cell.len > 0);
    try testing.expectEqualSlices(u8, without_cell, with_cell);
}
