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
