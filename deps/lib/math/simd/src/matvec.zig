const std = @import("std");
const bfloat = @import("bfloat.zig");
const dot = @import("dot.zig");

pub fn compute(
    comptime D: type,
    matrix: []const D.Lane,
    vector: []const D.Lane,
    output: []D.Lane,
) void {
    requireFloat(D.Lane);
    validateShape(matrix.len, vector.len, output.len);
    for (output, 0..) |*result, row| {
        const begin = row * vector.len;
        result.* = dot.compute(D, matrix[begin .. begin + vector.len], vector);
    }
}

pub fn computeAdd(
    comptime D: type,
    matrix: []const D.Lane,
    vector: []const D.Lane,
    add: []const D.Lane,
    output: []D.Lane,
) void {
    requireFloat(D.Lane);
    std.debug.assert(add.len >= output.len);
    compute(D, matrix, vector, output);
    for (output, add[0..output.len]) |*result, addend| {
        result.* = addScalar(D.Lane, result.*, addend);
    }
}

pub fn computeBFloatF32(
    comptime D: type,
    matrix: []const bfloat.BFloat16,
    vector: []const f32,
    output: []f32,
) void {
    if (comptime D.Lane != f32) @compileError("mixed matvec requires an f32 descriptor");
    validateShape(matrix.len, vector.len, output.len);
    for (output, 0..) |*result, row| {
        const begin = row * vector.len;
        result.* = dot.computeF32BFloat(D, vector, matrix[begin .. begin + vector.len]);
    }
}

pub fn computeBFloatF32Add(
    comptime D: type,
    matrix: []const bfloat.BFloat16,
    vector: []const f32,
    add: []const f32,
    output: []f32,
) void {
    std.debug.assert(add.len >= output.len);
    computeBFloatF32(D, matrix, vector, output);
    for (output, add[0..output.len]) |*result, addend| result.* += addend;
}

pub fn computeBFloat(
    comptime D: type,
    matrix: []const bfloat.BFloat16,
    vector: []const bfloat.BFloat16,
    output: []f32,
) void {
    requireBFloatTag(D);
    validateShape(matrix.len, vector.len, output.len);
    for (output, 0..) |*result, row| {
        const begin = row * vector.len;
        result.* = dot.computeBFloat(D, matrix[begin .. begin + vector.len], vector);
    }
}

pub fn computeBFloatAdd(
    comptime D: type,
    matrix: []const bfloat.BFloat16,
    vector: []const bfloat.BFloat16,
    add: []const bfloat.BFloat16,
    output: []f32,
) void {
    std.debug.assert(add.len >= output.len);
    computeBFloat(D, matrix, vector, output);
    for (output, add[0..output.len]) |*result, addend| result.* += addend.toF32();
}

fn validateShape(matrix_len: usize, columns: usize, rows: usize) void {
    const area = std.math.mul(usize, rows, columns) catch @panic("matrix shape exceeds usize");
    std.debug.assert(matrix_len >= area);
}

fn addScalar(comptime T: type, a: T, b: T) T {
    const sum = @as(f32, @floatCast(a)) + @as(f32, @floatCast(b));
    return @floatCast(sum);
}

fn requireFloat(comptime T: type) void {
    if (T != f16 and T != f32 and T != f64) {
        @compileError("matvec requires f16/f32/f64 lanes");
    }
}

fn requireBFloatTag(comptime D: type) void {
    if (comptime !@hasDecl(D, "is_bfloat16") or !D.is_bfloat16) {
        @compileError("bfloat16 matvec requires a bfloat16 descriptor");
    }
}

fn close(comptime T: type, expected: T, actual: T, scale: T) bool {
    const tolerance = scale * @max(@abs(expected), @as(T, 1));
    return @abs(expected - actual) <= tolerance;
}

fn verifySameType(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 8);
    const rows: usize = 19;
    const columns: usize = 37;
    var matrix: [rows * columns]T = undefined;
    var vector: [columns]T = undefined;
    var add: [rows]T = undefined;
    for (&matrix, 0..) |*value, index| {
        const integer = @as(i32, @intCast(index % 19)) - 9;
        value.* = @as(T, @floatFromInt(integer)) * @as(T, 0.125);
    }
    for (&vector, 0..) |*value, index| {
        const integer = @as(i32, @intCast(index % 13)) - 6;
        value.* = @as(T, @floatFromInt(integer)) * @as(T, 0.25);
    }
    for (&add, 0..) |*value, index| value.* = @as(T, @floatFromInt(index)) * @as(T, 0.5);
    var output: [rows]T = undefined;
    compute(D, &matrix, &vector, &output);
    for (output, 0..) |actual, row| {
        var expected: T = 0;
        for (matrix[row * columns ..][0..columns], vector) |a, b| {
            expected = @mulAdd(T, a, b, expected);
        }
        try std.testing.expect(close(T, expected, actual, 64 * std.math.floatEps(T)));
    }
    computeAdd(D, &matrix, &vector, &add, &output);
    for (output, 0..) |actual, row| {
        const product = dot.compute(D, matrix[row * columns ..][0..columns], &vector);
        const expected = addScalar(T, product, add[row]);
        try std.testing.expect(close(T, expected, actual, 4 * std.math.floatEps(T)));
    }
}

fn expectBits(expected: []const u32, actual: []const f32) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |bits, value| {
        try std.testing.expect(close(
            f32,
            @bitCast(bits),
            value,
            96 * std.math.floatEps(f32),
        ));
    }
}
