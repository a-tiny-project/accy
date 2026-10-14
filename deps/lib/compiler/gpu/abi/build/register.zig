const std = @import("std");
const configuration = @import("configuration.zig");
const module = @import("module.zig");

pub fn build(b: *std.Build) void {
    const config = configuration.resolve(b);
    _ = module.registered(b, config.policy);
    const artifact = b.addTest(.{
        .root_module = module.testing(b, config.policy),
        .filters = config.test_filters,
    });
    const parent = b.step("test", "Run the compiled-kernel interface tests");
    parent.dependOn(&b.addRunArtifact(artifact).step);
}
