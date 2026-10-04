const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");

const artifact_product = @import("../artifact/model/root.zig");

pub const product_name = "accy.exec.pipeline";

pub const PipelineLaunch = struct {
    pipeline: artifact_product.KernelCallPipeline,
    registry: artifact_product.KernelCallRegistry,
    format: gpu.ArtifactFormat,
    operands: []const gpu.BufferBinding = &.{},
    results: []const gpu.BufferBinding = &.{},
    runtime_scalar_arguments: []const gpu_abi.ScalarArgument = &.{},
    intermediates: ?[]const gpu.BufferBinding = null,
    artifacts: ?*const PipelineArtifactPool = null,
    stream: ?gpu.StreamHandle = null,
    diagnostic_id: ?[]const u8 = null,
};

/// The compiled and loaded kernels of one kernel pipeline, one per stage,
/// labeled with the chain's target, version and artifact format, and owned by
/// the caller. The caller keeps a pool to launch the same chain many times
/// without loading its kernels again. `deinit` destroys every loaded kernel and
/// frees every compiled one. `deinit` waits for nothing, so the caller first
/// makes sure no queued launch still uses the kernels.
pub const PipelineArtifactPool = struct {
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    target: []const u8,
    version: u32,
    format: gpu.ArtifactFormat,
    entries: []PoolEntry,

    pub const PoolEntry = struct {
        artifact: gpu.KernelArtifact,
        loaded: gpu.LoadedArtifact,
    };

    pub fn deinit(self: *PipelineArtifactPool) void {
        deinitPipelinePoolEntries(self.handle, self.entries);
        if (self.entries.len != 0) self.allocator.free(self.entries);
        self.allocator.free(self.target);
        self.* = undefined;
    }
};

fn deinitPipelinePoolEntries(
    handle: gpu.BackendHandle,
    entries: []PipelineArtifactPool.PoolEntry,
) void {
    for (entries) |*pool_entry| {
        handle.destroyObject(pool_entry.loaded.id);
        pool_entry.artifact.deinit();
    }
}

/// Prepares a reusable set of loaded kernels once for a kernel pipeline. The
/// call checks the whole chain against the registry first, then compiles and
/// loads each stage's registry entry into a new pool. A stage whose entry is
/// missing for `format` gives `error.UnsupportedOperation`, and a failure part
/// way through unloads and frees the stages already loaded.
pub fn loadPipelineArtifacts(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    pipeline: artifact_product.KernelCallPipeline,
    registry: artifact_product.KernelCallRegistry,
    format: gpu.ArtifactFormat,
) gpu.BackendError!PipelineArtifactPool {
    try pipeline.validate(registry, format);
    const target = allocator.dupe(u8, pipeline.target) catch return error.OutOfMemory;
    errdefer allocator.free(target);
    const entries = allocator.alloc(
        PipelineArtifactPool.PoolEntry,
        pipeline.stages.len,
    ) catch return error.OutOfMemory;
    var loaded_count: usize = 0;
    errdefer {
        deinitPipelinePoolEntries(handle, entries[0..loaded_count]);
        allocator.free(entries);
    }
    for (pipeline.stages, entries) |stage, *pool_entry| {
        const entry = registry.find(stage.target, stage.version, format) orelse
            return error.UnsupportedOperation;
        var stage_artifact = try handle.createArtifact(.{
            .kernel_name = entry.entry_name,
            .requested_format = format,
            .argument_count = entry.argument_count,
            .scalar_argument_count = try entry.scalarArgumentCount(),
            .required_dtypes = entry.required_dtypes,
            .required_features = entry.required_features,
            .required_subgroup = entry.required_subgroup,
            .push_constants = entry.push_constants,
            .payload = entry.payload,
        });
        errdefer stage_artifact.deinit();
        const loaded = try handle.loadArtifact(&stage_artifact);
        pool_entry.* = .{ .artifact = stage_artifact, .loaded = loaded };
        loaded_count += 1;
    }
    return .{
        .allocator = allocator,
        .handle = handle,
        .target = target,
        .version = pipeline.version,
        .format = format,
        .entries = entries,
    };
}

pub fn intermediateByteSize(
    spec: artifact_product.PipelineIntermediate,
    runtime_scalar_arguments: []const gpu_abi.ScalarArgument,
) gpu.BackendError!usize {
    const extent = try spec.extent.resolveExtent(runtime_scalar_arguments);
    if (extent == 0) return error.InvalidArtifact;
    return std.math.mul(usize, extent, spec.dtype.sizeOf()) catch return error.InvalidArtifact;
}

/// Allocates each intermediate, a scratch buffer between stages, once so the
/// caller can pass the buffers to many launches. The call checks each runtime
/// scalar argument, then allocates one readable and writable device buffer for
/// each intermediate at the size those arguments give, aligned to 256 bytes.
/// The caller releases the buffers with `deinitPipelineIntermediates`, and only
/// after the work queued on them has finished.
pub fn allocatePipelineIntermediates(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    pipeline: artifact_product.KernelCallPipeline,
    runtime_scalar_arguments: []const gpu_abi.ScalarArgument,
) gpu.BackendError![]gpu.BufferBinding {
    try pipeline.validateRuntimeScalarArguments(runtime_scalar_arguments);
    const bindings = allocator.alloc(
        gpu.BufferBinding,
        pipeline.intermediates.len,
    ) catch return error.OutOfMemory;
    var initialized: usize = 0;
    errdefer {
        destroyPipelineIntermediateObjects(handle, bindings[0..initialized]);
        allocator.free(bindings);
    }
    for (pipeline.intermediates, bindings) |spec, *binding| {
        const extent = try spec.extent.resolveExtent(runtime_scalar_arguments);
        const byte_size = try intermediateByteSize(spec, runtime_scalar_arguments);
        const buffer = try handle.allocateBuffer(.{
            .byte_size = byte_size,
            .alignment = 256,
            .dtype = spec.dtype,
            .element_count = extent,
        });
        binding.* = .{
            .handle = buffer,
            .access = .read_write,
            .ownership = buffer.ownership,
            .byte_size = buffer.byte_size,
        };
        initialized += 1;
    }
    return bindings;
}

pub fn deinitPipelineIntermediates(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    bindings: []gpu.BufferBinding,
) void {
    destroyPipelineIntermediateObjects(handle, bindings);
    allocator.free(bindings);
}

fn destroyPipelineIntermediateObjects(
    handle: gpu.BackendHandle,
    bindings: []const gpu.BufferBinding,
) void {
    for (bindings) |binding| handle.destroyObject(binding.handle.id);
}

/// Runs a kernel pipeline once for the caller. The call checks the chain, the
/// operand and result counts, each runtime scalar argument, and any pool and
/// scratch buffers the caller passed, before launching any stage. A pool must
/// match the chain's stage count, version, format and target, and each scratch
/// buffer must be large enough and disjoint from every other scratch, operand
/// or result buffer, else `error.LaunchArgumentMismatch`. The stages launch in
/// their listed order on `request.stream`. When the call allocated scratch or
/// loaded kernels itself, the call waits for the stream on success before
/// destroying them. When the caller passed both a pool and scratch buffers, the
/// call returns without waiting, and the caller synchronizes before reusing or
/// freeing them. An error after launching starts a best-effort wait, and the
/// objects the call owns are destroyed even when that wait fails.
pub fn launchPipeline(
    scratch: std.mem.Allocator,
    handle: gpu.BackendHandle,
    request: PipelineLaunch,
) gpu.BackendError!void {
    const pipeline = request.pipeline;
    try pipeline.validate(request.registry, request.format);
    if (request.operands.len != pipeline.operand_count) return error.LaunchArgumentMismatch;
    if (request.results.len != pipeline.result_count) return error.LaunchArgumentMismatch;
    try pipeline.validateRuntimeScalarArguments(request.runtime_scalar_arguments);

    if (request.artifacts) |pool| {
        if (pool.entries.len != pipeline.stages.len) return error.LaunchArgumentMismatch;
        if (pool.version != pipeline.version) return error.LaunchArgumentMismatch;
        if (pool.format != request.format) return error.LaunchArgumentMismatch;
        if (!std.mem.eql(u8, pool.target, pipeline.target)) return error.LaunchArgumentMismatch;
    }

    var owned_intermediates: []gpu.BufferBinding = &.{};
    const intermediates = if (request.intermediates) |provided| intermediates: {
        try validatePipelineIntermediates(
            pipeline,
            request.runtime_scalar_arguments,
            request.operands,
            request.results,
            provided,
        );
        break :intermediates provided;
    } else intermediates: {
        owned_intermediates = try allocatePipelineIntermediates(
            scratch,
            handle,
            pipeline,
            request.runtime_scalar_arguments,
        );
        break :intermediates owned_intermediates;
    };
    defer if (request.intermediates ==
        null) deinitPipelineIntermediates(scratch, handle, owned_intermediates);

    var no_loaded_artifacts: [0]gpu.LoadedArtifact = .{};
    const loaded_artifacts = if (request.artifacts == null)
        scratch.alloc(gpu.LoadedArtifact, pipeline.stages.len) catch return error.OutOfMemory
    else
        no_loaded_artifacts[0..];
    defer if (request.artifacts == null) scratch.free(loaded_artifacts);
    var loaded_count: usize = 0;
    defer if (request.artifacts == null) destroyLoadedArtifacts(
        handle,
        loaded_artifacts[0..loaded_count],
    );

    const needs_sync = request.intermediates == null or request.artifacts == null;
    errdefer if (needs_sync) synchronizePipelineLaunch(handle, request.stream) catch {};
    try launchStages(scratch, handle, request, intermediates, loaded_artifacts, &loaded_count);
    if (needs_sync) try synchronizePipelineLaunch(handle, request.stream);
}

fn validatePipelineIntermediates(
    pipeline: artifact_product.KernelCallPipeline,
    runtime_scalar_arguments: []const gpu_abi.ScalarArgument,
    operands: []const gpu.BufferBinding,
    results: []const gpu.BufferBinding,
    provided: []const gpu.BufferBinding,
) gpu.BackendError!void {
    if (provided.len != pipeline.intermediates.len) return error.LaunchArgumentMismatch;
    for (pipeline.intermediates, provided, 0..) |spec, binding, index| {
        const byte_size = try intermediateByteSize(spec, runtime_scalar_arguments);
        if (binding.byte_size < byte_size) return error.LaunchArgumentMismatch;
        for (provided[0..index]) |previous| {
            if (bufferBindingsAlias(binding, previous)) return error.LaunchArgumentMismatch;
        }
        for (operands) |operand| {
            if (bufferBindingsAlias(binding, operand)) return error.LaunchArgumentMismatch;
        }
        for (results) |result| {
            if (bufferBindingsAlias(binding, result)) return error.LaunchArgumentMismatch;
        }
    }
}

fn bufferBindingsAlias(lhs: gpu.BufferBinding, rhs: gpu.BufferBinding) bool {
    return lhs.handle.backend == rhs.handle.backend and lhs.handle.id == rhs.handle.id;
}

fn destroyLoadedArtifacts(
    handle: gpu.BackendHandle,
    loaded_artifacts: []const gpu.LoadedArtifact,
) void {
    for (loaded_artifacts) |loaded| handle.destroyObject(loaded.id);
}

fn synchronizePipelineLaunch(
    handle: gpu.BackendHandle,
    stream: ?gpu.StreamHandle,
) gpu.BackendError!void {
    if (stream) |stream_handle| {
        try handle.synchronize(.{ .scope = .stream, .stream = stream_handle });
    } else {
        try handle.synchronize(.{ .scope = .device });
    }
}

fn launchStages(
    scratch: std.mem.Allocator,
    handle: gpu.BackendHandle,
    request: PipelineLaunch,
    intermediates: []const gpu.BufferBinding,
    loaded_artifacts: []gpu.LoadedArtifact,
    loaded_count: *usize,
) gpu.BackendError!void {
    for (request.pipeline.stages, 0..) |stage, stage_index| {
        const entry = request.registry.find(stage.target, stage.version, request.format) orelse {
            return error.UnsupportedOperation;
        };
        try launchStage(
            scratch,
            handle,
            request,
            entry,
            stage,
            stage_index,
            intermediates,
            loaded_artifacts,
            loaded_count,
        );
    }
}

fn launchStage(
    scratch: std.mem.Allocator,
    handle: gpu.BackendHandle,
    request: PipelineLaunch,
    entry: artifact_product.KernelCallArtifact,
    stage: artifact_product.PipelineStage,
    stage_index: usize,
    intermediates: []const gpu.BufferBinding,
    loaded_artifacts: []gpu.LoadedArtifact,
    loaded_count: *usize,
) gpu.BackendError!void {
    const scalars = scratch.alloc(
        gpu_abi.ScalarArgument,
        stage.scalars.len,
    ) catch return error.OutOfMemory;
    defer scratch.free(scalars);
    for (stage.scalars, scalars) |derivation, *value| {
        value.* = try derivation.resolveScalar(request.runtime_scalar_arguments);
    }

    const buffers = scratch.alloc(
        gpu.BufferBinding,
        stage.buffers.len,
    ) catch return error.OutOfMemory;
    defer scratch.free(buffers);
    for (stage.buffers, buffers) |ref, *binding| {
        binding.* = switch (ref) {
            .operand => |index| request.operands[index],
            .result => |index| request.results[index],
            .intermediate => |index| intermediates[index],
        };
    }

    const geometry = switch (entry.launch) {
        .derived => |derived| try derived.geometry(scalars),
        .fixed => |fixed| fixed,
    };

    if (request.artifacts) |pool| {
        const pool_entry = &pool.entries[stage_index];
        try handle.launch(.{
            .artifact = &pool_entry.artifact,
            .loaded_artifact = pool_entry.loaded,
            .buffers = buffers,
            .scalar_arguments = scalars,
            .geometry = geometry,
            .stream = request.stream,
            .diagnostic_id = request.diagnostic_id,
        });
        return;
    }

    var stage_artifact = try handle.createArtifact(.{
        .kernel_name = entry.entry_name,
        .requested_format = request.format,
        .argument_count = entry.argument_count,
        .scalar_argument_count = try entry.scalarArgumentCount(),
        .required_dtypes = entry.required_dtypes,
        .required_features = entry.required_features,
        .required_subgroup = entry.required_subgroup,
        .push_constants = entry.push_constants,
        .diagnostic_id = request.diagnostic_id,
        .payload = entry.payload,
    });
    defer stage_artifact.deinit();
    const loaded = try handle.loadArtifact(&stage_artifact);
    errdefer handle.destroyObject(loaded.id);

    try handle.launch(.{
        .artifact = &stage_artifact,
        .loaded_artifact = loaded,
        .buffers = buffers,
        .scalar_arguments = scalars,
        .geometry = geometry,
        .stream = request.stream,
        .diagnostic_id = request.diagnostic_id,
    });
    if (loaded_count.* >= loaded_artifacts.len) return error.InvalidArtifact;
    loaded_artifacts[loaded_count.*] = loaded;
    loaded_count.* += 1;
}

const testing = std.testing;

fn pipelineTestEntry(
    comptime target: []const u8,
    argument_count: u32,
    runtime_scalars: u32,
    launch: artifact_product.KernelCallLaunch,
) artifact_product.KernelCallArtifact {
    return .{
        .target = target,
        .version = 1,
        .format = .cuda_ptx,
        .entry_name = target,
        .argument_count = argument_count,
        .payload = .{ .text = "// " ++ target },
        .launch = launch,
        .runtime_scalar_argument_count = runtime_scalars,
    };
}

const test_entries = [_]artifact_product.KernelCallArtifact{
    pipelineTestEntry("accy.kernel.test.block_scan", 4, 1, .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = 64 } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ 64, 1, 1 },
    } }),
    pipelineTestEntry("accy.kernel.test.sums_scan", 3, 1, .{ .derived = .{
        .grid = .{
            .{ .fixed = 1 },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ 96, 1, 1 },
    } }),
    pipelineTestEntry("accy.kernel.test.add_base", 3, 1, .{ .derived = .{
        .grid = .{
            .{ .runtime_u32_ceil_div = .{ .argument_index = 0, .divisor = 64 } },
            .{ .fixed = 1 },
            .{ .fixed = 1 },
        },
        .threadgroup = .{ 64, 1, 1 },
    } }),
};

const test_pipeline = artifact_product.KernelCallPipeline{
    .target = "accy.kernel.test.device_scan",
    .version = 1,
    .operand_count = 1,
    .result_count = 1,
    .runtime_scalar_argument_count = 1,
    .intermediates = &.{
        .{ .dtype = .f32, .extent = .{ .ceil_div = .{ .argument_index = 0, .divisor = 64 } } },
        .{ .dtype = .f32, .extent = .{ .ceil_div = .{ .argument_index = 0, .divisor = 64 } } },
    },
    .stages = &.{
        .{
            .target = "accy.kernel.test.block_scan",
            .version = 1,
            .buffers = &.{ .{ .result = 0 }, .{ .operand = 0 }, .{ .intermediate = 0 } },
            .scalars = &.{.{ .forward = 0 }},
        },
        .{
            .target = "accy.kernel.test.sums_scan",
            .version = 1,
            .buffers = &.{ .{ .intermediate = 1 }, .{ .intermediate = 0 } },
            .scalars = &.{.{ .ceil_div = .{ .argument_index = 0, .divisor = 64 } }},
        },
        .{
            .target = "accy.kernel.test.add_base",
            .version = 1,
            .buffers = &.{ .{ .result = 0 }, .{ .intermediate = 1 } },
            .scalars = &.{.{ .forward = 0 }},
        },
    },
};

fn testBinding(id: gpu.BackendObjectId) gpu.BufferBinding {
    return .{
        .handle = .{ .id = id, .backend = .cuda, .byte_size = 20000, .ownership = .backend },
        .access = .read_write,
        .ownership = .backend,
        .byte_size = 20000,
    };
}

fn recordingDestroyedId(state: *const gpu.recording.BackendState, id: gpu.BackendObjectId) bool {
    const count = @min(state.destroy_count, state.destroyed_ids.len);
    for (state.destroyed_ids[0..count]) |destroyed_id| {
        if (destroyed_id == id) return true;
    }
    return false;
}

test "pipeline executor derives intermediates scalars and geometry per stage" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..] };

    const operands = [_]gpu.BufferBinding{testBinding(1001)};
    const results = [_]gpu.BufferBinding{testBinding(1002)};
    const args = [_]gpu_abi.ScalarArgument{.{ .u32 = 5000 }};

    try launchPipeline(testing.allocator, state.handle(), .{
        .pipeline = test_pipeline,
        .registry = registry,
        .format = .cuda_ptx,
        .operands = operands[0..],
        .results = results[0..],
        .runtime_scalar_arguments = args[0..],
    });

    try testing.expectEqual(@as(usize, 2), state.buffer_allocate_count);
    try testing.expectEqual(@as(usize, 79 * 4), state.allocated_buffer_byte_sizes[0]);
    try testing.expectEqual(@as(usize, 79 * 4), state.allocated_buffer_byte_sizes[1]);

    try testing.expectEqual(@as(usize, 3), state.launch_count);
    try testing.expectEqual([3]u32{ 79, 1, 1 }, state.launch_grids[0]);
    try testing.expectEqual([3]u32{ 1, 1, 1 }, state.launch_grids[1]);
    try testing.expectEqual([3]u32{ 79, 1, 1 }, state.launch_grids[2]);
    try testing.expectEqual(@as(?u32, 5000), state.launch_scalar_u32s[0]);
    try testing.expectEqual(@as(?u32, 79), state.launch_scalar_u32s[1]);
    try testing.expectEqual(@as(?u32, 5000), state.launch_scalar_u32s[2]);

    try testing.expectEqual(@as(usize, 2), state.last_launch_buffer_count);
    try testing.expectEqual(@as(gpu.BackendObjectId, 1002), state.last_buffer_ids[0]);
    try testing.expectEqual(@as(usize, 3), state.load_count);
    try testing.expectEqual(@as(usize, 5), state.destroy_count);
    try testing.expect(recordingDestroyedId(&state, state.allocated_buffer_ids[0]));
    try testing.expect(recordingDestroyedId(&state, state.allocated_buffer_ids[1]));
}

test "pipeline executor rejects binding count mismatches" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..] };
    const args = [_]gpu_abi.ScalarArgument{.{ .u32 = 5000 }};
    const operands = [_]gpu.BufferBinding{testBinding(1001)};
    const results = [_]gpu.BufferBinding{testBinding(1002)};

    try testing.expectError(
        error.LaunchArgumentMismatch,
        launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = test_pipeline,
            .registry = registry,
            .format = .cuda_ptx,
            .operands = &.{},
            .results = results[0..],
            .runtime_scalar_arguments = args[0..],
        }),
    );
    try testing.expectError(
        error.LaunchArgumentMismatch,
        launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = test_pipeline,
            .registry = registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = &.{},
        }),
    );
    try testing.expectEqual(@as(usize, 0), state.launch_count);
}

test "pipeline executor rejects runtime scalar bounds before allocation" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..] };
    var bounded = test_pipeline;
    bounded.runtime_scalar_bounds = &.{.{ .argument_index = 0, .max_u32 = 5000 }};
    const args = [_]gpu_abi.ScalarArgument{.{ .u32 = 5001 }};
    const operands = [_]gpu.BufferBinding{testBinding(1001)};
    const results = [_]gpu.BufferBinding{testBinding(1002)};

    try testing.expectError(
        error.LaunchArgumentMismatch,
        launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = bounded,
            .registry = registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = args[0..],
        }),
    );
    try testing.expectEqual(@as(usize, 0), state.buffer_allocate_count);
    try testing.expectEqual(@as(usize, 0), state.launch_count);

    try testing.expectError(
        error.LaunchArgumentMismatch,
        allocatePipelineIntermediates(testing.allocator, state.handle(), bounded, args[0..]),
    );
    try testing.expectEqual(@as(usize, 0), state.buffer_allocate_count);
}

test "pipeline executor refuses unresolvable stages before any launch" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..1] };
    const args = [_]gpu_abi.ScalarArgument{.{ .u32 = 5000 }};
    const operands = [_]gpu.BufferBinding{testBinding(1001)};
    const results = [_]gpu.BufferBinding{testBinding(1002)};

    try testing.expectError(
        error.InvalidArtifact,
        launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = test_pipeline,
            .registry = registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = args[0..],
        }),
    );
    try testing.expectEqual(@as(usize, 0), state.launch_count);
    try testing.expectEqual(@as(usize, 0), state.destroy_count);
}

test "pipeline executor releases intermediates after partial allocation failure" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
        .fail_buffer_allocate_after_count = 1,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..] };
    const args = [_]gpu_abi.ScalarArgument{.{ .u32 = 5000 }};
    const operands = [_]gpu.BufferBinding{testBinding(1001)};
    const results = [_]gpu.BufferBinding{testBinding(1002)};

    try testing.expectError(error.OutOfMemory, launchPipeline(testing.allocator, state.handle(), .{
        .pipeline = test_pipeline,
        .registry = registry,
        .format = .cuda_ptx,
        .operands = operands[0..],
        .results = results[0..],
        .runtime_scalar_arguments = args[0..],
    }));
    try testing.expectEqual(@as(usize, 1), state.buffer_allocate_count);
    try testing.expectEqual(@as(usize, 1), state.destroy_count);
    try testing.expect(recordingDestroyedId(&state, state.allocated_buffer_ids[0]));
}

test "pipeline executor releases loaded artifacts after staged load failure" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
        .fail_load_after_count = 1,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..] };
    const args = [_]gpu_abi.ScalarArgument{.{ .u32 = 5000 }};
    const operands = [_]gpu.BufferBinding{testBinding(1001)};
    const results = [_]gpu.BufferBinding{testBinding(1002)};

    try testing.expectError(
        error.RuntimeUnavailable,
        launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = test_pipeline,
            .registry = registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = args[0..],
        }),
    );
    try testing.expectEqual(@as(usize, 2), state.buffer_allocate_count);
    try testing.expectEqual(@as(usize, 1), state.load_count);
    try testing.expectEqual(@as(usize, 1), state.launch_count);
    try testing.expectEqual(@as(usize, 3), state.destroy_count);
    try testing.expect(recordingDestroyedId(&state, state.allocated_buffer_ids[0]));
    try testing.expect(recordingDestroyedId(&state, state.allocated_buffer_ids[1]));
}

test "pipeline executor reuses provided intermediates without allocating" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..] };
    const args = [_]gpu_abi.ScalarArgument{.{ .u32 = 5000 }};
    const operands = [_]gpu.BufferBinding{testBinding(1001)};
    const results = [_]gpu.BufferBinding{testBinding(1002)};

    const provided = try allocatePipelineIntermediates(
        testing.allocator,
        state.handle(),
        test_pipeline,
        args[0..],
    );
    defer deinitPipelineIntermediates(testing.allocator, state.handle(), provided);
    try testing.expectEqual(@as(usize, 2), state.buffer_allocate_count);

    try launchPipeline(testing.allocator, state.handle(), .{
        .pipeline = test_pipeline,
        .registry = registry,
        .format = .cuda_ptx,
        .operands = operands[0..],
        .results = results[0..],
        .runtime_scalar_arguments = args[0..],
        .intermediates = provided,
    });
    try testing.expectEqual(@as(usize, 2), state.buffer_allocate_count);
    try testing.expectEqual(@as(usize, 3), state.launch_count);

    try launchPipeline(testing.allocator, state.handle(), .{
        .pipeline = test_pipeline,
        .registry = registry,
        .format = .cuda_ptx,
        .operands = operands[0..],
        .results = results[0..],
        .runtime_scalar_arguments = args[0..],
        .intermediates = provided,
    });
    try testing.expectEqual(@as(usize, 2), state.buffer_allocate_count);
    try testing.expectEqual(@as(usize, 6), state.launch_count);
}

test "pipeline executor rejects undersized or miscounted provided intermediates" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..] };
    const args = [_]gpu_abi.ScalarArgument{.{ .u32 = 5000 }};
    const operands = [_]gpu.BufferBinding{testBinding(1001)};
    const results = [_]gpu.BufferBinding{testBinding(1002)};

    const miscounted = [_]gpu.BufferBinding{testBinding(2001)};
    try testing.expectError(
        error.LaunchArgumentMismatch,
        launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = test_pipeline,
            .registry = registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = args[0..],
            .intermediates = miscounted[0..],
        }),
    );

    var undersized = [_]gpu.BufferBinding{ testBinding(2001), testBinding(2002) };
    undersized[1].byte_size = 4;
    try testing.expectError(
        error.LaunchArgumentMismatch,
        launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = test_pipeline,
            .registry = registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = args[0..],
            .intermediates = undersized[0..],
        }),
    );

    const duplicate = [_]gpu.BufferBinding{ testBinding(2001), testBinding(2001) };
    try testing.expectError(
        error.LaunchArgumentMismatch,
        launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = test_pipeline,
            .registry = registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = args[0..],
            .intermediates = duplicate[0..],
        }),
    );

    const operand_alias = [_]gpu.BufferBinding{ operands[0], testBinding(2002) };
    try testing.expectError(
        error.LaunchArgumentMismatch,
        launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = test_pipeline,
            .registry = registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = args[0..],
            .intermediates = operand_alias[0..],
        }),
    );

    const result_alias = [_]gpu.BufferBinding{ testBinding(2001), results[0] };
    try testing.expectError(
        error.LaunchArgumentMismatch,
        launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = test_pipeline,
            .registry = registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = args[0..],
            .intermediates = result_alias[0..],
        }),
    );
    try testing.expectEqual(@as(usize, 0), state.launch_count);
}

test "pipeline executor launches from a loaded artifact pool without driver round trips" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..] };
    const args = [_]gpu_abi.ScalarArgument{.{ .u32 = 5000 }};
    const operands = [_]gpu.BufferBinding{testBinding(1001)};
    const results = [_]gpu.BufferBinding{testBinding(1002)};

    var pool = try loadPipelineArtifacts(
        testing.allocator,
        state.handle(),
        test_pipeline,
        registry,
        .cuda_ptx,
    );
    defer pool.deinit();
    try testing.expectEqual(@as(usize, 3), state.create_count);
    try testing.expectEqual(@as(usize, 3), state.load_count);

    const provided = try allocatePipelineIntermediates(
        testing.allocator,
        state.handle(),
        test_pipeline,
        args[0..],
    );
    defer deinitPipelineIntermediates(testing.allocator, state.handle(), provided);

    var round: usize = 0;
    while (round < 3) : (round += 1) {
        try launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = test_pipeline,
            .registry = registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = args[0..],
            .intermediates = provided,
            .artifacts = &pool,
        });
    }
    try testing.expectEqual(@as(usize, 3), state.create_count);
    try testing.expectEqual(@as(usize, 3), state.load_count);
    try testing.expectEqual(@as(usize, 9), state.launch_count);
}

test "pipeline artifact pool deinit destroys loaded artifacts" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..] };

    var pool = try loadPipelineArtifacts(
        testing.allocator,
        state.handle(),
        test_pipeline,
        registry,
        .cuda_ptx,
    );
    try testing.expectEqual(@as(usize, 3), state.load_count);
    try testing.expectEqual(@as(usize, 0), state.destroy_count);

    pool.deinit();
    try testing.expectEqual(@as(usize, 3), state.destroy_count);
    try testing.expectEqual(@as(?gpu.BackendObjectId, 3), state.last_destroyed_id);
}

test "pipeline stage artifacts carry their entry's scalar count" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..] };

    var pool = try loadPipelineArtifacts(
        testing.allocator,
        state.handle(),
        test_pipeline,
        registry,
        .cuda_ptx,
    );
    defer pool.deinit();
    for (pool.entries, test_pipeline.stages) |pool_entry, stage| {
        const entry = registry.find(stage.target, stage.version, .cuda_ptx).?;
        try testing.expectEqual(
            entry.runtime_scalar_argument_count,
            pool_entry.artifact.scalar_argument_count,
        );
        try testing.expectEqual(
            entry.argument_count - entry.runtime_scalar_argument_count,
            try pool_entry.artifact.bufferArgumentCount(),
        );
    }
}

test "pipeline artifact pool cleans loaded artifacts after staged load failure" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
        .fail_load_after_count = 1,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..] };

    try testing.expectError(
        error.RuntimeUnavailable,
        loadPipelineArtifacts(
            testing.allocator,
            state.handle(),
            test_pipeline,
            registry,
            .cuda_ptx,
        ),
    );
    try testing.expectEqual(@as(usize, 1), state.load_count);
    try testing.expectEqual(@as(usize, 1), state.destroy_count);
    try testing.expectEqual(@as(?gpu.BackendObjectId, 1), state.last_destroyed_id);
}

test "pipeline executor rejects mismatched artifact pools before any launch" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..] };
    const args = [_]gpu_abi.ScalarArgument{.{ .u32 = 5000 }};
    const operands = [_]gpu.BufferBinding{testBinding(1001)};
    const results = [_]gpu.BufferBinding{testBinding(1002)};

    var pool = try loadPipelineArtifacts(
        testing.allocator,
        state.handle(),
        test_pipeline,
        registry,
        .cuda_ptx,
    );
    defer pool.deinit();

    var renamed = test_pipeline;
    renamed.target = "accy.kernel.test.other_pipeline";
    try testing.expectError(
        error.LaunchArgumentMismatch,
        launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = renamed,
            .registry = registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = args[0..],
            .artifacts = &pool,
        }),
    );

    var reversioned = test_pipeline;
    reversioned.version = 9;
    try testing.expectError(
        error.LaunchArgumentMismatch,
        launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = reversioned,
            .registry = registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = args[0..],
            .artifacts = &pool,
        }),
    );
    try testing.expectEqual(@as(usize, 0), state.launch_count);
}

test "pipeline executor rejects artifact pool format mismatches before any launch" {
    var state = gpu.recording.BackendState{
        .allocator = testing.allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const registry = artifact_product.KernelCallRegistry{ .entries = test_entries[0..] };
    var metal_entries = test_entries;
    for (&metal_entries) |*entry| entry.format = .metal_msl;
    const metal_registry = artifact_product.KernelCallRegistry{ .entries = metal_entries[0..] };
    const args = [_]gpu_abi.ScalarArgument{.{ .u32 = 5000 }};
    const operands = [_]gpu.BufferBinding{testBinding(1001)};
    const results = [_]gpu.BufferBinding{testBinding(1002)};

    var pool = try loadPipelineArtifacts(
        testing.allocator,
        state.handle(),
        test_pipeline,
        registry,
        .cuda_ptx,
    );
    defer pool.deinit();

    try testing.expectError(
        error.LaunchArgumentMismatch,
        launchPipeline(testing.allocator, state.handle(), .{
            .pipeline = test_pipeline,
            .registry = metal_registry,
            .format = .metal_msl,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = args[0..],
            .artifacts = &pool,
        }),
    );
    try testing.expectEqual(@as(usize, 0), state.buffer_allocate_count);
    try testing.expectEqual(@as(usize, 0), state.launch_count);
}
