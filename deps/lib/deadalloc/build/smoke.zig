const std = @import("std");

pub fn addCxxSmoke(b: *std.Build) std.Build.LazyPath {
    const source = b.path("src/smoke/cxx.cpp");
    const compile = b.addSystemCommand(&.{ b.graph.zig_exe, "c++", "-std=c++17", "-O2" });
    compile.addFileArg(source);
    compile.addArg("-o");
    return compile.addOutputFileArg("deadalloc-cxx-smoke");
}

pub fn addVerifierSmoke(b: *std.Build) std.Build.LazyPath {
    const source = b.path("src/smoke/verifier.cpp");
    const compile = b.addSystemCommand(&.{ b.graph.zig_exe, "c++", "-std=c++17", "-O2" });
    compile.addFileArg(source);
    compile.addArg("-o");
    return compile.addOutputFileArg("deadalloc-verifier-smoke");
}

pub fn addReferenceSmoke(
    b: *std.Build,
    step: *std.Build.Step,
    reference_build: []const u8,
    library_name: []const u8,
    test_name: []const u8,
) void {
    addReferenceSmokeArgs(b, step, reference_build, library_name, test_name, &.{});
}

pub fn addReferenceSmokeArgs(
    b: *std.Build,
    step: *std.Build.Step,
    reference_build: []const u8,
    library_name: []const u8,
    test_name: []const u8,
    args: []const []const u8,
) void {
    const run = b.addSystemCommand(&.{
        b.pathJoin(&.{ reference_build, "tests", test_name }),
    });
    run.addArgs(args);
    run.setEnvironmentVariable("LD_PRELOAD", b.pathJoin(&.{ reference_build, library_name }));
    step.dependOn(&run.step);
}

pub fn addReferenceCxxSmoke(
    b: *std.Build,
    step: *std.Build.Step,
    cxx_smoke: std.Build.LazyPath,
    reference_build: []const u8,
    library_name: []const u8,
) void {
    const run = b.addSystemCommand(&.{ "sh", "-c", "exec \"$1\"", "deadalloc-cxx-smoke" });
    run.addFileArg(cxx_smoke);
    run.setEnvironmentVariable("LD_PRELOAD", b.pathJoin(&.{ reference_build, library_name }));
    step.dependOn(&run.step);
}

pub fn addReferenceVerifierSmoke(
    b: *std.Build,
    step: *std.Build.Step,
    verifier_smoke: std.Build.LazyPath,
    reference_build: []const u8,
    library_name: []const u8,
) void {
    const run = b.addSystemCommand(&.{ "sh", "-c", "exec \"$1\"", "deadalloc-verifier-smoke" });
    run.addFileArg(verifier_smoke);
    run.setEnvironmentVariable("LD_PRELOAD", b.pathJoin(&.{ reference_build, library_name }));
    step.dependOn(&run.step);
}

pub fn addDeadallocSmoke(
    b: *std.Build,
    step: *std.Build.Step,
    library: std.Build.LazyPath,
    reference_build: []const u8,
    test_name: []const u8,
) void {
    addDeadallocSmokeArgs(b, step, library, reference_build, test_name, &.{});
}

pub fn addDeadallocSmokeArgs(
    b: *std.Build,
    step: *std.Build.Step,
    library: std.Build.LazyPath,
    reference_build: []const u8,
    test_name: []const u8,
    args: []const []const u8,
) void {
    const run = b.addSystemCommand(&.{"env"});
    run.addPrefixedFileArg("LD_PRELOAD=", library);
    run.addArg(b.pathJoin(&.{ reference_build, "tests", test_name }));
    run.addArgs(args);
    step.dependOn(&run.step);
}

pub fn addDeadallocVerifierSmoke(
    b: *std.Build,
    step: *std.Build.Step,
    verifier_smoke: std.Build.LazyPath,
    library: std.Build.LazyPath,
) void {
    const run = b.addSystemCommand(&.{"env"});
    run.addPrefixedFileArg("LD_PRELOAD=", library);
    run.addFileArg(verifier_smoke);
    step.dependOn(&run.step);
}

pub fn addDeadallocCxxSmoke(
    b: *std.Build,
    step: *std.Build.Step,
    cxx_smoke: std.Build.LazyPath,
    library: std.Build.LazyPath,
) void {
    const run = b.addSystemCommand(&.{"env"});
    run.addPrefixedFileArg("LD_PRELOAD=", library);
    run.addFileArg(cxx_smoke);
    step.dependOn(&run.step);
}
