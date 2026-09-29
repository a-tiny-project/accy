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
};

const BlockFrame = struct {
    next: ?*ir.Operation,
    terminator: Terminator,
};

const IfFrame = struct {
    operation: ScfDialect.IfOp,
    then_complete: bool,
};

pub const Frame = union(enum) {
    block: BlockFrame,
    if_control: IfFrame,
    for_control: ScfDialect.ForOp,
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
            try self.pushBlock(self.func.getEntryBlock(), .function_return);
            while (self.frame_len > 0) {
                switch (self.frames[self.frame_len - 1]) {
                    .block => try self.stepBlock(),
                    .if_control => try self.finishIf(),
                    .for_control => try self.finishFor(),
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
