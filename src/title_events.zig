const std = @import("std");

pub const debounce_ms: i64 = 1_000;
pub const semantic_heartbeat_ms: i64 = 2_000;
pub const max_settle_ms: i64 = 6_000;

// CDXC:ZmxTitleObservations 2026-06-01-10:17:
// Agent CLIs often animate terminal titles with spinner glyphs. zmx should observe those titles at the PTY layer, but it must coalesce semantic title changes before notifying gxserver: keep only the latest raw title, emit after 1s of semantic stability, and force a burst closed after 6s.
// CDXC:ZmxTitleObservations 2026-06-06-07:09:
// gxserver uses changing title frames inside a 5s slow-spinner freshness window to decide whether Codex/Claude/Cursor/Pi sessions are still working. After the first semantic title emission, send changing raw spinner frames at most once every 2s so the working detector stays alive without flooding the sidebar with dozens of no-op title events per second.
pub const Coalescer = struct {
    burst_started_ms: i64 = 0,
    last_changed_ms: i64 = 0,
    last_emitted_ms: i64 = 0,
    latest_signature: ?[]u8 = null,
    latest_title: ?[]u8 = null,
    last_emitted_signature: ?[]u8 = null,
    last_emitted_title: ?[]u8 = null,
    pending: bool = false,
    pending_heartbeat: bool = false,

    pub fn deinit(self: *Coalescer, alloc: std.mem.Allocator) void {
        if (self.latest_signature) |value| alloc.free(value);
        if (self.latest_title) |value| alloc.free(value);
        if (self.last_emitted_signature) |value| alloc.free(value);
        if (self.last_emitted_title) |value| alloc.free(value);
        self.* = .{};
    }

    pub fn observe(self: *Coalescer, alloc: std.mem.Allocator, title: []const u8, now_ms: i64) !void {
        const trimmed = trimAscii(title);
        if (trimmed.len == 0) {
            return;
        }
        if (self.latest_title) |latest_title| {
            if (std.mem.eql(u8, latest_title, trimmed)) {
                return;
            }
        }
        const signature = try createSemanticSignature(alloc, trimmed);
        errdefer alloc.free(signature);
        if (self.latest_signature) |latest| {
            if (std.mem.eql(u8, latest, signature)) {
                try self.replaceLatestTitle(alloc, trimmed);
                self.scheduleSemanticHeartbeatIfNeeded();
                alloc.free(signature);
                return;
            }
        }
        if (!self.pending) {
            if (self.last_emitted_signature) |last_emitted| {
                if (std.mem.eql(u8, last_emitted, signature)) {
                    try self.replaceLatestTitle(alloc, trimmed);
                    self.scheduleSemanticHeartbeatIfNeeded();
                    alloc.free(signature);
                    return;
                }
            }
            self.burst_started_ms = now_ms;
        }
        self.last_changed_ms = now_ms;
        self.pending = true;
        self.pending_heartbeat = false;
        if (self.latest_signature) |value| alloc.free(value);
        self.latest_signature = signature;
        try self.replaceLatestTitle(alloc, trimmed);
    }

    pub fn pollTimeoutMs(self: *const Coalescer, now_ms: i64) i32 {
        const due_ms = if (self.pending) blk: {
            const debounce_due_ms = self.last_changed_ms + debounce_ms;
            const max_due_ms = self.burst_started_ms + max_settle_ms;
            break :blk @min(debounce_due_ms, max_due_ms);
        } else if (self.pending_heartbeat) self.last_emitted_ms + semantic_heartbeat_ms else return -1;
        if (due_ms <= now_ms) {
            return 0;
        }
        const delta = due_ms - now_ms;
        return @intCast(@min(delta, std.math.maxInt(i32)));
    }

    pub fn takeDue(self: *Coalescer, alloc: std.mem.Allocator, now_ms: i64) !?[]u8 {
        if (self.isPendingDue(now_ms)) {
            self.pending = false;
            // A short-lived semantic title can settle back to the previously
            // emitted raw title before debounce (Codex /rename does this on
            // WSL). The completed burst is still a meaningful notification to
            // gxserver, which uses it to reconcile canonical agent metadata.
            return try self.emitLatest(alloc, now_ms, true);
        }
        if (self.isHeartbeatDue(now_ms)) {
            self.pending_heartbeat = false;
            return try self.emitLatest(alloc, now_ms, true);
        }
        return null;
    }

    pub fn lastEmittedTitle(self: *const Coalescer) ?[]const u8 {
        return self.last_emitted_title;
    }

    fn emitLatest(self: *Coalescer, alloc: std.mem.Allocator, now_ms: i64, allow_repeated_signature: bool) !?[]u8 {
        const title = self.latest_title orelse return null;
        const signature = self.latest_signature orelse return null;
        if (self.last_emitted_signature) |last_emitted| {
            if (std.mem.eql(u8, last_emitted, signature)) {
                if (!allow_repeated_signature) {
                    return null;
                }
            }
        }
        if (self.last_emitted_signature) |value| alloc.free(value);
        self.last_emitted_signature = try alloc.dupe(u8, signature);
        if (self.last_emitted_title) |value| alloc.free(value);
        self.last_emitted_title = try alloc.dupe(u8, title);
        self.last_emitted_ms = now_ms;
        return try alloc.dupe(u8, title);
    }

    fn isPendingDue(self: *const Coalescer, now_ms: i64) bool {
        return self.pending and
            (now_ms - self.last_changed_ms >= debounce_ms or
                now_ms - self.burst_started_ms >= max_settle_ms);
    }

    fn isHeartbeatDue(self: *const Coalescer, now_ms: i64) bool {
        return self.pending_heartbeat and now_ms - self.last_emitted_ms >= semantic_heartbeat_ms;
    }

    fn replaceLatestTitle(self: *Coalescer, alloc: std.mem.Allocator, title: []const u8) !void {
        if (self.latest_title) |value| alloc.free(value);
        self.latest_title = try alloc.dupe(u8, title);
    }

    fn scheduleSemanticHeartbeatIfNeeded(self: *Coalescer) void {
        if (self.pending) {
            return;
        }
        const latest_signature = self.latest_signature orelse return;
        const last_emitted_signature = self.last_emitted_signature orelse return;
        if (!std.mem.eql(u8, latest_signature, last_emitted_signature)) {
            return;
        }
        const latest_title = self.latest_title orelse return;
        const last_emitted_title = self.last_emitted_title orelse return;
        if (std.mem.eql(u8, latest_title, last_emitted_title)) {
            return;
        }
        self.pending_heartbeat = true;
    }
};

pub fn writeTitleJsonLine(writer: *std.Io.Writer, title: []const u8) !void {
    try writer.writeAll("{\"title\":\"");
    for (title) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11...12, 14...0x1f => try writer.print("\\u00{x:0>2}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeAll("\"}\n");
}

pub fn createSemanticSignature(alloc: std.mem.Allocator, title: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(alloc);
    const trimmed = trimAscii(title);
    if (try appendCodexActionRequiredSignature(&output, alloc, trimmed)) {
        return try output.toOwnedSlice(alloc);
    }
    const leading_animation_end = stripLeadingAnimatedMarkers(trimmed);
    var index = leading_animation_end;
    var previous_space = false;
    while (index < trimmed.len) {
        const byte = trimmed[index];
        if (isAsciiWhitespace(byte)) {
            if (!previous_space and output.items.len > 0) {
                try output.append(alloc, ' ');
                previous_space = true;
            }
            index += 1;
            continue;
        }
        try output.append(alloc, byte);
        previous_space = false;
        index += 1;
    }
    while (output.items.len > 0 and output.items[output.items.len - 1] == ' ') {
        _ = output.pop();
    }
    trimVolatileSemanticSuffix(&output, leading_animation_end > 0);
    return output.toOwnedSlice(alloc);
}

fn appendCodexActionRequiredSignature(output: *std.ArrayList(u8), alloc: std.mem.Allocator, title: []const u8) !bool {
    if (title.len < 3 or title[0] != '[') {
        return false;
    }
    var index: usize = 1;
    while (index < title.len and isAsciiWhitespace(title[index])) : (index += 1) {}
    if (index >= title.len) return false;
    const marker_len = animatedMarkerLength(title[index..]) orelse if (title[index] == '!' or title[index] == '.') @as(usize, 1) else return false;
    index += marker_len;
    while (index < title.len and isAsciiWhitespace(title[index])) : (index += 1) {}
    if (index >= title.len or title[index] != ']') {
        return false;
    }
    index += 1;
    const rest = trimAscii(title[index..]);
    if (!std.ascii.startsWithIgnoreCase(rest, "Action Required")) {
        return false;
    }
    try output.appendSlice(alloc, "[action-required] ");
    try output.appendSlice(alloc, stripTrailingElapsedCounter(rest));
    return true;
}

fn trimVolatileSemanticSuffix(output: *std.ArrayList(u8), had_animated_prefix: bool) void {
    trimTrailingCursorWorkingDots(output);
    if (!had_animated_prefix) {
        return;
    }
    const trimmed = stripTrailingElapsedCounter(output.items);
    truncateOutput(output, trimmed.len);
}

fn trimTrailingCursorWorkingDots(output: *std.ArrayList(u8)) void {
    var end = output.items.len;
    while (end > 0 and isAsciiWhitespace(output.items[end - 1])) : (end -= 1) {}
    var dot_start = end;
    while (dot_start > 0) {
        if (output.items[dot_start - 1] == '.') {
            dot_start -= 1;
            continue;
        }
        if (std.mem.endsWith(u8, output.items[0..dot_start], "·")) {
            dot_start -= "·".len;
            continue;
        }
        break;
    }
    if (dot_start == end) {
        return;
    }
    var prefix_end = dot_start;
    while (prefix_end > 0 and isAsciiWhitespace(output.items[prefix_end - 1])) : (prefix_end -= 1) {}
    if (std.mem.endsWith(u8, output.items[0..prefix_end], "Working")) {
        truncateOutput(output, prefix_end);
    }
}

fn stripTrailingElapsedCounter(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and isAsciiWhitespace(value[end - 1])) : (end -= 1) {}
    var cursor = end;
    var found = false;
    while (parseDurationGroupStartBefore(value, cursor)) |group_start| {
        found = true;
        cursor = group_start;
        while (cursor > 0 and isAsciiWhitespace(value[cursor - 1])) : (cursor -= 1) {}
    }
    if (!found or cursor == 0) {
        return value[0..end];
    }
    return value[0..cursor];
}

fn parseDurationGroupStartBefore(value: []const u8, end: usize) ?usize {
    var index = end;
    while (index > 0 and isAsciiWhitespace(value[index - 1])) : (index -= 1) {}
    if (index == 0) {
        return null;
    }
    const unit = value[index - 1];
    if (unit != 's' and unit != 'm' and unit != 'h' and unit != 'd') {
        return null;
    }
    index -= 1;
    const digits_end = index;
    while (index > 0 and std.ascii.isDigit(value[index - 1])) : (index -= 1) {}
    if (index == digits_end) {
        return null;
    }
    if (index > 0 and !isAsciiWhitespace(value[index - 1])) {
        return null;
    }
    return index;
}

fn truncateOutput(output: *std.ArrayList(u8), len: usize) void {
    while (output.items.len > len) {
        _ = output.pop();
    }
}

fn stripLeadingAnimatedMarkers(value: []const u8) usize {
    var index: usize = 0;
    while (index < value.len) {
        if (isAsciiWhitespace(value[index]) or value[index] == '*') {
            index += 1;
            continue;
        }
        if (animatedMarkerLength(value[index..])) |len| {
            index += len;
            continue;
        }
        break;
    }
    return index;
}

fn animatedMarkerLength(value: []const u8) ?usize {
    if (value.len >= 3 and value[0] == 0xe2 and value[1] >= 0xa0 and value[1] <= 0xa3) {
        return 3;
    }
    const markers = [_][]const u8{
        "·",
        "•",
        "⋅",
        "◦",
        "✳",
        "✶",
        "✻",
        "✽",
        "✸",
        "✹",
        "✺",
        "✷",
        "✴",
        "✦",
        "◇",
        "🤖",
    };
    for (markers) |marker| {
        if (std.mem.startsWith(u8, value, marker)) {
            return marker.len;
        }
    }
    return null;
}

fn trimAscii(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;
    while (start < end and isAsciiWhitespace(value[start])) : (start += 1) {}
    while (end > start and isAsciiWhitespace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn isAsciiWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

test "semantic signature coalesces codex action spinner markers" {
    const alloc = std.testing.allocator;
    const left = try createSemanticSignature(alloc, "[·] Action Required: Review");
    defer alloc.free(left);
    const right = try createSemanticSignature(alloc, "[⠂] Action Required: Review");
    defer alloc.free(right);
    try std.testing.expectEqualStrings(left, right);
}

test "semantic signature keeps visible title after leading braille spinner" {
    const alloc = std.testing.allocator;
    const value = try createSemanticSignature(alloc, "⠋ Codex Working");
    defer alloc.free(value);
    try std.testing.expectEqualStrings("Codex Working", value);
}

test "semantic signature ignores codex action elapsed counter" {
    const alloc = std.testing.allocator;
    const left = try createSemanticSignature(alloc, "[!] Action Required 11s");
    defer alloc.free(left);
    const right = try createSemanticSignature(alloc, "[·] Action Required 12s");
    defer alloc.free(right);
    try std.testing.expectEqualStrings(left, right);
}

test "coalescer suppresses repeated semantic frames after first emission" {
    const alloc = std.testing.allocator;
    var coalescer = Coalescer{};
    defer coalescer.deinit(alloc);

    try coalescer.observe(alloc, "[!] Action Required 11s", 0);
    try coalescer.observe(alloc, "[·] Action Required 12s", 500);
    const emitted = try coalescer.takeDue(alloc, debounce_ms);
    try std.testing.expect(emitted != null);
    alloc.free(emitted.?);
    try std.testing.expectEqualStrings("[·] Action Required 12s", coalescer.lastEmittedTitle().?);

    try coalescer.observe(alloc, "[!] Action Required 13s", 1_500);
    const repeated = try coalescer.takeDue(alloc, 1_999);
    try std.testing.expect(repeated == null);
}

test "coalescer heartbeats changing semantic spinner frames inside gxserver working window" {
    const alloc = std.testing.allocator;
    var coalescer = Coalescer{};
    defer coalescer.deinit(alloc);

    try coalescer.observe(alloc, "⠋ Codex Working", 0);
    const emitted = try coalescer.takeDue(alloc, debounce_ms);
    try std.testing.expect(emitted != null);
    alloc.free(emitted.?);
    try std.testing.expectEqualStrings("⠋ Codex Working", coalescer.lastEmittedTitle().?);

    try coalescer.observe(alloc, "⠙ Codex Working", 1_100);
    try std.testing.expectEqual(@as(i32, 1_900), coalescer.pollTimeoutMs(1_100));
    const early = try coalescer.takeDue(alloc, semantic_heartbeat_ms + debounce_ms - 1);
    try std.testing.expect(early == null);

    const heartbeat = try coalescer.takeDue(alloc, semantic_heartbeat_ms + debounce_ms);
    try std.testing.expect(heartbeat != null);
    defer alloc.free(heartbeat.?);
    try std.testing.expectEqualStrings("⠙ Codex Working", heartbeat.?);
}

test "coalescer does not heartbeat unchanged raw title" {
    const alloc = std.testing.allocator;
    var coalescer = Coalescer{};
    defer coalescer.deinit(alloc);

    try coalescer.observe(alloc, "⠋ Codex Working", 0);
    const emitted = try coalescer.takeDue(alloc, debounce_ms);
    try std.testing.expect(emitted != null);
    alloc.free(emitted.?);

    try coalescer.observe(alloc, "⠋ Codex Working", 1_100);
    try std.testing.expectEqual(@as(i32, -1), coalescer.pollTimeoutMs(max_settle_ms));
    const repeated = try coalescer.takeDue(alloc, max_settle_ms);
    try std.testing.expect(repeated == null);
}

test "coalescer notifies when a semantic burst settles back to the previous title" {
    const alloc = std.testing.allocator;
    var coalescer = Coalescer{};
    defer coalescer.deinit(alloc);

    try coalescer.observe(alloc, "ghostex", 0);
    const initial = try coalescer.takeDue(alloc, debounce_ms);
    try std.testing.expect(initial != null);
    alloc.free(initial.?);

    try coalescer.observe(alloc, "Fix Command Pane Titles", 1_100);
    try coalescer.observe(alloc, "ghostex", 1_200);
    const settled = try coalescer.takeDue(alloc, 1_200 + debounce_ms);
    try std.testing.expect(settled != null);
    defer alloc.free(settled.?);
    try std.testing.expectEqualStrings("ghostex", settled.?);
}

test "semantic signature ignores cursor working dot animation" {
    const alloc = std.testing.allocator;
    const left = try createSemanticSignature(alloc, "Build agent - ⏳ Working .");
    defer alloc.free(left);
    const right = try createSemanticSignature(alloc, "Build agent - ⏳ Working ...");
    defer alloc.free(right);
    try std.testing.expectEqualStrings(left, right);
}
