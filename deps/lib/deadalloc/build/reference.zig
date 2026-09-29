const std = @import("std");
const preload = @import("preload.zig");
const smoke = @import("smoke.zig");

const reference_libraries = [_][]const u8{
    "libdiehard.so",
    "libdieharder.so",
};

const reference_tests = [_][]const u8{
    "test_invalidfree",
    "test_doublefree",
    "test_remote_free",
};

const thread_args = [_][]const u8{ "2", "2", "200", "0", "4" };
const missing_command =
    "printf '%s\n' 'pass -Ddiehard-reference-build=/path/to/DieHard/build " ++
    "to run reference smokes' >&2; exit 1";

pub fn add(
    b: *std.Build,
    reference_build: []const u8,
    unit_run: *std.Build.Step,
    installs: preload.Installs,
) void {
    const parent = b.step(
        "reference",
        "Run deadalloc checks beside DieHard reference smokes",
    );
    parent.dependOn(unit_run);
    parent.dependOn(installs.exterminator.step);
    parent.dependOn(installs.dieharder.step);
    parent.dependOn(installs.diehard.step);
    if (reference_build.len == 0) {
        addMissingPath(b, parent);
        return;
    }

    const cxx = smoke.addCxxSmoke(b);
    const verifier = smoke.addVerifierSmoke(b);
    addReferenceSmokes(b, parent, reference_build, cxx, verifier);
    addDeadallocMode(
        b,
        parent,
        installs.exterminator,
        reference_build,
        &.{ "test_invalidfree", "test_doublefree" },
        cxx,
        verifier,
    );
    addDeadallocMode(
        b,
        parent,
        installs.dieharder,
        reference_build,
        &.{ "test_invalidfree", "test_doublefree", "test_remote_free" },
        cxx,
        verifier,
    );
    addDeadallocMode(
        b,
        parent,
        installs.diehard,
        reference_build,
        &.{"test_remote_free"},
        cxx,
        verifier,
    );
}

fn addMissingPath(b: *std.Build, parent: *std.Build.Step) void {
    const missing = b.addSystemCommand(&.{
        "sh",
        "-c",
        missing_command,
    });
    parent.dependOn(&missing.step);
}

fn addReferenceSmokes(
    b: *std.Build,
    parent: *std.Build.Step,
    reference_build: []const u8,
    cxx: std.Build.LazyPath,
    verifier: std.Build.LazyPath,
) void {
    for (reference_tests) |test_name| {
        for (reference_libraries) |library_name| {
            smoke.addReferenceSmoke(
                b,
                parent,
                reference_build,
                library_name,
                test_name,
            );
        }
    }
    for (reference_libraries) |library_name| {
        smoke.addReferenceSmokeArgs(
            b,
            parent,
            reference_build,
            library_name,
            "threadtest",
            &thread_args,
        );
    }
    for (reference_libraries) |library_name| {
        smoke.addReferenceCxxSmoke(
            b,
            parent,
            cxx,
            reference_build,
            library_name,
        );
    }
    for (reference_libraries) |library_name| {
        smoke.addReferenceVerifierSmoke(
            b,
            parent,
            verifier,
            reference_build,
            library_name,
        );
    }
}

fn addDeadallocMode(
    b: *std.Build,
    parent: *std.Build.Step,
    install: preload.Install,
    reference_build: []const u8,
    tests: []const []const u8,
    cxx: std.Build.LazyPath,
    verifier: std.Build.LazyPath,
) void {
    for (tests) |test_name| {
        smoke.addDeadallocSmoke(
            b,
            parent,
            install.library,
            reference_build,
            test_name,
        );
    }
    smoke.addDeadallocSmokeArgs(
        b,
        parent,
        install.library,
        reference_build,
        "threadtest",
        &thread_args,
    );
    smoke.addDeadallocCxxSmoke(
        b,
        parent,
        cxx,
        install.library,
    );
    smoke.addDeadallocVerifierSmoke(
        b,
        parent,
        verifier,
        install.library,
    );
}
