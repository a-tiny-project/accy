const std = @import("std");
const simd = @import("root.zig");

const parity = simd.parity;
const FixedTag = simd.FixedTag;
const allTrue = simd.allTrue;
const eq = simd.eq;
const shl = simd.shl;
const shr = simd.shr;
const roundingShr = simd.roundingShr;
const shiftLeft = simd.shiftLeft;
const shiftRight = simd.shiftRight;
const rol = simd.rol;
const ror = simd.ror;
const rotateLeftSame = simd.rotateLeftSame;
const rotateRightSame = simd.rotateRightSame;
const multiRotateRight = simd.multiRotateRight;
const populationCount = simd.populationCount;
const leadingZeroCount = simd.leadingZeroCount;
const trailingZeroCount = simd.trailingZeroCount;
const highestSetBitIndex = simd.highestSetBitIndex;
const copySign = simd.copySign;
const copySignToAbs = simd.copySignToAbs;
const bitsFromMask = simd.bitsFromMask;
const isNegative = simd.isNegative;
const isNaN = simd.isNaN;
const broadcastSignBit = simd.broadcastSignBit;
const lowerHalf = simd.lowerHalf;
const upperHalf = simd.upperHalf;
const zeroExtendVector = simd.zeroExtendVector;
const combine = simd.combine;
const concatLowerLower = simd.concatLowerLower;
const concatUpperUpper = simd.concatUpperUpper;
const concatLowerUpper = simd.concatLowerUpper;
const concatUpperLower = simd.concatUpperLower;
const concatOdd = simd.concatOdd;
const concatEven = simd.concatEven;
const interleaveWholeLower = simd.interleaveWholeLower;
const interleaveWholeUpper = simd.interleaveWholeUpper;
const lowerHalfOfMask = simd.lowerHalfOfMask;
const upperHalfOfMask = simd.upperHalfOfMask;
const combineMasks = simd.combineMasks;
const resizeBitCast = simd.resizeBitCast;
const zeroExtendResizeBitCast = simd.zeroExtendResizeBitCast;
const convertTo = simd.convertTo;
const demoteTo = simd.demoteTo;
const promoteLowerTo = simd.promoteLowerTo;
const promoteUpperTo = simd.promoteUpperTo;
const promoteEvenTo = simd.promoteEvenTo;
const promoteOddTo = simd.promoteOddTo;
const orderedDemote2To = simd.orderedDemote2To;
const orderedTruncate2To = simd.orderedTruncate2To;
const interleaveLower = simd.interleaveLower;
const interleaveUpper = simd.interleaveUpper;
const interleaveEven = simd.interleaveEven;
const interleaveOdd = simd.interleaveOdd;
const shiftLeftLanes = simd.shiftLeftLanes;
const shiftRightLanes = simd.shiftRightLanes;
const combineShiftRightLanes = simd.combineShiftRightLanes;
const reverse = simd.reverse;
const reverseBlocks = simd.reverseBlocks;
const compress = simd.compress;
const expand = simd.expand;
const slideUpLanes = simd.slideUpLanes;
const slideDownLanes = simd.slideDownLanes;
const sumOfLanes = simd.sumOfLanes;
const maskedReduceSum = simd.maskedReduceSum;
const tableLookupLanes = simd.tableLookupLanes;
const per4LaneBlockShuffle = simd.per4LaneBlockShuffle;
const storeInterleaved2 = simd.storeInterleaved2;
const load = simd.load;
const store = simd.store;
const add = simd.add;
const iota = simd.iota;
const lt = simd.lt;
const sub = simd.sub;
const mul = simd.mul;
const select = simd.select;
const reduceSum = simd.reduceSum;
const countTrue = simd.countTrue;
const Divisor = simd.Divisor;
const Divisor64 = simd.Divisor64;
const lemireMod = simd.lemireMod;

fn expectOracleVector(comptime D: type, expected: D.Vector, actual: D.Vector) !void {
    try std.testing.expect(allTrue(D, eq(D, expected, actual)));
}

fn verifySignedBitOracle() !void {
    const D = FixedTag(i16, 4);
    const U = FixedTag(u16, 4);
    const value: D.Vector = @bitCast(@as(U.Vector, .{ 0x8001, 0xfffd, 0x1234, 0x7fff }));
    const amounts: D.Vector = .{ 0, 1, 4, 15 };
    try expectOracleVector(D, @bitCast(@as(U.Vector, .{ 0x8001, 0xfffa, 0x2340, 0x8000 })), shl(D, value, amounts));
    try expectOracleVector(D, @bitCast(@as(U.Vector, .{ 0x8001, 0xfffe, 0x0123, 0x0000 })), shr(D, value, amounts));
    try expectOracleVector(D, @bitCast(@as(U.Vector, .{ 0x8001, 0xffff, 0x0123, 0x0001 })), roundingShr(D, value, amounts));
    try expectOracleVector(D, @bitCast(@as(U.Vector, .{ 0x0008, 0xffe8, 0x91a0, 0xfff8 })), shiftLeft(D, 3, value));
    try expectOracleVector(D, @bitCast(@as(U.Vector, .{ 0xf000, 0xffff, 0x0246, 0x0fff })), shiftRight(D, 3, value));
}

fn verifyWideRotateOracle() !void {
    const D = FixedTag(u64, 4);
    const value: D.Vector = .{ 0, 1, 0x8000_0000_0000_0001, 0xf0f0_0000_0000_0001 };
    const amounts: D.Vector = .{ 0, 1, @bitCast(@as(i64, -4)), 65 };
    try expectOracleVector(D, .{ 0, 2, 0x1800_0000_0000_0000, 0xe1e0_0000_0000_0003 }, rol(D, value, amounts));
    try expectOracleVector(D, .{ 0, 0x8000_0000_0000_0000, 0x18, 0xf878_0000_0000_0000 }, ror(D, value, amounts));
    try expectOracleVector(D, .{ 0, 0x0200_0000_0000_0000, 0x0300_0000_0000_0000, 0x03e1_e000_0000_0000 }, rotateLeftSame(D, value, -7));
    try expectOracleVector(D, .{ 0, 0x80, 0xc0, 0x7800_0000_0000_00f8 }, rotateRightSame(D, value, -7));
    const DI = D.repartition(u8);
    const indices: DI.Vector = .{
        0,  8,  16, 24, 32, 40, 48, 56,
        0,  9,  18, 27, 36, 45, 54, 63,
        4,  12, 20, 28, 36, 44, 52, 60,
        60, 52, 44, 36, 28, 20, 12, 4,
    };
    try expectOracleVector(D, .{ 0, 0x0200_0000_0000_0001, 0x1800_0000_0000_0000, 0x0f1f }, multiRotateRight(D, value, indices));
}

fn verifyWideCountOracle() !void {
    const D = FixedTag(u64, 4);
    const value: D.Vector = .{ 0, 1, 0x8000_0000_0000_0001, 0xf0f0_0000_0000_0001 };
    try expectOracleVector(D, .{ 0, 1, 2, 9 }, populationCount(D, value));
    try expectOracleVector(D, .{ 64, 63, 0, 0 }, leadingZeroCount(D, value));
    try expectOracleVector(D, .{ 64, 0, 0, 0 }, trailingZeroCount(D, value));
    try expectOracleVector(D, .{ std.math.maxInt(u64), 0, 63, 63 }, highestSetBitIndex(D, value));
}

fn verifySignOracle() !void {
    const D = FixedTag(f32, 4);
    const U = FixedTag(u32, 4);
    const magnitude: D.Vector = @bitCast(@as(U.Vector, .{ 0, 0x3f80_0000, 0xc000_0000, 0x7fc0_1234 }));
    const absolute: D.Vector = @bitCast(@as(U.Vector, .{ 0, 0x3f80_0000, 0x4000_0000, 0x7fc0_1234 }));
    const signs: D.Vector = @bitCast(@as(U.Vector, .{ 0x8000_0000, 0, 0x8000_0000, 0 }));
    const expected: U.Vector = .{ 0x8000_0000, 0x3f80_0000, 0xc000_0000, 0x7fc0_1234 };
    try expectOracleVector(U, expected, @bitCast(copySign(D, magnitude, signs)));
    try expectOracleVector(U, expected, @bitCast(copySignToAbs(D, absolute, signs)));
    try std.testing.expectEqual(@as(u64, 4), bitsFromMask(D, isNegative(D, magnitude)));
    try std.testing.expectEqual(@as(u64, 8), bitsFromMask(D, isNaN(D, magnitude)));
    const DI = FixedTag(i32, 4);
    const sign_values: DI.Vector = .{ 0, 1, -1, std.math.minInt(i32) };
    try expectOracleVector(DI, .{ 0, 0, -1, -1 }, broadcastSignBit(DI, sign_values));
}

fn verifyLayoutOracle() !void {
    const D = FixedTag(u32, 8);
    const H = D.half();
    const low: D.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const high: D.Vector = .{ 10, 11, 12, 13, 14, 15, 16, 17 };
    try expectOracleVector(H, .{ 0, 1, 2, 3 }, lowerHalf(H, low));
    try expectOracleVector(H, .{ 4, 5, 6, 7 }, upperHalf(H, low));
    try expectOracleVector(D, .{ 0, 1, 2, 3, 0, 0, 0, 0 }, zeroExtendVector(D, lowerHalf(H, low)));
    try expectOracleVector(D, low, combine(D, upperHalf(H, low), lowerHalf(H, low)));
    try expectOracleVector(D, .{ 0, 1, 2, 3, 10, 11, 12, 13 }, concatLowerLower(D, high, low));
    try expectOracleVector(D, .{ 4, 5, 6, 7, 14, 15, 16, 17 }, concatUpperUpper(D, high, low));
    try expectOracleVector(D, .{ 4, 5, 6, 7, 10, 11, 12, 13 }, concatLowerUpper(D, high, low));
    try expectOracleVector(D, .{ 0, 1, 2, 3, 14, 15, 16, 17 }, concatUpperLower(D, high, low));
    try expectOracleVector(D, .{ 1, 3, 5, 7, 11, 13, 15, 17 }, concatOdd(D, high, low));
    try expectOracleVector(D, .{ 0, 2, 4, 6, 10, 12, 14, 16 }, concatEven(D, high, low));
    try expectOracleVector(D, .{ 0, 10, 1, 11, 2, 12, 3, 13 }, interleaveWholeLower(D, low, high));
    try expectOracleVector(D, .{ 4, 14, 5, 15, 6, 16, 7, 17 }, interleaveWholeUpper(D, low, high));
    const mask = lt(D, low, @as(D.Vector, @splat(5)));
    try std.testing.expectEqual(@as(u64, 0x0f), bitsFromMask(H, lowerHalfOfMask(H, mask)));
    try std.testing.expectEqual(@as(u64, 0x01), bitsFromMask(H, upperHalfOfMask(H, mask)));
    try std.testing.expectEqual(@as(u64, 0x1f), bitsFromMask(D, combineMasks(D, upperHalfOfMask(H, mask), lowerHalfOfMask(H, mask))));
}

fn verifyResizeOracle() !void {
    const D = FixedTag(u16, 8);
    const H = D.half();
    const T = D.twice();
    const value: D.Vector = .{ 0x1001, 0x2002, 0x3003, 0x4004, 0x5005, 0x6006, 0x7007, 0x8008 };
    try expectOracleVector(H, .{ 0x1001, 0x2002, 0x3003, 0x4004 }, resizeBitCast(H, value));
    try expectOracleVector(T, .{
        0x1001, 0x2002, 0x3003, 0x4004, 0x5005, 0x6006, 0x7007, 0x8008,
        0,      0,      0,      0,      0,      0,      0,      0,
    }, zeroExtendResizeBitCast(T, D, value));
}

fn verifyConversionOracle() !void {
    const F = FixedTag(f32, 8);
    const I = FixedTag(i32, 8);
    const U = FixedTag(u32, 8);
    const float_bits: U.Vector = .{
        0xc060_0000,
        0xbf00_0000,
        0,
        0x409c_cccd,
        0x4f00_0000,
        0xcf00_0000,
        0x7f80_0000,
        0xff80_0000,
    };
    try expectOracleVector(I, .{
        -3,
        0,
        0,
        4,
        std.math.maxInt(i32),
        std.math.minInt(i32),
        std.math.maxInt(i32),
        std.math.minInt(i32),
    }, convertTo(I, @as(F.Vector, @bitCast(float_bits))));
    try expectOracleVector(U, .{
        0,
        0,
        0,
        4,
        2_147_483_648,
        0,
        std.math.maxInt(u32),
        0,
    }, convertTo(U, @as(F.Vector, @bitCast(float_bits))));

    const I16 = FixedTag(i16, 8);
    const U16 = FixedTag(u16, 8);
    const integers: I.Vector = .{
        std.math.minInt(i32), -65_536, -1, 0, 1, 65_535, 65_536, std.math.maxInt(i32),
    };
    try expectOracleVector(I16, .{
        -32_768, -32_768, -1, 0, 1, 32_767, 32_767, 32_767,
    }, demoteTo(I16, integers));
    try expectOracleVector(U16, .{
        0, 0, 0, 0, 1, 65_535, 65_535, 65_535,
    }, demoteTo(U16, integers));

    const B = FixedTag(u8, 8);
    const W = FixedTag(u16, 4);
    const bytes: B.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try expectOracleVector(W, .{ 0, 1, 2, 3 }, promoteLowerTo(W, bytes));
    try expectOracleVector(W, .{ 4, 5, 6, 7 }, promoteUpperTo(W, bytes));
    try expectOracleVector(W, .{ 0, 2, 4, 6 }, promoteEvenTo(W, bytes));
    try expectOracleVector(W, .{ 1, 3, 5, 7 }, promoteOddTo(W, bytes));
    const a: W.Vector = .{ 0x0102, 0x03ff, 0x0400, 0xffff };
    const b: W.Vector = .{ 0x1005, 0x2006, 0x3007, 0x4008 };
    try expectOracleVector(B, .{ 255, 255, 255, 255, 255, 255, 255, 255 }, orderedDemote2To(B, a, b));
    try expectOracleVector(B, .{ 2, 255, 0, 255, 5, 6, 7, 8 }, orderedTruncate2To(B, a, b));
}

fn verifyArrangeOracle() !void {
    const D = FixedTag(u32, 8);
    const a: D.Vector = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const b: D.Vector = .{ 10, 11, 12, 13, 14, 15, 16, 17 };
    const mask: D.Mask = .{ false, true, true, false, true, false, false, true };
    try expectOracleVector(D, .{ 0, 10, 1, 11, 4, 14, 5, 15 }, interleaveLower(D, a, b));
    try expectOracleVector(D, .{ 2, 12, 3, 13, 6, 16, 7, 17 }, interleaveUpper(D, a, b));
    try expectOracleVector(D, .{ 0, 10, 2, 12, 4, 14, 6, 16 }, interleaveEven(D, a, b));
    try expectOracleVector(D, .{ 1, 11, 3, 13, 5, 15, 7, 17 }, interleaveOdd(D, a, b));
    try expectOracleVector(D, .{ 0, 0, 1, 2, 0, 4, 5, 6 }, shiftLeftLanes(D, 1, a));
    try expectOracleVector(D, .{ 1, 2, 3, 0, 5, 6, 7, 0 }, shiftRightLanes(D, 1, a));
    try expectOracleVector(D, .{ 2, 3, 10, 11, 6, 7, 14, 15 }, combineShiftRightLanes(D, 2, b, a));
    try expectOracleVector(D, .{ 7, 6, 5, 4, 3, 2, 1, 0 }, reverse(D, a));
    try expectOracleVector(D, .{ 4, 5, 6, 7, 0, 1, 2, 3 }, reverseBlocks(D, a));
    const compacted = compress(D, a, mask);
    try expectOracleVector(D, .{ 1, 2, 4, 7, 0, 3, 5, 6 }, compacted);
    try expectOracleVector(D, .{ 0, 1, 2, 0, 4, 0, 0, 7 }, expand(D, compacted, mask));
    try expectOracleVector(D, .{ 0, 0, 0, 0, 1, 2, 3, 4 }, slideUpLanes(D, a, 3));
    try expectOracleVector(D, .{ 3, 4, 5, 6, 7, 0, 0, 0 }, slideDownLanes(D, a, 3));
    try expectOracleVector(D, @splat(28), sumOfLanes(D, a));
    try std.testing.expectEqual(@as(u32, 14), maskedReduceSum(D, mask, a));
    const indices: D.Vector = .{ 7, 0, 5, 2, 4, 1, 6, 3 };
    try expectOracleVector(D, .{ 7, 0, 5, 2, 4, 1, 6, 3 }, tableLookupLanes(D, a, indices));
    try expectOracleVector(D, .{ 3, 2, 1, 0, 7, 6, 5, 4 }, per4LaneBlockShuffle(D, 0, 1, 2, 3, a));
    var interleaved: [16]u32 = undefined;
    storeInterleaved2(D, a, b, &interleaved);
    try std.testing.expectEqualSlices(u32, &.{
        0, 10, 1, 11, 2, 12, 3, 13, 4, 14, 5, 15, 6, 16, 7, 17,
    }, &interleaved);
}

test "simd root composes a vector load compute store pipeline" {
    const D = FixedTag(u32, 4);
    const left = [_]u32{ 1, 2, 3, 4 };
    const right = [_]u32{ 10, 20, 30, 40 };
    var output: [4]u32 = undefined;
    store(D, add(D, load(D, &left), load(D, &right)), &output);
    try std.testing.expectEqualSlices(u32, &.{ 11, 22, 33, 44 }, &output);
}

test "pinned Highway AVX2 oracle agrees on wrapping lanes" {
    const D = FixedTag(u32, 8);
    const a = iota(D, 0xffff_fffc);
    const b = iota(D, 3);
    const mask = lt(D, a, b);
    try std.testing.expect(allTrue(D, eq(D, add(D, a, b), @as(D.Vector, .{ 0xffff_ffff, 1, 3, 5, 7, 9, 11, 13 }))));
    try std.testing.expect(allTrue(D, eq(D, sub(D, a, b), @as(D.Vector, @splat(0xffff_fff9)))));
    try std.testing.expect(allTrue(D, eq(D, mul(D, a, b), @as(D.Vector, .{ 0xffff_fff4, 0xffff_fff4, 0xffff_fff6, 0xffff_fffa, 0, 8, 18, 30 }))));
    try std.testing.expect(allTrue(D, eq(D, select(D, mask, a, b), @as(D.Vector, .{ 3, 4, 5, 6, 0, 1, 2, 3 }))));
    try std.testing.expectEqual(@as(u32, 48), reduceSum(D, add(D, a, b)));
    try std.testing.expectEqual(@as(usize, 4), countTrue(D, mask));
}

test "pinned Highway AVX2 oracle agrees on bit operations" {
    try verifySignedBitOracle();
    try verifyWideRotateOracle();
    try verifyWideCountOracle();
    try verifySignOracle();
}

test "pinned Highway AVX2 oracle agrees on lane geometry" {
    try verifyLayoutOracle();
    try verifyResizeOracle();
}

test "pinned Highway AVX2 oracle agrees on numeric conversions" {
    try verifyConversionOracle();
}

test "pinned Highway AVX2 oracle agrees on swizzle compaction and reduction" {
    try verifyArrangeOracle();
}

test "simd package namespace" {
    std.testing.refAllDecls(simd);
}

test "pinned Highway public declarations stay present" {
    comptime {
        for (parity.core_callables) |callable| {
            if (!@hasDecl(simd, callable.zig)) {
                @compileError("missing pinned Highway callable: " ++ callable.upstream);
            }
        }
        for (parity.supplemental_callables) |callable| {
            if (!@hasDecl(simd, callable.zig)) {
                @compileError("missing pinned Highway declaration: " ++ callable.upstream);
            }
        }
    }
}

test "pinned Highway base scalar differential digest" {
    var digest: u64 = 0xcbf2_9ce4_8422_2325;
    const divisors32 = [_]u32{ 1, 2, 3, 7, 31, 65_537, 0x8000_0001, 0xffff_ffff };
    const dividends32 = [_]u32{ 0, 1, 2, 7, 0x7fff_ffff, 0x8000_0000, 0xffff_fffe, 0xffff_ffff };
    for (divisors32) |divisor| {
        const prepared = Divisor.init(divisor);
        digest = baseDigestStep(digest, prepared.getDivisor());
        for (dividends32) |dividend| {
            digest = baseDigestStep(digest, prepared.divide(dividend));
            digest = baseDigestStep(digest, prepared.remainder(dividend));
            digest = baseDigestStep(digest, lemireMod(dividend, divisor));
        }
    }

    const divisors64 = [_]u64{
        1,
        2,
        3,
        7,
        0x0000_0001_0000_0001,
        0x7fff_ffff_ffff_ffff,
        0x8000_0000_0000_0001,
        0xffff_ffff_ffff_ffff,
    };
    const dividends64 = [_]u64{
        0,
        1,
        2,
        7,
        0x7fff_ffff_ffff_ffff,
        0x8000_0000_0000_0000,
        0xffff_ffff_ffff_fffe,
        0xffff_ffff_ffff_ffff,
    };
    for (divisors64) |divisor| {
        const prepared = Divisor64.init(divisor);
        digest = baseDigestStep(digest, prepared.getDivisor());
        for (dividends64) |dividend| {
            digest = baseDigestStep(digest, prepared.divide(dividend));
            digest = baseDigestStep(digest, prepared.remainder(dividend));
        }
    }
    try std.testing.expectEqual(@as(u64, 300_788_720_801_098_909), digest);
}

fn baseDigestStep(digest: u64, value: u64) u64 {
    return (digest ^ value) *% 0x0000_0100_0000_01b3;
}

test {
    _ = parity;
    _ = @import("topology/test.zig");
    _ = @import("thread/test.zig");
    _ = @import("image/test.zig");
    _ = @import("sort/test.zig");
    _ = @import("phast/test.zig");
    _ = @import("cuckoo/test.zig");
}
