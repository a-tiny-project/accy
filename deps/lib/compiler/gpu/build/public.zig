const std = @import("std");
const build_api = @import("build_api");
const boundary = @import("boundary.zig");
const dependency_owner = @import("dependency.zig");
const sys_build = @import("sys");
const tldr_build = @import("tldr");

pub const Imports = struct {
    build_options: *std.Build.Module,
    gating: *std.Build.Module,
    gpu_abi: *std.Build.Module,
    pretty: *std.Build.Module,
    sys: *std.Build.Module,
};

pub const ModuleInputs = struct {
    root_source_file: []const u8,
    options: dependency_owner.DependencyOptions,
    native: bool,
    imports: Imports,
};

/// The released gpu product graph. It takes the kernel interface from the
/// nested `gpu_abi` package and resolves no Choir dependency. checks.zig
/// adds the tests every archive runs; development witnesses live in gpu/dev.
pub const Graph = struct {
    module_options: build_api.ModuleOptions,
    options: dependency_owner.DependencyOptions,
    native: bool,
    imports: Imports,
    gpu: *std.Build.Module,
};

pub fn addGpuModule(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    expose: ?[]const u8,
    inputs: ModuleInputs,
) *std.Build.Module {
    const module_options = policy.createOptions(b, inputs.root_source_file, &.{
        .{ .name = "build_options", .module = inputs.imports.build_options },
        .{ .name = "gpu_gating", .module = inputs.imports.gating },
        .{ .name = "gpu_abi", .module = inputs.imports.gpu_abi },
        .{ .name = "pretty", .module = inputs.imports.pretty },
        .{ .name = "sys", .module = inputs.imports.sys },
    });
    const module = if (expose) |name|
        b.addModule(name, module_options)
    else
        b.createModule(module_options);
    if (inputs.native) {
        const target = policy.target;
        const tldr = tldr_build.dependencyWithAllocationObservation(
            b,
            target,
            policy.optimize,
            inputs.options.alloc,
            inputs.options.observe_allocations,
        );
        module.addImport("tldr", tldr.module("tldr"));
        sys_build.linkAppleMetal(module, target.result);
    }
    return module;
}

pub fn add(b: *std.Build) Graph {
    const targets = build_api.standardTargets(b);
    const target = targets.product;
    const optimize = b.standardOptimizeOption(.{});
    const module_options = build_api.ModuleOptions{
        .target = target,
        .optimize = optimize,
    };
    const options = dependency_owner.dependencyOptions(b);
    const browserish = target.result.cpu.arch.isWasm() and target.result.os.tag == .freestanding;

    const build_options = b.addOptions();
    build_options.addOption(bool, "gpu_tests", options.gpu_tests);
    build_options.addOption(bool, "vulkan_tests", options.vulkan_tests);
    build_options.addOption(bool, "metal_tests", options.metal_tests);
    build_options.addOption(bool, "native_backend_modules", !browserish);
    const build_options_mod = build_options.createModule();

    const sys_dep = b.dependency("sys", .{
        .target = target,
        .optimize = optimize,
    });
    const sys_mod = if (browserish) sys_dep.module("sys_no_libc") else sys_dep.module("sys");
    const gating_mod = b.addModule("gpu_gating", module_options.createOptions(b, "src/gating.zig", &.{
        .{ .name = "build_options", .module = build_options_mod },
        .{ .name = "sys", .module = sys_mod },
    }));
    const imports = Imports{
        .build_options = build_options_mod,
        .gating = gating_mod,
        .gpu_abi = b.dependency("gpu_abi", .{
            .target = target,
            .optimize = optimize,
        }).module("gpu_abi"),
        .pretty = b.dependency("pretty_core", .{
            .target = target,
            .optimize = optimize,
        }).module("pretty"),
        .sys = sys_mod,
    };
    const gpu_mod = addGpuModule(b, module_options, "gpu", .{
        .root_source_file = "src/root.zig",
        .options = options,
        .native = !browserish,
        .imports = imports,
    });
    boundary.requireRuntimeBoundary(b, gpu_mod);
    return .{
        .module_options = module_options,
        .options = options,
        .native = !browserish,
        .imports = imports,
        .gpu = gpu_mod,
    };
}

pub fn build(b: *std.Build) void {
    _ = add(b);
}
