const std = @import("std");
const interfaces = @import("root.zig");
const attrs = @import("attrs.zig");
const base = @import("base.zig");
const ops = @import("ops.zig");
const traits = @import("traits.zig");
const types = @import("types.zig");

test "choir core interfaces namespace" {
    _ = interfaces;
    std.testing.refAllDecls(interfaces.effects);
    std.testing.refAllDecls(base);
    std.testing.refAllDecls(traits);
    std.testing.refAllDecls(attrs);
    std.testing.refAllDecls(ops);
    std.testing.refAllDecls(types);
}
