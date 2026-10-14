const std = @import("std");
const testing = std.testing;

const core = @import("../model/core/root.zig");
const eval = @import("../../eval/root.zig");

const builder = core.builder;
const schedule_mod = core.schedule;

pub const enabled = true;
pub const Launch = schedule_mod.Launch;
pub const Argument = eval.KernelArgument;
pub const Machine = eval.Machine;
pub const Scalar = eval.Scalar;
pub const ExecutionDiagnostic = eval.Diagnostic;
pub const shared_alloc_sentinel = eval.shared_alloc_sentinel;
pub const tf32RoundF32 = eval.tf32RoundF32;

pub fn argumentBuffer(comptime T: type, values: []T) Argument {
    return .{ .memref = std.mem.sliceAsBytes(values) };
}

pub fn argumentBool(value: bool) Argument {
    return .{ .scalar = .{ .bool = value } };
}

pub fn argumentI32(value: i32) Argument {
    return .{ .scalar = .{ .i32 = value } };
}

pub fn argumentU32(value: u32) Argument {
    return .{ .scalar = .{ .u32 = value } };
}

pub fn argumentI64(value: i64) Argument {
    return .{ .scalar = .{ .i64 = value } };
}

pub fn argumentF32(value: f32) Argument {
    return .{ .scalar = .{ .f32 = value } };
}

pub fn argumentF64(value: f64) Argument {
    return .{ .scalar = .{ .f64 = value } };
}

pub fn run(
    allocator: std.mem.Allocator,
    kernel: *builder.Kernel,
    args: []const Argument,
    launch: Launch,
) !void {
    try kernel.verify();
    try eval.executeKernelFunction(allocator, kernel.func().op, args, launch);
}

pub fn runWithDiagnostic(
    allocator: std.mem.Allocator,
    kernel: *builder.Kernel,
    args: []const Argument,
    launch: Launch,
    diagnostic: *ExecutionDiagnostic,
) !void {
    diagnostic.len = 0;
    try kernel.verifyWithDiagnostic(diagnostic);
    try eval.executeKernelFunctionWithDiagnostic(
        allocator,
        kernel.func().op,
        args,
        launch,
        diagnostic,
    );
}

pub fn run1D(
    allocator: std.mem.Allocator,
    kernel: *builder.Kernel,
    args: []const Argument,
    extent: usize,
) !void {
    try run(allocator, kernel, args, Launch.oneDim(extent));
}

pub fn run1DWithDiagnostic(
    allocator: std.mem.Allocator,
    kernel: *builder.Kernel,
    args: []const Argument,
    extent: usize,
    diagnostic: *ExecutionDiagnostic,
) !void {
    try runWithDiagnostic(allocator, kernel, args, Launch.oneDim(extent), diagnostic);
}

fn expectApproxSlice(actual: []const f32, expected: []const f32) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |a, e| {
        try testing.expectApproxEqAbs(e, a, 0.0001);
    }
}

fn buildClampedFillKernel(allocator: std.mem.Allocator) !builder.Kernel {
    var b = try builder.Builder.init(
        allocator,
        builder.Builder.Limits.testing,
        "clamped_fill_f32",
        &.{
            builder.dynamicBuffer(.f32),
            builder.dynamicBuffer(.f32),
        },
        .{},
    );
    errdefer b.deinit();

    const src = b.argument(0);
    const dst = b.argument(1);
    const i = try b.globalId(.x);
    const x = try b.load(src, i);
    const zero = try b.constantFloat(.f32, 0.0);
    const pred = try b.compare(.gt, x, zero);
    var if_op = try b.if_(pred, &.{x.valueType()});

    {
        var scope = try b.enterBlock(if_op.thenBlock());
        defer scope.leave();
        try b.yield_(&.{x});
    }

    {
        var scope = try b.enterBlock(if_op.elseBlock().?);
        defer scope.leave();
        try b.yield_(&.{zero});
    }

    const clamped = if_op.result(0).?;
    const lower = try b.constantIndex(0);
    const upper = try b.constantIndex(4);
    const step = try b.constantIndex(1);
    var loop = try b.for_(lower, upper, step, &.{}, &.{});

    {
        var scope = try b.enterBlock(loop.bodyBlock());
        defer scope.leave();
        try b.store(clamped, dst, i);
        try b.yield_(&.{});
    }

    try b.return_();
    return b.finish();
}

const clamped_fill_input = [_]f32{ 1.5, -2.0, 3.25, -4.5, 0.5, -1.0, 2.0, 6.0 };
const clamped_fill_expected = [_]f32{ 1.5, 0.0, 3.25, 0.0, 0.5, 0.0, 2.0, 6.0 };

fn buildUnseededSharedKernel(allocator: std.mem.Allocator) !builder.Kernel {
    var b = try builder.Builder.init(
        allocator,
        builder.Builder.Limits.testing,
        "machine_shared_unseeded_i32",
        &.{
            builder.dynamicBuffer(.i32),
        },
        .{},
    );
    errdefer b.deinit();

    const out = b.argument(0);
    const i = try b.globalId(.x);
    const bins = try b.sharedBuffer(.i32, 4);
    const slot = try b.constantIndex(0);
    const one = try b.constantInt(.i32, 1);
    const old = try b.atomicRmw(.add, one, bins, slot);
    try b.store(old, out, i);
    try b.return_();
    return b.finish();
}

fn runMachineLifecycle(allocator: std.mem.Allocator, kernel: *builder.Kernel) !void {
    var machine = Machine.init(allocator);
    defer machine.deinit();

    var input = clamped_fill_input;
    var output = @as([8]f32, @splat(0));
    try machine.run(kernel.func().op, &.{
        argumentBuffer(f32, input[0..4]),
        argumentBuffer(f32, output[0..4]),
    }, Launch{ .grid = .{ 1, 1, 1 }, .block = .{ 4, 1, 1 } });
    for (output[0..4], clamped_fill_expected[0..4]) |actual, expected| {
        if (actual != expected) return error.TestUnexpectedResult;
    }

    try machine.run(kernel.func().op, &.{
        argumentBuffer(f32, input[0..]),
        argumentBuffer(f32, output[0..]),
    }, Launch{ .grid = .{ 1, 1, 1 }, .block = .{ 8, 1, 1 } });
    for (output[0..], clamped_fill_expected[0..]) |actual, expected| {
        if (actual != expected) return error.TestUnexpectedResult;
    }
}
