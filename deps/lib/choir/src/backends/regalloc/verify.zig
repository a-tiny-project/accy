const std = @import("std");
const alloc_phase = @import("alloc_phase");
const ir = @import("../../core/root.zig");
const interval = @import("interval.zig");
const position = @import("position.zig");
const range = @import("range.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidAllocation,
};

const CapacityError = error{
    CapacityOverflow,
};

const CandidateIndex = struct {
    value: *ir.Value,
    index: usize,
};

fn candidateIndexLessThan(_: void, lhs: CandidateIndex, rhs: CandidateIndex) bool {
    return @intFromPtr(lhs.value) < @intFromPtr(rhs.value);
}

fn candidateIndexOrder(value: *ir.Value, entry: CandidateIndex) std.math.Order {
    return std.math.order(@intFromPtr(value), @intFromPtr(entry.value));
}

fn valueLocationRangeOrder(comptime Register: type) type {
    const Range = range.ValueLocationRange(Register);
    return struct {
        fn lessThan(_: void, lhs: Range, rhs: Range) bool {
            const register_order = switch (@typeInfo(Register)) {
                .@"enum" => std.math.order(@backingInt(lhs.reg), @backingInt(rhs.reg)),
                .int => std.math.order(lhs.reg, rhs.reg),
                else => @compileError("register type must be an integer or enum"),
            };
            if (register_order != .eq) return register_order == .lt;
            const lhs_start = lhs.startPoint().rank();
            const rhs_start = rhs.startPoint().rank();
            if (lhs_start != rhs_start) return lhs_start < rhs_start;
            if (lhs.end != rhs.end) return lhs.end < rhs.end;
            return @backingInt(lhs.end_phase) < @backingInt(rhs.end_phase);
        }
    };
}

fn VerificationLimits(comptime Register: type, comptime Mask: type) type {
    return struct {
        ranges: []const range.ValueLocationRange(Register),
        candidates: []const interval.Candidate(Register, Mask),
        fixed_positions: interval.FixedPositionIndex(Register),
    };
}

fn VerificationCapacity(comptime Register: type, comptime Mask: type) type {
    const Limits = VerificationLimits(Register, Mask);
    const Range = range.ValueLocationRange(Register);
    return struct {
        candidate_count: usize,
        range_count: usize,
        candidate_index_bytes: usize,
        ordered_range_bytes: usize,
        working_bytes: usize,

        const Self = @This();

        pub fn derive(limits: Limits) CapacityError!Self {
            return deriveCounts(limits.candidates.len, limits.ranges.len);
        }

        fn deriveCounts(candidate_count: usize, range_count: usize) CapacityError!Self {
            const candidate_index_bytes = std.math.mul(
                usize,
                candidate_count,
                @sizeOf(CandidateIndex),
            ) catch return error.CapacityOverflow;
            const ordered_range_bytes = std.math.mul(
                usize,
                range_count,
                @sizeOf(Range),
            ) catch return error.CapacityOverflow;
            const working_bytes = std.math.add(
                usize,
                candidate_index_bytes,
                ordered_range_bytes,
            ) catch return error.CapacityOverflow;
            return .{
                .candidate_count = candidate_count,
                .range_count = range_count,
                .candidate_index_bytes = candidate_index_bytes,
                .ordered_range_bytes = ordered_range_bytes,
                .working_bytes = working_bytes,
            };
        }
    };
}

fn verifyOrderedRangeInterference(
    comptime Register: type,
    ordered: []const range.ValueLocationRange(Register),
) Error!void {
    const Range = range.ValueLocationRange(Register);
    var active: ?Range = null;
    for (ordered) |entry| {
        std.debug.assert(entry.start < entry.end);
        const current = active orelse {
            active = entry;
            continue;
        };
        if (current.reg != entry.reg) {
            active = entry;
            continue;
        }
        const overlaps = current.endPoint().rank() >= entry.startPoint().rank();
        if (overlaps and current.value != entry.value) return error.InvalidAllocation;
        if (!overlaps or current.endPoint().rank() < entry.endPoint().rank()) active = entry;
    }
}

fn initAllocationVerifier(
    comptime Register: type,
    comptime Mask: type,
    comptime Owner: type,
    allocator: Allocator,
    limits: Owner.Limits,
) !Owner {
    const Range = range.ValueLocationRange(Register);
    const capacity = try Owner.Capacity.derive(limits);
    const candidate_indices = try allocator.alloc(
        CandidateIndex,
        capacity.candidate_count,
    );
    errdefer allocator.free(candidate_indices);
    for (limits.candidates, 0..) |candidate, index| {
        candidate_indices[index] = .{ .value = candidate.value, .index = index };
    }
    std.sort.heap(CandidateIndex, candidate_indices, {}, candidateIndexLessThan);

    const ordered_ranges = try allocator.dupe(Range, limits.ranges);
    errdefer allocator.free(ordered_ranges);
    std.sort.heap(
        Range,
        ordered_ranges,
        {},
        valueLocationRangeOrder(Register).lessThan,
    );

    std.debug.assert(candidate_indices.len == capacity.candidate_count);
    std.debug.assert(ordered_ranges.len == capacity.range_count);
    _ = Mask;
    return .{
        .phase = .initialization,
        .capacity = capacity,
        .candidate_indices = candidate_indices,
        .ordered_ranges = ordered_ranges,
        .candidates = limits.candidates,
        .fixed_positions = limits.fixed_positions,
    };
}

fn activateAllocationVerifier(comptime Owner: type, self: *Owner) error{AlreadyActive}!void {
    if (self.phase != .initialization) return error.AlreadyActive;
    self.phase = .steady;
}

fn deinitAllocationVerifier(comptime Owner: type, self: *Owner, allocator: Allocator) void {
    if (self.phase == .teardown) {
        @panic("allocation verifier teardown is terminal");
    }
    self.phase = .teardown;
    allocator.free(self.ordered_ranges);
    allocator.free(self.candidate_indices);
    self.ordered_ranges = undefined;
    self.candidate_indices = undefined;
}

fn candidateForValue(
    comptime Register: type,
    comptime Mask: type,
    comptime Owner: type,
    self: *const Owner,
    value: *ir.Value,
) ?interval.Candidate(Register, Mask) {
    const candidate_index = std.sort.binarySearch(
        CandidateIndex,
        self.candidate_indices,
        value,
        candidateIndexOrder,
    ) orelse return null;
    return self.candidates[self.candidate_indices[candidate_index].index];
}

fn verifyCandidateIndex(comptime Owner: type, self: *const Owner) Error!void {
    if (self.candidate_indices.len < 2) return;
    for (
        self.candidate_indices[1..],
        self.candidate_indices[0 .. self.candidate_indices.len - 1],
    ) |current, previous| {
        if (current.value == previous.value) return error.InvalidAllocation;
    }
}

fn verifyRangeCandidates(
    comptime Register: type,
    comptime Mask: type,
    comptime Owner: type,
    self: *const Owner,
) Error!void {
    for (self.ordered_ranges) |entry| {
        if (entry.start >= entry.end) return error.InvalidAllocation;
        if (entry.startPoint().rank() > entry.endPoint().rank()) {
            return error.InvalidAllocation;
        }
        const candidate = candidateForValue(Register, Mask, Owner, self, entry.value) orelse
            return error.InvalidAllocation;
        if (!candidate.containsPoint(entry.startPoint())) return error.InvalidAllocation;
        if (!candidate.containsPoint(entry.endPoint())) return error.InvalidAllocation;
    }
}

fn verifyFixedPositions(
    comptime Register: type,
    comptime Mask: type,
    comptime Owner: type,
    self: *const Owner,
) Error!void {
    for (self.ordered_ranges) |entry| {
        const candidate = candidateForValue(Register, Mask, Owner, self, entry.value) orelse
            return error.InvalidAllocation;
        for (self.fixed_positions.between(
            entry.reg,
            entry.startPoint(),
            entry.endPoint(),
        )) |fixed| {
            switch (fixed.kind) {
                .source, .use => continue,
                .scratch_use, .def, .clobber => {},
            }
            if (!candidate.ownsFixedPosition(fixed)) return error.InvalidAllocation;
        }
    }
}

fn verifyAllocationVerifier(
    comptime Register: type,
    comptime Mask: type,
    comptime Owner: type,
    self: *const Owner,
) Error!void {
    if (self.phase != .steady) {
        @panic("allocation verifier used outside its steady phase");
    }
    std.debug.assert(self.candidate_indices.len == self.capacity.candidate_count);
    std.debug.assert(self.ordered_ranges.len == self.capacity.range_count);
    try verifyCandidateIndex(Owner, self);
    try verifyRangeCandidates(Register, Mask, Owner, self);
    try verifyOrderedRangeInterference(Register, self.ordered_ranges);
    try verifyFixedPositions(Register, Mask, Owner, self);
}

fn allocationVerifierType(comptime Register: type, comptime Mask: type) type {
    const Candidate = interval.Candidate(Register, Mask);
    const CapacityType = VerificationCapacity(Register, Mask);
    const FixedPositionIndex = interval.FixedPositionIndex(Register);
    const LimitsType = VerificationLimits(Register, Mask);
    const Range = range.ValueLocationRange(Register);
    return struct {
        pub const claim: alloc_phase.capacity.Declaration = .{
            .source = .{
                .id = "choir.allocation_verifier",
                .kind = .phase_static,
                .limit_source = .caller,
                .storage = .{
                    .covered = &.{
                        .{
                            .id = "sorted_candidateindex_entries_and_duplicated_ordere_0d17418499cc",
                            .lifetime = .steady,
                            .detail = "sorted CandidateIndex entries and duplicated ordered Range entries",
                        },
                    },
                    .excluded = &.{
                        "borrowed candidate records and use-position backing",
                        "borrowed fixed-position records and register spans",
                        "borrowed IR Value pointees and target emitter output",
                    },
                },
                .capacity = .{
                    .inputs = &.{},
                    .type_selectors = &.{},
                    .nodes = &.{
                        .{ .constant = 0 },
                    },
                    .assertions = &.{.{
                        .scope = .closure_total,
                        .measure = .retained,
                        .relation = .exact,
                        .expression = 0,
                    }},
                },
                .overload = .{
                    .kind = .reject_before_seal,
                    .detail = "capacity overflow or OOM rejects before steady verification; invalid allocations remain an explicit steady semantic error, and no steady exhaustion exists",
                },
                .risks = .{
                    .transitive = .{
                        .status = .open,
                        .detail = "the source-reviewed helper chain is clean but current tooling cannot close comptime generic calls and std binary search",
                    },
                    .foreign = .{
                        .status = .open,
                        .detail = "no foreign edge is visible in the reviewed sources, but the transitive machine certificate is incomplete",
                    },
                },
                .obligations = &.{
                    .{ .key = "verifier_capacity_capacity_model", .role = .capacity_model },
                    .{ .key = "verifier_capacity_overload", .role = .overload },
                    .{ .key = "verifier_oom_retry", .role = .overload },
                    .{ .key = "verifier_sealed_valid_transitive_risk", .role = .transitive_risk },
                    .{ .key = "verifier_sealed_valid_foreign_risk", .role = .foreign_risk },
                    .{ .key = "verifier_sealed_invalid_overload", .role = .overload },
                    .{ .key = "verifier_sealed_invalid_transitive_risk", .role = .transitive_risk },
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
        phase: alloc_phase.capacity.Phase,
        capacity: Capacity,
        candidate_indices: []CandidateIndex,
        ordered_ranges: []Range,
        candidates: []const Candidate,
        fixed_positions: FixedPositionIndex,

        pub const Limits: type = LimitsType;
        pub const Capacity: type = CapacityType;

        const Self = @This();

        pub fn init(allocator: Allocator, limits: Limits) !Self {
            return initAllocationVerifier(Register, Mask, Self, allocator, limits);
        }

        pub fn activate(self: *Self) error{AlreadyActive}!void {
            return activateAllocationVerifier(Self, self);
        }

        pub fn verify(self: *const Self) Error!void {
            return verifyAllocationVerifier(Register, Mask, Self, self);
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            deinitAllocationVerifier(Self, self, allocator);
        }
    };
}

pub fn AllocationVerifier(comptime Register: type, comptime Mask: type) type {
    const Verifier = allocationVerifierType(Register, Mask);
    comptime alloc_phase.capacity.requireAllocatorExactOwnerShape(Verifier);
    return Verifier;
}

const TestVerifier = AllocationVerifier(u8, u8);
const TestCandidate = interval.Candidate(u8, u8);
const TestRange = range.ValueLocationRange(u8);

const VerificationFixture = struct {
    owner: u8,
    values: [2]ir.Value,
    candidates: [2]TestCandidate,
    ranges: [3]TestRange,

    fn init(self: *@This()) void {
        self.owner = 0;
        self.values = .{
            .{
                .kind = .{ .op_result = .{ .owner = &self.owner, .result_number = 0 } },
                .type = undefined,
                .id = 0,
            },
            .{
                .kind = .{ .op_result = .{ .owner = &self.owner, .result_number = 1 } },
                .type = undefined,
                .id = 1,
            },
        };
        self.candidates = .{
            .{
                .value = &self.values[0],
                .range = .{ .start = 0, .end = 2, .end_phase = .definition },
                .use_positions = .empty,
                .definition = .{
                    .point = position.Point.definition(0),
                    .requirement = .any,
                    .source = .any,
                },
                .order = 0,
                .is_constant = false,
            },
            .{
                .value = &self.values[1],
                .range = .{ .start = 1, .end = 3, .end_phase = .definition },
                .use_positions = .empty,
                .definition = .{
                    .point = position.Point.definition(1),
                    .requirement = .any,
                    .source = .any,
                },
                .order = 1,
                .is_constant = false,
            },
        };
        self.ranges = .{
            .{ .value = &self.values[1], .start = 2, .end = 3, .reg = 1 },
            .{
                .value = &self.values[0],
                .start = 0,
                .end = 2,
                .reg = 1,
                .end_phase = .source,
            },
            .{ .value = &self.values[1], .start = 1, .end = 4, .reg = 1 },
        };
    }

    fn limits(self: *const @This()) TestVerifier.Limits {
        return .{
            .ranges = &self.ranges,
            .candidates = &self.candidates,
            .fixed_positions = interval.FixedPositionIndex(u8).empty(),
        };
    }
};

const VerifierSnapshot = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: TestVerifier.Capacity,
    candidate_indices_pointer: [*]CandidateIndex,
    candidate_indices_length: usize,
    ordered_ranges_pointer: [*]TestRange,
    ordered_ranges_length: usize,
};

fn verifierSnapshot(verifier: *const TestVerifier) VerifierSnapshot {
    return .{
        .phase = verifier.phase,
        .capacity = verifier.capacity,
        .candidate_indices_pointer = verifier.candidate_indices.ptr,
        .candidate_indices_length = verifier.candidate_indices.len,
        .ordered_ranges_pointer = verifier.ordered_ranges.ptr,
        .ordered_ranges_length = verifier.ordered_ranges.len,
    };
}

fn checkVerifierInitAllocationFailures(
    allocator: Allocator,
    limits: TestVerifier.Limits,
) !void {
    var verifier = try TestVerifier.init(allocator, limits);
    defer verifier.deinit(allocator);
    try std.testing.expectEqual(alloc_phase.capacity.Phase.initialization, verifier.phase);
}

fn verifyTestAllocation(
    ranges: []const range.ValueLocationRange(u8),
    candidates: []const interval.Candidate(u8, u8),
    fixed_positions: interval.FixedPositionIndex(u8),
) !void {
    var verifier = try TestVerifier.init(std.testing.allocator, .{
        .ranges = ranges,
        .candidates = candidates,
        .fixed_positions = fixed_positions,
    });
    defer verifier.deinit(std.testing.allocator);
    try verifier.activate();
    try verifier.verify();
}

fn verifyTestInterference(ranges: []range.ValueLocationRange(u8)) Error!void {
    std.sort.heap(
        range.ValueLocationRange(u8),
        ranges,
        {},
        valueLocationRangeOrder(u8).lessThan,
    );
    try verifyOrderedRangeInterference(u8, ranges);
}

test "allocation verifier derives exact typed working capacity" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(TestVerifier, "verifier_capacity_capacity_model"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(TestVerifier, "verifier_capacity_overload"),
        );
    }

    for (0..9) |candidate_count| {
        for (0..9) |range_count| {
            const capacity = try TestVerifier.Capacity.deriveCounts(
                candidate_count,
                range_count,
            );
            const candidate_bytes = candidate_count * @sizeOf(CandidateIndex);
            const range_bytes = range_count * @sizeOf(TestRange);
            try std.testing.expectEqual(candidate_count, capacity.candidate_count);
            try std.testing.expectEqual(range_count, capacity.range_count);
            try std.testing.expectEqual(candidate_bytes, capacity.candidate_index_bytes);
            try std.testing.expectEqual(range_bytes, capacity.ordered_range_bytes);
            try std.testing.expectEqual(candidate_bytes + range_bytes, capacity.working_bytes);
        }
    }

    const maximum = std.math.maxInt(usize);
    try std.testing.expectError(
        error.CapacityOverflow,
        TestVerifier.Capacity.deriveCounts(maximum / @sizeOf(CandidateIndex) + 1, 0),
    );
    try std.testing.expectError(
        error.CapacityOverflow,
        TestVerifier.Capacity.deriveCounts(0, maximum / @sizeOf(TestRange) + 1),
    );
    try std.testing.expectError(
        error.CapacityOverflow,
        TestVerifier.Capacity.deriveCounts(maximum / @sizeOf(CandidateIndex), 1),
    );
}

test "allocation verifier accepts an empty exact job" {
    var verifier = try TestVerifier.init(std.testing.allocator, .{
        .ranges = &.{},
        .candidates = &.{},
        .fixed_positions = interval.FixedPositionIndex(u8).empty(),
    });
    defer verifier.deinit(std.testing.allocator);
    try verifier.activate();
    try verifier.verify();
    try std.testing.expectEqual(@as(usize, 0), verifier.capacity.working_bytes);
}

test "allocation verifier initialization is retryable after every allocation failure" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(TestVerifier, "verifier_oom_retry"),
        );
    }

    var fixture: VerificationFixture = undefined;
    fixture.init();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkVerifierInitAllocationFailures,
        .{fixture.limits()},
    );

    var verifier = try TestVerifier.init(std.testing.allocator, fixture.limits());
    defer verifier.deinit(std.testing.allocator);
    try verifier.activate();
    try verifier.verify();
}

test "allocation verifier rejects duplicate and empty semantic input after activation" {
    var fixture: VerificationFixture = undefined;
    fixture.init();
    fixture.candidates[1].value = fixture.candidates[0].value;
    try std.testing.expectError(
        error.InvalidAllocation,
        verifyTestAllocation(
            &fixture.ranges,
            &fixture.candidates,
            interval.FixedPositionIndex(u8).empty(),
        ),
    );

    fixture.init();
    fixture.ranges[0].end = fixture.ranges[0].start;
    try std.testing.expectError(
        error.InvalidAllocation,
        verifyTestAllocation(
            &fixture.ranges,
            &fixture.candidates,
            interval.FixedPositionIndex(u8).empty(),
        ),
    );

    fixture.init();
    fixture.ranges[0] = .{
        .value = &fixture.values[0],
        .start = 1,
        .end = 2,
        .reg = 2,
        .end_phase = .source,
    };
    try std.testing.expectError(
        error.InvalidAllocation,
        verifyTestAllocation(
            &fixture.ranges,
            &fixture.candidates,
            interval.FixedPositionIndex(u8).empty(),
        ),
    );
}

test "allocation verifier is sealed before its first valid verification" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(TestVerifier, "verifier_sealed_valid_transitive_risk"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(TestVerifier, "verifier_sealed_valid_foreign_risk"),
        );
    }

    var fixture: VerificationFixture = undefined;
    fixture.init();
    const candidates_before = fixture.candidates;
    const ranges_before = fixture.ranges;

    var phase_allocator = try alloc_phase.SealedPhaseAllocator.init(std.testing.allocator);
    var maybe_verifier: ?TestVerifier = null;
    errdefer {
        if (phase_allocator.phase() == .initialization) {
            phase_allocator.abortInitialization();
        }
        if (phase_allocator.phase() == .steady) phase_allocator.beginTeardown();
        if (maybe_verifier) |*verifier| {
            if (verifier.phase != .teardown) {
                verifier.deinit(phase_allocator.teardownAllocator());
            }
        }
        if (phase_allocator.phase() == .teardown) phase_allocator.deinit();
    }

    maybe_verifier = try TestVerifier.init(
        phase_allocator.initializationAllocator(),
        fixture.limits(),
    );
    const verifier = &maybe_verifier.?;
    const initialized = verifierSnapshot(verifier);
    try std.testing.expectEqual(alloc_phase.capacity.Phase.initialization, initialized.phase);
    try std.testing.expectEqual(@as(usize, 2), initialized.capacity.candidate_count);
    try std.testing.expectEqual(@as(usize, 3), initialized.capacity.range_count);

    phase_allocator.seal();
    try verifier.activate();
    try verifier.verify();
    try verifier.verify();

    const verified = verifierSnapshot(verifier);
    try std.testing.expectEqual(alloc_phase.capacity.Phase.steady, verified.phase);
    try std.testing.expectEqual(initialized.capacity, verified.capacity);
    try std.testing.expectEqual(
        initialized.candidate_indices_pointer,
        verified.candidate_indices_pointer,
    );
    try std.testing.expectEqual(
        initialized.candidate_indices_length,
        verified.candidate_indices_length,
    );
    try std.testing.expectEqual(
        initialized.ordered_ranges_pointer,
        verified.ordered_ranges_pointer,
    );
    try std.testing.expectEqual(
        initialized.ordered_ranges_length,
        verified.ordered_ranges_length,
    );
    try std.testing.expectEqual(candidates_before, fixture.candidates);
    try std.testing.expectEqual(ranges_before, fixture.ranges);
    try std.testing.expectEqual(alloc_phase.PhaseViolations{}, phase_allocator.violations());

    phase_allocator.beginTeardown();
    verifier.deinit(phase_allocator.teardownAllocator());
    try std.testing.expectEqual(alloc_phase.capacity.Phase.teardown, verifier.phase);
    try std.testing.expectEqual(alloc_phase.PhaseViolations{}, phase_allocator.violations());
    phase_allocator.deinit();
}

test "allocation verifier is sealed before its first invalid verification" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(TestVerifier, "verifier_sealed_invalid_overload"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(TestVerifier, "verifier_sealed_invalid_transitive_risk"),
        );
    }

    var fixture: VerificationFixture = undefined;
    fixture.init();
    fixture.ranges[1].end_phase = .definition;

    var phase_allocator = try alloc_phase.SealedPhaseAllocator.init(std.testing.allocator);
    var maybe_verifier: ?TestVerifier = null;
    errdefer {
        if (phase_allocator.phase() == .initialization) {
            phase_allocator.abortInitialization();
        }
        if (phase_allocator.phase() == .steady) phase_allocator.beginTeardown();
        if (maybe_verifier) |*verifier| {
            if (verifier.phase != .teardown) {
                verifier.deinit(phase_allocator.teardownAllocator());
            }
        }
        if (phase_allocator.phase() == .teardown) phase_allocator.deinit();
    }

    maybe_verifier = try TestVerifier.init(
        phase_allocator.initializationAllocator(),
        fixture.limits(),
    );
    const verifier = &maybe_verifier.?;
    const initialized = verifierSnapshot(verifier);
    phase_allocator.seal();
    try verifier.activate();
    try std.testing.expectError(error.InvalidAllocation, verifier.verify());
    try std.testing.expectEqual(initialized.capacity, verifier.capacity);
    try std.testing.expectEqual(
        initialized.candidate_indices_pointer,
        verifier.candidate_indices.ptr,
    );
    try std.testing.expectEqual(
        initialized.candidate_indices_length,
        verifier.candidate_indices.len,
    );
    try std.testing.expectEqual(initialized.ordered_ranges_pointer, verifier.ordered_ranges.ptr);
    try std.testing.expectEqual(initialized.ordered_ranges_length, verifier.ordered_ranges.len);
    try std.testing.expectEqual(alloc_phase.PhaseViolations{}, phase_allocator.violations());

    phase_allocator.beginTeardown();
    verifier.deinit(phase_allocator.teardownAllocator());
    try std.testing.expectEqual(alloc_phase.PhaseViolations{}, phase_allocator.violations());
    phase_allocator.deinit();
}

test "allocation verifier rejects ranges without candidate ownership" {
    var owner: u8 = 0;
    var value = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 0 } },
        .type = undefined,
        .id = 0,
    };

    const Range = range.ValueLocationRange(u8);
    const ranges = [_]Range{.{
        .value = &value,
        .start = 1,
        .end = 2,
        .reg = 1,
    }};

    try std.testing.expectError(
        error.InvalidAllocation,
        verifyTestAllocation(&ranges, &.{}, interval.FixedPositionIndex(u8).empty()),
    );
}

test "allocation verifier rejects ranges outside candidate intervals" {
    var owner: u8 = 0;
    var value = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 0 } },
        .type = undefined,
        .id = 0,
    };

    const Candidate = interval.Candidate(u8, u8);
    const Range = range.ValueLocationRange(u8);
    const candidates = [_]Candidate{.{
        .value = &value,
        .range = .{ .start = 1, .end = 1, .end_phase = .definition },
        .use_positions = .empty,
        .definition = .{
            .point = position.Point.definition(1),
            .requirement = .any,
            .source = .any,
        },
        .order = 0,
        .is_constant = false,
    }};
    const ranges = [_]Range{.{
        .value = &value,
        .start = 0,
        .end = 2,
        .reg = 1,
    }};

    try std.testing.expectError(
        error.InvalidAllocation,
        verifyTestAllocation(
            &ranges,
            &candidates,
            interval.FixedPositionIndex(u8).empty(),
        ),
    );
}

test "allocation verifier accepts owned noninterfering ranges" {
    var owner: u8 = 0;
    var value = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 0 } },
        .type = undefined,
        .id = 0,
    };
    var other = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 1 } },
        .type = undefined,
        .id = 1,
    };

    const Candidate = interval.Candidate(u8, u8);
    const Range = range.ValueLocationRange(u8);
    const candidates = [_]Candidate{
        .{
            .value = &value,
            .range = .{ .start = 1, .end = 1, .end_phase = .definition },
            .use_positions = .empty,
            .definition = .{
                .point = position.Point.definition(1),
                .requirement = .any,
                .source = .any,
            },
            .order = 0,
            .is_constant = false,
        },
        .{
            .value = &other,
            .range = .{ .start = 2, .end = 2, .end_phase = .definition },
            .use_positions = .empty,
            .definition = .{
                .point = position.Point.definition(2),
                .requirement = .any,
                .source = .any,
            },
            .order = 1,
            .is_constant = false,
        },
    };
    const ranges = [_]Range{
        .{
            .value = &value,
            .start = 1,
            .end = 2,
            .reg = 1,
        },
        .{
            .value = &other,
            .start = 2,
            .end = 3,
            .reg = 1,
        },
    };

    try verifyTestAllocation(
        &ranges,
        &candidates,
        interval.FixedPositionIndex(u8).empty(),
    );
}

test "interference verifier retains the widest same-value range" {
    var owner: u8 = 0;
    var value = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 0 } },
        .type = undefined,
        .id = 0,
    };
    var other = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 1 } },
        .type = undefined,
        .id = 1,
    };
    const Range = range.ValueLocationRange(u8);
    var ranges = [_]Range{
        .{ .value = &other, .start = 4, .end = 5, .reg = 1 },
        .{ .value = &other, .start = 1, .end = 7, .reg = 2 },
        .{ .value = &value, .start = 2, .end = 3, .reg = 1 },
        .{ .value = &value, .start = 1, .end = 8, .reg = 1 },
    };

    try std.testing.expectError(
        error.InvalidAllocation,
        verifyTestInterference(&ranges),
    );
}

test "interference verifier permits overlapping ranges for one value" {
    var owner: u8 = 0;
    var value = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 0 } },
        .type = undefined,
        .id = 0,
    };
    var other = ir.Value{
        .kind = .{ .op_result = .{ .owner = &owner, .result_number = 1 } },
        .type = undefined,
        .id = 1,
    };
    const Range = range.ValueLocationRange(u8);
    var ranges = [_]Range{
        .{ .value = &value, .start = 5, .end = 9, .reg = 1 },
        .{ .value = &other, .start = 5, .end = 9, .reg = 2 },
        .{ .value = &value, .start = 1, .end = 8, .reg = 1 },
    };

    try verifyTestInterference(&ranges);
}
