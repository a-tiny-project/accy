const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const package = b.dependency("accy", .{ .target = target, .optimize = optimize });
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "accy", .module = package.module("accy") }},
    });
    const executable = b.addExecutable(.{ .name = "consumer", .root_module = root });
    b.installArtifact(executable);
    b.step("run", "Run the consumer").dependOn(&b.addRunArtifact(executable).step);
    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Test the consumer").dependOn(&b.addRunArtifact(tests).step);
}
