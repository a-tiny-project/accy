const std = @import("std");
const build_api = @import("build_api");
const deps = @import("deps.zig");
const module = @import("module.zig");

pub const Graph = struct {
    benchmark: *std.Build.Step.Compile,
    no_libc_witness: *std.Build.Step.Compile,
    step: *std.Build.Step,
    install_step: *std.Build.Step,
};

pub fn add(
    b: *std.Build,
    options: build_api.ModuleOptions,
    dependencies: deps.Benchmark,
) Graph {
    const windowing = module.createModule(b, options, dependencies.inputs);
    const profiling = b.createModule(options.createOptions(
        b,
        "src/profiling/test.zig",
        &.{
            .{ .name = "bench", .module = dependencies.bench },
            .{ .name = "sys", .module = dependencies.inputs.sys },
            .{ .name = "wayland", .module = dependencies.inputs.wayland },
            .{ .name = "windowing", .module = windowing },
        },
    ));
    const benchmark = addArtifact(b, profiling, "windowing-bench", true);
    const run_benchmark = std.Build.Step.Run.create(b, "run windowing presentation benchmarks");
    run_benchmark.addArtifactArg(benchmark);
    run_benchmark.stdio = .inherit;
    const step = b.step("bench", "Run windowing presentation profiling benchmarks");
    step.dependOn(&run_benchmark.step);
    const install_benchmark = b.addInstallArtifact(benchmark, .{});
    const install_step = b.step(
        "bench-bin",
        "Install windowing presentation benchmark binary",
    );
    install_step.dependOn(&install_benchmark.step);
    return .{
        .benchmark = benchmark,
        .no_libc_witness = addArtifact(
            b,
            profiling,
            "windowing-no-libc-witness",
            false,
        ),
        .step = step,
        .install_step = install_step,
    };
}

fn addArtifact(
    b: *std.Build,
    profiling: *std.Build.Module,
    name: []const u8,
    use_llvm: bool,
) *std.Build.Step.Compile {
    const artifact = b.addTest(.{
        .name = name,
        .root_module = profiling,
        .filters = &.{"bench:"},
    });
    artifact.use_llvm = use_llvm;
    return artifact;
}
