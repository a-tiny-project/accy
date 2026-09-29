const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const profile = @import("profile.zig");

/// One test root on the `test` step. A suite that carries a validation request
/// runs under the validation runner and records the declared suite's evidence.
const Suite = struct {
    module: *std.Build.Module,
    name: []const u8 = "test",
    validation: ?build_api.validationBuild.Configuration = null,
};

/// Adds the unit, provenance, and floor suites to `test` and `verify`, and the
/// property suite to `pbt`. Only the floor suite binds to a validation recipe,
/// because its tests are pure integer arithmetic over the standard library and
/// the self-hosted runner executes them as written. A recipe still runs every
/// suite on `test`, each in the recipe's test directory, because the unit
/// suite creates temporary directories below its working directory and the
/// check sandbox mounts the source read-only. The provenance generator runs
/// `sh`, which the recipe declares as a runtime executable.
pub fn add(
    b: *std.Build,
    options: build_api.ModuleOptions,
    configuration: deps.Configuration,
    dependencies: deps.Requested,
    bench: *std.Build.Module,
    bench_tests: *std.Build.Module,
    evidence: ?build_api.validationBuild.Configuration,
) void {
    const test_step = b.step("test", "Run unit tests");
    const verify_step = b.step(
        "verify",
        "Compile unit-test AIR for verification",
    );
    const provenance_module = b.createModule(options.createOptions(
        b,
        "src/provenance.zig",
        &.{.{
            .name = "profile_build_options",
            .module = profile.profileBuildOptions(
                b,
                configuration.target,
                configuration.optimize,
            ),
        }},
    ));
    const floor_module = b.createModule(options.createOptions(b, "src/floor/test.zig", &.{}));
    const bound = if (evidence) |recipe|
        if (std.mem.eql(u8, recipe.recipe.step, "test")) recipe else null
    else
        null;
    const suites = [_]Suite{
        .{ .module = bench_tests },
        .{ .module = provenance_module },
        .{ .module = floor_module, .name = "bench-floor-tests", .validation = bound },
    };
    for (suites) |suite| {
        const run = addSuite(b, options, suite, configuration.test_filters);
        if (bound) |recipe| run.setCwd(b.graph.cwdRelativePath(recipe.recipe.test_cwd));
        test_step.dependOn(&run.step);
        verify_step.dependOn(&compileOnlyTest(b, suite.module, configuration.test_filters).step);
    }

    const property_module = b.createModule(options.createOptions(
        b,
        "src/properties/test.zig",
        &.{
            .{ .name = "bench", .module = bench },
            .{ .name = "hypothesis", .module = dependencies.hypothesis },
            .{ .name = "pretty", .module = dependencies.inputs.pretty },
        },
    ));
    const property_tests = b.addTest(.{
        .root_module = property_module,
        .filters = configuration.test_filters,
    });
    const run_property_tests = b.addRunArtifact(property_tests);

    const property_step = b.step("pbt", "Run benchmark property tests");
    property_step.dependOn(&run_property_tests.step);
}

fn addSuite(
    b: *std.Build,
    options: build_api.ModuleOptions,
    suite: Suite,
    filters: []const []const u8,
) *std.Build.Step.Run {
    const validation = build_api.validationBuild;
    var test_options: std.Build.TestOptions = .{
        .name = suite.name,
        .root_module = suite.module,
        .filters = filters,
    };
    if (suite.validation) |configuration| {
        if (options.optimize != .debug or !build_api.targetsEqual(options.target, b.graph.host) or
            filters.len != 0) @panic("validation recipes require unfiltered Debug host tests");
        const api = b.dependency("build_api", .{
            .target = options.target,
            .optimize = options.optimize,
        });
        const declared = configuration.recipe.suites[0];
        std.debug.assert(std.mem.eql(u8, declared.id, suite.name));
        test_options.root_module = validation.bind(
            b,
            suite.module,
            configuration,
            declared,
            .{ .module = api.module("validation") },
        );
        test_options.use_llvm = false;
        test_options.test_runner = .{ .path = api.path("runner.zig"), .mode = .simple };
    }
    return validation.run(b, b.addTest(test_options), suite.validation);
}

fn compileOnlyTest(
    b: *std.Build,
    root_module: *std.Build.Module,
    filters: []const []const u8,
) *std.Build.Step.Compile {
    const tests = b.addTest(.{
        .root_module = root_module,
        .filters = filters,
    });
    tests.generated_bin = .none;
    return tests;
}
