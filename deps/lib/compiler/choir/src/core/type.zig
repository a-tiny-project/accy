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
