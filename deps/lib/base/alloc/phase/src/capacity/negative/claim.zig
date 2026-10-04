const capacity = @import("capacity");
const support = @import("support.zig");

test "provisioned owner requires a capacity claim" {
    const Owner = struct {
        pub const storage_alignment = support.storage_alignment;
        pub const Storage = support.Storage;
        pub const Limits = support.Limits;
        pub const Capacity = support.Capacity;
        pub const Exhaustion = support.Exhaustion;
        pub const work_limits = support.work_limits;

        phase: capacity.Phase,
        capacity: Capacity,
        storage: Storage,

        pub fn init(storage: Storage, limits: Limits) support.InitError!@This() {
            return .{
                .phase = .initialization,
                .capacity = try Capacity.derive(limits),
                .storage = storage,
            };
        }

        pub fn activate(self: *@This()) void {
            self.phase = .steady;
        }

        pub fn submit(_: *@This()) Exhaustion!void {}

        pub fn deinit(self: *@This()) Storage {
            return self.storage;
        }
    };
    comptime capacity.requireProvisionedRejectingOwnerShape(Owner);
}
