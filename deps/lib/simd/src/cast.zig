const std = @import("std");

pub fn bitCast(comptime D: type, value: anytype) D.Vector {
    if (@bitSizeOf(@TypeOf(value)) / 8 != D.byte_count) {
        @compileError("bitCast requires equal source and destination byte sizes");
    }
    return @bitCast(value);
}

pub fn resizeBitCast(comptime D: type, value: anytype) D.Vector {
    return resize(D, value);
}

pub fn zeroExtendResizeBitCast(
    comptime DTo: type,
    comptime DFrom: type,
    value: DFrom.Vector,
) DTo.Vector {
    return resize(DTo, value);
}

fn resize(comptime D: type, value: anytype) D.Vector {
    const source_byte_count = @bitSizeOf(@TypeOf(value)) / 8;
    const SourceBytes = [source_byte_count]u8;
    const source: SourceBytes = @bitCast(value);
    var target: [D.byte_count]u8 = @splat(0);
    inline for (0..@min(source_byte_count, D.byte_count)) |index| {
        target[index] = source[index];
    }
    return @bitCast(target);
}

test "Highway bit casts preserve every source bit" {
    const simd = @import("root.zig");
    const DW = simd.FixedTag(u32, 4);
    const DB = simd.FixedTag(u8, 16);
    const words: DW.Vector = .{ 0x0123_4567, 0x89ab_cdef, 0, 0xffff_ffff };
    const bytes = bitCast(DB, words);
    try std.testing.expect(@reduce(.And, bitCast(DW, bytes) == words));
}

test "Highway resize casts retain low-address bytes and zero extensions" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(u16, 8);
    const DH = simd.FixedTag(u16, 4);
    const DT = simd.FixedTag(u16, 16);
    const value: D.Vector = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expect(@reduce(.And, resizeBitCast(DH, value) ==
        @as(DH.Vector, .{ 1, 2, 3, 4 })));
    try std.testing.expect(@reduce(.And, zeroExtendResizeBitCast(DT, D, value) ==
        @as(DT.Vector, .{ 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0, 0, 0, 0, 0 })));
}

test "Highway resize casts work across lane types" {
    const simd = @import("root.zig");
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, f16, f32, f64 }) |T| {
        const D = simd.FixedTag(T, 4);
        const DB = simd.FixedTag(u8, D.byte_count);
        const DT = simd.FixedTag(T, 8);
        const value: D.Vector = @splat(0);
        try std.testing.expect(@reduce(.And, bitCast(D, bitCast(DB, value)) == value));
        const extended = zeroExtendResizeBitCast(DT, D, value);
        try std.testing.expect(@reduce(.And, resizeBitCast(D, extended) == value));
        try std.testing.expect(@reduce(.And, extended == @as(DT.Vector, @splat(0))));
    }
}
