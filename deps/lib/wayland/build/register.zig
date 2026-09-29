const std = @import("std");
const build_api = @import("build_api");
const configuration = @import("configuration.zig");
const deps = @import("deps.zig");
const module = @import("module.zig");
const schema = @import("schema.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const config = configuration.resolve(b);
    const sys = deps.sys(b, config.policy);
    const root_inputs = module.rootInputs(
        b,
        sys,
        config.environment_limits.retained_entry_count,
    );

    const wayland = module.registered(b, config.policy, root_inputs);
    _ = build_api.addStaticLibrary(b, .{
        .name = "wayland",
        .root_module = wayland,
    });

    const generated_check = schema.register(b);
    const unit = module.unit(b, config.policy, root_inputs);
    tests.unit(b, config, unit, generated_check);

    const hypothesis = deps.hypothesis(b, config.policy);
    const properties = module.properties(b, config.policy, hypothesis, wayland);
    tests.properties(b, config, properties, generated_check);
}
