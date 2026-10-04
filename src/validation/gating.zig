const std = @import("std");
const sys = @import("sys");

const build_options = @import("build_options");
const gpu_gating = @import("gpu_gating");

pub const Id = enum(u8) {
    workspace,
    default,
    cuda,
    vulkan,
    gpu,
    metal,
};

pub const Surface = enum(u8) {
    workspace,
    frontend,
    choir,
    backend_contract,
    cuda,
    vulkan,
    metal,
    cross_backend,
};

pub const SkipBehavior = enum(u8) {
    never_skip,
    skip_when_flag_disabled,
    skip_when_platform_or_runtime_missing,
};

pub const Row = struct {
    id: Id,
    name: []const u8,
    command: []const u8,
    flag_text: []const u8,
    required_for_default_development: bool,
    skip_behavior: SkipBehavior,
    surfaces: []const Surface,
    workspace_gate_is_sufficient: bool,
};

const workspace_surfaces = [_]Surface{.workspace};
const default_surfaces = [_]Surface{
    .frontend,
    .choir,
    .backend_contract,
};
const cuda_surfaces = [_]Surface{ .cuda, .backend_contract };
const vulkan_surfaces = [_]Surface{ .vulkan, .backend_contract };
const gpu_surfaces = [_]Surface{ .cuda, .vulkan, .cross_backend };
const metal_surfaces = [_]Surface{ .metal, .backend_contract };

pub const rows = [_]Row{
    .{
        .id = .workspace,
        .name = "workspace",
        .command = "zig build test",
        .flag_text = "none",
        .required_for_default_development = false,
        .skip_behavior = .never_skip,
        .surfaces = workspace_surfaces[0..],
        .workspace_gate_is_sufficient = false,
    },
    .{
        .id = .default,
        .name = "default",
        .command = "zig build accy-tests",
        .flag_text = "none",
        .required_for_default_development = true,
        .skip_behavior = .never_skip,
        .surfaces = default_surfaces[0..],
        .workspace_gate_is_sufficient = true,
    },
    .{
        .id = .cuda,
        .name = "cuda",
        .command = "zig build accy-tests -Dgpu-tests=true",
        .flag_text = "-Dgpu-tests=true",
        .required_for_default_development = false,
        .skip_behavior = .skip_when_platform_or_runtime_missing,
        .surfaces = cuda_surfaces[0..],
        .workspace_gate_is_sufficient = false,
    },
    .{
        .id = .vulkan,
        .name = "vulkan",
        .command = "zig build accy-tests -Dvulkan-tests=true",
        .flag_text = "-Dvulkan-tests=true",
        .required_for_default_development = false,
        .skip_behavior = .skip_when_platform_or_runtime_missing,
        .surfaces = vulkan_surfaces[0..],
        .workspace_gate_is_sufficient = false,
    },
    .{
        .id = .gpu,
        .name = "gpu",
        .command = "zig build accy-tests -Dgpu-tests=true -Dvulkan-tests=true",
        .flag_text = "-Dgpu-tests=true -Dvulkan-tests=true",
        .required_for_default_development = false,
        .skip_behavior = .skip_when_platform_or_runtime_missing,
        .surfaces = gpu_surfaces[0..],
        .workspace_gate_is_sufficient = false,
    },
    .{
        .id = .metal,
        .name = "metal",
        .command = "zig build accy-tests -Dmetal-tests=true",
        .flag_text = "-Dmetal-tests=true",
        .required_for_default_development = false,
        .skip_behavior = .skip_when_platform_or_runtime_missing,
        .surfaces = metal_surfaces[0..],
        .workspace_gate_is_sufficient = false,
    },
};

pub fn row(id: Id) *const Row {
    for (&rows) |*entry| {
        if (entry.id == id) return entry;
    }
    unreachable;
}

pub fn enabledByBuildOptions(id: Id) bool {
    return switch (id) {
        .workspace, .default => true,
        .cuda => build_options.gpu_tests,
        .vulkan => build_options.vulkan_tests,
        .gpu => build_options.gpu_tests and build_options.vulkan_tests,
        .metal => build_options.metal_tests,
    };
}

pub fn appleMetalPlatform() bool {
    return sys.capabilities.current.supportsAppleMetal();
}

pub fn skip(id: Id, reason: gpu_gating.SkipReason) error{SkipZigTest} {
    const entry = row(id);
    std.log.scoped(.accy_validation).info(
        "skipping {s} validation row ({s}); command: {s}",
        .{ entry.name, reason.label(), entry.command },
    );
    return error.SkipZigTest;
}

pub fn skipIfBuildFlagDisabled(id: Id) error{SkipZigTest}!void {
    if (!enabledByBuildOptions(id)) return skip(id, .build_flag_disabled);
}

pub fn skipIfNotAppleMetalHost(id: Id) error{SkipZigTest}!void {
    if (!appleMetalPlatform()) return skip(id, .unsupported_platform);
}

pub fn touchesSurface(id: Id, surface: Surface) bool {
    for (row(id).surfaces) |candidate| {
        if (candidate == surface) return true;
    }
    return false;
}

test "validation gating names the required backend rows" {
    try std.testing.expectEqualStrings("zig build test", row(.workspace).command);
    try std.testing.expectEqualStrings("zig build accy-tests", row(.default).command);
    try std.testing.expectEqualStrings(
        "zig build accy-tests -Dgpu-tests=true",
        row(.cuda).command,
    );
    try std.testing.expectEqualStrings(
        "zig build accy-tests -Dvulkan-tests=true",
        row(.vulkan).command,
    );
    try std.testing.expectEqualStrings(
        "zig build accy-tests -Dgpu-tests=true -Dvulkan-tests=true",
        row(.gpu).command,
    );
    try std.testing.expectEqualStrings(
        "zig build accy-tests -Dmetal-tests=true",
        row(.metal).command,
    );
}

test "optional hardware rows are controlled by explicit build flags" {
    try std.testing.expect(enabledByBuildOptions(.workspace));
    try std.testing.expect(enabledByBuildOptions(.default));
    try std.testing.expectEqual(build_options.gpu_tests, enabledByBuildOptions(.cuda));
    try std.testing.expectEqual(build_options.vulkan_tests, enabledByBuildOptions(.vulkan));
    try std.testing.expectEqual(
        build_options.gpu_tests and build_options.vulkan_tests,
        enabledByBuildOptions(.gpu),
    );
    try std.testing.expectEqual(build_options.metal_tests, enabledByBuildOptions(.metal));
}

test "workspace gate is not a backend health signal" {
    try std.testing.expect(!row(.workspace).workspace_gate_is_sufficient);
    try std.testing.expect(!row(.cuda).workspace_gate_is_sufficient);
    try std.testing.expect(!row(.vulkan).workspace_gate_is_sufficient);
    try std.testing.expect(!row(.gpu).workspace_gate_is_sufficient);
    try std.testing.expect(!row(.metal).workspace_gate_is_sufficient);
    try std.testing.expect(touchesSurface(.default, .choir));
    try std.testing.expect(touchesSurface(.cuda, .backend_contract));
    try std.testing.expect(touchesSurface(.vulkan, .backend_contract));
    try std.testing.expect(touchesSurface(.gpu, .cross_backend));
}
