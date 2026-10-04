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
