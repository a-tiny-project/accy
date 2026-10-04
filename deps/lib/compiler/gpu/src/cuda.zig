const std = @import("std");
const gpu_abi = @import("gpu_abi");
const builtin = @import("builtin");
const build_options = @import("build_options");
const sys = @import("sys");

const backend = @import("root.zig");
const runtime_root = @import("runtime/root.zig");

const driver_mod = sys.cuda;
const runtime_mod = runtime_root.cuda.runtime;

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

    fn constPtr(self: *const RuntimeStorage) ?*const Runtime {
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

pub fn platformSupported() bool {
    return driver_mod.platformSupported();
}

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

    pub fn initDevice(allocator: Allocator, device_ordinal: i32) backend.BackendError!State {
        const runtime = Runtime.init(allocator, device_ordinal) catch |err| return mapRuntimeInitError(err);
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
            deinitObject(self.allocator, entry.value_ptr);
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
            .kind = .cuda,
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
        if (loaded.backend != .cuda or loaded.format != .cuda_ptx) return error.InvalidArtifact;
        const object = self.objects.getPtr(loaded.id) orelse return error.InvalidArtifact;
        return switch (object.*) {
            .loaded_artifact => |*kernel| kernel,
            else => error.InvalidArtifact,
        };
    }

    fn getBuffer(self: *State, buffer_handle: backend.BufferHandle) backend.BackendError!*runtime_mod.DeviceBuffer {
        if (buffer_handle.backend != .cuda) return error.InvalidBuffer;
        const object = self.objects.getPtr(buffer_handle.id) orelse return error.InvalidBuffer;
        return switch (object.*) {
            .buffer => |*buffer| buffer,
            else => error.InvalidBuffer,
        };
    }

    fn getStream(self: *State, stream_handle: backend.StreamHandle) backend.BackendError!*runtime_mod.Stream {
        if (stream_handle.backend != .cuda) return error.InvalidStream;
        const object = self.objects.getPtr(stream_handle.id) orelse return error.InvalidStream;
        return switch (object.*) {
            .stream => |stream| stream,
            else => error.InvalidStream,
        };
    }

    fn getEvent(self: *State, event_handle: backend.EventHandle) backend.BackendError!*runtime_mod.Event {
        if (event_handle.backend != .cuda) return error.InvalidEvent;
        const object = self.objects.getPtr(event_handle.id) orelse return error.InvalidEvent;
        return switch (object.*) {
            .event => |event| event,
            else => error.InvalidEvent,
        };
    }
};

const LoadedKernel = struct {
    module: *runtime_mod.Module,
    kernel: runtime_mod.Kernel,
    entry_name: [:0]u8,
    argument_count: u32,
};

const Object = union(enum) {
    loaded_artifact: LoadedKernel,
    sequence: runtime_mod.Graph,
    buffer: runtime_mod.DeviceBuffer,
    stream: *runtime_mod.Stream,
    event: *runtime_mod.Event,
};

fn recordSequence(ptr: *anyopaque, request: backend.contract.SequenceRecordRequest) backend.BackendError!backend.contract.SequenceHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    // Keep the default-stream allocation out of the replay path.
    _ = rt.defaultStream() catch |err| return mapStreamError(err);
    var graph_dispatches: [backend.contract.max_sequence_dispatches]runtime_mod.GraphDispatch = undefined;
    var args: [backend.contract.max_sequence_dispatches][backend.contract.max_sequence_arguments]runtime_mod.KernelArg = undefined;
    for (request.dispatches, 0..) |dispatch, index| {
        if (request.failure) |failure| failure.* = .{
            .stage = .record,
            .dispatch_index = index,
            .dispatch_name = dispatch.name,
        };
        const launch_request = dispatch.launch;
        const loaded = state.getLoaded(launch_request.loaded_artifact orelse return error.InvalidArtifact) catch |err| {
            if (request.failure) |failure| failure.* = .{ .stage = .record, .dispatch_index = index, .dispatch_name = dispatch.name };
            return err;
        };
        const count = launch_request.buffers.len + launch_request.scalar_arguments.len;
        if (count != loaded.argument_count) return error.LaunchArgumentMismatch;
        for (launch_request.buffers, 0..) |binding, arg_index| {
            if (binding.ownership != .backend) return error.InvalidBuffer;
            const buffer = try state.getBuffer(binding.handle);
            if (binding.byte_size > buffer.bytes or binding.handle.byte_size != buffer.bytes) return error.InvalidBuffer;
            args[index][arg_index] = .{ .device_ptr = buffer.ptr };
        }
        for (launch_request.scalar_arguments, 0..) |scalar, scalar_index| {
            args[index][launch_request.buffers.len + scalar_index] = lowerScalarArgument(scalar);
        }
        graph_dispatches[index] = .{
            .kernel = loaded.kernel,
            .grid = launch_request.geometry.grid,
            .block = launch_request.geometry.threadgroup,
            .shared_mem_bytes = launch_request.geometry.dynamic_shared_memory_bytes,
            .args = args[index][0..count],
        };
    }
    var failed_index: ?usize = null;
    var graph = rt.recordGraph(graph_dispatches[0..request.dispatches.len], &failed_index) catch |err| {
        if (request.failure) |failure| failure.* = .{
            .stage = .record,
            .dispatch_index = failed_index,
            .dispatch_name = if (failed_index) |index| request.dispatches[index].name else null,
        };
        if (err == error.CudaNotSupported) return error.UnsupportedOperation;
        return mapLaunchError(err);
    };
    errdefer graph.deinit();
    const id = try state.putObject(.{ .sequence = graph });
    return .{ .id = id, .backend = .cuda };
}

fn submitSequence(ptr: *anyopaque, request: backend.contract.SequenceSubmitRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const object = state.objects.getPtr(request.sequence.id) orelse return error.InvalidArtifact;
    const graph = switch (object.*) {
        .sequence => |*value| value,
        else => return error.InvalidArtifact,
    };
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const stream = if (request.stream) |handle| try state.getStream(handle) else rt.defaultStream() catch |err| return mapStreamError(err);
    const signal = if (request.signal_event) |handle| try state.getEvent(handle) else null;
    for (request.wait_events) |handle| {
        _ = try state.getEvent(handle);
    }
    for (request.wait_events) |handle| {
        const event = try state.getEvent(handle);
        stream.waitEvent(event) catch |err| return mapStreamError(err);
    }
    graph.launch(stream) catch |err| return mapLaunchError(err);
    if (signal) |event| event.record(stream) catch |err| return mapEventError(err);
}

fn capabilitiesForRuntime(runtime: ?*const Runtime) backend.BackendCapabilities {
    const has_runtime = runtime != null;
    const device_name = if (runtime) |rt| rt.device.name() else "";
    const supports_tf32_tensor = if (runtime) |rt| rt.device.supportsTf32TensorOps() else false;
    const shared_memory_bytes = if (runtime) |rt| rt.device.dynamicSharedMemoryLimit() else 48 * 1024;
    return .{
        .identity = .{
            .backend = .cuda,
            .family = .nvidia_cuda,
            .name = if (device_name.len == 0) "cuda" else device_name,
        },
        .memory = .{
            .shared_memory_per_threadgroup_bytes = shared_memory_bytes,
            .constant_memory_bytes = 64 * 1024,
            .min_buffer_alignment = 256,
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
            .max_blocks = .{ 2_147_483_647, 65_535, 65_535 },
            .max_threads_per_dim = .{ 1024, 1024, 64 },
            .max_grid_per_dim = .{ 2_147_483_647, 65_535, 65_535 },
            .shared_memory_bytes = shared_memory_bytes,
        },
        .dtypes = backend.DTypeSet.init(&.{ .i1, .i8, .i16, .i32, .u8, .u16, .u32, .i64, .u64, .f32, .f16, .bf16, .f64, .key }),
        .layouts = .{
            .row_major = true,
            .compact_strides = true,
            .broadcast_strides = true,
            .tiled = true,
            .vectorized = true,
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
            .atomic_f32_add_shared = true,
            .tensor_cores = supports_tf32_tensor,
            .dynamic_shared_memory = true,
        },
        .artifact_formats = backend.ArtifactFormatSet.init(&.{.cuda_ptx}),
    };
}

fn queryCapabilities(ptr: *anyopaque) backend.BackendError!backend.BackendCapabilities {
    const state: *State = @ptrCast(@alignCast(ptr));
    return capabilitiesForRuntime(state.runtime.constPtr());
}

fn createArtifact(ptr: *anyopaque, request: backend.CompileRequest) backend.BackendError!backend.KernelArtifact {
    if (request.requested_format != .cuda_ptx) return error.UnsupportedOperation;
    const state: *State = @ptrCast(@alignCast(ptr));
    return switch (request.payload) {
        .text => |ptx| createPtxArtifact(state, request, ptx),
        .bytes => |ptx| createPtxArtifact(state, request, ptx),
        .none => error.UnsupportedOperation,
        .words_u32 => error.UnsupportedArtifactFormat,
    };
}

fn createPtxArtifact(
    state: *State,
    request: backend.CompileRequest,
    ptx: []const u8,
) backend.BackendError!backend.KernelArtifact {
    if (request.kernel_name.len == 0) return error.InvalidArtifact;
    if (ptx.len == 0) return error.InvalidArtifact;

    var artifact = backend.KernelArtifact.init(state.allocator, .{
        .backend = .cuda,
        .format = .cuda_ptx,
        .entry_name = request.kernel_name,
        .argument_count = request.argument_count,
        .scalar_argument_count = request.scalar_argument_count,
        .diagnostic_id = request.diagnostic_id,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    try artifact.setOwnedText(ptx);
    return artifact;
}

fn loadArtifact(ptr: *anyopaque, artifact: *const backend.KernelArtifact) backend.BackendError!backend.LoadedArtifact {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (artifact.backend != .cuda) return error.CapabilityMismatch;
    if (artifact.format != .cuda_ptx) return error.UnsupportedArtifactFormat;
    if (artifact.entry_name.len == 0) return error.InvalidArtifact;

    const ptx = switch (artifact.payload) {
        .text => |text| text,
        .bytes => |bytes| bytes,
        else => return error.InvalidArtifact,
    };
    if (ptx.len == 0) return error.InvalidArtifact;

    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const entry_name = state.allocator.dupeSentinel(u8, artifact.entry_name, 0) catch return error.OutOfMemory;
    errdefer state.allocator.free(entry_name);

    const module = rt.loadPtx(ptx) catch |err| return mapArtifactError(err);
    errdefer module.release();
    const kernel = module.getKernel(entry_name) catch |err| return mapArtifactError(err);

    const id = try state.putObject(.{ .loaded_artifact = .{
        .module = module,
        .kernel = kernel,
        .entry_name = entry_name,
        .argument_count = artifact.argument_count,
    } });
    return .{
        .id = id,
        .backend = .cuda,
        .format = .cuda_ptx,
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
        .backend = .cuda,
        .byte_size = request.byte_size,
        .ownership = .backend,
    };
}

fn createStream(ptr: *anyopaque, _: backend.StreamAllocation) backend.BackendError!backend.StreamHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;

    const stream = rt.createStream() catch |err| return mapStreamError(err);
    errdefer rt.destroyStream(stream);

    const id = try state.putObject(.{ .stream = stream });
    return .{
        .id = id,
        .backend = .cuda,
    };
}

fn createEvent(ptr: *anyopaque, _: backend.EventAllocation) backend.BackendError!backend.EventHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;

    const event = rt.createEvent() catch |err| return mapEventError(err);
    errdefer rt.destroyEvent(event);

    const id = try state.putObject(.{ .event = event });
    return .{
        .id = id,
        .backend = .cuda,
    };
}

fn writeBuffer(ptr: *anyopaque, request: backend.BufferWriteRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const buffer = try state.getBuffer(request.handle);
    if (request.bytes.len > buffer.bytes) return error.InvalidBuffer;
    buffer.copyFromHost(request.bytes) catch |err| return mapAllocationError(err);
}

fn fillBuffer(ptr: *anyopaque, request: backend.BufferFillRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const buffer = try state.getBuffer(request.handle);
    buffer.fillWords(request.pattern) catch |err| return mapAllocationError(err);
}

fn readBuffer(ptr: *anyopaque, request: backend.BufferReadRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const buffer = try state.getBuffer(request.handle);
    if (request.bytes.len < buffer.bytes) return error.ReadBufferDestinationTooSmall;
    buffer.copyToHost(request.bytes) catch |err| return mapAllocationError(err);
}

fn launch(ptr: *anyopaque, request: backend.LaunchRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (request.artifact.backend != .cuda or request.artifact.format != .cuda_ptx) {
        return error.CapabilityMismatch;
    }
    const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
    const loaded_handle = request.loaded_artifact orelse return error.InvalidArtifact;
    const loaded = try state.getLoaded(loaded_handle);
    const argument_count = request.buffers.len + request.scalar_arguments.len;
    if (argument_count != @as(usize, @intCast(loaded.argument_count))) {
        return error.LaunchArgumentMismatch;
    }
    if (argument_count > runtime_mod.max_kernel_args) return error.LaunchArgumentMismatch;

    var args: [runtime_mod.max_kernel_args]runtime_mod.KernelArg = undefined;
    var arg_count: usize = 0;
    for (request.buffers) |binding| {
        if (binding.handle.backend != .cuda or binding.ownership != .backend) return error.InvalidBuffer;
        const buffer = try state.getBuffer(binding.handle);
        if (binding.byte_size > buffer.bytes or binding.handle.byte_size != buffer.bytes) {
            return error.InvalidBuffer;
        }
        args[arg_count] = .{ .device_ptr = buffer.ptr };
        arg_count += 1;
    }
    for (request.scalar_arguments) |arg| {
        args[arg_count] = lowerScalarArgument(arg);
        arg_count += 1;
    }

    const stream = if (request.stream) |stream_handle|
        try state.getStream(stream_handle)
    else
        rt.defaultStream() catch |err| return mapStreamError(err);
    const signal_event = if (request.signal_event) |event_handle|
        try state.getEvent(event_handle)
    else
        null;
    for (request.wait_events) |event_handle| {
        _ = try state.getEvent(event_handle);
    }

    for (request.wait_events) |event_handle| {
        const event = try state.getEvent(event_handle);
        stream.waitEvent(event) catch |err| return mapStreamError(err);
    }

    loaded.kernel.launchOnStream(
        stream,
        request.geometry.grid,
        request.geometry.threadgroup,
        request.geometry.dynamic_shared_memory_bytes,
        args[0..arg_count],
    ) catch |err| return mapLaunchError(err);

    if (signal_event) |event| {
        event.record(stream) catch |err| return mapEventError(err);
    }
}

fn lowerScalarArgument(arg: gpu_abi.ScalarArgument) runtime_mod.KernelArg {
    return switch (arg) {
        .i32 => |value| .{ .i32 = value },
        .u32 => |value| .{ .u32 = value },
        .i64 => |value| .{ .i64 = value },
        .u64 => |value| .{ .u64 = value },
        .f32 => |value| .{ .f32 = value },
        .f64 => |value| .{ .f64 = value },
    };
}

fn synchronize(ptr: *anyopaque, request: backend.SyncRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    switch (request.scope) {
        .default_stream => {
            const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
            const stream = rt.defaultStream() catch |err| return mapStreamError(err);
            stream.synchronize() catch |err| return mapStreamError(err);
        },
        .device => {
            const rt = state.runtime.ptr() orelse return error.RuntimeUnavailable;
            rt.synchronize() catch |err| return mapSyncError(err);
        },
        .stream => {
            const stream = try state.getStream(request.stream.?);
            stream.synchronize() catch |err| return mapStreamError(err);
        },
        .event => {
            const event = try state.getEvent(request.event.?);
            event.synchronize() catch |err| return mapEventError(err);
        },
    }
}

fn queryEvent(ptr: *anyopaque, request: backend.EventQueryRequest) backend.BackendError!bool {
    const state: *State = @ptrCast(@alignCast(ptr));
    const event = try state.getEvent(request.event);
    return event.query() catch |err| return mapEventError(err);
}

fn recordEvent(ptr: *anyopaque, request: backend.EventRecordRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const stream = try state.getStream(request.stream);
    const event = try state.getEvent(request.event);
    event.record(stream) catch |err| return mapEventError(err);
}

fn elapsedEventNs(ptr: *anyopaque, request: backend.EventElapsedRequest) backend.BackendError!u64 {
    const state: *State = @ptrCast(@alignCast(ptr));
    const start = try state.getEvent(request.start);
    const end = try state.getEvent(request.end);
    const elapsed_ms = end.elapsedMs(start) catch |err| return mapEventError(err);
    if (!std.math.isFinite(elapsed_ms) or elapsed_ms < 0) return error.RuntimeUnavailable;
    const elapsed_ns = @as(f64, elapsed_ms) * 1_000_000.0;
    if (elapsed_ns > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.RuntimeUnavailable;
    return @intFromFloat(@round(elapsed_ns));
}

fn destroyObject(ptr: *anyopaque, id: BackendObjectId) void {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (state.objects.fetchRemove(id)) |entry| {
        var object = entry.value;
        deinitObject(state.allocator, &object);
    }
}

fn deinitHandle(ptr: *anyopaque, allocator: Allocator) void {
    _ = allocator;
    const state: *State = @ptrCast(@alignCast(ptr));
    state.deinit();
}

fn deinitObject(allocator: Allocator, object: *Object) void {
    switch (object.*) {
        .loaded_artifact => |*loaded| {
            loaded.module.release();
            allocator.free(loaded.entry_name);
        },
        .sequence => |*graph| graph.deinit(),
        .buffer => |*buffer| buffer.deinit(),
        .stream => |stream| stream.runtime.destroyStream(stream),
        .event => |event| event.runtime.destroyEvent(event),
    }
    object.* = undefined;
}

fn mapRuntimeInitError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.CudaOutOfMemory => error.OutOfMemory,
        error.CudaDriverNotFound,
        error.CudaSymbolMissing,
        error.CudaNotInitialized,
        error.CudaDeinitialized,
        error.CudaNoDevice,
        error.CudaInvalidDevice,
        error.CudaInvalidContext,
        error.CudaNotSupported,
        error.CudaSharedObjectSymbolNotFound,
        error.CudaSharedObjectInitFailed,
        => error.RuntimeUnavailable,
        else => error.RuntimeUnavailable,
    };
}

fn mapArtifactError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.CudaOutOfMemory => error.OutOfMemory,
        error.CudaInvalidPtx,
        error.CudaUnsupportedPtxVersion,
        error.CudaJitCompilerNotFound,
        error.CudaInvalidImage,
        error.CudaNoBinaryForGpu,
        error.CudaInvalidValue,
        error.CudaInvalidHandle,
        => error.InvalidArtifact,
        error.CudaDriverNotFound,
        error.CudaSymbolMissing,
        error.CudaNotInitialized,
        error.CudaDeinitialized,
        error.CudaNoDevice,
        error.CudaInvalidDevice,
        error.CudaInvalidContext,
        error.CudaNotSupported,
        error.CudaSharedObjectSymbolNotFound,
        error.CudaSharedObjectInitFailed,
        => error.RuntimeUnavailable,
        error.CudaIllegalAddress => error.DeviceLost,
        else => error.LaunchFailed,
    };
}

fn mapAllocationError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.CudaOutOfMemory => error.OutOfMemory,
        error.CudaInvalidValue, error.CudaInvalidHandle => error.InvalidBuffer,
        error.CudaIllegalAddress => error.DeviceLost,
        error.CudaDriverNotFound,
        error.CudaSymbolMissing,
        error.CudaNotInitialized,
        error.CudaDeinitialized,
        error.CudaNoDevice,
        error.CudaInvalidDevice,
        error.CudaInvalidContext,
        => error.RuntimeUnavailable,
        else => error.LaunchFailed,
    };
}

fn mapLaunchError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.CudaOutOfMemory => error.OutOfMemory,
        error.CudaInvalidValue, error.CudaLaunchOutOfResources => error.LaunchArgumentMismatch,
        error.CudaIllegalAddress => error.DeviceLost,
        error.CudaLaunchFailed,
        error.CudaLaunchTimeout,
        error.CudaLaunchIncompatibleTexturing,
        error.CudaStreamPoisoned,
        => error.LaunchFailed,
        error.CudaDriverNotFound,
        error.CudaSymbolMissing,
        error.CudaNotInitialized,
        error.CudaDeinitialized,
        error.CudaNoDevice,
        error.CudaInvalidDevice,
        error.CudaInvalidContext,
        => error.RuntimeUnavailable,
        else => error.LaunchFailed,
    };
}

fn mapStreamError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.CudaOutOfMemory => error.OutOfMemory,
        error.CudaInvalidValue, error.CudaInvalidHandle => error.InvalidStream,
        error.CudaIllegalAddress => error.DeviceLost,
        error.CudaLaunchFailed,
        error.CudaLaunchTimeout,
        error.CudaLaunchIncompatibleTexturing,
        error.CudaStreamPoisoned,
        => error.LaunchFailed,
        error.CudaDriverNotFound,
        error.CudaSymbolMissing,
        error.CudaNotInitialized,
        error.CudaDeinitialized,
        error.CudaNoDevice,
        error.CudaInvalidDevice,
        error.CudaInvalidContext,
        => error.RuntimeUnavailable,
        else => error.RuntimeUnavailable,
    };
}

fn mapEventError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.CudaOutOfMemory => error.OutOfMemory,
        error.CudaInvalidValue, error.CudaInvalidHandle => error.InvalidEvent,
        error.CudaIllegalAddress => error.DeviceLost,
        error.CudaLaunchFailed,
        error.CudaLaunchTimeout,
        error.CudaLaunchIncompatibleTexturing,
        error.CudaStreamPoisoned,
        => error.LaunchFailed,
        error.CudaDriverNotFound,
        error.CudaSymbolMissing,
        error.CudaNotInitialized,
        error.CudaDeinitialized,
        error.CudaNoDevice,
        error.CudaInvalidDevice,
        error.CudaInvalidContext,
        => error.RuntimeUnavailable,
        else => error.RuntimeUnavailable,
    };
}

fn mapSyncError(err: runtime_mod.Error) backend.BackendError {
    return switch (err) {
        error.CudaOutOfMemory => error.OutOfMemory,
        error.CudaIllegalAddress => error.DeviceLost,
        error.CudaLaunchFailed,
        error.CudaLaunchTimeout,
        error.CudaLaunchIncompatibleTexturing,
        error.CudaStreamPoisoned,
        => error.LaunchFailed,
        error.CudaDriverNotFound,
        error.CudaSymbolMissing,
        error.CudaNotInitialized,
        error.CudaDeinitialized,
        error.CudaNoDevice,
        error.CudaInvalidDevice,
        error.CudaInvalidContext,
        => error.RuntimeUnavailable,
        else => error.RuntimeUnavailable,
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
    .fill_buffer = fillBuffer,
    .read_buffer = readBuffer,
    .launch = launch,
    .record_sequence = recordSequence,
    .submit_sequence = submitSequence,
    .synchronize = synchronize,
    .query_event = queryEvent,
    .record_event = recordEvent,
    .elapsed_event_ns = elapsedEventNs,
    .destroy_object = destroyObject,
    .deinit = deinitHandle,
};

pub const testing = if (builtin.is_test) struct {
    pub const FakeSnapshot: type = runtime_mod.testing.FakeSnapshot;

    pub fn resetFakeRuntime() void {
        runtime_mod.testing.resetFake();
    }

    pub fn fakeRuntime(allocator: Allocator) Runtime {
        return runtime_mod.testing.fakeRuntime(allocator);
    }

    pub fn snapshot() FakeSnapshot {
        return runtime_mod.testing.snapshot();
    }

    pub fn setFakeEventElapsedMs(ms: f32) void {
        runtime_mod.testing.setFakeEventElapsedMs(ms);
    }

    pub fn stateWithRuntime(allocator: Allocator, runtime: *Runtime) State {
        return State.initWithRuntime(allocator, runtime);
    }
} else struct {};

test "cuda contract reports capabilities without a live runtime" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    const handle = state.handle();

    const caps = try handle.queryCapabilities();
    try std.testing.expectEqual(backend.BackendKind.cuda, caps.identity.backend);
    try std.testing.expectEqual(backend.DeviceFamily.nvidia_cuda, caps.identity.family);
    try std.testing.expect(caps.supportsDType(.i1));
    try std.testing.expect(caps.supportsDType(.f32));
    try std.testing.expect(caps.supportsDType(.i32));
    try std.testing.expect(caps.supportsDType(.f16));
    try std.testing.expect(caps.supportsDType(.bf16));
    try std.testing.expect(caps.supportsDType(.u32));
    try std.testing.expect(caps.supportsDType(.u64));
    try std.testing.expect(caps.supportsDType(.f64));
    try std.testing.expect(caps.supportsDType(.i64));
    try std.testing.expect(caps.features.atomic_i32);
    try std.testing.expect(caps.features.atomic_u32);
    try std.testing.expect(caps.features.atomic_index);
    try std.testing.expect(caps.features.atomic_f32_add_device);
    try std.testing.expect(caps.features.atomic_f32_add_shared);
    try std.testing.expect(caps.features.dynamic_shared_memory);
    try std.testing.expect(!caps.features.tensor_cores);
    try std.testing.expect(caps.supportsArtifactFormat(.cuda_ptx));
    try std.testing.expect(!caps.runtime.driver_loaded);
    try std.testing.expect(caps.runtime.streams);
}

test "cuda contract reports tensor cores for fake ampere runtime" {
    var runtime = testing.fakeRuntime(std.testing.allocator);
    defer runtime.module_cache.deinit(&runtime);

    var state = testing.stateWithRuntime(std.testing.allocator, &runtime);
    defer state.deinit();

    const caps = try state.handle().queryCapabilities();
    try std.testing.expectEqualStrings("fake cuda", caps.identity.name);
    try std.testing.expect(caps.features.tensor_cores);
    try std.testing.expectEqual(@as(u32, 100 * 1024), caps.memory.shared_memory_per_threadgroup_bytes);
    try std.testing.expectEqual(@as(u32, 100 * 1024), caps.threadgroup.shared_memory_bytes);
}

test "cuda contract records unsupported and unavailable phases" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    const handle = state.handle();

    try std.testing.expectError(error.UnsupportedOperation, handle.createArtifact(.{
        .kernel_name = "add",
        .requested_format = .cuda_ptx,
    }));
    try std.testing.expectError(error.RuntimeUnavailable, handle.allocateBuffer(.{
        .byte_size = 16,
        .alignment = 256,
    }));
    try std.testing.expectError(error.RuntimeUnavailable, handle.createStream(.{}));
    try std.testing.expectError(error.RuntimeUnavailable, handle.createEvent(.{}));
    try std.testing.expectError(error.RuntimeUnavailable, handle.synchronize(.{
        .scope = .device,
    }));
    try std.testing.expectError(error.InvalidEvent, handle.queryEvent(.{
        .event = .{
            .id = 1,
            .backend = .cuda,
        },
    }));
    try std.testing.expectError(error.InvalidEvent, handle.elapsedEventNs(.{
        .start = .{
            .id = 1,
            .backend = .cuda,
        },
        .end = .{
            .id = 2,
            .backend = .cuda,
        },
    }));

    var artifact = try backend.KernelArtifact.init(std.testing.allocator, .{
        .backend = .cuda,
        .format = .cuda_ptx,
        .entry_name = "main",
        .argument_count = 0,
    });
    defer artifact.deinit();
    artifact.setBorrowedText("// ptx");

    try std.testing.expectError(error.RuntimeUnavailable, handle.loadArtifact(&artifact));
}

test "cuda contract lowers event elapsed time to nanoseconds" {
    testing.resetFakeRuntime();
    testing.setFakeEventElapsedMs(2.5);
    var runtime = testing.fakeRuntime(std.testing.allocator);
    defer runtime.live_streams.deinit(runtime.allocator);
    var state = testing.stateWithRuntime(std.testing.allocator, &runtime);
    defer state.deinit();
    const handle = state.handle();

    const start = try handle.createEvent(.{});
    const end = try handle.createEvent(.{});

    try std.testing.expectEqual(@as(u64, 2_500_000), try handle.elapsedEventNs(.{
        .start = start,
        .end = end,
    }));
    try std.testing.expectEqual(@as(u32, 1), testing.snapshot().event_elapsed_calls);
}

test "cuda contract creates PTX artifact before runtime access" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact = try handle.createArtifact(.{
        .kernel_name = "accy_choir_contract_add",
        .requested_format = .cuda_ptx,
        .argument_count = 4,
        .required_dtypes = backend.DTypeSet.init(&.{.f32}),
        .diagnostic_id = "choir/kernel/0",
        .payload = .{ .text = ".version 7.0\n.visible .entry accy_choir_contract_add() { ret; }\n" },
    });
    defer artifact.deinit();

    try std.testing.expectEqual(backend.BackendKind.cuda, artifact.backend);
    try std.testing.expectEqual(backend.ArtifactFormat.cuda_ptx, artifact.format);
    try std.testing.expectEqualStrings("accy_choir_contract_add", artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 4), artifact.argument_count);
    try std.testing.expectEqualStrings("choir/kernel/0", artifact.diagnostic_id.?);
    try std.testing.expect(std.mem.indexOf(u8, artifact.payload.text, ".visible .entry accy_choir_contract_add") != null);
    try std.testing.expectError(error.RuntimeUnavailable, handle.loadArtifact(&artifact));
}

fn initRuntimeOrSkip(
    allocator: Allocator,
    device_ordinal: i32,
) (driver_mod.Error || error{SkipZigTest})!Runtime {
    if (!build_options.gpu_tests) return error.SkipZigTest;
    if (!driver_mod.platformSupported()) return error.SkipZigTest;

    return Runtime.init(allocator, device_ordinal) catch |err| switch (err) {
        error.CudaDriverNotFound,
        error.CudaNoDevice,
        error.CudaInvalidDevice,
        => return error.SkipZigTest,
        else => return err,
    };
}

test "cuda contract validates artifact format before runtime access" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact = try backend.KernelArtifact.init(std.testing.allocator, .{
        .backend = .cuda,
        .format = .cuda_cubin,
        .entry_name = "main",
        .argument_count = 0,
    });
    defer artifact.deinit();
    try artifact.setOwnedBytes(&.{ 0xca, 0xfe });

    try std.testing.expectError(error.UnsupportedArtifactFormat, handle.loadArtifact(&artifact));
}

test "cuda destroyObject releases loaded artifact modules after final shared reference" {
    runtime_mod.testing.resetFake();
    var rt = runtime_mod.testing.fakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    var state = State.initWithRuntime(std.testing.allocator, &rt);
    defer state.deinit();
    const handle = state.handle();

    var artifact = try backend.KernelArtifact.init(std.testing.allocator, .{
        .backend = .cuda,
        .format = .cuda_ptx,
        .entry_name = "shared",
        .argument_count = 0,
    });
    defer artifact.deinit();
    artifact.setBorrowedText(".version 6.0\n.visible .entry shared() { ret; }\n");

    const first = try handle.loadArtifact(&artifact);
    const second = try handle.loadArtifact(&artifact);
    var snapshot = runtime_mod.testing.snapshot();
    try std.testing.expectEqual(@as(u32, 1), snapshot.module_loads);
    try std.testing.expectEqual(@as(u32, 1), snapshot.module_load_data_ex_calls);
    try std.testing.expectEqual(@as(u32, 0), snapshot.module_unloads);

    handle.destroyObject(first.id);
    snapshot = runtime_mod.testing.snapshot();
    try std.testing.expectEqual(@as(u32, 0), snapshot.module_unloads);

    handle.destroyObject(second.id);
    snapshot = runtime_mod.testing.snapshot();
    try std.testing.expectEqual(@as(u32, 1), snapshot.module_unloads);
}

test "cuda destroyObject releases device buffers before state deinit" {
    runtime_mod.testing.resetFake();
    var rt = runtime_mod.testing.fakeRuntime(std.testing.allocator);
    defer rt.module_cache.deinit(&rt);

    var state = State.initWithRuntime(std.testing.allocator, &rt);
    defer state.deinit();
    const handle = state.handle();

    const buffer = try handle.allocateBuffer(.{
        .byte_size = 256,
        .alignment = 256,
        .dtype = .f32,
        .element_count = 64,
    });
    var snapshot = runtime_mod.testing.snapshot();
    try std.testing.expectEqual(@as(u32, 1), snapshot.mem_allocs);
    try std.testing.expectEqual(@as(u32, 0), snapshot.mem_frees);

    handle.destroyObject(buffer.id);
    snapshot = runtime_mod.testing.snapshot();
    try std.testing.expectEqual(@as(u32, 1), snapshot.mem_frees);

    handle.destroyObject(buffer.id);
    snapshot = runtime_mod.testing.snapshot();
    try std.testing.expectEqual(@as(u32, 1), snapshot.mem_frees);
}

test "cuda contract live stream event launch can be queried" {
    var rt = try initRuntimeOrSkip(std.testing.allocator, 0);
    defer rt.deinit();

    var state = State.initWithRuntime(std.testing.allocator, &rt);
    defer state.deinit();
    const handle = state.handle();

    const element_count: usize = 256;
    var host_in: [element_count]f32 = undefined;
    for (&host_in, 0..) |*x, i| x.* = @as(f32, @floatFromInt(i)) * 0.125;

    var host_out: [element_count]f32 = @as([element_count]f32, @splat(0));

    var artifact = try backend.KernelArtifact.init(std.testing.allocator, .{
        .backend = .cuda,
        .format = .cuda_ptx,
        .entry_name = "add_one",
        .argument_count = 1,
    });
    defer artifact.deinit();
    artifact.setBorrowedText(
        \\.version 6.0
        \\.target sm_52
        \\.address_size 64
        \\
        \\.visible .entry add_one(
        \\    .param .u64 in_ptr
        \\)
        \\{
        \\    .reg .b32    %r<4>;
        \\    .reg .f32    %f<3>;
        \\    .reg .b64    %rd<5>;
        \\
        \\    ld.param.u64       %rd1, [in_ptr];
        \\
        \\    mov.u32            %r1, %ntid.x;
        \\    mov.u32            %r2, %ctaid.x;
        \\    mov.u32            %r3, %tid.x;
        \\    mad.lo.s32         %r1, %r1, %r2, %r3;
        \\
        \\    cvta.to.global.u64 %rd2, %rd1;
        \\    mul.wide.s32       %rd3, %r1, 4;
        \\    add.s64            %rd4, %rd2, %rd3;
        \\
        \\    ld.global.f32      %f1, [%rd4];
        \\    add.f32            %f2, %f1, 0f3F800000;
        \\    st.global.f32      [%rd4], %f2;
        \\
        \\    ret;
        \\}
    );

    const loaded = try handle.loadArtifact(&artifact);
    const buffer = try handle.allocateBuffer(.{
        .byte_size = element_count * @sizeOf(f32),
        .alignment = 256,
        .dtype = .f32,
        .element_count = element_count,
    });
    try handle.writeBuffer(.{
        .handle = buffer,
        .bytes = std.mem.sliceAsBytes(host_in[0..]),
    });

    const stream = try handle.createStream(.{});
    const event = try handle.createEvent(.{});
    const binding = backend.BufferBinding{
        .handle = buffer,
        .access = .read_write,
        .ownership = buffer.ownership,
        .byte_size = buffer.byte_size,
    };

    try handle.launch(.{
        .artifact = &artifact,
        .loaded_artifact = loaded,
        .buffers = &.{binding},
        .geometry = .{
            .grid = .{ 1, 1, 1 },
            .threadgroup = .{ @intCast(element_count), 1, 1 },
        },
        .stream = stream,
        .signal_event = event,
    });

    _ = try handle.queryEvent(.{ .event = event });
    try handle.synchronize(.{
        .scope = .event,
        .event = event,
    });
    try std.testing.expect(try handle.queryEvent(.{ .event = event }));

    try handle.readBuffer(.{
        .handle = buffer,
        .bytes = std.mem.sliceAsBytes(host_out[0..]),
    });

    for (host_in, host_out) |in, out| {
        try std.testing.expectApproxEqAbs(in + 1.0, out, 1e-6);
    }
}

const InvalidWaitProbe = struct {
    var queued_waits: usize = 0;

    fn wait(
        _: runtime_mod.CUstream,
        _: runtime_mod.CUevent,
        _: c_uint,
    ) callconv(.c) driver_mod.CUresult {
        queued_waits += 1;
        return .success;
    }
};

fn expectInvalidSequenceEventsLeaveStreamUntouched(
    rt: *Runtime,
    handle: backend.BackendHandle,
    sequence: backend.contract.SequenceHandle,
    stream: backend.StreamHandle,
    complete: backend.EventHandle,
) !void {
    const driver_wait = rt.driver.cuStreamWaitEvent;
    defer rt.driver.cuStreamWaitEvent = driver_wait;
    rt.driver.cuStreamWaitEvent = InvalidWaitProbe.wait;
    InvalidWaitProbe.queued_waits = 0;
    const invalid_event = backend.EventHandle{
        .id = std.math.maxInt(BackendObjectId),
        .backend = .cuda,
    };
    try std.testing.expectError(error.InvalidEvent, handle.submitSequence(.{
        .sequence = sequence,
        .stream = stream,
        .wait_events = &.{ complete, invalid_event },
    }));
    try std.testing.expectEqual(@as(usize, 0), InvalidWaitProbe.queued_waits);
    try std.testing.expectError(error.InvalidEvent, handle.submitSequence(.{
        .sequence = sequence,
        .stream = stream,
        .wait_events = &.{complete},
        .signal_event = invalid_event,
    }));
    try std.testing.expectEqual(@as(usize, 0), InvalidWaitProbe.queued_waits);
}

fn expectSequenceReplayValues(
    handle: backend.BackendHandle,
    counter: backend.BufferHandle,
    first_output: backend.BufferHandle,
    second_output: backend.BufferHandle,
) !void {
    var first_readback: [16]u32 = undefined;
    var second_readback: [16]u32 = undefined;
    try handle.readBuffer(.{ .handle = first_output, .bytes = std.mem.sliceAsBytes(&first_readback) });
    try handle.readBuffer(.{ .handle = second_output, .bytes = std.mem.sliceAsBytes(&second_readback) });
    for (0..8) |index| {
        try std.testing.expectEqual(@as(u32, @intCast(index * 2)), first_readback[index * 2]);
        try std.testing.expectEqual(@as(u32, @intCast(index * 2 + 1)), second_readback[index * 2 + 1]);
    }
    var final_counter: u32 = 0;
    try handle.readBuffer(.{ .handle = counter, .bytes = std.mem.asBytes(&final_counter) });
    try std.testing.expectEqual(@as(u32, 16), final_counter);
}

test "cuda sequence replays preserve intra-sequence and cross-replay writes" {
    if (!build_options.gpu_tests) return error.SkipZigTest;
    var driver_probe = @import("sys").dynamic.openCudaDriver() catch |err| {
        std.log.err("CUDA loader: {s}", .{@errorName(err)});
        return err;
    };
    driver_probe.close();
    var rt = try Runtime.init(std.testing.allocator, 0);
    defer rt.deinit();
    var state = State.initWithRuntime(std.testing.allocator, &rt);
    defer state.deinit();
    const handle = state.handle();
    const ptx = @import("runtime/cuda/fixture/counter.zig").ptx;
    var artifact = try backend.KernelArtifact.init(std.testing.allocator, .{
        .backend = .cuda,
        .format = .cuda_ptx,
        .entry_name = "sequence_counter",
        .argument_count = 2,
    });
    defer artifact.deinit();
    artifact.setBorrowedText(ptx);
    const loaded = try handle.loadArtifact(&artifact);
    defer handle.destroyObject(loaded.id);
    const counter = try handle.allocateBuffer(.{ .byte_size = 4, .alignment = 256 });
    defer handle.destroyObject(counter.id);
    const first_output = try handle.allocateBuffer(.{ .byte_size = 16 * 4, .alignment = 256 });
    defer handle.destroyObject(first_output.id);
    const second_output = try handle.allocateBuffer(.{ .byte_size = 16 * 4, .alignment = 256 });
    defer handle.destroyObject(second_output.id);
    const stream = try handle.createStream(.{});
    defer handle.destroyObject(stream.id);
    var initial: u32 = 0;
    try handle.writeBuffer(.{ .handle = counter, .bytes = std.mem.asBytes(&initial) });
    var first_bindings = [_]backend.BufferBinding{
        .{ .handle = counter, .access = .read_write, .ownership = .backend, .byte_size = 4 },
        .{ .handle = first_output, .access = .write_only, .ownership = .backend, .byte_size = 16 * 4 },
    };
    const second_bindings = [_]backend.BufferBinding{
        .{ .handle = counter, .access = .read_write, .ownership = .backend, .byte_size = 4 },
        .{ .handle = second_output, .access = .write_only, .ownership = .backend, .byte_size = 16 * 4 },
    };
    const first = backend.contract.SequenceDispatch{
        .name = "first increment",
        .launch = .{
            .artifact = &artifact,
            .loaded_artifact = loaded,
            .buffers = &first_bindings,
            .geometry = .{ .grid = .{ 1, 1, 1 }, .threadgroup = .{ 1, 1, 1 } },
        },
    };
    var second = first;
    second.name = "second increment";
    second.launch.buffers = &second_bindings;
    const sequence = try handle.recordSequence(.{ .dispatches = &.{ first, second } });
    errdefer handle.destroyObject(sequence.id);
    first_bindings[0].handle = first_output;
    first_bindings[0].byte_size = first_output.byte_size;
    const complete = try handle.createEvent(.{});
    defer handle.destroyObject(complete.id);
    try expectInvalidSequenceEventsLeaveStreamUntouched(&rt, handle, sequence, stream, complete);
    for (0..7) |_| try handle.submitSequence(.{ .sequence = sequence, .stream = stream });
    try handle.submitSequence(.{ .sequence = sequence, .stream = stream, .signal_event = complete });
    handle.destroyObject(sequence.id);
    try std.testing.expect(try handle.queryEvent(.{ .event = complete }));
    try expectSequenceReplayValues(handle, counter, first_output, second_output);
}
