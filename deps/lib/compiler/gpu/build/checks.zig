const std = @import("std");
const build_api = @import("build_api");
const boundary = @import("boundary.zig");
const public = @import("public.zig");
const sys_build = @import("sys");

/// The checks every gpu archive runs: the contract, runtime and device tests
/// over src/test.zig, the gating tests, the no-libc witness, and the Metal
/// runtime compiled for both macOS architectures. It reaches only the files
/// an export ships; package.zig adds the monorepo's live tests on top.
pub const Checks = struct {
    test_module: *std.Build.Module,
    test_step: *std.Build.Step,
};

pub fn build(b: *std.Build) void {
    const graph = public.add(b);
    if (!graph.native) return;
    _ = add(b, graph);
}

pub fn add(b: *std.Build, graph: public.Graph) Checks {
    std.debug.assert(graph.native);
    const test_filters = build_api.focusedTestFilters(b);

    const test_mod = public.addGpuModule(b, graph.module_options, null, .{
        .root_source_file = "src/test.zig",
        .options = graph.options,
        .native = true,
        .imports = graph.imports,
    });
    boundary.requireRuntimeBoundary(b, test_mod);
    const tests = b.addTest(.{
        .root_module = test_mod,
        .filters = test_filters,
    });
    const gating_tests = b.addTest(.{
        .root_module = graph.imports.gating,
        .filters = test_filters,
    });
    const apple_metal_semantic_check = addAppleMetalSemanticCheck(b);

    const test_step = b.step("test", "Run lib/compiler/gpu contract, runtime and device tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(gating_tests).step);
    test_step.dependOn(apple_metal_semantic_check);

    const no_libc_step = sys_build.addNoLibcNeededCheck(b, .{
        .target = graph.module_options.target,
        .step_name = "no-libc-needed",
        .description = "Check the lib/compiler/gpu test witness does not require libc",
        .label = "gpu-no-libc-needed",
        .artifacts = &.{ tests, gating_tests },
        .strict_undefined = .all,
    });
    if (no_libc_step) |check| test_step.dependOn(check);

    const apple_metal_semantic_step = b.step(
        "apple-metal-semantic-check",
        "Compile the lib/compiler/gpu Metal runtime for both macOS architectures",
    );
    apple_metal_semantic_step.dependOn(apple_metal_semantic_check);

    return .{ .test_module = test_mod, .test_step = test_step };
}

fn addAppleMetalSemanticCheck(b: *std.Build) *std.Build.Step {
    const step = b.step(
        "apple-metal-semantic-objects",
        "Build the lib/compiler/gpu Metal runtime objects for macOS",
    );
    for ([_]std.Target.Cpu.Arch{ .aarch64, .x86_64 }) |arch| {
        step.dependOn(&addAppleMetalSemanticProbe(b, arch).step);
    }
    return step;
}

fn addAppleMetalSemanticProbe(
    b: *std.Build,
    arch: std.Target.Cpu.Arch,
) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = arch,
        .os_tag = .macos,
    });
    const module_options = build_api.ModuleOptions{
        .target = target,
        .optimize = .fast,
    };
    const sys_mod = b.dependency("sys", .{
        .target = target,
        .optimize = .fast,
    }).module("sys_semantic");
    const build_options = b.addOptions();
    build_options.addOption(bool, "gpu_tests", false);
    build_options.addOption(bool, "vulkan_tests", false);
    build_options.addOption(bool, "metal_tests", false);
    build_options.addOption(bool, "native_backend_modules", true);
    const gating = b.createModule(module_options.createOptions(b, "src/gating.zig", &.{
        .{ .name = "build_options", .module = build_options.createModule() },
        .{ .name = "sys", .module = sys_mod },
    }));
    const runtime = b.createModule(module_options.createOptions(b, "src/runtime/metal/runtime/root.zig", &.{
        .{ .name = "gpu_gating", .module = gating },
        .{ .name = "sys", .module = sys_mod },
    }));
    const probe = b.createModule((build_api.ModuleOptions{
        .target = target,
        .optimize = .fast,
        .strip = true,
    }).createOptions(b, "src/runtime/metal/probe.zig", &.{
        .{ .name = "gpu_metal_runtime", .module = runtime },
    }));
    return b.addObject(.{
        .name = b.fmt("gpu_metal_semantic_{s}", .{@tagName(arch)}),
        .root_module = probe,
        .use_llvm = true,
    });
}
