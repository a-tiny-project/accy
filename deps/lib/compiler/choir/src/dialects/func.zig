const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");
const effects = ir.interfaces.effects;

pub const attr_names = struct {
    pub const sym_name = "func.sym_name";
    pub const func_type = "func.type";
    pub const kernel = "func.kernel";
};

pub const op_attr_names = struct {
    pub const sym_name = "sym_name";
    pub const sym_visibility = ir.SymbolTable.symbol_attr_names.sym_visibility;
    pub const kernel = "kernel";
    pub const input_count = "input_count";
    pub const input_types = "input_types";
    pub const input_types_text = "input_types_text";
};

pub const FuncVerifyError = error{
    MissingCallee,
    UnresolvedCallee,
    CalleeNotFunction,
    CallOperandCountMismatch,
    CallResultCountMismatch,
    CallOperandTypeMismatch,
    CallResultTypeMismatch,
    MissingFunctionSignature,
    SyscallArgumentCount,
    SyscallMissingResult,
};

const FuncEval = struct {
    fn canEval(op_ptr: *const anyopaque) bool {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        return std.mem.eql(u8, op.name.name, FuncDialect.ReturnOp.operation_name) or
            std.mem.eql(u8, op.name.name, FuncDialect.CallOp.operation_name);
    }

    fn evaluate(
        op_ptr: *const anyopaque,
        operands: []const ir.Attribute,
        eval_ctx: *const ir.interfaces.EvalContext,
    ) ir.interfaces.EvalError!ir.Attribute {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (std.mem.eql(u8, op.name.name, FuncDialect.CallOp.operation_name)) {
            const callee_ref = op.getAttrAs(ir.Attribute.SymbolRefAttr, "callee") orelse return error.InvalidOperand;
            return eval_ctx.evaluateSymbol(eval_ctx.state, callee_ref.getLeafReference(), operands);
        }
        if (operands.len == 0) return error.YieldMissingOperand;
        if (operands.len == 1) return operands[0];
        return op.getContext().getArrayAttr(operands) catch error.OutOfMemory;
    }

    const vtable = ir.interfaces.Evaluatable.VTable{
        .canEval = canEval,
        .evaluate = evaluate,
    };

    fn fallback(_: *const ir.Operation) ?*const anyopaque {
        return &vtable;
    }
};

pub const FuncDialect = struct {
    pub const name = "func";
    const op_templates = ir.dialects.operationTemplate.dialect(@This());
    pub const spec = ir.dialects.dialectSpec(@This(), .{
        .op_interface_fallbacks = &.{
            .{ .id = ir.interfaces.Evaluatable.id, .fallback = FuncEval.fallback },
        },
    });

    const func_symbol_vtable = ir.interfaces.SymbolOpInterface.VTable{
        .getSymbolName = getFuncSymbolName,
        .setSymbolName = setFuncSymbolName,
        .isDeclaration = isFuncDeclaration,
    };

    const function_vtable = ir.interfaces.FunctionOpInterface.VTable{
        .hasBody = hasFunctionBody,
        .getEntryBlock = getFunctionEntryBlock,
        .getArgumentCount = getFunctionArgumentCount,
        .getResultCount = getFunctionResultCount,
    };

    const call_vtable = ir.interfaces.CallOpInterface.VTable{
        .getCalleeSymbol = getCallCalleeSymbol,
        .getCalleeValue = getCallCalleeValue,
        .getArgumentValues = getCallArgumentValues,
        .getArgumentKeywords = getCallArgumentKeywords,
    };

    const yield_vtable = ir.interfaces.YieldOpInterface.VTable{
        .getYieldOperandCount = getYieldOperandCount,
        .getYieldOperand = getYieldOperand,
    };

    pub const FuncOp = struct {
        op: *ir.Operation,

        const def = op_templates.explicit(@This(), .{
            .mnemonic = "func",
            .operands = 0,
            .regions = ir.dialects.shape.atMost(1),
            .region_names = .{"body"},
            .successors = 0,
            .attrs = &.{
                op_attr_names.kernel,
                op_attr_names.sym_visibility,
            },
            .required_attrs = &.{
                op_attr_names.input_count,
                op_attr_names.input_types,
                op_attr_names.input_types_text,
                op_attr_names.sym_name,
            },
            .interfaces = &.{
                ir.interfaces.SymbolOpInterface.entry(&func_symbol_vtable),
                ir.interfaces.FunctionOpInterface.entry(&function_vtable),
                effects.EffectOpInterface.entryFor(.{
                    .capacity = .{ .per_region = 1 },
                    .enumerate = functionEffects,
                }),
            },
            .dynamic_traits = .{ ir.traits.AtMostNRegions(1), ir.traits.IsolatedFromAbove },
        });
        pub const operation_spec = def.operation_spec;
        pub const operation_name = def.operation_name;
        pub const createOperation = def.createOperation;
        pub const getRegion = def.getRegion;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            func_name: []const u8,
            input_types: []const ir.Type,
            result_types: []const ir.Type,
        ) !FuncOp {
            try loadSpec(ctx);
            var body = ir.context.initRegion(ctx);
            defer body.deinit();
            var body_builder = ir.OperationBuilder.init(ctx);
            _ = try body_builder.createBlockWithLoc(&body, input_types, loc);
            var regions = [_]*ir.Region{&body};
            const func = try @This().createOperation(ctx, loc, &.{}, result_types, &regions, &.{});
            const op = func.op;
            errdefer op.erase();

            const name_attr = try getSymNameAttr(ctx, func_name);
            try op.setAttr(op_attr_names.sym_name, name_attr);
            try setFunctionSignatureAttrs(ctx, op, input_types);

            return func;
        }

        pub fn createDeclaration(
            ctx: *ir.Context,
            loc: ir.Location,
            func_name: []const u8,
            input_types: []const ir.Type,
            result_types: []const ir.Type,
        ) !FuncOp {
            try loadSpec(ctx);
            const func = try @This().createOperation(ctx, loc, &.{}, result_types, &.{}, &.{});
            const op = func.op;
            errdefer op.erase();

            const name_attr = try getSymNameAttr(ctx, func_name);
            try op.setAttr(op_attr_names.sym_name, name_attr);
            try setFunctionSignatureAttrs(ctx, op, input_types);
            try ir.SymbolTable.setSymbolVisibility(op, .private);

            return func;
        }

        pub fn createKernel(
            ctx: *ir.Context,
            loc: ir.Location,
            kernel_name: []const u8,
            input_types: []const ir.Type,
        ) !FuncOp {
            const func_op = try create(ctx, loc, kernel_name, input_types, &.{});
            errdefer func_op.op.erase();

            const kernel_attr = try getKernelAttr(ctx);
            try func_op.op.setAttr(op_attr_names.kernel, kernel_attr);

            return func_op;
        }

        pub fn getName(self: FuncOp) ?[]const u8 {
            return ir.SymbolTable.getSymbolName(self.op);
        }

        pub fn isKernel(self: FuncOp) bool {
            return self.op.getAttr(op_attr_names.kernel) != null;
        }

        pub fn hasBody(self: FuncOp) bool {
            return self.op.getRegion(0) != null;
        }

        pub fn isDeclaration(self: FuncOp) bool {
            return !self.hasBody();
        }

        pub fn getBody(self: FuncOp) *ir.Region {
            return self.getRegion("body");
        }

        pub fn getEntryBlock(self: FuncOp) *ir.Block {
            return self.getBody().getEntryBlock().?;
        }

        pub fn getArguments(self: FuncOp) []*ir.Value {
            return self.getEntryBlock().arguments.items;
        }

        pub fn getNumArguments(self: FuncOp) usize {
            if (self.op.getRegion(0)) |region| {
                return region.getEntryBlock().?.arguments.items.len;
            }
            if (self.getInputTypes()) |types| {
                return types.len;
            }
            if (self.op.getAttrAs(ir.Attribute.IntegerAttr, op_attr_names.input_count)) |int_attr| {
                return @intCast(int_attr.getValue());
            }
            return 0;
        }

        pub fn getInputTypes(self: FuncOp) ?[]const ir.Type {
            const type_list_attr = self.op.getAttrAs(ir.Attribute.TypeListAttr, op_attr_names.input_types) orelse return null;
            return type_list_attr.getValues();
        }

        pub fn getInputType(self: FuncOp, index: usize) ?ir.Type {
            const types = self.getInputTypes() orelse return null;
            if (index >= types.len) return null;
            return types[index];
        }

        pub fn getInputTypesText(self: FuncOp) ?[]const u8 {
            if (self.op.getAttr(op_attr_names.input_types_text)) |attr| {
                const string_attr = attr.cast(ir.Attribute.StringAttr) orelse return null;
                return string_attr.getValue();
            }
            const string_attr = self.op.getAttrAs(ir.Attribute.StringAttr, op_attr_names.input_types) orelse return null;
            return string_attr.getValue();
        }

        pub fn getArgument(self: FuncOp, index: usize) *ir.Value {
            return self.getEntryBlock().arguments.items[index];
        }

        pub fn getResultTypes(self: FuncOp) []const ir.Type {
            return self.op.getResultTypes();
        }

        pub fn getNumResults(self: FuncOp) usize {
            return self.op.results.items.len;
        }
    };

    pub const CallOp = struct {
        op: *ir.Operation,

        const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "call",
            .required_attrs = &.{"callee"},
            .interfaces = &.{
                ir.interfaces.CallOpInterface.entry(&call_vtable),
                effects.EffectOpInterface.entryFor(.{
                    .facts = &.{.{ .requirement = .{
                        .kind = .callee_contract,
                        .subject = .operation,
                    } }},
                }),
            },
        });
        pub const operation_spec = leaf.operation_spec;
        pub const operation_name = leaf.operation_name;
        pub const createLeaf = leaf.createLeaf;
        pub const verifySymbolUses = verifyCallSymbolUses;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            callee_name: []const u8,
            operands: []const *ir.Value,
            result_types: []const ir.Type,
        ) !CallOp {
            try loadSpec(ctx);
            const call = try @This().createLeaf(ctx, loc, operands, result_types);
            const op = call.op;
            errdefer op.erase();

            const callee_attr = try ctx.getFlatSymbolRefAttr(callee_name);
            try op.setAttr("callee", callee_attr);

            return call;
        }

        pub fn getCalleeRef(self: CallOp) ?*const ir.Attribute.SymbolRefAttr {
            return self.op.getAttrAs(ir.Attribute.SymbolRefAttr, "callee");
        }

        pub fn getCallee(self: CallOp) ?[]const u8 {
            const symbol_ref = self.getCalleeRef() orelse return null;
            return symbol_ref.getLeafReference();
        }

        pub fn getOperands(self: CallOp) []const *ir.Value {
            return self.op.getOperandValues();
        }

        pub fn getNumOperands(self: CallOp) usize {
            return self.op.operands.items.len;
        }

        pub fn getResult(self: *const CallOp, index: usize) ?*ir.Value {
            return self.op.getResult(index);
        }

        pub fn getNumResults(self: CallOp) usize {
            return self.op.results.items.len;
        }
    };

    /// Crosses into the kernel and answers the one value the kernel returns.
    ///
    /// The op belongs to `func` because `func` owns the call boundary. `func.call` names a
    /// callee the module can see and `func.syscall` names one it cannot, but both carry the
    /// same shape: arguments in operand order, a register convention the target supplies, and
    /// a result the callee decides. Nothing here is x86-64. Every Linux port spells this same
    /// boundary over a number and at most six arguments, so a target dialect would have been
    /// the wrong home for the operand order and the right home only for the instruction.
    ///
    /// Operand 0 is the number and operands 1 through 6 are the kernel's arguments in the
    /// kernel's order. The effect record is deliberately incomplete: what the kernel reads and
    /// writes follows from the number, which is an SSA value, so no pass may read the
    /// enumerated facts as the whole truth.
    pub const SyscallOp = struct {
        op: *ir.Operation,

        /// The kernel reads at most six arguments, so seven operands is the whole shape.
        pub const max_arguments: usize = 6;

        const leaf = op_templates.explicitLeaf(@This(), .{
            .mnemonic = "syscall",
            .operands = ir.dialects.shape.between(1, max_arguments + 1),
            .operand_names = .{
                "number",
                "argument0",
                "argument1",
                "argument2",
                "argument3",
                "argument4",
                "argument5",
            },
            .results = .{"result"},
            .interfaces = &.{
                effects.EffectOpInterface.entryFor(.{
                    .facts = &.{.{ .event = .{ .kind = .foreign, .resource = .{ .subject = .operation } } }},
                }),
            },
        });
        pub const operation_spec = leaf.operation_spec;
        pub const operation_name = leaf.operation_name;
        pub const createLeaf = leaf.createLeaf;
        pub const verify = verifySyscallOp;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            number: *ir.Value,
            arguments: []const *ir.Value,
            result_type: ir.Type,
        ) !SyscallOp {
            try loadSpec(ctx);
            if (arguments.len > max_arguments) return FuncVerifyError.SyscallArgumentCount;
            var operands: [max_arguments + 1]*ir.Value = undefined;
            operands[0] = number;
            @memcpy(operands[1..][0..arguments.len], arguments);
            return try @This().createLeaf(ctx, loc, operands[0 .. arguments.len + 1], &.{result_type});
        }

        pub fn getNumber(self: SyscallOp) *ir.Value {
            return self.op.getOperand(0).?;
        }

        pub fn getArguments(self: SyscallOp) []const *ir.Value {
            return self.op.getOperandValues()[1..];
        }

        pub fn getNumArguments(self: SyscallOp) usize {
            return self.op.operands.items.len - 1;
        }

        pub fn getResult(self: SyscallOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const ReturnOp = struct {
        op: *ir.Operation,

        const term = op_templates.explicitTerminator(@This(), .{
            .mnemonic = "return",
            .interfaces = &.{
                ir.interfaces.YieldOpInterface.entry(&yield_vtable),
                effects.EffectOpInterface.entryFor(.{
                    .capacity = .{ .per_operand = 1 },
                    .enumerate = returnEffects,
                }),
            },
        });
        pub const operation_spec = term.operation_spec;
        pub const operation_name = term.operation_name;
        pub const createTerminator = term.createTerminator;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            operands: []const *ir.Value,
        ) !ReturnOp {
            try loadSpec(ctx);
            return try @This().createTerminator(ctx, loc, operands, &.{});
        }

        pub fn getOperands(self: ReturnOp) []const *ir.Value {
            return self.op.getOperandValues();
        }

        pub fn getNumOperands(self: ReturnOp) usize {
            return self.op.operands.items.len;
        }
    };

    fn loadSpec(ctx: *ir.Context) !void {
        ir.dialects.loadDialectSpec(ctx, spec) catch |err| switch (err) {
            error.ContextFrozen => {},
            else => return err,
        };
    }

    pub fn getSymNameAttr(ctx: *ir.Context, func_name: []const u8) !ir.Attribute {
        return ctx.getDialectAttr(attr_names.sym_name, func_name);
    }

    pub fn getSymNameValue(attr: ir.Attribute) ?[]const u8 {
        if (!std.mem.eql(u8, attr.abstract.name, attr_names.sym_name)) return null;
        const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
        return dialect_attr.payload;
    }

    pub fn getSymbolRefValue(attr: ir.Attribute) ?*const ir.Attribute.SymbolRefAttr {
        return attr.cast(ir.Attribute.SymbolRefAttr);
    }

    pub fn getKernelAttr(ctx: *ir.Context) !ir.Attribute {
        return ctx.getDialectAttr(attr_names.kernel, "");
    }

    fn setFunctionSignatureAttrs(
        ctx: *ir.Context,
        op: *ir.Operation,
        input_types: []const ir.Type,
    ) !void {
        try op.setAttr(op_attr_names.input_count, try ctx.getI64Attr(@intCast(input_types.len)));
        try op.setAttr(op_attr_names.input_types, try ctx.getTypeListAttr(input_types));

        var input_type_text: std.ArrayListUnmanaged(u8) = .empty;
        const allocator = ir.context.transientAllocator(ctx);
        defer input_type_text.deinit(allocator);

        for (input_types, 0..) |typ, index| {
            if (index != 0) try input_type_text.append(allocator, ',');
            const rendered = try std.fmt.allocPrint(allocator, "{f}", .{typ});
            errdefer allocator.free(rendered);
            try input_type_text.appendSlice(allocator, rendered);
            allocator.free(rendered);
        }

        try op.setAttr(op_attr_names.input_types_text, try ctx.getStringAttr(input_type_text.items));
    }

    fn verifyCallOperands(call: CallOp, callee: FuncOp) !void {
        if (callee.op.getRegion(0)) |region| {
            const expected_args = region.getEntryBlock().?.arguments.items;
            if (call.getNumOperands() != expected_args.len) {
                return FuncVerifyError.CallOperandCountMismatch;
            }
            for (call.op.operands.items, 0..) |operand, index| {
                if (!operand.value.type.eql(expected_args[index].type)) {
                    return FuncVerifyError.CallOperandTypeMismatch;
                }
            }
            return;
        }

        const input_types = callee.getInputTypes();
        const input_count = if (input_types) |types|
            types.len
        else if (callee.op.getAttrAs(ir.Attribute.IntegerAttr, op_attr_names.input_count)) |int_attr|
            @as(usize, @intCast(int_attr.getValue()))
        else
            0;
        if (call.getNumOperands() != input_count) {
            return FuncVerifyError.CallOperandCountMismatch;
        }

        const expected_types = input_types orelse return FuncVerifyError.MissingFunctionSignature;
        for (call.op.operands.items, 0..) |operand, index| {
            if (!operand.value.type.eql(expected_types[index])) {
                return FuncVerifyError.CallOperandTypeMismatch;
            }
        }
    }

    fn verifyCallResults(call: CallOp, callee: FuncOp) !void {
        const expected_results = callee.getResultTypes();
        if (call.getNumResults() != expected_results.len) {
            return FuncVerifyError.CallResultCountMismatch;
        }

        for (call.op.results.items, 0..) |result, index| {
            if (!result.type.eql(expected_results[index])) {
                return FuncVerifyError.CallResultTypeMismatch;
            }
        }
    }

    /// The declared shape bounds the operand count, so the verifier only states the two facts
    /// the shape cannot: a number is present and the kernel's one return value is taken.
    fn verifySyscallOp(op_ptr: *const anyopaque) anyerror!void {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        const operand_count = op.operands.items.len;
        if (operand_count == 0 or operand_count > SyscallOp.max_arguments + 1) {
            return FuncVerifyError.SyscallArgumentCount;
        }
        if (op.results.items.len != 1) return FuncVerifyError.SyscallMissingResult;
    }

    fn verifyCallSymbolUses(
        op_ptr: *const anyopaque,
        symbol_tables: *ir.SymbolTable.Collection,
    ) anyerror!void {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        const call = CallOp{ .op = op };
        const callee_ref = call.getCalleeRef() orelse return FuncVerifyError.MissingCallee;
        const callee_op = try symbol_tables.lookupNearestSymbolRefFrom(op, callee_ref) orelse return FuncVerifyError.UnresolvedCallee;
        if (!std.mem.eql(u8, callee_op.name.name, FuncOp.operation_name)) {
            return FuncVerifyError.CalleeNotFunction;
        }

        const callee = FuncOp{ .op = callee_op };
        try verifyCallOperands(call, callee);
        try verifyCallResults(call, callee);
    }

    fn getFuncSymbolName(op_ptr: *const anyopaque) ?[]const u8 {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        const attr = op.getAttr(op_attr_names.sym_name) orelse return null;
        return getSymNameValue(attr);
    }

    fn setFuncSymbolName(op_ptr: *const anyopaque, symbol_name: []const u8) anyerror!void {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        try op.setAttr(op_attr_names.sym_name, try getSymNameAttr(op.getContext(), symbol_name));
    }

    fn isFuncDeclaration(op_ptr: *const anyopaque) bool {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        return (FuncOp{ .op = op }).isDeclaration();
    }

    fn getCallCalleeSymbol(op_ptr: *const anyopaque) ?[]const u8 {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        const symbol_ref = op.getAttrAs(ir.Attribute.SymbolRefAttr, "callee") orelse return null;
        return symbol_ref.getLeafReference();
    }

    fn getCallCalleeValue(_: *const anyopaque) ?*ir.Value {
        return null;
    }

    fn getCallArgumentValues(op_ptr: *const anyopaque) []const *ir.Value {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        return op.getOperandValues();
    }

    fn getCallArgumentKeywords(_: *const anyopaque) []const []const u8 {
        return &.{};
    }

    fn getYieldOperandCount(op_ptr: *const anyopaque) usize {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        return op.getOperandValues().len;
    }

    fn getYieldOperand(op_ptr: *const anyopaque, index: usize) ?*ir.Value {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        return op.getOperand(index);
    }

    fn hasFunctionBody(op_ptr: *const anyopaque) bool {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        return (FuncOp{ .op = op }).hasBody();
    }

    fn getFunctionEntryBlock(op_ptr: *const anyopaque) ?*ir.Block {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        const func = FuncOp{ .op = op };
        if (!func.hasBody()) return null;
        return func.getEntryBlock();
    }

    fn getFunctionArgumentCount(op_ptr: *const anyopaque) usize {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        return (FuncOp{ .op = op }).getNumArguments();
    }

    fn getFunctionResultCount(op_ptr: *const anyopaque) usize {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        return (FuncOp{ .op = op }).getNumResults();
    }
};

const ResourceCounts = struct {
    operations: usize,

    fn capture(ctx: *const ir.Context) ResourceCounts {
        return .{
            .operations = ctx.operationCount(),
        };
    }

    fn expectEqual(self: ResourceCounts, ctx: *const ir.Context) !void {
        try std.testing.expectEqual(self.operations, ctx.operationCount());
    }
};

fn checkFuncConstructorAllocationFailures(allocator: std.mem.Allocator) !void {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ir.dialects.loadDialectSpec(&ctx, FuncDialect.spec);
    const loc = ir.Location.getUnknown();
    const baseline = ResourceCounts.capture(&ctx);

    const function = FuncDialect.FuncOp.create(&ctx, loc, "function", &.{}, &.{}) catch |err| {
        try baseline.expectEqual(&ctx);
        return err;
    };
    function.op.erase();
    try baseline.expectEqual(&ctx);

    const declaration = FuncDialect.FuncOp.createDeclaration(&ctx, loc, "declaration", &.{}, &.{}) catch |err| {
        try baseline.expectEqual(&ctx);
        return err;
    };
    declaration.op.erase();
    try baseline.expectEqual(&ctx);

    const kernel = FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{}) catch |err| {
        try baseline.expectEqual(&ctx);
        return err;
    };
    kernel.op.erase();
    try baseline.expectEqual(&ctx);

    const call = FuncDialect.CallOp.create(&ctx, loc, "callee", &.{}, &.{}) catch |err| {
        try baseline.expectEqual(&ctx);
        return err;
    };
    call.op.erase();
    try baseline.expectEqual(&ctx);
}

fn functionEffects(op: *const ir.Operation, collector: *effects.Collector) void {
    for (0..op.getNumRegions()) |index| collector.append(.{ .region = .{
        .index = index,
        .execution = .latent,
        .may_diverge = false,
        .captures = false,
    } });
}

fn returnEffects(op: *const ir.Operation, collector: *effects.Collector) void {
    for (0..op.getNumOperands()) |index| collector.append(.{ .event = .{
        .kind = .move,
        .resource = .{ .subject = .{ .operand = index } },
    } });
}
