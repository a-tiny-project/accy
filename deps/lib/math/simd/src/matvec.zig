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

test "Highway same-type matvec and additive forms handle awkward shapes" {
    inline for (.{ f16, f32, f64 }) |T| try verifySameType(T);
}

test "Highway bfloat matrix forms widen outputs to f32" {
    const simd = @import("root.zig");
    const DF = simd.FixedTag(f32, 8);
    const DB = simd.BFloat16Tag(16);
    const rows: usize = 11;
    const columns: usize = 35;
    var matrix: [rows * columns]bfloat.BFloat16 = undefined;
    var vector_f32: [columns]f32 = undefined;
    var vector_bf: [columns]bfloat.BFloat16 = undefined;
    var add_f32: [rows]f32 = undefined;
    var add_bf: [rows]bfloat.BFloat16 = undefined;
    for (&matrix, 0..) |*value, index| {
        const integer = @as(i32, @intCast(index % 17)) - 8;
        value.* = bfloat.BFloat16.fromF32(@as(f32, @floatFromInt(integer)) * 0.125);
    }
    for (&vector_f32, &vector_bf, 0..) |*fv, *bv, index| {
        const integer = @as(i32, @intCast(index % 11)) - 5;
        fv.* = @as(f32, @floatFromInt(integer)) * 0.25;
        bv.* = bfloat.BFloat16.fromF32(fv.*);
    }
    for (&add_f32, &add_bf, 0..) |*fv, *bv, index| {
        fv.* = @as(f32, @floatFromInt(index)) * 0.5;
        bv.* = bfloat.BFloat16.fromF32(fv.*);
    }
    var output: [rows]f32 = undefined;
    computeBFloatF32Add(DF, &matrix, &vector_f32, &add_f32, &output);
    for (output, 0..) |actual, row| {
        const product = dot.computeF32BFloat(
            DF,
            &vector_f32,
            matrix[row * columns ..][0..columns],
        );
        try std.testing.expect(close(
            f32,
            product + add_f32[row],
            actual,
            4 * std.math.floatEps(f32),
        ));
    }
    computeBFloatAdd(DB, &matrix, &vector_bf, &add_bf, &output);
    for (output, 0..) |actual, row| {
        const product = dot.computeBFloat(
            DB,
            matrix[row * columns ..][0..columns],
            &vector_bf,
        );
        try std.testing.expect(close(
            f32,
            product + add_bf[row].toF32(),
            actual,
            4 * std.math.floatEps(f32),
        ));
    }
}

test "Highway matvec accepts empty dimensions without touching extra output" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f32, 4);
    var output = [_]f32{ 7, 7, 7 };
    compute(D, &.{}, &.{}, &output);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0 }, &output);
    compute(D, &.{}, &.{}, output[0..0]);
}

test "Highway AVX2 matvec oracle matches additive forms" {
    const simd = @import("root.zig");
    const DF = simd.FixedTag(f32, 8);
    const DB = simd.BFloat16Tag(16);
    const rows: usize = 5;
    const columns: usize = 35;
    var matrix: [rows * columns]f32 = undefined;
    var vector: [columns]f32 = undefined;
    var add: [rows]f32 = undefined;
    var matrix_bf: [rows * columns]bfloat.BFloat16 = undefined;
    var vector_bf: [columns]bfloat.BFloat16 = undefined;
    var add_bf: [rows]bfloat.BFloat16 = undefined;
    for (&matrix, &matrix_bf, 0..) |*value, *bf, index| {
        const integer = @as(i32, @intCast(index % 23)) - 11;
        value.* = @as(f32, @floatFromInt(integer)) * 0.071 +
            @as(f32, @floatFromInt(index % 3)) * 0.003;
        bf.* = bfloat.BFloat16.fromF32(value.*);
    }
    for (&vector, &vector_bf, 0..) |*value, *bf, index| {
        const integer = @as(i32, @intCast(index % 13)) - 6;
        value.* = @as(f32, @floatFromInt(integer)) * -0.113 + 0.007;
        bf.* = bfloat.BFloat16.fromF32(value.*);
    }
    for (&add, &add_bf, 0..) |*value, *bf, index| {
        value.* = @as(f32, @floatFromInt(index)) * 0.19 - 0.23;
        bf.* = bfloat.BFloat16.fromF32(value.*);
    }
    var output: [rows]f32 = undefined;
    computeAdd(DF, &matrix, &vector, &add, &output);
    try expectBits(&.{ 0xbfbb_9e28, 0x3e15_c7cd, 0xbec5_058a, 0x3fcb_8106, 0x3f03_ffef }, &output);
    computeBFloatF32Add(DF, &matrix_bf, &vector, &add, &output);
    try expectBits(&.{ 0xbfbb_c911, 0x3e14_3edd, 0xbec4_f2da, 0x3fcb_9624, 0x3f03_cb5e }, &output);
    computeBFloatAdd(DB, &matrix_bf, &vector_bf, &add_bf, &output);
    try expectBits(&.{ 0xbfbb_3f80, 0x3e15_7200, 0xbec2_bffc, 0x3fcb_ac8a, 0x3f04_cd00 }, &output);
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
