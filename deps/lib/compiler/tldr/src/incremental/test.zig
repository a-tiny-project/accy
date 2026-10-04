const std = @import("std");

const incremental = @import("root.zig");
const manifest = @import("manifest.zig");

test {
    std.testing.refAllDecls(incremental);
    std.testing.refAllDecls(manifest);
}
