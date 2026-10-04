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
        .reductions = &.{
            entry.reduction("dot", .dot_product, entry.shape1D(spec.input_axis, spec.extent)),
        },
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

fn sum_step(
    fold_inner: anytype,
    offset: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
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
        .name = std.fmt.comptimePrint(
            "accy_kernel_reduction_sum{}x{}_f32",
            .{ spec.extent, spec.threads },
        ),
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

fn dot_step(
    fold_inner: anytype,
    offset: kernel.Value,
    acc: kernel.Value,
    ctx: anytype,
) !kernel.Value {
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
        .name = std.fmt.comptimePrint(
            "accy_kernel_reduction_dot{}x{}_f32",
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

pub fn sumF32(comptime spec: OneDimensional) type {
    return entry.Entry(sumProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.reduction.sum{}x{}_f32",
            .{ spec.extent, spec.threads },
        ),
        .layer = .logical,
        .category = .reduction,
        .specialization = sumSpecialization(spec),
    });
}

pub fn dotF32(comptime spec: OneDimensional) type {
    return entry.Entry(dotProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.reduction.dot{}x{}_f32",
            .{ spec.extent, spec.threads },
        ),
        .layer = .logical,
        .category = .reduction,
        .specialization = dotSpecialization(spec),
    });
}

pub const Sum8F32 = sumF32(.{ .extent = 8, .threads = 1 });
pub const Dot8F32 = dotF32(.{ .extent = 8, .threads = 1 });
