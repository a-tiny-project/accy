const std = @import("std");
const key = @import("key.zig");
const random = @import("random.zig");

pub fn choose(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []const Key,
    state: *random.State,
) Key {
    std.debug.assert(values.len != 0);
    const limit: u32 = @intCast(@min(values.len, std.math.maxInt(u32)));
    var samples: [9]Key = undefined;
    for (&samples) |*sample| {
        const index = random.chunkIndex(limit, @truncate(state.next()));
        sample.* = values[index];
    }
    const first = key.medianOf3(Key, direction, samples[0], samples[1], samples[2]);
    const second = key.medianOf3(Key, direction, samples[3], samples[4], samples[5]);
    const third = key.medianOf3(Key, direction, samples[6], samples[7], samples[8]);
    return key.medianOf3(Key, direction, first, second, third);
}
