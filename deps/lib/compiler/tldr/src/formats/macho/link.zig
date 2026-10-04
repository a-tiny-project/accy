const std = @import("std");
const root = @import("../../root.zig");
const macho = @import("root.zig");

pub fn linkExecutable(
    allocator: std.mem.Allocator,
    inputs: []const root.Input,
    options: root.LinkOptions,
) root.Error!root.LinkedImage {
    return switch (options.target.architecture) {
        .x86_64 => macho.classic.linkExecutable(allocator, inputs, options),
        .aarch64 => macho.executable.linkExecutable(allocator, inputs, options),
        else => error.UnsupportedArchitecture,
    };
}
