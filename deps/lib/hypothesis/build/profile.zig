const std = @import("std");
const build_api = @import("build_api");

pub const Inputs = struct {
    bench: *std.Build.Module,
    hypothesis: *std.Build.Module,
};

pub fn createModule(
    b: *std.Build,
    options: build_api.ModuleOptions,
    inputs: Inputs,
) *std.Build.Module {
    return b.createModule(options.createOptions(b, "src/profiling/test.zig", &.{
        .{ .name = "bench", .module = inputs.bench },
        .{ .name = "hypothesis", .module = inputs.hypothesis },
    }));
}
