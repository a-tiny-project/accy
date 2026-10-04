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
) !Module {
    const limits = try ModuleEmitter.Limits.inspect(operation, options);
    var emitter = try ModuleEmitter.init(allocator, limits);
    defer emitter.deinit(allocator);
    try emitter.activate();
    return emitter.take();
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

test "WASM module emitter seals exact storage before its first emission" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ModuleEmitter, "wasm_sealed_emit_transitive_risk"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ModuleEmitter, "wasm_sealed_emit_foreign_risk"),
        );
    }

    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const source_module = try buildScalarAddModule(&context);
    const limits = try ModuleEmitter.Limits.inspect(source_module.op, .{});
    const derived = try ModuleEmitter.Capacity.derive(limits);

    var phase_allocator = try alloc_phase.SealedPhaseAllocator.init(allocator);
    var maybe_emitter: ?ModuleEmitter = null;
    var maybe_module: ?Module = null;
    errdefer {
        if (phase_allocator.phase() == .initialization) {
            phase_allocator.abortInitialization();
        }
        if (phase_allocator.phase() == .steady) phase_allocator.beginTeardown();
        if (maybe_module) |*module| {
            module.deinit(phase_allocator.teardownAllocator());
        }
        if (maybe_emitter) |*emitter| {
            if (emitter.phase != .teardown) {
                emitter.deinit(phase_allocator.teardownAllocator());
            }
        }
        if (phase_allocator.phase() == .teardown) phase_allocator.deinit();
    }

    maybe_emitter = try ModuleEmitter.init(
        phase_allocator.initializationAllocator(),
        limits,
    );
    const emitter = &maybe_emitter.?;
    const output_pointer = emitter.output.ptr;
    const output_capacity = emitter.output_capacity;

    phase_allocator.seal();
    try emitter.activate();
    const first = try emitter.emit();
    const second = try emitter.emit();
    maybe_module = try emitter.take();
    const module = &maybe_module.?;

    try std.testing.expectEqual(derived, emitter.capacity);
    try std.testing.expectEqual(output_pointer, first.ptr);
    try std.testing.expectEqual(first.ptr, second.ptr);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expectEqual(output_pointer, module.bytes.ptr);
    try std.testing.expectEqual(output_capacity.output_bytes, module.bytes.len);
    try std.testing.expectEqual(output_capacity.output_bytes, output_capacity.steady_bytes);
    try std.testing.expectEqual(
        derived.working_bytes + output_capacity.output_bytes,
        output_capacity.initialization_bytes,
    );
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
        0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x0b, 0x01,
        0x07, 'a',  'd',  'd',  '_',  'i',  '3',  '2',
        0x00, 0x00, 0x0a, 0x10, 0x01, 0x0e, 0x01, 0x01,
        0x7f, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x21, 0x02,
        0x20, 0x02, 0x0f, 0x0b,
    }, module.bytes);
    try std.testing.expectError(error.AlreadyEmitted, emitter.emit());
    try std.testing.expectError(error.AlreadyEmitted, emitter.take());
    try std.testing.expectEqual(
        alloc_phase.PhaseViolations{},
        phase_allocator.violations(),
    );

    phase_allocator.beginTeardown();
    module.deinit(phase_allocator.teardownAllocator());
    maybe_module = null;
    emitter.deinit(phase_allocator.teardownAllocator());
    try std.testing.expectEqual(
        alloc_phase.PhaseViolations{},
        phase_allocator.violations(),
    );
    phase_allocator.deinit();
}

test "WASM module emitter capacity matches an independent scalar model" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(ModuleEmitter, "wasm_capacity"));
    }

    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const source_module = try buildScalarAddModule(&context);
    const limits = try ModuleEmitter.Limits.inspect(source_module.op, .{});
    const capacity = try ModuleEmitter.Capacity.derive(limits);
    var emitter = try ModuleEmitter.init(allocator, limits);
    defer emitter.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), limits.facts.function_count);
    try std.testing.expectEqual(@as(usize, 0), limits.facts.import_count);
    try std.testing.expectEqual(@as(usize, 1), limits.facts.definition_count);
    try std.testing.expectEqual(@as(usize, 3), limits.facts.value_count);
    try std.testing.expectEqual(@as(usize, 1), limits.facts.local_count);
    try std.testing.expectEqual(@as(usize, 0), limits.facts.nesting_depth);
    try std.testing.expectEqual(@as(usize, 1), capacity.frame_count);

    const expected_working = @sizeOf(emission.FunctionPlan) +
        4 * @sizeOf(u32) +
        3 * @sizeOf(emission.ValuePlan) +
        4 * @sizeOf(u32) +
        @sizeOf(emission.function.Frame);
    try std.testing.expectEqual(expected_working, capacity.working_bytes);
    try std.testing.expectEqual(@as(usize, 52), emitter.output_capacity.output_bytes);
    try std.testing.expectEqual(
        expected_working + emitter.output_capacity.output_bytes,
        emitter.output_capacity.initialization_bytes,
    );
    try std.testing.expectEqual(
        emitter.output_capacity.output_bytes,
        emitter.output_capacity.steady_bytes,
    );
}

test "WASM empty and declaration-only modules need no control or value workspace" {
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try dialects.registerAllDialects(&context);
    const location = ir.Location.getUnknown();
    const empty = try BuiltinDialect.ModuleOp.create(&context, location);

    const empty_limits = try ModuleEmitter.Limits.inspect(empty.op, .{});
    const empty_capacity = try ModuleEmitter.Capacity.derive(empty_limits);
    try std.testing.expectEqual(@as(usize, 0), empty_capacity.frame_count);
    try std.testing.expectEqual(@as(usize, 0), empty_capacity.function_index_slots);
    try std.testing.expectEqual(@as(usize, 0), empty_capacity.value_index_slots);
    var empty_emitter = try ModuleEmitter.init(allocator, empty_limits);
    defer empty_emitter.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 11), empty_emitter.output_capacity.output_bytes);

    const i32_type = try ArithDialect.getI32Type(&context);
    const declaration = try FuncDialect.FuncOp.createDeclaration(
        &context,
        location,
        "external",
        &.{i32_type},
        &.{i32_type},
    );
    try empty.getBodyBlock().addOperation(declaration.op);
    const declaration_limits = try ModuleEmitter.Limits.inspect(empty.op, .{});
    const declaration_capacity = try ModuleEmitter.Capacity.derive(declaration_limits);
    try std.testing.expectEqual(@as(usize, 0), declaration_capacity.frame_count);
    try std.testing.expectEqual(@as(usize, 0), declaration_capacity.value_index_slots);
    try std.testing.expectEqual(@as(usize, 4), declaration_capacity.function_index_slots);
    var declaration_emitter = try ModuleEmitter.init(allocator, declaration_limits);
    defer declaration_emitter.deinit(allocator);
    try declaration_emitter.activate();
    try std.testing.expect((try declaration_emitter.emit()).len > 11);
    try std.testing.expectError(
        error.FunctionNotFound,
        ModuleEmitter.Limits.inspect(empty.op, .{ .entry = "external" }),
    );
}

test "WASM module emitter admits its nesting maximum and rejects one past it" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ModuleEmitter, "wasm_nesting_boundary"),
        );
    }

    const allocator = std.testing.allocator;
    var bounded_context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer bounded_context.deinit(allocator);
    const bounded = try buildNestedIfModule(&bounded_context, emission.max_nesting_depth);
    const limits = try ModuleEmitter.Limits.inspect(bounded.op, .{});
    const capacity = try ModuleEmitter.Capacity.derive(limits);
    try std.testing.expectEqual(emission.max_nesting_depth, limits.facts.nesting_depth);
    try std.testing.expectEqual(
        2 * emission.max_nesting_depth + 1,
        capacity.frame_count,
    );

    var one_past_context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer one_past_context.deinit(allocator);
    const one_past = try buildNestedIfModule(
        &one_past_context,
        emission.max_nesting_depth + 1,
    );
    try std.testing.expectError(
        error.NestingLimitExceeded,
        ModuleEmitter.Limits.inspect(one_past.op, .{}),
    );
}

test "WASM module emitter seals an input snapshot before activation" {
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const source_module = try buildScalarAddModule(&context);
    var entry = [_]u8{ 'a', 'd', 'd', '_', 'i', '3', '2' };
    const limits = try ModuleEmitter.Limits.inspect(
        source_module.op,
        .{ .entry = &entry },
    );
    var emitter = try ModuleEmitter.init(allocator, limits);
    defer emitter.deinit(allocator);

    entry[0] = 'x';
    try emitter.activate();
    const bytes = try emitter.emit();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "add_i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "xdd_i32") == null);
    var module = try emitter.take();
    defer module.deinit(allocator);
}

test "WASM module emitter rejects structural drift during indexed initialization" {
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const source_module = try buildScalarAddModule(&context);
    const limits = try ModuleEmitter.Limits.inspect(source_module.op, .{});

    var operations = source_module.getBodyBlock().getOperations();
    const function_op = operations.next().?;
    const function = FuncDialect.FuncOp{ .op = function_op };
    const i32_type = try ArithDialect.getI32Type(&context);
    const extra = try ArithDialect.ConstantOp.createInt(
        &context,
        ir.Location.getUnknown(),
        i32_type,
        1,
    );
    try function.getEntryBlock().addOperation(extra.op);

    try std.testing.expectError(
        error.InputChanged,
        ModuleEmitter.init(allocator, limits),
    );
}

test "WASM module emitter captures same-capacity semantics during initialization" {
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const source_module = try buildScalarAddModule(&context);
    const limits = try ModuleEmitter.Limits.inspect(source_module.op, .{});

    var operations = source_module.getBodyBlock().getOperations();
    const function_op = operations.next().?;
    try ir.SymbolTable.setSymbolName(function_op, "sub_i32");

    var emitter = try ModuleEmitter.init(allocator, limits);
    defer emitter.deinit(allocator);
    try emitter.activate();
    const bytes = try emitter.emit();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sub_i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "add_i32") == null);
}

test "WASM module snapshot outlives its IR and emitter" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(ModuleEmitter, "wasm_snapshot_lifetime"),
        );
    }

    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    const source_module = try buildScalarAddModule(&context);
    const limits = try ModuleEmitter.Limits.inspect(source_module.op, .{});
    var emitter = try ModuleEmitter.init(allocator, limits);
    context.deinit(allocator);

    try emitter.activate();
    var module = try emitter.take();
    emitter.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d }, module.bytes[0..4]);
    module.deinit(allocator);
}

test "WASM module emitter initialization survives every allocation failure" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(ModuleEmitter, "wasm_oom_retry"));
    }

    const Harness = struct {
        fn run(allocator: Allocator) !void {
            var context = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
            defer context.deinit(std.testing.allocator);
            const source_module = try buildScalarAddModule(&context);
            const limits = try ModuleEmitter.Limits.inspect(source_module.op, .{});
            var emitter = try ModuleEmitter.init(allocator, limits);
            defer emitter.deinit(allocator);
            try emitter.activate();
            var module = try emitter.take();
            defer module.deinit(allocator);
            try std.testing.expectEqual(emitter.output_capacity.output_bytes, module.bytes.len);
        }
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Harness.run,
        .{},
    );
}

test "WASM module emitter keeps imports before definitions in index space" {
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try dialects.registerAllDialects(&context);

    const location = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&context);
    const module = try BuiltinDialect.ModuleOp.create(&context, location);
    var caller = try FuncDialect.FuncOp.create(
        &context,
        location,
        "call_external",
        &.{i32_type},
        &.{i32_type},
    );
    try module.getBodyBlock().addOperation(caller.op);
    var call = try FuncDialect.CallOp.create(
        &context,
        location,
        "external_plus_one",
        &.{caller.getArgument(0)},
        &.{i32_type},
    );
    try caller.getEntryBlock().addOperation(call.op);
    const ret = try FuncDialect.ReturnOp.create(
        &context,
        location,
        &.{call.getResult(0).?},
    );
    try caller.getEntryBlock().addOperation(ret.op);
    const imported = try FuncDialect.FuncOp.createDeclaration(
        &context,
        location,
        "external_plus_one",
        &.{i32_type},
        &.{i32_type},
    );
    try module.getBodyBlock().addOperation(imported.op);

    var encoded = try emitTestModule(
        allocator,
        module.op,
        .{ .entry = "call_external" },
    );
    defer encoded.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0b, 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f,
        0x60, 0x01, 0x7f, 0x01, 0x7f, 0x02, 0x19, 0x01,
        0x03, 'e',  'n',  'v',  0x11, 'e',  'x',  't',
        'e',  'r',  'n',  'a',  'l',  '_',  'p',  'l',
        'u',  's',  '_',  'o',  'n',  'e',  0x00, 0x01,
        0x03, 0x02, 0x01, 0x00, 0x07, 0x11, 0x01, 0x0d,
        'c',  'a',  'l',  'l',  '_',  'e',  'x',  't',
        'e',  'r',  'n',  'a',  'l',  0x00, 0x01, 0x0a,
        0x0f, 0x01, 0x0d, 0x01, 0x01, 0x7f, 0x20, 0x00,
        0x10, 0x00, 0x21, 0x01, 0x20, 0x01, 0x0f, 0x0b,
    }, encoded.bytes);

    var backend = try wasm.Backend.init(allocator, &context);
    defer backend.deinit();
    var artifact = try backend.compileModuleToArtifact(
        module.op,
        .{ .entry = "call_external" },
    );
    defer artifact.deinit();
    try std.testing.expect(artifact.linkage.hasProvided("call_external"));
    try std.testing.expect(artifact.linkage.hasRequired("external_plus_one"));
}

test "WASM module emitter handles structured control and host memory" {
    const ScfDialect = dialects.ScfDialect;
    const MemrefDialect = dialects.MemrefDialect;
    const allocator = std.testing.allocator;
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    try dialects.registerAllDialects(&context);

    const location = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&context);
    const index_type = try ArithDialect.getIndexType(&context);
    const f32_type = try ArithDialect.getScalarType(&context, .f32);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(
        &context,
        f32_type,
        .host,
    );
    const module = try BuiltinDialect.ModuleOp.create(&context, location);

    var maximum = try FuncDialect.FuncOp.create(
        &context,
        location,
        "max_i32",
        &.{ i32_type, i32_type },
        &.{i32_type},
    );
    try module.getBodyBlock().addOperation(maximum.op);
    var cmp = try ArithDialect.CmpOp.create(
        &context,
        location,
        .sgt,
        maximum.getArgument(0),
        maximum.getArgument(1),
    );
    try maximum.getEntryBlock().addOperation(cmp.op);
    var if_op = try ScfDialect.IfOp.create(
        &context,
        location,
        cmp.getResult(),
        &.{i32_type},
    );
    try maximum.getEntryBlock().addOperation(if_op.op);
    const then_yield = try ScfDialect.YieldOp.create(
        &context,
        location,
        &.{maximum.getArgument(0)},
    );
    try if_op.getThenBlock().addOperation(then_yield.op);
    const else_yield = try ScfDialect.YieldOp.create(
        &context,
        location,
        &.{maximum.getArgument(1)},
    );
    try if_op.getElseBlock().?.addOperation(else_yield.op);
    const maximum_ret = try FuncDialect.ReturnOp.create(
        &context,
        location,
        &.{if_op.getResult(0).?},
    );
    try maximum.getEntryBlock().addOperation(maximum_ret.op);

    var sum = try FuncDialect.FuncOp.create(
        &context,
        location,
        "sum_four",
        &.{},
        &.{index_type},
    );
    try module.getBodyBlock().addOperation(sum.op);
    var lower = try ArithDialect.ConstantOp.createInt(&context, location, index_type, 0);
    try sum.getEntryBlock().addOperation(lower.op);
    var upper = try ArithDialect.ConstantOp.createInt(&context, location, index_type, 4);
    try sum.getEntryBlock().addOperation(upper.op);
    var step = try ArithDialect.ConstantOp.createInt(&context, location, index_type, 1);
    try sum.getEntryBlock().addOperation(step.op);
    var initial = try ArithDialect.ConstantOp.createInt(&context, location, index_type, 0);
    try sum.getEntryBlock().addOperation(initial.op);
    var loop = try ScfDialect.ForOp.create(
        &context,
        location,
        lower.getResult(),
        upper.getResult(),
        step.getResult(),
        &.{initial.getResult()},
        &.{index_type},
    );
    try sum.getEntryBlock().addOperation(loop.op);
    var next = try ArithDialect.AddOp.create(
        &context,
        location,
        loop.getIterArgs()[0],
        loop.getInductionVar(),
    );
    try loop.getBodyBlock().addOperation(next.op);
    const loop_yield = try ScfDialect.YieldOp.create(
        &context,
        location,
        &.{next.getResult()},
    );
    try loop.getBodyBlock().addOperation(loop_yield.op);
    const sum_ret = try FuncDialect.ReturnOp.create(
        &context,
        location,
        &.{loop.getResult(0).?},
    );
    try sum.getEntryBlock().addOperation(sum_ret.op);

    var copy = try FuncDialect.FuncOp.create(
        &context,
        location,
        "copy_one",
        &.{ memref_type, memref_type },
        &.{},
    );
    try module.getBodyBlock().addOperation(copy.op);
    var zero = try ArithDialect.ConstantOp.createInt(&context, location, index_type, 0);
    try copy.getEntryBlock().addOperation(zero.op);
    var loaded = try MemrefDialect.LoadOp.create(
        &context,
        location,
        copy.getArgument(0),
        zero.getResult(),
        f32_type,
    );
    try copy.getEntryBlock().addOperation(loaded.op);
    const store = try MemrefDialect.StoreOp.create(
        &context,
        location,
        loaded.getResult(),
        copy.getArgument(1),
        zero.getResult(),
    );
    try copy.getEntryBlock().addOperation(store.op);
    const copy_ret = try FuncDialect.ReturnOp.create(&context, location, &.{});
    try copy.getEntryBlock().addOperation(copy_ret.op);

    const limits = try ModuleEmitter.Limits.inspect(module.op, .{});
    try std.testing.expectEqual(@as(usize, 1), limits.facts.nesting_depth);
    try std.testing.expect(limits.facts.needs_memory);
    var encoded = try emitTestModule(allocator, module.op, .{});
    defer encoded.deinit(allocator);
    try std.testing.expect(encoded.bytes.len > 8);
    try std.testing.expect(std.mem.indexOfScalar(
        u8,
        encoded.bytes,
        @backingInt(@import("../binary/root.zig").Section.memory),
    ) != null);
}
