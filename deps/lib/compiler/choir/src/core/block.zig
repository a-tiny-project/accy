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
