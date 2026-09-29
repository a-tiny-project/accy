const std = @import("std");
const emission = @import("root.zig");
const function = @import("function/test.zig");
const module = @import("module/test.zig");
const plan = @import("plan/test.zig");

test {
    std.testing.refAllDecls(emission);
    _ = function;
    _ = module;
    _ = plan;
}
