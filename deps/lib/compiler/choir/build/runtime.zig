const std = @import("std");
const build_api = @import("build_api");
const module = @import("module.zig");

pub const Configuration = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_filters: []const []const u8,
    observe_allocations: bool,
    browserish: bool,
    wasm_node_path: []const u8 = "",
    wasm_node_version: []const u8 = "",
};

pub fn configure(b: *std.Build) Configuration {
    const target = build_api.standardTargets(b).product;
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = build_api.focusedTestFilters(b);
    const node_path = b.option([]const u8, "wasm-node-path", "Qualify wasm tests with this absolute Node binary") orelse "";
    const node_version = b.option([]const u8, "wasm-node-version", "Required Node version, including its v prefix") orelse "";
    if ((node_path.len == 0) != (node_version.len == 0))
        @panic("wasm qualification needs both Node path and version");
    if (node_path.len != 0) {
        if (!std.fs.path.isAbsolute(node_path)) @panic("wasm qualification needs an absolute Node path");
        // The merged filters also carry discovery names, so judge the requested set.
        const requested = build_api.testFilters(b);
        if (requested.len != 0 and !(requested.len == 2 and
            ((std.mem.eql(u8, requested[0], "WASM") and std.mem.eql(u8, requested[1], "wasm")) or
                (std.mem.eql(u8, requested[0], "wasm") and std.mem.eql(u8, requested[1], "WASM")))))
            @panic("wasm qualification accepts only the full suite or both WASM and wasm filters");
    }
    const observe_allocations = b.option(
        bool,
        "observe-allocations",
        "Compile allocator observation into owned Choir producers",
    ) orelse false;
    return .{
        .target = target,
        .optimize = optimize,
        .test_filters = test_filters,
        .observe_allocations = observe_allocations,
        .browserish = isBrowserish(target.result),
        .wasm_node_path = node_path,
        .wasm_node_version = node_version,
    };
}

/// Returns `configuration` retargeted to the profiling policy, which never builds the browser
/// system module.
pub fn profilingConfiguration(
    configuration: Configuration,
    policy: build_api.ModuleOptions,
) Configuration {
    var result = configuration;
    result.target = policy.target;
    result.optimize = policy.optimize;
    result.browserish = false;
    return result;
}

pub fn resolveRequested(b: *std.Build, configuration: Configuration) module.Inputs {
    const node_options = b.addOptions();
    node_options.addOption([]const u8, "path", configuration.wasm_node_path);
    node_options.addOption([]const u8, "version", configuration.wasm_node_version);
    const wasm_node_options = node_options.createModule();
    // Its own module, so the qualification runners share the tests' records.
    const wasm_census = b.createModule(.{
        .root_source_file = b.path("src/backends/wasm/fixture/census.zig"),
        .imports = &.{.{ .name = "wasm_node_options", .module = wasm_node_options }},
    });
    const arena = arenaDependency(
        b,
        configuration.target,
        configuration.optimize,
        configuration.observe_allocations,
    ).module("alloc_arena");
    const alloc_observe = arena.import_table.get("alloc_observe") orelse
        @panic("arena module is missing alloc_observe");
    const fixed = fixedDependency(
        b,
        configuration.target,
        configuration.optimize,
        configuration.observe_allocations,
    ).module("alloc_fixed");
    build_api.requireImport(fixed, "alloc_observe", alloc_observe);
    const sys = b.dependency("sys", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    const pretty = b.dependency("pretty_core", .{
        .target = configuration.target,
        .optimize = configuration.optimize,
    });
    const sys_module = sys.module(if (configuration.browserish) "sys_no_libc" else "sys");
    return .{
        .wasm_node_options = wasm_node_options,
        .wasm_census = wasm_census,
        // Its own module, so dev runs the same fixture without sharing a file.
        .wasm_node = b.createModule(.{
            .root_source_file = b.path("src/backends/wasm/fixture/root.zig"),
            .imports = &.{
                .{ .name = "sys", .module = sys_module },
                .{ .name = "wasm_census", .module = wasm_census },
                .{ .name = "wasm_node_options", .module = wasm_node_options },
            },
        }),
        .alloc_arena = arena,
        .alloc_fixed = fixed,
        .alloc_observe = alloc_observe,
        .alloc_phase = b.dependency("alloc_phase", .{
            .target = configuration.target,
            .optimize = configuration.optimize,
        }).module("alloc_phase"),
        .gpu_abi = b.dependency("gpu_abi", .{
            .target = configuration.target,
            .optimize = configuration.optimize,
        }).module("gpu_abi"),
        .pretty = pretty.module("pretty"),
        .isa = b.dependency("isa", .{
            .target = configuration.target,
            .optimize = configuration.optimize,
        }).module("isa"),
        .simd = b.dependency("simd", .{
            .target = configuration.target,
            .optimize = configuration.optimize,
        }).module("simd"),
        .sys = sys_module,
    };
}

fn arenaDependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    observe_allocations: bool,
) *std.Build.Dependency {
    if (!observe_allocations) {
        return b.dependency("alloc_arena", .{
            .target = target,
            .optimize = optimize,
        });
    }
    return b.dependency("alloc_arena", .{
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

fn isBrowserish(target: std.Target) bool {
    return target.cpu.arch.isWasm() and target.os.tag == .freestanding;
}
