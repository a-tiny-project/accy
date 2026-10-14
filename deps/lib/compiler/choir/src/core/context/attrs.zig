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
        // The lookup above found no such kind, so this registration cannot meet a duplicate.
        _ = registerAttributeType(ctx, attr_name, &.{}) catch |err| switch (err) {
            error.DuplicateAttribute => unreachable,
            else => |other| return other,
        };
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
