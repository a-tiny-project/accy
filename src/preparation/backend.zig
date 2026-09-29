const std = @import("std");
const sys = @import("sys");
const choir = @import("choir");
const bufferization = @import("bufferization/root.zig");
const accy_choir = @import("../choir/root.zig");
const kernelization_model = @import("kernelization/model/root.zig");
const kernel_outlining = @import("outlining/root.zig");
const target_profile = @import("target.zig");

const ir = choir.ir;
const passes = choir.passes;
const accounting = passes.pass.work;

pub const backend_legalization_analysis_name = "accy-choir-backend-legalization";
pub const backend_legalization_pass_name = "accy-choir-legalize-backend";
pub const backend_legalization_pass_description =
    "Validate Accy Choir kernel candidates for backend artifact planning";

pub const BackendKernelStatus = enum {
    legal,
    missing_input_slot,
    missing_output_slot,
    dynamic_input_slot,
    dynamic_output_slot,
    illegal_output_role,
    unsupported_dtype,
};

pub const BackendKernelLegalization = struct {
    kernel_id: usize,
    status: BackendKernelStatus,
    input_count: usize,
    output_slot_id: usize,
    static_bytes: u64 = 0,

    pub fn isLegal(self: BackendKernelLegalization) bool {
        return self.status == .legal;
    }
};

pub const BackendLegalizationAnalysis = struct {
    allocator: std.mem.Allocator,
    kernels: std.ArrayListUnmanaged(BackendKernelLegalization),
    target: ?target_profile.BackendTargetProfile = null,
    legal_kernel_count: usize = 0,
    illegal_kernel_count: usize = 0,
    total_static_bytes: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        target: ?target_profile.BackendTargetProfile,
    ) BackendLegalizationAnalysis {
        return .{
            .allocator = allocator,
            .kernels = .empty,
            .target = target,
        };
    }

    pub fn deinit(self: *BackendLegalizationAnalysis) void {
        self.kernels.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn kernelCount(self: BackendLegalizationAnalysis) usize {
        return self.kernels.items.len;
    }

    pub fn isLegal(self: BackendLegalizationAnalysis) bool {
        return self.illegal_kernel_count == 0;
    }

    pub fn hasPipelineFailure(self: BackendLegalizationAnalysis) bool {
        for (self.kernels.items) |kernel| {
            if (kernel.status != .legal and kernel.status != .unsupported_dtype) return true;
        }
        return false;
    }

    fn addKernel(self: *BackendLegalizationAnalysis, result: BackendKernelLegalization) !void {
        const total = try accounting.add(
            self.total_static_bytes,
            if (result.isLegal()) result.static_bytes else 0,
        );
        try self.kernels.append(self.allocator, result);
        if (result.isLegal()) {
            self.legal_kernel_count += 1;
            self.total_static_bytes = total;
        } else {
            self.illegal_kernel_count += 1;
        }
    }

    pub fn firstIllegalStatus(self: BackendLegalizationAnalysis) ?BackendKernelStatus {
        for (self.kernels.items) |kernel| {
            if (!kernel.isLegal()) return kernel.status;
        }
        return null;
    }
};

const BackendWork = struct {
    input: accounting.Census,

    fn bounds(self: BackendWork) !accounting.Bounds {
        const count = self.input.operations;
        const storage = try accounting.add(
            @sizeOf(BackendLegalizationAnalysis) + @alignOf(BackendLegalizationAnalysis),
            try accounting.arrayListGrowth(BackendKernelLegalization, count),
        );
        if (storage > std.math.maxInt(usize)) return error.WorkOverflow;
        const input_units = try accounting.add(self.input.atoms, self.input.input_bytes);
        const units = try accounting.add(input_units, 1);
        const checks = try accounting.multiply(
            try accounting.add(count, 1),
            try accounting.add(self.input.values, 1),
        );
        const visits = try accounting.multiply(64, try accounting.multiply(units, checks));
        return .{
            .work = .{
                .input_bytes = self.input.input_bytes,
                .structural_visits = visits,
                .analysis_computations = 1,
                .allocation_capacity = storage,
            },
            .workspace = storage,
            .retained_storage = storage,
        };
    }
};

fn backendAnalysisWork(input: accounting.Input) !accounting.Bounds {
    if (input.options.max_threads != 1 or input.options.worker_allocator != null) {
        return error.MissingWorkContract;
    }
    return (BackendWork{ .input = try accounting.Census.inspect(input.operation) }).bounds();
}

fn backendPassWork(input: accounting.Input) !accounting.Bounds {
    const counts = try accounting.Census.inspect(input.operation);
    return .{ .work = .{ .structural_visits = try accounting.add(counts.operations, 1) } };
}

pub const backend_legalization_analysis_descriptor = passes.AnalysisDescriptor{
    .id = passes.analysisId(backend_legalization_analysis_name),
    .name = backend_legalization_analysis_name,
    .work_contract = .{
        .identity = .{ .name = backend_legalization_analysis_name, .version = 1 },
        .estimate = backendAnalysisWork,
    },
};

pub fn getBackendLegalizationAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) !*BackendLegalizationAnalysis {
    const ptr = try pass_ctx.getAnalysis(
        op,
        &backend_legalization_analysis_descriptor,
        computeBackendLegalizationAnalysis,
        cleanupBackendLegalizationAnalysis,
    );
    return @ptrCast(@alignCast(ptr));
}

pub fn backendLegalizationPass() passes.Pass {
    return .{
        .name = backend_legalization_pass_name,
        .description = backend_legalization_pass_description,
        .run_fn = runBackendLegalizationPass,
        .work_contract = .{
            .identity = .{ .name = backend_legalization_pass_name, .version = 1 },
            .estimate = backendPassWork,
        },
    };
}

fn runBackendLegalizationPass(pass_ctx: *passes.PassContext) passes.PassResult {
    const analysis = getBackendLegalizationAnalysis(pass_ctx, pass_ctx.op) catch return .failure;
    if (analysis.hasPipelineFailure()) return .failure;
    pass_ctx.preserveAllAnalyses();
    return .success;
}

fn computeBackendLegalizationAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) anyerror!*anyopaque {
    const outline_plan = try kernel_outlining.getKernelOutlinePlanAnalysis(pass_ctx, op);
    const buffer_plan = try bufferization.getBufferPlanAnalysis(pass_ctx, op);

    const analysis = try pass_ctx.allocator.create(BackendLegalizationAnalysis);
    const target = target_profile.readBackendTargetProfile(op);
    analysis.* = BackendLegalizationAnalysis.init(pass_ctx.allocator, target);
    errdefer {
        analysis.deinit();
        pass_ctx.allocator.destroy(analysis);
    }

    try addLegalizedKernels(pass_ctx, analysis, outline_plan, buffer_plan);

    return @ptrCast(analysis);
}

fn cleanupBackendLegalizationAnalysis(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const analysis: *BackendLegalizationAnalysis = @ptrCast(@alignCast(ptr));
    analysis.deinit();
    allocator.destroy(analysis);
}

pub fn backendKernelStatusError(status: BackendKernelStatus) anyerror {
    return switch (status) {
        .unsupported_dtype => error.CapabilityMismatch,
        else => error.IllegalKernel,
    };
}

/// A caller uses this to learn whether one outlined kernel can run on the chosen device with the
/// buffers the memory plan gives it. The function looks up the kernel's output buffer and each
/// input buffer in the memory plan and returns a result with a status, the kernel id, the input
/// count, the output buffer id and the total static size in bytes. The status names the first
/// problem found: a missing or dynamically sized output buffer, an output buffer in a role a kernel
/// may not write, a missing or dynamically sized input buffer, or an element type the device does
/// not support. The function checks element types only when given a target profile, the facts about
/// the chosen device, such as which element types it supports. An illegal kernel comes back as a
/// status and never as an error, and the only error is an overflow while adding up the byte sizes.
pub fn legalizeKernel(
    kernel: kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    target: ?target_profile.BackendTargetProfile,
) !BackendKernelLegalization {
    var result = BackendKernelLegalization{
        .kernel_id = kernel.id,
        .status = .legal,
        .input_count = kernel.inputCount(),
        .output_slot_id = kernel.output_slot_id,
    };

    const output_slot = slotById(buffer_plan, kernel.output_slot_id) orelse {
        result.status = .missing_output_slot;
        return result;
    };
    if (!output_slot.hasStaticSize()) {
        result.status = .dynamic_output_slot;
        return result;
    }
    if (!outputSlotRoleIsLegal(output_slot.role)) {
        result.status = .illegal_output_role;
        return result;
    }
    if (target) |profile| {
        if (!profile.supportsDType(output_slot.dtype)) {
            result.status = .unsupported_dtype;
            return result;
        }
    }
    result.static_bytes = try accounting.add(result.static_bytes, output_slot.byte_size.?);

    for (kernel.input_slot_ids) |slot_id| {
        const input_slot = slotById(buffer_plan, slot_id) orelse {
            result.status = .missing_input_slot;
            return result;
        };
        if (!input_slot.hasStaticSize()) {
            result.status = .dynamic_input_slot;
            return result;
        }
        if (target) |profile| {
            if (!profile.supportsDType(input_slot.dtype)) {
                result.status = .unsupported_dtype;
                return result;
            }
        }
        result.static_bytes = try accounting.add(result.static_bytes, input_slot.byte_size.?);
    }

    return result;
}

fn addLegalizedKernels(
    pass_ctx: *passes.PassContext,
    analysis: *BackendLegalizationAnalysis,
    outline_plan: *const kernelization_model.KernelOutlinePlanAnalysis,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) !void {
    const kernels = outline_plan.kernels.items;
    if (pass_ctx.workerCount(kernels.len) > 1) {
        return try addLegalizedKernelsParallel(pass_ctx, analysis, kernels, buffer_plan);
    }
    for (kernels) |kernel| {
        try analysis.addKernel(try legalizeKernel(kernel, buffer_plan, analysis.target));
    }
}

const BackendLegalizationSlot = struct {
    result: ?(anyerror!BackendKernelLegalization) = null,
};

const BackendLegalizationBatch = struct {
    kernels: []const kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    target: ?target_profile.BackendTargetProfile,
    slots: []BackendLegalizationSlot,
};

fn addLegalizedKernelsParallel(
    pass_ctx: *passes.PassContext,
    analysis: *BackendLegalizationAnalysis,
    kernels: []const kernelization_model.KernelOutline,
    buffer_plan: *const bufferization.BufferPlanAnalysis,
) !void {
    const slots = try pass_ctx.allocator.alloc(BackendLegalizationSlot, kernels.len);
    defer pass_ctx.allocator.free(slots);
    for (slots) |*slot| slot.* = .{};

    var batch = BackendLegalizationBatch{
        .kernels = kernels,
        .buffer_plan = buffer_plan,
        .target = analysis.target,
        .slots = slots,
    };

    try ir.threading.parallelForEachIndex(
        pass_ctx.allocator,
        pass_ctx.run_options,
        kernels.len,
        &batch,
        legalizeKernelAt,
    );

    for (slots) |slot| {
        try analysis.addKernel(try (slot.result orelse unreachable));
    }
}

fn legalizeKernelAt(batch: *BackendLegalizationBatch, index: usize) void {
    batch.slots[index].result = legalizeKernel(
        batch.kernels[index],
        batch.buffer_plan,
        batch.target,
    );
}

fn slotById(
    buffer_plan: *const bufferization.BufferPlanAnalysis,
    slot_id: usize,
) ?*const bufferization.BufferSlot {
    if (slot_id >= buffer_plan.slots.items.len) return null;
    const slot = &buffer_plan.slots.items[slot_id];
    if (slot.id != slot_id) return null;
    return slot;
}

fn outputSlotRoleIsLegal(role: bufferization.BufferRole) bool {
    return role.output or role.temporary;
}

const testing = std.testing;
const semantic = accy_choir.semantic;

test "backend legalization accepts static elementwise outlined kernels" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("backend_legal_fused_add_mul", &.{ f32_4, f32_4, f32_4 }, &.{f32_4});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    const product = try fb.mul(sum, fb.parameter(2));
    try fb.return_(&.{product});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try backendTestLedger(false, std.math.maxInt(u64));
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 8);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const analysis = try getBackendLegalizationAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkBackendStorage(choir_mod, ctx, &cache, analysis);
    try testing.expect(analysis.isLegal());
    try testing.expectEqual(@as(usize, 1), analysis.kernelCount());
    try testing.expectEqual(@as(usize, 1), analysis.legal_kernel_count);
    try testing.expectEqual(@as(usize, 0), analysis.illegal_kernel_count);
    try testing.expectEqual(@as(u64, 64), analysis.total_static_bytes);
    try testing.expectEqual(BackendKernelStatus.legal, analysis.kernels.items[0].status);
}

test "backend legalization threads match serial analysis" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("backend_legal_threaded", &.{ f32_4, f32_4, f32_4 }, &.{ f32_4, f32_4 });
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    const product = try fb.mul(sum, fb.parameter(2));
    try fb.return_(&.{ sum, product });
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();

    var serial_cache = passes.AnalysisCache.init(allocator, null);
    defer serial_cache.deinit();
    var serial_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &serial_cache);
    defer serial_ctx.deinit();
    const serial = try getBackendLegalizationAnalysis(&serial_ctx, choir_mod);

    var threaded_cache = passes.AnalysisCache.init(allocator, null);
    defer threaded_cache.deinit();
    var threaded_ctx = passes.PassContext.initWithOptions(choir_mod, ctx, allocator, &threaded_cache, .{
        .max_threads = 2,
    });
    defer threaded_ctx.deinit();
    const threaded = try getBackendLegalizationAnalysis(&threaded_ctx, choir_mod);

    try testing.expectEqual(serial.kernelCount(), threaded.kernelCount());
    try testing.expectEqual(serial.legal_kernel_count, threaded.legal_kernel_count);
    try testing.expectEqual(serial.illegal_kernel_count, threaded.illegal_kernel_count);
    try testing.expectEqual(serial.total_static_bytes, threaded.total_static_bytes);
    for (serial.kernels.items, threaded.kernels.items) |expected, actual| {
        try testing.expectEqual(expected.kernel_id, actual.kernel_id);
        try testing.expectEqual(expected.status, actual.status);
        try testing.expectEqual(expected.input_count, actual.input_count);
        try testing.expectEqual(expected.output_slot_id, actual.output_slot_id);
        try testing.expectEqual(expected.static_bytes, actual.static_bytes);
    }
}

test "backend legalization pass preserves legal IR" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("backend_legal_pass_add4", &.{ f32_4, f32_4 }, &.{f32_4});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(backendLegalizationPass());

    const ledger = try backendTestLedger(true, std.math.maxInt(u64));
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 8);
    defer cache.deinit();
    try testing.expectEqual(
        passes.PassResult.success,
        pm.runWithAnalysisCache(choir_mod, ctx, &cache, .{}),
    );
    try ledger.producersComplete();
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

fn backendTestLedger(pass: bool, visits: u64) !*choir.product.revision.AccountingV1 {
    const revision = choir.product.revision;
    var allowance = revision.WorkVector.uniform(std.math.maxInt(u64));
    allowance.structural_visits = visits;
    const pipeline = [_]revision.record.Version{
        .{ .name = backend_legalization_pass_name, .version = 1 },
    };
    return revision.AccountingV1.create(testing.allocator, .{
        .allowance = allowance,
        .workspace = std.math.maxInt(u64),
        .events = 32,
    }, if (pass) &pipeline else &.{});
}

fn buildBackendModule(
    builder: *semantic.Builder,
    count: usize,
    extent: i64,
    alias: bool,
) !*semantic.SemanticModule {
    const typ = try builder.tensor(.f32, &.{extent});
    const types = try testing.allocator.alloc(ir.Type, count);
    defer testing.allocator.free(types);
    @memset(types, typ);
    const results = try testing.allocator.alloc(*ir.Value, count);
    defer testing.allocator.free(results);
    var function = try builder.beginFunction(
        "backend_work",
        if (alias) &.{typ} else &.{ typ, typ },
        types,
    );
    for (results) |*result| {
        if (alias) {
            const call = try function.kernelCall(&.{function.parameter(0)}, &.{typ}, .{
                .target = "update_f32",
                .operand_effects = &.{.read_write},
                .result_aliases = &.{0},
            });
            result.* = call.getFirstResult();
        } else {
            result.* = try function.add(function.parameter(0), function.parameter(1));
        }
    }
    try function.return_(results);
    try function.finish();
    return builder.finish();
}

fn checkBackendStorage(
    op: *ir.Operation,
    ctx: *ir.Context,
    cache: *passes.AnalysisCache,
    expected: *const BackendLegalizationAnalysis,
) !void {
    const bounds = try backendAnalysisWork(.{ .operation = op });
    const fixed = @import("alloc_fixed");
    const bytes = try testing.allocator.alignedAlloc(u8, .@"64", @intCast(bounds.workspace));
    defer testing.allocator.free(bytes);
    var backing = fixed.Tracked.init(bytes);
    var retained = fixed.Monotonic.init(backing.allocator(), @max(1, bytes.len));
    const allocator = retained.allocator();
    var ctx_fixed = passes.PassContext.init(op, ctx, allocator, cache);
    defer ctx_fixed.deinit();
    const ptr = try computeBackendLegalizationAnalysis(&ctx_fixed, op);
    defer cleanupBackendLegalizationAnalysis(ptr, allocator);
    const actual: *BackendLegalizationAnalysis = @ptrCast(@alignCast(ptr));
    try testing.expectEqual(expected.legal_kernel_count, actual.legal_kernel_count);
    try testing.expectEqual(expected.illegal_kernel_count, actual.illegal_kernel_count);
    try testing.expectEqual(expected.total_static_bytes, actual.total_static_bytes);
    try testing.expectEqualDeep(expected.target, actual.target);
    try testing.expectEqualDeep(expected.kernels.items, actual.kernels.items);
    const used = if (retained.current) |*current| fixed.used(current) else 0;
    try testing.expect(!backing.exhausted);
    try testing.expect(used >= @sizeOf(BackendLegalizationAnalysis));
    try testing.expect(used <= bounds.workspace);
}

test "backend legalization work contract covers growing output lists" {
    for ([_]usize{ 0, 1, 2, 6, 7, 16, 64 }) |count| {
        var builder = try semantic.Builder.init(
            testing.allocator,
            semantic.Builder.ContextLimits.standard,
        );
        defer builder.deinit();
        const module = try buildBackendModule(&builder, count, 4, false);
        defer module.deinit();
        const ledger = try backendTestLedger(false, std.math.maxInt(u64));
        defer ledger.destroy();
        var cache = try passes.AnalysisCache.initAccounted(
            testing.allocator,
            null,
            ledger,
            .{},
            8,
        );
        defer cache.deinit();
        var ctx = passes.PassContext.init(
            module.choir_module,
            module.context(),
            testing.allocator,
            &cache,
        );
        defer ctx.deinit();
        const analysis = try getBackendLegalizationAnalysis(&ctx, module.choir_module);
        try testing.expectEqual(count, analysis.kernelCount());
        try testing.expectEqual(@as(u64, count * 48), analysis.total_static_bytes);
        try ledger.producersComplete();
        try checkBackendStorage(module.choir_module, module.context(), &cache, analysis);
    }
    try testing.expectError(error.WorkOverflow, (BackendWork{
        .input = .{ .operations = std.math.maxInt(u64) },
    }).bounds());
    try testing.expectError(error.WorkOverflow, (BackendWork{
        .input = .{ .values = std.math.maxInt(u64) },
    }).bounds());
    try testing.expectError(error.WorkOverflow, (BackendWork{
        .input = .{ .input_bytes = std.math.maxInt(u64) },
    }).bounds());
}

test "backend legalization checks individual and repeated-buffer byte totals" {
    const aggregate_edge: i64 = @intCast(std.math.maxInt(u64) / 36);
    const alias_edge: i64 = @intCast(std.math.maxInt(u64) / 8);
    for ([_]i64{ -1, 0, 1 }) |offset| {
        try checkBackendBytes(3, aggregate_edge + offset, false, false);
        try checkBackendBytes(3, aggregate_edge + offset, false, true);
        try checkBackendBytes(1, alias_edge + offset, true, false);
    }
    try checkBackendBytes(2, alias_edge + 1, true, true);
}

fn checkBackendBytes(count: usize, extent: i64, alias: bool, parallel: bool) !void {
    if (parallel and !sys.thread.threadsSupported()) return error.SkipZigTest;
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const module = try buildBackendModule(&builder, count, extent, alias);
    defer module.deinit();
    const ledger = if (parallel) null else try backendTestLedger(false, std.math.maxInt(u64));
    defer if (ledger) |value| value.destroy();
    var cache = if (ledger) |value|
        try passes.AnalysisCache.initAccounted(testing.allocator, null, value, .{}, 8)
    else
        passes.AnalysisCache.init(testing.allocator, null);
    defer cache.deinit();
    var ctx = passes.PassContext.initWithOptions(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
        .{ .max_threads = if (parallel) 2 else 1 },
    );
    defer ctx.deinit();
    const outlines = try kernel_outlining.getKernelOutlinePlanAnalysis(&ctx, module.choir_module);
    const buffers = try bufferization.getBufferPlanAnalysis(&ctx, module.choir_module);
    try testing.expectEqual(count, outlines.kernelCount());
    try testing.expect(buffers.total_static_bytes > 0);
    const entries = cache.entries.count();
    const total: u128 = @as(u128, @intCast(extent)) * 4 * count * @as(u128, if (alias) 2 else 3);
    if (total <= std.math.maxInt(u64)) {
        const result = try getBackendLegalizationAnalysis(&ctx, module.choir_module);
        try testing.expectEqual(@as(u64, @intCast(total)), result.total_static_bytes);
        try testing.expectEqual(count, result.legal_kernel_count);
        if (ledger) |value| try value.producersComplete();
    } else {
        try testing.expectError(
            error.WorkOverflow,
            getBackendLegalizationAnalysis(&ctx, module.choir_module),
        );
        try testing.expectEqual(entries, cache.entries.count());
        if (ledger) |value| {
            try testing.expectEqual(.exhausted, value.view().outcome);
            try testing.expectError(
                error.TerminalWorkOutcome,
                getBackendLegalizationAnalysis(&ctx, module.choir_module),
            );
        }
    }
}

test "backend legalization overflow preserves the admitted result prefix" {
    var analysis = BackendLegalizationAnalysis.init(testing.allocator, null);
    defer analysis.deinit();
    const first = BackendKernelLegalization{
        .kernel_id = 0,
        .status = .legal,
        .input_count = 0,
        .output_slot_id = 0,
        .static_bytes = std.math.maxInt(u64),
    };
    try analysis.addKernel(first);
    try testing.expectError(error.WorkOverflow, analysis.addKernel(.{
        .kernel_id = 1,
        .status = .legal,
        .input_count = 0,
        .output_slot_id = 1,
        .static_bytes = 1,
    }));
    try testing.expectEqual(@as(usize, 1), analysis.kernelCount());
    try testing.expectEqual(@as(usize, 1), analysis.legal_kernel_count);
    try testing.expectEqual(std.math.maxInt(u64), analysis.total_static_bytes);
    try testing.expectEqualDeep(first, analysis.kernels.items[0]);
}

test "backend legalization rejects unmodeled options with cached dependencies" {
    for ([_]ir.ThreadingOptions{
        .{ .max_threads = 0 },
        .{ .max_threads = 2 },
        .{ .worker_allocator = testing.allocator },
    }) |options| {
        var builder = try semantic.Builder.init(
            testing.allocator,
            semantic.Builder.ContextLimits.standard,
        );
        defer builder.deinit();
        const module = try buildBackendModule(&builder, 2, 4, false);
        defer module.deinit();
        const ledger = try backendTestLedger(false, std.math.maxInt(u64));
        defer ledger.destroy();
        var cache = try passes.AnalysisCache.initAccounted(
            testing.allocator,
            null,
            ledger,
            .{},
            8,
        );
        defer cache.deinit();
        var ctx = passes.PassContext.init(
            module.choir_module,
            module.context(),
            testing.allocator,
            &cache,
        );
        defer ctx.deinit();
        _ = try kernel_outlining.getKernelOutlinePlanAnalysis(&ctx, module.choir_module);
        const before = ledger.view().charged;
        const entries = cache.entries.count();
        ctx.run_options = options;
        try testing.expectError(
            error.MissingWorkContract,
            getBackendLegalizationAnalysis(&ctx, module.choir_module),
        );
        try testing.expectEqualDeep(before, ledger.view().charged);
        try testing.expectEqual(entries, cache.entries.count());
        try testing.expectEqual(.rejected, ledger.view().outcome);
        ctx.run_options = .{};
        try testing.expectError(
            error.TerminalWorkOutcome,
            getBackendLegalizationAnalysis(&ctx, module.choir_module),
        );
    }
}

test "backend legalization preserves target capability failure as a distinct result" {
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const module = try buildBackendModule(&builder, 2, 4, false);
    defer module.deinit();
    const profile = target_profile.BackendTargetProfile{
        .backend_kind = .cuda,
        .artifact_format = .cuda_ptx,
        .math_tier = .exact,
        .dtype_bits = 0,
        .feature_bits = 0,
    };
    try target_profile.setBackendTargetProfile(module.context(), module.choir_module, profile);
    const ledger = try backendTestLedger(true, std.math.maxInt(u64));
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(
        testing.allocator,
        null,
        ledger,
        .{},
        8,
    );
    defer cache.deinit();
    var manager = passes.PassManager.init(testing.allocator);
    defer manager.deinit();
    try manager.addPass(backendLegalizationPass());
    try testing.expectEqual(
        passes.PassResult.success,
        manager.runWithAnalysisCache(module.choir_module, module.context(), &cache, .{}),
    );
    try ledger.producersComplete();
    var ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer ctx.deinit();
    const analysis = try getBackendLegalizationAnalysis(&ctx, module.choir_module);
    try testing.expect(!analysis.isLegal());
    try testing.expect(!analysis.hasPipelineFailure());
    try testing.expectEqual(@as(usize, 2), analysis.illegal_kernel_count);
    try testing.expectEqual(@as(u64, 0), analysis.total_static_bytes);
    try testing.expectEqualDeep(profile, analysis.target.?);
    try testing.expectEqual(.unsupported_dtype, analysis.firstIllegalStatus().?);
    try testing.expectEqual(error.CapabilityMismatch, backendKernelStatusError(.unsupported_dtype));
    try checkBackendStorage(module.choir_module, module.context(), &cache, analysis);
}

test "backend legalization retains slot failure distinctions" {
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const module = try buildBackendModule(&builder, 1, 4, false);
    defer module.deinit();
    var cache = passes.AnalysisCache.init(testing.allocator, null);
    defer cache.deinit();
    var ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer ctx.deinit();
    const outlines = try kernel_outlining.getKernelOutlinePlanAnalysis(&ctx, module.choir_module);
    const buffers = try bufferization.getBufferPlanAnalysis(&ctx, module.choir_module);
    const kernel = outlines.kernels.items[0];
    var bad_output = kernel;
    bad_output.output_slot_id = buffers.slots.items.len;
    try testing.expectEqual(
        .missing_output_slot,
        (try legalizeKernel(bad_output, buffers, null)).status,
    );
    var bad_inputs = kernel;
    var missing = [_]usize{buffers.slots.items.len};
    bad_inputs.input_slot_ids = &missing;
    try testing.expectEqual(
        .missing_input_slot,
        (try legalizeKernel(bad_inputs, buffers, null)).status,
    );
    const output = &buffers.slots.items[kernel.output_slot_id];
    const saved_output = output.*;
    defer output.* = saved_output;
    output.byte_size = null;
    try testing.expectEqual(
        .dynamic_output_slot,
        (try legalizeKernel(kernel, buffers, null)).status,
    );
    output.* = saved_output;
    output.role = .{};
    try testing.expectEqual(
        .illegal_output_role,
        (try legalizeKernel(kernel, buffers, null)).status,
    );
    output.* = saved_output;
    const input = &buffers.slots.items[kernel.input_slot_ids[0]];
    const saved_input = input.*;
    defer input.* = saved_input;
    input.byte_size = null;
    try testing.expectEqual(
        .dynamic_input_slot,
        (try legalizeKernel(kernel, buffers, null)).status,
    );
}

test "backend legalization enforces its pass allowance and terminal retry" {
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const module = try buildBackendModule(&builder, 2, 4, false);
    defer module.deinit();
    const charge = try checkBackendAllowance(module, std.math.maxInt(u64), true);
    try testing.expect(charge > 1);
    _ = try checkBackendAllowance(module, charge - 1, false);
    try testing.expectEqual(charge, try checkBackendAllowance(module, charge, true));
    try testing.expectEqual(charge, try checkBackendAllowance(module, charge + 1, true));
}

fn checkBackendAllowance(module: *semantic.SemanticModule, visits: u64, success: bool) !u64 {
    const ledger = try backendTestLedger(true, visits);
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(
        testing.allocator,
        null,
        ledger,
        .{},
        8,
    );
    defer cache.deinit();
    var manager = passes.PassManager.init(testing.allocator);
    defer manager.deinit();
    try manager.addPass(backendLegalizationPass());
    const result = manager.runWithAnalysisCache(module.choir_module, module.context(), &cache, .{});
    var ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer ctx.deinit();
    if (success) {
        try testing.expectEqual(passes.PassResult.success, result);
        try ledger.producersComplete();
        const before = ledger.view().charged;
        const analysis = try getBackendLegalizationAnalysis(&ctx, module.choir_module);
        try testing.expectEqual(@as(usize, 2), analysis.kernelCount());
        try testing.expectEqualDeep(before, ledger.view().charged);
    } else {
        try testing.expectEqual(passes.PassResult.failure, result);
        try testing.expectEqual(.exhausted, ledger.view().outcome);
        try testing.expectError(
            error.TerminalWorkOutcome,
            getBackendLegalizationAnalysis(&ctx, module.choir_module),
        );
    }
    return ledger.view().charged.structural_visits;
}
