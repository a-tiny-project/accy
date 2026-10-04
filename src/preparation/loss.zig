const std = @import("std");
const alloc_arena = @import("alloc_arena");
const choir = @import("choir");
const accy_choir = @import("../choir/root.zig");
const kernel_library = @import("../kernel/library/root.zig");
const call_preparation = @import("call.zig");
const library_preparation = @import("library.zig");
const dialect_mod = accy_choir.dialect;

const ir = choir.ir;
const rewrite = ir.rewrite;
const passes = choir.passes;
const work = passes.pass.work;

pub const KernelLibraryLowering = library_preparation.KernelLibraryLowering;

pub const Options = struct {
    kernel_library: KernelLibraryLowering = .disabled,
    row_sparse_cross_entropy_schedule: ?kernel_library.RowSparseCrossEntropySchedule = null,

    pub fn eql(self: Options, other: Options) bool {
        return self.kernel_library == other.kernel_library and
            std.meta.eql(
                self.row_sparse_cross_entropy_schedule,
                other.row_sparse_cross_entropy_schedule,
            );
    }
};

pub const loss_lowering_pass_name = "accy-choir-loss-lower";
pub const loss_lowering_pass_description =
    "Lower semantic Accy loss operations onto kernel library catalog calls";

const kernel_library_option_choices = [_]passes.PassOptionChoice{
    .{ .name = "disabled" },
    .{ .name = "enabled" },
};

pub const loss_lowering_pass_options = [_]passes.PassOptionSpec{
    .{
        .name = "kernel-library",
        .description = "Use kernel library calls for supported loss operations",
        .kind = .choice,
        .choices = &kernel_library_option_choices,
        .default_value = "disabled",
    },
    .{
        .name = "row-sparse-cross-entropy-thread-blocks",
        .description = "Thread blocks for selected row sparse cross entropy kernels",
        .kind = .unsigned,
    },
};

pub fn lossLoweringPass() passes.Pass {
    return .{
        .name = loss_lowering_pass_name,
        .description = loss_lowering_pass_description,
        .run_fn = runLossLoweringPass,
        .work_contract = loss_work_contract,
    };
}

pub fn lossLoweringPassWithOptions(options: *const Options) passes.Pass {
    return .{
        .name = loss_lowering_pass_name,
        .description = loss_lowering_pass_description,
        .state = @constCast(options),
        .run_with_state_fn = runLossLoweringPassWithState,
        .work_contract = loss_work_contract,
    };
}

pub fn lossLoweringPassFromOptions(
    allocator: std.mem.Allocator,
    set: passes.PassOptionSet,
) anyerror!passes.Pass {
    const options = try allocator.create(Options);
    errdefer allocator.destroy(options);
    options.* = .{
        .kernel_library = try kernelLibraryLoweringFromText(
            set.choiceValue("kernel-library", "disabled"),
        ),
        .row_sparse_cross_entropy_schedule = if (set.get(
            "row-sparse-cross-entropy-thread-blocks",
        )) |value| .{
            .thread_blocks = try parseU32Option(value),
        } else null,
    };
    var pass = lossLoweringPassWithOptions(options);
    pass.state_deinit_fn = destroyOptions;
    return pass;
}

const loss_work_contract: work.Contract = .{
    .identity = .{ .name = loss_lowering_pass_name, .version = 1 },
    .estimate = lossWork,
};

const LossWork = struct {
    candidates: u64 = 0,
    type_bytes: u64 = 0,

    fn visit(self: *LossWork, op: *ir.Operation) !ir.WalkResult {
        if (!std.mem.eql(
            u8,
            op.name.name,
            dialect_mod.AccyDialect.SparseCrossEntropyOp.operation_name,
        )) return .advance;
        if (op.getNumResults() != 1 or op.getNumOperands() != 2) return .advance;
        self.candidates = try work.add(self.candidates, 1);
        for (op.getOperandValues()) |operand| try self.typeBytes(operand.type);
        try self.typeBytes(op.getResult(0).?.type);
        return .advance;
    }

    fn typeBytes(self: *LossWork, typ: ir.Type) !void {
        if (typ.getDialectParamKey()) |key| {
            self.type_bytes = try work.add(self.type_bytes, key.len);
        }
    }
};

fn lossDescriptorStorage() u64 {
    const entry = kernel_library.entry;
    const shape = accy_choir.shape;
    const arrays = 2 * std.ArrayList(shape.Symbol).growCapacity(2) * @sizeOf(shape.Symbol) +
        3 * std.ArrayList(shape.Tensor).growCapacity(3) * @sizeOf(shape.Tensor) +
        2 * std.ArrayList(shape.Fact).growCapacity(2) * @sizeOf(shape.Fact);
    const records = 3 * @sizeOf(entry.Shape) + 4 * @sizeOf(entry.Axis) +
        2 * @sizeOf(entry.ScheduleBinding) + 4 * @sizeOf(shape.Expression) +
        8 * @sizeOf(shape.Term);
    const arena_traffic = 8 * (arrays + records + 256 + 64 * 128);
    return arena_traffic + @sizeOf(alloc_arena.Arena) + @sizeOf(shape.Family) + 64;
}

fn lossWork(input: work.Input) !work.Bounds {
    const options: *const Options = if (input.state) |state| @ptrCast(@alignCast(state)) else &.{};
    if (options.kernel_library != .enabled or options.row_sparse_cross_entropy_schedule == null) {
        return .{ .work = .{ .structural_visits = 1 } };
    }
    const counts = try work.Census.inspect(input.operation);
    var facts: LossWork = .{};
    _ = try input.operation.walk(.{ .order = .pre_order }, &facts, LossWork.visit);
    const descriptors = try work.multiply(facts.candidates, lossDescriptorStorage());
    const decoding = try work.multiply(8, try work.add(
        try work.multiply(facts.type_bytes, @sizeOf(i64)),
        try work.multiply(facts.candidates, 3 * 128 + 64),
    ));
    const queues = try work.multiply(2, try work.arrayListGrowth(*ir.Operation, facts.candidates));
    const bytes = try work.add(queues, try work.add(decoding, descriptors));
    const units = try work.add(try work.add(counts.atoms, counts.input_bytes), 1);
    const uses = try work.add(try work.add(counts.values, counts.operands), 1);
    const traversal = try work.multiply(128, try work.multiply(units, uses));
    const nodes = try work.multiply(facts.candidates, @sizeOf(ir.Operation) + @sizeOf(ir.Value) +
        2 * @sizeOf(ir.OpOperand) + 8 * @sizeOf(ir.NamedAttribute) + 256 +
        2 * @sizeOf(dialect_mod.AccyDialect.KernelCallScalar));
    return .{
        .work = .{
            .input_bytes = counts.input_bytes,
            .output_bytes = nodes,
            .structural_visits = try work.add(traversal, try work.multiply(2, descriptors)),
            .allocation_capacity = bytes,
        },
        .workspace = bytes,
    };
}

fn destroyOptions(raw: ?*anyopaque, allocator: std.mem.Allocator) void {
    const options: *Options = @ptrCast(@alignCast(raw orelse return));
    allocator.destroy(options);
}

fn kernelLibraryLoweringFromText(value: []const u8) !KernelLibraryLowering {
    if (std.mem.eql(u8, value, "disabled")) return .disabled;
    if (std.mem.eql(u8, value, "enabled")) return .enabled;
    return error.InvalidPassOptionValue;
}

fn parseU32Option(value: []const u8) !u32 {
    return std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidPassOptionValue;
}

fn runLossLoweringPass(pass_ctx: *passes.PassContext) passes.PassResult {
    return runLossLoweringWithOptions(pass_ctx, .{});
}

fn runLossLoweringPassWithState(raw: ?*anyopaque, pass_ctx: *passes.PassContext) passes.PassResult {
    const options: *const Options = @ptrCast(@alignCast(raw orelse return .failure));
    return runLossLoweringWithOptions(pass_ctx, options.*);
}

fn runLossLoweringWithOptions(pass_ctx: *passes.PassContext, options: Options) passes.PassResult {
    if (options.kernel_library != .enabled or options.row_sparse_cross_entropy_schedule == null) {
        pass_ctx.preserveAllAnalyses();
        return .success;
    }

    var rewriter = rewrite.PatternRewriter.init(pass_ctx.allocator, pass_ctx.ir_ctx);
    defer rewriter.deinit();

    var lowered_count: usize = 0;
    lowerOnOp(pass_ctx.op, &rewriter, options, &lowered_count) catch return .failure;
    if (lowered_count == 0) {
        pass_ctx.preserveAllAnalyses();
    } else {
        rewriter.finalize(pass_ctx.op);
        pass_ctx.markModified();
    }
    return .success;
}

fn lowerOnOp(
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
    options: Options,
    lowered_count: *usize,
) !void {
    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                const next = current_op.next_op;
                if (current_op.regions.items.len > 0) {
                    try lowerOnOp(current_op, rewriter, options, lowered_count);
                }
                if (std.mem.eql(
                    u8,
                    current_op.name.name,
                    dialect_mod.AccyDialect.SparseCrossEntropyOp.operation_name,
                )) {
                    var guard = rewriter.insertionGuard();
                    defer guard.deinit();
                    rewriter.setInsertionPointBefore(current_op);
                    if (try lowerKnownKernelLibrarySparseCrossEntropy(
                        current_op,
                        rewriter,
                        options,
                    )) {
                        lowered_count.* += 1;
                    }
                }
                current = next;
            }
        }
    }
}

fn lowerKnownKernelLibrarySparseCrossEntropy(
    op: *ir.Operation,
    rewriter: *rewrite.PatternRewriter,
    options: Options,
) !bool {
    if (op.getNumResults() != 1) return false;
    const result = op.getResult(0) orelse return false;
    const operands = op.getOperandValues();
    if (operands.len != 2) return false;

    var arena_state = alloc_arena.Arena.init(rewriter.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const logits_type = try dialect_mod.decodeTensorType(arena, operands[0].type);
    const targets_type = try dialect_mod.decodeTensorType(arena, operands[1].type);
    const output_type = try dialect_mod.decodeTensorType(arena, result.type);
    if (targets_type.dtype != .i32) return false;
    if (output_type.dtype != logits_type.dtype) return false;
    if (logits_type.dims.len != 2 or targets_type.dims.len != 1 or output_type.dims.len != 1) {
        return false;
    }
    if (targets_type.dims[0] != logits_type.dims[0]) return false;
    if (output_type.dims[0] != logits_type.dims[0]) return false;

    const rows = dimExtent(logits_type.dims[0]) orelse return false;
    const classes = dimExtent(logits_type.dims[1]) orelse return false;

    var selected = (try kernel_library.selectOwned(rewriter.allocator, .{
        .row_sparse_cross_entropy = .{
            .dtype = logits_type.dtype,
            .rows = rows,
            .classes = classes,
            .schedule = options.row_sparse_cross_entropy_schedule,
        },
    })) orelse return false;
    defer selected.deinit();

    const instance = kernel_library.loss.rowSparseCrossEntropyInstanceFromSpecialization(
        selected.descriptor.metadata.specialization,
    ) orelse return false;
    const runtime_scalars = call_preparation.catalogCallScalars(
        2,
        try kernel_library.loss.rowSparseCrossEntropyRuntimeArguments(instance),
    );
    const result_types = [_]ir.Type{result.type};
    const call = try call_preparation.insertCatalogCall(rewriter, .{
        .descriptor = selected.descriptor,
        .operands = operands,
        .result_types = &result_types,
        .options = .{ .runtime_scalars = runtime_scalars[0..] },
    });
    try rewriter.replaceOpWithValue(op, call.getFirstResult());
    return true;
}

fn dimExtent(dim: i64) ?u64 {
    if (dim <= 0) return null;
    return @intCast(dim);
}

const testing = std.testing;
const semantic = accy_choir.semantic;

const LossCase = struct {
    rows: u32 = 6,
    classes: u32 = 11,
    threads: u32 = 4,
    copies: u32 = 1,
    dtype: accy_choir.semantics.DType = .f32,

    fn module(self: LossCase) !*semantic.SemanticModule {
        var builder = try semantic.Builder.init(testing.allocator, .standard);
        defer builder.deinit();
        const logits = try builder.tensor(self.dtype, &.{ self.rows, self.classes });
        const targets = try builder.tensor(.i32, &.{self.rows});
        const losses = try builder.tensor(self.dtype, &.{self.rows});
        var function = try builder.beginFunction(
            "loss_accounting",
            &.{ logits, targets },
            &.{losses},
        );
        var value: *ir.Value = undefined;
        for (0..self.copies) |_| {
            value = try function.sparseCrossEntropy(
                function.parameter(0),
                function.parameter(1),
                losses,
            );
        }
        try function.return_(&.{value});
        try function.finish();
        return builder.finish();
    }

    fn options(self: LossCase) Options {
        return .{
            .kernel_library = .enabled,
            .row_sparse_cross_entropy_schedule = .{ .thread_blocks = self.threads },
        };
    }

    fn check(self: LossCase, module_: *semantic.SemanticModule, lowered: bool) !void {
        try module_.verify();
        const root = module_.choir_module;
        try testing.expectEqual(
            @as(usize, if (lowered) 0 else self.copies),
            ir.inspection.countOperationsNamed(root, "accy.sparse_cross_entropy"),
        );
        try testing.expectEqual(
            @as(usize, if (lowered) self.copies else 0),
            ir.inspection.countOperationsNamed(root, "accy.kernel_call"),
        );
        var witness: LossCallWitness = .{ .case = self };
        _ = try root.walk(.{ .order = .pre_order }, &witness, LossCallWitness.visit);
    }
};

const LossCallWitness = struct {
    case: LossCase,

    fn visit(self: *LossCallWitness, op: *ir.Operation) !ir.WalkResult {
        if (!std.mem.eql(u8, op.name.name, "accy.kernel_call")) return .advance;
        const target = op.getAttr("target").?.cast(ir.Attribute.DialectAttr).?.payload;
        var name: [96]u8 = undefined;
        const expected = try std.fmt.bufPrint(
            &name,
            "accy.kernel.loss.row_sparse_cross_entropy_family_{d}_f32",
            .{self.case.threads},
        );
        try testing.expectEqualStrings(expected, target);
        const scalars = (try dialect_mod.AccyDialect.kernelCallRuntimeScalars(op)).?;
        try testing.expectEqual(@as(usize, 2), scalars.count);
        try testing.expectEqual(.u32, scalars.items[0].kind);
        try testing.expectEqual(.u32, scalars.items[1].kind);
        try testing.expectEqual(@as(u64, self.case.rows), scalars.items[0].bits);
        try testing.expectEqual(@as(u64, self.case.classes), scalars.items[1].bits);
        return .advance;
    }
};

fn checkLossAccounting(admitted: bool, constructor: u32) !void {
    const allocator = testing.allocator;
    const revision = choir.product.revision;
    const fixture: LossCase = .{};
    const module = try fixture.module();
    defer module.deinit();
    const root = module.choir_module;
    const before = try choir.bytecode.encodeModule(allocator, root);
    defer allocator.free(before);
    const options: Options = switch (constructor) {
        0 => .{},
        3 => .{ .kernel_library = .enabled },
        else => fixture.options(),
    };
    const bounds = try lossWork(.{ .operation = root, .state = &options });
    var allowance = revision.WorkVector.uniform(1 << 40);
    if (!admitted) allowance.structural_visits = bounds.work.structural_visits - 1;
    const ledger = try revision.AccountingV1.create(allocator, .{
        .allowance = allowance,
        .workspace = 1 << 24,
        .events = 4,
    }, &.{.{ .name = loss_lowering_pass_name, .version = 1 }});
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(
        allocator,
        null,
        ledger,
        .{ .context = module.context() },
        0,
    );
    defer cache.deinit();
    var manager = passes.PassManager.init(allocator);
    defer manager.deinit();
    try manager.addPass(switch (constructor) {
        0 => lossLoweringPass(),
        1, 3 => lossLoweringPassWithOptions(&options),
        2 => try lossLoweringPassFromOptions(allocator, .{ .assignments = &.{
            .{ .name = "kernel-library", .value = "enabled" },
            .{ .name = "row-sparse-cross-entropy-thread-blocks", .value = "4" },
        } }),
        else => unreachable,
    });
    const result = manager.runWithAnalysisCache(root, module.context(), &cache, .{});
    try testing.expectEqual(if (admitted) passes.PassResult.success else .failure, result);
    if (admitted) {
        try ledger.producersComplete();
        try testing.expect(!ledger.view().missing_work_contract);
        try testing.expectEqual(@as(u64, 1), ledger.view().executed.counters.pass_runs);
        try fixture.check(module, constructor == 1 or constructor == 2);
    } else {
        try testing.expectEqual(.exhausted, ledger.view().outcome);
        try testing.expectEqual(@as(u64, 0), manager.stats.pass_runs);
    }
    if (!admitted or constructor == 0 or constructor == 3) {
        const after = try choir.bytecode.encodeModule(allocator, root);
        defer allocator.free(after);
        try testing.expectEqualSlices(u8, before, after);
    }
}

test "loss lowering accounts all constructors and no-op paths before mutation" {
    for (0..4) |constructor| {
        try checkLossAccounting(false, @intCast(constructor));
        try checkLossAccounting(true, @intCast(constructor));
    }
}

fn checkLossStorage(fixture: LossCase, lowered: bool) !void {
    const allocator = testing.allocator;
    const module = try fixture.module();
    defer module.deinit();
    const options = fixture.options();
    const bounds = try lossWork(.{ .operation = module.choir_module, .state = &options });
    const bytes = try allocator.alloc(u8, @intCast(bounds.workspace));
    defer allocator.free(bytes);
    var storage = @import("alloc_fixed").Tracked.init(bytes);
    var cache = passes.AnalysisCache.init(allocator, null);
    defer cache.deinit();
    var context = passes.PassContext.init(module.choir_module, module.context(), allocator, &cache);
    defer context.deinit();
    context.allocator = storage.allocator();
    defer context.allocator = allocator;
    const result = runLossLoweringWithOptions(&context, options);
    try testing.expect(!storage.exhausted);
    try testing.expectEqual(null, module.context().exhaustedSegment());
    try testing.expectEqual(.success, result);
    try testing.expect(storage.status().high_water_bytes <= bounds.workspace);
    try testing.expect(storage.status().high_water_bytes > 0);
    try fixture.check(module, lowered);
}

const loss_storage_cases = [_]LossCase{
    .{ .rows = 1, .classes = 1, .threads = 1 },
    .{},
    .{ .rows = 129, .classes = 1000, .threads = 128 },
    .{ .rows = std.math.maxInt(i32), .threads = std.math.maxInt(i32) },
    .{ .classes = std.math.maxInt(i32) },
};

test "loss lowering scratch covers family descriptors and repeated producers" {
    for (loss_storage_cases) |case| {
        for ([_]u32{ 1, 17 }) |copies| {
            var fixture = case;
            fixture.copies = copies;
            try checkLossStorage(fixture, true);
        }
    }
    try checkLossStorage(.{ .dtype = .f16 }, false);
    try checkLossStorage(.{ .threads = 0 }, false);
    try checkLossStorage(.{ .threads = 7 }, false);
}

test "loss lowering descriptor storage covers owned specialization and family" {
    const allocator = testing.allocator;
    for (loss_storage_cases) |case| {
        const bytes = try allocator.alloc(u8, @intCast(lossDescriptorStorage()));
        defer allocator.free(bytes);
        var storage = @import("alloc_fixed").Tracked.init(bytes);
        var selected = (try kernel_library.selectOwned(storage.allocator(), .{
            .row_sparse_cross_entropy = .{
                .dtype = .f32,
                .rows = case.rows,
                .classes = case.classes,
                .schedule = .{ .thread_blocks = case.threads },
            },
        })) orelse return error.TestExpectedDescriptor;
        defer selected.deinit();
        const instance = kernel_library.loss.rowSparseCrossEntropyInstanceFromSpecialization(
            selected.descriptor.metadata.specialization,
        ).?;
        try testing.expectEqual(@as(u64, case.rows), instance.rows);
        try testing.expectEqual(@as(u64, case.classes), instance.classes);
        try testing.expectEqual(case.threads, instance.threads);
        try testing.expect(!storage.exhausted);
        try testing.expect(storage.status().high_water_bytes <= bytes.len);
        try testing.expect(storage.status().high_water_bytes > 0);
    }
}

fn sparseCrossEntropyTestModule(allocator: std.mem.Allocator) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const logits_ty = try builder.tensor(.f32, &.{ 6, 11 });
    const targets_ty = try builder.tensor(.i32, &.{6});
    const losses_ty = try builder.tensor(.f32, &.{6});
    var fb = try builder.beginFunction(
        "loss_lowering_sparse_cross_entropy",
        &.{ logits_ty, targets_ty },
        &.{losses_ty},
    );
    const out = try fb.sparseCrossEntropy(fb.parameter(0), fb.parameter(1), losses_ty);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

test "loss lowering pass keeps sparse cross entropy generic without schedule" {
    const allocator = testing.allocator;

    const module = try sparseCrossEntropyTestModule(allocator);
    defer module.deinit();

    var options = Options{ .kernel_library = .enabled };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(lossLoweringPassWithOptions(&options));

    try testing.expectEqual(
        passes.PassResult.success,
        pm.run(module.choir_module, module.context()),
    );
    try module.verify();
    try testing.expectEqual(@as(usize, 1), ir.inspection.countOperationsNamed(
        module.choir_module,
        dialect_mod.AccyDialect.SparseCrossEntropyOp.operation_name,
    ));
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(
        module.choir_module,
        dialect_mod.AccyDialect.KernelCallOp.operation_name,
    ));
}

test "loss lowering pass selects scheduled row sparse cross entropy family" {
    const allocator = testing.allocator;

    const module = try sparseCrossEntropyTestModule(allocator);
    defer module.deinit();

    var options = Options{
        .kernel_library = .enabled,
        .row_sparse_cross_entropy_schedule = .{ .thread_blocks = 4 },
    };
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(lossLoweringPassWithOptions(&options));

    try testing.expectEqual(
        passes.PassResult.success,
        pm.run(module.choir_module, module.context()),
    );
    try module.verify();
    try testing.expectEqual(@as(usize, 0), ir.inspection.countOperationsNamed(
        module.choir_module,
        dialect_mod.AccyDialect.SparseCrossEntropyOp.operation_name,
    ));
    const kernel_call = ir.inspection.findOperationNamed(
        module.choir_module,
        dialect_mod.AccyDialect.KernelCallOp.operation_name,
    ) orelse {
        return error.TestExpectedKernelCall;
    };
    const target_attr = kernel_call.getAttr("target") orelse
        return error.TestExpectedKernelCallTarget;
    const target = target_attr.cast(ir.Attribute.DialectAttr) orelse
        return error.TestExpectedKernelCallTarget;
    try testing.expectEqualStrings(
        "accy.kernel.loss.row_sparse_cross_entropy_family_4_f32",
        target.payload,
    );
}
