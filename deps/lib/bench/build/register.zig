const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const module = @import("module.zig");
const product = @import("product.zig");
const profiling = @import("profiling.zig");
const tests = @import("tests.zig");

pub fn build(b: *std.Build) void {
    const configuration = deps.configure(b);
    const module_options = build_api.ModuleOptions{
        .target = configuration.target,
        .optimize = configuration.optimize,
    };
    const benchmark_options = build_api.ModuleOptions{
        .target = configuration.target,
        .optimize = .fast,
    };
    const dependencies = deps.resolve(b, configuration);
    var benchmark_configuration = configuration;
    benchmark_configuration.optimize = .fast;
    const benchmark_dependencies = deps.resolve(b, benchmark_configuration);
    const bench = product.addProduct(b, module_options, dependencies.inputs);
    const benchmark_bench = module.createModule(
        b,
        benchmark_options,
        benchmark_dependencies.inputs,
    );
    const bench_tests = module.createTestModule(
        b,
        module_options,
        dependencies.inputs,
    );
    const validation = build_api.validationBuild;
    const evidence = if (b.isRoot()) blk: {
        const metadata = validation.declaration.load(b, "../..", "lib/bench").?;
        break :blk validation.configure(b, metadata.recipes);
    } else null;
    tests.add(
        b,
        module_options,
        configuration,
        dependencies,
        bench,
        bench_tests,
        evidence,
    );
    profiling.addSteps(
        b,
        benchmark_options,
        benchmark_bench,
        benchmark_dependencies.inputs.sys,
    );
}
