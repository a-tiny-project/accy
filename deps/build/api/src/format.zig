const std = @import("std");

pub fn register(b: *std.Build) *std.Build.Step {
    const inventory_command = b.addSystemCommand(&.{
        "git",
        "ls-files",
        "-z",
        "--",
        "*.zig",
        "build.zig.zon",
    });
    inventory_command.setName("inventory tracked Zig source");
    inventory_command.setCwd(b.path("."));
    inventory_command.has_side_effects = true;
    const inventory = inventory_command.captureStdOut(.{
        .trim_whitespace = .none,
    });
    const format = b.addSystemCommand(&.{
        "xargs",
        "-0",
        b.graph.zig_exe,
        "fmt",
        "--check",
    });
    format.setName("check tracked Zig source formatting");
    format.setCwd(b.path("."));
    format.setStdIn(.{ .lazy_path = inventory });
    format.has_side_effects = true;
    const step = b.step("fmt", "Check Zig source formatting");
    step.dependOn(&format.step);
    return step;
}
