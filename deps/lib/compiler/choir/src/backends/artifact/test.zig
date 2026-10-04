const std = @import("std");
const artifact = @import("root.zig");
const model = @import("model/test.zig");
const serialization = @import("serialization/test.zig");

test {
    std.testing.refAllDecls(artifact);
    _ = model;
    _ = serialization;
}
