//! Program Status Protocol (OSC 7501): a program reports what it is doing
//! (idle, working, done, blocked, error) and the daemon keeps one record per
//! id with the spec's lifetime rules. Spec:
//! https://www.superlogical.com/rex/docs/build/program-status (revision 0.4).
//!
/// CDXC:ProgramStatus 2026-10-14 DECISION:
/// User: "i want this implemented in the app and i want to have a setting to switch to using it instead of all the weird stuff we're doing to track when the agent is working or has attention status". The daemon is where OSC 7501 is parsed and its records are kept, because most sessions are not on screen (asleep, in the background, on the phone or the web) and only the daemon sees every byte. It also answers the `OSC 7501 ; ?` feature query itself, so a program under zmx learns the protocol is supported even with no client attached; Claude Code only reports after that answer.
/// SEE-ALSO: .dependencies/wmx/src/program_status.rs (the Windows twin), server/src/program_status/ (gxserver's reader and the activity mapping), `ipc.Tag.ProgramStatusSubscribe`.
const std = @import("std");

pub const osc_number = "7501";
/// Whole sequence, OSC through ST.
pub const max_sequence_bytes: usize = 4096;
pub const max_key_bytes: usize = 16;
pub const max_msg_encoded: usize = 2732;
pub const max_msg_decoded: usize = 2048;
pub const max_title_encoded: usize = 256;
pub const max_title_decoded: usize = 192;
pub const max_app_bytes: usize = 32;
pub const max_id_bytes: usize = 128;
pub const max_id_segment_bytes: usize = 32;
pub const max_id_depth: usize = 8;
pub const max_records: usize = 256;

pub const State = enum {
    idle,
    working,
    done,
    blocked,
    @"error",

    /// working and blocked are dropped on process exit and at the next prompt.
    pub fn isTransient(self: State) bool {
        return self == .working or self == .blocked;
    }
};

pub const Kind = enum { permission, question, auth };

pub const Terminator = enum {
    bel,
    st,

    pub fn bytes(self: Terminator) []const u8 {
        return switch (self) {
            .bel => "\x07",
            .st => "\x1b\\",
        };
    }
};

/// The feature-detection reply. It never carries anything from a report.
pub fn queryReply(terminator: Terminator) []const u8 {
    return switch (terminator) {
        .bel => "\x1b]7501;?\x07",
        .st => "\x1b]7501;?\x1b\\",
    };
}

pub const Record = struct {
    /// Empty for the root record.
    id: []u8,
    state: State,
    kind: ?Kind = null,
    progress: ?u8 = null,
    app: ?[]u8 = null,
    title: ?[]u8 = null,
    msg: ?[]u8 = null,
    /// Daemon-wide report counter at the last update: least recently updated
    /// is evicted first, and gxserver uses it to tell a re-sent record from a
    /// new one.
    seq: u64,
    updated_at_ms: i64,
    /// Foreground process group when a working/blocked record was reported,
    /// so it can be dropped once that process is gone. 0 = unknown.
    pgid: i32 = 0,

    fn deinit(self: *Record, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        if (self.app) |value| alloc.free(value);
        if (self.title) |value| alloc.free(value);
        if (self.msg) |value| alloc.free(value);
    }
};

/// A report that passed every check, borrowing from the sequence body except
/// for the decoded text, which lives in the fixed buffers.
pub const Parsed = struct {
    clear: bool = false,
    state: State = .idle,
    id: []const u8 = "",
    kind: ?Kind = null,
    progress: ?u8 = null,
    app: ?[]const u8 = null,
    title: ?[]const u8 = null,
    msg: ?[]const u8 = null,
    title_buf: [max_title_decoded]u8 = undefined,
    msg_buf: [max_msg_decoded]u8 = undefined,
};

pub const Body = enum {
    query,
    /// `out` holds a report that passed every check.
    report,
    /// Ignored or discarded whole (malformed state, limits, bad base64, ...).
    ignored,
};

fn isValueByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '_', '.', ',', '+', '/', '=', '-' => true,
        else => false,
    };
}

fn isIdByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '_', '.', '+', '-' => true,
        else => false,
    };
}

/// `None` when the id breaks the grammar or a limit; both discard the report.
fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_bytes) return false;
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, id, '/');
    while (it.next()) |segment| {
        depth += 1;
        if (depth > max_id_depth) return false;
        if (segment.len == 0 or segment.len > max_id_segment_bytes) return false;
        for (segment) |byte| if (!isIdByte(byte)) return false;
    }
    return true;
}

fn validApp(app: []const u8) bool {
    if (app.len == 0 or app.len > max_app_bytes) return false;
    for (app) |byte| if (!isIdByte(byte)) return false;
    return true;
}

fn parseProgress(value: []const u8) ?u8 {
    if (value.len == 0 or value.len > 3) return null;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return null;
    const number = std.fmt.parseInt(u8, value, 10) catch return null;
    return if (number <= 100) number else null;
}

/// Decode standard base64 (padding optional) into `out` and refuse control
/// characters and invalid UTF-8. Null discards the whole report.
fn decodeText(encoded: []const u8, out: []u8) ?[]const u8 {
    var trimmed = encoded;
    var pad: usize = 0;
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '=' and pad < 2) {
        trimmed = trimmed[0 .. trimmed.len - 1];
        pad += 1;
    }
    for (trimmed) |byte| if (byte == '=') return null;
    const decoder = std.base64.standard_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(trimmed) catch return null;
    if (size > out.len) return null;
    decoder.decode(out[0..size], trimmed) catch return null;
    const text = out[0..size];
    if (!std.unicode.utf8ValidateSlice(text)) return null;
    var view = std.unicode.Utf8View.initUnchecked(text);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp <= 0x1f or (cp >= 0x7f and cp <= 0x9f)) return null;
    }
    return text;
}

fn trimSpace(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t");
}

/// Parse the body between `OSC 7501 ;` and the terminator. `sequence_len` is
/// the whole sequence (OSC through ST) for the 4096-byte cap.
pub fn parseBody(body: []const u8, sequence_len: usize, out: *Parsed) Body {
    if (std.mem.eql(u8, trimSpace(body), "?") or (body.len > 0 and body[0] == '?')) return .query;
    if (sequence_len > max_sequence_bytes) return .ignored;
    out.* = .{};
    var state_text: ?[]const u8 = null;
    var id_text: ?[]const u8 = null;
    var kind_text: ?[]const u8 = null;
    var progress_text: ?[]const u8 = null;
    var app_text: ?[]const u8 = null;
    var title_text: ?[]const u8 = null;
    var msg_text: ?[]const u8 = null;
    var pairs = std.mem.splitScalar(u8, body, ':');
    while (pairs.next()) |raw_pair| {
        const pair = trimSpace(raw_pair);
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = trimSpace(pair[0..eq]);
        const value = trimSpace(pair[eq + 1 ..]);
        if (key.len == 0) continue;
        if (key.len > max_key_bytes) return .ignored;
        var key_ok = true;
        for (key) |byte| key_ok = key_ok and byte >= 'a' and byte <= 'z';
        if (!key_ok) continue;
        var value_ok = true;
        for (value) |byte| value_ok = value_ok and isValueByte(byte);
        if (!value_ok) continue;
        // Unknown keys are ignored: that is how the protocol is extended.
        if (std.mem.eql(u8, key, "state")) {
            state_text = value;
        } else if (std.mem.eql(u8, key, "id")) {
            id_text = value;
        } else if (std.mem.eql(u8, key, "kind")) {
            kind_text = value;
        } else if (std.mem.eql(u8, key, "progress")) {
            progress_text = value;
        } else if (std.mem.eql(u8, key, "app")) {
            app_text = value;
        } else if (std.mem.eql(u8, key, "title")) {
            title_text = value;
        } else if (std.mem.eql(u8, key, "msg")) {
            msg_text = value;
        }
    }
    const state_value = state_text orelse return .ignored;
    if (std.mem.eql(u8, state_value, "clear")) {
        out.clear = true;
    } else {
        out.state = std.meta.stringToEnum(State, state_value) orelse return .ignored;
    }
    if (id_text) |id| {
        if (!validId(id)) return .ignored;
        out.id = id;
    }
    // Limits are checked on every pair before anything is decoded or stored.
    if (app_text) |app| if (app.len > max_app_bytes) return .ignored;
    if (title_text) |title| if (title.len > max_title_encoded) return .ignored;
    if (msg_text) |msg| if (msg.len > max_msg_encoded) return .ignored;
    if (out.clear) return .report;
    if (out.state == .blocked) {
        if (kind_text) |kind| out.kind = std.meta.stringToEnum(Kind, kind);
    }
    if (out.state.isTransient()) {
        if (progress_text) |progress| out.progress = parseProgress(progress);
    }
    if (app_text) |app| {
        if (validApp(app)) out.app = app;
    }
    if (title_text) |title| {
        out.title = decodeText(title, &out.title_buf) orelse return .ignored;
    }
    if (msg_text) |msg| {
        out.msg = decodeText(msg, &out.msg_buf) orelse return .ignored;
    }
    return .report;
}

fn isSelfOrDescendant(id: []const u8, ancestor: []const u8) bool {
    if (ancestor.len == 0) return true;
    if (!std.mem.startsWith(u8, id, ancestor)) return false;
    return id.len == ancestor.len or id[ancestor.len] == '/';
}

/// One terminal's records.
pub const Store = struct {
    records: std.ArrayList(Record) = .empty,
    seq: u64 = 0,
    /// Set once any report was applied; never cleared. gxserver's "Auto"
    /// setting trusts a session's reports from then on.
    ever_reported: bool = false,
    /// Bumped on every change, so the daemon knows a snapshot is due.
    generation: u64 = 0,

    pub fn deinit(self: *Store, alloc: std.mem.Allocator) void {
        for (self.records.items) |*record| record.deinit(alloc);
        self.records.deinit(alloc);
        self.* = .{};
    }

    fn indexOf(self: *const Store, id: []const u8) ?usize {
        for (self.records.items, 0..) |record, i| {
            if (std.mem.eql(u8, record.id, id)) return i;
        }
        return null;
    }

    fn removeAt(self: *Store, alloc: std.mem.Allocator, index: usize) void {
        var record = self.records.orderedRemove(index);
        record.deinit(alloc);
    }

    pub fn hasTransient(self: *const Store) bool {
        for (self.records.items) |record| if (record.state.isTransient()) return true;
        return false;
    }

    /// Apply one parsed report. `pgid` is the pty's foreground process group.
    pub fn apply(self: *Store, alloc: std.mem.Allocator, parsed: *const Parsed, now_ms: i64, pgid: i32) !void {
        self.ever_reported = true;
        if (parsed.clear) {
            var i: usize = self.records.items.len;
            var removed = false;
            while (i > 0) {
                i -= 1;
                if (isSelfOrDescendant(self.records.items[i].id, parsed.id)) {
                    self.removeAt(alloc, i);
                    removed = true;
                }
            }
            if (removed) self.generation += 1;
            return;
        }
        self.seq += 1;
        var record = Record{
            .id = try alloc.dupe(u8, parsed.id),
            .state = parsed.state,
            .kind = parsed.kind,
            .progress = parsed.progress,
            .seq = self.seq,
            .updated_at_ms = now_ms,
            .pgid = if (parsed.state.isTransient()) pgid else 0,
        };
        errdefer record.deinit(alloc);
        if (parsed.app) |value| record.app = try alloc.dupe(u8, value);
        if (parsed.title) |value| record.title = try alloc.dupe(u8, value);
        if (parsed.msg) |value| record.msg = try alloc.dupe(u8, value);
        if (self.indexOf(parsed.id)) |index| {
            self.records.items[index].deinit(alloc);
            self.records.items[index] = record;
        } else {
            if (self.records.items.len >= max_records) {
                var oldest: usize = 0;
                for (self.records.items, 0..) |existing, i| {
                    if (existing.seq < self.records.items[oldest].seq) oldest = i;
                }
                self.removeAt(alloc, oldest);
            }
            try self.records.append(alloc, record);
        }
        self.generation += 1;
    }

    /// OSC 133;A (a new shell prompt): working and blocked records end, and so
    /// do idle ones (the spec allows it; an idle record of a program that
    /// already returned to the prompt describes nothing). done and error stay.
    pub fn onPromptStart(self: *Store, alloc: std.mem.Allocator) void {
        var i: usize = self.records.items.len;
        var removed = false;
        while (i > 0) {
            i -= 1;
            const state = self.records.items[i].state;
            if (state.isTransient() or state == .idle) {
                self.removeAt(alloc, i);
                removed = true;
            }
        }
        if (removed) self.generation += 1;
    }

    /// Drop working/blocked records whose reporting process group is gone.
    /// `alive` answers whether a process group still exists.
    pub fn dropExited(self: *Store, alloc: std.mem.Allocator, context: anytype, comptime alive: fn (@TypeOf(context), i32) bool) void {
        var i: usize = self.records.items.len;
        var removed = false;
        while (i > 0) {
            i -= 1;
            const record = self.records.items[i];
            if (!record.state.isTransient() or record.pgid <= 0) continue;
            if (!alive(context, record.pgid)) {
                self.removeAt(alloc, i);
                removed = true;
            }
        }
        if (removed) self.generation += 1;
    }

    /// RIS (full reset) removes every record. DECSTR does not.
    pub fn onFullReset(self: *Store, alloc: std.mem.Allocator) void {
        if (self.records.items.len == 0) return;
        for (self.records.items) |*record| record.deinit(alloc);
        self.records.clearRetainingCapacity();
        self.generation += 1;
    }

    /// One JSON object: `{"reported":bool,"records":[...]}`, records in
    /// report order. Text values are already free of control characters.
    pub fn writeJson(self: *const Store, writer: *std.Io.Writer) !void {
        try writer.print("{{\"reported\":{},\"records\":[", .{self.ever_reported});
        for (self.records.items, 0..) |record, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"id\":");
            try writeJsonString(writer, record.id);
            try writer.print(",\"state\":\"{s}\"", .{@tagName(record.state)});
            if (record.kind) |kind| try writer.print(",\"kind\":\"{s}\"", .{@tagName(kind)});
            if (record.progress) |progress| try writer.print(",\"progress\":{d}", .{progress});
            if (record.app) |app| {
                try writer.writeAll(",\"app\":");
                try writeJsonString(writer, app);
            }
            if (record.title) |title| {
                try writer.writeAll(",\"title\":");
                try writeJsonString(writer, title);
            }
            if (record.msg) |msg| {
                try writer.writeAll(",\"msg\":");
                try writeJsonString(writer, msg);
            }
            try writer.print(",\"seq\":{d},\"updatedAtMs\":{d}}}", .{ record.seq, record.updated_at_ms });
        }
        try writer.writeAll("]}");
    }
};

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0...0x1f, 0x7f => try writer.print("\\u00{x:0>2}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

/// Streaming scanner over pty output. It finds `OSC 7501`, `OSC 133;A`
/// (prompt start) and `ESC c` (RIS) across read boundaries, buffering only
/// 7501 bodies (capped at the sequence limit) and skipping every other
/// string sequence without copying it.
pub const Scanner = struct {
    const Mode = enum {
        ground,
        esc,
        osc_number,
        osc_7501,
        osc_7501_esc,
        osc_133,
        osc_133_esc,
        osc_skip,
        osc_skip_esc,
        string_skip,
        string_skip_esc,
    };

    mode: Mode = .ground,
    number: u32 = 0,
    number_digits: u8 = 0,
    body: [max_sequence_bytes]u8 = undefined,
    body_len: usize = 0,
    body_overflow: bool = false,
    /// First two bytes after `133;`.
    semantic: [2]u8 = .{ 0, 0 },
    semantic_len: u8 = 0,

    pub const Event = union(enum) {
        /// Body of `OSC 7501 ; <body>`; `sequence_len` is OSC through ST.
        /// Null body when the sequence went over the cap.
        program_status: struct { body: ?[]const u8, sequence_len: usize, terminator: Terminator },
        prompt_start,
        full_reset,
    };

    /// Feed bytes and call `handler.onEvent(Event)` for each event in order.
    /// A body slice is only valid during the call.
    pub fn feed(self: *Scanner, bytes: []const u8, handler: anytype) void {
        for (bytes) |byte| self.step(byte, handler);
    }

    fn finishOsc(self: *Scanner, terminator: Terminator, handler: anytype) void {
        switch (self.mode) {
            .osc_7501, .osc_7501_esc => {
                const header_len = 2 + osc_number.len + 1;
                const sequence_len = header_len + self.body_len + terminator.bytes().len;
                handler.onEvent(.{ .program_status = .{
                    .body = if (self.body_overflow) null else self.body[0..self.body_len],
                    .sequence_len = if (self.body_overflow) max_sequence_bytes + 1 else sequence_len,
                    .terminator = terminator,
                } });
            },
            .osc_133, .osc_133_esc => {
                if (self.semantic_len >= 1 and self.semantic[0] == 'A' and
                    (self.semantic_len == 1 or self.semantic[1] == ';'))
                {
                    handler.onEvent(.prompt_start);
                }
            },
            else => {},
        }
        self.mode = .ground;
    }

    fn step(self: *Scanner, byte: u8, handler: anytype) void {
        switch (self.mode) {
            .ground => {
                if (byte == 0x1b) self.mode = .esc;
            },
            .esc => switch (byte) {
                ']' => {
                    self.mode = .osc_number;
                    self.number = 0;
                    self.number_digits = 0;
                },
                'c' => {
                    self.mode = .ground;
                    handler.onEvent(.full_reset);
                },
                'P', 'X', '^', '_' => self.mode = .string_skip,
                0x1b => self.mode = .esc,
                else => self.mode = .ground,
            },
            .osc_number => switch (byte) {
                '0'...'9' => {
                    if (self.number_digits < 6) {
                        self.number = self.number * 10 + (byte - '0');
                        self.number_digits += 1;
                    } else {
                        self.mode = .osc_skip;
                    }
                },
                ';' => {
                    if (self.number_digits == 4 and self.number == 7501) {
                        self.mode = .osc_7501;
                        self.body_len = 0;
                        self.body_overflow = false;
                    } else if (self.number_digits == 3 and self.number == 133) {
                        self.mode = .osc_133;
                        self.semantic_len = 0;
                    } else {
                        self.mode = .osc_skip;
                    }
                },
                0x07 => self.mode = .ground,
                0x1b => self.mode = .osc_skip_esc,
                0x18, 0x1a => self.mode = .ground,
                else => self.mode = .osc_skip,
            },
            .osc_7501 => switch (byte) {
                0x07 => self.finishOsc(.bel, handler),
                0x1b => self.mode = .osc_7501_esc,
                0x18, 0x1a => self.mode = .ground,
                else => {
                    if (self.body_len < self.body.len) {
                        self.body[self.body_len] = byte;
                        self.body_len += 1;
                    } else {
                        self.body_overflow = true;
                    }
                },
            },
            .osc_133 => switch (byte) {
                0x07 => self.finishOsc(.bel, handler),
                0x1b => self.mode = .osc_133_esc,
                0x18, 0x1a => self.mode = .ground,
                else => {
                    if (self.semantic_len < self.semantic.len) {
                        self.semantic[self.semantic_len] = byte;
                        self.semantic_len += 1;
                    }
                },
            },
            .osc_7501_esc, .osc_133_esc => {
                if (byte == '\\') {
                    self.finishOsc(.st, handler);
                } else {
                    // ESC that is not ST aborts the string and starts a new
                    // escape sequence.
                    self.mode = .esc;
                    self.step(byte, handler);
                }
            },
            .osc_skip => switch (byte) {
                0x07, 0x18, 0x1a => self.mode = .ground,
                0x1b => self.mode = .osc_skip_esc,
                else => {},
            },
            .osc_skip_esc, .string_skip_esc => {
                if (byte == '\\') {
                    self.mode = .ground;
                } else {
                    self.mode = .esc;
                    self.step(byte, handler);
                }
            },
            .string_skip => switch (byte) {
                0x18, 0x1a => self.mode = .ground,
                0x1b => self.mode = .string_skip_esc,
                else => {},
            },
        }
    }
};

/// Remove complete `OSC 7501 ; ? <ST|BEL>` queries from output bound for
/// attached clients: the daemon answers them itself, and a client terminal
/// that also answered would hand the program a second, unexpected reply.
/// Returns null when there is nothing to remove. A query split across two pty
/// reads is passed through; programs write the query in one write.
pub fn stripQueries(alloc: std.mem.Allocator, data: []const u8) ?[]u8 {
    const prefix = "\x1b]7501;?";
    if (std.mem.indexOf(u8, data, prefix) == null) return null;
    var out = std.ArrayList(u8).initCapacity(alloc, data.len) catch return null;
    var removed = false;
    var i: usize = 0;
    while (i < data.len) {
        if (std.mem.startsWith(u8, data[i..], prefix)) {
            const after = i + prefix.len;
            if (after < data.len and data[after] == 0x07) {
                i = after + 1;
                removed = true;
                continue;
            }
            if (after + 1 < data.len and data[after] == 0x1b and data[after + 1] == '\\') {
                i = after + 2;
                removed = true;
                continue;
            }
        }
        out.appendAssumeCapacity(data[i]);
        i += 1;
    }
    if (!removed) {
        out.deinit(alloc);
        return null;
    }
    return out.toOwnedSlice(alloc) catch {
        out.deinit(alloc);
        return null;
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Collector = struct {
    alloc: std.mem.Allocator,
    store: *Store,
    queries: usize = 0,
    prompts: usize = 0,
    resets: usize = 0,
    ignored: usize = 0,

    fn onEvent(self: *Collector, event: Scanner.Event) void {
        switch (event) {
            .program_status => |status| {
                const body = status.body orelse {
                    self.ignored += 1;
                    return;
                };
                var parsed: Parsed = undefined;
                switch (parseBody(body, status.sequence_len, &parsed)) {
                    .query => self.queries += 1,
                    .ignored => self.ignored += 1,
                    .report => self.store.apply(self.alloc, &parsed, 1000, 42) catch unreachable,
                }
            },
            .prompt_start => {
                self.prompts += 1;
                self.store.onPromptStart(self.alloc);
            },
            .full_reset => {
                self.resets += 1;
                self.store.onFullReset(self.alloc);
            },
        }
    }
};

fn feedAll(store: *Store, chunks: []const []const u8) !Collector {
    var scanner = Scanner{};
    var collector = Collector{ .alloc = testing.allocator, .store = store };
    for (chunks) |chunk| scanner.feed(chunk, &collector);
    return collector;
}

fn findRecord(store: *const Store, id: []const u8) ?Record {
    const index = store.indexOf(id) orelse return null;
    return store.records.items[index];
}

test "report replaces the root record whole" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    // "Installing updates"
    _ = try feedAll(&store, &.{
        "\x1b]7501;state=working:app=brew:progress=40:msg=SW5zdGFsbGluZyB1cGRhdGVz\x1b\\",
    });
    var root = findRecord(&store, "").?;
    try testing.expectEqual(State.working, root.state);
    try testing.expectEqual(@as(?u8, 40), root.progress);
    try testing.expectEqualStrings("brew", root.app.?);
    try testing.expectEqualStrings("Installing updates", root.msg.?);
    _ = try feedAll(&store, &.{"\x1b]7501;state=done\x07"});
    root = findRecord(&store, "").?;
    try testing.expectEqual(State.done, root.state);
    try testing.expect(root.app == null and root.msg == null and root.progress == null);
    try testing.expect(store.ever_reported);
}

test "sequence split across reads is reassembled" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    _ = try feedAll(&store, &.{ "out\x1b", "]75", "01;state=blo", "cked:kind=auth\x1b", "\\tail" });
    const root = findRecord(&store, "").?;
    try testing.expectEqual(State.blocked, root.state);
    try testing.expectEqual(Kind.auth, root.kind.?);
}

test "kind only with blocked, progress only with working or blocked" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    _ = try feedAll(&store, &.{"\x1b]7501;state=done:kind=permission:progress=50\x07"});
    const root = findRecord(&store, "").?;
    try testing.expect(root.kind == null and root.progress == null);
    _ = try feedAll(&store, &.{"\x1b]7501;state=blocked:kind=nope:progress=101\x07"});
    const blocked = findRecord(&store, "").?;
    try testing.expect(blocked.kind == null and blocked.progress == null);
}

test "unknown state and missing state are ignored" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    const c = try feedAll(&store, &.{ "\x1b]7501;state=sleeping\x07", "\x1b]7501;app=x\x07" });
    try testing.expectEqual(@as(usize, 2), c.ignored);
    try testing.expectEqual(@as(usize, 0), store.records.items.len);
}

test "malformed pairs are skipped, unknown keys ignored, last value wins" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    _ = try feedAll(&store, &.{"\x1b]7501; state = idle :novalue:Bad=1:app=a b:future=1:state=working \x07"});
    const root = findRecord(&store, "").?;
    try testing.expectEqual(State.working, root.state);
    try testing.expect(root.app == null);
}

test "control characters, bad base64 and bad ids discard the report" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    // "a\nb" = YQpi
    const c = try feedAll(&store, &.{
        "\x1b]7501;state=working:msg=YQpi\x07",
        "\x1b]7501;state=working:msg=Y\x07",
        "\x1b]7501;state=working:id=a//b\x07",
        "\x1b]7501;state=working:id=a/b/c/d/e/f/g/h/i\x07",
        // U+0085 (C1 NEL) = woU=
        "\x1b]7501;state=working:title=woU=\x07",
    });
    try testing.expectEqual(@as(usize, 5), c.ignored);
    try testing.expectEqual(@as(usize, 0), store.records.items.len);
    // A byte outside the value set only skips that pair.
    _ = try feedAll(&store, &.{"\x1b]7501;state=working:msg=%%%\x07"});
    try testing.expect(findRecord(&store, "").?.msg == null);
}

test "limits discard the whole report" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    var big: [5000]u8 = undefined;
    @memset(&big, 'A');
    var seq = std.ArrayList(u8).empty;
    defer seq.deinit(testing.allocator);
    try seq.appendSlice(testing.allocator, "\x1b]7501;state=working:msg=");
    try seq.appendSlice(testing.allocator, &big);
    try seq.append(testing.allocator, 0x07);
    var long_key = std.ArrayList(u8).empty;
    defer long_key.deinit(testing.allocator);
    try long_key.appendSlice(testing.allocator, "\x1b]7501;state=working:abcdefghijklmnopq=1\x07");
    var long_title = std.ArrayList(u8).empty;
    defer long_title.deinit(testing.allocator);
    try long_title.appendSlice(testing.allocator, "\x1b]7501;state=working:title=");
    try long_title.appendSlice(testing.allocator, big[0..260]);
    try long_title.append(testing.allocator, 0x07);
    const c = try feedAll(&store, &.{ seq.items, long_key.items, long_title.items });
    try testing.expectEqual(@as(usize, 3), c.ignored);
    try testing.expectEqual(@as(usize, 0), store.records.items.len);
    // The scanner is back in ground state afterwards.
    _ = try feedAll(&store, &.{"\x1b]7501;state=idle\x07"});
    try testing.expectEqual(@as(usize, 1), store.records.items.len);
}

test "clear removes a record and its descendants, bare clear removes all" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    _ = try feedAll(&store, &.{
        "\x1b]7501;state=working\x07",
        "\x1b]7501;state=working:id=build\x07",
        "\x1b]7501;state=blocked:id=build/test\x07",
        "\x1b]7501;state=done:id=builder\x07",
        "\x1b]7501;state=clear:id=build\x07",
    });
    try testing.expect(findRecord(&store, "build") == null);
    try testing.expect(findRecord(&store, "build/test") == null);
    try testing.expect(findRecord(&store, "builder") != null);
    try testing.expect(findRecord(&store, "") != null);
    _ = try feedAll(&store, &.{"\x1b]7501;state=clear\x1b\\"});
    try testing.expectEqual(@as(usize, 0), store.records.items.len);
}

test "prompt start drops working, blocked and idle but keeps done and error" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    const c = try feedAll(&store, &.{
        "\x1b]7501;state=working:id=a\x07",
        "\x1b]7501;state=blocked:id=b\x07",
        "\x1b]7501;state=idle:id=c\x07",
        "\x1b]7501;state=done:id=d\x07",
        "\x1b]7501;state=error:id=e\x07",
        "\x1b]133;A;aid=1\x07",
        "\x1b]133;B\x07",
    });
    try testing.expectEqual(@as(usize, 1), c.prompts);
    try testing.expectEqual(@as(usize, 2), store.records.items.len);
    try testing.expect(findRecord(&store, "d") != null and findRecord(&store, "e") != null);
}

test "RIS removes every record" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    const c = try feedAll(&store, &.{ "\x1b]7501;state=done\x07", "\x1bc" });
    try testing.expectEqual(@as(usize, 1), c.resets);
    try testing.expectEqual(@as(usize, 0), store.records.items.len);
}

test "feature query is recognised" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    const c = try feedAll(&store, &.{ "\x1b]7501;?\x1b\\", "\x1b]7501;?\x07" });
    try testing.expectEqual(@as(usize, 2), c.queries);
    try testing.expect(!store.ever_reported);
}

test "other OSCs and string sequences are skipped" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    const c = try feedAll(&store, &.{
        "\x1b]2;has 7501;state=working in it\x07",
        "\x1bP7501;state=working\x1b\\",
        "\x1b_G7501;state=working\x1b\\",
        "\x1b]75011;state=working\x07",
        "\x1b]133;B\x07",
    });
    try testing.expectEqual(@as(usize, 0), c.prompts);
    try testing.expectEqual(@as(usize, 0), c.queries);
    try testing.expectEqual(@as(usize, 0), store.records.items.len);
}

test "record cap evicts the least recently updated record" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    var scanner = Scanner{};
    var collector = Collector{ .alloc = testing.allocator, .store = &store };
    var buf: [64]u8 = undefined;
    for (0..max_records + 1) |i| {
        const seq = try std.fmt.bufPrint(&buf, "\x1b]7501;state=working:id=r{d}\x07", .{i});
        scanner.feed(seq, &collector);
    }
    try testing.expectEqual(max_records, store.records.items.len);
    try testing.expect(findRecord(&store, "r0") == null);
    try testing.expect(findRecord(&store, "r256") != null);
}

test "dropExited removes transient records of a gone process group" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    _ = try feedAll(&store, &.{ "\x1b]7501;state=working\x07", "\x1b]7501;state=done:id=x\x07" });
    const Ctx = struct {
        fn alive(_: void, _: i32) bool {
            return false;
        }
    };
    store.dropExited(testing.allocator, {}, Ctx.alive);
    try testing.expectEqual(@as(usize, 1), store.records.items.len);
    try testing.expect(findRecord(&store, "x") != null);
}

test "writeJson escapes text" {
    var store = Store{};
    defer store.deinit(testing.allocator);
    // `say "hi" \` = c2F5ICJoaSIgXA==
    _ = try feedAll(&store, &.{"\x1b]7501;state=blocked:kind=question:app=claude-code:msg=c2F5ICJoaSIgXA==\x07"});
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try store.writeJson(&out.writer);
    try testing.expectEqualStrings(
        "{\"reported\":true,\"records\":[{\"id\":\"\",\"state\":\"blocked\",\"kind\":\"question\",\"app\":\"claude-code\",\"msg\":\"say \\\"hi\\\" \\\\\",\"seq\":1,\"updatedAtMs\":1000}]}",
        out.written(),
    );
}

test "stripQueries removes only complete queries" {
    const out = stripQueries(testing.allocator, "a\x1b]7501;?\x1b\\b\x1b]7501;?\x07c\x1b]7501;state=idle\x07").?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("abc\x1b]7501;state=idle\x07", out);
    try testing.expect(stripQueries(testing.allocator, "plain") == null);
    try testing.expect(stripQueries(testing.allocator, "\x1b]7501;state=idle\x07") == null);
}
