const std = @import("std");
const ir = @import("../core/root.zig");

pub const ClassId = struct {
    index: u32,

    pub fn eql(self: ClassId, other: ClassId) bool {
        return self.index == other.index;
    }
};

fn class_id_less_than(_: void, lhs: ClassId, rhs: ClassId) bool {
    return lhs.index < rhs.index;
}

pub const ValueEntry = struct {
    value: *ir.Value,
    cost: u32,
    order: usize,
};

pub const NodeKind = enum {
    value,
    operation,
};

pub const Node = struct {
    kind: NodeKind,
    value: ?*ir.Value = null,
    op_name: []const u8 = "",
    operands: []ClassId = &.{},
    result_types: []ir.Type = &.{},
    attributes: []ir.NamedAttribute = &.{},
    raw_attributes: []ir.NamedAttribute = &.{},
    properties: ?ir.Attribute = null,
    commutative: bool = false,

    pub fn valueNode(value: *ir.Value) Node {
        return .{ .kind = .value, .value = value };
    }

    pub fn operationNode(
        allocator: std.mem.Allocator,
        op: *ir.Operation,
        operands: []const ClassId,
        commutative: bool,
    ) !Node {
        const owned_operands = try allocator.alloc(ClassId, operands.len);
        errdefer allocator.free(owned_operands);
        @memcpy(owned_operands, operands);

        const result_types = op.getResultTypes();
        const owned_result_types = try allocator.alloc(ir.Type, result_types.len);
        errdefer allocator.free(owned_result_types);
        @memcpy(owned_result_types, result_types);

        const owned_attributes = try allocator.alloc(ir.NamedAttribute, op.getNumAttrs());
        errdefer allocator.free(owned_attributes);
        var attributes = op.getAttrs();
        var attribute_index: usize = 0;
        while (attributes.next()) |attr| : (attribute_index += 1) {
            if (attribute_index >= owned_attributes.len) {
                return error.OperationAttributesChanged;
            }
            owned_attributes[attribute_index] = attr;
        }
        if (attribute_index != owned_attributes.len) return error.OperationAttributesChanged;

        const properties = try op.getPropertiesAsAttr();
        const raw_attributes = op.getRawDictionaryAttrs();
        const owned_raw_attributes = if (namedAttributesEqual(owned_attributes, raw_attributes))
            owned_attributes
        else blk: {
            const owned = try allocator.alloc(ir.NamedAttribute, raw_attributes.len);
            @memcpy(owned, raw_attributes);
            break :blk owned;
        };
        errdefer if (owned_raw_attributes.ptr != owned_attributes.ptr) {
            allocator.free(owned_raw_attributes);
        };

        var node = Node{
            .kind = .operation,
            .op_name = op.name.name,
            .operands = owned_operands,
            .result_types = owned_result_types,
            .attributes = owned_attributes,
            .raw_attributes = owned_raw_attributes,
            .properties = properties,
            .commutative = commutative,
        };
        node.normalizeOperands();
        return node;
    }

    pub fn clone(self: Node, allocator: std.mem.Allocator) !Node {
        switch (self.kind) {
            .value => return valueNode(self.value.?),
            .operation => {
                const owned_operands = try allocator.alloc(ClassId, self.operands.len);
                errdefer allocator.free(owned_operands);
                @memcpy(owned_operands, self.operands);

                const owned_result_types = try allocator.alloc(ir.Type, self.result_types.len);
                errdefer allocator.free(owned_result_types);
                @memcpy(owned_result_types, self.result_types);

                const owned_attributes = try allocator.alloc(ir.NamedAttribute, self.attributes.len);
                errdefer allocator.free(owned_attributes);
                @memcpy(owned_attributes, self.attributes);

                const owned_raw_attributes = if (namedAttributesEqual(
                    self.attributes,
                    self.raw_attributes,
                ))
                    owned_attributes
                else blk: {
                    const owned = try allocator.alloc(
                        ir.NamedAttribute,
                        self.raw_attributes.len,
                    );
                    @memcpy(owned, self.raw_attributes);
                    break :blk owned;
                };
                errdefer if (owned_raw_attributes.ptr != owned_attributes.ptr) {
                    allocator.free(owned_raw_attributes);
                };

                return .{
                    .kind = .operation,
                    .op_name = self.op_name,
                    .operands = owned_operands,
                    .result_types = owned_result_types,
                    .attributes = owned_attributes,
                    .raw_attributes = owned_raw_attributes,
                    .properties = self.properties,
                    .commutative = self.commutative,
                };
            },
        }
    }

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .value => {},
            .operation => {
                allocator.free(self.operands);
                allocator.free(self.result_types);
                if (self.raw_attributes.ptr != self.attributes.ptr) {
                    allocator.free(self.raw_attributes);
                }
                allocator.free(self.attributes);
            },
        }
        self.* = .{ .kind = .value, .value = undefined };
    }

    pub fn getAttr(self: *const Node, name: []const u8) ?ir.Attribute {
        if (self.kind != .operation) return null;
        for (self.attributes) |attribute| {
            if (std.mem.eql(u8, attribute.name, name)) return attribute.value;
        }
        return null;
    }

    pub fn normalizeOperands(self: *Node) void {
        if (self.kind != .operation) return;
        if (!self.commutative) return;
        std.mem.sort(ClassId, self.operands, {}, class_id_less_than);
    }

    pub fn hash(self: *const Node) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const tag: u8 = @backingInt(self.kind);
        hasher.update(std.mem.asBytes(&tag));

        switch (self.kind) {
            .value => {
                const ptr = @intFromPtr(self.value.?);
                hasher.update(std.mem.asBytes(&ptr));
                const type_id = self.value.?.type.uniqueId();
                hasher.update(std.mem.asBytes(&type_id));
            },
            .operation => {
                hasher.update(self.op_name);
                hasher.update(std.mem.asBytes(&self.commutative));
                for (self.operands) |operand| {
                    hasher.update(std.mem.asBytes(&operand.index));
                }
                for (self.result_types) |result_type| {
                    const type_id = result_type.uniqueId();
                    hasher.update(std.mem.asBytes(&type_id));
                }
                for (self.attributes) |attribute| {
                    hasher.update(attribute.name);
                    hashAttribute(&hasher, attribute.value);
                }
            },
        }

        return hasher.final();
    }

    pub fn eql(self: *const Node, other: *const Node) bool {
        if (self.kind != other.kind) return false;

        switch (self.kind) {
            .value => return self.value.? == other.value.?,
            .operation => {
                if (!std.mem.eql(u8, self.op_name, other.op_name)) return false;
                if (self.commutative != other.commutative) return false;
                if (self.operands.len != other.operands.len) return false;
                if (self.result_types.len != other.result_types.len) return false;
                if (self.attributes.len != other.attributes.len) return false;

                for (self.operands, other.operands) |lhs, rhs| {
                    if (!lhs.eql(rhs)) return false;
                }
                for (self.result_types, other.result_types) |lhs, rhs| {
                    if (!lhs.eql(rhs)) return false;
                }
                for (self.attributes, other.attributes) |lhs, rhs| {
                    if (!std.mem.eql(u8, lhs.name, rhs.name)) return false;
                    if (!lhs.value.eql(rhs.value)) return false;
                }
                return true;
            },
        }
    }
};

fn namedAttributesEqual(
    lhs: []const ir.NamedAttribute,
    rhs: []const ir.NamedAttribute,
) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name)) return false;
        if (!left.value.eql(right.value)) return false;
    }
    return true;
}

fn hashAttribute(hasher: *std.hash.Wyhash, attr: ir.Attribute) void {
    hasher.update(attr.abstract.name);

    if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.integer)) {
        const value = attr.cast(ir.Attribute.IntegerAttr).?;
        hasher.update(std.mem.asBytes(&value.value));
        hasher.update(std.mem.asBytes(&value.width));
        hasher.update(std.mem.asBytes(&value.is_signed));
        return;
    }

    if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.float_)) {
        const value = attr.cast(ir.Attribute.FloatAttr).?;
        const bits: u64 = @bitCast(value.value);
        hasher.update(std.mem.asBytes(&bits));
        hasher.update(std.mem.asBytes(&value.width));
        return;
    }

    if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.bool_)) {
        const value = attr.cast(ir.Attribute.BoolAttr).?;
        hasher.update(std.mem.asBytes(&value.value));
        return;
    }

    if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.string)) {
        const value = attr.cast(ir.Attribute.StringAttr).?;
        hasher.update(value.value);
        return;
    }

    if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.symbol_ref)) {
        const value = attr.cast(ir.Attribute.SymbolRefAttr).?;
        const root_len = value.root_reference.len;
        hasher.update(std.mem.asBytes(&root_len));
        hasher.update(value.root_reference);
        const nested_count = value.nested_references.len;
        hasher.update(std.mem.asBytes(&nested_count));
        for (value.nested_references) |item| {
            const item_len = item.len;
            hasher.update(std.mem.asBytes(&item_len));
            hasher.update(item);
        }
        return;
    }

    if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.string_list)) {
        const value = attr.cast(ir.Attribute.StringListAttr).?;
        for (value.values) |item| {
            hasher.update(item);
        }
        return;
    }

    if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.type_list)) {
        const value = attr.cast(ir.Attribute.TypeListAttr).?;
        for (value.values) |item| {
            const type_id = item.uniqueId();
            hasher.update(std.mem.asBytes(&type_id));
        }
        return;
    }

    if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.array)) {
        const value = attr.cast(ir.Attribute.ArrayAttr).?;
        const count = value.values.len;
        hasher.update(std.mem.asBytes(&count));
        for (value.values) |item| {
            hashAttribute(hasher, item);
        }
        return;
    }

    if (attr.cast(ir.Attribute.DialectAttr)) |value| {
        hasher.update(value.payload);
        return;
    }

    const ptr = @intFromPtr(attr.impl);
    hasher.update(std.mem.asBytes(&ptr));
}
