const std = @import("std");
const ir = @import("../core/root.zig");
const node_mod = @import("node.zig");

pub const ClassId = node_mod.ClassId;
pub const ValueEntry = node_mod.ValueEntry;
pub const Node = node_mod.Node;

const Class = struct {
    parent: ClassId,
    rank: u8 = 0,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    values: std.ArrayListUnmanaged(ValueEntry) = .empty,

    fn init(id: ClassId) Class {
        return .{ .parent = id };
    }

    fn deinit(self: *Class, allocator: std.mem.Allocator) void {
        for (self.nodes.items) |*node| {
            node.deinit(allocator);
        }
        self.nodes.deinit(allocator);
        self.values.deinit(allocator);
    }
};

pub const GraphStats = struct {
    classes_created: usize = 0,
    nodes_added: usize = 0,
    unions: usize = 0,
    rebuilds: usize = 0,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    classes: std.ArrayListUnmanaged(Class) = .empty,
    memo: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(ClassId)) = .empty,
    stats: GraphStats = .{},

    /// Cumulative allocation traffic for a graph whose rules only merge existing
    /// classes. Counts cover all blocks together; each class and collision bucket
    /// may grow to the entire population. Rebuild passes include terminal scans.
    pub fn mergeStorageBound(
        node_count: u64,
        atoms: u64,
        graphs: u64,
        rebuild_passes: u64,
    ) !u64 {
        if (node_count > std.math.maxInt(u32)) return error.CapacityOverflow;
        const classes = try mul(graphs, try listStorage(Class, node_count));
        const contents = try mul(node_count, try sum(
            try listStorage(Node, node_count),
            try listStorage(ValueEntry, node_count),
        ));
        const payload_item = @sizeOf(ClassId) + @sizeOf(ir.Type) +
            2 * @sizeOf(ir.NamedAttribute) + 64;
        const payload = try mul(try mul(2, atoms), payload_item);
        const table = try mul(graphs, try memoStorage(node_count));
        const buckets = try mul(node_count, try listStorage(ClassId, 1));
        const pairs = try listStorage(struct { lhs: ClassId, rhs: ClassId }, node_count);
        const rebuilds = try mul(rebuild_passes, try sum(buckets, pairs));
        return sum(try sum(classes, contents), try sum(payload, try sum(
            table,
            try sum(buckets, rebuilds),
        )));
    }

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Graph) void {
        self.clearMemo();
        self.memo.deinit(self.allocator);
        for (self.classes.items) |*class| {
            class.deinit(self.allocator);
        }
        self.classes.deinit(self.allocator);
    }

    pub fn find(self: *Graph, id: ClassId) ClassId {
        const idx: usize = @intCast(id.index);
        const parent = self.classes.items[idx].parent;
        if (parent.eql(id)) return id;
        const root = self.find(parent);
        self.classes.items[idx].parent = root;
        return root;
    }

    pub fn classCount(self: *const Graph) usize {
        return self.classes.items.len;
    }

    pub fn addValue(self: *Graph, value: *ir.Value, cost: u32, order: usize) !ClassId {
        var node = Node.valueNode(value);
        const id = try self.addNode(&node);
        try self.attachValue(id, value, cost, order);
        return id;
    }

    pub fn addOperation(
        self: *Graph,
        op: *ir.Operation,
        operands: []const ClassId,
        cost: u32,
        order: usize,
    ) !ClassId {
        var node = try Node.operationNode(self.allocator, op, operands, op.hasTrait("is_commutative"));
        defer node.deinit(self.allocator);
        self.canonicalizeNode(&node);
        const id = try self.addNode(&node);
        if (op.getResult(0)) |value| {
            try self.attachValue(id, value, cost, order);
        }
        return id;
    }

    pub fn addNode(self: *Graph, node: *const Node) !ClassId {
        const hash = node.hash();
        if (self.memo.get(hash)) |ids| {
            for (ids.items) |candidate| {
                const root = self.find(candidate);
                const class = &self.classes.items[@intCast(root.index)];
                for (class.nodes.items) |*existing| {
                    if (existing.eql(node)) return root;
                }
            }
        }

        const id = ClassId{ .index = @intCast(self.classes.items.len) };
        var class = Class.init(id);
        var class_owned = true;
        errdefer if (class_owned) class.deinit(self.allocator);

        var owned = try node.clone(self.allocator);
        var owned_in_class = false;
        errdefer if (!owned_in_class) owned.deinit(self.allocator);
        try class.nodes.append(self.allocator, owned);
        owned_in_class = true;

        try self.classes.append(self.allocator, class);
        class_owned = false;
        try self.insertMemo(hash, id);
        self.stats.classes_created += 1;
        self.stats.nodes_added += 1;
        return id;
    }

    pub fn attachValue(self: *Graph, id: ClassId, value: *ir.Value, cost: u32, order: usize) !void {
        const root = self.find(id);
        try self.attachValueToRoot(root, .{ .value = value, .cost = cost, .order = order });
    }

    pub fn representativeValue(self: *Graph, id: ClassId) ?ValueEntry {
        const root = self.find(id);
        const class = &self.classes.items[@intCast(root.index)];
        if (class.values.items.len == 0) return null;

        var best = class.values.items[0];
        for (class.values.items[1..]) |candidate| {
            if (candidate.cost < best.cost or
                (candidate.cost == best.cost and candidate.order < best.order))
            {
                best = candidate;
            }
        }
        return best;
    }

    pub fn nodes(self: *Graph, id: ClassId) []const Node {
        const root = self.find(id);
        return self.classes.items[@intCast(root.index)].nodes.items;
    }

    pub fn classValues(self: *Graph, id: ClassId) []const ValueEntry {
        const root = self.find(id);
        return self.classes.items[@intCast(root.index)].values.items;
    }

    pub fn merge(self: *Graph, lhs: ClassId, rhs: ClassId) !bool {
        var lhs_root = self.find(lhs);
        var rhs_root = self.find(rhs);
        if (lhs_root.eql(rhs_root)) return false;

        var lhs_class = &self.classes.items[@intCast(lhs_root.index)];
        var rhs_class = &self.classes.items[@intCast(rhs_root.index)];
        if (lhs_class.rank < rhs_class.rank) {
            const tmp_root = lhs_root;
            lhs_root = rhs_root;
            rhs_root = tmp_root;

            const tmp_class = lhs_class;
            lhs_class = rhs_class;
            rhs_class = tmp_class;
        }

        try lhs_class.nodes.appendSlice(self.allocator, rhs_class.nodes.items);
        rhs_class.nodes.clearRetainingCapacity();

        for (rhs_class.values.items) |entry| {
            try self.attachValueToRoot(lhs_root, entry);
        }
        rhs_class.values.clearRetainingCapacity();

        rhs_class.parent = lhs_root;
        if (lhs_class.rank == rhs_class.rank) {
            lhs_class.rank += 1;
        }

        self.stats.unions += 1;
        return true;
    }

    pub fn rebuild(self: *Graph) !bool {
        var any_changed = false;
        while (try self.rebuildOnce()) {
            any_changed = true;
            self.stats.rebuilds += 1;
        }
        return any_changed;
    }

    fn attachValueToRoot(self: *Graph, root: ClassId, entry: ValueEntry) !void {
        const class = &self.classes.items[@intCast(root.index)];
        for (class.values.items) |*existing| {
            if (existing.value == entry.value) {
                if (entry.cost < existing.cost or
                    (entry.cost == existing.cost and entry.order < existing.order))
                {
                    existing.cost = entry.cost;
                    existing.order = entry.order;
                }
                return;
            }
        }
        try class.values.append(self.allocator, entry);
    }

    fn canonicalizeNode(self: *Graph, node: *Node) void {
        if (node.kind != .operation) return;
        for (node.operands) |*operand| {
            operand.* = self.find(operand.*);
        }
        node.normalizeOperands();
    }

    fn rebuildOnce(self: *Graph) !bool {
        self.clearMemo();

        var pairs: std.ArrayListUnmanaged(struct { lhs: ClassId, rhs: ClassId }) = .empty;
        defer pairs.deinit(self.allocator);

        for (self.classes.items, 0..) |*class, index| {
            const id = ClassId{ .index = @intCast(index) };
            const root = self.find(id);
            if (!root.eql(id)) continue;

            for (class.nodes.items) |*node| {
                self.canonicalizeNode(node);
                const hash = node.hash();
                var found: ?ClassId = null;
                if (self.memo.get(hash)) |ids| {
                    for (ids.items) |candidate| {
                        const candidate_root = self.find(candidate);
                        const candidate_class = &self.classes.items[@intCast(candidate_root.index)];
                        for (candidate_class.nodes.items) |*existing| {
                            if (existing.eql(node)) {
                                found = candidate_root;
                                break;
                            }
                        }
                        if (found != null) break;
                    }
                }

                if (found) |existing| {
                    if (!existing.eql(root)) {
                        try pairs.append(self.allocator, .{ .lhs = root, .rhs = existing });
                    }
                } else {
                    try self.insertMemo(hash, root);
                }
            }
        }

        var changed = false;
        for (pairs.items) |pair| {
            if (try self.merge(pair.lhs, pair.rhs)) {
                changed = true;
            }
        }
        return changed;
    }

    fn insertMemo(self: *Graph, hash: u64, id: ClassId) !void {
        var gop = try self.memo.getOrPut(self.allocator, hash);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        const root = self.find(id);
        for (gop.value_ptr.items) |existing| {
            if (self.find(existing).eql(root)) return;
        }
        try gop.value_ptr.append(self.allocator, root);
    }

    fn clearMemo(self: *Graph) void {
        var iter = self.memo.valueIterator();
        while (iter.next()) |ids| {
            ids.deinit(self.allocator);
        }
        self.memo.clearRetainingCapacity();
    }
};

fn sum(a: u64, b: u64) !u64 {
    return std.math.add(u64, a, b) catch error.CapacityOverflow;
}

fn mul(a: u64, b: u64) !u64 {
    return std.math.mul(u64, a, b) catch error.CapacityOverflow;
}

fn listStorage(comptime Item: type, count: u64) !u64 {
    if (count == 0) return 0;
    return mul(try mul(4, try sum(try mul(4, count), 64)), @sizeOf(Item) + @alignOf(Item));
}

fn memoStorage(count: u64) !u64 {
    if (count == 0) return 0;
    const required = try sum(try mul(count, 100) / 80, 1);
    if (required > std.math.maxInt(u32)) return error.CapacityOverflow;
    const capacity = std.math.ceilPowerOfTwo(u32, @intCast(required)) catch
        return error.CapacityOverflow;
    if (capacity > std.math.maxInt(u32) / 80) return error.CapacityOverflow;
    const bytes = 1 + @sizeOf(u64) + @sizeOf(std.ArrayListUnmanaged(ClassId)) +
        4 * @sizeOf(usize) + 3 * @alignOf(usize);
    return mul(try mul(2, @max(8, capacity)), bytes);
}

fn checkMergeStorage(count: u32) !void {
    const allocator = std.testing.allocator;
    const fixed = @import("alloc_fixed");
    var context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer context.deinit(allocator);
    const bound = try Graph.mergeStorageBound(count, count, 1, count + 2);
    const storage = try allocator.alignedAlloc(u8, .@"64", @intCast(bound));
    defer allocator.free(storage);
    var backing = fixed.Tracked.init(storage);
    var retained = fixed.Monotonic.init(backing.allocator(), @intCast(bound));
    var graph = Graph.init(retained.allocator());
    defer graph.deinit();
    for (0..count) |index| {
        var attrs = [_]ir.NamedAttribute{.{
            .name = "value",
            .value = try context.getI64Attr(@intCast(index)),
        }};
        const node = Node{ .kind = .operation, .op_name = "test.node", .attributes = &attrs };
        _ = try graph.addNode(&node);
    }
    graph.clearMemo();
    for (0..count) |index| try graph.insertMemo(0, .{ .index = @intCast(index) });
    try std.testing.expectEqual(count, graph.memo.get(0).?.items.len);
    _ = try graph.rebuild();
    for (1..count) |index| {
        try std.testing.expect(try graph.merge(.{ .index = 0 }, .{ .index = @intCast(index) }));
        _ = try graph.rebuild();
    }
    try std.testing.expectEqual(count, graph.nodes(.{ .index = 0 }).len);
    try std.testing.expect(!backing.exhausted);
    const used = if (retained.current) |*current| fixed.used(current) else 0;
    try std.testing.expect(used <= bound);
}
