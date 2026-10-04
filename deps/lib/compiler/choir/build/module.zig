const std = @import("std");
const build_api = @import("build_api");

pub const Inputs = struct {
    alloc_arena: *std.Build.Module,
    alloc_fixed: *std.Build.Module,
    alloc_observe: *std.Build.Module,
    alloc_phase: *std.Build.Module,
    gpu_abi: *std.Build.Module,
    pretty: *std.Build.Module,
    sys: *std.Build.Module,
    isa: *std.Build.Module,
    simd: *std.Build.Module,
};

pub fn createModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
) *std.Build.Module {
    return create(b, options, inputs, "src/root.zig");
}

/// The root of Choir's unit tests. A release that strips its tests ships none.
pub const test_root = "src/test.zig";

pub fn createTestModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
) *std.Build.Module {
    return create(b, options, inputs, test_root);
}

fn create(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
    root_source_file: []const u8,
) *std.Build.Module {
    const result = b.createModule(options.createOptions(
        b,
        root_source_file,
        &.{
            .{ .name = "gpu_abi", .module = inputs.gpu_abi },
            .{ .name = "alloc_arena", .module = inputs.alloc_arena },
            .{ .name = "alloc_fixed", .module = inputs.alloc_fixed },
            .{ .name = "alloc_observe", .module = inputs.alloc_observe },
            .{ .name = "alloc_phase", .module = inputs.alloc_phase },
            .{ .name = "sys", .module = inputs.sys },
            .{ .name = "isa", .module = inputs.isa },
            .{ .name = "simd", .module = inputs.simd },
            .{ .name = "pretty", .module = inputs.pretty },
            .{ .name = "timing_runner_pretty", .module = inputs.pretty },
            .{ .name = "timing_runner_sys", .module = inputs.sys },
        },
    ));
    build_api.attachCompilerManifest(b, result);
    return result;
}
