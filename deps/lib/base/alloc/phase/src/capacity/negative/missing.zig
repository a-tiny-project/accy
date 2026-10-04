const capacity = @import("capacity");
const support = @import("support.zig");

test "provisioned owner requires stored caller storage" {
    const Owner = struct {
        pub const storage_alignment = support.storage_alignment;
        pub const Storage = support.Storage;
        pub const Limits = support.Limits;
        pub const Capacity = support.Capacity;
        pub const Exhaustion = support.Exhaustion;
        pub const work_limits = support.work_limits;
        pub const claim = support.declaration(@This());

        phase: capacity.Phase,
        capacity: Capacity,

        pub fn init(_: Storage, limits: Limits) support.InitError!@This() {
            return .{
                .phase = .initialization,
                .capacity = try Capacity.derive(limits),
            };
        }

        pub fn activate(self: *@This()) void {
            self.phase = .steady;
        }

        pub fn submit(_: *@This()) Exhaustion!void {}

        pub fn deinit(_: *@This()) Storage {
            unreachable;
        }
    };
    comptime capacity.requireProvisionedRejectingOwnerShape(Owner);
}
