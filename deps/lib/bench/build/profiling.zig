const std = @import("std");
const build_api = @import("build_api");

pub fn addSteps(
    b: *std.Build,
    options: build_api.ModuleOptions,
    bench: *std.Build.Module,
    sys: *std.Build.Module,
) void {
    const profiling = b.createModule(options.createOptions(
        b,
        "src/profiling/test.zig",
        &.{
            .{ .name = "bench", .module = bench },
            .{ .name = "sys", .module = sys },
        },
    ));
    const benchmark_tests = b.addTest(.{
        .name = "bench-stabilizer",
        .root_module = profiling,
        .filters = &.{"bench:"},
    });
    const run_benchmark = std.Build.Step.Run.create(b, "run Stabilizer benchmarks");
    run_benchmark.addArtifactArg(benchmark_tests);
    run_benchmark.stdio = .inherit;
    const benchmark_step = b.step(
        "stabilizer-bench",
        "Run Stabilizer allocation benchmarks",
    );
    benchmark_step.dependOn(&run_benchmark.step);
    const install_benchmark = b.addInstallArtifact(benchmark_tests, .{});
    const benchmark_binary_step = b.step(
        "stabilizer-bench-bin",
        "Install Stabilizer allocation benchmark binary",
    );
    benchmark_binary_step.dependOn(&install_benchmark.step);
}
