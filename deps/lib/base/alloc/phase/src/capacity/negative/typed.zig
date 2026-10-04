const std = @import("std");
const capacity = @import("capacity");

pub const Defect = enum {
    bad_field_path,
    unknown_obligation,
    missing_binding,
    outside_fragment,
};

pub fn Owner(comptime defect: Defect) type {
    return struct {
        const Self = @This();

        pub const Limits = struct { count: u16 };
        pub const Capacity = struct {
            count: usize,

            pub fn derive(limits: Limits) error{InvalidLimit}!Capacity {
                if (limits.count == 0) return error.InvalidLimit;
                return .{ .count = limits.count };
            }
        };
        pub const claim: capacity.Declaration = declaration(defect, Self);

        phase: capacity.Phase,
        capacity: Capacity,

        pub fn init(_: std.mem.Allocator, limits: Limits) !Self {
            return .{
                .phase = .initialization,
                .capacity = try Capacity.derive(limits),
            };
        }

        pub fn activate(self: *Self) void {
            self.phase = .steady;
        }

        pub fn deinit(self: *Self, _: std.mem.Allocator) void {
            self.phase = .teardown;
        }
    };
}

fn declaration(comptime defect: Defect, comptime OwnerType: type) capacity.Declaration {
    const Limits = OwnerType.Limits;
    return .{
        .source = .{
            .id = "alloc.typed_negative",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{.{
                    .id = "state",
                    .lifetime = .steady,
                    .detail = "negative fixture state",
                }},
                .excluded = &.{"caller values"},
            },
            .capacity = .{
                .inputs = &.{capacity.bindInput(
                    Limits,
                    "count",
                    if (defect == .bad_field_path) "missing" else "count",
                )},
                .nodes = if (defect == .outside_fragment)
                    &.{
                        capacity.Node{ .input = 0 },
                        capacity.Node{ .add = .{ .left = 0, .right = 1 } },
                    }
                else
                    &.{capacity.Node{ .input = 0 }},
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = if (defect == .outside_fragment) 1 else 0,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "negative fixture admission rejects",
            },
            .risks = .{
                .transitive = .{ .status = .open, .detail = "no fixture callees" },
                .foreign = .{ .status = .open, .detail = "no foreign state" },
            },
            .obligations = &.{
                .{ .key = "capacity", .role = .capacity_model },
                .{ .key = "overload", .role = .overload },
                .{ .key = "teardown", .role = .teardown },
            },
        },
        .bindings = .{
            .owner = if (defect == .missing_binding) null else OwnerType,
            .seal = .{
                .family = capacity.selector(OwnerType.activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = capacity.selector(OwnerType.deinit),
                .premise = .{
                    .class = .theorem_domain,
                    .authority = .{ .theorem = .{
                        .key = if (defect == .unknown_obligation)
                            "missing"
                        else
                            "teardown",
                    } },
                },
            },
        },
    };
}
