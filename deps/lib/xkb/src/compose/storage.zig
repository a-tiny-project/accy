const std = @import("std");
const alloc_phase = @import("alloc_phase");
const xkb = @import("../root.zig");
const capacity_mod = @import("capacity.zig");
const table = @import("table.zig");

const Keysym = xkb.keysym.Keysym;

pub const StorageExhaustion = error{
    ComposeStorageInUse,
    SequenceSymbolCapacityExceeded,
    TextByteCapacityExceeded,
};

pub const Status = struct {
    phase: alloc_phase.capacity.Phase,
    in_use: bool,
    storage_bytes: usize,
    sequence_symbols: usize,
    text_bytes: usize,
    used_nodes: usize,
    used_edges: usize,
    used_text_bytes: usize,
};

pub const Storage = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: capacity_mod.Capacity,
    bytes: []align(capacity_mod.storage_alignment) u8,
    nodes: []table.Node,
    edges: []table.Edge,
    text: []u8,
    used_nodes: usize = 0,
    used_edges: usize = 0,
    used_text_bytes: usize = 0,
    in_use: bool = false,

    pub const Limits: type = capacity_mod.Limits;
    pub const Capacity: type = capacity_mod.Capacity;
    pub const Exhaustion: type = StorageExhaustion;
    pub const InitError = std.mem.Allocator.Error || capacity_mod.DeriveError;
    pub const AcquireError = Storage.Exhaustion;

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "xkb.compose_storage",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "compose_trie_nodes_and_sorted_transition_links",
                        .lifetime = .steady,
                        .detail = "Compose trie nodes and sorted transition links",
                    },
                    .{
                        .id = "compose_result_text_bytes",
                        .lifetime = .steady,
                        .detail = "Compose result text bytes",
                    },
                },
                .excluded = &.{
                    "caller-owned root Compose input bytes",
                    "loading scratch covered by xkb.compose_scratch_storage",
                    "diagnostic callbacks and filesystem handles",
                    "windowing keymaps, operating-system state, and teardown storage",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(Limits, "sequence_symbols", "sequence_symbols"),
                    alloc_phase.capacity.bindInput(Limits, "text_bytes", "text_bytes"),
                },
                .type_selectors = &.{},
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .constant = 1 },
                    .{ .input = 1 },
                    .{ .add = .{ .left = 0, .right = 1 } },
                    .{ .add = .{ .left = 3, .right = 0 } },
                    .{ .add = .{ .left = 4, .right = 2 } },
                    .{ .alignment = .{ .node = 5, .alignment = .{ .literal = 16 } } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .upper_bound,
                    .expression = 6,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "Each rule reserves all missing trie symbols and result text before private trie mutation.",
            },
            .risks = .{
                .transitive = .{
                    .status = .witnessed,
                    .detail = "Trie construction, publication, lookup, iteration, and reuse stay inside fixed regions.",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "filesystem handles remain foreign initialization effects outside the bounded scratch owner",
                },
            },
            .obligations = &.{
                .{ .key = "xkb_compose_capacity", .role = .capacity_model },
                .{ .key = "xkb_compose_acquisition", .role = .custom },
                .{ .key = "xkb_compose_oom", .role = .custom },
                .{ .key = "xkb_compose_boundaries", .role = .overload },
                .{ .key = "xkb_compose_reuse", .role = .overload },
                .{ .key = "xkb_compose_reserve", .role = .overload },
                .{ .key = "xkb_compose_sealed", .role = .transitive_risk },
                .{ .key = "xkb_compose_root", .role = .custom },
                .{ .key = "xkb_compose_consumer", .role = .foreign_risk },
                .{ .key = "xkb_compose_windowing_root", .role = .custom },
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
            .nodes = typedSlice(
                table.Node,
                bytes,
                capacity.node_offset,
                capacity.node_count,
            ),
            .edges = typedSlice(
                table.Edge,
                bytes,
                capacity.edge_offset,
                capacity.edge_count,
            ),
            .text = bytes[capacity.text_offset..][0..capacity.limits.text_bytes],
        };
    }

    pub fn activate(self: *Storage) void {
        std.debug.assert(self.phase == .initialization);
        std.debug.assert(self.bytes.len == self.capacity.storage_bytes);
        self.phase = .steady;
    }

    pub fn acquire(self: *Storage) Storage.Exhaustion!void {
        std.debug.assert(self.phase == .steady);
        if (self.in_use) return error.ComposeStorageInUse;
        self.in_use = true;
        self.used_nodes = 1;
        self.used_edges = 0;
        self.used_text_bytes = 0;
        self.nodes[0] = .{};
    }

    pub fn insert(
        self: *Storage,
        sequence: []const Keysym,
        result_value: table.Result,
    ) Storage.Exhaustion!void {
        std.debug.assert(self.phase == .steady);
        std.debug.assert(self.in_use);
        std.debug.assert(sequence.len > 0);
        std.debug.assert(sequence.len <= table.max_sequence_length);
        if (result_value.text == null) std.debug.assert(result_value.symbol != null);
        if (result_value.symbol) |symbol| std.debug.assert(symbol != .no_symbol);

        const required_nodes = self.requiredNodes(sequence);
        if (required_nodes > self.nodes.len - self.used_nodes or
            required_nodes > self.edges.len - self.used_edges)
        {
            return error.SequenceSymbolCapacityExceeded;
        }
        const required_text = if (result_value.text) |value| value.len else 0;
        if (required_text > self.text.len - self.used_text_bytes) {
            return error.TextByteCapacityExceeded;
        }

        var node_index: u32 = 0;
        for (sequence, 0..) |symbol, sequence_index| {
            const last = sequence_index + 1 == sequence.len;
            node_index = self.childAssumeCapacity(node_index, symbol);
            const node = &self.nodes[node_index];
            if (!last) {
                if (node.result.has_result) {
                    node.result = .{};
                    node.first_edge = table.no_edge;
                }
                continue;
            }

            node.first_edge = table.no_edge;
            node.result = self.storeAssumeCapacity(result_value);
        }
    }

    pub fn publish(self: *const Storage) table.Table {
        std.debug.assert(self.phase == .steady);
        std.debug.assert(self.in_use);
        return .{
            .nodes = self.nodes[0..self.used_nodes],
            .edges = self.edges[0..self.used_edges],
            .text = self.text[0..self.used_text_bytes],
        };
    }

    pub fn reset(self: *Storage) void {
        std.debug.assert(self.phase == .steady);
        std.debug.assert(self.in_use);
        self.in_use = false;
        self.used_nodes = 0;
        self.used_edges = 0;
        self.used_text_bytes = 0;
    }

    pub fn status(self: *const Storage) Status {
        return .{
            .phase = self.phase,
            .in_use = self.in_use,
            .storage_bytes = self.capacity.storage_bytes,
            .sequence_symbols = self.capacity.limits.sequence_symbols,
            .text_bytes = self.capacity.limits.text_bytes,
            .used_nodes = self.used_nodes,
            .used_edges = self.used_edges,
            .used_text_bytes = self.used_text_bytes,
        };
    }

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        std.debug.assert(self.phase != .teardown);
        std.debug.assert(!self.in_use);
        std.debug.assert(self.bytes.len == self.capacity.storage_bytes);
        self.phase = .teardown;
        allocator.free(self.bytes);
        self.bytes = &.{};
        self.nodes = &.{};
        self.edges = &.{};
        self.text = &.{};
        self.used_nodes = 0;
        self.used_edges = 0;
        self.used_text_bytes = 0;
    }

    fn requiredNodes(self: *const Storage, sequence: []const Keysym) usize {
        var node_index: u32 = 0;
        for (sequence, 0..) |symbol, sequence_index| {
            const child_index = self.findChild(node_index, symbol) orelse
                return sequence.len - sequence_index;
            node_index = child_index;
            if (sequence_index + 1 < sequence.len and
                self.nodes[node_index].result.has_result)
            {
                return sequence.len - sequence_index - 1;
            }
        }
        return 0;
    }

    fn findChild(self: *const Storage, parent_index: u32, symbol: Keysym) ?u32 {
        var edge_index = self.nodes[parent_index].first_edge;
        while (edge_index != table.no_edge) {
            const edge = self.edges[edge_index];
            const symbol_value = @backingInt(symbol);
            const candidate_value = @backingInt(edge.symbol);
            if (symbol_value < candidate_value) return null;
            if (symbol_value == candidate_value) return edge.node;
            edge_index = edge.next;
        }
        return null;
    }

    fn childAssumeCapacity(self: *Storage, parent_index: u32, symbol: Keysym) u32 {
        var previous_edge: u32 = table.no_edge;
        var next_edge = self.nodes[parent_index].first_edge;
        while (next_edge != table.no_edge) {
            const edge = self.edges[next_edge];
            const symbol_value = @backingInt(symbol);
            const candidate_value = @backingInt(edge.symbol);
            if (symbol_value < candidate_value) break;
            if (symbol_value == candidate_value) return edge.node;
            previous_edge = next_edge;
            next_edge = edge.next;
        }

        std.debug.assert(self.used_nodes < self.nodes.len);
        std.debug.assert(self.used_edges < self.edges.len);
        const child_index: u32 = @intCast(self.used_nodes);
        const edge_index: u32 = @intCast(self.used_edges);
        self.nodes[child_index] = .{};
        self.edges[edge_index] = .{
            .symbol = symbol,
            .node = child_index,
            .next = next_edge,
        };
        if (previous_edge == table.no_edge) {
            self.nodes[parent_index].first_edge = edge_index;
        } else {
            self.edges[previous_edge].next = edge_index;
        }
        self.used_nodes += 1;
        self.used_edges += 1;
        return child_index;
    }

    fn storeAssumeCapacity(
        self: *Storage,
        result_value: table.Result,
    ) table.StoredResult {
        var stored = table.StoredResult{
            .has_result = true,
            .symbol = result_value.symbol orelse .no_symbol,
        };
        if (result_value.text) |text_value| {
            std.debug.assert(text_value.len <= table.max_output_bytes);
            std.debug.assert(text_value.len <= self.text.len - self.used_text_bytes);
            stored.text_offset = @intCast(self.used_text_bytes);
            stored.text_length = @intCast(text_value.len);
            stored.has_text = true;
            @memcpy(
                self.text[self.used_text_bytes..][0..text_value.len],
                text_value,
            );
            self.used_text_bytes += text_value.len;
        }
        return stored;
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
        .sequence_symbols = 16,
        .text_bytes = 32,
    });
    storage.deinit(allocator);
}

test "Compose storage acquires one exact aligned region" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "xkb_compose_acquisition"),
        );
    }

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const limits = capacity_mod.Limits{ .sequence_symbols = 16, .text_bytes = 32 };
    const capacity = try capacity_mod.Capacity.derive(limits);
    var storage = try Storage.init(counting.allocator(), limits);
    defer storage.deinit(counting.allocator());
    try std.testing.expectEqual(@as(usize, 1), counting.alloc_index);
    try std.testing.expectEqual(capacity.storage_bytes, counting.allocated_bytes);
    storage.activate();
    try storage.acquire();
    defer storage.reset();
    const base = @intFromPtr(storage.bytes.ptr);
    try std.testing.expectEqual(base + capacity.node_offset, @intFromPtr(storage.nodes.ptr));
    try std.testing.expectEqual(base + capacity.edge_offset, @intFromPtr(storage.edges.ptr));
    try std.testing.expectEqual(base + capacity.text_offset, @intFromPtr(storage.text.ptr));
}

test "Compose storage retries after every allocation failure" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(Storage, "xkb_compose_oom"));
    }

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkInitFailures,
        .{},
    );
}

test "Compose storage preserves prefix replacement in sorted linked storage" {
    var storage = try Storage.init(std.testing.allocator, .{
        .sequence_symbols = 15,
        .text_bytes = 32,
    });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    try storage.acquire();
    defer storage.reset();

    const a: Keysym = @fromBackingInt(@intCast('a'));
    const b: Keysym = @fromBackingInt(@intCast('b'));
    const c: Keysym = @fromBackingInt(@intCast('c'));
    try storage.insert(&.{ a, b }, .{ .text = "old" });
    try storage.insert(&.{ a, b, c }, .{ .text = "long" });
    try storage.insert(&.{a}, .{ .text = "short", .symbol = b });
    try storage.insert(&.{c}, .{ .symbol = a });

    const published = storage.publish();
    var iterator_value = published.iterator();
    const first = iterator_value.next().?;
    try std.testing.expectEqualSlices(Keysym, &.{a}, first.sequence);
    try std.testing.expectEqualStrings("short", first.text.?);
    try std.testing.expectEqual(@as(?Keysym, b), first.symbol);
    const second = iterator_value.next().?;
    try std.testing.expectEqualSlices(Keysym, &.{c}, second.sequence);
    try std.testing.expect(second.text == null);
    try std.testing.expectEqual(@as(?Keysym, a), second.symbol);
    try std.testing.expect(iterator_value.next() == null);
}

test "Compose storage reserves a complete rule before private mutation" {
    comptime {
        alloc_phase.capacity.record(alloc_phase.capacity.witness(Storage, "xkb_compose_reserve"));
    }

    var storage = try Storage.init(std.testing.allocator, .{
        .sequence_symbols = 2,
        .text_bytes = 3,
    });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    try storage.acquire();
    defer storage.reset();
    const a: Keysym = @fromBackingInt(@intCast('a'));
    const b: Keysym = @fromBackingInt(@intCast('b'));
    const c: Keysym = @fromBackingInt(@intCast('c'));
    try storage.insert(&.{a}, .{ .text = "ok" });
    const before = storage.status();
    try std.testing.expectError(
        error.SequenceSymbolCapacityExceeded,
        storage.insert(&.{ b, c }, .{ .text = "x" }),
    );
    try std.testing.expectEqual(before, storage.status());
    try std.testing.expectError(
        error.TextByteCapacityExceeded,
        storage.insert(&.{b}, .{ .text = "xx" }),
    );
    try std.testing.expectEqual(before, storage.status());
}

comptime {
    alloc_phase.capacity.requireAllocatorRejectingOwnerShape(Storage);
}
