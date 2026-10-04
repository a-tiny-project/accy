const std = @import("std");
const gpu = @import("gpu");
const choir = @import("choir");
const gpu_abi = @import("gpu_abi");
const accy_root = @import("../../root.zig");
const artifact_product = @import("../../artifact/root.zig");
const preparation = @import("../../preparation/root.zig");
const target = @import("../../target/root.zig");
const kernel_model = @import("../model/root.zig");
const builder = kernel_model.core.builder;
const plan_mod = kernel_model.plan;
const program_mod = @import("../program/root.zig");

const DType = gpu_abi.DType;

pub const Options = struct {
    format: ?gpu.ArtifactFormat = null,
    kernel_plan: plan_mod.Options = .{},
    disable_cpu_vectorization: bool = false,
};

const CompilePlan = struct {
    entry_name: []const u8,
    argument_count: u32,
    payload: gpu.CompilePayload,
    required_features: gpu_abi.Features = .{},
    required_subgroup: gpu_abi.SubgroupRequirements = .{},
    push_constants: gpu_abi.PushConstants = .{},
    runtime_scalar_argument_count: u32 = 0,
    static_arguments: []gpu_abi.ScalarArgument = &.{},

    fn deinit(self: *CompilePlan, allocator: std.mem.Allocator) void {
        if (self.static_arguments.len != 0) allocator.free(self.static_arguments);
        deinitCompilePayload(allocator, self.payload);
        self.* = undefined;
    }
};

pub fn createJob(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    program: *program_mod.Program,
    options: Options,
) !*artifact_product.ArtifactJob {
    var artifact_plan = try createPlan(allocator, handle, program, options);
    var plan_owned = true;
    errdefer if (plan_owned) artifact_plan.deinit();

    const artifact_job = try artifact_product.ArtifactJob.init(
        allocator,
        artifact_plan,
    );
    plan_owned = false;
    return artifact_job;
}

pub fn createPlan(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    program: *program_mod.Program,
    options: Options,
) !artifact_product.BackendArtifactPlan {
    var authored_plan = try program.createCheckedPlan(allocator, options.kernel_plan);
    defer authored_plan.deinit();

    const caps = try handle.queryCapabilities();
    const backend_kind = handle.backendKind() orelse caps.identity.backend;
    const format = options.format orelse
        artifact_product.defaultArtifactFormat(backend_kind) orelse {
        return error.UnsupportedOperation;
    };
    if (!caps.supportsArtifactFormat(format)) return error.UnsupportedArtifactFormat;
    const profile = try preparation.BackendTargetProfile.init(caps, backend_kind, format);

    const launch_resources = try createLaunchResourcePlan(caps, format, &authored_plan);
    var artifact_plan = artifact_product.BackendArtifactPlan.init(allocator, profile);
    errdefer artifact_plan.deinit();

    var compile_plan = try compilePlan(
        allocator,
        format,
        &authored_plan,
        program,
        launch_resources,
        options.disable_cpu_vectorization,
    );
    defer compile_plan.deinit(allocator);
    const required_dtypes = requiredDTypesForParams(authored_plan.params);
    var compile = try artifact_product.PlannedKernelCompileContract.init(
        allocator,
        .choir_kernel,
        .authored,
        format,
        compile_plan.entry_name,
        compile_plan.argument_count,
        required_dtypes,
        compile_plan.required_features,
        compile_plan.required_subgroup,
        null,
        compile_plan.payload,
    );
    var compile_owned = true;
    errdefer if (compile_owned) compile.deinit(allocator);

    const artifact = try createKernelArtifact(
        handle,
        format,
        &compile_plan,
        authored_plan.diagnostic_id,
        required_dtypes,
        compile_plan.required_features,
    );

    compile_owned = false;
    try artifact_plan.addStandaloneKernel(artifact, launch_resources, compile, .{
        .runtime_scalar_argument_count = compile_plan.runtime_scalar_argument_count,
        .static_arguments = compile_plan.static_arguments,
    });
    return artifact_plan;
}

fn requiredDTypesForParams(params: []const builder.Param) gpu.DTypeSet {
    var dtypes: gpu.DTypeSet = .{};
    for (params) |param| {
        switch (param) {
            .scalar => |dtype| dtypes.insert(dtype),
            .buffer => |buffer| dtypes.insert(buffer.dtype),
        }
    }
    return dtypes;
}

fn createLaunchResourcePlan(
    caps: gpu.BackendCapabilities,
    format: gpu.ArtifactFormat,
    authored_plan: *const plan_mod.Plan,
) gpu.BackendError!artifact_product.LaunchResourcePlan {
    const geometry = launchGeometry(authored_plan);
    try caps.validateLaunchGeometry(geometry);
    const element_count = try launchElementCount(geometry);

    var resources: artifact_product.LaunchResourcePlan = .{
        .format = format,
        .element_count = element_count,
        .geometry = geometry,
        .fixed_threadgroup = true,
        .candidate_count = 1,
    };
    resources.candidates[0] = .{
        .geometry = geometry,
    };
    return resources;
}

fn launchGeometry(authored_plan: *const plan_mod.Plan) gpu_abi.LaunchGeometry {
    return .{
        .grid = authored_plan.launch.grid,
        .threadgroup = authored_plan.launch.block,
    };
}

fn launchElementCount(geometry: gpu_abi.LaunchGeometry) gpu.BackendError!u64 {
    return try geometry.threadCount();
}

fn compilePlan(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    authored_plan: *const plan_mod.Plan,
    program: *const program_mod.Program,
    launch_resources: artifact_product.LaunchResourcePlan,
    disable_cpu_vectorization: bool,
) gpu.BackendError!CompilePlan {
    const module = program.kernelModule();
    const required_features = choir.backends.gpu.featureRequirementsForModule(module);
    const required_subgroup = choir.backends.gpu.subgroupRequirementsForModule(module);
    const static_arguments = try compileStaticArguments(allocator, format, launch_resources);
    errdefer if (static_arguments.len != 0) allocator.free(static_arguments);
    const compilation = try target.compileKernelForArtifactFormat(
        allocator,
        format,
        authored_plan.entry_name,
        module,
        compileOptions(format, launch_resources, disable_cpu_vectorization),
    );
    errdefer deinitCompilePayload(allocator, compilation.payload);
    return .{
        .entry_name = authored_plan.entry_name,
        .argument_count = try compileArgumentCount(format, authored_plan.argument_count),
        .payload = compilation.payload,
        .required_features = required_features,
        .required_subgroup = required_subgroup,
        .push_constants = compilation.push_constants,
        .runtime_scalar_argument_count = try runtimeScalarArgumentCount(authored_plan.params),
        .static_arguments = static_arguments,
    };
}

fn compileOptions(
    format: gpu.ArtifactFormat,
    launch_resources: artifact_product.LaunchResourcePlan,
    disable_cpu_vectorization: bool,
) target.CompileOptions {
    var options = target.compileOptionsForArtifactFormat(format, launch_resources.element_count);
    if (disable_cpu_vectorization) options.cpu_vector_width = null;
    return options;
}

fn runtimeScalarArgumentCount(params: []const builder.Param) gpu.BackendError!u32 {
    var count: u32 = 0;
    for (params) |param| {
        switch (param) {
            .scalar => count = std.math.add(u32, count, 1) catch return error.InvalidArtifact,
            .buffer => {},
        }
    }
    return count;
}

fn compileArgumentCount(format: gpu.ArtifactFormat, argument_count: u32) gpu.BackendError!u32 {
    if (!gpu.artifactFormatUsesHostLoopLaunch(format)) return argument_count;
    return gpu_abi.kernelArgumentCount(argument_count);
}

fn compileStaticArguments(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    launch_resources: artifact_product.LaunchResourcePlan,
) gpu.BackendError![]gpu_abi.ScalarArgument {
    if (!gpu.artifactFormatUsesHostLoopLaunch(format)) return &.{};
    return gpu_abi.launchShapeArguments(
        allocator,
        launch_resources.element_count,
        launch_resources.geometry,
    );
}

fn createKernelArtifact(
    handle: gpu.BackendHandle,
    format: gpu.ArtifactFormat,
    compile_plan: *const CompilePlan,
    diagnostic_id: []const u8,
    required_dtypes: gpu.DTypeSet,
    required_features: gpu_abi.Features,
) gpu.BackendError!gpu.KernelArtifact {
    return try handle.createArtifact(.{
        .kernel_name = compile_plan.entry_name,
        .requested_format = format,
        .argument_count = compile_plan.argument_count,
        .scalar_argument_count = compile_plan.runtime_scalar_argument_count + @as(
            u32,
            @intCast(compile_plan.static_arguments.len),
        ),
        .required_dtypes = required_dtypes,
        .required_features = required_features,
        .required_subgroup = compile_plan.required_subgroup,
        .push_constants = compile_plan.push_constants,
        .diagnostic_id = diagnostic_id,
        .payload = compile_plan.payload,
    });
}

fn deinitCompilePayload(allocator: std.mem.Allocator, payload: gpu.CompilePayload) void {
    switch (payload) {
        .bytes => |bytes| allocator.free(@constCast(bytes)),
        .words_u32 => |words| allocator.free(@constCast(words)),
        .text => |text| allocator.free(@constCast(text)),
        .none => {},
    }
}

const testing = std.testing;

const TestBackendState = struct {
    allocator: std.mem.Allocator,
    kind: gpu.BackendKind,
    format: gpu.ArtifactFormat,

    fn init(allocator: std.mem.Allocator, kind: gpu.BackendKind) TestBackendState {
        return .{
            .allocator = allocator,
            .kind = kind,
            .format = artifact_product.defaultArtifactFormat(kind).?,
        };
    }

    fn handle(self: *TestBackendState) gpu.BackendHandle {
        return .{
            .ptr = self,
            .vtable = &test_backend_vtable,
            .kind = self.kind,
        };
    }
};

fn testQueryCapabilities(ptr: *anyopaque) gpu.BackendError!gpu.BackendCapabilities {
    const state: *TestBackendState = @ptrCast(@alignCast(ptr));
    const subgroup_size: u32 = switch (state.kind) {
        .vulkan, .webgpu, .cpu => 0,
        else => 32,
    };
    const dtypes = switch (state.kind) {
        .cpu => gpu.DTypeSet.init(&.{ .i1, .i32, .u32, .i64, .u64, .f32, .f64 }),
        .webgpu => gpu.DTypeSet.init(&.{ .i1, .i32, .u32, .f32 }),
        else => gpu.DTypeSet.init(&.{ .i1, .i32, .u32, .f16, .f32 }),
    };
    return .{
        .identity = .{
            .backend = state.kind,
            .family = gpu.familyForBackendKind(state.kind),
            .name = "kernel-artifact-test",
        },
        .subgroup = if (subgroup_size == 0) .{} else .{
            .supported = true,
            .size_min = subgroup_size,
            .size_max = subgroup_size,
            .shuffle = true,
            .ballot = true,
            .vote = true,
            .arithmetic = true,
            .scan = state.kind == .cuda or state.kind == .metal,
        },
        .threadgroup = .{
            .max_threads = 1024,
            .max_blocks = .{ 65_535, 65_535, 65_535 },
            .max_threads_per_dim = .{ 1024, 1024, 64 },
            .max_grid_per_dim = .{ 65_535, 65_535, 65_535 },
        },
        .dtypes = dtypes,
        .artifact_formats = gpu.ArtifactFormatSet.init(&.{state.format}),
        .features = .{
            .atomic_i32 = state.kind != .webgpu,
            .atomic_u32 = state.kind != .webgpu,
            .atomic_index = state.kind != .webgpu,
            .atomic_f32_add_device = state.kind == .cuda or state.kind == .metal,
            .atomic_f32_add_shared = state.kind == .cuda,
            .dynamic_shared_memory = state.kind == .cuda,
        },
    };
}

fn runAuthoredCpuCopyKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
) !void {
    var builder_state = try program_mod.Builder.init(
        allocator,
        program_mod.Builder.Limits.testing,
        "authored_cpu_run_copy_f32",
        &.{
            builder.dynamicBuffer(.f32),
            builder.dynamicBuffer(.f32),
        },
    );
    errdefer builder_state.deinit();

    const axis = try builder_state.axis("i", 4);
    try builder_state.bind(axis, .thread_x);
    const src = builder_state.argument(0);
    const dst = builder_state.argument(1);
    const index = try builder_state.globalId(.x);
    const value = try builder_state.load(src, index);
    try builder_state.store(value, dst, index);
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact_plan = createPlan(
        allocator,
        handle,
        &program,
        .{ .format = format },
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer artifact_plan.deinit();

    try testing.expectEqual(format, artifact_plan.format);
    const planned = artifact_plan.kernels.items[0];
    try testing.expectEqual(format, planned.compile.format);
    try testing.expectEqual(@as(u32, 10), planned.artifact.argument_count);

    const loaded = try handle.loadArtifact(&planned.artifact);
    defer handle.destroyObject(loaded.id);

    const src_buffer = try handle.allocateBuffer(.{
        .byte_size = 4 * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = 4,
    });
    defer handle.destroyObject(src_buffer.id);

    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = 4 * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = 4,
    });
    defer handle.destroyObject(dst_buffer.id);

    const src_values = [_]f32{ 1.25, -2.5, 3.75, 8.0 };
    try handle.writeBuffer(.{
        .handle = src_buffer,
        .bytes = std.mem.sliceAsBytes(src_values[0..]),
    });

    const bindings = [_]gpu.BufferBinding{
        .{
            .handle = src_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = src_buffer.byte_size,
        },
        .{
            .handle = dst_buffer,
            .access = .write_only,
            .ownership = .backend,
            .byte_size = dst_buffer.byte_size,
        },
    };
    try handle.launch(.{
        .artifact = &planned.artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = planned.static_arguments,
        .geometry = planned.launch_resources.geometry,
    });

    var dst_values = @as([4]f32, @splat(0.0));
    try handle.readBuffer(.{
        .handle = dst_buffer,
        .bytes = std.mem.sliceAsBytes(dst_values[0..]),
    });
    try testing.expectEqualSlices(f32, src_values[0..], dst_values[0..]);
}

fn runAutomaticScalarAddKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    comptime Element: type,
    comptime dtype: DType,
    entry_name: []const u8,
    comptime extent: usize,
    lhs_values: [extent]Element,
    rhs_values: [extent]Element,
) !void {
    var builder_state = try program_mod.Builder.init(
        allocator,
        program_mod.Builder.Limits.testing,
        entry_name,
        &.{
            builder.dynamicBuffer(dtype),
            builder.dynamicBuffer(dtype),
            builder.dynamicBuffer(dtype),
        },
    );
    errdefer builder_state.deinit();

    const axis = try builder_state.axis("i", @intCast(extent));
    try builder_state.bind(axis, .thread_x);
    const dst = builder_state.argument(0);
    const lhs = builder_state.argument(1);
    const rhs = builder_state.argument(2);
    const index = try builder_state.globalId(.x);
    const lhs_value = try builder_state.load(lhs, index);
    const rhs_value = try builder_state.load(rhs, index);
    const sum = try builder_state.add(lhs_value, rhs_value);
    try builder_state.store(sum, dst, index);
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    var expected_values = @as([extent]Element, @splat(@as(Element, 0)));
    try program.runCpu(allocator, &.{
        accy_root.kernel.argumentBuffer(Element, expected_values[0..]),
        accy_root.kernel.argumentBuffer(Element, @constCast(lhs_values[0..])),
        accy_root.kernel.argumentBuffer(Element, @constCast(rhs_values[0..])),
    });

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact_plan = createPlan(
        allocator,
        handle,
        &program,
        .{ .format = format },
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer artifact_plan.deinit();

    const planned = artifact_plan.kernels.items[0];
    try testing.expectEqual(format, planned.artifact.format);
    try testing.expectEqual(@as(u32, 11), planned.artifact.argument_count);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        planned.static_arguments.len,
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 0 }, planned.static_arguments[0]);
    try testing.expectEqual(
        gpu_abi.ScalarArgument{ .u32 = @intCast(extent) },
        planned.static_arguments[1],
    );

    const loaded = try handle.loadArtifact(&planned.artifact);
    defer handle.destroyObject(loaded.id);

    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(Element),
        .alignment = @alignOf(Element),
        .dtype = dtype,
        .element_count = extent,
    });
    defer handle.destroyObject(dst_buffer.id);

    const lhs_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(Element),
        .alignment = @alignOf(Element),
        .dtype = dtype,
        .element_count = extent,
    });
    defer handle.destroyObject(lhs_buffer.id);

    const rhs_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(Element),
        .alignment = @alignOf(Element),
        .dtype = dtype,
        .element_count = extent,
    });
    defer handle.destroyObject(rhs_buffer.id);

    try handle.writeBuffer(.{
        .handle = lhs_buffer,
        .bytes = std.mem.sliceAsBytes(lhs_values[0..]),
    });
    try handle.writeBuffer(.{
        .handle = rhs_buffer,
        .bytes = std.mem.sliceAsBytes(rhs_values[0..]),
    });

    const bindings = [_]gpu.BufferBinding{
        .{
            .handle = dst_buffer,
            .access = .write_only,
            .ownership = .backend,
            .byte_size = dst_buffer.byte_size,
        },
        .{
            .handle = lhs_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = lhs_buffer.byte_size,
        },
        .{
            .handle = rhs_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = rhs_buffer.byte_size,
        },
    };
    try handle.launch(.{
        .artifact = &planned.artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = planned.static_arguments,
        .geometry = planned.launch_resources.geometry,
    });

    var actual_values = @as([extent]Element, @splat(@as(Element, 0)));
    try handle.readBuffer(.{
        .handle = dst_buffer,
        .bytes = std.mem.sliceAsBytes(actual_values[0..]),
    });
    try testing.expectEqualSlices(Element, expected_values[0..], actual_values[0..]);
}

fn runAutomaticScalarAffineKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    entry_name: []const u8,
    lhs_values: [6]f32,
    rhs_values: [6]f32,
    scale: f32,
) !void {
    const extent = 6;
    var builder_state = try program_mod.Builder.init(
        allocator,
        program_mod.Builder.Limits.testing,
        entry_name,
        &.{
            builder.dynamicBuffer(.f32),
            builder.scalar(.f32),
            builder.dynamicBuffer(.f32),
            builder.dynamicBuffer(.f32),
        },
    );
    errdefer builder_state.deinit();

    const axis = try builder_state.axis("i", extent);
    try builder_state.bind(axis, .thread_x);
    const dst = builder_state.argument(0);
    const scale_arg = builder_state.argument(1);
    const lhs = builder_state.argument(2);
    const rhs = builder_state.argument(3);
    const index = try builder_state.globalId(.x);
    const lhs_value = try builder_state.load(lhs, index);
    const rhs_value = try builder_state.load(rhs, index);
    const scaled = try builder_state.mul(lhs_value, scale_arg);
    const value = try builder_state.add(scaled, rhs_value);
    try builder_state.store(value, dst, index);
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    var expected_values = @as([extent]f32, @splat(@as(f32, 0)));
    try program.runCpu(allocator, &.{
        accy_root.kernel.argumentBuffer(f32, expected_values[0..]),
        accy_root.kernel.argumentF32(scale),
        accy_root.kernel.argumentBuffer(f32, @constCast(lhs_values[0..])),
        accy_root.kernel.argumentBuffer(f32, @constCast(rhs_values[0..])),
    });

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact_plan = createPlan(
        allocator,
        handle,
        &program,
        .{ .format = format },
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer artifact_plan.deinit();

    const planned = artifact_plan.kernels.items[0];
    try testing.expectEqual(format, planned.artifact.format);
    try testing.expectEqual(@as(u32, 12), planned.artifact.argument_count);
    try testing.expectEqual(@as(u32, 1), planned.runtime_scalar_argument_count);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        planned.static_arguments.len,
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 0 }, planned.static_arguments[0]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = extent }, planned.static_arguments[1]);

    const loaded = try handle.loadArtifact(&planned.artifact);
    defer handle.destroyObject(loaded.id);

    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = extent,
    });
    defer handle.destroyObject(dst_buffer.id);

    const lhs_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = extent,
    });
    defer handle.destroyObject(lhs_buffer.id);

    const rhs_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = extent,
    });
    defer handle.destroyObject(rhs_buffer.id);

    try handle.writeBuffer(.{
        .handle = lhs_buffer,
        .bytes = std.mem.sliceAsBytes(lhs_values[0..]),
    });
    try handle.writeBuffer(.{
        .handle = rhs_buffer,
        .bytes = std.mem.sliceAsBytes(rhs_values[0..]),
    });

    const bindings = [_]gpu.BufferBinding{
        .{
            .handle = dst_buffer,
            .access = .write_only,
            .ownership = .backend,
            .byte_size = dst_buffer.byte_size,
        },
        .{
            .handle = lhs_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = lhs_buffer.byte_size,
        },
        .{
            .handle = rhs_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = rhs_buffer.byte_size,
        },
    };
    var scalar_arguments: [
        1 +
            gpu_abi.launch_shape_argument_count
    ]gpu_abi.ScalarArgument = undefined;
    scalar_arguments[0] = .{ .f32 = scale };
    @memcpy(scalar_arguments[1..][0..planned.static_arguments.len], planned.static_arguments);
    try handle.launch(.{
        .artifact = &planned.artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = scalar_arguments[0 .. 1 + planned.static_arguments.len],
        .geometry = planned.launch_resources.geometry,
    });

    var actual_values = @as([extent]f32, @splat(@as(f32, 0)));
    try handle.readBuffer(.{
        .handle = dst_buffer,
        .bytes = std.mem.sliceAsBytes(actual_values[0..]),
    });
    try testing.expectEqualSlices(f32, expected_values[0..], actual_values[0..]);
}

const CpuVectorBinaryOp = enum {
    add,
    sub,
    mul,
    umulhi,
    div,
    min,
    max,
    band,
    bor,
    bxor,
    popcount,
    shl,
    shr,
    ushr,
    select_true,
    select_false,
};

fn CpuVectorBinaryContextType(comptime dtype: DType) type {
    return struct {
        dst: program_mod.BufferView(dtype),
        lhs_mem: program_mod.BufferView(dtype),
        rhs_mem: program_mod.BufferView(dtype),
        op: CpuVectorBinaryOp,

        const Self = @This();

        fn run(
            k: *program_mod.Builder,
            index: program_mod.VectorIndex1D,
            ctx: Self,
        ) !void {
            const lhs = try ctx.lhs_mem.loadVector(k, index, index.width);
            const rhs = try ctx.rhs_mem.loadVector(k, index, index.width);
            const output = switch (ctx.op) {
                .add => try k.add(lhs, rhs),
                .sub => try k.sub(lhs, rhs),
                .mul => try k.mul(lhs, rhs),
                .umulhi => try k.umulhi(lhs, rhs),
                .div => try k.div(lhs, rhs),
                .min => try k.min(lhs, rhs),
                .max => try k.max(lhs, rhs),
                .band => try k.and_(lhs, rhs),
                .bor => try k.or_(lhs, rhs),
                .bxor => try k.xor(lhs, rhs),
                .popcount => try k.popcount(lhs),
                .shl => try k.shl(lhs, rhs),
                .shr => try k.shr(lhs, rhs),
                .ushr => try k.ushr(lhs, rhs),
                .select_true => value: {
                    const condition = try k.constantBool(true);
                    break :value try k.select(condition, lhs, rhs);
                },
                .select_false => value: {
                    const condition = try k.constantBool(false);
                    break :value try k.select(condition, lhs, rhs);
                },
            };
            try ctx.dst.storeVector(k, output, index);
        }
    };
}

fn runAuthoredCpuVectorBinaryKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    op_kind: CpuVectorBinaryOp,
    comptime Element: type,
    comptime dtype: DType,
    entry_name: []const u8,
    comptime extent: usize,
    comptime width: u32,
    comptime threads_per_block: u32,
    lhs_values: [extent]Element,
    rhs_values: [extent]Element,
    expected_values: [extent]Element,
) !void {
    var builder_state = try program_mod.Builder.init(
        allocator,
        program_mod.Builder.Limits.testing,
        entry_name,
        &.{
            builder.dynamicBuffer(dtype),
            builder.dynamicBuffer(dtype),
            builder.dynamicBuffer(dtype),
        },
    );
    errdefer builder_state.deinit();

    const BinaryContext: type = CpuVectorBinaryContextType(dtype);
    const context: BinaryContext = .{
        .dst = builder_state.bufferArgument(dtype, 0),
        .lhs_mem = builder_state.bufferArgument(dtype, 1),
        .rhs_mem = builder_state.bufferArgument(dtype, 2),
        .op = op_kind,
    };
    _ = try builder_state.forEachVector1D(
        "i",
        extent,
        width,
        threads_per_block,
        context,
        BinaryContext.run,
    );
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    try runAuthoredCpuVectorThreeBufferProgram(
        allocator,
        format,
        &program,
        Element,
        dtype,
        extent,
        width,
        threads_per_block,
        lhs_values,
        rhs_values,
        expected_values,
    );
}

fn CpuVectorCompareContextType(comptime dtype: DType) type {
    return struct {
        dst: program_mod.BufferView(dtype),
        lhs_mem: program_mod.BufferView(dtype),
        rhs_mem: program_mod.BufferView(dtype),
        predicate: builder.Compare,

        const Self = @This();

        fn run(
            k: *program_mod.Builder,
            index: program_mod.VectorIndex1D,
            ctx: Self,
        ) !void {
            const lhs = try ctx.lhs_mem.loadVector(k, index, index.width);
            const rhs = try ctx.rhs_mem.loadVector(k, index, index.width);
            const output = try k.compare(ctx.predicate, lhs, rhs);
            try ctx.dst.storeVector(k, output, index);
        }
    };
}

fn runAuthoredCpuVectorCompareKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    predicate: builder.Compare,
    comptime Element: type,
    comptime dtype: DType,
    entry_name: []const u8,
    comptime extent: usize,
    comptime width: u32,
    comptime threads_per_block: u32,
    lhs_values: [extent]Element,
    rhs_values: [extent]Element,
    expected_values: [extent]Element,
) !void {
    var builder_state = try program_mod.Builder.init(
        allocator,
        program_mod.Builder.Limits.testing,
        entry_name,
        &.{
            builder.dynamicBuffer(dtype),
            builder.dynamicBuffer(dtype),
            builder.dynamicBuffer(dtype),
        },
    );
    errdefer builder_state.deinit();

    const CompareContext: type = CpuVectorCompareContextType(dtype);
    const context: CompareContext = .{
        .dst = builder_state.bufferArgument(dtype, 0),
        .lhs_mem = builder_state.bufferArgument(dtype, 1),
        .rhs_mem = builder_state.bufferArgument(dtype, 2),
        .predicate = predicate,
    };
    _ = try builder_state.forEachVector1D(
        "i",
        extent,
        width,
        threads_per_block,
        context,
        CompareContext.run,
    );
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    try runAuthoredCpuVectorThreeBufferProgram(
        allocator,
        format,
        &program,
        Element,
        dtype,
        extent,
        width,
        threads_per_block,
        lhs_values,
        rhs_values,
        expected_values,
    );
}

fn runAuthoredCpuVectorThreeBufferProgram(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    program: *program_mod.Program,
    comptime Element: type,
    comptime dtype: DType,
    comptime extent: usize,
    comptime width: u32,
    comptime threads_per_block: u32,
    lhs_values: [extent]Element,
    rhs_values: [extent]Element,
    expected_values: [extent]Element,
) !void {
    var schedule_snapshot = try program.scheduleSnapshot(allocator);
    defer schedule_snapshot.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), schedule_snapshot.allAxes().len);
    try testing.expectEqual(@as(?u32, width), schedule_snapshot.allAxes()[0].vector_width);
    const launch = try schedule_snapshot.launch();
    try testing.expectEqual(@as(u32, threads_per_block), launch.block[0]);

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact_plan = createPlan(
        allocator,
        handle,
        program,
        .{ .format = format },
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer artifact_plan.deinit();

    const planned = artifact_plan.kernels.items[0];
    const packet_count: u32 = @intCast(extent / width);
    try testing.expectEqual(format, planned.artifact.format);
    try testing.expectEqual(@as(u32, 11), planned.artifact.argument_count);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        planned.static_arguments.len,
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 0 }, planned.static_arguments[0]);
    try testing.expectEqual(
        gpu_abi.ScalarArgument{ .u32 = packet_count },
        planned.static_arguments[1],
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[2]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[3]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[4]);
    try testing.expectEqual(
        gpu_abi.ScalarArgument{ .u32 = threads_per_block },
        planned.static_arguments[5],
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[6]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[7]);

    const loaded = try handle.loadArtifact(&planned.artifact);
    defer handle.destroyObject(loaded.id);

    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(Element),
        .alignment = @alignOf(Element),
        .dtype = dtype,
        .element_count = extent,
    });
    defer handle.destroyObject(dst_buffer.id);

    const lhs_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(Element),
        .alignment = @alignOf(Element),
        .dtype = dtype,
        .element_count = extent,
    });
    defer handle.destroyObject(lhs_buffer.id);

    const rhs_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(Element),
        .alignment = @alignOf(Element),
        .dtype = dtype,
        .element_count = extent,
    });
    defer handle.destroyObject(rhs_buffer.id);

    try handle.writeBuffer(.{
        .handle = lhs_buffer,
        .bytes = std.mem.sliceAsBytes(lhs_values[0..]),
    });
    try handle.writeBuffer(.{
        .handle = rhs_buffer,
        .bytes = std.mem.sliceAsBytes(rhs_values[0..]),
    });

    const bindings = [_]gpu.BufferBinding{
        .{
            .handle = dst_buffer,
            .access = .write_only,
            .ownership = .backend,
            .byte_size = dst_buffer.byte_size,
        },
        .{
            .handle = lhs_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = lhs_buffer.byte_size,
        },
        .{
            .handle = rhs_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = rhs_buffer.byte_size,
        },
    };
    try handle.launch(.{
        .artifact = &planned.artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = planned.static_arguments,
        .geometry = planned.launch_resources.geometry,
    });

    var dst_values = @as([extent]Element, @splat(@as(Element, 0)));
    try handle.readBuffer(.{
        .handle = dst_buffer,
        .bytes = std.mem.sliceAsBytes(dst_values[0..]),
    });
    try testing.expectEqualSlices(Element, expected_values[0..], dst_values[0..]);
}

fn CpuVectorBiasContextType(comptime dtype: DType) type {
    return struct {
        dst: program_mod.BufferView(dtype),
        bias: builder.Value,
        src_mem: program_mod.BufferView(dtype),

        const Self = @This();

        fn run(
            k: *program_mod.Builder,
            index: program_mod.VectorIndex1D,
            ctx: Self,
        ) !void {
            const src = try ctx.src_mem.loadVector(k, index, index.width);
            const bias = try k.splatVector(ctx.bias, index.width);
            const sum = try k.add(src, bias);
            try ctx.dst.storeVector(k, sum, index);
        }
    };
}

fn runAuthoredCpuVectorBiasAddKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    comptime Element: type,
    comptime dtype: DType,
    entry_name: []const u8,
    comptime extent: usize,
    comptime width: u32,
    comptime threads_per_block: u32,
    scalar_argument: gpu_abi.ScalarArgument,
    src_values: [extent]Element,
    expected_values: [extent]Element,
) !void {
    var builder_state = try program_mod.Builder.init(
        allocator,
        program_mod.Builder.Limits.testing,
        entry_name,
        &.{
            builder.dynamicBuffer(dtype),
            builder.scalar(dtype),
            builder.dynamicBuffer(dtype),
        },
    );
    errdefer builder_state.deinit();

    const BiasContext: type = CpuVectorBiasContextType(dtype);
    const context: BiasContext = .{
        .dst = builder_state.bufferArgument(dtype, 0),
        .bias = builder_state.argument(1),
        .src_mem = builder_state.bufferArgument(dtype, 2),
    };
    _ = try builder_state.forEachVector1D(
        "i",
        extent,
        width,
        threads_per_block,
        context,
        BiasContext.run,
    );
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    var schedule_snapshot = try program.scheduleSnapshot(allocator);
    defer schedule_snapshot.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), schedule_snapshot.allAxes().len);
    try testing.expectEqual(@as(?u32, width), schedule_snapshot.allAxes()[0].vector_width);
    const launch = try schedule_snapshot.launch();
    try testing.expectEqual(@as(u32, threads_per_block), launch.block[0]);

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact_plan = createPlan(
        allocator,
        handle,
        &program,
        .{ .format = format },
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer artifact_plan.deinit();

    const planned = artifact_plan.kernels.items[0];
    const packet_count: u32 = @intCast(extent / width);
    try testing.expectEqual(format, planned.artifact.format);
    try testing.expectEqual(@as(u32, 11), planned.artifact.argument_count);
    try testing.expectEqual(@as(u32, 1), planned.runtime_scalar_argument_count);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        planned.static_arguments.len,
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 0 }, planned.static_arguments[0]);
    try testing.expectEqual(
        gpu_abi.ScalarArgument{ .u32 = packet_count },
        planned.static_arguments[1],
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[2]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[3]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[4]);
    try testing.expectEqual(
        gpu_abi.ScalarArgument{ .u32 = threads_per_block },
        planned.static_arguments[5],
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[6]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[7]);

    const loaded = try handle.loadArtifact(&planned.artifact);
    defer handle.destroyObject(loaded.id);

    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(Element),
        .alignment = @alignOf(Element),
        .dtype = dtype,
        .element_count = extent,
    });
    defer handle.destroyObject(dst_buffer.id);

    const src_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(Element),
        .alignment = @alignOf(Element),
        .dtype = dtype,
        .element_count = extent,
    });
    defer handle.destroyObject(src_buffer.id);

    try handle.writeBuffer(.{
        .handle = src_buffer,
        .bytes = std.mem.sliceAsBytes(src_values[0..]),
    });

    const bindings = [_]gpu.BufferBinding{
        .{
            .handle = dst_buffer,
            .access = .write_only,
            .ownership = .backend,
            .byte_size = dst_buffer.byte_size,
        },
        .{
            .handle = src_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = src_buffer.byte_size,
        },
    };
    var scalar_arguments: [
        1 +
            gpu_abi.launch_shape_argument_count
    ]gpu_abi.ScalarArgument = undefined;
    scalar_arguments[0] = scalar_argument;
    @memcpy(scalar_arguments[1..][0..planned.static_arguments.len], planned.static_arguments);
    try handle.launch(.{
        .artifact = &planned.artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = scalar_arguments[0 .. 1 + planned.static_arguments.len],
        .geometry = planned.launch_resources.geometry,
    });

    var dst_values = @as([extent]Element, @splat(@as(Element, 0)));
    try handle.readBuffer(.{
        .handle = dst_buffer,
        .bytes = std.mem.sliceAsBytes(dst_values[0..]),
    });
    try testing.expectEqualSlices(Element, expected_values[0..], dst_values[0..]);
}

const CpuFloatUnaryOp = enum {
    floor,
};

const CpuFloatUnaryContext = struct {
    dst: program_mod.BufferView(.f32),
    src_mem: program_mod.BufferView(.f32),
    op: CpuFloatUnaryOp,

    fn run(
        k: *program_mod.Builder,
        index: program_mod.Index1D,
        ctx: CpuFloatUnaryContext,
    ) !void {
        const src = try ctx.src_mem.load(k, index);
        const output = switch (ctx.op) {
            .floor => try src.floor(k),
        };
        try ctx.dst.store(k, output, index);
    }
};

fn runAuthoredCpuFloatUnaryKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    op_kind: CpuFloatUnaryOp,
    entry_name: []const u8,
    src_values: [4]f32,
    expected_values: [4]f32,
) !void {
    const extent: usize = 4;
    const threads_per_block: u32 = 4;

    var builder_state = try program_mod.Builder.init(
        allocator,
        program_mod.Builder.Limits.testing,
        entry_name,
        &.{
            builder.dynamicBuffer(.f32),
            builder.dynamicBuffer(.f32),
        },
    );
    errdefer builder_state.deinit();

    const context: CpuFloatUnaryContext = .{
        .dst = builder_state.bufferArgument(.f32, 0),
        .src_mem = builder_state.bufferArgument(.f32, 1),
        .op = op_kind,
    };
    _ = try builder_state.forEach1D(
        "i",
        extent,
        threads_per_block,
        context,
        CpuFloatUnaryContext.run,
    );
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact_plan = createPlan(
        allocator,
        handle,
        &program,
        .{ .format = format },
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer artifact_plan.deinit();

    const planned = artifact_plan.kernels.items[0];
    try testing.expectEqual(format, planned.artifact.format);
    try testing.expectEqual(@as(u32, 10), planned.artifact.argument_count);
    try testing.expectEqual(@as(u32, 0), planned.runtime_scalar_argument_count);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        planned.static_arguments.len,
    );

    const loaded = try handle.loadArtifact(&planned.artifact);
    defer handle.destroyObject(loaded.id);

    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = extent,
    });
    defer handle.destroyObject(dst_buffer.id);

    const src_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = extent,
    });
    defer handle.destroyObject(src_buffer.id);

    try handle.writeBuffer(.{
        .handle = src_buffer,
        .bytes = std.mem.sliceAsBytes(src_values[0..]),
    });

    const bindings = [_]gpu.BufferBinding{
        .{
            .handle = dst_buffer,
            .access = .write_only,
            .ownership = .backend,
            .byte_size = dst_buffer.byte_size,
        },
        .{
            .handle = src_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = src_buffer.byte_size,
        },
    };
    try handle.launch(.{
        .artifact = &planned.artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = planned.static_arguments,
        .geometry = planned.launch_resources.geometry,
    });

    var dst_values = @as([extent]f32, @splat(0.0));
    try handle.readBuffer(.{
        .handle = dst_buffer,
        .bytes = std.mem.sliceAsBytes(dst_values[0..]),
    });
    try testing.expectEqualSlices(f32, expected_values[0..], dst_values[0..]);
}

const CpuVectorUnaryOp = enum {
    neg,
    bnot,
    shuffle_reverse,
    shl_const_3,
};

const CpuVectorUnaryU32Context = struct {
    dst: program_mod.BufferView(.u32),
    src_mem: program_mod.BufferView(.u32),
    op: CpuVectorUnaryOp,

    fn run(
        k: *program_mod.Builder,
        index: program_mod.VectorIndex1D,
        ctx: CpuVectorUnaryU32Context,
    ) !void {
        const src = try ctx.src_mem.loadVector(k, index, index.width);
        const output = switch (ctx.op) {
            .neg => try k.neg(src),
            .bnot => try k.not(src),
            .shuffle_reverse => value: {
                const indices = [_]i64{ 3, 2, 1, 0 };
                break :value try k.shuffleVector(src, indices[0..]);
            },
            .shl_const_3 => value: {
                const shift_scalar = try k.constantInt(.u32, 3);
                const shift = try k.splatVector(shift_scalar, index.width);
                break :value try k.shl(src, shift);
            },
        };
        try ctx.dst.storeVector(k, output, index);
    }
};

fn runAuthoredCpuVectorUnaryU32Kernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    op_kind: CpuVectorUnaryOp,
    entry_name: []const u8,
    src_values: [8]u32,
    expected_values: [8]u32,
) !void {
    const extent: usize = 8;
    const width: u32 = 4;
    const threads_per_block: u32 = 2;

    var builder_state = try program_mod.Builder.init(
        allocator,
        program_mod.Builder.Limits.testing,
        entry_name,
        &.{
            builder.dynamicBuffer(.u32),
            builder.dynamicBuffer(.u32),
        },
    );
    errdefer builder_state.deinit();

    const context: CpuVectorUnaryU32Context = .{
        .dst = builder_state.bufferArgument(.u32, 0),
        .src_mem = builder_state.bufferArgument(.u32, 1),
        .op = op_kind,
    };
    _ = try builder_state.forEachVector1D(
        "i",
        extent,
        width,
        threads_per_block,
        context,
        CpuVectorUnaryU32Context.run,
    );
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    var schedule_snapshot = try program.scheduleSnapshot(allocator);
    defer schedule_snapshot.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), schedule_snapshot.allAxes().len);
    try testing.expectEqual(@as(?u32, width), schedule_snapshot.allAxes()[0].vector_width);
    const launch = try schedule_snapshot.launch();
    try testing.expectEqual(@as(u32, threads_per_block), launch.block[0]);

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact_plan = createPlan(
        allocator,
        handle,
        &program,
        .{ .format = format },
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer artifact_plan.deinit();

    const planned = artifact_plan.kernels.items[0];
    const packet_count: u32 = @intCast(extent / width);
    try testing.expectEqual(format, planned.artifact.format);
    try testing.expectEqual(@as(u32, 10), planned.artifact.argument_count);
    try testing.expectEqual(@as(u32, 0), planned.runtime_scalar_argument_count);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        planned.static_arguments.len,
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 0 }, planned.static_arguments[0]);
    try testing.expectEqual(
        gpu_abi.ScalarArgument{ .u32 = packet_count },
        planned.static_arguments[1],
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[2]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[3]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[4]);
    try testing.expectEqual(
        gpu_abi.ScalarArgument{ .u32 = threads_per_block },
        planned.static_arguments[5],
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[6]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[7]);

    const loaded = try handle.loadArtifact(&planned.artifact);
    defer handle.destroyObject(loaded.id);

    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(u32),
        .alignment = @alignOf(u32),
        .dtype = .u32,
        .element_count = extent,
    });
    defer handle.destroyObject(dst_buffer.id);

    const src_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(u32),
        .alignment = @alignOf(u32),
        .dtype = .u32,
        .element_count = extent,
    });
    defer handle.destroyObject(src_buffer.id);

    try handle.writeBuffer(.{
        .handle = src_buffer,
        .bytes = std.mem.sliceAsBytes(src_values[0..]),
    });

    const bindings = [_]gpu.BufferBinding{
        .{
            .handle = dst_buffer,
            .access = .write_only,
            .ownership = .backend,
            .byte_size = dst_buffer.byte_size,
        },
        .{
            .handle = src_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = src_buffer.byte_size,
        },
    };
    try handle.launch(.{
        .artifact = &planned.artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = planned.static_arguments,
        .geometry = planned.launch_resources.geometry,
    });

    var dst_values = @as([extent]u32, @splat(0));
    try handle.readBuffer(.{
        .handle = dst_buffer,
        .bytes = std.mem.sliceAsBytes(dst_values[0..]),
    });
    try testing.expectEqualSlices(u32, expected_values[0..], dst_values[0..]);
}

const CpuIntegerScalarOp = enum {
    add,
    max,
    div,
    umulhi,
    popcount,
};

fn runAuthoredCpuIntegerScalarKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    comptime Element: type,
    comptime dtype: DType,
    entry_name: []const u8,
    scalar_argument: gpu_abi.ScalarArgument,
    src_values: [4]Element,
    expected_values: [4]Element,
) !void {
    try runAuthoredCpuIntegerScalarOpKernel(
        allocator,
        format,
        .add,
        Element,
        dtype,
        entry_name,
        scalar_argument,
        src_values,
        expected_values,
    );
}

fn runAuthoredCpuIntegerScalarOpKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    op: CpuIntegerScalarOp,
    comptime Element: type,
    comptime dtype: DType,
    entry_name: []const u8,
    scalar_argument: gpu_abi.ScalarArgument,
    src_values: [4]Element,
    expected_values: [4]Element,
) !void {
    var builder_state = try program_mod.Builder.init(
        allocator,
        program_mod.Builder.Limits.testing,
        entry_name,
        &.{
            builder.dynamicBuffer(dtype),
            builder.scalar(dtype),
            builder.dynamicBuffer(dtype),
        },
    );
    errdefer builder_state.deinit();

    const axis = try builder_state.axis("i", 4);
    try builder_state.bind(axis, .thread_x);
    const dst = builder_state.argument(0);
    const bias = builder_state.argument(1);
    const src = builder_state.argument(2);
    const index = try builder_state.globalId(.x);
    const value = try builder_state.load(src, index);
    const adjusted = switch (op) {
        .add => try builder_state.add(value, bias),
        .max => try builder_state.max(value, bias),
        .div => try builder_state.div(value, bias),
        .umulhi => try builder_state.umulhi(value, bias),
        .popcount => try builder_state.popcount(value),
    };
    try builder_state.store(adjusted, dst, index);
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact_plan = createPlan(
        allocator,
        handle,
        &program,
        .{ .format = format },
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer artifact_plan.deinit();

    const planned = artifact_plan.kernels.items[0];
    try testing.expectEqual(format, planned.artifact.format);
    try testing.expectEqual(@as(u32, 11), planned.artifact.argument_count);
    try testing.expectEqual(@as(u32, 1), planned.runtime_scalar_argument_count);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        planned.static_arguments.len,
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 0 }, planned.static_arguments[0]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 4 }, planned.static_arguments[1]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[2]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[3]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[4]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 4 }, planned.static_arguments[5]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[6]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[7]);

    const loaded = try handle.loadArtifact(&planned.artifact);
    defer handle.destroyObject(loaded.id);

    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = 4 * @sizeOf(Element),
        .alignment = @alignOf(Element),
        .dtype = dtype,
        .element_count = 4,
    });
    defer handle.destroyObject(dst_buffer.id);

    const src_buffer = try handle.allocateBuffer(.{
        .byte_size = 4 * @sizeOf(Element),
        .alignment = @alignOf(Element),
        .dtype = dtype,
        .element_count = 4,
    });
    defer handle.destroyObject(src_buffer.id);

    try handle.writeBuffer(.{
        .handle = src_buffer,
        .bytes = std.mem.sliceAsBytes(src_values[0..]),
    });

    const bindings = [_]gpu.BufferBinding{
        .{
            .handle = dst_buffer,
            .access = .write_only,
            .ownership = .backend,
            .byte_size = dst_buffer.byte_size,
        },
        .{
            .handle = src_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = src_buffer.byte_size,
        },
    };
    var scalar_arguments: [
        1 +
            gpu_abi.launch_shape_argument_count
    ]gpu_abi.ScalarArgument = undefined;
    scalar_arguments[0] = scalar_argument;
    @memcpy(scalar_arguments[1..][0..planned.static_arguments.len], planned.static_arguments);
    try handle.launch(.{
        .artifact = &planned.artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = scalar_arguments[0 .. 1 + planned.static_arguments.len],
        .geometry = planned.launch_resources.geometry,
    });

    var dst_values = @as([4]Element, @splat(@as(Element, 0)));
    try handle.readBuffer(.{
        .handle = dst_buffer,
        .bytes = std.mem.sliceAsBytes(dst_values[0..]),
    });
    try testing.expectEqualSlices(Element, expected_values[0..], dst_values[0..]);
}

fn runAuthoredCpuCastKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    comptime SrcElement: type,
    comptime src_dtype: DType,
    comptime DstElement: type,
    comptime dst_dtype: DType,
    entry_name: []const u8,
    src_values: [4]SrcElement,
    expected_values: [4]DstElement,
) !void {
    var builder_state = try program_mod.Builder.init(
        allocator,
        program_mod.Builder.Limits.testing,
        entry_name,
        &.{
            builder.dynamicBuffer(dst_dtype),
            builder.dynamicBuffer(src_dtype),
        },
    );
    errdefer builder_state.deinit();

    const axis = try builder_state.axis("i", 4);
    try builder_state.bind(axis, .thread_x);
    const dst = builder_state.argument(0);
    const src = builder_state.argument(1);
    const index = try builder_state.globalId(.x);
    const value = try builder_state.load(src, index);
    const casted = try builder_state.cast(value, dst_dtype);
    try builder_state.store(casted, dst, index);
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact_plan = createPlan(
        allocator,
        handle,
        &program,
        .{ .format = format },
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer artifact_plan.deinit();

    const planned = artifact_plan.kernels.items[0];
    try testing.expectEqual(format, planned.artifact.format);
    try testing.expectEqual(@as(u32, 10), planned.artifact.argument_count);
    try testing.expectEqual(@as(u32, 0), planned.runtime_scalar_argument_count);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        planned.static_arguments.len,
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 0 }, planned.static_arguments[0]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 4 }, planned.static_arguments[1]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[2]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[3]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[4]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 4 }, planned.static_arguments[5]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[6]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[7]);

    const loaded = try handle.loadArtifact(&planned.artifact);
    defer handle.destroyObject(loaded.id);

    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = 4 * @sizeOf(DstElement),
        .alignment = @alignOf(DstElement),
        .dtype = dst_dtype,
        .element_count = 4,
    });
    defer handle.destroyObject(dst_buffer.id);

    const src_buffer = try handle.allocateBuffer(.{
        .byte_size = 4 * @sizeOf(SrcElement),
        .alignment = @alignOf(SrcElement),
        .dtype = src_dtype,
        .element_count = 4,
    });
    defer handle.destroyObject(src_buffer.id);

    try handle.writeBuffer(.{
        .handle = src_buffer,
        .bytes = std.mem.sliceAsBytes(src_values[0..]),
    });

    const bindings = [_]gpu.BufferBinding{
        .{
            .handle = dst_buffer,
            .access = .write_only,
            .ownership = .backend,
            .byte_size = dst_buffer.byte_size,
        },
        .{
            .handle = src_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = src_buffer.byte_size,
        },
    };
    try handle.launch(.{
        .artifact = &planned.artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = planned.static_arguments,
        .geometry = planned.launch_resources.geometry,
    });

    var dst_values = @as([4]DstElement, @splat(@as(DstElement, 0)));
    try handle.readBuffer(.{
        .handle = dst_buffer,
        .bytes = std.mem.sliceAsBytes(dst_values[0..]),
    });
    try testing.expectEqualSlices(DstElement, expected_values[0..], dst_values[0..]);
}

fn runAuthoredCpuFloatScalarKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
    comptime Element: type,
    comptime dtype: DType,
    entry_name: []const u8,
    scale: Element,
    src_values: [4]Element,
    expected_values: [4]Element,
) !void {
    var builder_state = try program_mod.Builder.init(
        allocator,
        program_mod.Builder.Limits.testing,
        entry_name,
        &.{
            builder.dynamicBuffer(dtype),
            builder.scalar(dtype),
            builder.dynamicBuffer(dtype),
        },
    );
    errdefer builder_state.deinit();

    const axis = try builder_state.axis("i", 4);
    try builder_state.bind(axis, .thread_x);
    const dst = builder_state.argument(0);
    const factor = builder_state.argument(1);
    const src = builder_state.argument(2);
    const index = try builder_state.globalId(.x);
    const value = try builder_state.load(src, index);
    const adjusted = try builder_state.mul(value, factor);
    try builder_state.store(adjusted, dst, index);
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact_plan = createPlan(
        allocator,
        handle,
        &program,
        .{ .format = format },
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer artifact_plan.deinit();

    const planned = artifact_plan.kernels.items[0];
    try testing.expectEqual(format, planned.artifact.format);
    try testing.expectEqual(@as(u32, 11), planned.artifact.argument_count);
    try testing.expectEqual(@as(u32, 1), planned.runtime_scalar_argument_count);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        planned.static_arguments.len,
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 0 }, planned.static_arguments[0]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 4 }, planned.static_arguments[1]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[2]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[3]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[4]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 4 }, planned.static_arguments[5]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[6]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[7]);

    const loaded = try handle.loadArtifact(&planned.artifact);
    defer handle.destroyObject(loaded.id);

    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = 4 * @sizeOf(Element),
        .alignment = @alignOf(Element),
        .dtype = dtype,
        .element_count = 4,
    });
    defer handle.destroyObject(dst_buffer.id);

    const src_buffer = try handle.allocateBuffer(.{
        .byte_size = 4 * @sizeOf(Element),
        .alignment = @alignOf(Element),
        .dtype = dtype,
        .element_count = 4,
    });
    defer handle.destroyObject(src_buffer.id);

    try handle.writeBuffer(.{
        .handle = src_buffer,
        .bytes = std.mem.sliceAsBytes(src_values[0..]),
    });

    const bindings = [_]gpu.BufferBinding{
        .{
            .handle = dst_buffer,
            .access = .write_only,
            .ownership = .backend,
            .byte_size = dst_buffer.byte_size,
        },
        .{
            .handle = src_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = src_buffer.byte_size,
        },
    };
    var scalar_arguments: [
        1 +
            gpu_abi.launch_shape_argument_count
    ]gpu_abi.ScalarArgument = undefined;
    scalar_arguments[0] = switch (dtype) {
        .f32 => .{ .f32 = @as(f32, @floatCast(scale)) },
        .f64 => .{ .f64 = @as(f64, @floatCast(scale)) },
        else => unreachable,
    };
    @memcpy(scalar_arguments[1..][0..planned.static_arguments.len], planned.static_arguments);
    try handle.launch(.{
        .artifact = &planned.artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = scalar_arguments[0 .. 1 + planned.static_arguments.len],
        .geometry = planned.launch_resources.geometry,
    });

    var dst_values = @as([4]Element, @splat(@as(Element, 0)));
    try handle.readBuffer(.{
        .handle = dst_buffer,
        .bytes = std.mem.sliceAsBytes(dst_values[0..]),
    });
    try testing.expectEqualSlices(Element, expected_values[0..], dst_values[0..]);
}

fn runAuthoredCpuRowKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
) !void {
    var builder_state = try program_mod.Builder.init(
        allocator,
        program_mod.Builder.Limits.testing,
        "authored_cpu_run_row_f32",
        &.{
            builder.dynamicBuffer(.f32),
            builder.dynamicBuffer(.f32),
        },
    );
    errdefer builder_state.deinit();

    const col_axis = try builder_state.axis("col", 3);
    const row_axis = try builder_state.axis("row", 2);
    try builder_state.bind(col_axis, .thread_x);
    try builder_state.bind(row_axis, .thread_y);

    const rows = builder_state.argument(0);
    const dst = builder_state.argument(1);
    const col = try builder_state.globalId(.x);
    const row = try builder_state.globalId(.y);
    const width = try builder_state.constantIndex(3);
    const row_offset = try builder_state.mul(row, width);
    const index = try builder_state.add(row_offset, col);
    const value = try builder_state.load(rows, row);
    try builder_state.store(value, dst, index);
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact_plan = createPlan(
        allocator,
        handle,
        &program,
        .{ .format = format },
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer artifact_plan.deinit();

    const planned = artifact_plan.kernels.items[0];
    try testing.expectEqual(format, planned.artifact.format);
    try testing.expectEqual(@as(u32, 10), planned.artifact.argument_count);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        planned.static_arguments.len,
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 0 }, planned.static_arguments[0]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 6 }, planned.static_arguments[1]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[2]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[3]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[4]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 3 }, planned.static_arguments[5]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 2 }, planned.static_arguments[6]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[7]);

    const loaded = try handle.loadArtifact(&planned.artifact);
    defer handle.destroyObject(loaded.id);

    const row_buffer = try handle.allocateBuffer(.{
        .byte_size = 2 * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = 2,
    });
    defer handle.destroyObject(row_buffer.id);

    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = 6 * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = 6,
    });
    defer handle.destroyObject(dst_buffer.id);

    const row_values = [_]f32{ 10.0, 20.0 };
    try handle.writeBuffer(.{
        .handle = row_buffer,
        .bytes = std.mem.sliceAsBytes(row_values[0..]),
    });

    const bindings = [_]gpu.BufferBinding{
        .{
            .handle = row_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = row_buffer.byte_size,
        },
        .{
            .handle = dst_buffer,
            .access = .write_only,
            .ownership = .backend,
            .byte_size = dst_buffer.byte_size,
        },
    };
    try handle.launch(.{
        .artifact = &planned.artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = planned.static_arguments,
        .geometry = planned.launch_resources.geometry,
    });

    var dst_values = @as([6]f32, @splat(0.0));
    try handle.readBuffer(.{
        .handle = dst_buffer,
        .bytes = std.mem.sliceAsBytes(dst_values[0..]),
    });
    try testing.expectEqualSlices(
        f32,
        &[_]f32{ 10.0, 10.0, 10.0, 20.0, 20.0, 20.0 },
        dst_values[0..],
    );
}

fn runAuthoredCpuThreadBlockKernel(
    allocator: std.mem.Allocator,
    format: gpu.ArtifactFormat,
) !void {
    var builder_state = try program_mod.Builder.init(
        allocator,
        program_mod.Builder.Limits.testing,
        "authored_cpu_thread_block_f32",
        &.{
            builder.dynamicBuffer(.f32),
            builder.dynamicBuffer(.f32),
        },
    );
    errdefer builder_state.deinit();

    const block_axis = try builder_state.axis("block", 2);
    const thread_axis = try builder_state.axis("thread", 4);
    try builder_state.bind(block_axis, .block_x);
    try builder_state.bind(thread_axis, .thread_x);

    const src = builder_state.argument(0);
    const dst = builder_state.argument(1);
    const thread = try builder_state.threadId(.x);
    const block = try builder_state.blockId(.x);
    const block_dim = try builder_state.blockDim(.x);
    const grid_dim = try builder_state.gridDim(.x);
    const block_offset = try builder_state.mul(block, block_dim);
    const base_index = try builder_state.add(block_offset, thread);
    const zero = try builder_state.sub(grid_dim, grid_dim);
    const index = try builder_state.add(base_index, zero);
    const value = try builder_state.load(src, index);
    try builder_state.store(value, dst, index);
    try builder_state.return_();

    var program = try builder_state.finish();
    defer program.deinit();

    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const handle = state.handle();

    var artifact_plan = createPlan(
        allocator,
        handle,
        &program,
        .{ .format = format },
    ) catch |err| switch (err) {
        error.UnsupportedOperation => return error.SkipZigTest,
        else => return err,
    };
    defer artifact_plan.deinit();

    const planned = artifact_plan.kernels.items[0];
    try testing.expectEqual(format, planned.artifact.format);
    try testing.expectEqual(@as(u32, 10), planned.artifact.argument_count);
    try testing.expectEqual(
        @as(usize, gpu_abi.launch_shape_argument_count),
        planned.static_arguments.len,
    );
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 0 }, planned.static_arguments[0]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 8 }, planned.static_arguments[1]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 2 }, planned.static_arguments[2]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[3]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[4]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 4 }, planned.static_arguments[5]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[6]);
    try testing.expectEqual(gpu_abi.ScalarArgument{ .u32 = 1 }, planned.static_arguments[7]);

    const loaded = try handle.loadArtifact(&planned.artifact);
    defer handle.destroyObject(loaded.id);

    const src_buffer = try handle.allocateBuffer(.{
        .byte_size = 8 * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = 8,
    });
    defer handle.destroyObject(src_buffer.id);

    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = 8 * @sizeOf(f32),
        .alignment = @alignOf(f32),
        .dtype = .f32,
        .element_count = 8,
    });
    defer handle.destroyObject(dst_buffer.id);

    const src_values = [_]f32{ 1.0, 2.0, 3.0, 4.0, -1.0, -2.0, -3.0, -4.0 };
    try handle.writeBuffer(.{
        .handle = src_buffer,
        .bytes = std.mem.sliceAsBytes(src_values[0..]),
    });

    const bindings = [_]gpu.BufferBinding{
        .{
            .handle = src_buffer,
            .access = .read_only,
            .ownership = .backend,
            .byte_size = src_buffer.byte_size,
        },
        .{
            .handle = dst_buffer,
            .access = .write_only,
            .ownership = .backend,
            .byte_size = dst_buffer.byte_size,
        },
    };
    try handle.launch(.{
        .artifact = &planned.artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = planned.static_arguments,
        .geometry = planned.launch_resources.geometry,
    });

    var dst_values = @as([8]f32, @splat(0.0));
    try handle.readBuffer(.{
        .handle = dst_buffer,
        .bytes = std.mem.sliceAsBytes(dst_values[0..]),
    });
    try testing.expectEqualSlices(f32, src_values[0..], dst_values[0..]);
}

fn testCreateArtifact(
    ptr: *anyopaque,
    request: gpu.CompileRequest,
) gpu.BackendError!gpu.KernelArtifact {
    const state: *TestBackendState = @ptrCast(@alignCast(ptr));
    if (request.requested_format != state.format) return error.UnsupportedOperation;
    var artifact = gpu.KernelArtifact.init(state.allocator, .{
        .backend = state.kind,
        .format = state.format,
        .entry_name = request.kernel_name,
        .argument_count = request.argument_count,
        .scalar_argument_count = request.scalar_argument_count,
        .diagnostic_id = request.diagnostic_id,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    switch (request.payload) {
        .text => |text| try artifact.setOwnedText(text),
        .bytes => |bytes| try artifact.setOwnedBytes(bytes),
        .words_u32 => |words| try artifact.setOwnedWords(words),
        .none => return error.InvalidArtifact,
    }
    return artifact;
}

const test_backend_vtable = gpu.BackendVTable{
    .query_capabilities = testQueryCapabilities,
    .create_artifact = testCreateArtifact,
};
