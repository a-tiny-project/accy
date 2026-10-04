const std = @import("std");
const registry_entry = @import("entry.zig");

pub const TraitId = u64;

pub fn traitId(comptime name: []const u8) TraitId {
    return std.hash.Wyhash.hash(0, name);
}

pub fn traitIdRuntime(name: []const u8) TraitId {
    return std.hash.Wyhash.hash(0, name);
}

pub const TraitVTable = struct {
    verify: ?*const fn (op_ptr: *const anyopaque) anyerror!void = null,
    verify_regions: ?*const fn (op_ptr: *const anyopaque) anyerror!void = null,
};

pub const TraitEntry = struct {
    id: TraitId,
    vtable: *const TraitVTable,
};

pub const TraitIds = struct {
    pub const inline_capacity: usize = 4;

    const Storage = registry_entry.InlineList(TraitId, inline_capacity);

    storage: Storage = .{},

    pub const InsertError = error{DuplicateTrait} || std.mem.Allocator.Error;

    pub fn initInline(storage: *[inline_capacity]TraitId) TraitIds {
        return .{ .storage = Storage.initInline(storage) };
    }

    pub fn deinit(self: *TraitIds, allocator: std.mem.Allocator) void {
        self.storage.deinit(allocator);
    }

    pub fn insert(
        self: *TraitIds,
        allocator: std.mem.Allocator,
        id: TraitId,
    ) InsertError!void {
        if (self.contains(id)) return error.DuplicateTrait;
        try self.storage.append(allocator, id);
        std.mem.sort(TraitId, self.storage.valuesMut(), {}, lessThan);
    }

    pub fn values(self: *const TraitIds) []const TraitId {
        return self.storage.values();
    }

    pub fn contains(self: *const TraitIds, id: TraitId) bool {
        const sorted = self.values();
        var left: usize = 0;
        var right = sorted.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (sorted[mid] == id) return true;
            if (sorted[mid] < id) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return false;
    }

    fn lessThan(_: void, a: TraitId, b: TraitId) bool {
        return a < b;
    }
};

pub const TraitRegistry = struct {
    traits: std.AutoHashMapUnmanaged(TraitId, *const TraitVTable),

    pub const RegisterError = error{DuplicateTrait} || std.mem.Allocator.Error;

    pub fn init() TraitRegistry {
        return .{ .traits = .{} };
    }

    pub fn deinit(self: *TraitRegistry, allocator: std.mem.Allocator) void {
        self.traits.deinit(allocator);
    }

    pub fn register(
        self: *TraitRegistry,
        allocator: std.mem.Allocator,
        entry: TraitEntry,
    ) RegisterError!void {
        const gop = try self.traits.getOrPut(allocator, entry.id);
        if (gop.found_existing) return error.DuplicateTrait;
        gop.value_ptr.* = entry.vtable;
    }

    pub fn lookup(self: *const TraitRegistry, id: TraitId) ?*const TraitVTable {
        return self.traits.get(id);
    }

    pub fn count(self: *const TraitRegistry) usize {
        return self.traits.count();
    }
};

pub const OperationTraits = packed struct(u64) {
    is_terminator: bool = false,
    is_commutative: bool = false,
    is_idempotent: bool = false,
    is_involution: bool = false,
    is_symbol_table: bool = false,
    has_no_terminator: bool = false,
    has_only_graph_regions: bool = false,
    _padding: u57 = 0,

    pub fn merge(a: OperationTraits, b: OperationTraits) OperationTraits {
        return .{
            .is_terminator = a.is_terminator or b.is_terminator,
            .is_commutative = a.is_commutative or b.is_commutative,
            .is_idempotent = a.is_idempotent or b.is_idempotent,
            .is_involution = a.is_involution or b.is_involution,
            .is_symbol_table = a.is_symbol_table or b.is_symbol_table,
            .has_no_terminator = a.has_no_terminator or b.has_no_terminator,
            .has_only_graph_regions = a.has_only_graph_regions or b.has_only_graph_regions,
        };
    }
};

test "traitId produces stable hashes" {
    const testing = std.testing;

    const id1 = traitId("ir.trait.idempotent");
    const id2 = traitId("ir.trait.idempotent");
    const id3 = traitId("ir.trait.terminator");

    try testing.expectEqual(id1, id2);
    try testing.expect(id1 != id3);

    const runtime_id = traitIdRuntime("ir.trait.idempotent");
    try testing.expectEqual(id1, runtime_id);
}

test "OperationTraits merge" {
    const testing = std.testing;

    const a = OperationTraits{ .is_idempotent = true };
    const b = OperationTraits{
        .is_terminator = true,
        .is_symbol_table = true,
        .has_no_terminator = true,
        .has_only_graph_regions = true,
    };
    const merged = OperationTraits.merge(a, b);

    try testing.expect(merged.is_idempotent);
    try testing.expect(merged.is_terminator);
    try testing.expect(merged.is_symbol_table);
    try testing.expect(merged.has_no_terminator);
    try testing.expect(merged.has_only_graph_regions);
    try testing.expect(!merged.is_commutative);
}

test "OperationTraits packed size" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 8), @sizeOf(OperationTraits));
}

test "TraitIds keeps four sorted IDs inline and spills transactionally" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 24), @sizeOf(TraitIds));

    var failing = testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    var inline_storage: [TraitIds.inline_capacity]TraitId = undefined;
    var ids = TraitIds.initInline(&inline_storage);
    defer ids.deinit(failing.allocator());

    try ids.insert(failing.allocator(), 40);
    try ids.insert(failing.allocator(), 10);
    try ids.insert(failing.allocator(), 30);
    try ids.insert(failing.allocator(), 20);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expectEqualSlices(TraitId, &.{ 10, 20, 30, 40 }, ids.values());
    try testing.expectError(error.DuplicateTrait, ids.insert(failing.allocator(), 20));
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);

    try testing.expectError(error.OutOfMemory, ids.insert(failing.allocator(), 50));
    try testing.expectEqualSlices(TraitId, &.{ 10, 20, 30, 40 }, ids.values());
    try testing.expect(!ids.contains(50));

    failing.fail_index = std.math.maxInt(usize);
    const before_allocated = failing.allocated_bytes;
    try ids.insert(failing.allocator(), 50);
    try testing.expectEqualSlices(TraitId, &.{ 10, 20, 30, 40, 50 }, ids.values());
    try testing.expectEqual(
        std.math.add(usize, before_allocated, 5 * @sizeOf(TraitId)) catch unreachable,
        failing.allocated_bytes,
    );
}

test "TraitRegistry register and lookup" {
    const testing = std.testing;

    var registry = TraitRegistry.init();
    defer registry.deinit(testing.allocator);

    const vtable: TraitVTable = .{ .verify = null };
    const id = traitId("ir.trait.test");
    const entry = TraitEntry{ .id = id, .vtable = &vtable };

    try registry.register(testing.allocator, entry);
    try testing.expectEqual(@as(usize, 1), registry.count());
    try testing.expectEqual(@as(?*const TraitVTable, &vtable), registry.lookup(id));

    try testing.expectError(
        error.DuplicateTrait,
        registry.register(testing.allocator, entry),
    );
}
