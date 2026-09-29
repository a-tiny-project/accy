const std = @import("std");
const alloc_phase = @import("alloc_phase");
const capacity_mod = @import("capacity.zig");
const model = @import("model.zig");

pub const Regions = struct {
    sorted: []u64,
    means: []f64,
    medians: []f64,
    p75s: []f64,
    p95s: []f64,
    p99s: []f64,
    counts: []u32,
};

pub const Status = struct {
    phase: alloc_phase.capacity.Phase,
    in_use: bool,
    storage_bytes: usize,
    samples: usize,
    bootstrap_iterations: u32,
};

pub const Storage = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: capacity_mod.Capacity,
    bytes: []align(capacity_mod.storage_alignment) u8,
    sorted: []u64,
    means: []f64,
    medians: []f64,
    p75s: []f64,
    p95s: []f64,
    p99s: []f64,
    counts: []u32,
    in_use: bool = false,

    pub const Limits: type = capacity_mod.Limits;
    pub const Capacity: type = capacity_mod.Capacity;
    pub const Exhaustion: type = model.Exhaustion;
    pub const InitError = std.mem.Allocator.Error || capacity_mod.DeriveError;
    pub const AcquireError: type = model.ComputeError;

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "bench.statistics_storage",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "sorted_sample_scratch",
                        .lifetime = .steady,
                        .detail = "sorted sample scratch",
                    },
                    .{
                        .id = "bootstrap_distribution_scratch",
                        .lifetime = .steady,
                        .detail = "bootstrap distribution scratch",
                    },
                    .{
                        .id = "bootstrap_multiplicity_scratch",
                        .lifetime = .steady,
                        .detail = "bootstrap multiplicity scratch",
                    },
                },
                .excluded = &.{
                    "caller-owned input samples",
                    "caller-owned benchmark result retention",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "samples", "samples"),
                    alloc_phase.capacity.bindInput(Limits, "bootstrap_iterations", "bootstrap_iterations"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(u64, "u64"),
                    alloc_phase.capacity.bindType(f64, "f64"),
                    alloc_phase.capacity.bindType(u32, "u32"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .input = 1 },
                    .{ .scale = .{ .node = 2, .coefficient = .{ .literal = 5 } } },
                    .{ .scale = .{ .node = 3, .coefficient = .{ .size_of_concrete_type = 1 } } },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 2 } } },
                    .{ .add = .{ .left = 1, .right = 4 } },
                    .{ .add = .{ .left = 6, .right = 5 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 7,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "empty, oversize, invalid confidence, and concurrent requests fail before workspace mutation",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "sorting and bootstrap sampling use only slices acquired from the sealed region",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "statistics calculation crosses no operating-system or foreign callback boundary",
                },
            },
            .obligations = &.{
                .{ .key = "bench_statistics_capacity", .role = .capacity_model },
                .{ .key = "bench_statistics_acquisition", .role = .custom },
                .{ .key = "bench_statistics_oom", .role = .custom },
                .{ .key = "bench_statistics_boundaries", .role = .overload },
                .{ .key = "bench_statistics_reuse", .role = .overload },
                .{ .key = "bench_statistics_sealed_transitive_risk", .role = .transitive_risk },
                .{ .key = "bench_statistics_sealed_foreign_risk", .role = .foreign_risk },
                .{ .key = "bench_statistics_sets", .role = .custom },
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
            .sorted = typedSlice(u64, bytes, capacity.sorted_offset, limits.samples),
            .means = typedSlice(f64, bytes, capacity.means_offset, limits.bootstrap_iterations),
            .medians = typedSlice(f64, bytes, capacity.medians_offset, limits.bootstrap_iterations),
            .p75s = typedSlice(f64, bytes, capacity.p75s_offset, limits.bootstrap_iterations),
            .p95s = typedSlice(f64, bytes, capacity.p95s_offset, limits.bootstrap_iterations),
            .p99s = typedSlice(f64, bytes, capacity.p99s_offset, limits.bootstrap_iterations),
            .counts = typedSlice(u32, bytes, capacity.counts_offset, limits.samples),
        };
    }

    pub fn activate(self: *Storage) void {
        std.debug.assert(self.phase == .initialization);
        std.debug.assert(self.bytes.len == self.capacity.storage_bytes);
        self.phase = .steady;
    }

    pub fn acquire(
        self: *Storage,
        samples: usize,
        bootstrap: model.BootstrapConfig,
    ) AcquireError!Regions {
        std.debug.assert(self.phase == .steady);
        if (self.in_use) return error.StatisticsStorageInUse;
        if (samples == 0) return error.EmptySampleSet;
        if (samples > self.capacity.limits.samples) return error.SampleCapacityExceeded;
        if (bootstrap.iterations > self.capacity.limits.bootstrap_iterations) {
            return error.BootstrapIterationCapacityExceeded;
        }
        if (bootstrap.iterations > 0 and
            (bootstrap.confidence_per_mille == 0 or bootstrap.confidence_per_mille > 1000))
        {
            return error.InvalidBootstrapConfidence;
        }
        self.in_use = true;
        return .{
            .sorted = self.sorted[0..samples],
            .means = self.means[0..bootstrap.iterations],
            .medians = self.medians[0..bootstrap.iterations],
            .p75s = self.p75s[0..bootstrap.iterations],
            .p95s = self.p95s[0..bootstrap.iterations],
            .p99s = self.p99s[0..bootstrap.iterations],
            .counts = self.counts[0..samples],
        };
    }

    pub fn reset(self: *Storage) void {
        std.debug.assert(self.phase == .steady);
        std.debug.assert(self.in_use);
        self.in_use = false;
    }

    pub fn status(self: *const Storage) Status {
        return .{
            .phase = self.phase,
            .in_use = self.in_use,
            .storage_bytes = self.capacity.storage_bytes,
            .samples = self.capacity.limits.samples,
            .bootstrap_iterations = self.capacity.limits.bootstrap_iterations,
        };
    }

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        std.debug.assert(self.phase != .teardown);
        std.debug.assert(!self.in_use);
        std.debug.assert(self.bytes.len == self.capacity.storage_bytes);
        self.phase = .teardown;
        allocator.free(self.bytes);
        self.bytes = &.{};
        self.sorted = &.{};
        self.means = &.{};
        self.medians = &.{};
        self.p75s = &.{};
        self.p95s = &.{};
        self.p99s = &.{};
        self.counts = &.{};
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
    var storage = try Storage.init(allocator, .{ .samples = 13, .bootstrap_iterations = 1000 });
    storage.deinit(allocator);
}

test "statistics storage acquires one exact region" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "bench_statistics_acquisition"),
        );
    }

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const limits = capacity_mod.Limits{ .samples = 13, .bootstrap_iterations = 1000 };
    const capacity = try capacity_mod.Capacity.derive(limits);
    var storage = try Storage.init(failing.allocator(), limits);
    defer storage.deinit(failing.allocator());

    try std.testing.expectEqual(@as(usize, 1), failing.alloc_index);
    try std.testing.expectEqual(capacity.storage_bytes, failing.allocated_bytes);
    try std.testing.expectEqual(alloc_phase.capacity.Phase.initialization, storage.status().phase);
    storage.activate();
    const regions = try storage.acquire(13, .{});
    defer storage.reset();
    const base = @intFromPtr(storage.bytes.ptr);
    try std.testing.expectEqual(base + capacity.sorted_offset, @intFromPtr(regions.sorted.ptr));
    try std.testing.expectEqual(base + capacity.means_offset, @intFromPtr(regions.means.ptr));
    try std.testing.expectEqual(base + capacity.counts_offset, @intFromPtr(regions.counts.ptr));
}

test "statistics storage retries after every allocation failure" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(Storage, "bench_statistics_oom"));
    }

    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInitFailures, .{});
}

comptime {
    alloc_phase.capacity.requireAllocatorRejectingOwnerShape(Storage);
}
