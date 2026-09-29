const std = @import("std");
const sys = @import("sys");
const windowing = @import("../../root.zig");
const window = @import("root.zig");

const WaylandBackend = window.WaylandBackend;

test "live Wayland window configures and presents shared memory" {
    if (comptime sys.capabilities.current.os != .linux) return error.SkipZigTest;
    if (sys.env.get("WAYLAND_DISPLAY") == null and sys.env.get("WAYLAND_SOCKET") == null) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend: WaylandBackend = undefined;
    try backend.init(allocator, .{
        .title = "windowing-wayland-live",
        .app_id = "tiny.windowing.live-test",
        .width = 64,
        .height = 32,
        .backend = .wayland,
    });
    defer backend.deinit();

    const Frame = struct {
        fn present(
            target: *WaylandBackend,
            frame_allocator: std.mem.Allocator,
            rgba8: *std.ArrayList(u8),
            framebuffer: windowing.Size,
        ) !void {
            const pixel_count = std.math.mul(usize, framebuffer.width, framebuffer.height) catch unreachable;
            const byte_len = std.math.mul(usize, pixel_count, 4) catch unreachable;
            try rgba8.resize(frame_allocator, byte_len);
            var offset: usize = 0;
            while (offset < rgba8.items.len) : (offset += 4) {
                rgba8.items[offset] = 0x20;
                rgba8.items[offset + 1] = 0x80;
                rgba8.items[offset + 2] = 0xe0;
                rgba8.items[offset + 3] = 0xff;
            }
            try target.presentRgba8(
                rgba8.items,
                framebuffer.width,
                framebuffer.height,
            );
        }
    };

    var rgba8: std.ArrayList(u8) = .empty;
    defer rgba8.deinit(allocator);
    var committed = backend.getFramebufferSize();
    try Frame.present(&backend, allocator, &rgba8, committed);
    try std.testing.expect(backend.toplevel.configured);
    try std.testing.expect(backend.toplevel.server_decorated);

    if (backend.presentationStatus() == .unavailable) {
        _ = try backend.pollEvents();
        return;
    }
    try std.testing.expectEqual(windowing.presentation.Status.active, backend.presentationStatus());
    try std.testing.expect(backend.presenter.timing.?.clockId() != null);

    const first_frame_deadline = sys.time.nanoTimestamp() + 250 * std.time.ns_per_ms;
    while (!backend.presenter.frame_ready and sys.time.nanoTimestamp() < first_frame_deadline) {
        _ = try backend.pollEvents();
        if (!backend.presenter.frame_ready) sys.time.sleepMilliseconds(1);
    }
    try std.testing.expect(backend.presenter.frame_ready);

    committed = backend.getFramebufferSize();
    try Frame.present(&backend, allocator, &rgba8, committed);

    var terminal: ?windowing.presentation.Outcome = null;
    const deadline = sys.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (terminal == null and sys.time.nanoTimestamp() < deadline) {
        _ = try backend.pollEvents();
        const current = backend.getFramebufferSize();
        if (current.width != committed.width or current.height != committed.height) {
            try Frame.present(&backend, allocator, &rgba8, current);
            committed = current;
        }
        while (backend.nextPresentationOutcome()) |outcome| {
            switch (outcome) {
                .presented => |value| {
                    if (value.submission.id >= 2) terminal = outcome;
                },
                .discarded, .unknown => {},
            }
        }
        if (terminal == null) sys.time.sleepMilliseconds(1);
    }

    try std.testing.expectEqual(windowing.presentation.Status.active, backend.presentationStatus());
    switch (terminal orelse return error.TestUnexpectedResult) {
        .presented => |value| {
            try std.testing.expect(value.latencyNanoseconds() != null);
            if (sys.env.getConstant("XDG_CURRENT_DESKTOP")) |desktop| {
                if (std.mem.indexOf(u8, desktop, "COSMIC") != null) {
                    try std.testing.expect(value.refresh_nanoseconds > 0);
                }
            }
        },
        .discarded, .unknown => return error.TestUnexpectedResult,
    }
}

fn waitForFrame(backend: *WaylandBackend) !void {
    const deadline = sys.time.nanoTimestamp() + 500 * std.time.ns_per_ms;
    while (!backend.presenter.frame_ready and sys.time.nanoTimestamp() < deadline) {
        _ = try backend.pollEvents();
        if (!backend.presenter.frame_ready) sys.time.sleepMilliseconds(1);
    }
    try std.testing.expect(backend.presenter.frame_ready);
}

fn paintBase(pixels: []u8) void {
    var offset: usize = 0;
    while (offset < pixels.len) : (offset += 4) {
        pixels[offset] = 0x20;
        pixels[offset + 1] = 0x80;
        pixels[offset + 2] = 0xe0;
        pixels[offset + 3] = 0xff;
    }
}

fn paintRegion(
    pixels: []u8,
    width: u32,
    region: windowing.PresentRegion,
    shade: u8,
) void {
    var row: u32 = 0;
    while (row < region.height) : (row += 1) {
        var column: u32 = 0;
        while (column < region.width) : (column += 1) {
            const pixel = (@as(usize, region.y + row) * width + region.x + column) * 4;
            pixels[pixel] = shade;
            pixels[pixel + 1] = shade +% 0x30;
            pixels[pixel + 2] = shade +% 0x60;
            pixels[pixel + 3] = 0xff;
        }
    }
}

/// Finds the active buffer whose accumulator is empty, which after a present is
/// the buffer that present wrote and attached. The helper reads that buffer's
/// pixels back through the memory it shares with the compositor after each
/// present and compares them against the whole frame the test painted.
/// Comparing the whole frame shows that a present of one rectangle leaves the
/// rest of the buffer holding the frame, and the rewritten rectangle with it.
/// The helper fails the test when no active buffer has an empty accumulator.
fn expectAttachedFrame(
    backend: *WaylandBackend,
    frame: []const u8,
    readback: []u8,
    size: windowing.Size,
) !void {
    const storage = &backend.presenter.swapchain.?.storage;
    for (storage.working_indices[0..storage.active_buffer_count]) |index| {
        if (index == std.math.maxInt(u32)) continue;
        const slot = @as(usize, index);
        if (!storage.dirty[slot].isEmpty()) continue;
        if (storage.buffers[slot]) |*value| {
            try value.copyRegionRgba8(
                .{ .x = 0, .y = 0, .width = size.width, .height = size.height },
                readback,
            );
            try std.testing.expectEqualSlices(u8, frame, readback);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "live Wayland window presents damage regions the buffer reads back whole" {
    if (comptime sys.capabilities.current.os != .linux) return error.SkipZigTest;
    if (sys.env.get("WAYLAND_DISPLAY") == null and
        sys.env.get("WAYLAND_SOCKET") == null) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var backend: WaylandBackend = undefined;
    try backend.init(allocator, .{
        .title = "windowing-wayland-region",
        .app_id = "tiny.windowing.region-test",
        .width = 64,
        .height = 32,
        .backend = .wayland,
    });
    defer backend.deinit();

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);
    var readback: std.ArrayList(u8) = .empty;
    defer readback.deinit(allocator);
    var committed = windowing.Size{ .width = 0, .height = 0 };
    var checked: usize = 0;
    const shades = [_]u8{ 0x11, 0x44, 0x77, 0xbb };
    for (shades, 0..) |shade, step| {
        const extent = backend.getFramebufferSize();
        if (extent.width < 32 or extent.height < 16) return error.SkipZigTest;
        if (extent.width != committed.width or extent.height != committed.height) {
            const byte_len = @as(usize, extent.width) * extent.height * 4;
            try frame.resize(allocator, byte_len);
            try readback.resize(allocator, byte_len);
            paintBase(frame.items);
            committed = extent;
            try backend.presentRgba8(frame.items, extent.width, extent.height);
            try std.testing.expect(backend.toplevel.configured);
            try expectAttachedFrame(&backend, frame.items, readback.items, extent);
            try waitForFrame(&backend);
            if (backend.getFramebufferSize().width != extent.width) continue;
        }
        const region = windowing.PresentRegion{
            .x = @intCast(step * 4),
            .y = @intCast(step * 2),
            .width = 8,
            .height = 4,
        };
        paintRegion(frame.items, extent.width, region, shade);
        try backend.presentRgba8Region(frame.items, extent.width, extent.height, region);
        if (backend.presenter.pending_owed) continue;
        try expectAttachedFrame(&backend, frame.items, readback.items, extent);
        checked += 1;
        try waitForFrame(&backend);
    }
    try std.testing.expect(checked > 0);
    try std.testing.expectEqual(
        windowing.presentation.StorageStatus{},
        backend.presentationStorageStatus(),
    );
}
