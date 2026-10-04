const std = @import("std");
const build_api = @import("build_api");
const dependency_owner = @import("dependency.zig");
const gpu_build = @import("gpu");
const sys_build = @import("sys");

const AccyModuleOptions = struct {
    expose: ?[]const u8 = null,
    root_source_file: []const u8 = "src/root.zig",
    module_options: build_api.ModuleOptions,
    observe_allocations: bool,
    build_options: *std.Build.Module,
    gating: *std.Build.Module,
    choir: *std.Build.Module,
    gpu: *std.Build.Module,
    pretty: *std.Build.Module,
    sys: *std.Build.Module,
};

fn addAccyModule(b: *std.Build, options: AccyModuleOptions) *std.Build.Module {
    const arena = options.choir.import_table.get("alloc_arena") orelse
        @panic("choir module is missing alloc_arena");
    const alloc_phase = options.choir.import_table.get("alloc_phase") orelse
        @panic("choir module is missing alloc_phase");
    const alloc_observe = options.choir.import_table.get("alloc_observe") orelse
        @panic("choir module is missing alloc_observe");
    build_api.requireImport(arena, "alloc_observe", alloc_observe);
    const fixed = fixedDependency(
        b,
        options.module_options.target,
        options.module_options.optimize,
        options.observe_allocations,
    ).module("alloc_fixed");
    build_api.requireImport(fixed, "alloc_observe", alloc_observe);
    const discovery = b.createModule(options.module_options.createOptions(
        b,
        "src/fixture/discovery.zig",
        &.{},
    ));
    const module_options = options.module_options.createOptions(b, options.root_source_file, &.{
        .{ .name = "test_discovery", .module = discovery },
        .{ .name = "alloc_arena", .module = arena },
        .{ .name = "alloc_fixed", .module = fixed },
        .{ .name = "alloc_phase", .module = alloc_phase },
        .{ .name = "build_options", .module = options.build_options },
        .{ .name = "accy_validation_gating", .module = options.gating },
        .{ .name = "choir", .module = options.choir },
        .{ .name = "gpu_abi", .module = options.choir.import_table.get("gpu_abi").? },
        .{ .name = "gpu", .module = options.gpu },
        .{ .name = "pretty", .module = options.pretty },
        .{ .name = "sys", .module = options.sys },
        .{ .name = "timing_runner_pretty", .module = options.pretty },
        .{ .name = "timing_runner_sys", .module = options.sys },
    });
    return if (options.expose) |name|
        b.addModule(name, module_options)
    else
        b.createModule(module_options);
}

/// The root of Accy's unit tests. A release that strips its tests ships none.
const test_root = "src/test.zig";

/// The Accy product graph: the `accy` module and the unit, gating, PTX
/// validation and integration tests behind `test`. Examples, property tests,
/// benchmarks, the browser Wasm module, AOT registries and live device steps
/// belong to lib/compiler/accy/dev.
pub fn build(b: *std.Build) void {
    const targets = build_api.standardTargets(b);
    const target = targets.product;
    const optimize = b.standardOptimizeOption(.{});
    const module_options = build_api.ModuleOptions{
        .target = target,
        .optimize = optimize,
    };
    const test_filters = build_api.focusedTestFilters(b);
    const dependency_options = dependency_owner.dependencyOptions(b);
    const browserish = target.result.cpu.arch.isWasm() and target.result.os.tag == .freestanding;

    const accy_build_options = b.addOptions();
    accy_build_options.addOption(bool, "gpu_tests", dependency_options.gpu_tests);
    accy_build_options.addOption(bool, "vulkan_tests", dependency_options.vulkan_tests);
    accy_build_options.addOption(bool, "metal_tests", dependency_options.metal_tests);
    const accy_build_options_mod = accy_build_options.createModule();

    const choir_mod = choirDependency(
        b,
        target,
        optimize,
        dependency_options.observe_allocations,
    ).module("choir");
    const gpu_mod = gpuDependency(b, target, optimize, dependency_options).module("gpu");
    const sys_dep = b.dependency("sys", .{
        .target = target,
        .optimize = optimize,
    });
    const sys_mod = if (browserish) sys_dep.module("sys_no_libc") else sys_dep.module("sys");
    const pretty_mod = b.dependency("pretty_core", .{
        .target = target,
        .optimize = optimize,
    }).module("pretty");

    const accy_validation_gating_mod = b.createModule(
        module_options.createOptions(b, "src/validation/gating.zig", &.{
            .{ .name = "build_options", .module = accy_build_options_mod },
            .{ .name = "gpu_gating", .module = gpu_mod.import_table.get("gpu_gating").? },
            .{ .name = "sys", .module = sys_mod },
        }),
    );

    const accy_options = AccyModuleOptions{
        .module_options = module_options,
        .observe_allocations = dependency_options.observe_allocations,
        .build_options = accy_build_options_mod,
        .gating = accy_validation_gating_mod,
        .choir = choir_mod,
        .gpu = gpu_mod,
        .pretty = pretty_mod,
        .sys = sys_mod,
    };
    var exposed_options = accy_options;
    exposed_options.expose = "accy";
    const accy_mod = addAccyModule(b, exposed_options);
    if (browserish) return;
    // A release that strips its tests ships none of the roots below: the test
    // roots, and the device evidence module that only monorepo tools import.
    // The configuration depends on the test root's directory entries, which a
    // missing root leaves trackable.
    b.dependOnDirectoryContents(b.path(std.fs.path.dirname(test_root).?));
    b.root.access(b.graph.io, test_root, .{}) catch return;

    var accy_test_options = accy_options;
    accy_test_options.root_source_file = test_root;
    const accy_test_mod = addAccyModule(b, accy_test_options);
    build_api.registerModule(b, "accy-tests", accy_test_mod);
    const accy_tests = b.addTest(.{
        .root_module = accy_test_mod,
        .filters = test_filters,
        .max_rss = testCompileRss(unit_test_compile, optimize),
    });
    const accy_validation_gating_tests = b.addTest(.{
        .root_module = accy_validation_gating_mod,
        .filters = test_filters,
        .max_rss = testCompileRss(gating_test_compile, optimize),
    });

    const accy_validation_ptx_mod = b.createModule(
        module_options.createOptions(b, "src/validation/ptx/root.zig", &.{
            .{ .name = "accy", .module = accy_mod },
            .{ .name = "gpu", .module = gpu_mod },
            .{ .name = "pretty", .module = pretty_mod },
            .{ .name = "sys", .module = sys_mod },
        }),
    );
    const accy_validation_ptx_test_mod = b.createModule(
        module_options.createOptions(b, "src/validation/ptx/test.zig", &.{
            .{ .name = "accy", .module = accy_mod },
            .{ .name = "gpu", .module = gpu_mod },
            .{ .name = "pretty", .module = pretty_mod },
            .{ .name = "sys", .module = sys_mod },
        }),
    );
    const accy_validation_ptx_tests = b.addTest(.{
        .root_module = accy_validation_ptx_test_mod,
        .filters = test_filters,
        .max_rss = testCompileRss(ptx_test_compile, optimize),
    });

    const accy_integration_tests_mod = b.addModule(
        "accy-integration-tests",
        module_options.createOptions(b, "src/validation/test.zig", &.{
            .{ .name = "test_discovery", .module = accy_mod.import_table.get("test_discovery").? },
            .{ .name = "accy", .module = accy_mod },
            .{ .name = "gpu", .module = gpu_mod },
            .{ .name = "accy_validation_gating", .module = accy_validation_gating_mod },
            .{ .name = "accy_validation_ptx", .module = accy_validation_ptx_mod },
            .{ .name = "build_options", .module = accy_build_options_mod },
            .{ .name = "pretty", .module = pretty_mod },
            .{ .name = "choir", .module = choir_mod },
            .{ .name = "gpu_abi", .module = choir_mod.import_table.get("gpu_abi").? },
            .{ .name = "sys", .module = sys_mod },
            .{ .name = "timing_runner_pretty", .module = pretty_mod },
            .{ .name = "timing_runner_sys", .module = sys_mod },
        }),
    );
    const accy_integration_tests = b.addTest(.{
        .root_module = accy_integration_tests_mod,
        .filters = test_filters,
        .max_rss = testCompileRss(integration_test_compile, optimize),
    });


    const test_step = b.step("test", "Run accy unit and integration tests");
    for ([_]*std.Build.Step.Compile{
        accy_tests,
        accy_validation_gating_tests,
        accy_validation_ptx_tests,
        accy_integration_tests,
    }) |artifact| {
        test_step.dependOn(&b.addRunArtifact(artifact).step);
    }
    const operational_no_libc_step = sys_build.addNoLibcNeededCheck(b, .{
        .target = target,
        .step_name = "no-libc-needed",
        .description = "Check the Accy native test witness does not require libc",
        .label = "accy-no-libc-needed",
        .artifacts = &.{accy_tests},
        .strict_undefined = .all,
    });
    const test_no_libc_validation_step = sys_build.addNoLibcNeededCheck(b, .{
        .target = target,
        .step_name = "test-no-libc-validate",
        .description = "Validate the remaining Accy native test artifacts do not require libc",
        .label = "accy-test-no-libc-validate",
        .artifacts = &.{
            accy_validation_gating_tests,
            accy_validation_ptx_tests,
            accy_integration_tests,
        },
        .strict_undefined = .all,
    });
    if (operational_no_libc_step) |operational_check| {
        const validate_step = b.step(
            "no-libc-validate",
            "Validate Accy native tests do not require libc",
        );
        validate_step.dependOn(operational_check);
        if (test_no_libc_validation_step) |test_check| {
            validate_step.dependOn(test_check);
        }
        test_step.dependOn(validate_step);
    }
    claimTestMemory(b);
}

fn claimTestMemory(b: *std.Build) void {
    const policy = build_api.TestResourcePolicy.init(
        b,
        .auto,
        build_api.defaultTestResourceSlots(b),
        build_api.defaultChildBuildJobs(),
    );
    build_api.applyTestGraphResourcePolicy(policy, b);
}

/// A test compile's memory claim in MiB for each optimize mode: 1.5 times the
/// peak RSS Zig 0.17.0 reached compiling its root on x86_64-linux, rounded up
/// to 128 MiB. Outside a lane the test policy grants a compile the host's
/// memory over its slots, which on a many-core host falls below the release
/// peaks. The policy keeps the larger of its grant and the claim.
///
/// Peaks in MiB   Debug  ReleaseSafe  ReleaseFast  ReleaseSmall
/// unit             797         3823         4440          1228
/// gating           163          305          301           167
/// ptx              380         1025         1135           485
/// integration      533         1910         2107           758
const TestCompileClaim = std.enums.EnumArray(std.builtin.OptimizeMode, u64);

fn testCompileRss(claim: TestCompileClaim, optimize: std.builtin.OptimizeMode) u64 {
    return claim.get(optimize) * 1024 * 1024;
}

const unit_test_compile: TestCompileClaim = .init(.{
    .debug = 1280,
    .safe = 5760,
    .fast = 6784,
    .small = 1920,
});
const gating_test_compile: TestCompileClaim = .init(.{
    .debug = 256,
    .safe = 512,
    .fast = 512,
    .small = 256,
});
const ptx_test_compile: TestCompileClaim = .init(.{
    .debug = 640,
    .safe = 1664,
    .fast = 1792,
    .small = 768,
});
const integration_test_compile: TestCompileClaim = .init(.{
    .debug = 896,
    .safe = 2944,
    .fast = 3200,
    .small = 1152,
});

fn gpuDependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: dependency_owner.DependencyOptions,
) *std.Build.Dependency {
    return gpu_build.dependency(b, target, optimize, .{
        .gpu_tests = options.gpu_tests,
        .vulkan_tests = options.vulkan_tests,
        .metal_tests = options.metal_tests,
        .alloc = options.alloc,
        .observe_allocations = options.observe_allocations,
    });
}

fn choirDependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    observe_allocations: bool,
) *std.Build.Dependency {
    if (!observe_allocations) {
        return b.dependency("choir", .{
            .target = target,
            .optimize = optimize,
        });
    }
    return b.dependency("choir", .{
        .target = target,
        .optimize = optimize,
        .@"observe-allocations" = true,
    });
}

fn fixedDependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    observe_allocations: bool,
) *std.Build.Dependency {
    if (!observe_allocations) {
        return b.dependency("alloc_fixed", .{
            .target = target,
            .optimize = optimize,
        });
    }
    return b.dependency("alloc_fixed", .{
        .target = target,
        .optimize = optimize,
        .@"observe-allocations" = true,
    });
}
