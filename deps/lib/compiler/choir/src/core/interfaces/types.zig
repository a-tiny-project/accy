const std = @import("std");
const base = @import("base.zig");
const registry_entry = @import("entry.zig");
const format = @import("../root.zig").format;
const IrType = @import("../root.zig").Type;

const InterfaceId = base.InterfaceId;
const InterfaceEntry = base.InterfaceEntry;
const InterfaceEntries = base.InterfaceEntries;
const ContextOpaque = base.ContextOpaque;
const TypeParamPayload = base.TypeParamPayload;

pub const TypeInfo = struct {
    name: []const u8,

    interfaces: InterfaceEntries = .{},

    pub const AddInterfaceError = error{DuplicateInterface} || std.mem.Allocator.Error;

    pub fn init(name: []const u8) TypeInfo {
        return .{ .name = name };
    }

    pub fn deinit(self: *TypeInfo, allocator: std.mem.Allocator) void {
        self.interfaces.deinit(allocator);
    }

    pub fn addInterface(
        self: *TypeInfo,
        allocator: std.mem.Allocator,
        entry: InterfaceEntry,
    ) AddInterfaceError!void {
        try self.interfaces.insert(allocator, entry);
    }

    pub fn addOrReplaceInterface(
        self: *TypeInfo,
        allocator: std.mem.Allocator,
        entry: InterfaceEntry,
    ) !void {
        try self.interfaces.insertOrReplace(allocator, entry);
    }

    pub fn getInterface(self: *const TypeInfo, id: InterfaceId) ?*const anyopaque {
        return self.interfaces.get(id);
    }

    pub fn hasInterface(self: *const TypeInfo, id: InterfaceId) bool {
        return self.getInterface(id) != null;
    }

    pub fn getNumInterfaces(self: *const TypeInfo) usize {
        return self.interfaces.count();
    }
};

pub const TypeRegistry = struct {
    allocator: std.mem.Allocator,

    types: std.StringHashMapUnmanaged(*TypeInfo),
    batch_regions: ?*BatchEntryStorage.RegionOwner,

    allow_unregistered_types: bool,

    pub const GetOrCreateError: type = std.mem.Allocator.Error;

    pub const GetOrCreateResult = struct {
        info: *TypeInfo,
        created: bool,
    };

    pub const RegisterInterfaceError: type = TypeInfo.AddInterfaceError;

    const EntryStorage: type = registry_entry.Storage(TypeInfo);
    const BatchEntryStorage: type = registry_entry.BatchStorage(TypeInfo);

    pub fn init(allocator: std.mem.Allocator) TypeRegistry {
        return .{
            .allocator = allocator,
            .types = .{},
            .batch_regions = null,
            .allow_unregistered_types = false,
        };
    }

    pub fn deinit(self: *TypeRegistry) void {
        var it = self.types.valueIterator();
        while (it.next()) |info_ptr| {
            const info = info_ptr.*;
            if (self.findBatchRegionLink(info) != null) {
                info.deinit(self.allocator);
                info.* = undefined;
            } else {
                EntryStorage.destroy(self.allocator, info);
            }
        }
        self.types.deinit(self.allocator);
        while (self.batch_regions) |region| {
            self.batch_regions = region.next;
            BatchEntryStorage.destroy(self.allocator, region);
        }
    }

    pub fn lookup(self: *const TypeRegistry, type_name: []const u8) ?*TypeInfo {
        return self.types.get(type_name);
    }

    pub fn getOrCreate(self: *TypeRegistry, type_name: []const u8) GetOrCreateError!*TypeInfo {
        return (try self.getOrCreateTracked(type_name)).info;
    }

    pub fn getOrCreateTracked(self: *TypeRegistry, type_name: []const u8) GetOrCreateError!GetOrCreateResult {
        if (self.types.get(type_name)) |existing| {
            return .{ .info = existing, .created = false };
        }

        const info = try EntryStorage.create(self.allocator, type_name);
        errdefer EntryStorage.destroy(self.allocator, info);

        const gop = try self.types.getOrPut(self.allocator, info.name);
        if (gop.found_existing) {
            EntryStorage.destroy(self.allocator, info);
            return .{ .info = gop.value_ptr.*, .created = false };
        }

        gop.value_ptr.* = info;
        return .{ .info = info, .created = true };
    }

    pub fn getOrCreateNamedBatch(self: *TypeRegistry, named_items: anytype) GetOrCreateError!void {
        try self.getOrCreateBatch(named_items);
    }

    fn getOrCreateBatch(
        self: *TypeRegistry,
        items: anytype,
    ) GetOrCreateError!void {
        var info_count: usize = 0;
        var name_bytes: usize = 0;
        for (items) |item| {
            const name = batchItemName(item);
            if (self.types.get(name) != null) continue;
            info_count = std.math.add(usize, info_count, 1) catch return error.OutOfMemory;
            name_bytes = std.math.add(usize, name_bytes, name.len) catch return error.OutOfMemory;
        }
        if (info_count == 0) return;
        const unused_capacity = std.math.cast(u32, info_count) orelse return error.OutOfMemory;

        const allocation = try BatchEntryStorage.create(self.allocator, info_count, name_bytes);
        errdefer BatchEntryStorage.destroy(self.allocator, allocation.region);

        var info_index: usize = 0;
        var name_offset: usize = 0;
        for (items) |item| {
            const name = batchItemName(item);
            if (self.types.get(name) != null) continue;
            const name_end = std.math.add(usize, name_offset, name.len) catch unreachable;
            const owned_name = allocation.names[name_offset..name_end];
            @memcpy(owned_name, name);
            allocation.infos[info_index] = TypeInfo.init(owned_name);
            info_index += 1;
            name_offset = name_end;
        }
        std.debug.assert(info_index == allocation.infos.len);
        std.debug.assert(name_offset == allocation.names.len);

        try self.types.ensureUnusedCapacity(self.allocator, unused_capacity);
        for (allocation.infos) |*info| {
            if (self.types.get(info.name) != null) continue;
            self.types.putAssumeCapacityNoClobber(info.name, info);
        }

        allocation.region.next = self.batch_regions;
        self.batch_regions = allocation.region;
    }

    fn batchItemName(item: anytype) []const u8 {
        if (@TypeOf(item) == []const u8) return item;
        return item.name;
    }

    pub fn registerType(self: *TypeRegistry, type_name: []const u8) GetOrCreateError!*TypeInfo {
        return self.getOrCreate(type_name);
    }

    pub fn registerInterface(
        self: *TypeRegistry,
        type_name: []const u8,
        entry: InterfaceEntry,
    ) RegisterInterfaceError!void {
        const info = try self.getOrCreate(type_name);
        try info.addInterface(self.allocator, entry);
    }

    pub fn registerOrReplaceInterface(
        self: *TypeRegistry,
        type_name: []const u8,
        entry: InterfaceEntry,
    ) !void {
        const info = try self.getOrCreate(type_name);
        try info.addOrReplaceInterface(self.allocator, entry);
    }

    pub fn count(self: *const TypeRegistry) usize {
        return self.types.count();
    }

    pub fn removeType(self: *TypeRegistry, type_name: []const u8) bool {
        const removed = self.types.fetchRemove(type_name) orelse return false;
        const info = removed.value;
        std.debug.assert(removed.key.ptr == info.name.ptr);
        if (self.findBatchRegionLink(info)) |region_link| {
            const region = region_link.*.?;
            info.deinit(self.allocator);
            info.* = undefined;
            if (!self.batchRegionHasLiveInfo(region)) {
                region_link.* = region.next;
                BatchEntryStorage.destroy(self.allocator, region);
            }
        } else {
            EntryStorage.destroy(self.allocator, info);
        }
        return true;
    }

    fn findBatchRegionLink(
        self: *TypeRegistry,
        info: *const TypeInfo,
    ) ?*?*BatchEntryStorage.RegionOwner {
        var region_link = &self.batch_regions;
        while (region_link.*) |region| {
            if (BatchEntryStorage.contains(region, info)) return region_link;
            region_link = &region.next;
        }
        return null;
    }

    fn batchRegionHasLiveInfo(
        self: *const TypeRegistry,
        region: *const BatchEntryStorage.RegionOwner,
    ) bool {
        var it = self.types.valueIterator();
        while (it.next()) |info_ptr| {
            if (BatchEntryStorage.contains(region, info_ptr.*)) return true;
        }
        return false;
    }
};

pub const TypePrintInterface = struct {
    pub const interface_name = "ir.interface.type_print";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        print: *const fn (type_ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(
        comptime print: *const fn (type_ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void,
    ) *const VTable {
        return &.{ .print = print };
    }

    pub fn entryFor(
        comptime print: *const fn (type_ptr: *const anyopaque, writer: *std.Io.Writer) std.Io.Writer.Error!void,
    ) InterfaceEntry {
        return entry(vtableFor(print));
    }
};

pub const TypeVerifyInterface = struct {
    pub const interface_name = "ir.interface.type_verify";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        verify: *const fn (type_ptr: *const anyopaque) anyerror!void,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(comptime verify: *const fn (type_ptr: *const anyopaque) anyerror!void) *const VTable {
        return &.{ .verify = verify };
    }

    pub fn entryFor(comptime verify: *const fn (type_ptr: *const anyopaque) anyerror!void) InterfaceEntry {
        return entry(vtableFor(verify));
    }
};

pub const TypeParamInterface = struct {
    pub const interface_name = "ir.interface.type_param";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        parse: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) anyerror!?TypeParamPayload,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(
        comptime parse: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) anyerror!?TypeParamPayload,
    ) *const VTable {
        return &.{ .parse = parse };
    }

    pub fn entryFor(
        comptime parse: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) anyerror!?TypeParamPayload,
    ) InterfaceEntry {
        return entry(vtableFor(parse));
    }
};

pub const ShapedTypeInterface = struct {
    pub const interface_name = "ir.interface.shaped_type";
    pub const id: InterfaceId = base.interfaceId(interface_name);

    pub const VTable = struct {
        getRank: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) ?usize,
        getShape: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) ?[]const u64,
        getElementType: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) ?IrType,
        getAddressSpaceTag: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) ?u8,
    };

    pub fn entry(vtable: *const VTable) InterfaceEntry {
        return .{ .id = id, .vtable = vtable };
    }

    pub fn vtableFor(
        comptime getRank: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) ?usize,
        comptime getShape: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) ?[]const u64,
        comptime getElementType: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) ?IrType,
        comptime getAddressSpaceTag: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) ?u8,
    ) *const VTable {
        return &.{
            .getRank = getRank,
            .getShape = getShape,
            .getElementType = getElementType,
            .getAddressSpaceTag = getAddressSpaceTag,
        };
    }

    pub fn entryFor(
        comptime getRank: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) ?usize,
        comptime getShape: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) ?[]const u64,
        comptime getElementType: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) ?IrType,
        comptime getAddressSpaceTag: *const fn (type_ptr: *const anyopaque, ctx: *const ContextOpaque) ?u8,
    ) InterfaceEntry {
        return entry(vtableFor(getRank, getShape, getElementType, getAddressSpaceTag));
    }
};

test "TypeRegistry basic usage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = TypeRegistry.init(allocator);
    defer registry.deinit();

    const info = try registry.registerType("dialect.foo");
    try testing.expectEqualStrings("dialect.foo", info.name);

    const iface_id = base.interfaceId("test.type_iface");
    const vtable_val: u8 = 7;
    try registry.registerInterface("dialect.foo", .{ .id = iface_id, .vtable = &vtable_val });

    const lookup = registry.lookup("dialect.foo").?;
    try testing.expect(lookup.hasInterface(iface_id));
    try testing.expectEqual(@as(*const u8, &vtable_val), @as(*const u8, @ptrCast(lookup.getInterface(iface_id).?)));
}

test "TypeRegistry co-owns each header and name in one allocation" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var registry = TypeRegistry.init(failing.allocator());
    defer registry.deinit();
    try registry.types.ensureTotalCapacity(failing.allocator(), 1);

    const before = failing.alloc_index;
    const expected = std.math.add(usize, before, 1) catch unreachable;
    const created = try registry.getOrCreateTracked("dialect.shared");
    try testing.expect(created.created);
    try testing.expectEqual(expected, failing.alloc_index);
    const name_address = std.math.add(
        usize,
        @intFromPtr(created.info),
        @sizeOf(TypeInfo),
    ) catch unreachable;
    try testing.expectEqual(name_address, @intFromPtr(created.info.name.ptr));

    const duplicate = try registry.getOrCreateTracked("dialect.shared");
    try testing.expect(!duplicate.created);
    try testing.expectEqual(created.info, duplicate.info);
    try testing.expectEqual(expected, failing.alloc_index);
    try testing.expect(registry.removeType("dialect.shared"));
    try testing.expectEqual(@as(usize, 0), registry.count());
}

test "TypeRegistry co-owns a named batch in one exact region" {
    const testing = std.testing;
    const Named = struct { name: []const u8 };
    const named = [_]Named{
        .{ .name = "dialect.existing" },
        .{ .name = "dialect.first" },
        .{ .name = "dialect.second" },
    };

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var registry = TypeRegistry.init(failing.allocator());
    defer registry.deinit();

    const existing = try registry.getOrCreate("dialect.existing");
    try registry.types.ensureTotalCapacity(failing.allocator(), 3);

    const expected_bytes = try registry_entry.BatchStorage(TypeInfo).capacity(
        2,
        "dialect.first".len + "dialect.second".len,
    );
    const before = failing.alloc_index;
    const before_allocated = failing.allocated_bytes;
    try registry.getOrCreateNamedBatch(&named);
    try testing.expectEqual(before + 1, failing.alloc_index);
    try testing.expectEqual(before_allocated + expected_bytes, failing.allocated_bytes);
    try testing.expectEqual(@as(usize, 3), registry.count());
    try testing.expectEqual(existing, registry.lookup("dialect.existing").?);

    const first = registry.lookup("dialect.first").?;
    const second = registry.lookup("dialect.second").?;
    try testing.expectEqual(@intFromPtr(first) + @sizeOf(TypeInfo), @intFromPtr(second));
    try testing.expectEqualStrings("dialect.first", first.name);
    try testing.expectEqualStrings("dialect.second", second.name);
    try testing.expect(registry.batch_regions != null);
    try testing.expect(registry.batch_regions.?.next == null);

    const before_duplicate = failing.alloc_index;
    try registry.getOrCreateNamedBatch(&named);
    try testing.expectEqual(before_duplicate, failing.alloc_index);
    try testing.expectEqual(first, registry.lookup("dialect.first").?);
    try testing.expectEqual(second, registry.lookup("dialect.second").?);
}

test "TypeRegistry named batch preserves duplicate registration semantics" {
    const testing = std.testing;
    const Named = struct { name: []const u8 };
    const named = [_]Named{
        .{ .name = "dialect.duplicate" },
        .{ .name = "dialect.duplicate" },
    };

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var registry = TypeRegistry.init(failing.allocator());
    defer registry.deinit();
    try registry.types.ensureTotalCapacity(failing.allocator(), 2);

    const expected_bytes = try registry_entry.BatchStorage(TypeInfo).capacity(
        2,
        2 * "dialect.duplicate".len,
    );
    const before = failing.alloc_index;
    const before_allocated = failing.allocated_bytes;
    try registry.getOrCreateNamedBatch(&named);
    try testing.expectEqual(before + 1, failing.alloc_index);
    try testing.expectEqual(before_allocated + expected_bytes, failing.allocated_bytes);
    try testing.expectEqual(@as(usize, 1), registry.count());
    try testing.expectEqualStrings("dialect.duplicate", registry.lookup("dialect.duplicate").?.name);
    try testing.expect(registry.removeType("dialect.duplicate"));
    try testing.expect(registry.batch_regions == null);
}

test "TypeRegistry named batch preserves state across allocation failures" {
    const testing = std.testing;
    const Named = struct { name: []const u8 };
    const named = [_]Named{
        .{ .name = "dialect.first" },
        .{ .name = "dialect.second" },
    };

    for ([_]usize{ 0, 1 }) |fail_index| {
        var failing = testing.FailingAllocator.init(
            testing.allocator,
            .{ .fail_index = fail_index },
        );
        var registry = TypeRegistry.init(failing.allocator());
        defer registry.deinit();

        try testing.expectError(error.OutOfMemory, registry.getOrCreateNamedBatch(&named));
        try testing.expectEqual(@as(usize, 0), registry.count());
        try testing.expect(registry.batch_regions == null);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);

        failing.fail_index = std.math.maxInt(usize);
        try registry.getOrCreateNamedBatch(&named);
        try testing.expectEqual(@as(usize, 2), registry.count());
        try testing.expect(registry.lookup("dialect.first") != null);
        try testing.expect(registry.lookup("dialect.second") != null);
    }
}

test "TypeRegistry releases a batch after its last removal" {
    const testing = std.testing;
    const Named = struct { name: []const u8 };
    const named = [_]Named{
        .{ .name = "dialect.first" },
        .{ .name = "dialect.second" },
    };

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var registry = TypeRegistry.init(failing.allocator());
    defer registry.deinit();

    const individual = try registry.getOrCreate("external.type");
    try registry.getOrCreateNamedBatch(&named);
    const vtable: u8 = 1;
    try registry.registerInterface("dialect.first", .{ .id = 1, .vtable = &vtable });
    const region_bytes = registry.batch_regions.?.total_bytes;
    const before_freed = failing.freed_bytes;

    try testing.expect(registry.removeType("dialect.first"));
    try testing.expect(registry.batch_regions != null);
    try testing.expect(failing.freed_bytes > before_freed);
    const freed_after_first = failing.freed_bytes;
    try testing.expectEqual(individual, registry.lookup("external.type").?);

    try testing.expect(registry.removeType("dialect.second"));
    try testing.expect(registry.batch_regions == null);
    try testing.expectEqual(freed_after_first + region_bytes, failing.freed_bytes);
    try testing.expectEqual(individual, registry.lookup("external.type").?);
    try testing.expect(registry.removeType("external.type"));
    try testing.expectEqual(@as(usize, 0), registry.count());
}

test "TypeRegistry cleans a shared entry when map growth fails" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 1 },
    );
    var registry = TypeRegistry.init(failing.allocator());
    defer registry.deinit();

    try testing.expectError(error.OutOfMemory, registry.getOrCreate("dialect.retry"));
    try testing.expectEqual(@as(usize, 0), registry.count());

    failing.fail_index = std.math.maxInt(usize);
    const info = try registry.getOrCreate("dialect.retry");
    try testing.expectEqualStrings("dialect.retry", info.name);
    try testing.expectEqual(@as(usize, 1), registry.count());
}

test "TypeRegistry stable pointers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = TypeRegistry.init(allocator);
    defer registry.deinit();

    const info1 = try registry.getOrCreate("dialect.ty0");
    const ptr1 = info1;

    for (0..100) |i| {
        var buf: [32]u8 = undefined;
        var pos: usize = 0;
        pos = try format.appendFmt(buf[0..], pos, "dialect.ty{d}", .{i});
        const name = buf[0..pos];
        _ = try registry.getOrCreate(name);
    }

    try testing.expectEqual(ptr1, registry.lookup("dialect.ty0").?);
    try testing.expectEqualStrings("dialect.ty0", ptr1.name);
}

test "TypePrintInterface stable ID" {
    const testing = std.testing;

    const id1 = TypePrintInterface.id;
    const id2 = base.interfaceId(TypePrintInterface.interface_name);
    try testing.expectEqual(id1, id2);

    try testing.expect(TypePrintInterface.id != base.interfaceId("ir.interface.evaluatable"));
}

test "TypeVerifyInterface stable ID" {
    const testing = std.testing;

    const id1 = TypeVerifyInterface.id;
    const id2 = base.interfaceId(TypeVerifyInterface.interface_name);
    try testing.expectEqual(id1, id2);

    try testing.expect(TypeVerifyInterface.id != TypePrintInterface.id);
}

test "TypeParamInterface stable ID" {
    const testing = std.testing;

    const id1 = TypeParamInterface.id;
    const id2 = base.interfaceId(TypeParamInterface.interface_name);
    try testing.expectEqual(id1, id2);

    try testing.expect(TypeParamInterface.id != TypeVerifyInterface.id);
}

test "ShapedTypeInterface stable ID" {
    const testing = std.testing;

    const id1 = ShapedTypeInterface.id;
    const id2 = base.interfaceId(ShapedTypeInterface.interface_name);
    try testing.expectEqual(id1, id2);

    try testing.expect(ShapedTypeInterface.id != TypeParamInterface.id);
}
