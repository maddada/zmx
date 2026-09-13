const std = @import("std");
const ipc = @import("ipc.zig");
const posix = @import("posix.zig");

// A reserved C1 OSC keeps an ordinary standalone Escape immediately usable.
// Only recognize it outside a UTF-8 continuation (for example U+015D).
const prefix = "\x9d1337;ZMX_DETACH=";
pub const capability = "\x1b]1337;ZMX_DETACH_CAP=1\x07";
const unavailable = "\x1b]1337;ZMX_DETACH_CAP=0\x07";
const ack_prefix = "\x1b]1337;ZMX_DETACH_ACK=";
const nonce_limit = 64;

/// CDXC:Zmx 2026-09-13 WHY:
/// A native viewer may retire only after its preceding input belongs to the daemon, rather than a local PTY or SSH buffer.
/// Use the existing Info reply as an ordered Input barrier, then Detach; a private stdout nonce confirms clean closure after both phases.
/// This is an advertised client capability, with no daemon IPC or wire-generation change.
/// SEE-ALSO: apps/desktop/src/terminal_model/child_lifecycle.rs and native terminal input leases.
pub const State = struct {
    phase: enum { idle, barrier, cancelled, closing } = .idle,
    nonce: [nonce_limit]u8 = undefined,
    nonce_len: usize = 0,
    carry: [prefix.len + nonce_limit + 1]u8 = undefined,
    carry_len: usize = 0,
    utf8_remaining: u3 = 0,
    acknowledged: bool = false,

    pub fn append(
        self: *State,
        gpa: std.mem.Allocator,
        output: *std.ArrayList(u8),
        input: []const u8,
        comptime ordinary: anytype,
    ) !void {
        // clientLoop reads at most 4096 bytes. Retain only a bounded prefix of
        // the new control, leaving every established private OSC unchanged.
        var buffer: [4096 + prefix.len + nonce_limit + 1]u8 = undefined;
        std.debug.assert(input.len <= 4096);
        @memcpy(buffer[0..self.carry_len], self.carry[0..self.carry_len]);
        @memcpy(buffer[self.carry_len..][0..input.len], input);
        var remaining = buffer[0 .. self.carry_len + input.len];
        self.carry_len = 0;
        while (self.controlStart(remaining)) |start| {
            if (start > 0) {
                self.cancel();
                try ordinary(gpa, output, remaining[0..start]);
            }
            const tail = remaining[start..];
            if (tail.len < prefix.len and std.mem.startsWith(u8, prefix, tail)) {
                self.save(tail);
                return;
            }
            if (!std.mem.startsWith(u8, tail, prefix)) {
                self.cancel();
                try ordinary(gpa, output, tail[0..1]);
                remaining = tail[1..];
                continue;
            }
            const body = tail[prefix.len..];
            const end = std.mem.indexOfScalar(u8, body, 7) orelse {
                if (body.len <= nonce_limit and (body.len == 0 or validNonce(body))) {
                    self.save(tail);
                    return;
                }
                // Preserve malformed bytes, and keep tracking UTF-8 across reads.
                self.cancel();
                try ordinary(gpa, output, tail[0..1]);
                remaining = tail[1..];
                continue;
            };
            const nonce = body[0..end];
            if (!validNonce(nonce)) {
                self.cancel();
                try ordinary(gpa, output, tail[0 .. prefix.len + end + 1]);
            } else if (self.phase == .idle) {
                @memcpy(self.nonce[0..nonce.len], nonce);
                self.nonce_len = nonce.len;
                self.phase = .barrier;
                try ipc.appendMessage(gpa, output, .Info, "");
            }
            remaining = body[end + 1 ..];
        }
        if (remaining.len > 0) {
            self.cancel();
            try ordinary(gpa, output, remaining);
        }
    }

    fn controlStart(self: *State, bytes: []const u8) ?usize {
        for (bytes, 0..) |byte, index| {
            if (self.utf8_remaining > 0) {
                if (byte & 0xc0 == 0x80) {
                    self.utf8_remaining -= 1;
                    continue;
                }
                self.utf8_remaining = 0;
            }
            if (byte == 0x9d) return index;
            self.utf8_remaining = switch (byte) {
                0xc2...0xdf => 1,
                0xe0...0xef => 2,
                0xf0...0xf4 => 3,
                else => 0,
            };
        }
        return null;
    }

    fn save(self: *State, bytes: []const u8) void {
        @memcpy(self.carry[0..bytes.len], bytes);
        self.carry_len = bytes.len;
    }

    fn cancel(self: *State) void {
        if (self.phase == .barrier) self.phase = .cancelled;
    }

    pub fn barrierReply(self: *State, gpa: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
        switch (self.phase) {
            .barrier => {
                self.phase = .closing;
                try ipc.appendMessage(gpa, output, .Detach, "");
            },
            .cancelled => self.phase = .idle,
            else => {},
        }
    }

    pub fn peerClosed(self: *State, all_sent: bool) void {
        if (self.phase != .closing or !all_sent) return;
        var message: [ack_prefix.len + nonce_limit + 1]u8 = undefined;
        @memcpy(message[0..ack_prefix.len], ack_prefix);
        @memcpy(message[ack_prefix.len..][0..self.nonce_len], self.nonce[0..self.nonce_len]);
        message[ack_prefix.len + self.nonce_len] = 7;
        self.acknowledged = emit(message[0 .. ack_prefix.len + self.nonce_len + 1]);
    }

    pub fn finish(self: *State) void {
        if (!self.acknowledged) _ = emit(unavailable);
    }
};

fn validNonce(nonce: []const u8) bool {
    if (nonce.len == 0 or nonce.len > nonce_limit) return false;
    for (nonce) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn emit(bytes: []const u8) bool {
    var written: usize = 0;
    var attempts: u8 = 0;
    while (written < bytes.len and attempts < 4) : (attempts += 1) {
        var descriptors = [_]posix.pollfd{.{ .fd = posix.STDOUT_FILENO, .events = posix.POLL.OUT, .revents = 0 }};
        const count = posix.poll(&descriptors, 250) catch return false;
        if (count == 0) continue;
        if (descriptors[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) return false;
        written += posix.write(posix.STDOUT_FILENO, bytes[written..]) catch return false;
    }
    return written == bytes.len;
}
