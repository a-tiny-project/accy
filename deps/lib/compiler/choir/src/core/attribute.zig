const std = @import("std");
const interfaces = @import("interfaces/root.zig");
const Type = @import("type.zig").Type;

pub const Attribute = struct {
    attr_id: AttrID,

    impl: *const anyopaque,

    abstract: *const interfaces.AbstractAttribute,

    pub const AttrID = enum(u32) {
        invalid = 0,
        _,
    };

    pub const first_dynamic_attr_id: u32 = @backingInt(AttrID.invalid) + 1;

    pub const DialectAttr = struct {
        payload: []const u8,
        context: *const anyopaque,
    };

    pub const IntegerAttr = struct {
        value: i64,
        width: u8,
        is_signed: bool,
        context: *const anyopaque,

        pub fn getValue(self: *const IntegerAttr) i64 {
            return self.value;
        }

        pub fn getUnsignedValue(self: *const IntegerAttr) u64 {
            return @bitCast(self.value);
        }
    };

    pub const FloatAttr = struct {
        value: f64,
        width: u8,
        context: *const anyopaque,

        pub fn getValue(self: *const FloatAttr) f64 {
            return self.value;
        }

        pub fn getF32Value(self: *const FloatAttr) f32 {
            return @floatCast(self.value);
        }
    };

    pub const BoolAttr = struct {
        value: bool,
        context: *const anyopaque,

        pub fn getValue(self: *const BoolAttr) bool {
            return self.value;
        }
    };

    pub const StringAttr = struct {
        value: []const u8,
        context: *const anyopaque,

        pub fn getValue(self: *const StringAttr) []const u8 {
            return self.value;
        }
    };

    pub const SymbolRefAttr = struct {
        root_reference: []const u8,
        nested_references: []const []const u8,
        context: *const anyopaque,

        pub fn getRootReference(self: *const SymbolRefAttr) []const u8 {
            return self.root_reference;
        }

        pub fn getNestedReferences(self: *const SymbolRefAttr) []const []const u8 {
            return self.nested_references;
        }

        pub fn getLeafReference(self: *const SymbolRefAttr) []const u8 {
            if (self.nested_references.len == 0) return self.root_reference;
            return self.nested_references[self.nested_references.len - 1];
        }

        pub fn isFlat(self: *const SymbolRefAttr) bool {
            return self.nested_references.len == 0;
        }
    };

    pub const StringListAttr = struct {
        values: []const []const u8,
        context: *const anyopaque,

        pub fn getValues(self: *const StringListAttr) []const []const u8 {
            return self.values;
        }
    };

    pub const TypeListAttr = struct {
        values: []const Type,
        context: *const anyopaque,

        pub fn getValues(self: *const TypeListAttr) []const Type {
            return self.values;
        }
    };

    pub const ArrayAttr = struct {
        values: []const Attribute,
        context: *const anyopaque,

        pub fn getValues(self: *const ArrayAttr) []const Attribute {
            return self.values;
        }
    };

    pub fn attrIdFromInt(id: u32) AttrID {
        return @fromBackingInt(@intCast(id));
    }

    pub fn isa(self: Attribute, comptime attr_id: AttrID) bool {
        return self.attr_id == attr_id;
    }

    pub fn eql(self: Attribute, other: Attribute) bool {
        if (self.attr_id != other.attr_id) return false;
        if (self.impl == other.impl) return true;
        if (self.getInterface(interfaces.AttributeEqualInterface)) |vtable| {
            return vtable.eql(self.impl, other.impl);
        }
        return false;
    }

    pub fn getInterface(self: Attribute, comptime IFace: type) ?*const IFace.VTable {
        if (self.abstract.getInterface(IFace.id)) |iface| {
            return @ptrCast(@alignCast(iface));
        }
        return null;
    }

    pub fn InterfaceHandle(comptime IFace: type) type {
        return struct {
            attr: Attribute,
            vtable: *const IFace.VTable,

            fn returnType(comptime fn_ptr_type: type) type {
                const ptr_info = @typeInfo(fn_ptr_type);
                const fn_type = switch (ptr_info) {
                    .pointer => |p| p.child,
                    else => @compileError("expected interface vtable field to be a function pointer"),
                };
                const fn_info = switch (@typeInfo(fn_type)) {
                    .@"fn" => |f| f,
                    else => @compileError("expected interface vtable field to be a function pointer"),
                };
                return fn_info.return_type orelse @compileError("generic interface vtable methods are not supported");
            }

            fn methodFnPtrType(comptime method: std.meta.FieldEnum(IFace.VTable)) type {
                const dummy: IFace.VTable = undefined;
                return @TypeOf(@field(dummy, @tagName(method)));
            }

            pub inline fn call(
                self: @This(),
                comptime method: std.meta.FieldEnum(IFace.VTable),
                args: anytype,
            ) returnType(methodFnPtrType(method)) {
                const fn_ptr = @field(self.vtable, @tagName(method));
                return @call(.auto, fn_ptr, .{self.attr.impl} ++ args);
            }
        };
    }

    pub fn interface(self: Attribute, comptime IFace: type) ?InterfaceHandle(IFace) {
        const vtable = self.getInterface(IFace) orelse return null;
        return .{ .attr = self, .vtable = vtable };
    }

    pub fn getAbstractAttribute(self: Attribute) *const interfaces.AbstractAttribute {
        return self.abstract;
    }

    pub fn hasStorageType(self: Attribute, comptime T: type) bool {
        return storageTypeMatchesName(T, self.abstract.name);
    }

    pub fn cast(self: Attribute, comptime T: type) ?*const T {
        if (!self.hasStorageType(T)) return null;
        return @ptrCast(@alignCast(self.impl));
    }

    pub fn format(self: Attribute, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.getInterface(interfaces.AttributePrintInterface)) |vtable| {
            return vtable.print(self.impl, writer);
        }

        if (self.abstract.name.len > 0) {
            try writer.print("#attr<{s}>", .{self.abstract.name});
        } else {
            try writer.print("#attr<{d}>", .{@backingInt(self.attr_id)});
        }
    }
};

pub const NamedAttribute = struct {
    name: []const u8,
    value: Attribute,

    pub fn format(self: NamedAttribute, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s} = {f}", .{ self.name, self.value });
    }
};

pub const NamedAttributeList = struct {
    const small_capacity = 4;

    len: usize = 0,
    owned_items: []NamedAttribute = &.{},
    small_items: [small_capacity]NamedAttribute = undefined,

    pub const Lookup = struct {
        found: bool,
        index: usize,
    };

    pub fn items(self: *const NamedAttributeList) []const NamedAttribute {
        if (self.owned_items.len != 0) return self.owned_items[0..self.len];
        return self.small_items[0..self.len];
    }

    pub fn capacity(self: *const NamedAttributeList) usize {
        if (self.owned_items.len != 0) return self.owned_items.len;
        return small_capacity;
    }

    fn storage(self: *NamedAttributeList) []NamedAttribute {
        if (self.owned_items.len != 0) return self.owned_items;
        return self.small_items[0..];
    }

    pub fn deinit(self: *NamedAttributeList, allocator: std.mem.Allocator) void {
        if (self.owned_items.len != 0) allocator.free(self.owned_items);
        self.len = 0;
        self.owned_items = &.{};
    }

    pub fn clearRetainingCapacity(self: *NamedAttributeList) void {
        self.len = 0;
    }

    pub fn ensureTotalCapacity(
        self: *NamedAttributeList,
        allocator: std.mem.Allocator,
        target_capacity: usize,
    ) std.mem.Allocator.Error!void {
        if (target_capacity <= self.capacity()) return;
        if (self.owned_items.len != 0) {
            self.owned_items = try allocator.realloc(self.owned_items, target_capacity);
            return;
        }
        const allocated_items = try allocator.alloc(NamedAttribute, target_capacity);
        @memcpy(allocated_items[0..self.len], self.small_items[0..self.len]);
        self.owned_items = allocated_items;
    }

    pub fn get(self: *const NamedAttributeList, name: []const u8) ?Attribute {
        const result = self.findIndexOrInsertPos(name);
        if (!result.found) return null;
        return self.items()[result.index].value;
    }

    pub fn getNamed(self: *const NamedAttributeList, name: []const u8) ?NamedAttribute {
        const result = self.findIndexOrInsertPos(name);
        if (!result.found) return null;
        return self.items()[result.index];
    }

    pub fn set(
        self: *NamedAttributeList,
        allocator: std.mem.Allocator,
        attr_name: []const u8,
        value: Attribute,
    ) !?Attribute {
        const result = self.findIndexOrInsertPos(attr_name);
        if (result.found) {
            const storage_items = self.storage();
            const previous = storage_items[result.index].value;
            storage_items[result.index].value = value;
            return previous;
        }
        const required_capacity = std.math.add(usize, self.len, 1) catch
            return error.OutOfMemory;
        if (required_capacity > self.capacity()) {
            try self.ensureTotalCapacity(
                allocator,
                @max(required_capacity, self.capacity() *| 2),
            );
        }
        const storage_items = self.storage();
        std.mem.copyBackwards(NamedAttribute, storage_items[result.index + 1 .. self.len + 1], storage_items[result.index..self.len]);
        storage_items[result.index] = .{ .name = attr_name, .value = value };
        self.len += 1;
        return null;
    }

    pub fn erase(self: *NamedAttributeList, attr_name: []const u8) ?Attribute {
        const result = self.findIndexOrInsertPos(attr_name);
        if (!result.found) return null;
        const storage_items = self.storage();
        const previous = storage_items[result.index].value;
        std.mem.copyForwards(NamedAttribute, storage_items[result.index .. self.len - 1], storage_items[result.index + 1 .. self.len]);
        self.len -= 1;
        return previous;
    }

    pub fn findIndexOrInsertPos(self: *const NamedAttributeList, name: []const u8) Lookup {
        var left: usize = 0;
        const current_items = self.items();
        var right: usize = current_items.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            const cmp = std.mem.order(u8, current_items[mid].name, name);
            switch (cmp) {
                .eq => return .{ .found = true, .index = mid },
                .lt => left = mid + 1,
                .gt => right = mid,
            }
        }
        return .{ .found = false, .index = left };
    }
};

pub const builtin_attr_names = struct {
    pub const integer = "builtin.integer";
    pub const float_ = "builtin.float";
    pub const bool_ = "builtin.bool";
    pub const string = "builtin.string";
    pub const symbol_ref = "builtin.symbol_ref";
    pub const string_list = "builtin.string_list";
    pub const type_list = "builtin.type_list";
    pub const array = "builtin.array";
};

const builtin_attr_name_values = [_][]const u8{
    builtin_attr_names.integer,
    builtin_attr_names.float_,
    builtin_attr_names.bool_,
    builtin_attr_names.string,
    builtin_attr_names.symbol_ref,
    builtin_attr_names.string_list,
    builtin_attr_names.type_list,
    builtin_attr_names.array,
};

pub fn isBuiltinAttributeName(name: []const u8) bool {
    inline for (builtin_attr_name_values) |builtin_name| {
        if (std.mem.eql(u8, name, builtin_name)) return true;
    }
    return false;
}

fn storageTypeMatchesName(comptime T: type, name: []const u8) bool {
    if (T == Attribute.DialectAttr) {
        return name.len > 0 and !isBuiltinAttributeName(name);
    }
    if (T == Attribute.IntegerAttr) return std.mem.eql(u8, name, builtin_attr_names.integer);
    if (T == Attribute.FloatAttr) return std.mem.eql(u8, name, builtin_attr_names.float_);
    if (T == Attribute.BoolAttr) return std.mem.eql(u8, name, builtin_attr_names.bool_);
    if (T == Attribute.StringAttr) return std.mem.eql(u8, name, builtin_attr_names.string);
    if (T == Attribute.SymbolRefAttr) return std.mem.eql(u8, name, builtin_attr_names.symbol_ref);
    if (T == Attribute.StringListAttr) return std.mem.eql(u8, name, builtin_attr_names.string_list);
    if (T == Attribute.TypeListAttr) return std.mem.eql(u8, name, builtin_attr_names.type_list);
    if (T == Attribute.ArrayAttr) return std.mem.eql(u8, name, builtin_attr_names.array);
    @compileError("unsupported attribute storage type: " ++ @typeName(T));
}

const EqlVTable = interfaces.AttributeEqualInterface.VTable;

fn dialect_attr_eql(self_impl: *const anyopaque, other_impl: *const anyopaque) bool {
    const a: *const Attribute.DialectAttr = @ptrCast(@alignCast(self_impl));
    const b: *const Attribute.DialectAttr = @ptrCast(@alignCast(other_impl));
    return std.mem.eql(u8, a.payload, b.payload);
}

fn integer_attr_eql(self_impl: *const anyopaque, other_impl: *const anyopaque) bool {
    const a: *const Attribute.IntegerAttr = @ptrCast(@alignCast(self_impl));
    const b: *const Attribute.IntegerAttr = @ptrCast(@alignCast(other_impl));
    return a.value == b.value and a.width == b.width and a.is_signed == b.is_signed;
}

fn float_attr_eql(self_impl: *const anyopaque, other_impl: *const anyopaque) bool {
    const a: *const Attribute.FloatAttr = @ptrCast(@alignCast(self_impl));
    const b: *const Attribute.FloatAttr = @ptrCast(@alignCast(other_impl));
    return @as(u64, @bitCast(a.value)) == @as(u64, @bitCast(b.value)) and a.width == b.width;
}

fn bool_attr_eql(self_impl: *const anyopaque, other_impl: *const anyopaque) bool {
    const a: *const Attribute.BoolAttr = @ptrCast(@alignCast(self_impl));
    const b: *const Attribute.BoolAttr = @ptrCast(@alignCast(other_impl));
    return a.value == b.value;
}

fn string_attr_eql(self_impl: *const anyopaque, other_impl: *const anyopaque) bool {
    const a: *const Attribute.StringAttr = @ptrCast(@alignCast(self_impl));
    const b: *const Attribute.StringAttr = @ptrCast(@alignCast(other_impl));
    return std.mem.eql(u8, a.value, b.value);
}

fn symbol_ref_attr_eql(self_impl: *const anyopaque, other_impl: *const anyopaque) bool {
    const a: *const Attribute.SymbolRefAttr = @ptrCast(@alignCast(self_impl));
    const b: *const Attribute.SymbolRefAttr = @ptrCast(@alignCast(other_impl));
    if (!std.mem.eql(u8, a.root_reference, b.root_reference)) return false;
    if (a.nested_references.len != b.nested_references.len) return false;
    for (a.nested_references, b.nested_references) |lhs, rhs| {
        if (!std.mem.eql(u8, lhs, rhs)) return false;
    }
    return true;
}

fn write_symbol_ref_attr(
    self_impl: *const anyopaque,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const attr: *const Attribute.SymbolRefAttr = @ptrCast(@alignCast(self_impl));
    try writer.print("@{s}", .{attr.root_reference});
    for (attr.nested_references) |nested| {
        try writer.print("::@{s}", .{nested});
    }
}

fn string_list_attr_eql(self_impl: *const anyopaque, other_impl: *const anyopaque) bool {
    const a: *const Attribute.StringListAttr = @ptrCast(@alignCast(self_impl));
    const b: *const Attribute.StringListAttr = @ptrCast(@alignCast(other_impl));
    if (a.values.len != b.values.len) return false;
    for (a.values, b.values) |lhs, rhs| {
        if (!std.mem.eql(u8, lhs, rhs)) return false;
    }
    return true;
}

fn type_list_attr_eql(self_impl: *const anyopaque, other_impl: *const anyopaque) bool {
    const a: *const Attribute.TypeListAttr = @ptrCast(@alignCast(self_impl));
    const b: *const Attribute.TypeListAttr = @ptrCast(@alignCast(other_impl));
    if (a.values.len != b.values.len) return false;
    for (a.values, b.values) |lhs, rhs| {
        if (!lhs.eql(rhs)) return false;
    }
    return true;
}

fn array_attr_eql(self_impl: *const anyopaque, other_impl: *const anyopaque) bool {
    const a: *const Attribute.ArrayAttr = @ptrCast(@alignCast(self_impl));
    const b: *const Attribute.ArrayAttr = @ptrCast(@alignCast(other_impl));
    if (a.values.len != b.values.len) return false;
    for (a.values, b.values) |lhs, rhs| {
        if (!lhs.eql(rhs)) return false;
    }
    return true;
}

fn array_attr_count(attr_ptr: *const anyopaque) usize {
    const attr: *const Attribute.ArrayAttr = @ptrCast(@alignCast(attr_ptr));
    return attr.values.len;
}

fn array_attr_element(attr_ptr: *const anyopaque, index: usize) ?Attribute {
    const attr: *const Attribute.ArrayAttr = @ptrCast(@alignCast(attr_ptr));
    if (index >= attr.values.len) return null;
    return attr.values[index];
}

pub const dialect_attr_eql_vtable = EqlVTable{
    .eql = dialect_attr_eql,
};

pub const integer_attr_eql_vtable = EqlVTable{
    .eql = integer_attr_eql,
};

pub const float_attr_eql_vtable = EqlVTable{
    .eql = float_attr_eql,
};

pub const bool_attr_eql_vtable = EqlVTable{
    .eql = bool_attr_eql,
};

pub const string_attr_eql_vtable = EqlVTable{
    .eql = string_attr_eql,
};

pub const symbol_ref_attr_eql_vtable = EqlVTable{
    .eql = symbol_ref_attr_eql,
};

pub const symbol_ref_attr_print_vtable = interfaces.AttributePrintInterface.VTable{
    .print = write_symbol_ref_attr,
};

pub const string_list_attr_eql_vtable = EqlVTable{
    .eql = string_list_attr_eql,
};

pub const type_list_attr_eql_vtable = EqlVTable{
    .eql = type_list_attr_eql,
};

pub const array_attr_eql_vtable = EqlVTable{
    .eql = array_attr_eql,
};

pub const array_attr_array_vtable = interfaces.AttributeArrayInterface.VTable{
    .getCount = array_attr_count,
    .getElement = array_attr_element,
};

pub const default_abstract = interfaces.AbstractAttribute{
    .attr_id = 0,
    .name = "",
    .interfaces = &.{},
};
