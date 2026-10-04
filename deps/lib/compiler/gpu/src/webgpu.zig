const std = @import("std");
const builtin = @import("builtin");

const backend = @import("root.zig");
const host = @import("host.zig");

const Allocator = std.mem.Allocator;
const browserish = builtin.target.cpu.arch.isWasm() and builtin.target.os.tag == .freestanding;

pub const State = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) State {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(_: *State) void {}

    pub fn handle(self: *State) backend.BackendHandle {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .kind = .webgpu,
        };
    }
};

pub fn staticCapabilities() backend.BackendCapabilities {
    return .{
        .identity = .{
            .backend = .webgpu,
            .family = .webgpu,
            .name = "webgpu",
        },
        .memory = .{
            .shared_memory_per_threadgroup_bytes = 16 * 1024,
            .min_buffer_alignment = 4,
        },
        .threadgroup = .{
            .max_threads = 256,
            .max_blocks = .{ 65_535, 65_535, 65_535 },
            .max_threads_per_dim = .{ 256, 256, 64 },
            .max_grid_per_dim = .{ 65_535, 65_535, 65_535 },
            .shared_memory_bytes = 16 * 1024,
        },
        .dtypes = backend.DTypeSet.init(&.{ .i1, .i32, .u32, .f32, .key }),
        .layouts = .{
            .row_major = true,
            .compact_strides = true,
            .broadcast_strides = true,
            .tiled = true,
            .opaque_backend_layouts = true,
        },
        .runtime = .{
            .driver_loaded = browserish,
            .device_context = browserish,
        },
        .artifact_formats = backend.ArtifactFormatSet.init(&.{.webgpu_wgsl}),
    };
}

fn queryCapabilities(_: *anyopaque) backend.BackendError!backend.BackendCapabilities {
    return staticCapabilities();
}

fn createArtifact(ptr: *anyopaque, request: backend.CompileRequest) backend.BackendError!backend.KernelArtifact {
    if (request.requested_format != .webgpu_wgsl) return error.UnsupportedOperation;
    const state: *State = @ptrCast(@alignCast(ptr));
    return switch (request.payload) {
        .text => |source| createWgslArtifact(state, request, source),
        .bytes => |source| createWgslArtifact(state, request, source),
        .none => error.UnsupportedOperation,
        .words_u32 => error.UnsupportedArtifactFormat,
    };
}

fn createWgslArtifact(
    state: *State,
    request: backend.CompileRequest,
    source: []const u8,
) backend.BackendError!backend.KernelArtifact {
    if (request.kernel_name.len == 0) return error.InvalidArtifact;
    if (source.len == 0) return error.InvalidArtifact;

    var artifact = backend.KernelArtifact.init(state.allocator, .{
        .backend = .webgpu,
        .format = .webgpu_wgsl,
        .entry_name = request.kernel_name,
        .argument_count = request.argument_count,
        .scalar_argument_count = request.scalar_argument_count,
        .diagnostic_id = request.diagnostic_id,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    try artifact.setOwnedText(source);
    return artifact;
}

fn loadArtifact(_: *anyopaque, artifact: *const backend.KernelArtifact) backend.BackendError!backend.LoadedArtifact {
    if (artifact.backend != .webgpu or artifact.format != .webgpu_wgsl) return error.InvalidArtifact;
    if (artifact.entry_name.len == 0) return error.InvalidArtifact;
    const source = switch (artifact.payload) {
        .text => |payload| payload,
        else => return error.InvalidArtifact,
    };
    if (source.len == 0) return error.InvalidArtifact;
    if (comptime !browserish) return error.RuntimeUnavailable;

    const id = Host.artifactLoad(
        host.pointer(source),
        source.len,
        host.pointer(artifact.entry_name),
        artifact.entry_name.len,
        artifact.argument_count,
    );
    if (id == 0) return error.RuntimeUnavailable;
    return .{
        .id = id,
        .backend = .webgpu,
        .format = .webgpu_wgsl,
    };
}

fn allocateBuffer(_: *anyopaque, request: backend.BufferAllocation) backend.BackendError!backend.BufferHandle {
    if (comptime !browserish) return error.RuntimeUnavailable;
    const id = Host.bufferAlloc(request.byte_size, request.alignment);
    if (id == 0) return error.OutOfMemory;
    return .{
        .id = id,
        .backend = .webgpu,
        .byte_size = request.byte_size,
        .ownership = .backend,
    };
}

fn writeBuffer(_: *anyopaque, request: backend.BufferWriteRequest) backend.BackendError!void {
    if (comptime !browserish) return error.RuntimeUnavailable;
    try host.status(Host.bufferWrite(request.handle.id, host.pointer(request.bytes), request.bytes.len));
}

fn readBuffer(_: *anyopaque, request: backend.BufferReadRequest) backend.BackendError!void {
    if (comptime !browserish) return error.RuntimeUnavailable;
    try host.status(Host.bufferRead(request.handle.id, host.pointer(request.bytes), request.bytes.len));
}

fn launch(ptr: *anyopaque, request: backend.LaunchRequest) backend.BackendError!void {
    if (comptime !browserish) return error.RuntimeUnavailable;
    const state: *State = @ptrCast(@alignCast(ptr));
    const loaded = request.loaded_artifact orelse return error.InvalidArtifact;
    if (loaded.backend != .webgpu or loaded.format != .webgpu_wgsl) return error.InvalidArtifact;

    const bindings = state.allocator.alloc(host.Binding, request.buffers.len) catch return error.OutOfMemory;
    defer state.allocator.free(bindings);
    for (request.buffers, bindings) |source, *dest| dest.* = try host.binding(source);

    const scalars = state.allocator.alloc(host.Scalar, request.scalar_arguments.len) catch return error.OutOfMemory;
    defer state.allocator.free(scalars);
    for (request.scalar_arguments, scalars) |source, *dest| dest.* = host.scalar(source);

    try host.status(Host.launch(
        loaded.id,
        host.pointer(bindings),
        bindings.len,
        host.pointer(scalars),
        scalars.len,
        request.geometry.grid[0],
        request.geometry.grid[1],
        request.geometry.grid[2],
        request.geometry.threadgroup[0],
        request.geometry.threadgroup[1],
        request.geometry.threadgroup[2],
        request.geometry.dynamic_shared_memory_bytes,
    ));
}

fn synchronize(_: *anyopaque, _: backend.SyncRequest) backend.BackendError!void {}

fn destroyObject(_: *anyopaque, id: backend.BackendObjectId) void {
    if (comptime browserish) Host.objectDestroy(id);
}

const BrowserHost = struct {
    extern "accy" fn accy_webgpu_artifact_load(
        source_ptr: usize,
        source_len: usize,
        entry_ptr: usize,
        entry_len: usize,
        argument_count: u32,
    ) callconv(.c) u64;

    extern "accy" fn accy_webgpu_buffer_alloc(byte_size: usize, alignment: u32) callconv(.c) u64;
    extern "accy" fn accy_webgpu_buffer_write(id: u64, bytes_ptr: usize, byte_count: usize) callconv(.c) i32;
    extern "accy" fn accy_webgpu_buffer_read(id: u64, bytes_ptr: usize, byte_count: usize) callconv(.c) i32;
    extern "accy" fn accy_webgpu_object_destroy(id: u64) callconv(.c) void;

    extern "accy" fn accy_webgpu_launch(
        artifact_id: u64,
        bindings_ptr: usize,
        binding_count: usize,
        scalars_ptr: usize,
        scalar_count: usize,
        grid_x: u32,
        grid_y: u32,
        grid_z: u32,
        threadgroup_x: u32,
        threadgroup_y: u32,
        threadgroup_z: u32,
        dynamic_shared_memory_bytes: u32,
    ) callconv(.c) i32;

    fn artifactLoad(source_ptr: usize, source_len: usize, entry_ptr: usize, entry_len: usize, argument_count: u32) u64 {
        return accy_webgpu_artifact_load(source_ptr, source_len, entry_ptr, entry_len, argument_count);
    }

    fn bufferAlloc(byte_size: usize, alignment: u32) u64 {
        return accy_webgpu_buffer_alloc(byte_size, alignment);
    }

    fn bufferWrite(id: u64, bytes_ptr: usize, byte_count: usize) i32 {
        return accy_webgpu_buffer_write(id, bytes_ptr, byte_count);
    }

    fn bufferRead(id: u64, bytes_ptr: usize, byte_count: usize) i32 {
        return accy_webgpu_buffer_read(id, bytes_ptr, byte_count);
    }

    fn launch(
        artifact_id: u64,
        bindings_ptr: usize,
        binding_count: usize,
        scalars_ptr: usize,
        scalar_count: usize,
        grid_x: u32,
        grid_y: u32,
        grid_z: u32,
        threadgroup_x: u32,
        threadgroup_y: u32,
        threadgroup_z: u32,
        dynamic_shared_memory_bytes: u32,
    ) i32 {
        return accy_webgpu_launch(
            artifact_id,
            bindings_ptr,
            binding_count,
            scalars_ptr,
            scalar_count,
            grid_x,
            grid_y,
            grid_z,
            threadgroup_x,
            threadgroup_y,
            threadgroup_z,
            dynamic_shared_memory_bytes,
        );
    }

    fn objectDestroy(id: u64) void {
        accy_webgpu_object_destroy(id);
    }
};

const Host = if (browserish) BrowserHost else struct {};

const vtable = backend.BackendVTable{
    .query_capabilities = queryCapabilities,
    .create_artifact = createArtifact,
    .load_artifact = loadArtifact,
    .allocate_buffer = allocateBuffer,
    .write_buffer = writeBuffer,
    .read_buffer = readBuffer,
    .launch = launch,
    .synchronize = synchronize,
    .destroy_object = destroyObject,
};
