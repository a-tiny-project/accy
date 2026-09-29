const std = @import("std");

const address = @import("root.zig");
const cache = @import("cache.zig");

test {
    std.testing.refAllDecls(address);
    std.testing.refAllDecls(cache);
}
