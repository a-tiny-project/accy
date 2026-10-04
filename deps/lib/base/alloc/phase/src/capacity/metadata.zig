//! This module serves as a dedicated test fixture for compiler claim metadata
//! containing nested `Limits` fields, signed input, collection and byte slice
//! inputs, type selectors, expression nodes, and phase premises. Tests attach
//! witness annotations for capacity, overload, work, seal, and teardown, while
//! supporting fixtures exercise concrete storage behavior.

const std = @import("std");
const capacity = @import("capacity");

pub const Fixture = struct {
    const Self = @This();

    pub const storage_alignment: usize = 16;
    pub const Storage = []align(storage_alignment) u8;
    pub const Limits = struct {
        shape: struct { slots: u16 },
        slot_bytes: u16,
        signed_bias: i32,
        candidates: []const u32,
        source: []const u8,
    };
    pub const Capacity = struct {
        storage_bytes: usize,

        pub const DeriveError = error{
            InvalidLimit,
            CapacityOverflow,
            CapacityExceeded,
        };

        pub fn derive(limits: Limits) DeriveError!Capacity {
            if (limits.shape.slots == 0 or limits.slot_bytes == 0) {
                return error.InvalidLimit;
            }
            const storage_bytes = @mulWithOverflow(
                @as(usize, limits.shape.slots),
                @as(usize, limits.slot_bytes),
            );
            if (storage_bytes[1] != 0) return error.CapacityOverflow;
            if (storage_bytes[0] > storage_bytes_max) {
                return error.CapacityExceeded;
            }
            return .{ .storage_bytes = storage_bytes[0] };
        }
    };
    pub const InitError = Capacity.DeriveError || error{StorageTooShort};
    pub const work_limits: capacity.WorkLimits = .{
        .transition_steps_max = 1,
        .cleanup_steps_per_call_max = 0,
        .cleanup_calls_at_capacity_max = 0,
    };
    pub const claim: capacity.Declaration = .{
        .source = .{
            .id = "stardust.metadata_fixture",
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
                        .id = "state",
                        .lifetime = .steady,
                        .detail = "retained fixture state",
                    },
                    .{
                        .id = "handoff",
                        .lifetime = .transferred,
                        .detail = "returned caller storage",
                    },
                },
                .excluded = &.{"caller value"},
            },
            .capacity = .{
                .inputs = &.{
                    capacity.bindInput(Limits, "slots", "shape.slots"),
                    capacity.bindInput(Limits, "slot_bytes", "slot_bytes"),
                    capacity.bindInput(Limits, "signed_bias", "signed_bias"),
                    capacity.bindInput(Limits, "candidates", "candidates"),
                    capacity.bindInput(Limits, "source", "source"),
                },
                .type_selectors = &.{capacity.bindType(u32, "entry")},
                .nodes = &.{
                    .{ .constant = 0 },
                    .{ .constant = 1 },
                    .{ .input = 0 },
                    .{ .input = 1 },
                    .{ .product = .{ .left = 2, .right = 3 } },
                    .{ .scale = .{
                        .node = 2,
                        .coefficient = .{ .size_of_concrete_type = 0 },
                    } },
                    .{ .add = .{ .left = 4, .right = 5 } },
                    .{ .alignment = .{
                        .node = 6,
                        .alignment = .{ .concrete_type = 0 },
                    } },
                    .{ .ceiling_division = .{ .left = 7, .right = 1 } },
                    .{ .conditional = .{
                        .predicate = .{
                            .comparison = .greater_than,
                            .left = 2,
                            .right = 0,
                        },
                        .when_true = 8,
                        .when_false = 0,
                    } },
                    .{ .maximum = .{ .left = 9, .right = 4 } },
                    .{ .input = 2 },
                    .{ .collection = .{ .length = 3 } },
                    .{ .collection = .{ .byte_count = .{
                        .input = 4,
                        .byte = '\n',
                    } } },
                    .{ .add = .{ .left = 12, .right = 13 } },
                    .{ .next_power_of_two = 14 },
                    .{ .add = .{ .left = 11, .right = 15 } },
                },
                .assertions = &.{
                    .{
                        .scope = .closure_total,
                        .measure = .retained,
                        .relation = .upper_bound,
                        .expression = 16,
                    },
                    .{
                        .scope = .closure_total,
                        .measure = .retained,
                        .relation = .exact,
                        .expression = 4,
                    },
                },
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "short storage rejects before construction",
            },
            .risks = .{
                .transitive = .{
                    .status = .excluded,
                    .detail = "the fixture has no transitive owners",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "the fixture crosses no foreign boundary",
                },
            },
            .work = .{ .equation = "transition steps are at most one" },
            .dependencies = &.{"stardust.fixture_support"},
            .obligations = &.{
                .{ .key = "capacity", .role = .capacity_model },
                .{ .key = "overload", .role = .overload },
                .{ .key = "work", .role = .work_bound },
                .{ .key = "seal", .role = .seal },
                .{ .key = "teardown", .role = .teardown },
            },
        },
        .bindings = .{
            .owner = Self,
            .default_limits = capacity.selector(Self.defaultLimits),
            .seal = .{
                .family = capacity.selector(Self.activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = capacity.selector(Self.deinit),
                .premise = .{
                    .class = .theorem_domain,
                    .authority = .{ .theorem = .{ .key = "teardown" } },
                },
            },
        },
    };

    phase: capacity.Phase,
    capacity: Capacity,
    storage: Storage,

    const storage_bytes_max: usize = 64;

    pub noinline fn defaultLimits() Limits {
        return .{
            .shape = .{ .slots = 4 },
            .slot_bytes = 2,
            .signed_bias = 1,
            .candidates = &.{ 1, 2 },
            .source = "one\ntwo\n",
        };
    }

    pub noinline fn init(storage: Storage, limits: Limits) InitError!Self {
        const derived = try Capacity.derive(limits);
        if (storage.len < derived.storage_bytes) return error.StorageTooShort;
        return .{
            .phase = .initialization,
            .capacity = derived,
            .storage = storage,
        };
    }

    pub noinline fn activate(self: *Self) void {
        self.phase = .steady;
    }

    pub noinline fn bytes(self: *const Self) usize {
        return self.capacity.storage_bytes;
    }

    pub noinline fn deinit(self: *Self) Storage {
        self.phase = .teardown;
        return self.storage;
    }
};

comptime {
    if (capacity.validateProvisionedExactOwnerShape(Fixture) != null) {
        @compileError("typed metadata fixture has an invalid owner shape");
    }
}

test "typed metadata fixture witnesses capacity overload and work" {
    comptime {
        capacity.record(capacity.witness(Fixture, "capacity"));
        capacity.record(capacity.witness(Fixture, "overload"));
        capacity.record(capacity.witness(Fixture, "work"));
    }
    var storage: [64]u8 align(Fixture.storage_alignment) = @splat(0);
    var fixture = try Fixture.init(storage[0..], Fixture.defaultLimits());
    try std.testing.expectEqual(@as(usize, 8), fixture.bytes());
    _ = fixture.deinit();
    var short: [1]u8 align(Fixture.storage_alignment) = @splat(0);
    try std.testing.expectError(
        error.StorageTooShort,
        Fixture.init(short[0..], Fixture.defaultLimits()),
    );
    try std.testing.expectEqual(
        @as(u16, 1),
        Fixture.work_limits.transition_steps_max,
    );
}

test "typed metadata fixture witnesses seal" {
    comptime {
        capacity.record(capacity.witness(Fixture, "seal"));
    }
    var storage: [64]u8 align(Fixture.storage_alignment) = @splat(0);
    var fixture = try Fixture.init(storage[0..], Fixture.defaultLimits());
    fixture.activate();
    try std.testing.expectEqual(capacity.Phase.steady, fixture.phase);
    _ = fixture.deinit();
}

test "typed metadata fixture witnesses teardown" {
    comptime {
        capacity.record(capacity.witness(Fixture, "teardown"));
    }
    var storage: [64]u8 align(Fixture.storage_alignment) = @splat(0);
    var fixture = try Fixture.init(storage[0..], Fixture.defaultLimits());
    const released = fixture.deinit();
    try std.testing.expectEqual(storage.len, released.len);
    try std.testing.expectEqual(capacity.Phase.teardown, fixture.phase);
}
