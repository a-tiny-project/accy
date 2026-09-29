const std = @import("std");
const windowing = @import("../../root.zig");
const wayland = @import("../root.zig");

const present = @import("root.zig");
const support = @import("support.zig");

const damage = present.damage;
const toplevel = wayland.toplevel;
const Presenter = present.Presenter;
const swapchainPresentError = support.swapchainPresentError;

const live_width: u32 = 64;
const live_height: u32 = 32;
const live_bytes: usize = live_width * live_height * 4;

fn visibleTarget(width: u32, height: u32) toplevel.Target {
    return .{
        .surface = 10,
        .viewport = null,
        .logical = .{ .width = width, .height = height },
        .framebuffer = .{ .width = width, .height = height },
        .scale_state = .{},
        .generation = 3,
        .visible = true,
    };
}

fn expectOwed(expected: []const windowing.PresentRegion, owed: *const damage.Region) !void {
    try std.testing.expectEqualSlices(windowing.PresentRegion, expected, owed.slice());
}

test "swapchain retirement exhaustion remains a typed presentation error" {
    try std.testing.expectEqual(
        error.CapacityExceeded,
        swapchainPresentError(error.RetiredCapacityExceeded),
    );
}

test "pending frame storage admits its exact bound and rejects max plus one" {
    const frames = try windowing.presentation.Capacity.derive(.{
        .retained_frame_byte_count = 16,
    });
    var presenter = try Presenter.init(std.testing.allocator, frames);
    defer presenter.deinit();
    try std.testing.expect(support.admitFrame(16, presenter.frame.bytes.len, &presenter.frame_capacity_rejection_count));
    try std.testing.expect(!support.admitFrame(17, presenter.frame.bytes.len, &presenter.frame_capacity_rejection_count));
    try std.testing.expectEqual(@as(u64, 1), presenter.frame_capacity_rejection_count);
    presenter.frame_capacity_rejection_count = std.math.maxInt(u64);
    try std.testing.expect(!support.admitFrame(17, presenter.frame.bytes.len, &presenter.frame_capacity_rejection_count));
    try std.testing.expectEqual(std.math.maxInt(u64), presenter.frame_capacity_rejection_count);
}

test "pending frame storage reports acquisition failure" {
    const frames = try windowing.presentation.Capacity.derive(.{
        .retained_frame_byte_count = 16,
    });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(error.OutOfMemory, Presenter.init(failing.allocator(), frames));
}

test "hidden targets never reach the content attachment path" {
    var presenter = Presenter{};
    const hidden = toplevel.Target{
        .surface = 10,
        .viewport = null,
        .logical = .{ .width = 64, .height = 32 },
        .framebuffer = .{ .width = 64, .height = 32 },
        .scale_state = .{},
        .generation = 0,
        .visible = false,
    };
    try presenter.present(hidden, &.{}, 0, 0, .{});
    try std.testing.expect(presenter.frame_callback == null);
}

test "a present owes its damage before the attachment path can consume it" {
    const frames = try windowing.presentation.Capacity.derive(.{
        .retained_frame_byte_count = live_bytes,
    });
    var presenter = try Presenter.init(std.testing.allocator, frames);
    defer presenter.deinit();

    const pixels = @as([live_bytes]u8, @splat(0x40));
    try std.testing.expectError(error.Unexpected, presenter.present(
        visibleTarget(live_width, live_height),
        &pixels,
        live_width,
        live_height,
        .{ .x = 4, .y = 4, .width = 8, .height = 8 },
    ));
    try std.testing.expect(!presenter.frame.isCurrent());
    const whole = windowing.PresentRegion.full(live_width, live_height);
    try expectOwed(&.{whole}, &presenter.frame.dirty);
    try expectOwed(&.{whole}, &presenter.surface_dirty);
    try std.testing.expect(!presenter.pending_owed);
}

test "a new framebuffer extent stales every retained byte" {
    const frames = try windowing.presentation.Capacity.derive(.{
        .retained_frame_byte_count = live_bytes,
    });
    var presenter = try Presenter.init(std.testing.allocator, frames);
    defer presenter.deinit();

    const pixels = @as([live_bytes]u8, @splat(0x11));
    presenter.present(
        visibleTarget(live_width, live_height),
        &pixels,
        live_width,
        live_height,
        .{ .x = 0, .y = 0, .width = 4, .height = 4 },
    ) catch {};
    presenter.frame.refresh(&pixels);
    try std.testing.expect(presenter.frame.isCurrent());

    const half_width = live_width / 2;
    const half_height = live_height / 2;
    presenter.present(
        visibleTarget(half_width, half_height),
        pixels[0 .. half_width * half_height * 4],
        half_width,
        half_height,
        .{ .x = 1, .y = 1, .width = 2, .height = 2 },
    ) catch {};
    try expectOwed(
        &.{windowing.PresentRegion.full(half_width, half_height)},
        &presenter.frame.dirty,
    );
    try std.testing.expectEqual(@as(usize, 0), presenter.frame.contents().len);
}

test "the surface owes the union of every region presented since its commit" {
    const frames = try windowing.presentation.Capacity.derive(.{
        .retained_frame_byte_count = live_bytes,
    });
    var presenter = try Presenter.init(std.testing.allocator, frames);
    defer presenter.deinit();
    const pixels = @as([live_bytes]u8, @splat(0x55));
    const target = visibleTarget(live_width, live_height);
    presenter.present(target, &pixels, live_width, live_height, .{
        .x = 0,
        .y = 0,
        .width = 4,
        .height = 4,
    }) catch {};
    presenter.surface_dirty.clear();
    presenter.frame.refresh(&pixels);

    const near = windowing.PresentRegion{ .x = 2, .y = 2, .width = 2, .height = 2 };
    const far = windowing.PresentRegion{ .x = 40, .y = 20, .width = 6, .height = 6 };
    presenter.present(target, &pixels, live_width, live_height, near) catch {};
    presenter.present(target, &pixels, live_width, live_height, far) catch {};
    try expectOwed(&.{ near, far }, &presenter.surface_dirty);
}

fn spacedPixel(index: usize) windowing.PresentRegion {
    std.debug.assert(index < damage.max_rects);
    return .{
        .x = @intCast(2 * (index % 8)),
        .y = @intCast(2 * (index / 8)),
        .width = 1,
        .height = 1,
    };
}

test "a present past forty eight disjoint regions counts one damage collapse" {
    const frames = try windowing.presentation.Capacity.derive(.{
        .retained_frame_byte_count = live_bytes,
    });
    var presenter = try Presenter.init(std.testing.allocator, frames);
    defer presenter.deinit();
    const pixels = @as([live_bytes]u8, @splat(0x66));
    const target = visibleTarget(live_width, live_height);
    try std.testing.expectError(error.Unexpected, presenter.present(
        target,
        &pixels,
        live_width,
        live_height,
        spacedPixel(0),
    ));
    presenter.surface_dirty.clear();
    presenter.frame.refresh(&pixels);

    for (0..damage.max_rects) |index| {
        try std.testing.expectError(error.Unexpected, presenter.present(
            target,
            &pixels,
            live_width,
            live_height,
            spacedPixel(index),
        ));
    }
    try std.testing.expectEqual(damage.max_rects, presenter.surface_dirty.slice().len);
    try std.testing.expectEqual(damage.max_rects, presenter.frame.dirty.slice().len);
    const listed = presenter.presentationStorageStatus();
    try std.testing.expectEqual(@as(u64, 0), listed.damage_capacity_collapse_count);

    const outside = windowing.PresentRegion{ .x = 40, .y = 20, .width = 3, .height = 2 };
    try std.testing.expectError(error.Unexpected, presenter.present(
        target,
        &pixels,
        live_width,
        live_height,
        outside,
    ));
    const spanning = windowing.PresentRegion.full(43, 22);
    try expectOwed(&.{spanning}, &presenter.surface_dirty);
    try expectOwed(&.{spanning}, &presenter.frame.dirty);
    const collapsed = presenter.presentationStorageStatus();
    try std.testing.expectEqual(@as(u64, 1), collapsed.damage_capacity_collapse_count);
}

const WireSink = struct {
    client: @import("wayland").runtime.Client = undefined,
    server: @import("wayland").Transport = undefined,
    presenter: Presenter = undefined,
    target: toplevel.Target = undefined,
    flushes: usize = 0,
    commits: usize = 0,
    attached: u32 = 0,

    fn init(self: *WireSink) !void {
        const native = @import("wayland");
        const sys = @import("sys");
        const sockets = try sys.fd.socketPairUnixStream(.{ .close_on_exec = true });
        self.client = try native.runtime.Client.initOwned(std.testing.allocator, sockets[0], try native.runtime.Capacity.derive(.{}));
        errdefer self.client.deinit();
        self.server = try native.Transport.initOwned(std.testing.allocator, sockets[1], try native.TransportCapacity.derive(.{}));
        errdefer self.server.deinit();
        const surface_id = try self.addObject("wl_surface", 6);
        const shm_id = try self.addObject("wl_shm", 1);
        const timing_id = try self.addObject("wp_presentation", 1);
        const capacity = try wayland.presentation.Capacity.derive(.{ .retained_frame_byte_count = 64 });
        self.presenter = try Presenter.init(std.testing.allocator, capacity.frames);
        errdefer self.presenter.deinit();
        try self.presenter.open(&self.client, timing_id, capacity, .{ .context = self, .flush = flush });
        self.presenter.timing.?.state.clock_id = sys.time.awake_clock_id;
        self.presenter.configure(shm_id, .abgr8888);
        self.target = visibleTarget(4, 4);
        self.target.surface = surface_id;
    }

    fn deinit(self: *WireSink) void {
        self.presenter.deinit();
        self.client.deinit();
        self.server.deinit();
    }

    fn addObject(self: *WireSink, name: []const u8, version: u32) !u32 {
        const id = try self.client.ids.allocate();
        try self.client.objects.addClient(id, try self.client.catalog.require(name), version);
        return id;
    }

    fn flush(context: *anyopaque) void {
        const self: *WireSink = @ptrCast(@alignCast(context));
        self.flushes += 1;
    }

    fn receive(self: *WireSink) !void {
        const core = @import("wayland").protocol.core;
        _ = try self.client.flush();
        while (try self.server.receive() == .data) {}
        while (try self.server.inbox.peek()) |frame| {
            if (frame.header.object_id == self.target.surface) {
                if (frame.header.opcode == core.wl_surface.requests.commit.opcode) self.commits += 1;
                if (frame.header.opcode == core.wl_surface.requests.attach.opcode) {
                    self.attached = std.mem.readInt(u32, frame.payload[0..4], .little);
                }
            }
            try self.server.inbox.consume();
        }
        while (self.server.inbox.takeDescriptor()) |descriptor| @import("sys").fd.close(descriptor);
    }

    fn expectPixels(self: *WireSink, expected: []const u8) !void {
        for (self.presenter.swapchain.?.storage.buffers) |slot| {
            if (slot) |value| {
                if (value.object_id != self.attached) continue;
                try std.testing.expectEqualSlices(u8, expected, value.mapping[0..value.byte_len]);
                return;
            }
        }
        return error.TestUnexpectedResult;
    }
};

test "Wayland multi-region acceptance stages identity and commits latest pixels once" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    var sink = WireSink{};
    try sink.init();
    defer sink.deinit();
    var pixels: [64]u8 = @splat(0x11);
    const first = try sink.presenter.presentFrame(sink.target, &pixels, 4, 4, &.{});
    try std.testing.expectEqual(@as(u64, 1), first);
    try sink.receive();
    try std.testing.expectEqual(@as(usize, 1), sink.commits);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    try sink.expectPixels(&pixels);
    const regions = [_]windowing.PresentRegion{ .{ .width = 1, .height = 1 }, .{ .x = 3, .y = 3, .width = 1, .height = 1 } };
    @memset(pixels[0..4], 0x22);
    @memset(pixels[60..64], 0x33);
    const second = try sink.presenter.presentFrame(sink.target, &pixels, 4, 4, &regions);
    try std.testing.expectEqual(@as(u64, 2), second);
    @memset(pixels[0..4], 0x44);
    const third = try sink.presenter.presentFrame(sink.target, &pixels, 4, 4, regions[0..1]);
    try std.testing.expectEqual(@as(u64, 3), third);
    const discarded = sink.presenter.nextPresentationOutcome().?;
    try std.testing.expect(discarded == .discarded);
    try std.testing.expectEqual(second, discarded.submission().id);
    try std.testing.expect(sink.presenter.nextPresentationOutcome() == null);
    try std.testing.expectEqual(third, sink.presenter.pending_id.?);
    const expected = pixels;
    @memset(&pixels, 0);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    _ = try sink.presenter.dispatchCallback(sink.presenter.frame_callback.?, 0);
    try sink.receive();
    try std.testing.expectEqual(@as(usize, 2), sink.commits);
    try std.testing.expectEqual(@as(usize, 2), sink.flushes);
    try std.testing.expect(sink.presenter.pending_id == null);
    try sink.expectPixels(&expected);
    const fourth = try sink.presenter.presentFrame(sink.target, &expected, 4, 4, &.{});
    var resized = sink.target;
    resized.generation += 1;
    sink.presenter.updateTarget(resized);
    const invalidated = sink.presenter.nextPresentationOutcome().?;
    try std.testing.expect(invalidated == .discarded);
    try std.testing.expectEqual(fourth, invalidated.submission().id);
}

test "Wayland never-poll host accepts three N frames and counts only the oldest queued drops" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    var sink = WireSink{};
    try sink.init();
    defer sink.deinit();
    const pixels: [64]u8 = @splat(0x55);
    const n = (windowing.presentation.Limits{}).pending_feedback_count;
    for (0..3 * n) |index| {
        const id = try sink.presenter.presentFrame(sink.target, &pixels, 4, 4, &.{});
        try std.testing.expectEqual(@as(u64, index + 1), id);
    }
    const status = sink.presenter.presentationStorageStatus();
    try std.testing.expectEqual(@as(u64, n - 2), status.feedback_dropped_outcome_count);
    try std.testing.expectEqual(@as(usize, 1), sink.flushes);
    try std.testing.expectEqual(@as(u64, 3 * n), sink.presenter.pending_id.?);
}
