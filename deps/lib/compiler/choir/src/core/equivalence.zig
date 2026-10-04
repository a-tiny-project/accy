const std = @import("std");
const alloc_arena = @import("alloc_arena");
const Operation = @import("operation/root.zig").Operation;
const Value = @import("value.zig").Value;
const Attribute = @import("attribute.zig").Attribute;
const NamedAttribute = @import("attribute.zig").NamedAttribute;
const context_mod = @import("context/root.zig");
const Context = context_mod.Context;
const Location = @import("location.zig").Location;
const interfaces = @import("interfaces/root.zig");

pub const OperationEquivalence = struct {
    pub const ValueMapper = *const fn (?*const anyopaque, *Value) *Value;

    pub const AttributeFilter = *const fn (?*const anyopaque, *Operation, NamedAttribute) bool;

    pub const Options = struct {
        value_mapper: ?ValueMapper = null,
        value_mapper_context: ?*const anyopaque = null,
        attribute_filter: ?AttributeFilter = null,
        attribute_filter_context: ?*const anyopaque = null,
        commute_operands: bool = false,
        include_locations: bool = false,
    };

    pub fn computeHash(
        op: *Operation,
        options: Options,
    ) u64 {
        var hasher = std.hash.Wyhash.init(0);

        updateBytes(&hasher, op.name.name);
        updateU64(&hasher, op.regions.items.len);
        updateU64(&hasher, op.successors.items.len);
        updateU64(&hasher, op.result_types.len);
        for (op.result_types) |typ| {
            updateU64(&hasher, typ.uniqueId());
        }

        if (options.include_locations) {
            updateLocation(&hasher, op.location);
        }

        const operands = op.operand_values;
        updateU64(&hasher, operands.len);
        if (options.commute_operands and operands.len > 1) {
            var operand_hash: u64 = 0;
            for (operands) |operand| {
                operand_hash +%= valueHash(options, operand);
            }
            updateU64(&hasher, operand_hash);
        } else {
            for (operands) |operand| {
                updateU64(&hasher, valueHash(options, operand));
            }
        }

        var hash_iter = op.getAttrs();
        while (hash_iter.next()) |attr| {
            if (!attributeIncluded(options, op, attr)) continue;
            updateBytes(&hasher, attr.name);
            updateAttribute(&hasher, attr.value);
        }

        return hasher.final();
    }

    pub fn isEquivalentTo(
        lhs: *Operation,
        rhs: *Operation,
        options: Options,
    ) bool {
        if (lhs == rhs) return true;
        if (!sameName(lhs.name.name, rhs.name.name)) return false;
        if (lhs.regions.items.len != rhs.regions.items.len) return false;
        if (lhs.successors.items.len != rhs.successors.items.len) return false;
        if (lhs.operands.items.len != rhs.operands.items.len) return false;
        if (lhs.result_types.len != rhs.result_types.len) return false;
        if (options.include_locations and !lhs.location.eql(rhs.location)) return false;

        for (lhs.result_types, rhs.result_types) |lhs_type, rhs_type| {
            if (!lhs_type.eql(rhs_type)) return false;
        }

        if (!operandsEquivalent(lhs.operand_values, rhs.operand_values, options)) {
            return false;
        }

        return attrsEquivalent(lhs, rhs, options);
    }

    pub fn exactValueMapper(_: ?*const anyopaque, value: *Value) *Value {
        return value;
    }

    fn valueHash(options: Options, value: *Value) u64 {
        return @intFromPtr(mapValue(options, value));
    }

    fn mapValue(options: Options, value: *Value) *Value {
        if (options.value_mapper) |mapper| {
            return mapper(options.value_mapper_context, value);
        }
        return value;
    }

    fn attributeIncluded(options: Options, op: *Operation, attr: NamedAttribute) bool {
        if (options.attribute_filter) |filter| {
            return filter(options.attribute_filter_context, op, attr);
        }
        return true;
    }
};

fn operandsEquivalent(
    lhs: []const *Value,
    rhs: []const *Value,
    options: OperationEquivalence.Options,
) bool {
    if (lhs.len != rhs.len) return false;
    if (!options.commute_operands or lhs.len <= 1) {
        for (lhs, rhs) |lhs_value, rhs_value| {
            if (OperationEquivalence.mapValue(options, lhs_value) !=
                OperationEquivalence.mapValue(options, rhs_value))
            {
                return false;
            }
        }
        return true;
    }

    if (lhs.len == 2) {
        const lhs_0 = OperationEquivalence.mapValue(options, lhs[0]);
        const lhs_1 = OperationEquivalence.mapValue(options, lhs[1]);
        const rhs_0 = OperationEquivalence.mapValue(options, rhs[0]);
        const rhs_1 = OperationEquivalence.mapValue(options, rhs[1]);
        return (lhs_0 == rhs_0 and lhs_1 == rhs_1) or
            (lhs_0 == rhs_1 and lhs_1 == rhs_0);
    }

    for (lhs, 0..) |lhs_value, lhs_index| {
        const mapped_lhs = OperationEquivalence.mapValue(options, lhs_value);
        var seen = false;
        for (lhs[0..lhs_index]) |earlier_value| {
            if (OperationEquivalence.mapValue(options, earlier_value) == mapped_lhs) {
                seen = true;
                break;
            }
        }
        if (seen) continue;

        var lhs_count: usize = 0;
        for (lhs) |value| {
            lhs_count += @intFromBool(OperationEquivalence.mapValue(options, value) == mapped_lhs);
        }
        var rhs_count: usize = 0;
        for (rhs) |value| {
            rhs_count += @intFromBool(OperationEquivalence.mapValue(options, value) == mapped_lhs);
        }
        if (lhs_count != rhs_count) return false;
    }
    return true;
}

fn attrsEquivalent(lhs: *Operation, rhs: *Operation, options: OperationEquivalence.Options) bool {
    var lhs_iter = lhs.getAttrs();
    var rhs_iter = rhs.getAttrs();
    while (true) {
        const lhs_attr = nextIncluded(&lhs_iter, lhs, options);
        const rhs_attr = nextIncluded(&rhs_iter, rhs, options);
        if (lhs_attr == null or rhs_attr == null) return lhs_attr == null and rhs_attr == null;
        if (!sameName(lhs_attr.?.name, rhs_attr.?.name)) return false;
        if (!lhs_attr.?.value.eql(rhs_attr.?.value)) return false;
    }
}

fn nextIncluded(
    attrs: *Operation.AttributeIterator,
    op: *Operation,
    options: OperationEquivalence.Options,
) ?NamedAttribute {
    while (attrs.next()) |attr| {
        if (OperationEquivalence.attributeIncluded(options, op, attr)) return attr;
    }
    return null;
}

fn sameName(lhs: []const u8, rhs: []const u8) bool {
    return (lhs.ptr == rhs.ptr and lhs.len == rhs.len) or std.mem.eql(u8, lhs, rhs);
}

fn updateLocation(hasher: *std.hash.Wyhash, loc: Location) void {
    const Tag = std.meta.Tag(Location);
    updateU64(hasher, @backingInt(@as(Tag, loc)));
    switch (loc) {
        .unknown => {},
        .file => |file| {
            updateBytes(hasher, file.filename);
            updateU64(hasher, file.line);
            updateU64(hasher, file.column);
        },
        .file_range => |range| {
            updateBytes(hasher, range.filename);
            updateU64(hasher, range.start.byte);
            updateU64(hasher, range.start.line);
            updateU64(hasher, range.start.column);
            updateU64(hasher, range.end.byte);
            updateU64(hasher, range.end.line);
            updateU64(hasher, range.end.column);
        },
        .name => |name| {
            updateBytes(hasher, name.name);
            updateU64(hasher, if (name.child == null) 0 else 1);
            if (name.child) |child| updateLocation(hasher, child.*);
        },
        .fused => |fused| {
            updateU64(hasher, fused.locations.len);
            for (fused.locations) |child| {
                updateLocation(hasher, child);
            }
            updateU64(hasher, if (fused.metadata) |metadata| @intFromPtr(metadata) else 0);
        },
        .call_site => |call_site| {
            updateLocation(hasher, call_site.callee.*);
            updateLocation(hasher, call_site.caller.*);
        },
    }
}

fn updateAttribute(hasher: *std.hash.Wyhash, attr: Attribute) void {
    updateU64(hasher, @backingInt(attr.attr_id));
    updateBytes(hasher, attr.abstract.name);

    if (attr.cast(Attribute.IntegerAttr)) |int_attr| {
        updateU64(hasher, @bitCast(int_attr.value));
        updateU64(hasher, int_attr.width);
        updateU64(hasher, if (int_attr.is_signed) 1 else 0);
        return;
    }
    if (attr.cast(Attribute.FloatAttr)) |float_attr| {
        updateU64(hasher, @bitCast(float_attr.value));
        updateU64(hasher, float_attr.width);
        return;
    }
    if (attr.cast(Attribute.BoolAttr)) |bool_attr| {
        updateU64(hasher, if (bool_attr.value) 1 else 0);
        return;
    }
    if (attr.cast(Attribute.StringAttr)) |string_attr| {
        updateBytes(hasher, string_attr.value);
        return;
    }
    if (attr.cast(Attribute.SymbolRefAttr)) |symbol_ref| {
        updateBytes(hasher, symbol_ref.root_reference);
        updateU64(hasher, symbol_ref.nested_references.len);
        for (symbol_ref.nested_references) |nested| {
            updateBytes(hasher, nested);
        }
        return;
    }
    if (attr.cast(Attribute.StringListAttr)) |list_attr| {
        updateU64(hasher, list_attr.values.len);
        for (list_attr.values) |value| {
            updateBytes(hasher, value);
        }
        return;
    }
    if (attr.cast(Attribute.TypeListAttr)) |list_attr| {
        updateU64(hasher, list_attr.values.len);
        for (list_attr.values) |typ| {
            updateU64(hasher, typ.uniqueId());
        }
        return;
    }
    if (attr.cast(Attribute.ArrayAttr)) |array_attr| {
        updateU64(hasher, array_attr.values.len);
        for (array_attr.values) |value| {
            updateAttribute(hasher, value);
        }
        return;
    }
    if (attr.cast(Attribute.DialectAttr)) |dialect_attr| {
        updateBytes(hasher, dialect_attr.payload);
        return;
    }

    updateU64(hasher, @intFromPtr(attr.impl));
}

fn updateBytes(hasher: *std.hash.Wyhash, bytes: []const u8) void {
    updateU64(hasher, bytes.len);
    hasher.update(bytes);
}

fn updateU64(hasher: *std.hash.Wyhash, value: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    hasher.update(&buf);
}

fn operationWithOperands(
    ctx: *Context,
    name: []const u8,
    operands: []const *Value,
    result_type: @import("type.zig").Type,
) !*Operation {
    var state = Operation.State.init(name, Location.getUnknown());
    state.addOperands(operands);
    state.addTypes(&.{result_type});
    return try ctx.createOperation(state);
}

fn ignoreDebugAttr(_: ?*const anyopaque, _: *Operation, attr: NamedAttribute) bool {
    return !std.mem.eql(u8, attr.name, "debug.span");
}

const RemapPair = struct {
    from: *Value,
    to: *Value,
};

fn pairValueMapper(mapper_context: ?*const anyopaque, value: *Value) *Value {
    const pair: *const RemapPair = @ptrCast(@alignCast(mapper_context.?));
    if (value == pair.from) return pair.to;
    return value;
}

test "OperationEquivalence matches same operation shape" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ctx = try Context.init(arena_alloc, Context.Limits.testing);
    defer ctx.deinit(arena_alloc);
    try ctx.allowUnregistered();

    var region = context_mod.initRegion(&ctx);
    const block = try region.addBlock();
    const i32_type = try ctx.getDialectTypeFromName("test.i32");
    const lhs = try block.addArgument(i32_type, Location.getUnknown());
    const rhs = try block.addArgument(i32_type, Location.getUnknown());

    const first = try operationWithOperands(&ctx, "test.add", &.{ lhs, rhs }, i32_type);
    const second = try operationWithOperands(&ctx, "test.add", &.{ lhs, rhs }, i32_type);
    try first.setAttr("value", try ctx.getI64Attr(1));
    try second.setAttr("value", try ctx.getI64Attr(1));

    const first_hash = OperationEquivalence.computeHash(first, .{});
    const second_hash = OperationEquivalence.computeHash(second, .{});
    try testing.expectEqual(first_hash, second_hash);
    try testing.expect(OperationEquivalence.isEquivalentTo(first, second, .{}));
}

test "OperationEquivalence keeps distinct attrs apart" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ctx = try Context.init(arena_alloc, Context.Limits.testing);
    defer ctx.deinit(arena_alloc);
    try ctx.allowUnregistered();

    const i32_type = try ctx.getDialectTypeFromName("test.i32");
    const first = try operationWithOperands(&ctx, "test.constant", &.{}, i32_type);
    const second = try operationWithOperands(&ctx, "test.constant", &.{}, i32_type);
    try first.setAttr("value", try ctx.getI64Attr(1));
    try second.setAttr("value", try ctx.getI64Attr(2));

    const first_hash = OperationEquivalence.computeHash(first, .{});
    const second_hash = OperationEquivalence.computeHash(second, .{});
    try testing.expect(first_hash != second_hash);
    try testing.expect(!OperationEquivalence.isEquivalentTo(first, second, .{}));
}

test "OperationEquivalence filters nonsemantic attrs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ctx = try Context.init(arena_alloc, Context.Limits.testing);
    defer ctx.deinit(arena_alloc);
    try ctx.allowUnregistered();

    const i32_type = try ctx.getDialectTypeFromName("test.i32");
    const first = try operationWithOperands(&ctx, "test.constant", &.{}, i32_type);
    const second = try operationWithOperands(&ctx, "test.constant", &.{}, i32_type);
    try first.setAttr("debug.span", try ctx.getI64Attr(1));
    try second.setAttr("debug.span", try ctx.getI64Attr(2));

    const options = OperationEquivalence.Options{ .attribute_filter = ignoreDebugAttr };
    const first_hash = OperationEquivalence.computeHash(first, options);
    const second_hash = OperationEquivalence.computeHash(second, options);
    try testing.expectEqual(first_hash, second_hash);
    try testing.expect(OperationEquivalence.isEquivalentTo(first, second, options));
}

test "OperationEquivalence hashes inherent attributes without temporary allocation" {
    const testing = std.testing;

    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    _ = try ctx.registerOperation("test.constant", .{});
    try ctx.registerOperationInherentAttributeName("test.constant", "value");
    try ctx.registerOperationPropertiesModel(
        "test.constant",
        interfaces.singleAttributePropertiesModel("test.constant.properties", "value"),
    );

    const i32_type = try ctx.getDialectTypeFromName("test.i32");
    const first = try operationWithOperands(&ctx, "test.constant", &.{}, i32_type);
    const second = try operationWithOperands(&ctx, "test.constant", &.{}, i32_type);
    try first.setAttr("value", try ctx.getI64Attr(7));
    try second.setAttr("value", try ctx.getI64Attr(8));

    const first_hash = OperationEquivalence.computeHash(first, .{});
    const second_hash = OperationEquivalence.computeHash(second, .{});
    try testing.expect(first_hash != second_hash);
    try testing.expect(!OperationEquivalence.isEquivalentTo(first, second, .{}));
}

test "OperationEquivalence commutes operands" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ctx = try Context.init(arena_alloc, Context.Limits.testing);
    defer ctx.deinit(arena_alloc);
    try ctx.allowUnregistered();

    var region = context_mod.initRegion(&ctx);
    const block = try region.addBlock();
    const i32_type = try ctx.getDialectTypeFromName("test.i32");
    const lhs = try block.addArgument(i32_type, Location.getUnknown());
    const rhs = try block.addArgument(i32_type, Location.getUnknown());

    const first = try operationWithOperands(&ctx, "test.add", &.{ lhs, rhs }, i32_type);
    const second = try operationWithOperands(&ctx, "test.add", &.{ rhs, lhs }, i32_type);
    const options = OperationEquivalence.Options{ .commute_operands = true };

    const first_hash = OperationEquivalence.computeHash(first, options);
    const second_hash = OperationEquivalence.computeHash(second, options);
    try testing.expectEqual(first_hash, second_hash);
    try testing.expect(OperationEquivalence.isEquivalentTo(first, second, options));
    try testing.expect(!OperationEquivalence.isEquivalentTo(first, second, .{}));
}

test "OperationEquivalence preserves multiplicity for variadic commutative operands" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ctx = try Context.init(arena_alloc, Context.Limits.testing);
    defer ctx.deinit(arena_alloc);
    try ctx.allowUnregistered();

    var region = context_mod.initRegion(&ctx);
    const block = try region.addBlock();
    const i32_type = try ctx.getDialectTypeFromName("test.i32");
    const lhs = try block.addArgument(i32_type, Location.getUnknown());
    const rhs = try block.addArgument(i32_type, Location.getUnknown());
    const extra = try block.addArgument(i32_type, Location.getUnknown());

    const first = try operationWithOperands(
        &ctx,
        "test.combine",
        &.{ lhs, rhs, lhs, extra },
        i32_type,
    );
    const reordered = try operationWithOperands(
        &ctx,
        "test.combine",
        &.{ extra, lhs, rhs, lhs },
        i32_type,
    );
    const different = try operationWithOperands(
        &ctx,
        "test.combine",
        &.{ extra, lhs, rhs, rhs },
        i32_type,
    );
    const options = OperationEquivalence.Options{ .commute_operands = true };

    try testing.expectEqual(
        OperationEquivalence.computeHash(first, options),
        OperationEquivalence.computeHash(reordered, options),
    );
    try testing.expect(OperationEquivalence.isEquivalentTo(first, reordered, options));
    try testing.expect(!OperationEquivalence.isEquivalentTo(first, different, options));
}

test "OperationEquivalence maps values before comparing operands" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = alloc_arena.Arena.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var ctx = try Context.init(arena_alloc, Context.Limits.testing);
    defer ctx.deinit(arena_alloc);
    try ctx.allowUnregistered();

    var region = context_mod.initRegion(&ctx);
    const block = try region.addBlock();
    const i32_type = try ctx.getDialectTypeFromName("test.i32");
    const canonical = try block.addArgument(i32_type, Location.getUnknown());
    const stale = try block.addArgument(i32_type, Location.getUnknown());

    const first = try operationWithOperands(&ctx, "test.use", &.{canonical}, i32_type);
    const second = try operationWithOperands(&ctx, "test.use", &.{stale}, i32_type);
    const pair = RemapPair{ .from = stale, .to = canonical };
    const options = OperationEquivalence.Options{
        .value_mapper = pairValueMapper,
        .value_mapper_context = &pair,
    };

    const first_hash = OperationEquivalence.computeHash(first, options);
    const second_hash = OperationEquivalence.computeHash(second, options);
    try testing.expectEqual(first_hash, second_hash);
    try testing.expect(OperationEquivalence.isEquivalentTo(first, second, options));
    try testing.expect(!OperationEquivalence.isEquivalentTo(first, second, .{}));
}
