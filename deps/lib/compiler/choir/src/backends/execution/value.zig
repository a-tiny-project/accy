//! The values a checked call passes and returns, and the check that runs before any entry.

const std = @import("std");
const artifact = @import("../root.zig").artifact;

const Signature = artifact.Signature;
const ScalarType = artifact.ScalarType;
const ValueType = artifact.ValueType;
const VectorType = artifact.VectorType;

/// One vector result. Each lane holds its element's bits, zero-extended to 64.
pub const Vector = struct {
    element: ScalarType,
    lanes: u8,
    /// Entries past `lanes` hold zero.
    bits: [VectorType.max_lanes]u64,
};

/// One argument or result of a checked call.
/// Each scalar variant holds the boundary scalar of the same name. `index` holds a 64-bit word,
/// and `memref` holds an address.
pub const Value = union(enum) {
    i8: i8,
    i16: i16,
    i32: i32,
    i64: i64,
    u8: u8,
    u16: u16,
    u32: u32,
    u64: u64,
    index: u64,
    bool: bool,
    f32: f32,
    f64: f64,
    memref: usize,
    vector: Vector,

    /// Returns the boundary type that a call checks this value against.
    pub fn valueType(self: Value) ValueType {
        return switch (self) {
            .memref => .memref,
            .vector => |vector| .{
                .vector = .{ .element = vector.element, .lanes = vector.lanes },
            },
            inline else => |_, tag| .{ .scalar = @field(ScalarType, @tagName(tag)) },
        };
    }
};

/// Fails with `error.SignatureMismatch` when `args` differ from the parameters of `signature` in
/// count or type, or when `results` has a different length than its result list. A target enters
/// code only after this passes.
pub fn check(
    signature: *const Signature,
    args: []const Value,
    results: []const Value,
) error{SignatureMismatch}!void {
    if (args.len != signature.parameter_count) return error.SignatureMismatch;
    if (results.len != signature.result_count) return error.SignatureMismatch;
    for (args, signature.parameters()) |arg, parameter| {
        if (!arg.valueType().eql(parameter)) return error.SignatureMismatch;
    }
}

/// Whether `check` would pass. Targets assert it on entry.
pub fn agrees(signature: *const Signature, args: []const Value, results: []const Value) bool {
    check(signature, args, results) catch return false;
    return true;
}
