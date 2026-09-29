const freeze_ctx = @import("freeze.zig");

fn strict_type_test_loader(_: *@import("root.zig").Context) anyerror!void {}

pub fn requireRegistered(ctx: anytype) @TypeOf(ctx.*).Error!void {
    try freeze_ctx.requireMutable(ctx);
    ctx.dialect_registry.allow_unregistered = false;
    ctx.dialect_registry.operation_registry.allow_unregistered_operations = false;
    ctx.type_interner.registry.allow_unregistered_types = false;
}

pub fn allowUnregistered(ctx: anytype) @TypeOf(ctx.*).Error!void {
    try freeze_ctx.requireMutable(ctx);
    ctx.dialect_registry.allow_unregistered = true;
    ctx.dialect_registry.operation_registry.allow_unregistered_operations = true;
    ctx.type_interner.registry.allow_unregistered_types = true;
}

test "Context defaults to registered dialect operation and type policy" {
    const std = @import("std");
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    const Operation = @import("../root.zig").Operation;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    try testing.expect(!ctx.dialect_registry.allow_unregistered);
    try testing.expect(!ctx.getOperationRegistry().allow_unregistered_operations);
    try testing.expect(!ctx.getTypeRegistry().allow_unregistered_types);

    try testing.expectError(error.UnknownDialect, ctx.getOrLoadDialect("missing"));

    const state = Operation.State.init("missing.op", .unknown);
    try testing.expectError(error.UnknownDialect, ctx.createOperation(state));
}

test "Context rejects unknown registered-dialect types under strict policy" {
    const std = @import("std");
    const testing = std.testing;
    const Context = @import("root.zig").Context;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    try ctx.registerDialectLoader("strict_type", strict_type_test_loader);
    _ = try ctx.getOrLoadDialect("strict_type");

    try testing.expectError(error.UnknownType, ctx.getDialectTypeFromName("strict_type.value"));

    try ctx.allowUnregistered();
    const typ = try ctx.getDialectTypeFromName("strict_type.value");
    try testing.expectEqualStrings("strict_type.value", typ.getDialectTypeName().?);

    try ctx.requireRegistered();
    try testing.expectError(error.UnknownType, ctx.getDialectTypeFromName("strict_type.other"));
}
