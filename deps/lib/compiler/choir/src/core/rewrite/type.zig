const std = @import("std");
const ir = @import("../root.zig");
const PatternRewriter = ir.rewrite.PatternRewriter;

pub const TypeConverter = struct {
    allocator: std.mem.Allocator,

    conversions: std.HashMap(TypeKey, TypeConversionResult, TypeKeyContext, std.hash_map.default_max_load_percentage),
    materialize_fn: ?MaterializeFn,

    const TypeKey = struct {
        name: []const u8,
        param_key: []const u8,
    };

    const TypeKeyContext = struct {
        pub fn hash(_: TypeKeyContext, key: TypeKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(key.name);
            hasher.update(&[_]u8{0});
            hasher.update(key.param_key);
            return hasher.final();
        }

        pub fn eql(_: TypeKeyContext, a: TypeKey, b: TypeKey) bool {
            return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.param_key, b.param_key);
        }
    };

    pub const TypeConversionResult = struct {
        types: []ir.Type,
    };

    pub const MaterializeFn = *const fn (
        rewriter: *PatternRewriter,
        value: *ir.Value,
        target_type: ir.Type,
    ) ?*ir.Value;

    fn dupeTypes(allocator: std.mem.Allocator, target_types: []const ir.Type) ![]ir.Type {
        if (target_types.len == 0) {
            return try allocator.alloc(ir.Type, 0);
        }
        const duped = try allocator.alloc(ir.Type, target_types.len);
        @memcpy(duped, target_types);
        return duped;
    }

    pub fn init(allocator: std.mem.Allocator) TypeConverter {
        return .{
            .allocator = allocator,
            .conversions = std.HashMap(TypeKey, TypeConversionResult, TypeKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .materialize_fn = null,
        };
    }

    pub fn deinit(self: *TypeConverter) void {
        var iter = self.conversions.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            self.allocator.free(key.name);
            if (key.param_key.len > 0) {
                self.allocator.free(key.param_key);
            }
            const types = entry.value_ptr.types;
            self.allocator.free(types);
        }
        self.conversions.deinit();
    }

    pub fn addConversion(self: *TypeConverter, source_type: ir.Type, target_types: []const ir.Type) !void {
        const storage = source_type.getDialectStorage() orelse return error.InvalidType;
        const lookup_key = TypeKey{ .name = storage.name, .param_key = storage.param_key };
        if (self.conversions.getPtr(lookup_key)) |result| {
            const types_copy = try dupeTypes(self.allocator, target_types);
            errdefer self.allocator.free(types_copy);
            self.allocator.free(result.types);
            result.types = types_copy;
            return;
        }
        const name_copy = try self.allocator.dupe(u8, storage.name);
        errdefer self.allocator.free(name_copy);
        const key_copy = if (storage.param_key.len > 0)
            try self.allocator.dupe(u8, storage.param_key)
        else
            "";
        errdefer if (key_copy.len > 0) self.allocator.free(key_copy);

        const types_copy = try dupeTypes(self.allocator, target_types);
        errdefer self.allocator.free(types_copy);

        try self.conversions.put(.{ .name = name_copy, .param_key = key_copy }, TypeConversionResult{ .types = types_copy });
    }

    pub fn setMaterialization(self: *TypeConverter, materialize_fn: MaterializeFn) void {
        self.materialize_fn = materialize_fn;
    }

    pub fn materialize(self: *const TypeConverter, rewriter: *PatternRewriter, value: *ir.Value, target_type: ir.Type) ?*ir.Value {
        const func = self.materialize_fn orelse return null;
        return func(rewriter, value, target_type);
    }

    pub fn convertType(self: *const TypeConverter, source_type: ir.Type) ?[]const ir.Type {
        if (source_type.getDialectStorage()) |storage| {
            const key = TypeKey{ .name = storage.name, .param_key = storage.param_key };
            if (self.conversions.get(key)) |result| {
                return result.types;
            }
        }
        return null;
    }

    pub fn convertTypesAlloc(self: *const TypeConverter, allocator: std.mem.Allocator, source_types: []const ir.Type) ![]ir.Type {
        var out: std.ArrayListUnmanaged(ir.Type) = .empty;
        errdefer out.deinit(allocator);

        for (source_types) |source_type| {
            if (self.convertType(source_type)) |converted| {
                try out.appendSlice(allocator, converted);
            } else {
                try out.append(allocator, source_type);
            }
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn isTypeLegal(self: *const TypeConverter, t: ir.Type) bool {
        return self.convertType(t) == null;
    }
};
