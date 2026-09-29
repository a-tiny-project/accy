const std = @import("std");
const gpu = @import("gpu");

const entry = @import("entry.zig");
const kernel = @import("../root.zig");

pub const OneDimensional = struct {
    extent: u64,
    threads: u32,
    input_axis: []const u8 = "i",
    output_axis: []const u8 = "out",
};

fn foldUpper(comptime extent: u64) i64 {
    if (extent > @as(u64, @intCast(std.math.maxInt(i64)))) {
        @compileError("kernel library reduction extent overflows index fold range");
    }
    return @intCast(extent);
}

fn sumSpecialization(comptime spec: OneDimensional) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .reduction = .sum },
        .equation = "i->",
        .inputs = &.{entry.shape1D(spec.input_axis, spec.extent)},
        .outputs = &.{entry.shapeScalar()},
        .reductions = &.{entry.reduction("sum", .sum, entry.shape1D(spec.input_axis, spec.extent))},
        .launch = entry.launch1D(1, spec.threads),
        .schedule = entry.threadBlocks1D(spec.output_axis, 1, spec.threads),
    };
}

fn dotSpecialization(comptime spec: OneDimensional) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .reduction = .dot_product },
        .equation = "i,i->",
        .inputs = &.{
            entry.shape1D(spec.input_axis, spec.extent),
            entry.shape1D(spec.input_axis, spec.extent),
        },
        .outputs = &.{entry.shapeScalar()},
        .reductions = &.{entry.reduction("dot", .dot_product, entry.shape1D(spec.input_axis, spec.extent))},
        .launch = entry.launch1D(1, spec.threads),
        .schedule = entry.threadBlocks1D(spec.output_axis, 1, spec.threads),
    };
}

fn sum_each(inner: anytype, index: kernel.Index1D, ctx: anytype) !void {
    const zero = try inner.constantFloat(.f32, 0.0);
    const sum = try inner.foldRange(0, foldUpper(ctx.spec.extent), 1, zero, .{
        .src = ctx.args.param(.src),
    }, sum_step);
    try ctx.args.param(.dst).store(inner, sum, index);
}

fn sum_step(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const value = try ctx.src.load(fold_inner, offset);
    return fold_inner.add(acc, value.raw());
}

fn sumProgram(comptime spec: OneDimensional) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach1D(spec.output_axis, 1, .{ .spec = spec, .args = args }, sum_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint("accy_kernel_reduction_sum{}x{}_f32", .{ spec.extent, spec.threads }),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .src = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

fn dot_each(inner: anytype, index: kernel.Index1D, ctx: anytype) !void {
    const zero = try inner.constantFloat(.f32, 0.0);
    const sum = try inner.foldRange(0, foldUpper(ctx.spec.extent), 1, zero, .{
        .lhs = ctx.args.param(.lhs),
        .rhs = ctx.args.param(.rhs),
    }, dot_step);
    try ctx.args.param(.dst).store(inner, sum, index);
}

fn dot_step(fold_inner: anytype, offset: kernel.Value, acc: kernel.Value, ctx: anytype) !kernel.Value {
    const lhs = try ctx.lhs.load(fold_inner, offset);
    const rhs = try ctx.rhs.load(fold_inner, offset);
    const product = try lhs.mul(fold_inner, rhs);
    return fold_inner.add(acc, product.raw());
}

fn dotProgram(comptime spec: OneDimensional) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach1D(spec.output_axis, 1, .{ .spec = spec, .args = args }, dot_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint("accy_kernel_reduction_dot{}x{}_f32", .{ spec.extent, spec.threads }),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .lhs = kernel.dynamicBuffer(.f32),
            .rhs = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

pub fn sumF32(comptime spec: OneDimensional) type {
    return entry.Entry(sumProgram(spec), .{
        .target = std.fmt.comptimePrint("accy.kernel.reduction.sum{}x{}_f32", .{ spec.extent, spec.threads }),
        .layer = .logical,
        .category = .reduction,
        .specialization = sumSpecialization(spec),
    });
}

pub fn dotF32(comptime spec: OneDimensional) type {
    return entry.Entry(dotProgram(spec), .{
        .target = std.fmt.comptimePrint("accy.kernel.reduction.dot{}x{}_f32", .{ spec.extent, spec.threads }),
        .layer = .logical,
        .category = .reduction,
        .specialization = dotSpecialization(spec),
    });
}

pub const Sum8F32 = sumF32(.{ .extent = 8, .threads = 1 });
pub const Dot8F32 = dotF32(.{ .extent = 8, .threads = 1 });

test "reduction sum entry runs on CPU" {
    var src = [_]f32{ 1.0, -2.0, 3.0, 4.0, 5.5, 0.5, -1.0, 8.0 };
    var dst = [_]f32{0.0};

    try Sum8F32.runCpu(std.testing.allocator, Sum8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
    });
    try std.testing.expectEqual(@as(f32, 19.0), dst[0]);

    const launch_value = try Sum8F32.launch(std.testing.allocator, Sum8F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), launch_value.block[0]);
}

test "reduction dot entry runs on CPU" {
    var lhs = [_]f32{ 1.0, -2.0, 3.0, 4.0, 0.5, -1.5, 2.0, -3.0 };
    var rhs = [_]f32{ 2.0, 3.0, -1.0, 0.25, 8.0, -2.0, 0.5, 4.0 };
    var dst = [_]f32{0.0};

    try Dot8F32.runCpu(std.testing.allocator, Dot8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try std.testing.expectEqual(@as(f32, -10.0), dst[0]);

    const launch_value = try Dot8F32.launch(std.testing.allocator, Dot8F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), launch_value.block[0]);
}

test "reduction constructor creates independent shape-specialized entries" {
    const Sum16F32 = sumF32(.{ .extent = 16, .threads = 1 });
    const Dot16F32 = dotF32(.{ .extent = 16, .threads = 1 });

    try std.testing.expectEqualStrings("accy.kernel.reduction.sum8x1_f32", Sum8F32.target);
    try std.testing.expectEqualStrings("accy.kernel.reduction.sum16x1_f32", Sum16F32.target);
    try std.testing.expectEqualStrings("accy.kernel.reduction.dot8x1_f32", Dot8F32.target);
    try std.testing.expectEqualStrings("accy.kernel.reduction.dot16x1_f32", Dot16F32.target);
    try std.testing.expectEqual(@as(u64, 8), Sum8F32.specialization.inputs[0].elementCount().?);
    try std.testing.expectEqualStrings("sum", Sum16F32.specialization.reductions[0].name);
    try std.testing.expectEqual(entry.ReductionOperator.sum, Sum16F32.specialization.reductions[0].operator);
    try std.testing.expect(Sum16F32.specialization.operationIs(.{ .reduction = .sum }));
    try std.testing.expectEqual(@as(u64, 16), Sum16F32.specialization.reductions[0].shape.elementCount().?);
    try std.testing.expectEqual(@as(u64, 1), Sum16F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqualStrings("dot", Dot16F32.specialization.reductions[0].name);
    try std.testing.expectEqual(entry.ReductionOperator.dot_product, Dot16F32.specialization.reductions[0].operator);
    try std.testing.expect(Dot16F32.specialization.operationIs(.{ .reduction = .dot_product }));
    try std.testing.expectEqual(@as(u64, 16), Dot16F32.specialization.reductions[0].shape.elementCount().?);
    try std.testing.expect(Dot16F32.specialization.outputHasExtents(0, &.{}));
    try std.testing.expectEqualDeep(Sum16F32.specialization.launch.?, Sum16F32.specialization.schedule.?.launch());
    try std.testing.expectEqualDeep(Dot16F32.specialization.launch.?, Dot16F32.specialization.schedule.?.launch());

    var snapshot = try Sum16F32.scheduleSnapshot(std.testing.allocator, Sum16F32.Limits.testing);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(Sum16F32.specialization.schedule.?.matchesSnapshot(&snapshot));

    var dot_snapshot = try Dot16F32.scheduleSnapshot(std.testing.allocator, Dot16F32.Limits.testing);
    defer dot_snapshot.deinit(std.testing.allocator);
    try std.testing.expect(Dot16F32.specialization.schedule.?.matchesSnapshot(&dot_snapshot));

    var src = @as([16]f32, @splat(1.0));
    var dst = [_]f32{0.0};
    try Sum16F32.runCpu(std.testing.allocator, Sum16F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
    });
    try std.testing.expectEqual(@as(f32, 16.0), dst[0]);

    var dot_dst = [_]f32{0.0};
    try Dot16F32.runCpu(std.testing.allocator, Dot16F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dot_dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
        kernel.argumentBuffer(f32, src[0..]),
    });
    try std.testing.expectEqual(@as(f32, 16.0), dot_dst[0]);
}

test "reduction sum entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try Sum8F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = Sum8F32.Limits.testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(Sum8F32.target, Sum8F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(Sum8F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 2), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(Sum8F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(Sum8F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "reduction dot entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try Dot8F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = Dot8F32.Limits.testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(Dot8F32.target, Dot8F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(Dot8F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 3), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(Dot8F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(Dot8F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}
