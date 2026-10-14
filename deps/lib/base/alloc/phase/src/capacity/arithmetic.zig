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

/// Byte range that `place` lays out for one sub-region of a composed region.
/// `offset` is a multiple of the alignment the sub-region was placed at, and
/// `end` is `offset + bytes`, the first byte after it.
pub const Placement = struct {
    offset: usize,
    bytes: usize,
    end: usize,
};

/// Places a sub-region of `bytes` at the first multiple of `alignment` at or
/// after `offset`, with checked arithmetic. `alignment` must be a nonzero power
/// of two. Returns `error.CapacityOverflow` when the aligned start or the end
/// does not fit `usize`. A composed owner places each delegated owner's
/// `storage_bytes` at that owner's `storage_alignment` this way.
pub fn place(
    offset: usize,
    alignment: usize,
    bytes: usize,
) error{CapacityOverflow}!Placement {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    const mask = alignment - 1;
    const start = (try add(usize, offset, mask)) & ~mask;
    std.debug.assert(start >= offset);
    std.debug.assert(start - offset < alignment);
    return .{ .offset = start, .bytes = bytes, .end = try add(usize, start, bytes) };
}
