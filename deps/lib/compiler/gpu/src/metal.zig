const std = @import("std");
const gpu_abi = @import("gpu_abi");
const pretty = @import("pretty");
const build_options = @import("build_options");
const sys = @import("sys");

const backend = @import("root.zig");
const runtime_root = @import("runtime/root.zig");

const runtime_mod = runtime_root.metal.runtime;
const raster_mod = runtime_mod.raster;
const foundation = sys.apple.foundation;
const metal = sys.apple.metal;

const Allocator = std.mem.Allocator;
const Runtime = runtime_mod.Runtime;
const BackendObjectId = backend.BackendObjectId;

const native_available = metal.available;

/// Releases a native object. On a host without Metal no native object exists.
fn releaseNative(object: anytype) void {
    if (comptime native_available) sys.apple.objc.release(object);
}

/// Vertex buffers a pipeline reads, at Metal buffer indices 0 to 7, below the uniform blocks.
const max_vertex_buffers = 8;
/// Vertex attributes a pipeline reads, at `[[attribute(0)]]` to `[[attribute(30)]]`.
const max_vertex_attributes = 16;
const max_attribute_location = 31;
/// Resource bindings a pipeline declares, each a uniform block or a sampled texture of group 0.
const max_bindings = gpu_abi.metal.max_uniform_bindings;
/// Bytes between two draws' push constants in a bundle's push buffer, which meets the constant
/// buffer offset alignment of every Metal GPU family.
const push_stride = 256;
const max_push_constant_bytes = gpu_abi.stage.push_words * 4;
/// Events a pass may wait for.
const max_wait_events = 8;

comptime {
    std.debug.assert(max_vertex_buffers <= gpu_abi.metal.uniform_buffer_base);
    std.debug.assert(max_push_constant_bytes <= push_stride);
}

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

pub const State = struct {
    allocator: Allocator,
    runtime: RuntimeStorage = .none,
    next_id: BackendObjectId = 1,
    objects: std.AutoHashMapUnmanaged(BackendObjectId, Object) = .{},

    fn init(allocator: Allocator) State {
        return .{
            .allocator = allocator,
        };
    }

    pub fn initDevice(allocator: Allocator) backend.BackendError!State {
        const runtime = Runtime.init(allocator) catch |err| return mapRuntimeError(err);
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
        self.runtime.deinit();
    }

    pub fn handle(self: *State) backend.BackendHandle {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .kind = .metal,
        };
    }

    fn putObject(self: *State, object: Object) backend.BackendError!BackendObjectId {
        const id = self.next_id;
        if (id == std.math.maxInt(BackendObjectId)) return error.OutOfMemory;
        self.next_id += 1;
        self.objects.put(self.allocator, id, object) catch return error.OutOfMemory;
        return id;
    }

    fn getLoaded(self: *State, loaded: backend.LoadedArtifact) backend.BackendError!*runtime_mod.LoadedKernel {
        if (loaded.backend != .metal or !isLoadableArtifactFormat(loaded.format)) return error.InvalidArtifact;
        const object = self.objects.getPtr(loaded.id) orelse return error.InvalidArtifact;
        return switch (object.*) {
            .loaded_artifact => |*artifact| if (artifact.format == loaded.format) &artifact.kernel else error.InvalidArtifact,
            else => error.InvalidArtifact,
        };
    }

    fn getBuffer(self: *State, buffer_handle: backend.BufferHandle) backend.BackendError!*runtime_mod.DeviceBuffer {
        if (buffer_handle.backend != .metal) return error.InvalidBuffer;
        const object = self.objects.getPtr(buffer_handle.id) orelse return error.InvalidBuffer;
        return switch (object.*) {
            .buffer => |*buffer| buffer,
            else => error.InvalidBuffer,
        };
    }

    fn getStream(self: *State, stream_handle: backend.StreamHandle) backend.BackendError!*MetalStream {
        if (stream_handle.backend != .metal) return error.InvalidStream;
        const object = self.objects.getPtr(stream_handle.id) orelse return error.InvalidStream;
        return switch (object.*) {
            .stream => |*stream| stream,
            else => error.InvalidStream,
        };
    }

    fn getEvent(self: *State, event_handle: backend.EventHandle) backend.BackendError!*MetalEvent {
        if (event_handle.backend != .metal) return error.InvalidEvent;
        const object = self.objects.getPtr(event_handle.id) orelse return error.InvalidEvent;
        return switch (object.*) {
            .event => |*event| event,
            else => error.InvalidEvent,
        };
    }

    fn getTexture(self: *State, texture_handle: backend.TextureHandle) backend.BackendError!*MetalTexture {
        if (texture_handle.backend != .metal) return error.InvalidTexture;
        const object = self.objects.getPtr(texture_handle.id) orelse return error.InvalidTexture;
        return switch (object.*) {
            .texture => |*texture| texture,
            else => error.InvalidTexture,
        };
    }

    fn getRenderPipeline(self: *State, loaded: backend.LoadedRenderArtifact) backend.BackendError!*MetalPipeline {
        if (loaded.backend != .metal) return error.InvalidRenderArtifact;
        const object = self.objects.getPtr(loaded.id) orelse return error.InvalidRenderArtifact;
        return switch (object.*) {
            .render_pipeline => |*pipeline| pipeline,
            else => error.InvalidRenderArtifact,
        };
    }

    fn getRenderBindings(self: *State, bindings: backend.RenderBindings) backend.BackendError!*MetalBindings {
        if (bindings.backend != .metal) return error.RenderArgumentMismatch;
        const object = self.objects.getPtr(bindings.id) orelse return error.RenderArgumentMismatch;
        return switch (object.*) {
            .render_bindings => |*set| set,
            else => error.RenderArgumentMismatch,
        };
    }

    fn getRenderBundle(self: *State, bundle: backend.RenderBundle) backend.BackendError!*MetalBundle {
        if (bundle.backend != .metal) return error.RenderArgumentMismatch;
        const object = self.objects.getPtr(bundle.id) orelse return error.RenderArgumentMismatch;
        return switch (object.*) {
            .render_bundle => |*recorded| recorded,
            else => error.RenderArgumentMismatch,
        };
    }

    fn getSurface(self: *State, surface: backend.SurfaceHandle) backend.BackendError!*MetalSurface {
        if (surface.backend != .metal) return error.InvalidSurface;
        const object = self.objects.getPtr(surface.id) orelse return error.InvalidSurface;
        return switch (object.*) {
            .surface => |*stored| stored,
            else => error.InvalidSurface,
        };
    }

    fn getSurfaceById(self: *State, id: BackendObjectId) ?*MetalSurface {
        const object = self.objects.getPtr(id) orelse return null;
        return switch (object.*) {
            .surface => |*stored| stored,
            else => null,
        };
    }

    fn getFrame(self: *State, frame: backend.SurfaceFrame) backend.BackendError!*MetalFrame {
        if (frame.backend != .metal) return error.InvalidSurfaceFrame;
        const object = self.objects.getPtr(frame.id) orelse return error.InvalidSurfaceFrame;
        return switch (object.*) {
            .surface_frame => |*stored| stored,
            else => error.InvalidSurfaceFrame,
        };
    }

    fn nativeStream(self: *State, stream: ?backend.StreamHandle) backend.BackendError!?*runtime_mod.Stream {
        const stream_handle = stream orelse return null;
        return (try self.getStream(stream_handle)).native orelse error.InvalidStream;
    }

    fn nativeWaits(
        self: *State,
        events: []const backend.EventHandle,
        storage: *[max_wait_events]*runtime_mod.Event,
    ) backend.BackendError![]const *runtime_mod.Event {
        if (events.len > max_wait_events) return error.LaunchArgumentMismatch;
        for (events, storage[0..events.len]) |event_handle, *slot| {
            const event = try self.getEvent(event_handle);
            if (!event.recorded) return error.InvalidEvent;
            slot.* = event.native orelse return error.InvalidEvent;
        }
        return storage[0..events.len];
    }

    fn nativeSignal(self: *State, event: ?backend.EventHandle) backend.BackendError!?*MetalEvent {
        const event_handle = event orelse return null;
        const signal = try self.getEvent(event_handle);
        if (signal.native == null) return error.InvalidEvent;
        return signal;
    }

    /// Encodes `pass` with no checks and no state beyond the first draw's pipeline, bindings and
    /// vertex buffers, then drops the command buffer uncommitted: the least a pass of these draws
    /// can cost to record. Every draw must be non-indexed.
    pub fn recordFloor(self: *State, pass: backend.RenderPass) backend.BackendError!void {
        if (comptime !native_available) return error.RuntimeUnavailable;
        const rt = self.runtime.ptr() orelse return error.RuntimeUnavailable;
        if (pass.draws.len == 0) return;
        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const targets = try passTargets(self, pass);
        const stream = rt.defaultStream() catch |err| return mapRenderError(err);
        const command_buffer = metal.commandBuffer(stream.command_queue) orelse return error.RenderFailed;
        const encoder = try beginPass(command_buffer, targets);
        const first = pass.draws[0];
        const pipeline = try self.getRenderPipeline(first.pipeline);
        var sink = EncoderSink{ .encoder = encoder };
        sink.setPipeline(pipeline);
        if (first.bindings) |bindings| sink.setBindings(try self.getRenderBindings(bindings));
        for (first.vertex_buffers, pipeline.layouts[0..first.vertex_buffers.len]) |range, layout| {
            metal.setVertexBuffer(encoder, (try self.getBuffer(range.buffer)).buffer, range.offset, layout.binding);
        }
        for (pass.draws) |draw| {
            if (draw.push_constants.len != 0) {
                metal.setVertexBytes(encoder, draw.push_constants, gpu_abi.metal.push_buffer);
                metal.setFragmentBytes(encoder, draw.push_constants, gpu_abi.metal.push_buffer);
            }
            metal.drawPrimitives(encoder, pipeline.primitive, draw.range.first_vertex, draw.range.vertex_count, draw.range.instance_count, draw.range.first_instance);
        }
        metal.endRenderEncoding(encoder);
    }

    /// Compiles `source` into a library with fast math off and drops it, so a caller can see that
    /// the Metal compiler takes a module whatever its entry points.
    pub fn compileMsl(self: *State, source: []const u8) backend.BackendError!void {
        if (comptime !native_available) return error.RuntimeUnavailable;
        const rt = self.runtime.ptr() orelse return error.RuntimeUnavailable;
        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const library = rt.newLibrary(.{ .msl = source }) catch |err| return mapRuntimeError(err);
        releaseNative(library);
    }

    /// Whether this macOS lets an indirect render command set its own depth-stencil state and
    /// depth bias. Bundles inherit both from the encoder either way.
    pub fn indirectCommandsCarryDepthState(self: *State) backend.BackendError!bool {
        if (comptime !native_available) return error.RuntimeUnavailable;
        const rt = self.runtime.ptr() orelse return error.RuntimeUnavailable;
        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const commands = raster_mod.createIndirectCommands(rt, 1) catch |err| return mapRuntimeError(err);
        defer releaseNative(commands);
        return metal.indirectCommandsCarryDepthState(metal.indirectRenderCommand(commands, 0));
    }

    /// The device's name, copied into `buffer` and cut to fit.
    pub fn deviceName(self: *State, buffer: []u8) []const u8 {
        if (comptime !native_available) return "";
        const rt = self.runtime.ptr() orelse return "";
        var pool = foundation.AutoreleasePool.init() orelse return "";
        defer pool.deinit();
        const name = metal.deviceName(rt.device) orelse return "";
        const bytes = std.mem.span(foundation.utf8(name) orelse return "");
        const length = @min(bytes.len, buffer.len);
        @memcpy(buffer[0..length], bytes[0..length]);
        return buffer[0..length];
    }

    /// The message of the last failed library compile or pipeline build.
    pub fn compileLog(self: *State) []const u8 {
        const rt = self.runtime.ptr() orelse return "";
        return rt.compile_log.text();
    }

    /// How the last library compiled from MSL treated floating point.
    pub fn mathSetting(self: *State) ?metal.MathSetting {
        const rt = self.runtime.ptr() orelse return null;
        return rt.math_setting;
    }
};

const MetalStream = struct {
    native: ?*runtime_mod.Stream = null,
};

const MetalEvent = struct {
    native: ?*runtime_mod.Event = null,
    recorded: bool = false,
};

const MetalLoadedArtifact = struct {
    kernel: runtime_mod.LoadedKernel,
    format: backend.ArtifactFormat,
};

/// A texture this backend allocated, or the texture of a drawable a surface lent it until the
/// frame presents.
const MetalTexture = struct {
    handle: backend.TextureHandle,
    native: raster_mod.Texture,
    lent: bool = false,
};

const VertexLayout = struct {
    binding: u32,
    stride: u32,
    per_instance: bool,
};

/// A render pipeline and the facts its draws are checked against, with the depth test, bias and
/// cull mode that Metal keeps as encoder state rather than pipeline state.
const MetalPipeline = struct {
    state: metal.RenderPipelineState,
    depth_state: ?metal.DepthStencilState,
    bias: backend.RenderDepthBias,
    cull: metal.CullMode,
    primitive: metal.PrimitiveType,
    loaded: backend.LoadedRenderArtifact,
    layouts: [max_vertex_buffers]VertexLayout,
    bindings: [max_bindings]backend.RenderBindingDesc,
    /// Whether an indirect command buffer may set the pipeline: only when it samples no texture.
    indirect: bool,
};

const MetalResource = union(enum) {
    /// A uniform block at buffer index `uniform_buffer_base + binding` of both stages.
    uniform: metal.Buffer,
    /// A texture and its sampler at index `binding` of both stages.
    texture: struct { texture: metal.Texture, sampler: metal.SamplerState },
};

const MetalBinding = struct {
    binding: u32,
    resource: MetalResource,
};

const MetalBindings = struct {
    pipeline_id: BackendObjectId,
    entries: [max_bindings]MetalBinding,
    count: u32,

    fn slice(self: *const MetalBindings) []const MetalBinding {
        return self.entries[0..self.count];
    }
};

/// Draws of a bundle that share their encoder state: the depth test, the bias, the cull mode and
/// the textures, which indirect commands inherit from the encoder that executes them.
const BundleRun = struct {
    start: u32,
    count: u32,
    depth_state: ?metal.DepthStencilState,
    bias: backend.RenderDepthBias,
    cull: metal.CullMode,
    bindings: MetalBindings,
};

/// A pass recorded as an indirect command buffer. Each command sets its own pipeline, vertex
/// buffers, uniform blocks and push constants, the last from a buffer the bundle filled when it
/// recorded. Runs set the rest on the encoder before executing their commands.
/// A recorded pass. When every pipeline it draws with may join an indirect command buffer, its
/// draws live in `commands`, run by run. Otherwise `replay` keeps the pass and each submission
/// encodes it again.
const MetalBundle = struct {
    replay: ?ReplayPass = null,
    commands: ?metal.IndirectCommandBuffer,
    push: ?metal.Buffer,
    targets: Targets,
    runs: []BundleRun,
    /// Every buffer a command reads, made resident before the commands execute.
    resources: []metal.Buffer,
    draw_count: u32,
};

/// A copy of a pass that owns its draws, their vertex buffer ranges and their push constants.
const ReplayPass = struct {
    pass: backend.RenderPass,
    draws: []backend.RenderDraw,
    ranges: []backend.RenderBufferRange,
    bytes: []u8,

    fn init(allocator: Allocator, pass: backend.RenderPass) error{OutOfMemory}!ReplayPass {
        var range_count: usize = 0;
        var byte_count: usize = 0;
        for (pass.draws) |draw| {
            range_count += draw.vertex_buffers.len;
            byte_count += draw.push_constants.len;
        }
        const draws = try allocator.dupe(backend.RenderDraw, pass.draws);
        errdefer allocator.free(draws);
        const ranges = try allocator.alloc(backend.RenderBufferRange, range_count);
        errdefer allocator.free(ranges);
        const bytes = try allocator.alloc(u8, byte_count);
        var range_next: usize = 0;
        var byte_next: usize = 0;
        for (draws) |*draw| {
            const vertex_buffers = ranges[range_next..][0..draw.vertex_buffers.len];
            @memcpy(vertex_buffers, draw.vertex_buffers);
            draw.vertex_buffers = vertex_buffers;
            range_next += vertex_buffers.len;
            const push_constants = bytes[byte_next..][0..draw.push_constants.len];
            @memcpy(push_constants, draw.push_constants);
            draw.push_constants = push_constants;
            byte_next += push_constants.len;
        }
        var copied = pass;
        copied.draws = draws;
        copied.diagnostic_id = null;
        return .{ .pass = copied, .draws = draws, .ranges = ranges, .bytes = bytes };
    }

    fn deinit(self: *ReplayPass, allocator: Allocator) void {
        allocator.free(self.draws);
        allocator.free(self.ranges);
        allocator.free(self.bytes);
    }
};

const MetalSurface = struct {
    surface: raster_mod.Surface,
    handle: backend.SurfaceHandle,
    acquired_frame: ?BackendObjectId = null,
    acquired_texture: ?BackendObjectId = null,
};

const MetalFrame = struct {
    surface_id: BackendObjectId,
    texture_id: BackendObjectId,
    frame: raster_mod.Frame,
    generation: u64,
    presented: bool = false,
    written: bool = false,
};

const Object = union(enum) {
    sequence: MetalSequence,
    loaded_artifact: MetalLoadedArtifact,
    buffer: runtime_mod.DeviceBuffer,
    stream: MetalStream,
    event: MetalEvent,
    texture: MetalTexture,
    render_pipeline: MetalPipeline,
    render_bindings: MetalBindings,
    render_bundle: MetalBundle,
    surface: MetalSurface,
    surface_frame: MetalFrame,
};

const SequenceEntry = struct {
    loaded: backend.LoadedArtifact,
    buffers: [backend.contract.max_sequence_arguments]backend.BufferHandle = undefined,
    buffer_count: u8,
    scalars: [backend.contract.max_sequence_arguments]runtime_mod.ScalarArgument = undefined,
    scalar_count: u8,
    grid: [3]u32,
    threadgroup: [3]u32,
    name: [backend.contract.max_sequence_name_bytes]u8 = undefined,
    name_len: u8,

    fn label(self: *const SequenceEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

const MetalSequence = struct {
    rt: *runtime_mod.Runtime,
    entries: [backend.contract.max_sequence_dispatches]SequenceEntry = undefined,
    count: u8,

    fn deinit(self: *MetalSequence) void {
        self.rt.synchronize() catch @panic("Metal sequence destruction requires completion");
        self.* = undefined;
    }
};

fn recordSequence(ptr: *anyopaque, request: backend.contract.SequenceRecordRequest) backend.BackendError!backend.contract.SequenceHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    // Keep the default-stream allocation out of the replay path.
    _ = rt.defaultStream() catch |err| return mapRuntimeError(err);
    var sequence = MetalSequence{ .rt = rt, .count = @intCast(request.dispatches.len) };
    for (request.dispatches, 0..) |dispatch, index| {
        if (request.failure) |failure| failure.* = .{ .stage = .record, .dispatch_index = index, .dispatch_name = dispatch.name };
        const launch_request = dispatch.launch;
        const loaded = launch_request.loaded_artifact orelse return error.InvalidArtifact;
        const kernel = try state.getLoaded(loaded);
        const count = launch_request.buffers.len + launch_request.scalar_arguments.len;
        if (count != kernel.argument_count) return error.LaunchArgumentMismatch;
        var entry = &sequence.entries[index];
        entry.* = .{
            .loaded = loaded,
            .buffer_count = @intCast(launch_request.buffers.len),
            .scalar_count = @intCast(launch_request.scalar_arguments.len),
            .grid = launch_request.geometry.grid,
            .threadgroup = launch_request.geometry.threadgroup,
            .name_len = @intCast(dispatch.name.len),
        };
        @memcpy(entry.name[0..dispatch.name.len], dispatch.name);
        for (launch_request.buffers, 0..) |binding, i| {
            if (binding.ownership != .backend) return error.InvalidBuffer;
            const buffer = try state.getBuffer(binding.handle);
            if (binding.byte_size > buffer.byte_size or binding.handle.byte_size != buffer.byte_size) return error.InvalidBuffer;
            entry.buffers[i] = binding.handle;
        }
        for (launch_request.scalar_arguments, 0..) |scalar, i| entry.scalars[i] = lowerScalarArgument(scalar);
    }
    const id = try state.putObject(.{ .sequence = sequence });
    return .{ .id = id, .backend = .metal };
}

fn submitSequence(ptr: *anyopaque, request: backend.contract.SequenceSubmitRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const object = state.objects.getPtr(request.sequence.id) orelse return error.InvalidArtifact;
    const sequence = switch (object.*) {
        .sequence => |*value| value,
        else => return error.InvalidArtifact,
    };
    var native: [backend.contract.max_sequence_dispatches]runtime_mod.SequenceDispatch = undefined;
    var buffers: [backend.contract.max_sequence_dispatches][backend.contract.max_sequence_arguments]*runtime_mod.DeviceBuffer = undefined;
    for (sequence.entries[0..sequence.count], 0..) |*entry, index| {
        if (request.failure) |failure| failure.* = .{ .stage = .submit, .dispatch_index = index, .dispatch_name = entry.label() };
        const loaded = try state.getLoaded(entry.loaded);
        for (entry.buffers[0..entry.buffer_count], 0..) |handle, i| buffers[index][i] = try state.getBuffer(handle);
        native[index] = .{
            .kernel = loaded,
            .buffers = buffers[index][0..entry.buffer_count],
            .scalars = entry.scalars[0..entry.scalar_count],
            .grid = entry.grid,
            .threadgroup = entry.threadgroup,
        };
    }
    if (request.wait_events.len > runtime_mod.max_kernel_arguments) return error.LaunchArgumentMismatch;
    var waits: [runtime_mod.max_kernel_arguments]*runtime_mod.Event = undefined;
    for (request.wait_events, 0..) |handle, index| {
        const event = try state.getEvent(handle);
        if (!event.recorded) return error.InvalidEvent;
        waits[index] = event.native orelse return error.InvalidEvent;
    }
    const stream = if (request.stream) |handle| try state.getStream(handle) else null;
    const signal = if (request.signal_event) |handle| try state.getEvent(handle) else null;
    var failed_index: ?usize = null;
    sequence.rt.launchSequence(
        native[0..sequence.count],
        if (stream) |value| value.native orelse return error.InvalidStream else null,
        waits[0..request.wait_events.len],
        if (signal) |event| event.native orelse return error.InvalidEvent else null,
        &failed_index,
    ) catch |err| {
        if (request.failure) |failure| failure.* = .{
            .stage = .submit,
            .dispatch_index = failed_index,
            .dispatch_name = if (failed_index) |index| sequence.entries[index].label() else null,
        };
        return mapRuntimeError(err);
    };
    if (signal) |event| event.recorded = true;
}

fn isLoadableArtifactFormat(format: backend.ArtifactFormat) bool {
    return switch (format) {
        .metal_msl, .metal_metallib => true,
        else => false,
    };
}

pub fn staticCapabilities(has_runtime: bool) backend.BackendCapabilities {
    return .{
        .identity = .{
            .backend = .metal,
            .family = .apple_metal,
            .name = "apple-metal",
        },
        .memory = .{
            .min_buffer_alignment = 256,
            .unified_memory = true,
            .host_visible_device_memory = true,
        },
        .subgroup = .{
            .supported = true,
            .size_min = 32,
            .size_max = 32,
            .shuffle = true,
            .ballot = true,
            .vote = true,
            .arithmetic = true,
            .scan = true,
        },
        .threadgroup = .{
            .max_threads = 1024,
            .max_blocks = .{ 65_535, 65_535, 65_535 },
            .max_threads_per_dim = .{ 1024, 1024, 64 },
            .max_grid_per_dim = .{ 65_535, 65_535, 65_535 },
        },
        .dtypes = backend.DTypeSet.init(&.{ .i1, .i32, .u32, .f16, .f32 }),
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
        },
        .features = .{
            .atomic_i32 = true,
            .atomic_u32 = true,
            .atomic_index = true,
            .atomic_f32_add_device = true,
            .async_copy = true,
        },
        .artifact_formats = backend.ArtifactFormatSet.init(&.{ .metal_msl, .metal_metallib }),
        .textures = .{
            .supported = has_runtime,
            .formats = backend.TextureFormatSet.init(&(color_formats ++ [_]backend.TextureFormat{.depth32_float})),
            .usages = .{
                .copy_src = true,
                .copy_dst = true,
                .sampled = true,
                .color_attachment = true,
                .depth_attachment = true,
            },
            .max_extent = .{ .width = 16_384, .height = 16_384, .depth = 1 },
            .max_sample_count = 1,
            .max_mip_levels = 15,
        },
        .raster = .{
            .supported = has_runtime,
            .artifact_formats = backend.RenderArtifactFormatSet.init(&.{ .metal_msl, .metal_metallib }),
            .target_formats = backend.TextureFormatSet.init(&color_formats),
            .depth_formats = backend.TextureFormatSet.init(&.{.depth32_float}),
            .blend_modes = backend.RenderBlendModeSet.init(&.{ .replace, .alpha_premultiplied, .alpha_straight, .additive }),
            .topologies = backend.RenderPrimitiveTopologySet.init(&.{ .triangle_list, .triangle_strip, .line_list, .line_strip }),
            .vertex_formats = backend.RenderVertexFormatSet.init(&.{ .float32, .float32x2, .float32x3, .float32x4, .uint32, .uint32x2, .uint32x4 }),
            .binding_kinds = backend.RenderBindingKindSet.init(&.{ .uniform_buffer, .sampled_texture }),
            .index_formats = backend.RenderIndexFormatSet.init(&.{ .none, .u16, .u32 }),
            .max_vertex_buffers = max_vertex_buffers,
            .max_vertex_attributes = max_vertex_attributes,
            .max_bindings = max_bindings,
            .instancing = true,
            .max_push_constant_bytes = max_push_constant_bytes,
            .depth_bias = true,
            .depth_bias_clamp = true,
            // Metal's samplers take no level bias; a stage would bias each read itself.
            .max_anisotropy = 16,
            .mip_lod_bias = false,
        },
        .surfaces = .{
            .supported = has_runtime,
            .platforms = backend.SurfacePlatformSet.init(&.{.cocoa}),
            .formats = backend.TextureFormatSet.init(&.{ .bgra8_unorm, .bgra8_srgb }),
            .color_spaces = backend.ColorSpaceSet.init(&.{.srgb}),
            .present_modes = backend.PresentModeSet.init(&.{ .fifo, .immediate }),
            .usages = .{
                .copy_src = true,
                .copy_dst = true,
                .color_attachment = true,
                .present = true,
            },
            .max_extent = .{ .width = 16_384, .height = 16_384 },
            .max_frames_in_flight = 3,
        },
    };
}

const color_formats = [_]backend.TextureFormat{ .rgba8_unorm, .bgra8_unorm, .rgba8_srgb, .bgra8_srgb, .rgba16_float };

fn pixelFormat(format: backend.TextureFormat) metal.PixelFormat {
    return switch (format) {
        .rgba8_unorm => .rgba8_unorm,
        .bgra8_unorm => .bgra8_unorm,
        .rgba8_srgb => .rgba8_unorm_srgb,
        .bgra8_srgb => .bgra8_unorm_srgb,
        .depth32_float => .depth32_float,
        .rgba16_float => .rgba16_float,
    };
}

fn queryCapabilities(ptr: *anyopaque) backend.BackendError!backend.BackendCapabilities {
    const state: *State = @ptrCast(@alignCast(ptr));
    return staticCapabilities(state.runtime.ptr() != null);
}

fn createArtifact(ptr: *anyopaque, request: backend.CompileRequest) backend.BackendError!backend.KernelArtifact {
    if (request.requested_format != .metal_msl) return error.UnsupportedOperation;
    const state: *State = @ptrCast(@alignCast(ptr));
    return switch (request.payload) {
        .text => |source| createMslArtifact(state, request, source),
        .bytes => |source| createMslArtifact(state, request, source),
        .none => error.UnsupportedOperation,
        .words_u32 => error.UnsupportedArtifactFormat,
    };
}

fn createMslArtifact(
    state: *State,
    request: backend.CompileRequest,
    source: []const u8,
) backend.BackendError!backend.KernelArtifact {
    if (request.kernel_name.len == 0) return error.InvalidArtifact;
    if (source.len == 0) return error.InvalidArtifact;

    var artifact = backend.KernelArtifact.init(state.allocator, .{
        .backend = .metal,
        .format = .metal_msl,
        .entry_name = request.kernel_name,
        .argument_count = request.argument_count,
        .scalar_argument_count = request.scalar_argument_count,
        .diagnostic_id = request.diagnostic_id,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    try artifact.setOwnedText(source);
    return artifact;
}

fn loadArtifact(ptr: *anyopaque, artifact: *const backend.KernelArtifact) backend.BackendError!backend.LoadedArtifact {
    if (artifact.backend != .metal) return error.CapabilityMismatch;
    if (artifact.entry_name.len == 0) return error.InvalidArtifact;
    if (!isLoadableArtifactFormat(artifact.format)) return error.UnsupportedArtifactFormat;

    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const kernel = switch (artifact.format) {
        .metal_msl => switch (artifact.payload) {
            .text => |source| if (source.len == 0)
                return error.InvalidArtifact
            else
                rt.loadMsl(
                    source,
                    artifact.entry_name,
                    artifact.argument_count,
                ) catch |err| return mapRuntimeError(err),
            else => return error.InvalidArtifact,
        },
        .metal_metallib => switch (artifact.payload) {
            .bytes => |bytes| if (bytes.len == 0)
                return error.InvalidArtifact
            else
                rt.loadMetallib(
                    bytes,
                    artifact.entry_name,
                    artifact.argument_count,
                ) catch |err| return mapRuntimeError(err),
            else => return error.InvalidArtifact,
        },
        else => unreachable,
    };
    errdefer {
        var owned = kernel;
        owned.deinit();
    }

    const id = try state.putObject(.{ .loaded_artifact = .{
        .kernel = kernel,
        .format = artifact.format,
    } });
    return .{
        .id = id,
        .backend = .metal,
        .format = artifact.format,
    };
}

fn allocateBuffer(ptr: *anyopaque, request: backend.BufferAllocation) backend.BackendError!backend.BufferHandle {
    if (request.byte_size == 0) return error.InvalidBuffer;
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;

    const buffer = rt.allocBuffer(request.byte_size) catch |err| return mapRuntimeError(err);
    errdefer {
        var owned = buffer;
        owned.deinit();
    }

    const id = try state.putObject(.{ .buffer = buffer });
    return .{
        .id = id,
        .backend = .metal,
        .byte_size = request.byte_size,
        .ownership = .backend,
    };
}

fn createStream(ptr: *anyopaque, _: backend.StreamAllocation) backend.BackendError!backend.StreamHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const stream = rt.createStream() catch |err| return mapRuntimeError(err);
    errdefer rt.destroyStream(stream);

    const id = try state.putObject(.{ .stream = .{ .native = stream } });
    return .{
        .id = id,
        .backend = .metal,
    };
}

fn createEvent(ptr: *anyopaque, _: backend.EventAllocation) backend.BackendError!backend.EventHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const event = rt.createEvent() catch |err| return mapRuntimeError(err);
    errdefer rt.destroyEvent(event);

    const id = try state.putObject(.{ .event = .{ .native = event } });
    return .{
        .id = id,
        .backend = .metal,
    };
}

fn writeBuffer(ptr: *anyopaque, request: backend.BufferWriteRequest) backend.BackendError!void {
    if (request.handle.backend != .metal) return error.InvalidBuffer;
    const state: *State = @ptrCast(@alignCast(ptr));
    _ = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const buffer = try state.getBuffer(request.handle);
    if (request.bytes.len > buffer.byte_size) return error.InvalidBuffer;
    buffer.write(request.bytes) catch |err| return mapRuntimeError(err);
}

fn readBuffer(ptr: *anyopaque, request: backend.BufferReadRequest) backend.BackendError!void {
    if (request.handle.backend != .metal) return error.InvalidBuffer;
    const state: *State = @ptrCast(@alignCast(ptr));
    _ = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const buffer = try state.getBuffer(request.handle);
    if (request.bytes.len < buffer.byte_size) return error.ReadBufferDestinationTooSmall;
    if (request.bytes.len > buffer.byte_size) return error.InvalidBuffer;
    buffer.read(request.bytes) catch |err| return mapRuntimeError(err);
}

fn launch(ptr: *anyopaque, request: backend.LaunchRequest) backend.BackendError!void {
    if (request.artifact.backend != .metal) return error.CapabilityMismatch;
    if (!isLoadableArtifactFormat(request.artifact.format)) return error.UnsupportedArtifactFormat;

    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const loaded_handle = request.loaded_artifact orelse return error.InvalidArtifact;
    const loaded = try state.getLoaded(loaded_handle);
    const argument_count = request.buffers.len + request.scalar_arguments.len;
    if (argument_count != @as(usize, @intCast(loaded.argument_count))) {
        return error.LaunchArgumentMismatch;
    }
    if (argument_count > runtime_mod.max_kernel_arguments) return error.LaunchArgumentMismatch;

    var buffers: [runtime_mod.max_kernel_arguments]*runtime_mod.DeviceBuffer = undefined;
    for (request.buffers, 0..) |binding, i| {
        if (binding.handle.backend != .metal or binding.ownership != .backend) {
            return error.InvalidBuffer;
        }
        const buffer = try state.getBuffer(binding.handle);
        if (binding.byte_size > buffer.byte_size or binding.handle.byte_size != buffer.byte_size) {
            return error.InvalidBuffer;
        }
        buffers[i] = buffer;
    }
    var scalars: [runtime_mod.max_kernel_arguments]runtime_mod.ScalarArgument = undefined;
    for (request.scalar_arguments, 0..) |arg, i| {
        scalars[i] = lowerScalarArgument(arg);
    }

    const stream = if (request.stream) |stream_handle|
        try state.getStream(stream_handle)
    else
        null;
    if (request.wait_events.len > runtime_mod.max_kernel_arguments) return error.LaunchArgumentMismatch;
    var wait_events: [runtime_mod.max_kernel_arguments]*runtime_mod.Event = undefined;
    for (request.wait_events, 0..) |event_handle, i| {
        const event = try state.getEvent(event_handle);
        if (!event.recorded) return error.InvalidEvent;
        wait_events[i] = event.native orelse return error.InvalidEvent;
    }
    const signal_event = if (request.signal_event) |event_handle|
        try state.getEvent(event_handle)
    else
        null;

    rt.launch(
        loaded,
        buffers[0..request.buffers.len],
        scalars[0..request.scalar_arguments.len],
        if (stream) |value| value.native orelse return error.InvalidStream else null,
        wait_events[0..request.wait_events.len],
        if (signal_event) |event| event.native orelse return error.InvalidEvent else null,
        request.geometry.grid,
        request.geometry.threadgroup,
    ) catch |err| return mapRuntimeError(err);

    if (signal_event) |event| event.recorded = true;
}

fn lowerScalarArgument(arg: gpu_abi.ScalarArgument) runtime_mod.ScalarArgument {
    return switch (arg) {
        .i32 => |value| .{ .tag = .i32, .bits = @as(u32, @bitCast(value)) },
        .u32 => |value| .{ .tag = .u32, .bits = value },
        .i64 => |value| .{ .tag = .i64, .bits = @bitCast(value) },
        .u64 => |value| .{ .tag = .u64, .bits = value },
        .f32 => |value| .{ .tag = .f32, .bits = @as(u32, @bitCast(value)) },
        .f64 => |value| .{ .tag = .f64, .bits = @bitCast(value) },
    };
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
            return rt.synchronize() catch |err| mapRuntimeError(err);
        },
        .stream => {
            _ = state.runtime.ptr() orelse return error.RuntimeUnavailable;
            const stream = try state.getStream(request.stream.?);
            if (stream.native) |native_stream| {
                native_stream.synchronize() catch |err| return mapRuntimeError(err);
            }
        },
        .event => {
            _ = state.runtime.ptr() orelse return error.RuntimeUnavailable;
            const event = try state.getEvent(request.event.?);
            if (!event.recorded) return error.InvalidEvent;
            if (event.native) |native_event| {
                native_event.synchronize() catch |err| return mapRuntimeError(err);
            }
        },
    }
}

fn queryEvent(ptr: *anyopaque, request: backend.EventQueryRequest) backend.BackendError!bool {
    const state: *State = @ptrCast(@alignCast(ptr));
    _ = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const event = try state.getEvent(request.event);
    if (event.native) |native_event| {
        return native_event.query() catch |err| return mapRuntimeError(err);
    }
    return event.recorded;
}

fn recordEvent(ptr: *anyopaque, request: backend.EventRecordRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    _ = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const stream = try state.getStream(request.stream);
    const event = try state.getEvent(request.event);
    if (stream.native) |native_stream| {
        const native_event = event.native orelse return error.InvalidEvent;
        native_event.record(native_stream) catch |err| return mapRuntimeError(err);
    }
    event.recorded = true;
}

fn destroyObject(ptr: *anyopaque, id: BackendObjectId) void {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (state.objects.fetchRemove(id)) |entry| {
        var object = entry.value;
        releaseLinked(state, &object);
        deinitObject(state, &object);
    }
}

/// Drops the objects that live only through `object`: a surface's unpresented frame and the
/// texture that frame lent.
fn releaseLinked(state: *State, object: *Object) void {
    switch (object.*) {
        .surface => |*surface| {
            if (surface.acquired_texture) |texture_id| _ = state.objects.remove(texture_id);
            if (surface.acquired_frame) |frame_id| if (state.objects.fetchRemove(frame_id)) |frame_entry| {
                var frame_object = frame_entry.value;
                deinitObject(state, &frame_object);
            };
        },
        .surface_frame => |*frame| if (!frame.presented) {
            _ = state.objects.remove(frame.texture_id);
            if (state.getSurfaceById(frame.surface_id)) |surface| {
                surface.acquired_frame = null;
                surface.acquired_texture = null;
            }
        },
        else => {},
    }
}

fn deinitHandle(ptr: *anyopaque, allocator: Allocator) void {
    _ = allocator;
    const state: *State = @ptrCast(@alignCast(ptr));
    state.deinit();
}

fn deinitObject(state: *State, object: *Object) void {
    switch (object.*) {
        .sequence => |*sequence| sequence.deinit(),
        .loaded_artifact => |*artifact| artifact.kernel.deinit(),
        .buffer => |*buffer| buffer.deinit(),
        .stream => |stream| if (stream.native) |native_stream| {
            if (state.runtime.ptr()) |rt| rt.destroyStream(native_stream);
        },
        .event => |event| if (event.native) |native_event| {
            if (state.runtime.ptr()) |rt| rt.destroyEvent(native_event);
        },
        .texture => |*texture| if (!texture.lent) texture.native.deinit(),
        .render_pipeline => |pipeline| {
            releaseNative(pipeline.state);
            if (pipeline.depth_state) |depth_state| releaseNative(depth_state);
        },
        .render_bindings => {},
        .render_bundle => |*bundle| {
            if (bundle.replay) |*replay| replay.deinit(state.allocator);
            if (bundle.commands) |commands| releaseNative(commands);
            if (bundle.push) |push| releaseNative(push);
            state.allocator.free(bundle.runs);
            state.allocator.free(bundle.resources);
        },
        .surface => |*surface| surface.surface.deinit(),
        .surface_frame => |*frame| if (!frame.presented) frame.frame.release(),
    }
    object.* = undefined;
}

fn allocateTexture(ptr: *anyopaque, request: backend.TextureAllocation) backend.BackendError!backend.TextureHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    if (request.sample_count != 1 or request.extent.depth != 1) return error.CapabilityMismatch;
    if (request.usage.present or request.usage.storage) return error.CapabilityMismatch;
    const depth = request.format.isDepth();
    if (depth and request.usage.color_attachment) return error.CapabilityMismatch;
    if (!depth and request.usage.depth_attachment) return error.CapabilityMismatch;
    try state.objects.ensureUnusedCapacity(state.allocator, 1);
    var usage: metal.TextureUsage = 0;
    if (request.usage.sampled) usage |= metal.texture_usage_shader_read;
    if (request.usage.color_attachment or request.usage.depth_attachment) usage |= metal.texture_usage_render_target;
    var native = raster_mod.Texture.create(
        rt,
        pixelFormat(request.format),
        request.extent.width,
        request.extent.height,
        request.format.texelBytes(),
        usage,
        request.mip_levels,
    ) catch |err| return mapRuntimeError(err);
    errdefer native.deinit();
    var texture = backend.TextureHandle{
        .id = 0,
        .backend = .metal,
        .extent = request.extent,
        .format = request.format,
        .usage = request.usage,
        .sample_count = 1,
        .ownership = .backend,
        .mip_levels = request.mip_levels,
    };
    texture.id = try state.putObject(.{ .texture = .{ .handle = texture, .native = native } });
    state.objects.getPtr(texture.id).?.texture.handle.id = texture.id;
    return texture;
}

fn destroyTexture(ptr: *anyopaque, handle: backend.TextureHandle) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const texture = try state.getTexture(handle);
    if (texture.lent) return error.SurfaceAlreadyAcquired;
    const entry = state.objects.fetchRemove(handle.id).?;
    var object = entry.value;
    deinitObject(state, &object);
}

fn writeTexture(ptr: *anyopaque, request: backend.TextureWriteRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const texture = try state.getTexture(request.texture);
    const native = &texture.native;
    const level = request.mip_level;
    if (level >= native.levels) return error.InvalidTexture;
    raster_mod.transferTexture(rt, native.texture, native.levelSize(level), level, native.texel_bytes, .{ .write = request.bytes }) catch |err| {
        return mapRuntimeError(err);
    };
}

fn readTexture(ptr: *anyopaque, request: backend.TextureReadRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const texture = try state.getTexture(request.texture);
    const native = &texture.native;
    const level = request.mip_level;
    if (level >= native.levels) return error.InvalidTexture;
    raster_mod.transferTexture(rt, native.texture, native.levelSize(level), level, native.texel_bytes, .{ .read = request.bytes }) catch |err| {
        return mapRuntimeError(err);
    };
}

fn createRenderArtifact(ptr: *anyopaque, desc: backend.RenderPipelineDesc) backend.BackendError!backend.RenderArtifact {
    const state: *State = @ptrCast(@alignCast(ptr));
    var artifact = backend.RenderArtifact.init(state.allocator, .{
        .backend = .metal,
        .pipeline = desc,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    switch (desc.format) {
        .metal_msl => switch (desc.payload) {
            .text => |text| if (text.len == 0) return error.InvalidRenderArtifact else try artifact.setOwnedText(text),
            else => return error.InvalidRenderArtifact,
        },
        .metal_metallib => switch (desc.payload) {
            .bytes => |bytes| if (bytes.len == 0) return error.InvalidRenderArtifact else try artifact.setOwnedBytes(bytes),
            else => return error.InvalidRenderArtifact,
        },
        else => return error.UnsupportedArtifactFormat,
    }
    return artifact;
}

/// Builds the pipeline an artifact describes. Vertex layout `binding` reads Metal buffer index
/// `binding`, below 8, and attribute `location` is `[[attribute(location)]]`. A uniform block of
/// binding `b` sits at buffer index 16 + b, below 24, and a sampled texture at texture and
/// sampler index `b`, below 16, all in group 0.
fn loadRenderArtifact(ptr: *anyopaque, artifact: *const backend.RenderArtifact) backend.BackendError!backend.LoadedRenderArtifact {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (artifact.backend != .metal) return error.CapabilityMismatch;
    const library: runtime_mod.LibrarySource = switch (artifact.format) {
        .metal_msl => switch (artifact.payload) {
            .text => |text| .{ .msl = text },
            else => return error.InvalidRenderArtifact,
        },
        .metal_metallib => switch (artifact.payload) {
            .bytes => |bytes| .{ .metallib = bytes },
            else => return error.InvalidRenderArtifact,
        },
        else => return error.UnsupportedArtifactFormat,
    };
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    if (artifact.vertex_layouts.len > max_vertex_buffers) return error.CapabilityMismatch;
    if (artifact.bindings.len > max_bindings) return error.CapabilityMismatch;
    if (artifact.push_constant_bytes > max_push_constant_bytes) return error.CapabilityMismatch;
    try state.objects.ensureUnusedCapacity(state.allocator, 1);

    var object: MetalPipeline = .{
        .state = undefined,
        .depth_state = null,
        .bias = if (artifact.depth) |depth| depth.bias else .{},
        .cull = switch (artifact.cull) {
            .none => .none,
            .back => .back,
            .front => .front,
        },
        .primitive = metalPrimitive(artifact.topology),
        .loaded = undefined,
        .layouts = undefined,
        .bindings = undefined,
        .indirect = for (artifact.bindings) |binding| {
            if (binding.kind == .sampled_texture) break false;
        } else true,
    };
    var layouts: [max_vertex_buffers]raster_mod.VertexLayout = undefined;
    var attributes: [max_vertex_attributes]raster_mod.VertexAttribute = undefined;
    var attribute_count: usize = 0;
    var used_buffers: u32 = 0;
    for (artifact.vertex_layouts, 0..) |layout, index| {
        if (layout.binding >= max_vertex_buffers) return error.CapabilityMismatch;
        const bit = @as(u32, 1) << @intCast(layout.binding);
        if (used_buffers & bit != 0) return error.InvalidRenderArtifact;
        used_buffers |= bit;
        const per_instance = layout.step_mode == .instance;
        layouts[index] = .{ .buffer_index = layout.binding, .stride = layout.stride, .per_instance = per_instance };
        object.layouts[index] = .{ .binding = layout.binding, .stride = layout.stride, .per_instance = per_instance };
        const start: usize = layout.attribute_start;
        const count: usize = layout.attribute_count;
        if (start > artifact.vertex_attributes.len or count > artifact.vertex_attributes.len - start) return error.InvalidRenderArtifact;
        for (artifact.vertex_attributes[start..][0..count]) |attribute| {
            if (attribute_count == max_vertex_attributes) return error.CapabilityMismatch;
            if (attribute.location >= max_attribute_location) return error.CapabilityMismatch;
            attributes[attribute_count] = .{
                .location = attribute.location,
                .format = vertexFormat(attribute.format),
                .offset = attribute.offset,
                .buffer_index = layout.binding,
            };
            attribute_count += 1;
        }
    }
    var used_bindings: u32 = 0;
    for (artifact.bindings, 0..) |binding, index| {
        if (binding.group != 0) return error.CapabilityMismatch;
        const limit: u32 = switch (binding.kind) {
            .uniform_buffer => gpu_abi.metal.max_uniform_bindings,
            .sampled_texture => gpu_abi.metal.max_texture_bindings,
            .storage_buffer, .storage_texture => return error.CapabilityMismatch,
        };
        if (binding.binding >= limit) return error.CapabilityMismatch;
        const bit = @as(u32, 1) << @intCast(binding.binding);
        if (used_bindings & bit != 0) return error.InvalidRenderArtifact;
        used_bindings |= bit;
        object.bindings[index] = binding;
    }
    if (artifact.depth) |depth| {
        if (depth.format != .depth32_float) return error.CapabilityMismatch;
    }

    object.state = raster_mod.createPipelineState(rt, .{
        .library = library,
        .vertex_entry = artifact.vertex_entry_name,
        .fragment_entry = artifact.fragment_entry_name,
        .color_format = pixelFormat(artifact.target_format),
        .blend = metalBlend(artifact.blend_mode),
        .depth_format = if (artifact.depth != null) .depth32_float else null,
        .layouts = layouts[0..artifact.vertex_layouts.len],
        .attributes = attributes[0..attribute_count],
        .indirect = object.indirect,
    }) catch |err| return mapRuntimeError(err);
    errdefer releaseNative(object.state);
    if (artifact.depth) |depth| {
        object.depth_state = raster_mod.createDepthState(rt, metalCompare(depth.compare), depth.write) catch |err| {
            return mapRuntimeError(err);
        };
    }
    errdefer if (object.depth_state) |depth_state| releaseNative(depth_state);

    const id = try state.putObject(.{ .render_pipeline = object });
    const loaded = backend.LoadedRenderArtifact.describing(artifact, id);
    state.objects.getPtr(id).?.render_pipeline.loaded = loaded;
    return loaded;
}

fn createRenderBindings(ptr: *anyopaque, request: backend.RenderBindingsRequest) backend.BackendError!backend.RenderBindings {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    try state.objects.ensureUnusedCapacity(state.allocator, 1);
    const pipeline = try state.getRenderPipeline(request.pipeline);
    const count: usize = pipeline.loaded.binding_count;
    if (request.resources.len != count) return error.RenderArgumentMismatch;
    var set = MetalBindings{ .pipeline_id = request.pipeline.id, .entries = undefined, .count = @intCast(count) };
    for (request.resources, pipeline.bindings[0..count], set.entries[0..count]) |resource, binding, *entry| {
        if (std.meta.activeTag(resource) != binding.kind) return error.RenderArgumentMismatch;
        entry.* = .{ .binding = binding.binding, .resource = switch (resource) {
            .uniform_buffer => |buffer_handle| .{ .uniform = (try state.getBuffer(buffer_handle)).buffer },
            .sampled_texture => |sampled| blk: {
                const texture = try state.getTexture(sampled.texture);
                if (!texture.handle.usage.sampled) return error.InvalidTexture;
                const sampler = rt.mipSampler(.{
                    .filter = switch (sampled.sampler.filter) {
                        .nearest => .nearest,
                        .linear => .linear,
                    },
                    .address = switch (sampled.sampler.address) {
                        .clamp_to_edge => .clamp_to_edge,
                        .repeat => .repeat,
                    },
                    .mip = switch (sampled.sampler.mip_filter) {
                        .none => .not_mipmapped,
                        .nearest => .nearest,
                        .linear => .linear,
                    },
                    .anisotropy = sampled.sampler.max_anisotropy,
                }) catch |err| return mapRuntimeError(err);
                break :blk .{ .texture = .{ .texture = texture.native.texture, .sampler = sampler } };
            },
            .storage_buffer, .storage_texture => return error.CapabilityMismatch,
        } };
    }
    const id = try state.putObject(.{ .render_bindings = set });
    return .{ .id = id, .backend = .metal, .pipeline = request.pipeline.id };
}

fn render(ptr: *anyopaque, request: backend.RenderRequest) backend.BackendError!void {
    if (comptime !native_available) return error.RuntimeUnavailable;
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const stream = try state.nativeStream(request.stream);
    var wait_storage: [max_wait_events]*runtime_mod.Event = undefined;
    const waits = try state.nativeWaits(request.wait_events, &wait_storage);
    const signal = try state.nativeSignal(request.signal_event);
    const targets = try passTargets(state, request.pass);

    var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
    defer pool.deinit();
    var submission = raster_mod.Submission.begin(rt, stream, waits) catch |err| return mapRenderError(err);
    const encoder = try beginPass(submission.command_buffer, targets);
    var sink = EncoderSink{ .encoder = encoder };
    recordDraws(state, request.pass, &sink) catch |err| {
        metal.endRenderEncoding(encoder);
        return err;
    };
    metal.endRenderEncoding(encoder);
    submission.finish(if (signal) |event| event.native.? else null) catch |err| return mapRenderError(err);
    if (signal) |event| event.recorded = true;
}

fn recordRenderBundle(ptr: *anyopaque, pass: backend.RenderPass) backend.BackendError!backend.RenderBundle {
    if (comptime !native_available) return error.RuntimeUnavailable;
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    try state.objects.ensureUnusedCapacity(state.allocator, 1);
    const draw_count: u32 = @intCast(pass.draws.len);
    const targets = try passTargets(state, pass);
    const indirect = for (pass.draws) |draw| {
        if (!(try state.getRenderPipeline(draw.pipeline)).indirect) break false;
    } else true;
    if (!indirect) {
        var check = CheckSink{};
        try recordDraws(state, pass, &check);
        var replay = ReplayPass.init(state.allocator, pass) catch return error.OutOfMemory;
        errdefer replay.deinit(state.allocator);
        const id = try state.putObject(.{ .render_bundle = .{
            .replay = replay,
            .commands = null,
            .push = null,
            .targets = targets,
            .runs = &.{},
            .resources = &.{},
            .draw_count = draw_count,
        } });
        return .{ .id = id, .backend = .metal, .draw_count = draw_count };
    }

    var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
    defer pool.deinit();
    const commands = if (draw_count == 0) null else raster_mod.createIndirectCommands(rt, draw_count) catch |err| {
        return mapRenderError(err);
    };
    errdefer if (commands) |owned| releaseNative(owned);
    var push_bytes: usize = 0;
    for (pass.draws) |draw| {
        if (draw.push_constants.len != 0) push_bytes = @as(usize, draw_count) * push_stride;
    }
    const push = if (push_bytes == 0) null else raster_mod.createSharedBuffer(rt, push_bytes) catch |err| {
        return mapRenderError(err);
    };
    errdefer if (push) |owned| releaseNative(owned);

    var sink = BundleSink{
        .allocator = state.allocator,
        .commands = commands,
        .push = push,
        .push_contents = if (push) |buffer| @ptrCast(metal.bufferContents(buffer) orelse return error.RenderFailed) else null,
        .runs = std.ArrayList(BundleRun).initCapacity(state.allocator, pass.draws.len) catch return error.OutOfMemory,
    };
    defer sink.deinit();
    if (push) |buffer| sink.addResource(buffer) catch return error.OutOfMemory;
    try recordDraws(state, pass, &sink);

    const runs = sink.runs.toOwnedSlice(state.allocator) catch return error.OutOfMemory;
    errdefer state.allocator.free(runs);
    const resources = state.allocator.dupe(metal.Buffer, sink.resources.keys()) catch return error.OutOfMemory;
    errdefer state.allocator.free(resources);
    const id = try state.putObject(.{ .render_bundle = .{
        .commands = commands,
        .push = push,
        .targets = targets,
        .runs = runs,
        .resources = resources,
        .draw_count = draw_count,
    } });
    return .{ .id = id, .backend = .metal, .draw_count = draw_count };
}

fn submitRenderBundle(ptr: *anyopaque, request: backend.RenderBundleSubmit) backend.BackendError!void {
    if (comptime !native_available) return error.RuntimeUnavailable;
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const bundle = try state.getRenderBundle(request.bundle);
    const stream = try state.nativeStream(request.stream);
    var wait_storage: [max_wait_events]*runtime_mod.Event = undefined;
    const waits = try state.nativeWaits(request.wait_events, &wait_storage);
    const signal = try state.nativeSignal(request.signal_event);

    var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
    defer pool.deinit();
    var submission = raster_mod.Submission.begin(rt, stream, waits) catch |err| return mapRenderError(err);
    const encoder = try beginPass(submission.command_buffer, bundle.targets);
    if (bundle.replay) |replay| {
        var sink = EncoderSink{ .encoder = encoder };
        recordDraws(state, replay.pass, &sink) catch |err| {
            metal.endRenderEncoding(encoder);
            return err;
        };
    }
    metal.useResources(encoder, bundle.resources);
    for (bundle.runs) |run| {
        setEncoderState(encoder, run.depth_state, run.bias, run.cull);
        for (run.bindings.slice()) |entry| switch (entry.resource) {
            .uniform => {},
            .texture => |bound| {
                metal.setVertexTexture(encoder, bound.texture, bound.sampler, entry.binding);
                metal.setFragmentTexture(encoder, bound.texture, bound.sampler, entry.binding);
            },
        };
        metal.executeCommands(encoder, bundle.commands.?, .{ .location = run.start, .length = run.count });
    }
    metal.endRenderEncoding(encoder);
    submission.finish(if (signal) |event| event.native.? else null) catch |err| return mapRenderError(err);
    if (signal) |event| event.recorded = true;
}

/// The attachments, viewport and scissor of a pass, in Metal's terms.
const Targets = struct {
    color: metal.Texture,
    color_load: metal.LoadAction,
    clear: metal.ClearColor,
    depth: ?metal.Texture,
    depth_load: metal.LoadAction,
    clear_depth: f64,
    viewport: metal.Viewport,
    scissor: metal.ScissorRect,
};

fn passTargets(state: *State, pass: backend.RenderPass) backend.BackendError!Targets {
    const color = try state.getTexture(pass.color.view.texture);
    const depth = if (pass.depth) |attachment| try state.getTexture(attachment.view.texture) else null;
    const clear: backend.SurfaceClearColor = switch (pass.color.load) {
        .load => .{},
        .clear => |value| value,
    };
    return .{
        .color = color.native.texture,
        .color_load = switch (pass.color.load) {
            .load => .load,
            .clear => .clear,
        },
        .clear = .{ .red = clear.r, .green = clear.g, .blue = clear.b, .alpha = clear.a },
        .depth = if (depth) |target| target.native.texture else null,
        .depth_load = if (pass.depth) |attachment| switch (attachment.load) {
            .load => .load,
            .clear => .clear,
        } else .dont_care,
        .clear_depth = if (pass.depth) |attachment| switch (attachment.load) {
            .load => 1,
            .clear => |value| value,
        } else 1,
        .viewport = .{
            .origin_x = pass.viewport.x,
            .origin_y = pass.viewport.y,
            .width = pass.viewport.width,
            .height = pass.viewport.height,
            .znear = pass.viewport.min_depth,
            .zfar = pass.viewport.max_depth,
        },
        .scissor = .{
            .x = pass.scissor.x,
            .y = pass.scissor.y,
            .width = pass.scissor.width,
            .height = pass.scissor.height,
        },
    };
}

/// Opens a render encoder on `targets`. A triangle is front-facing when counter-clockwise on
/// screen, as the contract has it; Metal's default is clockwise. The caller holds an autorelease
/// pool.
fn beginPass(command_buffer: metal.CommandBuffer, targets: Targets) backend.BackendError!metal.RenderCommandEncoder {
    const descriptor = metal.renderPassDescriptor() orelse return error.RenderFailed;
    metal.setColorAttachment(descriptor, targets.color, targets.color_load, targets.clear);
    if (targets.depth) |depth| metal.setDepthAttachment(descriptor, depth, targets.depth_load, targets.clear_depth);
    const encoder = metal.renderCommandEncoder(command_buffer, descriptor) orelse return error.RenderFailed;
    metal.setViewport(encoder, targets.viewport);
    metal.setScissorRect(encoder, targets.scissor);
    metal.setFrontFacingWinding(encoder, .counter_clockwise);
    return encoder;
}

fn setEncoderState(encoder: metal.RenderCommandEncoder, depth_state: ?metal.DepthStencilState, bias: backend.RenderDepthBias, cull: metal.CullMode) void {
    metal.setDepthStencilState(encoder, depth_state);
    metal.setDepthBias(encoder, bias.constant, bias.slope, bias.clamp);
    metal.setCullMode(encoder, cull);
}

/// The draw a pass issues once its state is bound.
const DrawCall = struct {
    draw: backend.RenderDraw,
    primitive: metal.PrimitiveType,
    index: ?struct { buffer: metal.Buffer, offset: u64, format: metal.IndexType },
};

/// Encodes a pass straight into a render encoder, binding only what changed.
const EncoderSink = struct {
    encoder: metal.RenderCommandEncoder,

    fn setPipeline(self: *EncoderSink, pipeline: *const MetalPipeline) void {
        metal.setRenderPipelineState(self.encoder, pipeline.state);
        setEncoderState(self.encoder, pipeline.depth_state, pipeline.bias, pipeline.cull);
    }

    fn setBindings(self: *EncoderSink, bindings: *const MetalBindings) void {
        for (bindings.slice()) |entry| switch (entry.resource) {
            .uniform => |buffer| {
                const index = gpu_abi.metal.uniform_buffer_base + entry.binding;
                metal.setVertexBuffer(self.encoder, buffer, 0, index);
                metal.setFragmentBuffer(self.encoder, buffer, 0, index);
            },
            .texture => |bound| {
                metal.setVertexTexture(self.encoder, bound.texture, bound.sampler, entry.binding);
                metal.setFragmentTexture(self.encoder, bound.texture, bound.sampler, entry.binding);
            },
        };
    }

    fn setVertexBuffer(self: *EncoderSink, binding: u32, buffer: metal.Buffer, offset: u64) error{OutOfMemory}!void {
        metal.setVertexBuffer(self.encoder, buffer, offset, binding);
    }

    fn issue(self: *EncoderSink, call: DrawCall) error{OutOfMemory}!void {
        const draw = call.draw;
        if (draw.push_constants.len != 0) {
            metal.setVertexBytes(self.encoder, draw.push_constants, gpu_abi.metal.push_buffer);
            metal.setFragmentBytes(self.encoder, draw.push_constants, gpu_abi.metal.push_buffer);
        }
        const range = draw.range;
        if (call.index) |index| {
            metal.drawIndexedPrimitives(self.encoder, call.primitive, range.index_count, index.format, index.buffer, index.offset, range.instance_count, range.base_vertex, range.first_instance);
        } else {
            metal.drawPrimitives(self.encoder, call.primitive, range.first_vertex, range.vertex_count, range.instance_count, range.first_instance);
        }
    }
};

/// Takes a pass's draws and encodes nothing: `recordDraws` through it only checks the pass.
const CheckSink = struct {
    fn setPipeline(_: *CheckSink, _: *const MetalPipeline) void {}
    fn setBindings(_: *CheckSink, _: *const MetalBindings) void {}
    fn setVertexBuffer(_: *CheckSink, _: u32, _: metal.Buffer, _: u64) error{OutOfMemory}!void {}
    fn issue(_: *CheckSink, _: DrawCall) error{OutOfMemory}!void {}
};

/// Encodes a pass into an indirect command buffer. A command inherits nothing from the command
/// before it, so each one sets the pipeline, vertex buffers and uniform blocks its draw reads.
const BundleSink = struct {
    allocator: Allocator,
    commands: ?metal.IndirectCommandBuffer,
    push: ?metal.Buffer,
    push_contents: ?[*]u8,
    runs: std.ArrayList(BundleRun),
    resources: std.AutoArrayHashMapUnmanaged(metal.Buffer, void) = .empty,
    pipeline: ?*const MetalPipeline = null,
    bindings: ?*const MetalBindings = null,
    vertex_buffers: [max_vertex_buffers]?struct { buffer: metal.Buffer, offset: u64 } = @splat(null),
    next: u32 = 0,
    run_open: bool = false,

    fn deinit(self: *BundleSink) void {
        self.runs.deinit(self.allocator);
        self.resources.deinit(self.allocator);
    }

    fn addResource(self: *BundleSink, buffer: metal.Buffer) error{OutOfMemory}!void {
        try self.resources.put(self.allocator, buffer, {});
    }

    fn setPipeline(self: *BundleSink, pipeline: *const MetalPipeline) void {
        self.pipeline = pipeline;
        self.run_open = false;
    }

    fn setBindings(self: *BundleSink, bindings: *const MetalBindings) void {
        self.bindings = bindings;
        self.run_open = false;
    }

    fn setVertexBuffer(self: *BundleSink, binding: u32, buffer: metal.Buffer, offset: u64) error{OutOfMemory}!void {
        self.vertex_buffers[binding] = .{ .buffer = buffer, .offset = offset };
        try self.addResource(buffer);
    }

    fn issue(self: *BundleSink, call: DrawCall) error{OutOfMemory}!void {
        const pipeline = self.pipeline.?;
        const draw = call.draw;
        if (!self.run_open) {
            self.runs.appendAssumeCapacity(.{
                .start = self.next,
                .count = 0,
                .depth_state = pipeline.depth_state,
                .bias = pipeline.bias,
                .cull = pipeline.cull,
                .bindings = if (draw.bindings != null) self.bindings.?.* else .{ .pipeline_id = 0, .entries = undefined, .count = 0 },
            });
            self.run_open = true;
        }
        self.runs.items[self.runs.items.len - 1].count += 1;
        const command = metal.indirectRenderCommand(self.commands.?, self.next);
        metal.setIndirectPipelineState(command, pipeline.state);
        for (pipeline.layouts[0..draw.vertex_buffers.len]) |layout| {
            const bound = self.vertex_buffers[layout.binding].?;
            metal.setIndirectVertexBuffer(command, bound.buffer, bound.offset, layout.binding);
        }
        if (draw.bindings != null) for (self.bindings.?.slice()) |entry| switch (entry.resource) {
            .uniform => |buffer| {
                const index = gpu_abi.metal.uniform_buffer_base + entry.binding;
                metal.setIndirectVertexBuffer(command, buffer, 0, index);
                metal.setIndirectFragmentBuffer(command, buffer, 0, index);
                try self.addResource(buffer);
            },
            .texture => {},
        };
        if (draw.push_constants.len != 0) {
            const offset = @as(u64, self.next) * push_stride;
            @memcpy(self.push_contents.?[@intCast(offset)..][0..draw.push_constants.len], draw.push_constants);
            metal.setIndirectVertexBuffer(command, self.push.?, offset, gpu_abi.metal.push_buffer);
            metal.setIndirectFragmentBuffer(command, self.push.?, offset, gpu_abi.metal.push_buffer);
        }
        const range = draw.range;
        if (call.index) |index| {
            try self.addResource(index.buffer);
            metal.indirectDrawIndexedPrimitives(command, call.primitive, range.index_count, index.format, index.buffer, index.offset, range.instance_count, range.base_vertex, range.first_instance);
        } else {
            metal.indirectDrawPrimitives(command, call.primitive, range.first_vertex, range.vertex_count, range.instance_count, range.first_instance);
        }
        self.next += 1;
    }
};

const VertexSlot = struct {
    id: BackendObjectId,
    offset: u64,
    size: u64,
};

/// Checks every draw of `pass` and hands `sink` what changed before each one, as the Vulkan
/// backend's pass recording does: each range a draw reads is checked against its buffer, except
/// the vertices an indexed draw reaches through its indices, which only the indices name.
fn recordDraws(state: *State, pass: backend.RenderPass, sink: anytype) backend.BackendError!void {
    var pipeline: ?*MetalPipeline = null;
    var bindings_id: ?BackendObjectId = null;
    var vertex_slots: [max_vertex_buffers]?VertexSlot = @splat(null);
    for (pass.draws) |draw| {
        const current = if (pipeline != null and pipeline.?.loaded.id == draw.pipeline.id) pipeline.? else blk: {
            const next = try state.getRenderPipeline(draw.pipeline);
            if (next.loaded.target_format != pass.color.view.format) return error.RenderArgumentMismatch;
            if ((next.loaded.depth != null) != (pass.depth != null)) return error.RenderArgumentMismatch;
            sink.setPipeline(next);
            bindings_id = null;
            pipeline = next;
            break :blk next;
        };
        if (draw.vertex_buffers.len != current.loaded.vertex_buffer_count) return error.RenderArgumentMismatch;
        if ((draw.bindings != null) != (current.loaded.binding_count != 0)) return error.RenderArgumentMismatch;
        if (draw.bindings) |bindings| if (bindings_id != bindings.id) {
            const set = try state.getRenderBindings(bindings);
            if (set.pipeline_id != current.loaded.id) return error.RenderArgumentMismatch;
            sink.setBindings(set);
            bindings_id = bindings.id;
        };
        if (draw.push_constants.len != current.loaded.push_constant_bytes) return error.RenderArgumentMismatch;
        const indexed = draw.range.index_format != .none;
        for (draw.vertex_buffers, current.layouts[0..draw.vertex_buffers.len]) |range, layout| {
            const slot = &vertex_slots[layout.binding];
            const bound = if (slot.*) |existing| existing.id == range.buffer.id and existing.offset == range.offset else false;
            if (!bound) {
                const buffer = try state.getBuffer(range.buffer);
                if (range.offset >= buffer.byte_size) return error.RenderArgumentMismatch;
                sink.setVertexBuffer(layout.binding, buffer.buffer, range.offset) catch return error.OutOfMemory;
                slot.* = .{ .id = range.buffer.id, .offset = range.offset, .size = buffer.byte_size };
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
            sink.issue(.{ .draw = draw, .primitive = current.primitive, .index = null }) catch return error.OutOfMemory;
            continue;
        }
        const range = draw.index_buffer orelse return error.RenderArgumentMismatch;
        const index_bytes: u64 = if (draw.range.index_format == .u16) 2 else 4;
        const buffer = try state.getBuffer(range.buffer);
        if (range.offset >= buffer.byte_size or range.offset % index_bytes != 0) return error.RenderArgumentMismatch;
        const indices = @as(u64, draw.range.first_index) + draw.range.index_count;
        if (indices * index_bytes > buffer.byte_size - range.offset) return error.RenderArgumentMismatch;
        sink.issue(.{ .draw = draw, .primitive = current.primitive, .index = .{
            .buffer = buffer.buffer,
            .offset = range.offset + @as(u64, draw.range.first_index) * index_bytes,
            .format = if (index_bytes == 2) .uint16 else .uint32,
        } }) catch return error.OutOfMemory;
    }
}

/// Makes a `CAMetalLayer` over the layer of the Cocoa window `request` names, as
/// `Window.getNativeSurface` returns it. The layer draws at `request.extent`, in pixels. FIFO
/// presentation syncs to the display; immediate does not.
fn createSurface(ptr: *anyopaque, request: backend.SurfaceCreationRequest) backend.BackendError!backend.SurfaceHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const cocoa = switch (request.platform) {
        .cocoa => |native| native,
        else => return error.CapabilityMismatch,
    };
    if (cocoa.layer == 0) return error.InvalidSurface;
    const format: metal.PixelFormat = switch (request.format) {
        .bgra8_unorm, .bgra8_srgb => pixelFormat(request.format),
        else => return error.CapabilityMismatch,
    };
    const display_sync = switch (request.present_mode) {
        .fifo => true,
        .immediate => false,
        .mailbox => return error.CapabilityMismatch,
    };
    try state.objects.ensureUnusedCapacity(state.allocator, 1);
    var surface = raster_mod.Surface.create(
        rt,
        @ptrFromInt(cocoa.layer),
        format,
        request.extent.width,
        request.extent.height,
        std.math.clamp(request.max_frames_in_flight, 2, 3),
        display_sync,
    ) catch |err| return mapSurfaceError(err);
    errdefer surface.deinit();
    var handle = backend.SurfaceHandle{
        .id = 0,
        .backend = .metal,
        .platform = .cocoa,
        .extent = request.extent,
        .format = request.format,
        .color_space = request.color_space,
        .present_mode = request.present_mode,
    };
    handle.id = try state.putObject(.{ .surface = .{ .surface = surface, .handle = handle } });
    state.objects.getPtr(handle.id).?.surface.handle.id = handle.id;
    return handle;
}

fn destroySurface(ptr: *anyopaque, handle: backend.SurfaceHandle) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const surface = try state.getSurface(handle);
    if (surface.handle.generation != handle.generation) return error.SurfaceFrameExpired;
    if (surface.acquired_frame != null) return error.SurfaceAlreadyAcquired;
    const entry = state.objects.fetchRemove(handle.id).?;
    var object = entry.value;
    deinitObject(state, &object);
}

fn acquireSurfaceFrame(ptr: *anyopaque, request: backend.SurfaceFrameAcquireRequest) backend.BackendError!backend.SurfaceFrame {
    const state: *State = @ptrCast(@alignCast(ptr));
    try state.objects.ensureUnusedCapacity(state.allocator, 2);
    const surface = try state.getSurface(request.surface);
    if (surface.handle.generation != request.surface.generation) return error.SurfaceFrameExpired;
    if (surface.acquired_frame != null) return error.SurfaceAlreadyAcquired;
    const texture_id = state.next_id;
    if (texture_id >= std.math.maxInt(BackendObjectId) - 1) return error.OutOfMemory;
    const frame_id = texture_id + 1;

    var native = surface.surface.acquire() catch |err| return mapSurfaceError(err);
    errdefer native.release();
    state.next_id = frame_id + 1;
    const texture = backend.TextureHandle{
        .id = texture_id,
        .backend = .metal,
        .extent = .{ .width = surface.handle.extent.width, .height = surface.handle.extent.height, .depth = 1 },
        .format = surface.handle.format,
        .usage = .{ .copy_src = true, .copy_dst = true, .color_attachment = true, .present = true },
        .sample_count = 1,
        .ownership = .acquired_surface,
    };
    surface.acquired_frame = frame_id;
    surface.acquired_texture = texture_id;
    state.objects.putAssumeCapacityNoClobber(texture_id, .{ .texture = .{
        .handle = texture,
        .native = .{ .texture = native.texture, .size = .{ .width = texture.extent.width, .height = texture.extent.height, .depth = 1 }, .texel_bytes = 4 },
        .lent = true,
    } });
    state.objects.putAssumeCapacityNoClobber(frame_id, .{ .surface_frame = .{
        .surface_id = request.surface.id,
        .texture_id = texture_id,
        .frame = native,
        .generation = surface.handle.generation,
    } });
    return .{
        .id = frame_id,
        .backend = .metal,
        .surface = surface.handle,
        .texture = texture,
        .view = .{ .texture = texture, .format = texture.format },
        .generation = surface.handle.generation,
    };
}

/// Checks that `request_frame` is the frame `request_surface` lent and has not presented.
fn liveFrame(
    state: *State,
    request_surface: backend.SurfaceHandle,
    request_frame: backend.SurfaceFrame,
) backend.BackendError!struct { *MetalSurface, *MetalFrame } {
    const surface = try state.getSurface(request_surface);
    const frame = try state.getFrame(request_frame);
    if (surface.handle.generation != request_surface.generation) return error.SurfaceFrameExpired;
    if (frame.generation != request_frame.generation) return error.SurfaceFrameExpired;
    if (frame.presented) return error.SurfaceFrameExpired;
    if (frame.surface_id != request_surface.id) return error.InvalidSurfaceFrame;
    if (frame.texture_id != request_frame.texture.id) return error.InvalidSurfaceFrame;
    if (surface.acquired_frame == null or surface.acquired_frame.? != request_frame.id) return error.InvalidSurfaceFrame;
    return .{ surface, frame };
}

/// Presents a frame. Presenting consumes the drawable whether or not it succeeds, so the frame and
/// its texture leave the surface before the native call, and a failed present releases nothing twice.
fn presentSurfaceFrame(ptr: *anyopaque, request: backend.PresentRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    if (request.signal_event != null) return error.UnsupportedOperation;
    const surface, const frame = try liveFrame(state, request.surface, request.frame);
    var wait_storage: [max_wait_events]*runtime_mod.Event = undefined;
    const waits = try state.nativeWaits(request.wait_events, &wait_storage);
    frame.presented = true;
    surface.acquired_frame = null;
    surface.acquired_texture = null;
    _ = state.objects.remove(frame.texture_id);
    surface.surface.present(rt, &frame.frame, waits) catch |err| return mapSurfaceError(err);
}

fn writeSurfaceFrame(ptr: *anyopaque, request: backend.SurfaceFrameWriteRequest) backend.BackendError!void {
    if (comptime !native_available) return error.RuntimeUnavailable;
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    _, const frame = try liveFrame(state, request.surface, request.frame);
    if (frame.written) return error.SurfaceFrameExpired;
    var wait_storage: [max_wait_events]*runtime_mod.Event = undefined;
    const waits = try state.nativeWaits(request.wait_events, &wait_storage);
    const signal = try state.nativeSignal(request.signal_event);
    const extent = request.frame.texture.extent;
    const size = metal.Size{ .width = extent.width, .height = extent.height, .depth = 1 };

    var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
    defer pool.deinit();
    var submission = raster_mod.Submission.begin(rt, null, waits) catch |err| return mapRenderError(err);
    for (request.operations) |op| switch (op) {
        .clear => |color| {
            const encoder = try beginPass(submission.command_buffer, .{
                .color = frame.frame.texture,
                .color_load = .clear,
                .clear = .{ .red = color.r, .green = color.g, .blue = color.b, .alpha = color.a },
                .depth = null,
                .depth_load = .dont_care,
                .clear_depth = 1,
                .viewport = .{ .origin_x = 0, .origin_y = 0, .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height), .znear = 0, .zfar = 1 },
                .scissor = .{ .x = 0, .y = 0, .width = extent.width, .height = extent.height },
            });
            metal.endRenderEncoding(encoder);
        },
        .copy_buffer => |buffer_handle| {
            const buffer = try state.getBuffer(buffer_handle);
            if (buffer.byte_size < @as(usize, extent.width) * extent.height * 4) return error.InvalidBuffer;
            const blit = metal.blitCommandEncoder(submission.command_buffer) orelse return error.RenderFailed;
            metal.copyBufferToTexture(blit, buffer.buffer, @as(u64, extent.width) * 4, frame.frame.texture, size);
            metal.endBlitEncoding(blit);
        },
    };
    submission.finish(if (signal) |event| event.native.? else null) catch |err| return mapRenderError(err);
    if (signal) |event| event.recorded = true;
    frame.written = true;
}

fn readSurfaceFrame(ptr: *anyopaque, request: backend.SurfaceFrameReadRequest) backend.BackendError!void {
    if (comptime !native_available) return error.RuntimeUnavailable;
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    _, const frame = try liveFrame(state, request.surface, request.frame);
    const buffer = try state.getBuffer(request.buffer);
    const extent = request.frame.texture.extent;
    if (buffer.byte_size < @as(usize, extent.width) * extent.height * 4) return error.InvalidBuffer;
    const size = metal.Size{ .width = extent.width, .height = extent.height, .depth = 1 };

    var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
    defer pool.deinit();
    var submission = raster_mod.Submission.begin(rt, null, &.{}) catch |err| return mapRenderError(err);
    const blit = metal.blitCommandEncoder(submission.command_buffer) orelse return error.RenderFailed;
    metal.copyTextureToBuffer(blit, frame.frame.texture, size, buffer.buffer, @as(u64, extent.width) * 4);
    metal.endBlitEncoding(blit);
    submission.finish(null) catch |err| return mapRenderError(err);
}

fn metalPrimitive(topology: backend.RenderPrimitiveTopology) metal.PrimitiveType {
    return switch (topology) {
        .triangle_list => .triangle,
        .triangle_strip => .triangle_strip,
        .line_list => .line,
        .line_strip => .line_strip,
    };
}

fn metalCompare(compare: backend.RenderCompare) metal.CompareFunction {
    return switch (compare) {
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_equal => .less_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_equal => .greater_equal,
        .always => .always,
    };
}

/// The factors of each blend mode's equations, as `RenderBlendMode` states them.
fn metalBlend(mode: backend.RenderBlendMode) ?metal.Blend {
    return switch (mode) {
        .replace => null,
        .alpha_premultiplied => .{
            .source_rgb = .one,
            .destination_rgb = .one_minus_source_alpha,
            .source_alpha = .one,
            .destination_alpha = .one_minus_source_alpha,
        },
        .alpha_straight => .{
            .source_rgb = .source_alpha,
            .destination_rgb = .one_minus_source_alpha,
            .source_alpha = .one,
            .destination_alpha = .one_minus_source_alpha,
        },
        .additive => .{
            .source_rgb = .one,
            .destination_rgb = .one,
            .source_alpha = .one,
            .destination_alpha = .one,
        },
    };
}

fn vertexFormat(format: backend.RenderVertexFormat) metal.VertexFormat {
    return switch (format) {
        .float32 => .float,
        .float32x2 => .float2,
        .float32x3 => .float3,
        .float32x4 => .float4,
        .uint32 => .uint,
        .uint32x2 => .uint2,
        .uint32x4 => .uint4,
    };
}

/// Maps a runtime failure met while recording or submitting a pass.
fn mapRenderError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.LaunchFailed => error.RenderFailed,
        else => mapRuntimeError(err),
    };
}

fn mapSurfaceError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.SurfaceUnavailable => error.InvalidSurface,
        error.FrameUnavailable => error.SurfaceFrameExpired,
        error.LaunchFailed => error.RenderFailed,
        else => mapRuntimeError(err),
    };
}

fn mapRuntimeError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.UnsupportedPlatform,
        error.RuntimeUnavailable,
        error.DeviceUnavailable,
        => error.RuntimeUnavailable,
        error.CompilationFailed => error.CompilationFailed,
        error.LaunchFailed,
        => error.LaunchFailed,
        error.ResultMismatch => error.ResultMismatch,
        error.DeviceLost => error.DeviceLost,
        error.InvalidArtifact => error.InvalidArtifact,
        error.InvalidBuffer => error.InvalidBuffer,
        error.InvalidStream => error.InvalidStream,
        error.InvalidEvent => error.InvalidEvent,
        error.OutOfMemory => error.OutOfMemory,
        error.SurfaceUnavailable => error.InvalidSurface,
        error.FrameUnavailable => error.SurfaceFrameExpired,
    };
}

const vtable = backend.BackendVTable{
    .query_capabilities = queryCapabilities,
    .create_artifact = createArtifact,
    .load_artifact = loadArtifact,
    .allocate_buffer = allocateBuffer,
    .create_stream = createStream,
    .create_event = createEvent,
    .write_buffer = writeBuffer,
    .read_buffer = readBuffer,
    .launch = launch,
    .record_sequence = recordSequence,
    .submit_sequence = submitSequence,
    .create_render_artifact = createRenderArtifact,
    .load_render_artifact = loadRenderArtifact,
    .allocate_texture = allocateTexture,
    .destroy_texture = destroyTexture,
    .write_texture = writeTexture,
    .read_texture = readTexture,
    .create_render_bindings = createRenderBindings,
    .render = render,
    .record_render_bundle = recordRenderBundle,
    .submit_render_bundle = submitRenderBundle,
    .create_surface = createSurface,
    .destroy_surface = destroySurface,
    .acquire_surface_frame = acquireSurfaceFrame,
    .present_surface_frame = presentSurfaceFrame,
    .write_surface_frame = writeSurfaceFrame,
    .read_surface_frame = readSurfaceFrame,
    .synchronize = synchronize,
    .query_event = queryEvent,
    .record_event = recordEvent,
    .destroy_object = destroyObject,
    .deinit = deinitHandle,
};

fn fakeRuntime(handle: *anyopaque) Runtime {
    return .{
        .allocator = std.testing.allocator,
        .device = @ptrCast(handle),
    };
}

/// Fills the top half of the target, in the contract's clip space where y = -1 is the top edge,
/// with the color its push constants carry.
const live_top_half_msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct live_out { float4 position [[position]]; };
    \\
    \\vertex live_out live_vertex(uint id [[vertex_id]]) {
    \\    const float2 corners[6] = {
    \\        float2(-1, -1), float2(1, -1), float2(-1, 0),
    \\        float2(1, -1), float2(1, 0), float2(-1, 0),
    \\    };
    \\    live_out out = {};
    \\    out.position = float4(corners[id], 0.5, 1);
    \\    out.position.y = -out.position.y;
    \\    return out;
    \\}
    \\
    \\fragment float4 live_fragment(live_out in [[stage_in]], constant uint* push [[buffer(30)]]) {
    \\    return float4(as_type<float>(push[0]), as_type<float>(push[1]), as_type<float>(push[2]), 1);
    \\}
;

/// Covers the target and reads the texture at binding 0 at its center, at the mip level the first
/// push word names.
const live_level_msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct live_out { float4 position [[position]]; };
    \\vertex live_out level_vertex(uint id [[vertex_id]]) {
    \\    const float2 corners[6] = {
    \\        float2(-1, -1), float2(1, -1), float2(-1, 1),
    \\        float2(1, -1), float2(1, 1), float2(-1, 1),
    \\    };
    \\    live_out out;
    \\    out.position = float4(corners[id], 0.5, 1);
    \\    return out;
    \\}
    \\fragment float4 level_fragment(live_out in [[stage_in]], constant uint* push [[buffer(30)]],
    \\        texture2d<float> choir_texture0 [[texture(0)]], sampler choir_sampler0 [[sampler(0)]]) {
    \\    return choir_texture0.sample(choir_sampler0, float2(0.5, 0.5), level(as_type<float>(push[0])));
    \\}
;

/// Two triangles in contract clip space, y = -1 at the top, flipped for Metal as Choir's emitter
/// flips them. The first covers the top-left half, counter-clockwise on screen and so front-facing
/// by the contract; the second covers the bottom-right half, clockwise and so back-facing.
const live_facing_msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct live_out { float4 position [[position]]; };
    \\vertex live_out facing_vertex(uint id [[vertex_id]]) {
    \\    const float2 corners[6] = {
    \\        float2(-1, -1), float2(-1, 1), float2(1, -1),
    \\        float2(-1, 1), float2(1, -1), float2(1, 1),
    \\    };
    \\    live_out out;
    \\    out.position = float4(corners[id].x, -corners[id].y, 0, 1);
    \\    return out;
    \\}
    \\fragment float4 facing_fragment(bool front [[front_facing]]) {
    \\    return front ? float4(1, 0, 0, 1) : float4(0, 1, 0, 1);
    \\}
;

fn expectTopHalf(texels: []const u8, side: usize) !void {
    for (0..side) |y| {
        const expected: [4]u8 = if (y < side / 2) .{ 255, 0, 0, 255 } else .{ 0, 0, 255, 255 };
        for (0..side) |x| {
            try std.testing.expectEqualSlices(u8, &expected, texels[(y * side + x) * 4 ..][0..4]);
        }
    }
}

fn compileMetallibOrSkip(allocator: Allocator, source: []const u8) ![]u8 {
    const dir = try metallibScratchDir(allocator);
    defer removeMetallibScratchDir(allocator, dir);

    const source_path = try sys.path.join(allocator, &.{ dir, "kernel.metal" });
    defer allocator.free(source_path);
    const air_path = try sys.path.join(allocator, &.{ dir, "kernel.air" });
    defer allocator.free(air_path);
    const metallib_path = try sys.path.join(allocator, &.{ dir, "kernel.metallib" });
    defer allocator.free(metallib_path);

    try sys.fs.writeFile(source_path, source);

    const metal_result = try runMetalToolOrSkip(allocator, &.{ "xcrun", "-sdk", "macosx", "metal", "-c", source_path, "-o", air_path });
    defer allocator.free(metal_result.stdout);
    defer allocator.free(metal_result.stderr);
    if (sys.process.exitCode(metal_result.term) != 0) {
        pretty.diagnostic.writeStderrText(
            "xcrun metal failed\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ metal_result.stdout, metal_result.stderr },
        );
        return error.MetalToolRejected;
    }

    const metallib_result = try runMetalToolOrSkip(allocator, &.{ "xcrun", "-sdk", "macosx", "metallib", air_path, "-o", metallib_path });
    defer allocator.free(metallib_result.stdout);
    defer allocator.free(metallib_result.stderr);
    if (sys.process.exitCode(metallib_result.term) != 0) {
        pretty.diagnostic.writeStderrText(
            "xcrun metallib failed\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ metallib_result.stdout, metallib_result.stderr },
        );
        return error.MetalToolRejected;
    }

    return try sys.fs.readFileAlloc(allocator, metallib_path, 4 * 1024 * 1024);
}

/// Runs an Xcode tool, skipping the test when the tool is absent. Xcode ships `xcrun metal` as a
/// shim until its Metal Toolchain component is downloaded, which counts as absent.
fn runMetalToolOrSkip(allocator: Allocator, argv: []const []const u8) !sys.process.RunResult {
    var io_state = std.Io.Threaded.init(allocator, .{ .environ = sys.env.current() });
    defer io_state.deinit();
    const result = sys.process.run(allocator, io_state.io(), .{
        .argv = argv,
        .expand_arg0 = .expand,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SkipZigTest,
    };
    if (std.mem.indexOf(u8, result.stderr, "missing Metal Toolchain") != null) {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return error.SkipZigTest;
    }
    return result;
}

fn metallibScratchDir(allocator: Allocator) ![]u8 {
    const base = sys.env.get("TMPDIR") orelse "/tmp";
    const pid = sys.process.currentProcessId() catch 0;
    const dir = try std.fmt.allocPrint(allocator, "{s}/gpu-metal-metallib-{d}", .{ base, pid });
    errdefer allocator.free(dir);
    try sys.fs.createDirPath(dir);
    return dir;
}

fn removeMetallibScratchDir(allocator: Allocator, dir: []u8) void {
    sys.fs.deleteTree(dir) catch {};
    allocator.free(dir);
}

fn initRuntimeOrSkip(allocator: Allocator) (runtime_mod.Error || error{SkipZigTest})!Runtime {
    if (!build_options.metal_tests) return error.SkipZigTest;
    switch (runtime_mod.detectAvailability()) {
        .available => {},
        .unsupported_platform,
        .runtime_missing,
        .device_missing,
        => return error.SkipZigTest,
    }
    return Runtime.init(allocator) catch |err| switch (err) {
        error.UnsupportedPlatform,
        error.RuntimeUnavailable,
        error.DeviceUnavailable,
        => return error.SkipZigTest,
        else => return err,
    };
}
