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
