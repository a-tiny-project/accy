const std = @import("std");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const accy_choir = @import("../../choir/root.zig");
const dialect_mod = accy_choir.dialect;
const fusion = @import("../fusion/root.zig");
const shape_analysis = @import("../shape/root.zig");

const ir = choir.ir;
const passes = choir.passes;
const accounting = passes.pass.work;

pub const buffer_plan_analysis_name = "accy-choir-buffer-plan";
pub const bufferization_planning_pass_name = "accy-choir-plan-buffers";
pub const bufferization_planning_pass_description =
    "Plan Accy Choir tensor buffer slots before lowering";

pub const BufferRole = accy_choir.record.memory.BufferRole;

pub const BufferSlot = struct {
    id: usize,
    value: *ir.Value,
    producer: ?*ir.Operation,
    function: ?*ir.Operation,
    role: BufferRole,
    dtype: gpu_abi.DType,
    dims: []i64,
    element_count: ?u64,
    row_major_strides: ?[]u64,
    byte_size: ?u64,

    fn init(
        allocator: std.mem.Allocator,
        id: usize,
        value: *ir.Value,
        producer: ?*ir.Operation,
        function: ?*ir.Operation,
        role: BufferRole,
        info: shape_analysis.TensorInfo,
    ) !BufferSlot {
        const dims = try allocator.dupe(i64, info.dims);
        errdefer allocator.free(dims);

        var strides: ?[]u64 = null;
        if (info.row_major_strides) |existing| {
            strides = try allocator.dupe(u64, existing);
            errdefer if (strides) |owned| allocator.free(owned);
        }

        return .{
            .id = id,
            .value = value,
            .producer = producer,
            .function = function,
            .role = role,
            .dtype = info.dtype,
            .dims = dims,
            .element_count = info.element_count,
            .row_major_strides = strides,
            .byte_size = byteSize(info),
        };
    }

    pub fn hasStaticSize(self: BufferSlot) bool {
        return self.byte_size != null;
    }

    fn deinit(self: *BufferSlot, allocator: std.mem.Allocator) void {
        allocator.free(self.dims);
        if (self.row_major_strides) |strides| allocator.free(strides);
        self.* = undefined;
    }
};

pub const FusionElision = struct {
    value: *ir.Value,
    producer: *ir.Operation,
    root: *ir.Operation,
    cluster_index: usize,
};

pub const BufferPlanAnalysis = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayListUnmanaged(BufferSlot),
    elisions: std.ArrayListUnmanaged(FusionElision),
    value_to_slot: std.AutoHashMap(*ir.Value, usize),
    value_to_elision: std.AutoHashMap(*ir.Value, usize),
    input_slot_count: usize = 0,
    output_slot_count: usize = 0,
    temporary_slot_count: usize = 0,
    constant_slot_count: usize = 0,
    dynamic_slot_count: usize = 0,
    total_static_bytes: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) BufferPlanAnalysis {
        return .{
            .allocator = allocator,
            .slots = .empty,
            .elisions = .empty,
            .value_to_slot = std.AutoHashMap(*ir.Value, usize).init(allocator),
            .value_to_elision = std.AutoHashMap(*ir.Value, usize).init(allocator),
        };
    }

    pub fn deinit(self: *BufferPlanAnalysis) void {
        for (self.slots.items) |*slot| {
            slot.deinit(self.allocator);
        }
        self.slots.deinit(self.allocator);
        self.elisions.deinit(self.allocator);
        self.value_to_slot.deinit();
        self.value_to_elision.deinit();
        self.* = undefined;
    }

    pub fn slotCount(self: BufferPlanAnalysis) usize {
        return self.slots.items.len;
    }

    pub fn elisionCount(self: BufferPlanAnalysis) usize {
        return self.elisions.items.len;
    }

    pub fn getSlot(self: *const BufferPlanAnalysis, value: *ir.Value) ?*const BufferSlot {
        const index = self.value_to_slot.get(value) orelse return null;
        return &self.slots.items[index];
    }

    pub fn getElision(self: *const BufferPlanAnalysis, value: *ir.Value) ?*const FusionElision {
        const index = self.value_to_elision.get(value) orelse return null;
        return &self.elisions.items[index];
    }

    fn addSlot(
        self: *BufferPlanAnalysis,
        value: *ir.Value,
        producer: ?*ir.Operation,
        function: ?*ir.Operation,
        role: BufferRole,
        info: shape_analysis.TensorInfo,
    ) !usize {
        if (self.value_to_slot.get(value)) |existing| return existing;

        const total_bytes = try accounting.add(self.total_static_bytes, byteSize(info) orelse 0);
        const id = self.slots.items.len;
        var slot = try BufferSlot.init(
            self.allocator,
            id,
            value,
            producer,
            function,
            role,
            info,
        );
        errdefer slot.deinit(self.allocator);

        try self.value_to_slot.put(value, id);
        errdefer _ = self.value_to_slot.remove(value);
        try self.slots.append(self.allocator, slot);

        if (role.input) self.input_slot_count += 1;
        if (role.output) self.output_slot_count += 1;
        if (role.temporary) self.temporary_slot_count += 1;
        if (role.constant) self.constant_slot_count += 1;
        self.total_static_bytes = total_bytes;
        if (slot.byte_size == null) self.dynamic_slot_count += 1;
        return id;
    }

    fn addAlias(
        self: *BufferPlanAnalysis,
        value: *ir.Value,
        source: *ir.Value,
        role: BufferRole,
    ) !usize {
        if (self.value_to_slot.get(value)) |existing| return existing;

        const id = self.value_to_slot.get(source) orelse return error.MissingAliasedBufferSlot;
        try self.value_to_slot.put(value, id);
        self.mergeSlotRole(id, role);
        return id;
    }

    fn mergeSlotRole(self: *BufferPlanAnalysis, id: usize, role: BufferRole) void {
        var slot = &self.slots.items[id];
        if (role.input and !slot.role.input) {
            slot.role.input = true;
            self.input_slot_count += 1;
        }
        if (role.output and !slot.role.output) {
            slot.role.output = true;
            self.output_slot_count += 1;
        }
        if (role.constant and !slot.role.constant) {
            slot.role.constant = true;
            self.constant_slot_count += 1;
        }
        if (role.temporary and !slot.role.temporary and !slot.role.input and !slot.role.output and !slot.role.constant) {
            slot.role.temporary = true;
            self.temporary_slot_count += 1;
        }
        if ((slot.role.input or slot.role.output or slot.role.constant) and slot.role.temporary) {
            slot.role.temporary = false;
            self.temporary_slot_count -= 1;
        }
    }

    fn addElision(self: *BufferPlanAnalysis, elision: FusionElision) !void {
        if (self.value_to_elision.contains(elision.value)) return;
        const index = self.elisions.items.len;
        try self.value_to_elision.put(elision.value, index);
        errdefer _ = self.value_to_elision.remove(elision.value);
        try self.elisions.append(self.allocator, elision);
    }
};

const BufferWork = struct {
    input: accounting.Census,

    fn storage(self: BufferWork) !u64 {
        const count = self.input.values;
        var bytes: u64 = @sizeOf(BufferPlanAnalysis) + @alignOf(BufferPlanAnalysis);
        bytes = try accounting.add(bytes, try accounting.arrayListGrowth(BufferSlot, count));
        bytes = try accounting.add(bytes, try accounting.arrayListGrowth(FusionElision, count));
        const index = try accounting.hashMapGrowth(*ir.Value, usize, count);
        bytes = try accounting.add(bytes, try accounting.multiply(2, index));
        bytes = try accounting.add(
            bytes,
            try accounting.hashMapGrowth(*ir.Value, void, self.input.operands),
        );
        bytes = try accounting.add(
            bytes,
            try accounting.hashMapGrowth(*ir.Value, FusionElision, self.input.operations),
        );
        const copies = try accounting.multiply(self.input.input_bytes, 2 * @sizeOf(u64));
        bytes = try accounting.add(bytes, copies);
        bytes = try accounting.add(bytes, try accounting.multiply(count, 2 * @alignOf(u64)));
        if (bytes > std.math.maxInt(usize)) return error.WorkOverflow;
        return bytes;
    }

    fn bounds(self: BufferWork) !accounting.Bounds {
        const bytes = try self.storage();
        const input_units = try accounting.add(self.input.atoms, self.input.input_bytes);
        const units = try accounting.add(input_units, 1);
        const operations = self.input.operations;
        const copies = try accounting.multiply(7, try accounting.multiply(operations, operations));
        const scans = try accounting.add(try accounting.add(copies, operations), units);
        const entries = try accounting.add(
            operations,
            try accounting.add(self.input.values, self.input.operands),
        );
        const inner = try accounting.add(try accounting.hashMapCapacity(entries), units);
        const visits = try accounting.multiply(64, try accounting.multiply(scans, inner));
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

fn bufferAnalysisWork(input: accounting.Input) !accounting.Bounds {
    return (BufferWork{ .input = try accounting.Census.inspect(input.operation) }).bounds();
}

fn bufferPassWork(_: accounting.Input) !accounting.Bounds {
    return .{ .work = .{ .structural_visits = 1 } };
}

pub const buffer_plan_analysis_descriptor = passes.AnalysisDescriptor{
    .id = passes.analysisId(buffer_plan_analysis_name),
    .name = buffer_plan_analysis_name,
    .work_contract = .{
        .identity = .{ .name = buffer_plan_analysis_name, .version = 1 },
        .estimate = bufferAnalysisWork,
    },
};

pub fn getBufferPlanAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) !*BufferPlanAnalysis {
    const ptr = try pass_ctx.getAnalysis(
        op,
        &buffer_plan_analysis_descriptor,
        computeBufferPlanAnalysis,
        cleanupBufferPlanAnalysis,
    );
    return @ptrCast(@alignCast(ptr));
}

pub fn bufferizationPlanningPass() passes.Pass {
    return .{
        .name = bufferization_planning_pass_name,
        .description = bufferization_planning_pass_description,
        .run_fn = runBufferizationPlanningPass,
        .work_contract = .{
            .identity = .{ .name = bufferization_planning_pass_name, .version = 1 },
            .estimate = bufferPassWork,
        },
    };
}

fn runBufferizationPlanningPass(pass_ctx: *passes.PassContext) passes.PassResult {
    _ = getBufferPlanAnalysis(pass_ctx, pass_ctx.op) catch return .failure;
    pass_ctx.preserveAllAnalyses();
    return .success;
}

fn computeBufferPlanAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) anyerror!*anyopaque {
    const shapes = try shape_analysis.getShapeLayoutAnalysis(pass_ctx, op);
    const fusion_plan = try fusion.getFusionPlanAnalysis(pass_ctx, op);

    const analysis = try pass_ctx.allocator.create(BufferPlanAnalysis);
    analysis.* = BufferPlanAnalysis.init(pass_ctx.allocator);
    errdefer {
        analysis.deinit();
        pass_ctx.allocator.destroy(analysis);
    }

    var returned = std.AutoHashMap(*ir.Value, void).init(pass_ctx.allocator);
    defer returned.deinit();
    try collectReturnedValues(op, &returned);

    var elided_values = std.AutoHashMap(*ir.Value, FusionElision).init(pass_ctx.allocator);
    defer elided_values.deinit();
    try collectFusionElisions(fusion_plan, &elided_values);

    try collectBufferSlots(
        op,
        null,
        shapes,
        &returned,
        &elided_values,
        analysis,
    );

    return @ptrCast(analysis);
}

fn cleanupBufferPlanAnalysis(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const analysis: *BufferPlanAnalysis = @ptrCast(@alignCast(ptr));
    analysis.deinit();
    allocator.destroy(analysis);
}

fn collectReturnedValues(
    op: *ir.Operation,
    returned: *std.AutoHashMap(*ir.Value, void),
) !void {
    if (isReturnOp(op)) {
        for (op.getOperandValues()) |value| {
            try returned.put(value, {});
        }
    }

    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                try collectReturnedValues(current_op, returned);
                current = current_op.next_op;
            }
        }
    }
}

fn collectFusionElisions(
    fusion_plan: *const fusion.FusionPlanAnalysis,
    elided_values: *std.AutoHashMap(*ir.Value, FusionElision),
) !void {
    for (fusion_plan.clusters.items, 0..) |cluster, cluster_index| {
        const root = cluster.root() orelse continue;
        if (cluster.ops.len < 2) continue;
        for (cluster.ops[0 .. cluster.ops.len - 1]) |producer| {
            const value = producer.getResult(0) orelse continue;
            try elided_values.put(value, .{
                .value = value,
                .producer = producer,
                .root = root,
                .cluster_index = cluster_index,
            });
        }
    }

    for (fusion_plan.elided.items) |producer| {
        const value = producer.getResult(0) orelse continue;
        try elided_values.put(value, .{
            .value = value,
            .producer = producer,
            .root = producer,
            .cluster_index = fusion_plan.clusters.items.len,
        });
    }
}

fn collectBufferSlots(
    op: *ir.Operation,
    current_function: ?*ir.Operation,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    returned: *const std.AutoHashMap(*ir.Value, void),
    elided_values: *const std.AutoHashMap(*ir.Value, FusionElision),
    analysis: *BufferPlanAnalysis,
) !void {
    const function = if (isFuncOp(op)) op else current_function;

    if (!isFuncOp(op)) {
        for (op.results.items, 0..) |*result, result_index| {
            try recordTensorValue(
                result,
                op,
                function,
                false,
                result_index,
                shapes,
                returned,
                elided_values,
                analysis,
            );
        }
    }

    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            for (block.arguments.items) |arg| {
                try recordTensorValue(
                    arg,
                    null,
                    function,
                    isFunctionEntryBlock(function, block),
                    null,
                    shapes,
                    returned,
                    elided_values,
                    analysis,
                );
            }
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                try collectBufferSlots(
                    current_op,
                    function,
                    shapes,
                    returned,
                    elided_values,
                    analysis,
                );
                current = current_op.next_op;
            }
        }
    }
}

fn recordTensorValue(
    value: *ir.Value,
    producer: ?*ir.Operation,
    function: ?*ir.Operation,
    is_function_argument: bool,
    producer_result_index: ?usize,
    shapes: *const shape_analysis.ShapeLayoutAnalysis,
    returned: *const std.AutoHashMap(*ir.Value, void),
    elided_values: *const std.AutoHashMap(*ir.Value, FusionElision),
    analysis: *BufferPlanAnalysis,
) !void {
    const info = shapes.get(value) orelse return;
    if (producer) |op| {
        if (producer_result_index) |result_index| {
            if (try aliasedOperandValueForResult(op, result_index)) |source| {
                _ = try analysis.addAlias(
                    value,
                    source,
                    roleForAliasedResult(value, returned),
                );
                return;
            }
        }
    }

    if (!returned.contains(value)) {
        if (elided_values.get(value)) |elision| {
            try analysis.addElision(elision);
            return;
        }
    }

    _ = try analysis.addSlot(
        value,
        producer,
        function,
        roleForValue(value, producer, returned, is_function_argument),
        info,
    );
}

fn roleForAliasedResult(
    value: *ir.Value,
    returned: *const std.AutoHashMap(*ir.Value, void),
) BufferRole {
    var role = BufferRole{};
    if (returned.contains(value)) role.output = true;
    return role;
}

fn aliasedOperandValueForResult(producer: *ir.Operation, result_index: usize) !?*ir.Value {
    if (!isName(producer.name.name, dialect_mod.AccyDialect.KernelCallOp.operation_name)) return null;
    const attr = producer.getAttr("result_aliases") orelse return error.InvalidKernelContract;
    if (!std.mem.eql(u8, attr.abstract.name, dialect_mod.AccyDialect.KernelCallOp.result_aliases_attr_name)) {
        return error.InvalidKernelContract;
    }
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return error.InvalidKernelContract;
    if (dialect_attr.payload.len % @sizeOf(i64) != 0) return error.InvalidKernelContract;

    const alias_count = dialect_attr.payload.len / @sizeOf(i64);
    if (alias_count != producer.getNumResults()) return error.InvalidKernelContract;
    if (result_index >= alias_count) return error.InvalidKernelContract;

    var alias_value: i64 = undefined;
    const start = result_index * @sizeOf(i64);
    @memcpy(std.mem.asBytes(&alias_value), dialect_attr.payload[start..][0..@sizeOf(i64)]);
    if (alias_value == -1) return null;
    if (alias_value < 0) return error.InvalidKernelContract;

    const operand_index: usize = @intCast(alias_value);
    return producer.getOperand(operand_index) orelse error.InvalidKernelContract;
}

fn roleForValue(
    value: *ir.Value,
    producer: ?*ir.Operation,
    returned: *const std.AutoHashMap(*ir.Value, void),
    is_function_argument: bool,
) BufferRole {
    var role = BufferRole{};
    if (is_function_argument) role.input = true;
    if (returned.contains(value)) role.output = true;
    if (producer) |op| {
        if (isName(op.name.name, dialect_mod.AccyDialect.ConstantOp.operation_name)) {
            role.constant = true;
        }
    }
    if (!role.input and !role.output and !role.constant) {
        role.temporary = true;
    }
    return role;
}

fn isFunctionEntryBlock(function: ?*ir.Operation, block: *ir.Block) bool {
    const func = function orelse return false;
    if (!isFuncOp(func)) return false;
    const region = func.getRegion(0) orelse return false;
    const entry = region.getEntryBlock() orelse return false;
    return entry == block;
}

fn byteSize(info: shape_analysis.TensorInfo) ?u64 {
    const elements = info.element_count orelse return null;
    return std.math.mul(u64, elements, @as(u64, info.dtype.sizeOf())) catch null;
}

fn isFuncOp(op: *ir.Operation) bool {
    return isName(op.name.name, "func.func");
}

fn isReturnOp(op: *ir.Operation) bool {
    return isName(op.name.name, "func.return") or
        isName(op.name.name, dialect_mod.AccyDialect.ReturnOp.operation_name);
}

fn isName(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
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

test "bufferization planning records function boundary slots" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("buffer_add4", &.{ f32_4, f32_4 }, &.{f32_4});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try bufferTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const analysis = try getBufferPlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkBufferStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 3), analysis.slotCount());
    try testing.expectEqual(@as(usize, 2), analysis.input_slot_count);
    try testing.expectEqual(@as(usize, 1), analysis.output_slot_count);
    try testing.expectEqual(@as(usize, 0), analysis.temporary_slot_count);
    try testing.expectEqual(@as(usize, 0), analysis.elisionCount());
    try testing.expectEqual(@as(u64, 48), analysis.total_static_bytes);

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "buffer_add4") orelse return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const add = findOpNamedInBlock(entry, dialect_mod.AccyDialect.AddOp.operation_name) orelse return error.TestExpectedAdd;
    const add_slot = analysis.getSlot(add.getResult(0).?) orelse return error.TestExpectedSlot;
    try testing.expect(add_slot.role.output);
    try testing.expect(!add_slot.role.temporary);
    try testing.expectEqual(@as(?u64, 16), add_slot.byte_size);
    try testing.expectEqualSlices(i64, &.{4}, add_slot.dims);
    try testing.expectEqualSlices(u64, &.{1}, add_slot.row_major_strides.?);
}

test "bufferization planning elides fusion-internal tensor values" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("buffer_fused_add_mul", &.{ f32_4, f32_4, f32_4 }, &.{f32_4});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    const product = try fb.mul(sum, fb.parameter(2));
    try fb.return_(&.{product});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try bufferTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "buffer_fused_add_mul") orelse return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const add = findOpNamedInBlock(entry, dialect_mod.AccyDialect.AddOp.operation_name) orelse return error.TestExpectedAdd;
    const mul = findOpNamedInBlock(entry, dialect_mod.AccyDialect.MulOp.operation_name) orelse return error.TestExpectedMul;

    const analysis = try getBufferPlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkBufferStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 4), analysis.slotCount());
    try testing.expectEqual(@as(usize, 3), analysis.input_slot_count);
    try testing.expectEqual(@as(usize, 1), analysis.output_slot_count);
    try testing.expectEqual(@as(usize, 1), analysis.elisionCount());
    try testing.expectEqual(@as(u64, 64), analysis.total_static_bytes);
    try testing.expect(analysis.getSlot(add.getResult(0).?) == null);

    const elision = analysis.getElision(add.getResult(0).?) orelse return error.TestExpectedElision;
    try testing.expectEqual(add, elision.producer);
    try testing.expectEqual(mul, elision.root);

    const root_slot = analysis.getSlot(mul.getResult(0).?) orelse return error.TestExpectedRootSlot;
    try testing.expect(root_slot.role.output);
}

test "bufferization planning coalesces aliased kernel call results" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("buffer_kernel_alias", &.{f32_4}, &.{f32_4});
    const call = try fb.kernelCall(&.{fb.parameter(0)}, &.{f32_4}, .{
        .target = "update_f32",
        .operand_effects = &.{.read_write},
        .result_aliases = &.{0},
    });
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try bufferTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "buffer_kernel_alias") orelse return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const call_op = findOpNamedInBlock(entry, dialect_mod.AccyDialect.KernelCallOp.operation_name) orelse return error.TestExpectedKernelCall;

    const analysis = try getBufferPlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkBufferStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 1), analysis.slotCount());
    try testing.expectEqual(@as(usize, 1), analysis.input_slot_count);
    try testing.expectEqual(@as(usize, 1), analysis.output_slot_count);
    try testing.expectEqual(@as(usize, 0), analysis.temporary_slot_count);
    try testing.expectEqual(@as(u64, 16), analysis.total_static_bytes);

    const input_value = entry.getArgument(0).?;
    const input_slot = analysis.getSlot(input_value) orelse return error.TestExpectedInputSlot;
    const result_slot = analysis.getSlot(call_op.getResult(0).?) orelse return error.TestExpectedResultSlot;
    try testing.expectEqual(input_slot.id, result_slot.id);
    try testing.expect(input_slot.role.input);
    try testing.expect(input_slot.role.output);
    try testing.expect(!input_slot.role.temporary);
}

test "bufferization planning keeps non-returned aliased results internal" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("buffer_kernel_alias_internal", &.{ f32_4, f32_4 }, &.{f32_4});
    const call = try fb.kernelCall(&.{fb.parameter(0)}, &.{f32_4}, .{
        .target = "update_f32",
        .operand_effects = &.{.read_write},
        .result_aliases = &.{0},
    });
    const sum = try fb.add(call.getFirstResult(), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try bufferTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "buffer_kernel_alias_internal") orelse return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const call_op = findOpNamedInBlock(entry, dialect_mod.AccyDialect.KernelCallOp.operation_name) orelse return error.TestExpectedKernelCall;
    const add_op = findOpNamedInBlock(entry, dialect_mod.AccyDialect.AddOp.operation_name) orelse return error.TestExpectedAdd;

    const analysis = try getBufferPlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkBufferStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 3), analysis.slotCount());
    try testing.expectEqual(@as(usize, 2), analysis.input_slot_count);
    try testing.expectEqual(@as(usize, 1), analysis.output_slot_count);
    try testing.expectEqual(@as(usize, 0), analysis.temporary_slot_count);
    try testing.expectEqual(@as(u64, 48), analysis.total_static_bytes);

    const input_value = entry.getArgument(0).?;
    const input_slot = analysis.getSlot(input_value) orelse return error.TestExpectedInputSlot;
    const result_slot = analysis.getSlot(call_op.getResult(0).?) orelse return error.TestExpectedResultSlot;
    const add_slot = analysis.getSlot(add_op.getResult(0).?) orelse return error.TestExpectedAddSlot;
    try testing.expectEqual(input_slot.id, result_slot.id);
    try testing.expect(input_slot.role.input);
    try testing.expect(!input_slot.role.output);
    try testing.expect(!input_slot.role.temporary);
    try testing.expect(add_slot.role.output);
}

test "bufferization planning records returned constants" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const i32_4 = try builder.tensor(.i32, &.{4});
    var fb = try builder.beginFunction("buffer_const", &.{}, &.{i32_4});
    const values = [_]i32{ 1, 2, 3, 4 };
    const c = try fb.constant(i32_4, std.mem.sliceAsBytes(values[0..]));
    try fb.return_(&.{c});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    const ledger = try bufferTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(choir_mod, ctx, allocator, &cache);
    defer pass_ctx.deinit();

    const analysis = try getBufferPlanAnalysis(&pass_ctx, choir_mod);
    try ledger.producersComplete();
    try checkBufferStorage(choir_mod, ctx, &cache, analysis);
    try testing.expectEqual(@as(usize, 1), analysis.slotCount());
    try testing.expectEqual(@as(usize, 1), analysis.output_slot_count);
    try testing.expectEqual(@as(usize, 1), analysis.constant_slot_count);
    try testing.expectEqual(@as(u64, 16), analysis.total_static_bytes);

    const body = choir_mod.getRegion(0).?.getEntryBlock().?;
    const func = ir.inspection.functionByNameInBlock(body, "buffer_const") orelse return error.TestExpectedFunc;
    const entry = func.getRegion(0).?.getEntryBlock().?;
    const constant = findOpNamedInBlock(entry, dialect_mod.AccyDialect.ConstantOp.operation_name) orelse return error.TestExpectedConstant;
    const slot = analysis.getSlot(constant.getResult(0).?) orelse return error.TestExpectedSlot;
    try testing.expect(slot.role.constant);
    try testing.expect(slot.role.output);
}

test "bufferization planning pass preserves IR" {
    const allocator = testing.allocator;

    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    defer builder.deinit();
    const f32_4 = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("buffer_pass_add4", &.{ f32_4, f32_4 }, &.{f32_4});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    const module = try builder.finish();
    defer module.deinit();

    const choir_mod = module.choir_module;
    const ctx = module.context();
    var pm = passes.PassManager.init(allocator);
    defer pm.deinit();
    try pm.addPass(bufferizationPlanningPass());

    const ledger = try choir.product.revision.AccountingV1.create(allocator, .{
        .allowance = choir.product.revision.WorkVector.uniform(std.math.maxInt(u64)),
        .workspace = std.math.maxInt(u64),
        .events = 8,
    }, &.{.{ .name = bufferization_planning_pass_name, .version = 1 }});
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    try testing.expectEqual(
        passes.PassResult.success,
        pm.runWithAnalysisCache(choir_mod, ctx, &cache, .{}),
    );
    try ledger.producersComplete();
    try testing.expectEqual(@as(u64, 1), pm.stats.pass_runs);
    try testing.expectEqual(@as(u64, 0), pm.stats.passes_modified);
}

fn bufferTestLedger() !*choir.product.revision.AccountingV1 {
    const revision = choir.product.revision;
    return revision.AccountingV1.create(testing.allocator, .{
        .allowance = revision.WorkVector.uniform(std.math.maxInt(u64)),
        .workspace = std.math.maxInt(u64),
        .events = 8,
    }, &.{});
}

fn checkBufferStorage(
    op: *ir.Operation,
    ctx: *ir.Context,
    cache: *passes.AnalysisCache,
    expected: *const BufferPlanAnalysis,
) !void {
    const bounds = try bufferAnalysisWork(.{ .operation = op });
    const fixed = @import("alloc_fixed");
    const bytes = try testing.allocator.alignedAlloc(u8, .@"64", @intCast(bounds.workspace));
    defer testing.allocator.free(bytes);
    var storage = fixed.Tracked.init(bytes);
    var retained = fixed.Monotonic.init(storage.allocator(), @max(1, bytes.len));
    const allocator = retained.allocator();
    var pass_ctx = passes.PassContext.init(op, ctx, allocator, cache);
    defer pass_ctx.deinit();
    const ptr = try computeBufferPlanAnalysis(&pass_ctx, op);
    defer cleanupBufferPlanAnalysis(ptr, allocator);
    const actual: *BufferPlanAnalysis = @ptrCast(@alignCast(ptr));
    inline for (.{
        "input_slot_count",    "output_slot_count",  "temporary_slot_count",
        "constant_slot_count", "dynamic_slot_count", "total_static_bytes",
    }) |field| try testing.expectEqual(@field(expected, field), @field(actual, field));
    try testing.expectEqual(expected.slotCount(), actual.slotCount());
    try testing.expectEqual(expected.elisionCount(), actual.elisionCount());
    for (expected.slots.items, actual.slots.items) |left, right| {
        inline for (.{
            "id",    "value",         "producer",  "function",
            "dtype", "element_count", "byte_size",
        }) |field| {
            try testing.expectEqual(@field(left, field), @field(right, field));
        }
        try testing.expectEqualDeep(left.role, right.role);
        try testing.expectEqualSlices(i64, left.dims, right.dims);
        if (left.row_major_strides) |strides| {
            try testing.expectEqualSlices(u64, strides, right.row_major_strides.?);
        } else try testing.expect(right.row_major_strides == null);
    }
    for (expected.elisions.items, actual.elisions.items) |left, right| {
        inline for (.{ "value", "producer", "root", "cluster_index" }) |field| {
            try testing.expectEqual(@field(left, field), @field(right, field));
        }
    }
    try testing.expectEqual(expected.value_to_slot.count(), actual.value_to_slot.count());
    var slots = expected.value_to_slot.iterator();
    while (slots.next()) |entry| {
        try testing.expectEqual(entry.value_ptr.*, actual.getSlot(entry.key_ptr.*).?.id);
    }
    try testing.expectEqual(expected.value_to_elision.count(), actual.value_to_elision.count());
    var elisions = expected.value_to_elision.iterator();
    while (elisions.next()) |entry| {
        try testing.expectEqual(entry.value_ptr.*, actual.value_to_elision.get(entry.key_ptr.*).?);
    }
    try testing.expect(!storage.exhausted);
    const used = if (retained.current) |*current| fixed.used(current) else 0;
    try testing.expect(used <= bounds.workspace);
    try testing.expect(used >= @sizeOf(BufferPlanAnalysis));
}

test "bufferization planning work contract covers boundary growth and layouts" {
    for ([_][]const i64{ &.{}, &.{ 2, 3 }, &.{ 1, 1, 1, 1, 1, 1, 1, 1 }, &.{ -1, 3 } }) |dims| {
        for ([_]usize{ 0, 1, 6, 7, 16, 64 }) |count| try checkBufferBoundary(count, dims);
    }
    try testing.expectError(error.WorkOverflow, (BufferWork{
        .input = .{ .values = std.math.maxInt(u64) },
    }).bounds());
    try testing.expectError(error.WorkOverflow, (BufferWork{
        .input = .{ .operations = std.math.maxInt(u64) },
    }).bounds());
    try testing.expectError(error.WorkOverflow, (BufferWork{
        .input = .{ .input_bytes = std.math.maxInt(u64) },
    }).bounds());
}

fn checkBufferBoundary(count: usize, dims: []const i64) !void {
    std.debug.assert(count <= 64);
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const typ = try builder.tensor(.f32, dims);
    var types: [64]@TypeOf(typ) = @splat(typ);
    var function = try builder.beginFunction("buffer_boundary", types[0..count], types[0..count]);
    var values: [64]@TypeOf(function.parameter(0)) = undefined;
    for (values[0..count], 0..) |*value, index| value.* = function.parameter(index);
    try function.return_(values[0..count]);
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    const ledger = try bufferTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(testing.allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer pass_ctx.deinit();
    const analysis = try getBufferPlanAnalysis(&pass_ctx, module.choir_module);
    try ledger.producersComplete();
    try testing.expectEqual(count, analysis.slotCount());
    try testing.expectEqual(count, analysis.input_slot_count);
    try testing.expectEqual(count, analysis.output_slot_count);
    try testing.expectEqual(@as(usize, 0), analysis.elisionCount());
    for (analysis.slots.items) |slot| try testing.expectEqualSlices(i64, dims, slot.dims);
    try checkBufferStorage(module.choir_module, module.context(), &cache, analysis);
    try checkBufferAdmission(module.choir_module, module.context());
}

fn checkBufferAdmission(op: *ir.Operation, ctx: *ir.Context) !void {
    const revision = choir.product.revision;
    var charge: u64 = 1;
    for ([_]passes.AnalysisDescriptor{
        shape_analysis.shape_layout_analysis_descriptor,
        fusion.fusion_plan_analysis_descriptor,
        buffer_plan_analysis_descriptor,
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
            .events = 8,
        }, &.{.{ .name = bufferization_planning_pass_name, .version = 1 }});
        defer ledger.destroy();
        var cache = try passes.AnalysisCache.initAccounted(
            testing.allocator,
            null,
            ledger,
            .{},
            3,
        );
        defer cache.deinit();
        var manager = passes.PassManager.init(testing.allocator);
        defer manager.deinit();
        try manager.addPass(bufferizationPlanningPass());
        const result = manager.runWithAnalysisCache(op, ctx, &cache, .{});
        if (offset < 0) {
            try testing.expectEqual(passes.PassResult.failure, result);
            try testing.expectEqual(revision.receipt.Outcome.exhausted, ledger.view().outcome);
            try testing.expectEqual(@as(usize, 1), cache.entries.count());
        } else {
            try testing.expectEqual(passes.PassResult.success, result);
            try ledger.producersComplete();
            try testing.expectEqual(@as(usize, 3), cache.entries.count());
        }
    }
}

test "bufferization planning rejects aggregate byte overflow before publishing slots" {
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const extent = std.math.maxInt(i64) / 4;
    const typ = try builder.tensor(.f32, &.{extent});
    var function = try builder.beginFunction("buffer_overflow", &.{ typ, typ, typ }, &.{typ});
    try function.return_(&.{function.parameter(0)});
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    const ledger = try bufferTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(testing.allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer pass_ctx.deinit();
    try testing.expectError(
        error.WorkOverflow,
        getBufferPlanAnalysis(&pass_ctx, module.choir_module),
    );
    try testing.expectEqual(
        choir.product.revision.receipt.Outcome.exhausted,
        ledger.view().outcome,
    );
    try testing.expectEqual(@as(usize, 2), cache.entries.count());
    try testing.expectError(
        error.TerminalWorkOutcome,
        getBufferPlanAnalysis(&pass_ctx, module.choir_module),
    );
}

test "bufferization planning work contract covers alias and elision growth" {
    for ([_]usize{ 1, 2, 6, 7, 16, 64 }) |count| {
        try checkBufferChain(count, true);
        try checkBufferChain(count, false);
    }
}

fn checkBufferChain(count: usize, alias: bool) !void {
    std.debug.assert(count > 0);
    std.debug.assert(count <= 64);
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const typ = try builder.tensor(.f32, &.{ 2, 3 });
    var function = try builder.beginFunction("buffer_chain", &.{ typ, typ }, &.{typ});
    var value = function.parameter(0);
    for (0..count) |_| {
        if (alias) {
            const call = try function.kernelCall(&.{value}, &.{typ}, .{
                .target = "update_f32",
                .operand_effects = &.{.read_write},
                .result_aliases = &.{0},
            });
            value = call.getFirstResult();
        } else value = try function.add(value, function.parameter(1));
    }
    try function.return_(&.{value});
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    const ledger = try bufferTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(testing.allocator, null, ledger, .{}, 3);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer pass_ctx.deinit();
    const analysis = try getBufferPlanAnalysis(&pass_ctx, module.choir_module);
    try ledger.producersComplete();
    try testing.expectEqual(@as(usize, if (alias) 2 else 3), analysis.slotCount());
    try testing.expectEqual(if (alias) 0 else count - 1, analysis.elisionCount());
    try testing.expectEqual(if (alias) count + 2 else 3, analysis.value_to_slot.count());
    try testing.expectEqual(@as(usize, 1), analysis.output_slot_count);
    try testing.expectEqual(@as(usize, 0), analysis.temporary_slot_count);
    try checkBufferStorage(module.choir_module, module.context(), &cache, analysis);
}
