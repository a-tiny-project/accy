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

test "NamedAttributeList keeps dictionary semantics" {
    const testing = std.testing;
    const TestAttr = struct {
        const abstract = interfaces.AbstractAttribute{
            .attr_id = 1,
            .name = "test.attr",
            .interfaces = &.{},
        };
        const alpha: u8 = 1;
        const beta: u8 = 2;
        const gamma: u8 = 3;

        fn value(comptime attr_id: u32, ptr: *const u8) Attribute {
            return .{
                .attr_id = Attribute.attrIdFromInt(attr_id),
                .impl = ptr,
                .abstract = &abstract,
            };
        }
    };

    const alpha = TestAttr.value(1, &TestAttr.alpha);
    const beta = TestAttr.value(2, &TestAttr.beta);
    const gamma = TestAttr.value(3, &TestAttr.gamma);

    var list = NamedAttributeList{};
    defer list.deinit(testing.allocator);

    try list.ensureTotalCapacity(testing.allocator, 8);
    try testing.expect(list.capacity() >= 8);

    try testing.expect(try list.set(testing.allocator, "gamma", gamma) == null);
    try testing.expect(try list.set(testing.allocator, "alpha", alpha) == null);
    try testing.expect(try list.set(testing.allocator, "beta", beta) == null);

    try testing.expectEqualStrings("alpha", list.items()[0].name);
    try testing.expectEqualStrings("beta", list.items()[1].name);
    try testing.expectEqualStrings("gamma", list.items()[2].name);
    try testing.expectEqual(alpha.impl, list.get("alpha").?.impl);

    const previous = (try list.set(testing.allocator, "beta", gamma)).?;
    try testing.expectEqual(beta.impl, previous.impl);
    try testing.expectEqual(gamma.impl, list.get("beta").?.impl);

    const erased = list.erase("alpha").?;
    try testing.expectEqual(alpha.impl, erased.impl);
    try testing.expect(list.erase("missing") == null);
    try testing.expect(list.get("alpha") == null);
    try testing.expectEqual(@as(usize, 2), list.items().len);
}

test "NamedAttributeList stores small dictionaries without allocation" {
    const testing = std.testing;
    const TestAttr = struct {
        const abstract = interfaces.AbstractAttribute{
            .attr_id = 1,
            .name = "test.attr",
            .interfaces = &.{},
        };
        const alpha: u8 = 1;

        fn value(ptr: *const u8) Attribute {
            return .{
                .attr_id = Attribute.attrIdFromInt(1),
                .impl = ptr,
                .abstract = &abstract,
            };
        }
    };

    const attr = TestAttr.value(&TestAttr.alpha);
    var list = NamedAttributeList{};
    defer list.deinit(testing.failing_allocator);

    try testing.expect(try list.set(testing.failing_allocator, "delta", attr) == null);
    try testing.expect(try list.set(testing.failing_allocator, "alpha", attr) == null);
    try testing.expect(try list.set(testing.failing_allocator, "gamma", attr) == null);
    try testing.expect(try list.set(testing.failing_allocator, "beta", attr) == null);

    const attrs = list.items();
    try testing.expectEqual(@as(usize, 4), attrs.len);
    try testing.expectEqualStrings("alpha", attrs[0].name);
    try testing.expectEqualStrings("beta", attrs[1].name);
    try testing.expectEqualStrings("delta", attrs[2].name);
    try testing.expectEqualStrings("gamma", attrs[3].name);

    try testing.expectError(error.OutOfMemory, list.set(testing.failing_allocator, "epsilon", attr));
    try testing.expectEqual(@as(usize, 4), list.items().len);
}

test "NamedAttributeList grows spilled dictionaries geometrically" {
    const testing = std.testing;
    const TestAttr = struct {
        const abstract = interfaces.AbstractAttribute{
            .attr_id = 1,
            .name = "test.attr",
            .interfaces = &.{},
        };
        const payload: u8 = 1;

        fn value() Attribute {
            return .{
                .attr_id = Attribute.attrIdFromInt(1),
                .impl = &payload,
                .abstract = &abstract,
            };
        }
    };

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var list = NamedAttributeList{};
    defer list.deinit(failing.allocator());

    const names = [_][]const u8{
        "alpha", "beta", "gamma", "delta", "epsilon",
        "zeta",  "eta",  "theta", "iota",
    };
    for (names[0..5]) |name| {
        try testing.expect(try list.set(failing.allocator(), name, TestAttr.value()) == null);
    }
    try testing.expectEqual(@as(usize, 8), list.capacity());

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    for (names[5..8]) |name| {
        try testing.expect(try list.set(failing.allocator(), name, TestAttr.value()) == null);
    }
    try testing.expectError(
        error.OutOfMemory,
        list.set(failing.allocator(), names[8], TestAttr.value()),
    );
    try testing.expectEqual(@as(usize, 8), list.items().len);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try testing.expect(try list.set(
        failing.allocator(),
        names[8],
        TestAttr.value(),
    ) == null);
    try testing.expectEqual(@as(usize, 16), list.capacity());
}

test "Attribute.cast checks comptime storage type" {
    const testing = std.testing;

    var context_token: u8 = 0;
    const integer_abstract = interfaces.AbstractAttribute{
        .attr_id = @backingInt(Attribute.AttrID.invalid) + 1,
        .name = builtin_attr_names.integer,
        .interfaces = &.{},
    };
    const string_abstract = interfaces.AbstractAttribute{
        .attr_id = @backingInt(Attribute.AttrID.invalid) + 2,
        .name = builtin_attr_names.string,
        .interfaces = &.{},
    };
    const dialect_abstract = interfaces.AbstractAttribute{
        .attr_id = @backingInt(Attribute.AttrID.invalid) + 3,
        .name = "test.flag",
        .interfaces = &.{},
    };

    const integer_storage = Attribute.IntegerAttr{
        .value = 42,
        .width = 64,
        .is_signed = true,
        .context = &context_token,
    };
    const string_storage = Attribute.StringAttr{
        .value = "name",
        .context = &context_token,
    };
    const dialect_storage = Attribute.DialectAttr{
        .payload = "payload",
        .context = &context_token,
    };

    const int_attr = Attribute{
        .attr_id = Attribute.attrIdFromInt(integer_abstract.attr_id),
        .impl = &integer_storage,
        .abstract = &integer_abstract,
    };
    const string_attr = Attribute{
        .attr_id = Attribute.attrIdFromInt(string_abstract.attr_id),
        .impl = &string_storage,
        .abstract = &string_abstract,
    };
    const dialect_attr = Attribute{
        .attr_id = Attribute.attrIdFromInt(dialect_abstract.attr_id),
        .impl = &dialect_storage,
        .abstract = &dialect_abstract,
    };

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
