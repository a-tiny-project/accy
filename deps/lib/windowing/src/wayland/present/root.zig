const std = @import("std");
const native = @import("wayland");
const windowing = @import("../../root.zig");
const wayland = @import("../root.zig");

pub const buffer = @import("buffer.zig");
pub const damage = buffer.damage;
pub const retained = @import("retained.zig");
pub const dmabuf = @import("dmabuf.zig");

const core = native.protocol.core;
const desktop = native.protocol.desktop;
const runtime = native.runtime;
const presentation = wayland.presentation;
const toplevel = wayland.toplevel;
const support = @import("support.zig");
const frame_model = @import("../../frame.zig");

pub const Callbacks = struct {
    context: *anyopaque,
    flush: *const fn (context: *anyopaque) void,
};

pub const Presenter = struct {
    allocator: std.mem.Allocator = undefined,
    client: ?*runtime.Client = null,
    callbacks: ?Callbacks = null,
    swapchain: ?buffer.Swapchain = null,
    timing: ?presentation.Presentation = null,
    frame_callback: ?u32 = null,
    frame_ready: bool = true,
    target: ?toplevel.Target = null,
    frame: retained.Frame = .{},
    surface_dirty: damage.Region = .{},
    pending_owed: bool = false,
    pending_generation: u64 = 0,
    pending_id: ?u64 = null,
    ids: frame_model.Ids = .{},
    empty_region_fallback_count: u64 = 0,
    failure: ?windowing.PresentError = null,
    presentation_init_failed: bool = false,
    presentation_submit_failed: bool = false,
    presentation_callback_failed: bool = false,
    /// Set by the first dma-buf commit. From then on every commit of the surface must carry sync
    /// points, which a shared-memory frame has none of.
    explicit_sync: bool = false,
    frame_capacity_rejection_count: u64 = 0,
    damage_capacity_collapse_count: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        capacity: windowing.presentation.Capacity,
    ) error{OutOfMemory}!Presenter {
        std.debug.assert(capacity.wayland_pending_frame_bytes > 0);
        return .{
            .allocator = allocator,
            .frame = .{
                .bytes = allocator.alloc(
                    u8,
                    capacity.wayland_pending_frame_bytes,
                ) catch return error.OutOfMemory,
            },
        };
    }

    pub fn open(
        self: *Presenter,
        client: *runtime.Client,
        timing_id: ?u32,
        capacity: presentation.Capacity,
        callbacks: Callbacks,
    ) error{OutOfMemory}!void {
        std.debug.assert(self.client == null);
        std.debug.assert(self.frame.bytes.len == capacity.pending_frame_bytes);
        self.client = client;
        self.callbacks = callbacks;
        self.swapchain = buffer.Swapchain.init(
            self.allocator,
            client,
            capacity.swapchain,
        ) catch return error.OutOfMemory;
        if (timing_id) |object_id| {
            self.timing = presentation.Presentation.init(
                self.allocator,
                client,
                object_id,
                capacity,
            ) catch {
                self.presentation_init_failed = true;
                return;
            };
        }
    }

    pub fn configure(self: *Presenter, shm: u32, format: buffer.Format) void {
        const chain = if (self.swapchain) |*value| value else return;
        chain.configure(shm, format);
    }

    pub fn deinit(self: *Presenter) void {
        if (self.timing) |*timing| timing.deinit();
        self.timing = null;
        if (self.swapchain) |*chain| chain.deinit();
        self.swapchain = null;
        self.frame_callback = null;
        if (self.frame.bytes.len > 0) self.allocator.free(self.frame.bytes);
        self.* = .{};
    }

    pub fn dispatch(self: *Presenter, event: *runtime.RoutedView) !bool {
        if (self.swapchain) |*chain| {
            if (try chain.dispatch(event)) return true;
        }
        if (self.timing) |*timing| {
            if (try timing.dispatch(event)) return true;
        }
        return false;
    }

    pub fn dispatchCallback(self: *Presenter, callback_id: u32, _: u32) !bool {
        if (self.frame_callback != callback_id) return false;
        self.frameDone();
        return true;
    }

    pub fn updateTarget(self: *Presenter, target: toplevel.Target) void {
        if (self.target) |current| {
            if (current.generation != target.generation) self.discardPending();
        }
        self.target = target;
    }

    pub fn present(
        self: *Presenter,
        target: toplevel.Target,
        rgba8: []const u8,
        width: u32,
        height: u32,
        region: windowing.PresentRegion,
    ) windowing.PresentError!void {
        if (self.explicit_sync) return error.ExplicitSyncSurface;
        self.updateTarget(target);
        if (!target.visible) return;
        if (width == 0 or height == 0) return;
        const dirty = region.clamped(width, height);
        if (dirty.width == 0 or dirty.height == 0) return;
        _ = try self.presentFrame(target, rgba8, width, height, &.{dirty});
    }

    pub fn presentFrame(
        self: *Presenter,
        target: toplevel.Target,
        rgba8: []const u8,
        width: u32,
        height: u32,
        regions: []const windowing.PresentRegion,
    ) windowing.PresentError!u64 {
        const frame = try frame_model.Frame.init(rgba8, width, height, regions);
        if (self.explicit_sync) return error.ExplicitSyncSurface;
        if (width != target.framebuffer.width or height != target.framebuffer.height) return error.UnsupportedFormat;
        if (!self.admitFrame(frame.byte_count)) return error.CapacityExceeded;
        const id = try self.ids.reserve();
        self.updateTarget(target);
        if (self.timing) |*timing| timing.prepare(id);
        errdefer if (self.timing) |*timing| timing.cancel(id);
        if (!target.visible) {
            self.ids.accept(id);
            if (frame.empty_fallback) self.empty_region_fallback_count +|= 1;
            if (self.timing) |*timing| {
                timing.accept(id);
                timing.discard(id);
            }
            return id;
        }
        self.markRegions(width, height, frame.slice());
        if (try self.presentNow(target, rgba8[0..frame.byte_count], width, height, id)) {
            self.discardPending();
        } else {
            self.discardPending();
            self.stage(rgba8[0..frame.byte_count], target.generation);
            self.pending_id = id;
        }
        self.ids.accept(id);
        if (self.timing) |*timing| timing.accept(id);
        if (frame.empty_fallback) self.empty_region_fallback_count +|= 1;
        return id;
    }

    /// Whether the compositor has asked for the next frame. A dma-buf frame is rendered only
    /// once it has, because `presentDmabuf` refuses a frame the compositor is not ready for
    /// rather than holding it.
    pub fn frameReady(self: *const Presenter) bool {
        return self.frame_ready;
    }

    /// Commits an imported dma-buf with the points that order the compositor's read of it, paced
    /// by the same frame callback and reported through the same presentation feedback as a
    /// shared-memory present. Returns the presentation submission id when feedback is active.
    ///
    /// A frame the compositor is not ready for, or a hidden window, is refused rather than held:
    /// the caller has already queued the rendering, and a held frame that a later one replaced
    /// would leave its release point unsignalled. The caller signals that point itself.
    pub fn presentDmabuf(
        self: *Presenter,
        target: toplevel.Target,
        explicit: *dmabuf.Dmabuf,
        frame: dmabuf.Frame,
    ) dmabuf.PresentError!?u64 {
        self.updateTarget(target);
        if (!target.visible) return error.NotVisible;
        if (!self.frame_ready) return error.FrameNotReady;
        if (frame.width != target.framebuffer.width or frame.height != target.framebuffer.height) return error.UnsupportedFormat;
        if (!explicit.ownsBuffer(frame.buffer)) return error.InvalidBuffer;
        const client = self.client orelse return error.Unexpected;
        var dirty = frame.region.clamped(frame.width, frame.height);
        if (dirty.width == 0 or dirty.height == 0) dirty = windowing.PresentRegion.full(frame.width, frame.height);
        const id = try self.ids.reserve();
        if (self.timing) |*timing| timing.prepare(id);
        errdefer if (self.timing) |*timing| timing.cancel(id);
        self.explicit_sync = true;
        self.discardPending();

        applyScale(client, target) catch return error.Unexpected;
        client.request(
            target.surface,
            core.wl_surface.requests.attach.opcode,
            &.{ .{ .object = frame.buffer.id }, .{ .int = 0 }, .{ .int = 0 } },
            &.{},
        ) catch return error.Unexpected;
        client.request(target.surface, core.wl_surface.requests.damage_buffer.opcode, &.{
            .{ .int = @intCast(dirty.x) },
            .{ .int = @intCast(dirty.y) },
            .{ .int = @intCast(dirty.width) },
            .{ .int = @intCast(dirty.height) },
        }, &.{}) catch return error.Unexpected;
        try explicit.setSyncPoints(frame.sync);
        var created: [1]u32 = undefined;
        client.request(
            target.surface,
            core.wl_surface.requests.frame.opcode,
            &.{.{ .new_id = .fixed }},
            &created,
        ) catch return error.Unexpected;
        if (self.timing) |*timing| timing.submit(target.surface, id);
        client.request(target.surface, core.wl_surface.requests.commit.opcode, &.{}, &.{}) catch
            return error.Unexpected;
        self.frame_callback = created[0];
        self.frame_ready = false;
        if (self.callbacks) |callbacks| callbacks.flush(callbacks.context);
        self.ids.accept(id);
        if (self.timing) |*timing| timing.accept(id);
        return if (self.timing != null) id else null;
    }

    pub fn poll(self: *Presenter) windowing.PresentError!void {
        if (self.failure) |failure| {
            self.failure = null;
            return failure;
        }
        if (self.timing) |*timing| {
            if (timing.takeCallbackError() != null) self.presentation_callback_failed = true;
        }
        if (self.swapchain) |*chain| chain.collectRetired();
        try self.flushPending();
    }

    pub fn nextPresentationOutcome(self: *Presenter) ?windowing.presentation.Outcome {
        const timing = if (self.timing) |*value| value else return null;
        return timing.nextOutcome();
    }

    pub fn presentationStatus(self: *const Presenter) windowing.presentation.Status {
        if (self.presentation_init_failed or self.presentation_submit_failed or self.presentation_callback_failed) {
            return .failed;
        }
        return if (self.timing == null) .unavailable else .active;
    }

    pub fn presentationStorageStatus(
        self: *const Presenter,
    ) windowing.presentation.StorageStatus {
        const rejected = if (self.swapchain) |*chain|
            chain.retiredCapacityRejectionCount()
        else
            0;
        var result = if (self.timing) |*timing| timing.storageStatus() else windowing.presentation.StorageStatus{};
        result.retired_buffer_capacity_rejection_count = rejected;
        result.frame_capacity_rejection_count = self.frame_capacity_rejection_count;
        result.damage_capacity_collapse_count = self.damage_capacity_collapse_count;
        result.empty_region_fallback_count = self.empty_region_fallback_count;
        return result;
    }

    /// Propagates each changed rectangle into the three structures tracking staleness: the retained staging
    /// frame, the surface damage accumulator, and every active swapchain buffer slot. An extent change
    /// invalidates the entire retained frame, damages the full surface area, and discards any pending
    /// submission identifier. Accumulators retain a fixed bound of 48 rectangles each: if any accumulator
    /// runs out of space and collapses into a single covering rectangle, the call increments
    /// `damage_capacity_collapse_count` at most once per present attempt.
    fn markRegions(self: *Presenter, width: u32, height: u32, regions: []const windowing.PresentRegion) void {
        if (self.frame.resize(width, height)) {
            self.surface_dirty.cover(width, height);
            self.discardPending();
        }
        var collapsed = false;
        for (regions) |dirty| {
            if (self.frame.invalidate(dirty) == .collapsed) collapsed = true;
            if (self.surface_dirty.add(dirty) == .collapsed) collapsed = true;
            if (self.swapchain) |*chain| {
                if (chain.markDamage(dirty) == .collapsed) collapsed = true;
            }
        }
        if (collapsed) self.damage_capacity_collapse_count +|= 1;
    }

    fn presentNow(
        self: *Presenter,
        target: toplevel.Target,
        source: []const u8,
        width: u32,
        height: u32,
        id: u64,
    ) windowing.PresentError!bool {
        if (!self.frame_ready) return false;
        const client = self.client orelse return error.Unexpected;
        const chain = if (self.swapchain) |*value| value else return error.Unexpected;
        chain.ensure(width, height) catch |failure| return swapchainPresentError(failure);
        const next = chain.acquire() orelse return false;
        errdefer next.dirty.cover(width, height);
        errdefer self.surface_dirty.cover(width, height);
        std.debug.assert(!next.dirty.isEmpty());
        applyScale(client, target) catch return error.Unexpected;
        client.request(
            target.surface,
            core.wl_surface.requests.attach.opcode,
            &.{ .{ .object = next.buffer.object_id }, .{ .int = 0 }, .{ .int = 0 } },
            &.{},
        ) catch return error.Unexpected;
        damageBuffer(client, target.surface, &self.surface_dirty) catch return error.Unexpected;
        _ = next.write(source) catch |err| return switch (err) {
            error.DestinationTooSmall => error.UnsupportedFormat,
            error.InvalidRegion => error.Unexpected,
        };

        var created: [1]u32 = undefined;
        client.request(
            target.surface,
            core.wl_surface.requests.frame.opcode,
            &.{.{ .new_id = .fixed }},
            &created,
        ) catch return error.Unexpected;
        if (self.timing) |*timing| timing.submit(target.surface, id);
        client.request(
            target.surface,
            core.wl_surface.requests.commit.opcode,
            &.{},
            &.{},
        ) catch return error.Unexpected;
        self.frame_callback = created[0];
        next.buffer.busy = true;
        self.frame_ready = false;
        self.surface_dirty.clear();
        if (self.callbacks) |callbacks| callbacks.flush(callbacks.context);
        return true;
    }

    /// Copies the stale rows of the caller's pixels into the retained frame. A
    /// present that has to wait for the compositor goes through this step so
    /// the pixels survive until the compositor is ready. The call marks the
    /// present as waiting and records the window generation it was made for. A
    /// later flush reads the retained frame, which then holds the logical
    /// frame, so it can supply the rectangles any buffer owes. A flush drops
    /// the waiting present when the window generation, visibility, or extent
    /// has changed since.
    fn stage(self: *Presenter, rgba8: []const u8, generation: u64) void {
        self.frame.refresh(rgba8);
        self.pending_generation = generation;
        self.pending_owed = true;
    }

    fn flushPending(self: *Presenter) windowing.PresentError!void {
        if (!self.pending_owed) return;
        if (self.explicit_sync) {
            self.discardPending();
            return;
        }
        std.debug.assert(self.frame.isCurrent());
        const target = self.target orelse {
            self.discardPending();
            return;
        };
        if (!target.visible or self.pending_generation != target.generation) {
            self.discardPending();
            return;
        }
        if (self.frame.width != target.framebuffer.width or
            self.frame.height != target.framebuffer.height)
        {
            self.discardPending();
            return;
        }
        const submitted = self.presentNow(
            target,
            self.frame.contents(),
            self.frame.width,
            self.frame.height,
            self.pending_id.?,
        ) catch |failure| {
            if (self.timing) |*timing| timing.fail(self.pending_id.?);
            self.pending_owed = false;
            self.pending_id = null;
            return failure;
        };
        if (!submitted) return;
        self.pending_owed = false;
        self.pending_id = null;
    }

    fn discardPending(self: *Presenter) void {
        if (self.pending_id) |id| {
            if (self.timing) |*timing| timing.discard(id);
        }
        self.pending_id = null;
        self.pending_owed = false;
    }

    fn frameDone(self: *Presenter) void {
        self.frame_callback = null;
        self.frame_ready = true;
        self.flushPending() catch |failure| {
            self.failure = failure;
        };
    }

    fn admitFrame(self: *Presenter, byte_count: usize) bool {
        return support.admitFrame(
            byte_count,
            self.frame.bytes.len,
            &self.frame_capacity_rejection_count,
        );
    }
};

fn applyScale(client: *runtime.Client, target: toplevel.Target) !void {
    try client.request(
        target.surface,
        core.wl_surface.requests.set_buffer_scale.opcode,
        &.{.{ .int = @intCast(target.scale_state.bufferScale()) }},
        &.{},
    );
    const viewport = target.viewport orelse return;
    const width: i32 = if (target.scale_state.usesViewport()) @intCast(target.logical.width) else -1;
    const height: i32 = if (target.scale_state.usesViewport()) @intCast(target.logical.height) else -1;
    try client.request(
        viewport,
        desktop.wp_viewport.requests.set_destination.opcode,
        &.{ .{ .int = width }, .{ .int = height } },
        &.{},
    );
}

/// Sends one `damage_buffer` request for each rectangle of the surface
/// accumulator. A present calls this before it commits so the compositor
/// redraws the parts of the window that changed. The surface accumulator holds
/// every rectangle presented since the last commit, which matches what the
/// compositor needs because it compares the attached buffer against the buffer
/// it last received. The accumulator of the buffer being attached can list
/// more, since that buffer may be two or more presents old, so the call reads
/// the surface list. The surface accumulator has to hold at least one
/// rectangle. A failed request comes back as the call's error.
fn damageBuffer(client: *runtime.Client, surface_id: u32, dirty: *const damage.Region) !void {
    std.debug.assert(!dirty.isEmpty());
    for (dirty.slice()) |region| {
        try client.request(
            surface_id,
            core.wl_surface.requests.damage_buffer.opcode,
            &.{
                .{ .int = @intCast(region.x) },
                .{ .int = @intCast(region.y) },
                .{ .int = @intCast(region.width) },
                .{ .int = @intCast(region.height) },
            },
            &.{},
        );
    }
}

const swapchainPresentError = support.swapchainPresentError;
