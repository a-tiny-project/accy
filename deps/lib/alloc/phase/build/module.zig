const std = @import("std");
const build_api = @import("build_api");

const stardust_observer = "src/observer/stardust.zig";
const silent_observer = "src/observer/silent.zig";

pub fn capacityRegistered(
    b: *std.Build,
    policy: build_api.ModuleOptions,
) *std.Build.Module {
    const module = b.addModule(
        "capacity",
        policy.createOptions(b, "src/capacity/root.zig", &.{}),
    );
    module.addImport("capacity", module);
    module.addImport("observer", observer(b, policy));
    return module;
}

/// `observer` selects the Stardust observer root when its source is present
/// and the silent root otherwise. The package manifest omits the Stardust
/// root from `.paths`, so released sources never name `@stardustClaim`.
/// The probe and selected module use the same source root. The directory
/// dependency reruns configuration when the file appears or goes.
pub fn observer(
    b: *std.Build,
    policy: build_api.ModuleOptions,
) *std.Build.Module {
    b.dependOnDirectory(build_api.sourcePath(b, policy.source_root, "src/observer"));
    const probe = build_api.sourceRelativePath(b, policy.source_root, stardust_observer);
    const root = if (b.root.access(b.graph.io, probe, .{})) |_|
        stardust_observer
    else |err| switch (err) {
        error.FileNotFound => silent_observer,
        else => std.debug.panic("alloc_phase observer probe: {t}", .{err}),
    };
    return b.createModule(policy.createOptions(b, root, &.{}));
}

pub fn registered(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    capacity: *std.Build.Module,
) *std.Build.Module {
    return b.addModule("alloc_phase", policy.createOptions(
        b,
        "src/root.zig",
        &.{.{ .name = "capacity", .module = capacity }},
    ));
}

pub fn testModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    capacity: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(options.createOptions(
        b,
        "src/test.zig",
        &.{.{ .name = "capacity", .module = capacity }},
    ));
}

pub fn capacityTestModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
) *std.Build.Module {
    return b.createModule(options.createOptions(b, "src/capacity/unit.zig", &.{
        .{ .name = "observer", .module = observer(b, options) },
    }));
}

/// `capacity_metadata` is the typed capacity fixture that its tests and the
/// Stardust metadata fixtures compile.
pub fn metadataRegistered(
    b: *std.Build,
    options: build_api.ModuleOptions,
    capacity: *std.Build.Module,
) *std.Build.Module {
    return b.addModule("capacity_metadata", options.createOptions(
        b,
        "src/capacity/metadata.zig",
        &.{.{ .name = "capacity", .module = capacity }},
    ));
}

pub fn nativeCapacity(
    b: *std.Build,
    options: build_api.ModuleOptions,
) *std.Build.Module {
    var native_options = options;
    native_options.target = b.graph.host;
    const module = b.createModule(native_options.createOptions(
        b,
        "src/capacity/root.zig",
        &.{.{ .name = "observer", .module = observer(b, native_options) }},
    ));
    module.addImport("capacity", module);
    return module;
}
