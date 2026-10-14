const std = @import("std");
const alloc_phase = @import("alloc_phase");

const Allocator = std.mem.Allocator;

pub const segment_count: usize = 4;

pub const Segment = struct {
    count: usize,
    element_bytes: usize,
    alignment: std.mem.Alignment,
};

pub fn segment(comptime T: type, count: usize) Segment {
    return .{
        .count = count,
        .element_bytes = @sizeOf(T),
        .alignment = .fromByteUnits(@alignOf(T)),
    };
}

pub const Storage = struct {
    pub const Limits = struct {
        segments: [segment_count]Segment,
    };

    pub const Capacity = struct {
        offsets: [segment_count]usize,
        byte_lengths: [segment_count]usize,
        alignments: [segment_count]std.mem.Alignment,
        total_bytes: usize,
        allocation_alignment: std.mem.Alignment,

        pub fn derive(limits: Limits) error{CapacityOverflow}!Capacity {
            var offsets: [segment_count]usize = undefined;
            var byte_lengths: [segment_count]usize = undefined;
            var alignments: [segment_count]std.mem.Alignment = undefined;
            var cursor: usize = 0;
            var allocation_alignment: usize = 1;
            for (limits.segments, &offsets, &byte_lengths, &alignments) |segment_value, *offset, *byte_length, *alignment| {
                byte_length.* = std.math.mul(
                    usize,
                    segment_value.count,
                    segment_value.element_bytes,
                ) catch return error.CapacityOverflow;
                offset.* = try placeBytes(
                    byte_length.*,
                    segment_value.alignment.toByteUnits(),
                    &cursor,
                    &allocation_alignment,
                );
                alignment.* = segment_value.alignment;
            }
            return .{
                .offsets = offsets,
                .byte_lengths = byte_lengths,
                .alignments = alignments,
                .total_bytes = cursor,
                .allocation_alignment = .fromByteUnits(allocation_alignment),
            };
        }
    };

    pub const InitError = Allocator.Error || error{CapacityOverflow};

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "choir.product_metadata_storage",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "durable_product_graph_records_and_names",
                        .lifetime = .steady,
                        .detail = "durable product graph records and names",
                    },
                    .{
                        .id = "durable_refresh_plan_records_and_names",
                        .lifetime = .steady,
                        .detail = "durable refresh plan records and names",
                    },
                    .{
                        .id = "durable_refresh_report_projections",
                        .lifetime = .steady,
                        .detail = "durable refresh report projections",
                    },
                },
                .excluded = &.{
                    "borrowing product graph builders and closure workspaces",
                    "caller-owned source metadata and allocator implementation state",
                    "retained exact records in separately bounded revision stores",
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
                .detail = "count, name-byte, layout, or allocation failure returns before a durable product value is published",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "graph queries read retained immutable revision records; teardown releases those handles after the local region",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "product metadata construction and queries cross no operating-system or foreign callback boundary",
                },
            },
            .obligations = &.{
                .{ .key = "choir_product_metadata_capacity", .role = .capacity_model },
                .{ .key = "choir_product_metadata_acquisition", .role = .custom },
                .{ .key = "choir_product_metadata_boundary", .role = .overload },
                .{ .key = "choir_product_metadata_oom", .role = .overload },
                .{ .key = "choir_product_graph_lifetime_transitive_risk", .role = .transitive_risk },
                .{ .key = "choir_product_graph_lifetime_foreign_risk", .role = .foreign_risk },
                .{ .key = "choir_product_refresh_lifetime", .role = .transitive_risk },
                .{ .key = "choir_product_report_composition_lifetime", .role = .transitive_risk },
                .{ .key = "choir_product_metadata_integration", .role = .custom },
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
    bytes: [*]u8,

    pub fn init(allocator: Allocator, limits: Limits) InitError!Storage {
        const capacity = try Capacity.derive(limits);
        std.debug.assert(capacity.total_bytes > 0);
        const bytes = allocator.rawAlloc(
            capacity.total_bytes,
            capacity.allocation_alignment,
            @returnAddress(),
        ) orelse return error.OutOfMemory;
        return .{
            .phase = .initialization,
            .capacity = capacity,
            .bytes = bytes,
        };
    }

    pub fn region(self: *Storage, comptime T: type, comptime index: usize, count: usize) []T {
        comptime std.debug.assert(index < segment_count);
        std.debug.assert(self.phase == .initialization);
        const byte_length = std.math.mul(usize, count, @sizeOf(T)) catch unreachable;
        std.debug.assert(byte_length == self.capacity.byte_lengths[index]);
        std.debug.assert(@alignOf(T) == self.capacity.alignments[index].toByteUnits());
        const offset = self.capacity.offsets[index];
        const address = std.math.add(usize, @intFromPtr(self.bytes), offset) catch unreachable;
        const raw: [*]u8 = @ptrFromInt(address);
        const items: [*]T = @ptrCast(@alignCast(raw));
        return items[0..count];
    }

    pub fn activate(self: *Storage) void {
        std.debug.assert(self.phase == .initialization);
        self.phase = .steady;
    }

    pub fn status(self: *const Storage) alloc_phase.capacity.Phase {
        return self.phase;
    }

    pub fn deinit(self: *Storage, allocator: Allocator) void {
        std.debug.assert(self.phase != .teardown);
        self.phase = .teardown;
        allocator.rawFree(
            self.bytes[0..self.capacity.total_bytes],
            self.capacity.allocation_alignment,
            @returnAddress(),
        );
        self.* = undefined;
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(Storage);
}

fn placeBytes(
    bytes: usize,
    alignment: usize,
    cursor: *usize,
    allocation_alignment: *usize,
) error{CapacityOverflow}!usize {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    const mask = std.math.sub(usize, alignment, 1) catch unreachable;
    const padded = std.math.add(usize, cursor.*, mask) catch return error.CapacityOverflow;
    const offset = padded & ~mask;
    cursor.* = std.math.add(usize, offset, bytes) catch return error.CapacityOverflow;
    allocation_alignment.* = @max(allocation_alignment.*, alignment);
    return offset;
}
