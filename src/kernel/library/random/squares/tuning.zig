const random = @import("../root.zig");
const profile = @import("profile.zig");
const types = @import("types.zig");

const base = random.base;
const std = base.std;
const entry = base.entry;
const tuning = base.tuning;

const Squares = types.Squares;
const squares_family_version = types.squares_family_version;
const squaresFamilyFingerprint = profile.squaresFamilyFingerprint;

pub fn squaresTuningExtents(instance: Squares) [1]u64 {
    return .{instance.count};
}

pub fn squaresTuningOperation(instance: Squares) entry.Operation {
    _ = instance;
    return .{ .random = .squares };
}

pub fn squaresFamilyTuningKey(
    backing_allocator: std.mem.Allocator,
    device_fingerprint: u64,
    instance: Squares,
) !tuning.FamilyTuningKey {
    const family_fingerprint = try squaresFamilyFingerprint(backing_allocator, instance);
    const extents = squaresTuningExtents(instance);
    return tuning.FamilyTuningKey.init(
        device_fingerprint,
        family_fingerprint,
        entry.operationFingerprint(squaresTuningOperation(instance)),
        instance.dtype,
        squares_family_version,
        extents[0..],
    ) orelse unreachable;
}
