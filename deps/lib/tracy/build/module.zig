const std = @import("std");
const configuration = @import("configuration.zig");
const deps = @import("deps.zig");

pub fn create(
    b: *std.Build,
    config: configuration.Configuration,
    dependencies: deps.Dependencies,
) *std.Build.Module {
    return createAt(b, config, dependencies, "src/root.zig", true);
}

pub fn createTest(
    b: *std.Build,
    config: configuration.Configuration,
    dependencies: deps.Dependencies,
) *std.Build.Module {
    return createAt(b, config, dependencies, "src/test.zig", false);
}

fn createAt(
    b: *std.Build,
    config: configuration.Configuration,
    dependencies: deps.Dependencies,
    source: []const u8,
    registered: bool,
) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "enabled", config.enabled);
    const create_options = config.policy.createOptions(b, source, &.{
        .{ .name = "build_options", .module = options.createModule() },
        .{ .name = "pretty", .module = dependencies.pretty.module("pretty") },
        .{ .name = "pretty_usage", .module = dependencies.pretty.module("pretty_usage") },
        .{ .name = "sys", .module = dependencies.sys.module("sys") },
    });
    return if (registered)
        b.addModule("tracy", create_options)
    else
        b.createModule(create_options);
}
