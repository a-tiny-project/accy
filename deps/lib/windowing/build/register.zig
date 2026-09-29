const std = @import("std");
const profiling = @import("profiling.zig");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const nolibc = @import("nolibc.zig");
const product = @import("product.zig");
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
    const dependencies = deps.resolve(
        b,
        configuration,
        benchmark_options.target,
        benchmark_options.optimize,
    );
    const windowing = product.addProduct(
        b,
        module_options,
        dependencies.requested.inputs,
    );
    const validation = tests.add(
        b,
        module_options,
        configuration,
        dependencies.requested,
        windowing,
    );
    const benchmark_graph = profiling.add(b, benchmark_options, dependencies.benchmark);
    nolibc.add(b, module_options.target, validation, benchmark_graph);
}
