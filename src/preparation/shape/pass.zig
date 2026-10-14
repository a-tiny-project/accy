const std = @import("std");
const gpu_abi = @import("gpu_abi");
const choir = @import("choir");
const accy_choir = @import("../../choir/root.zig");
const dialect_mod = accy_choir.dialect;

const ir = choir.ir;
const passes = choir.passes;
const work = passes.pass.work;

pub const shape_layout_analysis_name = "accy-choir-shape-layout";
pub const shape_layout_pass_name = "accy-choir-shape-layout-propagate";
pub const shape_layout_pass_description =
    "Decode Accy Choir tensor shape and row-major layout facts";

pub const TensorInfo = struct {
    dtype: gpu_abi.DType,
    dims: []i64,
    element_count: ?u64,
    row_major_strides: ?[]u64,

    pub fn rank(self: TensorInfo) usize {
        return self.dims.len;
    }

    pub fn hasStaticLayout(self: TensorInfo) bool {
        return self.element_count != null and self.row_major_strides != null;
    }

    fn deinit(self: *TensorInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.dims);
        if (self.row_major_strides) |strides| allocator.free(strides);
        self.* = undefined;
    }
};

pub const ShapeLayoutAnalysis = struct {
    allocator: std.mem.Allocator,
    tensors: std.AutoHashMap(*ir.Value, TensorInfo),
    tensor_value_count: usize = 0,
    accy_op_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ShapeLayoutAnalysis {
        return .{
            .allocator = allocator,
            .tensors = std.AutoHashMap(*ir.Value, TensorInfo).init(allocator),
        };
    }

    pub fn deinit(self: *ShapeLayoutAnalysis) void {
        var iter = self.tensors.valueIterator();
        while (iter.next()) |info| {
            info.deinit(self.allocator);
        }
        self.tensors.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const ShapeLayoutAnalysis, value: *ir.Value) ?TensorInfo {
        return self.tensors.get(value);
    }

    fn recordValue(self: *ShapeLayoutAnalysis, value: *ir.Value) !void {
        const info = try tensorInfoFromType(self.allocator, value.type) orelse return;
        errdefer {
            var mutable = info;
            mutable.deinit(self.allocator);
        }
        self.tensors.putAssumeCapacityNoClobber(value, info);
        self.tensor_value_count += 1;
    }
};

const ShapeWork = struct {
    visits: u64 = 0,
    values: u64 = 0,
    dimensions: u64 = 0,
    key_bytes: u64 = 0,

    fn inspect(op: *ir.Operation) !ShapeWork {
        var result: ShapeWork = .{};
        _ = try op.walk(.{ .order = .pre_order }, &result, visit);
        return result;
    }

    fn visit(self: *ShapeWork, op: *ir.Operation) !ir.Operation.WalkResult {
        self.visits = try work.add(self.visits, 1);
        for (op.results.items) |*result| try self.include(result.type);
        for (op.regions.items) |*region| {
            self.visits = try work.add(self.visits, 1);
            var blocks = region.getBlocks();
            while (blocks.next()) |block| {
                self.visits = try work.add(self.visits, 1);
                for (block.arguments.items) |arg| try self.include(arg.type);
            }
        }
        return .advance;
    }

    fn include(self: *ShapeWork, typ: ir.Type) !void {
        self.visits = try work.add(self.visits, 1);
        const name = typ.getDialectTypeName() orelse return;
        self.key_bytes = try work.add(self.key_bytes, name.len);
        if (!std.mem.eql(u8, name, dialect_mod.tensor_type_name)) return;
        const key = typ.getDialectParamKey() orelse return;
        self.key_bytes = try work.add(self.key_bytes, key.len);
        const comma = std.mem.indexOfScalar(u8, key, ',') orelse return;
        _ = gpu_abi.DType.fromName(key[0..comma]) orelse return;
        const dims = key[comma + 1 ..];
        var rank: u64 = @intFromBool(dims.len != 0);
        for (dims) |byte| if (byte == 'x') {
            rank = try work.add(rank, 1);
        };
        self.values = try work.add(self.values, 1);
        self.dimensions = try work.add(self.dimensions, rank);
    }

    fn storage(self: ShapeWork) !u64 {
        const alignment = @max(
            @alignOf(usize),
            @alignOf(TensorInfo),
            @alignOf(ShapeLayoutAnalysis),
        );
        var bytes: u64 = @sizeOf(ShapeLayoutAnalysis) + alignment;
        const capacity = try work.hashMapCapacity(self.values);
        if (capacity != 0) {
            const table = try work.multiply(capacity, 1 + @sizeOf(*ir.Value) + @sizeOf(TensorInfo));
            bytes = try work.add(bytes, try work.add(table, 4 * @sizeOf(usize) + 3 * alignment));
        }
        bytes = try work.add(bytes, try work.multiply(self.dimensions, 16));
        bytes = try work.add(bytes, try work.multiply(self.values, 2 * @alignOf(u64)));
        if (bytes > std.math.maxInt(usize)) return error.WorkOverflow;
        return bytes;
    }
};

fn analysisWork(input: work.Input) !work.Bounds {
    const counts = try ShapeWork.inspect(input.operation);
    const bytes = try counts.storage();
    const traversal = try work.add(
        try work.add(counts.visits, counts.key_bytes),
        counts.dimensions,
    );
    const probes = try work.multiply(counts.values, try work.hashMapCapacity(counts.values));
    return .{
        .work = .{
            .input_bytes = counts.key_bytes,
            .structural_visits = try work.add(try work.multiply(traversal, 8), probes),
            .analysis_computations = 1,
            .allocation_capacity = bytes,
        },
        .workspace = bytes,
        .retained_storage = bytes,
    };
}

fn propagationWork(_: work.Input) !work.Bounds {
    return .{ .work = .{ .structural_visits = 1 } };
}

const ShapeLayoutAnalysisRegistration = passes.Analysis(
    ShapeLayoutAnalysis,
    shape_layout_analysis_name,
    &.{},
    computeShapeLayoutAnalysis,
    cleanupShapeLayoutAnalysis,
    .{
        .identity = .{ .name = shape_layout_analysis_name, .version = 1 },
        .estimate = analysisWork,
    },
);

pub const shape_layout_analysis_descriptor = ShapeLayoutAnalysisRegistration.descriptor;

pub fn getShapeLayoutAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) !*ShapeLayoutAnalysis {
    return ShapeLayoutAnalysisRegistration.get(pass_ctx, op);
}

pub fn shapeLayoutPropagationPass() passes.Pass {
    return .{
        .name = shape_layout_pass_name,
        .description = shape_layout_pass_description,
        .run_fn = runShapeLayoutPropagationPass,
        .work_contract = .{
            .identity = .{ .name = shape_layout_pass_name, .version = 1 },
            .estimate = propagationWork,
        },
    };
}

fn runShapeLayoutPropagationPass(pass_ctx: *passes.PassContext) passes.PassResult {
    _ = getShapeLayoutAnalysis(pass_ctx, pass_ctx.op) catch return .failure;
    pass_ctx.preserveAllAnalyses();
    return .success;
}

fn computeShapeLayoutAnalysis(
    pass_ctx: *passes.PassContext,
    op: *ir.Operation,
) anyerror!*ShapeLayoutAnalysis {
    const analysis = try pass_ctx.allocator.create(ShapeLayoutAnalysis);
    analysis.* = ShapeLayoutAnalysis.init(pass_ctx.allocator);
    errdefer {
        analysis.deinit();
        pass_ctx.allocator.destroy(analysis);
    }

    const counts = try ShapeWork.inspect(op);
    _ = try work.hashMapCapacity(counts.values);
    try analysis.tensors.ensureTotalCapacity(@intCast(counts.values));
    try collectShapeLayoutFacts(analysis, op);
    std.debug.assert(analysis.tensor_value_count == counts.values);
    std.debug.assert(analysis.tensors.count() == analysis.tensor_value_count);
    return analysis;
}

fn cleanupShapeLayoutAnalysis(analysis: *ShapeLayoutAnalysis, allocator: std.mem.Allocator) void {
    analysis.deinit();
    allocator.destroy(analysis);
}

fn collectShapeLayoutFacts(analysis: *ShapeLayoutAnalysis, op: *ir.Operation) !void {
    if (std.mem.startsWith(u8, op.name.name, "accy.")) {
        analysis.accy_op_count += 1;
    }

    for (op.results.items) |*result| {
        try analysis.recordValue(result);
    }

    for (op.regions.items) |*region| {
        var block_iter = region.getBlocks();
        while (block_iter.next()) |block| {
            for (block.arguments.items) |arg| {
                try analysis.recordValue(arg);
            }
            var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
            while (current) |current_op| {
                try collectShapeLayoutFacts(analysis, current_op);
                current = current_op.next_op;
            }
        }
    }
}

const StaticLayout = struct {
    element_count: u64,
    strides: []u64,
};

fn tensorInfoFromType(allocator: std.mem.Allocator, typ: ir.Type) !?TensorInfo {
    const type_name = typ.getDialectTypeName() orelse return null;
    if (!std.mem.eql(u8, type_name, dialect_mod.tensor_type_name)) return null;
    const key = typ.getDialectParamKey() orelse return null;
    const comma = std.mem.indexOfScalar(u8, key, ',') orelse return null;
    const dtype_name = key[0..comma];
    const dtype = gpu_abi.DType.fromName(dtype_name) orelse return null;
    const dims = try parseDimsAlloc(allocator, key[comma + 1 ..]);
    errdefer allocator.free(dims);

    const static_layout = try computeStaticLayoutAlloc(allocator, dims);
    return .{
        .dtype = dtype,
        .dims = dims,
        .element_count = if (static_layout) |layout| layout.element_count else null,
        .row_major_strides = if (static_layout) |layout| layout.strides else null,
    };
}

fn parseDimsAlloc(allocator: std.mem.Allocator, dims_text: []const u8) ![]i64 {
    if (dims_text.len == 0) return try allocator.alloc(i64, 0);

    var dim_count: usize = 1;
    for (dims_text) |ch| {
        if (ch == 'x') dim_count += 1;
    }

    const dims = try allocator.alloc(i64, dim_count);
    errdefer allocator.free(dims);
    var iter = std.mem.splitScalar(u8, dims_text, 'x');
    var index: usize = 0;
    while (iter.next()) |part| {
        if (part.len == 0 or index >= dim_count) return error.InvalidTensorShape;
        dims[index] = std.fmt.parseInt(i64, part, 10) catch return error.InvalidTensorShape;
        index += 1;
    }
    if (index != dim_count) return error.InvalidTensorShape;
    return dims;
}

fn computeStaticLayoutAlloc(allocator: std.mem.Allocator, dims: []const i64) !?StaticLayout {
    const strides = try allocator.alloc(u64, dims.len);
    errdefer allocator.free(strides);

    var stride: u64 = 1;
    var i = dims.len;
    while (i > 0) {
        i -= 1;
        const dim = dims[i];
        if (dim < 0) {
            allocator.free(strides);
            return null;
        }
        strides[i] = stride;
        const dim_u64: u64 = @intCast(dim);
        stride = std.math.mul(u64, stride, dim_u64) catch {
            allocator.free(strides);
            return null;
        };
    }

    return .{ .element_count = stride, .strides = strides };
}

const testing = std.testing;
const semantic = accy_choir.semantic;

fn findOpNamedInBlock(block: *ir.Block, name: []const u8) ?*ir.Operation {
    var iter = block.operations.head;
    while (iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (std.mem.eql(u8, op.name.name, name)) return op;
        iter = op.next_op;
    }
    return null;
}

fn checkShapeStorage(dims: []const i64, count: usize) !void {
    var builder = try semantic.Builder.init(
        testing.allocator,
        semantic.Builder.ContextLimits.standard,
    );
    defer builder.deinit();
    const typ = try builder.tensor(.f32, dims);
    var parameters: [64]ir.Type = undefined;
    @memset(parameters[0..count], typ);
    var function = try builder.beginFunction("storage", parameters[0..count], &.{});
    try function.return_(&.{});
    try function.finish();
    const module = try builder.finish();
    defer module.deinit();
    const bounds = try analysisWork(.{ .operation = module.choir_module });
    const bytes = try testing.allocator.alloc(u8, @intCast(bounds.workspace));
    defer testing.allocator.free(bytes);
    var storage = @import("alloc_fixed").Tracked.init(bytes);
    var cache = passes.AnalysisCache.init(testing.allocator, null);
    defer cache.deinit();
    var pass_ctx = passes.PassContext.init(
        module.choir_module,
        module.context(),
        storage.allocator(),
        &cache,
    );
    defer pass_ctx.deinit();
    const analysis = try computeShapeLayoutAnalysis(&pass_ctx, module.choir_module);
    defer cleanupShapeLayoutAnalysis(analysis, storage.allocator());
    try testing.expectEqual(count, analysis.tensor_value_count);
    try testing.expect(!storage.exhausted);
    try testing.expect(storage.status().high_water_bytes <= bounds.workspace);
    try testing.expect(storage.status().high_water_bytes >= @sizeOf(ShapeLayoutAnalysis));
    var entries = analysis.tensors.valueIterator();
    while (entries.next()) |info| try testing.expectEqualSlices(i64, dims, info.dims);
}

fn checkShapeBudget(
    operation: *ir.Operation,
    context: *ir.Context,
    allowance: choir.product.revision.WorkVector,
    admitted: bool,
) !void {
    const revision = choir.product.revision;
    const ledger = try revision.AccountingV1.create(testing.allocator, .{
        .allowance = allowance,
        .workspace = 1 << 24,
        .events = 8,
    }, &.{.{ .name = shape_layout_pass_name, .version = 1 }});
    defer ledger.destroy();
    var cache = try passes.AnalysisCache.initAccounted(testing.allocator, null, ledger, .{}, 1);
    defer cache.deinit();
    var manager = passes.PassManager.init(testing.allocator);
    defer manager.deinit();
    try manager.addPass(shapeLayoutPropagationPass());
    const result = manager.runWithAnalysisCache(operation, context, &cache, .{});
    try testing.expectEqual(if (admitted) passes.PassResult.success else .failure, result);
    const events = ledger.view().events;
    try testing.expectEqual(@as(usize, 3), events.len);
    try testing.expectEqual(revision.receipt.Phase.analysis, events[2].phase);
    try testing.expectEqual(admitted, events[2].admitted);
    if (admitted) {
        try ledger.producersComplete();
        try testing.expectEqual(revision.receipt.Outcome.success, events[2].outcome);
    } else {
        try testing.expectEqual(revision.receipt.Outcome.exhausted, ledger.view().outcome);
        try testing.expectEqual(
            revision.WorkVector.Component.structural_visits,
            ledger.view().exceeded.?,
        );
        try testing.expectEqual(@as(usize, 0), cache.entries.count());
    }
}
