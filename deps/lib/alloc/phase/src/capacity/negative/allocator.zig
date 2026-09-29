const std = @import("std");
const capacity = @import("capacity");
const support = @import("support.zig");

test "provisioned owner rejects allocator-bearing limits" {
    const AllocatorLimits = struct {
        allocator: std.mem.Allocator,
        slots: usize,
    };
    const AllocatorCapacity = struct {
        storage_bytes: usize,

        pub fn derive(limits: AllocatorLimits) error{InvalidLimit}!@This() {
            if (limits.slots == 0) return error.InvalidLimit;
            return .{ .storage_bytes = limits.slots };
        }
    };
    const Owner = struct {
        pub const storage_alignment = support.storage_alignment;
        pub const Storage = support.Storage;
        pub const Limits = AllocatorLimits;
        pub const Capacity = AllocatorCapacity;
        pub const Exhaustion = support.Exhaustion;
        pub const work_limits = support.work_limits;
        pub const claim = support.declaration(@This());

        phase: capacity.Phase,
        capacity: Capacity,
        storage: Storage,
    };
    comptime capacity.requireProvisionedRejectingOwnerShape(Owner);
}
