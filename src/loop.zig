const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const ipc = @import("ipc.zig");
const log = @import("log.zig");
const util = @import("util.zig");
const cross = @import("cross.zig");
const socket = @import("socket.zig");
const label = @import("label.zig");
const title_events = @import("title_events.zig");
const lib_posix = @import("posix.zig");
const Cfg = @import("cfg.zig");
const signal = @import("signal.zig");
const assert = std.debug.assert;
const daemonize = @import("daemonize.zig");
const builtin = @import("builtin");

/// Prompt-editor capability bits advertised by an attaching client on .Init.
pub const prompt_editor_capability_monaco: u8 = 1;
pub const prompt_editor_capability_code_server: u8 = 2;

/// Ghostex sends this private OSC through the attached terminal to ask for a
/// display refresh. `clientLoop` consumes the exact sequence locally and turns
/// it into a Refresh IPC so the shell/PTY never receives the control bytes.
pub const ghostex_refresh_sequence = "\x1b]1337;ZMX_REFRESH\x07";

/// CDXC:Zmx 2026-09-03: every Ghostex private OSC shares this
/// prefix. The body between the prefix and the BEL terminator selects the IPC:
///   REFRESH               -> `.Refresh`
///   VISIBLE=<rows>,<cols> -> `.Visibility{ state = .visible, resize = rows x cols }`
///   CHAT=<rows>,<cols>    -> `.Visibility{ state = .chat, resize = rows x cols }`
///   HIDDEN=<rows>,<cols>  -> `.Visibility{ state = .parked, resize = rows x cols }`
/// `<rows>` and `<cols>` are decimal u16, both > 0. A terminated sequence with
/// any other body (unknown name, missing comma, zero, overflow, junk) is
/// consumed and dropped: the ZMX_ namespace is ours, so its control bytes are
/// never forwarded to the PTY. A prefix without a BEL in the same read is
/// forwarded untouched, matching the pre-existing REFRESH behaviour, which
/// also never reassembled a sequence split across two stdin reads.
pub const ghostex_osc_prefix = "\x1b]1337;ZMX_";
pub const ghostex_visible_body_prefix = "VISIBLE=";
pub const ghostex_chat_body_prefix = "CHAT=";
pub const ghostex_hidden_body_prefix = "HIDDEN=";
const ghostex_refresh_body = "REFRESH";
const osc_bel: u8 = 0x07;

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

const GhostexOscMessage = union(enum) {
    refresh,
    visibility: ipc.Visibility,
    /// Terminated but not a message we understand: consume silently.
    malformed,
};

/// Parse "<rows>,<cols>" as two decimal u16 values, both non-zero.
fn parseRowsCols(body: []const u8) ?ipc.Resize {
    const comma = std.mem.indexOfScalar(u8, body, ',') orelse return null;
    const rows = std.fmt.parseInt(u16, body[0..comma], 10) catch return null;
    const cols = std.fmt.parseInt(u16, body[comma + 1 ..], 10) catch return null;
    if (rows == 0 or cols == 0) return null;
    return .{ .rows = rows, .cols = cols };
}

fn parseGhostexOscBody(body: []const u8) GhostexOscMessage {
    if (std.mem.eql(u8, body, ghostex_refresh_body)) return .refresh;
    if (std.mem.startsWith(u8, body, ghostex_visible_body_prefix)) {
        const resize = parseRowsCols(body[ghostex_visible_body_prefix.len..]) orelse return .malformed;
        return .{ .visibility = .{ .state = .visible, .resize = resize } };
    }
    if (std.mem.startsWith(u8, body, ghostex_chat_body_prefix)) {
        const resize = parseRowsCols(body[ghostex_chat_body_prefix.len..]) orelse return .malformed;
        return .{ .visibility = .{ .state = .chat, .resize = resize } };
    }
    if (std.mem.startsWith(u8, body, ghostex_hidden_body_prefix)) {
        const resize = parseRowsCols(body[ghostex_hidden_body_prefix.len..]) orelse return .malformed;
        return .{ .visibility = .{ .state = .parked, .resize = resize } };
    }
    return .malformed;
}

/// clientLoop sends ipc commands to its corresponding daemon.  It uses poll() as its non-blocking
/// mechanism. It will send stdin to the daemon and receive stdout from the daemon.
/// Split raw client stdin into IPC messages, converting Ghostex's private
/// OSCs (refresh, visible, chat, hidden) into IPC instead of forwarding them to the PTY.
///
/// CDXC:Zmx 2026-05-20-09:57: Ghostex sends a private OSC refresh
/// request through the attached terminal because that path is already connected
/// to the correct zmx client. zmx must consume that exact sequence locally and
/// convert it to Refresh IPC so the shell/PTY never receives the control bytes.
fn appendClientInputMessages(gpa: std.mem.Allocator, sock_write_buf: *std.ArrayList(u8), input: []const u8) !void {
    var remaining = input;
    while (std.mem.indexOf(u8, remaining, ghostex_osc_prefix)) |index| {
        const tail = remaining[index..];
        // No terminator in this read: forward the rest verbatim, as the
        // REFRESH-only implementation did.
        const bel = std.mem.indexOfScalar(u8, tail, osc_bel) orelse break;
        if (index > 0) {
            try ipc.appendMessage(gpa, sock_write_buf, .Input, remaining[0..index]);
        }
        switch (parseGhostexOscBody(tail[ghostex_osc_prefix.len..bel])) {
            .refresh => try ipc.appendMessage(gpa, sock_write_buf, .Refresh, ""),
            .visibility => |visibility| try ipc.appendMessage(
                gpa,
                sock_write_buf,
                .Visibility,
                &visibility.encode(),
            ),
            .malformed => std.log.warn("dropping malformed Ghostex OSC len={d}", .{bel + 1}),
        }
        remaining = tail[bel + 1 ..];
    }
    if (remaining.len > 0) {
        try ipc.appendMessage(gpa, sock_write_buf, .Input, remaining);
    }
}

test "appendClientInputMessages converts Ghostex refresh OSC to Refresh IPC" {
    const alloc = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    try appendClientInputMessages(alloc, &out, "before" ++ ghostex_refresh_sequence ++ "after");

    var offset: usize = 0;
    const first_header = std.mem.bytesToValue(ipc.Header, out.items[offset..][0..@sizeOf(ipc.Header)]);
    offset += @sizeOf(ipc.Header);
    try std.testing.expectEqual(ipc.Tag.Input, first_header.tag);
    const first_len: usize = @intCast(first_header.len);
    try std.testing.expectEqualStrings("before", out.items[offset..][0..first_len]);
    offset += first_len;

    const refresh_header = std.mem.bytesToValue(ipc.Header, out.items[offset..][0..@sizeOf(ipc.Header)]);
    offset += @sizeOf(ipc.Header);
    try std.testing.expectEqual(ipc.Tag.Refresh, refresh_header.tag);
    try std.testing.expectEqual(@as(u32, 0), refresh_header.len);

    const second_header = std.mem.bytesToValue(ipc.Header, out.items[offset..][0..@sizeOf(ipc.Header)]);
    offset += @sizeOf(ipc.Header);
    try std.testing.expectEqual(ipc.Tag.Input, second_header.tag);
    const second_len: usize = @intCast(second_header.len);
    try std.testing.expectEqualStrings("after", out.items[offset..][0..second_len]);
}

pub fn clientLoop(client_sock_fd: i32, prompt_editor_capabilities: u8) !ClientResult {
    std.log.info("client loop fd={d}", .{client_sock_fd});
    const gpa: std.mem.Allocator = blk: {
        if (builtin.mode == .Debug) {
            const GPA = std.heap.DebugAllocator(.{});
            const Static = struct {
                var gpa: GPA = .{};
            };
            break :blk Static.gpa.allocator();
        }
        break :blk std.heap.c_allocator;
    };
    defer lib_posix.close(client_sock_fd);

    try signal.openSignalPipe();
    signal.installWakeHandler(@intFromEnum(lib_posix.SIG.WINCH));

    // Make socket non-blocking to avoid blocking on writes
    var sock_flags = try lib_posix.fcntl(client_sock_fd, lib_posix.F.GETFL, 0);
    sock_flags |= lib_posix.O_NONBLOCK;
    _ = try lib_posix.fcntl(client_sock_fd, lib_posix.F.SETFL, sock_flags);

    // Buffer for outgoing socket writes
    var sock_write_buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
    defer sock_write_buf.deinit(gpa);

    // Send init message with terminal size (buffered), plus the client's
    // prompt-editor capability byte. Omitting the byte means "machine editor".
    const size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
    var init_payload: [@sizeOf(ipc.Resize) + 1]u8 = undefined;
    @memcpy(init_payload[0..@sizeOf(ipc.Resize)], std.mem.asBytes(&size));
    init_payload[@sizeOf(ipc.Resize)] = prompt_editor_capabilities;
    try ipc.appendMessage(gpa, &sock_write_buf, .Init, &init_payload);

    var poll_fds = try std.ArrayList(lib_posix.pollfd).initCapacity(gpa, 4);
    defer poll_fds.deinit(gpa);

    var read_buf = try ipc.SocketBuffer.init(gpa);
    defer read_buf.deinit();

    var stdout_buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
    defer stdout_buf.deinit(gpa);

    const stdin_fd = lib_posix.STDIN_FILENO;

    // Make stdin non-blocking. O_NONBLOCK is set on the open file description,
    // which is shared with the parent shell; restore on exit to avoid
    // corrupting the parent's stdin.
    const stdin_orig_flags = try lib_posix.fcntl(stdin_fd, lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(stdin_fd, lib_posix.F.SETFL, stdin_orig_flags | lib_posix.O_NONBLOCK);
    defer _ = lib_posix.fcntl(stdin_fd, lib_posix.F.SETFL, stdin_orig_flags) catch {};

    const detach_key_disabled = util.isDetachKeyDisabled();

    while (true) {
        poll_fds.clearRetainingCapacity();

        try poll_fds.append(gpa, .{
            .fd = stdin_fd,
            .events = lib_posix.POLL.IN,
            .revents = 0,
        });

        // Poll socket for read, and also for write if we have pending data
        var sock_events: i16 = lib_posix.POLL.IN;
        if (sock_write_buf.items.len > 0) {
            sock_events |= lib_posix.POLL.OUT;
        }
        try poll_fds.append(gpa, .{
            .fd = client_sock_fd,
            .events = sock_events,
            .revents = 0,
        });

        try poll_fds.append(gpa, .{ .fd = signal.sig_pipe[0], .events = lib_posix.POLL.IN, .revents = 0 });

        if (stdout_buf.items.len > 0) {
            try poll_fds.append(gpa, .{
                .fd = lib_posix.STDOUT_FILENO,
                .events = lib_posix.POLL.OUT,
                .revents = 0,
            });
        }

        _ = try lib_posix.poll(poll_fds.items, -1);

        if (poll_fds.items[2].revents & lib_posix.POLL.IN != 0) {
            signal.drainSignalPipe();
            const next_size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
            try ipc.appendMessage(gpa, &sock_write_buf, .Resize, std.mem.asBytes(&next_size));
        }

        // Handle stdin -> socket (Input)
        const inp_flags = (lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL);
        if (poll_fds.items[0].revents & inp_flags != 0) {
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = lib_posix.read(stdin_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                return err;
            };

            if (n_opt) |n| {
                if (n > 0) {
                    // Check for detach sequences (ctrl+\ as first byte or Kitty escape sequence)
                    if (!detach_key_disabled and util.isCtrlBackslash(buf[0..n])) {
                        std.log.info("detach key detected", .{});
                        try ipc.appendMessage(gpa, &sock_write_buf, .Detach, "");
                    } else {
                        try appendClientInputMessages(gpa, &sock_write_buf, buf[0..n]);
                    }
                } else {
                    std.log.info("eof stdin", .{});
                    // EOF on stdin
                    return ClientResult{ .kind = .detach, .session_name = null };
                }
            }
        }

        // Handle socket read (incoming Output messages from daemon)
        if (poll_fds.items[1].revents & lib_posix.POLL.IN != 0) {
            const n = read_buf.read(client_sock_fd) catch |err| {
                if (err == error.WouldBlock) continue;
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                    return ClientResult{ .kind = .detach, .session_name = null };
                }
                std.log.err("daemon read err={s}", .{@errorName(err)});
                return err;
            };
            if (n == 0) {
                std.log.info("server closed connection", .{});
                // Server closed connection
                return ClientResult{ .kind = .detach, .session_name = null };
            }

            while (read_buf.next()) |msg| {
                switch (msg.header.tag) {
                    .Output => {
                        if (msg.payload.len > 0) {
                            try stdout_buf.appendSlice(gpa, msg.payload);
                        }
                    },
                    .Resize => {
                        // daemon is asking for the client's window size usually in response
                        // to this client being set as leader.
                        const next_size = ipc.getTerminalSize(lib_posix.STDOUT_FILENO);
                        try ipc.appendMessage(
                            gpa,
                            &sock_write_buf,
                            .Resize,
                            std.mem.asBytes(&next_size),
                        );
                    },
                    .Switch => {
                        std.log.info("switch session", .{});
                        // Payload format: "session_name\ncwd" from the daemon
                        const newline_idx = std.mem.indexOfScalar(u8, msg.payload, '\n') orelse {
                            // No cwd provided (backward compat or old daemon)
                            return ClientResult{ .kind = .switch_session, .session_name = try gpa.dupe(u8, msg.payload) };
                        };
                        return ClientResult{
                            .kind = .switch_session,
                            .session_name = try gpa.dupe(u8, msg.payload[0..newline_idx]),
                            .cwd = if (newline_idx + 1 < msg.payload.len) try gpa.dupe(u8, msg.payload[newline_idx + 1 ..]) else null,
                        };
                    },
                    else => {},
                }
            }
        }

        // Handle socket write (flush buffered messages to daemon)
        if (poll_fds.items[1].revents & lib_posix.POLL.OUT != 0) {
            if (sock_write_buf.items.len > 0) {
                const n = lib_posix.write(client_sock_fd, sock_write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                        std.log.info("connection reset or broken pipe", .{});
                        return ClientResult{ .kind = .detach, .session_name = null };
                    }
                    return err;
                };
                if (n > 0) {
                    try sock_write_buf.replaceRange(gpa, 0, n, &[_]u8{});
                }
            }
        }

        if (stdout_buf.items.len > 0) {
            const n = lib_posix.write(lib_posix.STDOUT_FILENO, stdout_buf.items) catch |err| blk: {
                if (err == error.WouldBlock) break :blk 0;
                return err;
            };
            if (n > 0) {
                try stdout_buf.replaceRange(gpa, 0, n, &[_]u8{});
            }
        }

        if (poll_fds.items[1].revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) {
            std.log.info("poll hup|err|nval", .{});
            return ClientResult{ .kind = .detach, .session_name = null };
        }
    }
}

/// dameonLoop is what the daemon runs to send and receive ipc commands from its corresponding
/// clients.  It uses poll() as its non-blocking mechanism.
fn daemonLoop(daemon: *Daemon, gpa: std.mem.Allocator, io: std.Io, server_sock_fd: lib_posix.socket_t, pty_fd: i32) !void {
    std.log.info("daemon started session=<redacted> pty_fd={d}", .{pty_fd});

    try signal.openSignalPipe();
    signal.installWakeHandler(@intFromEnum(lib_posix.SIG.TERM));
    var poll_fds = try std.ArrayList(lib_posix.pollfd).initCapacity(gpa, 8);
    defer poll_fds.deinit(gpa);

    const init_size = ipc.getTerminalSize(pty_fd);
    var term = try ghostty_vt.Terminal.init(io, gpa, .{
        .cols = init_size.cols,
        .rows = init_size.rows,
        .max_scrollback_lines = daemon.cfg.max_scrollback_lines,
    });
    defer term.deinit(gpa);
    var vt_stream = term.vtStream();
    defer vt_stream.deinit();
    daemon.pty_fd = pty_fd;
    daemon.term = &term;
    defer daemon.term = null;

    // Carries the tail of the previous PTY read so the task-exit marker
    // search below can see across a read() boundary. Sized to comfortably
    // hold "ZMX_TASK_COMPLETED:" (19 bytes) plus a u8 exit code and CRLF.
    var marker_carry: [32]u8 = undefined;
    var marker_carry_len: usize = 0;

    daemon_loop: while (daemon.running) {
        poll_fds.clearRetainingCapacity();

        try poll_fds.append(gpa, .{
            .fd = server_sock_fd,
            .events = lib_posix.POLL.IN,
            .revents = 0,
        });

        var pty_events: i16 = lib_posix.POLL.IN;
        if (daemon.pty_write_buf.items.len > 0) {
            pty_events |= lib_posix.POLL.OUT;
        }
        try poll_fds.append(gpa, .{
            .fd = pty_fd,
            .events = pty_events,
            .revents = 0,
        });

        try poll_fds.append(gpa, .{ .fd = signal.sig_pipe[0], .events = lib_posix.POLL.IN, .revents = 0 });

        for (daemon.clients.items) |client| {
            var events: i16 = lib_posix.POLL.IN;
            if (client.has_pending_output) {
                events |= lib_posix.POLL.OUT;
            }
            try poll_fds.append(gpa, .{
                .fd = client.socket_fd,
                .events = events,
                .revents = 0,
            });
        }

        // A pending title observation needs a bounded poll so the coalescer's
        // debounce / max-settle / heartbeat deadlines still fire on an
        // otherwise idle session. -1 when nothing is pending.
        _ = try lib_posix.poll(poll_fds.items, daemon.titlePollTimeoutMs(io));
        try daemon.flushTitleIfDue(gpa, io);

        if (poll_fds.items[2].revents & lib_posix.POLL.IN != 0) {
            signal.drainSignalPipe();
            std.log.info(
                "SIGTERM received, shutting down gracefully session=<redacted>",
                .{},
            );
            break :daemon_loop;
        }

        if (poll_fds.items[0].revents & (lib_posix.POLL.ERR | lib_posix.POLL.HUP | lib_posix.POLL.NVAL) != 0) {
            std.log.err("server socket error revents={d}", .{poll_fds.items[0].revents});
            break :daemon_loop;
        } else if (poll_fds.items[0].revents & lib_posix.POLL.IN != 0) {
            const client_fd = try lib_posix.accept(
                server_sock_fd,
                null,
                null,
                lib_posix.SOCK.NONBLOCK | lib_posix.SOCK.CLOEXEC,
            );
            const client = try gpa.create(Client);
            client.* = Client{
                .alloc = gpa,
                .socket_fd = client_fd,
                .read_buf = try ipc.SocketBuffer.init(gpa),
                .write_buf = undefined,
            };
            // 64KB initial capacity lets ~15 broadcast cycles (N_TTY_BUF_SIZE reads
            // * header) accumulate before the first ArrayList growth. The write
            // buffer is userspace-only: it drains via POLLOUT to the client socket,
            // which has no corresponding kernel-imposed per-write limit.
            client.write_buf = try std.ArrayList(u8).initCapacity(client.alloc, 65536);
            try daemon.clients.append(gpa, client);
            std.log.info(
                "client connected fd={d} total={d}",
                .{ client_fd, daemon.clients.items.len },
            );
        }

        const inp_flags = lib_posix.POLL.IN | lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL;
        if (poll_fds.items[1].revents & inp_flags != 0) {
            // Read from PTY. Buffer is sized to N_TTY_BUF_SIZE (4096): the hard
            // kernel limit for the N_TTY line discipline. A larger buffer doesn't
            // help: each read() from a PTY master returns at most 4096 bytes
            // regardless of the userspace buffer size.
            var buf: [4096]u8 = undefined;
            const n_opt: ?usize = lib_posix.read(pty_fd, &buf) catch |err| blk: {
                if (err == error.WouldBlock) break :blk null;
                break :blk 0;
            };

            if (n_opt) |n| {
                if (n == 0) {
                    // EOF: Shell exited
                    std.log.info("shell exited pty_fd={d}", .{pty_fd});
                    // Let the rest of this poll iteration complete so client
                    // write buffers are flushed via the normal POLLOUT path.
                    // On the next iteration, daemon.running will be false.
                    daemon.running = false;
                } else {
                    // Feed PTY output to terminal emulator for state tracking
                    vt_stream.nextSlice(buf[0..n]);
                    daemon.setPwd(&term);
                    if (term.getTitle()) |title| {
                        try daemon.observeTerminalTitle(gpa, io, title);
                    }
                    daemon.has_pty_output = true;

                    // When no real terminal client has attached yet, respond to
                    // terminal queries (e.g. DA1/DA2) on behalf of the terminal.
                    // This prevents fish from waiting 10s for unanswered queries.
                    // `has_terminal_client` is only set when a client sends .Init
                    // (a real zmx attach), not when a `zmx run` tail-only client
                    // connects.
                    if (!daemon.has_terminal_client and
                        daemon.pty_write_buf.items.len < Daemon.PTY_WRITE_BUF_MAX)
                    {
                        util.respondToDeviceAttributes(gpa, &daemon.pty_write_buf, buf[0..n]);
                    }

                    // In run mode, scan output for exit code marker. The marker
                    // can straddle two PTY reads (more likely under a throttled
                    // scheduler, e.g. containers), so prepend the tail carried
                    // over from the previous read before searching.
                    if (daemon.is_task_mode and daemon.task_exit_code == null) {
                        var scan_buf: [marker_carry.len + buf.len]u8 = undefined;
                        @memcpy(scan_buf[0..marker_carry_len], marker_carry[0..marker_carry_len]);
                        @memcpy(scan_buf[marker_carry_len..][0..n], buf[0..n]);
                        const scan_len = marker_carry_len + n;

                        if (try util.findTaskExitMarker(scan_buf[0..scan_len], daemon.task_id)) |exit_code| {
                            daemon.task_exit_code = exit_code;
                            daemon.task_ended_at = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());

                            std.log.info("task completed exit_code={d}", .{exit_code});

                            // Notify connected clients
                            for (daemon.clients.items) |c| {
                                if (c.is_title_watcher) continue;
                                ipc.appendMessage(gpa, &c.write_buf, .TaskComplete, &[_]u8{exit_code}) catch {};
                                c.has_pending_output = true;
                            }
                        }

                        marker_carry_len = @min(marker_carry.len, scan_len);
                        @memcpy(
                            marker_carry[0..marker_carry_len],
                            scan_buf[scan_len - marker_carry_len .. scan_len],
                        );
                    }

                    // Broadcast data to all clients.
                    // Rewrite OSC 133;A to include redraw=0 so the outer terminal
                    // does not clear prompt lines on resize (issue #111).
                    const broadcast_data = util.rewritePromptRedraw(gpa, buf[0..n]) orelse buf[0..n];
                    defer if (broadcast_data.ptr != buf[0..n].ptr) gpa.free(broadcast_data);
                    for (daemon.clients.items) |client| {
                        if (client.is_title_watcher) continue;
                        ipc.appendMessage(gpa, &client.write_buf, .Output, broadcast_data) catch |err| {
                            std.log.warn(
                                "failed to buffer output for client err={s}",
                                .{@errorName(err)},
                            );
                            continue;
                        };
                        client.has_pending_output = true;
                    }
                }
            }
        }

        if (poll_fds.items[1].revents & lib_posix.POLL.OUT != 0) {
            while (daemon.pty_write_buf.items.len > 0) {
                const n = lib_posix.write(pty_fd, daemon.pty_write_buf.items) catch |err| {
                    if (err != error.WouldBlock) {
                        // Everything still queued for the pty is thrown away
                        // here, which silently eats already-acked `.Send` /
                        // `.SendAcked` payloads. Log it as an error with the
                        // byte count so the loss is attributable. Session
                        // names stay out of daemon logs on purpose
                        // (CDXC:Telemetry); the log file is named
                        // after this daemon's pid, which identifies it.
                        std.log.err(
                            "pty write failed: {s}; dropped {d} unflushed pty input bytes session=<redacted>",
                            .{ @errorName(err), daemon.pty_write_buf.items.len },
                        );
                        daemon.pty_write_buf.clearRetainingCapacity();
                    }
                    break;
                };
                if (n == 0) break;
                daemon.pty_write_buf.replaceRange(gpa, 0, n, &[_]u8{}) catch unreachable;
            }
        }

        var i: usize = daemon.clients.items.len;
        // Only iterate over clients that were present when poll_fds was constructed
        // poll_fds contains [server, pty, sig_pipe, client0, client1, ...]
        // So number of clients in poll_fds is poll_fds.items.len - 3
        const num_polled_clients = poll_fds.items.len - 3;
        if (i > num_polled_clients) {
            // If we have more clients than polled (i.e. we just accepted one), start from the
            // polled ones
            i = num_polled_clients;
        }

        clients_loop: while (i > 0) {
            i -= 1;
            const client = daemon.clients.items[i];
            const revents = poll_fds.items[i + 3].revents;

            if (revents & lib_posix.POLL.IN != 0) {
                const n = client.read_buf.read(client.socket_fd) catch |err| {
                    if (err == error.WouldBlock) continue;
                    std.log.debug(
                        "client read err={s} fd={d}",
                        .{ @errorName(err), client.socket_fd },
                    );
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n == 0) {
                    // Client closed connection
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                }

                while (client.read_buf.next()) |msg| {
                    switch (msg.header.tag) {
                        .Input => try daemon.handleInput(gpa, client, msg.payload),
                        .Send => daemon.handleSend(gpa, msg.payload),
                        .SendAcked => try daemon.handleSendAcked(gpa, client, msg.payload),
                        .Output => try daemon.handleOutput(gpa, msg.payload, &term, &vt_stream),
                        .Init => try daemon.handleInit(gpa, client, pty_fd, &term, msg.payload),
                        .Switch => try daemon.handleSwitch(gpa, msg.payload),
                        .Resize => try daemon.handleResize(gpa, client, pty_fd, &term, msg.payload),
                        .Detach => {
                            daemon.handleDetach(gpa, client, i);
                            break :clients_loop;
                        },
                        .DetachAll => {
                            daemon.handleDetachAll(gpa);
                            break :clients_loop;
                        },
                        .Kill => {
                            break :daemon_loop;
                        },
                        .Info => try daemon.handleInfo(gpa, client, &term),
                        .LabelGet => try daemon.handleLabelGet(gpa, client),
                        .LabelSet => try daemon.handleLabelSet(gpa, client, msg.payload),
                        .LabelClear => try daemon.handleLabelClear(gpa, client),
                        .History => try daemon.handleHistory(gpa, client, &term, msg.payload),
                        .Run => try daemon.handleRun(gpa, io, client, msg.payload),
                        .Refresh => try daemon.handleRefresh(gpa, client, &term),
                        .RefreshIfStale => try daemon.handleRefreshIfStale(gpa, client, pty_fd, &term, msg.payload),
                        .PromptEditorCapability => try daemon.handlePromptEditorCapability(gpa, client),
                        .Visibility => try daemon.handleVisibility(gpa, client, msg.payload),
                        .GridInfo => try daemon.handleGridInfo(gpa, client, &term),
                        .TitleSubscribe => try daemon.handleTitleSubscribe(gpa, io, client, &term),
                        // Daemon -> client tags. A client never sends these.
                        .Ack, .TaskComplete, .LabelData, .TitleObserved, .SendAck => {},
                        .Write => try daemon.handleWrite(gpa, client, msg.payload),
                        _ => std.log.warn(
                            "ignoring unknown IPC tag={d}",
                            .{@intFromEnum(msg.header.tag)},
                        ),
                    }
                }
            }

            if (revents & lib_posix.POLL.OUT != 0) {
                // Flush pending output buffers
                const n = lib_posix.write(client.socket_fd, client.write_buf.items) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    // Error on write, close client
                    const last = daemon.closeClient(gpa, client, i, false);
                    if (last) break :daemon_loop;
                    continue;
                };

                if (n > 0) {
                    client.write_buf.replaceRange(gpa, 0, n, &[_]u8{}) catch unreachable;
                }

                if (client.write_buf.items.len == 0) {
                    client.has_pending_output = false;
                }
            }

            if (revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0) {
                const last = daemon.closeClient(gpa, client, i, false);
                if (last) break :daemon_loop;
            }
        }
    }
}

const ClientResult = struct {
    kind: enum {
        detach,
        switch_session,
    },
    session_name: ?[]const u8,
    cwd: ?[]const u8 = null,
};

/// Client represents each terminal that has connected to a session.
///
/// Multiple Clients can connect to a single session.
pub const Client = struct {
    alloc: std.mem.Allocator,
    socket_fd: i32,
    has_pending_output: bool = false,
    /// True once the client sent .Init, i.e. it is a real attached terminal
    /// that can render an Output repaint.
    is_terminal: bool = false,
    /// True for `zmx watch-title` clients. They are process plumbing, not a
    /// user-visible client: they never receive Output/TaskComplete and are
    /// excluded from the `zmx list` client count.
    is_title_watcher: bool = false,
    /// Prompt-editor capability bits this client advertised on .Init.
    /// See `prompt_editor_capability_monaco` / `_code_server`.
    prompt_editor_capabilities: u8 = 0,
    /// CDXC:Zmx 2026-09-03: the last grid this client reported
    /// (Init, Resize, or Visibility payload). `electLeader` applies it without
    /// a `.Resize` round trip.
    last_size: ?ipc.Resize = null,
    /// Explicit terminal/chat/parked claim; input and Init promote to visible.
    visibility: ipc.VisibilityState = .visible,
    /// CDXC:Zmx 2026-09-05 WHY:
    /// Pinning a parked emulator sends SIGWINCH before its OSC can arrive, briefly resizing the shared PTY to 200 even without chat.
    /// Once a client opts into visibility claims, only those ordered claims carry its grid; plain attach clients still use Resize.
    /// SEE-ALSO: apps/desktop/src/terminal_element.rs, server/src/terminal_ws.rs, apps/mobile/app/src/terminal/zmxDisplay.ts.
    uses_visibility_claims: bool = false,
    /// Copy of `Daemon.activity_clock` taken the last time this client
    /// attached, typed, or claimed visibility. Higher = more recent.
    activity: u64 = 0,
    read_buf: ipc.SocketBuffer,
    write_buf: std.ArrayList(u8),

    pub fn deinit(self: *Client) void {
        lib_posix.close(self.socket_fd);
        self.read_buf.deinit();
        self.write_buf.deinit(self.alloc);
    }
};

/// Daemon is responsible for managing a zmx session.
///
/// It holds all the state for a running session.  Instead of a single daemon for all sessions, we
/// create a daemon for every session.  This has some benefits. The ipc communication between
/// session clients and the daemon doesn't need to be tagged with the session name.  If a daemon
/// crashes for one session won't crash all the other sessions.
///
/// Conceptually it's also much simpler to reason about.
pub const Daemon = struct {
    cfg: *Cfg,
    session_name: []const u8,
    socket_path: []const u8,
    // === opt ===
    pty_write_buf: std.ArrayList(u8) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    labels: std.StringHashMapUnmanaged([]u8) = .empty,
    // This control which client is the leader.  The leader controls terminal state and
    // cols/rows of session.
    leader_client_fd: ?i32 = null,
    running: bool = true,
    pid: i32 = undefined,
    command: ?[]const []const u8 = null,
    /// The session's working directory in OSC 7 form, `file://<host><path>`.
    /// Kept as a URI rather than a path so `zmx list` shows the host, which is
    /// what tells you a session is inside SSH. Points into `cwd_buf` once set,
    /// so a Daemon must not be copied by value after that.
    cwd: []const u8 = "",
    /// The same directory as a path that can be opened: percent-decoding
    /// applied, scheme and host stripped. Empty when the cwd is on another
    /// host, since then it names no directory here and nothing should chdir
    /// into it. Points into `cwd_path_buf`.
    cwd_path: []const u8 = "",
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    cwd_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    has_pty_output: bool = false,
    has_had_client: bool = false,
    has_terminal_client: bool = false, // true only after a real attach (.Init received)
    created_at: u64, // unix timestamp (ns)
    is_task_mode: bool = false, // flag for when session is run as a task
    task_id: [4]u8 = undefined,
    task_exit_code: ?u8 = null, // null = running or n/a, set when task completes
    task_ended_at: ?u64 = null, // timestamp when task exited
    pty_fd: i32 = -1, // set by daemonLoop
    /// The daemon's own terminal, set by daemonLoop. Needed by grid changes
    /// that start from places without a `term` parameter (`closeClient`).
    term: ?*ghostty_vt.Terminal = null,
    /// CDXC:Zmx 2026-09-03: monotonic counter behind
    /// `Client.activity`; bumped on attach, user input, and visible claims.
    activity_clock: u64 = 0,
    shell: []const u8 = "/bin/sh",
    title_coalescer: title_events.Coalescer = .{},
    /// Set by `run()` when this process actually created the session. Lets a
    /// caller tell "created" from "already existed", which `ensureSession`'s
    /// is-daemon-proc return value cannot express on its own.
    created_session: bool = false,

    /// Create a Daemon. Caller is responsible for freeing all variables passed
    /// into the init fn.
    pub fn init(io: std.Io, cfg: *Cfg, sesh_name: []const u8, socket_path: []const u8) Daemon {
        return .{
            .cfg = cfg,
            .session_name = sesh_name,
            .socket_path = socket_path,
            .created_at = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        };
    }

    pub fn deinit(self: *Daemon, gpa: std.mem.Allocator) void {
        self.clients.deinit(gpa);
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.labels.deinit(gpa);
        self.pty_write_buf.deinit(gpa);
        self.title_coalescer.deinit(gpa);
        // socket_path is NOT freed here: init()'s contract says the caller
        // owns everything passed into it, and in the daemon process it is a
        // PRE-fork allocation that must never be freed post-fork (see the
        // CDXC:Zmx comment in run()). The client process
        // frees it via its own defer at the attach call site in main.zig.
    }

    pub fn shutdown(self: *Daemon, gpa: std.mem.Allocator) void {
        std.log.info("shutting down daemon session=<redacted>", .{});
        self.running = false;

        for (self.clients.items) |client| {
            client.deinit();
            gpa.destroy(client);
        }
        self.clients.clearRetainingCapacity();
    }

    pub fn closeClient(self: *Daemon, gpa: std.mem.Allocator, client: *Client, i: usize, shutdown_on_last: bool) bool {
        const fd = client.socket_fd;
        const was_leader = self.leader_client_fd == client.socket_fd;
        if (was_leader) {
            std.log.info(
                "unsetting leader session=<redacted> fd={d}",
                .{client.socket_fd},
            );
            self.leader_client_fd = null;
        }
        client.deinit();
        gpa.destroy(client);
        _ = self.clients.orderedRemove(i);
        std.log.info("client disconnected fd={d} remaining={d}", .{ fd, self.clients.items.len });
        if (shutdown_on_last and self.clients.items.len == 0) {
            self.shutdown(gpa);
            return true;
        }
        // The leader left: hand the grid to whoever is still looking, or
        // honor a remaining chat claim. Must run after the removal so the departed
        // client is not a candidate.
        if (was_leader) {
            self.electLeader(gpa) catch |err| {
                std.log.warn("leader election failed err={s}", .{@errorName(err)});
            };
        }
        return false;
    }

    /// ensureSession will either create or re-use the daemon used for a session.
    /// It will spin up a unix socket, double-fork the process (so it survives
    /// the terminal dying), and automatically attach the client to the ipc unix
    /// socket.
    ///
    /// The return bool value indicates if the current process is the daemon
    /// or the client since they have different behaviors post-fork.
    ///
    /// E.g. If it's the client process then we need to connect to the unix socket
    /// and run the clientLoop.  If it's the daemon then we need to bail since
    /// the daemonLoop is created inside this fn and when it returns that means
    /// the daemon stopped and needs to exit.
    pub fn ensureSession(self: *Daemon, io: std.Io) !bool {
        const sesh_name = self.session_name;
        std.log.info("ensure session session=<redacted>", .{});
        var dir = try std.Io.Dir.openDirAbsolute(io, self.cfg.socket_dir, .{});
        defer dir.close(io);

        const exists = try socket.sessionExists(io, dir, sesh_name);
        // if daemon is gone then we flip this to true
        var should_create = !exists;

        if (exists) {
            if (ipc.connectSession(self.socket_path)) |fd| {
                lib_posix.close(fd);
                if (self.command != null) {
                    std.log.warn(
                        "session already exists, ignoring command session=<redacted>",
                        .{},
                    );
                }
            } else |err| switch (err) {
                // Daemon is definitively gone: safe to replace.
                error.ConnectionRefused => {
                    socket.cleanupStaleSocket(io, dir, sesh_name);
                    should_create = true;
                },
                // Connect failed for an unusual reason. The check is only to
                // decide create-vs-attach; the socket file exists, so proceed
                // to attach rather than fail or orphan.
                else => {
                    std.log.warn(
                        "connect failed ({s}), proceeding to attach session=<redacted>",
                        .{@errorName(err)},
                    );
                },
            }
        }

        if (!should_create) {
            return false;
        }

        return self.run(io, dir, sesh_name);
    }

    fn run(self: *Daemon, io: std.Io, dir: std.Io.Dir, sesh_name: []const u8) !bool {
        std.log.info("creating session=<redacted>", .{});
        self.created_session = true;
        const server_sock_fd: lib_posix.socket_t = try socket.createSocket(self.socket_path);
        const log_fd = log.log_system.file.?.handle;

        var keep_fds_open = [_]i32{ server_sock_fd, dir.handle, log_fd };
        const cmd = try daemonize.createCmdZ(self.shell, self.is_task_mode, self.command);

        // `cwd_path` is the decoded path, and is empty when the cwd is on
        // another host: OSC 7 crosses SSH boundaries, so a session that ssh'd
        // elsewhere reports a directory that does not exist on this machine.
        std.log.info("checking pwd=<redacted> has_local_path={}", .{self.cwd_path.len > 0});
        if (self.cwd_path.len > 0) {
            const pwd_dir = std.Io.Dir.openDirAbsolute(io, self.cwd_path, .{}) catch |err| blk: {
                std.log.warn("failed to open session dir=<redacted> err={s}", .{@errorName(err)});
                break :blk null;
            };
            if (pwd_dir) |pdir| {
                defer std.Io.Dir.close(pdir, io);
                std.log.info("set directory dir=<redacted>", .{});
                try std.process.setCurrentDir(io, pdir);
            }
        }

        const pty_info = daemonize.daemonize(
            sesh_name,
            cmd,
            &keep_fds_open,
        ) catch |err| {
            switch (err) {
                error.IsClientProc => {
                    // send a msg to the client that the session was created.
                    var w_buf: [2048]u8 = undefined;
                    var w = std.Io.File.stdout().writer(io, &w_buf);
                    try w.interface.print("session \"{s}\" created\n", .{sesh_name});
                    try w.interface.flush();
                    lib_posix.close(server_sock_fd);
                    return false;
                },
                else => {
                    lib_posix.close(server_sock_fd);
                    dir.deleteFile(io, self.session_name) catch {};
                    return err;
                },
            }
        };
        // =======
        // WARNING: cannot use upstream allocator or io after this point since
        // we forked the process and there's a risk of a mutex (e.g. thread-safe
        // allocator) being locked by a thread prior to fork which can cause a
        // deadlock.
        // =======

        self.pid = pty_info.pid;

        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const new_io = threaded.io();

        { // re-initialize logs under a name that does not leak the session
            // CDXC:Telemetry 2026-05-31-00:18:
            // Users must be able to zip and send zmx log directories without
            // exposing session names. Use the daemon process id in the
            // per-session log filename so support can still correlate
            // child-daemon logs without leaking the user-provided label.
            log.log_system.deinit();
            var log_buf: [4096]u8 = undefined;
            const session_log_name = try std.fmt.bufPrint(
                &log_buf,
                "zmx-daemon-{d}.log",
                .{std.c.getpid()},
            );
            var fba_buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
            const session_log_path = try std.fs.path.join(
                fba.allocator(),
                &.{ self.cfg.log_dir, session_log_name },
            );
            const log_mode = std.Io.File.Permissions.fromMode(@intCast(self.cfg.log_mode));
            log.log_system.init(new_io, session_log_path, log_mode) catch {};
        }

        const gpa: std.mem.Allocator = blk: {
            if (builtin.mode == .Debug) {
                const GPA = std.heap.DebugAllocator(.{});
                const Static = struct {
                    var gpa: GPA = .{};
                };
                break :blk Static.gpa.allocator();
            }
            break :blk std.heap.c_allocator;
        };

        var daemon_exit_status: u8 = 0;
        daemonLoop(self, gpa, new_io, server_sock_fd, pty_info.master_fd) catch |err| {
            std.log.err("daemon loop failed err={s}", .{@errorName(err)});
            daemon_exit_status = 1;
        };
        if (daemon_exit_status == 0) std.log.info("daemon loop shutdown", .{});

        // Close and unlink the listen socket BEFORE handleKill()'s
        // 500ms SIGHUP->SIGKILL grace sleep. Otherwise a `zmx run`
        // for the same name issued in that window will hang waiting
        // for a connect.
        lib_posix.close(server_sock_fd);
        std.log.info("deleting socket file session=<redacted>", .{});
        dir.deleteFile(new_io, sesh_name) catch |err| {
            std.log.warn("failed to delete socket file err={s}", .{@errorName(err)});
        };
        self.handleKill(gpa, new_io);
        self.deinit(gpa);
        lib_posix.close(pty_info.master_fd);
        _ = lib_posix.waitpid(self.pid, 0);

        // CDXC:Zmx 2026-08-30:
        // The daemon process is the child of daemonize()'s fork and never
        // execs. Zig 0.16's std.process.Init starts a std.Io.Threaded pool
        // before main(), so the client is multi-threaded when it forks, and on
        // macOS 26+ libmalloc therefore keeps the child on its fork-safe
        // fallback allocator (mfm_*) for the child's entire life: the pre-fork
        // xzone heap may have been forked mid-mutation, so free() of any
        // PRE-fork allocation aborts with "BUG IN CLIENT OF LIBMALLOC: not an
        // allocated block". Returning from here would unwind into exactly such
        // frees (main()'s defers on sesh/log_path/cfg and std.start's
        // environ/arena teardown), which SIGTRAP'd the daemon on every single
        // `zmx kill` (156+ crash reports in two days). Post-fork allocations
        // (clients, labels, buffers — everything deinit() still frees above)
        // are fork-child-owned and safe. Pre-fork memory is reclaimed by
        // process exit, so the daemon must leave via exit() and never unwind
        // past this function. The `return true` "is daemon proc" contract this
        // replaces only told callers to unwind straight out anyway.
        lib_posix.exit(daemon_exit_status);
    }

    fn setLeader(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        std.log.info("setting new leader client_fd={d}", .{client.socket_fd});
        self.leader_client_fd = client.socket_fd;
        if (client.last_size) |resize| {
            // The client already told us its grid: apply it directly.
            _ = try self.applyGridIfChanged(gpa, resize);
            return;
        }
        // Send a resize message to the client so it can send us back their window size
        // so we can resize the pty and ghostty state.
        try ipc.appendMessage(gpa, &client.write_buf, .Resize, "");
        client.has_pending_output = true;
    }

    fn touchActivity(self: *Daemon, client: *Client) void {
        self.activity_clock += 1;
        client.activity = self.activity_clock;
    }

    fn currentGrid(term: *ghostty_vt.Terminal) ipc.Resize {
        return .{
            .rows = @intCast(term.screens.active.pages.rows),
            .cols = @intCast(term.screens.active.pages.cols),
        };
    }

    /// Resize the pty and the daemon terminal to `resize` unless that is
    /// already the grid. Returns whether anything changed.
    fn applyGridIfChanged(self: *Daemon, gpa: std.mem.Allocator, resize: ipc.Resize) !bool {
        const term = self.term orelse return false;
        const current = currentGrid(term);
        if (current.rows == resize.rows and current.cols == resize.cols) return false;
        try self.applyTerminalResize(gpa, self.pty_fd, term, resize);
        return true;
    }

    /// CDXC:Zmx 2026-09-05 DECISION:
    /// User: a client is chat exactly when it would report visible if the session were in terminal view, on screen right now.
    /// Visible terminals always own the PTY; the most recently active visible client wins.
    /// Without a visible client, only a chat claim may widen the grid to at least 200 columns, using the freshest parked rows.
    /// With neither claim, retain the grid unchanged so terminal tab switches do not reflow the agent TUI.
    /// Dropping a chat claim never narrows an unattended grid. Headless sessions still start at 50x200.
    /// SEE-ALSO: apps/desktop/src/terminal_model.rs, server/src/terminal_ws.rs, apps/web/src/terminal/session-terminal.tsx, apps/mobile/app/src/terminal/zmxDisplay.ts.
    fn electLeader(self: *Daemon, gpa: std.mem.Allocator) !void {
        const term = self.term orelse return;
        var visible: ?*Client = null;
        var hidden: ?*Client = null;
        var chat_claim = false;
        for (self.clients.items) |client| {
            if (!client.is_terminal) continue;
            chat_claim = chat_claim or client.visibility == .chat;
            if (client.visibility != .visible) {
                if (hidden == null or client.activity > hidden.?.activity) hidden = client;
            } else {
                if (visible == null or client.activity > visible.?.activity) visible = client;
            }
        }

        var changed = false;
        if (visible) |client| {
            std.log.info("elected leader client_fd={d}", .{client.socket_fd});
            self.leader_client_fd = client.socket_fd;
            if (client.last_size) |resize| {
                changed = try self.applyGridIfChanged(gpa, resize);
            } else {
                try ipc.appendMessage(gpa, &client.write_buf, .Resize, "");
                client.has_pending_output = true;
            }
        } else {
            self.leader_client_fd = null;
            if (!chat_claim) return;
            const rows: u16 = blk: {
                if (hidden) |client| {
                    if (client.last_size) |resize| break :blk resize.rows;
                }
                break :blk currentGrid(term).rows;
            };
            std.log.info(
                "no displayed client, resting grid rows={d} cols={d} hidden_clients={}",
                .{ rows, ipc.RESTING_GRID_COLS, hidden != null },
            );
            changed = try self.applyGridIfChanged(gpa, .{ .rows = rows, .cols = @max(currentGrid(term).cols, ipc.RESTING_GRID_COLS) });
        }

        if (changed) {
            for (self.clients.items) |client| {
                if (!client.is_terminal) continue;
                self.appendVisibleRefresh(gpa, client, term);
            }
        }
    }

    /// `.Visibility`: the attach client relayed a `ZMX_VISIBLE` / `ZMX_CHAT` / `ZMX_HIDDEN`
    /// OSC. Only terminal clients (those that sent `.Init`) may claim.
    pub fn handleVisibility(self: *Daemon, gpa: std.mem.Allocator, client: *Client, payload: []const u8) !void {
        const visibility = ipc.Visibility.decode(payload) orelse return;
        if (!client.is_terminal) return;
        client.uses_visibility_claims = true;
        client.last_size = visibility.resize;
        if (visibility.state == .visible) {
            client.visibility = .visible;
            self.touchActivity(client);
            std.log.info(
                "client visible, taking leadership client_fd={d} rows={d} cols={d}",
                .{ client.socket_fd, visibility.resize.rows, visibility.resize.cols },
            );
            self.leader_client_fd = client.socket_fd;
            // A claim that changes the grid repaints every client
            // from the daemon's screen, exactly like `refresh-if-stale` when
            // stale: the client's own reflow of the resting-width content and
            // the daemon's reflow diverge otherwise, and a shell prompt never
            // repaints on SIGWINCH by itself.
            if (try self.applyGridIfChanged(gpa, visibility.resize)) {
                const term = self.term orelse return;
                for (self.clients.items) |existing| {
                    if (!existing.is_terminal) continue;
                    self.appendVisibleRefresh(gpa, existing, term);
                }
            }
            return;
        }
        const changed = client.visibility != visibility.state;
        client.visibility = visibility.state;
        std.log.info("client {s} client_fd={d}", .{ @tagName(client.visibility), client.socket_fd });
        if (changed) {
            try self.electLeader(gpa);
        }
    }

    /// `.GridInfo`: answer with one JSON object describing the grid, the
    /// leader, and every terminal client. Diagnostics for `zmx grid`.
    pub fn handleGridInfo(self: *Daemon, gpa: std.mem.Allocator, client: *Client, term: *ghostty_vt.Terminal) !void {
        var builder: std.Io.Writer.Allocating = .init(gpa);
        defer builder.deinit();
        const w = &builder.writer;
        const grid = currentGrid(term);
        var chat_claim = false;
        for (self.clients.items) |existing| {
            chat_claim = chat_claim or (existing.is_terminal and existing.visibility == .chat);
        }
        try w.print(
            "{{\"rows\":{d},\"cols\":{d},\"leader_fd\":{d},\"resting_rows\":{d},\"resting_cols\":{d},\"chat_claim\":{},\"clients\":[",
            .{ grid.rows, grid.cols, self.leader_client_fd orelse -1, ipc.RESTING_GRID_ROWS, ipc.RESTING_GRID_COLS, chat_claim },
        );
        var first = true;
        for (self.clients.items) |existing| {
            if (!existing.is_terminal) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.print(
                "{{\"fd\":{d},\"state\":\"{s}\",\"activity\":{d},\"last_size\":",
                .{ existing.socket_fd, @tagName(existing.visibility), existing.activity },
            );
            if (existing.last_size) |resize| {
                try w.print("{{\"rows\":{d},\"cols\":{d}}}", .{ resize.rows, resize.cols });
            } else {
                try w.writeAll("null");
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        try ipc.appendMessage(gpa, &client.write_buf, .GridInfo, builder.written());
        client.has_pending_output = true;
    }

    const PTY_WRITE_BUF_MAX = 256 * 1024;

    /// Queue bytes for the PTY's stdin. Flushed by daemonLoop on POLLOUT.
    /// Drops the payload if the buffer is over cap -- same failure mode as
    /// the old direct-write ptyWrite (drop on EAGAIN), just at a 64x higher
    /// threshold. Capping avoids OOM when the shell stops reading; dropping
    /// new (not old) bytes avoids tearing a partially-accepted sequence.
    fn queuePtyInput(self: *Daemon, gpa: std.mem.Allocator, data: []const u8) void {
        _ = self.queuePtyInputChecked(gpa, data);
    }

    /// Same as `queuePtyInput`, but reports the outcome so `.SendAcked`
    /// senders learn about a drop instead of it living only in this log.
    fn queuePtyInputChecked(
        self: *Daemon,
        gpa: std.mem.Allocator,
        data: []const u8,
    ) ipc.SendAckStatus {
        if (data.len == 0) return .queued;
        if (self.pty_write_buf.items.len + data.len > PTY_WRITE_BUF_MAX) {
            std.log.warn(
                "pty input dropped {d} bytes (buffer full, shell not reading)",
                .{data.len},
            );
            return .dropped_pty_buffer_full;
        }

        // NOTE: for local dev only
        // std.log.debug("buffering pty input data={x}", .{data});

        self.pty_write_buf.appendSlice(gpa, data) catch |err| {
            std.log.warn(
                "pty input dropped {d} bytes: {s}",
                .{ data.len, @errorName(err) },
            );
            return .dropped_out_of_memory;
        };
        return .queued;
    }

    pub fn handleInput(self: *Daemon, gpa: std.mem.Allocator, client: *Client, payload: []const u8) !void {
        // NOTE: for local dev only
        // std.log.debug("buffering pty input data={x}", .{payload});

        const is_user_input = util.isUserInput(payload);
        if (is_user_input) {
            // A keystroke proves someone is at this terminal.
            client.visibility = .visible;
            self.touchActivity(client);
        }

        // client is leader, send entire payload (ansi escape codes + text)
        if (self.leader_client_fd == client.socket_fd) {
            self.queuePtyInput(gpa, payload);
            return;
        }

        // check if leader needs to be updated by detecting any user input
        if (is_user_input) {
            try self.setLeader(gpa, client);
            self.queuePtyInput(gpa, payload);
        }
    }

    /// Queue input from `zmx send` without changing interactive client leadership.
    pub fn handleSend(self: *Daemon, gpa: std.mem.Allocator, payload: []const u8) void {
        self.queuePtyInput(gpa, payload);
    }

    /// `.SendAcked` is `.Send` plus a receipt.
    ///
    /// Ghostex's gxserver treats a zero exit from `zmx send` as proof the
    /// agent received the text, so whether the payload made it into the pty
    /// queue has to travel back to the sender. The receipt covers the
    /// enqueue only; the final pty flush happens later in the poll loop.
    ///
    /// An empty payload is the client's capability ping: it queues nothing
    /// and still acks, which is how a new client learns this daemon
    /// understands the tag before it commits a real payload to it.
    pub fn handleSendAcked(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        payload: []const u8,
    ) !void {
        const status = self.queuePtyInputChecked(gpa, payload);
        try ipc.appendMessage(
            gpa,
            &client.write_buf,
            .SendAck,
            &[_]u8{@intFromEnum(status)},
        );
        client.has_pending_output = true;
    }

    pub fn handleSwitch(self: *Daemon, gpa: std.mem.Allocator, session_name: []const u8) !void {
        for (self.clients.items) |client| {
            if (self.leader_client_fd == client.socket_fd) {
                // Include the daemon's current cwd so the new session can start
                // in the right directory. A remote cwd is left out: it names no
                // directory here, so the new session is better off with the
                // attaching client's own cwd than with a path it cannot enter.
                if (self.cwd.len > 0 and self.cwd_path.len > 0) {
                    var payload = gpa.alloc(u8, session_name.len + 1 + self.cwd.len) catch return;
                    defer gpa.free(payload);
                    @memcpy(payload[0..session_name.len], session_name);
                    payload[session_name.len] = '\n';
                    @memcpy(payload[session_name.len + 1 ..], self.cwd);
                    ipc.appendMessage(gpa, &client.write_buf, .Switch, payload) catch |err| {
                        std.log.warn(
                            "failed to buffer terminal state for client err={s}",
                            .{@errorName(err)},
                        );
                    };
                } else {
                    ipc.appendMessage(gpa, &client.write_buf, .Switch, session_name) catch |err| {
                        std.log.warn(
                            "failed to buffer terminal state for client err={s}",
                            .{@errorName(err)},
                        );
                    };
                }
                client.has_pending_output = true;
                return;
            }
        }
        return error.NoLeaderFound;
    }

    /// Resize the PTY and the daemon's own terminal to `resize`.
    ///
    /// Extracted from handleInit/handleResize because handleRefreshIfStale
    /// needs the same sequence from a third call site.
    fn applyTerminalResize(
        self: *Daemon,
        gpa: std.mem.Allocator,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        resize: ipc.Resize,
    ) !void {
        _ = self;
        var ws: cross.c.struct_winsize = .{
            .ws_row = resize.rows,
            .ws_col = resize.cols,
            .ws_xpixel = resize.xpixel,
            .ws_ypixel = resize.ypixel,
        };
        _ = cross.c.ioctl(pty_fd, cross.c.TIOCSWINSZ, &ws);
        // Disable prompt_redraw before resize. The daemon's internal terminal
        // would otherwise clear prompt lines expecting the shell to redraw them,
        // but the shell's redraw goes to the PTY (forwarded to clients), not to
        // this daemon terminal. The clearing corrupts the daemon's snapshot state.
        const saved_prompt_redraw = term.flags.shell_redraws_prompt;
        term.flags.shell_redraws_prompt = .false;
        defer term.flags.shell_redraws_prompt = saved_prompt_redraw;
        try term.resize(gpa, .{ .cols = resize.cols, .rows = resize.rows });
    }

    pub fn handleInit(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len < @sizeOf(ipc.Resize)) return;
        client.is_terminal = true;
        // CDXC:PromptEditor 2026-06-06-16:40: zmx attach clients advertise
        // prompt-editor support explicitly; an omitted capability byte means
        // the machine editor, so inherited shell environment cannot make SSH,
        // mobile, or TUI clients open a host-only popup.
        client.prompt_editor_capabilities = if (payload.len > @sizeOf(ipc.Resize))
            payload[@sizeOf(ipc.Resize)]
        else
            0;

        // Serialize terminal state BEFORE resize to capture correct cursor position.
        // Resizing triggers reflow which can move the cursor, and the shell's
        // SIGWINCH-triggered redraw will run after our snapshot is sent.
        // Only serialize on re-attach (has_had_client), not first attach, to avoid
        // interfering with shell initialization (DA1 queries, etc.)
        if (self.has_pty_output and self.has_had_client) {
            const cursor = &term.screens.active.cursor;
            std.log.debug(
                "cursor before serialize: x={d} y={d} pending_wrap={}",
                .{ cursor.x, cursor.y, cursor.pending_wrap },
            );
            if (util.serializeTerminalState(gpa, term)) |term_output| {
                std.log.debug("serialize terminal state", .{});
                // Rewrite OSC 133;A to include redraw=0 so the outer terminal
                // does not clear prompt lines on resize (issue #111).
                const restore_data = util.rewritePromptRedraw(gpa, term_output) orelse term_output;
                defer gpa.free(term_output);
                defer if (restore_data.ptr != term_output.ptr) gpa.free(restore_data);
                ipc.appendMessage(gpa, &client.write_buf, .Output, restore_data) catch |err| {
                    std.log.warn(
                        "failed to buffer terminal state for client err={s}",
                        .{@errorName(err)},
                    );
                };
                client.has_pending_output = true;
            }
        }

        // A client that just attached is being looked at, so it always takes
        // leadership and its grid is applied at once (CDXC:Zmx).
        const resize = std.mem.bytesToValue(ipc.Resize, payload[0..@sizeOf(ipc.Resize)]);
        client.visibility = .visible;
        client.last_size = resize;
        self.touchActivity(client);
        std.log.info("init: new leader client_fd={d}", .{client.socket_fd});
        self.leader_client_fd = client.socket_fd;
        try self.applyTerminalResize(gpa, pty_fd, term, resize);

        // Mark that we've had a client init, so subsequent clients get terminal state
        self.has_had_client = true;
        self.has_terminal_client = true;

        std.log.debug("init resize rows={d} cols={d}", .{ resize.rows, resize.cols });
    }

    pub fn handleResize(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) return;
        if (client.uses_visibility_claims) return;
        const resize = std.mem.bytesToValue(ipc.Resize, payload);
        client.last_size = resize;
        if (self.leader_client_fd == null) {
            std.log.info("resize with no leader: sender becomes leader client_fd={d}", .{client.socket_fd});
            self.leader_client_fd = client.socket_fd;
        }
        // only leader can resize
        if (self.leader_client_fd != client.socket_fd) return;

        try self.applyTerminalResize(gpa, pty_fd, term, resize);
        std.log.debug("resize rows={d} cols={d}", .{ resize.rows, resize.cols });
    }

    // ==================================================================
    // Ghostex fork: display refresh, title observation, prompt editor
    // ==================================================================

    fn appendVisibleRefresh(self: *Daemon, gpa: std.mem.Allocator, client: *Client, term: *ghostty_vt.Terminal) void {
        if (!self.has_pty_output) return;
        if (util.serializeVisibleTerminalState(gpa, term)) |term_output| {
            std.log.debug("serialize visible terminal state", .{});
            const restore_data = util.rewritePromptRedraw(gpa, term_output) orelse term_output;
            defer gpa.free(term_output);
            defer if (restore_data.ptr != term_output.ptr) gpa.free(restore_data);
            ipc.appendMessage(gpa, &client.write_buf, .Output, restore_data) catch |err| {
                std.log.warn(
                    "failed to buffer visible terminal refresh for client err={s}",
                    .{@errorName(err)},
                );
                return;
            };
            client.has_pending_output = true;
        }
    }

    /// CDXC:Zmx 2026-05-20-09:57: Ghostex refreshes stale zmx-backed
    /// panes by asking the zmx daemon to repaint attached terminal clients from
    /// tracked VT state. This is intentionally an IPC/display operation, never
    /// PTY input, so refresh cannot type escape bytes into the user's shell.
    pub fn handleRefresh(self: *Daemon, gpa: std.mem.Allocator, requesting_client: *Client, term: *ghostty_vt.Terminal) !void {
        var refreshed_count: usize = 0;
        for (self.clients.items) |client| {
            if (!client.is_terminal) continue;
            self.appendVisibleRefresh(gpa, client, term);
            refreshed_count += 1;
        }
        if (refreshed_count == 0) {
            self.appendVisibleRefresh(gpa, requesting_client, term);
        }
        try ipc.appendMessage(gpa, &requesting_client.write_buf, .Ack, "");
        requesting_client.has_pending_output = true;
    }

    /// CDXC:Zmx 2026-06-05-21:27: Mac pane clicks should repair
    /// sessions resized by another client, such as an iPhone attach, without
    /// repainting on every normal terminal click. Compare the caller's current
    /// grid to the daemon VT grid; ACK without Output when they already match
    /// so clicks do not scroll the terminal to the bottom.
    pub fn handleRefreshIfStale(
        self: *Daemon,
        gpa: std.mem.Allocator,
        requesting_client: *Client,
        pty_fd: i32,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        if (payload.len != @sizeOf(ipc.Resize)) {
            try ipc.appendMessage(gpa, &requesting_client.write_buf, .Ack, "0");
            requesting_client.has_pending_output = true;
            return;
        }

        const resize = std.mem.bytesToValue(ipc.Resize, payload[0..@sizeOf(ipc.Resize)]);
        const current_rows: u16 = @intCast(term.screens.active.pages.rows);
        const current_cols: u16 = @intCast(term.screens.active.pages.cols);
        const is_stale = resize.rows != current_rows or resize.cols != current_cols;
        if (is_stale) {
            try self.applyTerminalResize(gpa, pty_fd, term, resize);
            for (self.clients.items) |client| {
                if (!client.is_terminal) continue;
                self.appendVisibleRefresh(gpa, client, term);
            }
        }
        try ipc.appendMessage(gpa, &requesting_client.write_buf, .Ack, if (is_stale) "1" else "0");
        requesting_client.has_pending_output = true;
    }

    /// CDXC:PromptEditor 2026-06-06-16:40:
    /// Ctrl+G prompt-editor routing must use the current zmx attach client, not
    /// stale shell environment inherited when the long-lived session was
    /// created. Only a leader client that explicitly advertised support may open
    /// a host editor; every missing or non-advertised client returns "editor" so
    /// TUI, mobile, and plain SSH attaches stay on the machine editor.
    /// CDXC:PromptEditor 2026-06-30-03:11: Non-Monaco zmx clients
    /// advertise "editor" instead of the old gte sentinel because Ctrl+G
    /// fallback now runs the machine's EDITOR/VISUAL command.
    pub fn handlePromptEditorCapability(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        var capability: []const u8 = "editor";
        if (self.leader_client_fd) |leader_fd| {
            for (self.clients.items) |existing_client| {
                if (existing_client.socket_fd == leader_fd) {
                    if (existing_client.prompt_editor_capabilities & prompt_editor_capability_code_server != 0) {
                        capability = "code-server";
                    } else if (existing_client.prompt_editor_capabilities & prompt_editor_capability_monaco != 0) {
                        capability = "monaco";
                    }
                    break;
                }
            }
        }
        try ipc.appendMessage(gpa, &client.write_buf, .PromptEditorCapability, capability);
        client.has_pending_output = true;
    }

    /// CDXC:SessionStatus 2026-06-01-10:17:
    /// Title watchers should not receive the raw title captured at subscription
    /// time unless zmx has already emitted it as stable. New or restored
    /// surfaces can briefly expose shell/bootstrap titles before the agent
    /// redraws, so the first observed title must pass through the same 1s
    /// debounce and 6s max-settle window as later changes.
    pub fn handleTitleSubscribe(
        self: *Daemon,
        gpa: std.mem.Allocator,
        io: std.Io,
        client: *Client,
        term: *ghostty_vt.Terminal,
    ) !void {
        client.is_title_watcher = true;
        if (self.title_coalescer.lastEmittedTitle()) |title| {
            try self.sendTitleToClient(gpa, client, title);
        }
        if (term.getTitle()) |title| {
            try self.title_coalescer.observe(gpa, title, nowMs(io));
        }
    }

    pub fn observeTerminalTitle(self: *Daemon, gpa: std.mem.Allocator, io: std.Io, title: []const u8) !void {
        try self.title_coalescer.observe(gpa, title, nowMs(io));
    }

    pub fn titlePollTimeoutMs(self: *const Daemon, io: std.Io) i32 {
        return self.title_coalescer.pollTimeoutMs(nowMs(io));
    }

    pub fn flushTitleIfDue(self: *Daemon, gpa: std.mem.Allocator, io: std.Io) !void {
        const title = try self.title_coalescer.takeDue(gpa, nowMs(io));
        if (title) |value| {
            defer gpa.free(value);
            try self.broadcastTitle(gpa, value);
        }
    }

    fn broadcastTitle(self: *Daemon, gpa: std.mem.Allocator, title: []const u8) !void {
        for (self.clients.items) |client| {
            if (!client.is_title_watcher) continue;
            try self.sendTitleToClient(gpa, client, title);
        }
    }

    fn sendTitleToClient(self: *Daemon, gpa: std.mem.Allocator, client: *Client, title: []const u8) !void {
        _ = self;
        try ipc.appendMessage(gpa, &client.write_buf, .TitleObserved, title);
        client.has_pending_output = true;
    }

    pub fn handleDetach(self: *Daemon, gpa: std.mem.Allocator, client: *Client, i: usize) void {
        std.log.info("client detach session=<redacted> fd={d}", .{client.socket_fd});
        _ = self.closeClient(gpa, client, i, false);
    }

    pub fn handleDetachAll(self: *Daemon, gpa: std.mem.Allocator) void {
        std.log.info("detach all clients={d}", .{self.clients.items.len});
        for (self.clients.items) |client_to_close| {
            client_to_close.deinit();
            gpa.destroy(client_to_close);
        }
        self.clients.clearRetainingCapacity();
        // Nobody is looking any more: rest the grid wide.
        self.leader_client_fd = null;
        self.electLeader(gpa) catch |err| {
            std.log.warn("leader election failed err={s}", .{@errorName(err)});
        };
    }

    pub fn handleKill(self: *Daemon, gpa: std.mem.Allocator, io: std.Io) void {
        std.log.info("kill received session=<redacted>", .{});
        self.shutdown(gpa);
        // gracefully shutdown shell processes, shells tend to ignore SIGTERM so we send SIGHUP
        // instead
        //   https://www.gnu.org/software/bash/manual/html_node/Signals.html
        // negative pid means kill process and children
        std.log.info("sending SIGHUP session=<redacted> pid={d}", .{self.pid});
        lib_posix.kill(-self.pid, lib_posix.SIG.HUP) catch |err| {
            std.log.warn("failed to send SIGHUP to pty child err={s}", .{@errorName(err)});
        };
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .real) catch unreachable;
        lib_posix.kill(-self.pid, lib_posix.SIG.KILL) catch |err| {
            std.log.warn("failed to send SIGKILL to pty child err={s}", .{@errorName(err)});
        };
    }

    pub fn handleInfo(self: *Daemon, gpa: std.mem.Allocator, client: *Client, term: *ghostty_vt.Terminal) !void {
        self.setPwd(term);

        // zeroes() so asBytes() doesn't ship struct padding + unused cmd/cwd
        // tail bytes (daemon stack contents) to clients.
        var info = std.mem.zeroes(ipc.Info);
        // CDXC:SessionStatus 2026-06-01-10:17:
        // gxserver keeps a long-lived title watcher attached to each observed
        // zmx session. That watcher is process plumbing, not a user-visible
        // client, so `zmx list` client counts must ignore it while still
        // excluding this transient Info request.
        var visible_client_count: usize = 0;
        for (self.clients.items) |existing_client| {
            if (!existing_client.is_title_watcher) visible_client_count += 1;
        }
        info.clients_len = if (visible_client_count > 0) visible_client_count - 1 else 0;
        info.pid = self.pid;
        info.created_at = self.created_at;
        info.task_ended_at = self.task_ended_at orelse 0;
        info.task_exit_code = self.task_exit_code orelse 0;

        // Build command string from args, re-quoting args that contain
        // shell-special characters so the displayed command is copy-pasteable.
        const cur_cmd = self.command;
        if (cur_cmd) |args| {
            for (args, 0..) |arg, i| {
                const quoted = if (util.shellNeedsQuoting(arg))
                    util.shellQuote(gpa, arg) catch null
                else
                    null;
                defer if (quoted) |q| gpa.free(q);
                const src = quoted orelse arg;

                const need = src.len + @as(usize, if (i > 0) 1 else 0);
                if (info.cmd_len + need > ipc.MAX_CMD_LEN) {
                    const ellipsis = "...";
                    if (info.cmd_len + ellipsis.len <= ipc.MAX_CMD_LEN) {
                        @memcpy(info.cmd[info.cmd_len..][0..ellipsis.len], ellipsis);
                        info.cmd_len += ellipsis.len;
                    }
                    break;
                }

                if (i > 0) {
                    info.cmd[info.cmd_len] = ' ';
                    info.cmd_len += 1;
                }
                @memcpy(info.cmd[info.cmd_len..][0..src.len], src);
                info.cmd_len += @intCast(src.len);
            }
        }

        info.cwd_len = @intCast(@min(self.cwd.len, ipc.MAX_CWD_LEN));
        @memcpy(info.cwd[0..info.cwd_len], self.cwd[0..info.cwd_len]);

        try ipc.appendMessage(gpa, &client.write_buf, .Info, std.mem.asBytes(&info));
        client.has_pending_output = true;
    }

    pub fn handleHistory(
        self: *Daemon,
        gpa: std.mem.Allocator,
        client: *Client,
        term: *ghostty_vt.Terminal,
        payload: []const u8,
    ) !void {
        self.setPwd(term);
        const format: util.HistoryFormat = if (payload.len > 0)
            @enumFromInt(payload[0])
        else
            .plain;
        if (util.serializeTerminal(gpa, term, format)) |output| {
            defer gpa.free(output);
            try ipc.appendMessage(gpa, &client.write_buf, .History, output);
            client.has_pending_output = true;
        } else {
            try ipc.appendMessage(gpa, &client.write_buf, .History, "");
            client.has_pending_output = true;
        }
    }

    pub fn handleRun(self: *Daemon, gpa: std.mem.Allocator, io: std.Io, client: *Client, payload: []const u8) !void {
        // Reset task tracking so the new command's exit marker is detected.
        // Without this, a second `zmx run` on the same session is ignored
        // because task_exit_code is still set from the first run.
        self.task_exit_code = null;
        self.task_ended_at = null;
        self.is_task_mode = true;
        self.task_id = util.generateTaskId(io);

        if (payload.len == 0) return;

        const cmd = payload;

        // Chain the exit marker with `;` on the same line. `$?` captures the
        // exit code of the command (not the `;`). The sole exception is when
        // the command contains a heredoc (`<<`), the delimiter must be alone
        // on its line, so the marker goes on the next line instead.
        var buf: [1024]u8 = undefined;
        const marker = try util.getTaskExitMarker(&buf, self.task_id);
        var single_buf: [1024]u8 = undefined;
        const single_line_marker = try std.fmt.bufPrint(&single_buf, "; echo {s}$?\r", .{marker});
        var here_buf: [1024]u8 = undefined;
        const heredoc_marker = try std.fmt.bufPrint(&here_buf, "\r\necho {s}$?\r", .{marker});
        const uses_heredoc = std.mem.indexOf(u8, cmd, "<<") != null;

        if (cmd.len > 0 and cmd[cmd.len - 1] == '\r') {
            self.queuePtyInput(gpa, cmd[0 .. cmd.len - 1]);
        } else {
            self.queuePtyInput(gpa, cmd);
        }
        self.queuePtyInput(gpa, if (uses_heredoc) heredoc_marker else single_line_marker);

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        self.has_had_client = true;
        std.log.debug("run command len={d}", .{payload.len});
    }

    /// Store the session's working directory as a plain path.
    ///
    /// Accepts either an OSC 7 value (`file://<host><path>`, percent-encoded)
    /// or a path. Decoding here rather than at each use keeps `zmx list`
    /// printing a path and lets the chdir on session create find directories
    /// whose names needed escaping.
    ///
    /// The value is copied, so callers may pass a temporary.
    pub fn setCwd(self: *Daemon, value: []const u8) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&host_buf) catch "";
        const cwd = util.parseOsc7Cwd(&buf, value, hostname) orelse {
            std.log.warn("ignoring unusable cwd=<redacted>", .{});
            return;
        };

        // Store the URI form. A caller that handed us a plain path gets one
        // built here, so `cwd` has the same shape no matter the source. A value
        // that already was a URI is kept verbatim, so `list` shows what the
        // shell actually reported.
        self.cwd = if (std.fs.path.isAbsolute(value))
            util.toOsc7Cwd(&self.cwd_buf, value, hostname) orelse return
        else blk: {
            if (value.len > self.cwd_buf.len) return;
            @memcpy(self.cwd_buf[0..value.len], value);
            break :blk self.cwd_buf[0..value.len];
        };

        // Only keep an openable path when it names a directory on this host.
        if (cwd.is_local and cwd.path.len <= self.cwd_path_buf.len) {
            @memcpy(self.cwd_path_buf[0..cwd.path.len], cwd.path);
            self.cwd_path = self.cwd_path_buf[0..cwd.path.len];
        } else {
            self.cwd_path = "";
        }
        std.log.info("set cwd=<redacted> has_local_path={}", .{self.cwd_path.len > 0});
    }

    fn setPwd(self: *Daemon, term: *ghostty_vt.Terminal) void {
        const pwd = term.getPwd() orelse return;
        self.setCwd(pwd);
    }

    pub fn handleOutput(self: *Daemon, gpa: std.mem.Allocator, payload: []const u8, term: *ghostty_vt.Terminal, vt_stream: anytype) !void {
        vt_stream.nextSlice(payload);
        self.setPwd(term);
        self.has_pty_output = true;
        for (self.clients.items) |client| {
            if (client.is_title_watcher) continue;
            try ipc.appendMessage(gpa, &client.write_buf, .Output, payload);
            client.has_pending_output = true;
        }
        if (self.clients.items.len > 0) {
            lib_posix.kill(self.pid, lib_posix.SIG.WINCH) catch |err| {
                std.log.warn("failed to send SIGWINCH err={s}", .{@errorName(err)});
            };
        }
    }

    pub fn handleWrite(self: *Daemon, gpa: std.mem.Allocator, client: *Client, payload: []const u8) !void {
        // Wire format: [u32 path len][path bytes][file content]
        if (payload.len < @sizeOf(u32)) return error.InvalidPayload;
        const path_len = std.mem.bytesToValue(u32, payload[0..@sizeOf(u32)]);
        if (payload.len < @sizeOf(u32) + path_len) return error.InvalidPayload;
        const file_path = payload[@sizeOf(u32)..][0..path_len];
        const file_content = payload[@sizeOf(u32) + path_len ..];

        // Inject file creation through the PTY so it works over SSH.
        // Base64-encode content and pipe through printf | base64 -d > file.
        // Chunk large files to stay under command-line length limits.
        // 48000 is divisible by 3 (clean base64 boundaries) and encodes
        // to ~64KB, well under typical ARG_MAX.
        const chunk_size = 48000;
        var offset: usize = 0;
        var is_first = true;

        while (offset < file_content.len or is_first) {
            const end = @min(offset + chunk_size, file_content.len);
            const chunk = file_content[offset..end];

            const encoded_len = std.base64.standard.Encoder.calcSize(chunk.len);
            const encoded = try gpa.alloc(u8, encoded_len);
            defer gpa.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, chunk);

            self.queuePtyInput(gpa, "printf '%s' '");
            self.queuePtyInput(gpa, encoded);
            if (is_first) {
                self.queuePtyInput(gpa, "' | base64 -d > '");
            } else {
                self.queuePtyInput(gpa, "' | base64 -d >> '");
            }
            self.queuePtyInput(gpa, file_path);
            self.queuePtyInput(gpa, "'");
            self.queuePtyInput(gpa, "\r");

            offset = end;
            is_first = false;
        }

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
        self.has_had_client = true;
        std.log.debug(
            "write command len={d} file_path=<redacted>",
            .{file_content.len},
        );
    }

    fn handleLabelGet(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        const out = try label.labelsToU8(gpa, self.labels);
        defer gpa.free(out);
        try ipc.appendMessage(gpa, &client.write_buf, .LabelData, out);
        client.has_pending_output = true;
    }

    fn handleLabelSet(self: *Daemon, gpa: std.mem.Allocator, client: *Client, labels: []const u8) !void {
        std.log.info("handle label set payload_len={d}", .{labels.len});

        var kvs = label.LabelIterator.init(labels);
        while (kvs.next()) |kv| {
            if (kv.value.len == 0) {
                if (self.labels.fetchRemove(kv.key)) |existing| {
                    gpa.free(existing.key);
                    gpa.free(existing.value);
                }
                continue;
            }

            const owned_key = try gpa.dupe(u8, kv.key);
            errdefer gpa.free(owned_key);
            const owned_value = try gpa.dupe(u8, kv.value);
            errdefer gpa.free(owned_value);
            if (try self.labels.fetchPut(gpa, owned_key, owned_value)) |existing| {
                // fetchPut does NOT replace the key in the map, the old
                // key pointer stays. So free the new (unused) key and the
                // old value.
                gpa.free(owned_key);
                gpa.free(existing.value);
            }
        }

        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }

    fn handleLabelClear(self: *Daemon, gpa: std.mem.Allocator, client: *Client) !void {
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.labels.clearRetainingCapacity();
        try ipc.appendMessage(gpa, &client.write_buf, .Ack, "");
        client.has_pending_output = true;
    }
};

test "send queues PTY input without changing leader" {
    const alloc = std.testing.allocator;
    var daemon = Daemon{
        .cfg = undefined,
        .clients = .empty,
        .leader_client_fd = 42,
        .session_name = "test",
        .socket_path = "",
        .running = true,
        .pid = 0,
        .created_at = 0,
    };
    defer daemon.pty_write_buf.deinit(alloc);

    daemon.handleSend(alloc, "hello");

    try std.testing.expectEqual(@as(?i32, 42), daemon.leader_client_fd);
    try std.testing.expectEqualStrings("hello", daemon.pty_write_buf.items);
}
