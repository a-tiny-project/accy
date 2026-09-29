const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const expected_native = b.option(
        bool,
        "expected-native",
        "Whether the dependency target must retain native provenance",
    ) orelse false;
    const expected_native_cpu = b.option(
        bool,
        "expected-native-cpu",
        "Whether the dependency target must retain native CPU provenance",
    ) orelse expected_native;
    if (target.query.isNative() != expected_native) {
        @panic("dependency target native provenance changed");
    }
    if (target.query.isNativeCpu() != expected_native_cpu) {
        @panic("dependency target native CPU provenance changed");
    }
    const check = b.step("check", "Validate dependency target option transport");

    const expected_dynamic_linker = b.option(
        []const u8,
        "expected-dynamic-linker",
        "Expected dependency target dynamic linker",
    );
    const expected_ofmt = b.option(
        std.Target.ObjectFormat,
        "expected-ofmt",
        "Expected dependency target object format",
    );
    if (expected_dynamic_linker == null and expected_ofmt == null) return;
    const required_dynamic_linker = expected_dynamic_linker orelse
        @panic("expected-dynamic-linker is required");
    const required_ofmt = expected_ofmt orelse
        @panic("expected-ofmt is required");
    const actual_dynamic_linker = target.query.dynamic_linker orelse
        @panic("dependency target lost dynamic-linker");
    const actual_dynamic_linker_path = actual_dynamic_linker.get() orelse "";
    const actual_ofmt = target.query.ofmt orelse
        @panic("dependency target lost object format");
    const options = b.addOptions();
    options.addOption([]const u8, "expected_dynamic_linker", required_dynamic_linker);
    options.addOption([]const u8, "actual_dynamic_linker", actual_dynamic_linker_path);
    options.addOption(std.Target.ObjectFormat, "expected_ofmt", required_ofmt);
    options.addOption(std.Target.ObjectFormat, "actual_ofmt", actual_ofmt);
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test.zig"),
            .target = b.graph.host,
            .optimize = .debug,
            .imports = &.{.{
                .name = "transport_options",
                .module = options.createModule(),
            }},
        }),
    });
    check.dependOn(&b.addRunArtifact(tests).step);
}
