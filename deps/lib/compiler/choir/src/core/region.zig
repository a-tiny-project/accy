const std = @import("std");
const alloc_arena = @import("alloc_arena");
const Block = @import("block.zig").Block;
const Mapping = @import("mapping.zig").Mapping;

pub const Region = struct {
    allocator: std.mem.Allocator,

    blocks: BlockList,

    parent: ?*anyopaque,

    pub const BlockList = struct {
        head: ?*Block,
        tail: ?*Block,
        size: usize,

        pub fn init() BlockList {
            return .{
                .head = null,
                .tail = null,
                .size = 0,
            };
        }

        pub fn isEmpty(self: BlockList) bool {
            return self.head == null;
        }

        pub fn front(self: BlockList) ?*Block {
            return self.head;
        }

        pub fn back(self: BlockList) ?*Block {
            return self.tail;
        }
    };

    pub const BlockIterator = struct {
        current: ?*Block,

        pub fn next(self: *BlockIterator) ?*Block {
            const block = self.current;
            if (self.current) |b| {
                self.current = b.next;
            }
            return block;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Region {
        return .{
            .allocator = allocator,
            .blocks = BlockList.init(),
            .parent = null,
        };
    }

    pub fn deinit(self: *Region) void {
        var current = self.blocks.head;
        while (current) |block| {
            const next = block.next;
            block.deinit();
            self.allocator.destroy(block);
            current = next;
        }
    }

    pub fn takeBody(self: *Region, source: *Region) !void {
        if (self == source) return;
        if (!source.empty() and !sameAllocator(self.allocator, source.allocator)) {
            return error.RegionAllocatorMismatch;
        }

        self.deinit();
        self.blocks = source.blocks;
        source.blocks = BlockList.init();

        var current = self.blocks.head;
        while (current) |block| {
            block.parent = self;
            current = block.next;
        }
    }

    pub fn dropAllReferences(self: *Region) void {
        var blocks = self.getBlocks();
        while (blocks.next()) |block| {
            block.dropAllReferences();
        }
    }

    pub fn hasNoDefinedValueUses(self: *Region) bool {
        var blocks = self.getBlocks();
        while (blocks.next()) |block| {
            if (!block.hasNoDefinedValueUses()) return false;
        }
        return true;
    }

    pub fn dropAllDefinedValueUses(self: *Region) void {
        var blocks = self.getBlocks();
        while (blocks.next()) |block| {
            block.dropAllDefinedValueUses();
        }
    }

    pub fn walkOperations(
        self: *Region,
        options: @import("operation/root.zig").Operation.WalkOptions,
        context: anytype,
        callback: anytype,
    ) anyerror!@import("operation/root.zig").Operation.WalkResult {
        var blocks = self.getBlocks();
        while (blocks.next()) |block| {
            const result = try block.walkOperations(options, context, callback);
            if (result.wasInterrupted()) return .interrupt;
        }
        return .advance;
    }

    pub fn cloneInto(self: *Region, dest: *Region, mapping: *Mapping) anyerror!void {
        if (self == dest) return error.RegionCloneIntoSelf;

        var source_block = self.blocks.head;
        while (source_block) |block| : (source_block = block.next) {
            const cloned_block = try dest.addBlock();
            try mapping.mapBlock(block, cloned_block);
            try cloned_block.arguments.ensureTotalCapacity(cloned_block.allocator, block.arguments.items.len);
            for (block.arguments.items, 0..) |argument, index| {
                const cloned_argument = try cloned_block.addArgument(
                    argument.type,
                    block.getArgumentLocation(index).?,
                );
                try mapping.mapValue(argument, cloned_argument);
            }
        }

        source_block = self.blocks.head;
        while (source_block) |block| : (source_block = block.next) {
            const cloned_block = mapping.lookupBlock(block).?;
            var ops = block.getOperations();
            while (ops.next()) |op| {
                const cloned_op = try op.cloneWithoutRegionsMapped(mapping, .{ .clone_operands = false });
                try cloned_block.addOperation(cloned_op);
            }
        }

        source_block = self.blocks.head;
        while (source_block) |block| : (source_block = block.next) {
            const cloned_block = mapping.lookupBlock(block).?;
            var source_ops = block.getOperations();
            var cloned_ops = cloned_block.getOperations();
            while (source_ops.next()) |op| {
                const cloned_op = cloned_ops.next().?;
                try remapOperationBody(op, cloned_op, mapping);
            }
        }
    }

    pub fn empty(self: Region) bool {
        return self.blocks.isEmpty();
    }

    pub fn hasOneBlock(self: Region) bool {
        return self.blocks.size == 1;
    }

    pub fn getEntryBlock(self: Region) ?*Block {
        return self.blocks.front();
    }

    pub fn addBlock(self: *Region) !*Block {
        const block = try self.allocator.create(Block);
        block.* = Block.init(self.allocator);
        block.parent = self;
        block.id = @intCast(self.blocks.size);

        block.prev = self.blocks.tail;
        block.next = null;
        if (self.blocks.tail) |tail| {
            tail.next = block;
        } else {
            self.blocks.head = block;
        }
        self.blocks.tail = block;
        self.blocks.size += 1;

        return block;
    }

    pub fn pushFront(self: *Region, block: *Block) void {
        block.parent = self;
        block.prev = null;
        block.next = self.blocks.head;

        if (self.blocks.head) |head| {
            head.prev = block;
        } else {
            self.blocks.tail = block;
        }
        self.blocks.head = block;
        self.blocks.size += 1;
    }

    pub fn pushBack(self: *Region, block: *Block) void {
        block.parent = self;
        block.prev = self.blocks.tail;
        block.next = null;

        if (self.blocks.tail) |tail| {
            tail.next = block;
        } else {
            self.blocks.head = block;
        }
        self.blocks.tail = block;
        self.blocks.size += 1;
    }

    pub fn eraseBlock(self: *Region, block: *Block) bool {
        if (block.parent != @as(*anyopaque, @ptrCast(self))) return false;
        if (!block.hasNoPredecessors()) return false;

        var op_node = block.operations.tail;
        while (op_node) |node| {
            const op: *@import("operation/root.zig").Operation = @ptrCast(@alignCast(node));
            op_node = op.prev_op;
            op.erase();
        }
        std.debug.assert(block.hasNoDefinedValueUses());

        const prev = block.prev;
        const next = block.next;

        if (prev) |prev_block| {
            prev_block.next = next;
        } else {
            self.blocks.head = next;
        }

        if (next) |next_block| {
            next_block.prev = prev;
        } else {
            self.blocks.tail = prev;
        }

        block.parent = null;
        block.prev = null;
        block.next = null;
        self.blocks.size -= 1;

        block.deinit();
        self.allocator.destroy(block);
        return true;
    }

    pub fn getParentOperation(self: *const Region) ?*@import("operation/root.zig").Operation {
        const parent = self.parent orelse return null;
        return @ptrCast(@alignCast(parent));
    }

    pub fn getBlocks(self: *Region) BlockIterator {
        return BlockIterator{ .current = self.blocks.head };
    }

    pub fn format(self: Region, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("{\n");
        var current = self.blocks.head;
        while (current) |block| {
            try writer.print("  {f}\n", .{block.*});
            current = block.next;
        }
        try writer.writeAll("}");
    }

    fn sameAllocator(a: std.mem.Allocator, b: std.mem.Allocator) bool {
        return a.ptr == b.ptr and a.vtable == b.vtable;
    }
};

fn remapOperationBody(source: *@import("operation/root.zig").Operation, dest: *@import("operation/root.zig").Operation, mapping: *Mapping) anyerror!void {
    var operands: []*@import("value.zig").Value = &.{};
    defer if (operands.len > 0) dest.allocator.free(operands);
    if (source.operand_values.len > 0) {
        operands = try dest.allocator.alloc(*@import("value.zig").Value, source.operand_values.len);
        for (source.operand_values, 0..) |operand, i| {
            operands[i] = mapping.lookupOrDefaultValue(operand);
        }
    }
    try dest.replaceOperands(operands);

    for (source.regions.items, 0..) |*region, i| {
        try region.cloneInto(&dest.regions.items[i], mapping);
    }
}
