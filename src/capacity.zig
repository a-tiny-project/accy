const std = @import("std");

test {
    std.testing.refAllDecls(@import("kernel/model/core/root.zig"));
    std.testing.refAllDecls(@import("kernel/model/program/root.zig"));
}
