const std = @import("std");
const build_api = @import("build_api");
const sys_build = @import("sys");

pub const Inputs = struct {
    sys: *std.Build.Module,
};

pub const TimedInputs = struct {
    pretty: *std.Build.Module,
    sys: *std.Build.Module,
};

pub fn createModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
) *std.Build.Module {
    return createRootModule(b, options, inputs, "src/root.zig");
}

pub fn createTestModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
) *std.Build.Module {
    return createRootModule(b, options, inputs, "src/test.zig");
}

pub fn createTimedModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: TimedInputs,
) *std.Build.Module {
    const result = b.createModule(options.createOptions(b, "src/root.zig", &.{
        .{ .name = "sys", .module = inputs.sys },
        .{ .name = "timing_runner_pretty", .module = inputs.pretty },
        .{ .name = "timing_runner_sys", .module = inputs.sys },
    }));
    sys_build.addThreadLocalPointer(b, result, .{
        .name = "gpalloc_thread_cache_slot",
    });
    return result;
}

fn createRootModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
    root_source_file: []const u8,
) *std.Build.Module {
    const result = b.createModule(options.createOptions(b, root_source_file, &.{
        .{ .name = "sys", .module = inputs.sys },
    }));
    sys_build.addThreadLocalPointer(b, result, .{
        .name = "gpalloc_thread_cache_slot",
    });
    return result;
}
