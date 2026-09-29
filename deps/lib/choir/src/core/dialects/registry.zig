const std = @import("std");
const core = @import("../root.zig");

const Type = core.Type;
const Operation = core.Operation;
const Context = core.Context;
const interfaces = core.interfaces;

pub const DialectLoaderFn = *const fn (ctx: *Context) anyerror!void;

pub const DialectExtensionFn = *const fn (ctx: *Context) anyerror!void;

pub const DialectRegistryEntry = struct {
    name: []const u8,
    load: DialectLoaderFn,
};

pub const DialectRegistrySpec = struct {
    entries: []const DialectRegistryEntry,
};

pub const OpInterfaceFallbackFn = *const fn (op: *const Operation) ?*const anyopaque;

pub const OpInterfaceFallbackEntry = struct {
    id: interfaces.InterfaceId,
    fallback: OpInterfaceFallbackFn,
};

pub const TypeInterfaceFallbackFn = *const fn (ctx: *const Context, typ: Type) ?*const anyopaque;

pub const TypeInterfaceFallbackEntry = struct {
    id: interfaces.InterfaceId,
    fallback: TypeInterfaceFallbackFn,
};

pub fn InterfaceFallbackRegistry(comptime FallbackFn: type) type {
    return struct {
        groups: std.ArrayListUnmanaged(Group) = .empty,

        const Self = @This();

        const Entry = struct {
            dialect_name: []const u8,
            fallback: FallbackFn,
        };

        pub const Lookup = struct {
            entries: []const Entry,

            pub fn get(self: Lookup, dialect_name: []const u8) ?FallbackFn {
                for (self.entries) |entry| {
                    if (std.mem.eql(u8, entry.dialect_name, dialect_name)) return entry.fallback;
                }
                return null;
            }
        };

        const Group = struct {
            id: interfaces.InterfaceId,
            entries: std.ArrayListUnmanaged(Entry),
        };

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.groups.items) |*group| {
                group.entries.deinit(allocator);
            }
            self.groups.deinit(allocator);
        }

        pub fn register(
            self: *Self,
            allocator: std.mem.Allocator,
            dialect_name: []const u8,
            id: interfaces.InterfaceId,
            fallback: FallbackFn,
        ) (error{DuplicateInterface} || std.mem.Allocator.Error)!void {
            const index = self.lowerBound(id);
            if (index < self.groups.items.len and self.groups.items[index].id == id) {
                const group = &self.groups.items[index];
                for (group.entries.items) |entry| {
                    if (std.mem.eql(u8, entry.dialect_name, dialect_name)) {
                        return error.DuplicateInterface;
                    }
                }
                try group.entries.append(allocator, .{ .dialect_name = dialect_name, .fallback = fallback });
                return;
            }

            var entries: std.ArrayListUnmanaged(Entry) = .empty;
            errdefer entries.deinit(allocator);
            try entries.append(allocator, .{ .dialect_name = dialect_name, .fallback = fallback });
            try self.groups.insert(allocator, index, .{ .id = id, .entries = entries });
        }

        pub fn get(self: *const Self, dialect_name: []const u8, id: interfaces.InterfaceId) ?FallbackFn {
            const candidates = self.lookup(id) orelse return null;
            return candidates.get(dialect_name);
        }

        pub fn lookup(self: *const Self, id: interfaces.InterfaceId) ?Lookup {
            const index = self.lowerBound(id);
            if (index == self.groups.items.len or self.groups.items[index].id != id) return null;
            return .{ .entries = self.groups.items[index].entries.items };
        }

        fn lowerBound(self: *const Self, id: interfaces.InterfaceId) usize {
            var left: usize = 0;
            var right = self.groups.items.len;
            while (left < right) {
                const mid = left + (right - left) / 2;
                if (self.groups.items[mid].id < id) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }
            return left;
        }
    };
}

pub const DialectLoadState = enum {
    loading,
    loaded,
};

pub const Dialect = struct {
    name: []const u8,
    context: *Context,

    pub fn init(name: []const u8, context: *Context) Dialect {
        return .{
            .name = name,
            .context = context,
        };
    }
};

pub const DialectRegistry = struct {
    names: std.StringHashMapUnmanaged(void),

    loaded: std.StringHashMap(*Dialect),

    loaders: std.StringHashMapUnmanaged(DialectLoaderFn),

    load_state: std.StringHashMapUnmanaged(DialectLoadState),

    pending_extensions: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(DialectExtensionFn)),

    interfaces: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(interfaces.InterfaceEntry)),

    op_interface_fallbacks: InterfaceFallbackRegistry(OpInterfaceFallbackFn),

    type_interface_fallbacks: InterfaceFallbackRegistry(TypeInterfaceFallbackFn),

    backend_names: std.StringHashMapUnmanaged(void),

    operation_registry: interfaces.OperationRegistry,

    allow_unregistered: bool,

    pub fn init(
        table_allocator: std.mem.Allocator,
        interface_allocator: std.mem.Allocator,
    ) DialectRegistry {
        return .{
            .names = .{},
            .loaded = std.StringHashMap(*Dialect).init(table_allocator),
            .loaders = .{},
            .load_state = .{},
            .pending_extensions = .{},
            .interfaces = .{},
            .op_interface_fallbacks = .{},
            .type_interface_fallbacks = .{},
            .backend_names = .{},
            .operation_registry = interfaces.OperationRegistry.init(interface_allocator),
            .allow_unregistered = false,
        };
    }

    pub fn deinit(
        self: *DialectRegistry,
        table_allocator: std.mem.Allocator,
        name_allocator: std.mem.Allocator,
        interface_allocator: std.mem.Allocator,
    ) void {
        var dialect_iter = self.loaded.valueIterator();
        while (dialect_iter.next()) |dialect| {
            table_allocator.destroy(dialect.*);
        }
        self.loaded.deinit();

        self.loaders.deinit(table_allocator);

        self.load_state.deinit(table_allocator);

        var ext_iter = self.pending_extensions.valueIterator();
        while (ext_iter.next()) |ext_list| {
            ext_list.deinit(interface_allocator);
        }
        self.pending_extensions.deinit(interface_allocator);

        var di_iter = self.interfaces.valueIterator();
        while (di_iter.next()) |iface_list| {
            iface_list.deinit(interface_allocator);
        }
        self.interfaces.deinit(interface_allocator);

        self.op_interface_fallbacks.deinit(interface_allocator);

        self.type_interface_fallbacks.deinit(interface_allocator);

        self.backend_names.deinit(table_allocator);

        var name_iter = self.names.keyIterator();
        while (name_iter.next()) |name_ptr| {
            name_allocator.free(name_ptr.*);
        }
        self.names.deinit(table_allocator);

        self.operation_registry.deinit();
    }

    pub fn internDialectName(
        self: *DialectRegistry,
        table_allocator: std.mem.Allocator,
        name_allocator: std.mem.Allocator,
        name: []const u8,
    ) ![]const u8 {
        if (self.names.getKeyPtr(name)) |key_ptr| {
            return key_ptr.*;
        }
        const copy = try name_allocator.dupe(u8, name);
        errdefer name_allocator.free(copy);
        try self.names.putNoClobber(table_allocator, copy, {});
        return copy;
    }
};

test "interface fallback registry survives allocation failures" {
    const testing = std.testing;
    const Harness = struct {
        const FallbackFn = *const fn () void;

        fn fallback() void {}

        fn run(allocator: std.mem.Allocator) !void {
            var registry: InterfaceFallbackRegistry(FallbackFn) = .{};
            defer registry.deinit(allocator);

            try registry.register(allocator, "beta", 17, fallback);
            try registry.register(allocator, "alpha", 3, fallback);
            try registry.register(allocator, "alpha", 17, fallback);
            const id_17 = registry.lookup(17).?;
            try testing.expect(id_17.get("alpha") != null);
            try testing.expect(id_17.get("beta") != null);
            try testing.expectEqual(@as(?FallbackFn, null), id_17.get("missing"));
            try testing.expectEqual(@as(?InterfaceFallbackRegistry(FallbackFn).Lookup, null), registry.lookup(19));
            try testing.expect(registry.get("alpha", 3) != null);
            try testing.expect(registry.get("alpha", 17) != null);
            try testing.expect(registry.get("beta", 17) != null);
        }
    };

    try testing.checkAllAllocationFailures(testing.allocator, Harness.run, .{});
}

test {
    @import("std").testing.refAllDecls(@This());
}
