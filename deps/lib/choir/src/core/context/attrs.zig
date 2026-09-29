const std = @import("std");
const alloc_phase = @import("alloc_phase");
const attribute = @import("../root.zig").attribute;
const Attribute = attribute.Attribute;
const Operation = @import("../root.zig").Operation;
const Type = @import("../root.zig").Type;
const interfaces = @import("../root.zig").interfaces;
const attrs = @import("../root.zig").attrs;
const dialect_ctx = @import("dialects.zig");
const freeze_ctx = @import("freeze.zig");
const memory_ctx = @import("memory.zig");
const transactions = @import("transactions.zig");

pub fn lookupAttributeType(
    ctx: anytype,
    attr_name: []const u8,
) ?*const interfaces.AbstractAttribute {
    return ctx.attr_interner.registry.lookup(attr_name);
}

pub fn registerAttributeType(
    ctx: anytype,
    attr_name: []const u8,
    iface_entries: []const interfaces.InterfaceEntry,
) (@TypeOf(ctx.*).Error || interfaces.AttributeRegistry.RegisterError)!*const interfaces.AbstractAttribute {
    try freeze_ctx.requireMutable(ctx);

    const name_struct = Operation.OperationName.init(attr_name);
    const ns = name_struct.getDialectNamespace();
    if (ns.len > 0) {
        if (ctx.dialect_registry.load_state.get(ns)) |state| {
            if (state == .loaded) {
                _ = dialect_ctx.getOrLoadDialect(ctx, ns) catch {};
            }
        } else {
            _ = dialect_ctx.getOrLoadDialect(ctx, ns) catch {};
        }
    }

    const existed_before = ctx.attr_interner.registry.lookup(attr_name) != null;

    const attr = ctx.attr_interner.registry.registerAttribute(attr_name, iface_entries) catch |err| switch (err) {
        error.DuplicateAttribute => blk: {
            for (iface_entries) |entry| {
                ctx.attr_interner.registry.registerOrReplaceInterface(attr_name, entry) catch |e| switch (e) {
                    error.UnknownAttribute => unreachable,
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
            break :blk ctx.attr_interner.registry.lookup(attr_name).?;
        },
        else => return err,
    };

    if (!existed_before) {
        try transactions.recordCreatedAttribute(ctx, attr_name, true);
    }

    return attr;
}

pub fn registerAttributeInterfaceExternal(
    ctx: anytype,
    attr_name: []const u8,
    entry: interfaces.InterfaceEntry,
) (@TypeOf(ctx.*).Error || std.mem.Allocator.Error)!void {
    try freeze_ctx.requireMutable(ctx);
    if (ctx.attr_interner.registry.lookup(attr_name) == null) {
        _ = try registerAttributeType(ctx, attr_name, &.{});
    }
    ctx.attr_interner.registry.registerOrReplaceInterface(attr_name, entry) catch |err| switch (err) {
        error.UnknownAttribute => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

pub fn getDialectAttr(
    ctx: anytype,
    full_name: []const u8,
    payload: []const u8,
) !Attribute {
    const abstract = ctx.attr_interner.registry.lookup(full_name) orelse blk: {
        const iface = interfaces.AttributeEqualInterface.entry(&attribute.dialect_attr_eql_vtable);
        const interfaces_list = &.{iface};
        break :blk try registerAttributeType(ctx, full_name, interfaces_list);
    };

    const lookup_key = attrs.DialectAttrKey{
        .attr_id = abstract.attr_id,
        .payload = payload,
    };
    if (ctx.attr_interner.storage.dialect_attrs.get(lookup_key)) |attr| {
        return attr;
    }

    try freeze_ctx.requireSingleThreadedMutation(ctx);

    const payload_copy = try memory_ctx.segmentAllocator(ctx, .attribute_payloads).dupe(u8, payload);
    errdefer memory_ctx.segmentAllocator(ctx, .attribute_payloads).free(payload_copy);
    const storage = try memory_ctx.segmentAllocator(ctx, .attribute_payloads).create(Attribute.DialectAttr);
    errdefer memory_ctx.segmentAllocator(ctx, .attribute_payloads).destroy(storage);
    storage.* = .{ .payload = payload_copy, .context = ctx };

    const a = Attribute{
        .attr_id = Attribute.attrIdFromInt(abstract.attr_id),
        .impl = storage,
        .abstract = abstract,
    };

    try ctx.attr_interner.storage.dialect_attrs.put(
        .{ .attr_id = abstract.attr_id, .payload = payload_copy },
        a,
    );
    return a;
}

pub fn getIntegerAttr(
    ctx: anytype,
    value: i64,
    width: u8,
    is_signed: bool,
) !Attribute {
    const lookup_key = attrs.IntegerAttrKey{
        .value = value,
        .width = width,
        .is_signed = is_signed,
    };

    if (ctx.attr_interner.storage.integer_attrs.get(lookup_key)) |attr| {
        return attr;
    }

    try freeze_ctx.requireSingleThreadedMutation(ctx);

    const abstract = ctx.attr_interner.registry.lookup(attribute.builtin_attr_names.integer) orelse blk: {
        const iface = interfaces.AttributeEqualInterface.entry(&attribute.integer_attr_eql_vtable);
        break :blk try registerAttributeType(ctx, attribute.builtin_attr_names.integer, &.{iface});
    };

    const storage = try memory_ctx.segmentAllocator(ctx, .attribute_payloads).create(Attribute.IntegerAttr);
    errdefer memory_ctx.segmentAllocator(ctx, .attribute_payloads).destroy(storage);
    storage.* = .{
        .value = value,
        .width = width,
        .is_signed = is_signed,
        .context = ctx,
    };

    const a = Attribute{
        .attr_id = Attribute.attrIdFromInt(abstract.attr_id),
        .impl = storage,
        .abstract = abstract,
    };

    try ctx.attr_interner.storage.integer_attrs.put(lookup_key, a);
    return a;
}

pub fn getI64Attr(ctx: anytype, value: i64) !Attribute {
    return getIntegerAttr(ctx, value, 64, true);
}

pub fn getI32Attr(ctx: anytype, value: i32) !Attribute {
    return getIntegerAttr(ctx, value, 32, true);
}

pub fn getFloatAttr(
    ctx: anytype,
    value: f64,
    width: u8,
) !Attribute {
    const lookup_key = attrs.FloatAttrKey{
        .value_bits = @bitCast(value),
        .width = width,
    };

    if (ctx.attr_interner.storage.float_attrs.get(lookup_key)) |attr| {
        return attr;
    }

    try freeze_ctx.requireSingleThreadedMutation(ctx);

    const abstract = ctx.attr_interner.registry.lookup(attribute.builtin_attr_names.float_) orelse blk: {
        const iface = interfaces.AttributeEqualInterface.entry(&attribute.float_attr_eql_vtable);
        break :blk try registerAttributeType(ctx, attribute.builtin_attr_names.float_, &.{iface});
    };

    const storage = try memory_ctx.segmentAllocator(ctx, .attribute_payloads).create(Attribute.FloatAttr);
    errdefer memory_ctx.segmentAllocator(ctx, .attribute_payloads).destroy(storage);
    storage.* = .{
        .value = value,
        .width = width,
        .context = ctx,
    };

    const a = Attribute{
        .attr_id = Attribute.attrIdFromInt(abstract.attr_id),
        .impl = storage,
        .abstract = abstract,
    };

    try ctx.attr_interner.storage.float_attrs.put(lookup_key, a);
    return a;
}

pub fn getF64Attr(ctx: anytype, value: f64) !Attribute {
    return getFloatAttr(ctx, value, 64);
}

pub fn getF32Attr(ctx: anytype, value: f32) !Attribute {
    return getFloatAttr(ctx, value, 32);
}

pub fn getBoolAttr(ctx: anytype, value: bool) !Attribute {
    if (ctx.attr_interner.storage.bool_attrs.get(value)) |attr| {
        return attr;
    }

    try freeze_ctx.requireSingleThreadedMutation(ctx);

    const abstract = ctx.attr_interner.registry.lookup(attribute.builtin_attr_names.bool_) orelse blk: {
        const iface = interfaces.AttributeEqualInterface.entry(&attribute.bool_attr_eql_vtable);
        break :blk try registerAttributeType(ctx, attribute.builtin_attr_names.bool_, &.{iface});
    };

    const storage = try memory_ctx.segmentAllocator(ctx, .attribute_payloads).create(Attribute.BoolAttr);
    errdefer memory_ctx.segmentAllocator(ctx, .attribute_payloads).destroy(storage);
    storage.* = .{
        .value = value,
        .context = ctx,
    };

    const a = Attribute{
        .attr_id = Attribute.attrIdFromInt(abstract.attr_id),
        .impl = storage,
        .abstract = abstract,
    };

    try ctx.attr_interner.storage.bool_attrs.put(value, a);
    return a;
}

pub fn getStringAttr(ctx: anytype, value: []const u8) !Attribute {
    const lookup_key = attrs.StringAttrKey{ .value = value };

    if (ctx.attr_interner.storage.string_attrs.get(lookup_key)) |attr| {
        return attr;
    }

    try freeze_ctx.requireSingleThreadedMutation(ctx);

    const abstract = ctx.attr_interner.registry.lookup(attribute.builtin_attr_names.string) orelse blk: {
        const iface = interfaces.AttributeEqualInterface.entry(&attribute.string_attr_eql_vtable);
        break :blk try registerAttributeType(ctx, attribute.builtin_attr_names.string, &.{iface});
    };

    const value_copy = try memory_ctx.segmentAllocator(ctx, .attribute_payloads).dupe(u8, value);
    errdefer memory_ctx.segmentAllocator(ctx, .attribute_payloads).free(value_copy);

    const storage = try memory_ctx.segmentAllocator(ctx, .attribute_payloads).create(Attribute.StringAttr);
    errdefer memory_ctx.segmentAllocator(ctx, .attribute_payloads).destroy(storage);
    storage.* = .{
        .value = value_copy,
        .context = ctx,
    };

    const a = Attribute{
        .attr_id = Attribute.attrIdFromInt(abstract.attr_id),
        .impl = storage,
        .abstract = abstract,
    };

    try ctx.attr_interner.storage.string_attrs.put(.{ .value = value_copy }, a);
    return a;
}

pub fn getSymbolRefAttr(
    ctx: anytype,
    root_reference: []const u8,
    nested_references: []const []const u8,
) !Attribute {
    const lookup_key = attrs.SymbolRefAttrKey{
        .root_reference = root_reference,
        .nested_references = nested_references,
    };

    if (ctx.attr_interner.storage.symbol_ref_attrs.get(lookup_key)) |attr| {
        return attr;
    }

    try freeze_ctx.requireSingleThreadedMutation(ctx);

    const abstract = ctx.attr_interner.registry.lookup(attribute.builtin_attr_names.symbol_ref) orelse blk: {
        const equal_iface = interfaces.AttributeEqualInterface.entry(&attribute.symbol_ref_attr_eql_vtable);
        const print_iface = interfaces.AttributePrintInterface.entry(&attribute.symbol_ref_attr_print_vtable);
        break :blk try registerAttributeType(ctx, attribute.builtin_attr_names.symbol_ref, &.{ equal_iface, print_iface });
    };

    const root_copy = try memory_ctx.segmentAllocator(ctx, .attribute_payloads).dupe(u8, root_reference);
    errdefer memory_ctx.segmentAllocator(ctx, .attribute_payloads).free(root_copy);

    const nested_copy = try dupeStringList(memory_ctx.segmentAllocator(ctx, .attribute_payloads), nested_references);
    errdefer {
        var index = nested_copy.len;
        while (index > 0) {
            index -= 1;
            memory_ctx.segmentAllocator(ctx, .attribute_payloads).free(nested_copy[index]);
        }
        if (nested_copy.len > 0) memory_ctx.segmentAllocator(ctx, .attribute_payloads).free(nested_copy);
    }

    const storage = try memory_ctx.segmentAllocator(ctx, .attribute_payloads).create(Attribute.SymbolRefAttr);
    errdefer memory_ctx.segmentAllocator(ctx, .attribute_payloads).destroy(storage);
    storage.* = .{
        .root_reference = root_copy,
        .nested_references = nested_copy,
        .context = ctx,
    };

    const a = Attribute{
        .attr_id = Attribute.attrIdFromInt(abstract.attr_id),
        .impl = storage,
        .abstract = abstract,
    };

    try ctx.attr_interner.storage.symbol_ref_attrs.put(.{
        .root_reference = root_copy,
        .nested_references = nested_copy,
    }, a);
    return a;
}

pub fn getFlatSymbolRefAttr(ctx: anytype, root_reference: []const u8) !Attribute {
    return getSymbolRefAttr(ctx, root_reference, &.{});
}

fn dupeStringList(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    if (values.len == 0) return &[_][]const u8{};

    const values_copy = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(values_copy);

    var initialized: usize = 0;
    errdefer {
        while (initialized > 0) {
            initialized -= 1;
            allocator.free(values_copy[initialized]);
        }
    }

    for (values, 0..) |value, index| {
        values_copy[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }

    return values_copy;
}

pub fn getStringListAttr(ctx: anytype, values: []const []const u8) !Attribute {
    const lookup_key = attrs.StringListAttrKey{ .values = values };

    if (ctx.attr_interner.storage.string_list_attrs.get(lookup_key)) |attr| {
        return attr;
    }

    try freeze_ctx.requireSingleThreadedMutation(ctx);

    const abstract = ctx.attr_interner.registry.lookup(attribute.builtin_attr_names.string_list) orelse blk: {
        const iface = interfaces.AttributeEqualInterface.entry(&attribute.string_list_attr_eql_vtable);
        break :blk try registerAttributeType(ctx, attribute.builtin_attr_names.string_list, &.{iface});
    };

    const values_copy = try dupeStringList(memory_ctx.segmentAllocator(ctx, .attribute_payloads), values);
    errdefer {
        var index = values_copy.len;
        while (index > 0) {
            index -= 1;
            memory_ctx.segmentAllocator(ctx, .attribute_payloads).free(values_copy[index]);
        }
        if (values_copy.len > 0) memory_ctx.segmentAllocator(ctx, .attribute_payloads).free(values_copy);
    }

    const storage = try memory_ctx.segmentAllocator(ctx, .attribute_payloads).create(Attribute.StringListAttr);
    errdefer memory_ctx.segmentAllocator(ctx, .attribute_payloads).destroy(storage);
    storage.* = .{
        .values = values_copy,
        .context = ctx,
    };

    const a = Attribute{
        .attr_id = Attribute.attrIdFromInt(abstract.attr_id),
        .impl = storage,
        .abstract = abstract,
    };

    try ctx.attr_interner.storage.string_list_attrs.put(.{ .values = values_copy }, a);
    return a;
}

pub fn getTypeListAttr(ctx: anytype, values: []const Type) !Attribute {
    const lookup_key = attrs.TypeListAttrKey{ .values = values };

    if (ctx.attr_interner.storage.type_list_attrs.get(lookup_key)) |attr| {
        return attr;
    }

    try freeze_ctx.requireSingleThreadedMutation(ctx);

    const abstract = ctx.attr_interner.registry.lookup(attribute.builtin_attr_names.type_list) orelse blk: {
        const iface = interfaces.AttributeEqualInterface.entry(&attribute.type_list_attr_eql_vtable);
        break :blk try registerAttributeType(ctx, attribute.builtin_attr_names.type_list, &.{iface});
    };

    const values_copy = if (values.len > 0)
        try memory_ctx.segmentAllocator(ctx, .attribute_payloads).dupe(Type, values)
    else
        &[_]Type{};
    errdefer if (values_copy.len > 0) memory_ctx.segmentAllocator(ctx, .attribute_payloads).free(values_copy);

    const storage = try memory_ctx.segmentAllocator(ctx, .attribute_payloads).create(Attribute.TypeListAttr);
    errdefer memory_ctx.segmentAllocator(ctx, .attribute_payloads).destroy(storage);
    storage.* = .{
        .values = values_copy,
        .context = ctx,
    };

    const a = Attribute{
        .attr_id = Attribute.attrIdFromInt(abstract.attr_id),
        .impl = storage,
        .abstract = abstract,
    };

    try ctx.attr_interner.storage.type_list_attrs.put(.{ .values = values_copy }, a);
    return a;
}

pub fn getArrayAttr(ctx: anytype, values: []const Attribute) !Attribute {
    const lookup_key = attrs.ArrayAttrKey{ .values = values };

    if (ctx.attr_interner.storage.array_attrs.get(lookup_key)) |attr| {
        return attr;
    }

    try freeze_ctx.requireSingleThreadedMutation(ctx);

    const abstract = ctx.attr_interner.registry.lookup(attribute.builtin_attr_names.array) orelse blk: {
        const equal_iface = interfaces.AttributeEqualInterface.entry(&attribute.array_attr_eql_vtable);
        const array_iface = interfaces.AttributeArrayInterface.entry(&attribute.array_attr_array_vtable);
        break :blk try registerAttributeType(ctx, attribute.builtin_attr_names.array, &.{ equal_iface, array_iface });
    };

    const values_copy = if (values.len > 0)
        try memory_ctx.segmentAllocator(ctx, .attribute_payloads).dupe(Attribute, values)
    else
        &[_]Attribute{};
    errdefer if (values_copy.len > 0) memory_ctx.segmentAllocator(ctx, .attribute_payloads).free(values_copy);

    const storage = try memory_ctx.segmentAllocator(ctx, .attribute_payloads).create(Attribute.ArrayAttr);
    errdefer memory_ctx.segmentAllocator(ctx, .attribute_payloads).destroy(storage);
    storage.* = .{
        .values = values_copy,
        .context = ctx,
    };

    const a = Attribute{
        .attr_id = Attribute.attrIdFromInt(abstract.attr_id),
        .impl = storage,
        .abstract = abstract,
    };

    try ctx.attr_interner.storage.array_attrs.put(.{ .values = values_copy }, a);
    return a;
}

test "Context attribute store cleanup" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    _ = try ctx.getDialectAttr("test.unit", "");
    _ = try ctx.getDialectAttr("test.bool", &[_]u8{1});
    _ = try ctx.getDialectAttr("test.bool", &[_]u8{0});
    _ = try ctx.getDialectAttr("test.int", "42");
    _ = try ctx.getDialectAttr("test.int", "100");
    _ = try ctx.getDialectAttr("test.string", "test");
    _ = try ctx.getDialectAttr("test.string", "another");
    _ = try ctx.getDialectAttr("test.type", "test.ty");
}

test "Context attribute type registration upgrades existing attributes" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const attr = try ctx.getDialectAttr("test.foo", "payload");

    const before = try std.fmt.allocPrint(testing.allocator, "{f}", .{attr});
    defer testing.allocator.free(before);
    try testing.expectEqualStrings("#attr<test.foo>", before);

    const Print = struct {
        fn print(_: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("foo");
        }
    };
    const vtable = interfaces.AttributePrintInterface.vtableFor(Print.print);
    const ifaces = [_]interfaces.InterfaceEntry{
        interfaces.AttributePrintInterface.entry(vtable),
    };

    _ = try ctx.registerAttributeType("test.foo", &ifaces);

    const after = try std.fmt.allocPrint(testing.allocator, "{f}", .{attr});
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("foo", after);
}

test "Context getDialectAttr creates and uniques dialect attributes" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const attr1 = try ctx.getDialectAttr("test.foo", "payload");
    const attr2 = try ctx.getDialectAttr("test.foo", "payload");
    const attr3 = try ctx.getDialectAttr("test.foo", "other");
    const attr4 = try ctx.getDialectAttr("test.bar", "payload");

    try testing.expectEqual(attr1.impl, attr2.impl);

    try testing.expect(attr1.impl != attr3.impl);
    try testing.expect(attr1.impl != attr4.impl);

    try testing.expectEqualStrings("test.foo", attr1.abstract.name);
    const dialect_attr = attr1.cast(Attribute.DialectAttr).?;
    try testing.expectEqualStrings("payload", dialect_attr.payload);
}

test "Context attributes cast by storage type" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const int_attr = try ctx.getI64Attr(42);
    const string_attr = try ctx.getStringAttr("name");
    const dialect_attr = try ctx.getDialectAttr("test.flag", "payload");

    try testing.expect(int_attr.hasStorageType(Attribute.IntegerAttr));
    try testing.expect(int_attr.cast(Attribute.IntegerAttr) != null);
    try testing.expect(int_attr.cast(Attribute.StringAttr) == null);
    try testing.expect(int_attr.cast(Attribute.DialectAttr) == null);

    try testing.expect(string_attr.cast(Attribute.StringAttr) != null);
    try testing.expect(string_attr.cast(Attribute.IntegerAttr) == null);

    try testing.expect(dialect_attr.hasStorageType(Attribute.DialectAttr));
    try testing.expect(dialect_attr.cast(Attribute.DialectAttr) != null);
    try testing.expect(dialect_attr.cast(Attribute.BoolAttr) == null);
}

test "Context getIntegerAttr creates typed integer attribute" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const attr = try ctx.getI64Attr(42);

    try testing.expectEqualStrings(attribute.builtin_attr_names.integer, attr.abstract.name);

    const int_attr = attr.cast(Attribute.IntegerAttr).?;
    try testing.expectEqual(@as(i64, 42), int_attr.getValue());
    try testing.expectEqual(@as(u8, 64), int_attr.width);
    try testing.expect(int_attr.is_signed);
}

test "Context getIntegerAttr uniquing works correctly" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const attr1 = try ctx.getI64Attr(42);
    const attr2 = try ctx.getI64Attr(42);
    const attr3 = try ctx.getI64Attr(100);

    try testing.expectEqual(attr1.impl, attr2.impl);

    try testing.expect(attr1.impl != attr3.impl);
}

test "Context getFloatAttr creates typed float attribute" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const attr = try ctx.getF64Attr(3.14);

    try testing.expectEqualStrings(attribute.builtin_attr_names.float_, attr.abstract.name);

    const float_attr = attr.cast(Attribute.FloatAttr).?;
    try testing.expectApproxEqAbs(@as(f64, 3.14), float_attr.getValue(), 0.001);
    try testing.expectEqual(@as(u8, 64), float_attr.width);
}

test "Context getFloatAttr uniquing handles special values" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const pos_zero = try ctx.getF64Attr(0.0);
    const neg_zero = try ctx.getF64Attr(-0.0);

    try testing.expect(pos_zero.impl != neg_zero.impl);
}

test "Context getBoolAttr creates typed bool attribute" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const true_attr = try ctx.getBoolAttr(true);
    const false_attr = try ctx.getBoolAttr(false);

    try testing.expectEqualStrings(attribute.builtin_attr_names.bool_, true_attr.abstract.name);
    try testing.expectEqualStrings(attribute.builtin_attr_names.bool_, false_attr.abstract.name);

    const true_val = true_attr.cast(Attribute.BoolAttr).?;
    const false_val = false_attr.cast(Attribute.BoolAttr).?;
    try testing.expect(true_val.getValue());
    try testing.expect(!false_val.getValue());
}

test "Context getStringAttr creates typed string attribute" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const attr = try ctx.getStringAttr("hello");

    try testing.expectEqualStrings(attribute.builtin_attr_names.string, attr.abstract.name);

    const str_attr = attr.cast(Attribute.StringAttr).?;
    try testing.expectEqualStrings("hello", str_attr.getValue());
}

test "Context getStringAttr uniquing works correctly" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const attr1 = try ctx.getStringAttr("test");
    const attr2 = try ctx.getStringAttr("test");
    const attr3 = try ctx.getStringAttr("different");

    try testing.expectEqual(attr1.impl, attr2.impl);

    try testing.expect(attr1.impl != attr3.impl);
}

test "Context getSymbolRefAttr creates and uniques symbol references" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const attr1 = try ctx.getSymbolRefAttr("module", &.{ "nested", "leaf" });
    const attr2 = try ctx.getSymbolRefAttr("module", &.{ "nested", "leaf" });
    const attr3 = try ctx.getSymbolRefAttr("module", &.{"other"});
    const flat = try ctx.getFlatSymbolRefAttr("module");

    try testing.expectEqual(attr1.impl, attr2.impl);
    try testing.expect(attr1.impl != attr3.impl);
    try testing.expect(flat.impl != attr1.impl);
    try testing.expectEqualStrings(attribute.builtin_attr_names.symbol_ref, attr1.abstract.name);

    const ref_attr = attr1.cast(Attribute.SymbolRefAttr).?;
    try testing.expectEqualStrings("module", ref_attr.getRootReference());
    try testing.expectEqualStrings("leaf", ref_attr.getLeafReference());
    try testing.expect(!ref_attr.isFlat());

    const rendered = try std.fmt.allocPrint(testing.allocator, "{f}", .{attr1});
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("@module::@nested::@leaf", rendered);
}

test "Context getStringListAttr creates and uniques structural string lists" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const attr1 = try ctx.getStringListAttr(&.{ "ctx", "value", "result" });
    const attr2 = try ctx.getStringListAttr(&.{ "ctx", "value", "result" });
    const attr3 = try ctx.getStringListAttr(&.{ "ctx", "result" });

    try testing.expectEqualStrings(attribute.builtin_attr_names.string_list, attr1.abstract.name);
    try testing.expectEqual(attr1.impl, attr2.impl);
    try testing.expect(attr1.impl != attr3.impl);

    const list_attr = attr1.cast(Attribute.StringListAttr).?;
    const values = list_attr.getValues();
    try testing.expectEqual(@as(usize, 3), values.len);
    try testing.expectEqualStrings("ctx", values[0]);
    try testing.expectEqualStrings("value", values[1]);
    try testing.expectEqualStrings("result", values[2]);
}

test "Context getTypeListAttr creates and uniques structural type lists" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const i32_type = try ctx.getDialectTypeFromName("arith.i32");
    const i64_type = try ctx.getDialectTypeFromName("arith.i64");

    const attr1 = try ctx.getTypeListAttr(&.{ i32_type, i64_type });
    const attr2 = try ctx.getTypeListAttr(&.{ i32_type, i64_type });
    const attr3 = try ctx.getTypeListAttr(&.{i64_type});

    try testing.expectEqualStrings(attribute.builtin_attr_names.type_list, attr1.abstract.name);
    try testing.expectEqual(attr1.impl, attr2.impl);
    try testing.expect(attr1.impl != attr3.impl);

    const list_attr = attr1.cast(Attribute.TypeListAttr).?;
    const values = list_attr.getValues();
    try testing.expectEqual(@as(usize, 2), values.len);
    try testing.expect(values[0].eql(i32_type));
    try testing.expect(values[1].eql(i64_type));
}

test "Context getArrayAttr creates and uniques structural attribute arrays" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const name_attr = try ctx.getStringAttr("name");
    const value_attr = try ctx.getI64Attr(7);
    const attr1 = try ctx.getArrayAttr(&.{ name_attr, value_attr });
    const attr2 = try ctx.getArrayAttr(&.{ name_attr, value_attr });
    const attr3 = try ctx.getArrayAttr(&.{ value_attr, name_attr });

    try testing.expectEqualStrings(attribute.builtin_attr_names.array, attr1.abstract.name);
    try testing.expectEqual(attr1.impl, attr2.impl);
    try testing.expect(attr1.impl != attr3.impl);

    const array_attr = attr1.cast(Attribute.ArrayAttr).?;
    const values = array_attr.getValues();
    try testing.expectEqual(@as(usize, 2), values.len);
    try testing.expect(values[0].eql(name_attr));
    try testing.expect(values[1].eql(value_attr));

    const iface = attr1.interface(interfaces.AttributeArrayInterface).?;
    try testing.expectEqual(@as(usize, 2), iface.call(.getCount, .{}));
    try testing.expect((iface.call(.getElement, .{0}) orelse return error.TestExpectedAttribute).eql(name_attr));
    try testing.expect((iface.call(.getElement, .{1}) orelse return error.TestExpectedAttribute).eql(value_attr));
    try testing.expect(iface.call(.getElement, .{2}) == null);
}

test "attribute interning rolls back retained payloads on named table exhaustion" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Context, "choir_context_attribute_exhaustion"),
        );
    }

    const testing = std.testing;
    const Context = @import("root.zig").Context;
    const values = &.{ "first", "second", "third" };
    const Helpers = struct {
        fn prepare(ctx: *Context) !void {
            const iface = interfaces.AttributeEqualInterface.entry(
                &attribute.string_list_attr_eql_vtable,
            );
            _ = try ctx.registerAttributeType(
                attribute.builtin_attr_names.string_list,
                &.{iface},
            );
        }
    };

    var table_frontier: usize = undefined;
    var table_delta: usize = undefined;
    {
        var probe = try Context.init(testing.allocator, Context.Limits.testing);
        defer probe.deinit(testing.allocator);
        try Helpers.prepare(&probe);
        table_frontier = probe.capacityUsage().attribute_tables.frontier_bytes;
        _ = try probe.getStringListAttr(values);
        table_delta = probe.capacityUsage().attribute_tables.frontier_bytes - table_frontier;
        try testing.expect(table_delta > 0);
    }

    var limits = Context.Limits.testing;
    limits.attributes.table_bytes = table_frontier + table_delta - 1;
    var context = try Context.init(testing.allocator, limits);
    defer context.deinit(testing.allocator);
    try Helpers.prepare(&context);
    try testing.expectEqual(
        table_frontier,
        context.capacityUsage().attribute_tables.frontier_bytes,
    );
    context.activate();

    const payload_frontier = context.capacityUsage().attribute_payloads.frontier_bytes;
    try testing.expectError(error.OutOfMemory, context.getStringListAttr(values));
    try testing.expectEqual(
        payload_frontier,
        context.capacityUsage().attribute_payloads.frontier_bytes,
    );
    try testing.expect(context.attr_interner.storage.string_list_attrs.get(.{
        .values = values,
    }) == null);
    try testing.expectEqual(
        Context.Segment.attribute_tables,
        context.exhaustedSegment().?,
    );
}

test "Typed attribute equality via interface" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);
    try ctx.allowUnregistered();

    const int1 = try ctx.getI64Attr(42);
    const int2 = try ctx.getI64Attr(42);
    const int3 = try ctx.getI64Attr(100);
    try testing.expect(int1.eql(int2));
    try testing.expect(!int1.eql(int3));

    const f1 = try ctx.getF64Attr(3.14);
    const f2 = try ctx.getF64Attr(3.14);
    const f3 = try ctx.getF64Attr(2.71);
    try testing.expect(f1.eql(f2));
    try testing.expect(!f1.eql(f3));

    const b1 = try ctx.getBoolAttr(true);
    const b2 = try ctx.getBoolAttr(true);
    const b3 = try ctx.getBoolAttr(false);
    try testing.expect(b1.eql(b2));
    try testing.expect(!b1.eql(b3));

    const s1 = try ctx.getStringAttr("hello");
    const s2 = try ctx.getStringAttr("hello");
    const s3 = try ctx.getStringAttr("world");
    try testing.expect(s1.eql(s2));
    try testing.expect(!s1.eql(s3));

    const sl1 = try ctx.getStringListAttr(&.{ "ctx", "value", "result" });
    const sl2 = try ctx.getStringListAttr(&.{ "ctx", "value", "result" });
    const sl3 = try ctx.getStringListAttr(&.{ "ctx", "result" });
    try testing.expect(sl1.eql(sl2));
    try testing.expect(!sl1.eql(sl3));

    const i32_type = try ctx.getDialectTypeFromName("arith.i32");
    const i64_type = try ctx.getDialectTypeFromName("arith.i64");
    const tl1 = try ctx.getTypeListAttr(&.{ i32_type, i64_type });
    const tl2 = try ctx.getTypeListAttr(&.{ i32_type, i64_type });
    const tl3 = try ctx.getTypeListAttr(&.{i64_type});
    try testing.expect(tl1.eql(tl2));
    try testing.expect(!tl1.eql(tl3));
}

test "Context getFloatAttr uniquing handles NaN correctly" {
    const testing = std.testing;
    const Context = @import("root.zig").Context;
    var ctx = try Context.init(testing.allocator, Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    const nan = std.math.nan(f64);

    const nan1 = try ctx.getF64Attr(nan);
    const nan2 = try ctx.getF64Attr(nan);

    try testing.expectEqual(nan1.impl, nan2.impl);

    const float_attr = nan1.cast(Attribute.FloatAttr).?;
    try testing.expect(std.math.isNan(float_attr.getValue()));
}
