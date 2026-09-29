const std = @import("std");
const root = @import("root.zig");
const bytecode = @import("bytecode.zig");

test {
    _ = root;
    std.testing.refAllDecls(bytecode);
    std.testing.refAllDecls(root.qualification);
    std.testing.refAllDecls(root.image);
}
