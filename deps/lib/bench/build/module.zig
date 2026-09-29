const std = @import("std");
const build_api = @import("build_api");

pub const Inputs = struct {
    alloc_phase: *std.Build.Module,
    bootstrap: *std.Build.Module,
    coz: *std.Build.Module,
    memtrace: *std.Build.Module,
    pretty: *std.Build.Module,
    stabilizer: *std.Build.Module,
    sys: *std.Build.Module,
    tracy: *std.Build.Module,
};

/// Publication name of the module holding the performance floor model (the
/// floor leaf). Every bench module built here imports the floor leaf under this
/// name. The bench package registers the floor leaf under the same name, so a
/// build file can ask for the floor model on its own. The floor leaf is created
/// with an empty import list, so it reaches the Zig standard library and
/// nothing else. A program that imports the floor leaf to price its own work,
/// for example the recorder tests under press/web/sympathy, is a measurement
/// binary. Such a binary can therefore depend on the floor model alone, leaving
/// aside the eight packages a bench module imports: alloc_phase, bench_bootstrap,
/// coz, memtrace, pretty, stabilizer, sys, and tracy.
pub const floor_name = "bench_floor";

pub fn createModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
) *std.Build.Module {
    return createModuleAt(b, options, inputs, "src/root.zig");
}

pub fn createTestModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
) *std.Build.Module {
    return createModuleAt(b, options, inputs, "src/test.zig");
}

fn createModuleAt(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
    source_root: []const u8,
) *std.Build.Module {
    const floor = b.createModule(options.createOptions(b, "src/floor/root.zig", &.{}));
    return b.createModule(options.createOptions(b, source_root, &.{
        .{ .name = "alloc_phase", .module = inputs.alloc_phase },
        .{ .name = "bench_bootstrap", .module = inputs.bootstrap },
        .{ .name = floor_name, .module = floor },
        .{ .name = "coz", .module = inputs.coz },
        .{ .name = "memtrace", .module = inputs.memtrace },
        .{ .name = "pretty", .module = inputs.pretty },
        .{ .name = "stabilizer", .module = inputs.stabilizer },
        .{ .name = "sys", .module = inputs.sys },
        .{ .name = "tracy", .module = inputs.tracy },
    }));
}
