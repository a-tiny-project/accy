const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");
const core_dialects = @import("../core/root.zig").dialects;
const interfaces = @import("../core/root.zig").interfaces;

const builtin = @import("builtin.zig");
const arith = @import("arith/root.zig");
const memref = @import("memref.zig");
const rc = @import("rc.zig");
const scf = @import("scf.zig");
const func = @import("func.zig");
const tile = @import("tile.zig");
const aarch64 = @import("aarch64.zig");

const BuiltinDialect = builtin.BuiltinDialect;
const MemrefDialect = memref.MemrefDialect;
const RcDialect = rc.RcDialect;
const ScfDialect = scf.ScfDialect;
const FuncDialect = func.FuncDialect;
const TileDialect = tile.TileDialect;
const AArch64Dialect = aarch64.AArch64Dialect;

fn loadBuiltinDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, BuiltinDialect.spec);
}

fn loadTileDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, TileDialect.spec);
}

fn loadAArch64Dialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, AArch64Dialect.spec);
}

fn loadArithDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, arith.spec);
}

fn loadMemrefDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, MemrefDialect.spec);
}

fn loadRcDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, RcDialect.spec);
}

fn loadScfDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, ScfDialect.spec);
}

fn loadFuncDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, FuncDialect.spec);
}

pub const choir_registry = core_dialects.DialectRegistrySpec{
    .entries = &[_]core_dialects.DialectRegistryEntry{
        .{ .name = "builtin", .load = loadBuiltinDialect },
        .{ .name = "tile", .load = loadTileDialect },
        .{ .name = "aarch64", .load = loadAArch64Dialect },
        .{ .name = "arith", .load = loadArithDialect },
        .{ .name = "memref", .load = loadMemrefDialect },
        .{ .name = "rc", .load = loadRcDialect },
        .{ .name = "scf", .load = loadScfDialect },
        .{ .name = "func", .load = loadFuncDialect },
    },
};

fn registerChoirDialectLoader(ctx: *ir.Context, entry: core_dialects.DialectRegistryEntry) !void {
    ctx.registerDialectLoader(entry.name, entry.load) catch |err| switch (err) {
        error.DuplicateDialectLoader => {
            const existing = ctx.dialect_registry.loaders.get(entry.name) orelse return err;
            if (existing != entry.load) return err;
        },
        else => return err,
    };
}

pub fn registerChoirDialect(ctx: *ir.Context) !void {
    inline for (choir_registry.entries) |entry| {
        try registerChoirDialectLoader(ctx, entry);
    }
}

pub fn registerAllDialects(ctx: *ir.Context) !void {
    try registerChoirDialect(ctx);
    inline for (choir_registry.entries) |entry| {
        _ = try ctx.getOrLoadDialect(entry.name);
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "DialectSpec typeNames skips non-string entries without aborting" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const Names = struct {
        pub const first = "choir.test.first";
        pub const bad: *const [2]u16 = &[_]u16{ 1, 2 };
        pub const second = "choir.test.second";
    };

    try ir.dialects.loadDialectSpec(&ctx, .{
        .name = "choir.test",
        .types = ir.dialects.typeNames(Names),
    });

    try testing.expect(ctx.lookupType(Names.first) != null);
    try testing.expect(ctx.lookupType(Names.second) != null);
}

test "registerChoirDialect lazily loads builtin, arith, memref, rc, scf, and func for strict contexts" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    try testing.expectError(error.UnknownDialect, ctx.getOrLoadDialect("builtin"));

    try registerChoirDialect(&ctx);
    _ = try ctx.getOrLoadDialect("builtin");

    try testing.expect(ctx.lookupOperation("arith.add") == null);
    try testing.expect(ctx.lookupOperation("memref.load") == null);
    try testing.expect(ctx.lookupOperation("rc.retain") == null);
    try testing.expect(ctx.lookupOperation("scf.for") == null);
    try testing.expect(ctx.lookupOperation("func.func") == null);
    try testing.expect(ctx.lookupOperation("func.call") == null);
    try testing.expect(ctx.lookupOperation("func.return") == null);
    try testing.expect(ctx.lookupType(arith.type_names.int32) == null);
    try testing.expect(ctx.lookupType(MemrefDialect.name) == null);

    _ = try ctx.getOrLoadDialect("arith");
    try testing.expect(ctx.lookupOperation("arith.add") != null);
    try testing.expect(ctx.lookupType(arith.type_names.int32) != null);
    try testing.expect(ctx.lookupType(arith.type_names.vec4xf32) != null);

    const loc = ir.Location.getUnknown();
    const arith_state = ir.Operation.State.init("arith.add", loc);
    _ = try ctx.createOperation(arith_state);

    _ = try ctx.getOrLoadDialect("memref");
    try testing.expect(ctx.lookupOperation("memref.load") != null);
    try testing.expect(ctx.lookupType(MemrefDialect.name) != null);
    const memref_type = try ctx.getDialectTypeFromNameWithKey("memref", "64,arith.f32,device");
    try testing.expect((try ctx.getTypeParamPayload(memref_type, MemrefDialect.MemrefTypePayload)) != null);
    try testing.expect(ctx.typeInterface(memref_type, interfaces.ShapedTypeInterface) != null);
    const memref_state = ir.Operation.State.init("memref.load", loc);
    _ = try ctx.createOperation(memref_state);

    _ = try ctx.getOrLoadDialect("rc");
    try testing.expect(ctx.lookupOperation("rc.retain") != null);
    try testing.expect(ctx.lookupOperation("rc.release") != null);
    const rc_state = ir.Operation.State.init("rc.retain", loc);
    _ = try ctx.createOperation(rc_state);

    _ = try ctx.getOrLoadDialect("scf");
    try testing.expect(ctx.lookupOperation("scf.for") != null);
    const scf_state = ir.Operation.State.init("scf.for", loc);
    _ = try ctx.createOperation(scf_state);

    _ = try ctx.getOrLoadDialect("func");
    const func_info = ctx.lookupOperation("func.func") orelse return error.TestExpectedOperation;
    try testing.expect(func_info.hasInterface(interfaces.SymbolOpInterface.id));
    const call_info = ctx.lookupOperation("func.call") orelse return error.TestExpectedOperation;
    try testing.expect(call_info.hasInterface(interfaces.CallOpInterface.id));
    try testing.expect(call_info.hasInterface(interfaces.SymbolUserOpInterface.id));
    try testing.expect(ctx.lookupOperation("func.return") != null);
    const func_state = ir.Operation.State.init("func.func", loc);
    _ = try ctx.createOperation(func_state);

    const bad_state = ir.Operation.State.init("builtin.unknown", loc);
    try testing.expectError(error.UnknownOperation, ctx.createOperation(bad_state));
}

test "registerAllDialects is repeatable after lazy registry registration" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    try registerChoirDialect(&ctx);
    try registerAllDialects(&ctx);
    try registerAllDialects(&ctx);

    inline for (choir_registry.entries) |entry| {
        try testing.expect(ctx.isDialectLoaded(entry.name));
    }
}

test "Choir dialect operation metadata matches co-owned capacity witnesses" {
    const testing = std.testing;

    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try registerAllDialects(&ctx);

    var maximum_traits: usize = 0;
    var maximum_interfaces: usize = 0;
    var maximum_inherent_attribute_names: usize = 0;
    var maximum_required_attribute_names: usize = 0;
    var total_inherent_attribute_names: usize = 0;
    var total_required_attribute_names: usize = 0;
    var nonempty_inherent_attribute_names: usize = 0;
    var nonempty_required_attribute_names: usize = 0;
    var operation_count: usize = 0;
    var operation_iter = ctx.dialect_registry.operation_registry.ops.valueIterator();
    while (operation_iter.next()) |info_ptr| {
        operation_count += 1;
        maximum_traits = @max(maximum_traits, info_ptr.*.getDynamicTraitIds().len);
        maximum_interfaces = @max(maximum_interfaces, info_ptr.*.getNumInterfaces());
        const inherent_attribute_names = info_ptr.*.getInherentAttributeNames().len;
        const required_attribute_names = info_ptr.*.getRequiredAttributeNames().len;
        maximum_inherent_attribute_names = @max(
            maximum_inherent_attribute_names,
            inherent_attribute_names,
        );
        maximum_required_attribute_names = @max(
            maximum_required_attribute_names,
            required_attribute_names,
        );
        total_inherent_attribute_names += inherent_attribute_names;
        total_required_attribute_names += required_attribute_names;
        if (inherent_attribute_names != 0) nonempty_inherent_attribute_names += 1;
        if (required_attribute_names != 0) nonempty_required_attribute_names += 1;
    }
    try testing.expectEqual(
        interfaces.OperationInfo.dynamic_trait_inline_capacity,
        maximum_traits,
    );
    try testing.expectEqual(
        @as(usize, 3),
        maximum_interfaces,
    );
    try testing.expectEqual(@as(usize, 6), maximum_inherent_attribute_names);
    try testing.expectEqual(@as(usize, 4), maximum_required_attribute_names);
    try testing.expectEqual(@as(usize, 87), total_inherent_attribute_names);
    try testing.expectEqual(@as(usize, 71), total_required_attribute_names);
    try testing.expectEqual(@as(usize, 58), nonempty_inherent_attribute_names);
    try testing.expectEqual(@as(usize, 51), nonempty_required_attribute_names);
    try testing.expectEqual(@as(usize, 121), operation_count);
}

test "standard compiler dialect specs expose exact rollback record capacities" {
    const testing = std.testing;
    const specs = .{
        BuiltinDialect.spec,
        arith.spec,
        FuncDialect.spec,
        MemrefDialect.spec,
        ScfDialect.spec,
    };

    var operation_count: usize = 0;
    var type_count: usize = 0;
    var region_count: usize = 0;
    inline for (specs) |spec| {
        operation_count += spec.operations.len;
        type_count += spec.types.len;
        if (spec.operations.len != 0 or spec.types.len != 0) region_count += 1;
    }

    try testing.expectEqual(@as(usize, 72), operation_count);
    try testing.expectEqual(@as(usize, 64), type_count);
    try testing.expectEqual(@as(usize, 5), region_count);
}

test "registerChoirDialect lazily loads first-class builtin dialect (tick 41 rename)" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    try registerChoirDialect(&ctx);

    try testing.expect(ctx.lookupOperation("builtin.module") == null);

    _ = try ctx.getOrLoadDialect("builtin");

    try testing.expect(ctx.lookupOperation("builtin.module") != null);

    try testing.expectError(error.UnknownDialect, ctx.getOrLoadDialect("choir"));
}

test "registerChoirDialect leaves accelerator dialects to package extensions" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    try registerChoirDialect(&ctx);

    inline for (.{ "gpu", "spirv", "nvptx" }) |dialect_name| {
        try testing.expectError(error.UnknownDialect, ctx.getOrLoadDialect(dialect_name));
    }
}

test "registerChoirDialect lazily loads first-class tile dialect (tick 40 rename)" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    try registerChoirDialect(&ctx);

    try testing.expect(ctx.lookupOperation("tile.load") == null);
    try testing.expect(ctx.lookupType(tile.type_names.tile) == null);

    _ = try ctx.getOrLoadDialect("tile");

    try testing.expect(ctx.lookupOperation("tile.load") != null);
    try testing.expect(ctx.lookupOperation("tile.store") != null);
    try testing.expect(ctx.lookupOperation("tile.mma") != null);
    try testing.expect(ctx.lookupOperation("tile.copy") != null);
    const tile_type_info = ctx.lookupType(tile.type_names.tile) orelse return error.TestExpectedType;
    try testing.expect(tile_type_info.hasInterface(interfaces.TypeParamInterface.id));
    try testing.expect(ctx.lookupType(tile.type_names.barrier) != null);
}

test "registerChoirDialect lazily loads first-class aarch64 dialect (tick 40 rename)" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    try registerChoirDialect(&ctx);

    try testing.expect(ctx.lookupOperation("aarch64.add") == null);
    try testing.expect(ctx.lookupType(aarch64.type_names.gpr) == null);
    try testing.expect(ctx.lookupType(aarch64.type_names.fpr) == null);

    _ = try ctx.getOrLoadDialect("aarch64");

    try testing.expect(ctx.lookupOperation("aarch64.add") != null);
    try testing.expect(ctx.lookupOperation("aarch64.add_imm") != null);
    try testing.expect(ctx.lookupOperation("aarch64.get_reg") != null);
    try testing.expect(ctx.lookupType(aarch64.type_names.gpr) != null);
    try testing.expect(ctx.lookupType(aarch64.type_names.fpr) != null);
}

test "memref type reconstruction lazy-loads interfaces in strict contexts" {
    const testing = std.testing;

    var arena = alloc_arena.Arena.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    try registerChoirDialect(&ctx);
    const memref_type = try ctx.getDialectTypeFromNameWithKey("memref", "64,arith.f32,device");

    try testing.expect(ctx.lookupType(MemrefDialect.name) != null);
    try testing.expect((try ctx.getTypeParamPayload(memref_type, MemrefDialect.MemrefTypePayload)) != null);
    try testing.expect(ctx.typeInterface(memref_type, interfaces.ShapedTypeInterface) != null);
}
