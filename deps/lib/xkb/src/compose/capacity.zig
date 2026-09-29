const std = @import("std");
const alloc_phase = @import("alloc_phase");
const table = @import("table.zig");

pub const storage_alignment: usize = @max(@alignOf(table.Node), @alignOf(table.Edge));

pub const Limits = struct {
    sequence_symbols: usize,
    text_bytes: usize,
};

pub const DeriveError = error{
    SequenceSymbolLimitExceeded,
    TextByteLimitExceeded,
    CapacityOverflow,
};

pub const Capacity = struct {
    limits: Limits,
    node_count: usize,
    node_offset: usize,
    node_bytes: usize,
    edge_count: usize,
    edge_offset: usize,
    edge_bytes: usize,
    text_offset: usize,
    storage_bytes: usize,

    pub fn derive(limits: Limits) DeriveError!Capacity {
        if (limits.sequence_symbols >= table.max_nodes) {
            return error.SequenceSymbolLimitExceeded;
        }
        if (limits.text_bytes > std.math.maxInt(u32)) return error.TextByteLimitExceeded;
        const node_count = try added(limits.sequence_symbols, 1);
        const nodes = try placed(table.Node, 0, node_count);
        const edges = try placed(table.Edge, nodes.end, limits.sequence_symbols);
        const text_offset = edges.end;
        return .{
            .limits = limits,
            .node_count = node_count,
            .node_offset = nodes.start,
            .node_bytes = nodes.bytes,
            .edge_count = limits.sequence_symbols,
            .edge_offset = edges.start,
            .edge_bytes = edges.bytes,
            .text_offset = text_offset,
            .storage_bytes = try added(text_offset, limits.text_bytes),
        };
    }
};

const Region = struct {
    start: usize,
    bytes: usize,
    end: usize,
};

fn added(left: usize, right: usize) DeriveError!usize {
    return std.math.add(usize, left, right) catch error.CapacityOverflow;
}

fn placed(comptime T: type, offset: usize, count: usize) DeriveError!Region {
    const mask: usize = @alignOf(T) - 1;
    const start = (try added(offset, mask)) & ~mask;
    const bytes = std.math.mul(usize, count, @sizeOf(T)) catch
        return error.CapacityOverflow;
    return .{ .start = start, .bytes = bytes, .end = try added(start, bytes) };
}

fn modelCapacity(limits: Limits) DeriveError!Capacity {
    if (limits.sequence_symbols >= table.max_nodes) {
        return error.SequenceSymbolLimitExceeded;
    }
    if (limits.text_bytes > std.math.maxInt(u32)) return error.TextByteLimitExceeded;
    const node_count = @as(u128, limits.sequence_symbols) + 1;
    const node_offset: u128 = 0;
    const node_bytes = node_count * @sizeOf(table.Node);
    const edge_offset = alignForward(node_offset + node_bytes, @alignOf(table.Edge));
    const edge_count: u128 = limits.sequence_symbols;
    const edge_bytes = edge_count * @sizeOf(table.Edge);
    const text_offset = edge_offset + edge_bytes;
    const storage_bytes = text_offset + limits.text_bytes;
    const values = [_]u128{
        node_count,
        node_bytes,
        edge_offset,
        edge_count,
        edge_bytes,
        text_offset,
        storage_bytes,
    };
    for (values) |value| {
        if (value > std.math.maxInt(usize)) return error.CapacityOverflow;
    }
    return .{
        .limits = limits,
        .node_count = @intCast(node_count),
        .node_offset = @intCast(node_offset),
        .node_bytes = @intCast(node_bytes),
        .edge_count = @intCast(edge_count),
        .edge_offset = @intCast(edge_offset),
        .edge_bytes = @intCast(edge_bytes),
        .text_offset = @intCast(text_offset),
        .storage_bytes = @intCast(storage_bytes),
    };
}

fn alignForward(value: u128, alignment: u128) u128 {
    return (value + alignment - 1) & ~(alignment - 1);
}

test "Compose capacity matches an independent aligned byte model" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./root.zig").Storage, "xkb_compose_capacity"),
        );
    }

    const limits = Limits{ .sequence_symbols = 4096, .text_bytes = 16 * 1024 };
    const capacity = try Capacity.derive(limits);
    try std.testing.expectEqual(try modelCapacity(limits), capacity);
    try std.testing.expectEqual(capacity.node_count, capacity.edge_count + 1);
    try std.testing.expectEqual(
        capacity.storage_bytes,
        capacity.text_offset + limits.text_bytes,
    );
}

test "Compose capacity rejects index and text representation overflow" {
    try std.testing.expectError(
        error.SequenceSymbolLimitExceeded,
        Capacity.derive(.{ .sequence_symbols = table.max_nodes, .text_bytes = 0 }),
    );
    if (comptime @bitSizeOf(usize) > @bitSizeOf(u32)) {
        try std.testing.expectError(
            error.TextByteLimitExceeded,
            Capacity.derive(.{
                .sequence_symbols = 0,
                .text_bytes = @as(usize, std.math.maxInt(u32)) + 1,
            }),
        );
    }
}
