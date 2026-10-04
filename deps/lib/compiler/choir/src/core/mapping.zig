const std = @import("std");
const Value = @import("value.zig").Value;
const Block = @import("block.zig").Block;
const Operation = @import("operation/root.zig").Operation;

pub const Mapping = struct {
    allocator: std.mem.Allocator,

    values: std.AutoHashMapUnmanaged(*const Value, *Value) = .{},

    blocks: std.AutoHashMapUnmanaged(*const Block, *Block) = .{},

    operations: std.AutoHashMapUnmanaged(*const Operation, *Operation) = .{},

    pub fn init(allocator: std.mem.Allocator) Mapping {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Mapping) void {
        self.values.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        self.operations.deinit(self.allocator);
    }

    pub fn mapValue(self: *Mapping, source: *const Value, dest: *Value) !void {
        try self.values.put(self.allocator, source, dest);
    }

    pub fn lookupValue(self: *const Mapping, source: *const Value) ?*Value {
        return self.values.get(source);
    }

    pub fn lookupOrDefaultValue(self: *const Mapping, source: *Value) *Value {
        return self.lookupValue(source) orelse source;
    }

    pub fn mapBlock(self: *Mapping, source: *const Block, dest: *Block) !void {
        try self.blocks.put(self.allocator, source, dest);
    }

    pub fn lookupBlock(self: *const Mapping, source: *const Block) ?*Block {
        return self.blocks.get(source);
    }

    pub fn lookupOrDefaultBlock(self: *const Mapping, source: *Block) *Block {
        return self.lookupBlock(source) orelse source;
    }

    pub fn mapOperation(self: *Mapping, source: *const Operation, dest: *Operation) !void {
        try self.operations.put(self.allocator, source, dest);
    }

    pub fn lookupOperation(self: *const Mapping, source: *const Operation) ?*Operation {
        return self.operations.get(source);
    }

    pub fn lookupOrDefaultOperation(self: *const Mapping, source: *Operation) *Operation {
        return self.lookupOperation(source) orelse source;
    }
};

test "mapping stores value block and operation remaps with identity fallback" {
    const testing = std.testing;
    const Context = @import("context/root.zig").Context;

    var mapping = Mapping.init(testing.allocator);
    defer mapping.deinit();

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();
    const value_type = try ctx.getDialectTypeFromName("test.value");

    var source_block = Block.init(testing.allocator);
    defer source_block.deinit();
    var dest_block = Block.init(testing.allocator);
    defer dest_block.deinit();
    var external_block = Block.init(testing.allocator);
    defer external_block.deinit();

    const source_op = try ctx.createOperation(Operation.State.init("test.source", .unknown));
    const dest_op = try ctx.createOperation(Operation.State.init("test.dest", .unknown));
    const external_op = try ctx.createOperation(Operation.State.init("test.external", .unknown));

    var source_value = Value{
        .kind = .{ .block_argument = .{
            .owner = &source_block,
            .arg_number = 0,
        } },
        .type = value_type,
        .id = 1,
    };
    var dest_value = Value{
        .kind = .{ .block_argument = .{
            .owner = &dest_block,
            .arg_number = 0,
        } },
        .type = value_type,
        .id = 2,
    };
    var external_value = Value{
        .kind = .{ .block_argument = .{
            .owner = &external_block,
            .arg_number = 0,
        } },
        .type = value_type,
        .id = 3,
    };

    try mapping.mapValue(&source_value, &dest_value);
    try mapping.mapBlock(&source_block, &dest_block);
    try mapping.mapOperation(source_op, dest_op);

    try testing.expect(mapping.lookupValue(&source_value).? == &dest_value);
    try testing.expect(mapping.lookupBlock(&source_block).? == &dest_block);
    try testing.expect(mapping.lookupOperation(source_op).? == dest_op);
    try testing.expect(mapping.lookupOrDefaultValue(&external_value) == &external_value);
    try testing.expect(mapping.lookupOrDefaultBlock(&external_block) == &external_block);
    try testing.expect(mapping.lookupOrDefaultOperation(external_op) == external_op);
}
