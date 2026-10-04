const alloc_phase = @import("alloc_phase");
const alloc_arena = @import("alloc_arena");
const std = @import("std");
const core = @import("root.zig");
const dialects = @import("../dialects/root.zig");
const context_test = @import("context/test.zig");
const dialects_test = @import("dialects/test.zig");
const interfaces_test = @import("interfaces/test.zig");

const Attribute = core.Attribute;
const Block = core.Block;
const Context = core.Context;
const interfaces = core.interfaces;
const Location = core.Location;
const Mapping = core.Mapping;
const NamedAttribute = core.NamedAttribute;
const Operation = core.Operation;
const Region = core.Region;
const Type = core.Type;
const Value = core.Value;

test {
    _ = @import("rewrite/test.zig");
    std.testing.refAllDecls(core);
    _ = context_test;
    _ = dialects_test;
    _ = interfaces_test;
}

test "Choir parse round-trips dumped module operations" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try core.Context.init(allocator, core.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerChoirDialect(&ctx);
    _ = try ctx.getOrLoadDialect("builtin");
    _ = try ctx.getOrLoadDialect("arith");
    _ = try ctx.getOrLoadDialect("func");

    const loc = core.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    const body = module.getBodyBlock();
    const i32_type = try dialects.ArithDialect.getScalarType(&ctx, .i32);
    var func = try dialects.FuncDialect.FuncOp.create(
        &ctx,
        loc,
        "parse_round_trip",
        &.{i32_type},
        &.{i32_type},
    );
    try body.addOperation(func.op);
    const entry = func.getEntryBlock();
    const ret = try dialects.FuncDialect.ReturnOp.create(
        &ctx,
        loc,
        &.{func.getArgument(0)},
    );
    try entry.addOperation(ret.op);

    const text = try core.dump.operationAlloc(allocator, module.op);
    const parsed = try core.parse.operation(&ctx, text);
    defer parsed.erase();

    const reparsed = try core.dump.operationAlloc(allocator, parsed);
    try testing.expectEqualStrings(text, reparsed);
}

test "Choir parse round-trips atomic memory operations and their orderings" {
    const testing = std.testing;
    const memref = dialects.MemrefDialect;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try core.Context.init(allocator, core.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try dialects.registerChoirDialect(&ctx);
    _ = try ctx.getOrLoadDialect("builtin");
    _ = try ctx.getOrLoadDialect("arith");
    _ = try ctx.getOrLoadDialect("func");
    _ = try ctx.getOrLoadDialect("memref");

    const loc = core.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(&ctx, loc);
    const body = module.getBodyBlock();
    const i64_type = try dialects.ArithDialect.getScalarType(&ctx, .i64);
    const i32_type = try dialects.ArithDialect.getScalarType(&ctx, .i32);
    const index_type = try dialects.ArithDialect.getIndexType(&ctx);
    const words = try memref.getMemrefType1D(&ctx, 4, i64_type, .host);
    const halves = try memref.getMemrefType1D(&ctx, 4, i32_type, .host);
    var func = try dialects.FuncDialect.FuncOp.create(
        &ctx,
        loc,
        "atomic_round_trip",
        &.{ words, halves, index_type, i64_type, i32_type },
        &.{i64_type},
    );
    try body.addOperation(func.op);
    const entry = func.getEntryBlock();
    const word_buffer = func.getArgument(0);
    const half_buffer = func.getArgument(1);
    const slot = func.getArgument(2);
    const word = func.getArgument(3);
    const half = func.getArgument(4);

    const loaded = try memref.AtomicLoadOp.create(&ctx, loc, word_buffer, slot, i64_type, .acquire);
    try entry.addOperation(loaded.op);
    const released = try memref.AtomicStoreOp.create(&ctx, loc, word, word_buffer, slot, .release);
    try entry.addOperation(released.op);
    const published = try memref.AtomicStoreOp.create(&ctx, loc, half, half_buffer, slot, .seq_cst);
    try entry.addOperation(published.op);
    const exchanged = try memref.AtomicCasOp.createOrdered(
        &ctx,
        loc,
        loaded.getResult(),
        word,
        word_buffer,
        slot,
        i64_type,
        .acq_rel,
    );
    try entry.addOperation(exchanged.op);
    const unordered = try memref.AtomicCasOp.create(&ctx, loc, half, half, half_buffer, slot, i32_type);
    try entry.addOperation(unordered.op);
    const fence = try memref.FenceOp.create(&ctx, loc, .system, .seq_cst);
    try entry.addOperation(fence.op);
    const ret = try dialects.FuncDialect.ReturnOp.create(&ctx, loc, &.{exchanged.getResult()});
    try entry.addOperation(ret.op);

    const text = try core.dump.operationAlloc(allocator, module.op);
    try testing.expect(std.mem.indexOf(u8, text, "memref.atomic_load") != null);
    try testing.expect(std.mem.indexOf(u8, text, "memref.atomic_store") != null);
    try testing.expect(std.mem.indexOf(u8, text, "memref.atomic_cas") != null);
    try testing.expect(std.mem.indexOf(u8, text, "memref.fence") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"acq_rel\"") != null);

    const parsed = try core.parse.operation(&ctx, text);
    defer parsed.erase();
    const reparsed = try core.dump.operationAlloc(allocator, parsed);
    try testing.expectEqualStrings(text, reparsed);

    var module_ops = parsed.getRegion(0).?.getEntryBlock().?.getOperations();
    const parsed_func = module_ops.next().?;
    var func_ops = parsed_func.getRegion(0).?.getEntryBlock().?.getOperations();
    var orderings: [4]dialects.FenceOrdering = undefined;
    var ordering_count: usize = 0;
    while (func_ops.next()) |op| {
        if (std.mem.eql(u8, op.name.name, "memref.atomic_load")) {
            orderings[ordering_count] = (memref.AtomicLoadOp{ .op = op }).getOrdering().?;
            ordering_count += 1;
        }
        if (std.mem.eql(u8, op.name.name, "memref.atomic_store")) {
            orderings[ordering_count] = (memref.AtomicStoreOp{ .op = op }).getOrdering().?;
            ordering_count += 1;
        }
        if (std.mem.eql(u8, op.name.name, "memref.atomic_cas")) {
            if (ordering_count == 3) {
                orderings[ordering_count] = (memref.AtomicCasOp{ .op = op }).getOrdering();
                ordering_count += 1;
            } else {
                try testing.expectEqual(dialects.FenceOrdering.seq_cst, (memref.AtomicCasOp{ .op = op }).getOrdering());
            }
        }
    }
    try testing.expectEqual(@as(usize, 4), ordering_count);
    try testing.expectEqualSlices(
        dialects.FenceOrdering,
        &.{ .acquire, .release, .seq_cst, .acq_rel },
        &orderings,
    );
}

test "Choir parse round-trips list attributes" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try core.Context.init(allocator, core.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();
    _ = try dialects.ArithDialect.getScalarType(&ctx, .i32);
    _ = try dialects.ArithDialect.getScalarType(&ctx, .f32);

    const text =
        \\test.attrs() {array = [true, [false, 4:i32], "tail"], empty = [], strings = ["alpha", "beta"], types = [!arith.i32, !arith.f32]}
        \\
    ;

    const parsed = try core.parse.operation(&ctx, text);
    defer parsed.erase();

    const reparsed = try core.dump.operationAlloc(allocator, parsed);
    try testing.expectEqualStrings(text, reparsed);
}

const WalkNameRecorder = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayList([]const u8) = .empty,
    skip_name: ?[]const u8 = null,
    interrupt_name: ?[]const u8 = null,

    fn deinit(self: *WalkNameRecorder) void {
        self.names.deinit(self.allocator);
    }

    fn record(self: *WalkNameRecorder, op: *Operation) !Operation.WalkResult {
        try self.names.append(self.allocator, op.name.name);
        if (self.interrupt_name) |name| {
            if (std.mem.eql(u8, name, op.name.name)) return .interrupt;
        }
        if (self.skip_name) |name| {
            if (std.mem.eql(u8, name, op.name.name)) return .skip;
        }
        return .advance;
    }
};

fn expectWalkNames(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_name, actual_name| {
        try std.testing.expectEqualStrings(expected_name, actual_name);
    }
}

test "use-def chain basic operations" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const unknown_type = try ctx.getDialectTypeFromName("test.ty");
    var producer_state = Operation.State.init("test.producer", .unknown);
    producer_state.addTypes(&.{unknown_type});
    const producer = try ctx.createOperation(producer_state);

    const result = producer.getResult(0).?;
    try testing.expect(result.hasNoUses());
    try testing.expect(producer.hasNoUses());
    try testing.expectEqual(@as(usize, 0), result.getNumUses());

    var consumer_state = Operation.State.init("test.consumer", .unknown);
    consumer_state.addOperands(&.{result});
    _ = try ctx.createOperation(consumer_state);

    try testing.expect(!result.hasNoUses());
    try testing.expect(result.hasOneUse());
    try testing.expect(!producer.hasNoUses());
    try testing.expectEqual(@as(usize, 1), result.getNumUses());

    var consumer2_state = Operation.State.init("test.consumer2", .unknown);
    consumer2_state.addOperands(&.{result});
    _ = try ctx.createOperation(consumer2_state);

    try testing.expect(!result.hasNoUses());
    try testing.expect(!result.hasOneUse());
    try testing.expectEqual(@as(usize, 2), result.getNumUses());
}

test "use-def chain drop uses on erase" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const unknown_type = try ctx.getDialectTypeFromName("test.ty");
    var producer_state = Operation.State.init("test.producer", .unknown);
    producer_state.addTypes(&.{unknown_type});
    const producer = try ctx.createOperation(producer_state);

    const result = producer.getResult(0).?;

    {
        var consumer_state = Operation.State.init("test.consumer", .unknown);
        consumer_state.addOperands(&.{result});
        const consumer = try ctx.createOperation(consumer_state);

        try testing.expectEqual(@as(usize, 1), result.getNumUses());

        consumer.erase();
    }

    try testing.expect(result.hasNoUses());
    try testing.expectEqual(@as(usize, 0), result.getNumUses());
}

test "operation hasNoUses with zero results" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const state = Operation.State.init("test.void_op", .unknown);
    const op = try ctx.createOperation(state);

    try testing.expect(op.hasNoUses());
}

test "operation walk orders and controls nested traversal" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var child_region = core.context.initRegion(&ctx);
    defer child_region.deinit();
    const child_block = try child_region.addBlock();
    const grandchild = try ctx.createOperation(Operation.State.init("test.walk.grandchild", .unknown));
    try child_block.addOperation(grandchild);

    var parent_state = Operation.State.init("test.walk.parent", .unknown);
    parent_state.addRegionBodies(&.{&child_region});
    const parent = try ctx.createOperation(parent_state);

    var root_region = core.context.initRegion(&ctx);
    defer root_region.deinit();
    const root_block = try root_region.addBlock();
    const first = try ctx.createOperation(Operation.State.init("test.walk.first", .unknown));
    const last = try ctx.createOperation(Operation.State.init("test.walk.last", .unknown));
    try root_block.addOperation(first);
    try root_block.addOperation(parent);
    try root_block.addOperation(last);

    var root_state = Operation.State.init("test.walk.root", .unknown);
    root_state.addRegionBodies(&.{&root_region});
    const root = try ctx.createOperation(root_state);

    var pre_order = WalkNameRecorder{ .allocator = testing.allocator };
    defer pre_order.deinit();
    try testing.expectEqual(Operation.WalkResult.advance, try root.walk(.{ .order = .pre_order }, &pre_order, WalkNameRecorder.record));
    try expectWalkNames(pre_order.names.items, &.{
        "test.walk.root",
        "test.walk.first",
        "test.walk.parent",
        "test.walk.grandchild",
        "test.walk.last",
    });

    var post_order = WalkNameRecorder{ .allocator = testing.allocator };
    defer post_order.deinit();
    try testing.expectEqual(Operation.WalkResult.advance, try root.walk(.{ .order = .post_order }, &post_order, WalkNameRecorder.record));
    try expectWalkNames(post_order.names.items, &.{
        "test.walk.first",
        "test.walk.grandchild",
        "test.walk.parent",
        "test.walk.last",
        "test.walk.root",
    });

    var skip_parent = WalkNameRecorder{
        .allocator = testing.allocator,
        .skip_name = "test.walk.parent",
    };
    defer skip_parent.deinit();
    try testing.expectEqual(Operation.WalkResult.advance, try root.walk(.{ .order = .pre_order }, &skip_parent, WalkNameRecorder.record));
    try expectWalkNames(skip_parent.names.items, &.{
        "test.walk.root",
        "test.walk.first",
        "test.walk.parent",
        "test.walk.last",
    });

    var interrupt_parent = WalkNameRecorder{
        .allocator = testing.allocator,
        .interrupt_name = "test.walk.parent",
    };
    defer interrupt_parent.deinit();
    try testing.expectEqual(Operation.WalkResult.interrupt, try root.walk(.{ .order = .pre_order }, &interrupt_parent, WalkNameRecorder.record));
    try expectWalkNames(interrupt_parent.names.items, &.{
        "test.walk.root",
        "test.walk.first",
        "test.walk.parent",
    });
}

test "operation walk accepts void callbacks" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var body = core.context.initRegion(&ctx);
    defer body.deinit();
    const block = try body.addBlock();
    const child = try ctx.createOperation(Operation.State.init("test.walk.child", .unknown));
    try block.addOperation(child);

    var state = Operation.State.init("test.walk.void_root", .unknown);
    state.addRegionBodies(&.{&body});
    const root = try ctx.createOperation(state);

    const Counter = struct {
        count: usize = 0,

        fn visit(self: *@This(), op: *Operation) void {
            _ = op;
            self.count += 1;
        }
    };

    var counter = Counter{};
    try testing.expectEqual(Operation.WalkResult.advance, try root.walk(.{ .order = .pre_order }, &counter, Counter.visit));
    try testing.expectEqual(@as(usize, 2), counter.count);
}

test "operation exposes parent and ancestry navigation" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var child_body = core.context.initRegion(&ctx);
    defer child_body.deinit();
    const child_block = try child_body.addBlock();
    const first = try ctx.createOperation(Operation.State.init("test.nav.first", .unknown));
    const second = try ctx.createOperation(Operation.State.init("test.nav.second", .unknown));
    try child_block.addOperation(first);
    try child_block.addOperation(second);

    var parent_state = Operation.State.init("test.nav.parent", .unknown);
    parent_state.addRegionBodies(&.{&child_body});
    const parent = try ctx.createOperation(parent_state);
    const parent_region = parent.getRegion(0).?;
    const parent_block = parent_region.getEntryBlock().?;

    var root_body = core.context.initRegion(&ctx);
    defer root_body.deinit();
    const root_block = try root_body.addBlock();
    const sibling = try ctx.createOperation(Operation.State.init("test.nav.sibling", .unknown));
    try root_block.addOperation(parent);
    try root_block.addOperation(sibling);

    var root_state = Operation.State.init("test.nav.root", .unknown);
    root_state.addRegionBodies(&.{&root_body});
    const root = try ctx.createOperation(root_state);
    const root_region = root.getRegion(0).?;

    try testing.expect(parent.getParentRegion() == root_region);
    try testing.expect(parent.getParentOp() == root);
    try testing.expect(root_block.getParentRegion() == root_region);
    try testing.expect(root_block.getParentOperation() == root);
    try testing.expect(first.getParentRegion() == parent_region);
    try testing.expect(first.getParentOp() == parent);
    try testing.expect(parent_block.getParentOperation() == parent);

    try testing.expect(root.isAncestor(root));
    try testing.expect(root.isProperAncestor(parent));
    try testing.expect(root.isProperAncestor(first));
    try testing.expect(parent.isProperAncestor(first));
    try testing.expect(!parent.isProperAncestor(parent));
    try testing.expect(!first.isProperAncestor(parent));

    try testing.expect(parent.isBeforeInBlock(sibling));
    try testing.expect(first.isBeforeInBlock(second));
    try testing.expect(!second.isBeforeInBlock(first));
    try testing.expect(!first.isBeforeInBlock(parent));
}

test "operation defined value use query includes nested regions" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const value_type = try ctx.getDialectTypeFromName("test.value");

    var body = core.context.initRegion(&ctx);
    defer body.deinit();
    const body_block = try body.addBlock();
    const body_arg = try body_block.addArgument(value_type, .unknown);

    var parent_state = Operation.State.init("test.parent", .unknown);
    parent_state.addRegionBodies(&.{&body});
    const parent = try ctx.createOperation(parent_state);
    const entry = parent.getRegion(0).?.getEntryBlock().?;

    var nested_state = Operation.State.init("test.nested_producer", .unknown);
    nested_state.addTypes(&.{value_type});
    const nested = try ctx.createOperation(nested_state);
    try entry.addOperation(nested);

    var user_state = Operation.State.init("test.user", .unknown);
    user_state.addOperands(&.{ body_arg, nested.getResult(0).? });
    const user = try ctx.createOperation(user_state);

    try testing.expect(!parent.hasNoDefinedValueUses());
    try testing.expect(!parent.getRegion(0).?.hasNoDefinedValueUses());
    try testing.expect(!entry.hasNoDefinedValueUses());

    user.dropAllReferences();

    try testing.expect(parent.hasNoDefinedValueUses());
    try testing.expect(parent.getRegion(0).?.hasNoDefinedValueUses());
    try testing.expect(entry.hasNoDefinedValueUses());
}

test "operation dropAllDefinedValueUses includes nested regions" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const value_type = try ctx.getDialectTypeFromName("test.value");

    var body = core.context.initRegion(&ctx);
    defer body.deinit();
    const body_block = try body.addBlock();
    const body_arg = try body_block.addArgument(value_type, .unknown);

    var parent_state = Operation.State.init("test.parent", .unknown);
    parent_state.addRegionBodies(&.{&body});
    const parent = try ctx.createOperation(parent_state);
    const entry = parent.getRegion(0).?.getEntryBlock().?;

    var nested_state = Operation.State.init("test.nested_producer", .unknown);
    nested_state.addTypes(&.{value_type});
    const nested = try ctx.createOperation(nested_state);
    try entry.addOperation(nested);
    const nested_result = nested.getResult(0).?;

    var user_state = Operation.State.init("test.user", .unknown);
    user_state.addOperands(&.{ body_arg, nested_result });
    const user = try ctx.createOperation(user_state);

    try testing.expectEqual(@as(usize, 1), body_arg.getNumUses());
    try testing.expectEqual(@as(usize, 1), nested_result.getNumUses());

    parent.dropAllDefinedValueUses();

    try testing.expect(parent.hasNoDefinedValueUses());
    try testing.expect(body_arg.hasNoUses());
    try testing.expect(nested_result.hasNoUses());
    try testing.expectEqual(body_arg, user.getOperand(0).?);
    try testing.expectEqual(nested_result, user.getOperand(1).?);

    user.erase();
}

test "operation dropAllReferences recurses through nested operations" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const value_type = try ctx.getDialectTypeFromName("test.value");
    var external_state = Operation.State.init("test.external_producer", .unknown);
    external_state.addTypes(&.{value_type});
    const external = try ctx.createOperation(external_state);
    const external_result = external.getResult(0).?;

    var body = core.context.initRegion(&ctx);
    defer body.deinit();
    _ = try body.addBlock();

    var parent_state = Operation.State.init("test.parent", .unknown);
    parent_state.addRegionBodies(&.{&body});
    const parent = try ctx.createOperation(parent_state);
    const entry = parent.getRegion(0).?.getEntryBlock().?;

    var nested_state = Operation.State.init("test.nested_consumer", .unknown);
    nested_state.addOperands(&.{external_result});
    const nested = try ctx.createOperation(nested_state);
    try entry.addOperation(nested);

    try testing.expectEqual(@as(usize, 1), external_result.getNumUses());

    parent.dropAllReferences();

    try testing.expect(external_result.hasNoUses());
    try testing.expectEqual(@as(usize, 0), external_result.getNumUses());
}

test "operation dropAllReferences clears successor predecessors" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var pred = Block.init(testing.allocator);
    defer pred.deinit();
    var succ = Block.init(testing.allocator);
    defer succ.deinit();

    var state = Operation.State.init("test.branch", .unknown);
    state.addSuccessors(&.{&succ});
    const op = try ctx.createOperation(state);
    try pred.addOperation(op);

    try testing.expectEqual(@as(usize, 1), op.getNumSuccessors());
    try testing.expect(succ.hasPredecessor(&pred));

    op.dropAllReferences();

    try testing.expectEqual(@as(usize, 0), op.getNumSuccessors());
    try testing.expect(!succ.hasPredecessor(&pred));
}

test "operation erase owns nested context operations" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const value_type = try ctx.getDialectTypeFromName("test.value");

    var body = core.context.initRegion(&ctx);
    defer body.deinit();
    _ = try body.addBlock();

    var parent_state = Operation.State.init("test.parent", .unknown);
    parent_state.addRegionBodies(&.{&body});
    const parent = try ctx.createOperation(parent_state);
    const entry = parent.getRegion(0).?.getEntryBlock().?;

    var producer_state = Operation.State.init("test.producer", .unknown);
    producer_state.addTypes(&.{value_type});
    const producer = try ctx.createOperation(producer_state);
    try entry.addOperation(producer);

    var consumer_state = Operation.State.init("test.consumer", .unknown);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    const consumer = try ctx.createOperation(consumer_state);
    try entry.addOperation(consumer);

    try testing.expectEqual(@as(usize, 3), ctx.operationCount());

    parent.erase();

    try testing.expectEqual(@as(usize, 0), ctx.operationCount());
}

test "region eraseBlock removes predecessor-free blocks in reverse operation order" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    var region = core.context.initRegion(&ctx);
    defer {
        region.deinit();
        ctx.deinit(testing.allocator);
    }
    try ctx.allowUnregistered();

    const entry = try region.addBlock();
    const with_predecessor = try region.addBlock();
    const with_defined_uses = try region.addBlock();
    const removable = try region.addBlock();
    var detached = Block.init(testing.allocator);
    defer detached.deinit();

    try testing.expectEqual(@as(usize, 4), region.blocks.size);
    const value_type = try ctx.getDialectTypeFromName("test.value");
    const block_arg = try with_defined_uses.addArgument(value_type, .unknown);
    var producer_state = Operation.State.init("test.producer", .unknown);
    producer_state.addTypes(&.{value_type});
    const producer = try ctx.createOperation(producer_state);
    try with_defined_uses.addOperation(producer);
    var consumer_state = Operation.State.init("test.consumer", .unknown);
    consumer_state.addOperands(&.{ block_arg, producer.getResult(0).? });
    const consumer = try ctx.createOperation(consumer_state);
    try with_defined_uses.addOperation(consumer);
    var branch_state = Operation.State.init("test.branch", .unknown);
    branch_state.addSuccessors(&.{with_predecessor});
    const branch = try ctx.createOperation(branch_state);
    try entry.addOperation(branch);

    try testing.expect(!region.eraseBlock(&detached));
    try testing.expect(!region.eraseBlock(with_predecessor));
    try testing.expect(region.eraseBlock(with_defined_uses));
    try testing.expect(region.eraseBlock(removable));

    try testing.expectEqual(@as(usize, 2), region.blocks.size);
    try testing.expect(region.blocks.head == entry);
    try testing.expect(entry.next == with_predecessor);
    try testing.expect(with_predecessor.prev == entry);
    try testing.expect(region.blocks.tail == with_predecessor);
    branch.erase();
    try testing.expectEqual(@as(usize, 0), ctx.operationCount());
}

test "use-def chain multiple operands same value" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const unknown_type = try ctx.getDialectTypeFromName("test.ty");
    var producer_state = Operation.State.init("test.producer", .unknown);
    producer_state.addTypes(&.{unknown_type});
    const producer = try ctx.createOperation(producer_state);

    const result = producer.getResult(0).?;

    var consumer_state = Operation.State.init("test.binary_op", .unknown);
    consumer_state.addOperands(&.{ result, result });
    _ = try ctx.createOperation(consumer_state);

    try testing.expectEqual(@as(usize, 2), result.getNumUses());
}

test "operation caches operand values and result types" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const unknown_type = try ctx.getDialectTypeFromName("test.ty");

    var producer_a_state = Operation.State.init("test.producer_a", .unknown);
    producer_a_state.addTypes(&.{unknown_type});
    const producer_a = try ctx.createOperation(producer_a_state);
    const a_result = producer_a.getResult(0).?;

    var producer_b_state = Operation.State.init("test.producer_b", .unknown);
    producer_b_state.addTypes(&.{unknown_type});
    const producer_b = try ctx.createOperation(producer_b_state);
    const b_result = producer_b.getResult(0).?;

    var consumer_state = Operation.State.init("test.consumer", .unknown);
    consumer_state.addOperands(&.{ a_result, b_result });
    consumer_state.addTypes(&.{unknown_type});
    const consumer = try ctx.createOperation(consumer_state);

    const cached_operands = consumer.getOperandValues();
    try testing.expectEqual(@as(usize, 2), cached_operands.len);
    try testing.expectEqual(a_result, cached_operands[0]);
    try testing.expectEqual(b_result, cached_operands[1]);
    try testing.expectEqual(a_result, consumer.getOperand(0).?);
    try testing.expectEqual(b_result, consumer.getOperand(1).?);

    const cached_result_types = consumer.getResultTypes();
    try testing.expectEqual(@as(usize, 1), cached_result_types.len);
    try testing.expectEqual(unknown_type, cached_result_types[0]);
    try testing.expectEqual(@as(usize, 1), consumer.getNumResults());
}

test "operation creation consumes only Context-reserved storage" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./operation/root.zig").OperationFixedStorage, "choir_operation_storage_integration"),
        );
    }

    const testing = std.testing;

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var ctx = try Context.init(failing.allocator(), Context.Limits.testing);
    defer ctx.deinit(failing.allocator());
    try ctx.allowUnregistered();
    _ = try ctx.registerOperation("test.operation.storage", .{});
    try ctx.registerOperationPropertiesModel(
        "test.operation.storage",
        interfaces.singleAttributePropertiesModel("test.operation.storage.properties", "value"),
    );

    const storage = Type.DialectTypeStorage{
        .name = "test.operation.storage",
        .param_key = "",
        .type_info = null,
        .print_fn = null,
        .unique_id = 1,
    };
    const ty = Type{ .type_id = .dialect_type, .impl = &storage };
    var owner: u8 = 0;
    var operand = Value{
        .kind = .{ .block_argument = .{ .owner = &owner, .arg_number = 0 } },
        .type = ty,
        .id = 1,
    };
    var successor = Block.init(failing.allocator());
    defer successor.deinit();

    var state = Operation.State.init("test.operation.storage", .unknown);
    state.addOperands(&.{&operand});
    state.addTypes(&.{ty});
    state.addRegion();
    state.addSuccessors(&.{&successor});

    const before = failing.alloc_index;
    const op = try Operation.create(&ctx, state);
    try testing.expectEqual(before, failing.alloc_index);
    try testing.expectEqual(alloc_phase.capacity.Phase.steady, op.storage.status());
    try testing.expectEqual(@as(usize, 1), op.getNumOperands());
    try testing.expectEqual(@as(usize, 1), op.getNumResults());
    try testing.expectEqual(@as(usize, 1), op.getNumRegions());
    try testing.expectEqual(@as(usize, 1), op.getNumSuccessors());
    try testing.expect(op.getPropertiesRef() != null);
    op.destroy();
}

test "common operation storage allocator retries and reuses exact classes" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var pool = Operation.StorageAllocator.init(failing.allocator());
    defer pool.deinit();
    const allocator = pool.allocator();

    try testing.expectEqual(
        @as(?[*]u8, null),
        allocator.rawAlloc(672, .@"8", @returnAddress()),
    );
    failing.fail_index = std.math.maxInt(usize);
    const first = allocator.rawAlloc(
        672,
        .@"8",
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    allocator.rawFree(first[0..672], .@"8", @returnAddress());

    const first_allocations = failing.alloc_index;
    failing.fail_index = first_allocations;
    var first_chunk: [Operation.StorageAllocator.items_per_chunk][*]u8 = undefined;
    for (&first_chunk) |*slot| {
        slot.* = allocator.rawAlloc(
            672,
            .@"8",
            @returnAddress(),
        ) orelse return error.OutOfMemory;
    }
    try testing.expectEqual(first_allocations, failing.alloc_index);
    try testing.expectEqual(@intFromPtr(first), @intFromPtr(first_chunk[0]));
    try testing.expectEqual(
        @as(?[*]u8, null),
        allocator.rawAlloc(672, .@"8", @returnAddress()),
    );

    failing.fail_index = std.math.maxInt(usize);
    const first_overflow = allocator.rawAlloc(
        672,
        .@"8",
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    for (first_chunk) |slot| allocator.rawFree(slot[0..672], .@"8", @returnAddress());
    allocator.rawFree(first_overflow[0..672], .@"8", @returnAddress());

    failing.fail_index = failing.alloc_index;
    try testing.expectEqual(
        @as(?[*]u8, null),
        allocator.rawAlloc(752, .@"8", @returnAddress()),
    );
    failing.fail_index = std.math.maxInt(usize);
    const second = allocator.rawAlloc(
        752,
        .@"8",
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    allocator.rawFree(second[0..752], .@"8", @returnAddress());

    const second_allocations = failing.alloc_index;
    failing.fail_index = second_allocations;
    const second_reused = allocator.rawAlloc(
        752,
        .@"8",
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    try testing.expectEqual(second_allocations, failing.alloc_index);
    try testing.expectEqual(@intFromPtr(second), @intFromPtr(second_reused));
    allocator.rawFree(second_reused[0..752], .@"8", @returnAddress());

    failing.fail_index = failing.alloc_index;
    try testing.expectEqual(
        @as(?[*]u8, null),
        allocator.rawAlloc(640, .@"8", @returnAddress()),
    );
    failing.fail_index = std.math.maxInt(usize);
    const third = allocator.rawAlloc(
        640,
        .@"8",
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    allocator.rawFree(third[0..640], .@"8", @returnAddress());

    const third_allocations = failing.alloc_index;
    failing.fail_index = third_allocations;
    const third_reused = allocator.rawAlloc(
        640,
        .@"8",
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    try testing.expectEqual(third_allocations, failing.alloc_index);
    try testing.expectEqual(@intFromPtr(third), @intFromPtr(third_reused));
    allocator.rawFree(third_reused[0..640], .@"8", @returnAddress());

    failing.fail_index = failing.alloc_index;
    try testing.expectEqual(
        @as(?[*]u8, null),
        allocator.rawAlloc(696, .@"8", @returnAddress()),
    );
    failing.fail_index = std.math.maxInt(usize);
    const fourth = allocator.rawAlloc(
        696,
        .@"8",
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    allocator.rawFree(fourth[0..696], .@"8", @returnAddress());

    const fourth_allocations = failing.alloc_index;
    failing.fail_index = fourth_allocations;
    const fourth_reused = allocator.rawAlloc(
        696,
        .@"8",
        @returnAddress(),
    ) orelse return error.OutOfMemory;
    try testing.expectEqual(fourth_allocations, failing.alloc_index);
    try testing.expectEqual(@intFromPtr(fourth), @intFromPtr(fourth_reused));
    allocator.rawFree(fourth_reused[0..696], .@"8", @returnAddress());
}

test "operation replaceOperands updates caches and uses" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const unknown_type = try ctx.getDialectTypeFromName("test.ty");

    var producer_1_state = Operation.State.init("test.producer_1", .unknown);
    producer_1_state.addTypes(&.{unknown_type});
    const producer_1 = try ctx.createOperation(producer_1_state);
    const r1 = producer_1.getResult(0).?;

    var producer_2_state = Operation.State.init("test.producer_2", .unknown);
    producer_2_state.addTypes(&.{unknown_type});
    const producer_2 = try ctx.createOperation(producer_2_state);
    const r2 = producer_2.getResult(0).?;

    var producer_3_state = Operation.State.init("test.producer_3", .unknown);
    producer_3_state.addTypes(&.{unknown_type});
    const producer_3 = try ctx.createOperation(producer_3_state);
    const r3 = producer_3.getResult(0).?;

    var consumer_state = Operation.State.init("test.consumer_replace", .unknown);
    consumer_state.addOperands(&.{r1});
    const consumer = try ctx.createOperation(consumer_state);

    try testing.expectEqual(@as(usize, 1), r1.getNumUses());

    try consumer.replaceOperands(&.{ r2, r3 });

    try testing.expectEqual(@as(usize, 0), r1.getNumUses());
    try testing.expectEqual(@as(usize, 1), r2.getNumUses());
    try testing.expectEqual(@as(usize, 1), r3.getNumUses());

    const cached_operands = consumer.getOperandValues();
    try testing.expectEqual(@as(usize, 2), cached_operands.len);
    try testing.expectEqual(r2, cached_operands[0]);
    try testing.expectEqual(r3, cached_operands[1]);

    try consumer.replaceOperands(consumer.getOperandValues()[1..]);
    try testing.expectEqual(@as(usize, 0), r2.getNumUses());
    try testing.expectEqual(@as(usize, 1), r3.getNumUses());
    try testing.expectEqual(@as(usize, 1), consumer.getNumOperands());
    try testing.expectEqual(r3, consumer.getOperand(0).?);
}

test "operation replaceOperands rejects exhausted Context spill capacity before mutation" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./context/root.zig").Context, "choir_context_spill_exhaustion"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./operation/root.zig").OperationFixedStorage, "choir_operation_storage_spill"),
        );
    }

    const testing = std.testing;

    var limits = Context.Limits.testing;
    limits.operations.nested_bytes = 0;
    var ctx = try Context.init(testing.allocator, limits);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const unknown_type = try ctx.getDialectTypeFromName("test.ty");
    var producer_state = Operation.State.init("test.producer", .unknown);
    producer_state.addTypes(&.{ unknown_type, unknown_type, unknown_type });
    const producer = try ctx.createOperation(producer_state);
    const first = producer.getResult(0).?;
    const second = producer.getResult(1).?;
    const third = producer.getResult(2).?;

    var consumer_state = Operation.State.init("test.consumer", .unknown);
    consumer_state.addOperands(&.{first});
    const consumer = try ctx.createOperation(consumer_state);

    try testing.expectError(error.OutOfMemory, consumer.replaceOperands(&.{ second, third }));
    try testing.expectEqual(@as(usize, 1), consumer.getNumOperands());
    try testing.expectEqual(first, consumer.getOperand(0).?);
    try testing.expectEqual(@as(usize, 1), first.getNumUses());
    try testing.expectEqual(@as(usize, 0), second.getNumUses());
    try testing.expectEqual(@as(usize, 0), third.getNumUses());
}

test "operation setOperandValue updates caches and uses" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const unknown_type = try ctx.getDialectTypeFromName("test.ty");

    var producer_1_state = Operation.State.init("test.producer_1", .unknown);
    producer_1_state.addTypes(&.{unknown_type});
    const producer_1 = try ctx.createOperation(producer_1_state);
    const r1 = producer_1.getResult(0).?;

    var producer_2_state = Operation.State.init("test.producer_2", .unknown);
    producer_2_state.addTypes(&.{unknown_type});
    const producer_2 = try ctx.createOperation(producer_2_state);
    const r2 = producer_2.getResult(0).?;

    var consumer_state = Operation.State.init("test.consumer_set_operand", .unknown);
    consumer_state.addOperands(&.{r1});
    const consumer = try ctx.createOperation(consumer_state);

    try testing.expectEqual(@as(usize, 1), r1.getNumUses());
    try testing.expectEqual(@as(usize, 0), r2.getNumUses());

    consumer.setOperandValue(0, r2);

    try testing.expectEqual(@as(usize, 0), r1.getNumUses());
    try testing.expectEqual(@as(usize, 1), r2.getNumUses());
    try testing.expectEqual(r2, consumer.getOperand(0).?);
    try testing.expectEqual(r2, consumer.getOperandValues()[0]);
}

test "value replaceAllUsesWith updates operand caches" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const unknown_type = try ctx.getDialectTypeFromName("test.ty");

    var producer_1_state = Operation.State.init("test.producer_1", .unknown);
    producer_1_state.addTypes(&.{unknown_type});
    const producer_1 = try ctx.createOperation(producer_1_state);
    const r1 = producer_1.getResult(0).?;

    var producer_2_state = Operation.State.init("test.producer_2", .unknown);
    producer_2_state.addTypes(&.{unknown_type});
    const producer_2 = try ctx.createOperation(producer_2_state);
    const r2 = producer_2.getResult(0).?;

    var consumer_state = Operation.State.init("test.consumer_replace_all_uses", .unknown);
    consumer_state.addOperands(&.{r1});
    const consumer = try ctx.createOperation(consumer_state);

    try testing.expectEqual(@as(usize, 1), r1.getNumUses());
    try testing.expectEqual(@as(usize, 0), r2.getNumUses());

    r1.replaceAllUsesWith(r2);

    try testing.expectEqual(@as(usize, 0), r1.getNumUses());
    try testing.expectEqual(@as(usize, 1), r2.getNumUses());
    try testing.expectEqual(r2, consumer.getOpOperand(0).?.value);
    try testing.expectEqual(r2, consumer.getOperand(0).?);
    try testing.expectEqual(r2, consumer.getOperandValues()[0]);
}

test "operation attribute lookup uses sorted storage" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const state = Operation.State.init("test.attr_op", .unknown);
    const op = try ctx.createOperation(state);

    const unit_attr = try ctx.getDialectAttr("test.unit", "");
    try op.setAttr("zeta", unit_attr);
    try op.setAttr("alpha", unit_attr);
    try op.setAttr("mid", unit_attr);

    try testing.expect(op.getAttr("alpha") != null);
    try testing.expect(op.getAttr("mid") != null);
    try testing.expect(op.getAttr("zeta") != null);
    try testing.expect(op.removeAttr("mid"));
    try testing.expect(op.getAttr("mid") == null);
    try testing.expect(!op.removeAttr("mid"));

    const attrs = op.getRawDictionaryAttrs();
    try testing.expect(std.mem.order(u8, attrs[0].name, attrs[1].name) != .gt);
    try testing.expectEqual(attrs.ptr, op.getRawDictionaryAttrs().ptr);
    try testing.expectEqual(attrs.len, op.countDiscardableAttrs());
    try testing.expect(op.getDiscardableAttr("alpha") != null);
    try testing.expect(op.removeDiscardableAttr("zeta"));
    try testing.expect(op.getAttr("zeta") == null);
}

test "inherent attribute names are not discardable attributes" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("test.inherent_attr_op", .{});
    try ctx.registerOperationInherentAttributeName("test.inherent_attr_op", "value");

    const state = Operation.State.init("test.inherent_attr_op", .unknown);
    const op = try ctx.createOperation(state);

    const value_attr = try ctx.getI64Attr(1);
    const note_attr = try ctx.getI64Attr(2);
    try op.setAttr("value", value_attr);
    try op.setAttr("debug.note", note_attr);

    const raw_attrs = op.getRawDictionaryAttrs();
    try testing.expectEqual(@as(usize, 2), raw_attrs.len);
    try testing.expectEqualStrings("debug.note", raw_attrs[0].name);
    try testing.expectEqualStrings("value", raw_attrs[1].name);
    try testing.expect(op.hasInherentAttributeName("value"));
    try testing.expect(!op.isDiscardableAttrName("value"));
    try testing.expect(op.isDiscardableAttrName("debug.note"));
    try testing.expect(op.getAttr("value") != null);
    try testing.expect(op.getDiscardableAttr("value") == null);
    try testing.expect(op.getDiscardableAttr("debug.note") != null);
    try testing.expectEqual(@as(usize, 1), op.countDiscardableAttrs());

    var iter = op.getDiscardableAttrs();
    const only_attr = iter.next() orelse return error.TestExpectedDiscardableAttr;
    try testing.expectEqualStrings("debug.note", only_attr.name);
    try testing.expect(iter.next() == null);

    try testing.expectError(error.InherentAttributeName, op.setDiscardableAttr("value", value_attr));
    try testing.expect(!op.removeDiscardableAttr("value"));
    try testing.expect(op.getAttr("value") != null);
    try testing.expect(op.removeAttr("value"));
    try testing.expect(op.getAttr("value") == null);
}

test "operation typed attribute lookup checks inherent and discardable storage" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("test.typed_attr_op", .{});
    try ctx.registerOperationInherentAttributeName("test.typed_attr_op", "value");
    try ctx.registerOperationPropertiesModel(
        "test.typed_attr_op",
        interfaces.singleAttributePropertiesModel("test.typed_attr_op.properties", "value"),
    );

    const state = Operation.State.init("test.typed_attr_op", .unknown);
    const op = try ctx.createOperation(state);

    try op.setAttr("value", try ctx.getI64Attr(7));
    try op.setAttr("debug.note", try ctx.getStringAttr("note"));

    try testing.expectEqual(
        @as(i64, 7),
        op.getAttrAs(Attribute.IntegerAttr, "value").?.getValue(),
    );
    try testing.expect(op.getAttrAs(Attribute.StringAttr, "value") == null);

    try testing.expectEqualStrings(
        "note",
        op.getAttrAs(Attribute.StringAttr, "debug.note").?.getValue(),
    );
    try testing.expectEqualStrings(
        "note",
        op.getDiscardableAttrAs(Attribute.StringAttr, "debug.note").?.getValue(),
    );
    try testing.expect(op.getDiscardableAttrAs(Attribute.IntegerAttr, "debug.note") == null);
    try testing.expect(op.getDiscardableAttrAs(Attribute.IntegerAttr, "value") == null);
}

test "operation attribute iterator merges raw and inherent attributes" {
    const testing = std.testing;

    const TestProperties = struct {
        value: ?Attribute = null,
        predicate: ?Attribute = null,

        fn from(storage: *anyopaque) *@This() {
            return @ptrCast(@alignCast(storage));
        }

        fn fromConst(storage: *const anyopaque) *const @This() {
            return @ptrCast(@alignCast(storage));
        }

        fn init(storage: *anyopaque, _: std.mem.Allocator) anyerror!void {
            from(storage).* = .{};
        }

        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

        fn get(_: *const Operation, storage: *const anyopaque, name: []const u8) ?Attribute {
            const self = fromConst(storage);
            if (std.mem.eql(u8, name, "value")) return self.value;
            if (std.mem.eql(u8, name, "predicate")) return self.predicate;
            return null;
        }

        fn set(_: *Operation, storage: *anyopaque, name: []const u8, attr: Attribute) anyerror!bool {
            const self = from(storage);
            if (std.mem.eql(u8, name, "value")) {
                self.value = attr;
                return true;
            }
            if (std.mem.eql(u8, name, "predicate")) {
                self.predicate = attr;
                return true;
            }
            return false;
        }

        fn remove(_: *Operation, storage: *anyopaque, name: []const u8) bool {
            const self = from(storage);
            if (std.mem.eql(u8, name, "value")) {
                const existed = self.value != null;
                self.value = null;
                return existed;
            }
            if (std.mem.eql(u8, name, "predicate")) {
                const existed = self.predicate != null;
                self.predicate = null;
                return existed;
            }
            return false;
        }

        fn copyProperties(dest: *anyopaque, source: *const anyopaque) anyerror!void {
            from(dest).* = fromConst(source).*;
        }

        const model = interfaces.OperationPropertiesModel{
            .name = "test.properties",
            .size = @sizeOf(@This()),
            .alignment = std.mem.Alignment.fromByteUnits(@alignOf(@This())),
            .init = init,
            .deinit = deinit,
            .getInherentAttr = get,
            .setInherentAttr = set,
            .removeInherentAttr = remove,
            .copyProperties = copyProperties,
        };
    };

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("test.property_attr_op", .{});
    try ctx.registerOperationInherentAttributeNames(
        "test.property_attr_op",
        &.{ "unused", "value", "missing", "predicate" },
    );
    try ctx.registerOperationPropertiesModel("test.property_attr_op", TestProperties.model);

    const value_attr = try ctx.getI64Attr(11);
    const note_attr = try ctx.getI64Attr(12);
    const predicate_attr = try ctx.getBoolAttr(true);
    const alpha_attr = try ctx.getI64Attr(13);
    const missing_attr = try ctx.getI64Attr(14);
    const omega_attr = try ctx.getI64Attr(15);
    const zeta_attr = try ctx.getI64Attr(16);
    const collision_attr = try ctx.getI64Attr(17);
    const attrs = [_]NamedAttribute{
        .{ .name = "value", .value = value_attr },
        .{ .name = "debug.note", .value = note_attr },
        .{ .name = "zeta", .value = zeta_attr },
        .{ .name = "alpha", .value = alpha_attr },
        .{ .name = "missing", .value = missing_attr },
        .{ .name = "omega", .value = omega_attr },
    };
    var state = Operation.State.init("test.property_attr_op", .unknown);
    state.addAttributes(&attrs);
    const op = try ctx.createOperation(state);

    try testing.expect(op.getAttr("value").?.eql(value_attr));
    try testing.expect(op.getAttr("debug.note").?.eql(note_attr));
    try testing.expectEqual(@as(usize, 5), op.getRawDictionaryAttrs().len);

    try op.setAttr("predicate", predicate_attr);
    _ = try op.raw_dictionary_attrs.set(testing.allocator, "value", collision_attr);
    try testing.expect(op.getAttr("predicate").?.eql(predicate_attr));
    try testing.expect(op.getAttr("value").?.eql(value_attr));
    try testing.expect(op.raw_dictionary_attrs.get("value").?.eql(collision_attr));

    const raw_ptr = op.getRawDictionaryAttrs().ptr;
    const raw_len = op.getRawDictionaryAttrs().len;
    const raw_capacity = op.raw_dictionary_attrs.capacity();
    var raw_snapshot: [6]NamedAttribute = undefined;
    @memcpy(&raw_snapshot, op.getRawDictionaryAttrs());

    const expected_names = [_][]const u8{
        "alpha",
        "debug.note",
        "missing",
        "omega",
        "predicate",
        "value",
        "zeta",
    };
    const expected_values = [_]Attribute{
        alpha_attr,
        note_attr,
        missing_attr,
        omega_attr,
        predicate_attr,
        value_attr,
        zeta_attr,
    };
    op.name.registered_info = null;
    try testing.expect(op.name.getRegisteredInfo() == null);
    try testing.expectEqual(expected_names.len, op.getNumAttrs());
    var logical_attrs = op.getAttrs();
    for (expected_names, expected_values) |name, value| {
        const attr = logical_attrs.next() orelse return error.TestExpectedAttribute;
        try testing.expectEqualStrings(name, attr.name);
        try testing.expect(attr.value.eql(value));
    }
    try testing.expect(logical_attrs.next() == null);
    try testing.expect(op.name.getRegisteredInfo() == null);
    try testing.expectEqual(raw_ptr, op.getRawDictionaryAttrs().ptr);
    try testing.expectEqual(raw_len, op.getRawDictionaryAttrs().len);
    try testing.expectEqual(raw_capacity, op.raw_dictionary_attrs.capacity());
    for (raw_snapshot, op.getRawDictionaryAttrs()) |before, after| {
        try testing.expectEqualStrings(before.name, after.name);
        try testing.expect(before.value.eql(after.value));
    }

    const printed = try std.fmt.allocPrint(testing.allocator, "{f}", .{op.*});
    defer testing.allocator.free(printed);
    try testing.expect(std.mem.indexOf(u8, printed, "debug.note") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "predicate") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "value") != null);

    try testing.expect(op.removeAttr("value"));
    try testing.expect(op.getAttr("value").?.eql(collision_attr));
    try testing.expectEqual(expected_names.len, op.getNumAttrs());
    var after_remove = op.getAttrs();
    for (expected_names) |name| {
        const attr = after_remove.next() orelse return error.TestExpectedAttribute;
        try testing.expectEqualStrings(name, attr.name);
        if (std.mem.eql(u8, name, "value")) {
            try testing.expect(attr.value.eql(collision_attr));
        }
    }
    try testing.expect(after_remove.next() == null);
}

test "operation state property attribute converts after initial attributes" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("test.state_property_attr_op", .{});
    try ctx.registerOperationInherentAttributeName("test.state_property_attr_op", "value");
    try ctx.registerOperationPropertiesModel(
        "test.state_property_attr_op",
        interfaces.singleAttributePropertiesModel("test.state_property_attr.properties", "value"),
    );

    const initial_attr = try ctx.getI64Attr(1);
    const properties_attr = try ctx.getI64Attr(2);
    const note_attr = try ctx.getI64Attr(3);
    const attrs = [_]NamedAttribute{
        .{ .name = "value", .value = initial_attr },
        .{ .name = "debug.note", .value = note_attr },
    };
    var state = Operation.State.init("test.state_property_attr_op", .unknown);
    state.addAttributes(&attrs);
    try state.setPropertiesAttr(properties_attr);
    const op = try ctx.createOperation(state);

    try testing.expect(op.getAttr("value").?.eql(properties_attr));
    try testing.expect((try op.getPropertiesAsAttr()).?.eql(properties_attr));
    try testing.expectEqual(@as(usize, 1), op.getRawDictionaryAttrs().len);
    try testing.expectEqualStrings("debug.note", op.getRawDictionaryAttrs()[0].name);

    try testing.expectEqual(@as(usize, 2), op.getNumAttrs());
    var collected = op.getAttrs();
    try testing.expectEqualStrings("debug.note", collected.next().?.name);
    const value = collected.next().?;
    try testing.expectEqualStrings("value", value.name);
    try testing.expect(value.value.eql(properties_attr));
    try testing.expect(collected.next() == null);
}

test "operation state property ref copies typed storage after initial attributes" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("test.state_property_ref_op", .{});
    try ctx.registerOperationInherentAttributeName("test.state_property_ref_op", "value");
    try ctx.registerOperationPropertiesModel(
        "test.state_property_ref_op",
        interfaces.singleAttributePropertiesModel("test.state_property_ref.properties", "value"),
    );

    const source_attr = try ctx.getI64Attr(41);
    const changed_source_attr = try ctx.getI64Attr(42);
    const initial_attr = try ctx.getI64Attr(1);
    const note_attr = try ctx.getI64Attr(7);

    const source = try ctx.createOperation(Operation.State.init("test.state_property_ref_op", .unknown));
    try source.setAttr("value", source_attr);

    const attrs = [_]NamedAttribute{
        .{ .name = "value", .value = initial_attr },
        .{ .name = "debug.note", .value = note_attr },
    };
    var state = Operation.State.init("test.state_property_ref_op", .unknown);
    state.addAttributes(&attrs);
    try state.setPropertiesFromOperation(source);
    const target = try ctx.createOperation(state);

    try testing.expect(target.getAttr("value").?.eql(source_attr));
    try testing.expect((try target.getPropertiesAsAttr()).?.eql(source_attr));
    try testing.expectEqual(@as(usize, 1), target.getRawDictionaryAttrs().len);
    try testing.expectEqualStrings("debug.note", target.getRawDictionaryAttrs()[0].name);

    try source.setAttr("value", changed_source_attr);
    try testing.expect(source.getAttr("value").?.eql(changed_source_attr));
    try testing.expect(target.getAttr("value").?.eql(source_attr));
}

test "operation state property ref rejects model mismatch" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("test.source_property_ref_op", .{});
    try ctx.registerOperationInherentAttributeName("test.source_property_ref_op", "value");
    try ctx.registerOperationPropertiesModel(
        "test.source_property_ref_op",
        interfaces.singleAttributePropertiesModel("test.source_property_ref.properties", "value"),
    );

    _ = try ctx.registerOperation("test.target_property_ref_op", .{});
    try ctx.registerOperationInherentAttributeName("test.target_property_ref_op", "value");
    try ctx.registerOperationPropertiesModel(
        "test.target_property_ref_op",
        interfaces.singleAttributePropertiesModel("test.target_property_ref.properties", "value"),
    );

    const source = try ctx.createOperation(Operation.State.init("test.source_property_ref_op", .unknown));
    try source.setAttr("value", try ctx.getI64Attr(11));

    var state = Operation.State.init("test.target_property_ref_op", .unknown);
    try state.setPropertiesFromOperation(source);
    try testing.expectError(error.OperationPropertiesMismatch, ctx.createOperation(state));
}

test "operation state rejects mixed property payloads" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("test.mixed_property_payload_op", .{});
    try ctx.registerOperationInherentAttributeName("test.mixed_property_payload_op", "value");
    try ctx.registerOperationPropertiesModel(
        "test.mixed_property_payload_op",
        interfaces.singleAttributePropertiesModel("test.mixed_property_payload.properties", "value"),
    );

    const source = try ctx.createOperation(Operation.State.init("test.mixed_property_payload_op", .unknown));
    const attr = try ctx.getI64Attr(19);
    try source.setAttr("value", attr);

    var ref_first = Operation.State.init("test.mixed_property_payload_op", .unknown);
    try ref_first.setPropertiesFromOperation(source);
    try testing.expectError(error.DuplicateOperationPropertiesPayload, ref_first.setPropertiesAttr(attr));

    var attr_first = Operation.State.init("test.mixed_property_payload_op", .unknown);
    try attr_first.setPropertiesAttr(attr);
    try testing.expectError(error.DuplicateOperationPropertiesPayload, attr_first.setPropertiesFromOperation(source));
}

test "operation cloneWithoutRegions copies header and leaves regions empty" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const value_type = try ctx.getDialectTypeFromName("test.value");
    var producer_state = Operation.State.init("test.clone_producer", .unknown);
    producer_state.addTypes(&.{value_type});
    const producer = try ctx.createOperation(producer_state);
    const operand = producer.getResult(0).?;

    var successor = Block.init(testing.allocator);
    defer successor.deinit();

    var body = core.context.initRegion(&ctx);
    defer body.deinit();
    _ = try body.addBlock();

    const note_attr = try ctx.getI64Attr(9);
    const attrs = [_]NamedAttribute{.{ .name = "debug.note", .value = note_attr }};

    var state = Operation.State.init("test.clone_source", .unknown);
    state.addOperands(&.{operand});
    state.addTypes(&.{value_type});
    state.addAttributes(&attrs);
    state.addRegionBodies(&.{&body});
    state.addSuccessors(&.{&successor});
    const source = try ctx.createOperation(state);

    const clone = try source.cloneWithoutRegions();

    try testing.expect(clone != source);
    try testing.expectEqualStrings(source.name.name, clone.name.name);
    try testing.expectEqual(@as(usize, 1), clone.getNumOperands());
    try testing.expect(clone.getOperand(0).? == operand);
    try testing.expectEqual(@as(usize, 1), clone.getNumResults());
    try testing.expect(clone.getResult(0).? != source.getResult(0).?);
    try testing.expect(clone.getResult(0).?.type.eql(value_type));
    try testing.expect(clone.getAttr("debug.note").?.eql(note_attr));
    try testing.expectEqual(@as(usize, 1), clone.getNumSuccessors());
    try testing.expect(clone.getSuccessor(0).? == &successor);
    try testing.expectEqual(@as(usize, 1), clone.getNumRegions());
    try testing.expect(!source.getRegion(0).?.empty());
    try testing.expect(clone.getRegion(0).?.empty());
    try testing.expect(clone.parent_block == null);
}

test "operation cloneWithoutRegions copies typed properties independently" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("test.clone_property_op", .{});
    try ctx.registerOperationInherentAttributeName("test.clone_property_op", "value");
    try ctx.registerOperationPropertiesModel(
        "test.clone_property_op",
        interfaces.singleAttributePropertiesModel("test.clone_property.properties", "value"),
    );

    const value_attr = try ctx.getI64Attr(11);
    const changed_attr = try ctx.getI64Attr(12);
    const note_attr = try ctx.getI64Attr(13);

    const source = try ctx.createOperation(Operation.State.init("test.clone_property_op", .unknown));
    try source.setAttr("value", value_attr);
    try source.setAttr("debug.note", note_attr);

    const clone = try source.cloneWithoutRegions();
    try source.setAttr("value", changed_attr);

    try testing.expect(source.getAttr("value").?.eql(changed_attr));
    try testing.expect(clone.getAttr("value").?.eql(value_attr));
    try testing.expect((try clone.getPropertiesAsAttr()).?.eql(value_attr));
    try testing.expect(clone.getAttr("debug.note").?.eql(note_attr));
    try testing.expectEqual(@as(usize, 1), clone.getRawDictionaryAttrs().len);
    try testing.expectEqualStrings("debug.note", clone.getRawDictionaryAttrs()[0].name);
}

test "operation clone copies nested regions through mapped values" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const value_type = try ctx.getDialectTypeFromName("test.value");

    var body = core.context.initRegion(&ctx);
    defer body.deinit();
    _ = try body.addBlock();

    var parent_state = Operation.State.init("test.clone_parent", .unknown);
    parent_state.addTypes(&.{value_type});
    parent_state.addRegionBodies(&.{&body});
    const parent = try ctx.createOperation(parent_state);

    const entry = parent.getRegion(0).?.getEntryBlock().?;
    var child_state = Operation.State.init("test.clone_child", .unknown);
    child_state.addOperands(&.{parent.getResult(0).?});
    const child = try ctx.createOperation(child_state);
    try entry.addOperation(child);

    const cloned_parent = try parent.clone();

    try testing.expect(cloned_parent != parent);
    try testing.expectEqual(@as(usize, 1), cloned_parent.getNumRegions());
    try testing.expect(!cloned_parent.getRegion(0).?.empty());
    try testing.expect(cloned_parent.getResult(0).? != parent.getResult(0).?);

    const cloned_entry = cloned_parent.getRegion(0).?.getEntryBlock().?;
    try testing.expect(cloned_entry != entry);

    var cloned_ops = cloned_entry.getOperations();
    const cloned_child = cloned_ops.next().?;
    try testing.expect(cloned_ops.next() == null);
    try testing.expect(cloned_child != child);
    try testing.expect(cloned_child.getOperand(0).? == cloned_parent.getResult(0).?);
    try testing.expect(parent.getResult(0).?.getNumUses() == 1);
    try testing.expect(cloned_parent.getResult(0).?.getNumUses() == 1);
}

test "operation clone records source to clone operation mappings" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const value_type = try ctx.getDialectTypeFromName("test.value");

    var body = core.context.initRegion(&ctx);
    defer body.deinit();
    _ = try body.addBlock();

    var parent_state = Operation.State.init("test.clone_parent", .unknown);
    parent_state.addTypes(&.{value_type});
    parent_state.addRegionBodies(&.{&body});
    const parent = try ctx.createOperation(parent_state);

    const entry = parent.getRegion(0).?.getEntryBlock().?;
    var child_state = Operation.State.init("test.clone_child", .unknown);
    child_state.addOperands(&.{parent.getResult(0).?});
    const child = try ctx.createOperation(child_state);
    try entry.addOperation(child);

    var mapping = Mapping.init(testing.allocator);
    defer mapping.deinit();

    const cloned_parent = try parent.cloneWithoutRegionsMapped(&mapping, .{});
    for (parent.regions.items, 0..) |*region, i| {
        try region.cloneInto(&cloned_parent.regions.items[i], &mapping);
    }

    const cloned_entry = cloned_parent.getRegion(0).?.getEntryBlock().?;
    var cloned_ops = cloned_entry.getOperations();
    const cloned_child = cloned_ops.next().?;

    try testing.expect(mapping.lookupOperation(parent).? == cloned_parent);
    try testing.expect(mapping.lookupOperation(child).? == cloned_child);
    try testing.expect(mapping.lookupOrDefaultOperation(parent) == cloned_parent);
    try testing.expect(cloned_child.getOperand(0).? == cloned_parent.getResult(0).?);
}

test "region cloneInto remaps blocks arguments results operands and successors" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    try ctx.allowUnregistered();

    const value_type = try ctx.getDialectTypeFromName("test.value");

    const boundary = ctx.operationCreationBoundary();
    var source = core.context.initRegion(&ctx);
    var dest = core.context.initRegion(&ctx);
    defer {
        ctx.eraseOperationsCreatedSince(boundary);
        dest.deinit();
        source.deinit();
        ctx.deinit(testing.allocator);
    }

    const entry = try source.addBlock();
    const exit = try source.addBlock();
    const argument = try entry.addArgument(value_type, .unknown);

    var producer_state = Operation.State.init("test.clone_producer", .unknown);
    producer_state.addTypes(&.{value_type});
    const producer = try ctx.createOperation(producer_state);
    try entry.addOperation(producer);

    var consumer_state = Operation.State.init("test.clone_consumer", .unknown);
    consumer_state.addOperands(&.{ producer.getResult(0).?, argument });
    consumer_state.addSuccessors(&.{exit});
    const consumer = try ctx.createOperation(consumer_state);
    try entry.addOperation(consumer);

    var mapping = Mapping.init(testing.allocator);
    defer mapping.deinit();
    try source.cloneInto(&dest, &mapping);

    try testing.expectEqual(@as(usize, 2), source.blocks.size);
    try testing.expectEqual(@as(usize, 2), dest.blocks.size);

    const cloned_entry = mapping.lookupBlock(entry).?;
    const cloned_exit = mapping.lookupBlock(exit).?;
    try testing.expect(cloned_entry != entry);
    try testing.expect(cloned_exit != exit);
    try testing.expect(dest.blocks.head == cloned_entry);
    try testing.expect(dest.blocks.tail == cloned_exit);
    try testing.expect(cloned_entry.parent == @as(*anyopaque, @ptrCast(&dest)));
    try testing.expect(cloned_exit.parent == @as(*anyopaque, @ptrCast(&dest)));

    const cloned_argument = mapping.lookupValue(argument).?;
    try testing.expect(cloned_argument != argument);
    try testing.expect(cloned_argument.type.eql(value_type));
    try testing.expect(cloned_argument.kind.block_argument.owner == @as(*anyopaque, @ptrCast(cloned_entry)));

    var cloned_ops = cloned_entry.getOperations();
    const cloned_producer = cloned_ops.next().?;
    const cloned_consumer = cloned_ops.next().?;
    try testing.expect(cloned_ops.next() == null);
    try testing.expect(cloned_producer != producer);
    try testing.expect(cloned_consumer != consumer);
    try testing.expect(mapping.lookupOperation(producer).? == cloned_producer);
    try testing.expect(mapping.lookupOperation(consumer).? == cloned_consumer);
    try testing.expect(mapping.lookupValue(producer.getResult(0).?).? == cloned_producer.getResult(0).?);
    try testing.expect(cloned_consumer.getOperand(0).? == cloned_producer.getResult(0).?);
    try testing.expect(cloned_consumer.getOperand(1).? == cloned_argument);
    try testing.expect(cloned_consumer.getSuccessor(0).? == cloned_exit);
    try testing.expect(cloned_exit.hasPredecessor(cloned_entry));
    try testing.expect(!exit.hasPredecessor(cloned_entry));
    try testing.expect(consumer.getOperand(0).? == producer.getResult(0).?);
    try testing.expect(consumer.getSuccessor(0).? == exit);
}

test "operation state region bodies transfer into created operation" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    var body = core.context.initRegion(&ctx);
    defer body.deinit();

    const moved_block = try body.addBlock();
    var state = Operation.State.init("test.region_body_op", .unknown);
    state.addRegion();
    state.addRegionBodies(&.{&body});

    const op = try ctx.createOperation(state);

    try testing.expectEqual(@as(usize, 2), op.getNumRegions());
    const empty_region = op.getRegion(0).?;
    try testing.expect(empty_region.empty());

    const moved_region = op.getRegion(1).?;
    try testing.expect(!moved_region.empty());
    try testing.expect(moved_region.getEntryBlock().? == moved_block);
    try testing.expect(moved_block.parent == @as(*anyopaque, @ptrCast(moved_region)));
    try testing.expect(moved_region.parent == @as(*anyopaque, @ptrCast(op)));
    try testing.expect(body.empty());
}

test "operation creation canonicalizes duplicate initial attributes" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const first = try ctx.getI64Attr(1);
    const second = try ctx.getI64Attr(2);
    const beta = try ctx.getI64Attr(3);

    const attrs = [_]NamedAttribute{
        .{ .name = "beta", .value = beta },
        .{ .name = "alpha", .value = first },
        .{ .name = "alpha", .value = second },
    };
    var state = Operation.State.init("test.attr_op", .unknown);
    state.addAttributes(&attrs);
    const op = try ctx.createOperation(state);

    const stored_attrs = op.getRawDictionaryAttrs();
    try testing.expectEqual(@as(usize, 2), stored_attrs.len);
    try testing.expectEqualStrings("alpha", stored_attrs[0].name);
    try testing.expectEqualStrings("beta", stored_attrs[1].name);
    try testing.expect(op.getAttr("alpha").?.eql(second));
    try testing.expect(op.getAttr("beta").?.eql(beta));
}

test "operation successors update block predecessors" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try Context.init(allocator, Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    var pred = Block.init(allocator);
    defer pred.deinit();
    var succ = Block.init(allocator);
    defer succ.deinit();

    var state = Operation.State.init("test.br", Location.getUnknown());
    state.addSuccessors(&.{&succ});

    const op = try ctx.createOperation(state);
    try pred.addOperation(op);

    try testing.expect(succ.hasPredecessor(&pred));

    op.erase();

    try testing.expect(!succ.hasPredecessor(&pred));
}

test "setSuccessors preserves the old relation on allocation failure" {
    const testing = std.testing;

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();
    var ctx = try Context.init(allocator, Context.Limits.testing);
    var source = Block.init(allocator);
    var old_target = Block.init(allocator);
    var new_target = Block.init(allocator);
    defer {
        ctx.deinit(allocator);
        source.deinit();
        old_target.deinit();
        new_target.deinit();
    }
    try ctx.allowUnregistered();

    var state = Operation.State.init("test.branch", .unknown);
    state.addSuccessors(&.{&old_target});
    const branch = try ctx.createOperation(state);
    try source.addOperation(branch);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    const result = branch.setSuccessors(&.{&new_target});
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);

    try testing.expectError(error.OutOfMemory, result);
    try testing.expect(branch.getSuccessor(0).? == &old_target);
    try testing.expect(old_target.hasPredecessor(&source));
    try testing.expect(new_target.hasNoPredecessors());
}

test "setSuccessors accepts an overlapping successor slice" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    var source = Block.init(testing.allocator);
    var first_target = Block.init(testing.allocator);
    var second_target = Block.init(testing.allocator);
    defer {
        ctx.deinit(testing.allocator);
        source.deinit();
        first_target.deinit();
        second_target.deinit();
    }
    try ctx.allowUnregistered();

    var state = Operation.State.init("test.branch", .unknown);
    state.addSuccessors(&.{ &first_target, &second_target });
    const branch = try ctx.createOperation(state);
    try source.addOperation(branch);

    try branch.setSuccessors(branch.successors.items[1..]);

    try testing.expectEqual(@as(usize, 1), branch.getNumSuccessors());
    try testing.expect(branch.getSuccessor(0).? == &second_target);
    try testing.expect(first_target.hasNoPredecessors());
    try testing.expect(second_target.hasPredecessor(&source));
}

test "setSuccessors stabilizes a borrowed predecessor slice" {
    const testing = std.testing;
    var limits = Context.Limits.testing;
    limits.operations.nested_bytes = 0;
    var ctx = try Context.init(testing.allocator, limits);
    var source = Block.init(testing.allocator);
    var alias_owner = Block.init(testing.allocator);
    var old_target = Block.init(testing.allocator);
    defer {
        ctx.deinit(testing.allocator);
        source.deinit();
        alias_owner.deinit();
        old_target.deinit();
    }
    try ctx.allowUnregistered();

    var self_state = Operation.State.init("test.self_branch", .unknown);
    self_state.addSuccessors(&.{&alias_owner});
    try alias_owner.addOperation(try ctx.createOperation(self_state));

    var branch_state = Operation.State.init("test.branch", .unknown);
    branch_state.addSuccessors(&.{&old_target});
    const branch = try ctx.createOperation(branch_state);
    try source.addOperation(branch);

    try alias_owner.predecessors.shrinkToLen(testing.allocator);
    const borrowed = alias_owner.getPredecessors();
    try testing.expectError(error.OutOfMemory, branch.setSuccessors(borrowed));
    try testing.expect(branch.getSuccessor(0).? == &old_target);
    try testing.expect(old_target.hasPredecessor(&source));
    try testing.expect(!alias_owner.hasPredecessor(&source));

    try branch.setSuccessors(&.{&alias_owner});

    try testing.expectEqual(@as(usize, 1), branch.getNumSuccessors());
    try testing.expect(branch.getSuccessor(0).? == &alias_owner);
    try testing.expectEqual(@as(usize, 2), alias_owner.getNumPredecessors());
    try testing.expect(alias_owner.hasPredecessor(&source));
    try testing.expect(old_target.hasNoPredecessors());
}

test "setSuccessors preserves another operation edge" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    var source = Block.init(testing.allocator);
    var shared_target = Block.init(testing.allocator);
    var replacement_target = Block.init(testing.allocator);
    defer {
        ctx.deinit(testing.allocator);
        source.deinit();
        shared_target.deinit();
        replacement_target.deinit();
    }
    try ctx.allowUnregistered();

    var first_state = Operation.State.init("test.first_branch", .unknown);
    first_state.addSuccessors(&.{&shared_target});
    const first = try ctx.createOperation(first_state);
    try source.addOperation(first);
    var second_state = Operation.State.init("test.second_branch", .unknown);
    second_state.addSuccessors(&.{&shared_target});
    const second = try ctx.createOperation(second_state);
    try source.addOperation(second);

    try first.setSuccessors(&.{&replacement_target});

    try testing.expect(shared_target.hasPredecessor(&source));
    try testing.expect(replacement_target.hasPredecessor(&source));
    source.removeOperation(second);
    try testing.expect(shared_target.hasNoPredecessors());
    try testing.expect(replacement_target.hasPredecessor(&source));
}

test "moveToEnd preserves placement and CFG on allocation failure" {
    const testing = std.testing;

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();
    var ctx = try Context.init(allocator, Context.Limits.testing);
    var source = Block.init(allocator);
    var destination = Block.init(allocator);
    var target = Block.init(allocator);
    defer {
        ctx.deinit(allocator);
        source.deinit();
        destination.deinit();
        target.deinit();
    }
    try ctx.allowUnregistered();

    var state = Operation.State.init("test.branch", .unknown);
    state.addSuccessors(&.{&target});
    const branch = try ctx.createOperation(state);
    try source.addOperation(branch);
    try target.predecessors.shrinkToLen(allocator);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    const result = branch.moveToEnd(&destination);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);

    try testing.expectError(error.OutOfMemory, result);
    try testing.expect(branch.parent_block == &source);
    const source_head: *Operation = @ptrCast(@alignCast(source.operations.head.?));
    const source_tail: *Operation = @ptrCast(@alignCast(source.operations.tail.?));
    try testing.expect(source_head == branch);
    try testing.expect(source_tail == branch);
    try testing.expect(destination.operations.isEmpty());
    try testing.expect(target.hasPredecessor(&source));
    try testing.expect(!target.hasPredecessor(&destination));
}

test "eraseBlock rejects a target with a remaining operation edge" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    var region = core.context.initRegion(&ctx);
    const boundary = ctx.operationCreationBoundary();
    defer {
        ctx.eraseOperationsCreatedSince(boundary);
        region.deinit();
        ctx.deinit(testing.allocator);
    }
    try ctx.allowUnregistered();

    const source = try region.addBlock();
    const target = try region.addBlock();
    var first_state = Operation.State.init("test.first_branch", .unknown);
    first_state.addSuccessors(&.{target});
    const first = try ctx.createOperation(first_state);
    try source.addOperation(first);
    var second_state = Operation.State.init("test.second_branch", .unknown);
    second_state.addSuccessors(&.{target});
    try source.addOperation(try ctx.createOperation(second_state));

    source.removeOperation(first);

    try testing.expect(target.hasPredecessor(source));
    try testing.expect(!region.eraseBlock(target));
}

var materialize_called: bool = false;

fn materializeIdentity(_: *core.rewrite.PatternRewriter, value: *core.Value, _: core.Type) ?*core.Value {
    materialize_called = true;
    return value;
}

test "pattern rewriter materialize uses type converter" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try core.Context.init(allocator, core.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);
    var converter = core.rewrite.TypeConverter.init(allocator);
    defer converter.deinit();
    converter.setMaterialization(materializeIdentity);

    var rewriter = core.rewrite.PatternRewriter.initWithTypeConverter(allocator, &ctx, &converter);
    defer rewriter.deinit();

    var state = core.Operation.State.init("test.constant", core.Location.getUnknown());
    state.addTypes(&.{i32_type});
    const op = try ctx.createOperation(state);
    const value = op.getResult(0).?;

    materialize_called = false;
    const result = rewriter.materializeConversion(value, i32_type);
    try testing.expect(materialize_called);
    try testing.expect(result == value);
}

test "type converter addConversion overwrites existing mapping" {
    const testing = std.testing;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try core.Context.init(allocator, core.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);
    const i64_type = try test_dialect.TestDialect.getI64Type(&ctx);

    var converter = core.rewrite.TypeConverter.init(allocator);
    defer converter.deinit();

    try converter.addConversion(i32_type, &.{i64_type});
    try testing.expect(converter.convertType(i32_type) != null);
    var converted = converter.convertType(i32_type).?;
    try testing.expectEqual(@as(usize, 1), converted.len);
    try testing.expect(converted[0].eql(i64_type));

    try converter.addConversion(i32_type, &.{i32_type});
    try testing.expect(converter.convertType(i32_type) != null);
    converted = converter.convertType(i32_type).?;
    try testing.expectEqual(@as(usize, 1), converted.len);
    try testing.expect(converted[0].eql(i32_type));
}

test "Choir parse preserves block argument identity in an scf loop" {
    const testing = std.testing;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try core.dialects.loadDialectSpec(&ctx, dialects.BuiltinDialect.spec);
    try core.dialects.loadDialectSpec(&ctx, dialects.arith.spec);
    try core.dialects.loadDialectSpec(&ctx, dialects.ScfDialect.spec);

    const text =
        \\builtin.module() {
        \\  ^bb0(%0: !arith.index, %1: !arith.index, %2: !arith.index, %3: !arith.f64):
        \\    %7 = scf.for(%0, %1, %2, %3): !arith.f64 {
        \\      ^bb1(%4: !arith.index, %5: !arith.f64):
        \\        scf.yield(%4)
        \\    }
        \\}
        \\
    ;
    const parsed = try core.parse.operation(&ctx, text);
    defer parsed.erase();
    try testing.expectError(
        error.ScfForYieldTypeMismatch,
        core.verify.verifyOperation(parsed, core.verify.default_options),
    );
    const dumped = try core.dump.operationAlloc(testing.allocator, parsed);
    defer testing.allocator.free(dumped);
    const expected =
        \\builtin.module() {
        \\  ^bb0(%0: !arith.index, %1: !arith.index, %2: !arith.index, %3: !arith.f64):
        \\    %4 = scf.for(%0, %1, %2, %3) : !arith.f64 {
        \\      ^bb0(%5: !arith.index, %6: !arith.f64):
        \\        scf.yield(%5)
        \\    }
        \\}
        \\
    ;
    try testing.expectEqualStrings(expected, dumped);
}
