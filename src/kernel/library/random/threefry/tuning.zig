const random = @import("../root.zig");
const profile = @import("profile.zig");
const types = @import("types.zig");

const base = random.base;
const std = base.std;
const entry = base.entry;
const tuning = base.tuning;

const Threefry = types.Threefry;
const threefry_family_version = types.threefry_family_version;
const threefryFamilyFingerprint = profile.threefryFamilyFingerprint;

pub fn threefryTuningExtents(instance: Threefry) [1]u64 {
    return .{instance.count};
}

pub fn threefryTuningOperation(instance: Threefry) entry.Operation {
    return .{ .random = .{ .threefry = instance.rounds } };
}

pub fn threefryFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: Threefry,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try threefryFamilyFingerprint(backing_allocator, instance);
    const extents = threefryTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(threefryTuningOperation(instance)),
        instance.dtype,
        threefry_family_version,
        extents[0..],
    ) orelse unreachable;
}
