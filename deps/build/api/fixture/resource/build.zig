const std = @import("std");
const build_api = @import("build_api");

pub fn build(b: *std.Build) void {
    const executable = b.addExecutable(.{
        .name = "resource-locality-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
        .use_llvm = false,
    });
    const run = build_api.addResourceRun(b, .heavy);
    run.addArtifactArg(executable);
    run.setName("run build-owned executable on its executor");
    b.step("check", "Check build-owned executable locality").dependOn(&run.step);
}
