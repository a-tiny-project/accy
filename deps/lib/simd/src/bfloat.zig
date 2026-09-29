const std = @import("std");
const tag = @import("tag.zig");

pub const BFloat16 = extern struct {
    pub const is_bfloat16 = true;
    pub const Storage = u16;

    bits: u16,

    pub fn fromBits(bits: u16) BFloat16 {
        return .{ .bits = bits };
    }

    pub fn fromF32(value: f32) BFloat16 {
        return .{ .bits = bitsFromF32(value) };
    }

    pub fn fromF64(value: f64) BFloat16 {
        const bits: u64 = @bitCast(value);
        const rounded_bits = (bits & 0xffff_ffc0_0000_0000) |
            ((bits +% 0x0000_003f_ffff_ffff) & 0x0000_0040_0000_0000);
        return fromF32(@floatCast(@as(f64, @bitCast(rounded_bits))));
    }

    pub fn toF32(self: BFloat16) f32 {
        return f32FromBits(self.bits);
    }

    pub fn neg(self: BFloat16) BFloat16 {
        return fromBits(self.bits ^ 0x8000);
    }

    pub fn add(self: BFloat16, other: BFloat16) BFloat16 {
        return fromF32(self.toF32() + other.toF32());
    }

    pub fn sub(self: BFloat16, other: BFloat16) BFloat16 {
        return fromF32(self.toF32() - other.toF32());
    }

    pub fn mul(self: BFloat16, other: BFloat16) BFloat16 {
        return fromF32(self.toF32() * other.toF32());
    }

    pub fn div(self: BFloat16, other: BFloat16) BFloat16 {
        return fromF32(self.toF32() / other.toF32());
    }
};

pub fn Tag(comptime lanes: usize) type {
    return tag.Descriptor(BFloat16, lanes, 0);
}

pub fn zero(comptime D: type) D.Vector {
    requireTag(D);
    return @splat(0);
}

pub fn set(comptime D: type, value: BFloat16) D.Vector {
    requireTag(D);
    return @splat(value.bits);
}

pub fn load(comptime D: type, input: []const BFloat16) D.Vector {
    requireTag(D);
    std.debug.assert(input.len >= D.lane_count);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = input[index].bits;
    return result;
}

pub fn store(comptime D: type, value: D.Vector, output: []BFloat16) void {
    requireTag(D);
    std.debug.assert(output.len >= D.lane_count);
    inline for (0..D.lane_count) |index| output[index] = BFloat16.fromBits(value[index]);
}

pub fn dup128VecFromValues(
    comptime D: type,
    values: [8]BFloat16,
) D.Vector {
    requireTag(D);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = values[index % 8].bits;
    return result;
}

pub fn neg(comptime D: type, value: D.Vector) D.Vector {
    requireTag(D);
    return value ^ @as(D.Vector, @splat(0x8000));
}

pub fn demoteF32(comptime D: type, value: anytype) D.Vector {
    requireTag(D);
    validateF32Vector(@TypeOf(value), D.lane_count);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = bitsFromF32(value[index]);
    return result;
}

pub fn promoteF32(comptime D: type, value: anytype) D.Vector {
    if (comptime D.Lane != f32) @compileError("bfloat16 promotion requires f32 destinations");
    validateBitsVector(@TypeOf(value), D.lane_count);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = f32FromBits(value[index]);
    return result;
}

pub fn promoteLowerF32(comptime D: type, value: anytype) D.Vector {
    return promoteSelectedF32(D, value, 0);
}

pub fn promoteUpperF32(comptime D: type, value: anytype) D.Vector {
    return promoteSelectedF32(D, value, D.lane_count);
}

pub fn promoteEvenF32(comptime D: type, value: anytype) D.Vector {
    return promoteParityF32(D, value, 0);
}

pub fn promoteOddF32(comptime D: type, value: anytype) D.Vector {
    return promoteParityF32(D, value, 1);
}

pub fn orderedDemote2F32(comptime D: type, a: anytype, b: @TypeOf(a)) D.Vector {
    requireTag(D);
    if (comptime vectorLanes(@TypeOf(a)) * 2 != D.lane_count) {
        @compileError("ordered bfloat16 demotion requires two half-size f32 vectors");
    }
    validateF32Vector(@TypeOf(a), D.lane_count / 2);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count / 2) |index| {
        result[index] = bitsFromF32(a[index]);
        result[D.lane_count / 2 + index] = bitsFromF32(b[index]);
    }
    return result;
}

pub fn mulEvenAdd(
    comptime D: type,
    a: anytype,
    b: @TypeOf(a),
    addend: D.Vector,
) D.Vector {
    return mulParityAdd(D, a, b, addend, 0);
}

pub fn mulOddAdd(
    comptime D: type,
    a: anytype,
    b: @TypeOf(a),
    addend: D.Vector,
) D.Vector {
    return mulParityAdd(D, a, b, addend, 1);
}

pub fn widenMulPairwiseAdd(comptime D: type, a: anytype, b: @TypeOf(a)) D.Vector {
    return mulOddAdd(D, a, b, mulEvenAdd(D, a, b, @splat(0)));
}

pub fn maskedWidenMulPairwiseAdd(
    comptime D: type,
    mask: D.Mask,
    a: anytype,
    b: @TypeOf(a),
) D.Vector {
    return @select(f32, mask, widenMulPairwiseAdd(D, a, b), @as(D.Vector, @splat(0)));
}

pub fn reorderWidenMulAccumulate(
    comptime D: type,
    a: anytype,
    b: @TypeOf(a),
    sum0: D.Vector,
    sum1: *D.Vector,
) D.Vector {
    sum1.* = mulOddAdd(D, a, b, sum1.*);
    return mulEvenAdd(D, a, b, sum0);
}

pub fn rearrangeToOddPlusEven(comptime D: type, sum0: D.Vector, sum1: D.Vector) D.Vector {
    if (comptime D.Lane != f32) @compileError("bfloat16 accumulation requires f32 sums");
    return sum0 + sum1;
}

pub fn bitsFromF32(value: f32) u16 {
    const bits: u32 = @bitCast(value);
    const magnitude = bits & 0x7fff_ffff;
    const increment: u32 = if (magnitude < 0x7f80_0000)
        0x7fff + ((bits >> 16) & 1)
    else
        0;
    const quiet_nan: u32 = if (magnitude > 0x7f80_0000) 1 << 6 else 0;
    return @truncate(quiet_nan | ((bits +% increment) >> 16));
}

pub fn f32FromBits(bits: u16) f32 {
    return @bitCast(@as(u32, bits) << 16);
}

fn promoteSelectedF32(comptime D: type, value: anytype, comptime offset: usize) D.Vector {
    if (comptime D.Lane != f32) @compileError("bfloat16 promotion requires f32 destinations");
    validateBitsVector(@TypeOf(value), D.lane_count * 2);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = f32FromBits(value[offset + index]);
    return result;
}

fn promoteParityF32(comptime D: type, value: anytype, comptime parity: usize) D.Vector {
    if (comptime D.Lane != f32) @compileError("bfloat16 promotion requires f32 destinations");
    validateBitsVector(@TypeOf(value), D.lane_count * 2);
    var result: D.Vector = undefined;
    inline for (0..D.lane_count) |index| result[index] = f32FromBits(value[index * 2 + parity]);
    return result;
}

fn mulParityAdd(
    comptime D: type,
    a: anytype,
    b: @TypeOf(a),
    addend: D.Vector,
    comptime parity: usize,
) D.Vector {
    if (comptime D.Lane != f32) @compileError("bfloat16 multiply-add requires f32 destinations");
    validateBitsVector(@TypeOf(a), D.lane_count * 2);
    var result = addend;
    inline for (0..D.lane_count) |index| {
        result[index] = @mulAdd(
            f32,
            f32FromBits(a[index * 2 + parity]),
            f32FromBits(b[index * 2 + parity]),
            addend[index],
        );
    }
    return result;
}

fn requireTag(comptime D: type) void {
    if (comptime !@hasDecl(D, "is_bfloat16") or !D.is_bfloat16) {
        @compileError("operation requires a bfloat16 descriptor");
    }
}

fn validateF32Vector(comptime V: type, comptime lanes: usize) void {
    if (comptime vectorLane(V) != f32 or vectorLanes(V) != lanes) {
        @compileError("operation requires the expected number of f32 lanes");
    }
}

fn validateBitsVector(comptime V: type, comptime lanes: usize) void {
    if (comptime vectorLane(V) != u16 or vectorLanes(V) != lanes) {
        @compileError("operation requires the expected number of bfloat16 bit lanes");
    }
}

fn vectorLane(comptime V: type) type {
    return switch (@typeInfo(V)) {
        .vector => |info| info.child,
        else => @compileError("operation requires a vector"),
    };
}

fn vectorLanes(comptime V: type) usize {
    return switch (@typeInfo(V)) {
        .vector => |info| info.len,
        else => @compileError("operation requires a vector"),
    };
}

test "Highway bfloat16 scalar conversion rounds to nearest even and preserves classes" {
    try std.testing.expectEqual(@as(u16, 0x3f80), BFloat16.fromF32(1).bits);
    try std.testing.expectEqual(@as(u16, 0xbf80), BFloat16.fromF32(-1).bits);
    try std.testing.expectEqual(@as(u16, 0x3f80), BFloat16.fromF32(1.00390625).bits);
    try std.testing.expectEqual(@as(u16, 0x3f82), BFloat16.fromF32(1.01171875).bits);
    try std.testing.expectEqual(@as(u16, 0x4000), BFloat16.fromF32(1.99609375).bits);
    try std.testing.expectEqual(@as(u16, 0x8000), BFloat16.fromF32(-0.0).bits);
    try std.testing.expectEqual(@as(u16, 0x7f80), BFloat16.fromF32(std.math.inf(f32)).bits);
    try std.testing.expect(std.math.isNan(BFloat16.fromF32(std.math.nan(f32)).toF32()));
}

test "Highway bfloat16 descriptors preserve scalar type relations" {
    const D = tag.FixedTag(BFloat16, 8);
    try std.testing.expectEqual(BFloat16, tag.TFromD(D));
    try std.testing.expectEqual(Tag(8), D);
    try std.testing.expectEqual(@as(usize, 4), tag.Half(D).lane_count);
    try std.testing.expectEqual(@as(i8, -1), tag.pow2(tag.Half(D)));
    try std.testing.expectEqual(Tag(8), tag.BlockDFromD(Tag(16)));
    try std.testing.expectEqual(tag.FixedTag(i16, 8), tag.RebindToSigned(D));
    try std.testing.expectEqual(tag.FixedTag(u16, 8), tag.RebindToUnsigned(D));
    try std.testing.expectEqual(tag.FixedTag(f32, 4), tag.RepartitionToWide(D));
    try std.testing.expectEqual(u16, tag.MakeUnsigned(BFloat16));
    try std.testing.expectEqual(i16, tag.MakeSigned(BFloat16));
    try std.testing.expectEqual(f32, tag.MakeWide(BFloat16));
    try std.testing.expect(tag.isSpecialFloat(BFloat16));
    try std.testing.expect(!tag.isFloat(BFloat16));
    try std.testing.expect(tag.isSigned(BFloat16));
    try std.testing.expect(!tag.isUnsigned(BFloat16));
}

test "Highway bfloat16 vector promotion demotion and memory preserve bit patterns" {
    const simd = @import("root.zig");
    const D = Tag(4);
    const F = tag.FixedTag(f32, 4);
    const input: F.Vector = .{ 1, -2, 3.984375, -0.0 };
    const bits = simd.demoteTo(D, input);
    try std.testing.expect(@reduce(.And, simd.promoteTo(F, bits) == @as(F.Vector, .{ 1, -2, 3.984375, -0.0 })));
    var scalar: [4]BFloat16 = undefined;
    store(D, bits, &scalar);
    try std.testing.expect(@reduce(.And, load(D, &scalar) == bits));
    try std.testing.expect(@reduce(.And, neg(D, bits) == (bits ^ @as(D.Vector, @splat(0x8000)))));
}

test "Highway bfloat16 even odd and pairwise multiply-add widen to f32" {
    const simd = @import("root.zig");
    const D = tag.FixedTag(f32, 4);
    const B = Tag(8);
    const a = demoteF32(B, @as(tag.FixedTag(f32, 8).Vector, .{ 1, 2, 3, 4, 5, 6, 7, 8 }));
    const b = demoteF32(B, @as(tag.FixedTag(f32, 8).Vector, .{ 8, 7, 6, 5, 4, 3, 2, 1 }));
    try std.testing.expect(@reduce(.And, mulEvenAdd(D, a, b, @splat(1)) ==
        @as(D.Vector, .{ 9, 19, 21, 15 })));
    try std.testing.expect(@reduce(.And, mulOddAdd(D, a, b, @splat(1)) ==
        @as(D.Vector, .{ 15, 21, 19, 9 })));
    try std.testing.expect(@reduce(.And, simd.widenMulPairwiseAdd(D, a, b) ==
        @as(D.Vector, .{ 22, 38, 38, 22 })));
    var odd: D.Vector = @splat(0);
    const even = simd.reorderWidenMulAccumulate(D, a, b, @splat(0), &odd);
    try std.testing.expect(@reduce(.And, simd.rearrangeToOddPlusEven(D, even, odd) ==
        @as(D.Vector, .{ 22, 38, 38, 22 })));
}
