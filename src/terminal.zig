const std = @import("std");
const build_options = @import("build_options");
const util = @import("util.zig");
const testing = std.testing;
const has_daemon = if (@hasDecl(build_options, "has_daemon")) build_options.has_daemon else true;
pub const ghostty_vt = if (has_daemon) @import("ghostty-vt") else struct {
    pub const Terminal = struct {};
    pub const Parser = struct {};
    pub const Selection = struct {};
    pub const formatter = struct {};
    pub const color = struct {};
};

pub const HistoryFormat = util.HistoryFormat;

/// Detect keyboard input that should transfer ownership to the sending client.
///
/// Terminal-generated replies must not count: every attached client's terminal
/// answers the queries the app broadcasts, so a reply from a passive viewer
/// would otherwise make it leader and resize the session to its window.
/// CDXC:Zmx 2026-09-15 WHY:
/// The output-oriented VT parser misses raw control keys and treats Alt shortcuts as terminal commands, so using only its print actions drops those keys from non-leading attachments.
/// Mouse, focus, and key-release reports can share a read with a keypress; skip the report and inspect the remaining bytes before deciding whether to transfer leadership.
pub fn isUserInput(payload: []const u8) bool {
    var parser = ghostty_vt.Parser.init();
    var i: usize = 0;
    while (i < payload.len) {
        if (parser.state == .ground) {
            if (payload[i] == 0x1b) {
                if (i + 1 == payload.len) return true;
                switch (payload[i + 1]) {
                    '[', ']', 'P', 'X', '^', '_', '\\' => {},
                    else => return true, // Alt key, SS3 key, or repeated Escape.
                }
                if (payload[i + 1] == '[') {
                    if (util.parseKittyCsiU(payload[i + 2 ..])) |kitty| {
                        if (kitty.event_type != 3) return true;
                        i += 2 + kitty.consumed;
                        continue;
                    }
                }
            } else if (payload[i] < 0x20 or payload[i] == 0x7f) {
                return true;
            }
        }

        const actions = parser.next(payload[i]);
        for (actions) |action_opt| {
            const action = action_opt orelse continue;
            switch (action) {
                .print => return true, // printable characters
                .csi_dispatch => |csi| {
                    // X10 mouse reports have three coordinate/button bytes
                    // outside the CSI. They are not subsequent typed text.
                    if (csi.final == 'M' and csi.intermediates.len == 0 and csi.params.len == 0) {
                        i += @min(@as(usize, 3), payload.len - i - 1);
                        continue;
                    }
                    // A reply, not a key: terminal replies carry a private
                    // marker (`?`, `>`, `=`, `<`) or another intermediate that
                    // keyboard encodings never use. Skip it and keep scanning,
                    // since a real keystroke can arrive in the same read.
                    if (csi.intermediates.len != 0) continue;
                    // kitty keyboard: CSI ... u or CSI ... ~
                    // legacy modified keys: CSI 27 ; ... ~
                    if (csi.final == 'u' or csi.final == '~') return true;
                    if (csi.final >= 'A' and csi.final <= 'D') return true;
                    // Home/End and Shift+Tab, including modifier forms.
                    // A two-coordinate CUP command is not a Home key.
                    if (csi.final == 'H' or csi.final == 'F' or csi.final == 'Z') {
                        if (csi.params.len <= 1 or (csi.params.len == 2 and csi.params[0] == 1)) return true;
                    }
                },
                else => {},
            }
        }
        i += 1;
    }
    return false;
}

/// CDXC:Zmx 2026-09-29 WHY:
/// A client that attached while a full-screen TUI held the alternate screen (Codex's fullscreen view, its default since 0.157, or Claude Code) received only that grid, so its primary screen came up empty: the shell history from before the TUI was gone from that client, which showed a blank terminal once the TUI quit. The primary screen's history, grid and cursor are written first, the way ghostty's formatter documents replaying every screen; the active-screen replay that follows enters the alternate screen with `?1049h`, which saves exactly this cursor for the TUI's exit to restore. wmx cannot do the same: its vt100 grid exposes only the active screen.
fn writePrimaryBehindAlternate(writer: *std.Io.Writer, term: *const ghostty_vt.Terminal) !void {
    const primary = term.screens.get(.primary) orelse return;
    const pages = &primary.pages;
    const screen_top = pages.getTopLeft(.screen);
    const active_top = pages.getTopLeft(.active);
    if (!screen_top.eql(active_top)) {
        if (active_top.up(1)) |sb_bottom_row| {
            var sb_bottom = sb_bottom_row;
            sb_bottom.x = @intCast(pages.cols - 1);
            var scroll_fmt = ghostty_vt.formatter.ScreenFormatter.init(primary, .vt);
            scroll_fmt.opts.unwrap = true;
            scroll_fmt.content = .{
                .selection = ghostty_vt.Selection.init(screen_top, sb_bottom, false),
            };
            try scroll_fmt.format(writer);
        }
        // Same two-phase contract as the active screen's replay below.
        for (0..pages.rows) |_| try writer.writeAll("\r\n");
        try writer.writeAll("\x1b[2J\x1b[H\x1b[0m");
    }
    const top_left = pages.pin(.{ .active = .{ .x = 0, .y = 0 } }) orelse return;
    const bottom_right = pages.pin(.{ .active = .{
        .x = @intCast(pages.cols - 1),
        .y = @intCast(pages.rows - 1),
    } }) orelse return;
    var grid_fmt = ghostty_vt.formatter.ScreenFormatter.init(primary, .vt);
    grid_fmt.opts.unwrap = true;
    grid_fmt.content = .{
        .selection = ghostty_vt.Selection.init(top_left, bottom_right, false),
    };
    grid_fmt.extra = .none;
    grid_fmt.extra.cursor = true;
    try grid_fmt.format(writer);
    // Enter now, saving the cursor just placed, and home: the replay's own `?1049h`
    // then finds the alternate screen active and leaves the cursor where its grid starts.
    try writer.writeAll("\x1b[0m\x1b[?1049h\x1b[H");
}

/// Emit the terminal's pwd as OSC 7.
///
/// This replaces the formatter's own `extra.pwd`, which writes
/// `terminal.pwd.items` verbatim. `Terminal.setPwd` appends a NUL sentinel to
/// that buffer, so the formatter's OSC 7 carries a stray `\x00` before the
/// terminator. `getPwd()` returns the same bytes without the sentinel.
///
/// The NUL is not cosmetic: a client that records what it receives (kitty
/// writing its session file, for one) persists the NUL and then fails to parse
/// its own state back. See https://github.com/neurosnap/zmx/issues/222.
fn writePwd(writer: *std.Io.Writer, term: *const ghostty_vt.Terminal) void {
    const pwd = term.getPwd() orelse return;
    if (pwd.len == 0) return;
    writer.print("\x1b]7;{s}\x1b\\", .{pwd}) catch |err| {
        std.log.warn("failed to format pwd err={s}", .{@errorName(err)});
    };
}

fn writeDynamicColor(
    writer: *std.Io.Writer,
    kind: ghostty_vt.color.Dynamic,
    dynamic: ghostty_vt.color.DynamicRGB,
) void {
    const c = dynamic.override orelse return;
    writer.print("\x1b]{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{
        @backingInt(kind), c.r, c.g, c.b,
    }) catch |err| {
        std.log.warn("failed to format dynamic color err={s}", .{@errorName(err)});
    };
}

fn writeColorOverrides(writer: *std.Io.Writer, term: *const ghostty_vt.Terminal) void {
    const colors = &term.colors;
    writeDynamicColor(writer, .foreground, colors.foreground);
    writeDynamicColor(writer, .background, colors.background);
    writeDynamicColor(writer, .cursor, colors.cursor);
}

/// The VT formatter does not emit the cursor shape (DECSCUSR).
fn writeCursorStyle(writer: *std.Io.Writer, term: *ghostty_vt.Terminal) !void {
    if (term.cursor.is_default) return writer.writeAll("\x1b[0 q");
    const blink = term.modes.get(.cursor_blinking);
    const style: u8 = switch (term.screens.active.cursor.cursor_style) {
        .block, .block_hollow => if (blink) 1 else 2,
        .underline => if (blink) 3 else 4,
        .bar => if (blink) 5 else 6,
    };
    try writer.print("\x1b[{d} q", .{style});
}

/// CDXC:Zmx 2026-09-24 WHY:
/// Replay must preserve soft wraps for later reflow, so emit unwrapped content with autowrap enabled and restore the application's mode afterward. Move every replayed history row beyond the client's viewport before clearing the live grid, as wmx's history snapshot does; otherwise short scrollback disappears on attachment.
pub fn serializeTerminalState(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal) ?[]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    // Synchronized output (DECSET 2026) is a transient rendering handshake
    // between a program and its current terminal client. Replaying it to a
    // newly attached client can leave that client deferring renders until its
    // local timeout fires, so temporarily exclude it from restored state and
    // restore the original mode before returning.
    const had_synchronized_output = term.modes.get(.synchronized_output);
    if (had_synchronized_output) {
        term.modes.set(.synchronized_output, false);
    }
    defer if (had_synchronized_output) term.modes.set(.synchronized_output, true);

    const had_wraparound = term.modes.get(.wraparound);
    term.modes.set(.wraparound, true);
    defer term.modes.set(.wraparound, had_wraparound);
    builder.writer.writeAll("\x1b[?7h") catch return null;

    // If state contains color override, restore it.
    writeColorOverrides(&builder.writer, term);

    const pages = &term.screens.active.pages;
    const screen_top = pages.getTopLeft(.screen);
    const active_top = pages.getTopLeft(.active);
    const has_scrollback = !screen_top.eql(active_top);

    // Two-phase serialization to preserve scrollback without corrupting
    // cursor positions. This matters for nested zmx sessions (zmx→SSH→zmx)
    // where the outer daemon's ghostty-vt accumulates inner session scrollback.
    //
    // Phase 1: Emit scrollback content (plain text with styles, no terminal extras).
    // These lines scroll past the visible area into the terminal's scrollback buffer.
    // Phase 2: Clear visible screen, then emit visible content with full extras.
    // The clear ensures visible content starts from a clean slate regardless of
    // how much scrollback preceded it. CUP cursor positioning is then correct.
    //
    // See: https://github.com/neurosnap/zmx/issues/31

    // Phase 1: scrollback only (if any exists)
    if (has_scrollback) {
        if (active_top.up(1)) |sb_bottom_row| {
            var sb_bottom = sb_bottom_row;
            sb_bottom.x = @intCast(pages.cols - 1);

            var scroll_fmt = ghostty_vt.formatter.TerminalFormatter.init(term, .vt);
            scroll_fmt.opts.unwrap = true;
            scroll_fmt.content = .{
                .selection = ghostty_vt.Selection.init(
                    screen_top,
                    sb_bottom,
                    false,
                ),
            };
            scroll_fmt.extra = .none; // no modes, cursor, keyboard — just content
            scroll_fmt.format(&builder.writer) catch |err| {
                std.log.warn("failed to format scrollback err={s}", .{@errorName(err)});
            };
        }

        // The formatter leaves its final history rows in the viewport. Move
        // every one into scrollback before clearing that viewport, including
        // when the entire history is shorter than the terminal height.
        for (0..pages.rows) |_| builder.writer.writeAll("\r\n") catch |err| {
            std.log.warn("failed to preserve scrollback err={s}", .{@errorName(err)});
            return null;
        };

        // Clear visible screen after scrollback. \x1b[2J clears only the visible
        // rows (not the scrollback buffer). \x1b[H homes the cursor. \x1b[0m resets
        // SGR style so phase 1 styles don't bleed into phase 2.
        builder.writer.writeAll("\x1b[2J\x1b[H\x1b[0m") catch {};
    }

    if (term.screens.active_key == .alternate) {
        writePrimaryBehindAlternate(&builder.writer, term) catch return null;
    }

    // Phase 2: visible screen with full extras (modes, cursor, keyboard, etc.)
    var vis_fmt = ghostty_vt.formatter.TerminalFormatter.init(term, .vt);
    vis_fmt.opts.unwrap = true;

    // Restrict content to the active viewport only
    const active_tl = pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
    const active_br = pages.pin(.{
        .active = .{
            .x = @intCast(pages.cols - 1),
            .y = @intCast(pages.rows - 1),
        },
    });

    if (active_tl != null and active_br != null) {
        vis_fmt.content = .{
            .selection = ghostty_vt.Selection.init(
                active_tl.?,
                active_br.?,
                false,
            ),
        };
    }
    // Fallback: if pins are somehow invalid, use null selection (all content)

    vis_fmt.extra = .{
        .palette = false,
        .modes = true,
        .scrolling_region = true,
        .tabstops = false, // tabstop restoration moves cursor after CUP, corrupting position
        .pwd = false, // emitted below without the sentinel the formatter includes
        .keyboard = true,
        .screen = .all,
    };

    vis_fmt.format(&builder.writer) catch |err| {
        std.log.warn("failed to format terminal state err={s}", .{@errorName(err)});
        return null;
    };

    if (!had_wraparound) builder.writer.writeAll("\x1b[?7l") catch return null;
    writePwd(&builder.writer, term);

    // The formatter has no title extra and never emits OSC 0/1/2, so the title
    // has to be replayed separately or an attaching client shows whatever its
    // terminal defaults to, usually the client process name. OSC 2 does not
    // move the cursor, so this is safe to append after the content.
    if (term.getTitle()) |title| {
        builder.writer.print("\x1b]2;{s}\x07", .{title}) catch |err| {
            std.log.warn("failed to format title err={s}", .{@errorName(err)});
        };
    }

    writeCursorStyle(&builder.writer, term) catch |err| {
        std.log.warn("failed to restore cursor style err={s}", .{@errorName(err)});
    };

    const output = builder.writer.buffered();
    if (output.len == 0) return null;

    return alloc.dupe(u8, output) catch |err| {
        std.log.warn("failed to allocate terminal state err={s}", .{@errorName(err)});
        return null;
    };
}

/// Serialize only the active viewport, as a clear-and-repaint snapshot.
///
/// CDXC:Zmx 2026-05-20-09:57: Ghostex can ask an already attached
/// zmx client to repaint a stale visible pane. Refresh output must not include
/// scrollback because the client already owns that history; emit only a
/// clear-and-repaint snapshot of the active viewport so no bytes reach the PTY
/// and no scrollback is duplicated.
pub fn serializeVisibleTerminalState(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal) ?[]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    // Same rationale as serializeTerminalState: synchronized output (DECSET
    // 2026) is a handshake with the *current* client, so replaying it would
    // make the repainted client defer rendering until its own timeout fires.
    const had_synchronized_output = term.modes.get(.synchronized_output);
    if (had_synchronized_output) {
        term.modes.set(.synchronized_output, false);
    }
    defer if (had_synchronized_output) {
        term.modes.set(.synchronized_output, true);
    };

    const had_wraparound = term.modes.get(.wraparound);
    term.modes.set(.wraparound, true);
    defer term.modes.set(.wraparound, had_wraparound);
    // CDXC:Zmx 2026-09-24 WHY:
    // The refresh carries its own synchronized-output pair (DECSET 2026 set here, reset as the last bytes below), so a terminal that honors the mode paints the finished dump once instead of the intermediate states of a dump that arrives over several reads (a flash of older screens on every grid change). Unlike replaying the program's open handshake above, this pair closes inside the same message; terminals that ignore the private mode are unaffected.
    // SEE-ALSO: apps/desktop/src/terminal_element.rs `synchronized_output_since` (Ghostex defers painting while the mode is set); wmx sends its refresh snapshot with the same pair.
    builder.writer.writeAll("\x1b[?2026h") catch return null;
    builder.writer.writeAll("\x1b[?7h") catch return null;

    builder.writer.writeAll("\x1b[2J\x1b[H\x1b[0m") catch {};

    var vis_fmt = ghostty_vt.formatter.TerminalFormatter.init(term, .vt);
    vis_fmt.opts.unwrap = true;
    const pages = &term.screens.active.pages;
    const active_tl = pages.pin(.{ .active = .{ .x = 0, .y = 0 } });
    const active_br = pages.pin(.{
        .active = .{
            .x = @intCast(pages.cols - 1),
            .y = @intCast(pages.rows - 1),
        },
    });

    if (active_tl != null and active_br != null) {
        vis_fmt.content = .{
            .selection = ghostty_vt.Selection.init(
                active_tl.?,
                active_br.?,
                false,
            ),
        };
    }
    vis_fmt.extra = .{
        .palette = false,
        .modes = true,
        .scrolling_region = true,
        .tabstops = false,
        .pwd = false, // emitted below without the sentinel the formatter includes
        .keyboard = true,
        .screen = .all,
    };

    vis_fmt.format(&builder.writer) catch |err| {
        std.log.warn("failed to format visible terminal state err={s}", .{@errorName(err)});
        return null;
    };

    if (!had_wraparound) builder.writer.writeAll("\x1b[?7l") catch return null;
    writePwd(&builder.writer, term);
    builder.writer.writeAll("\x1b[?2026l") catch return null;

    const output = builder.writer.buffered();
    if (output.len == 0) return null;

    return alloc.dupe(u8, output) catch |err| {
        std.log.warn("failed to allocate visible terminal state err={s}", .{@errorName(err)});
        return null;
    };
}

pub fn serializeTerminal(
    alloc: std.mem.Allocator,
    term: *ghostty_vt.Terminal,
    format: HistoryFormat,
) ?[]const u8 {
    return serializeTerminalRange(alloc, term, format, null);
}

/// Formats the active screen and at most `scrollback_rows` preceding physical
/// rows. Null preserves whole-history formatting. Alternate screens have no
/// scrollback, so their selection always stays inside the current grid.
pub fn serializeTerminalRange(
    alloc: std.mem.Allocator,
    term: *ghostty_vt.Terminal,
    format: HistoryFormat,
    scrollback_rows: ?u32,
) ?[]const u8 {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    const opts: ghostty_vt.formatter.Options = switch (format) {
        .plain => .plain,
        .vt => .vt,
        .html => .html,
    };
    var term_formatter = ghostty_vt.formatter.TerminalFormatter.init(term, opts);
    term_formatter.content = .{ .selection = null };
    if (scrollback_rows) |rows| {
        const pages = &term.screens.active.pages;
        const active_top = pages.getTopLeft(.active);
        const top = active_top.up(rows) orelse pages.getTopLeft(.screen);
        const bottom = pages.pin(.{ .active = .{
            .x = @intCast(pages.cols - 1),
            .y = @intCast(pages.rows - 1),
        } }) orelse return null;
        term_formatter.content = .{
            .selection = ghostty_vt.Selection.init(top, bottom, false),
        };
    }
    term_formatter.extra = switch (format) {
        .plain => .none,
        .vt => .{
            .palette = false,
            .modes = true,
            .scrolling_region = true,
            .tabstops = false,
            .pwd = false, // emitted below without the sentinel the formatter includes
            .keyboard = true,
            .screen = .all,
        },
        .html => .styles,
    };

    term_formatter.format(&builder.writer) catch |err| {
        std.log.warn("failed to format terminal err={s}", .{@errorName(err)});
        return null;
    };

    if (format == .vt) writePwd(&builder.writer, term);

    const output = builder.writer.buffered();
    if (output.len == 0) return null;

    return alloc.dupe(u8, output) catch |err| {
        std.log.warn("failed to allocate terminal output err={s}", .{@errorName(err)});
        return null;
    };
}

test "serializeTerminalState excludes synchronized output replay" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b[?2004h"); // Bracketed paste
    stream.nextSlice("\x1b[?2026h"); // Synchronized output
    stream.nextSlice("hello");

    try testing.expect(term.modes.get(.bracketed_paste));
    try testing.expect(term.modes.get(.synchronized_output));

    const output = serializeTerminalState(alloc, &term) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    // The serialized output should contain bracketed paste (DECSET 2004)
    // but NOT synchronized output (DECSET 2026)
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[?2004h") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[?2026h") == null);
}

test "serializeTerminalState replays the title" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b]2;my title\x07");
    stream.nextSlice("hello");

    const output = serializeTerminalState(alloc, &term) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\x1b]2;my title\x07") != null);
}

test "serializeTerminalState omits the title when none is set" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("hello");

    const output = serializeTerminalState(alloc, &term) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\x1b]2;") == null);
}

test "serializeTerminalState replays the pwd without a NUL sentinel" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b]7;file://myhost/private/tmp\x1b\\");
    stream.nextSlice("hello");

    const output = serializeTerminalState(alloc, &term) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\x1b]7;file://myhost/private/tmp\x1b\\") != null);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, output, 0));
}

test "serializeTerminalState omits the pwd when none is set" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("hello");

    const output = serializeTerminalState(alloc, &term) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\x1b]7;") == null);
}

test "serializeTerminal vt replays the pwd without a NUL sentinel" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b]7;file://myhost/private/tmp\x1b\\");
    stream.nextSlice("hello");

    const output = serializeTerminal(alloc, &term, .vt) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\x1b]7;file://myhost/private/tmp\x1b\\") != null);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, output, 0));
}

test "serializeTerminalRange screen only returns the active screen" {
    const alloc = testing.allocator;
    var term = try testCreateTerminal(alloc, testing.io, 80, 3, "1\r\n2\r\n3\r\n4\r\n5");
    defer term.deinit(alloc);

    const output = serializeTerminalRange(alloc, &term, .plain, 0) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);
    try testing.expectEqualStrings("3\n4\n5", output);
}

test "serializeTerminalRange adds the requested scrollback rows" {
    const alloc = testing.allocator;
    var term = try testCreateTerminal(alloc, testing.io, 80, 3, "1\r\n2\r\n3\r\n4\r\n5");
    defer term.deinit(alloc);

    const output = serializeTerminalRange(alloc, &term, .plain, 1) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);
    try testing.expectEqualStrings("2\n3\n4\n5", output);

    const all = serializeTerminalRange(alloc, &term, .plain, 100) orelse return error.TestUnexpectedNull;
    defer alloc.free(all);
    const full = serializeTerminal(alloc, &term, .plain) orelse return error.TestUnexpectedNull;
    defer alloc.free(full);
    try testing.expectEqualStrings(full, all);
}

test "serializeTerminalRange alternate screen returns only its grid" {
    const alloc = testing.allocator;
    var term = try testCreateTerminal(alloc, testing.io, 80, 3, "1\r\n2\r\n3\r\n4\r\n5\x1b[?1049h\x1b[Halt");
    defer term.deinit(alloc);

    const output = serializeTerminalRange(alloc, &term, .plain, 100) orelse return error.TestUnexpectedNull;
    defer alloc.free(output);
    try testing.expectEqualStrings("alt", output);
}

fn testCreateTerminal(alloc: std.mem.Allocator, io: std.Io, cols: u16, rows: u16, vt_data: []const u8) !ghostty_vt.Terminal {
    var term = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_lines = 2_000,
    });
    if (vt_data.len > 0) {
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice(vt_data);
    }
    return term;
}

fn expectScreensMatch(alloc: std.mem.Allocator, expected: *ghostty_vt.Terminal, actual: *ghostty_vt.Terminal) !void {
    const exp_str = try expected.plainString(alloc);
    defer alloc.free(exp_str);
    const act_str = try actual.plainString(alloc);
    defer alloc.free(act_str);
    try testing.expectEqualStrings(exp_str, act_str);
}

fn expectCursorAt(term: *ghostty_vt.Terminal, row: usize, col: usize) !void {
    const cursor = &term.screens.active.cursor;
    try testing.expectEqual(col, cursor.x);
    try testing.expectEqual(row, cursor.y);
}

fn serializeRoundtrip(alloc: std.mem.Allocator, io: std.Io, source: *ghostty_vt.Terminal) !ghostty_vt.Terminal {
    const serialized = serializeTerminalState(alloc, source) orelse
        return error.SerializationFailed;
    defer alloc.free(serialized);

    var dest = try ghostty_vt.Terminal.init(io, alloc, .{
        .cols = source.screens.active.pages.cols,
        .rows = source.screens.active.pages.rows,
        .max_scrollback_lines = 2_000,
    });
    var stream = dest.vtStream();
    defer stream.deinit();
    stream.nextSlice(serialized);
    return dest;
}

fn expectMarkerAtRow(alloc: std.mem.Allocator, term: *ghostty_vt.Terminal, marker: []const u8, expected_row: usize) !void {
    const plain = try term.plainString(alloc);
    defer alloc.free(plain);
    var row: usize = 0;
    var iter = std.mem.splitScalar(u8, plain, '\n');
    while (iter.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) != null) {
            try testing.expectEqual(expected_row, row);
            return;
        }
        row += 1;
    }
    std.debug.print("marker '{s}' not found in terminal output\n", .{marker});
    return error.TestExpectedEqual;
}

test "serializeTerminalState roundtrip preserves cursor position" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try testCreateTerminal(alloc, io, 80, 24, "\x1b[2J" ++ // clear
        "\x1b[10;20H" // cursor at row 10, col 20 (1-indexed)
    );
    defer term.deinit(alloc);

    try expectCursorAt(&term, 9, 19); // 0-indexed

    var client = try serializeRoundtrip(alloc, io, &term);
    defer client.deinit(alloc);

    try expectCursorAt(&client, 9, 19);
}

test "serializeTerminalState roundtrip preserves CUP-positioned markers" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try testCreateTerminal(alloc, io, 80, 24, "\x1b[2J" ++
        "\x1b[2;5HMARK_A" ++
        "\x1b[6;15HMARK_B" ++
        "\x1b[10;30HMARK_C" ++
        "\x1b[14;50HMARK_D" ++
        "\x1b[16;20H");
    defer term.deinit(alloc);

    var client = try serializeRoundtrip(alloc, io, &term);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &term, &client);
    try expectMarkerAtRow(alloc, &client, "MARK_A", 1);
    try expectMarkerAtRow(alloc, &client, "MARK_B", 5);
    try expectMarkerAtRow(alloc, &client, "MARK_C", 9);
    try expectMarkerAtRow(alloc, &client, "MARK_D", 13);
    try expectCursorAt(&client, 15, 19);
}

test "serializeTerminalState preserves all scrollback rows before clearing viewport" {
    const alloc = testing.allocator;
    const io = testing.io;
    for ([_]u16{ 1, 3, 24 }) |rows| {
        for ([_]usize{ 1, 2, 23, 24, 25, 80 }) |lines| {
            var term = try testCreateTerminal(alloc, io, 40, rows, "");
            defer term.deinit(alloc);
            {
                var stream = term.vtStream();
                defer stream.deinit();
                var buf: [32]u8 = undefined;
                for (0..lines) |index| {
                    stream.nextSlice(try std.fmt.bufPrint(&buf, "ROW_{d}\r\n", .{index}));
                }
                stream.nextSlice("\x1b[2J\x1b[Hvisible");
            }
            var restored = try serializeRoundtrip(alloc, io, &term);
            defer restored.deinit(alloc);
            const expected = try term.screens.active.dumpStringAlloc(alloc, .{ .screen = .{ .x = 0, .y = 0 } });
            defer alloc.free(expected);
            const actual = try restored.screens.active.dumpStringAlloc(alloc, .{ .screen = .{ .x = 0, .y = 0 } });
            defer alloc.free(actual);
            try testing.expectEqualStrings(expected, actual);
            try expectCursorAt(&restored, term.screens.active.cursor.y, term.screens.active.cursor.x);
        }
    }
}

test "serializeTerminalState allocation failure preserves synchronized output mode" {
    const alloc = testing.allocator;
    var term = try testCreateTerminal(alloc, testing.io, 40, 3, "one\r\ntwo\r\nthree\r\nfour\r\n");
    defer term.deinit(alloc);
    term.modes.set(.synchronized_output, true);
    var failing = testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try testing.expect(serializeTerminalState(failing.allocator(), &term) == null);
    try testing.expect(term.modes.get(.synchronized_output));
}

test "serializeTerminalState with scrollback preserves visible content" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try testCreateTerminal(alloc, io, 80, 24, "");
    defer term.deinit(alloc);

    var stream = term.vtStream();
    defer stream.deinit();

    // Generate 80 lines of scrollback (more than 24 visible rows)
    var buf: [32]u8 = undefined;
    for (0..80) |i| {
        const line = std.fmt.bufPrint(&buf, "SCROLL_{d}\r\n", .{i}) catch unreachable;
        stream.nextSlice(line);
    }

    // Clear screen and place markers at specific positions
    stream.nextSlice("\x1b[2J" ++
        "\x1b[2;5HMARK_A" ++
        "\x1b[6;15HMARK_B" ++
        "\x1b[10;30HMARK_C" ++
        "\x1b[16;20H");

    // Verify source terminal has scrollback
    const pages = &term.screens.active.pages;
    const has_scrollback = !pages.getTopLeft(.screen).eql(pages.getTopLeft(.active));
    try testing.expect(has_scrollback);

    // Roundtrip: serialize → feed into fresh terminal
    var client = try serializeRoundtrip(alloc, io, &term);
    defer client.deinit(alloc);

    // Visible content must match (this is the core cursor corruption test)
    try expectScreensMatch(alloc, &term, &client);
    try expectMarkerAtRow(alloc, &client, "MARK_A", 1);
    try expectMarkerAtRow(alloc, &client, "MARK_B", 5);
    try expectMarkerAtRow(alloc, &client, "MARK_C", 9);
    try expectCursorAt(&client, 15, 19);
}

test "serializeTerminalState nested roundtrip preserves content" {
    // Simulates: inner zmx → serialized state → outer ghostty-vt → serialized again → client
    // This is the exact nested session scenario (zmx → SSH → zmx).
    const alloc = testing.allocator;
    const io = testing.io;

    // "Inner" terminal with scrollback + markers
    var inner = try testCreateTerminal(alloc, io, 80, 24, "");
    defer inner.deinit(alloc);

    {
        var inner_stream = inner.vtStream();
        defer inner_stream.deinit();
        var buf: [32]u8 = undefined;
        for (0..60) |i| {
            const line = std.fmt.bufPrint(&buf, "SCROLL_{d}\r\n", .{i}) catch unreachable;
            inner_stream.nextSlice(line);
        }
        inner_stream.nextSlice("\x1b[2J" ++
            "\x1b[3;10HINNER_A" ++
            "\x1b[12;25HINNER_B" ++
            "\x1b[20;5H");
    }

    // Record inner's ground truth
    const inner_cursor_x = inner.screens.active.cursor.x;
    const inner_cursor_y = inner.screens.active.cursor.y;

    // Serialize inner (simulates inner daemon re-attach to inner client)
    const inner_serialized = serializeTerminalState(alloc, &inner) orelse
        return error.SerializationFailed;
    defer alloc.free(inner_serialized);

    // "Outer" terminal processes inner's serialized output
    var outer = try testCreateTerminal(alloc, io, 80, 24, "");
    defer outer.deinit(alloc);

    {
        var outer_stream = outer.vtStream();
        defer outer_stream.deinit();
        outer_stream.nextSlice(inner_serialized);
    }

    // Serialize outer (simulates outer daemon re-attach after detach)
    var client = try serializeRoundtrip(alloc, io, &outer);
    defer client.deinit(alloc);

    // Client must see the same content as inner's visible screen
    try expectScreensMatch(alloc, &inner, &client);
    try expectCursorAt(&client, inner_cursor_y, inner_cursor_x);
    try expectMarkerAtRow(alloc, &client, "INNER_A", 2);
    try expectMarkerAtRow(alloc, &client, "INNER_B", 11);
}

test "serializeTerminalState alternate screen not leaked" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try testCreateTerminal(alloc, io, 80, 24, "\x1b[?1049h" ++ // enter alt screen
        "\x1b[2J\x1b[3;10HALT_MARK" ++ // write on alt screen
        "\x1b[?1049l" ++ // exit alt screen
        "\x1b[2J\x1b[2;5HMAIN_MARK\x1b[8;20H" // write on main screen
    );
    defer term.deinit(alloc);

    var client = try serializeRoundtrip(alloc, io, &term);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &term, &client);

    const plain = try client.plainString(alloc);
    defer alloc.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "ALT_MARK") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "MAIN_MARK") != null);
}

test "serializeTerminalState size mismatch roundtrip" {
    const alloc = testing.allocator;
    const io = testing.io;

    var term = try testCreateTerminal(alloc, io, 80, 30, "\x1b[2J" ++
        "\x1b[3;10HSIZE_A" ++
        "\x1b[12;20HSIZE_B" ++
        "\x1b[20;40HSIZE_C" ++
        "\x1b[15;15H");
    defer term.deinit(alloc);

    // Resize to 24 rows (simulates outer terminal being smaller)
    try term.resize(alloc, ghostty_vt.Terminal.Resize{ .cols = 80, .rows = 24 });

    var client = try serializeRoundtrip(alloc, io, &term);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &term, &client);
    try expectCursorAt(&client, term.screens.active.cursor.y, term.screens.active.cursor.x);
}

test "serializeTerminalState scrollback + size mismatch nested roundtrip" {
    const alloc = testing.allocator;
    const io = testing.io;

    var inner = try testCreateTerminal(alloc, io, 80, 30, "");
    defer inner.deinit(alloc);

    {
        var inner_stream = inner.vtStream();
        defer inner_stream.deinit();
        var buf: [32]u8 = undefined;
        for (0..80) |i| {
            const line = std.fmt.bufPrint(&buf, "LINE_{d}\r\n", .{i}) catch unreachable;
            inner_stream.nextSlice(line);
        }
        inner_stream.nextSlice("\x1b[2J" ++
            "\x1b[3;10HSTRESS_A" ++
            "\x1b[12;25HSTRESS_B" ++
            "\x1b[16;20H");
    }

    // Resize inner to 24 rows (outer terminal is smaller)
    try inner.resize(alloc, ghostty_vt.Terminal.Resize{ .cols = 80, .rows = 24 });

    const inner_cursor_x = inner.screens.active.cursor.x;
    const inner_cursor_y = inner.screens.active.cursor.y;

    // Inner serialize → outer processes → outer serialize → client
    const inner_ser = serializeTerminalState(alloc, &inner) orelse
        return error.SerializationFailed;
    defer alloc.free(inner_ser);

    var outer = try testCreateTerminal(alloc, io, 80, 24, "");
    defer outer.deinit(alloc);
    {
        var outer_stream = outer.vtStream();
        defer outer_stream.deinit();
        outer_stream.nextSlice(inner_ser);
    }

    var client = try serializeRoundtrip(alloc, io, &outer);
    defer client.deinit(alloc);

    try expectScreensMatch(alloc, &inner, &client);
    try expectCursorAt(&client, inner_cursor_y, inner_cursor_x);
}

test "isUserInput: printable characters" {
    // Regular text should be detected as user input
    try testing.expect(isUserInput("hello"));
    try testing.expect(isUserInput("Hello World!"));
    try testing.expect(isUserInput("12345"));
    try testing.expect(isUserInput("!@#$%^&*()"));
}

test "isUserInput: whitespace characters" {
    // Space character is printable
    try testing.expect(isUserInput(" "));
    try testing.expect(isUserInput("   "));
}

test "isUserInput: line feed (LF)" {
    // LF triggers .execute action
    try testing.expect(isUserInput("\n"));
    try testing.expect(isUserInput("test\n"));
}

test "isUserInput: carriage return (CR)" {
    // CR triggers .execute action
    try testing.expect(isUserInput("\r"));
    try testing.expect(isUserInput("test\r"));
}

test "isUserInput: tab" {
    // Tab triggers .execute action
    try testing.expect(isUserInput("\t"));
    try testing.expect(isUserInput("col1\tcol2"));
}

test "isUserInput: backspace" {
    // Backspace triggers .execute action
    try testing.expect(isUserInput("\x08"));
    try testing.expect(isUserInput("test\x08"));
}

test "isUserInput: arrow keys (CSI ~)" {
    // Arrow keys use CSI with ~ - these have params
    try testing.expect(isUserInput("\x1b[3~")); // delete
    try testing.expect(isUserInput("\x1b[5~")); // page up
    try testing.expect(isUserInput("\x1b[6~")); // page down
}

test "isUserInput: modified arrow keys with CSI u" {
    // Modified arrow keys with CSI ... u
    try testing.expect(isUserInput("\x1bOA")); // up with modifier
    try testing.expect(isUserInput("\x1bOB")); // down with modifier
    try testing.expect(isUserInput("\x1bOC")); // right with modifier
    try testing.expect(isUserInput("\x1bOD")); // left with modifier
}

test "isUserInput: up arrow legacy" {
    // Legacy up arrow: CSI A (with params for kitty-style)
    try testing.expect(isUserInput("\x1b[1;1A")); // kitty-style legacy
}

test "isUserInput: up arrow kitty" {
    // Kitty keyboard up arrow: CSI 1;1;1A (no colon format supported by parser)
    try testing.expect(isUserInput("\x1b[1;1;1A")); // kitty up arrow
}

test "isUserInput: arrow keys with modifier params CSI A-D" {
    // Modified arrow keys like Ctrl+Up: CSI 1;5A
    try testing.expect(isUserInput("\x1b[1;5A")); // Ctrl+Up
    try testing.expect(isUserInput("\x1b[1;5B")); // Ctrl+Down
    try testing.expect(isUserInput("\x1b[1;5C")); // Ctrl+Right
    try testing.expect(isUserInput("\x1b[1;5D")); // Ctrl+Left
    try testing.expect(isUserInput("\x1b[1;3A")); // Alt+Up
    try testing.expect(isUserInput("\x1b[1;3B")); // Alt+Down
}

test "isUserInput: function keys with modifiers CSI 27 ; ~" {
    // Legacy modified keys: CSI 27 ; ... ~
    try testing.expect(isUserInput("\x1b[15;2~")); // F4 with modifier
    try testing.expect(isUserInput("\x1b[17;2~")); // F5 with modifier
    try testing.expect(isUserInput("\x1b[18;2~")); // F6 with modifier
}

test "isUserInput: enter key" {
    // Enter is LF (0x0A)
    try testing.expect(isUserInput("\x0A"));
}

test "isUserInput: mixed content" {
    // Mix of printable and control sequences
    try testing.expect(isUserInput("hello\nworld"));
    try testing.expect(isUserInput("\x1b[3~\x1b[6~")); // multiple CSI ~ sequences
    try testing.expect(isUserInput("abc\x1b[3~def")); // text with CSI ~
}

test "isUserInput: non-user input (escape sequences only)" {
    // Cursor movement without user input
    try testing.expect(!isUserInput("\x1b[2;1H")); // CSI H cursor home
    // SGR color set (no printing)
    try testing.expect(!isUserInput("\x1b[0m"));
    // Cursor position report query
    try testing.expect(!isUserInput("\x1b[6n"));
}

test "isUserInput: empty string" {
    try testing.expect(!isUserInput(""));
}

test "isUserInput: only whitespace controls" {
    // Multiple control chars should return true
    try testing.expect(isUserInput("\n\r\t"));
}

test "isUserInput: kitty keyboard sequences" {
    // Kitty keyboard protocol uses CSI u
    try testing.expect(isUserInput("\x1b[11;2u")); // F1 with modifier
    try testing.expect(isUserInput("\x1b[12;2u")); // F2 with modifier
    try testing.expect(isUserInput("\x1b[102;1:1u")); // literal "f" press
    try testing.expect(isUserInput("\x1b[57444;1:1u")); // Kitty functional key press
    try testing.expect(!isUserInput("\x1b[102;1:3u")); // literal "f" release only
    try testing.expect(isUserInput("\x1b[102;1:1u\x1b[67;65;31M")); // key press with mouse noise
}

test "isUserInput: mouse events (CSI M) excluded" {
    // Basic mouse tracking (SGR disabled): CSI M Cb Cx Cy
    // Mouse events should NOT trigger leader switch
    try testing.expect(!isUserInput("\x1b[M !!")); // button 0, column 1, row 1
    try testing.expect(!isUserInput("\x1b[M\"\"\"")); // button 2, column 2, row 2
}

test "isUserInput: mouse events SGR mode CSI < excluded" {
    // SGR extended mouse tracking: CSI < Cb;Cx;Y M
    // Mouse events should NOT trigger leader switch
    try testing.expect(!isUserInput("\x1b[<0;1;1M")); // button release
    try testing.expect(!isUserInput("\x1b[<64;1;1M")); // button press
}

test "isUserInput: focus events excluded" {
    // Focus in/out are automatic terminal events, not user typing
    try testing.expect(!isUserInput("\x1b[I")); // focus in
    try testing.expect(!isUserInput("\x1b[O")); // focus out
}

test "isUserInput: terminal query replies excluded" {
    // Replies every attached terminal sends to queries the app broadcasts.
    try testing.expect(!isUserInput("\x1b[?5u")); // kitty keyboard flags
    try testing.expect(!isUserInput("\x1b[?0u"));
    try testing.expect(!isUserInput("\x1b[?62;22;52c")); // DA1
    try testing.expect(!isUserInput("\x1b[>1;10;0c")); // DA2
    try testing.expect(!isUserInput("\x1b[?2026;2$y")); // DECRPM
    try testing.expect(!isUserInput("\x1b[?997;1n")); // color scheme
    try testing.expect(!isUserInput("\x1b[12;40R")); // cursor position
    try testing.expect(!isUserInput("\x1b[6;32;14t")); // cell size
    // XTVERSION + kitty flags + DA1 in one read, as a passive Ghostty
    // client sent it in the wild (it made that viewer the leader).
    try testing.expect(!isUserInput("\x1bP>|ghostty 1.3.2-main+64f5cc175\x1b\\\x1b[?5u\x1b[?62;22;52c"));
}

test "isUserInput: key after a reply in the same read still counts" {
    try testing.expect(isUserInput("\x1b[?5ux"));
    try testing.expect(isUserInput("\x1b[?62;22c\x1b[99;5u")); // reply then kitty ctrl+c
    try testing.expect(isUserInput("\x1b[?5u\x1b[3~")); // reply then delete
}

test "isUserInput: bracketed paste included" {
    // Bracketed paste start/end are user-initiated paste operations
    try testing.expect(isUserInput("\x1b[200~")); // paste start
    try testing.expect(isUserInput("\x1b[201~")); // paste end
    // Content between start/end is also user input
    try testing.expect(isUserInput("\x1b[200~hello\x1b[201~"));
}

test "isUserInput: kitty keyboard status reply is a terminal response" {
    // CSI ? flags u answers the program's CSI ? u query; no key was pressed
    try testing.expect(!isUserInput("\x1b[?1u"));
    try testing.expect(!isUserInput("\x1b[?0u"));
    try testing.expect(!isUserInput("\x1b[?31u"));
    // a real key coalesced with the reply still counts
    try testing.expect(isUserInput("\x1b[?1ua"));
    try testing.expect(isUserInput("\x1b[?1u\r"));
    try testing.expect(isUserInput("\x1b[?1u\x1b[97;1u"));
    try testing.expect(!isUserInput("\x1b[?1u\x1b[97;1:3u"));
}
