const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const product = @import("product.zig");

pub fn add(
    b: *std.Build,
    configuration: deps.Configuration,
    dependencies: deps.Requested,
    tldr: product.Product,
) void {
    const tldr_tests = b.addTest(.{
        .root_module = tldr.tests,
        .filters = configuration.test_filters,
    });
    const run_tldr_tests = b.addRunArtifact(tldr_tests);
    const cli_tests = b.addTest(.{
        .root_module = tldr.cli,
        .filters = configuration.test_filters,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const checker_options = build_api.ModuleOptions{
        .target = configuration.targets.host,
        .optimize = configuration.optimize,
    };
    const checker_dependencies = if (configuration.targets.rolesCoincide())
        dependencies
    else
        deps.resolveRole(
            b,
            configuration,
            checker_options.target,
            checker_options.optimize,
        );
    const checker_tldr = if (configuration.targets.rolesCoincide())
        tldr.tldr
    else
        product.createModule(b, checker_options, checker_dependencies);
    const macho_object_check = addMachoObjectCheck(
        b,
        checker_options,
        checker_dependencies.sys,
        checker_tldr,
    );

    const test_step = b.step("test", "Run TLDR linker tests");
    test_step.dependOn(&run_tldr_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(macho_object_check);

    const macho_object_step = b.step("macho-object-check", "Check a compiler-produced arm64 Mach-O object");
    macho_object_step.dependOn(macho_object_check);
}

fn addMachoObjectCheck(
    b: *std.Build,
    checker_options: build_api.ModuleOptions,
    sys: *std.Build.Module,
    tldr: *std.Build.Module,
) *std.Build.Step {
    const arm_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    });
    const probe_options = build_api.ModuleOptions{
        .target = arm_target,
        .optimize = .fast,
        .strip = true,
    };
    const probe_module = b.createModule(probe_options.createOptions(
        b,
        "src/probe/macho/object.zig",
        &.{},
    ));
    const probe = b.addObject(.{
        .name = "tldr_macho_arm64_object",
        .root_module = probe_module,
        .use_llvm = true,
    });

    const checker_module = b.createModule(checker_options.createOptions(
        b,
        "src/probe/macho/check.zig",
        &.{
            .{ .name = "sys", .module = sys },
            .{ .name = "tldr", .module = tldr },
        },
    ));
    const checker = b.addExecutable(.{
        .name = "tldr_macho_object_check",
        .root_module = checker_module,
    });
    const run_checker = b.addRunArtifact(checker);
    run_checker.addArtifactArg(probe);
    return &run_checker.step;
}
