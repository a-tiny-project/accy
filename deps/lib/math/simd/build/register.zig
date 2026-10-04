const std = @import("std");
const build_api = @import("build_api");

pub fn build(b: *std.Build) void {
    const target = build_api.standardTargets(b).product;
    const optimize = b.standardOptimizeOption(.{});
    const module_options = build_api.ModuleOptions{
        .target = target,
        .optimize = optimize,
    };
    const test_filters = build_api.focusedTestFilters(b);
    const alloc_phase_dep = b.dependency("alloc_phase", .{
        .target = module_options.target,
        .optimize = module_options.optimize,
    });
    const sys_dep = b.dependency("sys", .{
        .target = module_options.target,
        .optimize = module_options.optimize,
    });
    const sys_mod = sysModule(sys_dep, module_options.target.result);

    const simd_mod = b.addModule(
        "simd",
        module_options.createOptions(b, "src/root.zig", &.{
            .{ .name = "alloc_phase", .module = alloc_phase_dep.module("alloc_phase") },
            .{ .name = "sys", .module = sys_mod },
        }),
    );
    const simd_test_mod = b.createModule(
        module_options.createOptions(b, "src/test.zig", &.{
            .{ .name = "alloc_phase", .module = alloc_phase_dep.module("alloc_phase") },
            .{ .name = "sys", .module = sys_mod },
        }),
    );
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "simd",
        .root_module = simd_mod,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_module = simd_test_mod,
        .filters = test_filters,
    });
    const run_tests = b.addRunArtifact(tests);
    const browserish_identity_check = addBrowserishIdentityCheck(b);
    const test_step = b.step("test", "Run SIMD unit and conformance tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&browserish_identity_check.step);
}

fn sysModule(
    dependency: *std.Build.Dependency,
    target: std.Target,
) *std.Build.Module {
    return dependency.module(if (target.cpu.arch.isWasm() and
        target.os.tag == .freestanding)
        "sys_no_libc"
    else
        "sys");
}

fn addBrowserishIdentityCheck(
    b: *std.Build,
) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const options = build_api.ModuleOptions{
        .target = target,
        .optimize = .safe,
    };
    const alloc_phase = b.dependency("alloc_phase", .{
        .target = target,
        .optimize = options.optimize,
    }).module("alloc_phase");
    const sys_dependency = b.dependency("sys", .{
        .target = target,
        .optimize = options.optimize,
    });
    const sys = sysModule(sys_dependency, target.result);
    const simd = b.createModule(options.createOptions(b, "src/root.zig", &.{
        .{ .name = "alloc_phase", .module = alloc_phase },
        .{ .name = "sys", .module = sys },
    }));
    const probe = b.createModule(options.createOptions(
        b,
        "src/browserish/test.zig",
        &.{
            .{ .name = "simd", .module = simd },
            .{ .name = "sys", .module = sys },
        },
    ));
    return b.addObject(.{
        .name = "simd_browserish_identity",
        .root_module = probe,
    });
}
