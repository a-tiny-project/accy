const std = @import("std");

pub fn add(b: *std.Build) *std.Build.Step {
    const generated_check = command(b, true);
    const generated_check_step = b.step(
        "generated-check",
        "Check generated XKB tables are current",
    );
    generated_check_step.dependOn(&generated_check.step);

    _ = b.step(
        "generated-check-check",
        "Check generated-check without emitting products or running effects",
    );

    const generate = command(b, false);
    const generate_step = b.step("generate", "Regenerate XKB tables from pinned sources");
    generate_step.dependOn(&generate.step);
    return generated_check_step;
}

fn command(b: *std.Build, check: bool) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path("build/generate"));
    if (check) run.addArg("--check");
    run.setCwd(b.path("."));
    return run;
}
