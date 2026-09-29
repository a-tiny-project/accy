const std = @import("std");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const lowering = @import("root.zig");
const model = @import("../model/root.zig");
const work = choir.passes.pass.work;
const ir = choir.ir;
const kernel = lowering.common.kernel_root;

/// The kernel stage calls this function before the pass runs to charge kernel generation against
/// the caller's limits. The function computes the work bound from counts read off the source
/// module, before any allocation and before any analysis is requested. The work bound is the costs
/// a pass declares before it runs, so compilation can refuse a pass that would exceed the caller's
/// limits. The call returns `error.MissingWorkContract` when the pass would run on more than one
/// thread or with a worker allocator. The analyses it depends on declare their own bounds and their
/// own retained storage.
pub fn analysis(input: work.Input) !work.Bounds {
    if (input.options.max_threads != 1 or input.options.worker_allocator != null) {
        return error.MissingWorkContract;
    }
    var source = try work.Census.inspect(input.operation);
    source.values = try work.add(source.values, source.operands);
    const limits = input.operation.context.capacity.asLimits();
    const capacity = ir.Context.Capacity.derive(limits) catch return error.WorkOverflow;
    const attempts = @max(
        2,
        lowering.row_pipeline.max_schedule_candidates + 2,
        lowering.scan_lowering.max_schedule_candidates + 2,
    );
    const per_kernel = try work.multiply(attempts, try attemptStorage(source, limits));
    const base = try model.KernelizationAnalysis.baseStorageBound(limits, source.operations);
    const storage = try work.add(base, try work.multiply(source.operations, per_kernel));
    const visits = try traversal(source, limits, attempts);
    return .{
        .work = .{
            .input_bytes = source.input_bytes,
            .output_bytes = capacity.storage_bytes,
            .structural_visits = visits,
            .analysis_computations = 1,
            .allocation_capacity = storage,
        },
        .workspace = storage,
        .retained_storage = storage,
    };
}

pub fn pass(_: work.Input) !work.Bounds {
    return .{ .work = .{ .structural_visits = 1 } };
}

/// `analysis` calls this function to size the storage of one generation attempt, one try at
/// emitting a kernel under one candidate schedule. One attempt owns one generated program, its name
/// and one parameter list. The scratch of every kernel family is added up so the bound holds
/// whichever family generation picks, including the vector fallback, the second body
/// element-by-element generation emits when the per-element form does not apply.
fn attemptStorage(source: work.Census, limits: ir.Context.Limits) !u64 {
    var bytes = try lowering.builder.storageBound(limits);
    bytes = try work.add(bytes, lowering.name.maximum_storage_bytes);
    bytes = try work.add(bytes, try lowering.abi.storageBound(source.values));
    bytes = try work.add(bytes, try lowering.elementwise.scratchStorageBound(source));
    bytes = try work.add(bytes, try lowering.row_pipeline.scratchStorageBound(source.values));
    const arrays = try work.multiply(source.values, @sizeOf(gpu_abi.DType) +
        @sizeOf(lowering.common.bufferization.BufferSlot) + @sizeOf(kernel.Value));
    const alignment = @alignOf(gpu_abi.DType) +
        @alignOf(lowering.common.bufferization.BufferSlot) + @alignOf(kernel.Value);
    bytes = try work.add(bytes, try work.add(arrays, alignment));
    const memo = try work.hashMapGrowth(*ir.Value, kernel.Value, source.values);
    const varying = try work.hashMapGrowth(*ir.Value, void, source.values);
    bytes = try work.add(bytes, try work.add(try work.multiply(6, memo), varying));
    if (bytes > std.math.maxInt(usize)) return error.WorkOverflow;
    return bytes;
}

/// `analysis` calls this function to count the visits kernel generation makes. The count covers
/// scans of the source and the plans, memo lookups, and building, checking and hashing the
/// generated code. The shared compiler context, the object that owns the operations and values of
/// the generated kernels, caps the generated records, and that cap holds even across failed
/// attempts.
fn traversal(source: work.Census, limits: ir.Context.Limits, attempts: u64) !u64 {
    const source_units = try work.add(try work.add(source.atoms, source.input_bytes), 1);
    const generated_bytes = try work.add(limits.operations.storage_bytes, limits.operations.nested_bytes);
    const generated_values = generated_bytes / @sizeOf(ir.Value);
    const generated_ops = limits.operations.storage_bytes / @sizeOf(ir.Operation);
    const records = try work.add(try work.add(generated_values, generated_ops), 1);
    const source_walks = try work.multiply(source_units, try work.add(source.operations, 1));
    const lookups = try work.add(try work.hashMapCapacity(source.values), source_units);
    const generated_walks = try work.multiply(records, try work.add(lookups, 256));
    const total = try work.add(source_walks, generated_walks);
    return work.multiply(128, try work.multiply(
        try work.multiply(try work.add(source.operations, 1), attempts),
        total,
    ));
}
