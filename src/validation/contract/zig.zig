const std = @import("std");
const gpu = @import("gpu");
const sys = @import("sys");
const testing = std.testing;
const accy = @import("accy");

fn buildAddOne(allocator: std.mem.Allocator) !*accy.choir.SemanticModule {
    var builder = try accy.choir.SemanticBuilder.init(
        allocator,
        accy.choir.SemanticBuilder.ContextLimits.standard,
    );
    defer builder.deinit();

    const x_ty = try builder.tensor(.f32, &.{4});
    var function = try builder.beginFunction("add_one", &.{x_ty}, &.{x_ty});
    const x = function.parameter(0);

    const one_bytes: [4]f32 = .{ 1, 1, 1, 1 };
    const one = try function.constant(x_ty, std.mem.sliceAsBytes(one_bytes[0..]));
    const sum = try function.add(x, one);
    try function.return_(&.{sum});
    try function.finish();

    return try builder.finish();
}

const RecordingBackendState = struct {
    allocator: std.mem.Allocator,
    create_count: usize = 0,
    load_count: usize = 0,
    destroy_count: usize = 0,
    next_id: gpu.BackendObjectId = 1,
    last_create_had_payload: bool = false,
    last_create_argument_count: u32 = 0,
    last_create_required_dtype_bits: u64 = 0,
    last_create_payload_mentions_entry: bool = false,
    last_loaded_id: ?gpu.BackendObjectId = null,
    last_destroyed_id: ?gpu.BackendObjectId = null,

    fn init(allocator: std.mem.Allocator) RecordingBackendState {
        return .{ .allocator = allocator };
    }

    fn handle(self: *RecordingBackendState) gpu.BackendHandle {
        return .{
            .ptr = self,
            .vtable = &recording_vtable,
            .kind = .cuda,
        };
    }
};

fn recordingQueryCapabilities(_: *anyopaque) gpu.BackendError!gpu.BackendCapabilities {
    return .{
        .identity = .{
            .backend = .cuda,
            .family = .nvidia_cuda,
            .name = "recording-cuda",
        },
        .threadgroup = .{
            .max_threads = 1024,
            .max_blocks = .{ 65_535, 65_535, 65_535 },
            .max_threads_per_dim = .{ 1024, 1024, 64 },
            .max_grid_per_dim = .{ 65_535, 65_535, 65_535 },
            .shared_memory_bytes = 48 * 1024,
        },
        .dtypes = gpu.DTypeSet.init(&.{ .f32, .i32, .u32 }),
        .runtime = .{
            .driver_loaded = true,
            .device_context = true,
            .streams = true,
            .events = true,
        },
        .features = .{
            .atomic_i32 = true,
            .atomic_u32 = true,
            .atomic_index = true,
            .atomic_f32_add_device = true,
            .atomic_f32_add_shared = true,
            .dynamic_shared_memory = true,
        },
        .artifact_formats = gpu.ArtifactFormatSet.init(&.{.cuda_ptx}),
    };
}

fn recordingCreateArtifact(
    ptr: *anyopaque,
    request: gpu.CompileRequest,
) gpu.BackendError!gpu.KernelArtifact {
    if (request.requested_format != .cuda_ptx) return error.UnsupportedArtifactFormat;
    const state: *RecordingBackendState = @ptrCast(@alignCast(ptr));
    state.create_count += 1;
    state.last_create_argument_count = request.argument_count;
    state.last_create_required_dtype_bits = request.required_dtypes.bits;
    state.last_create_had_payload = switch (request.payload) {
        .none => false,
        else => true,
    };
    state.last_create_payload_mentions_entry = switch (request.payload) {
        .text => |text| std.mem.indexOf(u8, text, request.kernel_name) != null,
        .bytes => |bytes| std.mem.indexOf(u8, bytes, request.kernel_name) != null,
        else => false,
    };

    var artifact = gpu.KernelArtifact.init(state.allocator, .{
        .backend = .cuda,
        .format = .cuda_ptx,
        .entry_name = request.kernel_name,
        .argument_count = request.argument_count,
        .scalar_argument_count = request.scalar_argument_count,
        .diagnostic_id = request.diagnostic_id,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    switch (request.payload) {
        .text => |text| try artifact.setOwnedText(text),
        .bytes => |bytes| try artifact.setOwnedBytes(bytes),
        else => return error.InvalidArtifact,
    }
    return artifact;
}

fn recordingLoadArtifact(
    ptr: *anyopaque,
    artifact: *const gpu.KernelArtifact,
) gpu.BackendError!gpu.LoadedArtifact {
    if (artifact.backend != .cuda) return error.CapabilityMismatch;
    if (artifact.format != .cuda_ptx) return error.UnsupportedArtifactFormat;
    switch (artifact.payload) {
        .text => |text| if (text.len == 0) return error.InvalidArtifact,
        .bytes => |bytes| if (bytes.len == 0) return error.InvalidArtifact,
        else => return error.InvalidArtifact,
    }
    const state: *RecordingBackendState = @ptrCast(@alignCast(ptr));
    const id = state.next_id;
    state.next_id += 1;
    state.load_count += 1;
    state.last_loaded_id = id;
    return .{
        .id = id,
        .backend = .cuda,
        .format = .cuda_ptx,
    };
}

fn recordingDestroyObject(ptr: *anyopaque, id: gpu.BackendObjectId) void {
    const state: *RecordingBackendState = @ptrCast(@alignCast(ptr));
    state.destroy_count += 1;
    state.last_destroyed_id = id;
}

const recording_vtable = gpu.BackendVTable{
    .query_capabilities = recordingQueryCapabilities,
    .create_artifact = recordingCreateArtifact,
    .load_artifact = recordingLoadArtifact,
    .destroy_object = recordingDestroyObject,
};

test "contract: semantic Choir module compiles and loads a fragment" {
    const allocator = testing.allocator;

    const module = try buildAddOne(allocator);

    var state = RecordingBackendState.init(allocator);
    const compiled = try accy.executable.compileFragmentFromSemanticModule(
        allocator,
        state.handle(),
        module,
        .{},
    );
    var fragment = try accy.executable.loadFragment(allocator, state.handle(), compiled, .{});
    var fragment_live = true;
    defer if (fragment_live) fragment.deinit();

    try testing.expectEqual(@as(usize, 1), state.create_count);
    try testing.expectEqual(@as(usize, 1), state.load_count);
    try testing.expect(state.last_create_had_payload);
    try testing.expect(state.last_create_payload_mentions_entry);
    try testing.expect(state.last_create_argument_count > 0);
    try testing.expect(
        (state.last_create_required_dtype_bits & gpu.DTypeSet.init(&.{.f32}).bits) != 0,
    );
    try testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try testing.expectEqual(accy.artifact.KernelSource.tensor, summary.source);

    const loaded_id = state.last_loaded_id.?;
    fragment.deinit();
    fragment_live = false;
    try testing.expectEqual(@as(usize, 1), state.destroy_count);
    try testing.expectEqual(loaded_id, state.last_destroyed_id.?);
}

test "contract: Choir fragment compilation and loading is repeatable" {
    const allocator = testing.allocator;

    var state = RecordingBackendState.init(allocator);
    for (0..3) |_| {
        const module = try buildAddOne(allocator);
        const compiled = try accy.executable.compileFragmentFromSemanticModule(
            allocator,
            state.handle(),
            module,
            .{},
        );
        var fragment = try accy.executable.loadFragment(allocator, state.handle(), compiled, .{});
        fragment.deinit();
    }
    try testing.expectEqual(@as(usize, 3), state.create_count);
    try testing.expectEqual(@as(usize, 3), state.load_count);
    try testing.expectEqual(@as(usize, 3), state.destroy_count);
}

test "contract: Choir compile path stays on one thread" {
    const allocator = testing.allocator;

    const module = try buildAddOne(allocator);

    const owner = sys.thread.currentId();

    var state = RecordingBackendState.init(allocator);
    const compiled = try accy.executable.compileFragmentFromSemanticModule(
        allocator,
        state.handle(),
        module,
        .{},
    );
    var fragment = try accy.executable.loadFragment(allocator, state.handle(), compiled, .{});
    defer fragment.deinit();

    try testing.expectEqual(owner, sys.thread.currentId());
}
