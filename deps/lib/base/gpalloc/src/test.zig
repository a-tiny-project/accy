const std = @import("std");
const gpalloc = @import("root.zig");
const cache = @import("cache/test.zig");
const large = @import("large/test.zig");
const page = @import("page/test.zig");

test "gpalloc package namespace" {
    std.testing.refAllDecls(gpalloc);
    std.testing.refAllDecls(cache);
    std.testing.refAllDecls(large);
    std.testing.refAllDecls(page);
}
