const std = @import("std");
const base = @import("base.zig");
const IrAttribute = @import("../root.zig").Attribute;
const IrOperation = @import("../root.zig").Operation;
const IrSymbolTable = @import("../root.zig").SymbolTable;

const InterfaceId = base.InterfaceId;
const InterfaceEntry = base.InterfaceEntry;

pub const AbstractAttribute = struct {
    attr_id: u32,

    name: []const u8,

    interfaces: []const InterfaceEntry,

    pub fn getInterface(self: *const AbstractAttribute, id: InterfaceId) ?*const anyopaque {
        for (self.interfaces) |entry| {
            if (entry.id == id) return entry.vtable;
        }
        return null;
    }

    pub fn hasInterface(self: *const AbstractAttribute, id: InterfaceId) bool {
        return self.getInterface(id) != null;
    }
};

pub const AttributeEqualInterface = struct {
    pub const interface_name = "ir.interface.attribute_equal";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        eql: *const fn (self_impl: *const anyopaque, other_impl: *const anyopaque) bool,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(comptime eql: *const fn (self_impl: *const anyopaque, other_impl: *const anyopaque) bool) *const VTable {
        return &.{ .eql = eql };
    }

    pub fn entryFor(comptime eql: *const fn (self_impl: *const anyopaque, other_impl: *const anyopaque) bool) InterfaceEntry {
        return entry(vtableFor(eql));
    }
};

pub const AttributePrintInterface = struct {
    pub const interface_name = "ir.interface.attribute_print";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        print: *const fn (attr_ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(comptime print: *const fn (attr_ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void) *const VTable {
        return &.{ .print = print };
    }

    pub fn entryFor(comptime print: *const fn (attr_ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void) InterfaceEntry {
        return entry(vtableFor(print));
    }
};

pub const AttributeArrayInterface = struct {
    pub const interface_name = "ir.interface.attribute_array";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        getCount: *const fn (attr_ptr: *const anyopaque) usize,
        getElement: *const fn (attr_ptr: *const anyopaque, index: usize) ?IrAttribute,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(
        comptime getCount: *const fn (attr_ptr: *const anyopaque) usize,
        comptime getElement: *const fn (attr_ptr: *const anyopaque, index: usize) ?IrAttribute,
    ) *const VTable {
        return &.{
            .getCount = getCount,
            .getElement = getElement,
        };
    }

    pub fn entryFor(
        comptime getCount: *const fn (attr_ptr: *const anyopaque) usize,
        comptime getElement: *const fn (attr_ptr: *const anyopaque, index: usize) ?IrAttribute,
    ) InterfaceEntry {
        return entry(vtableFor(getCount, getElement));
    }
};

pub const SymbolUserAttrInterface = struct {
    pub const interface_name = "ir.interface.symbol_user_attr";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        verifySymbolUses: *const fn (
            attr_ptr: *const anyopaque,
            op: *IrOperation,
            symbol_tables: *IrSymbolTable.Collection,
        ) anyerror!void,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(
        comptime verifySymbolUses: *const fn (
            attr_ptr: *const anyopaque,
            op: *IrOperation,
            symbol_tables: *IrSymbolTable.Collection,
        ) anyerror!void,
    ) *const VTable {
        return &.{ .verifySymbolUses = verifySymbolUses };
    }

    pub fn entryFor(
        comptime verifySymbolUses: *const fn (
            attr_ptr: *const anyopaque,
            op: *IrOperation,
            symbol_tables: *IrSymbolTable.Collection,
        ) anyerror!void,
    ) InterfaceEntry {
        return entry(vtableFor(verifySymbolUses));
    }
};

pub const AttributeRegistry = struct {
    allocator: std.mem.Allocator,
    attrs: std.StringHashMapUnmanaged(AttributeRegistryEntry),
    next_attr_id: u32,

    pub const AttributeRegistryEntry = struct {
        abstract: *const AbstractAttribute,
        owns_interfaces: bool,
    };

    pub const RegisterError = error{DuplicateAttribute} || std.mem.Allocator.Error;

    pub const RegisterInterfaceError = error{ UnknownAttribute, DuplicateInterface } || std.mem.Allocator.Error;

    pub const RegisterOrReplaceInterfaceError = error{UnknownAttribute} || std.mem.Allocator.Error;

    fn interfaceLessThan(_: void, a: InterfaceEntry, b: InterfaceEntry) bool {
        return a.id < b.id;
    }

    pub fn init(allocator: std.mem.Allocator, first_dynamic_id: u32) AttributeRegistry {
        return .{
            .allocator = allocator,
            .attrs = .{},
            .next_attr_id = first_dynamic_id,
        };
    }

    pub fn deinit(self: *AttributeRegistry) void {
        var it = self.attrs.valueIterator();
        while (it.next()) |entry| {
            const abstract = entry.abstract;
            if (entry.owns_interfaces and abstract.interfaces.len > 0) {
                self.allocator.free(@constCast(abstract.interfaces));
            }
            self.allocator.destroy(@constCast(abstract));
        }

        var key_iter = self.attrs.keyIterator();
        while (key_iter.next()) |name_ptr| {
            self.allocator.free(name_ptr.*);
        }
        self.attrs.deinit(self.allocator);
    }

    pub fn lookup(self: *const AttributeRegistry, attr_name: []const u8) ?*const AbstractAttribute {
        if (self.attrs.get(attr_name)) |entry| {
            return entry.abstract;
        }
        return null;
    }

    pub fn nextAttributeId(self: *AttributeRegistry) u32 {
        return self.next_attr_id;
    }

    pub fn restoreNextAttributeId(self: *AttributeRegistry, id: u32) void {
        self.next_attr_id = id;
    }

    pub fn registerAttribute(
        self: *AttributeRegistry,
        attr_name: []const u8,
        interfaces: []const InterfaceEntry,
    ) RegisterError!*const AbstractAttribute {
        if (self.attrs.get(attr_name) != null) return error.DuplicateAttribute;

        const owned_name = try self.allocator.dupe(u8, attr_name);
        errdefer self.allocator.free(owned_name);

        var iface_slice: []InterfaceEntry = &.{};
        var owns_interfaces = false;
        if (interfaces.len > 0) {
            iface_slice = try self.allocator.dupe(InterfaceEntry, interfaces);
            std.mem.sort(InterfaceEntry, iface_slice, {}, interfaceLessThan);
            owns_interfaces = true;
        }
        errdefer if (owns_interfaces and iface_slice.len > 0) self.allocator.free(iface_slice);

        const abstract = try self.allocator.create(AbstractAttribute);
        errdefer self.allocator.destroy(abstract);

        abstract.* = .{
            .attr_id = self.next_attr_id,
            .name = owned_name,
            .interfaces = iface_slice,
        };

        const gop = try self.attrs.getOrPut(self.allocator, owned_name);
        if (gop.found_existing) return error.DuplicateAttribute;

        gop.key_ptr.* = owned_name;
        gop.value_ptr.* = .{
            .abstract = abstract,
            .owns_interfaces = owns_interfaces,
        };
        self.next_attr_id += 1;

        return abstract;
    }

    pub fn registerInterface(
        self: *AttributeRegistry,
        attr_name: []const u8,
        entry: InterfaceEntry,
    ) RegisterInterfaceError!void {
        const reg_entry = self.attrs.getPtr(attr_name) orelse return error.UnknownAttribute;
        const abstract: *AbstractAttribute = @constCast(reg_entry.abstract);

        for (abstract.interfaces) |existing| {
            if (existing.id == entry.id) return error.DuplicateInterface;
        }

        const old_slice = abstract.interfaces;
        const new_slice = try self.allocator.alloc(InterfaceEntry, old_slice.len + 1);
        if (old_slice.len > 0) {
            @memcpy(new_slice[0..old_slice.len], old_slice);
        }
        new_slice[old_slice.len] = entry;
        std.mem.sort(InterfaceEntry, new_slice, {}, interfaceLessThan);

        if (reg_entry.owns_interfaces and old_slice.len > 0) {
            self.allocator.free(@constCast(old_slice));
        }

        reg_entry.owns_interfaces = true;
        abstract.interfaces = new_slice;
    }

    pub fn registerOrReplaceInterface(
        self: *AttributeRegistry,
        attr_name: []const u8,
        entry: InterfaceEntry,
    ) RegisterOrReplaceInterfaceError!void {
        const reg_entry = self.attrs.getPtr(attr_name) orelse return error.UnknownAttribute;
        const abstract: *AbstractAttribute = @constCast(reg_entry.abstract);

        const old_slice = abstract.interfaces;
        var replace_index: ?usize = null;
        for (old_slice, 0..) |existing, i| {
            if (existing.id == entry.id) {
                replace_index = i;
                break;
            }
        }

        const new_len = if (replace_index == null) old_slice.len + 1 else old_slice.len;
        const new_slice = try self.allocator.alloc(InterfaceEntry, new_len);
        if (old_slice.len > 0) {
            @memcpy(new_slice[0..old_slice.len], old_slice);
        }

        if (replace_index) |idx| {
            new_slice[idx] = entry;
        } else {
            new_slice[old_slice.len] = entry;
        }
        std.mem.sort(InterfaceEntry, new_slice, {}, interfaceLessThan);

        if (reg_entry.owns_interfaces and old_slice.len > 0) {
            self.allocator.free(@constCast(old_slice));
        }

        reg_entry.owns_interfaces = true;
        abstract.interfaces = new_slice;
    }

    pub fn count(self: *const AttributeRegistry) usize {
        return self.attrs.count();
    }

    pub fn removeAttribute(self: *AttributeRegistry, attr_name: []const u8) bool {
        const removed = self.attrs.fetchRemove(attr_name) orelse return false;

        const abstract = removed.value.abstract;
        if (removed.value.owns_interfaces and abstract.interfaces.len > 0) {
            self.allocator.free(@constCast(abstract.interfaces));
        }
        self.allocator.destroy(@constCast(abstract));
        self.allocator.free(removed.key);
        return true;
    }
};

fn testAttributeEqual(_: *const anyopaque, _: *const anyopaque) bool {
    return true;
}

fn checkRegisterAttributeAllocationFailures(allocator: std.mem.Allocator) !void {
    var registry = AttributeRegistry.init(allocator, 1);
    defer registry.deinit();
    _ = try registry.registerAttribute(
        "allocation.test",
        &.{AttributeEqualInterface.entryFor(testAttributeEqual)},
    );
}
