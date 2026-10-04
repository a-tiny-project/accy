const std = @import("std");
const ir = @import("../../core/root.zig");

pub const capacity = @import("capacity.zig");
pub const index = @import("index.zig");
pub const numbering = @import("numbering.zig");
pub const stable = @import("stable.zig");
pub const walk = @import("walk.zig");

pub const maximum_operation_depth = capacity.maximum_operation_depth;
pub const maximum_attribute_depth = capacity.maximum_attribute_depth;
pub const StableHasher = stable.StableHasher;
pub const StableValueNumbering = numbering.StableValueNumbering;
pub const OperationFingerprintError = std.mem.Allocator.Error || capacity.InspectError || error{
    CapacityOverflow,
    DuplicateValueDefinition,
    InputChanged,
};

pub fn operationFingerprint(
    allocator: std.mem.Allocator,
    operation: *ir.Operation,
) OperationFingerprintError!u64 {
    const limits = try StableHasher.Limits.inspect(operation);
    var hasher = try StableHasher.init(allocator, limits);
    defer hasher.deinit(allocator);
    hasher.activate() catch |err| switch (err) {
        error.AlreadyActive => unreachable,
        error.InputChanged => return error.InputChanged,
    };
    return hasher.fingerprint();
}
