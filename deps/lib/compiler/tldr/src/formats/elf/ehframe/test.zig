const std = @import("std");

const ehframe = @import("root.zig");
const header_suite = @import("header/test.zig");

test {
    std.testing.refAllDecls(ehframe);
    std.testing.refAllDecls(header_suite);
}
