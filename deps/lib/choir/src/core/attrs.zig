const std = @import("std");
const attribute = @import("attribute.zig");
const Attribute = attribute.Attribute;
const Type = @import("type.zig").Type;
const interfaces = @import("interfaces/root.zig");

const default_hash_load = std.hash_map.default_max_load_percentage;

fn hashUpdateU64(hasher: *std.hash.Wyhash, value: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    hasher.update(&buf);
}

pub const DialectAttrKey = struct {
    attr_id: u32,
    payload: []const u8,
};

const DialectAttrKeyContext = struct {
    pub fn hash(_: DialectAttrKeyContext, key: DialectAttrKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hashUpdateU64(&hasher, key.attr_id);
        hasher.update(key.payload);
        return hasher.final();
    }

    pub fn eql(_: DialectAttrKeyContext, a: DialectAttrKey, b: DialectAttrKey) bool {
        return a.attr_id == b.attr_id and std.mem.eql(u8, a.payload, b.payload);
    }
};

pub const IntegerAttrKey = struct {
    value: i64,
    width: u8,
    is_signed: bool,
};

const IntegerAttrKeyContext = struct {
    pub fn hash(_: IntegerAttrKeyContext, key: IntegerAttrKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hashUpdateU64(&hasher, @bitCast(key.value));
        hasher.update(&[_]u8{key.width});
        hasher.update(&[_]u8{if (key.is_signed) 1 else 0});
        return hasher.final();
    }

    pub fn eql(_: IntegerAttrKeyContext, a: IntegerAttrKey, b: IntegerAttrKey) bool {
        return a.value == b.value and a.width == b.width and a.is_signed == b.is_signed;
    }
};

pub const FloatAttrKey = struct {
    value_bits: u64,
    width: u8,
};

const FloatAttrKeyContext = struct {
    pub fn hash(_: FloatAttrKeyContext, key: FloatAttrKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hashUpdateU64(&hasher, key.value_bits);
        hasher.update(&[_]u8{key.width});
        return hasher.final();
    }

    pub fn eql(_: FloatAttrKeyContext, a: FloatAttrKey, b: FloatAttrKey) bool {
        return a.value_bits == b.value_bits and a.width == b.width;
    }
};

pub const StringAttrKey = struct {
    value: []const u8,
};

const StringAttrKeyContext = struct {
    pub fn hash(_: StringAttrKeyContext, key: StringAttrKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.value);
        return hasher.final();
    }

    pub fn eql(_: StringAttrKeyContext, a: StringAttrKey, b: StringAttrKey) bool {
        return std.mem.eql(u8, a.value, b.value);
    }
};

pub const SymbolRefAttrKey = struct {
    root_reference: []const u8,
    nested_references: []const []const u8,
};

const SymbolRefAttrKeyContext = struct {
    pub fn hash(_: SymbolRefAttrKeyContext, key: SymbolRefAttrKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hashUpdateU64(&hasher, @intCast(key.root_reference.len));
        hasher.update(key.root_reference);
        hashUpdateU64(&hasher, @intCast(key.nested_references.len));
        for (key.nested_references) |nested| {
            hashUpdateU64(&hasher, @intCast(nested.len));
            hasher.update(nested);
        }
        return hasher.final();
    }

    pub fn eql(_: SymbolRefAttrKeyContext, a: SymbolRefAttrKey, b: SymbolRefAttrKey) bool {
        if (!std.mem.eql(u8, a.root_reference, b.root_reference)) return false;
        if (a.nested_references.len != b.nested_references.len) return false;
        for (a.nested_references, b.nested_references) |lhs, rhs| {
            if (!std.mem.eql(u8, lhs, rhs)) return false;
        }
        return true;
    }
};

pub const StringListAttrKey = struct {
    values: []const []const u8,
};

const StringListAttrKeyContext = struct {
    pub fn hash(_: StringListAttrKeyContext, key: StringListAttrKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (key.values) |value| {
            hashUpdateU64(&hasher, @intCast(value.len));
            hasher.update(value);
        }
        return hasher.final();
    }

    pub fn eql(_: StringListAttrKeyContext, a: StringListAttrKey, b: StringListAttrKey) bool {
        if (a.values.len != b.values.len) return false;
        for (a.values, b.values) |lhs, rhs| {
            if (!std.mem.eql(u8, lhs, rhs)) return false;
        }
        return true;
    }
};

pub const TypeListAttrKey = struct {
    values: []const Type,
};

const TypeListAttrKeyContext = struct {
    pub fn hash(_: TypeListAttrKeyContext, key: TypeListAttrKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (key.values) |typ| {
            hashUpdateU64(&hasher, typ.uniqueId());
        }
        return hasher.final();
    }

    pub fn eql(_: TypeListAttrKeyContext, a: TypeListAttrKey, b: TypeListAttrKey) bool {
        if (a.values.len != b.values.len) return false;
        for (a.values, b.values) |lhs, rhs| {
            if (!lhs.eql(rhs)) return false;
        }
        return true;
    }
};

pub const ArrayAttrKey = struct {
    values: []const Attribute,
};

const ArrayAttrKeyContext = struct {
    pub fn hash(_: ArrayAttrKeyContext, key: ArrayAttrKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hashUpdateU64(&hasher, @intCast(key.values.len));
        for (key.values) |attr| {
            hashUpdateU64(&hasher, @backingInt(attr.attr_id));
        }
        return hasher.final();
    }

    pub fn eql(_: ArrayAttrKeyContext, a: ArrayAttrKey, b: ArrayAttrKey) bool {
        if (a.values.len != b.values.len) return false;
        for (a.values, b.values) |lhs, rhs| {
            if (!lhs.eql(rhs)) return false;
        }
        return true;
    }
};

pub const AttrStorage = struct {
    dialect_attrs: DialectAttrMap,
    integer_attrs: IntegerAttrMap,
    float_attrs: FloatAttrMap,
    bool_attrs: BoolAttrMap,
    string_attrs: StringAttrMap,
    symbol_ref_attrs: SymbolRefAttrMap,
    string_list_attrs: StringListAttrMap,
    type_list_attrs: TypeListAttrMap,
    array_attrs: ArrayAttrMap,

    const DialectAttrMap: type = std.HashMap(DialectAttrKey, Attribute, DialectAttrKeyContext, default_hash_load);
    const IntegerAttrMap: type = std.HashMap(IntegerAttrKey, Attribute, IntegerAttrKeyContext, default_hash_load);
    const FloatAttrMap: type = std.HashMap(FloatAttrKey, Attribute, FloatAttrKeyContext, default_hash_load);
    const BoolAttrMap: type = std.AutoHashMap(bool, Attribute);
    const StringAttrMap: type = std.HashMap(StringAttrKey, Attribute, StringAttrKeyContext, default_hash_load);
    const SymbolRefAttrMap: type = std.HashMap(SymbolRefAttrKey, Attribute, SymbolRefAttrKeyContext, default_hash_load);
    const StringListAttrMap: type = std.HashMap(StringListAttrKey, Attribute, StringListAttrKeyContext, default_hash_load);
    const TypeListAttrMap: type = std.HashMap(TypeListAttrKey, Attribute, TypeListAttrKeyContext, default_hash_load);
    const ArrayAttrMap: type = std.HashMap(ArrayAttrKey, Attribute, ArrayAttrKeyContext, default_hash_load);

    pub fn init(allocator: std.mem.Allocator) AttrStorage {
        return .{
            .dialect_attrs = DialectAttrMap.init(allocator),
            .integer_attrs = IntegerAttrMap.init(allocator),
            .float_attrs = FloatAttrMap.init(allocator),
            .bool_attrs = BoolAttrMap.init(allocator),
            .string_attrs = StringAttrMap.init(allocator),
            .symbol_ref_attrs = SymbolRefAttrMap.init(allocator),
            .string_list_attrs = StringListAttrMap.init(allocator),
            .type_list_attrs = TypeListAttrMap.init(allocator),
            .array_attrs = ArrayAttrMap.init(allocator),
        };
    }

    pub fn deinit(self: *AttrStorage, payload_allocator: std.mem.Allocator) void {
        var dialect_iter = self.dialect_attrs.valueIterator();
        while (dialect_iter.next()) |attr| {
            const impl: *Attribute.DialectAttr = @ptrCast(@alignCast(@constCast(attr.impl)));
            payload_allocator.free(impl.payload);
            payload_allocator.destroy(impl);
        }
        self.dialect_attrs.deinit();

        var int_iter = self.integer_attrs.valueIterator();
        while (int_iter.next()) |attr| {
            const impl: *Attribute.IntegerAttr = @ptrCast(@alignCast(@constCast(attr.impl)));
            payload_allocator.destroy(impl);
        }
        self.integer_attrs.deinit();

        var float_iter = self.float_attrs.valueIterator();
        while (float_iter.next()) |attr| {
            const impl: *Attribute.FloatAttr = @ptrCast(@alignCast(@constCast(attr.impl)));
            payload_allocator.destroy(impl);
        }
        self.float_attrs.deinit();

        var bool_iter = self.bool_attrs.valueIterator();
        while (bool_iter.next()) |attr| {
            const impl: *Attribute.BoolAttr = @ptrCast(@alignCast(@constCast(attr.impl)));
            payload_allocator.destroy(impl);
        }
        self.bool_attrs.deinit();

        var string_iter = self.string_attrs.valueIterator();
        while (string_iter.next()) |attr| {
            const impl: *Attribute.StringAttr = @ptrCast(@alignCast(@constCast(attr.impl)));
            payload_allocator.free(impl.value);
            payload_allocator.destroy(impl);
        }
        self.string_attrs.deinit();

        var symbol_ref_iter = self.symbol_ref_attrs.valueIterator();
        while (symbol_ref_iter.next()) |attr| {
            const impl: *Attribute.SymbolRefAttr = @ptrCast(@alignCast(@constCast(attr.impl)));
            payload_allocator.free(impl.root_reference);
            for (impl.nested_references) |nested| {
                payload_allocator.free(nested);
            }
            if (impl.nested_references.len > 0) payload_allocator.free(impl.nested_references);
            payload_allocator.destroy(impl);
        }
        self.symbol_ref_attrs.deinit();

        var string_list_iter = self.string_list_attrs.valueIterator();
        while (string_list_iter.next()) |attr| {
            const impl: *Attribute.StringListAttr = @ptrCast(@alignCast(@constCast(attr.impl)));
            for (impl.values) |value| {
                payload_allocator.free(value);
            }
            if (impl.values.len > 0) payload_allocator.free(impl.values);
            payload_allocator.destroy(impl);
        }
        self.string_list_attrs.deinit();

        var type_list_iter = self.type_list_attrs.valueIterator();
        while (type_list_iter.next()) |attr| {
            const impl: *Attribute.TypeListAttr = @ptrCast(@alignCast(@constCast(attr.impl)));
            if (impl.values.len > 0) payload_allocator.free(impl.values);
            payload_allocator.destroy(impl);
        }
        self.type_list_attrs.deinit();

        var array_iter = self.array_attrs.valueIterator();
        while (array_iter.next()) |attr| {
            const impl: *Attribute.ArrayAttr = @ptrCast(@alignCast(@constCast(attr.impl)));
            if (impl.values.len > 0) payload_allocator.free(impl.values);
            payload_allocator.destroy(impl);
        }
        self.array_attrs.deinit();
    }
};

pub const AttributeInterner = struct {
    storage: AttrStorage,
    registry: interfaces.AttributeRegistry,

    pub fn init(
        table_allocator: std.mem.Allocator,
        registry_allocator: std.mem.Allocator,
    ) AttributeInterner {
        return .{
            .storage = AttrStorage.init(table_allocator),
            .registry = interfaces.AttributeRegistry.init(registry_allocator, attribute.Attribute.first_dynamic_attr_id),
        };
    }

    pub fn deinit(self: *AttributeInterner, payload_allocator: std.mem.Allocator) void {
        self.storage.deinit(payload_allocator);
        self.registry.deinit();
    }
};
