const std = @import("std");
const core = @import("../root.zig");
const context = @import("root.zig");

const RollbackTestState = struct {
    var fail_once: bool = true;
    var use_spec: bool = true;
    const iface_id: core.interfaces.InterfaceId = core.interfaces.interfaceId("txn_test.interface");
    var vtable: u8 = 7;
    const operations = [_]core.dialects.OperationSpec{
        .{ .name = "txn_test.op", .traits = .{ .is_idempotent = true } },
        .{ .name = "txn_test.other", .traits = .{ .is_commutative = true } },
    };
    const types = [_]core.dialects.TypeSpec{
        .{ .name = "txn_test.ty" },
        .{ .name = "txn_test.token" },
    };
    const spec: core.dialects.DialectSpec = .{
        .name = "txn_test",
        .operations = &operations,
        .types = &types,
    };
};

fn rollbackTestLoader(ctx: *context.Context) anyerror!void {
    if (RollbackTestState.use_spec) {
        try core.dialects.loadDialectSpec(ctx, RollbackTestState.spec);
    } else {
        _ = try ctx.registerOperation("txn_test.op", .{ .is_idempotent = true });
        _ = try ctx.registerOperation("txn_test.other", .{ .is_commutative = true });
        _ = try ctx.registerType("txn_test.ty");
        _ = try ctx.registerType("txn_test.token");
    }
    try ctx.registerOperationInterface("txn_test.op", .{
        .id = RollbackTestState.iface_id,
        .vtable = &RollbackTestState.vtable,
    });
    _ = try ctx.registerAttributeType("txn_test.attr", &.{});

    if (RollbackTestState.fail_once) {
        RollbackTestState.fail_once = false;
        return error.TestDialectFailure;
    }
}

test "Context dialect load rollback removes partial registrations and allows retry" {
    const testing = std.testing;

    for ([_]bool{ false, true }) |use_spec| {
        var ctx = try context.Context.init(testing.allocator, context.Context.Limits.testing);
        defer ctx.deinit(testing.allocator);

        RollbackTestState.fail_once = true;
        RollbackTestState.use_spec = use_spec;

        try ctx.registerDialectLoader("txn_test", rollbackTestLoader);

        const next_attr_id_before = ctx.attr_interner.registry.nextAttributeId();
        const first_attempt = ctx.getOrLoadDialect("txn_test");
        try testing.expectError(error.TestDialectFailure, first_attempt);

        try testing.expect(ctx.lookupOperation("txn_test.op") == null);
        try testing.expect(ctx.lookupOperation("txn_test.other") == null);
        try testing.expect(ctx.lookupType("txn_test.ty") == null);
        try testing.expect(ctx.lookupType("txn_test.token") == null);
        try testing.expect(ctx.lookupAttributeType("txn_test.attr") == null);
        try testing.expect(!ctx.isDialectLoaded("txn_test"));
        try testing.expectEqual(next_attr_id_before, ctx.attr_interner.registry.nextAttributeId());

        _ = try ctx.getOrLoadDialect("txn_test");
        const op_info = ctx.lookupOperation("txn_test.op") orelse return error.TestOperationMissing;
        const other_info = ctx.lookupOperation("txn_test.other") orelse return error.TestOperationMissing;
        try testing.expect(ctx.lookupType("txn_test.ty") != null);
        try testing.expect(ctx.lookupType("txn_test.token") != null);
        try testing.expect(op_info.hasInterface(RollbackTestState.iface_id));
        try testing.expectEqual(@as(usize, 1), op_info.getNumInterfaces());
        try testing.expect(other_info.traits.is_commutative);
    }
}
