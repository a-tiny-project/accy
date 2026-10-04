const std = @import("std");
const Operation = @import("operation/root.zig").Operation;
const Block = @import("block.zig").Block;
const Region = @import("region.zig").Region;
const Type = @import("type.zig").Type;
const Location = @import("location.zig").Location;
const context_mod = @import("context/root.zig");
const Context = context_mod.Context;

pub const OperationBuilder = struct {
    ir_ctx: *Context,
    insertion_block: ?*Block,
    insertion_before: ?*Operation,
    listener: ?Listener,

    pub const Listener = struct {
        context: ?*anyopaque = null,
        notify_operation_inserted: ?*const fn (?*anyopaque, *Operation, InsertPoint) anyerror!void = null,
        notify_block_inserted: ?*const fn (?*anyopaque, *Block) anyerror!void = null,

        pub fn notifyOperationInserted(self: Listener, op: *Operation, previous: InsertPoint) !void {
            if (self.notify_operation_inserted) |notify| {
                try notify(self.context, op, previous);
            }
        }

        pub fn notifyBlockInserted(self: Listener, block: *Block) !void {
            if (self.notify_block_inserted) |notify| {
                try notify(self.context, block);
            }
        }
    };

    pub const InsertPoint = struct {
        block: ?*Block = null,
        before: ?*Operation = null,

        pub fn isSet(self: InsertPoint) bool {
            return self.block != null;
        }
    };

    pub const InsertionGuard = struct {
        builder: ?*OperationBuilder,
        insert_point: InsertPoint,

        pub fn init(builder: *OperationBuilder) InsertionGuard {
            return .{
                .builder = builder,
                .insert_point = builder.saveInsertionPoint(),
            };
        }

        pub fn deinit(self: *InsertionGuard) void {
            const builder = self.builder orelse return;
            builder.restoreInsertionPoint(self.insert_point);
            self.builder = null;
        }
    };

    pub fn init(ir_ctx: *Context) OperationBuilder {
        return .{
            .ir_ctx = ir_ctx,
            .insertion_block = null,
            .insertion_before = null,
            .listener = null,
        };
    }

    pub fn setListener(self: *OperationBuilder, listener: ?Listener) void {
        self.listener = listener;
    }

    pub fn getListener(self: *const OperationBuilder) ?Listener {
        return self.listener;
    }

    pub fn clearInsertionPoint(self: *OperationBuilder) void {
        self.insertion_block = null;
        self.insertion_before = null;
    }

    pub fn hasInsertionPoint(self: *const OperationBuilder) bool {
        return self.insertion_block != null;
    }

    pub fn saveInsertionPoint(self: *const OperationBuilder) InsertPoint {
        return .{
            .block = self.insertion_block,
            .before = self.insertion_before,
        };
    }

    pub fn restoreInsertionPoint(self: *OperationBuilder, insert_point: InsertPoint) void {
        if (insert_point.isSet()) {
            self.insertion_block = insert_point.block;
            self.insertion_before = insert_point.before;
            return;
        }
        self.clearInsertionPoint();
    }

    pub fn insertionGuard(self: *OperationBuilder) InsertionGuard {
        return InsertionGuard.init(self);
    }

    pub fn setInsertionPoint(self: *OperationBuilder, block: *Block) void {
        self.setInsertionPointToEnd(block);
    }

    pub fn setInsertionPointToEnd(self: *OperationBuilder, block: *Block) void {
        self.insertion_block = block;
        self.insertion_before = null;
    }

    pub fn setInsertionPointBefore(self: *OperationBuilder, op: *Operation) void {
        self.insertion_block = op.getBlock();
        self.insertion_before = op;
    }

    pub fn setInsertionPointAfter(self: *OperationBuilder, op: *Operation) void {
        if (op.next_op) |next| {
            self.setInsertionPointBefore(next);
            return;
        }
        if (op.getBlock()) |block| {
            self.setInsertionPointToEnd(block);
            return;
        }
        self.clearInsertionPoint();
    }

    pub fn getInsertionBlock(self: *const OperationBuilder) ?*Block {
        return self.insertion_block;
    }

    pub fn getInsertionBefore(self: *const OperationBuilder) ?*Operation {
        return self.insertion_before;
    }

    pub fn createBlock(self: *OperationBuilder, region: *Region, arg_types: []const Type, locs: []const Location) !*Block {
        if (arg_types.len != locs.len) return error.BlockArgumentLocationMismatch;

        const previous = self.saveInsertionPoint();
        errdefer self.restoreInsertionPoint(previous);
        const block = try region.addBlock();
        errdefer std.debug.assert(region.eraseBlock(block));

        for (arg_types, locs) |arg_type, loc| {
            _ = try block.addArgument(arg_type, loc);
        }

        self.setInsertionPointToEnd(block);
        if (self.listener) |listener| {
            try listener.notifyBlockInserted(block);
        }
        return block;
    }

    pub fn createBlockWithLoc(self: *OperationBuilder, region: *Region, arg_types: []const Type, loc: Location) !*Block {
        const previous = self.saveInsertionPoint();
        errdefer self.restoreInsertionPoint(previous);
        const block = try region.addBlock();
        errdefer std.debug.assert(region.eraseBlock(block));

        for (arg_types) |arg_type| {
            _ = try block.addArgument(arg_type, loc);
        }

        self.setInsertionPointToEnd(block);
        if (self.listener) |listener| {
            try listener.notifyBlockInserted(block);
        }
        return block;
    }

    pub fn insert(self: *OperationBuilder, op: *Operation) !*Operation {
        var inserted = false;
        if (self.insertion_block) |block| {
            if (self.insertion_before) |before| {
                if (before.getBlock() == block) {
                    try block.insertBefore(op, before);
                } else {
                    try block.addOperation(op);
                }
            } else {
                try block.addOperation(op);
            }
            inserted = true;
        }

        if (inserted) {
            if (self.listener) |listener| {
                listener.notifyOperationInserted(op, .{}) catch |err| {
                    if (op.getBlock()) |block| block.detachOperation(op);
                    return err;
                };
            }
        }

        return op;
    }

    pub fn create(self: *OperationBuilder, state: Operation.State) !*Operation {
        const op = try self.ir_ctx.createOperation(state);
        errdefer if (op.getBlock() == null) op.erase();
        return try self.insert(op);
    }
};

fn expectBlockOperationNames(block: *Block, expected: []const []const u8) !void {
    var iter = block.getOperations();
    for (expected) |name| {
        const op = iter.next() orelse return error.TestExpectedOperation;
        try std.testing.expectEqualStrings(name, op.name.name);
    }
    try std.testing.expect(iter.next() == null);
}

const BuilderListenerRecorder = struct {
    inserted_ops: usize = 0,
    inserted_blocks: usize = 0,
    last_op: ?*Operation = null,
    last_block: ?*Block = null,
    last_previous: OperationBuilder.InsertPoint = .{},

    fn notifyOperationInserted(listener_context: ?*anyopaque, op: *Operation, previous: OperationBuilder.InsertPoint) !void {
        const recorder = try contextAsRecorder(listener_context);
        recorder.inserted_ops += 1;
        recorder.last_op = op;
        recorder.last_previous = previous;
    }

    fn notifyBlockInserted(listener_context: ?*anyopaque, block: *Block) !void {
        const recorder = try contextAsRecorder(listener_context);
        recorder.inserted_blocks += 1;
        recorder.last_block = block;
    }

    fn contextAsRecorder(listener_context: ?*anyopaque) !*BuilderListenerRecorder {
        return @ptrCast(@alignCast(listener_context orelse return error.MissingListenerContext));
    }
};

const RejectingBuilderListener = struct {
    fn notifyOperationInserted(_: ?*anyopaque, _: *Operation, _: OperationBuilder.InsertPoint) !void {
        return error.InsertionRejected;
    }

    fn notifyBlockInserted(_: ?*anyopaque, _: *Block) !void {
        return error.InsertionRejected;
    }
};
