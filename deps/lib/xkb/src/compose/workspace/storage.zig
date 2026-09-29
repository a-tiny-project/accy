const std = @import("std");
const alloc_phase = @import("alloc_phase");
const capacity_mod = @import("capacity.zig");

pub const StorageExhaustion = error{
    ComposeScratchInUse,
    LineByteCapacityExceeded,
    PathByteCapacityExceeded,
};

pub const Status = struct {
    phase: alloc_phase.capacity.Phase,
    in_use: bool,
    storage_bytes: usize,
    line_bytes: usize,
    path_bytes: usize,
};

pub const Storage = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: capacity_mod.Capacity,
    bytes: []u8,
    lines: []u8,
    paths: []u8,
    in_use: bool = false,

    pub const Limits: type = capacity_mod.Limits;
    pub const Capacity: type = capacity_mod.Capacity;
    pub const Exhaustion: type = StorageExhaustion;
    pub const InitError = std.mem.Allocator.Error || capacity_mod.DeriveError;
    pub const AcquireError = Storage.Exhaustion;

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "xkb.compose_scratch_storage",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "recursive_compose_and_registry_line_input",
                        .lifetime = .steady,
                        .detail = "recursive Compose and registry line input",
                    },
                    .{
                        .id = "compose_discovery_and_include_paths",
                        .lifetime = .steady,
                        .detail = "Compose discovery and include paths",
                    },
                },
                .excluded = &.{
                    "caller-owned root Compose input bytes",
                    "Compose trie and result storage",
                    "diagnostic callbacks, operating-system file handles, and teardown storage",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "line_bytes", "line_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "path_bytes", "path_bytes"),
                },
                .type_selectors = &.{},
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .constant = 1 },
                    .{ .add = .{ .left = 0, .right = 1 } },
                    .{ .scale = .{ .node = 2, .coefficient = .{ .literal = 7 } } },
                    .{ .input = 1 },
                    .{ .scale = .{ .node = 4, .coefficient = .{ .literal = 8 } } },
                    .{ .add = .{ .left = 3, .right = 5 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 6,
                }},
            },
            .overload = .{
                .kind = .terminal,
                .detail = "Line or path overload terminates compilation and resets private scratch and table state.",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "File, registry, locale, include, and path processing use only fixed scratch slots after activation.",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "filesystem handles and platform I/O internals remain foreign initialization effects",
                },
            },
            .obligations = &.{
                .{ .key = "xkb_compose_scratch_capacity", .role = .capacity_model },
                .{ .key = "xkb_compose_scratch_acquisition", .role = .custom },
                .{ .key = "xkb_compose_scratch_oom", .role = .custom },
                .{ .key = "xkb_compose_scratch_boundaries", .role = .overload },
                .{ .key = "xkb_compose_scratch_reuse", .role = .overload },
                .{ .key = "xkb_compose_scratch_depth", .role = .overload },
                .{ .key = "xkb_compose_scratch_sealed", .role = .transitive_risk },
                .{ .key = "xkb_compose_scratch_root", .role = .custom },
                .{ .key = "xkb_compose_scratch_consumer", .role = .foreign_risk },
                .{ .key = "xkb_compose_scratch_windowing_root", .role = .custom },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    pub fn init(allocator: std.mem.Allocator, limits: Limits) InitError!Storage {
        const capacity = try Capacity.derive(limits);
        const bytes = try allocator.alloc(u8, capacity.storage_bytes);
        return .{
            .phase = .initialization,
            .capacity = capacity,
            .bytes = bytes,
            .lines = bytes[capacity.line_offset..][0..capacity.line_storage_bytes],
            .paths = bytes[capacity.path_offset..][0..capacity.path_storage_bytes],
        };
    }

    pub fn activate(self: *Storage) void {
        std.debug.assert(self.phase == .initialization);
        std.debug.assert(self.bytes.len == self.capacity.storage_bytes);
        self.phase = .steady;
    }

    pub fn acquire(self: *Storage) Storage.Exhaustion!void {
        std.debug.assert(self.phase == .steady);
        if (self.in_use) return error.ComposeScratchInUse;
        self.in_use = true;
    }

    pub fn reset(self: *Storage) void {
        std.debug.assert(self.phase == .steady);
        std.debug.assert(self.in_use);
        self.in_use = false;
    }

    pub fn fileLine(self: *Storage, depth: usize) []u8 {
        std.debug.assert(self.in_use);
        std.debug.assert(depth < capacity_mod.file_line_slot_count);
        return self.lineSlot(depth);
    }

    pub fn registryLine(self: *Storage) []u8 {
        std.debug.assert(self.in_use);
        return self.lineSlot(capacity_mod.registry_line_slot_index);
    }

    pub fn filePath(self: *Storage, depth: usize) []u8 {
        std.debug.assert(self.in_use);
        std.debug.assert(depth < capacity_mod.file_path_slot_count);
        return self.pathSlot(depth);
    }

    pub fn auxiliaryPath(self: *Storage, index: usize) []u8 {
        std.debug.assert(self.in_use);
        std.debug.assert(index < capacity_mod.auxiliary_path_slot_count);
        return self.pathSlot(capacity_mod.file_path_slot_count + index);
    }

    pub fn lineLimit(self: *const Storage) usize {
        return self.capacity.limits.line_bytes;
    }

    pub fn status(self: *const Storage) Status {
        return .{
            .phase = self.phase,
            .in_use = self.in_use,
            .storage_bytes = self.capacity.storage_bytes,
            .line_bytes = self.capacity.limits.line_bytes,
            .path_bytes = self.capacity.limits.path_bytes,
        };
    }

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        std.debug.assert(self.phase != .teardown);
        std.debug.assert(!self.in_use);
        std.debug.assert(self.bytes.len == self.capacity.storage_bytes);
        self.phase = .teardown;
        allocator.free(self.bytes);
        self.bytes = &.{};
        self.lines = &.{};
        self.paths = &.{};
    }

    fn lineSlot(self: *Storage, index: usize) []u8 {
        const width = self.capacity.line_bytes_per_slot;
        const start = index * width;
        return self.lines[start..][0..width];
    }

    fn pathSlot(self: *Storage, index: usize) []u8 {
        const width = self.capacity.limits.path_bytes;
        const start = index * width;
        return self.paths[start..][0..width];
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorRejectingOwnerShape(Storage);
}

fn checkInitFailures(allocator: std.mem.Allocator) !void {
    var storage = try Storage.init(allocator, capacity_mod.default_limits);
    storage.deinit(allocator);
}

test "Compose scratch storage acquires one exact region" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "xkb_compose_scratch_acquisition"),
        );
    }

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const capacity = try capacity_mod.Capacity.derive(capacity_mod.default_limits);
    var storage = try Storage.init(counting.allocator(), capacity_mod.default_limits);
    defer storage.deinit(counting.allocator());
    try std.testing.expectEqual(@as(usize, 1), counting.alloc_index);
    try std.testing.expectEqual(capacity.storage_bytes, counting.allocated_bytes);
    storage.activate();
    try storage.acquire();
    defer storage.reset();
    const base = @intFromPtr(storage.bytes.ptr);
    try std.testing.expectEqual(base + capacity.line_offset, @intFromPtr(storage.lines.ptr));
    try std.testing.expectEqual(base + capacity.path_offset, @intFromPtr(storage.paths.ptr));
}

test "Compose scratch storage retries after every allocation failure" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "xkb_compose_scratch_oom"),
        );
    }

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkInitFailures,
        .{},
    );
}
