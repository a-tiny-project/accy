const std = @import("std");
const interfaces = @import("interfaces/root.zig");
const TypeRegistry = interfaces.TypeRegistry;
const Type = @import("type.zig").Type;

pub const TypeStorage = struct {
    dialect_types: std.HashMapUnmanaged(DialectTypeKey, Type, DialectTypeKeyContext, std.hash_map.default_max_load_percentage),
    next_type_id: u64,

    pub const DialectTypeKey = struct {
        name: []const u8,
        param_key: []const u8,

        pub fn eql(self: DialectTypeKey, other: DialectTypeKey) bool {
            return std.mem.eql(u8, self.name, other.name) and std.mem.eql(u8, self.param_key, other.param_key);
        }

        pub fn hash(self: DialectTypeKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(self.name);
            hasher.update(&[_]u8{0});
            hasher.update(self.param_key);
            return hasher.final();
        }
    };

    pub const DialectTypeKeyContext = struct {
        pub fn hash(_: DialectTypeKeyContext, key: DialectTypeKey) u64 {
            return key.hash();
        }

        pub fn eql(_: DialectTypeKeyContext, a: DialectTypeKey, b: DialectTypeKey) bool {
            return a.eql(b);
        }
    };

    pub fn init(allocator: std.mem.Allocator) TypeStorage {
        _ = allocator;
        return .{
            .dialect_types = .{},
            .next_type_id = 1,
        };
    }

    pub fn allocateTypeId(self: *TypeStorage) u64 {
        const id = self.next_type_id;
        self.next_type_id += 1;
        return id;
    }

    pub fn deinit(
        self: *TypeStorage,
        table_allocator: std.mem.Allocator,
        key_allocator: std.mem.Allocator,
        payload_allocator: std.mem.Allocator,
    ) void {
        var dialect_iter = self.dialect_types.valueIterator();
        while (dialect_iter.next()) |typ| {
            const impl: *Type.DialectTypeStorage = @ptrCast(@alignCast(@constCast(typ.impl)));
            if (impl.param_key.len > 0) {
                key_allocator.free(impl.param_key);
            }
            payload_allocator.destroy(impl);
        }
        self.dialect_types.deinit(table_allocator);
    }
};

const default_hash_load = std.hash_map.default_max_load_percentage;

pub const TypeParamCache = std.HashMapUnmanaged(
    u64,
    interfaces.TypeParamPayload,
    std.hash_map.AutoContext(u64),
    default_hash_load,
);

pub const TypeInterner = struct {
    storage: TypeStorage,
    registry: TypeRegistry,

    pub fn init(
        table_allocator: std.mem.Allocator,
        registry_allocator: std.mem.Allocator,
    ) TypeInterner {
        return .{
            .storage = TypeStorage.init(table_allocator),
            .registry = TypeRegistry.init(registry_allocator),
        };
    }

    pub fn deinit(
        self: *TypeInterner,
        table_allocator: std.mem.Allocator,
        key_allocator: std.mem.Allocator,
        payload_allocator: std.mem.Allocator,
    ) void {
        self.storage.deinit(table_allocator, key_allocator, payload_allocator);
        self.registry.deinit();
    }
};
