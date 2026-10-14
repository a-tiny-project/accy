const std = @import("std");
const gpu = @import("gpu");
const choir = @import("choir");
const accy_root = @import("../../../root.zig");
const executable = @import("../../root.zig");
const composition = @import("../root.zig");
const cpu = @import("root.zig");

const Allocator = std.mem.Allocator;
const accy = accy_root.choir;
const ChoirComposition = choir.composition;
const preparation = accy_root.preparation;

pub const CpuObjectCompileOptions = struct {
    request: executable.FragmentCompilationRequest,
    compiler: executable.FragmentCompilerOptions = .{},
};

pub const CpuObjectCompilation = struct {
    allocator: Allocator,
    fragment_id: ChoirComposition.FragmentId,
    launch_tuning_artifact: []const u8,
    input_product: choir.product.ProductKey,
    compiled_fragment: ?*executable.CompiledFragment,
    metadata: composition.CpuObjectMetadata,

    pub fn deinit(self: *CpuObjectCompilation) void {
        if (self.compiled_fragment) |fragment| fragment.deinit();
        self.metadata.deinit();
        self.input_product.record.release();
        if (self.launch_tuning_artifact.len != 0) {
            self.allocator.free(@constCast(self.launch_tuning_artifact));
        }
        self.* = undefined;
    }

    pub fn materializer(self: *CpuObjectCompilation) ChoirComposition.FragmentMaterializer {
        return .{
            .id = self.fragment_id,
            .context = self,
            .materialize = materialize,
        };
    }
};

pub fn compileCpuObject(
    allocator: Allocator,
    fragment_id: ChoirComposition.FragmentId,
    module: *accy.SemanticModule,
    options: CpuObjectCompileOptions,
    report: *preparation.publication.PreparationReport,
    comptime configuration: choir.product.operation.Configuration,
) !CpuObjectCompilation {
    defer module.deinit();
    const launch_tuning_artifact: []const u8 = if (options.compiler.launch_tuning_artifact.len == 0)
        &.{}
    else
        try allocator.dupe(u8, options.compiler.launch_tuning_artifact);
    errdefer if (launch_tuning_artifact.len !=
        0) allocator.free(@constCast(launch_tuning_artifact));
    var compiler_options = options.compiler;
    compiler_options.artifact_format = .cpu_object;
    var backend_state = gpu.cpu.State.init(allocator);
    defer backend_state.deinit();
    var plan: executable.fragment.FragmentPreparationPlan = undefined;
    try plan.init(allocator, backend_state.handle(), compiler_options);
    defer plan.deinit();
    const prepared = try preparation.publication.prepare(allocator, .{ .draft = module }, .{
        .source = options.request.source,
        .variant = options.request.variant,
        .work = options.request.work,
        .record_bytes = options.request.record_bytes,
        .options = plan.run_options,
    }, report, configuration);
    defer prepared.deinit();
    try recordPreparation(compiler_options.instrumentation, report);
    const input_record = try prepared.stage(.semantic).metadata().retain();
    errdefer input_record.release();
    const compiled_fragment = try executable.compileFragmentFromPreparedModule(
        allocator,
        backend_state.handle(),
        prepared,
        compiler_options,
        options.request.artifact_workspace,
        configuration,
    );
    errdefer compiled_fragment.deinit();
    const metadata = try composition.CpuObjectMetadata.init(allocator, compiled_fragment);
    return .{
        .allocator = allocator,
        .fragment_id = fragment_id,
        .launch_tuning_artifact = launch_tuning_artifact,
        .input_product = choir.product.productKey(input_record),
        .compiled_fragment = compiled_fragment,
        .metadata = metadata,
    };
}

fn recordPreparation(
    instrumentation: executable.FragmentInstrumentation,
    report: *const preparation.publication.PreparationReport,
) !void {
    const phases = [_]executable.FragmentPhase{
        .run_contract_pipeline, .run_tensor_pipeline, .run_dispatch_pipeline,
        .run_memory_pipeline,   .run_kernel_pipeline, .run_target_pipeline,
    };
    for (phases, report.elapsed_ns[1..]) |phase, elapsed| {
        try instrumentation.recordElapsed(phase, elapsed);
    }
}

fn materialize(
    ptr: *anyopaque,
    allocator: Allocator,
    module: *const ChoirComposition.CompositionModule,
    fragment: *const ChoirComposition.Fragment,
) anyerror!ChoirComposition.MaterializedFragment {
    const compilation: *CpuObjectCompilation = @ptrCast(@alignCast(ptr));
    return cpu.materializeCpuObject(compilation, allocator, module, fragment);
}
