const std = @import("std");
const module = @import("root.zig");
const section = @import("section/test.zig");

test {
    std.testing.refAllDecls(module);
    _ = section;
}
