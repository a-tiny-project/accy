const random = @import("../root.zig");
const profile = @import("profile.zig");
const types = @import("types.zig");

const base = random.base;
const std = base.std;
const entry = base.entry;
const tuning = base.tuning;

const Philox = types.Philox;
const philox_family_version = types.philox_family_version;
const philoxFamilyFingerprint = profile.philoxFamilyFingerprint;

pub fn philoxTuningExtents(instance: Philox) [1]u64 {
    return .{instance.count};
}

pub fn philoxTuningOperation(instance: Philox) entry.Operation {
    return .{ .random = .{ .philox = instance.rounds } };
}

pub fn philoxFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: Philox,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try philoxFamilyFingerprint(backing_allocator, instance);
    const extents = philoxTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(philoxTuningOperation(instance)),
        instance.dtype,
        philox_family_version,
        extents[0..],
    ) orelse unreachable;
}
