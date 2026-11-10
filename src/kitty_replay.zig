//! Kitty graphics pictures in the snapshots the daemon sends its terminal clients.
//!
//! CDXC:Zmx 2026-11-10 WHY:
//! The daemon's ghostty-vt keeps every picture a program draws with the Kitty graphics protocol, but the VT formatter writes only text, so a client that attached later, skipped ahead to a resync, or got a visible refresh (whose `ED 2` deletes the pictures on screen) showed a blank gap where a picture was (GitHub #536). The snapshot now sends the pictures again: each one as deflated pixels, then its placements on the active screen and its Unicode-placeholder (virtual) placements. Pictures anchored in history, placements relative to another placement and animation frames past the first are not replayed. Every command carries `q=2`, so the client's answers never reach the program.
//! SEE-ALSO: apps/desktop/src/ghostty_vt/kitty_graphics.rs (the desktop draws them, same 320 MB limit and direct medium only).
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const graphics = ghostty_vt.kitty.graphics;

/// The desktop terminal's limit (`KITTY_IMAGE_STORAGE_LIMIT_BYTES`), so the daemon keeps the
/// pictures the client keeps instead of libghostty-vt's 10 MB library default.
pub const storage_limit: usize = 320 * 1000 * 1000;

/// libghostty-vt ships without a PNG decoder, so the daemon refused every `f=100` picture and had
/// nothing to replay. Install ghostty's own wuffs decoder once per process.
pub fn installPngDecoder() void {
    ghostty_vt.sys.decode_png = &decodePng;
}

fn decodePng(alloc: std.mem.Allocator, data: []const u8) ghostty_vt.sys.DecodeError!ghostty_vt.sys.Image {
    const result = @import("wuffs").png.decode(alloc, data) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidData;
    };
    return .{ .width = result.width, .height = result.height, .data = result.data };
}

/// What the client holds when the pictures are written.
pub const Client = enum {
    /// A fresh or reset terminal: it holds no pictures.
    fresh,
    /// A terminal whose screen was just cleared with `ED 2`: placements anchored in history and
    /// virtual placements survived, with their pictures; every other picture was deleted.
    screen_cleared,
};

/// Write the active screen's pictures and placements, after the snapshot's text and modes: the
/// modes re-enter the alternate screen with `?1049h`, which clears it, pictures included. Placing
/// moves the cursor, so it is saved and restored (DECSC/DECRC keep the position, pending wrap,
/// origin mode and charset); the formatter replays no saved cursor, so only that slot changes.
/// A picture that cannot be written (out of memory) leaves the snapshot without pictures, not
/// without its text.
pub fn write(alloc: std.mem.Allocator, writer: *std.Io.Writer, term: *ghostty_vt.Terminal, client: Client) std.Io.Writer.Error!void {
    if (term.screens.active.kitty_images.images.count() == 0) return;
    var pictures: std.Io.Writer.Allocating = .init(alloc);
    defer pictures.deinit();
    writePictures(alloc, &pictures.writer, term, client) catch |err| {
        std.log.warn("failed to replay kitty graphics err={s}", .{@errorName(err)});
        return;
    };
    try writer.writeAll(pictures.written());
}

fn writePictures(alloc: std.mem.Allocator, writer: *std.Io.Writer, term: *ghostty_vt.Terminal, client: Client) !void {
    const screen = term.screens.active;
    const storage = &screen.kitty_images;

    var saved_cursor = false;
    var image_it = storage.images.iterator();
    while (image_it.next()) |image_entry| {
        const image = image_entry.value_ptr.*;
        const pixels = image.data.bytes() orelse continue;
        if (pixels.len == 0) continue;

        var replayed: usize = 0;
        var survives = false;
        var placement_it = storage.placements.iterator();
        while (placement_it.next()) |entry| {
            if (entry.key_ptr.image_id != image.id) continue;
            switch (placementFate(term, image, entry.value_ptr.*, client)) {
                .replay => replayed += 1,
                .survives => survives = true,
                .lost => {},
            }
        }
        // A picture sent without placements can still be placed by id later; one sent without an
        // id cannot be addressed at all.
        const unplaced = image.metadata.placement_count == 0 and !image.metadata.implicit_id;
        if (replayed == 0 and !unplaced) continue;

        if (!survives) try writeTransmit(alloc, writer, image, pixels);

        placement_it = storage.placements.iterator();
        while (placement_it.next()) |entry| {
            if (entry.key_ptr.image_id != image.id) continue;
            const placement = entry.value_ptr.*;
            if (placementFate(term, image, placement, client) != .replay) continue;
            const external_id: ?u32 = switch (entry.key_ptr.placement_id.tag) {
                .external => entry.key_ptr.placement_id.id,
                .internal => null,
            };
            switch (placement.location) {
                .pin => |pin| {
                    const pt = screen.pages.pointFromPin(.active, pin.*) orelse continue;
                    if (!saved_cursor) {
                        try writer.writeAll("\x1b7");
                        // CUP counts from the scrolling region in origin mode; DECRC turns it back on.
                        if (term.modes.get(.origin)) try writer.writeAll("\x1b[?6l");
                        saved_cursor = true;
                    }
                    try writer.print("\x1b[{d};{d}H", .{ pt.active.y + 1, pt.active.x + 1 });
                    try writePlace(writer, image.id, external_id, placement, false);
                },
                .virtual => try writePlace(writer, image.id, external_id, placement, true),
                .relative => {},
            }
        }
    }
    if (saved_cursor) try writer.writeAll("\x1b8");
}

const Fate = enum { replay, survives, lost };

fn placementFate(term: *ghostty_vt.Terminal, image: graphics.Image, placement: graphics.ImageStorage.Placement, client: Client) Fate {
    const pages = &term.screens.active.pages;
    return switch (placement.location) {
        .pin => |pin| {
            if (pin.garbage) return .lost;
            if (pages.pointFromPin(.active, pin.*) != null) return .replay;
            if (client == .fresh) return .lost;
            // `ED 2` keeps a history placement only when none of it reaches the active area.
            const rect = placement.rect(image, term) orelse return .survives;
            return if (pages.pointFromPin(.active, rect.bottom_right) == null) .survives else .lost;
        },
        .virtual => if (client == .fresh) .replay else .survives,
        // `ED 2` removes a relative placement with an on-screen parent, so it keeps no picture.
        .relative => .lost,
    };
}

/// Base64 bytes per transmission chunk; the protocol allows at most 4096.
const chunk_b64_len = 4096;
const chunk_raw_len = chunk_b64_len / 4 * 3;

/// The picture's pixels, deflated (`o=z`): the store keeps them decoded, and a PNG sent as a few
/// hundred bytes is otherwise resent as width × height × 4.
fn writeTransmit(alloc: std.mem.Allocator, writer: *std.Io.Writer, image: graphics.Image, pixels: []const u8) !void {
    // The protocol carries only RGB and RGBA; a grayscale picture is widened.
    const in_channels: usize, const out_channels: usize, const format: u8 = switch (image.format) {
        .rgb => .{ 3, 3, 24 },
        .rgba => .{ 4, 4, 32 },
        .gray => .{ 1, 3, 24 },
        .gray_alpha => .{ 2, 4, 32 },
        .png => return,
    };

    var deflated: std.Io.Writer.Allocating = try .initCapacity(alloc, pixels.len / 8 + 64);
    defer deflated.deinit();
    {
        const flate = std.compress.flate;
        const window = try alloc.alloc(u8, flate.max_window_len);
        defer alloc.free(window);
        const compress = try alloc.create(flate.Compress);
        defer alloc.destroy(compress);
        compress.* = try .init(&deflated.writer, window, .zlib, .fastest);
        if (in_channels == out_channels) {
            try compress.writer.writeAll(pixels[0 .. pixels.len / in_channels * in_channels]);
        } else {
            var widened: [chunk_raw_len]u8 = undefined;
            var len: usize = 0;
            for (0..pixels.len / in_channels) |i| {
                const px = pixels[i * in_channels ..][0..in_channels];
                @memset(widened[len..][0..3], px[0]);
                if (out_channels == 4) widened[len + 3] = px[1];
                len += out_channels;
                if (len == widened.len) {
                    try compress.writer.writeAll(&widened);
                    len = 0;
                }
            }
            try compress.writer.writeAll(widened[0..len]);
        }
        try compress.finish();
    }

    const data = deflated.written();
    var b64: [chunk_b64_len]u8 = undefined;
    var offset: usize = 0;
    while (offset < data.len) {
        const chunk = data[offset..@min(offset + chunk_raw_len, data.len)];
        offset += chunk.len;
        const more: u8 = if (offset < data.len) 1 else 0;
        if (chunk.ptr == data.ptr) {
            try writer.print("\x1b_Ga=t,t=d,o=z,q=2,f={d},s={d},v={d},i={d},m={d};", .{
                format, image.width, image.height, image.id, more,
            });
        } else {
            try writer.print("\x1b_Gq=2,m={d};", .{more});
        }
        try writer.writeAll(std.base64.standard.Encoder.encode(&b64, chunk));
        try writer.writeAll("\x1b\\");
    }
}

fn writePlace(
    writer: *std.Io.Writer,
    image_id: u32,
    placement_id: ?u32,
    placement: graphics.ImageStorage.Placement,
    virtual: bool,
) !void {
    try writer.print("\x1b_Ga=p,q=2,i={d}", .{image_id});
    if (placement_id) |id| try writer.print(",p={d}", .{id});
    if (virtual) {
        try writer.writeAll(",U=1");
    } else {
        try writer.writeAll(",C=1");
        try writeField(writer, 'x', placement.source_x);
        try writeField(writer, 'y', placement.source_y);
        try writeField(writer, 'w', placement.source_width);
        try writeField(writer, 'h', placement.source_height);
        try writeField(writer, 'X', placement.x_offset);
        try writeField(writer, 'Y', placement.y_offset);
        if (placement.z != 0) try writer.print(",z={d}", .{placement.z});
    }
    try writeField(writer, 'c', placement.columns);
    try writeField(writer, 'r', placement.rows);
    try writer.writeAll("\x1b\\");
}

fn writeField(writer: *std.Io.Writer, key: u8, value: u32) !void {
    if (value != 0) try writer.print(",{c}={d}", .{ key, value });
}
