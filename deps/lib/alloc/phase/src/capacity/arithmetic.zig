const std = @import("std");

/// Computes the checked sum of two integer values of type `T`. It delegates to
/// the `@addWithOverflow` builtin, returning `error.CapacityOverflow` if
/// arithmetic overflow or carry occurs. The function imposes no domain-specific
/// maximum bounds or byte limit policies, leaving application limits to owner
/// capacity derivation. On success, it returns the sum as a value of type `T`.
pub inline fn add(comptime T: type, lhs: T, rhs: T) error{CapacityOverflow}!T {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] != 0) return error.CapacityOverflow;
    return result[0];
}

/// Computes the checked product of two integer values of type `T`. It delegates
/// to the `@mulWithOverflow` builtin, returning `error.CapacityOverflow` if
/// arithmetic overflow occurs. The function enforces no external range policies
/// or domain limits beyond the representation limits of type `T`. On success,
/// it returns the product as a value of type `T`.
pub inline fn mul(comptime T: type, lhs: T, rhs: T) error{CapacityOverflow}!T {
    const result = @mulWithOverflow(lhs, rhs);
    if (result[1] != 0) return error.CapacityOverflow;
    return result[0];
}

test "checked capacity arithmetic returns values for two integer types" {
    try std.testing.expectEqual(@as(u8, 7), try add(u8, 3, 4));
    try std.testing.expectEqual(@as(usize, 12), try mul(usize, 3, 4));
}

test "checked capacity arithmetic reports overflow" {
    try std.testing.expectError(error.CapacityOverflow, add(u8, std.math.maxInt(u8), 1));
    try std.testing.expectError(
        error.CapacityOverflow,
        mul(usize, std.math.maxInt(usize), 2),
    );
}
