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
