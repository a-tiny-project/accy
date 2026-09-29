const std = @import("std");

pub fn register(b: *std.Build) *std.Build.Step {
    const check = generator(b, true);
    const check_step = b.step("generated-check", "Check generated Wayland schema is current");
    check_step.dependOn(&check.step);

    const generate = generator(b, false);
    const generate_step = b.step("generate", "Regenerate Wayland schema from pinned XML");
    generate_step.dependOn(&generate.step);
    return check_step;
}

fn generator(b: *std.Build, check: bool) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path("build/generate"));
    run.addArgs(&.{ "--zig", b.graph.zig_exe });
    if (check) run.addArg("--check");
    run.setCwd(b.path("."));
    return run;
}
