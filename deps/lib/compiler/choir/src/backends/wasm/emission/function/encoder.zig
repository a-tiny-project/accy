const std = @import("std");
const wasm = @import("../../root.zig");
const ir = @import("../../../../core/root.zig");
const dialects = @import("../../../../dialects/root.zig");
const emission = @import("../root.zig");

const FuncDialect = dialects.FuncDialect;
const ScfDialect = dialects.ScfDialect;
const instruction = emission.function.instruction;
const arithmetic = instruction.arithmetic;
const types = emission.types;

const Terminator = union(enum) {
    function_return,
    if_yield: ScfDialect.IfOp,
    for_yield: ScfDialect.ForOp,
    while_condition: ScfDialect.WhileOp,
    while_yield: ScfDialect.WhileOp,
};

const BlockFrame = struct {
    next: ?*ir.Operation,
    terminator: Terminator,
};

const IfFrame = struct {
    operation: ScfDialect.IfOp,
    then_complete: bool,
};

const WhileFrame = struct {
    operation: ScfDialect.WhileOp,
    after_started: bool,
};

pub const Frame = union(enum) {
    block: BlockFrame,
    if_control: IfFrame,
    for_control: ScfDialect.ForOp,
    while_control: WhileFrame,
};

pub fn writeContent(
    out: anytype,
    plan: *const emission.Plan,
    func: FuncDialect.FuncOp,
    function_ordinal: usize,
    local_count: usize,
    frames: []Frame,
) emission.Error!void {
    try writeLocalDeclarations(out, plan, function_ordinal, local_count);
    var encoder = Encoder(@TypeOf(out)){
        .out = out,
        .func = func,
        .frames = frames,
        .instructions = .{
            .out = out,
            .plan = plan,
            .function_ordinal = function_ordinal,
        },
    };
    try encoder.writeFunctionBody();
    try out.writeByte(0x0b);
}

fn writeLocalDeclarations(
    out: anytype,
    plan: *const emission.Plan,
    function_ordinal: usize,
    local_count: usize,
) emission.Error!void {
    try wasm.binary.writeUleb(out, local_count);
    const locals = plan.localPlans(function_ordinal);
    if (locals.len != local_count) return error.InputChanged;
    for (locals) |local| {
        try wasm.binary.writeUleb(out, @as(u32, 1));
        try wasm.binary.writeValueType(out, local.value_type);
    }
}

fn Encoder(comptime Out: type) type {
    return struct {
        out: Out,
        func: FuncDialect.FuncOp,
        frames: []Frame,
        instructions: instruction.Writer(Out),
        frame_len: usize = 0,

        const Self = @This();

        fn writeFunctionBody(self: *Self) emission.Error!void {
            // A parameter is read once, on entry, from its low declared-width bits.
            const entry = self.func.getEntryBlock();
            for (0..entry.getNumArguments()) |index| {
                const argument = entry.getArgument(index) orelse return error.CodeGenFailed;
                if (!narrow(argument.type)) continue;
                const local = try self.instructions.localFor(argument);
                try self.instructions.writeLocalGet(local);
                try instruction.call.writeReceived(self.out, argument.type);
                try self.instructions.writeLocalSet(local);
            }
            try self.pushBlock(entry, .function_return);
            while (self.frame_len > 0) {
                switch (self.frames[self.frame_len - 1]) {
                    .block => try self.stepBlock(),
                    .if_control => try self.finishIf(),
                    .for_control => try self.finishFor(),
                    .while_control => try self.finishWhile(),
                }
            }
        }

        fn stepBlock(self: *Self) emission.Error!void {
            const block = &self.frames[self.frame_len - 1].block;
            const operation = block.next orelse {
                self.frame_len -= 1;
                return;
            };
            block.next = operation.next_op;
            const name = operation.name.name;
            if (std.mem.eql(u8, name, FuncDialect.ReturnOp.operation_name)) {
                try self.writeFunctionReturn(FuncDialect.ReturnOp{ .op = operation });
                self.frame_len -= 1;
                return;
            }
            if (std.mem.eql(u8, name, ScfDialect.YieldOp.operation_name)) {
                try self.writeYield(
                    ScfDialect.YieldOp{ .op = operation },
                    block.terminator,
                );
                self.frame_len -= 1;
                return;
            }
            if (std.mem.eql(u8, name, ScfDialect.IfOp.operation_name)) {
                try self.beginIf(ScfDialect.IfOp{ .op = operation });
                return;
            }
            if (std.mem.eql(u8, name, ScfDialect.ForOp.operation_name)) {
                try self.beginFor(ScfDialect.ForOp{ .op = operation });
                return;
            }
            if (std.mem.eql(u8, name, ScfDialect.ConditionOp.operation_name)) {
                const while_op = switch (block.terminator) {
                    .while_condition => |owner| owner,
                    else => return error.CodeGenFailed,
                };
                try self.writeCondition(ScfDialect.ConditionOp{ .op = operation }, while_op);
                self.frame_len -= 1;
                return;
            }
            if (std.mem.eql(u8, name, ScfDialect.WhileOp.operation_name)) {
                try self.beginWhile(ScfDialect.WhileOp{ .op = operation });
                return;
            }
            try self.instructions.writeOperation(operation);
        }

        fn beginIf(self: *Self, if_op: ScfDialect.IfOp) emission.Error!void {
            try self.instructions.writeValue(if_op.getCondition());
            try self.out.writeByte(0x04);
            try self.out.writeByte(wasm.binary.empty_block_type);
            try self.push(.{ .if_control = .{
                .operation = if_op,
                .then_complete = false,
            } });
            try self.pushBlock(if_op.getThenBlock(), .{ .if_yield = if_op });
        }

        fn finishIf(self: *Self) emission.Error!void {
            const state = &self.frames[self.frame_len - 1].if_control;
            if (!state.then_complete) {
                state.then_complete = true;
                if (state.operation.getElseBlock()) |else_block| {
                    try self.out.writeByte(0x05);
                    try self.pushBlock(else_block, .{ .if_yield = state.operation });
                    return;
                }
            }
            try self.out.writeByte(0x0b);
            self.frame_len -= 1;
        }

        fn beginFor(self: *Self, for_op: ScfDialect.ForOp) emission.Error!void {
            const induction_local = try self.instructions.localFor(for_op.getInductionVar());
            try self.instructions.writeValue(for_op.getLowerBound());
            try self.instructions.writeLocalSet(induction_local);

            const iter_args = for_op.getIterArgs();
            const init_args = for_op.getInitArgs();
            if (iter_args.len != init_args.len) return error.CodeGenFailed;
            for (iter_args, init_args) |iter_arg, init_arg| {
                try self.instructions.writeValue(init_arg);
                try self.instructions.writeLocalSet(try self.instructions.localFor(iter_arg));
            }

            try self.out.writeByte(0x02);
            try self.out.writeByte(wasm.binary.empty_block_type);
            try self.out.writeByte(0x03);
            try self.out.writeByte(wasm.binary.empty_block_type);
            try self.instructions.writeValue(for_op.getInductionVar());
            try self.instructions.writeValue(for_op.getUpperBound());
            const scalar = types.scalarKindForType(for_op.getInductionVar().type) orelse
                return error.CodeGenFailed;
            try self.out.writeByte(try arithmetic.opcode.comparison(.lt, scalar));
            try self.out.writeByte(0x45);
            try self.out.writeByte(0x0d);
            try wasm.binary.writeUleb(self.out, @as(u32, 1));
            try self.push(.{ .for_control = for_op });
            try self.pushBlock(for_op.getBodyBlock(), .{ .for_yield = for_op });
        }

        fn finishFor(self: *Self) emission.Error!void {
            const for_op = self.frames[self.frame_len - 1].for_control;
            try self.out.writeByte(0x0b);
            try self.out.writeByte(0x0b);
            const iter_args = for_op.getIterArgs();
            if (iter_args.len != for_op.op.getNumResults()) return error.CodeGenFailed;
            for (iter_args, 0..) |iter_arg, index| {
                const result = for_op.getResult(index) orelse return error.CodeGenFailed;
                try self.instructions.writeLocalGet(try self.instructions.localFor(iter_arg));
                try self.instructions.writeLocalSet(try self.instructions.localFor(result));
            }
            self.frame_len -= 1;
        }

        /// The before block runs at the head of a `loop` inside a `block`. Its condition hands
        /// the forwarded values to the after block's locals and leaves the `block` when false,
        /// so those locals hold the results at exit. The after block's yield writes the before
        /// block's locals and branches back to the `loop`.
        fn beginWhile(self: *Self, while_op: ScfDialect.WhileOp) emission.Error!void {
            try self.writeCarried(while_op.op.getOperandValues(), while_op.getBeforeBlock());
            try self.out.writeAll(&.{ 0x02, wasm.binary.empty_block_type, 0x03, wasm.binary.empty_block_type });
            try self.push(.{ .while_control = .{ .operation = while_op, .after_started = false } });
            try self.pushBlock(while_op.getBeforeBlock(), .{ .while_condition = while_op });
        }

        fn writeCondition(
            self: *Self,
            condition: ScfDialect.ConditionOp,
            while_op: ScfDialect.WhileOp,
        ) emission.Error!void {
            try self.writeCarried(condition.getArgs(), while_op.getAfterBlock());
            try self.instructions.writeValue(condition.getCondition());
            try self.out.writeAll(&.{ 0x45, 0x0d, 0x01 }); // i32.eqz, br_if to the block's end
        }

        fn finishWhile(self: *Self) emission.Error!void {
            const state = &self.frames[self.frame_len - 1].while_control;
            if (!state.after_started) {
                state.after_started = true;
                try self.pushBlock(state.operation.getAfterBlock(), .{ .while_yield = state.operation });
                return;
            }
            try self.out.writeAll(&.{ 0x0b, 0x0b });
            const after = state.operation.getAfterBlock();
            if (after.getNumArguments() != state.operation.op.getNumResults()) return error.CodeGenFailed;
            for (0..after.getNumArguments()) |index| {
                const argument = after.getArgument(index) orelse return error.CodeGenFailed;
                const result = state.operation.op.getResult(index) orelse return error.CodeGenFailed;
                try self.instructions.writeLocalGet(try self.instructions.localFor(argument));
                try self.instructions.writeLocalSet(try self.instructions.localFor(result));
            }
            self.frame_len -= 1;
        }

        /// Writes `values` into `block`'s argument locals as one simultaneous assignment: every
        /// value is pushed before any local is set, so a permutation needs no temporaries.
        fn writeCarried(self: *Self, values: []const *ir.Value, block: *ir.Block) emission.Error!void {
            if (values.len != block.getNumArguments()) return error.CodeGenFailed;
            for (values) |value| try self.instructions.writeValue(value);
            var index = values.len;
            while (index > 0) {
                index -= 1;
                const argument = block.getArgument(index) orelse return error.CodeGenFailed;
                try self.instructions.writeLocalSet(try self.instructions.localFor(argument));
            }
        }

        fn writeFunctionReturn(
            self: *Self,
            operation: FuncDialect.ReturnOp,
        ) emission.Error!void {
            for (operation.getOperands()) |operand| try self.instructions.writeValue(operand);
            try self.out.writeByte(0x0f);
        }

        fn writeYield(
            self: *Self,
            operation: ScfDialect.YieldOp,
            terminator: Terminator,
        ) emission.Error!void {
            switch (terminator) {
                .function_return => return error.CodeGenFailed,
                .if_yield => |if_op| {
                    const operands = operation.getOperands();
                    if (operands.len != if_op.getNumResults()) return error.CodeGenFailed;
                    for (operands, 0..) |operand, index| {
                        const result = if_op.getResult(index) orelse return error.CodeGenFailed;
                        try self.instructions.writeValue(operand);
                        try self.instructions.writeLocalSet(try self.instructions.localFor(result));
                    }
                },
                .for_yield => |for_op| {
                    const operands = operation.getOperands();
                    const iter_args = for_op.getIterArgs();
                    if (operands.len != iter_args.len or
                        operands.len != for_op.op.getNumResults())
                    {
                        return error.CodeGenFailed;
                    }
                    for (operands, 0..) |operand, index| {
                        const result = for_op.getResult(index) orelse return error.CodeGenFailed;
                        try self.instructions.writeValue(operand);
                        try self.instructions.writeLocalSet(try self.instructions.localFor(result));
                    }
                    for (iter_args, 0..) |iter_arg, index| {
                        const result = for_op.getResult(index) orelse return error.CodeGenFailed;
                        try self.instructions.writeLocalGet(try self.instructions.localFor(result));
                        try self.instructions.writeLocalSet(try self.instructions.localFor(iter_arg));
                    }
                    try self.instructions.writeLocalGet(
                        try self.instructions.localFor(for_op.getInductionVar()),
                    );
                    try self.instructions.writeValue(for_op.getStep());
                    const scalar = types.scalarKindForType(for_op.getStep().type) orelse
                        return error.CodeGenFailed;
                    try self.out.writeByte(try arithmetic.opcode.binary(.add, scalar));
                    try self.instructions.writeLocalSet(
                        try self.instructions.localFor(for_op.getInductionVar()),
                    );
                    try self.out.writeByte(0x0c);
                    try wasm.binary.writeUleb(self.out, @as(u32, 0));
                },
                .while_condition => return error.CodeGenFailed,
                .while_yield => |while_op| {
                    try self.writeCarried(operation.getOperands(), while_op.getBeforeBlock());
                    try self.out.writeAll(&.{ 0x0c, 0x00 }); // br to the loop's head
                },
            }
        }

        fn pushBlock(
            self: *Self,
            block: *ir.Block,
            terminator: Terminator,
        ) emission.Error!void {
            const first = if (block.operations.head) |node|
                @as(*ir.Operation, @ptrCast(@alignCast(node)))
            else
                null;
            try self.push(.{ .block = .{ .next = first, .terminator = terminator } });
        }

        fn push(self: *Self, frame: Frame) emission.Error!void {
            if (self.frame_len == self.frames.len) return error.NestingLimitExceeded;
            self.frames[self.frame_len] = frame;
            self.frame_len += 1;
        }
    };
}

fn narrow(typ: ir.Type) bool {
    const scalar = emission.types.scalarKindForType(typ) orelse return false;
    return switch (scalar) {
        .bool, .i8, .u8, .i16, .u16 => true,
        else => false,
    };
}
