//! Semantic replay of retained static Kitty graphics on fresh attachment.
//! Pixels and placement geometry come from Ghostty, never escape history.
//! Ordinary pins are placed while their history row is still addressable;
//! visible and virtual placements follow the grid. Every command uses q=2.
//!
//! Animated, relative, numbered and implicit-ID assets are not reconstructed:
//! the protocol cannot restore their full state/aliases with an explicit ID.
//! Refresh clears only text (ED0), preserving the client's live image storage.
//! wmx's vt100 parser retains no equivalent image state.
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const wuffs = @import("wuffs");
const graphics = ghostty_vt.kitty.graphics;
const ImageStorage = graphics.ImageStorage;
const max_side = 4096;
const max_pixels = 4 * 1024 * 1024;
const max_png_bytes = 16 * 1024 * 1024;
const screen_budget = 16 * 1024 * 1024;
const max_entries = 4096;
const raw_chunk_len = 3072; // exactly 4096 base64 bytes

const Asset = struct {
    image: *const graphics.Image,
    pixels: []const u8,
    priority: u8 = 2, // active/virtual, then history, then unplaced
    selected: bool = true,
    fn byId(_: void, a: Asset, b: Asset) bool {
        return a.image.id < b.image.id;
    }
    fn byPriority(_: void, a: Asset, b: Asset) bool {
        if (a.priority != b.priority) return a.priority < b.priority;
        return byId({}, a, b);
    }
};
const Entry = struct {
    key: ImageStorage.PlacementKey,
    placement: ImageStorage.Placement,
    row: ?u32,
    col: u16 = 0,
    fn lessThan(_: void, a: Entry, b: Entry) bool {
        const ar = a.row orelse std.math.maxInt(u32);
        const br = b.row orelse std.math.maxInt(u32);
        if (ar != br) return ar < br;
        if (a.col != b.col) return a.col < b.col;
        if (a.key.image_id != b.key.image_id) return a.key.image_id < b.key.image_id;
        return a.key.placement_id.preferredOver(b.key.placement_id);
    }
};

/// A bounded, borrowed view used only during synchronous serialization.
/// No terminal mutation or borrowed pixel/pin escapes this snapshot.
pub const Replay = struct {
    alloc: std.mem.Allocator,
    screen: *const ghostty_vt.Screen,
    active_row: u32,
    assets: std.ArrayList(Asset) = .empty,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(alloc: std.mem.Allocator, screen: *const ghostty_vt.Screen) std.mem.Allocator.Error!Replay {
        var self: Replay = .{ .alloc = alloc, .screen = screen, .active_row = screen.pages.pointFromPin(.screen, screen.pages.getTopLeft(.active)).?.screen.y };
        errdefer self.deinit();
        var images = screen.kitty_images.images.iterator();
        while (images.next()) |kv| {
            const pixels = replayablePixels(kv.value_ptr) orelse continue;
            if (self.assets.items.len == max_entries) {
                self.deinit();
                return .{ .alloc = alloc, .screen = screen, .active_row = self.active_row };
            }
            try self.assets.append(alloc, .{ .image = kv.value_ptr, .pixels = pixels });
        }
        std.mem.sort(Asset, self.assets.items, {}, Asset.byId);
        var placement_iter = screen.kitty_images.placements.iterator();
        while (placement_iter.next()) |kv| {
            const asset = self.findAsset(kv.key_ptr.image_id) orelse continue;
            var row: ?u32 = null;
            var col: u16 = 0;
            switch (kv.value_ptr.location) {
                .virtual => asset.priority = 0,
                .pin => |pin| {
                    if (pin.garbage) continue;
                    const point = screen.pages.pointFromPin(.screen, pin.*) orelse continue;
                    row = point.screen.y;
                    col = point.screen.x;
                    asset.priority = @min(asset.priority, if (row.? >= self.active_row) @as(u8, 0) else 1);
                },
                .relative => continue,
            }
            if (self.entries.items.len == max_entries) {
                self.deinit();
                return .{ .alloc = alloc, .screen = screen, .active_row = self.active_row };
            }
            try self.entries.append(alloc, .{ .key = kv.key_ptr.*, .placement = kv.value_ptr.*, .row = row, .col = col });
        }
        std.mem.sort(Asset, self.assets.items, {}, Asset.byPriority);
        var budget: usize = screen_budget;
        for (self.assets.items) |*asset_| {
            asset_.selected = asset_.pixels.len <= budget;
            if (asset_.selected) budget -= asset_.pixels.len;
        }
        std.mem.sort(Asset, self.assets.items, {}, Asset.byId);
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.findAsset(self.entries.items[i].key.image_id).?.selected) _ = self.entries.swapRemove(i);
        }
        std.mem.sort(Entry, self.entries.items, {}, Entry.lessThan);
        return self;
    }

    pub fn deinit(self: *Replay) void {
        self.assets.deinit(self.alloc);
        self.entries.deinit(self.alloc);
    }

    fn findAsset(self: *Replay, id: u32) ?*Asset {
        var lo: usize = 0;
        var hi = self.assets.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const item = &self.assets.items[mid];
            if (item.image.id == id) return item;
            if (item.image.id < id) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    pub fn transmit(self: *const Replay, writer: *std.Io.Writer) !void {
        for (self.assets.items) |asset_| if (asset_.selected) try writeTransmit(writer, asset_.image, asset_.pixels);
    }

    /// Return how many rows were advanced past the final history row.
    /// Split at anchors and erased soft-wrap continuations. The formatter trims
    /// blank rows, so explicitly reach each final physical row. The same path
    /// handles text-only history without a second, less precise formatter.
    pub fn history(self: *const Replay, writer: *std.Io.Writer) !u1 {
        std.debug.assert(self.active_row > 0);
        const pages = &self.screen.pages;
        var start: u32 = 0;
        var i: usize = 0;
        var row: u32 = 0;
        const last = pages.pin(.{ .screen = .{ .x = 0, .y = self.active_row - 1 } }).?;
        var rows = pages.getTopLeft(.screen).rowIterator(.right_down, last);
        while (rows.next()) |pin| : (row += 1) {
            const next = if (row < self.active_row - 1) pin.down(1) else null;
            const erased_wrap = pin.rowAndCell().row.wrap and next != null and
                !@TypeOf(pin.cells(.right)[0]).hasTextAny(next.?.cells(.right));
            const anchored = i < self.entries.items.len and self.entries.items[i].row == row;
            if (!anchored and !erased_wrap) continue;
            try self.historySegment(writer, start, row);
            while (i < self.entries.items.len and self.entries.items[i].row == row) : (i += 1) {
                const entry = self.entries.items[i];
                // Save includes pending wrap; CR and CUF do not rewrap text.
                try writer.writeAll("\x1b7\r");
                if (entry.col != 0) try writer.print("\x1b[{d}C", .{entry.col});
                try writePlacement(writer, entry);
                try writer.writeAll("\x1b8");
            }
            if (row == self.active_row - 1) return try self.finishHistory(writer);
            if (!pin.rowAndCell().row.wrap) {
                try writer.writeAll("\r\n");
            } else if (erased_wrap) {
                // An erased continuation has no text to trigger autowrap.
                try advanceWrappedRow(writer, pin);
            }
            start = row + 1;
        }
        if (start < self.active_row) try self.historySegment(writer, start, self.active_row - 1);
        return try self.finishHistory(writer);
    }

    fn finishHistory(self: *const Replay, writer: *std.Io.Writer) !u1 {
        const last = self.screen.pages.pin(.{ .screen = .{ .x = 0, .y = self.active_row - 1 } }).?;
        if (!last.rowAndCell().row.wrap) return 0;
        // The caller flushes the remaining viewport before repainting it.
        // Trigger this last soft wrap first, and count that advance once.
        try advanceWrappedRow(writer, last);
        return 1;
    }

    fn historySegment(self: *const Replay, writer: *std.Io.Writer, start: u32, end: u32) !void {
        const pages = &self.screen.pages;
        const top = pages.pin(.{ .screen = .{ .x = 0, .y = start } }).?;
        var bottom = pages.pin(.{ .screen = .{ .x = @intCast(pages.cols - 1), .y = end } }).?;
        // An unwrapped selection ending on a spacer head includes the wide
        // character from the next row. Keep that character in the next segment
        // so this row's image anchor is emitted before the cursor wraps.
        if (bottom.rowAndCell().cell.wide == .spacer_head and bottom.x > 0) bottom.x -= 1;
        var fmt = ghostty_vt.formatter.ScreenFormatter.init(self.screen, .vt);
        fmt.opts.unwrap = true;
        fmt.content = .{ .selection = ghostty_vt.Selection.init(top, bottom, false) };
        try fmt.format(writer);
        var last_text: ?u32 = null;
        var row = start;
        var rows = top.rowIterator(.right_down, bottom);
        while (rows.next()) |pin| {
            const cells = pin.cells(.right);
            if (@TypeOf(cells[0]).hasTextAny(cells)) last_text = row;
            row += 1;
        }
        const blanks = end - (last_text orelse start);
        for (0..blanks) |_| try writer.writeAll("\r\n");
        const final = bottom.rowAndCell();
        if (final.row.wrap) {
            // Trim short hard lines as before, but reach the edge on this
            // final soft-wrapped row. VT already emits literal/styled spaces;
            // only unstyled empty cells are omitted. A wide tail already
            // reached the edge when its head was printed.
            const cells = bottom.cells(.all);
            const edge = cells.len - @as(usize, @intFromBool(cells[cells.len - 1].wide == .spacer_head));
            var tail = edge;
            while (tail > 0 and cells[tail - 1].wide == .narrow and
                cells[tail - 1].content_tag == .codepoint and
                cells[tail - 1].codepoint() == 0 and cells[tail - 1].style_id == 0) tail -= 1;
            try writer.splatByteAll(' ', edge - tail);
        }
    }

    pub fn placements(self: *const Replay, writer: *std.Io.Writer) !void {
        for (self.entries.items) |entry| {
            if (entry.row) |row| {
                if (row < self.active_row) continue; // already anchored in history
                try writer.print("\x1b7\x1b[?6l\x1b[{d};{d}H", .{ row - self.active_row + 1, @as(u32, entry.col) + 1 });
                try writePlacement(writer, entry);
                try writer.writeAll("\x1b8");
            } else try writePlacement(writer, entry);
        }
    }
};

fn advanceWrappedRow(writer: *std.Io.Writer, pin: ghostty_vt.PageList.Pin) !void {
    const cells = pin.cells(.all);
    // A spacer head needs a wide character to wrap from the penultimate
    // column. Erase the temporary character after reaching the next row.
    try writer.writeAll(if (cells[cells.len - 1].wide == .spacer_head) "\xe3\x80\x80\r\x1b[2K" else " \r\x1b[2K");
}

fn replayablePixels(image: *const graphics.Image) ?[]const u8 {
    if (image.metadata.implicit_id or image.number != 0 or image.animation != null) return null;
    const bpp: usize = switch (image.format) {
        .rgb => 3,
        .rgba => 4,
        else => return null,
    };
    if (image.width == 0 or image.height == 0 or image.width > max_side or image.height > max_side) return null;
    const count = @as(usize, image.width) * image.height;
    if (count > max_pixels) return null;
    const data = image.data.bytes() orelse return null;
    if (data.len != count * bpp) return null;
    return data;
}
fn writeTransmit(writer: *std.Io.Writer, image: *const graphics.Image, pixels: []const u8) !void {
    const format: u32 = if (image.format == .rgb) 24 else 32;
    var buf: [4096]u8 = undefined;
    var offset: usize = 0;
    while (true) {
        const end = @min(offset + raw_chunk_len, pixels.len);
        const more: u1 = @intFromBool(end < pixels.len);
        if (offset == 0) try writer.print("\x1b_Ga=t,f={d},s={d},v={d},i={d},q=2,m={d};", .{ format, image.width, image.height, image.id, more }) else try writer.print("\x1b_Gm={d},q=2;", .{more});
        try writer.writeAll(std.base64.standard.Encoder.encode(&buf, pixels[offset..end]));
        try writer.writeAll("\x1b\\");
        if (more == 0) return;
        offset = end;
    }
}
fn writePlacement(writer: *std.Io.Writer, entry: Entry) !void {
    const p = entry.placement;
    try writer.print("\x1b_Ga=p,i={d}", .{entry.key.image_id});
    if (p.location == .virtual) try writer.writeAll(",U=1");
    if (entry.key.placement_id.tag == .external) try writer.print(",p={d}", .{entry.key.placement_id.id});
    try writer.print(",c={d},r={d},x={d},y={d},w={d},h={d},X={d},Y={d},z={d},C=1,q=2\x1b\\", .{ p.columns, p.rows, p.source_x, p.source_y, p.source_width, p.source_height, p.x_offset, p.y_offset, p.z });
}

/// PNG decoder registered with ghostty-vt at startup, backed by the Wuffs
/// module Ghostty pins. The IHDR is checked before Wuffs allocates anything so
/// an oversized image is refused from its header alone; Wuffs still validates
/// the whole stream.
pub fn decodePng(
    alloc: std.mem.Allocator,
    data: []const u8,
) ghostty_vt.sys.DecodeError!ghostty_vt.sys.Image {
    if (!pngHeaderWithinLimits(data)) return error.InvalidData;
    const result = wuffs.png.decode(alloc, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
    return .{ .width = result.width, .height = result.height, .data = result.data };
}

fn pngHeaderWithinLimits(data: []const u8) bool {
    const signature = "\x89PNG\r\n\x1a\n";
    // Signature, then IHDR's length, type, 13 data bytes and CRC.
    if (data.len < signature.len + 4 + 4 + 13 + 4 or data.len > max_png_bytes) return false;
    if (!std.mem.eql(u8, data[0..8], signature)) return false;
    if (std.mem.readInt(u32, data[8..12], .big) != 13) return false;
    if (!std.mem.eql(u8, data[12..16], "IHDR")) return false;
    const width = std.mem.readInt(u32, data[16..20], .big);
    const height = std.mem.readInt(u32, data[20..24], .big);
    if (width == 0 or height == 0 or width > max_side or height > max_side) return false;
    return @as(u64, width) * height <= max_pixels;
}
