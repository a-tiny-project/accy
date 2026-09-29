const std = @import("std");
const xkb = @import("../root.zig");

const Keysym = xkb.keysym.Keysym;

pub const max_sequence_length = 10;
pub const max_output_bytes = 255;
pub const max_nodes = 1 << 23;
pub const no_edge: u32 = std.math.maxInt(u32);

pub const Result = struct {
    text: ?[]const u8 = null,
    symbol: ?Keysym = null,
};

pub const StoredResult = struct {
    text_offset: u32 = 0,
    symbol: Keysym = .no_symbol,
    text_length: u8 = 0,
    has_result: bool = false,
    has_text: bool = false,
};

pub const Node = struct {
    first_edge: u32 = no_edge,
    result: StoredResult = .{},
};

pub const Edge = struct {
    symbol: Keysym,
    node: u32,
    next: u32 = no_edge,
};

pub const Entry = struct {
    sequence: []const Keysym,
    text: ?[]const u8,
    symbol: ?Keysym,
};

pub const Table = struct {
    nodes: []const Node,
    edges: []const Edge,
    text: []const u8,

    pub fn iterator(self: *const Table) Iterator {
        return Iterator.init(self);
    }

    pub fn view(self: *const Table) View {
        return .{
            .nodes = self.nodes,
            .edges = self.edges,
            .text = self.text,
        };
    }

    pub fn transition(self: *const Table, node_index: u32, symbol: Keysym) ?u32 {
        return self.view().transition(node_index, symbol);
    }

    pub fn result(self: *const Table, node_index: u32) ?Result {
        return self.view().result(node_index);
    }
};

pub const View = struct {
    nodes: []const Node,
    edges: []const Edge,
    text: []const u8,

    pub fn transition(self: View, node_index: u32, symbol: Keysym) ?u32 {
        var edge_index = self.nodes[node_index].first_edge;
        while (edge_index != no_edge) {
            const edge = self.edges[edge_index];
            const symbol_value = @backingInt(symbol);
            const candidate_value = @backingInt(edge.symbol);
            if (symbol_value < candidate_value) return null;
            if (symbol_value == candidate_value) return edge.node;
            edge_index = edge.next;
        }
        return null;
    }

    pub fn result(self: View, node_index: u32) ?Result {
        const stored = self.nodes[node_index].result;
        if (!stored.has_result) return null;
        return .{
            .text = if (stored.has_text)
                self.text[stored.text_offset..][0..stored.text_length]
            else
                null,
            .symbol = if (stored.symbol == .no_symbol) null else stored.symbol,
        };
    }
};

pub const Iterator = struct {
    table: View,
    frames: [max_sequence_length + 1]Frame = undefined,
    sequence: [max_sequence_length]Keysym = undefined,
    depth: usize = 0,

    const Frame = struct {
        node: u32,
        next_edge: u32,
        yielded: bool = false,
    };

    fn init(table: *const Table) Iterator {
        var result = Iterator{ .table = table.view() };
        result.frames[0] = .{
            .node = 0,
            .next_edge = result.table.nodes[0].first_edge,
        };
        return result;
    }

    pub fn next(self: *Iterator) ?Entry {
        while (true) {
            var frame = &self.frames[self.depth];
            if (!frame.yielded) {
                frame.yielded = true;
                if (self.table.result(frame.node)) |result_value| {
                    return .{
                        .sequence = self.sequence[0..self.depth],
                        .text = result_value.text,
                        .symbol = result_value.symbol,
                    };
                }
            }

            if (frame.next_edge != no_edge) {
                const edge = self.table.edges[frame.next_edge];
                frame.next_edge = edge.next;
                self.sequence[self.depth] = edge.symbol;
                self.depth += 1;
                self.frames[self.depth] = .{
                    .node = edge.node,
                    .next_edge = self.table.nodes[edge.node].first_edge,
                };
                continue;
            }

            if (self.depth == 0) return null;
            self.depth -= 1;
        }
    }
};

test "table traverses sorted linked transitions" {
    const a: Keysym = @fromBackingInt(@intCast('a'));
    const b: Keysym = @fromBackingInt(@intCast('b'));
    const nodes = [_]Node{
        .{ .first_edge = 0 },
        .{ .result = .{ .has_result = true, .symbol = a } },
        .{ .result = .{
            .text_offset = 0,
            .text_length = 1,
            .has_result = true,
            .has_text = true,
        } },
    };
    const edges = [_]Edge{
        .{ .symbol = a, .node = 1, .next = 1 },
        .{ .symbol = b, .node = 2 },
    };
    const published = Table{ .nodes = &nodes, .edges = &edges, .text = "b" };
    try std.testing.expectEqual(@as(?u32, 1), published.transition(0, a));
    try std.testing.expectEqual(@as(?u32, 2), published.transition(0, b));
    var iterator_value = published.iterator();
    try std.testing.expectEqualSlices(Keysym, &.{a}, iterator_value.next().?.sequence);
    try std.testing.expectEqualSlices(Keysym, &.{b}, iterator_value.next().?.sequence);
    try std.testing.expect(iterator_value.next() == null);
}
