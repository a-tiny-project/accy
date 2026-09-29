const std = @import("std");
const gpu = @import("gpu");

const accy_choir = @import("../choir/root.zig");
const executable = @import("../executable/root.zig");
const kernel = @import("../kernel/root.zig");
const kernelization = @import("kernelization/root.zig");
const pipeline = @import("pipeline.zig");

const tensor = @import("../tensor/root.zig");
const SemanticBuilder = accy_choir.SemanticBuilder;
const SemanticModule = accy_choir.SemanticModule;

const element_count = 8;

fn runGeneratedProgram(
    allocator: std.mem.Allocator,
    program: *kernelization.GeneratedKernelProgram,
    args: []const kernel.Argument,
) !void {
    var executor = kernel.program.execution.Executor.init(program);
    defer executor.deinit();
    try executor.runCpu(allocator, args);
}

fn compileAndLoadSemanticModule(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    module: *SemanticModule,
    options: executable.FragmentCompilerOptions,
) !*executable.LoadedFragment {
    const compiled = try executable.compileFragmentFromSemanticModule(allocator, handle, module, options);
    return try executable.loadFragment(allocator, handle, compiled, options);
}

fn runSingleKernel(
    allocator: std.mem.Allocator,
    module: *SemanticModule,
    args: []const kernel.Argument,
) !void {
    const contract_module = try pipeline.prepareContractJobFromSemanticModule(allocator, module, .{});
    const tensor_module = try pipeline.prepareTensorJobFromContractJob(allocator, contract_module, .{});
    const dispatch_module = try pipeline.prepareDispatchJobFromTensorJob(allocator, tensor_module, .{});
    const memory_module = try pipeline.prepareMemoryJobFromDispatchJob(allocator, dispatch_module, .{});
    defer memory_module.deinit();

    var pass_ctx = memory_module.passContext();
    defer pass_ctx.deinit();
    const analysis = try kernelization.getKernelizationAnalysis(&pass_ctx, memory_module.choir_module);
    try std.testing.expectEqual(@as(usize, 1), analysis.kernelCount());
    try runGeneratedProgram(allocator, &analysis.kernels.items[0].program, args);
}

fn binaryF32Module(allocator: std.mem.Allocator, comptime op: enum { add, mul }) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{element_count});
    var fb = try builder.beginFunction("numerics_" ++ @tagName(op), &.{ vec_ty, vec_ty }, &.{vec_ty});
    const out = switch (op) {
        .add => try fb.add(fb.parameter(0), fb.parameter(1)),
        .mul => try fb.mul(fb.parameter(0), fb.parameter(1)),
    };
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn cumsumModule(allocator: std.mem.Allocator, comptime total: i64) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{total});
    var fb = try builder.beginFunction("numerics_cumsum_schedule", &.{vec_ty}, &.{vec_ty});
    const out_value = try fb.cumsum(fb.parameter(0), vec_ty, 0);
    try fb.return_(&.{out_value});
    try fb.finish();
    return try builder.finish();
}

fn expectCumsumGeneratedSchedule(comptime total: i64, expected_threads: u32, expected_blocks: u32) !void {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const module = try cumsumModule(allocator, total);
    var prepared = try executable.prepareFragmentFromSemanticModule(allocator, state.handle(), module, .{});
    defer prepared.deinit();

    try std.testing.expectEqual(@as(usize, 1), try prepared.generatedKernelCount());
    const summary = try prepared.generatedKernelSummary(0);
    try std.testing.expectEqual(kernelization.GeneratedScheduleKind.flat, summary.schedule.kind);
    try std.testing.expectEqual(expected_threads, summary.schedule.threads.x);
    var entry_buffer: [128]u8 = undefined;
    const expected_entry_part = try std.fmt.bufPrint(
        entry_buffer[0..],
        "scan_lookback_{d}x{d}_",
        .{ @as(u64, @intCast(total)), expected_blocks },
    );
    try std.testing.expect(std.mem.indexOf(u8, summary.entry_name, expected_entry_part) != null);
}

test "numerics: f32 add matches the host reference exactly" {
    const allocator = std.testing.allocator;
    const module = try binaryF32Module(allocator, .add);

    var lhs = [_]f32{ 1.0, -2.5, 3.25, 0.0, 1e6, -1e-6, 7.5, -8.0 };
    var rhs = [_]f32{ 0.5, 2.5, -3.25, -0.0, 1.0, 1e-6, 0.25, 8.0 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (lhs, rhs, out) |a, b, actual| {
        try std.testing.expectEqual(a + b, actual);
    }
}

test "numerics: f32 tanh stays within transcendental tolerance" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{element_count});
    var fb = try builder.beginFunction("numerics_tanh", &.{vec_ty}, &.{vec_ty});
    const out_value = try fb.tanh(fb.parameter(0));
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f32{ -4.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 4.0 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (input, out) |x, actual| {
        try std.testing.expectApproxEqAbs(std.math.tanh(x), actual, 0.000001);
    }
}

test "numerics: f32 atan2 handles finite quadrants" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{element_count});
    var fb = try builder.beginFunction("numerics_atan2", &.{ vec_ty, vec_ty }, &.{vec_ty});
    const out_value = try fb.atan2(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var y = [_]f32{ 1.0, 1.0, -1.0, -1.0, 0.5, -0.5, 2.0, -2.0 };
    var x = [_]f32{ 1.0, -1.0, -1.0, 1.0, 2.0, 2.0, -0.5, -0.5 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, y[0..]),
        kernel.argumentBuffer(f32, x[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (y, x, out) |yy, xx, actual| {
        try std.testing.expectApproxEqAbs(std.math.atan2(yy, xx), actual, 0.000001);
    }
}

test "numerics: f32 round matches the host reference bits" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{element_count});
    var fb = try builder.beginFunction("numerics_round", &.{vec_ty}, &.{vec_ty});
    const out_value = try fb.round(fb.parameter(0));
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f32{ -1.5, -0.5, -0.25, -0.0, 0.0, 0.25, 0.5, 1.5 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (input, out) |x, actual| {
        try std.testing.expectEqual(@as(u32, @bitCast(@round(x))), @as(u32, @bitCast(actual)));
    }
}

test "numerics: i32 mul matches the host reference exactly" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.i32, &.{element_count});
    var fb = try builder.beginFunction("numerics_i32_mul", &.{ vec_ty, vec_ty }, &.{vec_ty});
    const out_value = try fb.mul(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var lhs = [_]i32{ 1, -2, 3, 0, 100000, -7, 11, -13 };
    var rhs = [_]i32{ 5, 2, -3, 9, 3, -7, 0, 13 };
    var out = @as([element_count]i32, @splat(0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(i32, out[0..]),
        kernel.argumentBuffer(i32, lhs[0..]),
        kernel.argumentBuffer(i32, rhs[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (lhs, rhs, out) |a, b, actual| {
        try std.testing.expectEqual(a *% b, actual);
    }
}

test "numerics: f32 convert to i32 truncates toward zero" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{element_count});
    const out_ty = try builder.tensor(.i32, &.{element_count});
    var fb = try builder.beginFunction("numerics_convert", &.{in_ty}, &.{out_ty});
    const out_value = try fb.convert(fb.parameter(0), out_ty, .i32);
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f32{ 0.0, 1.5, -1.5, 2.9, -2.9, 100.0, -100.0, 0.4 };
    var out = @as([element_count]i32, @splat(0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(i32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (input, out) |x, actual| {
        try std.testing.expectEqual(@as(i32, @intFromFloat(x)), actual);
    }
}

test "numerics: fused f32 convert feeds i32 add" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{element_count});
    const i32_ty = try builder.tensor(.i32, &.{element_count});
    var fb = try builder.beginFunction("numerics_fused_convert_i32_add", &.{ in_ty, i32_ty }, &.{i32_ty});
    const converted = try fb.convert(fb.parameter(0), i32_ty, .i32);
    const out_value = try fb.add(converted, fb.parameter(1));
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f32{ 0.0, 1.5, -1.5, 2.9, -2.9, 100.0, -100.0, 0.4 };
    var bias = [_]i32{ 1, 2, 3, -4, -5, 6, 7, -8 };
    var out = @as([element_count]i32, @splat(0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(i32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, bias[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (input, bias, out) |x, y, actual| {
        try std.testing.expectEqual(@as(i32, @intFromFloat(x)) +% y, actual);
    }
}

test "numerics: fused f16 convert feeds f32 add" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const f16_ty = try builder.tensor(.f16, &.{element_count});
    const f32_ty = try builder.tensor(.f32, &.{element_count});
    var fb = try builder.beginFunction("numerics_fused_convert_f32_add", &.{ f16_ty, f32_ty }, &.{f32_ty});
    const converted = try fb.convert(fb.parameter(0), f32_ty, .f32);
    const out_value = try fb.add(converted, fb.parameter(1));
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f16{ 0.5, -1.0, 2.25, 0.0, 1.5, -0.25, 3.0, -2.0 };
    var bias = [_]f32{ 0.1, -0.2, 0.3, -0.4, 0.0, 0.5, -0.6, 0.7 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f16, input[0..]),
        kernel.argumentBuffer(f32, bias[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (input, bias, out) |x, y, actual| {
        try std.testing.expectApproxEqAbs(@as(f32, x) + y, actual, 0.000001);
    }
}

test "numerics: f32 reduce sum honors non-identity constant init" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{ 2, 4 });
    const init_ty = try builder.tensor(.f32, &.{});
    const out_ty = try builder.tensor(.f32, &.{2});
    var fb = try builder.beginFunction("numerics_reduce_init", &.{in_ty}, &.{out_ty});
    const bias = [_]f32{5.0};
    const init = try fb.constant(init_ty, std.mem.sliceAsBytes(bias[0..]));
    const out_value = try fb.reduce(fb.parameter(0), init, out_ty, "sum", &.{1});
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f32{ 1.0, 2.0, 3.0, 4.0, -1.0, -2.0, 0.5, 0.5 };
    var out = @as([2]f32, @splat(0.0));
    var count = [_]i32{2};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    try std.testing.expectApproxEqAbs(@as(f32, 15.0), out[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), out[1], 0.000001);
}

test "numerics: f32 reduce sum reads parameter init" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{ 2, 4 });
    const init_ty = try builder.tensor(.f32, &.{});
    const out_ty = try builder.tensor(.f32, &.{2});
    var fb = try builder.beginFunction("numerics_reduce_parameter_init", &.{ in_ty, init_ty }, &.{out_ty});
    const out_value = try fb.reduce(fb.parameter(0), fb.parameter(1), out_ty, "sum", &.{1});
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f32{ 1.0, 2.0, 3.0, 4.0, -1.0, -2.0, 0.5, 0.5 };
    var init = [_]f32{5.0};
    var out = @as([2]f32, @splat(0.0));
    var count = [_]i32{2};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, init[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    try std.testing.expectApproxEqAbs(@as(f32, 15.0), out[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), out[1], 0.000001);
}

test "numerics: f16 reduce sum rounds through half precision" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f16, &.{ 2, 4 });
    const init_ty = try builder.tensor(.f16, &.{});
    const out_ty = try builder.tensor(.f16, &.{2});
    var fb = try builder.beginFunction("numerics_f16_reduce_sum", &.{ in_ty, init_ty }, &.{out_ty});
    const out_value = try fb.reduce(fb.parameter(0), fb.parameter(1), out_ty, "sum", &.{1});
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f16{ 1.0, 2.0, 3.0, 4.0, -1.0, -2.0, 0.5, 0.5 };
    var init = [_]f16{5.0};
    var out = @as([2]f16, @splat(0.0));
    var count = [_]i32{2};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f16, out[0..]),
        kernel.argumentBuffer(f16, input[0..]),
        kernel.argumentBuffer(f16, init[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    try std.testing.expectApproxEqAbs(@as(f32, 15.0), @as(f32, out[0]), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), @as(f32, out[1]), 0.001);
}

test "numerics: i32 reduce max reads parameter init" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.i32, &.{ 2, 4 });
    const init_ty = try builder.tensor(.i32, &.{});
    const out_ty = try builder.tensor(.i32, &.{2});
    var fb = try builder.beginFunction("numerics_i32_reduce_parameter_init", &.{ in_ty, init_ty }, &.{out_ty});
    const out_value = try fb.reduce(fb.parameter(0), fb.parameter(1), out_ty, "max", &.{1});
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]i32{ -4, -3, -2, -1, 1, 7, 3, 5 };
    var init = [_]i32{0};
    var out = @as([2]i32, @splat(0));
    var count = [_]i32{2};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(i32, out[0..]),
        kernel.argumentBuffer(i32, input[0..]),
        kernel.argumentBuffer(i32, init[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    try std.testing.expectEqual(@as(i32, 0), out[0]);
    try std.testing.expectEqual(@as(i32, 7), out[1]);
}

test "numerics: f32 fused compare select picks the smaller operand" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{element_count});
    const pred_ty = try builder.tensor(.i1, &.{element_count});
    var fb = try builder.beginFunction("numerics_compare_select", &.{ vec_ty, vec_ty }, &.{vec_ty});
    const pred = try fb.compare(fb.parameter(0), fb.parameter(1), pred_ty, .lt);
    const out_value = try fb.select(pred, fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var lhs = [_]f32{ 1.0, -2.5, 3.25, 0.0, 7.0, -8.0, 0.5, 2.0 };
    var rhs = [_]f32{ 0.5, 2.5, -3.25, -1.0, 7.5, -9.0, 0.5, 1.0 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (lhs, rhs, out) |a, b, actual| {
        try std.testing.expectEqual(@min(a, b), actual);
    }
}

test "numerics: returned compare mask stores byte-sized bools" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{element_count});
    const pred_ty = try builder.tensor(.i1, &.{element_count});
    var fb = try builder.beginFunction("numerics_compare_mask", &.{ vec_ty, vec_ty }, &.{pred_ty});
    const out_value = try fb.compare(fb.parameter(0), fb.parameter(1), pred_ty, .lt);
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var lhs = [_]f32{ 1.0, -2.5, 3.25, 0.0, 7.0, -8.0, 0.5, 2.0 };
    var rhs = [_]f32{ 0.5, 2.5, -3.25, -1.0, 7.5, -9.0, 0.5, 1.0 };
    var out = @as([element_count]bool, @splat(false));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(bool, out[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (lhs, rhs, out) |a, b, actual| {
        try std.testing.expectEqual(a < b, actual);
    }
}

test "numerics: external bool mask feeds select" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{element_count});
    const pred_ty = try builder.tensor(.i1, &.{element_count});
    var fb = try builder.beginFunction("numerics_external_mask_select", &.{ pred_ty, vec_ty, vec_ty }, &.{vec_ty});
    const out_value = try fb.select(fb.parameter(0), fb.parameter(1), fb.parameter(2));
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var mask = [_]bool{ true, false, true, false, false, true, true, false };
    var on_true = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    var on_false = [_]f32{ -1.0, -2.0, -3.0, -4.0, -5.0, -6.0, -7.0, -8.0 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(bool, mask[0..]),
        kernel.argumentBuffer(f32, on_true[0..]),
        kernel.argumentBuffer(f32, on_false[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (mask, on_true, on_false, out) |take_true, yes, no, actual| {
        try std.testing.expectEqual(if (take_true) yes else no, actual);
    }
}

test "numerics: ordered compare treats NaN as false and select takes the other branch" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{element_count});
    const pred_ty = try builder.tensor(.i1, &.{element_count});
    var fb = try builder.beginFunction("numerics_nan_compare", &.{ vec_ty, vec_ty }, &.{vec_ty});
    const pred = try fb.compare(fb.parameter(0), fb.parameter(1), pred_ty, .lt);
    const out_value = try fb.select(pred, fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    var lhs = [_]f32{ nan, 1.0, nan, -inf, inf, 0.0, nan, 2.0 };
    var rhs = [_]f32{ 1.0, nan, nan, 0.0, inf, -0.0, -inf, 3.0 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (lhs, rhs, out) |a, b, actual| {
        const expected = if (a < b) a else b;
        if (std.math.isNan(expected)) {
            try std.testing.expect(std.math.isNan(actual));
        } else {
            try std.testing.expectEqual(expected, actual);
        }
    }
}

test "numerics: f32 min and max propagate NaN like the host" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{element_count});
    var fb = try builder.beginFunction("numerics_minmax_nan", &.{ vec_ty, vec_ty }, &.{vec_ty});
    const low = try fb.min(fb.parameter(0), fb.parameter(1));
    const out_value = try fb.max(low, fb.parameter(1));
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    var lhs = [_]f32{ nan, 1.0, -inf, inf, 0.0, -1.0, nan, 4.0 };
    var rhs = [_]f32{ 1.0, nan, 0.0, inf, -0.0, -2.0, nan, 3.0 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (lhs, rhs, out) |a, b, actual| {
        const expected = @max(@min(a, b), b);
        if (std.math.isNan(expected)) {
            try std.testing.expect(std.math.isNan(actual));
        } else {
            try std.testing.expectEqual(expected, actual);
        }
    }
}

test "numerics: transpose moves every element exactly" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{ 2, 4 });
    const out_ty = try builder.tensor(.f32, &.{ 4, 2 });
    var fb = try builder.beginFunction("numerics_transpose", &.{in_ty}, &.{out_ty});
    const out_value = try fb.transpose(fb.parameter(0), out_ty, &.{ 1, 0 });
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    try std.testing.expectEqualSlices(f32, &.{ 1.0, 5.0, 2.0, 6.0, 3.0, 7.0, 4.0, 8.0 }, out[0..]);
}

test "numerics: reshape preserves row-major element order exactly" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{ 2, 4 });
    const out_ty = try builder.tensor(.f32, &.{ 4, 2 });
    var fb = try builder.beginFunction("numerics_reshape", &.{in_ty}, &.{out_ty});
    const out_value = try fb.reshape(fb.parameter(0), out_ty, &.{ 4, 2 });
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    try std.testing.expectEqualSlices(f32, input[0..], out[0..]);
}

test "numerics: slice strides select exact elements" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{element_count});
    const out_ty = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("numerics_slice", &.{in_ty}, &.{out_ty});
    const out_value = try fb.slice(fb.parameter(0), out_ty, &.{1}, &.{8}, &.{2});
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f32{ 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0 };
    var out = @as([4]f32, @splat(0.0));
    var count = [_]i32{4};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    try std.testing.expectEqualSlices(f32, &.{ 11.0, 13.0, 15.0, 17.0 }, out[0..]);
}

test "numerics: gather selects exactly the indexed elements" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{element_count});
    const indices_ty = try builder.tensor(.i32, &.{4});
    const out_ty = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("numerics_gather", &.{ in_ty, indices_ty }, &.{out_ty});
    const out_value = try fb.gather(fb.parameter(0), fb.parameter(1), out_ty, 0);
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f32{ 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0 };
    var indices = [_]i32{ 7, 0, 3, 3 };
    var out = @as([4]f32, @splat(0.0));
    var count = [_]i32{4};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, indices[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    try std.testing.expectEqualSlices(f32, &.{ 17.0, 10.0, 13.0, 13.0 }, out[0..]);
}

test "numerics: pad fills low and high edges exactly" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{4});
    const fill_ty = try builder.tensor(.f32, &.{});
    const out_ty = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("numerics_pad", &.{ in_ty, fill_ty }, &.{out_ty});
    const out_value = try fb.pad(fb.parameter(0), fb.parameter(1), out_ty, &.{2}, &.{2}, &.{0});
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var fill = [_]f32{-1.0};
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, fill[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    try std.testing.expectEqualSlices(f32, &.{ -1.0, -1.0, 1.0, 2.0, 3.0, 4.0, -1.0, -1.0 }, out[0..]);
}

test "numerics: concatenate appends operands exactly" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{4});
    const out_ty = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("numerics_concatenate", &.{ vec_ty, vec_ty }, &.{out_ty});
    const out_value = try fb.concatenate(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, 0);
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var lhs = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var rhs = [_]f32{ 5.0, 6.0, 7.0, 8.0 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    try std.testing.expectEqualSlices(f32, &.{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 }, out[0..]);
}

test "numerics: scatter writes updates at exact indices" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const in_ty = try builder.tensor(.f32, &.{8});
    const indices_ty = try builder.tensor(.i32, &.{4});
    const updates_ty = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("numerics_scatter", &.{ in_ty, indices_ty, updates_ty }, &.{in_ty});
    const out_value = try fb.scatter(fb.parameter(0), fb.parameter(1), fb.parameter(2), in_ty, 0);
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f32{ 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0 };
    var indices = [_]i32{ 6, 1, 4, 3 };
    var updates = [_]f32{ 60.0, 10.0, 40.0, 30.0 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, indices[0..]),
        kernel.argumentBuffer(f32, updates[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    try std.testing.expectEqualSlices(f32, &.{ 10.0, 10.0, 12.0, 30.0, 40.0, 15.0, 60.0, 17.0 }, out[0..]);
}

test "numerics: fused elementwise chain lowers to one kernel and computes exactly" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{element_count});
    var fb = try builder.beginFunction("numerics_fused_chain", &.{ vec_ty, vec_ty, vec_ty }, &.{vec_ty});
    const product = try fb.mul(fb.parameter(0), fb.parameter(1));
    const shifted = try fb.add(product, fb.parameter(2));
    const out_value = try fb.tanh(shifted);
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var a = [_]f32{ 0.5, -1.0, 2.0, 0.0, 1.5, -0.25, 3.0, -2.0 };
    var b = [_]f32{ 2.0, 0.5, -1.0, 4.0, 1.0, 8.0, -0.5, 0.75 };
    var c = [_]f32{ 0.1, -0.2, 0.3, -0.4, 0.0, 0.5, -0.6, 0.7 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, a[0..]),
        kernel.argumentBuffer(f32, b[0..]),
        kernel.argumentBuffer(f32, c[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (a, b, c, out) |x, y, z, actual| {
        try std.testing.expectApproxEqAbs(std.math.tanh(x * y + z), actual, 0.000001);
    }
}

test "numerics: iterate runs per-element do-while trip counts" {
    const allocator = std.testing.allocator;

    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{element_count});
    const pred_ty = try builder.tensor(.i1, &.{element_count});
    var fb = try builder.beginFunction("numerics_iterate", &.{vec_ty}, &.{vec_ty});

    var it = try fb.beginIterate(&.{fb.parameter(0)}, 10);
    const body = it.inner();
    var ones: [element_count]f32 = @splat(1.0);
    var limits: [element_count]f32 = @splat(5.0);
    const one = try body.constant(vec_ty, std.mem.sliceAsBytes(ones[0..]));
    const limit = try body.constant(vec_ty, std.mem.sliceAsBytes(limits[0..]));
    const stepped = try body.add(it.carry(0), one);
    const active = try body.compare(stepped, limit, pred_ty, .lt);
    try it.yield_(active, &.{stepped});

    try fb.return_(&.{it.result(0)});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f32{ 0.0, 3.5, 4.0, 4.5, 7.0, -100.0, 4.999, -2.25 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (input, out) |start, actual| {
        var value = start;
        var iters: usize = 0;
        while (iters < 10) : (iters += 1) {
            value += 1.0;
            if (!(value < 5.0)) break;
        }
        try std.testing.expectApproxEqAbs(value, actual, 0.00001);
    }
}

test "numerics: cumsum lookback kernel matches the host on CUDA" {
    const allocator = std.testing.allocator;
    var state = gpu.cuda.State.initDevice(allocator, 0) catch return error.SkipZigTest;
    defer state.deinit();

    const total = 16384;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{total});
    var fb = try builder.beginFunction("probe_scan", &.{vec_ty}, &.{vec_ty});
    const out_value = try fb.cumsum(fb.parameter(0), vec_ty, 0);
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{},
    );
    defer fragment.deinit();
    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());

    var input: [total]f32 = undefined;
    for (input[0..], 0..) |*value, index| value.* = @sin(@as(f32, @floatFromInt(index)) * 0.01) + 0.5;
    var out = @as([total]f32, @splat(0.0));
    var outputs = [_][]u8{std.mem.sliceAsBytes(out[0..])};
    try executable.invoke(fragment, allocator, allocator, &.{std.mem.sliceAsBytes(input[0..])}, &outputs);

    var acc: f64 = 0;
    var worst: f64 = 0;
    for (0..total) |i| {
        acc += input[i];
        worst = @max(worst, @abs(acc - out[i]));
    }
    try std.testing.expect(worst < 0.01);
}

test "numerics: cumsum generated scan chooses adaptive block schedule" {
    try expectCumsumGeneratedSchedule(4096, 256, 1);
    try expectCumsumGeneratedSchedule(8192, 512, 1);
    try expectCumsumGeneratedSchedule(12288, 256, 3);
}

test "numerics: cumsum scans a vector to one kernel and matches the host" {
    const allocator = std.testing.allocator;
    const total = 1000;

    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{total});
    var fb = try builder.beginFunction("numerics_cumsum", &.{vec_ty}, &.{vec_ty});
    const out_value = try fb.cumsum(fb.parameter(0), vec_ty, 0);
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input: [total]f32 = undefined;
    for (input[0..], 0..) |*value, index| {
        value.* = @sin(@as(f32, @floatFromInt(index)) * 0.1) + 0.25;
    }
    var out = @as([total]f32, @splat(0.0));
    var count = [_]i32{total};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    var acc: f64 = 0;
    for (0..total) |i| {
        acc += input[i];
        try std.testing.expectApproxEqAbs(@as(f32, @floatCast(acc)), out[i], 0.002);
    }
}

const flash_attention_seq = 128;
const flash_attention_head = 64;

fn flashAttentionModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const qkv_ty = try builder.tensor(.f32, &.{ flash_attention_seq, flash_attention_head });
    const kt_ty = try builder.tensor(.f32, &.{ flash_attention_head, flash_attention_seq });
    const scores_ty = try builder.tensor(.f32, &.{ flash_attention_seq, flash_attention_seq });
    const row_ty = try builder.tensor(.f32, &.{flash_attention_seq});
    const scalar_ty = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("numerics_flash", &.{ qkv_ty, kt_ty, qkv_ty }, &.{qkv_ty});
    const q = fb.parameter(0);
    const kt = fb.parameter(1);
    const v = fb.parameter(2);
    const raw_scores = try fb.dotGeneral(q, kt, scores_ty, &.{1}, &.{0}, &.{}, &.{});
    const scale_scalar = try fb.constant(scalar_ty, std.mem.asBytes(&@as(f32, 0.125)));
    const scale = try fb.broadcast(scale_scalar, scores_ty, &.{ flash_attention_seq, flash_attention_seq });
    const scores = try fb.mul(raw_scores, scale);
    const lowest = try fb.constant(scalar_ty, std.mem.asBytes(&@as(f32, -std.math.floatMax(f32))));
    const row_max = try fb.reduce(scores, lowest, row_ty, "max", &.{1});
    const shifted = try fb.sub(scores, try fb.broadcastInDim(row_max, scores_ty, &.{ flash_attention_seq, flash_attention_seq }, &.{0}));
    const exps = try fb.exp(shifted);
    const zero = try fb.constant(scalar_ty, std.mem.asBytes(&@as(f32, 0.0)));
    const row_sum = try fb.reduce(exps, zero, row_ty, "sum", &.{1});
    const ones_data = @as([flash_attention_seq]f32, @splat(1.0));
    const ones = try fb.constant(row_ty, std.mem.sliceAsBytes(ones_data[0..]));
    const inverse_sum = try fb.div(ones, row_sum);
    const probs = try fb.mul(exps, try fb.broadcastInDim(inverse_sum, scores_ty, &.{ flash_attention_seq, flash_attention_seq }, &.{0}));
    const out_value = try fb.dotGeneral(probs, v, qkv_ty, &.{1}, &.{0}, &.{}, &.{});
    try fb.return_(&.{out_value});
    try fb.finish();
    return try builder.finish();
}

test "numerics: reciprocal-normalized flash attention has one CUDA schedule" {
    const allocator = std.testing.allocator;

    var recording = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    const module = try flashAttentionModule(allocator);
    var prepared = try executable.prepareFragmentFromSemanticModule(
        allocator,
        recording.handle(),
        module,
        .{},
    );
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 1), try prepared.generatedKernelCount());
    const generated = try prepared.generatedKernelSummary(0);
    try std.testing.expectEqual(kernelization.GeneratedScheduleKind.matrix, generated.schedule.kind);
    try std.testing.expectEqual(@as(u32, 16), generated.schedule.threads.x);
    try std.testing.expectEqual(@as(u32, 8), generated.schedule.threads.y);
    try std.testing.expect(std.mem.indexOf(u8, generated.entry_name, "flash_attention") != null);
}

test "numerics: iterate carries multiple states with per-element exits" {
    const allocator = std.testing.allocator;

    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{element_count});
    const pred_ty = try builder.tensor(.i1, &.{element_count});
    var fb = try builder.beginFunction("numerics_iterate_pair", &.{ vec_ty, vec_ty }, &.{ vec_ty, vec_ty });

    var it = try fb.beginIterate(&.{ fb.parameter(0), fb.parameter(1) }, 12);
    const body = it.inner();
    var halves: [element_count]f32 = @splat(0.5);
    var limits: [element_count]f32 = @splat(20.0);
    const half = try body.constant(vec_ty, std.mem.sliceAsBytes(halves[0..]));
    const limit = try body.constant(vec_ty, std.mem.sliceAsBytes(limits[0..]));
    const stepped = try body.add(it.carry(0), it.carry(1));
    const decayed = try body.mul(it.carry(1), half);
    const active = try body.compare(stepped, limit, pred_ty, .lt);
    try it.yield_(active, &.{ stepped, decayed });

    try fb.return_(&.{ it.result(0), it.result(1) });
    try fb.finish();
    const module = try builder.finish();

    var a = [_]f32{ 0.0, 5.0, 18.0, 30.0, 1.0, -4.0, 10.0, 19.0 };
    var b = [_]f32{ 4.0, 8.0, 1.0, 2.0, 16.0, 3.0, 0.5, 2.0 };
    var out_a = @as([element_count]f32, @splat(0.0));
    var out_b = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    const contract_module = try pipeline.prepareContractJobFromSemanticModule(allocator, module, .{});
    const tensor_module = try pipeline.prepareTensorJobFromContractJob(allocator, contract_module, .{});
    const dispatch_module = try pipeline.prepareDispatchJobFromTensorJob(allocator, tensor_module, .{});
    const memory_module = try pipeline.prepareMemoryJobFromDispatchJob(allocator, dispatch_module, .{});
    defer memory_module.deinit();

    var pass_ctx = memory_module.passContext();
    defer pass_ctx.deinit();
    const analysis = try kernelization.getKernelizationAnalysis(&pass_ctx, memory_module.choir_module);
    try std.testing.expectEqual(@as(usize, 1), analysis.kernelCount());
    try runGeneratedProgram(allocator, &analysis.kernels.items[0].program, &.{
        kernel.argumentBuffer(f32, out_a[0..]),
        kernel.argumentBuffer(f32, a[0..]),
        kernel.argumentBuffer(f32, b[0..]),
        kernel.argumentBuffer(f32, out_b[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (0..element_count) |i| {
        var av = a[i];
        var bv = b[i];
        var iters: usize = 0;
        while (iters < 12) : (iters += 1) {
            const na = av + bv;
            const nb = bv * 0.5;
            av = na;
            bv = nb;
            if (!(av < 20.0)) break;
        }
        try std.testing.expectApproxEqAbs(av, out_a[i], 0.0001);
        try std.testing.expectApproxEqAbs(bv, out_b[i], 0.0001);
    }
}

test "numerics: layernorm row pipeline lowers to one kernel and matches the host" {
    const allocator = std.testing.allocator;
    const rows = 2;
    const cols = 1024;

    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const mat_ty = try builder.tensor(.f32, &.{ rows, cols });
    const row_ty = try builder.tensor(.f32, &.{rows});
    const col_ty = try builder.tensor(.f32, &.{cols});
    const scalar_ty = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("numerics_layernorm_rows", &.{ mat_ty, col_ty, col_ty }, &.{mat_ty});
    const x = fb.parameter(0);
    const gamma = fb.parameter(1);
    const beta = fb.parameter(2);

    const zero = try fb.constant(scalar_ty, std.mem.asBytes(&@as(f32, 0.0)));
    const row_sum = try fb.reduce(x, zero, row_ty, "sum", &.{1});
    const inv_cols_values = @as([rows]f32, @splat(1.0 / @as(f32, cols)));
    const inv_cols = try fb.constant(row_ty, std.mem.sliceAsBytes(inv_cols_values[0..]));
    const mean = try fb.mul(row_sum, inv_cols);
    const mean_b = try fb.broadcastInDim(mean, mat_ty, &.{ rows, cols }, &.{0});
    const centered = try fb.sub(x, mean_b);
    const centered_squared = try fb.mul(centered, centered);
    const square_sum = try fb.reduce(centered_squared, zero, row_ty, "sum", &.{1});
    const variance = try fb.mul(square_sum, inv_cols);
    const eps_values = @as([rows]f32, @splat(0.00001));
    const eps = try fb.constant(row_ty, std.mem.sliceAsBytes(eps_values[0..]));
    const variance_eps = try fb.add(variance, eps);
    const stddev = try fb.sqrt(variance_eps);
    const one_values = @as([rows]f32, @splat(1.0));
    const one = try fb.constant(row_ty, std.mem.sliceAsBytes(one_values[0..]));
    const inv_std = try fb.div(one, stddev);
    const inv_std_b = try fb.broadcastInDim(inv_std, mat_ty, &.{ rows, cols }, &.{0});
    const normalized = try fb.mul(centered, inv_std_b);
    const gamma_b = try fb.broadcastInDim(gamma, mat_ty, &.{ rows, cols }, &.{1});
    const scaled = try fb.mul(normalized, gamma_b);
    const beta_b = try fb.broadcastInDim(beta, mat_ty, &.{ rows, cols }, &.{1});
    const out_value = try fb.add(scaled, beta_b);
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input: [rows * cols]f32 = undefined;
    for (input[0..], 0..) |*value, index| {
        const col: f32 = @floatFromInt(index % cols);
        const row: f32 = @floatFromInt(index / cols);
        value.* = @sin(col * 0.02) * 1.5 + row * 0.25 + col * 0.001;
    }
    var gamma_values: [cols]f32 = undefined;
    var beta_values: [cols]f32 = undefined;
    for (0..cols) |col| {
        gamma_values[col] = 0.75 + 0.5 * @as(f32, @floatFromInt(col % 7)) / 7.0;
        beta_values[col] = -0.25 + 0.1 * @as(f32, @floatFromInt(col % 5));
    }
    var out = @as([(rows * cols)]f32, @splat(0.0));
    var count = [_]i32{rows * cols};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(f32, gamma_values[0..]),
        kernel.argumentBuffer(f32, beta_values[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (0..rows) |row| {
        var mean_acc: f32 = 0;
        for (0..cols) |col| mean_acc += input[row * cols + col];
        const mean_host = mean_acc / cols;
        var var_acc: f32 = 0;
        for (0..cols) |col| {
            const centered_host = input[row * cols + col] - mean_host;
            var_acc += centered_host * centered_host;
        }
        const inv_std_host = 1.0 / @sqrt(var_acc / cols + 0.00001);
        for (0..cols) |col| {
            const expected = (input[row * cols + col] - mean_host) * inv_std_host * gamma_values[col] + beta_values[col];
            try std.testing.expectApproxEqAbs(expected, out[row * cols + col], 0.001);
        }
    }
}

test "numerics: softmax row pipeline lowers to one kernel and matches the host" {
    const allocator = std.testing.allocator;
    const rows = 2;
    const cols = 1024;

    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const mat_ty = try builder.tensor(.f32, &.{ rows, cols });
    const row_ty = try builder.tensor(.f32, &.{rows});
    const scalar_ty = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("numerics_softmax_rows", &.{mat_ty}, &.{mat_ty});
    const neg_inf = try fb.constant(scalar_ty, std.mem.asBytes(&@as(f32, -std.math.inf(f32))));
    const zero = try fb.constant(scalar_ty, std.mem.asBytes(&@as(f32, 0.0)));
    const row_max = try fb.reduce(fb.parameter(0), neg_inf, row_ty, "max", &.{1});
    const max_full = try fb.broadcastInDim(row_max, mat_ty, &.{ rows, cols }, &.{0});
    const shifted = try fb.sub(fb.parameter(0), max_full);
    const exps = try fb.exp(shifted);
    const row_sum = try fb.reduce(exps, zero, row_ty, "sum", &.{1});
    const sum_full = try fb.broadcastInDim(row_sum, mat_ty, &.{ rows, cols }, &.{0});
    const out_value = try fb.div(exps, sum_full);
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input: [rows * cols]f32 = undefined;
    for (input[0..], 0..) |*value, index| {
        const row: f32 = @floatFromInt(index / cols);
        const col: f32 = @floatFromInt(index % cols);
        value.* = @sin(col * 0.01) * 2.0 + row * 0.5 - col * 0.0005;
    }
    var out = @as([(rows * cols)]f32, @splat(0.0));
    var count = [_]i32{rows * cols};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (0..rows) |row| {
        var host_max: f32 = -std.math.inf(f32);
        for (0..cols) |col| {
            host_max = @max(host_max, input[row * cols + col]);
        }
        var host_sum: f32 = 0.0;
        for (0..cols) |col| {
            host_sum += @exp(input[row * cols + col] - host_max);
        }
        for (0..cols) |col| {
            const expected = @exp(input[row * cols + col] - host_max) / host_sum;
            try std.testing.expectApproxEqAbs(expected, out[row * cols + col], 0.00001);
        }
    }
}

fn gradLoss(_: *tensor.trace.Builder, args: []const tensor.trace.Value) !tensor.trace.Value {
    const product = try args[0].mul(args[1]);
    return try product.sum(.lane);
}

test "numerics: gradient of sum of products equals the other operand" {
    const allocator = std.testing.allocator;
    var source = try tensor.trace.define(allocator, "numerics_grad", &.{
        tensor.spec(.f32, .{ .lane = element_count }),
        tensor.spec(.f32, .{ .lane = element_count }),
    }, gradLoss);
    defer source.deinit();

    var differentiated = try tensor.grad(allocator, &source, .{ .wrt = &.{0} });
    defer differentiated.deinit();

    const module = try tensor.toSemanticModule(allocator, &differentiated);

    var a = [_]f32{ 1.0, -2.0, 3.0, 0.5, -0.25, 4.0, 7.0, -8.0 };
    var b = [_]f32{ 2.0, 0.5, -1.5, 8.0, 4.0, -0.125, 0.0, 1.0 };
    var out = @as([element_count]f32, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, a[0..]),
        kernel.argumentBuffer(f32, b[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    try std.testing.expectEqualSlices(f32, b[0..], out[0..]);
}

test "numerics: one lowered kernel serves multiple effective extents through its count guard" {
    const allocator = std.testing.allocator;
    const module = try binaryF32Module(allocator, .add);

    const contract_module = try pipeline.prepareContractJobFromSemanticModule(allocator, module, .{});
    const tensor_module = try pipeline.prepareTensorJobFromContractJob(allocator, contract_module, .{});
    const dispatch_module = try pipeline.prepareDispatchJobFromTensorJob(allocator, tensor_module, .{});
    const memory_module = try pipeline.prepareMemoryJobFromDispatchJob(allocator, dispatch_module, .{});
    defer memory_module.deinit();

    var pass_ctx = memory_module.passContext();
    defer pass_ctx.deinit();
    const analysis = try kernelization.getKernelizationAnalysis(&pass_ctx, memory_module.choir_module);
    try std.testing.expectEqual(@as(usize, 1), analysis.kernelCount());
    const program = &analysis.kernels.items[0].program;

    var lhs = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    var rhs = [_]f32{ 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0 };

    var full_out = @as([element_count]f32, @splat(0.0));
    var full_count = [_]i32{element_count};
    try runGeneratedProgram(allocator, program, &.{
        kernel.argumentBuffer(f32, full_out[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
        kernel.argumentBuffer(i32, full_count[0..]),
    });
    try std.testing.expectEqualSlices(f32, &.{ 11.0, 22.0, 33.0, 44.0, 55.0, 66.0, 77.0, 88.0 }, full_out[0..]);

    var short_out = @as([element_count]f32, @splat(0.0));
    var short_count = [_]i32{5};
    try runGeneratedProgram(allocator, program, &.{
        kernel.argumentBuffer(f32, short_out[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
        kernel.argumentBuffer(i32, short_count[0..]),
    });
    try std.testing.expectEqualSlices(f32, &.{ 11.0, 22.0, 33.0, 44.0, 55.0, 0.0, 0.0, 0.0 }, short_out[0..]);
}

const IdentitySide = enum { left, right };

fn matrixIdentityModule(
    allocator: std.mem.Allocator,
    side: IdentitySide,
    constant_identity: bool,
) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const ty = try builder.tensor(.f32, &.{ 2, 2 });
    var fb = try builder.beginFunction(
        "matrix_identity",
        if (constant_identity) &.{ty} else &.{ ty, ty },
        &.{ty},
    );
    const payload = [_]f32{ 1, 0, 0, 1 };
    const identity = if (constant_identity)
        try fb.constant(ty, std.mem.sliceAsBytes(&payload))
    else
        fb.parameter(1);
    const lhs = if (side == .left) identity else fb.parameter(0);
    const rhs = if (side == .right) identity else fb.parameter(0);
    const product = try fb.dotGeneral(lhs, rhs, ty, &.{1}, &.{0}, &.{}, &.{});
    try fb.return_(&.{product});
    try fb.finish();
    return try builder.finish();
}

fn matrixIdentityReference(side: IdentitySide, input: [4]f32) [4]f32 {
    @setFloatMode(.strict);
    const identity = [_]f32{ 1, 0, 0, 1 };
    const lhs = if (side == .left) identity else input;
    const rhs = if (side == .right) identity else input;
    var output: [4]f32 = undefined;
    for (0..2) |row| {
        for (0..2) |column| {
            var sum: f32 = 0;
            for (0..2) |inner| sum += lhs[row * 2 + inner] * rhs[inner * 2 + column];
            output[row * 2 + column] = sum;
        }
    }
    return output;
}

fn expectF32Observation(expected: f32, actual: f32) !void {
    if (std.math.isNan(expected)) {
        try std.testing.expect(std.math.isNan(actual));
    } else {
        try std.testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(actual)));
    }
}

fn expectMatrixIdentityExecution(side: IdentitySide) !void {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const options = executable.FragmentCompilerOptions{ .artifact_format = .cpu_object };
    const folded = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        try matrixIdentityModule(allocator, side, true),
        options,
    );
    defer folded.deinit();
    const runtime = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        try matrixIdentityModule(allocator, side, false),
        options,
    );
    defer runtime.deinit();
    const cases = [_][4]f32{
        .{ 1.5, -2.25, 0.125, 42 },
        .{ std.math.inf(f32), 1, 2, 3 },
        .{ -std.math.inf(f32), 1, 2, 3 },
        .{ std.math.nan(f32), 1, 2, 3 },
        .{ -0.0, -0.0, -0.0, -0.0 },
        .{ 0.0, -0.0, -0.0, 0.0 },
    };
    const identity = [_]f32{ 1, 0, 0, 1 };
    for (cases) |input| {
        var folded_output: [4]f32 = undefined;
        var runtime_output: [4]f32 = undefined;
        const input_bytes = std.mem.sliceAsBytes(&input);
        try executable.invoke(folded, allocator, allocator, &.{input_bytes}, &.{
            std.mem.sliceAsBytes(&folded_output),
        });
        try executable.invoke(runtime, allocator, allocator, &.{
            input_bytes, std.mem.sliceAsBytes(&identity),
        }, &.{std.mem.sliceAsBytes(&runtime_output)});
        const expected = matrixIdentityReference(side, input);
        for (expected, runtime_output, folded_output) |reference, dynamic, constant| {
            try expectF32Observation(reference, dynamic);
            try expectF32Observation(reference, constant);
        }
    }
}

test "numerics: matrix identity on the left preserves floating observations" {
    try expectMatrixIdentityExecution(.left);
}

test "numerics: matrix identity on the right preserves floating observations" {
    try expectMatrixIdentityExecution(.right);
}

test "numerics: dot general matmul accumulates exactly on the oracle" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 3, 4 });
    const rhs_ty = try builder.tensor(.f32, &.{ 4, 5 });
    const out_ty = try builder.tensor(.f32, &.{ 3, 5 });
    var fb = try builder.beginFunction("numerics_dot_general", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out_value = try fb.dotGeneral(fb.parameter(0), fb.parameter(1), out_ty, &.{1}, &.{0}, &.{}, &.{});
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var lhs: [12]f32 = undefined;
    for (&lhs, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index)) * 0.5 - 2.0;
    var rhs: [20]f32 = undefined;
    for (&rhs, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index % 7)) - 3.0;

    var expected: [15]f32 = undefined;
    for (0..3) |row| {
        for (0..5) |col| {
            var sum: f32 = 0.0;
            for (0..4) |inner| {
                sum += lhs[row * 4 + inner] * rhs[inner * 5 + col];
            }
            expected[row * 5 + col] = sum;
        }
    }

    var out = @as([15]f32, @splat(0.0));
    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, lhs[0..]),
        kernel.argumentBuffer(f32, rhs[0..]),
    });
    try std.testing.expectEqualSlices(f32, expected[0..], out[0..]);
}

test "numerics: gather fuses into its consumer chain and matches the host" {
    const allocator = std.testing.allocator;
    const total = 512;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{total});
    const idx_ty = try builder.tensor(.i32, &.{total});
    const scalar_ty = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("probe_gather_fusion", &.{vec_ty}, &.{vec_ty});
    const src = fb.parameter(0);
    const flat = try fb.iota(vec_ty, 0);
    const two = try fb.broadcast(try fb.constant(scalar_ty, std.mem.asBytes(&@as(f32, 2.0))), vec_ty, &.{total});
    const limit = try fb.broadcast(try fb.constant(scalar_ty, std.mem.asBytes(&@as(f32, total - 1))), vec_ty, &.{total});
    const doubled = try fb.min(try fb.mul(flat, two), limit);
    const idx = try fb.convert(doubled, idx_ty, .i32);
    const gathered = try fb.gather(src, idx, vec_ty, 0);
    const out_value = try fb.add(try fb.mul(gathered, two), flat);
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input: [total]f32 = undefined;
    for (input[0..], 0..) |*value, index| value.* = @sin(@as(f32, @floatFromInt(index)) * 0.05);
    var out = @as([total]f32, @splat(0.0));
    var count = [_]i32{total};
    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f32, out[0..]),
        kernel.argumentBuffer(f32, input[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });
    for (0..total) |i| {
        const j = @min(i * 2, total - 1);
        const expected = input[j] * 2.0 + @as(f32, @floatFromInt(i));
        try std.testing.expectApproxEqAbs(expected, out[i], 1e-4);
    }
}

test "numerics: multistage tiled dot matches the host on CUDA" {
    const allocator = std.testing.allocator;
    var state = gpu.cuda.State.initDevice(allocator, 0) catch return error.SkipZigTest;
    defer state.deinit();

    const batch = 4;
    const m = 256;
    const n = 256;
    const k = 192;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ batch, m, k });
    const rhs_ty = try builder.tensor(.f32, &.{ batch, k, n });
    const out_ty = try builder.tensor(.f32, &.{ batch, m, n });
    var fb = try builder.beginFunction("probe_multistage_dot", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out_value = try fb.dotGeneral(fb.parameter(0), fb.parameter(1), out_ty, &.{2}, &.{1}, &.{0}, &.{0});
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{},
    );
    defer fragment.deinit();

    const lhs = try allocator.alloc(f32, batch * m * k);
    defer allocator.free(lhs);
    const rhs = try allocator.alloc(f32, batch * k * n);
    defer allocator.free(rhs);
    const out = try allocator.alloc(f32, batch * m * n);
    defer allocator.free(out);
    for (lhs, 0..) |*value, index| value.* = @sin(@as(f32, @floatFromInt(index)) * 0.013) * 0.5;
    for (rhs, 0..) |*value, index| value.* = @cos(@as(f32, @floatFromInt(index)) * 0.007) * 0.5;
    @memset(out, 0.0);

    var outputs = [_][]u8{std.mem.sliceAsBytes(out)};
    try executable.invoke(fragment, allocator, allocator, &.{
        std.mem.sliceAsBytes(lhs),
        std.mem.sliceAsBytes(rhs),
    }, &outputs);

    var sample: usize = 0;
    while (sample < 256) : (sample += 1) {
        const slab = sample % batch;
        const row = (sample * 37 + 11) % m;
        const col = (sample * 53 + 7) % n;
        var acc: f64 = 0.0;
        var inner: usize = 0;
        while (inner < k) : (inner += 1) {
            acc += @as(f64, lhs[(slab * m + row) * k + inner]) * @as(f64, rhs[(slab * k + inner) * n + col]);
        }
        const got: f64 = out[(slab * m + row) * n + col];
        try std.testing.expect(@abs(acc - got) < 1e-3);
    }
}

test "numerics: f16 dot general rounds through half precision" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const lhs_ty = try builder.tensor(.f16, &.{ 3, 4 });
    const rhs_ty = try builder.tensor(.f16, &.{ 4, 5 });
    const out_ty = try builder.tensor(.f16, &.{ 3, 5 });
    var fb = try builder.beginFunction("numerics_f16_dot", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out_value = try fb.dotGeneral(fb.parameter(0), fb.parameter(1), out_ty, &.{1}, &.{0}, &.{}, &.{});
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var lhs = [_]f16{
        1.0,   -2.0, 3.0,  0.5,
        -0.25, 4.0,  7.0,  -8.0,
        0.75,  1.5,  -3.0, 2.0,
    };
    var rhs = [_]f16{
        2.0,    0.5,  -1.5, 8.0,  4.0,
        -0.125, 0.0,  1.0,  -2.0, 3.0,
        0.25,   -4.0, 2.0,  1.0,  -1.0,
        3.0,    2.0,  0.5,  -0.5, 1.5,
    };
    var expected = @as([15]f16, @splat(0.0));
    for (0..3) |row| {
        for (0..5) |col| {
            var sum: f16 = 0.0;
            for (0..4) |inner| {
                const product: f16 = @floatCast(@as(f32, lhs[row * 4 + inner]) * @as(f32, rhs[inner * 5 + col]));
                sum = @floatCast(@as(f32, sum) + @as(f32, product));
            }
            expected[row * 5 + col] = sum;
        }
    }

    var out = @as([15]f16, @splat(0.0));
    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f16, out[0..]),
        kernel.argumentBuffer(f16, lhs[0..]),
        kernel.argumentBuffer(f16, rhs[0..]),
    });
    for (expected, out) |want, actual| {
        try std.testing.expectApproxEqAbs(@as(f32, want), @as(f32, actual), 0.001);
    }
}

test "numerics: i32 arithmetic wraps on overflow like the host" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.i32, &.{element_count});
    var fb = try builder.beginFunction("numerics_i32_overflow", &.{ vec_ty, vec_ty }, &.{vec_ty});
    const out_value = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    const max = std.math.maxInt(i32);
    const min = std.math.minInt(i32);
    var lhs = [_]i32{ max, min, max, min, 1, -1, max - 1, min + 1 };
    var rhs = [_]i32{ 1, -1, max, min, max, min, 2, -2 };
    var out = @as([element_count]i32, @splat(0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(i32, out[0..]),
        kernel.argumentBuffer(i32, lhs[0..]),
        kernel.argumentBuffer(i32, rhs[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (lhs, rhs, out) |a, b, actual| {
        try std.testing.expectEqual(a +% b, actual);
    }
}

test "numerics: f16 add stays within half precision tolerance" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f16, &.{element_count});
    var fb = try builder.beginFunction("numerics_f16_add", &.{ vec_ty, vec_ty }, &.{vec_ty});
    const out_value = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var lhs = [_]f16{ 1.0, -2.5, 3.25, 0.0, 100.0, -0.125, 7.5, -8.0 };
    var rhs = [_]f16{ 0.5, 2.5, -3.25, -0.0, 1.0, 0.125, 0.25, 8.0 };
    var out = @as([element_count]f16, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f16, out[0..]),
        kernel.argumentBuffer(f16, lhs[0..]),
        kernel.argumentBuffer(f16, rhs[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (lhs, rhs, out) |a, b, actual| {
        const expected: f32 = @as(f32, a) + @as(f32, b);
        try std.testing.expectApproxEqAbs(expected, @as(f32, actual), 0.001);
    }
}

test "numerics: f16 tanh stays within half precision tolerance" {
    const allocator = std.testing.allocator;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f16, &.{element_count});
    var fb = try builder.beginFunction("numerics_f16_tanh", &.{vec_ty}, &.{vec_ty});
    const out_value = try fb.tanh(fb.parameter(0));
    try fb.return_(&.{out_value});
    try fb.finish();
    const module = try builder.finish();

    var input = [_]f16{ -4.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 4.0 };
    var out = @as([element_count]f16, @splat(0.0));
    var count = [_]i32{element_count};

    try runSingleKernel(allocator, module, &.{
        kernel.argumentBuffer(f16, out[0..]),
        kernel.argumentBuffer(f16, input[0..]),
        kernel.argumentBuffer(i32, count[0..]),
    });

    for (input, out) |x, actual| {
        const expected: f32 = std.math.tanh(@as(f32, x));
        try std.testing.expectApproxEqAbs(expected, @as(f32, actual), 0.001);
    }
}

const ReturnedView = enum { broadcast, broadcast_in_dim, reshape_broadcast, computed_broadcast };

fn returnedViewModule(allocator: std.mem.Allocator, view: ReturnedView) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const input_dims: []const i64 = switch (view) {
        .broadcast => &.{},
        .broadcast_in_dim => &.{2},
        .reshape_broadcast, .computed_broadcast => &.{4},
    };
    const input_type = try builder.tensor(.f32, input_dims);
    const broadcast_type = try builder.tensor(.f32, &.{ 2, 4 });
    const output_type = if (view == .reshape_broadcast or view == .computed_broadcast)
        try builder.tensor(.f32, &.{8})
    else
        broadcast_type;
    var function = try builder.beginFunction(@tagName(view), &.{input_type}, &.{output_type});
    const output = switch (view) {
        .broadcast => try function.broadcast(function.parameter(0), output_type, &.{ 2, 4 }),
        .broadcast_in_dim => try function.broadcastInDim(
            function.parameter(0),
            output_type,
            &.{ 2, 4 },
            &.{0},
        ),
        .reshape_broadcast => try function.reshape(
            try function.broadcast(function.parameter(0), broadcast_type, &.{2}),
            output_type,
            &.{8},
        ),
        .computed_broadcast => try function.reshape(
            try function.broadcast(
                try function.mul(function.parameter(0), function.parameter(0)),
                broadcast_type,
                &.{2},
            ),
            output_type,
            &.{8},
        ),
    };
    try function.return_(&.{output});
    try function.finish();
    return try builder.finish();
}

fn expectReturnedViewReadback(view: ReturnedView) !void {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        try returnedViewModule(allocator, view),
        .{ .artifact_format = .cpu_object },
    );
    defer fragment.deinit();
    const inputs = [_]f32{ 7.5, -2.25, 0.125, 42 };
    const count: usize = switch (view) {
        .broadcast => 1,
        .broadcast_in_dim => 2,
        .reshape_broadcast, .computed_broadcast => 4,
    };
    var invocation = try executable.prepareInvocation(fragment, allocator, &.{
        std.mem.sliceAsBytes(inputs[0..count]),
    });
    defer invocation.deinit();
    try invocation.launch(allocator);
    var output: [8]f32 = undefined;
    try invocation.readOutput(0, std.mem.sliceAsBytes(&output));
    for (output, 0..) |actual, index| {
        const source = switch (view) {
            .broadcast => 0,
            .broadcast_in_dim => index / 4,
            .reshape_broadcast, .computed_broadcast => index % 4,
        };
        const expected = if (view == .computed_broadcast)
            inputs[source] * inputs[source]
        else
            inputs[source];
        try expectF32Observation(expected, actual);
    }
}

test "numerics: returned standalone broadcast has an executed readback" {
    try expectReturnedViewReadback(.broadcast);
}

test "numerics: returned standalone broadcast_in_dim has an executed readback" {
    try expectReturnedViewReadback(.broadcast_in_dim);
}

test "numerics: returned reshape of broadcast has an executed readback" {
    try expectReturnedViewReadback(.reshape_broadcast);
}

test "numerics: returned reshape of computed broadcast respects writer dependencies" {
    try expectReturnedViewReadback(.computed_broadcast);
}

test "numerics: returned broadcast beyond constant folding limit has an executed readback" {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    const count = 16385;
    const expected: f32 = -2.25;
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    defer builder.deinit();
    const scalar = try builder.tensor(.f32, &.{});
    const vector = try builder.tensor(.f32, &.{count});
    var function = try builder.beginFunction("large_constant_broadcast", &.{}, &.{vector});
    const constant = try function.constant(scalar, std.mem.asBytes(&expected));
    const broadcast = try function.broadcast(constant, vector, &.{count});
    try function.return_(&.{broadcast});
    try function.finish();
    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        try builder.finish(),
        .{ .artifact_format = .cpu_object },
    );
    defer fragment.deinit();
    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    var invocation = try executable.prepareInvocation(fragment, allocator, &.{});
    defer invocation.deinit();
    try invocation.launch(allocator);
    const output = try allocator.alloc(f32, count);
    defer allocator.free(output);
    try invocation.readOutput(0, std.mem.sliceAsBytes(output));
    for (output) |actual| try expectF32Observation(expected, actual);
}

test "numerics: returned input and constant backing have executed readbacks without kernels" {
    try @import("../fixture/root.zig").requireNativeCpuArtifacts();
    const allocator = std.testing.allocator;
    const input = [_]f32{ 7.5, -2.25 };
    const payload = [_]f32{ 0.125, 42 };
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    defer builder.deinit();
    const vector = try builder.tensor(.f32, &.{2});
    var function = try builder.beginFunction("backed_outputs", &.{vector}, &.{ vector, vector });
    const constant = try function.constant(vector, std.mem.sliceAsBytes(&payload));
    try function.return_(&.{ function.parameter(0), constant });
    try function.finish();
    var state = gpu.cpu.State.init(allocator);
    defer state.deinit();
    const fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        try builder.finish(),
        .{ .artifact_format = .cpu_object },
    );
    defer fragment.deinit();
    try std.testing.expectEqual(@as(usize, 0), fragment.kernelCount());
    var invocation = try executable.prepareInvocation(fragment, allocator, &.{
        std.mem.sliceAsBytes(&input),
    });
    defer invocation.deinit();
    try invocation.launch(allocator);
    for ([_][2]f32{ input, payload }, 0..) |expected, index| {
        var output: [2]f32 = undefined;
        try invocation.readOutput(index, std.mem.sliceAsBytes(&output));
        for (expected, output) |wanted, actual| try expectF32Observation(wanted, actual);
    }
}
