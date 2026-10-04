const std = @import("std");
const choir = @import("choir");
const ir = choir.ir;

pub const Operation = struct {
    ordinal: u32,

    pub fn validate(self: Operation, image: choir.bytecode.image.View) !void {
        if (self.ordinal >= image.operations.len) return error.UnboundProductInput;
    }
};

pub const Value = union(enum) {
    result: struct { operation: Operation, position: u32 },
    argument: struct { operation: Operation, region: u32, block: u32, position: u32 },

    pub fn ordinal(self: Value, image: choir.bytecode.image.View) !u32 {
        switch (self) {
            .result => |result| {
                try result.operation.validate(image);
                const range = image.operations[result.operation.ordinal].results;
                if (result.position >= range.count) return error.UnboundProductInput;
                return range.start + result.position;
            },
            .argument => |argument| {
                const region = image.region(argument.operation.ordinal, argument.region) orelse
                    return error.UnboundProductInput;
                const block = image.block(region, argument.block) orelse
                    return error.UnboundProductInput;
                const range = image.blocks[block].arguments;
                if (argument.position >= range.count) return error.UnboundProductInput;
                return range.start + argument.position;
            },
        }
    }
};

/// Turns pointers into numbers that survive a round trip through bytes, for the
/// encoder and comparer of a stage record, an immutable compile stage result.
/// The index numbers every operation of one program in preorder, by the order a
/// walk from the root visits it, in the same order the bytecode writer uses.
/// The walk stops with `error.RecordLimit` once it reaches `limit` operations.
/// A value is named by its defining operation and its result position, or for a
/// block argument by operation, region, block and position, and never by an
/// address. A lookup of an operation or value absent from the index fails with
/// `error.UnboundProductInput`. The numbering belongs to one job and one
/// program.
pub const Index = struct {
    allocator: std.mem.Allocator,
    limit: u32,
    operations: std.AutoHashMapUnmanaged(*ir.Operation, Operation) = .empty,
    values: std.AutoHashMapUnmanaged(*ir.Value, Value) = .empty,

    pub fn init(allocator: std.mem.Allocator, root: *ir.Operation, limit: u32) !Index {
        var self = Index{ .allocator = allocator, .limit = limit };
        errdefer self.deinit();
        _ = try root.walk(.{ .order = .pre_order }, &self, visit);
        return self;
    }

    pub fn deinit(self: *Index) void {
        self.operations.deinit(self.allocator);
        self.values.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn operation(self: *const Index, source: *ir.Operation) !Operation {
        return self.operations.get(source) orelse error.UnboundProductInput;
    }

    pub fn value(self: *const Index, source: *ir.Value) !Value {
        return self.values.get(source) orelse error.UnboundProductInput;
    }

    fn visit(self: *Index, op: *ir.Operation) !ir.WalkResult {
        if (self.operations.count() == self.limit) return error.RecordLimit;
        const ref = Operation{ .ordinal = @intCast(self.operations.count()) };
        try self.operations.putNoClobber(self.allocator, op, ref);
        for (op.results.items, 0..) |*result, position| {
            try self.addValue(result, .{ .result = .{
                .operation = ref,
                .position = @intCast(position),
            } });
        }
        for (op.regions.items, 0..) |*region, region_position| {
            var blocks = region.getBlocks();
            var block_position: u32 = 0;
            while (blocks.next()) |block| : (block_position += 1) {
                if (block_position == self.limit) return error.RecordLimit;
                for (block.arguments.items, 0..) |argument, position| {
                    try self.addValue(argument, .{ .argument = .{
                        .operation = ref,
                        .region = @intCast(region_position),
                        .block = block_position,
                        .position = @intCast(position),
                    } });
                }
            }
        }
        return .advance;
    }

    fn addValue(self: *Index, source: *ir.Value, ref: Value) !void {
        if (self.values.count() == self.limit) return error.RecordLimit;
        try self.values.putNoClobber(self.allocator, source, ref);
    }
};
