const std = @import("std");
const alloc_phase = @import("alloc_phase");
const capacity_mod = @import("capacity.zig");
const model = @import("model.zig");

pub const Exhaustion = error{CensusStorageInUse};

pub const Regions = struct {
    slots: []model.Slot,
    summary: []model.Entry,
    labels: []u8,
    joined_label: []u8,
};

pub const Status = struct {
    phase: alloc_phase.capacity.Phase,
    in_use: bool,
    storage_bytes: usize,
    category_capacity: usize,
    table_slots: usize,
    label_bytes_capacity: usize,
    joined_label_bytes_capacity: usize,
};

pub const Storage = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: capacity_mod.Capacity,
    bytes: []align(capacity_mod.storage_alignment) u8,
    slots: []model.Slot,
    summary: []model.Entry,
    labels: []u8,
    joined_label: []u8,
    in_use: bool = false,

    pub const Limits: type = capacity_mod.Limits;
    pub const Capacity: type = capacity_mod.Capacity;
    pub const Exhaustion: type = @import("storage.zig").Exhaustion;
    pub const InitError = std.mem.Allocator.Error || capacity_mod.DeriveError;

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "memtrace.census_storage",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "bounded_census_category_hash_table",
                        .lifetime = .steady,
                        .detail = "bounded census category hash table",
                    },
                    .{
                        .id = "retained_category_label_bytes",
                        .lifetime = .steady,
                        .detail = "retained category label bytes",
                    },
                    .{
                        .id = "prefixed_label_join_scratch",
                        .lifetime = .steady,
                        .detail = "prefixed-label join scratch",
                    },
                    .{
                        .id = "sorted_summary_entry_scratch",
                        .lifetime = .steady,
                        .detail = "sorted summary entry scratch",
                    },
                },
                .excluded = &.{
                    "the caller-owned output writer and its storage",
                    "allocation events and tracer state outside the semantic census",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "categories", "categories"),
                    alloc_phase.capacity.bindInput(Limits, "label_bytes", "label_bytes"),
                    alloc_phase.capacity.bindInput(Limits, "joined_label_bytes", "joined_label_bytes"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(model.Slot, "slot"),
                    alloc_phase.capacity.bindType(model.Entry, "entry"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .literal = 2 } } },
                    .{ .next_power_of_two = 1 },
                    .{ .scale = .{ .node = 2, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .alignment = .{ .node = 3, .alignment = .{ .literal = 16 } } },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 1 } } },
                    .{ .alignment = .{ .node = 5, .alignment = .{ .literal = 16 } } },
                    .{ .input = 1 },
                    .{ .input = 2 },
                    .{ .add = .{ .left = 4, .right = 6 } },
                    .{ .add = .{ .left = 9, .right = 7 } },
                    .{ .add = .{ .left = 10, .right = 8 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 11,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "named category, retained-label, joined-label, and counter exhaustion leaves aggregate entries unchanged",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "recording, prefix joins, summary sorting, and JSONL emission use only the acquired census regions after activation",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "writer effects and writer-owned buffering remain outside Census storage",
                },
            },
            .obligations = &.{
                .{ .key = "memtrace_census_capacity", .role = .capacity_model },
                .{ .key = "memtrace_census_acquisition", .role = .custom },
                .{ .key = "memtrace_census_oom", .role = .custom },
                .{ .key = "memtrace_census_boundary", .role = .overload },
                .{ .key = "memtrace_census_overflow", .role = .overload },
                .{ .key = "memtrace_census_reuse", .role = .overload },
                .{ .key = "memtrace_census_sealed", .role = .transitive_risk },
                .{ .key = "memtrace_census_output", .role = .foreign_risk },
                .{ .key = "memtrace_census_root", .role = .custom },
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
        const bytes = try allocator.alignedAlloc(
            u8,
            .fromByteUnits(capacity_mod.storage_alignment),
            capacity.storage_bytes,
        );
        return .{
            .phase = .initialization,
            .capacity = capacity,
            .bytes = bytes,
            .slots = typedSlice(model.Slot, bytes, capacity.table_offset, capacity.table_slots),
            .summary = typedSlice(model.Entry, bytes, capacity.summary_offset, capacity.summary_entries),
            .labels = bytes[capacity.label_offset..][0..capacity.label_bytes],
            .joined_label = bytes[capacity.joined_label_offset..][0..capacity.joined_label_bytes],
        };
    }

    pub fn activate(self: *Storage) void {
        std.debug.assert(self.phase == .initialization);
        std.debug.assert(self.bytes.len == self.capacity.storage_bytes);
        self.phase = .steady;
    }

    pub fn acquire(self: *Storage) Storage.Exhaustion!Regions {
        std.debug.assert(self.phase == .steady);
        if (self.in_use) return error.CensusStorageInUse;
        @memset(self.slots, .{});
        self.in_use = true;
        return .{
            .slots = self.slots,
            .summary = self.summary,
            .labels = self.labels,
            .joined_label = self.joined_label,
        };
    }

    pub fn release(self: *Storage) void {
        std.debug.assert(self.phase == .steady);
        std.debug.assert(self.in_use);
        self.in_use = false;
    }

    pub fn status(self: *const Storage) Status {
        return .{
            .phase = self.phase,
            .in_use = self.in_use,
            .storage_bytes = self.capacity.storage_bytes,
            .category_capacity = self.capacity.categories,
            .table_slots = self.capacity.table_slots,
            .label_bytes_capacity = self.capacity.label_bytes,
            .joined_label_bytes_capacity = self.capacity.joined_label_bytes,
        };
    }

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        std.debug.assert(self.phase != .teardown);
        std.debug.assert(!self.in_use);
        std.debug.assert(self.bytes.len == self.capacity.storage_bytes);
        self.phase = .teardown;
        allocator.free(self.bytes);
        self.bytes = &.{};
        self.slots = &.{};
        self.summary = &.{};
        self.labels = &.{};
        self.joined_label = &.{};
    }
};

fn typedSlice(
    comptime T: type,
    bytes: []align(capacity_mod.storage_alignment) u8,
    offset: usize,
    count: usize,
) []T {
    const byte_count = count * @sizeOf(T);
    const region: []align(@alignOf(T)) u8 = @alignCast(bytes[offset..][0..byte_count]);
    return std.mem.bytesAsSlice(T, region);
}

fn checkInitFailures(allocator: std.mem.Allocator) !void {
    var storage = try Storage.init(allocator, .{
        .categories = 3,
        .label_bytes = 64,
        .joined_label_bytes = 31,
    });
    storage.deinit(allocator);
}

test "Census storage acquires one exact aligned region" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "memtrace_census_acquisition"),
        );
    }

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const capacity = try capacity_mod.Capacity.derive(.{
        .categories = 3,
        .label_bytes = 64,
        .joined_label_bytes = 31,
    });
    var storage = try Storage.init(counting.allocator(), .{
        .categories = 3,
        .label_bytes = 64,
        .joined_label_bytes = 31,
    });
    defer storage.deinit(counting.allocator());

    try std.testing.expectEqual(@as(usize, 1), counting.alloc_index);
    try std.testing.expectEqual(capacity.storage_bytes, counting.allocated_bytes);
    try std.testing.expectEqual(capacity.storage_bytes, storage.status().storage_bytes);
    try std.testing.expectEqual(alloc_phase.capacity.Phase.initialization, storage.status().phase);

    storage.activate();
    const regions = try storage.acquire();
    defer storage.release();
    const base = @intFromPtr(storage.bytes.ptr);
    try std.testing.expectEqual(base + capacity.table_offset, @intFromPtr(regions.slots.ptr));
    try std.testing.expectEqual(base + capacity.summary_offset, @intFromPtr(regions.summary.ptr));
    try std.testing.expectEqual(base + capacity.label_offset, @intFromPtr(regions.labels.ptr));
    try std.testing.expectEqual(base + capacity.joined_label_offset, @intFromPtr(regions.joined_label.ptr));
}

test "Census storage retries after every allocation failure" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(Storage, "memtrace_census_oom"));
    }

    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInitFailures, .{});
}

comptime {
    alloc_phase.capacity.requireAllocatorRejectingOwnerShape(Storage);
}
