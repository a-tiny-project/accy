const std = @import("std");
const gpu = @import("gpu");

pub const State = struct {
    allocator: std.mem.Allocator,
    next_id: gpu.BackendObjectId = 1,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn handle(self: *State) gpu.BackendHandle {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .kind = .cuda,
        };
    }
};

fn queryCapabilities(_: *anyopaque) gpu.BackendError!gpu.BackendCapabilities {
    return .{
        .identity = .{
            .backend = .cuda,
            .family = .nvidia_cuda,
            .name = "ptx-validation",
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
            .shared_memory_bytes = 48 * 1024,
        },
        .dtypes = gpu.DTypeSet.init(&.{ .i1, .i8, .i16, .i32, .u8, .u16, .u32, .i64, .u64, .f32, .f16, .bf16, .f64 }),
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

fn createArtifact(
    ptr: *anyopaque,
    request: gpu.CompileRequest,
) gpu.BackendError!gpu.KernelArtifact {
    if (request.requested_format != .cuda_ptx) return error.UnsupportedArtifactFormat;
    const state: *State = @ptrCast(@alignCast(ptr));
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

fn loadArtifact(
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
    const state: *State = @ptrCast(@alignCast(ptr));
    const id = state.next_id;
    state.next_id += 1;
    return .{
        .id = id,
        .backend = .cuda,
        .format = .cuda_ptx,
    };
}

const vtable = gpu.BackendVTable{
    .query_capabilities = queryCapabilities,
    .create_artifact = createArtifact,
    .load_artifact = loadArtifact,
};

test "compile-only backend preserves PTX payload text" {
    var state = State.init(std.testing.allocator);
    var artifact = try state.handle().createArtifact(.{
        .kernel_name = "ptx_validation_probe",
        .requested_format = .cuda_ptx,
        .argument_count = 1,
        .required_dtypes = gpu.DTypeSet.init(&.{.f32}),
        .diagnostic_id = "validation/ptx/backend",
        .payload = .{ .text = ".version 7.0\n.visible .entry ptx_validation_probe() { ret; }\n" },
    });
    defer artifact.deinit();
    try std.testing.expectEqual(gpu.ArtifactFormat.cuda_ptx, artifact.format);
    switch (artifact.payload) {
        .text => |text| try std.testing.expect(std.mem.indexOf(u8, text, ".visible .entry") != null),
        else => return error.TestUnexpectedResult,
    }
}

test "compile-only backend rejects non-ptx artifact formats" {
    var state = State.init(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedArtifactFormat, state.handle().createArtifact(.{
        .kernel_name = "ptx_validation_probe",
        .requested_format = .metal_msl,
        .argument_count = 1,
        .required_dtypes = gpu.DTypeSet.init(&.{.f32}),
        .diagnostic_id = "validation/ptx/backend",
        .payload = .{ .text = "kernel" },
    }));
}

test "compile-only backend claims the same dtypes as the cuda runtime backend" {
    var state = State.init(std.testing.allocator);
    const capabilities = try state.handle().queryCapabilities();
    const expected = gpu.DTypeSet.init(&.{ .i1, .i8, .i16, .i32, .u8, .u16, .u32, .i64, .u64, .f32, .f16, .bf16, .f64 });
    try std.testing.expectEqual(expected.bits, capabilities.dtypes.bits);
}
