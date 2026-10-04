const std = @import("std");
const build_api = @import("build_api");

pub fn build(b: *std.Build) void {
    const config = build_api.resolvePackageConfiguration(b);
    _ = b.addModule(
        "alloc_observe_channel",
        config.policy.createOptions(b, "src/root.zig", &.{}),
    );
    const artifact = b.addTest(.{
        .name = "alloc-observe-channel-tests",
        .root_module = b.createModule(
            config.policy.createOptions(b, "src/test.zig", &.{}),
        ),
        .filters = config.test_filters,
    });
    const parent = b.step("test", "Run observer sink channel tests");
    parent.dependOn(&b.addRunArtifact(artifact).step);
}
