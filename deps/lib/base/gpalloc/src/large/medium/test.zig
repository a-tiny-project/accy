const std = @import("std");
const subject = @import("root.zig");
const cache = @import("cache.zig");
const class = @import("class.zig");
const header = @import("header.zig");

comptime {
    _ = subject;
}

test {
    std.testing.refAllDecls(cache);
    std.testing.refAllDecls(class);
    std.testing.refAllDecls(header);
}
