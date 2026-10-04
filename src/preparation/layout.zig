const std = @import("std");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const bufferization = @import("bufferization/root.zig");
const accy_choir = @import("../choir/root.zig");
const dialect_mod = accy_choir.dialect;
const memory_space = @import("root.zig").memory;

const ir = choir.ir;
const passes = choir.passes;
const accounting = passes.pass.work;

pub const layout_plan_analysis_name = "accy-choir-layout-plan";
pub const layout_planning_pass_name = "accy-choir-plan-layouts";
pub const layout_planning_pass_description =
    "Plan Accy Choir buffer layouts before scheduling";

pub const LayoutKind = accy_choir.record.memory.LayoutKind;

pub const LayoutAssignment = struct {
    slot_id: usize,
    value: *ir.Value,
    producer: ?*ir.Operation,
    role: bufferization.BufferRole,
    dtype: gpu_abi.DType,
    memory_space: memory_space.MemorySpace,
    kind: LayoutKind,
    rank: usize,
    dims: []i64,
    element_strides: ?[]u64,
    minor_to_major: []usize,
    element_count: ?u64,
    byte_size: ?u64,
    element_size: u64,
    alignment: u64,
    contiguous: bool,
    static_layout: bool,

    fn init(
        allocator: std.mem.Allocator,
        slot: bufferization.BufferSlot,
        memory_assignment: memory_space.MemorySpaceAssignment,
    ) !LayoutAssignment {
        const dims = try allocator.dupe(i64, slot.dims);
        errdefer allocator.free(dims);

        var strides: ?[]u64 = null;
        if (slot.row_major_strides) |existing| {
            strides = try allocator.dupe(u64, existing);
            errdefer if (strides) |owned| allocator.free(owned);
        }

        const minor_to_major = try rowMajorMinorToMajorAlloc(allocator, slot.dims.len);
        errdefer allocator.free(minor_to_major);

        const kind = layoutKindForSlot(slot);
        return .{
            .slot_id = slot.id,
            .value = slot.value,
            .producer = slot.producer,
            .role = slot.role,
            .dtype = slot.dtype,
            .memory_space = memory_assignment.space,
            .kind = kind,
            .rank = slot.dims.len,
            .dims = dims,
            .element_strides = strides,
            .minor_to_major = minor_to_major,
            .element_count = slot.element_count,
            .byte_size = slot.byte_size,
            .element_size = @as(u64, slot.dtype.sizeOf()),
            .alignment = @as(u64, slot.dtype.alignOf()),
            .contiguous = true,
            .static_layout = kind.hasStaticStrides(),
        };
    }

    fn deinit(self: *LayoutAssignment, allocator: std.mem.Allocator) void {
        allocator.free(self.dims);
        if (self.element_strides) |strides| allocator.free(strides);
        allocator.free(self.minor_to_major);
        self.* = undefined;
    }

    pub fn hasStaticByteSize(self: LayoutAssignment) bool {
        return self.byte_size != null;
    }
};

pub const LayoutPlanAnalysis = struct {
    allocator: std.mem.Allocator,
    assignments: std.ArrayListUnmanaged(LayoutAssignment),
    slot_to_assignment: std.AutoHashMap(usize, usize),
    scalar_layout_count: usize = 0,
    row_major_layout_count: usize = 0,
    dynamic_row_major_layout_count: usize = 0,
    host_slot_count: usize = 0,
    device_global_slot_count: usize = 0,
    device_constant_slot_count: usize = 0,
    device_shared_slot_count: usize = 0,
    unified_slot_count: usize = 0,
    dynamic_slot_count: usize = 0,
    elided_value_count: usize = 0,
    total_static_bytes: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) LayoutPlanAnalysis {
        return .{
            .allocator = allocator,
            .assignments = .empty,
            .slot_to_assignment = std.AutoHashMap(usize, usize).init(allocator),
        };
    }

    pub fn deinit(self: *LayoutPlanAnalysis) void {
        for (self.assignments.items) |*assignment| {
            assignment.deinit(self.allocator);
        }
        self.assignments.deinit(self.allocator);
        self.slot_to_assignment.deinit();
        self.* = undefined;
    }

    pub fn assignmentCount(self: LayoutPlanAnalysis) usize {
        return self.assignments.items.len;
    }

    pub fn getAssignmentForSlot(
        self: *const LayoutPlanAnalysis,
        slot_id: usize,
    ) ?*const LayoutAssignment {
        const index = self.slot_to_assignment.get(slot_id) orelse return null;
        return &self.assignments.items[index];
    }

    pub fn getAssignmentForValue(
        self: *const LayoutPlanAnalysis,
        buffers: *const bufferization.BufferPlanAnalysis,
        value: *ir.Value,
    ) ?*const LayoutAssignment {
        const slot = buffers.getSlot(value) orelse return null;
        return self.getAssignmentForSlot(slot.id);
    }

    fn addAssignment(self: *LayoutPlanAnalysis, assignment: LayoutAssignment) !void {
        if (self.slot_to_assignment.contains(assignment.slot_id)) {
            return error.DuplicateLayoutAssignment;
        }
        const index = self.assignments.items.len;
        try self.slot_to_assignment.put(assignment.slot_id, index);
        errdefer _ = self.slot_to_assignment.remove(assignment.slot_id);
        try self.assignments.append(self.allocator, assignment);

        switch (assignment.kind) {
            .scalar => self.scalar_layout_count += 1,
            .row_major => self.row_major_layout_count += 1,
            .dynamic_row_major => self.dynamic_row_major_layout_count += 1,
        }
        switch (assignment.memory_space) {
            .host => self.host_slot_count += 1,
            .device_global => self.device_global_slot_count += 1,
            .device_constant => self.device_constant_slot_count += 1,
            .device_shared => self.device_shared_slot_count += 1,
            .unified => self.unified_slot_count += 1,
        }
        if (assignment.byte_size) |bytes| {
            self.total_static_bytes += bytes;
        } else {
            self.dynamic_slot_count += 1;
        }
    }
};

const LayoutWork = struct {
    input: accounting.Census,

    fn storage(self: LayoutWork) !u64 {
        var bytes: u64 = @sizeOf(LayoutPlanAnalysis) + @alignOf(LayoutPlanAnalysis);
        bytes = try accounting.add(
            bytes,
            try accounting.arrayListGrowth(LayoutAssignment, self.input.values),
        );
        bytes = try accounting.add(
            bytes,
            try accounting.hashMapGrowth(usize, usize, self.input.values),
        );
        const element = @sizeOf(i64) + @sizeOf(u64) + @sizeOf(usize);
        bytes = try accounting.add(bytes, try accounting.multiply(self.input.input_bytes, element));
        const alignment = @alignOf(i64) + @alignOf(u64) + @alignOf(usize);
        bytes = try accounting.add(bytes, try accounting.multiply(self.input.values, alignment));
        if (bytes > std.math.maxInt(usize)) return error.WorkOverflow;
        return bytes;
    }

    fn bounds(self: LayoutWork) !accounting.Bounds {
        const bytes = try self.storage();
        const input_units = try accounting.add(self.input.atoms, self.input.input_bytes);
        const units = try accounting.add(input_units, 1);
        const probes = try accounting.add(try accounting.hashMapCapacity(self.input.values), 1);
        const visits = try accounting.multiply(32, try accounting.multiply(units, probes));
        return .{
            .work = .{
                .input_bytes = self.input.input_bytes,
                .structural_visits = visits,
                .analysis_computations = 1,
                .allocation_capacity = bytes,
            },
            .workspace = bytes,
            .retained_storage = bytes,
        };
    }
};

fn layoutAnalysisWork(input: accounting.Input) !accounting.Bounds {
    return (LayoutWork{ .input = try accounting.Census.inspect(input.operation) }).bounds();
}

fn layoutPassWork(_: accounting.Input) !accounting.Bounds {
    return .{ .work = .{ .structural_visits = 1 } };
}

pub const layout_plan_analysis_descriptor = passes.AnalysisDescriptor{
    .id = passes.analysisId(layout_plan_analysis_name),
    .name = layout_plan_analysis_name,
    .work_contract = .{
        .identity = .{ .name = layout_plan_analysis_name, .version = 1 },
        .estimate = layoutAnalysisWork,
    },
};

pub fn getLayoutPlanAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) !*LayoutPlanAnalysis {
    const ptr = try pass_ctx.getAnalysis(
        op,
        &layout_plan_analysis_descriptor,
        computeLayoutPlanAnalysis,
        cleanupLayoutPlanAnalysis,
    );
    return @ptrCast(@alignCast(ptr));
}

pub fn layoutPlanningPass() passes.Pass {
    return .{
        .name = layout_planning_pass_name,
        .description = layout_planning_pass_description,
        .run_fn = runLayoutPlanningPass,
        .work_contract = .{
            .identity = .{ .name = layout_planning_pass_name, .version = 1 },
            .estimate = layoutPassWork,
        },
    };
}

fn runLayoutPlanningPass(pass_ctx: *passes.PassContext) passes.PassResult {
    _ = getLayoutPlanAnalysis(pass_ctx, pass_ctx.op) catch return .failure;
    pass_ctx.preserveAllAnalyses();
    return .success;
}

fn computeLayoutPlanAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) anyerror!*anyopaque {
    const buffers = try bufferization.getBufferPlanAnalysis(pass_ctx, op);
    const memory_plan = try memory_space.getMemorySpacePlanAnalysis(pass_ctx, op);

    const analysis = try pass_ctx.allocator.create(LayoutPlanAnalysis);
    analysis.* = LayoutPlanAnalysis.init(pass_ctx.allocator);
    errdefer {
        analysis.deinit();
        pass_ctx.allocator.destroy(analysis);
    }

    analysis.elided_value_count = buffers.elisionCount();
    for (buffers.slots.items) |slot| {
        const memory_assignment = memory_plan.getAssignmentForSlot(slot.id) orelse {
            return error.MissingMemorySpaceAssignment;
        };
        {
            var assignment = try LayoutAssignment.init(
                pass_ctx.allocator,
                slot,
                memory_assignment.*,
            );
            errdefer assignment.deinit(pass_ctx.allocator);
            try analysis.addAssignment(assignment);
        }
    }
    std.debug.assert(analysis.assignmentCount() == buffers.slotCount());
    std.debug.assert(analysis.total_static_bytes == buffers.total_static_bytes);

    return @ptrCast(analysis);
}

fn cleanupLayoutPlanAnalysis(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const analysis: *LayoutPlanAnalysis = @ptrCast(@alignCast(ptr));
    analysis.deinit();
    allocator.destroy(analysis);
}

fn layoutKindForSlot(slot: bufferization.BufferSlot) LayoutKind {
    if (slot.dims.len == 0) return .scalar;
    if (slot.element_count != null and slot.row_major_strides != null) return .row_major;
    return .dynamic_row_major;
}

fn rowMajorMinorToMajorAlloc(allocator: std.mem.Allocator, rank: usize) ![]usize {
    const order = try allocator.alloc(usize, rank);
    for (order, 0..) |*axis, index| {
        axis.* = rank - 1 - index;
    }
    return order;
}

const testing = std.testing;
const semantic = accy_choir.semantic;

fn findOpNamedInBlock(block: *ir.Block, name: []const u8) ?*ir.Operation {
    var iter = block.operations.head;
    while (iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (isName(op.name.name, name)) return op;
        iter = op.next_op;
    }
    return null;
}

fn isName(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
}

test "layout planning records row-major slot layouts" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_2x3 = try builder.tensor(.f32, &.{ 2, 3 });
    var fb = try builder.beginFunction("layout_add2x3", &.{ f32_2x3, f32_2x3 }, &.{f32_2x3});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try layoutTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 6);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const buffers = try bufferization.getBufferPlanAnalysis(&pass_ctx, choir_mod);
    const analysis = try getLayoutPlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkLayoutStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 3), analysis.assignmentCount());
    try testing.expectEqual(@as(usize, 3), analysis.row_major_layout_count);
    try testing.expectEqual(@as(usize, 3), analysis.device_global_slot_count);
    try testing.expectEqual(@as(usize, 0), analysis.dynamic_slot_count);
    try testing.expectEqual(@as(u64, 72), analysis.total_static_bytes);

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "layout_add2x3") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const add = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.AddOp.operation_name,
    ) orelse return error.TestExpectedAdd;
    const output = analysis.getAssignmentForValue(buffers, add.getResult(0).?) orelse
        return error.TestExpectedAssignment;
    try testing.expectEqual(LayoutKind.row_major, output.kind);
    try testing.expectEqual(memory_space.MemorySpace.device_global, output.memory_space);
    try testing.expectEqual(@as(usize, 2), output.rank);
    try testing.expectEqualSlices(i64, &.{ 2, 3 }, output.dims);
    try testing.expectEqualSlices(u64, &.{ 3, 1 }, output.element_strides.?);
    try testing.expectEqualSlices(usize, &.{ 1, 0 }, output.minor_to_major);
    try testing.expectEqual(@as(?u64, 6), output.element_count);
    try testing.expectEqual(@as(?u64, 24), output.byte_size);
    try testing.expectEqual(@as(u64, 4), output.element_size);
    try testing.expectEqual(@as(u64, 4), output.alignment);
    try testing.expect(output.contiguous);
    try testing.expect(output.static_layout);
}

test "layout planning records constant memory layouts" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const i32_4 = try builder.tensor(.i32, &.{4});
    var fb = try builder.beginFunction("layout_const_add", &.{i32_4}, &.{i32_4});
    const values = [_]i32{ 1, 2, 3, 4 };
    const c = try fb.constant(i32_4, std.mem.sliceAsBytes(values[0..]));
    const sum = try fb.add(fb.parameter(0), c);
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try layoutTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 6);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const buffers = try bufferization.getBufferPlanAnalysis(&pass_ctx, choir_mod);
    const analysis = try getLayoutPlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkLayoutStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 3), analysis.assignmentCount());
    try testing.expectEqual(@as(usize, 2), analysis.device_global_slot_count);
    try testing.expectEqual(@as(usize, 1), analysis.device_constant_slot_count);
    try testing.expectEqual(@as(u64, 48), analysis.total_static_bytes);

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "layout_const_add") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const constant = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.ConstantOp.operation_name,
    ) orelse return error.TestExpectedConstant;
    const assignment = analysis.getAssignmentForValue(buffers, constant.getResult(0).?) orelse
        return error.TestExpectedAssignment;
    try testing.expectEqual(LayoutKind.row_major, assignment.kind);
    try testing.expectEqual(memory_space.MemorySpace.device_constant, assignment.memory_space);
    try testing.expectEqualSlices(i64, &.{4}, assignment.dims);
    try testing.expectEqualSlices(u64, &.{1}, assignment.element_strides.?);
    try testing.expectEqualSlices(usize, &.{0}, assignment.minor_to_major);
    try testing.expectEqual(@as(?u64, 16), assignment.byte_size);
}

test "layout planning records fusion elisions without layouts" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction(
        "layout_fused_add_mul",
        &.{ f32_4, f32_4, f32_4 },
        &.{f32_4},
    );
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    const product = try fb.mul(sum, fb.parameter(2));
    try fb.return_(&.{product});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try layoutTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 6);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const buffers = try bufferization.getBufferPlanAnalysis(&pass_ctx, choir_mod);
    const analysis = try getLayoutPlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkLayoutStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 4), analysis.assignmentCount());
    try testing.expectEqual(@as(usize, 1), analysis.elided_value_count);
    try testing.expectEqual(@as(usize, 4), analysis.device_global_slot_count);

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "layout_fused_add_mul") orelse
        return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const add = findOpNamedInBlock(
        entry,
        dialect_mod.AccyDialect.AddOp.operation_name,
    ) orelse return error.TestExpectedAdd;
    try testing.expect(buffers.getSlot(add.getResult(0).?) == null);
    try testing.expect(analysis.getAssignmentForValue(buffers, add.getResult(0).?) == null);
}

test "layout planning pass preserves IR" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("layout_pass_add4", &.{ f32_4, f32_4 }, &.{f32_4});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(layoutPlanningPass());

    const ledger = try choir.product.revision.AccountingV1.create(allocator, .{
        .allowance = choir.product.revision.WorkVector.uniform(std.math.maxInt(u64)),
        .workspace = std.math.maxInt(u64),
        .events = 14,
    }, &.{.{ .name = layout_planning_pass_name, .version = 1 }});
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 6);
    defer cache.deinit();
    try testing.expectEqual(
        passes.PassResult.success,
        pm.runWithAnalysisCache(choir_mod, ctx, &cache, .{}),
    );
    try ledger.producersComplete();
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

fn layoutTestLedger() !*choir.product.revision.AccountingV1 {
    const revision = choir.product.revision;
    return revision.AccountingV1.create(testing.allocator, .{
        .allowance = revision.WorkVector.uniform(std.math.maxInt(u64)),
        .workspace = std.math.maxInt(u64),
        .events = 14,
    }, &.{});
}

fn checkLayoutStorage(
    op: *ir.Operation,
    ctx: *ir.Context,
    cache: *passes.AnalysisCache,
    expected: *const LayoutPlanAnalysis,
) !void {
    const bounds = try layoutAnalysisWork(.{ .operation = op });
    const fixed = @import("alloc_fixed");
    const bytes = try testing.allocator.alignedAlloc(u8, .@"64", @intCast(bounds.workspace));
    defer testing.allocator.free(bytes);
    var storage = fixed.Tracked.init(bytes);
    var retained = fixed.Monotonic.init(storage.allocator(), @max(1, bytes.len));
    const allocator = retained.allocator();
    var pass_ctx = passes.PassContext.init(op, ctx, allocator, cache);
    defer pass_ctx.deinit();
    const ptr = try computeLayoutPlanAnalysis(&pass_ctx, op);
    defer cleanupLayoutPlanAnalysis(ptr, allocator);
    const actual: *LayoutPlanAnalysis = @ptrCast(@alignCast(ptr));
    inline for (.{
        "scalar_layout_count",      "row_major_layout_count",   "dynamic_row_major_layout_count",
        "host_slot_count",          "device_global_slot_count", "device_constant_slot_count",
        "device_shared_slot_count", "unified_slot_count",       "dynamic_slot_count",
        "elided_value_count",       "total_static_bytes",
    }) |field| try testing.expectEqual(@field(expected, field), @field(actual, field));
    try testing.expectEqual(expected.assignmentCount(), actual.assignmentCount());
    for (expected.assignments.items, actual.assignments.items) |left, right| {
        inline for (.{
            "slot_id",       "value",        "producer",  "dtype",
            "memory_space",  "kind",         "rank",      "element_count",
            "byte_size",     "element_size", "alignment", "contiguous",
            "static_layout",
        }) |field| try testing.expectEqual(@field(left, field), @field(right, field));
        try testing.expectEqualDeep(left.role, right.role);
        try testing.expectEqualSlices(i64, left.dims, right.dims);
        try testing.expectEqualSlices(usize, left.minor_to_major, right.minor_to_major);
        if (left.element_strides) |strides| {
            try testing.expectEqualSlices(u64, strides, right.element_strides.?);
        } else try testing.expect(right.element_strides == null);
        try testing.expectEqual(right.value, actual.getAssignmentForSlot(right.slot_id).?.value);
    }
    try testing.expectEqual(expected.slot_to_assignment.count(), actual.slot_to_assignment.count());
    try testing.expect(!storage.exhausted);
    const used = if (retained.current) |*current| fixed.used(current) else 0;
    try testing.expect(used <= bounds.workspace);
    try testing.expect(used >= @sizeOf(LayoutPlanAnalysis));
}

test "layout planning work contract covers slot growth and layout dimensions" {
    const high_rank: [512]i64 = @splat(1);
    for ([_]usize{ 0, 1, 6, 7, 16, 64 }) |count| {
        try checkLayoutBoundary(count, &.{}, .scalar, false);
        try checkLayoutBoundary(count, &.{ 2, 3 }, .row_major, false);
        try checkLayoutBoundary(count, &high_rank, .row_major, false);
        try checkLayoutBoundary(count, &.{ -1, 3 }, .dynamic_row_major, true);
        try checkLayoutBoundary(count, &.{ std.math.maxInt(i64), 3 }, .dynamic_row_major, true);
        try checkLayoutBoundary(count, &.{std.math.maxInt(i64)}, .row_major, true);
    }
    try testing.expectError(error.WorkOverflow, (LayoutWork{
        .input = .{ .values = std.math.maxInt(u64) },
    }).bounds());
    try testing.expectError(error.WorkOverflow, (LayoutWork{
        .input = .{ .input_bytes = std.math.maxInt(u64) },
    }).bounds());
    try testing.expectError(error.WorkOverflow, (LayoutWork{
        .input = .{ .atoms = std.math.maxInt(u64) },
    }).bounds());
}

fn checkLayoutBoundary(
    count: usize,
    dims: []const i64,
    kind: LayoutKind,
    unknown_bytes: bool,
) !void {
    std.debug.assert(count <= 64);
    var context_limits = semantic.Builder.ContextLimits.standard;
    context_limits.transient_bytes = 2 * 1024 * 1024;
    var builder = try semantic.Builder.init(testing.allocator, context_limits);
    defer builder.deinit();
    const typ = try builder.tensor(.f32, dims);
    var types: [64]@TypeOf(typ) = @splat(typ);
    var function = try builder.beginFunction("layout_boundary", types[0..count], types[0..count]);
    var values: [64]@TypeOf(function.parameter(0)) = undefined;
    for (values[0..count], 0..) |*value, index| value.* = function.parameter(index);
    try function.return_(values[0..count]);
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    const ledger = try layoutTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(testing.allocator, null, ledger, .{}, 6);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer pass_ctx.deinit();
    const analysis = try getLayoutPlanAnalysis(&pass_ctx, module.choir_module);
    try ledger.producersComplete();
    try testing.expectEqual(count, analysis.assignmentCount());
    try testing.expectEqual(if (unknown_bytes) count else 0, analysis.dynamic_slot_count);
    for (analysis.assignments.items, 0..) |assignment, index| {
        try testing.expectEqual(index, assignment.slot_id);
        try testing.expectEqual(values[index], assignment.value);
        try testing.expectEqual(kind, assignment.kind);
        try testing.expectEqual(dims.len, assignment.rank);
        try testing.expectEqualSlices(i64, dims, assignment.dims);
        try testing.expectEqual(dims.len, assignment.minor_to_major.len);
        for (assignment.minor_to_major, 0..) |axis, position| {
            try testing.expectEqual(dims.len - position - 1, axis);
        }
    }
    try checkLayoutStorage(module.choir_module, module.context(), &cache, analysis);
    try checkLayoutAdmission(module.choir_module, module.context());
}

fn checkLayoutAdmission(op: *ir.Operation, ctx: *ir.Context) !void {
    const revision = choir.product.revision;
    const preparation = @import("root.zig");
    var charge: u64 = 1;
    for ([_]passes.AnalysisDescriptor{
        preparation.shape.shape_layout_analysis_descriptor,
        preparation.fusion.fusion_plan_analysis_descriptor,
        preparation.schedule.schedule_plan_analysis_descriptor,
        bufferization.buffer_plan_analysis_descriptor,
        memory_space.memory_space_plan_analysis_descriptor,
        layout_plan_analysis_descriptor,
    }) |descriptor| {
        const bounds = try descriptor.work_contract.?.estimate(.{ .operation = op });
        charge = try accounting.add(charge, bounds.work.structural_visits);
    }
    for ([_]i8{ -1, 0, 1 }) |offset| {
        var allowance = revision.WorkVector.uniform(std.math.maxInt(u64));
        allowance.structural_visits = @intCast(@as(i128, charge) + offset);
        const ledger = try revision.AccountingV1.create(testing.allocator, .{
            .allowance = allowance,
            .workspace = std.math.maxInt(u64),
            .events = 14,
        }, &.{.{ .name = layout_planning_pass_name, .version = 1 }});
        defer ledger.destroy();
        var cache = try passes.AnalysisCache.initAccounted(
            testing.allocator,
            null,
            ledger,
            .{},
            6,
        );
        defer cache.deinit();
        var manager = passes.PassManager.init(testing.allocator);
        defer manager.deinit();
        try manager.addPass(layoutPlanningPass());
        const result = manager.runWithAnalysisCache(op, ctx, &cache, .{});
        if (offset < 0) {
            try testing.expectEqual(passes.PassResult.failure, result);
            try testing.expectEqual(revision.receipt.Outcome.exhausted, ledger.view().outcome);
            try testing.expectEqual(@as(usize, 3), cache.entries.count());
        } else {
            try testing.expectEqual(passes.PassResult.success, result);
            try ledger.producersComplete();
            try testing.expectEqual(@as(usize, 6), cache.entries.count());
        }
    }
}
