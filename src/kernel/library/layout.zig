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
        .schedule = entry.threadBlocks2D(
            spec.col_axis,
            spec.cols,
            spec.row_axis,
            spec.rows,
            spec.threads.x,
            spec.threads.y,
        ),
    };
}

fn transposeInputIndex(
    inner: anytype,
    comptime spec: entry.Matrix2D,
    row: kernel.Value,
    col: kernel.Value,
) !kernel.Value {
    const col_stride = try inner.constantIndex(indexUpper(spec.cols));
    const row_offset = try inner.mul(row, col_stride);
    return inner.add(row_offset, col);
}

fn transposeOutputIndex(
    inner: anytype,
    comptime spec: entry.Matrix2D,
    row: kernel.Value,
    col: kernel.Value,
) !kernel.Value {
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
