const std = @import("std");
const gpu_abi = @import("gpu_abi");
const build_options = @import("build_options");
const sys = @import("sys");

const backend = @import("root.zig");
const runtime_root = @import("runtime/root.zig");

const launch_mod = runtime_root.vulkan.launch;
const sequence_mod = runtime_root.vulkan.sequence;
comptime {
    std.debug.assert(backend.contract.max_sequence_dispatches == sequence_mod.max_dispatches);
}
const raster_mod = runtime_root.vulkan.raster;
const dmabuf_mod = runtime_root.vulkan.dmabuf;
const memory_mod = runtime_root.vulkan.memory;
const runtime_mod = runtime_root.vulkan.runtime;
pub const AllocationObservation = runtime_root.vulkan.observation.AllocationObservation;
const driver_mod = sys.vulkan;

const Allocator = std.mem.Allocator;
const BackendObjectId = backend.BackendObjectId;
const Runtime = runtime_mod.Runtime;

const RuntimeStorage = union(enum) {
    none,
    borrowed: *Runtime,
    owned: Runtime,

    fn ptr(self: *RuntimeStorage) ?*Runtime {
        return switch (self.*) {
            .none => null,
            .borrowed => |runtime| runtime,
            .owned => |*runtime| runtime,
        };
    }

    fn deinit(self: *RuntimeStorage) void {
        switch (self.*) {
            .none, .borrowed => {},
            .owned => |*runtime| runtime.deinit(),
        }
        self.* = .none;
    }
};

/// The raster state beside a runtime, made the first time a texture, pipeline or capability query
/// needs it. A runtime whose queue runs no graphics leaves it unavailable.
const RasterSlot = union(enum) {
    untried,
    unavailable,
    ready: raster_mod.Raster,
};

pub const State = struct {
    allocator: Allocator,
    runtime: RuntimeStorage = .none,
    next_id: BackendObjectId = 1,
    objects: std.AutoHashMapUnmanaged(BackendObjectId, Object) = .{},
    raster: RasterSlot = .untried,
    /// A device's capabilities never change, so the first query answers every later one.
    caps: ?backend.BackendCapabilities = null,
    /// The dma-buf target whose frame is being recorded, the only time its images may be named.
    presenting: ?BackendObjectId = null,

    fn init(allocator: Allocator) State {
        return .{
            .allocator = allocator,
        };
    }

    pub fn initDevice(allocator: Allocator, device_ordinal: i32) backend.BackendError!State {
        var diagnostic: []const u8 = "none";
        return initDeviceOptional(allocator, device_ordinal, &diagnostic, null);
    }

    pub fn initDeviceDiagnosed(allocator: Allocator, device_ordinal: i32, diagnostic: *[]const u8) backend.BackendError!State {
        return initDeviceOptional(allocator, device_ordinal, diagnostic, null);
    }

    /// The caller retains the observer through failed initialization and teardown.
    pub fn initDeviceObserved(allocator: Allocator, device_ordinal: i32, diagnostic: *[]const u8, observer: *AllocationObservation) backend.BackendError!State {
        return initDeviceOptional(allocator, device_ordinal, diagnostic, observer);
    }

    fn initDeviceOptional(allocator: Allocator, device_ordinal: i32, diagnostic: *[]const u8, observer: ?*AllocationObservation) backend.BackendError!State {
        const runtime = Runtime.initObserved(allocator, device_ordinal, observer) catch |err| {
            diagnostic.* = @errorName(err);
            return mapRuntimeError(err);
        };
        diagnostic.* = "none";
        return .{
            .allocator = allocator,
            .runtime = .{ .owned = runtime },
        };
    }

    fn initWithRuntime(allocator: Allocator, runtime: ?*Runtime) State {
        return .{
            .allocator = allocator,
            .runtime = if (runtime) |rt| .{ .borrowed = rt } else .none,
        };
    }

    pub fn deinit(self: *State) void {
        var it = self.objects.iterator();
        while (it.next()) |entry| {
            deinitObject(self, entry.value_ptr);
        }
        self.objects.deinit(self.allocator);
        self.objects = .{};
        self.next_id = 1;
        switch (self.raster) {
            .ready => |*raster| raster.deinit(),
            .untried, .unavailable => {},
        }
        self.raster = .untried;
        self.caps = null;
        self.runtime.deinit();
    }

    fn rasterState(self: *State) backend.BackendError!*raster_mod.Raster {
        switch (self.raster) {
            .ready => |*raster| return raster,
            .unavailable => return error.CapabilityMismatch,
            .untried => {},
        }
        const rt = self.runtime.ptr() orelse return error.RuntimeUnavailable;
        const raster = raster_mod.Raster.init(rt) catch |err| switch (err) {
            error.FeatureNotPresent => {
                self.raster = .unavailable;
                return error.CapabilityMismatch;
            },
            else => return mapRasterError(err, error.RuntimeUnavailable),
        };
        self.raster = .{ .ready = raster };
        return &self.raster.ready;
    }

    /// The raster that made an existing raster object.
    fn liveRaster(self: *State) *raster_mod.Raster {
        return &self.raster.ready;
    }

    pub fn handle(self: *State) backend.BackendHandle {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .kind = .vulkan,
        };
    }

    fn putObject(self: *State, object: Object) backend.BackendError!BackendObjectId {
        const id = self.next_id;
        if (id == std.math.maxInt(BackendObjectId)) return error.OutOfMemory;
        self.next_id += 1;
        self.objects.put(self.allocator, id, object) catch return error.OutOfMemory;
        return id;
    }

    fn getLoaded(self: *State, loaded: backend.LoadedArtifact) backend.BackendError!*LoadedKernel {
        if (loaded.backend != .vulkan or loaded.format != .vulkan_spirv) return error.InvalidArtifact;
        const object = self.objects.getPtr(loaded.id) orelse return error.InvalidArtifact;
        return switch (object.*) {
            .loaded_artifact => |*kernel| kernel,
            else => error.InvalidArtifact,
        };
    }

    fn getBuffer(self: *State, buffer_handle: backend.BufferHandle) backend.BackendError!*runtime_mod.DeviceBuffer {
        if (buffer_handle.backend != .vulkan) return error.InvalidBuffer;
        const object = self.objects.getPtr(buffer_handle.id) orelse return error.InvalidBuffer;
        return switch (object.*) {
            .loaded_artifact => error.InvalidBuffer,
            .buffer => |*buffer| buffer,
            else => error.InvalidBuffer,
        };
    }

    fn getStream(self: *State, stream_handle: backend.StreamHandle) backend.BackendError!*runtime_mod.Stream {
        if (stream_handle.backend != .vulkan) return error.InvalidStream;
        const object = self.objects.getPtr(stream_handle.id) orelse return error.InvalidStream;
        return switch (object.*) {
            .stream => |stream| stream,
            else => error.InvalidStream,
        };
    }

    fn getEvent(self: *State, event_handle: backend.EventHandle) backend.BackendError!*runtime_mod.Event {
        if (event_handle.backend != .vulkan) return error.InvalidEvent;
        const object = self.objects.getPtr(event_handle.id) orelse return error.InvalidEvent;
        return switch (object.*) {
            .event => |event| event,
            else => error.InvalidEvent,
        };
    }

    fn getSurface(self: *State, surface_handle: backend.SurfaceHandle) backend.BackendError!*VulkanSurface {
        if (surface_handle.backend != .vulkan) return error.InvalidSurface;
        const object = self.objects.getPtr(surface_handle.id) orelse return error.InvalidSurface;
        return switch (object.*) {
            .surface => |*surface| surface,
            else => error.InvalidSurface,
        };
    }

    /// The surface that lent `texture` and still holds it acquired, as a pass's color attachment.
    fn getLender(self: *State, texture_handle: backend.TextureHandle) backend.BackendError!*VulkanSurface {
        const texture = try self.getTexture(texture_handle);
        if (!std.meta.eql(texture.handle, texture_handle)) return error.InvalidTexture;
        const object = self.objects.getPtr(texture.surface_id) orelse return error.InvalidTexture;
        const surface = switch (object.*) {
            .surface => |*surface| surface,
            else => return error.InvalidTexture,
        };
        if (surface.acquired_texture != texture_handle.id) return error.SurfaceFrameExpired;
        return surface;
    }

    fn getTexture(self: *State, texture_handle: backend.TextureHandle) backend.BackendError!*VulkanTexture {
        if (texture_handle.backend != .vulkan) return error.InvalidTexture;
        const object = self.objects.getPtr(texture_handle.id) orelse return error.InvalidTexture;
        return switch (object.*) {
            .texture => |*texture| texture,
            else => error.InvalidTexture,
        };
    }

    /// An image the contract may name now. An image a dma-buf target shares with another process
    /// is named only by its target's frame, since between frames that process owns it.
    fn getImage(self: *State, texture_handle: backend.TextureHandle) backend.BackendError!*VulkanImage {
        const image = try self.getAnyImage(texture_handle);
        if (image.target) |owner| if (self.presenting != owner) return error.InvalidTexture;
        return image;
    }

    fn getAnyImage(self: *State, texture_handle: backend.TextureHandle) backend.BackendError!*VulkanImage {
        if (texture_handle.backend != .vulkan) return error.InvalidTexture;
        const object = self.objects.getPtr(texture_handle.id) orelse return error.InvalidTexture;
        return switch (object.*) {
            .image => |*image| if (std.meta.eql(image.handle, texture_handle)) image else error.InvalidTexture,
            else => error.InvalidTexture,
        };
    }

    fn getRenderPipeline(self: *State, loaded: backend.LoadedRenderArtifact) backend.BackendError!*VulkanPipeline {
        if (loaded.backend != .vulkan) return error.InvalidRenderArtifact;
        const object = self.objects.getPtr(loaded.id) orelse return error.InvalidRenderArtifact;
        return switch (object.*) {
            .render_pipeline => |*pipeline| if (std.meta.eql(pipeline.loaded, loaded)) pipeline else error.InvalidRenderArtifact,
            else => error.InvalidRenderArtifact,
        };
    }

    fn getRenderBindings(self: *State, bindings: backend.RenderBindings) backend.BackendError!*VulkanBindings {
        if (bindings.backend != .vulkan) return error.RenderArgumentMismatch;
        const object = self.objects.getPtr(bindings.id) orelse return error.RenderArgumentMismatch;
        return switch (object.*) {
            .render_bindings => |*set| if (set.pipeline_id == bindings.pipeline) set else error.RenderArgumentMismatch,
            else => error.RenderArgumentMismatch,
        };
    }

    fn getRenderBundle(self: *State, bundle: backend.RenderBundle) backend.BackendError!*VulkanBundle {
        if (bundle.backend != .vulkan) return error.RenderArgumentMismatch;
        const object = self.objects.getPtr(bundle.id) orelse return error.RenderArgumentMismatch;
        return switch (object.*) {
            .render_bundle => |*recorded| if (recorded.draw_count == bundle.draw_count) recorded else error.RenderArgumentMismatch,
            else => error.RenderArgumentMismatch,
        };
    }

    fn submitStream(self: *State, stream_handle: ?backend.StreamHandle) backend.BackendError!*runtime_mod.Stream {
        if (stream_handle) |handle_value| return self.getStream(handle_value);
        const rt = self.runtime.ptr() orelse return error.RuntimeUnavailable;
        return rt.defaultStream() catch |err| mapRuntimeError(err);
    }

    fn submitWaits(
        self: *State,
        handles: []const backend.EventHandle,
        events: *[raster_mod.max_wait_events]*runtime_mod.Event,
    ) backend.BackendError![]const *runtime_mod.Event {
        if (handles.len > raster_mod.max_wait_events) return error.RenderArgumentMismatch;
        for (handles, 0..) |event_handle, index| {
            const event = try self.getEvent(event_handle);
            if (!event.recorded) return error.InvalidEvent;
            events[index] = event;
        }
        return events[0..handles.len];
    }

    /// Where the device placed a texture and a buffer, and which queue runs them. A witness reports
    /// it so a run on another driver says what that driver chose.
    pub fn placement(self: *State, texture: backend.TextureHandle, buffer: backend.BufferHandle) backend.BackendError!Placement {
        const raster = try self.rasterState();
        const rt = raster.runtime;
        const image = try self.getImage(texture);
        const device_buffer = try self.getBuffer(buffer);
        return .{
            .queue_family = rt.device.queueFamilyIndex(),
            .graphics = rt.device.graphics(),
            .buffer_image_granularity = raster.buffer_image_granularity,
            .image_memory = switch (image.image.backing) {
                .pooled => |allocation| memoryPlacement(rt, allocation),
                .dedicated => return error.InvalidTexture,
            },
            .buffer_memory = memoryPlacement(rt, device_buffer._allocation),
        };
    }

    /// Records `pass`'s targets and one bare draw command per draw into a command buffer it then
    /// frees unsubmitted. It binds the first draw's pipeline, bindings and vertex buffers once and
    /// checks nothing per draw, so its time is the least any path recording these draws on this
    /// driver can take. The raster witness measures the contract's recording against it.
    pub fn recordFloor(self: *State, pass: backend.RenderPass) backend.BackendError!void {
        if (pass.draws.len == 0) return error.RenderArgumentMismatch;
        const raster = try self.rasterState();
        const drv = &raster.runtime._driver;
        const cb = raster_mod.beginBundle(raster) catch |err| return mapRasterError(err, error.RenderFailed);
        defer raster.discardBundle(cb);
        var lender: ?*VulkanSurface = null;
        const targets = try passTargets(self, pass, &lender);
        if (lender != null) return error.RenderArgumentMismatch;
        const first = pass.draws[0];
        const pipeline = try self.getRenderPipeline(first.pipeline);
        raster_mod.beginPass(drv, cb, targets);
        drv.vkCmdBindPipeline(cb, driver_mod.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline.pipeline);
        if (first.bindings) |bindings| {
            const set = try self.getRenderBindings(bindings);
            drv.vkCmdBindDescriptorSets(cb, driver_mod.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline.layout, 0, 1, @ptrCast(&set.set.set), 0, null);
        }
        for (first.vertex_buffers, pipeline.layouts[0..first.vertex_buffers.len]) |range, layout| {
            const buffer = try self.getBuffer(range.buffer);
            drv.vkCmdBindVertexBuffers(cb, layout.binding, 1, @ptrCast(&buffer._buffer), @ptrCast(&range.offset));
        }
        for (pass.draws) |draw| {
            if (draw.push_constants.len != 0) {
                const size: u32 = @intCast(draw.push_constants.len);
                drv.vkCmdPushConstants(cb, pipeline.pipeline.layout, raster_mod.push_constant_stages, 0, size, draw.push_constants.ptr);
            }
            drv.vkCmdDraw(cb, draw.range.vertex_count, draw.range.instance_count, draw.range.first_vertex, draw.range.first_instance);
        }
        raster_mod.endPass(drv, cb, targets);
        drv.fromResult(drv.vkEndCommandBuffer(cb)) catch |err| return mapRasterError(err, error.RenderFailed);
    }

    /// Makes a ring of color images another process on `desc.device` can import as dma-bufs, each
    /// registered as a texture a frame's pass renders into. See `runtime/vulkan/dmabuf.zig` for the
    /// frame protocol.
    pub fn createDmabufTarget(self: *State, desc: DmabufTargetDesc) DmabufError!BackendObjectId {
        const raster = try self.rasterState();
        if (desc.format.isDepth()) return error.CapabilityMismatch;
        if (desc.image_count > dmabuf_mod.max_images) return error.CapabilityMismatch;
        const id = self.next_id;
        if (id > std.math.maxInt(BackendObjectId) - 1 - @as(BackendObjectId, desc.image_count)) return error.OutOfMemory;
        try self.objects.ensureUnusedCapacity(self.allocator, 1 + desc.image_count);
        const shared = try self.allocator.create(VulkanDmabufTarget);
        errdefer self.allocator.destroy(shared);
        var images: [dmabuf_mod.max_images]raster_mod.Image = undefined;
        shared.* = .{
            .target = dmabuf_mod.Target.create(raster, .{
                .width = desc.width,
                .height = desc.height,
                .format = try vulkanFormat(desc.format),
                .modifiers = desc.modifiers,
                .image_count = desc.image_count,
                .device = desc.device,
            }, &images) catch |err| return mapDmabufError(err),
            .textures = undefined,
        };
        self.next_id += 1 + desc.image_count;
        self.objects.putAssumeCapacity(id, .{ .dmabuf_target = shared });
        for (images[0..desc.image_count], shared.textures[0..desc.image_count], 1..) |image, *texture, offset| {
            texture.* = .{
                .id = id + @as(BackendObjectId, @intCast(offset)),
                .backend = .vulkan,
                .extent = .{ .width = desc.width, .height = desc.height, .depth = 1 },
                .format = desc.format,
                .usage = .{ .color_attachment = true },
                .sample_count = 1,
                .ownership = .backend,
            };
            self.objects.putAssumeCapacity(texture.id, .{ .image = .{ .handle = texture.*, .image = image, .target = id } });
        }
        return id;
    }

    /// Waits up to a second for the consumer to release every image, then frees the target and
    /// its textures.
    pub fn destroyDmabufTarget(self: *State, id: BackendObjectId) DmabufError!void {
        const shared = try self.getDmabufTarget(id);
        if (shared.target.open != null) return error.RenderArgumentMismatch;
        const count = shared.target.count;
        const textures = shared.textures;
        var target = self.objects.fetchRemove(id).?.value;
        deinitObject(self, &target);
        for (textures[0..count]) |texture| {
            var image = self.objects.fetchRemove(texture.id).?.value;
            deinitObject(self, &image);
        }
    }

    /// Image `index` of a target: its texture, its dma-buf and its timeline's descriptor. The
    /// target owns both descriptors.
    pub fn dmabufImage(self: *State, id: BackendObjectId, index: u32) DmabufError!DmabufImage {
        const shared = try self.getDmabufTarget(id);
        if (index >= shared.target.count) return error.InvalidTexture;
        return .{
            .texture = shared.textures[index],
            .dmabuf = shared.target.dmabuf(index),
            .timeline_fd = shared.target.timelineFd(index),
        };
    }

    pub fn dmabufImageCount(self: *State, id: BackendObjectId) DmabufError!u32 {
        return (try self.getDmabufTarget(id)).target.count;
    }

    /// The highest signalled point on image `index`'s timeline.
    pub fn dmabufSignalledPoint(self: *State, id: BackendObjectId, index: u32) DmabufError!u64 {
        const shared = try self.getDmabufTarget(id);
        if (index >= shared.target.count) return error.InvalidTexture;
        return shared.target.signalledPoint(index) catch |err| mapDmabufError(err);
    }

    /// Picks the target's next image, waiting until `deadline_ns` on `CLOCK_MONOTONIC` for the
    /// consumer to release it. The frame's pass must render into the returned texture.
    pub fn beginDmabufFrame(self: *State, id: BackendObjectId, deadline_ns: i64) DmabufError!DmabufFrame {
        const shared = try self.getDmabufTarget(id);
        if (shared.broken) return error.RenderFailed;
        if (shared.target.open != null) return error.RenderArgumentMismatch;
        const frame = shared.target.begin(deadline_ns) catch |err| return mapDmabufError(err);
        return .{
            .index = frame.index,
            .texture = shared.textures[frame.index],
            .acquire_point = frame.acquire_point,
            .release_point = frame.release_point,
        };
    }

    /// Records `pass` between the barriers that take the frame's image from the consumer and hand
    /// it back, submits it on the default stream, and attaches its completion to the frame's
    /// acquire point. A failure before the submission queues leaves the frame open to try again.
    pub fn submitDmabufFrame(self: *State, id: BackendObjectId, frame: DmabufFrame, pass: backend.RenderPass) DmabufError!void {
        const raster = try self.rasterState();
        const shared = try self.getDmabufTarget(id);
        const inner = dmabuf_mod.Frame{ .index = frame.index, .acquire_point = frame.acquire_point, .release_point = frame.release_point };
        if (!std.meta.eql(shared.target.open, inner)) return error.RenderArgumentMismatch;
        if (!std.meta.eql(pass.color.view.texture, shared.textures[frame.index])) return error.RenderArgumentMismatch;
        const stream = raster.runtime.defaultStream() catch |err| return mapRuntimeError(err);
        const cb = raster_mod.beginStreamPass(stream) catch |err| return mapRasterError(err, error.RenderFailed);
        self.presenting = id;
        defer self.presenting = null;
        shared.target.recordAcquire(cb, inner);
        var lender: ?*VulkanSurface = null;
        recordPass(self, raster, cb, pass, &lender) catch |err| {
            runtime_mod.retireStreamCommandBuffer(stream, cb, stream.counter);
            return err;
        };
        shared.target.recordRelease(cb, inner);
        const drv = &raster.runtime._driver;
        drv.fromResult(drv.vkEndCommandBuffer(cb)) catch |err| {
            runtime_mod.retireStreamCommandBuffer(stream, cb, stream.counter);
            return mapRasterError(err, error.RenderFailed);
        };
        raster_mod.submit(raster, .{
            .stream = stream,
            .cb = cb,
            .wait_events = &.{},
            .signal_event = null,
            .retire = true,
            .signal_semaphore = shared.target.semaphore,
        }) catch |err| return mapRasterError(err, error.RenderFailed);
        shared.target.finish(inner) catch |err| {
            shared.broken = true;
            return mapDmabufError(err);
        };
    }

    /// Signals the release point of a submitted frame the consumer never received, such as one a
    /// window refused, so the image can be used again.
    pub fn reclaimDmabufFrame(self: *State, id: BackendObjectId, frame: DmabufFrame) DmabufError!void {
        const shared = try self.getDmabufTarget(id);
        if (frame.index >= shared.target.count) return error.RenderArgumentMismatch;
        if (frame.release_point != 2 * shared.target.slots[frame.index].uses) return error.RenderArgumentMismatch;
        shared.target.reclaim(.{ .index = frame.index, .acquire_point = frame.acquire_point, .release_point = frame.release_point }) catch |err|
            return mapDmabufError(err);
    }

    /// Submits an empty command buffer that signals the target's semaphore, and moves its fence
    /// onto a scratch timeline as a frame's would be. It is the least a frame's submission and
    /// sync bridge can cost on this driver, and a witness measures `submitDmabufFrame` against it.
    pub fn dmabufBridgeFloor(self: *State, id: BackendObjectId) DmabufError!void {
        const raster = try self.rasterState();
        const shared = try self.getDmabufTarget(id);
        if (shared.broken or shared.target.open != null) return error.RenderArgumentMismatch;
        const stream = raster.runtime.defaultStream() catch |err| return mapRuntimeError(err);
        const cb = raster_mod.beginStreamPass(stream) catch |err| return mapRasterError(err, error.RenderFailed);
        const drv = &raster.runtime._driver;
        drv.fromResult(drv.vkEndCommandBuffer(cb)) catch |err| {
            runtime_mod.retireStreamCommandBuffer(stream, cb, stream.counter);
            return mapRasterError(err, error.RenderFailed);
        };
        raster_mod.submit(raster, .{
            .stream = stream,
            .cb = cb,
            .wait_events = &.{},
            .signal_event = null,
            .retire = true,
            .signal_semaphore = shared.target.semaphore,
        }) catch |err| return mapRasterError(err, error.RenderFailed);
        shared.target.bridgeScratch() catch |err| {
            shared.broken = true;
            return mapDmabufError(err);
        };
    }

    fn getDmabufTarget(self: *State, id: BackendObjectId) backend.BackendError!*VulkanDmabufTarget {
        const object = self.objects.getPtr(id) orelse return error.InvalidTexture;
        return switch (object.*) {
            .dmabuf_target => |shared| shared,
            else => error.InvalidTexture,
        };
    }

    fn getFrame(self: *State, frame_handle: backend.SurfaceFrame) backend.BackendError!*VulkanSurfaceFrame {
        if (frame_handle.backend != .vulkan) return error.InvalidSurfaceFrame;
        const object = self.objects.getPtr(frame_handle.id) orelse return error.InvalidSurfaceFrame;
        return switch (object.*) {
            .surface_frame => |*frame| frame,
            else => error.InvalidSurfaceFrame,
        };
    }
};

pub const DmabufError = backend.BackendError || error{
    /// The device did not enable dma-buf export or cannot name its render node.
    NoDmabufDevice,
    /// The consumer wants buffers from another device.
    DeviceMismatch,
    /// The device can render the format with none of the modifiers the consumer lists.
    NoSharedModifier,
    /// The render node would not open for this process.
    RenderNodeUnavailable,
    /// The consumer had not released the image by the deadline.
    Timeout,
};

pub const DmabufTargetDesc = struct {
    width: u32,
    height: u32,
    format: backend.TextureFormat,
    /// Modifiers of the format the consumer can import, such as a compositor's dma-buf feedback
    /// lists for its main device.
    modifiers: []const u64,
    image_count: u32,
    device: sys.drm.DeviceNumber,
};

pub const DmabufImage = struct {
    texture: backend.TextureHandle,
    dmabuf: dmabuf_mod.Dmabuf,
    timeline_fd: i32,
};

/// One image's turn. The consumer may read the image once `acquire_point` on its timeline
/// signals, and signals `release_point` when it is done.
pub const DmabufFrame = struct {
    index: u32,
    texture: backend.TextureHandle,
    acquire_point: u64,
    release_point: u64,
};

fn mapDmabufError(err: dmabuf_mod.Error) DmabufError {
    return switch (err) {
        error.NoDmabufDevice, error.UnsupportedPlatform, error.Unsupported => error.NoDmabufDevice,
        error.DeviceMismatch => error.DeviceMismatch,
        error.NoSharedModifier => error.NoSharedModifier,
        error.OpenFailed, error.AccessDenied => error.RenderNodeUnavailable,
        error.Timeout => error.Timeout,
        error.OutOfMemory, error.OutOfHostMemory, error.OutOfDeviceMemory => error.OutOfMemory,
        error.DeviceLost => error.DeviceLost,
        error.InvalidHandle, error.Failed => error.RenderFailed,
        else => |vulkan_err| mapRasterError(vulkan_err, error.RenderFailed),
    };
}

/// A memory type by index, with its property flags and the size of the heap it draws on.
pub const MemoryPlacement = struct {
    type_index: u32,
    property_flags: driver_mod.VkMemoryPropertyFlags,
    heap_bytes: u64,
};

pub const Placement = struct {
    queue_family: u32,
    graphics: bool,
    buffer_image_granularity: u64,
    image_memory: MemoryPlacement,
    buffer_memory: MemoryPlacement,
};

fn memoryPlacement(rt: *runtime_mod.Runtime, allocation: memory_mod.Allocation) MemoryPlacement {
    const index = rt._memory.memoryTypeIndex(allocation);
    const memory_type = rt._memory.properties.memoryTypes[index];
    return .{
        .type_index = index,
        .property_flags = memory_type.propertyFlags,
        .heap_bytes = rt._memory.properties.memoryHeaps[memory_type.heapIndex].size,
    };
}

const LoadedKernel = struct {
    kernel: launch_mod.Kernel,
    entry_name: [:0]u8,
    buffer_argument_count: u32,
    scalar_argument_count: u32,
    push_constants: gpu_abi.PushConstants,
};

const Object = union(enum) {
    loaded_artifact: LoadedKernel,
    sequence: sequence_mod.Sequence,
    buffer: runtime_mod.DeviceBuffer,
    stream: *runtime_mod.Stream,
    event: *runtime_mod.Event,
    surface: VulkanSurface,
    texture: VulkanTexture,
    surface_frame: VulkanSurfaceFrame,
    image: VulkanImage,
    render_pipeline: VulkanPipeline,
    render_bindings: VulkanBindings,
    render_bundle: VulkanBundle,
    dmabuf_target: *VulkanDmabufTarget,
};

fn recordSequence(ptr: *anyopaque, request: backend.contract.SequenceRecordRequest) backend.BackendError!backend.contract.SequenceHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    // Keep the default-stream allocation out of the replay path.
    _ = rt.defaultStream() catch |err| return mapRuntimeError(err);
    var native: [backend.contract.max_sequence_dispatches]sequence_mod.Dispatch = undefined;
    var buffers: [backend.contract.max_sequence_dispatches][backend.contract.max_sequence_arguments]*runtime_mod.DeviceBuffer = undefined;
    var pushes: [backend.contract.max_sequence_dispatches][gpu_abi.max_push_constant_bytes]u8 = undefined;
    for (request.dispatches, 0..) |dispatch, index| {
        const launch_request = dispatch.launch;
        if (request.failure) |failure| failure.* = .{ .stage = .record, .dispatch_index = index, .dispatch_name = dispatch.name };
        if (launch_request.geometry.dynamic_shared_memory_bytes != 0) return error.UnsupportedOperation;
        const loaded = try state.getLoaded(launch_request.loaded_artifact orelse return error.InvalidArtifact);
        if (launch_request.buffers.len != loaded.buffer_argument_count or
            launch_request.scalar_arguments.len != loaded.scalar_argument_count) return error.LaunchArgumentMismatch;
        const push_size = try loaded.push_constants.pack(launch_request.scalar_arguments, &pushes[index]);
        for (launch_request.buffers, 0..) |binding, i| {
            if (binding.ownership != .backend) return error.InvalidBuffer;
            const buffer = try state.getBuffer(binding.handle);
            if (binding.byte_size > buffer.size or binding.handle.byte_size != buffer.size) return error.InvalidBuffer;
            buffers[index][i] = buffer;
        }
        native[index] = .{
            .kernel = &loaded.kernel,
            .buffers = buffers[index][0..launch_request.buffers.len],
            .push_constants = pushes[index][0..push_size],
            .grid = launch_request.geometry.grid,
            .threadgroup = launch_request.geometry.threadgroup,
        };
    }
    var failed_index: ?usize = null;
    var sequence = sequence_mod.Sequence.record(rt, native[0..request.dispatches.len], &failed_index) catch |err| {
        if (request.failure) |failure| failure.* = .{
            .stage = .record,
            .dispatch_index = failed_index,
            .dispatch_name = if (failed_index) |index| request.dispatches[index].name else null,
        };
        return mapLaunchError(err);
    };
    errdefer sequence.deinit();
    const id = try state.putObject(.{ .sequence = sequence });
    return .{ .id = id, .backend = .vulkan };
}

fn submitSequence(ptr: *anyopaque, request: backend.contract.SequenceSubmitRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const object = state.objects.getPtr(request.sequence.id) orelse return error.InvalidArtifact;
    const sequence = switch (object.*) {
        .sequence => |*value| value,
        else => return error.InvalidArtifact,
    };
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const stream = if (request.stream) |handle| try state.getStream(handle) else rt.defaultStream() catch |err| return mapRuntimeError(err);
    if (request.wait_events.len > launch_mod.max_wait_events) return error.LaunchArgumentMismatch;
    var waits: [launch_mod.max_wait_events]*runtime_mod.Event = undefined;
    for (request.wait_events, 0..) |handle, index| {
        const event = try state.getEvent(handle);
        if (!event.recorded) return error.InvalidEvent;
        waits[index] = event;
    }
    const signal = if (request.signal_event) |handle| try state.getEvent(handle) else null;
    sequence.submit(stream, waits[0..request.wait_events.len], signal) catch |err| return mapLaunchError(err);
}

/// A texture this backend allocated, as opposed to a swapchain image a surface lent it.
const VulkanImage = struct {
    handle: backend.TextureHandle,
    image: raster_mod.Image,
    /// The dma-buf target that shares the image, if one does.
    target: ?BackendObjectId = null,
};

const VulkanDmabufTarget = struct {
    target: dmabuf_mod.Target,
    textures: [dmabuf_mod.max_images]backend.TextureHandle,
    /// A frame whose submission queued but whose fence never reached the timeline. The target's
    /// semaphore may still be signalled, so the target takes no more frames.
    broken: bool = false,
};

const VertexLayout = struct {
    binding: u32,
    stride: u32,
    per_instance: bool,
};

/// A graphics pipeline and the facts its draws are checked against: the loaded description, the
/// Vulkan binding each vertex layout feeds, and the pipeline's resource bindings in order.
const VulkanPipeline = struct {
    pipeline: raster_mod.Pipeline,
    loaded: backend.LoadedRenderArtifact,
    layouts: [raster_mod.max_vertex_buffers]VertexLayout,
    bindings: [raster_mod.max_descriptors]backend.RenderBindingDesc,
};

const VulkanBindings = struct {
    set: raster_mod.BindingSet,
    pipeline_id: BackendObjectId,
};

const VulkanBundle = struct {
    command_buffer: driver_mod.VkCommandBuffer,
    draw_count: u32,
};

const VulkanSurface = struct {
    surface: runtime_mod.Surface,
    handle: backend.SurfaceHandle,
    acquired_frame: ?BackendObjectId = null,
    acquired_texture: ?BackendObjectId = null,
};

/// A swapchain image a surface lends for one frame, and the surface that lent it.
const VulkanTexture = struct {
    handle: backend.TextureHandle,
    image: runtime_mod.SurfaceImage,
    surface_id: BackendObjectId,
};

const VulkanSurfaceFrame = struct {
    surface_id: BackendObjectId,
    texture_id: BackendObjectId,
    image_index: u32,
    generation: u64,
    written: bool = false,
    presented: bool = false,
};

pub fn staticCapabilities() backend.BackendCapabilities {
    return capabilitiesFrom(null, false);
}

fn capabilitiesFrom(caps: ?runtime_mod.Runtime.Caps, has_runtime: bool) backend.BackendCapabilities {
    var dtypes = backend.DTypeSet.init(&.{ .i32, .u32, .f32 });
    if (caps) |actual| {
        if (actual.storage_buffer8) dtypes.insert(.i1);
        if (actual.shader_float16 and actual.storage_buffer16) dtypes.insert(.f16);
        if (actual.shader_float64) dtypes.insert(.f64);
        if (actual.shader_int8 and actual.storage_buffer8) {
            dtypes.insert(.i8);
            dtypes.insert(.u8);
        }
        if (actual.shader_int16 and actual.storage_buffer16) {
            dtypes.insert(.i16);
            dtypes.insert(.u16);
        }
        if (actual.shader_int64) {
            dtypes.insert(.i64);
            dtypes.insert(.u64);
        }
    } else {
        dtypes.insert(.i1);
    }

    const subgroup_size_reported = if (caps) |actual| actual.subgroup_size else 0;
    const subgroup_stages = if (caps) |actual| actual.subgroup_supported_stages else 0;
    const subgroup_operations = if (caps) |actual| actual.subgroup_supported_operations else 0;
    const subgroup_supported = subgroup_size_reported != 0 and
        hasAllBits(subgroup_stages, driver_mod.VK_SHADER_STAGE_COMPUTE_BIT) and
        hasAllBits(subgroup_operations, driver_mod.VK_SUBGROUP_FEATURE_BASIC_BIT);
    const subgroup_size = if (subgroup_supported) subgroup_size_reported else 0;
    return .{
        .identity = .{
            .backend = .vulkan,
            .family = .vulkan,
            .name = if (caps) |actual| actual.vendor_name else "vulkan",
            .vendor_id = if (caps) |actual| actual.vendor_id else null,
        },
        .memory = .{
            .min_buffer_alignment = 16,
            .host_visible_device_memory = true,
        },
        .subgroup = .{
            .supported = subgroup_supported,
            .size_min = subgroup_size,
            .size_max = subgroup_size,
            .shuffle = subgroup_supported and hasAllBits(
                subgroup_operations,
                driver_mod.VK_SUBGROUP_FEATURE_SHUFFLE_BIT |
                    driver_mod.VK_SUBGROUP_FEATURE_SHUFFLE_RELATIVE_BIT,
            ),
            .ballot = subgroup_supported and
                hasAllBits(subgroup_operations, driver_mod.VK_SUBGROUP_FEATURE_BALLOT_BIT),
            .vote = subgroup_supported and
                hasAllBits(subgroup_operations, driver_mod.VK_SUBGROUP_FEATURE_VOTE_BIT),
            .arithmetic = subgroup_supported and
                hasAllBits(subgroup_operations, driver_mod.VK_SUBGROUP_FEATURE_ARITHMETIC_BIT),
            .scan = subgroup_supported and
                hasAllBits(subgroup_operations, driver_mod.VK_SUBGROUP_FEATURE_ARITHMETIC_BIT),
        },
        .threadgroup = .{
            .max_threads = 1024,
            .max_blocks = .{ 65_535, 65_535, 65_535 },
            .max_threads_per_dim = .{ 1024, 1024, 64 },
            .max_grid_per_dim = .{ 65_535, 65_535, 65_535 },
        },
        .dtypes = dtypes,
        .layouts = .{
            .row_major = true,
            .compact_strides = true,
            .broadcast_strides = true,
            .tiled = true,
            .opaque_backend_layouts = true,
        },
        .runtime = .{
            .driver_loaded = has_runtime,
            .device_context = has_runtime,
            .streams = true,
            .events = true,
            .timeline_events = true,
        },
        .features = .{
            .atomic_i32 = true,
            .atomic_u32 = true,
            .atomic_index = true,
        },
        .artifact_formats = backend.ArtifactFormatSet.init(&.{.vulkan_spirv}),
        .surfaces = .{
            .supported = has_runtime,
            .platforms = backend.SurfacePlatformSet.init(&.{.x11}),
            .formats = backend.TextureFormatSet.init(&.{ .rgba8_unorm, .bgra8_unorm }),
            .color_spaces = backend.ColorSpaceSet.init(&.{.srgb}),
            .present_modes = backend.PresentModeSet.init(&.{ .fifo, .mailbox, .immediate }),
            .usages = .{
                .copy_src = true,
                .copy_dst = true,
                .color_attachment = true,
                .present = true,
            },
            .max_extent = .{ .width = 16_384, .height = 16_384 },
            .max_frames_in_flight = 4,
        },
    };
}

fn hasAllBits(actual: u32, required: u32) bool {
    return actual & required == required;
}

fn queryCapabilities(ptr: *anyopaque) backend.BackendError!backend.BackendCapabilities {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (state.caps) |caps| return caps;
    const rt = state.runtime.ptr() orelse return staticCapabilities();
    const runtime_caps = rt.queryCapabilities() catch |err| return mapRuntimeError(err);
    var caps = capabilitiesFrom(runtime_caps, true);
    caps.float_controls = queryFloatControls(rt);
    if (state.rasterState()) |raster| {
        addRasterCapabilities(&caps, raster);
    } else |err| switch (err) {
        error.CapabilityMismatch => {},
        else => return err,
    }
    state.caps = caps;
    return caps;
}

/// VkPhysicalDeviceFloatControlsProperties is a Vulkan 1.2 properties-chain node.
const FloatProperties = extern struct {
    sType: driver_mod.VkStructureType = 1000197000,
    pNext: ?*anyopaque = null,
    denormBehaviorIndependence: u32 = 0,
    roundingModeIndependence: u32 = 0,
    shaderSignedZeroInfNanPreserveFloat16: driver_mod.VkBool32 = 0,
    shaderSignedZeroInfNanPreserveFloat32: driver_mod.VkBool32 = 0,
    shaderSignedZeroInfNanPreserveFloat64: driver_mod.VkBool32 = 0,
    shaderDenormPreserveFloat16: driver_mod.VkBool32 = 0,
    shaderDenormPreserveFloat32: driver_mod.VkBool32 = 0,
    shaderDenormPreserveFloat64: driver_mod.VkBool32 = 0,
    shaderDenormFlushToZeroFloat16: driver_mod.VkBool32 = 0,
    shaderDenormFlushToZeroFloat32: driver_mod.VkBool32 = 0,
    shaderDenormFlushToZeroFloat64: driver_mod.VkBool32 = 0,
    shaderRoundingModeRTEFloat16: driver_mod.VkBool32 = 0,
    shaderRoundingModeRTEFloat32: driver_mod.VkBool32 = 0,
    shaderRoundingModeRTEFloat64: driver_mod.VkBool32 = 0,
    shaderRoundingModeRTZFloat16: driver_mod.VkBool32 = 0,
    shaderRoundingModeRTZFloat32: driver_mod.VkBool32 = 0,
    shaderRoundingModeRTZFloat64: driver_mod.VkBool32 = 0,
};

fn queryFloatControls(rt: *Runtime) backend.FloatControlFacts {
    var float_props = FloatProperties{};
    var props = driver_mod.VkPhysicalDeviceProperties2{
        .sType = driver_mod.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
        .pNext = @ptrCast(&float_props),
        .properties = undefined,
    };
    rt._driver.vkGetPhysicalDeviceProperties2(rt._physical_device, &props);
    return floatFactsFrom(float_props);
}

fn floatFactsFrom(float_props: FloatProperties) backend.FloatControlFacts {
    return .{
        .denorm_preserve = .{
            .f16 = float_props.shaderDenormPreserveFloat16 == driver_mod.VK_TRUE,
            .f32 = float_props.shaderDenormPreserveFloat32 == driver_mod.VK_TRUE,
            .f64 = float_props.shaderDenormPreserveFloat64 == driver_mod.VK_TRUE,
        },
        .signed_zero_inf_nan_preserve = .{
            .f16 = float_props.shaderSignedZeroInfNanPreserveFloat16 == driver_mod.VK_TRUE,
            .f32 = float_props.shaderSignedZeroInfNanPreserveFloat32 == driver_mod.VK_TRUE,
            .f64 = float_props.shaderSignedZeroInfNanPreserveFloat64 == driver_mod.VK_TRUE,
        },
        .rounding_rte = .{
            .f16 = float_props.shaderRoundingModeRTEFloat16 == driver_mod.VK_TRUE,
            .f32 = float_props.shaderRoundingModeRTEFloat32 == driver_mod.VK_TRUE,
            .f64 = float_props.shaderRoundingModeRTEFloat64 == driver_mod.VK_TRUE,
        },
        .denorm_behavior_independence = switch (float_props.denormBehaviorIndependence) {
            0 => .bit32_only,
            1 => .all,
            2 => .none,
            else => null,
        },
    };
}

const color_formats = [_]backend.TextureFormat{ .rgba8_unorm, .bgra8_unorm, .rgba8_srgb, .bgra8_srgb };

/// Every feature a color texture needs for any usage the textures report: sampling with either
/// filter, blended attachment writes, and both transfer directions.
const color_features = driver_mod.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
    driver_mod.VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT |
    driver_mod.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT |
    driver_mod.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT |
    driver_mod.VK_FORMAT_FEATURE_TRANSFER_SRC_BIT |
    driver_mod.VK_FORMAT_FEATURE_TRANSFER_DST_BIT;

const depth_features = driver_mod.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
    driver_mod.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT |
    driver_mod.VK_FORMAT_FEATURE_TRANSFER_SRC_BIT |
    driver_mod.VK_FORMAT_FEATURE_TRANSFER_DST_BIT;

/// Reports textures and rasterization for the formats whose every needed feature the device
/// reports, so a texture of a reported format serves every reported usage its aspect allows.
fn addRasterCapabilities(caps: *backend.BackendCapabilities, raster: *const raster_mod.Raster) void {
    var targets: backend.TextureFormatSet = .{};
    for (color_formats) |format| {
        const vk_format = vulkanFormat(format) catch unreachable;
        if (hasAllBits(raster.formatFeatures(vk_format), color_features)) targets.insert(format);
    }
    var depths: backend.TextureFormatSet = .{};
    if (hasAllBits(raster.formatFeatures(driver_mod.VK_FORMAT_D32_SFLOAT), depth_features)) depths.insert(.depth32_float);
    var formats = targets;
    formats.bits |= depths.bits;
    caps.textures = .{
        .supported = true,
        .formats = formats,
        .usages = .{
            .copy_src = true,
            .copy_dst = true,
            .sampled = true,
            .color_attachment = true,
            .depth_attachment = true,
        },
        .max_extent = .{ .width = raster.max_image_extent, .height = raster.max_image_extent, .depth = 1 },
        .max_sample_count = 1,
    };
    caps.raster = .{
        .supported = true,
        .artifact_formats = backend.RenderArtifactFormatSet.init(&.{.vulkan_spirv}),
        .target_formats = targets,
        .depth_formats = depths,
        .blend_modes = backend.RenderBlendModeSet.init(&.{ .replace, .alpha_premultiplied, .alpha_straight, .additive }),
        .topologies = backend.RenderPrimitiveTopologySet.init(&.{ .triangle_list, .triangle_strip, .line_list, .line_strip }),
        .vertex_formats = backend.RenderVertexFormatSet.init(&.{ .float32, .float32x2, .float32x3, .float32x4, .uint32, .uint32x2, .uint32x4 }),
        .binding_kinds = backend.RenderBindingKindSet.init(&.{ .uniform_buffer, .sampled_texture }),
        .index_formats = backend.RenderIndexFormatSet.init(&.{ .none, .u16, .u32 }),
        .max_vertex_buffers = raster.max_vertex_buffers,
        .max_vertex_attributes = raster.max_vertex_attributes,
        .max_bindings = raster_mod.max_descriptors,
        .instancing = true,
        .max_push_constant_bytes = raster.max_push_constant_bytes,
        .depth_bias = true,
        .depth_bias_clamp = raster.runtime._depth_bias_clamp,
    };
}

fn createArtifact(ptr: *anyopaque, request: backend.CompileRequest) backend.BackendError!backend.KernelArtifact {
    if (request.requested_format != .vulkan_spirv) return error.UnsupportedOperation;
    const state: *State = @ptrCast(@alignCast(ptr));
    return switch (request.payload) {
        .words_u32 => |words| createSpirvArtifact(state, request, words),
        .none => error.UnsupportedOperation,
        else => error.UnsupportedOperation,
    };
}

fn createSpirvArtifact(
    state: *State,
    request: backend.CompileRequest,
    words: []const u32,
) backend.BackendError!backend.KernelArtifact {
    if (request.kernel_name.len == 0) return error.InvalidArtifact;
    if (words.len == 0) return error.InvalidArtifact;

    var artifact = backend.KernelArtifact.init(state.allocator, .{
        .backend = .vulkan,
        .format = .vulkan_spirv,
        .entry_name = request.kernel_name,
        .argument_count = request.argument_count,
        .scalar_argument_count = request.scalar_argument_count,
        .diagnostic_id = request.diagnostic_id,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    try artifact.setOwnedWords(words);
    return artifact;
}

fn loadArtifact(ptr: *anyopaque, artifact: *const backend.KernelArtifact) backend.BackendError!backend.LoadedArtifact {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (artifact.backend != .vulkan) return error.CapabilityMismatch;
    if (artifact.format != .vulkan_spirv) return error.UnsupportedArtifactFormat;
    if (artifact.entry_name.len == 0) return error.InvalidArtifact;
    const buffer_argument_count = try artifact.bufferArgumentCount();
    if (buffer_argument_count > runtime_mod.max_buffers_per_set) return error.InvalidArtifact;

    const words = switch (artifact.payload) {
        .words_u32 => |words| words,
        else => return error.InvalidArtifact,
    };
    if (words.len == 0) return error.InvalidArtifact;

    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const entry_name = state.allocator.dupeSentinel(u8, artifact.entry_name, 0) catch return error.OutOfMemory;
    errdefer state.allocator.free(entry_name);

    const push_constants = artifact.interface.push_constants;
    if (push_constants.count != artifact.scalar_argument_count) return error.InvalidArtifact;
    const push_constant_size: u32 = push_constants.byte_size;
    var kernel = launch_mod.compile(rt, words, entry_name, buffer_argument_count, push_constant_size) catch |err| return mapArtifactError(err);
    errdefer kernel.deinit();

    const id = try state.putObject(.{ .loaded_artifact = .{
        .kernel = kernel,
        .entry_name = entry_name,
        .buffer_argument_count = buffer_argument_count,
        .scalar_argument_count = artifact.scalar_argument_count,
        .push_constants = push_constants,
    } });
    return .{
        .id = id,
        .backend = .vulkan,
        .format = .vulkan_spirv,
    };
}

fn allocateBuffer(ptr: *anyopaque, request: backend.BufferAllocation) backend.BackendError!backend.BufferHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (request.byte_size == 0) return error.InvalidBuffer;
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;

    var buffer = runtime_mod.DeviceBuffer.alloc(rt, request.byte_size) catch |err| return mapAllocationError(err);
    errdefer buffer.deinit();

    const id = try state.putObject(.{ .buffer = buffer });
    return .{
        .id = id,
        .backend = .vulkan,
        .byte_size = request.byte_size,
        .ownership = .backend,
    };
}

fn createSurface(ptr: *anyopaque, request: backend.SurfaceCreationRequest) backend.BackendError!backend.SurfaceHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const desc = try surfaceDescFromRequest(request);

    var surface = rt.createXlibSurface(desc) catch |err| return mapSurfaceRuntimeError(err);
    errdefer surface.deinit();

    const handle = backend.SurfaceHandle{
        .id = 0,
        .backend = .vulkan,
        .platform = request.platform.kind(),
        .extent = .{ .width = surface.extent.width, .height = surface.extent.height },
        .format = request.format,
        .color_space = request.color_space,
        .present_mode = request.present_mode,
        .generation = surface.generation,
    };
    const id = try state.putObject(.{ .surface = .{
        .surface = surface,
        .handle = handle,
    } });
    const object = state.objects.getPtr(id).?;
    switch (object.*) {
        .surface => |*stored| stored.handle.id = id,
        else => unreachable,
    }
    return switch (object.*) {
        .surface => |*stored| stored.handle,
        else => unreachable,
    };
}

fn destroySurface(ptr: *anyopaque, handle: backend.SurfaceHandle) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const surface = try state.getSurface(handle);
    if (surface.handle.generation != handle.generation) return error.SurfaceFrameExpired;
    if (surface.acquired_frame != null) return error.SurfaceAlreadyAcquired;
    const entry = state.objects.fetchRemove(handle.id) orelse return error.InvalidSurface;
    var object = entry.value;
    deinitObject(state, &object);
}

fn destroyTexture(ptr: *anyopaque, handle: backend.TextureHandle) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (state.getAnyImage(handle)) |image| {
        if (image.target != null) return error.InvalidTexture;
        const entry = state.objects.fetchRemove(handle.id).?;
        var object = entry.value;
        deinitObject(state, &object);
        return;
    } else |_| {}
    _ = try state.getTexture(handle);
    var it = state.objects.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .surface => |*surface| {
                if (surface.acquired_texture == handle.id) return error.SurfaceAlreadyAcquired;
            },
            else => {},
        }
    }
    const entry = state.objects.fetchRemove(handle.id) orelse return error.InvalidTexture;
    var object = entry.value;
    deinitObject(state, &object);
}

fn acquireSurfaceFrame(
    ptr: *anyopaque,
    request: backend.SurfaceFrameAcquireRequest,
) backend.BackendError!backend.SurfaceFrame {
    const state: *State = @ptrCast(@alignCast(ptr));
    try state.objects.ensureUnusedCapacity(state.allocator, 2);
    const surface = try state.getSurface(request.surface);
    if (surface.handle.generation != request.surface.generation) return error.SurfaceFrameExpired;
    if (surface.acquired_frame != null) return error.SurfaceAlreadyAcquired;

    const texture_id = state.next_id;
    if (texture_id == std.math.maxInt(BackendObjectId)) return error.OutOfMemory;
    const frame_id = texture_id + 1;
    if (frame_id == std.math.maxInt(BackendObjectId)) return error.OutOfMemory;
    state.next_id = frame_id + 1;

    const image = surface.surface.acquire() catch |err| return mapSurfaceRuntimeError(err);

    const texture = backend.TextureHandle{
        .id = texture_id,
        .backend = .vulkan,
        .extent = .{
            .width = image.extent.width,
            .height = image.extent.height,
            .depth = 1,
        },
        .format = request.surface.format,
        .usage = textureUsageFromImageUsage(image.usage),
        .sample_count = 1,
        .ownership = .acquired_surface,
    };
    const frame_surface = surface.handle;
    const view = backend.TextureView{
        .texture = texture,
        .format = texture.format,
    };
    const frame = backend.SurfaceFrame{
        .id = frame_id,
        .backend = .vulkan,
        .surface = frame_surface,
        .texture = texture,
        .view = view,
        .index = image.image_index,
        .generation = image.generation,
        .token = image.image,
    };

    surface.acquired_frame = frame_id;
    surface.acquired_texture = texture_id;
    state.objects.putAssumeCapacityNoClobber(texture_id, .{ .texture = .{
        .handle = texture,
        .image = image,
        .surface_id = request.surface.id,
    } });
    state.objects.putAssumeCapacityNoClobber(frame_id, .{ .surface_frame = .{
        .surface_id = request.surface.id,
        .texture_id = texture_id,
        .image_index = image.image_index,
        .generation = image.generation,
    } });
    return frame;
}

fn presentSurfaceFrame(ptr: *anyopaque, request: backend.PresentRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (request.signal_event != null) return error.UnsupportedOperation;
    const surface = try state.getSurface(request.surface);
    const frame = try state.getFrame(request.frame);
    if (surface.handle.generation != request.surface.generation) return error.SurfaceFrameExpired;
    if (frame.generation != request.frame.generation) return error.SurfaceFrameExpired;
    if (frame.presented) return error.SurfaceFrameExpired;
    if (frame.surface_id != request.surface.id) return error.InvalidSurfaceFrame;
    if (frame.texture_id != request.frame.texture.id) return error.InvalidSurfaceFrame;
    if (surface.acquired_frame == null or surface.acquired_frame.? != request.frame.id) return error.InvalidSurfaceFrame;

    for (request.wait_events) |event_handle| {
        const event = try state.getEvent(event_handle);
        if (!event.recorded) return error.InvalidEvent;
        event.synchronize() catch |err| return mapRuntimeError(err);
    }

    // The image goes back to the swapchain whether or not the presentation succeeds, so a caller
    // can destroy a surface whose swapchain went out of date.
    frame.presented = true;
    surface.acquired_frame = null;
    surface.acquired_texture = null;
    surface.surface.present(frame.image_index, frame.generation) catch |err| return mapSurfaceRuntimeError(err);
}

/// The surface, frame, and texture of a frame the surface still holds unpresented.
fn liveFrame(
    state: *State,
    request_surface: backend.SurfaceHandle,
    request_frame: backend.SurfaceFrame,
) backend.BackendError!struct { *VulkanSurface, *VulkanSurfaceFrame, *VulkanTexture } {
    const surface = try state.getSurface(request_surface);
    const frame = try state.getFrame(request_frame);
    if (surface.handle.generation != request_surface.generation) return error.SurfaceFrameExpired;
    if (frame.generation != request_frame.generation) return error.SurfaceFrameExpired;
    if (frame.presented) return error.SurfaceFrameExpired;
    if (frame.surface_id != request_surface.id) return error.InvalidSurfaceFrame;
    if (frame.texture_id != request_frame.texture.id) return error.InvalidSurfaceFrame;
    if (surface.acquired_frame == null or surface.acquired_frame.? != request_frame.id) return error.InvalidSurfaceFrame;
    return .{ surface, frame, try state.getTexture(request_frame.texture) };
}

fn writeSurfaceFrame(ptr: *anyopaque, request: backend.SurfaceFrameWriteRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const surface, const frame, const texture = try liveFrame(state, request.surface, request.frame);
    if (frame.written) return error.SurfaceFrameExpired;

    if (request.wait_events.len > runtime_mod.max_surface_wait_events) return error.LaunchArgumentMismatch;
    var wait_events: [runtime_mod.max_surface_wait_events]*runtime_mod.Event = undefined;
    for (request.wait_events, 0..) |event_handle, index| {
        const event = try state.getEvent(event_handle);
        if (!event.recorded) return error.InvalidEvent;
        wait_events[index] = event;
    }
    const signal_event = if (request.signal_event) |event_handle| try state.getEvent(event_handle) else null;

    const ops = state.allocator.alloc(runtime_mod.SurfaceWriteOp, request.operations.len) catch return error.OutOfMemory;
    defer state.allocator.free(ops);
    for (request.operations, 0..) |op, index| {
        ops[index] = switch (op) {
            .clear => |color| .{ .clear = .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a } },
            .copy_buffer => |buffer_handle| .{ .copy_buffer = try state.getBuffer(buffer_handle) },
        };
    }
    surface.surface.write(texture.image, ops, wait_events[0..request.wait_events.len], signal_event) catch |err| return mapSurfaceRuntimeError(err);
    frame.written = true;
}

fn readSurfaceFrame(ptr: *anyopaque, request: backend.SurfaceFrameReadRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const surface, _, const texture = try liveFrame(state, request.surface, request.frame);
    const buffer = try state.getBuffer(request.buffer);
    surface.surface.read(texture.image, buffer) catch |err| return mapSurfaceRuntimeError(err);
}

fn createStream(ptr: *anyopaque, _: backend.StreamAllocation) backend.BackendError!backend.StreamHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;

    const stream = rt.createStream() catch |err| return mapRuntimeError(err);
    errdefer rt.destroyStream(stream);

    const id = try state.putObject(.{ .stream = stream });
    return .{
        .id = id,
        .backend = .vulkan,
    };
}

fn createEvent(ptr: *anyopaque, _: backend.EventAllocation) backend.BackendError!backend.EventHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;

    const event = rt.createEvent() catch |err| return mapRuntimeError(err);
    errdefer rt.destroyEvent(event);

    const id = try state.putObject(.{ .event = event });
    return .{
        .id = id,
        .backend = .vulkan,
    };
}

fn writeBuffer(ptr: *anyopaque, request: backend.BufferWriteRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const buffer = try state.getBuffer(request.handle);
    if (request.bytes.len > buffer.size) return error.InvalidBuffer;
    buffer.copyFromHost(request.bytes) catch |err| return mapAllocationError(err);
}

fn readBuffer(ptr: *anyopaque, request: backend.BufferReadRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const buffer = try state.getBuffer(request.handle);
    if (request.bytes.len < buffer.size) return error.ReadBufferDestinationTooSmall;
    buffer.copyToHost(request.bytes) catch |err| return mapAllocationError(err);
}

fn launch(ptr: *anyopaque, request: backend.LaunchRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (request.geometry.dynamic_shared_memory_bytes != 0) return error.UnsupportedOperation;
    if (request.artifact.backend != .vulkan or request.artifact.format != .vulkan_spirv) {
        return error.CapabilityMismatch;
    }
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const loaded_handle = request.loaded_artifact orelse return error.InvalidArtifact;
    const loaded = try state.getLoaded(loaded_handle);
    if (request.buffers.len != @as(usize, @intCast(loaded.buffer_argument_count))) {
        return error.LaunchArgumentMismatch;
    }
    if (request.scalar_arguments.len != @as(usize, @intCast(loaded.scalar_argument_count))) {
        return error.LaunchArgumentMismatch;
    }
    if (request.buffers.len > runtime_mod.max_buffers_per_set) return error.LaunchArgumentMismatch;

    var push_storage: [gpu_abi.max_push_constant_bytes]u8 = undefined;
    const push_size = try loaded.push_constants.pack(request.scalar_arguments, &push_storage);

    var args: [runtime_mod.max_buffers_per_set]*runtime_mod.DeviceBuffer = undefined;
    for (request.buffers, 0..) |binding, i| {
        if (binding.handle.backend != .vulkan or binding.ownership != .backend) return error.InvalidBuffer;
        const buffer = try state.getBuffer(binding.handle);
        if (binding.byte_size > buffer.size or binding.handle.byte_size != buffer.size) {
            return error.InvalidBuffer;
        }
        args[i] = buffer;
    }

    const stream = if (request.stream) |stream_handle|
        try state.getStream(stream_handle)
    else
        rt.defaultStream() catch |err| return mapRuntimeError(err);

    if (request.wait_events.len > launch_mod.max_wait_events) return error.LaunchArgumentMismatch;
    var wait_events: [launch_mod.max_wait_events]*runtime_mod.Event = undefined;
    for (request.wait_events, 0..) |event_handle, i| {
        const event = try state.getEvent(event_handle);
        if (!event.recorded) return error.InvalidEvent;
        wait_events[i] = event;
    }

    const signal_event = if (request.signal_event) |event_handle|
        try state.getEvent(event_handle)
    else
        null;

    loaded.kernel.launch(
        stream,
        args[0..request.buffers.len],
        push_storage[0..push_size],
        request.geometry.grid,
        request.geometry.threadgroup,
        wait_events[0..request.wait_events.len],
        signal_event,
    ) catch |err| return mapLaunchError(err);
}

fn synchronize(ptr: *anyopaque, request: backend.SyncRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    switch (request.scope) {
        .default_stream => {
            const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
            const stream = rt.defaultStream() catch |err| return mapRuntimeError(err);
            stream.synchronize() catch |err| return mapRuntimeError(err);
        },
        .device => {
            const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
            rt.synchronize() catch |err| return mapRuntimeError(err);
        },
        .stream => {
            const stream = try state.getStream(request.stream.?);
            stream.synchronize() catch |err| return mapRuntimeError(err);
        },
        .event => {
            const event = try state.getEvent(request.event.?);
            if (!event.recorded) return error.InvalidEvent;
            event.synchronize() catch |err| return mapRuntimeError(err);
        },
    }
}

fn queryEvent(ptr: *anyopaque, request: backend.EventQueryRequest) backend.BackendError!bool {
    const state: *State = @ptrCast(@alignCast(ptr));
    const event = try state.getEvent(request.event);
    if (!event.recorded) return false;
    return event.query() catch |err| return mapRuntimeError(err);
}

fn recordEvent(ptr: *anyopaque, request: backend.EventRecordRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const stream = try state.getStream(request.stream);
    const event = try state.getEvent(request.event);
    event.record(stream) catch |err| return mapRuntimeError(err);
}

fn elapsedEventNs(ptr: *anyopaque, request: backend.EventElapsedRequest) backend.BackendError!u64 {
    const state: *State = @ptrCast(@alignCast(ptr));
    const start = try state.getEvent(request.start);
    const end = try state.getEvent(request.end);
    return end.elapsedNs(start) catch |err| return mapElapsedEventError(err);
}

fn destroyObject(ptr: *anyopaque, id: BackendObjectId) void {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (state.objects.fetchRemove(id)) |entry| {
        var object = entry.value;
        deinitObject(state, &object);
    }
}

fn deinitHandle(ptr: *anyopaque, allocator: Allocator) void {
    _ = allocator;
    const state: *State = @ptrCast(@alignCast(ptr));
    state.deinit();
}

fn deinitObject(state: *State, object: *Object) void {
    switch (object.*) {
        .loaded_artifact => |*loaded| {
            loaded.kernel.deinit();
            state.allocator.free(loaded.entry_name);
        },
        .sequence => |*sequence| sequence.deinit(),
        .image => |*texture| texture.image.destroy(state.liveRaster()),
        .render_pipeline => |*pipeline| pipeline.pipeline.destroy(state.liveRaster()),
        .render_bindings => |*bindings| bindings.set.destroy(state.liveRaster()),
        .render_bundle => |bundle| state.liveRaster().freeBundle(bundle.command_buffer),
        .dmabuf_target => |shared| {
            shared.target.destroy(state.liveRaster());
            state.allocator.destroy(shared);
        },
        .buffer => |*buffer| buffer.deinit(),
        .stream => |stream| stream._runtime.destroyStream(stream),
        .event => |event| event._runtime.destroyEvent(event),
        .surface => |*surface| surface.surface.deinit(),
        .texture, .surface_frame => {},
    }
    object.* = undefined;
}

fn allocateTexture(ptr: *anyopaque, request: backend.TextureAllocation) backend.BackendError!backend.TextureHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const raster = try state.rasterState();
    if (request.sample_count != 1 or request.extent.depth != 1) return error.CapabilityMismatch;
    if (request.usage.present or request.usage.storage) return error.CapabilityMismatch;
    const depth = request.format.isDepth();
    if (depth and request.usage.color_attachment) return error.CapabilityMismatch;
    if (!depth and request.usage.depth_attachment) return error.CapabilityMismatch;
    try state.objects.ensureUnusedCapacity(state.allocator, 1);

    var image = raster_mod.Image.create(raster, .{
        .width = request.extent.width,
        .height = request.extent.height,
        .format = try vulkanFormat(request.format),
        .usage = imageUsageFromTextureUsage(request.usage),
        .aspect = if (depth) driver_mod.VK_IMAGE_ASPECT_DEPTH_BIT else driver_mod.VK_IMAGE_ASPECT_COLOR_BIT,
        .texel_bytes = request.format.texelBytes(),
    }) catch |err| return mapRasterError(err, error.InvalidTexture);
    errdefer image.destroy(raster);

    var texture = backend.TextureHandle{
        .id = 0,
        .backend = .vulkan,
        .extent = request.extent,
        .format = request.format,
        .usage = request.usage,
        .sample_count = 1,
        .ownership = .backend,
    };
    texture.id = try state.putObject(.{ .image = .{ .handle = texture, .image = image } });
    state.objects.getPtr(texture.id).?.image.handle.id = texture.id;
    return texture;
}

fn writeTexture(ptr: *anyopaque, request: backend.TextureWriteRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const texture = try state.getImage(request.texture);
    texture.image.write(state.liveRaster(), request.bytes) catch |err| return mapRasterError(err, error.InvalidTexture);
}

fn readTexture(ptr: *anyopaque, request: backend.TextureReadRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const texture = try state.getImage(request.texture);
    texture.image.read(state.liveRaster(), request.bytes) catch |err| return mapRasterError(err, error.InvalidTexture);
}

fn createRenderArtifact(ptr: *anyopaque, desc: backend.RenderPipelineDesc) backend.BackendError!backend.RenderArtifact {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (desc.format != .vulkan_spirv) return error.UnsupportedArtifactFormat;
    const words = switch (desc.payload) {
        .words_u32 => |words| words,
        else => return error.InvalidRenderArtifact,
    };
    if (words.len == 0) return error.InvalidRenderArtifact;
    var artifact = backend.RenderArtifact.init(state.allocator, .{
        .backend = .vulkan,
        .pipeline = desc,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    try artifact.setOwnedWords(words);
    return artifact;
}

/// Builds the pipeline an artifact describes. Every resource binding must sit in group 0, and each
/// vertex layout's binding must be below the vertex buffer limit and used once.
fn loadRenderArtifact(ptr: *anyopaque, artifact: *const backend.RenderArtifact) backend.BackendError!backend.LoadedRenderArtifact {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (artifact.backend != .vulkan) return error.CapabilityMismatch;
    if (artifact.format != .vulkan_spirv) return error.UnsupportedArtifactFormat;
    const words = switch (artifact.payload) {
        .words_u32 => |words| words,
        else => return error.InvalidRenderArtifact,
    };
    if (words.len == 0) return error.InvalidRenderArtifact;
    const raster = try state.rasterState();
    if (artifact.vertex_layouts.len > raster.max_vertex_buffers) return error.CapabilityMismatch;
    if (artifact.bindings.len > raster_mod.max_descriptors) return error.CapabilityMismatch;
    try state.objects.ensureUnusedCapacity(state.allocator, 1);

    var object: VulkanPipeline = .{
        .pipeline = undefined,
        .loaded = undefined,
        .layouts = undefined,
        .bindings = undefined,
    };
    var vertex_bindings: [raster_mod.max_vertex_buffers]driver_mod.VkVertexInputBindingDescription = undefined;
    var vertex_attributes: [raster_mod.max_vertex_attributes]driver_mod.VkVertexInputAttributeDescription = undefined;
    var attribute_count: usize = 0;
    var used_vertex_bindings: u32 = 0;
    for (artifact.vertex_layouts, 0..) |layout, index| {
        if (layout.binding >= raster_mod.max_vertex_buffers) return error.CapabilityMismatch;
        const bit = @as(u32, 1) << @intCast(layout.binding);
        if (used_vertex_bindings & bit != 0) return error.InvalidRenderArtifact;
        used_vertex_bindings |= bit;
        const per_instance = layout.step_mode == .instance;
        vertex_bindings[index] = .{
            .binding = layout.binding,
            .stride = layout.stride,
            .inputRate = if (per_instance) driver_mod.VK_VERTEX_INPUT_RATE_INSTANCE else driver_mod.VK_VERTEX_INPUT_RATE_VERTEX,
        };
        object.layouts[index] = .{ .binding = layout.binding, .stride = layout.stride, .per_instance = per_instance };
        const start: usize = layout.attribute_start;
        const count: usize = layout.attribute_count;
        if (start > artifact.vertex_attributes.len or count > artifact.vertex_attributes.len - start) return error.InvalidRenderArtifact;
        for (artifact.vertex_attributes[start..][0..count]) |attribute| {
            if (attribute_count == raster.max_vertex_attributes) return error.CapabilityMismatch;
            vertex_attributes[attribute_count] = .{
                .location = attribute.location,
                .binding = layout.binding,
                .format = vertexFormat(attribute.format),
                .offset = attribute.offset,
            };
            attribute_count += 1;
        }
    }
    var descriptors: [raster_mod.max_descriptors]driver_mod.VkDescriptorSetLayoutBinding = undefined;
    var used_descriptor_bindings: u64 = 0;
    for (artifact.bindings, 0..) |binding, index| {
        if (binding.group != 0 or binding.binding >= 64) return error.CapabilityMismatch;
        const bit = @as(u64, 1) << @intCast(binding.binding);
        if (used_descriptor_bindings & bit != 0) return error.InvalidRenderArtifact;
        used_descriptor_bindings |= bit;
        descriptors[index] = .{
            .binding = binding.binding,
            .descriptorType = switch (binding.kind) {
                .uniform_buffer => driver_mod.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .sampled_texture => driver_mod.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .storage_buffer, .storage_texture => return error.CapabilityMismatch,
            },
            .descriptorCount = 1,
            .stageFlags = driver_mod.VK_SHADER_STAGE_VERTEX_BIT | driver_mod.VK_SHADER_STAGE_FRAGMENT_BIT,
            .pImmutableSamplers = null,
        };
        object.bindings[index] = binding;
    }

    const vertex_entry = state.allocator.dupeSentinel(u8, artifact.vertex_entry_name, 0) catch return error.OutOfMemory;
    defer state.allocator.free(vertex_entry);
    const fragment_entry = state.allocator.dupeSentinel(u8, artifact.fragment_entry_name, 0) catch return error.OutOfMemory;
    defer state.allocator.free(fragment_entry);
    const depth: ?raster_mod.DepthTest = if (artifact.depth) |depth_state| .{
        .format = try vulkanFormat(depth_state.format),
        .compare = vulkanCompare(depth_state.compare),
        .write = depth_state.write,
        .bias_constant = depth_state.bias.constant,
        .bias_slope = depth_state.bias.slope,
        .bias_clamp = depth_state.bias.clamp,
    } else null;
    if (artifact.push_constant_bytes > raster.max_push_constant_bytes) return error.CapabilityMismatch;
    if (depth) |test_state| {
        if (test_state.bias_clamp != 0 and !raster.runtime._depth_bias_clamp) return error.CapabilityMismatch;
    }
    object.pipeline = raster_mod.Pipeline.create(raster, .{
        .words = words,
        .vertex_entry = vertex_entry.ptr,
        .fragment_entry = fragment_entry.ptr,
        .color_format = try vulkanFormat(artifact.target_format),
        .depth = depth,
        .blend = switch (artifact.blend_mode) {
            .replace => .replace,
            .alpha_premultiplied => .alpha_premultiplied,
            .alpha_straight => .alpha_straight,
            .additive => .additive,
        },
        .cull = switch (artifact.cull) {
            .none => driver_mod.VK_CULL_MODE_NONE,
            .back => driver_mod.VK_CULL_MODE_BACK_BIT,
            .front => driver_mod.VK_CULL_MODE_FRONT_BIT,
        },
        .topology = vulkanTopology(artifact.topology),
        .vertex_bindings = vertex_bindings[0..artifact.vertex_layouts.len],
        .vertex_attributes = vertex_attributes[0..attribute_count],
        .descriptors = descriptors[0..artifact.bindings.len],
        .push_constant_bytes = artifact.push_constant_bytes,
    }) catch |err| return mapRasterError(err, error.InvalidRenderArtifact);
    errdefer object.pipeline.destroy(raster);

    const id = try state.putObject(.{ .render_pipeline = object });
    const loaded = backend.LoadedRenderArtifact.describing(artifact, id);
    state.objects.getPtr(id).?.render_pipeline.loaded = loaded;
    return loaded;
}

fn createRenderBindings(ptr: *anyopaque, request: backend.RenderBindingsRequest) backend.BackendError!backend.RenderBindings {
    const state: *State = @ptrCast(@alignCast(ptr));
    const raster = try state.rasterState();
    try state.objects.ensureUnusedCapacity(state.allocator, 1);
    const pipeline = try state.getRenderPipeline(request.pipeline);
    const count: usize = pipeline.loaded.binding_count;
    if (request.resources.len != count) return error.RenderArgumentMismatch;
    var descriptors: [raster_mod.max_descriptors]raster_mod.Descriptor = undefined;
    for (request.resources, pipeline.bindings[0..count], 0..) |resource, binding, index| {
        if (std.meta.activeTag(resource) != binding.kind) return error.RenderArgumentMismatch;
        descriptors[index] = .{ .binding = binding.binding, .resource = switch (resource) {
            .uniform_buffer => |buffer_handle| .{ .buffer = .{
                .buffer = (try state.getBuffer(buffer_handle))._buffer,
                .kind = driver_mod.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            } },
            .sampled_texture => |sampled| blk: {
                const texture = try state.getImage(sampled.texture);
                if (!texture.handle.usage.sampled) return error.InvalidTexture;
                const sampler = raster.sampler(.{
                    .filter = switch (sampled.sampler.filter) {
                        .nearest => driver_mod.VK_FILTER_NEAREST,
                        .linear => driver_mod.VK_FILTER_LINEAR,
                    },
                    .address = switch (sampled.sampler.address) {
                        .clamp_to_edge => driver_mod.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                        .repeat => driver_mod.VK_SAMPLER_ADDRESS_MODE_REPEAT,
                    },
                }) catch |err| return mapRasterError(err, error.RenderFailed);
                break :blk .{ .image = .{ .view = texture.image.view, .layout = texture.image.home, .sampler = sampler } };
            },
            .storage_buffer, .storage_texture => return error.CapabilityMismatch,
        } };
    }
    var set = raster_mod.BindingSet.create(raster, &pipeline.pipeline, descriptors[0..count]) catch |err| {
        return mapRasterError(err, error.RenderFailed);
    };
    errdefer set.destroy(raster);
    const id = try state.putObject(.{ .render_bindings = .{ .set = set, .pipeline_id = request.pipeline.id } });
    return .{ .id = id, .backend = .vulkan, .pipeline = request.pipeline.id };
}

/// Records and submits one pass. A pass into an acquired surface frame waits for the swapchain to
/// hand the image over, the first time the frame's image is touched, and leaves it ready to
/// present.
fn render(ptr: *anyopaque, request: backend.RenderRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const raster = try state.rasterState();
    const stream = try state.submitStream(request.stream);
    var wait_storage: [raster_mod.max_wait_events]*runtime_mod.Event = undefined;
    const waits = try state.submitWaits(request.wait_events, &wait_storage);
    const signal = if (request.signal_event) |event_handle| try state.getEvent(event_handle) else null;

    const cb = raster_mod.beginStreamPass(stream) catch |err| return mapRasterError(err, error.RenderFailed);
    var lender: ?*VulkanSurface = null;
    recordPassAndEnd(state, raster, cb, request.pass, &lender) catch |err| {
        runtime_mod.retireStreamCommandBuffer(stream, cb, stream.counter);
        return err;
    };
    raster_mod.submit(raster, .{
        .stream = stream,
        .cb = cb,
        .wait_events = waits,
        .signal_event = signal,
        .retire = true,
        .wait_semaphore = if (lender) |surface| surface.surface.acquireWait() else null,
    }) catch |err| return mapRasterError(err, error.RenderFailed);
    if (lender) |surface| surface.surface.touched(.{ .semaphore = stream._semaphore, .value = stream.counter });
}

fn recordRenderBundle(ptr: *anyopaque, pass: backend.RenderPass) backend.BackendError!backend.RenderBundle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const raster = try state.rasterState();
    try state.objects.ensureUnusedCapacity(state.allocator, 1);
    const cb = raster_mod.beginBundle(raster) catch |err| return mapRasterError(err, error.RenderFailed);
    errdefer raster.discardBundle(cb);
    // A swapchain lends a different image every frame, so a bundle never draws into one.
    var lender: ?*VulkanSurface = null;
    try recordPassAndEnd(state, raster, cb, pass, &lender);
    if (lender != null) return error.RenderArgumentMismatch;
    const draw_count: u32 = @intCast(pass.draws.len);
    const id = try state.putObject(.{ .render_bundle = .{ .command_buffer = cb, .draw_count = draw_count } });
    return .{ .id = id, .backend = .vulkan, .draw_count = draw_count };
}

fn submitRenderBundle(ptr: *anyopaque, request: backend.RenderBundleSubmit) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const raster = try state.rasterState();
    const bundle = try state.getRenderBundle(request.bundle);
    const stream = try state.submitStream(request.stream);
    var wait_storage: [raster_mod.max_wait_events]*runtime_mod.Event = undefined;
    const waits = try state.submitWaits(request.wait_events, &wait_storage);
    const signal = if (request.signal_event) |event_handle| try state.getEvent(event_handle) else null;
    raster_mod.submit(raster, .{
        .stream = stream,
        .cb = bundle.command_buffer,
        .wait_events = waits,
        .signal_event = signal,
        .retire = false,
    }) catch |err| return mapRasterError(err, error.RenderFailed);
}

fn recordPassAndEnd(
    state: *State,
    raster: *raster_mod.Raster,
    cb: driver_mod.VkCommandBuffer,
    pass: backend.RenderPass,
    lender: *?*VulkanSurface,
) backend.BackendError!void {
    try recordPass(state, raster, cb, pass, lender);
    const drv = &raster.runtime._driver;
    drv.fromResult(drv.vkEndCommandBuffer(cb)) catch |err| return mapRasterError(err, error.RenderFailed);
}

const VertexSlot = struct {
    id: BackendObjectId,
    offset: u64,
    size: u64,
};

const IndexSlot = struct {
    id: BackendObjectId,
    offset: u64,
    size: u64,
    format: backend.RenderIndexFormat,
};

/// Records one pass. A draw binds only what differs from the draw before it, so a run of draws
/// that share a pipeline, bindings and buffers costs one draw command each. Every range a draw
/// reads is checked against its buffer, except the vertices an indexed draw reaches through its
/// indices, which only the indices name.
fn recordPass(
    state: *State,
    raster: *raster_mod.Raster,
    cb: driver_mod.VkCommandBuffer,
    pass: backend.RenderPass,
    lender: *?*VulkanSurface,
) backend.BackendError!void {
    const drv = &raster.runtime._driver;
    const targets = try passTargets(state, pass, lender);
    raster_mod.beginPass(drv, cb, targets);
    var pipeline: ?*VulkanPipeline = null;
    var bindings_id: ?BackendObjectId = null;
    var vertex_slots: [raster_mod.max_vertex_buffers]?VertexSlot = @splat(null);
    var index_slot: ?IndexSlot = null;
    for (pass.draws) |draw| {
        const current = if (pipeline != null and pipeline.?.loaded.id == draw.pipeline.id) pipeline.? else blk: {
            const next = try state.getRenderPipeline(draw.pipeline);
            if (next.loaded.target_format != pass.color.view.format) return error.RenderArgumentMismatch;
            if ((next.loaded.depth != null) != (pass.depth != null)) return error.RenderArgumentMismatch;
            drv.vkCmdBindPipeline(cb, driver_mod.VK_PIPELINE_BIND_POINT_GRAPHICS, next.pipeline.pipeline);
            bindings_id = null;
            pipeline = next;
            break :blk next;
        };
        if (draw.vertex_buffers.len != current.loaded.vertex_buffer_count) return error.RenderArgumentMismatch;
        if ((draw.bindings != null) != (current.loaded.binding_count != 0)) return error.RenderArgumentMismatch;
        if (draw.bindings) |bindings| if (bindings_id != bindings.id) {
            const set = try state.getRenderBindings(bindings);
            if (set.pipeline_id != current.loaded.id) return error.RenderArgumentMismatch;
            drv.vkCmdBindDescriptorSets(
                cb,
                driver_mod.VK_PIPELINE_BIND_POINT_GRAPHICS,
                current.pipeline.layout,
                0,
                1,
                @ptrCast(&set.set.set),
                0,
                null,
            );
            bindings_id = bindings.id;
        };
        if (draw.push_constants.len != current.loaded.push_constant_bytes) return error.RenderArgumentMismatch;
        if (draw.push_constants.len != 0) {
            const size: u32 = @intCast(draw.push_constants.len);
            drv.vkCmdPushConstants(cb, current.pipeline.layout, raster_mod.push_constant_stages, 0, size, draw.push_constants.ptr);
        }
        const indexed = draw.range.index_format != .none;
        for (draw.vertex_buffers, current.layouts[0..draw.vertex_buffers.len]) |range, layout| {
            const slot = &vertex_slots[layout.binding];
            const bound = if (slot.*) |existing| existing.id == range.buffer.id and existing.offset == range.offset else false;
            if (!bound) {
                const buffer = try state.getBuffer(range.buffer);
                if (range.offset >= buffer.size) return error.RenderArgumentMismatch;
                drv.vkCmdBindVertexBuffers(cb, layout.binding, 1, @ptrCast(&buffer._buffer), @ptrCast(&range.offset));
                slot.* = .{ .id = range.buffer.id, .offset = range.offset, .size = buffer.size };
            }
            const elements: u64 = if (layout.per_instance)
                @as(u64, draw.range.first_instance) + draw.range.instance_count
            else if (indexed)
                0
            else
                @as(u64, draw.range.first_vertex) + draw.range.vertex_count;
            if (elements * layout.stride > slot.*.?.size - slot.*.?.offset) return error.RenderArgumentMismatch;
        }
        if (!indexed) {
            if (draw.index_buffer != null) return error.RenderArgumentMismatch;
            drv.vkCmdDraw(cb, draw.range.vertex_count, draw.range.instance_count, draw.range.first_vertex, draw.range.first_instance);
            continue;
        }
        const range = draw.index_buffer orelse return error.RenderArgumentMismatch;
        const index_bytes: u64 = if (draw.range.index_format == .u16) 2 else 4;
        const bound = if (index_slot) |existing|
            existing.id == range.buffer.id and existing.offset == range.offset and existing.format == draw.range.index_format
        else
            false;
        if (!bound) {
            const buffer = try state.getBuffer(range.buffer);
            if (range.offset >= buffer.size or range.offset % index_bytes != 0) return error.RenderArgumentMismatch;
            const index_type = if (index_bytes == 2) driver_mod.VK_INDEX_TYPE_UINT16 else driver_mod.VK_INDEX_TYPE_UINT32;
            drv.vkCmdBindIndexBuffer(cb, buffer._buffer, range.offset, index_type);
            index_slot = .{ .id = range.buffer.id, .offset = range.offset, .size = buffer.size, .format = draw.range.index_format };
        }
        const indices = @as(u64, draw.range.first_index) + draw.range.index_count;
        if (indices * index_bytes > index_slot.?.size - index_slot.?.offset) return error.RenderArgumentMismatch;
        drv.vkCmdDrawIndexed(
            cb,
            draw.range.index_count,
            draw.range.instance_count,
            draw.range.first_index,
            draw.range.base_vertex,
            draw.range.first_instance,
        );
    }
    raster_mod.endPass(drv, cb, targets);
}

/// The attachments of `pass`. A color attachment may be a swapchain image an acquired surface frame
/// lent: the pass starts it from the layout its last use left and leaves it ready to present, and
/// `lender` receives the surface. Every other attachment is an image of this backend.
fn passTargets(state: *State, pass: backend.RenderPass, lender: *?*VulkanSurface) backend.BackendError!raster_mod.Targets {
    lender.* = null;
    const clear: ?driver_mod.VkClearValue = switch (pass.color.load) {
        .load => null,
        .clear => |value| .{ .color = .{ .float32 = .{ value.r, value.g, value.b, value.a } } },
    };
    const texture = pass.color.view.texture;
    const color = if (texture.ownership == .acquired_surface) color: {
        const surface = try state.getLender(texture);
        const lent = (try state.getTexture(texture)).image;
        if (lent.view == 0) return error.InvalidTexture;
        lender.* = surface;
        break :color raster_mod.Attachment{
            .image = lent.image,
            .view = lent.view,
            .aspect = driver_mod.VK_IMAGE_ASPECT_COLOR_BIT,
            .width = lent.extent.width,
            .height = lent.extent.height,
            .before = surface.surface.heldLayout(),
            .after = driver_mod.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .clear = clear,
        };
    } else (try state.getImage(texture)).image.attachment(clear);
    const depth = if (pass.depth) |attachment| depth: {
        const target = try state.getImage(attachment.view.texture);
        break :depth target.image.attachment(switch (attachment.load) {
            .load => null,
            .clear => |value| .{ .depthStencil = .{ .depth = value, .stencil = 0 } },
        });
    } else null;
    return .{
        .color = color,
        .depth = depth,
        .viewport = .{
            .x = pass.viewport.x,
            .y = pass.viewport.y,
            .width = pass.viewport.width,
            .height = pass.viewport.height,
            .minDepth = pass.viewport.min_depth,
            .maxDepth = pass.viewport.max_depth,
        },
        .scissor = .{
            .offset = .{ .x = @intCast(pass.scissor.x), .y = @intCast(pass.scissor.y) },
            .extent = .{ .width = pass.scissor.width, .height = pass.scissor.height },
        },
    };
}

fn vulkanCompare(compare: backend.RenderCompare) driver_mod.VkCompareOp {
    return switch (compare) {
        .never => driver_mod.VK_COMPARE_OP_NEVER,
        .less => driver_mod.VK_COMPARE_OP_LESS,
        .equal => driver_mod.VK_COMPARE_OP_EQUAL,
        .less_equal => driver_mod.VK_COMPARE_OP_LESS_OR_EQUAL,
        .greater => driver_mod.VK_COMPARE_OP_GREATER,
        .not_equal => driver_mod.VK_COMPARE_OP_NOT_EQUAL,
        .greater_equal => driver_mod.VK_COMPARE_OP_GREATER_OR_EQUAL,
        .always => driver_mod.VK_COMPARE_OP_ALWAYS,
    };
}

fn vulkanTopology(topology: backend.RenderPrimitiveTopology) driver_mod.VkPrimitiveTopology {
    return switch (topology) {
        .triangle_list => driver_mod.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .triangle_strip => driver_mod.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
        .line_list => driver_mod.VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
        .line_strip => driver_mod.VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
    };
}

fn vertexFormat(format: backend.RenderVertexFormat) driver_mod.VkFormat {
    return switch (format) {
        .float32 => driver_mod.VK_FORMAT_R32_SFLOAT,
        .float32x2 => driver_mod.VK_FORMAT_R32G32_SFLOAT,
        .float32x3 => driver_mod.VK_FORMAT_R32G32B32_SFLOAT,
        .float32x4 => driver_mod.VK_FORMAT_R32G32B32A32_SFLOAT,
        .uint32 => driver_mod.VK_FORMAT_R32_UINT,
        .uint32x2 => driver_mod.VK_FORMAT_R32G32_UINT,
        .uint32x4 => driver_mod.VK_FORMAT_R32G32B32A32_UINT,
    };
}

/// Maps a raster runtime failure, with `fallback` for failures that belong to the request itself.
fn mapRasterError(err: raster_mod.Error, fallback: backend.BackendError) backend.BackendError {
    return switch (err) {
        error.OutOfHostMemory, error.OutOfDeviceMemory, error.FragmentedPool, error.OutOfPoolMemory, error.TooManyObjects => error.OutOfMemory,
        error.DeviceLost => error.DeviceLost,
        error.StreamPoisoned => error.RenderFailed,
        error.FeatureNotPresent,
        error.FormatNotSupported,
        error.ExtensionNotPresent,
        error.LayerNotPresent,
        => error.CapabilityMismatch,
        error.DriverUnavailable,
        error.SymbolMissing,
        error.NoDevice,
        error.InvalidDevice,
        error.TimelineSemaphoreUnavailable,
        error.IncompatibleDriver,
        => error.RuntimeUnavailable,
        else => fallback,
    };
}

fn surfaceDescFromRequest(request: backend.SurfaceCreationRequest) backend.BackendError!runtime_mod.SurfaceDesc {
    const x11 = switch (request.platform) {
        .x11 => |x11| x11,
        else => return error.CapabilityMismatch,
    };
    if (x11.display == 0 or x11.window == 0) return error.InvalidSurface;
    const usage = imageUsageFromTextureUsage(request.usage);
    if (usage == 0) return error.InvalidSurface;
    return .{
        .display = x11.display,
        .window = x11.window,
        .extent = .{ .width = request.extent.width, .height = request.extent.height },
        .format = try vulkanFormat(request.format),
        .color_space = try vulkanColorSpace(request.color_space),
        .present_mode = vulkanPresentMode(request.present_mode),
        .usage = usage,
        .min_image_count = request.max_frames_in_flight,
        .composite_alpha = vulkanCompositeAlpha(request.alpha_mode),
    };
}

fn vulkanFormat(format: backend.TextureFormat) backend.BackendError!driver_mod.VkFormat {
    return switch (format) {
        .rgba8_unorm => driver_mod.VK_FORMAT_R8G8B8A8_UNORM,
        .bgra8_unorm => driver_mod.VK_FORMAT_B8G8R8A8_UNORM,
        .rgba8_srgb => driver_mod.VK_FORMAT_R8G8B8A8_SRGB,
        .bgra8_srgb => driver_mod.VK_FORMAT_B8G8R8A8_SRGB,
        .depth32_float => driver_mod.VK_FORMAT_D32_SFLOAT,
    };
}

fn vulkanColorSpace(color_space: backend.ColorSpace) backend.BackendError!driver_mod.VkColorSpaceKHR {
    return switch (color_space) {
        .srgb => driver_mod.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        .linear => error.CapabilityMismatch,
    };
}

fn vulkanPresentMode(present_mode: backend.PresentMode) driver_mod.VkPresentModeKHR {
    return switch (present_mode) {
        .fifo => driver_mod.VK_PRESENT_MODE_FIFO_KHR,
        .mailbox => driver_mod.VK_PRESENT_MODE_MAILBOX_KHR,
        .immediate => driver_mod.VK_PRESENT_MODE_IMMEDIATE_KHR,
    };
}

fn vulkanCompositeAlpha(alpha_mode: backend.SurfaceAlphaMode) driver_mod.VkCompositeAlphaFlagBitsKHR {
    return switch (alpha_mode) {
        .solid => driver_mod.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .premultiplied => driver_mod.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
        .postmultiplied => driver_mod.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
        .inherit => driver_mod.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
    };
}

fn imageUsageFromTextureUsage(usage: backend.TextureUsage) driver_mod.VkImageUsageFlags {
    var flags: driver_mod.VkImageUsageFlags = 0;
    if (usage.copy_src) flags |= driver_mod.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    if (usage.copy_dst) flags |= driver_mod.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if (usage.sampled) flags |= driver_mod.VK_IMAGE_USAGE_SAMPLED_BIT;
    if (usage.storage) flags |= driver_mod.VK_IMAGE_USAGE_STORAGE_BIT;
    if (usage.color_attachment) flags |= driver_mod.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    if (usage.depth_attachment) flags |= driver_mod.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    return flags;
}

fn textureUsageFromImageUsage(usage: driver_mod.VkImageUsageFlags) backend.TextureUsage {
    return .{
        .copy_src = (usage & driver_mod.VK_IMAGE_USAGE_TRANSFER_SRC_BIT) != 0,
        .copy_dst = (usage & driver_mod.VK_IMAGE_USAGE_TRANSFER_DST_BIT) != 0,
        .sampled = (usage & driver_mod.VK_IMAGE_USAGE_SAMPLED_BIT) != 0,
        .storage = (usage & driver_mod.VK_IMAGE_USAGE_STORAGE_BIT) != 0,
        .color_attachment = (usage & driver_mod.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) != 0,
        .present = true,
    };
}

fn mapRuntimeError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.OutOfHostMemory, error.OutOfDeviceMemory, error.FragmentedPool, error.OutOfPoolMemory => error.OutOfMemory,
        error.DeviceLost => error.DeviceLost,
        error.DriverUnavailable,
        error.SymbolMissing,
        error.NoDevice,
        error.InvalidDevice,
        error.TimelineSemaphoreUnavailable,
        error.IncompatibleDriver,
        => error.RuntimeUnavailable,
        error.LayerNotPresent,
        error.ExtensionNotPresent,
        error.FeatureNotPresent,
        => error.CapabilityMismatch,
        error.StreamPoisoned => error.LaunchFailed,
        else => error.RuntimeUnavailable,
    };
}

fn mapSurfaceRuntimeError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.OutOfHostMemory, error.OutOfDeviceMemory, error.FragmentedPool, error.OutOfPoolMemory => error.OutOfMemory,
        error.DeviceLost => error.DeviceLost,
        error.SurfaceOutOfDate, error.SurfaceLost => error.SurfaceFrameExpired,
        error.NativeWindowInUse, error.InitializationFailed => error.InvalidSurface,
        error.FormatNotSupported,
        error.LayerNotPresent,
        error.ExtensionNotPresent,
        error.FeatureNotPresent,
        => error.CapabilityMismatch,
        error.DriverUnavailable,
        error.SymbolMissing,
        error.NoDevice,
        error.InvalidDevice,
        error.TimelineSemaphoreUnavailable,
        error.IncompatibleDriver,
        => error.RuntimeUnavailable,
        else => error.RuntimeUnavailable,
    };
}

fn mapArtifactError(err: launch_mod.Error) backend.BackendError {
    return switch (err) {
        error.OutOfHostMemory, error.OutOfDeviceMemory, error.FragmentedPool, error.OutOfPoolMemory => error.OutOfMemory,
        error.DeviceLost => error.DeviceLost,
        error.FormatNotSupported, error.InitializationFailed => error.InvalidArtifact,
        error.DriverUnavailable,
        error.SymbolMissing,
        error.NoDevice,
        error.InvalidDevice,
        error.TimelineSemaphoreUnavailable,
        error.IncompatibleDriver,
        => error.RuntimeUnavailable,
        error.LayerNotPresent,
        error.ExtensionNotPresent,
        error.FeatureNotPresent,
        => error.CapabilityMismatch,
        else => error.InvalidArtifact,
    };
}

fn mapAllocationError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.OutOfHostMemory, error.OutOfDeviceMemory, error.FragmentedPool, error.OutOfPoolMemory => error.OutOfMemory,
        error.DeviceLost => error.DeviceLost,
        error.MemoryMapFailed, error.InitializationFailed => error.InvalidBuffer,
        error.DriverUnavailable,
        error.SymbolMissing,
        error.NoDevice,
        error.InvalidDevice,
        error.TimelineSemaphoreUnavailable,
        error.IncompatibleDriver,
        => error.RuntimeUnavailable,
        else => error.InvalidBuffer,
    };
}

fn mapLaunchError(err: launch_mod.Error) backend.BackendError {
    return switch (err) {
        error.OutOfHostMemory, error.OutOfDeviceMemory, error.FragmentedPool, error.OutOfPoolMemory => error.OutOfMemory,
        error.DeviceLost => error.DeviceLost,
        error.StreamPoisoned => error.LaunchFailed,
        error.InitializationFailed => error.LaunchArgumentMismatch,
        error.DriverUnavailable,
        error.SymbolMissing,
        error.NoDevice,
        error.InvalidDevice,
        error.TimelineSemaphoreUnavailable,
        error.IncompatibleDriver,
        => error.RuntimeUnavailable,
        else => error.LaunchFailed,
    };
}

fn mapElapsedEventError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.OutOfHostMemory, error.OutOfDeviceMemory, error.FragmentedPool, error.OutOfPoolMemory => error.OutOfMemory,
        error.DeviceLost => error.DeviceLost,
        error.FeatureNotPresent => error.UnsupportedOperation,
        error.InitializationFailed => error.InvalidEvent,
        error.StreamPoisoned => error.LaunchFailed,
        error.DriverUnavailable,
        error.SymbolMissing,
        error.NoDevice,
        error.InvalidDevice,
        error.TimelineSemaphoreUnavailable,
        error.IncompatibleDriver,
        => error.RuntimeUnavailable,
        error.LayerNotPresent,
        error.ExtensionNotPresent,
        => error.CapabilityMismatch,
        else => error.RuntimeUnavailable,
    };
}

const vtable = backend.BackendVTable{
    .query_capabilities = queryCapabilities,
    .create_artifact = createArtifact,
    .load_artifact = loadArtifact,
    .create_render_artifact = createRenderArtifact,
    .load_render_artifact = loadRenderArtifact,
    .allocate_buffer = allocateBuffer,
    .allocate_texture = allocateTexture,
    .create_surface = createSurface,
    .destroy_surface = destroySurface,
    .destroy_texture = destroyTexture,
    .acquire_surface_frame = acquireSurfaceFrame,
    .present_surface_frame = presentSurfaceFrame,
    .write_surface_frame = writeSurfaceFrame,
    .read_surface_frame = readSurfaceFrame,
    .create_stream = createStream,
    .create_event = createEvent,
    .write_buffer = writeBuffer,
    .read_buffer = readBuffer,
    .launch = launch,
    .record_sequence = recordSequence,
    .submit_sequence = submitSequence,
    .render = render,
    .create_render_bindings = createRenderBindings,
    .record_render_bundle = recordRenderBundle,
    .submit_render_bundle = submitRenderBundle,
    .write_texture = writeTexture,
    .read_texture = readTexture,
    .synchronize = synchronize,
    .query_event = queryEvent,
    .record_event = recordEvent,
    .elapsed_event_ns = elapsedEventNs,
    .destroy_object = destroyObject,
    .deinit = deinitHandle,
};
