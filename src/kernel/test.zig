const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const kernel = @import("root.zig");

const build_options = @import("build_options");
const artifact_product = @import("../artifact/root.zig");
const exec_product = @import("../executable/root.zig");
const logical_mod = @import("logical/root.zig");
const builder = kernel.builder;
const oracle = kernel.oracle;
const schedule = kernel.schedule;
const Builder = kernel.Builder;
const FragmentCompilerOptions = exec_product.FragmentCompilerOptions;
const ArtifactKernelSource = artifact_product.KernelSource;
const Program = kernel.Program;
const Index1D = kernel.Index1D;
const Schedule = kernel.Schedule;
const Launch = kernel.Launch;
const BindTarget = kernel.BindTarget;
const scalar = kernel.scalar;
const dynamicBuffer = kernel.dynamicBuffer;
const createKernelCallArtifact = kernel.createKernelCallArtifact;
const compileFragment = kernel.compileFragment;
const createKernelArtifact = kernel.createKernelArtifact;
const argumentBuffer = kernel.argumentBuffer;

test {
    _ = @import("dsl/test.zig");
    _ = @import("library/test.zig");
    _ = @import("logical/test.zig");
    _ = @import("program/test.zig");
    _ = @import("call.zig");
    @import("test_discovery").discover(kernel);
}

fn executableCopyEach(inner: anytype, index: Index1D, each_args: anytype) !void {
    const value = try each_args.param(.src).load(inner, index);
    try each_args.param(.dst).store(inner, value, index);
}

fn executableCopyBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("i", 4, 4, args, executableCopyEach);
}

const ExecutableCopy = Program(.{
    .name = "kernel_dsl_executable_copy_i32",
    .parameters = .{
        .src = dynamicBuffer(.i32),
        .dst = dynamicBuffer(.i32),
    },
    .body = executableCopyBody,
});

fn kernelCallAddEach(inner: anytype, index: Index1D, each_args: anytype) !void {
    const lhs = try each_args.param(.lhs).load(inner, index);
    const rhs = try each_args.param(.rhs).load(inner, index);
    const sum = try lhs.add(inner, rhs);
    try each_args.param(.dst).store(inner, sum, index);
}

fn kernelCallAddBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("i", 8, 8, args, kernelCallAddEach);
}

const KernelCallAdd = Program(.{
    .name = "kernel_call_add_f32",
    .parameters = .{
        .dst = dynamicBuffer(.f32),
        .lhs = dynamicBuffer(.f32),
        .rhs = dynamicBuffer(.f32),
    },
    .body = kernelCallAddBody,
});

fn logicalKernelCallAddEach(inner: anytype, index: Index1D, each_args: anytype) !void {
    const lhs = try each_args.param(.lhs).load(inner, index);
    const rhs = try each_args.param(.rhs).load(inner, index);
    const sum = try lhs.add(inner, rhs);
    try each_args.param(.dst).store(inner, sum, index);
}

fn logicalKernelCallAddBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("i", 8, args, logicalKernelCallAddEach);
}

const LogicalKernelCallAdd = logical_mod.Program(.{
    .name = "logical_kernel_call_add_f32",
    .parameters = .{
        .dst = dynamicBuffer(.f32),
        .lhs = dynamicBuffer(.f32),
        .rhs = dynamicBuffer(.f32),
    },
    .body = logicalKernelCallAddBody,
}).withSchedule(logical_mod.schedule.threadBlocks(.{ .x = 4 }));

fn metalGeneratedScaleEach(inner: anytype, index: Index1D, each_args: anytype) !void {
    const value = try each_args.param(.src).load(inner, index);
    const scaled = try value.mul(inner, each_args.param(.scale));
    try each_args.param(.dst).store(inner, scaled, index);
}

fn metalGeneratedScaleBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("i", 5, 4, args, metalGeneratedScaleEach);
}

const MetalGeneratedScale = Program(.{
    .name = "kernel_metal_generated_scale_f32",
    .parameters = .{
        .src = dynamicBuffer(.f32),
        .dst = dynamicBuffer(.f32),
        .scale = scalar(.f32),
    },
    .body = metalGeneratedScaleBody,
});

test "kernel Program creates executable fragment through BackendHandle" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };

    var graph = try ExecutableCopy.build(allocator, ExecutableCopy.Limits.testing);
    defer graph.deinit();
    var schedule_snapshot = try graph.scheduleSnapshot(allocator);
    defer schedule_snapshot.deinit(allocator);
    var checked_plan = try graph.createCheckedPlan(allocator, .{});
    defer checked_plan.deinit();
    const body_fingerprint = checked_plan.body_fingerprint;
    const options = FragmentCompilerOptions{ .authored_kernel_diagnostic_id = "choir/kernel/program-executable" };
    const compiled = try compileFragment(
        allocator,
        state.handle(),
        &graph,
        options,
    );
    var fragment = try @import("../executable/root.zig").loadFragment(allocator, state.handle(), compiled, options);
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), state.create_count);
    try std.testing.expect(state.last_create_had_payload);
    try std.testing.expectEqual(@as(u32, 2), state.last_create_argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.i32}).bits, state.last_create_required_dtype_bits);
    try std.testing.expectEqual(@as(usize, 1), state.load_count);
    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());

    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.choir_kernel, summary.source);
    try std.testing.expectEqualStrings("kernel_dsl_executable_copy_i32", summary.entry_name);
    try std.testing.expectEqual(gpu.ArtifactFormat.vulkan_spirv, summary.artifact_format);
    try std.testing.expectEqual(@as(u32, 2), summary.compile_argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.i32}).bits, summary.compile_required_dtype_bits);
    try std.testing.expect(std.meta.eql(gpu_abi.Features{}, summary.compile_required_features));
    try std.testing.expect(std.meta.eql(gpu_abi.SubgroupRequirements{}, summary.compile_required_subgroup));
    try std.testing.expectEqual(.words_u32, summary.compile_payload);
    try std.testing.expectEqual(.authored, summary.compile_launch);
    try std.testing.expect(summary.fixed_threadgroup);
    try std.testing.expectEqual(@as(u64, 0), summary.output_layout_fingerprint);
    try std.testing.expectEqual(@as(u64, 0), summary.input_layout_fingerprint);
    try std.testing.expectEqual(@as(usize, 1), schedule_snapshot.allAxes().len);
    try std.testing.expectEqualStrings("i", schedule_snapshot.allAxes()[0].name);
    try std.testing.expectEqual(BindTarget.thread_x, schedule_snapshot.allAxes()[0].bind.?);
    try std.testing.expectEqual(checked_plan.schedule_fingerprint, schedule_snapshot.fingerprint());
    try std.testing.expectEqual(body_fingerprint, try graph.bodyFingerprint(allocator));

    const buffers = [_]gpu.BufferBinding{
        testBufferBinding(31, .vulkan, 16),
        testBufferBinding(32, .vulkan, 16),
    };
    try fragment.launchKernelWithArguments(0, &buffers, &.{}, .{});

    try std.testing.expectEqual(@as(usize, 1), state.launch_count);
    try std.testing.expectEqual(state.last_loaded_id.?, state.last_launch_loaded_id.?);
    try std.testing.expectEqual(@as(usize, 2), state.last_launch_buffer_count);
    try std.testing.expectEqual(@as(usize, 0), state.last_launch_scalar_count);
    try std.testing.expectEqual(@as(u32, 1), state.last_launch_grid[0]);
    try std.testing.expectEqual(@as(u32, 4), state.last_launch_threadgroup[0]);
    try std.testing.expectEqual(@as(gpu.BackendObjectId, 31), state.last_buffer_ids[0]);
    try std.testing.expectEqual(@as(gpu.BackendObjectId, 32), state.last_buffer_ids[1]);
}

test "kernel Program creates registry-ready kernel_call artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try KernelCallAdd.createKernelCallArtifact(allocator, KernelCallAdd.Limits.testing, state.handle(), .{
        .target = "accy.custom.add",
    });
    defer call_artifact.deinit();

    const registry = call_artifact.registry();
    const entry = registry.find("accy.custom.add", 1, .cuda_ptx) orelse return error.TestExpectedKernelCallArtifact;
    try std.testing.expectEqualStrings("kernel_call_add_f32", entry.entry_name);
    try std.testing.expectEqual(@as(u32, 3), entry.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, entry.required_dtypes.bits);
    switch (entry.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(@as(u32, 1), geometry.grid[0]);
            try std.testing.expectEqual(@as(u32, 8), geometry.threadgroup[0]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
    try std.testing.expectEqual(.none, entry.element_count_argument);
    try std.testing.expectEqual(@as(usize, 0), entry.static_arguments.len);
    switch (entry.payload) {
        .text => |text| try std.testing.expect(std.mem.indexOf(u8, text, "kernel_call_add_f32") != null),
        else => return error.TestExpectedPtxPayload,
    }
}

test "logical Program creates scheduled registry-ready kernel_call artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try LogicalKernelCallAdd.createKernelCallArtifact(allocator, LogicalKernelCallAdd.Limits.testing, state.handle(), .{
        .target = "accy.custom.logical_add",
    });
    defer call_artifact.deinit();

    const entry = call_artifact.entry();
    try std.testing.expectEqualStrings("logical_kernel_call_add_f32", entry.entry_name);
    try std.testing.expectEqual(@as(u32, 3), entry.argument_count);
    switch (entry.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(@as(u32, 2), geometry.grid[0]);
            try std.testing.expectEqual(@as(u32, 4), geometry.threadgroup[0]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "kernel Program creates standalone kernel artifact through BackendHandle" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };

    var compiled = try ExecutableCopy.createKernelArtifact(
        allocator,
        ExecutableCopy.Limits.testing,
        state.handle(),
        .{ .authored_kernel_diagnostic_id = "choir/kernel/program-artifact" },
    );
    defer compiled.deinit();

    try std.testing.expectEqual(@as(usize, 1), state.create_count);
    try std.testing.expect(state.last_create_had_payload);
    try std.testing.expectEqual(@as(u32, 2), state.last_create_argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.i32}).bits, state.last_create_required_dtype_bits);
    try std.testing.expectEqual(@as(usize, 0), state.load_count);
    try std.testing.expectEqual(gpu.BackendKind.vulkan, compiled.backend);
    try std.testing.expectEqual(gpu.ArtifactFormat.vulkan_spirv, compiled.format);
    try std.testing.expectEqual(@as(u32, 2), compiled.argument_count);
    try std.testing.expectEqualStrings("kernel_dsl_executable_copy_i32", compiled.entry_name);
    try std.testing.expectEqualStrings("choir/kernel/program-artifact", compiled.diagnostic_id.?);
}

test "kernel Program launches generated Choir artifact on live Metal" {
    const allocator = std.testing.allocator;

    var state = try initMetalStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    const options = FragmentCompilerOptions{
        .artifact_format = .metal_msl,
        .authored_kernel_diagnostic_id = "choir/kernel/generated-metal-scale-live",
    };
    const compiled = try MetalGeneratedScale.compileFragment(
        allocator,
        MetalGeneratedScale.Limits.testing,
        handle,
        options,
    );
    var fragment = try @import("../executable/root.zig").loadFragment(allocator, handle, compiled, options);
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.choir_kernel, summary.source);
    try std.testing.expectEqual(gpu.ArtifactFormat.metal_msl, summary.artifact_format);
    try std.testing.expectEqual(@as(u32, 3), summary.compile_argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, summary.compile_required_dtype_bits);
    try std.testing.expect(summary.fixed_threadgroup);
    try std.testing.expectEqual(@as(u32, 2), summary.launch_geometry.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), summary.launch_geometry.threadgroup[0]);

    var input = [_]f32{ 1.25, -2.0, 0.5, 4.0, -3.5 };
    var output = @as([input.len]f32, @splat(0));
    const scale: f32 = -3.0;

    const input_buffer = try handle.allocateBuffer(.{
        .byte_size = @sizeOf(@TypeOf(input)),
        .alignment = 256,
        .dtype = .f32,
        .element_count = input.len,
    });
    const output_buffer = try handle.allocateBuffer(.{
        .byte_size = @sizeOf(@TypeOf(output)),
        .alignment = 256,
        .dtype = .f32,
        .element_count = output.len,
    });

    try handle.writeBuffer(.{
        .handle = input_buffer,
        .bytes = std.mem.sliceAsBytes(input[0..]),
    });
    try handle.writeBuffer(.{
        .handle = output_buffer,
        .bytes = std.mem.sliceAsBytes(output[0..]),
    });

    const stream = try handle.createStream(.{});
    const event = try handle.createEvent(.{});
    const bindings = [_]gpu.BufferBinding{
        liveBufferBinding(input_buffer, .read_only),
        liveBufferBinding(output_buffer, .write_only),
    };
    try fragment.launchKernelWithArguments(
        0,
        &bindings,
        &.{.{ .f32 = scale }},
        .{
            .stream = stream,
            .signal_event = event,
        },
    );

    try handle.synchronize(.{ .scope = .event, .event = event });
    try std.testing.expect(try handle.queryEvent(.{ .event = event }));
    try handle.readBuffer(.{
        .handle = output_buffer,
        .bytes = std.mem.sliceAsBytes(output[0..]),
    });

    for (input, output) |source, observed| {
        try std.testing.expectApproxEqAbs(source * scale, observed, 1e-6);
    }
}

fn initMetalStateOrSkip(allocator: std.mem.Allocator) !gpu.metal.State {
    if (!build_options.metal_tests) return error.SkipZigTest;
    return gpu.metal.State.initDevice(allocator) catch |err| switch (err) {
        error.RuntimeUnavailable => return error.SkipZigTest,
        else => return err,
    };
}

fn testBufferBinding(
    id: gpu.BackendObjectId,
    kind: gpu.BackendKind,
    bytes: usize,
) gpu.BufferBinding {
    return .{
        .handle = .{
            .id = id,
            .backend = kind,
            .byte_size = bytes,
            .ownership = .backend,
        },
        .access = .read_write,
        .ownership = .backend,
        .byte_size = bytes,
    };
}

fn liveBufferBinding(handle: gpu.BufferHandle, access: gpu.BufferAccess) gpu.BufferBinding {
    return .{
        .handle = handle,
        .access = access,
        .ownership = handle.ownership,
        .byte_size = handle.byte_size,
    };
}

test "Schedule launch drives Choir-backed CPU kernel oracle" {
    var schedule_plan = try Schedule.init(std.testing.allocator, Schedule.Limits.testing);
    defer schedule_plan.deinit(std.testing.allocator);

    const i = try schedule_plan.addAxis("i", 4);
    try schedule_plan.bind(i, .thread_x);

    var b = try builder.Builder.init(std.testing.allocator, builder.Builder.Limits.testing, "copy_i32_scheduled", &.{
        dynamicBuffer(.i32),
        dynamicBuffer(.i32),
    }, .{});
    errdefer b.deinit();

    const src = b.argument(0);
    const dst = b.argument(1);
    const index = try b.globalId(.x);
    const value = try b.load(src, index);
    try b.store(value, dst, index);
    try b.return_();

    var kernel_graph = try b.finish();
    defer kernel_graph.deinit();

    var input = [_]i32{ 4, 3, 2, 1 };
    var output = [_]i32{ 0, 0, 0, 0 };
    const launch: Launch = try schedule_plan.launch();
    try oracle.run(std.testing.allocator, &kernel_graph, &.{
        oracle.argumentBuffer(i32, input[0..]),
        oracle.argumentBuffer(i32, output[0..]),
    }, launch);

    try std.testing.expectEqualSlices(i32, input[0..], output[0..]);
}

test "accy kernel declaration coverage" {
    std.testing.refAllDecls(kernel);
}
