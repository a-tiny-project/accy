const std = @import("std");
const bfloat = @import("bfloat.zig");

pub fn perBlock2x2MatMul(
    comptime D: type,
    a: anytype,
    b: @TypeOf(a),
    c: D.Vector,
) D.Vector {
    validateDescriptor(D);
    if (comptime D.Lane == i32) {
        validateVector(@TypeOf(a), i8, D.lane_count * 4);
        return int8MatMul(D, a, b, c);
    }
    if (comptime D.Lane == f32) {
        validateVector(@TypeOf(a), u16, D.lane_count * 2);
        return bfloatMatMul(D, a, b, c);
    }
    @compileError("2x2 block matrix multiplication requires i32 or f32 accumulators");
}

fn int8MatMul(comptime D: type, a: anytype, b: @TypeOf(a), c: D.Vector) D.Vector {
    const Input = [D.lane_count * 4]i8;
    const Output = [D.lane_count]i32;
    const input_a: Input = @bitCast(a);
    const input_b: Input = @bitCast(b);
    var result: Output = @bitCast(c);
    for (0..D.lane_count / 4) |block| {
        const input = block * 16;
        const output = block * 4;
        for (0..2) |row| {
            for (0..2) |column| {
                var sum: i32 = 0;
                for (0..8) |inner| {
                    sum += @as(i32, input_a[input + row * 8 + inner]) *
                        @as(i32, input_b[input + column * 8 + inner]);
                }
                const index = output + row * 2 + column;
                result[index] = result[index] +% sum;
            }
        }
    }
    return @bitCast(result);
}

fn bfloatMatMul(comptime D: type, a: anytype, b: @TypeOf(a), c: D.Vector) D.Vector {
    const Input = [D.lane_count * 2]u16;
    const Output = [D.lane_count]f32;
    const input_a: Input = @bitCast(a);
    const input_b: Input = @bitCast(b);
    var result: Output = @bitCast(c);
    for (0..D.lane_count / 4) |block| {
        const input = block * 8;
        const output = block * 4;
        for (0..2) |row| {
            for (0..2) |column| {
                var sum: f32 = 0;
                for (0..4) |inner| {
                    sum += bfloat.f32FromBits(input_a[input + row * 4 + inner]) *
                        bfloat.f32FromBits(input_b[input + column * 4 + inner]);
                }
                const index = output + row * 2 + column;
                result[index] += sum;
            }
        }
    }
    return @bitCast(result);
}

fn validateDescriptor(comptime D: type) void {
    if (D.lane_count < 4 or D.lane_count % 4 != 0) {
        @compileError("2x2 block matrix multiplication requires four-lane accumulator blocks");
    }
}

fn validateVector(comptime V: type, comptime Lane: type, comptime lanes: usize) void {
    switch (@typeInfo(V)) {
        .vector => |info| {
            if (info.child != Lane or info.len != lanes) {
                @compileError("2x2 block matrix multiplication received an incompatible input");
            }
        },
        else => @compileError("2x2 block matrix multiplication requires vector inputs"),
    }
}

test "Highway int8 per-block 2x2 matrix multiplication matches upstream fixture" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i32, 4);
    const I = simd.FixedTag(i8, 16);
    const a: I.Vector = .{
        -12, -11, -10, -9, -8, -7, -6, -5,
        -4,  -3,  -2,  -1, 0,  1,  2,  3,
    };
    const b: I.Vector = .{
        -9, -8, -7, -6, -5, -4, -3, -2,
        -1, 0,  1,  2,  3,  4,  5,  6,
    };
    const actual = perBlock2x2MatMul(D, a, b, @as(D.Vector, .{ 10, 11, 12, 13 }));
    try std.testing.expect(@reduce(.And, actual == @as(D.Vector, .{ 426, -117, 76, 45 })));
}

test "Highway bfloat16 per-block 2x2 matrix multiplication matches upstream fixture" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f32, 4);
    const B = simd.BFloat16Tag(8);
    const a = bfloat.demoteF32(
        B,
        @as(simd.FixedTag(f32, 8).Vector, .{ 0, 0.5, 1, 1.5, 2, 0, 0.5, 1 }),
    );
    const b = bfloat.demoteF32(
        B,
        @as(simd.FixedTag(f32, 8).Vector, .{ 0, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 0 }),
    );
    const actual = perBlock2x2MatMul(D, a, b, @as(D.Vector, .{ 1, 2, 3, 1 }));
    try std.testing.expect(@reduce(.And, actual == @as(D.Vector, .{ 2.75, 4.125, 4, 3.75 })));
}

test "Highway int8 per-block 2x2 matrix multiplication wraps accumulators" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i32, 8);
    const I = simd.FixedTag(i8, 32);
    const actual = perBlock2x2MatMul(
        D,
        @as(I.Vector, @splat(127)),
        @as(I.Vector, @splat(127)),
        @as(D.Vector, @splat(std.math.maxInt(i32))),
    );
    try std.testing.expect(@reduce(.And, actual == @as(D.Vector, @splat(-2_147_354_617))));
}
