const std = @import("std");
const alloc_phase = @import("alloc_phase");
const ir = @import("../../../core/root.zig");
const dialects = @import("../../../dialects/root.zig");
const wasm = @import("../root.zig");
const emission = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const Module = struct {
    bytes: []u8,

    pub fn deinit(self: *Module, allocator: Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const ModuleEmitter = struct {
    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "choir.wasm_module_emitter",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "exact_function_and_value_plans_indices_and_control_frames",
                        .lifetime = .initialization,
                        .detail = "exact function and value plans, indices, and control frames",
                    },
                    .{
                        .id = "exact_count_and_fixed_encoded_output_snapshot",
                        .lifetime = .steady,
                        .detail = "exact Count and Fixed encoded output snapshot",
                    },
                    .{
                        .id = "the_same_exact_output_allocation_after_take",
                        .lifetime = .transferred,
                        .detail = "the same exact output allocation after take",
                    },
                },
                .excluded = &.{
                    "borrowed IR and options after initialization",
                    "dynamic artifact and linkage copies outside ModuleEmitter",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "facts_definition_count", "facts.definition_count"),
                    alloc_phase.capacity.bindInput(Limits, "facts_function_count", "facts.function_count"),
                    alloc_phase.capacity.bindInput(Limits, "facts_import_count", "facts.import_count"),
                    alloc_phase.capacity.bindInput(Limits, "facts_local_count", "facts.local_count"),
                    alloc_phase.capacity.bindInput(Limits, "facts_nesting_depth", "facts.nesting_depth"),
                    alloc_phase.capacity.bindInput(Limits, "facts_value_count", "facts.value_count"),
                },
                .type_selectors = &.{},
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .input = 1 },
                    .{ .input = 2 },
                    .{ .input = 3 },
                    .{ .input = 4 },
                    .{ .input = 5 },
                    .{ .add = .{ .left = 0, .right = 1 } },
                    .{ .add = .{ .left = 6, .right = 2 } },
                    .{ .add = .{ .left = 7, .right = 3 } },
                    .{ .add = .{ .left = 8, .right = 4 } },
                    .{ .add = .{ .left = 9, .right = 5 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .upper_bound,
                    .expression = 10,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "unsupported input, nesting, index, byte, arithmetic, or OOM failure occurs before activation",
            },
            .risks = .{
                .transitive = .{
                    .status = .open,
                    .detail = "emit and take are source-reviewed simple roots, but the ledger does not fail closed over their complete call graph",
                },
                .foreign = .{
                    .status = .open,
                    .detail = "source review found no callback, indirect, policy, raw heap, or OS edge, but no machine witness excludes future foreign edges",
                },
            },
            .obligations = &.{
                .{ .key = "wasm_capacity", .role = .capacity_model },
                .{ .key = "wasm_sealed_emit_transitive_risk", .role = .transitive_risk },
                .{ .key = "wasm_sealed_emit_foreign_risk", .role = .foreign_risk },
                .{ .key = "wasm_nesting_boundary", .role = .overload },
                .{ .key = "wasm_snapshot_lifetime", .role = .custom },
                .{ .key = "wasm_oom_retry", .role = .overload },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };
    phase: alloc_phase.capacity.Phase,
    capacity: Capacity,
    output_capacity: OutputCapacity,
    output: []u8,
    output_taken: bool,

    pub const Limits = emission.Limits;
    pub const Capacity = emission.Capacity;
    pub const OutputCapacity = emission.OutputCapacity;

    const Self = @This();

    pub fn init(allocator: Allocator, limits: Limits) emission.Error!Self {
        const capacity = try Capacity.derive(limits);

        const functions = try allocator.alloc(
            emission.FunctionPlan,
            capacity.facts.function_count,
        );
        errdefer allocator.free(functions);
        const function_index = try allocator.alloc(u32, capacity.function_index_slots);
        errdefer allocator.free(function_index);
        const values = try allocator.alloc(emission.ValuePlan, capacity.facts.value_count);
        errdefer allocator.free(values);
        const value_index = try allocator.alloc(u32, capacity.value_index_slots);
        errdefer allocator.free(value_index);
        const frames = try allocator.alloc(emission.function.Frame, capacity.frame_count);
        errdefer allocator.free(frames);

        var plan = try emission.plan.planning.fill(
            limits.module,
            functions,
            function_index,
            values,
            value_index,
            capacity.facts,
        );
        const measured = try emission.module_encoding.preparePlan(
            &plan,
            limits.module,
            limits.options,
            frames,
        );
        const output_capacity = try OutputCapacity.derive(capacity, measured);
        const output = try allocator.alloc(u8, output_capacity.output_bytes);
        errdefer allocator.free(output);

        var out = wasm.binary.Fixed.init(output);
        try emission.module_encoding.write(
            &out,
            &plan,
            limits.module,
            limits.options,
            frames,
        );
        _ = try out.finish();

        allocator.free(frames);
        allocator.free(value_index);
        allocator.free(values);
        allocator.free(function_index);
        allocator.free(functions);

        return .{
            .phase = .initialization,
            .capacity = capacity,
            .output_capacity = output_capacity,
            .output = output,
            .output_taken = false,
        };
    }

    pub fn activate(self: *Self) emission.Error!void {
        if (self.phase != .initialization) return error.AlreadyActive;
        self.phase = .steady;
    }

    pub fn emit(self: *const Self) emission.Error![]const u8 {
        if (self.phase != .steady) return error.NotActive;
        if (self.output_taken) return error.AlreadyEmitted;
        return self.output;
    }

    pub fn take(self: *Self) emission.Error!Module {
        _ = try self.emit();
        self.output_taken = true;
        return .{ .bytes = self.output };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        if (self.phase == .teardown) @panic("WASM module emitter teardown is terminal");
        self.phase = .teardown;
        if (!self.output_taken) allocator.free(self.output);
        self.output = undefined;
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(ModuleEmitter);
}

const ArithDialect = dialects.ArithDialect;
const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;

fn buildScalarAddModule(context: *ir.Context) !BuiltinDialect.ModuleOp {
    try dialects.registerAllDialects(context);

    const location = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(context);
    const module = try BuiltinDialect.ModuleOp.create(context, location);
    var func = try FuncDialect.FuncOp.create(
        context,
        location,
        "add_i32",
        &.{ i32_type, i32_type },
        &.{i32_type},
    );
    try module.getBodyBlock().addOperation(func.op);
    var add = try ArithDialect.AddOp.create(
        context,
        location,
        func.getArgument(0),
        func.getArgument(1),
    );
    try func.getEntryBlock().addOperation(add.op);
    const ret = try FuncDialect.ReturnOp.create(
        context,
        location,
        &.{add.getResult()},
    );
    try func.getEntryBlock().addOperation(ret.op);
    return module;
}

fn emitTestModule(
    allocator: Allocator,
    operation: *ir.Operation,
    options: emission.Options,
    call: ?@import("wasm_node").node.Call,
    identity: @import("wasm_node").census.Validation,
) !Module {
    const limits = try ModuleEmitter.Limits.inspect(operation, options);
    var emitter = try ModuleEmitter.init(allocator, limits);
    defer emitter.deinit(allocator);
    try emitter.activate();
    var result = try emitter.take();
    errdefer result.deinit(allocator);
    _ = try @import("wasm_node").node.check(result.bytes, call, identity);
    return result;
}

fn buildNestedIfModule(context: *ir.Context, depth: usize) !BuiltinDialect.ModuleOp {
    std.debug.assert(depth <= emission.max_nesting_depth + 1);
    const ScfDialect = dialects.ScfDialect;
    try dialects.registerAllDialects(context);
    const location = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(context);
    const module = try BuiltinDialect.ModuleOp.create(context, location);
    var func = try FuncDialect.FuncOp.create(
        context,
        location,
        "nested",
        &.{i32_type},
        &.{},
    );
    try module.getBodyBlock().addOperation(func.op);
    var then_blocks: [emission.max_nesting_depth + 1]*ir.Block = undefined;
    var block = func.getEntryBlock();
    for (0..depth) |index| {
        var if_op = try ScfDialect.IfOp.create(
            context,
            location,
            func.getArgument(0),
            &.{},
        );
        try block.addOperation(if_op.op);
        then_blocks[index] = if_op.getThenBlock();
        const else_yield = try ScfDialect.YieldOp.create(context, location, &.{});
        try if_op.getElseBlock().?.addOperation(else_yield.op);
        block = if_op.getThenBlock();
    }
    for (then_blocks[0..depth]) |then_block| {
        const yield = try ScfDialect.YieldOp.create(context, location, &.{});
        try then_block.addOperation(yield.op);
    }
    const ret = try FuncDialect.ReturnOp.create(context, location, &.{});
    try func.getEntryBlock().addOperation(ret.op);
    return module;
}
