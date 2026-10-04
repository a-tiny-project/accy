const std = @import("std");
const subject = @import("root.zig");
const cache = @import("cache.zig");
const class = @import("class.zig");
const header = @import("header.zig");
const medium = @import("medium/test.zig");
const model = subject.model;

test {
    std.testing.refAllDecls(cache);
    std.testing.refAllDecls(class);
    std.testing.refAllDecls(header);
    std.testing.refAllDecls(medium);
    std.testing.refAllDecls(model);
}
