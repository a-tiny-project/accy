const std = @import("std");
const build_api = @import("build_api");

pub fn registered(
    b: *std.Build,
    options: build_api.ModuleOptions,
) *std.Build.Module {
    return b.addModule("isa", options.createOptions(b, "src/root.zig", &.{}));
}

pub fn tests(
    b: *std.Build,
    options: build_api.ModuleOptions,
) *std.Build.Module {
    return b.createModule(options.createOptions(b, "src/test.zig", &.{}));
}
