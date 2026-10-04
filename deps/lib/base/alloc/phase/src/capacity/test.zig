const std = @import("std");
const capacity = @import("capacity");
const phase = @import("../root.zig");

const Allocator = std.mem.Allocator;
const OwnerShapeViolation = capacity.OwnerShapeViolation;
const Phase = capacity.Phase;
const ProvisionedExactFixture = capacity.ProvisionedExactFixture;
const ProvisionedRejectingFixture = capacity.ProvisionedRejectingFixture;

const TestLimits = struct {
    slots: u32,
};

const TestCapacity = struct {
    slots: usize,

    pub fn derive(limits: TestLimits) error{InvalidLimit}!TestCapacity {
        if (limits.slots == 0) return error.InvalidLimit;
        return .{ .slots = limits.slots };
    }
};

const TestExhaustion = error{Full};

const TestOwner = struct {
    pub const Limits = TestLimits;
    pub const Capacity = TestCapacity;
    pub const Exhaustion = TestExhaustion;

    pub const claim: capacity.Declaration = .{
        .source = .{
            .id = "alloc.shape_fixture",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{.{
                    .id = "slot_storage",
                    .lifetime = .steady,
                    .detail = "slot storage",
                }},
                .excluded = &.{"caller-owned payloads"},
            },
            .capacity = .{
                .inputs = &.{capacity.bindInput(Limits, "slots", "slots")},
                .nodes = &.{.{ .input = 0 }},
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 0,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "take returns Full before any slot mutates",
            },
            .risks = .{
                .transitive = .{ .status = .open, .detail = "fixture has no callees" },
                .foreign = .{ .status = .open, .detail = "fixture crosses no foreign resources" },
            },
            .obligations = &.{
                .{ .key = "capacity", .role = .capacity_model },
                .{ .key = "overload", .role = .overload },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    phase: Phase,
    capacity: TestCapacity,
    storage: []u8,

    pub fn init(allocator: Allocator, limits: TestLimits) !TestOwner {
        const derived = try TestCapacity.derive(limits);
        return .{
            .phase = .initialization,
            .capacity = derived,
            .storage = try allocator.alloc(u8, derived.slots),
        };
    }

    pub fn activate(self: *TestOwner) void {
        self.phase = .steady;
    }

    pub fn available(self: *const TestOwner) usize {
        std.debug.assert(self.phase == .steady);
        return self.storage.len;
    }

    pub fn take(self: *TestOwner) Exhaustion!void {
        if (self.storage.len == 0) return error.Full;
    }

    pub fn deinit(self: *TestOwner, allocator: Allocator) void {
        self.phase = .teardown;
        allocator.free(self.storage);
    }
};

const TypedOwner = struct {
    pub const Limits = struct {
        shape: struct { slots: u16 },
        slot_bytes: u32,
    };
    pub const Capacity = struct {
        storage_bytes: usize,

        pub fn derive(limits: Limits) error{ InvalidLimit, CapacityOverflow }!Capacity {
            if (limits.shape.slots == 0 or limits.slot_bytes == 0) {
                return error.InvalidLimit;
            }
            return .{
                .storage_bytes = try capacity.mul(
                    usize,
                    limits.shape.slots,
                    limits.slot_bytes,
                ),
            };
        }
    };
    pub const claim: capacity.Declaration = .{
        .source = .{
            .id = "alloc.typed_shape_fixture",
            .kind = .phase_static,
            .limit_source = .application_default,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "scratch",
                        .lifetime = .initialization,
                        .detail = "capacity derivation scratch",
                    },
                    .{
                        .id = "slots",
                        .lifetime = .steady,
                        .detail = "retained slot storage",
                    },
                    .{
                        .id = "handoff",
                        .lifetime = .transferred,
                        .detail = "returned payload storage",
                    },
                },
                .excluded = &.{"caller-owned payloads"},
            },
            .capacity = .{
                .inputs = &.{
                    capacity.bindInput(Limits, "slots", "shape.slots"),
                    capacity.bindInput(Limits, "slot_bytes", "slot_bytes"),
                },
                .nodes = &.{
                    .{ .constant = 1 },
                    .{ .input = 0 },
                    .{ .input = 1 },
                    .{ .add = .{ .left = 1, .right = 2 } },
                    .{ .maximum = .{ .left = 0, .right = 3 } },
                    .{ .scale = .{ .node = 4, .coefficient = .{ .literal = 2 } } },
                    .{ .scale = .{
                        .node = 5,
                        .coefficient = .{ .unsigned_comptime_parameter = 0 },
                    } },
                    .{ .scale = .{
                        .node = 6,
                        .coefficient = .{ .size_of_type_parameter = 0 },
                    } },
                },
                .assertions = &.{
                    .{
                        .scope = .closure_total,
                        .measure = .retained,
                        .relation = .upper_bound,
                        .expression = 7,
                    },
                    .{
                        .scope = .closure_total,
                        .measure = .retained,
                        .relation = .exact,
                        .expression = 3,
                    },
                },
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "capacity admission rejects before owner construction",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "the fixture has no transitive owners",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "the fixture crosses no foreign boundary",
                },
            },
            .work = .{ .equation = "transition steps are at most one" },
            .dependencies = &.{"alloc.fixture_support"},
            .obligations = &.{
                .{ .key = "capacity", .role = .capacity_model },
                .{ .key = "acquire", .role = .acquisition },
                .{ .key = "init_failure", .role = .initialization_failure },
                .{ .key = "overload", .role = .overload },
                .{ .key = "seal", .role = .seal },
                .{ .key = "teardown", .role = .teardown },
                .{ .key = "work", .role = .work_bound },
                .{ .key = "transitive", .role = .transitive_risk },
                .{ .key = "foreign", .role = .foreign_risk },
                .{ .key = "integration", .role = .integration },
                .{ .key = "extension", .role = .custom },
            },
        },
        .bindings = .{
            .owner = @This(),
            .default_limits = capacity.selector(defaultLimits),
            .seal = .{
                .family = capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = capacity.selector(@This().deinit),
                .premise = .{
                    .class = .theorem_domain,
                    .authority = .{ .theorem = .{ .key = "teardown" } },
                },
            },
        },
    };

    phase: Phase,
    capacity: Capacity,
    storage: []u8,

    fn defaultLimits() Limits {
        return .{ .shape = .{ .slots = 4 }, .slot_bytes = 1 };
    }

    pub fn init(allocator: Allocator, limits: Limits) !TypedOwner {
        const derived = try Capacity.derive(limits);
        return .{
            .phase = .initialization,
            .capacity = derived,
            .storage = try allocator.alloc(u8, derived.storage_bytes),
        };
    }

    pub fn activate(self: *TypedOwner) void {
        std.debug.assert(self.phase == .initialization);
        self.phase = .steady;
    }

    pub fn deinit(self: *TypedOwner, allocator: Allocator) void {
        std.debug.assert(self.phase == .steady);
        self.phase = .teardown;
        allocator.free(self.storage);
    }
};

const ExactOwnerFixture = struct {
    pub const Limits = TestLimits;
    pub const Capacity = TestCapacity;

    phase: Phase,
    capacity: TestCapacity,

    pub fn init(_: Allocator, limits: TestLimits) !@This() {
        return .{
            .phase = .initialization,
            .capacity = try TestCapacity.derive(limits),
        };
    }

    pub fn activate(self: *@This()) void {
        self.phase = .steady;
    }

    pub fn run(self: *const @This()) usize {
        return self.capacity.slots;
    }

    pub fn deinit(self: *@This(), _: Allocator) void {
        self.phase = .teardown;
    }
};

const StoredAllocatorOwnerFixture = struct {
    pub const Limits = TestLimits;
    pub const Capacity = TestCapacity;
    pub const Exhaustion = TestExhaustion;

    phase: Phase,
    capacity: TestCapacity,
    allocator: Allocator,

    pub fn init(allocator: Allocator, limits: TestLimits) !@This() {
        return .{
            .phase = .initialization,
            .capacity = try TestCapacity.derive(limits),
            .allocator = allocator,
        };
    }

    pub fn activate(self: *@This()) void {
        self.phase = .steady;
    }

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

const SteadyAllocatorOwnerFixture = struct {
    pub const Limits = TestLimits;
    pub const Capacity = TestCapacity;
    pub const Exhaustion = TestExhaustion;

    phase: Phase,
    capacity: TestCapacity,

    pub fn init(_: Allocator, limits: TestLimits) !@This() {
        return .{ .phase = .initialization, .capacity = try TestCapacity.derive(limits) };
    }

    pub fn activate(self: *@This()) void {
        self.phase = .steady;
    }

    pub fn grow(_: *@This(), _: Allocator) void {}

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

const InvalidCapacityFixture = struct {
    pub fn derive(_: usize) @This() {
        return .{};
    }
};

const CapacityDerivationOwnerFixture = struct {
    pub const Limits = TestLimits;
    pub const Capacity = InvalidCapacityFixture;
    pub const Exhaustion = TestExhaustion;

    phase: Phase,
    capacity: InvalidCapacityFixture,

    pub fn init(_: Allocator, _: TestLimits) @This() {
        return .{ .phase = .initialization, .capacity = .{} };
    }

    pub fn activate(self: *@This()) void {
        self.phase = .steady;
    }

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

const WrongExhaustionOwnerFixture = struct {
    pub const Limits = TestLimits;
    pub const Capacity = TestCapacity;
    pub const Exhaustion = usize;

    phase: Phase,
    capacity: TestCapacity,

    pub fn init(_: Allocator, limits: TestLimits) !@This() {
        return .{ .phase = .initialization, .capacity = try TestCapacity.derive(limits) };
    }

    pub fn activate(self: *@This()) void {
        self.phase = .steady;
    }

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

const PrimitiveLimitsOwnerFixture = struct {
    pub const Limits = usize;
    pub const Capacity = TestCapacity;
    pub const Exhaustion = TestExhaustion;
};

const PrimitiveCapacityOwnerFixture = struct {
    pub const Limits = TestLimits;
    pub const Capacity = usize;
    pub const Exhaustion = TestExhaustion;

    phase: Phase,
    capacity: usize,
};

const SteadyAllocatorResultOwnerFixture = struct {
    pub const Limits = TestLimits;
    pub const Capacity = TestCapacity;
    pub const Exhaustion = TestExhaustion;

    phase: Phase,
    capacity: TestCapacity,

    pub fn init(_: Allocator, limits: TestLimits) !@This() {
        return .{ .phase = .initialization, .capacity = try TestCapacity.derive(limits) };
    }

    pub fn activate(self: *@This()) void {
        self.phase = .steady;
    }

    pub fn currentAllocator(_: *const @This()) Allocator {
        return undefined;
    }

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

const ByValueAllocatorResultOwnerFixture = struct {
    pub const Limits = TestLimits;
    pub const Capacity = TestCapacity;
    pub const Exhaustion = TestExhaustion;

    phase: Phase,
    capacity: TestCapacity,

    pub fn init(_: Allocator, limits: TestLimits) !@This() {
        return .{ .phase = .initialization, .capacity = try TestCapacity.derive(limits) };
    }

    pub fn activate(self: *@This()) void {
        self.phase = .steady;
    }

    pub fn currentAllocator(_: @This()) Allocator {
        return undefined;
    }

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

const UnobservableExhaustionOwnerFixture = struct {
    pub const Limits = TestLimits;
    pub const Capacity = TestCapacity;
    pub const Exhaustion = TestExhaustion;

    phase: Phase,
    capacity: TestCapacity,

    pub fn init(_: Allocator, limits: TestLimits) !@This() {
        return .{ .phase = .initialization, .capacity = try TestCapacity.derive(limits) };
    }

    pub fn activate(self: *@This()) void {
        self.phase = .steady;
    }

    pub fn unrelated() Exhaustion!void {}

    pub fn available(_: *const @This()) usize {
        return 0;
    }

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

test "phase owner shape accepts an allocator-free steady surface" {
    comptime capacity.requireAllocatorRejectingOwnerShape(TestOwner);
    try std.testing.expect(
        capacity.validateAllocatorRejectingOwnerShape(TestOwner) == null,
    );

    var owner = try TestOwner.init(std.testing.allocator, .{ .slots = 4 });
    defer owner.deinit(std.testing.allocator);
    owner.activate();
    try std.testing.expectEqual(@as(usize, 4), owner.available());
}

test "typed claim declaration covers the complete authoring surface" {
    comptime capacity.requireAllocatorExactOwnerShape(TypedOwner);
    try std.testing.expect(
        capacity.validateAllocatorExactOwnerShape(TypedOwner) == null,
    );
    var owner = try TypedOwner.init(std.testing.allocator, .{
        .shape = .{ .slots = 4 },
        .slot_bytes = 2,
    });
    owner.activate();
    try std.testing.expectEqual(@as(usize, 8), owner.storage.len);
    owner.deinit(std.testing.allocator);
}

test "phase owner shape accepts exact work without steady exhaustion" {
    comptime capacity.requireAllocatorExactOwnerShape(ExactOwnerFixture);
    try std.testing.expect(
        capacity.validateAllocatorExactOwnerShape(ExactOwnerFixture) == null,
    );
    try std.testing.expectEqual(
        OwnerShapeViolation.missing_exhaustion_declaration,
        capacity.validateAllocatorRejectingOwnerShape(ExactOwnerFixture).?,
    );
}

test "phase owner shape classifies incomplete declarations" {
    const MissingLimits = struct {};
    const WrongLimits = struct {
        pub const Limits = 1;
    };
    const MissingCapacity = struct {
        pub const Limits = TestLimits;
    };
    try std.testing.expectEqual(
        OwnerShapeViolation.owner_not_struct,
        capacity.validateAllocatorExactOwnerShape(usize).?,
    );
    try std.testing.expectEqual(
        OwnerShapeViolation.missing_limits_declaration,
        capacity.validateAllocatorExactOwnerShape(MissingLimits).?,
    );
    try std.testing.expectEqual(
        OwnerShapeViolation.wrong_limits_declaration,
        capacity.validateAllocatorExactOwnerShape(WrongLimits).?,
    );
    try std.testing.expectEqual(
        OwnerShapeViolation.missing_capacity_declaration,
        capacity.validateAllocatorExactOwnerShape(MissingCapacity).?,
    );
}

test "phase owner shape rejects a stored allocator" {
    try std.testing.expectEqual(
        OwnerShapeViolation.stored_allocator,
        capacity.validateAllocatorExactOwnerShape(StoredAllocatorOwnerFixture).?,
    );
}

test "phase owner shape rejects allocator-bearing steady methods" {
    try std.testing.expectEqual(
        OwnerShapeViolation.steady_allocator_parameter,
        capacity.validateAllocatorExactOwnerShape(SteadyAllocatorOwnerFixture).?,
    );
}

test "phase owner shape checks capacity derivation" {
    try std.testing.expectEqual(
        OwnerShapeViolation.wrong_capacity_derive,
        capacity.validateAllocatorExactOwnerShape(CapacityDerivationOwnerFixture).?,
    );
}

test "phase owner shape requires a domain exhaustion error" {
    try std.testing.expectEqual(
        OwnerShapeViolation.wrong_exhaustion_declaration,
        capacity.validateAllocatorRejectingOwnerShape(WrongExhaustionOwnerFixture).?,
    );
}

test "phase owner shape requires domain limit and capacity containers" {
    try std.testing.expectEqual(
        OwnerShapeViolation.wrong_limits_declaration,
        capacity.validateAllocatorExactOwnerShape(PrimitiveLimitsOwnerFixture).?,
    );
    try std.testing.expectEqual(
        OwnerShapeViolation.wrong_capacity_declaration,
        capacity.validateAllocatorExactOwnerShape(PrimitiveCapacityOwnerFixture).?,
    );
}

test "phase owner shape rejects allocator-bearing steady results" {
    try std.testing.expectEqual(
        OwnerShapeViolation.steady_allocator_result,
        capacity.validateAllocatorExactOwnerShape(SteadyAllocatorResultOwnerFixture).?,
    );
    try std.testing.expectEqual(
        OwnerShapeViolation.steady_allocator_result,
        capacity.validateAllocatorExactOwnerShape(ByValueAllocatorResultOwnerFixture).?,
    );
}

test "phase owner shape requires exhaustion on an owner operation" {
    try std.testing.expectEqual(
        OwnerShapeViolation.exhaustion_not_observable,
        capacity.validateAllocatorRejectingOwnerShape(UnobservableExhaustionOwnerFixture).?,
    );
}

test "provisioned exact owner returns its exact caller storage" {
    comptime {
        capacity.record(
            capacity.witness(ProvisionedExactFixture, "alloc_provisioned_exact_capacity_capacity_model"),
        );
    }
    comptime {
        capacity.record(
            capacity.witness(ProvisionedExactFixture, "alloc_provisioned_exact_capacity_overload"),
        );
    }
    comptime {
        capacity.record(
            capacity.witness(ProvisionedExactFixture, "alloc_provisioned_exact_capacity_work_bound"),
        );
    }

    const Owner = ProvisionedExactFixture;
    comptime capacity.requireProvisionedExactOwnerShape(Owner);
    try std.testing.expect(capacity.validateProvisionedExactOwnerShape(Owner) == null);

    var bytes: [32]u8 align(Owner.storage_alignment) = @splat(0);
    const storage: Owner.Storage = bytes[0..];
    var owner = try Owner.init(storage, .{ .bytes = 24 });
    owner.activate();
    try std.testing.expectEqual(@as(usize, 24), owner.bytes());

    const returned = owner.deinit();
    try std.testing.expectEqual(@intFromPtr(storage.ptr), @intFromPtr(returned.ptr));
    try std.testing.expectEqual(storage.len, returned.len);
}

test "provisioned owner rejects one-byte-short storage without mutation" {
    const Owner = ProvisionedRejectingFixture;
    var bytes: [16]u8 align(Owner.storage_alignment) = @splat(0xa5);
    const before = bytes;
    const short: Owner.Storage = bytes[0 .. bytes.len - 1];

    try std.testing.expectError(
        error.StorageTooShort,
        Owner.init(short, .{ .slots = Owner.slots_max, .slot_bytes = 2 }),
    );
    try std.testing.expectEqualSlices(u8, &before, &bytes);
}

test "provisioned capacity rejects overflow and semantic max plus one" {
    const Owner = ProvisionedRejectingFixture;
    try std.testing.expectError(
        error.CapacityOverflow,
        Owner.Capacity.derive(.{
            .slots = std.math.maxInt(usize),
            .slot_bytes = 2,
        }),
    );
    try std.testing.expectError(
        error.CapacityExceeded,
        Owner.Capacity.derive(.{
            .slots = Owner.slots_max + 1,
            .slot_bytes = 1,
        }),
    );
}

test "provisioned rejecting owner preserves state at capacity plus one" {
    comptime {
        capacity.record(
            capacity.witness(ProvisionedRejectingFixture, "alloc_provisioned_rejecting_capacity_capacity_model"),
        );
    }
    comptime {
        capacity.record(
            capacity.witness(ProvisionedRejectingFixture, "alloc_provisioned_rejecting_capacity_overload"),
        );
    }
    comptime {
        capacity.record(
            capacity.witness(ProvisionedRejectingFixture, "alloc_provisioned_rejecting_capacity_work_bound"),
        );
    }

    const Owner = ProvisionedRejectingFixture;
    comptime capacity.requireProvisionedRejectingOwnerShape(Owner);
    try std.testing.expect(
        capacity.validateProvisionedRejectingOwnerShape(Owner) == null,
    );
    var bytes: [Owner.slots_max * 2]u8 align(Owner.storage_alignment) = @splat(0);
    var owner = try Owner.init(bytes[0..], .{
        .slots = Owner.slots_max,
        .slot_bytes = 2,
    });
    owner.activate();
    for (0..Owner.slots_max) |index| try owner.submit(@intCast(index + 1));

    const before_bytes = bytes;
    var expected_owner = owner;
    const storage_pointer = @intFromPtr(owner.storage.ptr);
    const storage_length = owner.storage.len;
    expected_owner.usage.submitted += 1;
    expected_owner.usage.rejected += 1;
    try std.testing.expectError(error.Full, owner.submit(0xff));

    try std.testing.expectEqualSlices(u8, &before_bytes, &bytes);
    try std.testing.expectEqualDeep(expected_owner, owner);
    try std.testing.expectEqual(storage_pointer, @intFromPtr(owner.storage.ptr));
    try std.testing.expectEqual(storage_length, owner.storage.len);
    _ = owner.deinit();
}

test "provisioned accounting rejects max plus one before mutation" {
    const Owner = ProvisionedRejectingFixture;
    var bytes: [Owner.slots_max]u8 align(Owner.storage_alignment) = @splat(0);
    var owner = try Owner.init(bytes[0..], .{
        .slots = Owner.slots_max,
        .slot_bytes = 1,
    });
    owner.activate();
    owner.usage.submitted = std.math.maxInt(usize);
    const empty_bytes = bytes;
    const empty_owner = owner;
    const empty_storage_pointer = @intFromPtr(owner.storage.ptr);
    const empty_storage_length = owner.storage.len;
    try std.testing.expectError(error.AccountingOverflow, owner.submit(1));
    try std.testing.expectEqualDeep(empty_owner, owner);
    try std.testing.expectEqual(
        empty_storage_pointer,
        @intFromPtr(owner.storage.ptr),
    );
    try std.testing.expectEqual(empty_storage_length, owner.storage.len);
    try std.testing.expectEqualSlices(u8, &empty_bytes, &bytes);

    owner.usage = .{};
    for (0..Owner.slots_max) |index| try owner.submit(@intCast(index + 1));
    owner.usage.submitted = std.math.maxInt(usize) - 1;
    owner.usage.rejected = std.math.maxInt(usize);
    const full_bytes = bytes;
    const full_owner = owner;
    const full_storage_pointer = @intFromPtr(owner.storage.ptr);
    const full_storage_length = owner.storage.len;
    try std.testing.expectError(error.AccountingOverflow, owner.submit(0xff));
    try std.testing.expectEqualDeep(full_owner, owner);
    try std.testing.expectEqual(
        full_storage_pointer,
        @intFromPtr(owner.storage.ptr),
    );
    try std.testing.expectEqual(full_storage_length, owner.storage.len);
    try std.testing.expectEqualSlices(u8, &full_bytes, &bytes);
    _ = owner.deinit();
}

test "provisioned cleanup completes within literal work limits" {
    const Owner = ProvisionedRejectingFixture;
    var bytes: [Owner.slots_max]u8 align(Owner.storage_alignment) = @splat(0);
    var owner = try Owner.init(bytes[0..], .{
        .slots = Owner.slots_max,
        .slot_bytes = 1,
    });
    owner.activate();
    for (0..Owner.slots_max) |index| try owner.submit(@intCast(index + 1));

    var cleanup_calls: usize = 0;
    var cleanup_steps: usize = 0;
    while (owner.cleanupOne()) {
        cleanup_calls += 1;
        cleanup_steps += 1;
        try std.testing.expect(cleanup_steps <= cleanup_calls);
        try std.testing.expectEqual(Owner.slots_max - cleanup_calls, owner.used);
    }
    try std.testing.expectEqual(
        Owner.work_limits.cleanup_calls_at_capacity_max,
        cleanup_calls,
    );
    try std.testing.expect(
        cleanup_steps <= cleanup_calls * Owner.work_limits.cleanup_steps_per_call_max,
    );
    try std.testing.expectEqualSlices(u8, &@as([Owner.slots_max]u8, @splat(0)), &bytes);
    _ = owner.deinit();
}

test "provisioned owner surface carries no allocator capability" {
    try std.testing.expect(
        !capacity.typeHasAllocatorCapability(ProvisionedExactFixture),
    );
    try std.testing.expect(
        !capacity.typeHasAllocatorCapability(ProvisionedRejectingFixture),
    );
}

test "provisioned owner lifecycle performs zero observed allocations" {
    const Owner = ProvisionedRejectingFixture;
    var observer = try phase.ObservingPhaseAllocator.init(std.testing.allocator);
    const initialization_allocator = observer.initializationAllocator();
    const bytes = try initialization_allocator.alignedAlloc(
        u8,
        .fromByteUnits(Owner.storage_alignment),
        Owner.slots_max,
    );
    @memset(bytes, 0);
    defer {
        if (observer.phase() == .initialization) {
            observer.abortInitialization();
        } else if (observer.phase() == .steady) {
            observer.beginTeardown();
        }
        observer.teardownAllocator().free(bytes);
        observer.deinit();
    }
    var owner = try Owner.init(bytes[0..], .{
        .slots = Owner.slots_max,
        .slot_bytes = 1,
    });

    observer.seal();
    owner.activate();
    for (0..Owner.slots_max) |index| {
        try owner.submit(@intCast(index + 1));
    }
    try std.testing.expectError(error.Full, owner.submit(0xff));
    while (owner.cleanupOne()) {}
    _ = owner.deinit();

    try std.testing.expectEqual(@as(u64, 0), observer.violations().total());
}

test "capacity package namespace" {
    std.testing.refAllDecls(capacity);
}
