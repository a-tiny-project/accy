const capacity = @import("capacity");

pub const storage_alignment: usize = 16;
pub const Storage = []align(storage_alignment) u8;
pub const Limits = struct {
    slots: usize,
};
pub const Capacity = struct {
    storage_bytes: usize,

    pub fn derive(limits: Limits) error{InvalidLimit}!Capacity {
        if (limits.slots == 0) return error.InvalidLimit;
        return .{ .storage_bytes = limits.slots };
    }
};
pub const Exhaustion = error{Full};
pub const InitError = error{ InvalidLimit, StorageTooShort };
pub const work_limits: capacity.WorkLimits = .{
    .transition_steps_max = 1,
    .cleanup_steps_per_call_max = 1,
    .cleanup_calls_at_capacity_max = 8,
};
pub fn declaration(comptime Owner: type) capacity.Declaration {
    return .{
        .source = .{
            .id = "alloc.negative_fixture",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{.{
                    .id = "caller_storage",
                    .lifetime = .transferred,
                    .detail = "caller storage",
                }},
                .excluded = &.{"caller payloads"},
            },
            .capacity = .{
                .inputs = &.{capacity.bindInput(Owner.Limits, "slots", "slots")},
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
                .detail = "full rejects before storage mutation",
            },
            .risks = .{
                .transitive = .{ .status = .open, .detail = "fixture has no callees" },
                .foreign = .{ .status = .open, .detail = "fixture has no foreign resources" },
            },
            .work = .{ .equation = "transition_steps <= transition_steps_max" },
            .obligations = &.{
                .{ .key = "capacity", .role = .capacity_model },
                .{ .key = "overload", .role = .overload },
                .{ .key = "work", .role = .work_bound },
            },
        },
        .bindings = .{
            .owner = Owner,
            .seal = .{
                .family = capacity.selector(activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = capacity.selector(deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };
}

fn activate() void {}
fn deinit() void {}
