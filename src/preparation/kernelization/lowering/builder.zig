const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const common = @import("common.zig");
const product_mod = @import("../model/root.zig");

const kernel_root = common.kernel_root;
const mapKernelBuildError = common.mapKernelBuildError;
const mapGeneratedKernelError = common.mapGeneratedKernelError;

const LoweredKernel = product_mod.LoweredKernel;

/// The kernel stage calls this once per try at emitting a kernel under one candidate schedule to
/// charge one kernel builder for its work bound. A pass declares those costs before it runs so
/// compilation can refuse a pass that would exceed the caller's limits. The bound adds up every
/// allocation one generated-kernel builder makes over its life, together with the working memory
/// for hashing its finished kernel, and the alignment slack of each part. The kernel's entry name
/// and the scratch each kernel family uses are owned elsewhere and charged separately, along with
/// the shared compiler context, the object that owns the operations and values of the generated
/// kernels. The call returns `error.WorkOverflow` when a size does not fit.
pub fn storageBound(context_limits: common.ir.Context.Limits) !u64 {
    const work = choir.passes.pass.work;
    const limits = kernel_root.Builder.Limits.borrowed_standard;
    const program = kernel_root.Builder.Capacity.deriveBorrowing(limits) catch
        return error.WorkOverflow;
    const context = common.ir.Context.Capacity.derive(context_limits) catch
        return error.WorkOverflow;
    const hashing = choir.product.hashing;
    const value_count = std.math.cast(u32, context.storage_bytes / @sizeOf(common.ir.Value)) orelse
        return error.WorkOverflow;
    const hash = hashing.StableHasher.Capacity.derive(.{
        .root = undefined,
        .facts = .{
            .value_count = value_count,
            .operation_depth = hashing.maximum_operation_depth,
            .attribute_depth = hashing.maximum_attribute_depth,
        },
    }) catch return error.WorkOverflow;
    var bytes = try work.add(program.construction_bytes, hash.working_bytes);
    bytes = try work.add(bytes, program.body.storage_alignment.toByteUnits());
    bytes = try work.add(bytes, program.schedule.storage_alignment.toByteUnits());
    bytes = try work.add(bytes, @alignOf(hashing.capacity.ValueEntry));
    bytes = try work.add(bytes, @alignOf(hashing.capacity.OperationFrame));
    bytes = try work.add(bytes, @alignOf(hashing.capacity.AttributeFrame));
    if (bytes > std.math.maxInt(usize)) return error.WorkOverflow;
    return bytes;
}

const Launch = enum {
    none,
    generated,
};

pub fn withLaunch(
    allocator: std.mem.Allocator,
    ir_ctx: *common.ir.Context,
    work_item_id: usize,
    entry_name: []u8,
    params: []const kernel_root.Param,
    schedule_plan: anytype,
    context: anytype,
    comptime body: anytype,
) common.LoweringError!LoweredKernel {
    return build(
        allocator,
        ir_ctx,
        work_item_id,
        entry_name,
        params,
        schedule_plan,
        context,
        body,
        true,
    );
}

pub fn withoutLaunch(
    allocator: std.mem.Allocator,
    ir_ctx: *common.ir.Context,
    work_item_id: usize,
    entry_name: []u8,
    params: []const kernel_root.Param,
    schedule_plan: anytype,
    context: anytype,
    comptime body: anytype,
) common.LoweringError!LoweredKernel {
    return build(
        allocator,
        ir_ctx,
        work_item_id,
        entry_name,
        params,
        schedule_plan,
        context,
        body,
        false,
    );
}

fn build(
    allocator: std.mem.Allocator,
    ir_ctx: *common.ir.Context,
    work_item_id: usize,
    entry_name: []u8,
    params: []const kernel_root.Param,
    schedule_plan: anytype,
    context: anytype,
    comptime body: anytype,
    comptime capture_launch: bool,
) common.LoweringError!LoweredKernel {
    var builder = kernel_root.Builder.initBorrowing(
        allocator,
        kernel_root.Builder.Limits.borrowed_standard,
        ir_ctx,
        entry_name,
        params,
    ) catch |err| return mapKernelBuildError(err);
    errdefer builder.deinit();

    var logical = kernel_root.logical.wrap(&builder, schedule_plan.policy);
    body(&logical, context) catch |err| return mapGeneratedKernelError(err);

    if (comptime capture_launch) {
        return finish(
            allocator,
            &builder,
            work_item_id,
            entry_name,
            params.len,
            schedule_plan.generated,
            .generated,
        );
    }
    return finish(
        allocator,
        &builder,
        work_item_id,
        entry_name,
        params.len,
        schedule_plan.generated,
        .none,
    );
}

fn finish(
    allocator: std.mem.Allocator,
    builder: *kernel_root.Builder,
    work_item_id: usize,
    entry_name: []u8,
    argument_count: usize,
    schedule: product_mod.GeneratedSchedule,
    launch: Launch,
) common.LoweringError!LoweredKernel {
    builder.return_() catch |err| return mapKernelBuildError(err);

    var kernel = builder.finish() catch |err| return mapKernelBuildError(err);
    errdefer kernel.deinit();

    const body_fingerprint = kernel.bodyFingerprint(allocator) catch |err|
        return mapKernelBuildError(err);
    const dynamic_shared_memory_bytes = product_mod.dynamicSharedMemoryBytes(
        kernel.kernelModule(),
    ) catch |err| return mapGeneratedKernelError(err);
    const lowered_argument_count = std.math.cast(u32, argument_count) orelse
        return error.InvalidArtifact;

    return switch (launch) {
        .none => .{
            .work_item_id = work_item_id,
            .entry_name = entry_name,
            .program = kernel,
            .argument_count = lowered_argument_count,
            .body_fingerprint = body_fingerprint,
            .dynamic_shared_memory_bytes = dynamic_shared_memory_bytes,
            .schedule = schedule,
        },
        .generated => .{
            .work_item_id = work_item_id,
            .entry_name = entry_name,
            .program = kernel,
            .argument_count = lowered_argument_count,
            .body_fingerprint = body_fingerprint,
            .dynamic_shared_memory_bytes = dynamic_shared_memory_bytes,
            .schedule = schedule,
            .launch = kernel.launch() catch |err| return mapGeneratedKernelError(err),
        },
    };
}

const testing = std.testing;
const choir = @import("choir");
const generated_schedule = @import("schedule.zig");

fn testContext() !common.ir.Context {
    var ctx = try common.ir.Context.init(testing.allocator, common.ir.Context.Limits.testing);
    errdefer ctx.deinit(testing.allocator);
    try choir.dialects.registerChoirDialect(&ctx);
    return ctx;
}

fn emitEmpty(_: anytype, _: void) !void {}

fn emitStorageBody(logical: anytype, count: usize) !void {
    const builder: *kernel_root.Builder = @ptrCast(@alignCast(logical.token));
    for (0..count) |index| _ = try builder.constantInt(.i32, @intCast(index));
    for (0..kernel_root.Builder.Limits.borrowed_standard.schedule.axes) |_| {
        _ = try builder.axis("x", 1);
    }
}

test "kernelization generated builder storage covers construction and fingerprint traffic" {
    for ([_]usize{ 0, 1, 512 }) |count| try checkBuilderStorage(count);
    var overflow = common.ir.Context.Limits.testing;
    overflow.operations.storage_bytes = std.math.maxInt(usize);
    try testing.expectError(error.WorkOverflow, storageBound(overflow));
}

fn checkBuilderStorage(count: usize) !void {
    const fixed = @import("alloc_fixed");
    var ctx = try testContext();
    defer ctx.deinit(testing.allocator);
    const bound = try storageBound(ctx.capacity.asLimits());
    const bytes = try testing.allocator.alignedAlloc(u8, .@"64", @intCast(bound));
    defer testing.allocator.free(bytes);
    var backing = fixed.Tracked.init(bytes);
    var retained = fixed.Monotonic.init(backing.allocator(), bytes.len);
    const allocator = retained.allocator();
    const name = try testing.allocator.dupe(u8, "storage");
    defer testing.allocator.free(name);
    const parameter_count = kernel_root.Builder.Limits.borrowed_standard.parameters;
    const params: [parameter_count]kernel_root.Param = @splat(kernel_root.scalar(.i32));
    var result = try withoutLaunch(
        allocator,
        &ctx,
        0,
        name,
        &params,
        generated_schedule.flat(),
        count,
        emitStorageBody,
    );
    defer result.program.deinit();
    try result.program.verify();
    try testing.expectEqual(params.len, result.argument_count);
    try testing.expectEqual(
        try result.program.bodyFingerprint(testing.allocator),
        result.body_fingerprint,
    );
    try testing.expect(!backing.exhausted);
    try testing.expect(backing.status().used_bytes > 0);
    try testing.expect(backing.status().used_bytes <= bound);
}

test "kernelization generated builder distinguishes name and parameter exhaustion" {
    const limits = kernel_root.Builder.Limits.borrowed_standard;
    for ([_]usize{ limits.parameters - 1, limits.parameters, limits.parameters + 1 }) |count| {
        var ctx = try testContext();
        defer ctx.deinit(testing.allocator);
        const params = try testing.allocator.alloc(kernel_root.Param, count);
        defer testing.allocator.free(params);
        @memset(params, kernel_root.scalar(.i32));
        const name = try testing.allocator.dupe(u8, "parameters");
        const before = ctx.capacityUsage();
        const result = withoutLaunch(
            testing.allocator,
            &ctx,
            0,
            name,
            params,
            generated_schedule.flat(),
            {},
            emitEmpty,
        );
        if (count > limits.parameters) {
            defer testing.allocator.free(name);
            try testing.expectError(error.WorkExhausted, result);
            try testing.expectEqualDeep(before, ctx.capacityUsage());
        } else {
            var kernel = try result;
            defer kernel.deinit(testing.allocator);
            try testing.expectEqual(count, kernel.program.params().len);
            try testing.expectEqual(count, kernel.argument_count);
            try testing.expectEqual(@as(?kernel_root.Launch, null), kernel.launch);
        }
    }
    for ([_]usize{
        limits.kernel_name_bytes - 1,
        limits.kernel_name_bytes,
        limits.kernel_name_bytes + 1,
    }) |count| {
        var ctx = try testContext();
        defer ctx.deinit(testing.allocator);
        const name = try testing.allocator.alloc(u8, count);
        @memset(name, 'k');
        const result = withoutLaunch(
            testing.allocator,
            &ctx,
            0,
            name,
            &.{},
            generated_schedule.flat(),
            {},
            emitEmpty,
        );
        if (count > limits.kernel_name_bytes) {
            defer testing.allocator.free(name);
            try testing.expectError(error.WorkExhausted, result);
        } else {
            var kernel = try result;
            defer kernel.deinit(testing.allocator);
            try testing.expectEqualStrings(name, kernel.entry_name);
            try testing.expectEqualStrings(name, kernel.program.storage.kernel.func().getName().?);
        }
    }
}

fn emitAxes(logical: anytype, count: usize) !void {
    const builder: *kernel_root.Builder = @ptrCast(@alignCast(logical.token));
    for (0..count) |_| _ = try builder.axis("x", 1);
}

test "kernelization generated builder preserves schedule capacity failure" {
    const limit = kernel_root.Builder.Limits.borrowed_standard.schedule.axes;
    for ([_]usize{ limit - 1, limit, limit + 1 }) |count| {
        var ctx = try testContext();
        defer ctx.deinit(testing.allocator);
        const name = try testing.allocator.dupe(u8, "schedule");
        const result = withoutLaunch(
            testing.allocator,
            &ctx,
            0,
            name,
            &.{},
            generated_schedule.flat(),
            count,
            emitAxes,
        );
        if (count > limit) {
            defer testing.allocator.free(name);
            try testing.expectError(error.WorkExhausted, result);
        } else {
            var kernel = try result;
            defer kernel.deinit(testing.allocator);
            var snapshot = try kernel.program.scheduleSnapshot(testing.allocator);
            defer snapshot.deinit(testing.allocator);
            try testing.expectEqual(count, snapshot.allAxes().len);
        }
    }
}

test "kernelization generated builder distinguishes borrowed budget from host OOM" {
    var limits = common.ir.Context.Limits.testing;
    limits.operations.storage_bytes = 1;
    var ctx = try common.ir.Context.init(testing.allocator, limits);
    defer ctx.deinit(testing.allocator);
    try choir.dialects.registerChoirDialect(&ctx);
    const name = try testing.allocator.dupe(u8, "budget");
    defer testing.allocator.free(name);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(
        error.WorkExhausted,
        withoutLaunch(
            failing.allocator(),
            &ctx,
            0,
            name,
            &.{},
            generated_schedule.flat(),
            {},
            emitEmpty,
        ),
    );
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expectEqual(@as(?common.ir.Context.Segment, null), ctx.exhaustedSegment());
    try testing.checkAllAllocationFailures(testing.allocator, testHostAllocationFailure, .{});
}

fn emitIndex(logical: anytype, _: void) !void {
    _ = try logical.index1D("x", 5);
}

fn testHostAllocationFailure(allocator: std.mem.Allocator) !void {
    var ctx = try testContext();
    defer ctx.deinit(testing.allocator);
    const name = try allocator.dupe(u8, "host");
    var kernel = withLaunch(
        allocator,
        &ctx,
        7,
        name,
        &.{},
        generated_schedule.flat(),
        {},
        emitIndex,
    ) catch |err| {
        allocator.free(name);
        return err;
    };
    defer kernel.deinit(allocator);
    try testing.expectEqual(@as(usize, 7), kernel.work_item_id);
    try testing.expectEqual(@as(u32, 1), kernel.launch.?.grid[0]);
    try testing.expectEqual(@as(u32, 5), kernel.launch.?.block[0]);
    try testing.expectEqual(try kernel.program.bodyFingerprint(allocator), kernel.body_fingerprint);
}

fn emitTemporaryFailure(logical: anytype, types: bool) !void {
    const value = try logical.constantInt(.i32, 0);
    var values: [65]kernel_root.Value = undefined;
    @memset(&values, value);
    var result_types: [65]kernel_root.Type = undefined;
    @memset(&result_types, value.valueType());
    _ = try logical.forScope(
        value,
        value,
        value,
        if (types) &.{} else &values,
        if (types) &result_types else &.{},
    );
}

test "kernelization generated builder preserves temporary capacity failure" {
    for ([_]bool{ false, true }) |types| {
        var ctx = try testContext();
        defer ctx.deinit(testing.allocator);
        const name = try testing.allocator.dupe(u8, "temporary");
        defer testing.allocator.free(name);
        try testing.expectError(
            error.WorkExhausted,
            withoutLaunch(
                testing.allocator,
                &ctx,
                0,
                name,
                &.{},
                generated_schedule.flat(),
                types,
                emitTemporaryFailure,
            ),
        );
    }
}

fn testReductionModule(
    source: anytype,
    count: usize,
) !*@import("../../../choir/root.zig").semantic.SemanticModule {
    const typ = try source.tensor(.f32, &.{4});
    const types = try testing.allocator.alloc(common.ir.Type, count);
    defer testing.allocator.free(types);
    @memset(types, typ);
    var function = try source.beginFunction("kernel_capacity", types, &.{typ});
    const values = try testing.allocator.alloc(*common.ir.Value, count);
    defer testing.allocator.free(values);
    for (values, 0..) |*value, index| value.* = function.parameter(index);
    var remaining = count;
    while (remaining > 1) {
        var next: usize = 0;
        var index: usize = 0;
        while (index < remaining) : (index += 2) {
            values[next] = if (index + 1 < remaining)
                try function.add(values[index], values[index + 1])
            else
                values[index];
            next += 1;
        }
        remaining = next;
    }
    try function.return_(values[0..1]);
    try function.finish();
    return source.finish();
}

test "kernelization generated builder exhaustion reaches the analysis cache" {
    const semantic = @import("../../../choir/root.zig").semantic;
    const lowering = @import("root.zig");
    const outline_owner = @import("../../outlining/root.zig");
    for ([_]usize{ 61, 62, 63 }) |count| {
        var source = try semantic.Builder.init(
            testing.allocator,
            semantic.Builder.ContextLimits.standard,
        );
        defer source.deinit();
        const module = try testReductionModule(&source, count);
        defer module.deinit();
        const revision = choir.product.revision;
        const ledger = try revision.AccountingV1.create(testing.allocator, .{
            .allowance = revision.WorkVector.uniform(std.math.maxInt(u64)),
            .workspace = std.math.maxInt(u64),
            .events = 32,
        }, &.{});
        defer ledger.destroy();
        var cache = try choir.passes.AnalysisCache.initAccounted(
            testing.allocator,
            null,
            ledger,
            .{},
            8,
        );
        defer cache.deinit();
        var ctx = choir.passes.PassContext.init(
            module.choir_module,
            module.context(),
            testing.allocator,
            &cache,
        );
        defer ctx.deinit();
        const outline = try outline_owner.getKernelOutlinePlanAnalysis(&ctx, module.choir_module);
        try testing.expectEqual(@as(usize, 1), outline.kernels.items.len);
        try testing.expectEqual(count, outline.kernels.items[0].inputCount());
        const before = cache.entries.count();
        const result = lowering.getKernelizationAnalysis(&ctx, module.choir_module);
        if (count == 63) {
            try testing.expectError(error.WorkExhausted, result);
            try testing.expectEqual(before, cache.entries.count());
            try testing.expectEqual(.exhausted, ledger.view().outcome);
            try testing.expectError(
                error.TerminalWorkOutcome,
                lowering.getKernelizationAnalysis(&ctx, module.choir_module),
            );
        } else {
            const analysis = try result;
            try testing.expectEqual(@as(usize, 1), analysis.kernelCount());
            try testing.expectEqual(count + 2, analysis.kernels.items[0].argument_count);
        }
    }
}

test "kernelization generated builder ABI distinguishes size overflow from host OOM" {
    const abi = @import("abi.zig");
    const byte_limit = std.math.maxInt(usize) / @sizeOf(kernel_root.Param);
    for ([_]usize{
        byte_limit - 2,
        byte_limit - 1,
        std.math.maxInt(usize) - 1,
        std.math.maxInt(usize),
    }) |count| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        const expected = if (count == byte_limit - 2) error.OutOfMemory else error.WorkOverflow;
        try testing.expectError(expected, abi.flat(failing.allocator(), .f32, count));
        try testing.expectEqual(count == byte_limit - 2, failing.has_induced_failure);
    }
    const inputs = [_]gpu_abi.DType{ .i32, .f32, .f16 };
    var mixed = try abi.flatTyped(testing.allocator, .f32, &inputs);
    defer mixed.deinit(testing.allocator);
    var uniform = try abi.flat(testing.allocator, .f32, inputs.len);
    defer uniform.deinit(testing.allocator);
    try testing.expectEqual(inputs.len + 2, mixed.params().len);
    try testing.expectEqual(mixed.params().len, uniform.params().len);
    try testing.expectEqualDeep(uniform.params()[0], mixed.params()[0]);
    try testing.expectEqualDeep(uniform.params()[4], mixed.params()[4]);
    for (inputs, 1..) |dtype, index| {
        try testing.expectEqual(dtype, mixed.params()[index].buffer.dtype);
        try testing.expectEqual(.f32, uniform.params()[index].buffer.dtype);
    }
}

fn occupySourceAttributes(ctx: *common.ir.Context) !void {
    const remaining = ctx.capacityUsage().attribute_payloads.remainingBytes();
    const reserved = kernel_root.Builder.Limits.borrowed_standard.context.attributes.payload_bytes;
    const bytes = try testing.allocator.alloc(u8, remaining - reserved / 2);
    defer testing.allocator.free(bytes);
    @memset(bytes, 'q');
    _ = try ctx.getStringAttr(bytes);
    try testing.expect(ctx.capacityUsage().attribute_payloads.remainingBytes() < reserved);
}

fn testDetachedProgram(
    cache: *choir.passes.AnalysisCache,
    occupied: bool,
    vector: bool,
) !*product_mod.KernelizationAnalysis {
    const semantic = @import("../../../choir/root.zig").semantic;
    const lowering = @import("root.zig");
    var source = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer source.deinit();
    const module = try testReductionModule(&source, 2);
    defer module.deinit();
    if (vector) {
        const target = @import("../../root.zig").target;
        var dtypes = gpu.DTypeSet{};
        dtypes.insert(.f32);
        try target.setBackendTargetProfile(module.context(), module.choir_module, .{
            .backend_kind = .cuda,
            .artifact_format = .cuda_ptx,
            .dtype_bits = dtypes.bits,
        });
    }
    var ctx = choir.passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        cache,
    );
    defer ctx.deinit();
    errdefer {
        var preserved = choir.passes.PreservedAnalyses.init(testing.allocator);
        defer preserved.deinit();
        cache.invalidate(&preserved);
    }
    const outline = @import("../../outlining/root.zig");
    _ = try outline.getKernelOutlinePlanAnalysis(&ctx, module.choir_module);
    const before = try choir.bytecode.encodeModule(testing.allocator, module.choir_module);
    defer testing.allocator.free(before);
    if (occupied) try occupySourceAttributes(module.context());
    const generated = try lowering.getKernelizationAnalysis(&ctx, module.choir_module);
    try testing.expect(generated.context != module.context());
    try testing.expectEqual(@as(usize, 1), generated.kernelCount());
    try testing.expect(
        generated.kernels.items[0].program.kernelModule().context == generated.context,
    );
    const expected_body: std.meta.Tag(product_mod.LoweredKernelBody) =
        if (vector) .elementwise_vector else .generic;
    try testing.expectEqual(expected_body, std.meta.activeTag(generated.kernels.items[0].body));
    try testing.expectEqualDeep(
        module.context().capacity.asLimits(),
        generated.context.capacity.asLimits(),
    );
    const after = try choir.bytecode.encodeModule(testing.allocator, module.choir_module);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
    return generated;
}

test "kernelization generated builder owns programs after occupied origin destruction" {
    for ([_]bool{ false, true }) |vector| try checkDetachedPrograms(vector);
}

fn checkDetachedPrograms(vector: bool) !void {
    var cold_cache = choir.passes.AnalysisCache.init(testing.allocator, null);
    defer cold_cache.deinit();
    var occupied_cache = choir.passes.AnalysisCache.init(testing.allocator, null);
    defer occupied_cache.deinit();
    const cold = try testDetachedProgram(&cold_cache, false, vector);
    const occupied = try testDetachedProgram(&occupied_cache, true, vector);
    try testing.expectEqual(@as(usize, 1), cold.kernelCount());
    try testing.expectEqual(cold.kernelCount(), occupied.kernelCount());
    for (cold.kernels.items, occupied.kernels.items) |*left, *right| {
        try left.program.verify();
        try right.program.verify();
        const left_bytes = try choir.bytecode.encodeModule(
            testing.allocator,
            left.program.kernelModule(),
        );
        defer testing.allocator.free(left_bytes);
        const right_bytes = try choir.bytecode.encodeModule(
            testing.allocator,
            right.program.kernelModule(),
        );
        defer testing.allocator.free(right_bytes);
        try testing.expectEqualSlices(u8, left_bytes, right_bytes);
        try testing.expectEqualDeep(left.program.params(), right.program.params());
        try testing.expectEqualDeep(left.summary(), right.summary());
        try testing.expectEqualDeep(left.body, right.body);
        try testing.expectEqual(left.output_fill_pattern, right.output_fill_pattern);
        try testing.expectEqual(left.scratch_fill_pattern, right.scratch_fill_pattern);
        var left_schedule = try left.program.scheduleSnapshot(testing.allocator);
        defer left_schedule.deinit(testing.allocator);
        var right_schedule = try right.program.scheduleSnapshot(testing.allocator);
        defer right_schedule.deinit(testing.allocator);
        try testing.expectEqualDeep(left_schedule.allAxes(), right_schedule.allAxes());
        try testing.expectEqualDeep(left_schedule.allSteps(), right_schedule.allSteps());
    }
}

fn testSplatSource(source: anytype, broadcast: u2) !*common.ir.Value {
    const typ = try source.tensor(.f32, &.{2});
    const result_type = if (broadcast == 2) try source.tensor(.f32, &.{ 2, 2 }) else typ;
    var function = try source.beginFunction("splat_failure", &.{}, &.{result_type});
    const data = [_]f32{ 7, 7 };
    var value = try function.constant(typ, std.mem.sliceAsBytes(&data));
    if (broadcast == 1) {
        value = try function.broadcastInDim(value, typ, &.{2}, &.{0});
    } else if (broadcast == 2) {
        value = try function.broadcast(value, result_type, &.{2});
    }
    try function.return_(&.{value});
    try function.finish();
    return value;
}

fn testSplatRefusal(broadcast: u2) !void {
    const semantic = @import("../../../choir/root.zig").semantic;
    const elementwise = @import("elementwise.zig");
    const abi_owner = @import("abi.zig");
    var source = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer source.deinit();
    const value = try testSplatSource(&source, broadcast);
    const root: *common.ir.Operation = @ptrCast(@alignCast(value.getDefiningOp().?));
    var ctx = try testContext();
    defer ctx.deinit(testing.allocator);
    var abi = try abi_owner.flat(testing.allocator, .f32, 0);
    defer abi.deinit(testing.allocator);
    var builder = try kernel_root.Builder.initBorrowing(
        testing.allocator,
        kernel_root.Builder.Limits.borrowed_standard,
        &ctx,
        "splat",
        abi.params(),
    );
    defer builder.deinit();
    const index = try builder.constantIndex(0);
    const payload_allocator = common.ir.context.attributePayloadAllocator(&ctx);
    const unused = try payload_allocator.alloc(
        u8,
        ctx.capacityUsage().attribute_payloads.remainingBytes(),
    );
    defer payload_allocator.free(unused);
    var buffers = common.bufferization.BufferPlanAnalysis.init(testing.allocator);
    defer buffers.deinit();
    const outline = product_mod.KernelOutline{
        .id = 0,
        .name = &.{},
        .kind = .elementwise,
        .work_item_id = 0,
        .root = root,
        .input_slot_ids = &.{},
        .output_slot_id = 0,
        .element_count = 2,
        .op_count = 1,
    };
    try testing.expectError(error.OutOfMemory, elementwise.shapeReadValue(
        &builder,
        index,
        value,
        outline,
        &buffers,
        abi,
        elementwise.max_recompute_depth,
    ));
    try testing.expectEqual(common.ir.Context.Segment.attribute_payloads, ctx.exhaustedSegment().?);
}

test "kernelization generated builder preserves splat emission exhaustion" {
    for ([_]u2{ 0, 1, 2 }) |broadcast| try testSplatRefusal(broadcast);
}

fn testKernelContextHostFailure(allocator: std.mem.Allocator) !void {
    const semantic = @import("../../../choir/root.zig").semantic;
    const lowering = @import("root.zig");
    var source = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer source.deinit();
    const module = try testReductionModule(&source, 2);
    defer module.deinit();
    var cache = choir.passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var ctx = choir.passes.PassContext.init(
        module.choir_module,
        module.context(),
        allocator,
        &cache,
    );
    defer ctx.deinit();
    const analysis = try lowering.getKernelizationAnalysis(&ctx, module.choir_module);
    try testing.expectEqual(@as(usize, 1), analysis.kernelCount());
    try testing.expectEqual(@as(u32, 4), analysis.kernels.items[0].argument_count);
    try testing.expect(analysis.context != module.context());
}

test "kernelization generated builder owns cleanup across native allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, testKernelContextHostFailure, .{});
}

test "kernelization generated builder declines nonsplats without losing valid literals" {
    const semantic = @import("../../../choir/root.zig").semantic;
    var source = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer source.deinit();
    const typ = try source.tensor(.f32, &.{2});
    var function = try source.beginFunction("constants", &.{}, &.{typ});
    const uniform_data = [_]f32{ 7, 7 };
    const varied_data = [_]f32{ 7, 8 };
    const uniform = try function.constant(typ, std.mem.sliceAsBytes(&uniform_data));
    const varied = try function.constant(typ, std.mem.sliceAsBytes(&varied_data));
    try function.return_(&.{uniform});
    try function.finish();
    var ctx = try testContext();
    defer ctx.deinit(testing.allocator);
    var builder = try kernel_root.Builder.initBorrowing(
        testing.allocator,
        kernel_root.Builder.Limits.borrowed_standard,
        &ctx,
        "literal",
        &.{},
    );
    defer builder.deinit();
    const before = ctx.capacityUsage();
    const varied_op: *common.ir.Operation = @ptrCast(@alignCast(varied.getDefiningOp().?));
    try testing.expect(try common.optionalSplatConstantValue(&builder, varied_op) == null);
    try testing.expectEqualDeep(before, ctx.capacityUsage());
    const uniform_op: *common.ir.Operation = @ptrCast(@alignCast(uniform.getDefiningOp().?));
    try testing.expect(try common.optionalSplatConstantValue(&builder, uniform_op) != null);
    try builder.return_();
    var program = try builder.finish();
    defer program.deinit();
    try program.verify();
}
