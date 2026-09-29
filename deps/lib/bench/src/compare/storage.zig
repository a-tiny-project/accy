const std = @import("std");
const alloc_phase = @import("alloc_phase");
const capacity_mod = @import("capacity.zig");

const storage_exhaustion = error{
    BaseSampleCapacityExceeded,
    CandidateSampleCapacityExceeded,
    SampleCapacityExceeded,
    BootstrapIterationCapacityExceeded,
    ComparisonStorageInUse,
};

pub const Exhaustion = storage_exhaustion;

pub const InputError = error{
    EmptyBaseSeries,
    EmptyCandidateSeries,
    EmptySampleSet,
    InvalidBootstrapIterations,
};

pub const Error = Exhaustion || InputError;

pub const F64Regions = struct {
    effects: []f64,
    samples: []f64,
    counts: []u32,
};

pub const U64Regions = struct {
    effects: []f64,
    samples: []u64,
    counts: []u32,
};

pub const Status = struct {
    phase: alloc_phase.capacity.Phase,
    in_use: bool,
    storage_bytes: usize,
    max_samples_per_series: usize,
    max_bootstrap_iterations: u32,
};

pub const Storage = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: capacity_mod.Capacity,
    bytes: []align(capacity_mod.storage_alignment) u8,
    in_use: bool = false,

    pub const Limits: type = capacity_mod.Limits;
    pub const Capacity: type = capacity_mod.Capacity;
    pub const Exhaustion: type = storage_exhaustion;
    pub const InitError = std.mem.Allocator.Error || capacity_mod.DeriveError;
    pub const AcquireError: type = Error;

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "bench.comparison_storage",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "bootstrap_effect_distribution_scratch",
                        .lifetime = .steady,
                        .detail = "bootstrap effect distribution scratch",
                    },
                    .{
                        .id = "median_and_resampling_sample_scratch",
                        .lifetime = .steady,
                        .detail = "median and resampling sample scratch",
                    },
                    .{
                        .id = "bootstrap_multiplicity_scratch",
                        .lifetime = .steady,
                        .detail = "bootstrap multiplicity scratch",
                    },
                },
                .excluded = &.{
                    "caller-owned parsed comparison datasets",
                    "caller-owned comparison rows and report output",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "max_bootstrap_iterations", "max_bootstrap_iterations"),
                    alloc_phase.capacity.bindInput(Limits, "max_samples_per_series", "max_samples_per_series"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(f64, "f64"),
                    alloc_phase.capacity.bindType(u64, "u64"),
                    alloc_phase.capacity.bindType(u32, "u32"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .constant = 1 },
                    .{ .scale = .{ .node = 2, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .scale = .{ .node = 2, .coefficient = .{ .size_of_concrete_type = 1 } } },
                    .{ .maximum = .{ .left = 3, .right = 4 } },
                    .{ .scale = .{ .node = 2, .coefficient = .{ .size_of_concrete_type = 2 } } },
                    .{ .add = .{ .left = 5, .right = 6 } },
                    .{ .input = 1 },
                    .{ .product = .{ .left = 8, .right = 7 } },
                    .{ .add = .{ .left = 1, .right = 9 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 10,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "empty, zero-iteration, oversize, and concurrent requests fail before workspace mutation",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "f64 and u64 median sorting and bootstrap multiplicities use only slices acquired from the sealed region",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "comparison analysis crosses no operating-system or foreign callback boundary",
                },
            },
            .obligations = &.{
                .{ .key = "bench_comparison_capacity", .role = .capacity_model },
                .{ .key = "bench_comparison_acquisition", .role = .custom },
                .{ .key = "bench_comparison_oom", .role = .custom },
                .{ .key = "bench_comparison_boundaries", .role = .overload },
                .{ .key = "bench_comparison_reuse", .role = .overload },
                .{ .key = "bench_comparison_sealed_f64_transitive_risk", .role = .transitive_risk },
                .{ .key = "bench_comparison_sealed_f64_foreign_risk", .role = .foreign_risk },
                .{ .key = "bench_comparison_rows", .role = .custom },
                .{ .key = "bench_comparison_sealed_u64", .role = .transitive_risk },
                .{ .key = "bench_comparison_command", .role = .custom },
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
        };
    }

    pub fn activate(self: *Storage) void {
        std.debug.assert(self.phase == .initialization);
        std.debug.assert(self.bytes.len == self.capacity.storage_bytes);
        self.phase = .steady;
    }

    pub fn acquireF64(
        self: *Storage,
        base_samples: usize,
        candidate_samples: usize,
        bootstrap_iterations: u32,
    ) AcquireError!F64Regions {
        const sample_count = try self.beginComparison(
            base_samples,
            candidate_samples,
            bootstrap_iterations,
        );
        return .{
            .effects = typedSlice(
                f64,
                self.bytes,
                self.capacity.effects_offset,
                bootstrap_iterations,
            ),
            .samples = typedSlice(
                f64,
                self.bytes,
                self.capacity.samples_offset,
                sample_count,
            ),
            .counts = typedSlice(
                u32,
                self.bytes,
                self.capacity.counts_offset,
                sample_count,
            ),
        };
    }

    pub fn acquireU64(
        self: *Storage,
        base_samples: usize,
        candidate_samples: usize,
        bootstrap_iterations: u32,
    ) AcquireError!U64Regions {
        const sample_count = try self.beginComparison(
            base_samples,
            candidate_samples,
            bootstrap_iterations,
        );
        return .{
            .effects = typedSlice(
                f64,
                self.bytes,
                self.capacity.effects_offset,
                bootstrap_iterations,
            ),
            .samples = typedSlice(
                u64,
                self.bytes,
                self.capacity.samples_offset,
                sample_count,
            ),
            .counts = typedSlice(
                u32,
                self.bytes,
                self.capacity.counts_offset,
                sample_count,
            ),
        };
    }

    pub fn acquireF64Samples(self: *Storage, sample_count: usize) AcquireError![]f64 {
        std.debug.assert(self.phase == .steady);
        if (self.in_use) return error.ComparisonStorageInUse;
        if (sample_count == 0) return error.EmptySampleSet;
        if (sample_count > self.capacity.limits.max_samples_per_series) {
            return error.SampleCapacityExceeded;
        }
        self.in_use = true;
        return typedSlice(
            f64,
            self.bytes,
            self.capacity.samples_offset,
            sample_count,
        );
    }

    fn beginComparison(
        self: *Storage,
        base_samples: usize,
        candidate_samples: usize,
        bootstrap_iterations: u32,
    ) AcquireError!usize {
        std.debug.assert(self.phase == .steady);
        if (self.in_use) return error.ComparisonStorageInUse;
        if (base_samples == 0) return error.EmptyBaseSeries;
        if (candidate_samples == 0) return error.EmptyCandidateSeries;
        if (bootstrap_iterations == 0) return error.InvalidBootstrapIterations;
        if (base_samples > self.capacity.limits.max_samples_per_series) {
            return error.BaseSampleCapacityExceeded;
        }
        if (candidate_samples > self.capacity.limits.max_samples_per_series) {
            return error.CandidateSampleCapacityExceeded;
        }
        if (bootstrap_iterations > self.capacity.limits.max_bootstrap_iterations) {
            return error.BootstrapIterationCapacityExceeded;
        }
        self.in_use = true;
        return @max(base_samples, candidate_samples);
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
            .max_samples_per_series = self.capacity.limits.max_samples_per_series,
            .max_bootstrap_iterations = self.capacity.limits.max_bootstrap_iterations,
        };
    }

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        std.debug.assert(self.phase != .teardown);
        std.debug.assert(!self.in_use);
        std.debug.assert(self.bytes.len == self.capacity.storage_bytes);
        self.phase = .teardown;
        allocator.free(self.bytes);
        self.bytes = &.{};
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
        .max_samples_per_series = 8,
        .max_bootstrap_iterations = 500,
    });
    storage.deinit(allocator);
}

test "comparison storage acquires one exact region" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "bench_comparison_acquisition"),
        );
    }

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const limits = capacity_mod.Limits{
        .max_samples_per_series = 8,
        .max_bootstrap_iterations = 500,
    };
    const capacity = try capacity_mod.Capacity.derive(limits);
    var storage = try Storage.init(counting.allocator(), limits);
    defer storage.deinit(counting.allocator());

    try std.testing.expectEqual(@as(usize, 1), counting.alloc_index);
    try std.testing.expectEqual(capacity.storage_bytes, counting.allocated_bytes);
    try std.testing.expectEqual(alloc_phase.capacity.Phase.initialization, storage.status().phase);
    storage.activate();
    const f64_regions = try storage.acquireF64(8, 5, 500);
    const base = @intFromPtr(storage.bytes.ptr);
    try std.testing.expectEqual(
        base + capacity.effects_offset,
        @intFromPtr(f64_regions.effects.ptr),
    );
    try std.testing.expectEqual(
        base + capacity.samples_offset,
        @intFromPtr(f64_regions.samples.ptr),
    );
    try std.testing.expectEqual(
        base + capacity.counts_offset,
        @intFromPtr(f64_regions.counts.ptr),
    );
    storage.reset();
    const u64_regions = try storage.acquireU64(5, 8, 500);
    try std.testing.expectEqual(
        base + capacity.effects_offset,
        @intFromPtr(u64_regions.effects.ptr),
    );
    try std.testing.expectEqual(
        base + capacity.samples_offset,
        @intFromPtr(u64_regions.samples.ptr),
    );
    try std.testing.expectEqual(
        base + capacity.counts_offset,
        @intFromPtr(u64_regions.counts.ptr),
    );
    storage.reset();
}

test "comparison storage retries after every allocation failure" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(Storage, "bench_comparison_oom"));
    }

    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInitFailures, .{});
}

comptime {
    alloc_phase.capacity.requireAllocatorRejectingOwnerShape(Storage);
}
