const std = @import("std");
const build_api = @import("build_api");
const configuration = @import("configuration.zig");
const deps = @import("deps.zig");
const tracy_module = @import("module.zig");

const Source = struct {
    path: []const u8,
    imports_sys: bool,
};

const sources = [_]Source{
    .{ .path = "src/context.zig", .imports_sys = true },
    .{ .path = "src/fiber.zig", .imports_sys = true },
    .{ .path = "src/gpu.zig", .imports_sys = true },
    .{ .path = "src/system.zig", .imports_sys = true },
    .{ .path = "src/plot.zig", .imports_sys = true },
    .{ .path = "src/timeline.zig", .imports_sys = true },
    .{ .path = "src/flame.zig", .imports_sys = false },
    .{ .path = "src/find.zig", .imports_sys = false },
    .{ .path = "src/source.zig", .imports_sys = true },
    .{ .path = "src/message.zig", .imports_sys = true },
    .{ .path = "src/sample.zig", .imports_sys = true },
    .{ .path = "src/lock.zig", .imports_sys = true },
};

pub fn register(
    b: *std.Build,
    config: configuration.Configuration,
    dependencies: deps.Dependencies,
) void {
    const test_module = tracy_module.createTest(b, config, dependencies);
    const tracy_tests = b.addTest(.{
        .root_module = test_module,
        .filters = config.test_filters,
    });
    const run_tracy_tests = b.addRunArtifact(tracy_tests);
    const parent = b.step("test", "Run native Tracy package tests");
    parent.dependOn(&run_tracy_tests.step);
    const pretty_imports: []const std.Build.Module.Import = &.{
        .{ .name = "pretty", .module = dependencies.pretty.module("pretty") },
    };
    const pretty_sys_imports: []const std.Build.Module.Import = &.{
        .{ .name = "pretty", .module = dependencies.pretty.module("pretty") },
        .{ .name = "sys", .module = dependencies.sys.module("sys") },
    };
    const inputs = Inputs{
        .b = b,
        .parent = parent,
        .policy = config.policy,
        .filters = config.test_filters,
    };
    for (sources) |source| {
        const imports = if (source.imports_sys) pretty_sys_imports else pretty_imports;
        addSource(inputs, source.path, imports);
    }
}

const Inputs = struct {
    b: *std.Build,
    parent: *std.Build.Step,
    policy: build_api.ModuleOptions,
    filters: []const []const u8,
};

fn addSource(
    inputs: Inputs,
    path: []const u8,
    imports: []const std.Build.Module.Import,
) void {
    const module = inputs.b.createModule(inputs.policy.createOptions(inputs.b, path, imports));
    const tests = inputs.b.addTest(.{
        .root_module = module,
        .filters = inputs.filters,
    });
    inputs.parent.dependOn(&inputs.b.addRunArtifact(tests).step);
}
