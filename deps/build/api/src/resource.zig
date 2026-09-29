const std = @import("std");

pub const Class = enum {
    ordinary,
    heavy,
};

pub fn addDependencyReporter(b: *std.Build) *std.Build.Step.Run {
    const dependency = b.dependency("build_api", .{});
    return addReporter(b, dependency.path("loom"));
}

pub fn addDependencyRun(b: *std.Build, class: Class) *std.Build.Step.Run {
    return addRun(
        b,
        b.dependency("build_api", .{}).path("loom"),
        class,
    );
}

pub fn addLocalRun(b: *std.Build, class: Class) *std.Build.Step.Run {
    return addRun(b, b.path("loom"), class);
}

fn addRun(
    b: *std.Build,
    runner: std.Build.LazyPath,
    class: Class,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"sh"});
    run.addFileArg(runner);
    run.addArgs(&.{ "run", @tagName(class), "--local", "--" });
    return run;
}

pub fn addLocalReporter(b: *std.Build) *std.Build.Step.Run {
    return addReporter(b, b.path("loom"));
}

fn addReporter(
    b: *std.Build,
    launcher: std.Build.LazyPath,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"sh"});
    run.addFileArg(launcher);
    return run;
}
