const std = @import("std");
const gpu = @import("gpu");

const activation_mod = @import("../../choir/root.zig").activation;
const entry = @import("entry.zig");
const kernel = @import("../root.zig");

fn unaryElementwiseSpecialization(
    comptime spec: entry.Vector1D,
    comptime operation: entry.Operation,
) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = operation,
        .inputs = &.{entry.shape1D(spec.axis, spec.extent)},
        .outputs = &.{entry.shape1D(spec.axis, spec.extent)},
        .launch = entry.launch1D(spec.extent, spec.threads),
        .schedule = entry.threadBlocks1D(spec.axis, spec.extent, spec.threads),
    };
}

fn binaryElementwiseSpecialization(
    comptime spec: entry.Vector1D,
    comptime operation: entry.Operation,
) entry.Specialization {
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
        .name = std.fmt.comptimePrint(
            "accy_kernel_elementwise_add{}x{}_f32",
            .{ spec.extent, spec.threads },
        ),
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
        .target = std.fmt.comptimePrint(
            "accy.kernel.elementwise.add{}x{}_f32",
            .{ spec.extent, spec.threads },
        ),
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
        .name = std.fmt.comptimePrint(
            "accy_kernel_elementwise_axpy{}x{}_f32",
            .{ spec.extent, spec.threads },
        ),
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
        .target = std.fmt.comptimePrint(
            "accy.kernel.elementwise.axpy{}x{}_f32",
            .{ spec.extent, spec.threads },
        ),
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

fn unaryActivationValue(
    inner: anytype,
    comptime activation: activation_mod.Kind,
    value: anytype,
) !@TypeOf(value) {
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

fn unaryActivationProgram(
    comptime spec: entry.Vector1D,
    comptime activation: activation_mod.Kind,
) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach1D(spec.axis, spec.extent, .{
                .args = args,
                .activation = activation,
            }, unary_activation_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_activation_{s}{}x{}_f32",
            .{ unaryActivationName(activation), spec.extent, spec.threads },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .src = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}

fn unaryActivationF32(
    comptime spec: entry.Vector1D,
    comptime activation: activation_mod.Kind,
) type {
    return entry.Entry(unaryActivationProgram(spec, activation), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.activation.{s}{}x{}_f32",
            .{ unaryActivationName(activation), spec.extent, spec.threads },
        ),
        .layer = .logical,
        .category = .elementwise,
        .specialization = unaryElementwiseSpecialization(
            spec,
            unaryActivationOperation(activation),
        ),
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
    return 0.5 * value * (1.0 + std.math.tanh(
        0.7978845608028654 * (value + 0.044715 * value * value * value),
    ));
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
        .name = std.fmt.comptimePrint(
            "accy_kernel_authored_elementwise_scale{}x{}_f32",
            .{ spec.extent, spec.threads },
        ),
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
        .target = std.fmt.comptimePrint(
            "accy.kernel.authored.elementwise.scale{}x{}_f32",
            .{ spec.extent, spec.threads },
        ),
        .layer = .authored,
        .category = .elementwise,
        .specialization = unaryElementwiseSpecialization(spec, .{ .elementwise = .scale }),
    });
}

pub const AuthoredScale8F32 = authoredScaleF32(.{ .extent = 8, .threads = 8 });
