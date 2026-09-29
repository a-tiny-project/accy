const std = @import("std");
const serialization = @import("root.zig");
const binary = @import("binary/test.zig");

test {
    std.testing.refAllDecls(serialization);
    _ = binary;
}
