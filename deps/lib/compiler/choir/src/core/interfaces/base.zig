const std = @import("std");
const entry = @import("entry.zig");

pub const ContextOpaque = opaque {};

pub fn castContext(comptime CtxT: type, ctx_ptr: *const ContextOpaque) *CtxT {
    return @ptrCast(@alignCast(@constCast(ctx_ptr)));
}

pub const InterfaceId = u64;

pub fn interfaceId(comptime name: []const u8) InterfaceId {
    return std.hash.Wyhash.hash(0, name);
}

pub fn interfaceIdRuntime(name: []const u8) InterfaceId {
    return std.hash.Wyhash.hash(0, name);
}

pub const InterfaceEntry = struct {
    id: InterfaceId,
    vtable: *const anyopaque,
};

pub const InterfaceEntries = struct {
    pub const inline_capacity: usize = 2;

    const Storage = entry.InlineList(InterfaceEntry, inline_capacity);

    storage: Storage = .{},

    pub const InsertError = error{DuplicateInterface} || std.mem.Allocator.Error;

    pub fn initInline(storage: *[inline_capacity]InterfaceEntry) InterfaceEntries {
        return .{ .storage = Storage.initInline(storage) };
    }

    pub fn deinit(self: *InterfaceEntries, allocator: std.mem.Allocator) void {
        self.storage.deinit(allocator);
    }

    pub fn insert(
        self: *InterfaceEntries,
        allocator: std.mem.Allocator,
        item: InterfaceEntry,
    ) InsertError!void {
        if (self.findIndex(item.id) != null) return error.DuplicateInterface;
        try self.storage.append(allocator, item);
        std.mem.sort(InterfaceEntry, self.storage.valuesMut(), {}, lessThan);
    }

    pub fn insertOrReplace(
        self: *InterfaceEntries,
        allocator: std.mem.Allocator,
        item: InterfaceEntry,
    ) std.mem.Allocator.Error!void {
        if (self.findIndex(item.id)) |index| {
            self.storage.valuesMut()[index].vtable = item.vtable;
            return;
        }
        try self.storage.append(allocator, item);
        std.mem.sort(InterfaceEntry, self.storage.valuesMut(), {}, lessThan);
    }

    pub fn get(self: *const InterfaceEntries, id: InterfaceId) ?*const anyopaque {
        const index = self.findIndex(id) orelse return null;
        return self.storage.values()[index].vtable;
    }

    pub fn values(self: *const InterfaceEntries) []const InterfaceEntry {
        return self.storage.values();
    }

    pub fn count(self: *const InterfaceEntries) usize {
        return self.storage.values().len;
    }

    fn findIndex(self: *const InterfaceEntries, id: InterfaceId) ?usize {
        const sorted = self.storage.values();
        var left: usize = 0;
        var right = sorted.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (sorted[mid].id == id) return mid;
            if (sorted[mid].id < id) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return null;
    }

    fn lessThan(_: void, a: InterfaceEntry, b: InterfaceEntry) bool {
        return a.id < b.id;
    }
};

pub const TypeParamPayload = struct {
    ptr: *anyopaque,
    deinit: *const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void,
};
