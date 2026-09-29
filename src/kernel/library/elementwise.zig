const std = @import("std");
const gpu = @import("gpu");

const activation_mod = @import("../../choir/root.zig").activation;
const entry = @import("entry.zig");
const kernel = @import("../root.zig");

fn unaryElementwiseSpecialization(comptime spec: entry.Vector1D, comptime operation: entry.Operation) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = operation,
        .inputs = &.{entry.shape1D(spec.axis, spec.extent)},
        .outputs = &.{entry.shape1D(spec.axis, spec.extent)},
        .launch = entry.launch1D(spec.extent, spec.threads),
        .schedule = entry.threadBlocks1D(spec.axis, spec.extent, spec.threads),
    };
}

fn binaryElementwiseSpecialization(comptime spec: entry.Vector1D, comptime operation: entry.Operation) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = operation,
        .inputs = &.{
            entry.shape1D(spec.axis, spec.extent),
            entry.shape1D(spec.axis, spec.extent),
        },
        .outputs = &.{entry.shape1D(spec.axis, spec.extent)},
        .launch = entry.launch1D(spec.extent, spec.threads),
        .schedule = entry.threadBlocks1D(spec.axis, spec.extent, spec.threads),
    };
}

fn vector_add_each(inner: anytype, index: kernel.Index1D, each_args: anytype) !void {
    const lhs = try each_args.param(.lhs).load(inner, index);
    const rhs = try each_args.param(.rhs).load(inner, index);
    const sum = try lhs.add(inner, rhs);
    try each_args.param(.dst).store(inner, sum, index);
}

fn vectorAddProgram(comptime spec: entry.Vector1D) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach1D(spec.axis, spec.extent, args, vector_add_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint("accy_kernel_elementwise_add{}x{}_f32", .{ spec.extent, spec.threads }),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .lhs = kernel.dynamicBuffer(.f32),
            .rhs = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

pub fn vectorAddF32(comptime spec: entry.Vector1D) type {
    return entry.Entry(vectorAddProgram(spec), .{
        .target = std.fmt.comptimePrint("accy.kernel.elementwise.add{}x{}_f32", .{ spec.extent, spec.threads }),
        .layer = .logical,
        .category = .elementwise,
        .specialization = binaryElementwiseSpecialization(spec, .{ .elementwise = .add }),
    });
}

pub const VectorAdd8F32 = vectorAddF32(.{ .extent = 8, .threads = 4 });

fn axpy_each(inner: anytype, index: kernel.Index1D, each_args: anytype) !void {
    const x = try each_args.param(.x).load(inner, index);
    const y = try each_args.param(.y).load(inner, index);
    const scaled = try x.mul(inner, each_args.param(.alpha));
    const value = try scaled.add(inner, y);
    try each_args.param(.dst).store(inner, value, index);
}

fn axpyProgram(comptime spec: entry.Vector1D) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach1D(spec.axis, spec.extent, args, axpy_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint("accy_kernel_elementwise_axpy{}x{}_f32", .{ spec.extent, spec.threads }),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .x = kernel.dynamicBuffer(.f32),
            .y = kernel.dynamicBuffer(.f32),
            .alpha = kernel.scalar(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

pub fn axpyF32(comptime spec: entry.Vector1D) type {
    return entry.Entry(axpyProgram(spec), .{
        .target = std.fmt.comptimePrint("accy.kernel.elementwise.axpy{}x{}_f32", .{ spec.extent, spec.threads }),
        .layer = .logical,
        .category = .elementwise,
        .specialization = binaryElementwiseSpecialization(spec, .{ .elementwise = .axpy }),
    });
}

pub const Axpy8F32 = axpyF32(.{ .extent = 8, .threads = 4 });

pub fn geluTanhApprox(inner: anytype, value: anytype) !@TypeOf(value) {
    const square = try value.mul(inner, value);
    const cube = try square.mul(inner, value);
    const cubic = try cube.mul(inner, 0.044715);
    const shifted = try value.add(inner, cubic);
    const scaled = try shifted.mul(inner, 0.7978845608028654);
    const smooth = try scaled.tanh(inner);
    const gate = try smooth.add(inner, 1.0);
    const half_value = try value.mul(inner, 0.5);
    return half_value.mul(inner, gate);
}

pub fn silu(inner: anytype, value: anytype) !@TypeOf(value) {
    const negated = try value.mul(inner, -1.0);
    const exp_value = try negated.exp(inner);
    const denominator = try exp_value.add(inner, 1.0);
    return value.div(inner, denominator);
}

pub fn relu(inner: anytype, value: anytype) !@TypeOf(value) {
    return value.max(inner, 0.0);
}

fn unaryActivationName(comptime activation: activation_mod.Kind) []const u8 {
    return switch (activation) {
        .gelu => "gelu",
        .relu => "relu",
        .silu => "silu",
    };
}

fn unaryActivationOperation(comptime activation: activation_mod.Kind) entry.Operation {
    return .{ .activation = activation };
}

fn unaryActivationValue(inner: anytype, comptime activation: activation_mod.Kind, value: anytype) !@TypeOf(value) {
    return switch (activation) {
        .gelu => geluTanhApprox(inner, value),
        .relu => relu(inner, value),
        .silu => silu(inner, value),
    };
}

fn unary_activation_each(inner: anytype, index: kernel.Index1D, ctx: anytype) !void {
    const value = try ctx.args.param(.src).load(inner, index);
    const activated = try unaryActivationValue(inner, ctx.activation, value);
    try ctx.args.param(.dst).store(inner, activated, index);
}

fn unaryActivationProgram(comptime spec: entry.Vector1D, comptime activation: activation_mod.Kind) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach1D(spec.axis, spec.extent, .{ .args = args, .activation = activation }, unary_activation_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint("accy_kernel_activation_{s}{}x{}_f32", .{ unaryActivationName(activation), spec.extent, spec.threads }),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .src = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

fn unaryActivationF32(comptime spec: entry.Vector1D, comptime activation: activation_mod.Kind) type {
    return entry.Entry(unaryActivationProgram(spec, activation), .{
        .target = std.fmt.comptimePrint("accy.kernel.activation.{s}{}x{}_f32", .{ unaryActivationName(activation), spec.extent, spec.threads }),
        .layer = .logical,
        .category = .elementwise,
        .specialization = unaryElementwiseSpecialization(spec, unaryActivationOperation(activation)),
    });
}

pub fn geluF32(comptime spec: entry.Vector1D) type {
    return unaryActivationF32(spec, .gelu);
}

pub fn reluF32(comptime spec: entry.Vector1D) type {
    return unaryActivationF32(spec, .relu);
}

pub fn siluF32(comptime spec: entry.Vector1D) type {
    return unaryActivationF32(spec, .silu);
}

pub const Gelu8F32 = geluF32(.{ .extent = 8, .threads = 4 });
pub const Relu8F32 = reluF32(.{ .extent = 8, .threads = 4 });
pub const Silu8F32 = siluF32(.{ .extent = 8, .threads = 4 });

fn geluApprox(value: f32) f32 {
    return 0.5 * value * (1.0 + std.math.tanh(0.7978845608028654 * (value + 0.044715 * value * value * value)));
}

fn siluExpected(value: f32) f32 {
    return value / (1.0 + @exp(-value));
}

fn reluExpected(value: f32) f32 {
    if (value > 0.0) return value;
    return 0.0;
}

fn authored_scale_each(inner: anytype, index: kernel.Index1D, each_args: anytype) !void {
    const value = try each_args.param(.src).load(inner, index);
    const scaled = try value.mul(inner, each_args.param(.alpha));
    try each_args.param(.dst).store(inner, scaled, index);
}

fn authoredScaleProgram(comptime spec: entry.Vector1D) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach1D(spec.axis, spec.extent, spec.threads, args, authored_scale_each);
        }
    };

    return kernel.Program(.{
        .name = std.fmt.comptimePrint("accy_kernel_authored_elementwise_scale{}x{}_f32", .{ spec.extent, spec.threads }),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .src = kernel.dynamicBuffer(.f32),
            .alpha = kernel.scalar(.f32),
        },
        .body = Body.run,
    });
}

pub fn authoredScaleF32(comptime spec: entry.Vector1D) type {
    return entry.Entry(authoredScaleProgram(spec), .{
        .target = std.fmt.comptimePrint("accy.kernel.authored.elementwise.scale{}x{}_f32", .{ spec.extent, spec.threads }),
        .layer = .authored,
        .category = .elementwise,
        .specialization = unaryElementwiseSpecialization(spec, .{ .elementwise = .scale }),
    });
}

pub const AuthoredScale8F32 = authoredScaleF32(.{ .extent = 8, .threads = 8 });

test "elementwise add entry runs on CPU and records schedule" {
    var lhs = [_]f32{ 1.0, 2.0, -3.0, 4.5, 8.0, -1.0, 0.25, 16.0 };
    var rhs = [_]f32{ 4.0, -2.0, 6.0, 0.5, -3.0, 5.0, 0.75, -8.0 };
    var dst = @as([8]f32, @splat(0.0));

    try VectorAdd8F32.runCpu(std.testing.allocator, VectorAdd8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try std.testing.expectEqualSlices(f32, &.{ 5.0, 0.0, 3.0, 5.0, 5.0, 4.0, 1.0, 8.0 }, dst[0..]);

    const launch_value = try VectorAdd8F32.launch(std.testing.allocator, VectorAdd8F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
}

test "elementwise constructor creates independent shape-specialized entries" {
    const VectorAdd16F32 = vectorAddF32(.{ .extent = 16, .threads = 8 });

    try std.testing.expectEqualStrings("accy.kernel.elementwise.add8x4_f32", VectorAdd8F32.target);
    try std.testing.expectEqualStrings("accy.kernel.elementwise.add16x8_f32", VectorAdd16F32.target);
    try std.testing.expectEqual(@as(usize, 2), VectorAdd16F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 8), VectorAdd8F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 16), VectorAdd16F32.specialization.outputs[0].elementCount().?);
    try std.testing.expect(VectorAdd16F32.specialization.operationIs(.{ .elementwise = .add }));
    try std.testing.expectEqual(@as(u32, 8), VectorAdd16F32.specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), VectorAdd16F32.specialization.launch.?.grid[0]);
    try std.testing.expectEqualDeep(VectorAdd16F32.specialization.launch.?, VectorAdd16F32.specialization.schedule.?.launch());

    var snapshot = try VectorAdd16F32.scheduleSnapshot(std.testing.allocator, VectorAdd16F32.Limits.testing);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(VectorAdd16F32.specialization.schedule.?.matchesSnapshot(&snapshot));

    var lhs: [16]f32 = undefined;
    var rhs: [16]f32 = undefined;
    var dst = @as([16]f32, @splat(0.0));
    for (0..16) |i| {
        lhs[i] = @floatFromInt(i);
        rhs[i] = @floatFromInt(16 - i);
    }

    try VectorAdd16F32.runCpu(std.testing.allocator, VectorAdd16F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    for (dst) |value| try std.testing.expectEqual(@as(f32, 16.0), value);
}

test "elementwise axpy entry runs on CPU" {
    var x = [_]f32{ 1.0, 2.0, -3.0, 4.0, 0.5, -1.5, 8.0, 16.0 };
    var y = [_]f32{ 10.0, -4.0, 1.0, 2.0, 3.0, 6.0, -8.0, 0.0 };
    var dst = @as([8]f32, @splat(0.0));

    try Axpy8F32.runCpu(std.testing.allocator, Axpy8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, x[0..]),
        kernel.argumentBuffer(f32, y[0..]),
        kernel.argumentF32(2.0),
    });
    try std.testing.expectEqualSlices(f32, &.{ 12.0, 0.0, -5.0, 10.0, 4.0, 3.0, 8.0, 32.0 }, dst[0..]);
}

test "elementwise gelu entry runs on CPU and records operation" {
    var src = [_]f32{ -3.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 4.0 };
    var dst = @as([8]f32, @splat(0.0));

    try Gelu8F32.runCpu(std.testing.allocator, Gelu8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
    });
    for (src, dst) |input, actual| {
        try std.testing.expectApproxEqAbs(geluApprox(input), actual, 0.0001);
    }

    const launch_value = try Gelu8F32.launch(std.testing.allocator, Gelu8F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expect(Gelu8F32.specialization.operationIs(.{ .activation = .gelu }));
    try std.testing.expectEqual(@as(usize, 1), Gelu8F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 8), Gelu8F32.specialization.outputs[0].elementCount().?);
}

test "elementwise relu entry runs on CPU and records operation" {
    var src = [_]f32{ -5.0, -2.0, -1.0, 0.0, 0.5, 1.0, 3.0, 6.0 };
    var dst = @as([8]f32, @splat(0.0));

    try Relu8F32.runCpu(std.testing.allocator, Relu8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
    });
    for (src, dst) |input, actual| {
        try std.testing.expectApproxEqAbs(reluExpected(input), actual, 0.0001);
    }

    const launch_value = try Relu8F32.launch(std.testing.allocator, Relu8F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expect(Relu8F32.specialization.operationIs(.{ .activation = .relu }));
    try std.testing.expectEqual(@as(usize, 1), Relu8F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 8), Relu8F32.specialization.outputs[0].elementCount().?);
}

test "elementwise silu entry runs on CPU and records operation" {
    var src = [_]f32{ -5.0, -2.0, -1.0, 0.0, 0.5, 1.0, 3.0, 6.0 };
    var dst = @as([8]f32, @splat(0.0));

    try Silu8F32.runCpu(std.testing.allocator, Silu8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
    });
    for (src, dst) |input, actual| {
        try std.testing.expectApproxEqAbs(siluExpected(input), actual, 0.0001);
    }

    const launch_value = try Silu8F32.launch(std.testing.allocator, Silu8F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), launch_value.block[0]);
    try std.testing.expect(Silu8F32.specialization.operationIs(.{ .activation = .silu }));
    try std.testing.expectEqual(@as(usize, 1), Silu8F32.specialization.inputs.len);
    try std.testing.expectEqual(@as(u64, 8), Silu8F32.specialization.outputs[0].elementCount().?);
}

test "elementwise entries create registry-ready artifacts" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try VectorAdd8F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = VectorAdd8F32.Limits.testing });
    defer call_artifact.deinit();

    const registry = call_artifact.registry();
    const artifact = registry.find(VectorAdd8F32.target, VectorAdd8F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(VectorAdd8F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 3), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(VectorAdd8F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(VectorAdd8F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}

test "authored elementwise entry preserves authored launch" {
    var src = [_]f32{ 1.0, 2.0, -3.0, 4.0, 0.5, -1.5, 8.0, 16.0 };
    var dst = @as([8]f32, @splat(0.0));

    try AuthoredScale8F32.runCpu(std.testing.allocator, AuthoredScale8F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
        kernel.argumentF32(3.0),
    });
    try std.testing.expectEqualSlices(f32, &.{ 3.0, 6.0, -9.0, 12.0, 1.5, -4.5, 24.0, 48.0 }, dst[0..]);

    const launch_value = try AuthoredScale8F32.launch(std.testing.allocator, AuthoredScale8F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 8), launch_value.block[0]);
    try std.testing.expectEqual(entry.Layer.authored, AuthoredScale8F32.layer);
    try std.testing.expectEqual(@as(usize, 1), AuthoredScale8F32.specialization.inputs.len);
    try std.testing.expect(AuthoredScale8F32.specialization.operationIs(.{ .elementwise = .scale }));
    try std.testing.expectEqual(@as(u32, 8), AuthoredScale8F32.specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqualDeep(AuthoredScale8F32.specialization.launch.?, AuthoredScale8F32.specialization.schedule.?.launch());
}
