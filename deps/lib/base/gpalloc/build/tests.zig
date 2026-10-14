const std = @import("std");
const build_api = @import("build_api");
const module = @import("module.zig");

pub fn add(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    sys: *std.Build.Module,
    filters: []const []const u8,
) void {
    const tests = b.addTest(.{
        .root_module = module.createTestModule(b, policy, .{ .sys = sys }),
        .filters = filters,
    });
    const run = b.addRunArtifact(tests);
    const step = b.step("test", "Run gpalloc unit tests");
    step.dependOn(&run.step);
}
