const std = @import("std");
const alloc_phase = @import("../root.zig");

const Limits = struct {
    input_bytes: usize,
};

const Capacity = struct {
    input_bytes: usize,
    storage_bytes: usize,

    pub fn derive(limits: Limits) alloc_phase.input.DeriveError!Capacity {
        return alloc_phase.input.deriveCapacity(
            Limits,
            Capacity,
            "input_bytes",
            limits,
        );
    }
};

test "one-region capacity matches independent arithmetic across bounded inputs" {
    const input_bytes_max: usize = 4_096;
    for (0..input_bytes_max + 1) |input_bytes| {
        const capacity = try Capacity.derive(.{ .input_bytes = input_bytes });
        try std.testing.expectEqual(input_bytes, capacity.input_bytes);
        try std.testing.expectEqual(input_bytes + 1, capacity.storage_bytes);
        try std.testing.expect(capacity.storage_bytes > capacity.input_bytes);
    }
}
