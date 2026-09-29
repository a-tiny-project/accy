const namespace = @import("root.zig");
const std = @import("std");

const command = namespace.command;
const types = namespace.types;
const terminal = namespace.terminal;
const render = namespace.render;
test {
    _ = @import("command/test.zig");
}

test "pretty usage package namespace" {
    _ = command;
    std.testing.refAllDecls(types);
    std.testing.refAllDecls(terminal);
    std.testing.refAllDecls(render);
}
