const std = @import("std");
const Value = @import("value.zig").Value;
const Type = @import("type.zig").Type;
const Location = @import("location.zig").Location;
const cfg = @import("cfg.zig");

pub const Block = struct {
    allocator: std.mem.Allocator,

    /// Values keep their addresses until the block is deinitialized.
    arguments: std.ArrayList(*Value),

    argument_locations: std.ArrayList(Location),

    operations: OperationList,

    parent: ?*anyopaque,

    prev: ?*Block,
    next: ?*Block,

    id: u32,

    predecessors: std.ArrayList(*Block),

    op_order_valid: bool,

    pub const order_stride: u32 = 8;
    pub const order_query_scan_limit: u8 = 8;

    pub const OperationList = struct {
        head: ?*anyopaque,
        tail: ?*anyopaque,

        pub fn init() OperationList {
            return .{
                .head = null,
                .tail = null,
            };
        }

        pub fn isEmpty(self: OperationList) bool {
            return self.head == null;
        }
    };

    pub const OperationIterator = struct {
        current: ?*anyopaque,

        pub fn next(self: *OperationIterator) ?*@import("operation/root.zig").Operation {
            const op_any = self.current orelse return null;
            const op: *@import("operation/root.zig").Operation = @ptrCast(@alignCast(op_any));
            self.current = op.next_op;
            return op;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Block {
        return .{
            .allocator = allocator,
            .arguments = .empty,
            .argument_locations = .empty,
            .operations = OperationList.init(),
            .parent = null,
            .prev = null,
            .next = null,
            .id = 0,
            .predecessors = .empty,
            .op_order_valid = true,
        };
    }

    fn recomputeOpOrder(self: *Block) void {
        var next_order: u32 = 0;
        var current = self.operations.head;
        while (current) |node| {
            const op: *@import("operation/root.zig").Operation = @ptrCast(@alignCast(node));
            op.order = next_order;
            next_order +|= order_stride;
            current = op.next_op;
        }
        self.op_order_valid = true;
    }

    pub fn sealOperationOrder(self: *Block) bool {
        if (self.op_order_valid) return false;
        self.recomputeOpOrder();
        return true;
    }

    pub fn operationPrecedes(
        self: *Block,
        first: *const @import("operation/root.zig").Operation,
        second: *const @import("operation/root.zig").Operation,
    ) bool {
        std.debug.assert(first.parent_block == self);
        std.debug.assert(second.parent_block == self);

        if (self.op_order_valid) return first.order < second.order;

        var next = first.next_op;
        var previous = first.prev_op;
        var scanned: u8 = 0;
        while (scanned < order_query_scan_limit) : (scanned += 1) {
            if (next) |op| {
                if (op == second) return true;
                next = op.next_op;
            }
            if (previous) |op| {
                if (op == second) return false;
                previous = op.prev_op;
            }
        }

        _ = self.sealOperationOrder();
        return first.order < second.order;
    }

    pub fn deinit(self: *Block) void {
        for (self.arguments.items) |argument| self.allocator.destroy(argument);
        self.arguments.deinit(self.allocator);
        self.argument_locations.deinit(self.allocator);
        self.predecessors.deinit(self.allocator);
    }

    pub fn addArgument(self: *Block, arg_type: Type, loc: Location) !*Value {
        const arg_num: u32 = @intCast(self.arguments.items.len);
        const value = try self.allocator.create(Value);
        errdefer self.allocator.destroy(value);
        value.* = .{
            .kind = .{ .block_argument = .{
                .owner = self,
                .arg_number = arg_num,
            } },
            .type = arg_type,
            .id = 0,
        };
        try self.argument_locations.append(self.allocator, loc);
        errdefer _ = self.argument_locations.pop();
        try self.arguments.append(self.allocator, value);
        return self.arguments.items[self.arguments.items.len - 1];
    }

    pub fn getArgumentLocation(self: *const Block, index: usize) ?Location {
        if (index >= self.argument_locations.items.len) return null;
        return self.argument_locations.items[index];
    }

    pub fn setArgumentLocation(self: *Block, index: usize, loc: Location) void {
        std.debug.assert(index < self.argument_locations.items.len);
        self.argument_locations.items[index] = loc;
    }

    pub fn getNumArguments(self: Block) usize {
        return self.arguments.items.len;
    }

    pub fn getArgument(self: *Block, index: usize) ?*Value {
        if (index >= self.arguments.items.len) return null;
        return self.arguments.items[index];
    }

    pub fn empty(self: Block) bool {
        return self.operations.isEmpty();
    }

    pub fn dropAllReferences(self: *Block) void {
        var ops = self.getOperations();
        while (ops.next()) |op| {
            op.dropAllReferences();
        }
    }

    pub fn hasNoDefinedValueUses(self: *Block) bool {
        for (self.arguments.items) |argument| {
            if (!argument.hasNoUses()) return false;
        }

        var ops = self.getOperations();
        while (ops.next()) |op| {
            if (!op.hasNoDefinedValueUses()) return false;
        }
        return true;
    }

    pub fn dropAllDefinedValueUses(self: *Block) void {
        for (self.arguments.items) |argument| {
            argument.dropAllUses();
        }

        var ops = self.getOperations();
        while (ops.next()) |op| {
            op.dropAllDefinedValueUses();
        }
    }

    pub fn getOperations(self: *Block) OperationIterator {
        return .{ .current = self.operations.head };
    }

    pub fn walkOperations(
        self: *Block,
        options: @import("operation/root.zig").Operation.WalkOptions,
        context: anytype,
        callback: anytype,
    ) anyerror!@import("operation/root.zig").Operation.WalkResult {
        var ops = self.getOperations();
        while (ops.next()) |op| {
            const result = try op.walk(options, context, callback);
            if (result.wasInterrupted()) return .interrupt;
        }
        return .advance;
    }

    pub fn getParentRegion(self: *const Block) ?*@import("region.zig").Region {
        const parent = self.parent orelse return null;
        return @ptrCast(@alignCast(parent));
    }

    pub fn getParentOperation(self: *const Block) ?*@import("operation/root.zig").Operation {
        const region = self.getParentRegion() orelse return null;
        return region.getParentOperation();
    }

    pub fn hasNoPredecessors(self: Block) bool {
        return self.predecessors.items.len == 0;
    }

    pub fn getNumPredecessors(self: Block) usize {
        return self.predecessors.items.len;
    }

    pub fn getPredecessors(self: *const Block) []const *Block {
        return self.predecessors.items;
    }

    pub fn getPredecessor(self: Block, index: usize) ?*Block {
        if (index >= self.predecessors.items.len) return null;
        return self.predecessors.items[index];
    }

    pub fn hasPredecessor(self: Block, pred: *Block) bool {
        for (self.predecessors.items) |existing| {
            if (existing == pred) return true;
        }
        return false;
    }

    pub fn getTerminator(self: Block) ?*anyopaque {
        return self.operations.tail;
    }

    pub fn addOperation(self: *Block, op: anytype) !void {
        const Operation = @import("operation/root.zig").Operation;
        const op_ptr: *Operation = @ptrCast(@alignCast(op));
        if (op_ptr.parent_block != null or op_ptr.prev_op != null or op_ptr.next_op != null) {
            return error.OperationAlreadyInserted;
        }

        try cfg.attach(self, op_ptr);

        op_ptr.parent_block = self;

        if (self.operations.tail) |tail| {
            const tail_op: *Operation = @ptrCast(@alignCast(tail));
            tail_op.next_op = op_ptr;
            op_ptr.prev_op = tail_op;
            if (self.op_order_valid) {
                if (tail_op.order <= std.math.maxInt(u32) - order_stride) {
                    op_ptr.order = tail_op.order + order_stride;
                } else {
                    self.op_order_valid = false;
                }
            }
        } else {
            self.operations.head = op_ptr;
            if (self.op_order_valid) op_ptr.order = 0;
        }
        self.operations.tail = op_ptr;
    }

    pub fn insertBefore(self: *Block, op: anytype, before: anytype) !void {
        const Operation = @import("operation/root.zig").Operation;
        const before_op: *Operation = @ptrCast(@alignCast(before));
        const op_ptr: *Operation = @ptrCast(@alignCast(op));
        if (before_op.parent_block != self) return error.OperationInsertBeforeDetached;
        if (op_ptr.parent_block != null or op_ptr.prev_op != null or op_ptr.next_op != null) {
            return error.OperationAlreadyInserted;
        }

        try cfg.attach(self, op_ptr);

        op_ptr.parent_block = self;

        const prev = before_op.prev_op;
        op_ptr.prev_op = prev;
        op_ptr.next_op = before_op;
        before_op.prev_op = op_ptr;

        if (prev) |prev_op| {
            prev_op.next_op = op_ptr;
        } else {
            self.operations.head = op_ptr;
        }

        if (self.op_order_valid) {
            const low: u64 = if (prev) |prev_op| @as(u64, prev_op.order) + 1 else 0;
            const high: u64 = before_op.order;
            if (high > low) {
                op_ptr.order = @intCast(low + (high - low) / 2);
            } else {
                self.op_order_valid = false;
            }
        }
    }

    fn unlinkOperation(self: *Block, op_ptr: *@import("operation/root.zig").Operation) bool {
        if (op_ptr.parent_block == null) return false;
        std.debug.assert(op_ptr.parent_block == self);

        cfg.detach(self, op_ptr);

        const prev = op_ptr.prev_op;
        const next = op_ptr.next_op;

        if (prev) |prev_op| {
            prev_op.next_op = next;
        } else {
            self.operations.head = next;
        }

        if (next) |next_op| {
            next_op.prev_op = prev;
        } else {
            self.operations.tail = prev;
        }

        op_ptr.prev_op = null;
        op_ptr.next_op = null;
        op_ptr.parent_block = null;
        return true;
    }

    pub fn detachOperation(self: *Block, op: anytype) void {
        const Operation = @import("operation/root.zig").Operation;
        const op_ptr: *Operation = @ptrCast(@alignCast(op));
        _ = self.unlinkOperation(op_ptr);
    }

    pub fn removeOperation(self: *Block, op: anytype) void {
        const Operation = @import("operation/root.zig").Operation;
        const op_ptr: *Operation = @ptrCast(@alignCast(op));
        if (self.unlinkOperation(op_ptr)) {
            op_ptr.dropAllReferences();
        }
    }

    pub fn format(self: Block, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("^bb{d}", .{self.id});
        if (self.arguments.items.len > 0) {
            try writer.writeAll("(");
            for (self.arguments.items, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{f}: {f}", .{ arg, arg.type });
            }
            try writer.writeAll(")");
        }
    }
};

test "block predecessor tracking" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Operation = @import("operation/root.zig").Operation;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(allocator, Context.Limits.testing);
    var entry = Block.init(allocator);
    var then_block = Block.init(allocator);
    var merge = Block.init(allocator);
    defer {
        ctx.deinit(allocator);
        entry.deinit();
        then_block.deinit();
        merge.deinit();
    }
    try ctx.allowUnregistered();

    try testing.expect(entry.hasNoPredecessors());
    try testing.expect(then_block.hasNoPredecessors());
    try testing.expect(merge.hasNoPredecessors());
    try testing.expectEqual(@as(usize, 0), entry.getNumPredecessors());

    var entry_state = Operation.State.init("test.entry_branch", .unknown);
    entry_state.addSuccessors(&.{ &then_block, &merge });
    try entry.addOperation(try ctx.createOperation(entry_state));
    var then_state = Operation.State.init("test.then_branch", .unknown);
    then_state.addSuccessors(&.{&merge});
    try then_block.addOperation(try ctx.createOperation(then_state));

    try testing.expect(!then_block.hasNoPredecessors());
    try testing.expectEqual(@as(usize, 1), then_block.getNumPredecessors());
    try testing.expectEqual(&entry, then_block.getPredecessor(0).?);

    try testing.expectEqual(@as(usize, 2), merge.getNumPredecessors());
    try testing.expect(merge.hasPredecessor(&entry));
    try testing.expect(merge.hasPredecessor(&then_block));
    try testing.expect(!merge.hasPredecessor(&merge));

    try testing.expect(entry.hasNoPredecessors());
}

test "block insert and remove operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Operation = @import("operation/root.zig").Operation;
    const context = @import("context/root.zig");

    var ctx = try context.Context.init(allocator, context.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    var block = Block.init(allocator);
    defer block.deinit();
    var succ = Block.init(allocator);
    defer succ.deinit();

    const loc = Location.getUnknown();

    var state1 = Operation.State.init("test.br", loc);
    state1.addSuccessors(&.{&succ});
    const op1 = try ctx.createOperation(state1);

    const state2 = Operation.State.init("test.noop", loc);
    const op2 = try ctx.createOperation(state2);

    try block.addOperation(op1);
    try testing.expectEqual(@as(usize, 1), succ.getNumPredecessors());
    try testing.expect(succ.hasPredecessor(&block));

    try block.insertBefore(op2, op1);
    const head: *Operation = @ptrCast(@alignCast(block.operations.head.?));
    const tail: *Operation = @ptrCast(@alignCast(block.operations.tail.?));
    try testing.expect(head == op2);
    try testing.expect(tail == op1);
    try testing.expect(op2.next_op == op1);
    try testing.expect(op1.prev_op == op2);

    block.removeOperation(op2);
    const head_after: *Operation = @ptrCast(@alignCast(block.operations.head.?));
    const tail_after: *Operation = @ptrCast(@alignCast(block.operations.tail.?));
    try testing.expect(head_after == op1);
    try testing.expect(tail_after == op1);
    try testing.expect(op1.prev_op == null);

    block.removeOperation(op1);
    try testing.expect(block.operations.head == null);
    try testing.expect(block.operations.tail == null);
    try testing.expect(op1.parent_block == null);
    try testing.expect(!succ.hasPredecessor(&block));
}

test "removing one of two block edges preserves the predecessor" {
    const testing = std.testing;
    const Operation = @import("operation/root.zig").Operation;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    var source = Block.init(testing.allocator);
    var target = Block.init(testing.allocator);
    defer {
        ctx.deinit(testing.allocator);
        source.deinit();
        target.deinit();
    }
    try ctx.allowUnregistered();

    var first_state = Operation.State.init("test.first_branch", .unknown);
    first_state.addSuccessors(&.{&target});
    const first = try ctx.createOperation(first_state);
    var second_state = Operation.State.init("test.second_branch", .unknown);
    second_state.addSuccessors(&.{&target});
    const second = try ctx.createOperation(second_state);

    try source.addOperation(first);
    try source.addOperation(second);
    source.removeOperation(first);

    try testing.expect(target.hasPredecessor(&source));
    try testing.expect(second.getSuccessor(0).? == &target);

    source.removeOperation(second);
    try testing.expect(target.hasNoPredecessors());
}

test "block op order stays coherent through append, insert, and move" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Operation = @import("operation/root.zig").Operation;
    const context = @import("context/root.zig");

    var ctx = try context.Context.init(allocator, context.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    var block = Block.init(allocator);
    defer block.deinit();

    const loc = Location.getUnknown();
    var ops: [6]*Operation = undefined;
    for (&ops) |*slot| {
        slot.* = try ctx.createOperation(Operation.State.init("test.noop", loc));
    }

    try block.addOperation(ops[0]);
    try block.addOperation(ops[1]);
    try block.addOperation(ops[2]);
    try testing.expect(block.op_order_valid);
    try testing.expect(ops[0].isBeforeInBlock(ops[2]));
    try testing.expect(!ops[2].isBeforeInBlock(ops[0]));

    try block.insertBefore(ops[3], ops[1]);
    try testing.expect(ops[0].isBeforeInBlock(ops[3]));
    try testing.expect(ops[3].isBeforeInBlock(ops[1]));

    try block.insertBefore(ops[4], ops[3]);
    try block.insertBefore(ops[5], ops[4]);
    try testing.expect(ops[0].isBeforeInBlock(ops[5]));
    try testing.expect(ops[5].isBeforeInBlock(ops[4]));
    try testing.expect(ops[4].isBeforeInBlock(ops[3]));
    try testing.expect(ops[3].isBeforeInBlock(ops[1]));
    try testing.expect(block.op_order_valid);

    try ops[1].moveBefore(ops[0]);
    try testing.expect(!block.op_order_valid);
    try testing.expect(ops[1].isBeforeInBlock(ops[0]));
    try testing.expect(!ops[0].isBeforeInBlock(ops[1]));
    try testing.expect(!block.op_order_valid);
    try testing.expect(block.sealOperationOrder());
    try testing.expect(block.op_order_valid);
    try testing.expect(!block.sealOperationOrder());

    block.removeOperation(ops[2]);
    try testing.expect(ops[1].isBeforeInBlock(ops[3]));
    try testing.expect(ops[0].isBeforeInBlock(ops[3]));
}

test "block order queries bound local scans before sealing" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Operation = @import("operation/root.zig").Operation;
    const context = @import("context/root.zig");

    var ctx = try context.Context.init(allocator, context.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    var block = Block.init(allocator);
    defer block.deinit();

    const loc = Location.getUnknown();
    var ops: [12]*Operation = undefined;
    for (&ops) |*slot| {
        slot.* = try ctx.createOperation(Operation.State.init("test.noop", loc));
        try block.addOperation(slot.*);
    }

    try ops[11].moveBefore(ops[0]);
    try testing.expect(!block.op_order_valid);
    try testing.expect(ops[11].isBeforeInBlock(ops[0]));
    try testing.expect(!block.op_order_valid);
    try testing.expect(ops[11].isBeforeInBlock(ops[9]));
    try testing.expect(block.op_order_valid);
}

test "block insertion rejects already parented operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Operation = @import("operation/root.zig").Operation;
    const context = @import("context/root.zig");

    var ctx = try context.Context.init(allocator, context.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    var first = Block.init(allocator);
    defer first.deinit();
    var second = Block.init(allocator);
    defer second.deinit();

    const op = try ctx.createOperation(Operation.State.init("test.noop", Location.getUnknown()));
    const anchor = try ctx.createOperation(Operation.State.init("test.anchor", Location.getUnknown()));
    const detached = try ctx.createOperation(Operation.State.init("test.detached", Location.getUnknown()));
    try first.addOperation(op);
    try second.addOperation(anchor);

    try testing.expectError(error.OperationAlreadyInserted, second.addOperation(op));
    try testing.expectError(error.OperationAlreadyInserted, second.insertBefore(op, anchor));
    try testing.expectError(error.OperationMoveDetached, detached.moveBefore(anchor));
    try testing.expectError(error.OperationMoveDetached, detached.moveToEnd(&second));
    const first_head: *Operation = @ptrCast(@alignCast(first.operations.head.?));
    const first_tail: *Operation = @ptrCast(@alignCast(first.operations.tail.?));
    const second_head: *Operation = @ptrCast(@alignCast(second.operations.head.?));
    const second_tail: *Operation = @ptrCast(@alignCast(second.operations.tail.?));
    try testing.expect(first_head == op);
    try testing.expect(first_tail == op);
    try testing.expect(op.parent_block == &first);
    try testing.expect(second_head == anchor);
    try testing.expect(second_tail == anchor);
}

test "operation movement preserves operands and repairs successor predecessors" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Operation = @import("operation/root.zig").Operation;
    const context = @import("context/root.zig");

    var ctx = try context.Context.init(allocator, context.Context.Limits.testing);

    var source = Block.init(allocator);
    defer source.deinit();
    var target = Block.init(allocator);
    defer target.deinit();
    var successor = Block.init(allocator);
    defer successor.deinit();
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const ty = try ctx.getDialectTypeFromName("test.i32");
    var producer_state = Operation.State.init("test.producer", Location.getUnknown());
    producer_state.addTypes(&.{ty});
    const producer = try ctx.createOperation(producer_state);

    var consumer_state = Operation.State.init("test.consumer", Location.getUnknown());
    consumer_state.addOperands(&.{producer.getResult(0).?});
    const consumer = try ctx.createOperation(consumer_state);

    var branch_state = Operation.State.init("test.br", Location.getUnknown());
    branch_state.addSuccessors(&.{&successor});
    const branch = try ctx.createOperation(branch_state);

    const anchor = try ctx.createOperation(Operation.State.init("test.anchor", Location.getUnknown()));

    try source.addOperation(producer);
    try source.addOperation(consumer);
    try source.addOperation(branch);
    try target.addOperation(anchor);

    try testing.expectEqual(@as(usize, 1), producer.getResult(0).?.getNumUses());
    try testing.expect(successor.hasPredecessor(&source));
    try testing.expect(!successor.hasPredecessor(&target));

    try consumer.moveBefore(anchor);
    const source_head_after_consumer_move: *Operation = @ptrCast(@alignCast(source.operations.head.?));
    const source_tail_after_consumer_move: *Operation = @ptrCast(@alignCast(source.operations.tail.?));
    const target_head_after_consumer_move: *Operation = @ptrCast(@alignCast(target.operations.head.?));
    try testing.expect(consumer.parent_block == &target);
    try testing.expect(source_head_after_consumer_move == producer);
    try testing.expect(source_tail_after_consumer_move == branch);
    try testing.expect(producer.next_op == branch);
    try testing.expect(branch.prev_op == producer);
    try testing.expect(target_head_after_consumer_move == consumer);
    try testing.expect(consumer.next_op == anchor);
    try testing.expect(anchor.prev_op == consumer);
    try testing.expect(consumer.getOperand(0).? == producer.getResult(0).?);
    try testing.expectEqual(@as(usize, 1), producer.getResult(0).?.getNumUses());

    try branch.moveToEnd(&target);
    const source_head_after_branch_move: *Operation = @ptrCast(@alignCast(source.operations.head.?));
    const source_tail_after_branch_move: *Operation = @ptrCast(@alignCast(source.operations.tail.?));
    const target_tail_after_branch_move: *Operation = @ptrCast(@alignCast(target.operations.tail.?));
    try testing.expect(branch.parent_block == &target);
    try testing.expect(source_head_after_branch_move == producer);
    try testing.expect(source_tail_after_branch_move == producer);
    try testing.expect(target_tail_after_branch_move == branch);
    try testing.expect(anchor.next_op == branch);
    try testing.expect(branch.prev_op == anchor);
    try testing.expect(!successor.hasPredecessor(&source));
    try testing.expect(successor.hasPredecessor(&target));
}

test "block detach operation preserves operand uses" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Operation = @import("operation/root.zig").Operation;
    const context = @import("context/root.zig");

    var ctx = try context.Context.init(allocator, context.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    var block = Block.init(allocator);
    defer block.deinit();

    const loc = Location.getUnknown();
    const ty = try ctx.getDialectTypeFromName("test.i32");

    var producer_state = Operation.State.init("test.producer", loc);
    producer_state.addTypes(&.{ty});
    const producer = try ctx.createOperation(producer_state);

    var consumer_state = Operation.State.init("test.consumer", loc);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    const consumer = try ctx.createOperation(consumer_state);

    try block.addOperation(producer);
    try block.addOperation(consumer);
    try testing.expectEqual(@as(usize, 1), producer.getResult(0).?.getNumUses());

    block.detachOperation(consumer);
    try testing.expect(consumer.parent_block == null);
    try testing.expectEqual(@as(usize, 1), producer.getResult(0).?.getNumUses());

    try block.addOperation(consumer);
    try testing.expectEqual(@as(usize, 1), producer.getResult(0).?.getNumUses());

    block.removeOperation(consumer);
    try testing.expectEqual(@as(usize, 0), producer.getResult(0).?.getNumUses());
}

test "block predecessor deduplication" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Operation = @import("operation/root.zig").Operation;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(allocator, Context.Limits.testing);
    var pred = Block.init(allocator);
    var succ = Block.init(allocator);
    defer {
        ctx.deinit(allocator);
        pred.deinit();
        succ.deinit();
    }
    try ctx.allowUnregistered();

    var state = Operation.State.init("test.duplicate_branch", .unknown);
    state.addSuccessors(&.{ &succ, &succ, &succ });
    try pred.addOperation(try ctx.createOperation(state));

    try testing.expectEqual(@as(usize, 1), succ.getNumPredecessors());
}

test "block predecessor removal" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Operation = @import("operation/root.zig").Operation;
    const Context = @import("context/root.zig").Context;

    var ctx = try Context.init(allocator, Context.Limits.testing);
    var a = Block.init(allocator);
    var b = Block.init(allocator);
    var c = Block.init(allocator);
    defer {
        ctx.deinit(allocator);
        a.deinit();
        b.deinit();
        c.deinit();
    }
    try ctx.allowUnregistered();

    var a_state = Operation.State.init("test.a_branch", .unknown);
    a_state.addSuccessors(&.{&c});
    const a_branch = try ctx.createOperation(a_state);
    try a.addOperation(a_branch);
    var b_state = Operation.State.init("test.b_branch", .unknown);
    b_state.addSuccessors(&.{&c});
    const b_branch = try ctx.createOperation(b_state);
    try b.addOperation(b_branch);
    try testing.expectEqual(@as(usize, 2), c.getNumPredecessors());

    a.removeOperation(a_branch);
    try testing.expectEqual(@as(usize, 1), c.getNumPredecessors());
    try testing.expect(!c.hasPredecessor(&a));
    try testing.expect(c.hasPredecessor(&b));

    b.removeOperation(b_branch);
    try testing.expect(c.hasNoPredecessors());
}

test "block arguments keep identity across nine appends" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;
    const Operation = @import("operation/root.zig").Operation;
    const verify = @import("verify.zig");
    const dump = @import("dump.zig");

    var block = Block.init(testing.allocator);
    defer block.deinit();
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    const typ = try ctx.getDialectTypeFromName("test.ty");
    const first = try block.addArgument(typ, .unknown);
    for (1..9) |_| _ = try block.addArgument(typ, .unknown);
    try testing.expectEqual(first, block.getArgument(0).?);

    var state = Operation.State.init("test.use", .unknown);
    state.addOperands(&.{first});
    const user = try ctx.createOperation(state);
    try block.addOperation(user);
    try verify.verifyBlock(&block, verify.default_options);
    try testing.expect(first.hasOneUse());
    const text = try dump.operationAlloc(testing.allocator, user);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("test.use(%0)\n", text);
}
