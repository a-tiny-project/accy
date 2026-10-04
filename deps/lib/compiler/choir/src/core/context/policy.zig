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
