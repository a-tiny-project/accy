const std = @import("std");
const gpu = @import("gpu");
const sys = @import("sys");
const exec = @import("../../executable/root.zig");
const artifact = @import("root.zig").artifact;
const program = @import("../program/root.zig");

const FragmentCompilerOptions = exec.FragmentCompilerOptions;
const ArtifactOptions = exec.KernelCompilerOptions;

pub fn compileFragment(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    graph: *program.Program,
    options: FragmentCompilerOptions,
) !*exec.CompiledFragment {
    const artifact_start = nowNs();
    const artifact_job = try artifact.createJob(
        allocator,
        handle,
        graph,
        artifactPlanOptions(options),
    );
    defer artifact_job.deinit();
    try options.instrumentation.record(.plan_create_backend_artifacts, artifact_start);
    return try exec.compileFragmentFromArtifactJob(allocator, artifact_job);
}

pub fn createArtifact(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    graph: *program.Program,
    options: ArtifactOptions,
) !gpu.KernelArtifact {
    const compiled = try compileFragment(allocator, handle, graph, .{
        .artifact_format = options.artifact_format,
        .authored_kernel_diagnostic_id = options.authored_kernel_diagnostic_id,
        .instrumentation = options.instrumentation,
    });
    defer compiled.deinit();
    if (compiled.kernelCount() != 1) return error.InvalidArtifact;
    return try exec.candidate.copyKernelArtifactToAllocator(
        allocator,
        compiled.artifactPlan().kernels.items[0].artifact,
    );
}

fn artifactPlanOptions(options: FragmentCompilerOptions) artifact.Options {
    return .{
        .format = options.artifact_format,
        .kernel_plan = .{ .diagnostic_id = options.authored_kernel_diagnostic_id },
    };
}

fn nowNs() i128 {
    return sys.time.nanoTimestamp();
}
