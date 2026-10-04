const std = @import("std");

const fixed = @import("fixed.zig");
const lookup = @import("lookup.zig");
const merge = @import("root.zig");
const section = @import("section.zig");
const start = @import("start.zig");
const string = @import("string.zig");

test {
    std.testing.refAllDecls(fixed);
    std.testing.refAllDecls(lookup);
    std.testing.refAllDecls(merge);
    std.testing.refAllDecls(section);
    std.testing.refAllDecls(start);
    std.testing.refAllDecls(string);
}
