const capacity = @import("capacity");
const support = @import("support.zig");

test "provisioned owner requires literal work limits" {
    const Owner = struct {
        pub const storage_alignment = support.storage_alignment;
        pub const Storage = support.Storage;
        pub const Limits = support.Limits;
        pub const Capacity = support.Capacity;
        pub const Exhaustion = support.Exhaustion;
        pub const claim = support.declaration(@This());

        phase: capacity.Phase,
        capacity: Capacity,
        storage: Storage,
    };
    comptime capacity.requireProvisionedRejectingOwnerShape(Owner);
}
