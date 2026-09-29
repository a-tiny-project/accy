const std = @import("std");
const gpu = @import("gpu");

const entry = @import("entry.zig");
const kernel = @import("../root.zig");

fn indexUpper(comptime extent: u64) i64 {
    if (extent > @as(u64, @intCast(std.math.maxInt(i64)))) {
        @compileError("kernel library layout extent overflows index range");
    }
    return @intCast(extent);
}

fn transposeSpecialization(comptime spec: entry.Matrix2D) entry.Specialization {
    return .{
        .dtype = .f32,
        .operation = .{ .layout = .transpose },
        .equation = "ij->ji",
        .inputs = &.{entry.shape2D(spec.row_axis, spec.rows, spec.col_axis, spec.cols)},
        .outputs = &.{entry.shape2D(spec.col_axis, spec.cols, spec.row_axis, spec.rows)},
        .launch = entry.launch2D(spec.cols, spec.rows, spec.threads.x, spec.threads.y),
        .schedule = entry.threadBlocks2D(spec.col_axis, spec.cols, spec.row_axis, spec.rows, spec.threads.x, spec.threads.y),
    };
}

fn transposeInputIndex(inner: anytype, comptime spec: entry.Matrix2D, row: kernel.Value, col: kernel.Value) !kernel.Value {
    const col_stride = try inner.constantIndex(indexUpper(spec.cols));
    const row_offset = try inner.mul(row, col_stride);
    return inner.add(row_offset, col);
}

fn transposeOutputIndex(inner: anytype, comptime spec: entry.Matrix2D, row: kernel.Value, col: kernel.Value) !kernel.Value {
    const row_stride = try inner.constantIndex(indexUpper(spec.rows));
    const col_offset = try inner.mul(col, row_stride);
    return inner.add(col_offset, row);
}

fn transpose_each(inner: anytype, index: kernel.Index2D, ctx: anytype) !void {
    const input_index = try transposeInputIndex(inner, ctx.spec, index.y.index, index.x.index);
    const output_index = try transposeOutputIndex(inner, ctx.spec, index.y.index, index.x.index);
    const value = try ctx.args.param(.src).load(inner, input_index);
    try ctx.args.param(.dst).store(inner, value, output_index);
}

fn transposeProgram(comptime spec: entry.Matrix2D) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            _ = try k.forEach2D(.{
                .x = kernel.logical.axis(spec.col_axis, spec.cols),
                .y = kernel.logical.axis(spec.row_axis, spec.rows),
            }, .{ .spec = spec, .args = args }, transpose_each);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_layout_transpose{}x{}_{}x{}_f32",
            .{ spec.rows, spec.cols, spec.threads.x, spec.threads.y },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(.f32),
            .src = kernel.dynamicBuffer(.f32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{
        .x = spec.threads.x,
        .y = spec.threads.y,
    }));
}

pub fn transposeF32(comptime spec: entry.Matrix2D) type {
    return entry.Entry(transposeProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.layout.transpose{}x{}_{}x{}_f32",
            .{ spec.rows, spec.cols, spec.threads.x, spec.threads.y },
        ),
        .layer = .logical,
        .category = .layout,
        .specialization = transposeSpecialization(spec),
    });
}

pub const Transpose8x16F32 = transposeF32(.{
    .rows = 8,
    .cols = 16,
    .threads = .{ .x = 8, .y = 4 },
});

test "layout transpose entry runs on CPU and records schedule" {
    const Transpose2x3F32 = transposeF32(.{
        .rows = 2,
        .cols = 3,
        .threads = .{ .x = 2, .y = 2 },
    });

    var src = [_]f32{
        1.0, 2.0, 3.0,
        4.0, 5.0, 6.0,
    };
    var dst = @as([6]f32, @splat(0.0));

    try Transpose2x3F32.runCpu(std.testing.allocator, Transpose2x3F32.Limits.testing, &.{
        kernel.argumentBuffer(f32, dst[0..]),
        kernel.argumentBuffer(f32, src[0..]),
    });
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 4.0, 2.0, 5.0, 3.0, 6.0 }, dst[0..]);

    const launch_value = try Transpose2x3F32.launch(std.testing.allocator, Transpose2x3F32.Limits.testing);
    try std.testing.expectEqual(@as(u32, 2), launch_value.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), launch_value.grid[1]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[0]);
    try std.testing.expectEqual(@as(u32, 2), launch_value.block[1]);
    try std.testing.expect(Transpose2x3F32.specialization.operationIs(.{ .layout = .transpose }));
    try std.testing.expectEqualStrings("ij->ji", Transpose2x3F32.specialization.equation.?);
    try std.testing.expectEqual(@as(u64, 6), Transpose2x3F32.specialization.inputs[0].elementCount().?);
    try std.testing.expectEqual(@as(u64, 6), Transpose2x3F32.specialization.outputs[0].elementCount().?);
    try std.testing.expectEqualDeep(Transpose2x3F32.specialization.launch.?, Transpose2x3F32.specialization.schedule.?.launch());

    var snapshot = try Transpose2x3F32.scheduleSnapshot(std.testing.allocator, Transpose2x3F32.Limits.testing);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expect(Transpose2x3F32.specialization.schedule.?.matchesSnapshot(&snapshot));
}

test "layout transpose entry creates registry-ready artifact" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try Transpose8x16F32.createKernelCallArtifact(allocator, state.handle(), .{ .limits = Transpose8x16F32.Limits.testing });
    defer call_artifact.deinit();

    const artifact = call_artifact.registry().find(Transpose8x16F32.target, Transpose8x16F32.version, .cuda_ptx) orelse {
        return error.TestExpectedKernelCallArtifact;
    };
    try std.testing.expectEqualStrings(Transpose8x16F32.name, artifact.entry_name);
    try std.testing.expectEqual(@as(u32, 2), artifact.argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, artifact.required_dtypes.bits);
    switch (artifact.launch) {
        .fixed => |geometry| {
            try std.testing.expectEqual(Transpose8x16F32.specialization.launch.?.grid[0], geometry.grid[0]);
            try std.testing.expectEqual(Transpose8x16F32.specialization.launch.?.grid[1], geometry.grid[1]);
            try std.testing.expectEqual(Transpose8x16F32.specialization.launch.?.threadgroup[0], geometry.threadgroup[0]);
            try std.testing.expectEqual(Transpose8x16F32.specialization.launch.?.threadgroup[1], geometry.threadgroup[1]);
        },
        else => return error.TestExpectedFixedLaunch,
    }
}
