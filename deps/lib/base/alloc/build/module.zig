const std = @import("std");
const build_api = @import("build_api");
const model = @import("model.zig");

pub fn createModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: model.Inputs,
) *std.Build.Module {
    return createModuleAt(b, options, inputs, "src/root.zig");
}

pub fn createTestModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: model.Inputs,
) *std.Build.Module {
    return createModuleAt(b, options, inputs, "src/test.zig");
}

pub fn createLockedModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    sys: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(options.createOptions(
        b,
        "src/locked/root.zig",
        &.{.{ .name = "sys", .module = sys }},
    ));
}

pub fn createTimedTestModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: model.Inputs,
    pretty: *std.Build.Module,
    sys: *std.Build.Module,
) *std.Build.Module {
    const imports = moduleImports(
        inputs,
        allocLocked(b, options, inputs),
        allocLimit(b, options, inputs),
    ) ++ [_]std.Build.Module.Import{
        .{ .name = "timing_runner_pretty", .module = pretty },
        .{ .name = "timing_runner_sys", .module = sys },
    };
    return b.createModule(options.createOptions(
        b,
        "src/test.zig",
        &imports,
    ));
}

fn createModuleAt(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: model.Inputs,
    source_root: []const u8,
) *std.Build.Module {
    const imports = moduleImports(
        inputs,
        allocLocked(b, options, inputs),
        allocLimit(b, options, inputs),
    );
    return b.createModule(options.createOptions(b, source_root, &imports));
}

fn allocLocked(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: model.Inputs,
) *std.Build.Module {
    return inputs.alloc_locked orelse createLockedModule(
        b,
        options,
        inputs.sys,
    );
}

fn allocLimit(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: model.Inputs,
) *std.Build.Module {
    return inputs.alloc_limit orelse b.createModule(options.createOptions(
        b,
        "src/limit/root.zig",
        &.{.{ .name = "sys", .module = inputs.sys }},
    ));
}

fn moduleImports(
    inputs: model.Inputs,
    alloc_locked: *std.Build.Module,
    alloc_limit: *std.Build.Module,
) [7]std.Build.Module.Import {
    return .{
        .{ .name = "alloc_locked", .module = alloc_locked },
        .{ .name = "alloc_limit", .module = alloc_limit },
        .{ .name = "alloc_phase", .module = inputs.alloc_phase },
        .{ .name = "build_options", .module = inputs.build_options },
        .{ .name = "deadalloc", .module = inputs.deadalloc },
        .{ .name = "gpalloc", .module = inputs.gpalloc },
        .{ .name = "sys", .module = inputs.sys },
    };
}
