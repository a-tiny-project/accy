const std = @import("std");
const alloc_arena = @import("alloc_arena");
const alloc_observe = @import("alloc_observe");
const ir = @import("../core/root.zig");
const interfaces = @import("../core/root.zig").interfaces;
const rewrite_builder = @import("rewrite.zig");

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    ir_ctx: *ir.Context,

    branch_fuel: u32 = 10_000,
    iteration_fuel: u32 = 100_000,
    recursion_depth: u32 = 0,
    max_recursion: u32 = 256,
    allocation_used: u64 = 0,
    allocation_cap: u64 = 64 * 1024 * 1024,

    comptime_gpa: alloc_observe.debug.Allocator(.{}),

    current_loc: ir.Location,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),

    frames: std.ArrayListUnmanaged(ValueFrame),

    root_op: ?*ir.Operation = null,
    symbol_table: ir.SymbolTable,

    handle_table: std.ArrayList(HandleEntry),
    rewrite_builders: std.ArrayListUnmanaged(*rewrite_builder.RewriteBuilder),

    pub const Diagnostic = struct {
        kind: interfaces.DiagnosticKind,
        message: []const u8,
        loc: ir.Location,
    };

    pub const HandleEntry = struct {
        slice: []u8,
        valid: bool = true,
    };

    pub const ValueFrame = struct {
        values: std.AutoHashMap(*ir.Value, ir.Attribute),
        inherits_parent: bool = false,
    };

    pub const EvalError = error{
        UnknownEffect,
        EffectViolation,
        LocationViolation,
        DeviceLocationForbidden,
        UnifiedLocationForbidden,
        BranchQuotaExceeded,
        IterationQuotaExceeded,
        RecursionDepthExceeded,
        InvalidOperand,
        InvalidConstant,
        DivisionByZero,
        InvalidPredicate,
        InvalidShiftAmount,
        InvalidSize,
        NegativeSize,
        InvalidCondition,
        UnsupportedOperation,
        EvaluationFailed,
        YieldMissingOperand,
        NoYield,
        ValueNotFound,
        InvalidHandle,
        HandleAlreadyDropped,
        BorrowOfInvalidHandle,
        MoveOfInvalidHandle,
        OutOfMemory,
    };

    pub fn init(allocator: std.mem.Allocator, ir_ctx: *ir.Context) Evaluator {
        return .{
            .allocator = allocator,
            .ir_ctx = ir_ctx,
            .comptime_gpa = .init(allocator),
            .current_loc = ir.Location.getUnknown(),
            .frames = .empty,
            .symbol_table = ir.SymbolTable.init(allocator),
            .handle_table = .empty,
            .diagnostics = .empty,
            .rewrite_builders = .empty,
        };
    }

    pub fn initMeta(allocator: std.mem.Allocator, ir_ctx: *ir.Context) Evaluator {
        return init(allocator, ir_ctx);
    }

    pub fn deinit(self: *Evaluator) void {
        self.discardRewriteBuilders();
        for (self.frames.items) |*frame| {
            frame.values.deinit();
        }
        self.frames.deinit(self.allocator);
        self.symbol_table.deinit();
        for (self.handle_table.items) |h| {
            self.comptime_gpa.allocator().free(h.slice);
        }
        self.handle_table.deinit(self.allocator);
        for (self.diagnostics.items) |diag| {
            self.allocator.free(@constCast(diag.message));
        }
        self.diagnostics.deinit(self.allocator);
        _ = self.comptime_gpa.deinit();
    }

    pub fn getDiagnostics(self: *const Evaluator) []const Diagnostic {
        return self.diagnostics.items;
    }

    pub fn clearDiagnostics(self: *Evaluator) void {
        for (self.diagnostics.items) |diag| {
            self.allocator.free(@constCast(diag.message));
        }
        self.diagnostics.clearRetainingCapacity();
    }

    pub fn evaluate(self: *Evaluator, op: *ir.Operation) EvalError!ir.Attribute {
        self.current_loc = op.location;
        const num_operands = op.getNumOperands();
        const iface = op.interface(interfaces.Evaluatable) orelse {
            emitUnsupportedDiagnostic(self, op, num_operands, "missing Evaluatable interface");
            return error.UnsupportedOperation;
        };
        if (!iface.call(.canEval, .{})) {
            emitUnsupportedDiagnostic(self, op, num_operands, "canEval returned false");
            return error.UnsupportedOperation;
        }

        var operand_stack: [16]ir.Attribute = undefined;
        var operand_attrs: []ir.Attribute = operand_stack[0..@min(num_operands, operand_stack.len)];
        var heap_operands: ?[]ir.Attribute = null;
        if (num_operands > operand_stack.len) {
            const allocated = self.allocator.alloc(ir.Attribute, num_operands) catch |err| {
                emitUnsupportedDiagnostic(self, op, num_operands, "failed to allocate operand buffer");
                return err;
            };
            heap_operands = allocated;
            operand_attrs = allocated;
        }
        defer if (heap_operands) |buf| self.allocator.free(buf);

        for (0..num_operands) |i| {
            const operand = op.getOperand(@intCast(i)) orelse return error.InvalidOperand;
            operand_attrs[i] = if (self.getValue(operand)) |attr| attr else resolved_attr: {
                if (operand.getDefiningOp()) |op_ptr| {
                    const defining_op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
                    const result = try self.evaluate(defining_op);
                    try self.registerResults(defining_op, result);
                    if (self.getValue(operand)) |attr| break :resolved_attr attr;
                }
                return error.ValueNotFound;
            };
        }

        const ctx = self.buildEvalContext();
        const result = iface.call(.evaluate, .{ operand_attrs[0..num_operands], &ctx }) catch |err| {
            return mapEvalInterfaceError(err);
        };

        return result;
    }

    fn enterCall(self: *Evaluator) !void {
        if (self.recursion_depth >= self.max_recursion) return error.RecursionDepthExceeded;
        self.recursion_depth += 1;
    }

    fn exitCall(self: *Evaluator) void {
        if (self.recursion_depth > 0) {
            self.recursion_depth -= 1;
        }
    }

    fn addDiagnostic(self: *Evaluator, kind: interfaces.DiagnosticKind, message: []const u8) !void {
        const owned_message = try self.allocator.dupe(u8, message);
        try self.diagnostics.append(self.allocator, .{
            .kind = kind,
            .message = owned_message,
            .loc = self.current_loc,
        });
    }

    fn ensureFrame(self: *Evaluator) !*ValueFrame {
        if (self.frames.items.len == 0) {
            try self.frames.append(self.allocator, .{
                .values = std.AutoHashMap(*ir.Value, ir.Attribute).init(self.allocator),
            });
        }
        return &self.frames.items[self.frames.items.len - 1];
    }

    fn pushFrame(self: *Evaluator, inherits_parent: bool) !void {
        try self.frames.append(self.allocator, .{
            .inherits_parent = inherits_parent,
            .values = std.AutoHashMap(*ir.Value, ir.Attribute).init(self.allocator),
        });
    }

    fn popFrame(self: *Evaluator) void {
        var frame = self.frames.pop() orelse return;
        frame.values.deinit();
    }

    /// A structured region reads lexical parents, but never crosses a call.
    pub fn getValue(self: *Evaluator, value: *ir.Value) ?ir.Attribute {
        var remaining = self.frames.items.len;
        while (remaining > 0) {
            remaining -= 1;
            const frame = &self.frames.items[remaining];
            if (frame.values.get(value)) |attr| return attr;
            if (!frame.inherits_parent) break;
        }
        return null;
    }

    pub fn setValue(self: *Evaluator, value: *ir.Value, attr: ir.Attribute) !void {
        const frame = try self.ensureFrame();
        try frame.values.put(value, attr);
    }

    pub fn setRootOperation(self: *Evaluator, op: *ir.Operation) !void {
        self.root_op = op;
        try self.symbol_table.buildFromOperation(op);
    }

    fn finishRewriteBuilders(self: *Evaluator, finalize: bool) void {
        for (self.rewrite_builders.items) |builder| {
            if (finalize) {
                builder.finalize();
            }
            builder.deinit();
            self.allocator.destroy(builder);
        }
        self.rewrite_builders.deinit(self.allocator);
        self.rewrite_builders = .empty;
    }

    pub fn finalizeRewriteBuilders(self: *Evaluator) void {
        self.finishRewriteBuilders(true);
    }

    pub fn discardRewriteBuilders(self: *Evaluator) void {
        self.finishRewriteBuilders(false);
    }

    fn buildEvalContext(self: *Evaluator) interfaces.EvalContext {
        return .{
            .state = self,
            .allocator = self.allocator,
            .emitDiagnostic = evalContextEmitDiagnostic,
            .evaluateRegion = evalContextEvaluateRegion,
            .evaluateRegionWithArgs = evalContextEvaluateRegionWithArgs,
            .evaluateSymbol = evalContextEvaluateSymbol,
            .consumeBranchFuel = evalContextConsumeBranchFuel,
            .consumeIterationFuel = evalContextConsumeIterationFuel,
            .allocHandle = evalContextAllocHandle,
            .borrowHandle = evalContextBorrowHandle,
            .borrowMutHandle = evalContextBorrowMutHandle,
            .moveHandle = evalContextMoveHandle,
            .dropHandle = evalContextDropHandle,
            .createRewriteBuilder = evalContextCreateRewriteBuilder,
        };
    }

    fn evaluateRegionInternal(self: *Evaluator, region: *ir.Region) EvalError!ir.Attribute {
        if (region.blocks.head) |block_opaque| {
            const block: *ir.Block = @ptrCast(@alignCast(block_opaque));
            var op_ptr = block.operations.head;
            while (op_ptr) |o_opaque| {
                const op: *ir.Operation = @ptrCast(@alignCast(o_opaque));

                const result = try self.evaluate(op);

                try self.registerResults(op, result);

                if (op.hasTrait("is_terminator")) {
                    return result;
                }

                op_ptr = op.next_op;
            }
        }
        return error.NoYield;
    }

    fn registerResults(self: *Evaluator, op: *ir.Operation, result: ir.Attribute) EvalError!void {
        const num_results = op.getNumResults();
        if (num_results == 0) return;
        if (num_results == 1) {
            const res = op.getResult(0) orelse return error.InvalidOperand;
            try self.setValue(res, result);
            return;
        }
        const iface = result.interface(interfaces.AttributeArrayInterface) orelse return error.InvalidOperand;
        const count = iface.call(.getCount, .{});
        if (count != num_results) return error.InvalidOperand;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const attr = iface.call(.getElement, .{i}) orelse return error.InvalidOperand;
            const res = op.getResult(@intCast(i)) orelse return error.InvalidOperand;
            try self.setValue(res, attr);
        }
    }

    fn bindBlockArgs(self: *Evaluator, region: *ir.Region, args: []const ir.Attribute) EvalError!void {
        const block = region.getEntryBlock() orelse return error.NoYield;
        if (block.arguments.items.len != args.len) return error.InvalidOperand;
        for (args, 0..) |arg, i| {
            const arg_value = block.getArgument(i) orelse return error.InvalidOperand;
            try self.setValue(arg_value, arg);
        }
    }

    fn evaluateRegionWithArgs(self: *Evaluator, region: *ir.Region, args: []const ir.Attribute) EvalError!ir.Attribute {
        try self.pushFrame(true);
        defer self.popFrame();
        try self.bindBlockArgs(region, args);
        return try self.evaluateRegionInternal(region);
    }

    pub fn evaluateRegion(self: *Evaluator, region: *ir.Region) EvalError!ir.Attribute {
        return self.evaluateRegionWithArgs(region, &.{});
    }

    fn evaluateFunction(self: *Evaluator, func_op: *ir.Operation, args: []const ir.Attribute) EvalError!ir.Attribute {
        try self.enterCall();
        defer self.exitCall();
        const region = func_op.getRegion(0) orelse return error.NoYield;
        try self.pushFrame(false);
        defer self.popFrame();
        try self.bindBlockArgs(region, args);
        return self.evaluateRegionInternal(region);
    }

    pub fn evaluateFunctionOp(self: *Evaluator, func_op: *ir.Operation, args: []const ir.Attribute) EvalError!ir.Attribute {
        return self.evaluateFunction(func_op, args);
    }

    pub fn evaluateSymbol(self: *Evaluator, symbol: []const u8, args: []const ir.Attribute) EvalError!ir.Attribute {
        if (self.root_op == null) return error.UnsupportedOperation;
        if (self.symbol_table.lookup(symbol)) |func_op| {
            return self.evaluateFunction(func_op, args);
        }
        return error.UnsupportedOperation;
    }

    pub fn evaluateSymbolOptional(
        self: *Evaluator,
        symbol: []const u8,
        args: []const ir.Attribute,
    ) EvalError!?ir.Attribute {
        if (self.root_op == null) return null;
        if (self.symbol_table.lookup(symbol)) |func_op| {
            return try self.evaluateFunction(func_op, args);
        }
        return null;
    }
};

fn emitUnsupportedDiagnostic(
    evaluator: *Evaluator,
    op: *ir.Operation,
    num_operands: usize,
    reason: []const u8,
) void {
    const msg = std.fmt.allocPrint(
        evaluator.allocator,
        "cannot evaluate '{s}' ({d} operands): {s}",
        .{ op.name.name, num_operands, reason },
    ) catch return;
    defer evaluator.allocator.free(msg);
    evaluator.addDiagnostic(.error_, msg) catch {};
}

fn mapEvalInterfaceError(err: interfaces.EvalError) Evaluator.EvalError {
    return switch (err) {
        error.UnsupportedOperation => error.UnsupportedOperation,
        error.UnknownEffect => error.UnknownEffect,
        error.EffectViolation => error.EffectViolation,
        error.LocationViolation => error.LocationViolation,
        error.DivisionByZero => error.DivisionByZero,
        error.InvalidOperand => error.InvalidOperand,
        error.InvalidConstant => error.InvalidConstant,
        error.RequiresDynamicInfo => error.UnsupportedOperation,
        error.InvalidShiftAmount => error.InvalidShiftAmount,
        error.InvalidPredicate => error.InvalidPredicate,
        error.EvaluationFailed => error.EvaluationFailed,
        error.Overflow => error.UnsupportedOperation,
        error.RecursionDepthExceeded => error.RecursionDepthExceeded,
        error.InvalidCondition => error.InvalidCondition,
        error.InvalidSize => error.InvalidSize,
        error.NegativeSize => error.NegativeSize,
        error.InvalidHandle => error.InvalidHandle,
        error.HandleAlreadyDropped => error.HandleAlreadyDropped,
        error.BorrowOfInvalidHandle => error.BorrowOfInvalidHandle,
        error.MoveOfInvalidHandle => error.MoveOfInvalidHandle,
        error.BranchQuotaExceeded => error.BranchQuotaExceeded,
        error.IterationQuotaExceeded => error.IterationQuotaExceeded,
        error.DeviceLocationForbidden => error.DeviceLocationForbidden,
        error.UnifiedLocationForbidden => error.UnifiedLocationForbidden,
        error.YieldMissingOperand => error.YieldMissingOperand,
        error.NoYield => error.NoYield,
        error.ValueNotFound => error.ValueNotFound,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn mapEvalError(err: Evaluator.EvalError) interfaces.EvalError {
    return switch (err) {
        error.UnknownEffect => error.UnknownEffect,
        error.EffectViolation => error.EffectViolation,
        error.LocationViolation => error.LocationViolation,
        error.DeviceLocationForbidden => error.DeviceLocationForbidden,
        error.UnifiedLocationForbidden => error.UnifiedLocationForbidden,
        error.BranchQuotaExceeded => error.BranchQuotaExceeded,
        error.IterationQuotaExceeded => error.IterationQuotaExceeded,
        error.RecursionDepthExceeded => error.RecursionDepthExceeded,
        error.InvalidOperand => error.InvalidOperand,
        error.InvalidConstant => error.InvalidConstant,
        error.DivisionByZero => error.DivisionByZero,
        error.InvalidPredicate => error.InvalidPredicate,
        error.InvalidShiftAmount => error.InvalidShiftAmount,
        error.InvalidSize => error.InvalidSize,
        error.NegativeSize => error.NegativeSize,
        error.InvalidCondition => error.InvalidCondition,
        error.UnsupportedOperation => error.UnsupportedOperation,
        error.EvaluationFailed => error.EvaluationFailed,
        error.YieldMissingOperand => error.YieldMissingOperand,
        error.NoYield => error.NoYield,
        error.ValueNotFound => error.ValueNotFound,
        error.InvalidHandle => error.InvalidHandle,
        error.HandleAlreadyDropped => error.HandleAlreadyDropped,
        error.BorrowOfInvalidHandle => error.BorrowOfInvalidHandle,
        error.MoveOfInvalidHandle => error.MoveOfInvalidHandle,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn evalContextEmitDiagnostic(
    state: *anyopaque,
    kind: interfaces.DiagnosticKind,
    message: []const u8,
) interfaces.EvalError!void {
    const evaluator: *Evaluator = @ptrCast(@alignCast(state));
    evaluator.addDiagnostic(kind, message) catch return error.OutOfMemory;
}

fn evalContextEvaluateRegion(state: *anyopaque, region_opaque: *const anyopaque) interfaces.EvalError!ir.Attribute {
    const evaluator: *Evaluator = @ptrCast(@alignCast(state));
    const region_const: *const ir.Region = @ptrCast(@alignCast(region_opaque));
    const region = @constCast(region_const);
    return evaluator.evaluateRegion(region) catch |err| return mapEvalError(err);
}

fn evalContextEvaluateRegionWithArgs(
    state: *anyopaque,
    region_opaque: *const anyopaque,
    args: []const ir.Attribute,
) interfaces.EvalError!ir.Attribute {
    const evaluator: *Evaluator = @ptrCast(@alignCast(state));
    const region_const: *const ir.Region = @ptrCast(@alignCast(region_opaque));
    const region = @constCast(region_const);
    return evaluator.evaluateRegionWithArgs(region, args) catch |err| return mapEvalError(err);
}

fn evalContextEvaluateSymbol(
    state: *anyopaque,
    symbol: []const u8,
    args: []const ir.Attribute,
) interfaces.EvalError!ir.Attribute {
    const evaluator: *Evaluator = @ptrCast(@alignCast(state));
    return evaluator.evaluateSymbol(symbol, args) catch |err| return mapEvalError(err);
}

fn evalContextConsumeBranchFuel(state: *anyopaque) interfaces.EvalError!void {
    const evaluator: *Evaluator = @ptrCast(@alignCast(state));
    if (evaluator.branch_fuel == 0) return error.BranchQuotaExceeded;
    evaluator.branch_fuel -= 1;
}

fn evalContextConsumeIterationFuel(state: *anyopaque) interfaces.EvalError!void {
    const evaluator: *Evaluator = @ptrCast(@alignCast(state));
    if (evaluator.iteration_fuel == 0) return error.IterationQuotaExceeded;
    evaluator.iteration_fuel -= 1;
}

fn evalContextAllocHandle(state: *anyopaque, size: i64) interfaces.EvalError!i64 {
    const evaluator: *Evaluator = @ptrCast(@alignCast(state));
    if (size < 0) return error.NegativeSize;

    const slice = evaluator.comptime_gpa.allocator().alloc(u8, @intCast(size)) catch return error.OutOfMemory;
    errdefer evaluator.comptime_gpa.allocator().free(slice);

    evaluator.handle_table.append(evaluator.allocator, .{ .slice = slice }) catch return error.OutOfMemory;
    return @intCast(evaluator.handle_table.items.len - 1);
}

fn evalContextBorrowHandle(state: *anyopaque, handle: i64) interfaces.EvalError!i64 {
    const evaluator: *Evaluator = @ptrCast(@alignCast(state));
    if (handle < 0) return error.InvalidHandle;

    const idx: usize = @intCast(handle);
    if (idx >= evaluator.handle_table.items.len) return error.InvalidHandle;
    if (!evaluator.handle_table.items[idx].valid) return error.BorrowOfInvalidHandle;

    return @intCast(idx);
}

fn evalContextBorrowMutHandle(state: *anyopaque, handle: i64) interfaces.EvalError!i64 {
    const evaluator: *Evaluator = @ptrCast(@alignCast(state));
    if (handle < 0) return error.InvalidHandle;

    const idx: usize = @intCast(handle);
    if (idx >= evaluator.handle_table.items.len) return error.InvalidHandle;
    if (!evaluator.handle_table.items[idx].valid) return error.BorrowOfInvalidHandle;

    return @intCast(idx);
}

fn evalContextMoveHandle(state: *anyopaque, handle: i64) interfaces.EvalError!i64 {
    const evaluator: *Evaluator = @ptrCast(@alignCast(state));
    if (handle < 0) return error.InvalidHandle;

    const idx: usize = @intCast(handle);
    if (idx >= evaluator.handle_table.items.len) return error.InvalidHandle;
    if (!evaluator.handle_table.items[idx].valid) return error.MoveOfInvalidHandle;

    return @intCast(idx);
}

fn evalContextDropHandle(state: *anyopaque, handle: i64) interfaces.EvalError!void {
    const evaluator: *Evaluator = @ptrCast(@alignCast(state));
    if (handle < 0) return error.InvalidHandle;

    const idx: usize = @intCast(handle);
    if (idx >= evaluator.handle_table.items.len) return error.InvalidHandle;
    if (!evaluator.handle_table.items[idx].valid) return error.HandleAlreadyDropped;

    evaluator.handle_table.items[idx].valid = false;
}

fn evalContextCreateRewriteBuilder(
    state: *anyopaque,
    root: *ir.Operation,
) interfaces.EvalError!*anyopaque {
    const evaluator: *Evaluator = @ptrCast(@alignCast(state));
    const builder = evaluator.allocator.create(rewrite_builder.RewriteBuilder) catch return error.OutOfMemory;
    builder.* = rewrite_builder.RewriteBuilder.init(
        evaluator.allocator,
        root.getContext(),
        root,
    );
    evaluator.rewrite_builders.append(evaluator.allocator, builder) catch return error.OutOfMemory;
    return @ptrCast(builder);
}

test "Evaluator handles variadic evaluatable ops beyond stack buffer" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const op_name = "test.sum";
    _ = try ctx.registerOperation(op_name, .{});

    const SumEval = struct {
        fn canEval(op_ptr: *const anyopaque) bool {
            _ = op_ptr;
            return true;
        }

        fn evaluate(
            op_ptr: *const anyopaque,
            operands: []const ir.Attribute,
            eval_ctx: *const interfaces.EvalContext,
        ) interfaces.EvalError!ir.Attribute {
            _ = eval_ctx;
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            const op_ctx = op.getContext();

            var total: i64 = 0;
            for (operands) |attr| {
                const value = test_dialect.TestDialect.getIntegerValue(attr) orelse return error.InvalidOperand;
                total += value;
            }

            return test_dialect.TestDialect.getIntegerAttr(op_ctx, total) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.UnsupportedOperation,
            };
        }
    };

    try ctx.registerOperationInterface(
        op_name,
        interfaces.Evaluatable.entryFor(SumEval.canEval, SumEval.evaluate),
    );

    const result_type = try test_dialect.TestDialect.getI64Type(&ctx);
    var constants: std.ArrayListUnmanaged(test_dialect.TestDialect.ConstantOp) = .empty;
    defer constants.deinit(allocator);

    var evaluator = Evaluator.init(allocator, &ctx);
    defer evaluator.deinit();

    const operand_count: usize = 32;
    var expected_total: i64 = 0;
    var operand_values = try allocator.alloc(*ir.Value, operand_count);
    defer allocator.free(operand_values);

    for (0..operand_count) |i| {
        const value: i64 = @intCast(i + 1);
        expected_total += value;
        var constant = try test_dialect.TestDialect.ConstantOp.create(&ctx, loc, result_type, value);
        try constants.append(allocator, constant);
        operand_values[i] = constant.getResult();

        const attr = try test_dialect.TestDialect.getIntegerAttr(&ctx, value);
        try evaluator.setValue(operand_values[i], attr);
    }

    var builder = ir.OperationBuilder.init(&ctx);
    var state = ir.Operation.State.init(op_name, loc);
    state.addOperands(operand_values);
    state.addTypes(&.{result_type});
    const sum_op = try builder.create(state);

    const result_attr = try evaluator.evaluate(sum_op);
    try testing.expectEqual(@as(i64, expected_total), test_dialect.TestDialect.getIntegerValue(result_attr).?);
    try testing.expectEqual(@as(usize, 0), evaluator.getDiagnostics().len);
}

test "Evaluator emits diagnostic for unsupported operations" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    var evaluator = Evaluator.init(allocator, &ctx);
    defer evaluator.deinit();

    const loc = ir.Location.getUnknown();
    var builder = ir.OperationBuilder.init(&ctx);
    const op = try builder.create(ir.Operation.State.init("test.unknown_eval", loc));

    try testing.expectError(error.UnsupportedOperation, evaluator.evaluate(op));

    const diagnostics = evaluator.getDiagnostics();
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, diagnostics[0].message, "test.unknown_eval") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostics[0].message, "missing Evaluatable interface") != null);
}
