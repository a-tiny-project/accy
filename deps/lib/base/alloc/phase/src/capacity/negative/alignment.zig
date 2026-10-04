const capacity = @import("capacity");
const support = @import("support.zig");

test "provisioned owner rejects invalid alignment" {
    const Owner = struct {
        pub const storage_alignment: usize = 3;
        pub const Storage = support.Storage;
        pub const Limits = support.Limits;
        pub const Capacity = support.Capacity;
        pub const Exhaustion = support.Exhaustion;
        pub const work_limits = support.work_limits;
        pub const claim = support.declaration(@This());
    };
    comptime capacity.requireProvisionedRejectingOwnerShape(Owner);
}
