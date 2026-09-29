const std = @import("std");
const dialects = @import("../../../../../../dialects/root.zig");

const CmpPredicate = dialects.arith.CmpPredicate;
const ScalarKind = dialects.arith.ScalarKind;

pub const BinaryKind = enum {
    add,
    sub,
    mul,
    div,
    rem,
    band,
    bor,
    bxor,
    shl,
    shr,
    ushr,
};

const CmpClass = enum {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
};

pub fn requireNoSubwordArithmetic(kind: ScalarKind) error{CodeGenFailed}!void {
    return switch (kind) {
        .i8, .i16, .u8, .u16, .f16, .bf16 => error.CodeGenFailed,
        else => {},
    };
}

pub fn binary(kind: BinaryKind, scalar: ScalarKind) error{CodeGenFailed}!u8 {
    return switch (scalar) {
        .i32, .index, .bool => switch (kind) {
            .add => 0x6a,
            .sub => 0x6b,
            .mul => 0x6c,
            .div => 0x6d,
            .rem => 0x6f,
            .band => 0x71,
            .bor => 0x72,
            .bxor => 0x73,
            .shl => 0x74,
            .shr => 0x75,
            .ushr => 0x76,
        },
        .u32 => switch (kind) {
            .add => 0x6a,
            .sub => 0x6b,
            .mul => 0x6c,
            .div => 0x6e,
            .rem => 0x70,
            .band => 0x71,
            .bor => 0x72,
            .bxor => 0x73,
            .shl => 0x74,
            .shr, .ushr => 0x76,
        },
        .i64 => switch (kind) {
            .add => 0x7c,
            .sub => 0x7d,
            .mul => 0x7e,
            .div => 0x7f,
            .rem => 0x81,
            .band => 0x83,
            .bor => 0x84,
            .bxor => 0x85,
            .shl => 0x86,
            .shr => 0x87,
            .ushr => 0x88,
        },
        .u64 => switch (kind) {
            .add => 0x7c,
            .sub => 0x7d,
            .mul => 0x7e,
            .div => 0x80,
            .rem => 0x82,
            .band => 0x83,
            .bor => 0x84,
            .bxor => 0x85,
            .shl => 0x86,
            .shr, .ushr => 0x88,
        },
        .f32 => switch (kind) {
            .add => 0x92,
            .sub => 0x93,
            .mul => 0x94,
            .div => 0x95,
            else => error.CodeGenFailed,
        },
        .f64 => switch (kind) {
            .add => 0xa0,
            .sub => 0xa1,
            .mul => 0xa2,
            .div => 0xa3,
            else => error.CodeGenFailed,
        },
        else => error.CodeGenFailed,
    };
}

pub fn comparison(
    predicate_value: CmpPredicate,
    scalar: ScalarKind,
) error{CodeGenFailed}!u8 {
    return switch (scalar) {
        .i32, .u32, .index, .bool => switch (integerPredicate(predicate_value)) {
            .eq => 0x46,
            .ne => 0x47,
            .lt => if (integerPredicateIsUnsigned(predicate_value, scalar)) 0x49 else 0x48,
            .le => if (integerPredicateIsUnsigned(predicate_value, scalar)) 0x4d else 0x4c,
            .gt => if (integerPredicateIsUnsigned(predicate_value, scalar)) 0x4b else 0x4a,
            .ge => if (integerPredicateIsUnsigned(predicate_value, scalar)) 0x4f else 0x4e,
        },
        .i64, .u64 => switch (integerPredicate(predicate_value)) {
            .eq => 0x51,
            .ne => 0x52,
            .lt => if (integerPredicateIsUnsigned(predicate_value, scalar)) 0x54 else 0x53,
            .le => if (integerPredicateIsUnsigned(predicate_value, scalar)) 0x58 else 0x57,
            .gt => if (integerPredicateIsUnsigned(predicate_value, scalar)) 0x56 else 0x55,
            .ge => if (integerPredicateIsUnsigned(predicate_value, scalar)) 0x5a else 0x59,
        },
        .f32 => switch (floatPredicate(predicate_value)) {
            .eq => 0x5b,
            .ne => 0x5c,
            .lt => 0x5d,
            .le => 0x5f,
            .gt => 0x5e,
            .ge => 0x60,
        },
        .f64 => switch (floatPredicate(predicate_value)) {
            .eq => 0x61,
            .ne => 0x62,
            .lt => 0x63,
            .le => 0x65,
            .gt => 0x64,
            .ge => 0x66,
        },
        else => error.CodeGenFailed,
    };
}

fn integerPredicate(predicate_value: CmpPredicate) CmpClass {
    return switch (predicate_value) {
        .eq => .eq,
        .ne => .ne,
        .lt, .slt, .ult => .lt,
        .le, .sle, .ule => .le,
        .gt, .sgt, .ugt => .gt,
        .ge, .sge, .uge => .ge,
    };
}

fn integerPredicateIsUnsigned(predicate_value: CmpPredicate, scalar: ScalarKind) bool {
    return switch (predicate_value) {
        .ult, .ule, .ugt, .uge => true,
        .slt, .sle, .sgt, .sge => false,
        else => switch (scalar) {
            .u32, .u64 => true,
            else => false,
        },
    };
}

fn floatPredicate(predicate_value: CmpPredicate) CmpClass {
    return switch (predicate_value) {
        .eq => .eq,
        .ne => .ne,
        .lt, .slt, .ult => .lt,
        .le, .sle, .ule => .le,
        .gt, .sgt, .ugt => .gt,
        .ge, .sge, .uge => .ge,
    };
}

test "wasm comparison opcodes honor explicit integer signedness" {
    try std.testing.expectEqual(@as(u8, 0x48), try comparison(.slt, .u32));
    try std.testing.expectEqual(@as(u8, 0x49), try comparison(.ult, .i32));
    try std.testing.expectEqual(@as(u8, 0x49), try comparison(.lt, .u32));
    try std.testing.expectEqual(@as(u8, 0x48), try comparison(.lt, .i32));
    try std.testing.expectEqual(@as(u8, 0x53), try comparison(.slt, .u64));
    try std.testing.expectEqual(@as(u8, 0x54), try comparison(.ult, .i64));
}

test "wasm integer arithmetic opcodes preserve scalar signedness" {
    try std.testing.expectEqual(@as(u8, 0x6d), try binary(.div, .i32));
    try std.testing.expectEqual(@as(u8, 0x6e), try binary(.div, .u32));
    try std.testing.expectEqual(@as(u8, 0x7f), try binary(.div, .i64));
    try std.testing.expectEqual(@as(u8, 0x80), try binary(.div, .u64));
    try std.testing.expectEqual(@as(u8, 0x75), try binary(.shr, .i32));
    try std.testing.expectEqual(@as(u8, 0x76), try binary(.shr, .u32));
}
