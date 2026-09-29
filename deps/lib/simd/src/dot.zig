const std = @import("std");
const arithmetic = @import("arithmetic.zig");
const bfloat = @import("bfloat.zig");
const construct = @import("construct.zig");
const memory = @import("memory.zig");
const multiply = @import("multiply.zig");
const reduce = @import("reduce.zig");

pub const Assumptions = packed struct(u3) {
    at_least_one_vector: bool = false,
    multiple_of_vector: bool = false,
    padded_to_vector: bool = false,
};

pub fn compute(
    comptime D: type,
    a: []const D.Lane,
    b: []const D.Lane,
) resultType(D.Lane) {
    std.debug.assert(a.len == b.len);
    return computeAssume(D, a, b, a.len, .{});
}

pub fn computeAssume(
    comptime D: type,
    a: []const D.Lane,
    b: []const D.Lane,
    count: usize,
    comptime assumptions: Assumptions,
) resultType(D.Lane) {
    validateSameLane(D.Lane);
    validateInputs(D.lane_count, a.len, b.len, count, assumptions);
    if (D.Lane == i16) return computeI16(D, a, b, count, assumptions);
    return computeFloat(D, a, b, count, assumptions);
}

pub fn computeBFloat(
    comptime D: type,
    a: []const bfloat.BFloat16,
    b: []const bfloat.BFloat16,
) f32 {
    std.debug.assert(a.len == b.len);
    return computeBFloatAssume(D, a, b, a.len, .{});
}

pub fn computeBFloatAssume(
    comptime D: type,
    a: []const bfloat.BFloat16,
    b: []const bfloat.BFloat16,
    count: usize,
    comptime assumptions: Assumptions,
) f32 {
    requireBFloatTag(D);
    validateInputs(D.lane_count, a.len, b.len, count, assumptions);
    if (D.lane_count < 2) return computeBFloatScalar(a, b, count);
    const DF = D.repartition(f32);
    var sum0: DF.Vector = @splat(0);
    var sum1: DF.Vector = @splat(0);
    var sum2: DF.Vector = @splat(0);
    var sum3: DF.Vector = @splat(0);
    var index: usize = 0;
    while (index + 2 * D.lane_count <= count) : (index += 2 * D.lane_count) {
        const a0 = bfloat.load(D, a[index..]);
        const b0 = bfloat.load(D, b[index..]);
        sum0 = bfloat.reorderWidenMulAccumulate(DF, a0, b0, sum0, &sum1);
        const a1 = bfloat.load(D, a[index + D.lane_count ..]);
        const b1 = bfloat.load(D, b[index + D.lane_count ..]);
        sum2 = bfloat.reorderWidenMulAccumulate(DF, a1, b1, sum2, &sum3);
    }
    if (index + D.lane_count <= count) {
        const av = bfloat.load(D, a[index..]);
        const bv = bfloat.load(D, b[index..]);
        sum0 = bfloat.reorderWidenMulAccumulate(DF, av, bv, sum0, &sum1);
        index += D.lane_count;
    }
    if (!assumptions.multiple_of_vector and index != count) {
        const remaining = count - index;
        const av = loadBFloatTail(D, a[index..], remaining, assumptions.padded_to_vector);
        const bv = loadBFloatTail(D, b[index..], remaining, assumptions.padded_to_vector);
        sum2 = bfloat.reorderWidenMulAccumulate(DF, av, bv, sum2, &sum3);
    }
    return reduce.sum(DF, (sum0 + sum1) + (sum2 + sum3));
}

pub fn computeF32BFloat(
    comptime D: type,
    a: []const f32,
    b: []const bfloat.BFloat16,
) f32 {
    std.debug.assert(a.len == b.len);
    return computeF32BFloatAssume(D, a, b, a.len, .{});
}

pub fn computeF32BFloatAssume(
    comptime D: type,
    a: []const f32,
    b: []const bfloat.BFloat16,
    count: usize,
    comptime assumptions: Assumptions,
) f32 {
    if (comptime D.Lane != f32) @compileError("mixed dot requires an f32 descriptor");
    validateInputs(D.lane_count, a.len, b.len, count, assumptions);
    var sum0: D.Vector = @splat(0);
    var sum1: D.Vector = @splat(0);
    var sum2: D.Vector = @splat(0);
    var sum3: D.Vector = @splat(0);
    var index: usize = 0;
    while (index + 4 * D.lane_count <= count) : (index += 4 * D.lane_count) {
        sum0 = mixedMulAdd(D, a[index..], b[index..], sum0);
        const index1 = index + D.lane_count;
        sum1 = mixedMulAdd(D, a[index1..], b[index1..], sum1);
        const index2 = index + 2 * D.lane_count;
        sum2 = mixedMulAdd(D, a[index2..], b[index2..], sum2);
        const index3 = index + 3 * D.lane_count;
        sum3 = mixedMulAdd(D, a[index3..], b[index3..], sum3);
    }
    while (index + D.lane_count <= count) : (index += D.lane_count) {
        sum0 = mixedMulAdd(D, a[index..], b[index..], sum0);
    }
    if (!assumptions.multiple_of_vector and index != count) {
        const remaining = count - index;
        const av = loadTail(D, a[index..], remaining, assumptions.padded_to_vector);
        const DB = bfloat.Tag(D.lane_count);
        const bits = loadBFloatTail(DB, b[index..], remaining, assumptions.padded_to_vector);
        sum1 = arithmetic.mulAdd(D, av, bfloat.promoteF32(D, bits), sum1);
    }
    return reduce.sum(D, (sum0 + sum1) + (sum2 + sum3));
}

fn computeFloat(
    comptime D: type,
    a: []const D.Lane,
    b: []const D.Lane,
    count: usize,
    comptime assumptions: Assumptions,
) D.Lane {
    var sum0: D.Vector = @splat(0);
    var sum1: D.Vector = @splat(0);
    var sum2: D.Vector = @splat(0);
    var sum3: D.Vector = @splat(0);
    var index: usize = 0;
    while (index + 4 * D.lane_count <= count) : (index += 4 * D.lane_count) {
        sum0 = arithmetic.mulAdd(D, memory.load(D, a[index..]), memory.load(D, b[index..]), sum0);
        const index1 = index + D.lane_count;
        sum1 = arithmetic.mulAdd(D, memory.load(D, a[index1..]), memory.load(D, b[index1..]), sum1);
        const index2 = index + 2 * D.lane_count;
        sum2 = arithmetic.mulAdd(D, memory.load(D, a[index2..]), memory.load(D, b[index2..]), sum2);
        const index3 = index + 3 * D.lane_count;
        sum3 = arithmetic.mulAdd(D, memory.load(D, a[index3..]), memory.load(D, b[index3..]), sum3);
    }
    while (index + D.lane_count <= count) : (index += D.lane_count) {
        sum0 = arithmetic.mulAdd(D, memory.load(D, a[index..]), memory.load(D, b[index..]), sum0);
    }
    if (!assumptions.multiple_of_vector and index != count) {
        const remaining = count - index;
        const av = loadTail(D, a[index..], remaining, assumptions.padded_to_vector);
        const bv = loadTail(D, b[index..], remaining, assumptions.padded_to_vector);
        sum1 = arithmetic.mulAdd(D, av, bv, sum1);
    }
    return reduce.sum(D, (sum0 + sum1) + (sum2 + sum3));
}

fn computeI16(
    comptime D: type,
    a: []const i16,
    b: []const i16,
    count: usize,
    comptime assumptions: Assumptions,
) i32 {
    if (D.lane_count < 2) return computeI16Scalar(a, b, count);
    const DW = D.repartition(i32);
    var sum0: DW.Vector = @splat(0);
    var sum1: DW.Vector = @splat(0);
    var sum2: DW.Vector = @splat(0);
    var sum3: DW.Vector = @splat(0);
    var index: usize = 0;
    while (index + 2 * D.lane_count <= count) : (index += 2 * D.lane_count) {
        const a0 = memory.load(D, a[index..]);
        const b0 = memory.load(D, b[index..]);
        sum0 = multiply.reorderWidenMulAccumulate(DW, a0, b0, sum0, &sum1);
        const index1 = index + D.lane_count;
        const a1 = memory.load(D, a[index1..]);
        const b1 = memory.load(D, b[index1..]);
        sum2 = multiply.reorderWidenMulAccumulate(DW, a1, b1, sum2, &sum3);
    }
    if (index + D.lane_count <= count) {
        const av = memory.load(D, a[index..]);
        const bv = memory.load(D, b[index..]);
        sum0 = multiply.reorderWidenMulAccumulate(DW, av, bv, sum0, &sum1);
        index += D.lane_count;
    }
    if (!assumptions.multiple_of_vector and index != count) {
        const remaining = count - index;
        const av = loadTail(D, a[index..], remaining, assumptions.padded_to_vector);
        const bv = loadTail(D, b[index..], remaining, assumptions.padded_to_vector);
        sum2 = multiply.reorderWidenMulAccumulate(DW, av, bv, sum2, &sum3);
    }
    return reduce.sum(DW, (sum0 +% sum1) +% (sum2 +% sum3));
}

fn mixedMulAdd(
    comptime D: type,
    a: []const f32,
    b: []const bfloat.BFloat16,
    sum: D.Vector,
) D.Vector {
    const DB = bfloat.Tag(D.lane_count);
    return arithmetic.mulAdd(D, memory.load(D, a), bfloat.promoteF32(D, bfloat.load(DB, b)), sum);
}

fn loadTail(
    comptime D: type,
    input: []const D.Lane,
    count: usize,
    comptime padded: bool,
) D.Vector {
    if (padded) {
        const value = memory.load(D, input);
        return @select(D.Lane, construct.firstN(D, count), value, @as(D.Vector, @splat(0)));
    }
    return memory.loadN(D, input, count);
}

fn loadBFloatTail(
    comptime D: type,
    input: []const bfloat.BFloat16,
    count: usize,
    comptime padded: bool,
) D.Vector {
    if (padded) {
        const value = bfloat.load(D, input);
        return @select(u16, construct.firstN(D, count), value, @as(D.Vector, @splat(0)));
    }
    var result: D.Vector = @splat(0);
    inline for (0..D.lane_count) |index| {
        if (index < count) result[index] = input[index].bits;
    }
    return result;
}

fn computeI16Scalar(a: []const i16, b: []const i16, count: usize) i32 {
    var sum: i32 = 0;
    for (a[0..count], b[0..count]) |av, bv| sum +%= @as(i32, av) * @as(i32, bv);
    return sum;
}

fn computeBFloatScalar(
    a: []const bfloat.BFloat16,
    b: []const bfloat.BFloat16,
    count: usize,
) f32 {
    var sum: f32 = 0;
    for (a[0..count], b[0..count]) |av, bv| sum = @mulAdd(f32, av.toF32(), bv.toF32(), sum);
    return sum;
}

fn validateInputs(
    comptime lanes: usize,
    a_len: usize,
    b_len: usize,
    count: usize,
    comptime assumptions: Assumptions,
) void {
    std.debug.assert(a_len >= count);
    std.debug.assert(b_len >= count);
    if (assumptions.at_least_one_vector) std.debug.assert(count >= lanes);
    if (assumptions.multiple_of_vector) std.debug.assert(count % lanes == 0);
    if (assumptions.padded_to_vector and count % lanes != 0) {
        const padded_count = std.mem.alignForward(usize, count, lanes);
        std.debug.assert(a_len >= padded_count);
        std.debug.assert(b_len >= padded_count);
    }
}

fn validateSameLane(comptime T: type) void {
    if (T != f16 and T != f32 and T != f64 and T != i16) {
        @compileError("dot requires f16/f32/f64 or i16 lanes");
    }
}

fn requireBFloatTag(comptime D: type) void {
    if (comptime !@hasDecl(D, "is_bfloat16") or !D.is_bfloat16) {
        @compileError("bfloat16 dot requires a bfloat16 descriptor");
    }
}

fn resultType(comptime T: type) type {
    validateSameLane(T);
    return if (T == i16) i32 else T;
}

fn close(comptime T: type, expected: T, actual: T, scale: T) bool {
    const tolerance = scale * @max(@abs(expected), @as(T, 1));
    return @abs(expected - actual) <= tolerance;
}

test "Highway floating dot handles every assumption and awkward alignment" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(f32, 8);
    var a_storage: [96]f32 = @splat(std.math.nan(f32));
    var b_storage: [96]f32 = @splat(std.math.nan(f32));
    const a = a_storage[1..];
    const b = b_storage[3..];
    for (0..75) |index| {
        a[index] = @as(f32, @floatFromInt(@as(i32, @intCast(index % 17)) - 8)) * 0.25;
        b[index] = @as(f32, @floatFromInt(@as(i32, @intCast(index % 13)) - 6)) * 0.5;
    }
    const count: usize = 67;
    var expected: f32 = 0;
    for (a[0..count], b[0..count]) |av, bv| expected = @mulAdd(f32, av, bv, expected);
    inline for (.{
        Assumptions{},
        Assumptions{ .at_least_one_vector = true },
        Assumptions{ .padded_to_vector = true },
        Assumptions{ .at_least_one_vector = true, .padded_to_vector = true },
    }) |assumptions| {
        const actual = computeAssume(D, a, b, count, assumptions);
        try std.testing.expect(close(f32, expected, actual, 32 * std.math.floatEps(f32)));
    }
    const multiple_count: usize = 64;
    inline for (.{
        Assumptions{ .multiple_of_vector = true },
        Assumptions{ .at_least_one_vector = true, .multiple_of_vector = true },
        Assumptions{ .multiple_of_vector = true, .padded_to_vector = true },
        Assumptions{
            .at_least_one_vector = true,
            .multiple_of_vector = true,
            .padded_to_vector = true,
        },
    }) |assumptions| {
        _ = computeAssume(D, a, b, multiple_count, assumptions);
    }
}

test "Highway dot supports every same-input lane class" {
    const simd = @import("root.zig");
    inline for (.{ f16, f32, f64 }) |T| {
        const D = simd.FixedTag(T, 4);
        var a: [13]T = undefined;
        var b: [13]T = undefined;
        var expected: T = 0;
        for (&a, &b, 0..) |*av, *bv, index| {
            av.* = @floatFromInt(@as(i32, @intCast(index % 7)) - 3);
            bv.* = @floatFromInt(@as(i32, @intCast(index % 5)) - 2);
            expected = @mulAdd(T, av.*, bv.*, expected);
        }
        const actual = compute(D, &a, &b);
        try std.testing.expect(close(T, expected, actual, 32 * std.math.floatEps(T)));
    }
    const DI = simd.FixedTag(i16, 8);
    const ai = [_]i16{ 7, -3, 12, 9, -8, 4, 6, -11, 5, 2, -1 };
    const bi = [_]i16{ -2, 8, 3, -7, 5, 9, -4, 6, 10, -3, 12 };
    var expected_i16: i32 = 0;
    for (ai, bi) |av, bv| expected_i16 +%= @as(i32, av) * @as(i32, bv);
    try std.testing.expectEqual(expected_i16, compute(DI, &ai, &bi));
    const D1 = simd.FixedTag(i16, 1);
    try std.testing.expectEqual(expected_i16, compute(D1, &ai, &bi));
}

test "Highway bfloat dot widens both same and mixed inputs" {
    const simd = @import("root.zig");
    const DB = simd.BFloat16Tag(8);
    const DF = simd.FixedTag(f32, 8);
    var a: [19]bfloat.BFloat16 = undefined;
    var b: [19]bfloat.BFloat16 = undefined;
    var af: [19]f32 = undefined;
    var expected_bf: f32 = 0;
    var expected_mixed: f32 = 0;
    for (&a, &b, &af, 0..) |*av, *bv, *fv, index| {
        const ai = @as(i32, @intCast(index % 11)) - 5;
        const bi = @as(i32, @intCast(index % 7)) - 3;
        av.* = bfloat.BFloat16.fromF32(@as(f32, @floatFromInt(ai)) * 0.5);
        bv.* = bfloat.BFloat16.fromF32(@as(f32, @floatFromInt(bi)) * 0.25);
        fv.* = @as(f32, @floatFromInt(ai)) * 0.125;
        expected_bf = @mulAdd(f32, av.toF32(), bv.toF32(), expected_bf);
        expected_mixed = @mulAdd(f32, fv.*, bv.toF32(), expected_mixed);
    }
    try std.testing.expect(close(
        f32,
        expected_bf,
        computeBFloat(DB, &a, &b),
        32 * std.math.floatEps(f32),
    ));
    try std.testing.expect(close(
        f32,
        expected_mixed,
        computeF32BFloat(DF, &af, &b),
        32 * std.math.floatEps(f32),
    ));
}

test "Highway AVX2 dot oracle matches awkward tails" {
    const simd = @import("root.zig");
    const DF32 = simd.FixedTag(f32, 8);
    const DF64 = simd.FixedTag(f64, 4);
    const DI16 = simd.FixedTag(i16, 16);
    const DBF16 = simd.BFloat16Tag(16);
    var a32: [67]f32 = undefined;
    var b32: [67]f32 = undefined;
    for (&a32, &b32, 0..) |*av, *bv, index| {
        const ai = @as(i32, @intCast(index % 19)) - 9;
        const bi = @as(i32, @intCast(index % 13)) - 6;
        av.* = @as(f32, @floatFromInt(ai)) * 0.1375 + 0.03125;
        bv.* = @as(f32, @floatFromInt(bi)) * -0.2125 + 0.015625;
    }
    try std.testing.expect(close(
        f32,
        @bitCast(@as(u32, 0xbf29_b714)),
        compute(DF32, &a32, &b32),
        96 * std.math.floatEps(f32),
    ));

    var a64: [37]f64 = undefined;
    var b64: [37]f64 = undefined;
    for (&a64, &b64, 0..) |*av, *bv, index| {
        const ai = @as(i32, @intCast(index % 11)) - 5;
        const bi = @as(i32, @intCast(index % 7)) - 3;
        av.* = @as(f64, @floatFromInt(ai)) * 0.1375 + 0.03125;
        bv.* = @as(f64, @floatFromInt(bi)) * -0.2125 + 0.015625;
    }
    try std.testing.expect(close(
        f64,
        @bitCast(@as(u64, 0x3fa9_cf5c_28f5_c270)),
        compute(DF64, &a64, &b64),
        96 * std.math.floatEps(f64),
    ));

    var ai16: [53]i16 = undefined;
    var bi16: [53]i16 = undefined;
    for (&ai16, &bi16, 0..) |*av, *bv, index| {
        av.* = @intCast(@as(i32, @intCast(index % 31)) - 15);
        bv.* = @intCast(@as(i32, @intCast(index % 23)) - 11);
    }
    try std.testing.expectEqual(@as(i32, 24), compute(DI16, &ai16, &bi16));

    var abf: [35]bfloat.BFloat16 = undefined;
    var bbf: [35]bfloat.BFloat16 = undefined;
    var mixed: [35]f32 = undefined;
    for (&abf, &bbf, &mixed, 0..) |*av, *bv, *mv, index| {
        const ai = @as(i32, @intCast(index % 17)) - 8;
        const bi = @as(i32, @intCast(index % 9)) - 4;
        const af = @as(f32, @floatFromInt(ai)) * 0.1375 + 0.03125;
        const bf = @as(f32, @floatFromInt(bi)) * -0.2125 + 0.015625;
        av.* = bfloat.BFloat16.fromF32(af);
        bv.* = bfloat.BFloat16.fromF32(bf);
        const offset = @as(i32, @intCast(index % 5)) - 2;
        mv.* = af + @as(f32, @floatFromInt(offset)) * 0.003;
    }
    try std.testing.expect(close(
        f32,
        @bitCast(@as(u32, 0xc015_a4a0)),
        computeBFloat(DBF16, &abf, &bbf),
        96 * std.math.floatEps(f32),
    ));
    try std.testing.expect(close(
        f32,
        @bitCast(@as(u32, 0xc015_d992)),
        computeF32BFloat(DF32, &mixed, &bbf),
        96 * std.math.floatEps(f32),
    ));
}
