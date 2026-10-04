const std = @import("std");

test "incremental link sentinel" {
    const sentinel: u8 = 2;
    std.mem.doNotOptimizeAway(sentinel);
}
