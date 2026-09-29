const std = @import("std");
const choir = @import("../root.zig");
const compiler = @import("root.zig");
const extensions = choir.extensions;
const ir = choir.ir;

const fake_dialect_name = "compiler_fake";
const fake_op_name = "compiler_fake.op";

fn loadFakeDialect(ctx: *ir.Context) !void {
    _ = try ctx.registerOperation(fake_op_name, .{});
    _ = try ctx.registerType("compiler_fake.type");
}

const fake_package = extensions.PackageExtension{
    .name = "compiler-fake-package",
    .dialects = &.{.{
        .name = fake_dialect_name,
        .load = loadFakeDialect,
    }},
};

test "compiler context preloads strict core Choir dialects" {
    var ctx = try compiler.initContext(std.testing.allocator, .{
        .context_limits = ir.Context.Limits.testing,
    });
    defer ctx.deinit(std.testing.allocator);

    try std.testing.expect(ctx.lookupOperation("builtin.module") != null);
    try std.testing.expect(ctx.lookupOperation("arith.add") != null);
    try std.testing.expect(ctx.lookupOperation("memref.load") != null);
    try std.testing.expect(ctx.lookupOperation("scf.for") != null);
    try std.testing.expect(ctx.lookupOperation("func.func") != null);

    try std.testing.expectError(error.UnknownDialect, ctx.getOrLoadDialect("compiler_missing"));
    try std.testing.expectError(error.UnknownDialect, ctx.createOperation(ir.Operation.State.init("compiler_missing.op", .unknown)));
    try std.testing.expectError(error.UnknownOperation, ctx.createOperation(ir.Operation.State.init("builtin.unknown", .unknown)));
}

test "compiler context loads package dialects by name" {
    var ctx = try compiler.initContext(std.testing.allocator, .{
        .context_limits = ir.Context.Limits.testing,
        .packages = &.{fake_package},
        .preload_dialects = &.{fake_dialect_name},
    });
    defer ctx.deinit(std.testing.allocator);

    try std.testing.expect(ctx.lookupOperation(fake_op_name) != null);
    try std.testing.expect(ctx.lookupType("compiler_fake.type") != null);
}

test "compiler session retains package extensions beside its context" {
    var session = try compiler.Session.init(std.testing.allocator, .{
        .context_limits = ir.Context.Limits.testing,
        .packages = &.{fake_package},
        .preload_dialects = &.{fake_dialect_name},
    });
    defer session.deinit();

    try std.testing.expect(session.context().lookupOperation(fake_op_name) != null);
    try std.testing.expectEqual(@as(usize, 1), session.extensionRegistry().packages.items.len);
    try std.testing.expectEqualStrings(fake_package.name, session.extensionRegistry().packages.items[0]);
}
