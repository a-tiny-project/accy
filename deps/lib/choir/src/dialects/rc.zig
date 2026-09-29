const std = @import("std");
const ir = @import("../core/root.zig");
const effects = ir.interfaces.effects;

pub const attr_names = struct {
    pub const ownership = "rc.ownership";
};

pub const RcDialect = struct {
    pub const name = "rc";
    const op_templates = ir.dialects.operationTemplate.dialect(@This());
    pub const spec = ir.dialects.dialectSpec(@This(), .{});

    pub const RetainOp: type = op_templates.unarySameType(
        "retain",
        ownershipOptions(.retain, .owned),
    );

    pub const ReleaseOp: type = op_templates.unaryNoResult(
        "release",
        ownershipOptions(.release, .none),
    );

    pub const BorrowOp: type = op_templates.unarySameTypeStringAttr(
        "borrow",
        attr_names.ownership,
        "borrowed",
        ownershipOptions(.borrow, .borrowed),
    );

    pub const MoveOp: type = op_templates.unarySameTypeStringAttr(
        "move",
        attr_names.ownership,
        "owned",
        ownershipOptions(.move, .transferred),
    );
};

test "rc dialect ops preserve value type" {
    const arith = @import("arith/root.zig");
    const test_dialect = @import("fixture/root.zig");

    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);

    try ir.dialects.loadDialectSpec(&ctx, RcDialect.spec);
    try test_dialect.registerTestDialect(&ctx);
    _ = try ctx.registerOperation("test.source", .{});

    const retain_info = ctx.lookupOperation(RcDialect.RetainOp.operation_name) orelse return error.TestExpectedRetainOp;
    const release_info = ctx.lookupOperation(RcDialect.ReleaseOp.operation_name) orelse return error.TestExpectedReleaseOp;
    const borrow_info = ctx.lookupOperation(RcDialect.BorrowOp.operation_name) orelse return error.TestExpectedBorrowOp;

    try std.testing.expect(retain_info.shape.operands.allows(1));
    try std.testing.expect(!retain_info.shape.operands.allows(2));
    try std.testing.expect(retain_info.shape.results.allows(1));
    try std.testing.expect(release_info.shape.operands.allows(1));
    try std.testing.expect(release_info.shape.results.allows(0));
    try std.testing.expect(!release_info.shape.results.allows(1));
    try std.testing.expect(borrow_info.hasInherentAttributeName(attr_names.ownership));

    const loc = ir.Location.getUnknown();
    const i64_type = try arith.ArithDialect.getScalarType(&ctx, .i64);
    var state = ir.Operation.State.init("test.source", loc);
    state.addTypes(&.{i64_type});
    const source = try ctx.createOperation(state);
    const value = source.getResult(0).?;

    const retained = try RcDialect.RetainOp.create(&ctx, loc, value);
    const borrowed = try RcDialect.BorrowOp.create(&ctx, loc, retained.getResult());
    const moved = try RcDialect.MoveOp.create(&ctx, loc, borrowed.getResult());
    const release = try RcDialect.ReleaseOp.create(&ctx, loc, moved.getResult());

    try std.testing.expect(retained.getResult().type.eql(i64_type));
    try std.testing.expect(borrowed.getResult().type.eql(i64_type));
    try std.testing.expect(moved.getResult().type.eql(i64_type));
    try std.testing.expectEqualStrings("borrowed", borrowed.getStringAttr().?);
    try std.testing.expectEqualStrings("owned", moved.getStringAttr().?);
    try std.testing.expect(release.getInput() == moved.getResult());
    try std.testing.expectEqual(@as(usize, 0), release.op.results.items.len);
}

fn ownershipOptions(
    comptime kind: effects.EventKind,
    comptime ownership: effects.Ownership,
) ir.dialects.opSpec.Options {
    const Declaration = struct {
        fn enumerate(op: *const ir.Operation, collector: *effects.Collector) void {
            if (op.getNumOperands() != 1) return;
            collector.append(.{ .requirement = .{ .kind = .live, .subject = .{ .operand = 0 } } });
            collector.append(.{ .event = .{ .kind = kind, .resource = .{
                .subject = .{ .operand = 0 },
            } } });
            if (kind == .release) {
                collector.append(.{ .requirement = .{
                    .kind = .callee_contract,
                    .subject = .{ .operand = 0 },
                } });
                collector.append(.{ .event = .{ .kind = .free, .resource = .{
                    .subject = .{ .operand = 0 },
                } } });
            }
            for (0..op.getNumResults()) |index| collector.append(.{ .result = .{
                .index = index,
                .alias = .{ .operand = 0 },
                .ownership = ownership,
            } });
        }
    };
    return .{ .interfaces = &.{effects.EffectOpInterface.entryFor(.{
        .capacity = .{ .entries = 4, .per_result = 1 },
        .enumerate = Declaration.enumerate,
    })} };
}

test "rc effect declarations retain ownership events and result aliases" {
    const arith = @import("arith/root.zig").ArithDialect;
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    try ir.dialects.loadDialectSpec(&ctx, RcDialect.spec);
    const typ = try arith.getScalarType(&ctx, .i64);
    const input = try arith.ConstantOp.createInt(&ctx, .unknown, typ, 1);
    const retained = try RcDialect.RetainOp.create(&ctx, .unknown, input.getResult());
    const borrowed = try RcDialect.BorrowOp.create(&ctx, .unknown, retained.getResult());
    const moved = try RcDialect.MoveOp.create(&ctx, .unknown, borrowed.getResult());
    const released = try RcDialect.ReleaseOp.create(&ctx, .unknown, moved.getResult());
    const operations = [_]*ir.Operation{ retained.op, borrowed.op, moved.op, released.op };
    const kinds = [_]effects.EventKind{ .retain, .borrow, .move, .release };
    for (operations, kinds) |op, kind| {
        var declaration = try effects.inspect(std.testing.allocator, op);
        defer declaration.deinit(std.testing.allocator);
        try std.testing.expect(!effects.discard(declaration.facts));
        try std.testing.expect(!effects.duplicate(declaration.facts, .{}));
        try std.testing.expectEqual(kind, declaration.facts.records[1].event.kind);
        if (op.getNumResults() != 0) {
            const result = declaration.facts.records[2].result;
            try std.testing.expectEqual(@as(usize, 0), result.alias.?.operand);
            try std.testing.expect(result.ownership != .none);
        }
    }
}
