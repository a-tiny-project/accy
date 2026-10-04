const std = @import("std");
const builtin = @import("builtin");

const backend = @import("root.zig");
const host = @import("host.zig");

const Allocator = std.mem.Allocator;
const browserish = builtin.target.cpu.arch.isWasm() and builtin.target.os.tag == .freestanding;

pub const State = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *State) void {}

    pub fn handle(self: *State) backend.BackendHandle {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .kind = .wasm,
        };
    }
};

pub fn staticCapabilities() backend.BackendCapabilities {
    return .{
        .identity = .{
            .backend = .wasm,
            .family = .webassembly,
            .name = "webassembly",
        },
        .memory = .{
            .min_buffer_alignment = 1,
            .host_visible_device_memory = true,
        },
        .threadgroup = .{
            .max_threads = 1024,
            .max_blocks = .{ std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) },
            .max_threads_per_dim = .{ 1024, 1024, 64 },
            .max_grid_per_dim = .{ std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) },
        },
        .dtypes = backend.DTypeSet.init(&.{ .i1, .i32, .u32, .i64, .u64, .f32, .f64, .key }),
        .layouts = .{
            .row_major = true,
            .compact_strides = true,
            .broadcast_strides = true,
        },
        .runtime = .{
            .driver_loaded = true,
            .device_context = true,
        },
        .artifact_formats = backend.ArtifactFormatSet.init(&.{.webassembly_module}),
    };
}

fn queryCapabilities(_: *anyopaque) backend.BackendError!backend.BackendCapabilities {
    return staticCapabilities();
}

fn createArtifact(ptr: *anyopaque, request: backend.CompileRequest) backend.BackendError!backend.KernelArtifact {
    if (request.requested_format != .webassembly_module) return error.UnsupportedArtifactFormat;
    const state: *State = @ptrCast(@alignCast(ptr));
    const bytes = switch (request.payload) {
        .bytes => |payload| payload,
        else => return error.InvalidArtifact,
    };
    if (!isWasmModule(bytes)) return error.InvalidArtifact;

    var artifact = backend.KernelArtifact.init(state.allocator, .{
        .backend = .wasm,
        .format = .webassembly_module,
        .entry_name = request.kernel_name,
        .argument_count = request.argument_count,
        .scalar_argument_count = request.scalar_argument_count,
        .diagnostic_id = request.diagnostic_id,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    try artifact.setOwnedBytes(bytes);
    return artifact;
}

fn loadArtifact(_: *anyopaque, artifact: *const backend.KernelArtifact) backend.BackendError!backend.LoadedArtifact {
    if (artifact.backend != .wasm or artifact.format != .webassembly_module) return error.InvalidArtifact;
    if (artifact.entry_name.len == 0) return error.InvalidArtifact;
    const bytes = switch (artifact.payload) {
        .bytes => |payload| payload,
        else => return error.InvalidArtifact,
    };
    if (!isWasmModule(bytes)) return error.InvalidArtifact;
    if (comptime !browserish) return error.RuntimeUnavailable;

    const id = Host.artifactLoad(
        host.pointer(bytes),
        bytes.len,
        host.pointer(artifact.entry_name),
        artifact.entry_name.len,
        artifact.argument_count,
    );
    if (id == 0) return error.RuntimeUnavailable;
    return .{
        .id = id,
        .backend = .wasm,
        .format = .webassembly_module,
    };
}

fn allocateBuffer(_: *anyopaque, request: backend.BufferAllocation) backend.BackendError!backend.BufferHandle {
    if (comptime !browserish) return error.RuntimeUnavailable;
    const id = Host.bufferAlloc(request.byte_size, request.alignment);
    if (id == 0) return error.OutOfMemory;
    return .{
        .id = id,
        .backend = .wasm,
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
    if (loaded.backend != .wasm or loaded.format != .webassembly_module) return error.InvalidArtifact;

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

fn isWasmModule(bytes: []const u8) bool {
    return bytes.len >= 8 and
        std.mem.eql(u8, bytes[0..4], &.{ 0x00, 0x61, 0x73, 0x6d }) and
        std.mem.eql(u8, bytes[4..8], &.{ 0x01, 0x00, 0x00, 0x00 });
}

const BrowserHost = struct {
    extern "accy" fn accy_wasm_artifact_load(
        bytes_ptr: usize,
        bytes_len: usize,
        entry_ptr: usize,
        entry_len: usize,
        argument_count: u32,
    ) callconv(.c) u64;

    extern "accy" fn accy_wasm_buffer_alloc(byte_size: usize, alignment: u32) callconv(.c) u64;
    extern "accy" fn accy_wasm_buffer_write(id: u64, bytes_ptr: usize, byte_count: usize) callconv(.c) i32;
    extern "accy" fn accy_wasm_buffer_read(id: u64, bytes_ptr: usize, byte_count: usize) callconv(.c) i32;
    extern "accy" fn accy_wasm_object_destroy(id: u64) callconv(.c) void;

    extern "accy" fn accy_wasm_launch(
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

    fn artifactLoad(bytes_ptr: usize, bytes_len: usize, entry_ptr: usize, entry_len: usize, argument_count: u32) u64 {
        return accy_wasm_artifact_load(bytes_ptr, bytes_len, entry_ptr, entry_len, argument_count);
    }

    fn bufferAlloc(byte_size: usize, alignment: u32) u64 {
        return accy_wasm_buffer_alloc(byte_size, alignment);
    }

    fn bufferWrite(id: u64, bytes_ptr: usize, byte_count: usize) i32 {
        return accy_wasm_buffer_write(id, bytes_ptr, byte_count);
    }

    fn bufferRead(id: u64, bytes_ptr: usize, byte_count: usize) i32 {
        return accy_wasm_buffer_read(id, bytes_ptr, byte_count);
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
        return accy_wasm_launch(
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
        accy_wasm_object_destroy(id);
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
