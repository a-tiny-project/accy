const std = @import("std");
const build_api = @import("build_api");
const configuration = @import("configuration.zig");

pub const Inputs = struct {
    sys: *std.Build.Module,
    coz: *std.Build.Module,
    test_sys: *std.Build.Module,
    test_coz: *std.Build.Module,
};

pub const Installs = struct {
    exterminator: Install,
    dieharder: Install,
    diehard: Install,
};

pub const Install = struct {
    step: *std.Build.Step,
    library: std.Build.LazyPath,
};

const ModuleInputs = struct {
    coz: *std.Build.Module,
    deadalloc: *std.Build.Module,
    options: *std.Build.Module,
    sys: *std.Build.Module,
};

const Mode = struct {
    install: Install,
    run: *std.Build.Step,
};

const ModeSpec = struct {
    option: []const u8,
    artifact: []const u8,
    test_root: []const u8,
};

pub fn add(
    b: *std.Build,
    policies: configuration.Policies,
    inputs: Inputs,
    filters: []const []const u8,
    unit_step: *std.Build.Step,
) Installs {
    const deadalloc = baseModule(b, policies.preload, inputs.sys);
    const test_deadalloc = baseModule(b, policies.library, inputs.test_sys);
    const exterminator = addMode(
        b,
        policies,
        inputs,
        deadalloc,
        test_deadalloc,
        filters,
        .{
            .option = "exterminator",
            .artifact = "deadalloc_malloc",
            .test_root = "src/profiling/test.zig",
        },
    );
    const dieharder = addMode(
        b,
        policies,
        inputs,
        deadalloc,
        test_deadalloc,
        filters,
        .{
            .option = "dieharder",
            .artifact = "deadalloc_malloc_dieharder",
            .test_root = "src/profiling/preload/test.zig",
        },
    );
    const diehard = addMode(
        b,
        policies,
        inputs,
        deadalloc,
        test_deadalloc,
        filters,
        .{
            .option = "diehard",
            .artifact = "deadalloc_malloc_diehard",
            .test_root = "src/profiling/preload/test.zig",
        },
    );

    const install_step = b.step(
        "preload",
        "Build the LD_PRELOAD allocator libraries",
    );
    install_step.dependOn(exterminator.install.step);
    install_step.dependOn(dieharder.install.step);
    install_step.dependOn(diehard.install.step);

    const test_step = b.step(
        "preload-test",
        "Run deadalloc LD_PRELOAD allocator tests",
    );
    test_step.dependOn(exterminator.run);
    test_step.dependOn(dieharder.run);
    test_step.dependOn(diehard.run);
    unit_step.dependOn(exterminator.run);
    unit_step.dependOn(dieharder.run);
    unit_step.dependOn(diehard.run);
    return .{
        .exterminator = exterminator.install,
        .dieharder = dieharder.install,
        .diehard = diehard.install,
    };
}

fn addMode(
    b: *std.Build,
    policies: configuration.Policies,
    inputs: Inputs,
    deadalloc: *std.Build.Module,
    test_deadalloc: *std.Build.Module,
    filters: []const []const u8,
    spec: ModeSpec,
) Mode {
    const options = b.addOptions();
    options.addOption([]const u8, "mode", spec.option);
    const options_module = options.createModule();
    const library_module = preloadModule(
        b,
        policies.preload,
        "src/profiling/preload/root.zig",
        .{
            .coz = inputs.coz,
            .deadalloc = deadalloc,
            .options = options_module,
            .sys = inputs.sys,
        },
    );
    const test_module = preloadModule(
        b,
        policies.library,
        spec.test_root,
        .{
            .coz = inputs.test_coz,
            .deadalloc = test_deadalloc,
            .options = options_module,
            .sys = inputs.test_sys,
        },
    );
    const library = b.addLibrary(.{
        .linkage = .dynamic,
        .name = spec.artifact,
        .root_module = library_module,
    });
    const install = b.addInstallArtifact(library, .{});
    const tests = b.addTest(.{
        .root_module = test_module,
        .filters = filters,
    });
    const run = b.addRunArtifact(tests);
    return .{
        .install = .{
            .step = &install.step,
            .library = library.getEmittedBin(),
        },
        .run = &run.step,
    };
}

fn baseModule(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    sys: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(policy.createOptions(b, "src/root.zig", &.{
        .{ .name = "sys", .module = sys },
    }));
}

fn preloadModule(
    b: *std.Build,
    policy: build_api.ModuleOptions,
    root: []const u8,
    inputs: ModuleInputs,
) *std.Build.Module {
    return b.createModule(policy.createOptions(
        b,
        root,
        &.{
            .{ .name = "coz", .module = inputs.coz },
            .{ .name = "deadalloc", .module = inputs.deadalloc },
            .{ .name = "preload_options", .module = inputs.options },
            .{ .name = "sys", .module = inputs.sys },
        },
    ));
}
