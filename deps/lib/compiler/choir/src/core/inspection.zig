const std = @import("std");
const alloc_arena = @import("alloc_arena");
const Operation = @import("operation/root.zig").Operation;
const Block = @import("block.zig").Block;
const interfaces = @import("interfaces/root.zig");

pub fn countOperationsNamed(root: *Operation, name: []const u8) usize {
    var state = CountNamed{ .name = name };
    _ = root.walk(.{ .order = .pre_order }, &state, CountNamed.visit) catch unreachable;
    return state.count;
}

pub fn findOperationNamed(root: *Operation, name: []const u8) ?*Operation {
    var state = FindNamed{ .name = name };
    _ = root.walk(.{ .order = .pre_order }, &state, FindNamed.visit) catch unreachable;
    return state.found;
}

pub fn moduleBodyBlock(module: *Operation) ?*Block {
    const region = module.getRegion(0) orelse return null;
    return region.getEntryBlock();
}

pub fn isFunctionDefinition(op: *Operation) bool {
    const iface = functionInterface(op) orelse return false;
    return iface.call(.hasBody, .{});
}

pub fn functionByName(module: *Operation, name: []const u8) ?*Operation {
    const block = moduleBodyBlock(module) orelse return null;
    return functionByNameInBlock(block, name);
}

pub fn functionByNameInBlock(block: *Block, name: []const u8) ?*Operation {
    var ops = block.getOperations();
    while (ops.next()) |op| {
        if (functionInterface(op) == null) continue;
        const symbol_name = symbolName(op) orelse continue;
        if (std.mem.eql(u8, symbol_name, name)) return op;
    }
    return null;
}

pub fn functionDefinitionByName(module: *Operation, name: []const u8) ?*Operation {
    const block = moduleBodyBlock(module) orelse return null;
    return functionDefinitionByNameInBlock(block, name);
}

pub fn functionDefinitionByNameInBlock(block: *Block, name: []const u8) ?*Operation {
    var ops = block.getOperations();
    while (ops.next()) |op| {
        if (!isFunctionDefinition(op)) continue;
        const symbol_name = symbolName(op) orelse continue;
        if (std.mem.eql(u8, symbol_name, name)) return op;
    }
    return null;
}

fn functionInterface(op: *Operation) ?Operation.interface_handle(interfaces.FunctionOpInterface) {
    if (symbolName(op) == null) return null;
    return op.interface(interfaces.FunctionOpInterface);
}

fn symbolName(op: *Operation) ?[]const u8 {
    const iface = op.interface(interfaces.SymbolOpInterface) orelse return null;
    return iface.call(.getSymbolName, .{});
}

const CountNamed = struct {
    name: []const u8,
    count: usize = 0,

    fn visit(self: *CountNamed, op: *Operation) void {
        if (std.mem.eql(u8, op.name.name, self.name)) {
            self.count += 1;
        }
    }
};

const FindNamed = struct {
    name: []const u8,
    found: ?*Operation = null,

    fn visit(self: *FindNamed, op: *Operation) void {
        if (self.found != null) return;
        if (std.mem.eql(u8, op.name.name, self.name)) {
            self.found = op;
        }
    }
};
