const std = @import("std");
const choir = @import("choir");
const bufferization = @import("bufferization/root.zig");
const schedule = @import("schedule/root.zig");
const accy_choir = @import("../choir/root.zig");
const dialect_mod = accy_choir.dialect;

const ir = choir.ir;
const passes = choir.passes;
const accounting = passes.pass.work;

pub const memory_space_plan_analysis_name = "accy-choir-memory-space-plan";
pub const memory_space_planning_pass_name = "accy-choir-plan-memory-spaces";
pub const memory_space_planning_pass_description =
    "Plan Accy Choir buffer memory spaces and boundary transfers";

pub const MemorySpace = accy_choir.record.memory.MemorySpace;

pub const MemoryAccess = accy_choir.record.memory.MemoryAccess;

pub const BoundaryTransfer = accy_choir.record.memory.BoundaryTransfer;

/// A caller reads this to know whether a function output is written by a kernel or is an existing
/// buffer. The value is either the id of the scheduled unit of work that writes the output, or the
/// id of an input or constant buffer that the output is. Planning fails with
/// `error.MissingOutputWriter` when an output has neither.
pub const OutputSource = accy_choir.record.memory.OutputSource;

pub const MemorySpaceAssignment = struct {
    slot_id: usize,
    value: *ir.Value,
    producer: ?*ir.Operation,
    role: bufferization.BufferRole,
    space: MemorySpace,
    access: MemoryAccess,
    transfer: BoundaryTransfer,
    byte_size: ?u64,
    output_source: ?OutputSource = null,

    pub fn isDynamic(self: MemorySpaceAssignment) bool {
        return self.byte_size == null;
    }
};

pub const MemorySpacePlanAnalysis = struct {
    allocator: std.mem.Allocator,
    assignments: std.ArrayListUnmanaged(MemorySpaceAssignment),
    slot_to_assignment: std.AutoHashMap(usize, usize),
    host_slot_count: usize = 0,
    device_global_slot_count: usize = 0,
    device_constant_slot_count: usize = 0,
    device_shared_slot_count: usize = 0,
    unified_slot_count: usize = 0,
    host_input_transfer_count: usize = 0,
    host_output_transfer_count: usize = 0,
    dynamic_slot_count: usize = 0,
    elided_value_count: usize = 0,
    total_static_bytes: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) MemorySpacePlanAnalysis {
        return .{
            .allocator = allocator,
            .assignments = .empty,
            .slot_to_assignment = std.AutoHashMap(usize, usize).init(allocator),
        };
    }

    pub fn deinit(self: *MemorySpacePlanAnalysis) void {
        self.assignments.deinit(self.allocator);
        self.slot_to_assignment.deinit();
        self.* = undefined;
    }

    pub fn assignmentCount(self: MemorySpacePlanAnalysis) usize {
        return self.assignments.items.len;
    }

    pub fn getAssignmentForSlot(
        self: *const MemorySpacePlanAnalysis,
        slot_id: usize,
    ) ?*const MemorySpaceAssignment {
        const index = self.slot_to_assignment.get(slot_id) orelse return null;
        return &self.assignments.items[index];
    }

    pub fn getAssignmentForValue(
        self: *const MemorySpacePlanAnalysis,
        buffers: *const bufferization.BufferPlanAnalysis,
        value: *ir.Value,
    ) ?*const MemorySpaceAssignment {
        const slot = buffers.getSlot(value) orelse return null;
        return self.getAssignmentForSlot(slot.id);
    }

    fn addAssignment(self: *MemorySpacePlanAnalysis, assignment: MemorySpaceAssignment) !void {
        if (self.slot_to_assignment.contains(assignment.slot_id)) return;
        const index = self.assignments.items.len;
        try self.slot_to_assignment.put(assignment.slot_id, index);
        errdefer _ = self.slot_to_assignment.remove(assignment.slot_id);
        try self.assignments.append(self.allocator, assignment);

        switch (assignment.space) {
            .host => self.host_slot_count += 1,
            .device_global => self.device_global_slot_count += 1,
            .device_constant => self.device_constant_slot_count += 1,
            .device_shared => self.device_shared_slot_count += 1,
            .unified => self.unified_slot_count += 1,
        }
        if (assignment.transfer.needsHostInput()) self.host_input_transfer_count += 1;
        if (assignment.transfer.needsHostOutput()) self.host_output_transfer_count += 1;
        if (assignment.byte_size) |bytes| {
            self.total_static_bytes += bytes;
        } else {
            self.dynamic_slot_count += 1;
        }
    }
};

const missing_output_format =
    "function @{s} result #{d} (%{d}) has no kernel writer or backing alias; " ++
    "schedule its producer or provide an input/constant alias";

const MemoryWork = struct {
    input: accounting.Census,
    symbols: u64,

    fn inspect(op: *ir.Operation) !MemoryWork {
        var result: MemoryWork = .{ .input = try accounting.Census.inspect(op), .symbols = 0 };
        _ = try op.walk(.{ .order = .pre_order }, &result, visit);
        return result;
    }

    fn visit(self: *MemoryWork, op: *ir.Operation) !ir.Operation.WalkResult {
        if (isName(op.name.name, "func.func")) {
            const function = choir.dialects.FuncDialect.FuncOp{ .op = op };
            const name = function.getName() orelse "<unknown>";
            self.symbols = try accounting.add(self.symbols, name.len);
        }
        return .advance;
    }

    fn diagnosticBytes(self: MemoryWork) !u64 {
        return accounting.add(self.symbols, missing_output_format.len + 2 * 20 + "<unknown>".len);
    }

    fn storage(self: MemoryWork) !u64 {
        var bytes: u64 = @sizeOf(MemorySpacePlanAnalysis) + @alignOf(MemorySpacePlanAnalysis);
        bytes = try accounting.add(
            bytes,
            try accounting.arrayListGrowth(MemorySpaceAssignment, self.input.values),
        );
        bytes = try accounting.add(
            bytes,
            try accounting.hashMapGrowth(usize, usize, self.input.values),
        );
        bytes = try accounting.add(bytes, try self.diagnosticBytes());
        if (bytes > std.math.maxInt(usize)) return error.WorkOverflow;
        return bytes;
    }

    fn bounds(self: MemoryWork) !accounting.Bounds {
        const bytes = try self.storage();
        const input_bytes = try accounting.add(self.input.input_bytes, self.symbols);
        const input_units = try accounting.add(self.input.atoms, input_bytes);
        const units = try accounting.add(input_units, try self.diagnosticBytes());
        const entries = try accounting.add(
            self.input.operations,
            try accounting.add(self.input.values, self.input.operands),
        );
        const probes = try accounting.hashMapCapacity(entries);
        const scans = try accounting.multiply(units, try accounting.add(self.input.operations, 1));
        const inner = try accounting.add(try accounting.add(self.input.values, probes), units);
        const visits = try accounting.multiply(64, try accounting.multiply(scans, inner));
        return .{
            .work = .{
                .input_bytes = input_bytes,
                .structural_visits = visits,
                .analysis_computations = 1,
                .allocation_capacity = bytes,
            },
            .workspace = bytes,
            .retained_storage = bytes,
        };
    }
};

fn memoryAnalysisWork(input: accounting.Input) !accounting.Bounds {
    return (try MemoryWork.inspect(input.operation)).bounds();
}

fn memoryPassWork(_: accounting.Input) !accounting.Bounds {
    return .{ .work = .{ .structural_visits = 1 } };
}

pub const memory_space_plan_analysis_descriptor = passes.AnalysisDescriptor{
    .id = passes.analysisId(memory_space_plan_analysis_name),
    .name = memory_space_plan_analysis_name,
    .work_contract = .{
        .identity = .{ .name = memory_space_plan_analysis_name, .version = 1 },
        .estimate = memoryAnalysisWork,
    },
};

pub fn getMemorySpacePlanAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) !*MemorySpacePlanAnalysis {
    const ptr = try pass_ctx.getAnalysis(
        op,
        &memory_space_plan_analysis_descriptor,
        computeMemorySpacePlanAnalysis,
        cleanupMemorySpacePlanAnalysis,
    );
    return @ptrCast(@alignCast(ptr));
}

pub fn memorySpacePlanningPass() passes.Pass {
    return .{
        .name = memory_space_planning_pass_name,
        .description = memory_space_planning_pass_description,
        .run_fn = runMemorySpacePlanningPass,
        .work_contract = .{
            .identity = .{ .name = memory_space_planning_pass_name, .version = 1 },
            .estimate = memoryPassWork,
        },
    };
}

fn runMemorySpacePlanningPass(pass_ctx: *passes.PassContext) passes.PassResult {
    _ = getMemorySpacePlanAnalysis(pass_ctx, pass_ctx.op) catch return .failure;
    pass_ctx.preserveAllAnalyses();
    return .success;
}

fn computeMemorySpacePlanAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) anyerror!*anyopaque {
    const buffers = try bufferization.getBufferPlanAnalysis(pass_ctx, op);
    const work = try schedule.getSchedulePlanAnalysis(pass_ctx, op);

    const analysis = try pass_ctx.allocator.create(MemorySpacePlanAnalysis);
    analysis.* = MemorySpacePlanAnalysis.init(pass_ctx.allocator);
    errdefer {
        analysis.deinit();
        pass_ctx.allocator.destroy(analysis);
    }

    analysis.elided_value_count = buffers.elisionCount();
    for (buffers.slots.items) |slot| {
        var assignment = classifySlot(slot);
        assignment.output_source = try classifyOutput(pass_ctx.allocator, slot, buffers, work);
        try analysis.addAssignment(assignment);
    }
    std.debug.assert(analysis.assignmentCount() == buffers.slotCount());
    std.debug.assert(analysis.total_static_bytes == buffers.total_static_bytes);

    return @ptrCast(analysis);
}

fn classifyOutput(
    allocator: std.mem.Allocator,
    slot: bufferization.BufferSlot,
    buffers: *const bufferization.BufferPlanAnalysis,
    work: *const schedule.SchedulePlanAnalysis,
) !?OutputSource {
    if (!slot.role.output) return null;
    for (work.work_items.items) |item| {
        if (workWritesSlot(item, buffers, slot.id)) return .{ .kernel_written = item.id };
    }
    if (slot.role.input or slot.role.constant) return .{ .aliased = slot.id };
    try diagnoseMissingOutput(allocator, slot);
    return error.MissingOutputWriter;
}

fn workWritesSlot(
    work: schedule.ScheduleWorkItem,
    buffers: *const bufferization.BufferPlanAnalysis,
    slot_id: usize,
) bool {
    if (buffers.getSlot(work.output_value)) |output| {
        if (output.id == slot_id) return true;
    }
    if (work.kind == .iterate) {
        for (work.root.results.items) |*result| {
            if (buffers.getSlot(result)) |output| {
                if (output.id == slot_id) return true;
            }
        }
    }
    if (work.kind == .scan) {
        if (work.root.getOperand(1)) |scratch| {
            if (buffers.getSlot(scratch)) |output| return output.id == slot_id;
        }
    }
    return false;
}

fn diagnoseMissingOutput(allocator: std.mem.Allocator, slot: bufferization.BufferSlot) !void {
    var uses = slot.value.useIterator();
    while (uses.next()) |use| {
        const user: *ir.Operation = @ptrCast(@alignCast(use.owner));
        if (!isName(user.name.name, "func.return") and
            !isName(user.name.name, dialect_mod.AccyDialect.ReturnOp.operation_name)) continue;
        const function_name = if (slot.function) |function|
            (choir.dialects.FuncDialect.FuncOp{ .op = function }).getName() orelse "<unknown>"
        else
            "<unknown>";
        const message = try std.fmt.allocPrint(
            allocator,
            missing_output_format,
            .{ function_name, use.operand_number, slot.value.id },
        );
        defer allocator.free(message);
        var diagnostic = (slot.producer orelse user).emitError(message);
        defer diagnostic.deinit();
        _ = try diagnostic.emit();
        return;
    }
    return error.InvalidOutputSlot;
}

fn cleanupMemorySpacePlanAnalysis(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const analysis: *MemorySpacePlanAnalysis = @ptrCast(@alignCast(ptr));
    analysis.deinit();
    allocator.destroy(analysis);
}

fn classifySlot(slot: bufferization.BufferSlot) MemorySpaceAssignment {
    return .{
        .slot_id = slot.id,
        .value = slot.value,
        .producer = slot.producer,
        .role = slot.role,
        .space = spaceForSlot(slot),
        .access = accessForRole(slot.role),
        .transfer = transferForRole(slot.role),
        .byte_size = slot.byte_size,
    };
}

fn spaceForSlot(slot: bufferization.BufferSlot) MemorySpace {
    if (slot.role.constant and !slot.role.output) return .device_constant;
    return .device_global;
}

fn accessForRole(role: bufferization.BufferRole) MemoryAccess {
    if (role.input and role.output) return .read_write;
    if (role.output) return .write_only;
    if (role.input or role.constant) return .read_only;
    return .read_write;
}

fn transferForRole(role: bufferization.BufferRole) BoundaryTransfer {
    if (role.input and role.output) return .bidirectional;
    if (role.input) return .host_to_device;
    if (role.output) return .device_to_host;
    return .none;
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

fn memoryTestLedger() !*choir.product.revision.AccountingV1 {
    const revision = choir.product.revision;
    return revision.AccountingV1.create(testing.allocator, .{
        .allowance = revision.WorkVector.uniform(std.math.maxInt(u64)),
        .workspace = std.math.maxInt(u64),
        .events = 12,
    }, &.{});
}

fn checkMemoryStorage(
    op: *ir.Operation,
    ctx: *ir.Context,
    cache: *passes.AnalysisCache,
    expected: *const MemorySpacePlanAnalysis,
) !void {
    const bounds = try memoryAnalysisWork(.{ .operation = op });
    const fixed = @import("alloc_fixed");
    const bytes = try testing.allocator.alignedAlloc(u8, .@"64", @intCast(bounds.workspace));
    defer testing.allocator.free(bytes);
    var storage = fixed.Tracked.init(bytes);
    var retained = fixed.Monotonic.init(storage.allocator(), @max(1, bytes.len));
    const allocator = retained.allocator();
    var pass_ctx = passes.PassContext.init(op, ctx, allocator, cache);
    defer pass_ctx.deinit();
    const ptr = try computeMemorySpacePlanAnalysis(&pass_ctx, op);
    defer cleanupMemorySpacePlanAnalysis(ptr, allocator);
    const actual: *MemorySpacePlanAnalysis = @ptrCast(@alignCast(ptr));
    inline for (.{
        "host_slot_count",            "device_global_slot_count", "device_constant_slot_count",
        "device_shared_slot_count",   "unified_slot_count",       "host_input_transfer_count",
        "host_output_transfer_count", "dynamic_slot_count",       "elided_value_count",
        "total_static_bytes",
    }) |field| try testing.expectEqual(@field(expected, field), @field(actual, field));
    try testing.expectEqual(expected.assignmentCount(), actual.assignmentCount());
    for (expected.assignments.items, actual.assignments.items) |left, right| {
        inline for (.{
            "slot_id", "value", "producer", "space", "access", "transfer", "byte_size",
        }) |field| try testing.expectEqual(@field(left, field), @field(right, field));
        try testing.expectEqualDeep(left.role, right.role);
        try testing.expectEqualDeep(left.output_source, right.output_source);
        try testing.expectEqual(right.value, actual.getAssignmentForSlot(right.slot_id).?.value);
    }
    try testing.expectEqual(expected.slot_to_assignment.count(), actual.slot_to_assignment.count());
    try testing.expect(!storage.exhausted);
    const used = if (retained.current) |*current| fixed.used(current) else 0;
    try testing.expect(used <= bounds.workspace);
    try testing.expect(used >= @sizeOf(MemorySpacePlanAnalysis));
}

fn checkMemoryFailureStorage(
    op: *ir.Operation,
    ctx: *ir.Context,
    cache: *passes.AnalysisCache,
) !void {
    const counts = try MemoryWork.inspect(op);
    const bounds = try counts.bounds();
    const fixed = @import("alloc_fixed");
    const bytes = try testing.allocator.alignedAlloc(u8, .@"64", @intCast(bounds.workspace));
    defer testing.allocator.free(bytes);
    var storage = fixed.Tracked.init(bytes);
    var retained = fixed.Monotonic.init(storage.allocator(), @max(1, bytes.len));
    var pass_ctx = passes.PassContext.init(op, ctx, retained.allocator(), cache);
    defer pass_ctx.deinit();
    var captured = choir.diagnostics.CaptureBuffer.init(testing.allocator);
    defer captured.deinit();
    var scope = ctx.captureDiagnostics(&captured);
    var guard = scope.enter();
    defer guard.deinit();
    try testing.expectError(
        error.MissingOutputWriter,
        computeMemorySpacePlanAnalysis(&pass_ctx, op),
    );
    try testing.expectEqual(@as(usize, 1), captured.diagnostics.items.len);
    const message = captured.diagnostics.items[0].message;
    try testing.expect(message.len <= try counts.diagnosticBytes());
    try testing.expect(!storage.exhausted);
    const used = if (retained.current) |*current| fixed.used(current) else 0;
    try testing.expect(used <= bounds.workspace);
    try testing.expect(used >= @sizeOf(MemorySpacePlanAnalysis) + message.len);
}

fn checkMemoryBoundary(count: usize, written: bool, dims: []const i64) !void {
    std.debug.assert(count <= 64);
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const typ = try builder.tensor(.f32, dims);
    var types: [64]@TypeOf(typ) = @splat(typ);
    var function = try builder.beginFunction("memory_boundary", types[0..count], types[0..count]);
    var values: [64]@TypeOf(function.parameter(0)) = undefined;
    for (values[0..count], 0..) |*value, index| {
        const input = function.parameter(index);
        value.* = if (written) try function.reshape(input, typ, dims) else input;
    }
    try function.return_(values[0..count]);
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    const ledger = try memoryTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(testing.allocator, null, ledger, .{}, 5);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer pass_ctx.deinit();
    const analysis = try getMemorySpacePlanAnalysis(&pass_ctx, module.choir_module);
    try ledger.producersComplete();
    try testing.expectEqual(count * @as(usize, if (written) 2 else 1), analysis.assignmentCount());
    try testing.expectEqual(count, analysis.host_input_transfer_count);
    try testing.expectEqual(count, analysis.host_output_transfer_count);
    for (values[0..count], 0..) |value, index| {
        const slot_id = if (written) count + index else index;
        const assignment = analysis.getAssignmentForSlot(slot_id).?;
        try testing.expectEqual(value, assignment.value);
        const source = assignment.output_source.?;
        if (written) {
            try testing.expectEqual(index, source.kernel_written);
        } else try testing.expectEqual(slot_id, source.aliased);
    }
    try checkMemoryStorage(module.choir_module, module.context(), &cache, analysis);
    try checkMemoryAdmission(module.choir_module, module.context());
}

fn checkMemoryAdmission(op: *ir.Operation, ctx: *ir.Context) !void {
    const revision = choir.product.revision;
    var charge: u64 = 1;
    for ([_]passes.AnalysisDescriptor{
        @import("shape/root.zig").shape_layout_analysis_descriptor,
        @import("fusion/root.zig").fusion_plan_analysis_descriptor,
        schedule.schedule_plan_analysis_descriptor,
        bufferization.buffer_plan_analysis_descriptor,
        memory_space_plan_analysis_descriptor,
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
            .events = 12,
        }, &.{.{ .name = memory_space_planning_pass_name, .version = 1 }});
        defer ledger.destroy();
        var cache = try passes.AnalysisCache.initAccounted(
            testing.allocator,
            null,
            ledger,
            .{},
            5,
        );
        defer cache.deinit();
        var manager = passes.PassManager.init(testing.allocator);
        defer manager.deinit();
        try manager.addPass(memorySpacePlanningPass());
        const result = manager.runWithAnalysisCache(op, ctx, &cache, .{});
        if (offset < 0) {
            try testing.expectEqual(passes.PassResult.failure, result);
            try testing.expectEqual(revision.receipt.Outcome.exhausted, ledger.view().outcome);
            try testing.expectEqual(@as(usize, 3), cache.entries.count());
        } else {
            try testing.expectEqual(passes.PassResult.success, result);
            try ledger.producersComplete();
            try testing.expectEqual(@as(usize, 5), cache.entries.count());
        }
    }
}

fn checkMemoryDiagnostic(name: []const u8) !void {
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const scalar = try builder.tensor(.f32, &.{});
    const vector = try builder.tensor(.f32, &.{8});
    var function = try builder.beginFunction(name, &.{scalar}, &.{vector});
    const result = try function.broadcastInDim(function.parameter(0), vector, &.{8}, &.{});
    try function.return_(&.{result});
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    const counts = try MemoryWork.inspect(module.choir_module);
    try testing.expectEqual(name.len, counts.symbols);
    const ledger = try memoryTestLedger();
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(testing.allocator, null, ledger, .{}, 5);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        testing.allocator,
        &cache,
    );
    defer pass_ctx.deinit();
    const work = try schedule.getSchedulePlanAnalysis(&pass_ctx, module.choir_module);
    _ = try bufferization.getBufferPlanAnalysis(&pass_ctx, module.choir_module);
    work.deinit();
    work.* = schedule.SchedulePlanAnalysis.init(testing.allocator);
    try checkMemoryFailureStorage(module.choir_module, module.context(), &cache);
    try ledger.producersComplete();
}
