const std = @import("std");
const cross = @import("cross.zig");
const socket = @import("socket.zig");
const lib_posix = @import("posix.zig");

/// CDXC:ZmxWireGeneration 2026-09-03: the generation of the client<->daemon
/// wire contract this binary speaks, printed by `zmx version` as
/// `wire_generation\t<n>`. A daemon keeps running the code of the binary that
/// spawned it, so gxserver records this number per session and cycles (kills
/// and later restores) only the daemons whose recorded generation differs
/// from the bundled binary's. Cycling kills whatever agent is running inside
/// the session, so this number must change exactly when an OLD daemon can no
/// longer serve a NEW client:
///
/// BUMP when
///   - a `Tag` value is renumbered or removed,
///   - the payload layout of an existing tag changes (`Resize`, `Visibility`,
///     the `Init` header, a JSON reply schema a client parses strictly, ...),
///   - an existing tag changes meaning, or
///   - a client starts to REQUIRE a reply to a new tag without a compatibility
///     probe (the `SendAcked` ping in `sendToSessionPty` is the model for
///     avoiding that).
/// DO NOT bump when
///   - a new tag is added that old daemons drop through their `_` arm and
///     clients tolerate the silence (`Visibility`, `GridInfo`),
///   - a daemon-side bug fix, log line, or performance change lands, or
///   - upstream code unrelated to the IPC framing is merged.
///
/// Generation 1 also covers the 2026-09-05 widening of the Visibility byte from
/// `hidden: bool` to visible/chat/parked. Ghostex 8.8.0 already shipped tag 26
/// with the boolean, so live daemons do read that byte, but the payload is still
/// 9 bytes and an old daemon reads both chat and parked as `hidden = true` —
/// the resting-grid behaviour 8.8.0 already had. It degrades, it does not break,
/// so it is not worth cycling every live session and killing agents mid-task.
/// Generation 1 is the contract of tags 0-27 as of 2026-09-03 and every
/// binary since the 2026-08-23 tag renumbering, which is why gxserver treats
/// its older binary-identity stamps as generation 1.
pub const WIRE_GENERATION: u32 = 1;

pub const Tag = enum(u8) {
    Input = 0,
    Output = 1,
    Resize = 2,
    Detach = 3,
    DetachAll = 4,
    Kill = 5,
    Info = 6,
    Init = 7,
    History = 8,
    Run = 9,
    Ack = 10,
    Switch = 11,
    Write = 12,
    TaskComplete = 13,
    LabelGet = 14,
    LabelSet = 15,
    LabelClear = 16,
    LabelData = 17,
    Send = 18,
    // === Ghostex fork tags ===
    // Upstream owns 0-18. The fork's five tags used to live at 14-18 and were
    // renumbered to 19-23 when upstream claimed 14-18 for labels and Send.
    // This is a deliberate wire break against pre-renumber Ghostex daemons:
    // they must be cycled, not upgraded in place.
    Refresh = 19,
    TitleSubscribe = 20,
    TitleObserved = 21,
    RefreshIfStale = 22,
    PromptEditorCapability = 23,
    /// Like `Send`, but the daemon answers with `SendAck` once it has decided
    /// what to do with the payload. Added 2026-08-24 so `zmx send` can stop
    /// reporting success for bytes that never reached the pty queue.
    ///
    /// COMPATIBILITY: daemons predating this tag fall into the dispatcher's
    /// `_` arm, which logs and drops the message without desyncing the
    /// stream (the header is length-prefixed) and without closing the
    /// connection. That is exactly why `sendToSessionPty` pings with an
    /// EMPTY `SendAcked` first and only commits the real payload to this tag
    /// after a `SendAck` proves the daemon understands it.
    SendAcked = 24,
    /// Daemon -> client receipt for `SendAcked`. Payload is one byte holding
    /// a `SendAckStatus`.
    SendAck = 25,
    /// Client -> daemon: "my terminal is (not) being looked at, and this is
    /// its size". Payload is `VISIBILITY_WIRE_LEN` bytes (see `Visibility`).
    /// Added 2026-09-03 (CDXC:Zmx) so only a terminal someone is
    /// looking at may size the pty; old daemons drop it via the `_` arm.
    Visibility = 26,
    /// Client -> daemon request with an empty payload; daemon -> client reply
    /// whose payload is one JSON object (no trailing newline) describing the
    /// grid and leadership state. See `Daemon.handleGridInfo`.
    GridInfo = 27,
    // Non-exhaustive: this enum comes off the wire via bytesToValue and
    // @enumFromInt, so out-of-range values are representable
    // rather than UB. Switches must handle `_` (unknown tag).
    _,
};

comptime {
    if (@typeInfo(Tag).@"enum".is_exhaustive) @compileError(
        "ipc.Tag must stay non-exhaustive -- old daemons rely on `_` to ignore unknown tags",
    );
}

pub const Header = packed struct {
    tag: Tag,
    len: u32,
};

pub const Resize = packed struct {
    rows: u16,
    cols: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

/// CDXC:Zmx 2026-09-03: grid the daemon rests at when no
/// displayed terminal client owns the pty size. Wide enough that agent CLIs
/// (Claude Code, Codex, ...) stop truncating lines for the chat view that
/// reads the daemon's screen; also the no-tty fallback for `getTerminalSize`,
/// so headless `zmx run` spawns start here instead of at 24x120.
pub const RESTING_GRID_COLS: u16 = 200;
pub const RESTING_GRID_ROWS: u16 = 50;

/// Payload of `Tag.Visibility`. Fixed 9-byte wire layout (`VISIBILITY_WIRE_LEN`),
/// encoded by hand so no struct padding ever travels:
///   [0]    state: 0 = visible, 1 = chat, 2 = parked
///   [1..9] resize: the 8 `Resize` bytes exactly as `.Resize` ships them
///          (rows u16, cols u16, xpixel u16, ypixel u16, host byte order)
pub const VisibilityState = enum(u8) { visible = 0, chat = 1, parked = 2 };

pub const Visibility = struct {
    state: VisibilityState,
    resize: Resize,

    pub fn encode(self: Visibility) [VISIBILITY_WIRE_LEN]u8 {
        var out: [VISIBILITY_WIRE_LEN]u8 = undefined;
        out[0] = @intFromEnum(self.state);
        @memcpy(out[1..], std.mem.asBytes(&self.resize));
        return out;
    }

    /// Returns null for a payload of the wrong length or an unknown state.
    pub fn decode(payload: []const u8) ?Visibility {
        if (payload.len != VISIBILITY_WIRE_LEN) return null;
        return .{
            .state = std.enums.fromInt(VisibilityState, payload[0]) orelse return null,
            .resize = std.mem.bytesToValue(Resize, payload[1..][0..@sizeOf(Resize)]),
        };
    }
};

pub const VISIBILITY_WIRE_LEN = 1 + @sizeOf(Resize);

pub fn getTerminalSize(fd: i32) Resize {
    var ws: cross.c.struct_winsize = undefined;
    if (cross.c.ioctl(fd, cross.c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
    }
    inline for (.{ lib_posix.STDOUT_FILENO, lib_posix.STDIN_FILENO, lib_posix.STDERR_FILENO }) |fallback_fd| {
        if (fallback_fd != fd) {
            if (cross.c.ioctl(fallback_fd, cross.c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
                return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
            }
        }
    }
    if (lib_posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0)) |tty_fd| {
        defer lib_posix.close(tty_fd);
        if (cross.c.ioctl(tty_fd, cross.c.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
            return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
        }
    } else |_| {}
    return .{ .rows = RESTING_GRID_ROWS, .cols = RESTING_GRID_COLS };
}

pub const MAX_CMD_LEN = 256;
pub const MAX_CWD_LEN = 256;

/// Frozen wire shape. Do NOT add fields! New stats go in new `Tag` values
/// so old daemons (whose `_` arm ignores unknown tags) stay reachable.
/// Changing `@sizeOf(Info)` breaks `zmx list` against running daemons.
pub const Info = extern struct {
    clients_len: u64,
    pid: i32,
    cmd_len: u16,
    cwd_len: u16,
    cmd: [MAX_CMD_LEN]u8,
    cwd: [MAX_CWD_LEN]u8,
    created_at: u64,
    task_ended_at: u64,
    task_exit_code: u8,
};

pub fn expectedLength(data: []const u8) ?usize {
    if (data.len < @sizeOf(Header)) return null;
    const header = std.mem.bytesToValue(Header, data[0..@sizeOf(Header)]);
    // header.len comes off the wire; widen to usize before adding so a
    // near-u32-max value can't wrap (panic in safe mode, UB in release).
    return @as(usize, @sizeOf(Header)) + @as(usize, header.len);
}

pub fn send(fd: i32, tag: Tag, data: []const u8) !void {
    const header = Header{
        .tag = tag,
        .len = @intCast(data.len),
    };
    const header_bytes = std.mem.asBytes(&header);
    try writeAll(fd, header_bytes);
    if (data.len > 0) {
        try writeAll(fd, data);
    }
}

pub fn appendMessage(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(u8),
    tag: Tag,
    data: []const u8,
) !void {
    const header = Header{
        .tag = tag,
        .len = @intCast(data.len),
    };
    // Guarantee capacity for header + payload in one check to avoid
    // intermediate realloc between the two appends on the hot path.
    try list.ensureTotalCapacity(gpa, list.items.len + @sizeOf(Header) + data.len);
    list.appendSliceAssumeCapacity(std.mem.asBytes(&header));
    if (data.len > 0) {
        list.appendSliceAssumeCapacity(data);
    }
}

fn writeAll(fd: i32, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        const n = try lib_posix.write(fd, data[index..]);
        if (n == 0) return error.DiskQuota;
        index += n;
    }
}

pub const Message = struct {
    tag: Tag,
    data: []u8,

    pub fn deinit(self: Message, alloc: std.mem.Allocator) void {
        if (self.data.len > 0) {
            alloc.free(self.data);
        }
    }
};

pub const SocketMsg = struct {
    header: Header,
    payload: []const u8,
};

pub const SocketBuffer = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    head: usize,

    pub fn init(alloc: std.mem.Allocator) !SocketBuffer {
        return .{
            .buf = try std.ArrayList(u8).initCapacity(alloc, 4096),
            .alloc = alloc,
            .head = 0,
        };
    }

    pub fn deinit(self: *SocketBuffer) void {
        self.buf.deinit(self.alloc);
    }

    /// Reads from fd into buffer.
    /// Returns number of bytes read.
    /// Propagates error.WouldBlock and other errors to caller.
    /// Returns 0 on EOF.
    pub fn read(self: *SocketBuffer, fd: i32) !usize {
        if (self.head > 0) {
            const remaining = self.buf.items.len - self.head;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.head..]);
                self.buf.items.len = remaining;
            } else {
                self.buf.clearRetainingCapacity();
            }
            self.head = 0;
        }

        var tmp: [4096]u8 = undefined;
        const n = try lib_posix.read(fd, &tmp);
        if (n > 0) {
            try self.buf.appendSlice(self.alloc, tmp[0..n]);
        }
        return n;
    }

    /// Returns the next complete message or `null` when none available.
    /// `buf` is advanced automatically; caller keeps the returned slices
    /// valid until the following `next()` (or `deinit`).
    pub fn next(self: *SocketBuffer) ?SocketMsg {
        const available = self.buf.items[self.head..];
        const total = expectedLength(available) orelse return null;
        if (available.len < total) return null;

        const hdr = std.mem.bytesToValue(Header, available[0..@sizeOf(Header)]);
        const pay = available[@sizeOf(Header)..total];

        self.head += total;
        return .{ .header = hdr, .payload = pay };
    }
};

const ConnectError = error{
    ConnectionRefused,
    Unexpected,
};

/// Connect-only liveness check. Callers that don't read `Info` should use
/// this (not `probeSession`) so they survive `Info` shape changes.
pub fn connectSession(socket_path: []const u8) ConnectError!i32 {
    return socket.sessionConnect(socket_path) catch |err| switch (err) {
        error.ConnectionRefused => return error.ConnectionRefused,
        else => return error.Unexpected,
    };
}

const SessionProbeError = error{
    Timeout,
    ConnectionRefused,
    Unexpected,
    InfoSizeMismatch,
};

const SessionProbeResult = struct {
    fd: i32,
    info: Info,
    labels: ?[]const u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *const SessionProbeResult) void {
        if (self.labels) |lbl| self.alloc.free(lbl);
        lib_posix.close(self.fd);
    }
};

pub fn probeSession(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
) SessionProbeError!SessionProbeResult {
    const timeout_ms = 1000;
    const fd = try connectSession(socket_path);
    errdefer lib_posix.close(fd);

    send(fd, .Info, "") catch return error.Unexpected;
    send(fd, .LabelGet, "") catch {};

    var poll_fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
    const poll_result = lib_posix.poll(&poll_fds, timeout_ms) catch return error.Unexpected;
    if (poll_result == 0) {
        return error.Timeout;
    }

    var sb = SocketBuffer.init(alloc) catch return error.Unexpected;
    defer sb.deinit();

    const n = sb.read(fd) catch return error.Unexpected;
    if (n == 0) return error.Unexpected;

    var info_result: ?Info = null;
    var labels: ?[]const u8 = null;
    errdefer if (labels) |lbl| alloc.free(lbl);

    while (true) {
        if (sb.next()) |msg| {
            if (msg.header.tag == .Info) {
                if (msg.payload.len != @sizeOf(Info)) return error.InfoSizeMismatch;
                info_result = std.mem.bytesToValue(Info, msg.payload[0..@sizeOf(Info)]);
            }
            if (msg.header.tag == .LabelData) {
                labels = alloc.dupe(u8, msg.payload) catch null;
            }

            if (info_result != null and labels != null) break;
            continue;
        }

        // No complete message available, wait for more data
        const more = lib_posix.poll(&poll_fds, 50) catch break;
        if (more == 0) break;
        const n_read = sb.read(fd) catch break;
        if (n_read == 0) break;
    }

    if (info_result) |info| {
        return .{
            .fd = fd,
            .info = info,
            .labels = labels,
            .alloc = alloc,
        };
    }
    return error.Unexpected;
}

/// What the daemon did with a `SendAcked` payload. Wire value: one byte.
pub const SendAckStatus = enum(u8) {
    /// Appended to the pty input buffer. The poll loop flushes it.
    queued = 0,
    /// Dropped: the pty input buffer is at `PTY_WRITE_BUF_MAX` because the
    /// program on the other end stopped reading.
    dropped_pty_buffer_full = 1,
    /// Dropped: the daemon could not grow its pty input buffer.
    dropped_out_of_memory = 2,
    // Non-exhaustive for the same reason `Tag` is: it comes off the wire.
    _,
};

pub const SendDeliveryError = error{
    Timeout,
    ConnectionRefused,
    ConnectionLost,
    Unexpected,
};

pub const SendDelivery = union(enum) {
    /// The daemon reported what it did with the payload.
    acked: SendAckStatus,
    /// The daemon predates `Tag.SendAcked`, so the payload went out under the
    /// legacy `Tag.Send` and nothing confirms it reached the pty queue.
    legacy_unconfirmed,
};

/// How long to wait for the daemon's answer to the capability ping. Same
/// budget `probeSession` gives a liveness probe.
const SEND_PROBE_TIMEOUT_MS: i64 = 1000;

/// Reads framed messages off `fd` until `wanted` arrives or `timeout_ms`
/// elapses, discarding anything else (an unattached client still receives
/// `Output` broadcasts). Returns a slice into `sb`, valid until the next
/// read on it.
fn awaitMessage(
    io: std.Io,
    fd: i32,
    sb: *SocketBuffer,
    wanted: Tag,
    timeout_ms: i64,
    saw_send_ack: ?*bool,
    ack_status: ?*u8,
) SendDeliveryError![]const u8 {
    var poll_fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
    const started = std.Io.Timestamp.now(io, .awake);
    while (true) {
        // Drain everything already framed before touching the socket again.
        while (sb.next()) |msg| {
            if (msg.header.tag == .SendAck) {
                if (saw_send_ack) |flag| flag.* = true;
                if (ack_status) |slot| slot.* = if (msg.payload.len > 0) msg.payload[0] else 0;
            }
            if (msg.header.tag == wanted) return msg.payload;
        }

        const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
        const remaining = timeout_ms - elapsed;
        if (remaining <= 0) return error.Timeout;

        const ready = lib_posix.poll(&poll_fds, @intCast(remaining)) catch return error.Unexpected;
        if (ready == 0) return error.Timeout;
        const n = sb.read(fd) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return error.ConnectionLost,
        };
        // EOF: the daemon closed the connection without answering.
        if (n == 0) return error.ConnectionLost;
    }
}

/// Hand `payload` to a session's pty and find out whether it landed.
///
/// Ghostex's gxserver treats a zero exit from `zmx send` as proof the agent
/// received the text, so "the write went into a socket" is not good enough:
/// the daemon has to say it queued the bytes.
///
/// Capability detection costs no extra round trip. Requests are answered in
/// the order the daemon reads them, so an EMPTY `SendAcked` ping followed by
/// `Info` on the same connection is self-describing: a daemon that knows the
/// tag answers `SendAck` *before* `Info`, and an `Info` reply with no
/// `SendAck` in front of it proves the daemon is older and must be fed the
/// legacy `Send` tag. The ping itself is harmless either way -- an empty
/// payload queues nothing, and an old daemon just logs an unknown tag.
pub fn sendToSessionPty(
    alloc: std.mem.Allocator,
    io: std.Io,
    socket_path: []const u8,
    payload: []const u8,
    ack_timeout_ms: i64,
) SendDeliveryError!SendDelivery {
    const fd = try connectSession(socket_path);
    defer lib_posix.close(fd);

    try sendRequest(fd, .SendAcked, "");
    try sendRequest(fd, .Info, "");

    var sb = SocketBuffer.init(alloc) catch return error.Unexpected;
    defer sb.deinit();

    var supports_ack = false;
    _ = try awaitMessage(io, fd, &sb, .Info, SEND_PROBE_TIMEOUT_MS, &supports_ack, null);

    if (!supports_ack) {
        try sendRequest(fd, .Send, payload);
        return .legacy_unconfirmed;
    }

    try sendRequest(fd, .SendAcked, payload);
    var status_byte: u8 = @intFromEnum(SendAckStatus.queued);
    _ = try awaitMessage(io, fd, &sb, .SendAck, ack_timeout_ms, null, &status_byte);
    return .{ .acked = @enumFromInt(status_byte) };
}

fn sendRequest(fd: i32, tag: Tag, data: []const u8) SendDeliveryError!void {
    send(fd, tag, data) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return error.ConnectionLost,
        else => return error.Unexpected,
    };
}

//  WIRE PROTOCOL FREEZE: read before "fixing" any test below.
//
//  Changing these constants does not fix the test; it breaks every
//  running daemon for every user until they `pkill -f zmx`.
//
//  Need a new field?   → add a new `Tag` value (next free integer).
//  Need to remove one? → don't. Reserve the integer, stop sending it.
test "Info wire size is frozen" {
    try std.testing.expectEqual(@as(usize, 552), @sizeOf(Info));
    // packed struct{u8,u32} backs to u40 → @sizeOf rounds to 8, not 5.
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Header));
}

test "Tag wire values are frozen" {
    inline for (.{
        .{ Tag.Input, 0 },     .{ Tag.Output, 1 },        .{ Tag.Resize, 2 },
        .{ Tag.Detach, 3 },    .{ Tag.DetachAll, 4 },     .{ Tag.Kill, 5 },
        .{ Tag.Info, 6 },      .{ Tag.Init, 7 },          .{ Tag.History, 8 },
        .{ Tag.Run, 9 },       .{ Tag.Ack, 10 },          .{ Tag.Switch, 11 },
        .{ Tag.Write, 12 },    .{ Tag.TaskComplete, 13 }, .{ Tag.LabelGet, 14 },
        .{ Tag.LabelSet, 15 }, .{ Tag.LabelClear, 16 },   .{ Tag.LabelData, 17 },
        .{ Tag.Send, 18 },
    }) |p| try std.testing.expectEqual(@as(u8, p[1]), @intFromEnum(p[0]));
}

test "Ghostex fork Tag wire values are frozen" {
    inline for (.{
        .{ Tag.Refresh, 19 },                .{ Tag.TitleSubscribe, 20 },
        .{ Tag.TitleObserved, 21 },          .{ Tag.RefreshIfStale, 22 },
        .{ Tag.PromptEditorCapability, 23 }, .{ Tag.SendAcked, 24 },
        .{ Tag.SendAck, 25 },                .{ Tag.Visibility, 26 },
        .{ Tag.GridInfo, 27 },
    }) |p| try std.testing.expectEqual(@as(u8, p[1]), @intFromEnum(p[0]));
}

test "Visibility wire layout is frozen" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Resize));
    try std.testing.expectEqual(@as(usize, 9), VISIBILITY_WIRE_LEN);
    const v = Visibility{ .state = .chat, .resize = .{ .rows = 40, .cols = 150 } };
    const bytes = v.encode();
    try std.testing.expectEqual(@as(u8, 1), bytes[0]);
    const back = Visibility.decode(&bytes) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(VisibilityState.chat, back.state);
    try std.testing.expectEqual(@as(u16, 40), back.resize.rows);
    try std.testing.expectEqual(@as(u16, 150), back.resize.cols);
    try std.testing.expect(Visibility.decode(bytes[0..8]) == null);
}

pub fn roundTripForTag(
    alloc: std.mem.Allocator,
    socket_path: []const u8,
    request_tag: Tag,
    payload: []const u8,
    expected_tag: Tag,
) SessionProbeError![]u8 {
    const timeout_ms = 1000;
    const fd = try connectSession(socket_path);
    defer lib_posix.close(fd);

    send(fd, request_tag, payload) catch return error.Unexpected;

    var poll_fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
    const poll_result = lib_posix.poll(&poll_fds, timeout_ms) catch return error.Unexpected;
    if (poll_result == 0) return error.Timeout;

    var sb = SocketBuffer.init(alloc) catch return error.Unexpected;
    defer sb.deinit();

    const n = sb.read(fd) catch return error.Unexpected;
    if (n == 0) return error.Unexpected;

    while (sb.next()) |msg| {
        if (msg.header.tag == expected_tag) {
            return alloc.dupe(u8, msg.payload) catch return error.Unexpected;
        }
    }
    return error.Unexpected;
}

test "zeroed Info has no stack garbage in wire bytes" {
    var info = std.mem.zeroes(Info);
    info.clients_len = 3;
    info.pid = 999;
    info.task_exit_code = 7;
    const bytes = std.mem.asBytes(&info);
    // Tail padding after task_exit_code must be zero (asBytes ships it).
    const last_field_end = @offsetOf(Info, "task_exit_code") + @sizeOf(u8);
    for (bytes[last_field_end..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}
