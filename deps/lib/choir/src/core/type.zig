const std = @import("std");

pub const Type = struct {
    type_id: TypeID,

    impl: *const anyopaque,

    pub const TypeID = enum(u32) {
        dialect_type,
        _,
    };

    pub const DialectTypeStorage = struct {
        name: []const u8,
        param_key: []const u8,
        type_info: ?*const anyopaque,
        print_fn: ?*const fn (type_ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void,
        unique_id: u64,
    };

    pub fn isa(self: Type, comptime type_id: TypeID) bool {
        return self.type_id == type_id;
    }

    pub fn cast(self: Type, comptime T: type) ?*const T {
        return @ptrCast(@alignCast(self.impl));
    }

    pub fn isDialectType(self: Type) bool {
        return self.type_id == .dialect_type;
    }

    pub fn getDialectStorage(self: Type) ?*const DialectTypeStorage {
        if (self.type_id != .dialect_type) return null;
        return @ptrCast(@alignCast(self.impl));
    }

    pub fn getDialectTypeName(self: Type) ?[]const u8 {
        if (self.getDialectStorage()) |storage| {
            return storage.name;
        }
        return null;
    }

    pub fn getDialectParamKey(self: Type) ?[]const u8 {
        if (self.getDialectStorage()) |storage| {
            if (storage.param_key.len == 0) return null;
            return storage.param_key;
        }
        return null;
    }

    pub fn uniqueId(self: Type) u64 {
        if (self.getDialectStorage()) |storage| {
            return storage.unique_id;
        }
        return @intFromPtr(self.impl);
    }

    pub fn eql(self: Type, other: Type) bool {
        return self.impl == other.impl;
    }

    pub fn format(self: Type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.type_id) {
            .dialect_type => {
                if (self.getDialectStorage()) |storage| {
                    try writer.print("!{s}", .{storage.name});
                    if (storage.param_key.len > 0) {
                        try writer.print("<{s}>", .{storage.param_key});
                    }
                } else {
                    try writer.writeAll("!dialect_type");
                }
            },
            else => try writer.print("!type<{d}>", .{@backingInt(self.type_id)}),
        }
    }
};

test "Type.eql uses pointer equality" {
    const storage = Type.DialectTypeStorage{
        .name = "test.i32",
        .param_key = "",
        .type_info = null,
        .print_fn = null,
        .unique_id = 1,
    };
    const t1 = Type{ .type_id = .dialect_type, .impl = &storage };
    const t2 = Type{ .type_id = .dialect_type, .impl = &storage };

    try std.testing.expect(t1.eql(t2));
    try std.testing.expect(t1.impl == t2.impl);
}

test "Type.eql different pointers are not equal" {
    const storage1 = Type.DialectTypeStorage{
        .name = "test.i32",
        .param_key = "",
        .type_info = null,
        .print_fn = null,
        .unique_id = 1,
    };
    const storage2 = Type.DialectTypeStorage{
        .name = "test.i32",
        .param_key = "",
        .type_info = null,
        .print_fn = null,
        .unique_id = 2,
    };
    const t1 = Type{ .type_id = .dialect_type, .impl = &storage1 };
    const t2 = Type{ .type_id = .dialect_type, .impl = &storage2 };

    try std.testing.expect(!t1.eql(t2));
    try std.testing.expect(t1.impl != t2.impl);
}

test "Type.uniqueId returns assigned ID" {
    const storage = Type.DialectTypeStorage{
        .name = "test.f64",
        .param_key = "custom_key",
        .type_info = null,
        .print_fn = null,
        .unique_id = 42,
    };
    const t = Type{ .type_id = .dialect_type, .impl = &storage };

    try std.testing.expectEqual(@as(u64, 42), t.uniqueId());
}

test "Type.uniqueId for non-dialect type uses pointer" {
    const some_impl: u64 = 0xDEADBEEF;
    const t = Type{ .type_id = @fromBackingInt(@intCast(999)), .impl = @ptrFromInt(some_impl) };

    try std.testing.expectEqual(some_impl, t.uniqueId());
}
