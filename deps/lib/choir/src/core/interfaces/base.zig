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

test "interfaceId produces stable hashes" {
    const testing = std.testing;

    const id1 = interfaceId("ir.interface.symbol_op");
    const id2 = interfaceId("ir.interface.symbol_op");
    const id3 = interfaceId("ir.interface.comptime_evaluatable");

    try testing.expectEqual(id1, id2);
    try testing.expect(id1 != id3);

    const runtime_id = interfaceIdRuntime("ir.interface.symbol_op");
    try testing.expectEqual(id1, runtime_id);
}

test "InterfaceEntries keeps two sorted entries inline and spills transactionally" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 24), @sizeOf(InterfaceEntries));

    const vtable_a: u8 = 1;
    const vtable_b: u8 = 2;
    const vtable_c: u8 = 3;
    const vtable_replacement: u8 = 4;
    const vtable_d: u8 = 5;
    var failing = testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    var inline_storage: [InterfaceEntries.inline_capacity]InterfaceEntry = undefined;
    var entries = InterfaceEntries.initInline(&inline_storage);
    defer entries.deinit(failing.allocator());

    try entries.insert(failing.allocator(), .{ .id = 20, .vtable = &vtable_b });
    try entries.insert(failing.allocator(), .{ .id = 10, .vtable = &vtable_a });
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expectEqual(@as(InterfaceId, 10), entries.values()[0].id);
    try testing.expectEqual(@as(InterfaceId, 20), entries.values()[1].id);
    try testing.expectError(
        error.DuplicateInterface,
        entries.insert(failing.allocator(), .{ .id = 10, .vtable = &vtable_a }),
    );
    try entries.insertOrReplace(
        failing.allocator(),
        .{ .id = 10, .vtable = &vtable_replacement },
    );
    try testing.expectEqual(
        @as(*const u8, &vtable_replacement),
        @as(*const u8, @ptrCast(entries.get(10).?)),
    );
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);

    try testing.expectError(
        error.OutOfMemory,
        entries.insert(failing.allocator(), .{ .id = 30, .vtable = &vtable_c }),
    );
    try testing.expectEqual(@as(usize, 2), entries.count());
    try testing.expect(entries.get(30) == null);

    failing.fail_index = std.math.maxInt(usize);
    const before_allocated = failing.allocated_bytes;
    try entries.insert(failing.allocator(), .{ .id = 30, .vtable = &vtable_c });
    try testing.expectEqual(@as(usize, 3), entries.count());
    try testing.expectEqual(
        std.math.add(usize, before_allocated, 3 * @sizeOf(InterfaceEntry)) catch unreachable,
        failing.allocated_bytes,
    );
    try entries.insert(failing.allocator(), .{ .id = 5, .vtable = &vtable_d });
    try testing.expectEqual(@as(InterfaceId, 5), entries.values()[0].id);
    try testing.expectEqual(@as(usize, 4), entries.count());
}
