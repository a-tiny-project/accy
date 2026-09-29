const capacity = @import("capacity");
const support = @import("support.zig");

test "provisioned owner rejects anyerror capacity derivation" {
    const AnyCapacity = struct {
        storage_bytes: usize,

        pub fn derive(limits: support.Limits) anyerror!@This() {
            return .{ .storage_bytes = limits.slots };
        }
    };
    const Owner = struct {
        pub const storage_alignment = support.storage_alignment;
        pub const Storage = support.Storage;
        pub const Limits = support.Limits;
        pub const Capacity = AnyCapacity;
        pub const Exhaustion = support.Exhaustion;
        pub const work_limits = support.work_limits;
        pub const claim = support.declaration(@This());

        phase: capacity.Phase,
        capacity: Capacity,
        storage: Storage,
    };
    comptime capacity.requireProvisionedRejectingOwnerShape(Owner);
}
