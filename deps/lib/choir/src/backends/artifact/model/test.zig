const std = @import("std");
const model = @import("root.zig");
const linkage = @import("linkage/test.zig");
const payload = @import("payload/test.zig");

test {
    std.testing.refAllDecls(model);
    _ = linkage;
    _ = payload;
}
