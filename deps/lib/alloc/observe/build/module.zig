const std = @import("std");
const build_api = @import("build_api");

pub fn registered(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    enabled: bool,
) *std.Build.Module {
    return b.addModule(
        "alloc_observe",
        policy.createOptions(b, "src/root.zig", &.{
            .{
                .name = "alloc_observe_channel",
                .module = channel(b, policy),
            },
            .{
                .name = "build_options",
                .module = optionsModule(b, enabled),
            },
        }),
    );
}

pub fn testing(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    enabled: bool,
) *std.Build.Module {
    return b.createModule(policy.createOptions(b, "src/test.zig", &.{
        .{
            .name = "alloc_observe_channel",
            .module = channel(b, policy),
        },
        .{
            .name = "build_options",
            .module = optionsModule(b, enabled),
        },
    }));
}

/// `channel` resolves the option-free sink channel package. Every
/// `alloc_observe` instance and every other consumer that passes the same
/// target and optimize mode shares its one module, whatever `enabled` says.
fn channel(b: *std.Build, policy: build_api.ModuleOptions) *std.Build.Module {
    return b.dependency("alloc_observe_channel", .{
        .target = policy.target,
        .optimize = policy.optimize,
    }).module("alloc_observe_channel");
}

fn optionsModule(b: *std.Build, enabled: bool) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "allocation_observation_enabled", enabled);
    return options.createModule();
}
