const std = @import("std");

pub fn addRun(
    b: *std.Build,
    test_artifact: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(test_artifact);
    if (run.stdio == .infer_from_args) run.expectExitCode(0);
    return run;
}
