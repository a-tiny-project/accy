const std = @import("std");
const core = @import("../root.zig");
const Attribute = core.Attribute;
const interfaces = @import("../interfaces/root.zig");

pub const Ref = struct {
    model: *const interfaces.OperationPropertiesModel,
    storage: *const anyopaque,
};

pub fn Storage(comptime Operation: type) type {
    return struct {
        model: ?*const interfaces.OperationPropertiesModel = null,
        memory: []u8 = &.{},

        const PropertyStorage = @This();

        pub fn init(
            self: *PropertyStorage,
            allocator: std.mem.Allocator,
            model: *const interfaces.OperationPropertiesModel,
            memory: []u8,
        ) !void {
            if (model.size == 0) return error.EmptyOperationProperties;
            std.debug.assert(memory.len == model.size);
            std.debug.assert(@intFromPtr(memory.ptr) % model.alignment.toByteUnits() == 0);
            self.* = .{
                .model = model,
                .memory = memory,
            };
            errdefer self.* = .{};
            try model.init(self.ptr(), allocator);
        }

        pub fn deinit(self: *PropertyStorage, allocator: std.mem.Allocator) void {
            const model = self.model orelse return;
            model.deinit(self.ptr(), allocator);
            self.* = .{};
        }

        pub fn getInherentAttr(
            self: *const PropertyStorage,
            op: *const Operation,
            name: []const u8,
        ) ?Attribute {
            const model = self.model orelse return null;
            const hook = model.getInherentAttr orelse return null;
            return hook(op, self.constPtr(), name);
        }

        pub fn setInherentAttr(
            self: *PropertyStorage,
            op: *Operation,
            name: []const u8,
            value: Attribute,
        ) !bool {
            const model = self.model orelse return false;
            const hook = model.setInherentAttr orelse return false;
            return try hook(op, self.ptr(), name, value);
        }

        pub fn removeInherentAttr(
            self: *PropertyStorage,
            op: *Operation,
            name: []const u8,
        ) bool {
            const model = self.model orelse return false;
            const hook = model.removeInherentAttr orelse return false;
            return hook(op, self.ptr(), name);
        }

        pub fn getPropertiesAsAttr(
            self: *const PropertyStorage,
            op: *const Operation,
        ) !?Attribute {
            const model = self.model orelse return null;
            const hook = model.getPropertiesAsAttr orelse
                return error.UnsupportedOperationProperties;
            if (model.setPropertiesFromAttr == null) {
                return error.UnsupportedOperationProperties;
            }
            return hook(op, self.constPtr());
        }

        pub fn setPropertiesFromAttr(
            self: *PropertyStorage,
            op: *Operation,
            attr: Attribute,
        ) !void {
            const model = self.model orelse return error.UnsupportedOperationProperties;
            const hook = model.setPropertiesFromAttr orelse return error.UnsupportedOperationProperties;
            try hook(op, self.ptr(), attr);
        }

        pub fn asRef(self: *const PropertyStorage) ?Ref {
            const model = self.model orelse return null;
            return .{ .model = model, .storage = self.constPtr() };
        }

        pub fn copyFrom(
            self: *PropertyStorage,
            source: Ref,
        ) !void {
            const model = self.model orelse return error.UnsupportedOperationProperties;
            if (!std.mem.eql(u8, model.name, source.model.name) or
                model.size != source.model.size or
                model.alignment != source.model.alignment)
            {
                return error.OperationPropertiesMismatch;
            }
            try model.copyProperties(self.ptr(), source.storage);
        }

        fn ptr(self: *PropertyStorage) *anyopaque {
            return @ptrCast(&self.memory[0]);
        }

        fn constPtr(self: *const PropertyStorage) *const anyopaque {
            return @ptrCast(&self.memory[0]);
        }
    };
}
