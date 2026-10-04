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

test "inspection counts operations by name" {
    const testing = std.testing;
    const dialects = @import("../dialects/root.zig");
    const test_dialect = @import("../dialects/fixture/root.zig");
    const ir = @import("root.zig");

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();

    var ctx = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer ctx.deinit(arena.allocator());
    try ctx.allowUnregistered();
    try test_dialect.registerTestDialect(&ctx);

    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    const left = try ctx.createOperation(ir.Operation.State.init("test.leaf", loc));
    const right = try ctx.createOperation(ir.Operation.State.init("test.leaf", loc));
    const other = try ctx.createOperation(ir.Operation.State.init("test.other", loc));
    try block.addOperation(left);
    try block.addOperation(other);
    try block.addOperation(right);

    try testing.expectEqual(@as(usize, 2), countOperationsNamed(module.op, "test.leaf"));
    try testing.expectEqual(@as(usize, 1), countOperationsNamed(module.op, "test.other"));
    try testing.expectEqual(@as(usize, 0), countOperationsNamed(module.op, "test.missing"));
    try testing.expect(findOperationNamed(module.op, "test.leaf") == left);
    try testing.expect(findOperationNamed(module.op, "test.other") == other);
    try testing.expect(findOperationNamed(module.op, "test.missing") == null);
}

test "inspection finds function definitions by symbol name" {
    const testing = std.testing;
    const dialects = @import("../dialects/root.zig");
    const ir = @import("root.zig");

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();

    var ctx = try ir.Context.init(arena.allocator(), ir.Context.Limits.testing);
    defer ctx.deinit(arena.allocator());

    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    const block = module.getBodyBlock();

    const body = try dialects.FuncDialect.FuncOp.create(&ctx, loc, "body", &.{}, &.{});
    const declaration = try dialects.FuncDialect.FuncOp.createDeclaration(&ctx, loc, "declaration", &.{}, &.{});
    try block.addOperation(declaration.op);
    try block.addOperation(body.op);

    try testing.expect(functionByName(module.op, "body") == body.op);
    try testing.expect(functionByNameInBlock(block, "body") == body.op);
    try testing.expect(functionByName(module.op, "declaration") == declaration.op);
    try testing.expect(functionDefinitionByName(module.op, "body") == body.op);
    try testing.expect(functionDefinitionByNameInBlock(block, "body") == body.op);
    try testing.expect(functionDefinitionByName(module.op, "declaration") == null);
    try testing.expect(functionByName(module.op, "missing") == null);
}
