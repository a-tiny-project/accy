const std = @import("std");
const ir = @import("../../core/root.zig");
const position = @import("position.zig");
const range = @import("range.zig");

pub fn ValueLocationIndex(comptime Register: type) type {
    const Range = range.ValueLocationRange(Register);
    const Link = struct {
        range_index: usize,
        next: ?usize,
    };
    const no_link = std.math.maxInt(usize);
    const Chain = struct {
        first: usize = no_link,
        last: usize = no_link,
    };
    const no_interval = std.math.maxInt(usize);
    const IntervalNode = struct {
        range_index: usize,
        start: u64,
        end: u64,
        max_end: u64,
        left: usize = no_interval,
        right: usize = no_interval,
    };

    return struct {
        value_keys: std.ArrayListUnmanaged(usize) = .empty,
        value_heads: std.ArrayListUnmanaged(Chain) = .empty,
        value_links: std.ArrayListUnmanaged(Link) = .empty,
        register_roots: std.AutoHashMapUnmanaged(Register, usize) = .empty,
        register_intervals: std.ArrayListUnmanaged(IntervalNode) = .empty,
        start_heads: std.ArrayListUnmanaged(Chain) = .empty,
        start_links: std.ArrayListUnmanaged(Link) = .empty,
        end_heads: std.ArrayListUnmanaged(Chain) = .empty,
        end_links: std.ArrayListUnmanaged(Link) = .empty,

        const Self = @This();

        pub const Iterator = struct {
            links: []const Link,
            link_index: ?usize,

            pub fn next(self: *Iterator) ?usize {
                const index = self.link_index orelse return null;
                const link = self.links[index];
                self.link_index = link.next;
                return link.range_index;
            }
        };

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.value_keys.deinit(allocator);
            self.value_heads.deinit(allocator);
            self.value_links.deinit(allocator);
            self.register_roots.deinit(allocator);
            self.register_intervals.deinit(allocator);
            self.start_heads.deinit(allocator);
            self.start_links.deinit(allocator);
            self.end_heads.deinit(allocator);
            self.end_links.deinit(allocator);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.value_keys.clearRetainingCapacity();
            self.value_heads.clearRetainingCapacity();
            self.value_links.clearRetainingCapacity();
            self.register_roots.clearRetainingCapacity();
            self.register_intervals.clearRetainingCapacity();
            self.start_heads.clearRetainingCapacity();
            self.start_links.clearRetainingCapacity();
            self.end_heads.clearRetainingCapacity();
            self.end_links.clearRetainingCapacity();
        }

        pub fn prepare(
            self: *Self,
            allocator: std.mem.Allocator,
            value_capacity: usize,
            position_count: usize,
            range_capacity: usize,
            register_capacity: usize,
        ) !void {
            self.clearRetainingCapacity();
            try self.value_keys.ensureTotalCapacityPrecise(allocator, value_capacity);
            try self.value_heads.ensureTotalCapacityPrecise(allocator, value_capacity);
            try resizeHeads(&self.start_heads, allocator, position_count);
            try resizeHeads(&self.end_heads, allocator, position_count);
            try self.value_links.ensureTotalCapacityPrecise(allocator, range_capacity);
            try self.register_roots.ensureTotalCapacity(allocator, @intCast(register_capacity));
            try self.register_intervals.ensureTotalCapacityPrecise(allocator, range_capacity);
            try self.start_links.ensureTotalCapacityPrecise(allocator, range_capacity);
            try self.end_links.ensureTotalCapacityPrecise(allocator, range_capacity);
        }

        pub fn includeValue(self: *Self, value: *ir.Value) void {
            std.debug.assert(self.value_keys.items.len < self.value_keys.capacity);
            self.value_keys.appendAssumeCapacity(valueKey(value));
        }

        pub fn sealValues(self: *Self, allocator: std.mem.Allocator) !void {
            std.mem.sort(usize, self.value_keys.items, {}, std.sort.asc(usize));
            if (self.value_keys.items.len != 0) {
                var count: usize = 1;
                for (self.value_keys.items[1..]) |key| {
                    if (key == self.value_keys.items[count - 1]) continue;
                    self.value_keys.items[count] = key;
                    count += 1;
                }
                self.value_keys.items.len = count;
            }
            try resizeHeads(&self.value_heads, allocator, self.value_keys.items.len);
        }

        pub fn rebuild(self: *Self, allocator: std.mem.Allocator, ranges: []const Range) !void {
            var position_count: usize = 0;
            for (ranges) |entry| {
                position_count = @max(position_count, @as(usize, @max(entry.start, entry.end)) + 1);
            }
            try self.prepare(allocator, ranges.len, position_count, ranges.len, ranges.len);
            for (ranges) |entry| self.includeValue(entry.value);
            try self.sealValues(allocator);
            for (ranges, 0..) |entry, index| self.append(index, entry);
        }

        pub fn append(self: *Self, range_index: usize, entry: Range) void {
            const value_index = self.valueIndex(entry.value) orelse unreachable;
            appendDenseLink(&self.value_heads, &self.value_links, value_index, range_index);
            self.appendRegisterInterval(range_index, entry);
            appendDenseLink(&self.start_heads, &self.start_links, entry.start, range_index);
            appendDenseLink(&self.end_heads, &self.end_links, entry.end, range_index);
        }

        pub fn valueLocationAtPoint(self: Self, ranges: []const Range, value: *ir.Value, point: position.Point) ?Register {
            const location = self.valueRangeAtPoint(ranges, value, point) orelse return null;
            return location.reg;
        }

        pub fn valueRangeAtPoint(self: Self, ranges: []const Range, value: *ir.Value, point: position.Point) ?Range {
            var iterator = self.valueIterator(value);
            while (iterator.next()) |index| {
                const entry = ranges[index];
                if (entry.coversValueAt(value, point)) return entry;
            }
            return null;
        }

        pub fn valueHasRangeAtPoint(self: Self, ranges: []const Range, value: *ir.Value, point: position.Point) bool {
            return self.valueLocationAtPoint(ranges, value, point) != null;
        }

        pub fn valueHasLocationRange(self: Self, value: *ir.Value) bool {
            const value_index = self.valueIndex(value) orelse return false;
            return headAt(self.value_heads.items, value_index) != null;
        }

        pub fn valueHasEntry(self: Self, ranges: []const Range, value: *ir.Value, entry: range.Entry) bool {
            var iterator = self.valueIterator(value);
            while (iterator.next()) |index| {
                if (ranges[index].entry == entry) return true;
            }
            return false;
        }

        pub fn valueLocationStart(self: Self, ranges: []const Range, value: *ir.Value) ?u32 {
            var iterator = self.valueIterator(value);
            const index = iterator.next() orelse return null;
            return ranges[index].start;
        }

        pub fn registerBlocksAt(self: Self, reg: Register, point: position.Point) bool {
            const root = self.register_roots.get(reg) orelse no_interval;
            return self.firstRegisterOverlap(root, point.rank(), point.rank()) != null;
        }

        pub fn registerRangeFirstOverlapStart(
            self: Self,
            ranges: []const Range,
            value: *ir.Value,
            start: u32,
            end: u32,
            reg: Register,
            entry: range.Entry,
            end_phase: position.Phase,
        ) ?position.Point {
            if (start >= end) return null;
            const proposed = Range{
                .value = value,
                .start = start,
                .end = end,
                .reg = reg,
                .entry = entry,
                .end_phase = end_phase,
            };
            const proposed_start = proposed.startPoint().rank();
            const proposed_end = proposed.endPoint().rank();
            if (proposed_start > proposed_end) return null;
            const range_index = self.firstRegisterOverlap(
                self.register_roots.get(reg) orelse no_interval,
                proposed_start,
                proposed_end,
            ) orelse return null;
            const existing = ranges[range_index];
            return if (existing.startPoint().lessThan(proposed.startPoint())) proposed.startPoint() else existing.startPoint();
        }

        pub fn rangesStartingAt(self: Self, point: u32) Iterator {
            return eventIterator(headAt(self.start_heads.items, point), self.start_links.items);
        }

        pub fn rangesEndingAt(self: Self, point: u32) Iterator {
            return eventIterator(headAt(self.end_heads.items, point), self.end_links.items);
        }

        fn valueIterator(self: Self, value: *ir.Value) Iterator {
            const value_index = self.valueIndex(value) orelse return eventIterator(null, self.value_links.items);
            return eventIterator(headAt(self.value_heads.items, value_index), self.value_links.items);
        }

        fn eventIterator(chain: ?Chain, links: []const Link) Iterator {
            return .{ .links = links, .link_index = if (chain) |entry| entry.first else null };
        }

        fn appendRegisterInterval(self: *Self, range_index: usize, entry: Range) void {
            const start = entry.startPoint().rank();
            const end = entry.endPoint().rank();
            const node_index = self.register_intervals.items.len;
            std.debug.assert(node_index < self.register_intervals.capacity);
            self.register_intervals.appendAssumeCapacity(.{
                .range_index = range_index,
                .start = start,
                .end = end,
                .max_end = end,
            });
            const root = self.insertRegisterInterval(self.register_roots.get(entry.reg) orelse no_interval, node_index);
            self.register_roots.putAssumeCapacity(entry.reg, root);
        }

        fn insertRegisterInterval(self: *Self, root_index: usize, node_index: usize) usize {
            if (root_index == no_interval) return node_index;
            if (intervalBefore(self.register_intervals.items[node_index], self.register_intervals.items[root_index])) {
                const child = self.insertRegisterInterval(self.register_intervals.items[root_index].left, node_index);
                self.register_intervals.items[root_index].left = child;
                if (intervalPriority(self.register_intervals.items[child].range_index) < intervalPriority(self.register_intervals.items[root_index].range_index)) {
                    return self.rotateRegisterRight(root_index);
                }
            } else {
                const child = self.insertRegisterInterval(self.register_intervals.items[root_index].right, node_index);
                self.register_intervals.items[root_index].right = child;
                if (intervalPriority(self.register_intervals.items[child].range_index) < intervalPriority(self.register_intervals.items[root_index].range_index)) {
                    return self.rotateRegisterLeft(root_index);
                }
            }
            self.updateRegisterMaxEnd(root_index);
            return root_index;
        }

        fn rotateRegisterRight(self: *Self, root_index: usize) usize {
            const pivot_index = self.register_intervals.items[root_index].left;
            self.register_intervals.items[root_index].left = self.register_intervals.items[pivot_index].right;
            self.register_intervals.items[pivot_index].right = root_index;
            self.updateRegisterMaxEnd(root_index);
            self.updateRegisterMaxEnd(pivot_index);
            return pivot_index;
        }

        fn rotateRegisterLeft(self: *Self, root_index: usize) usize {
            const pivot_index = self.register_intervals.items[root_index].right;
            self.register_intervals.items[root_index].right = self.register_intervals.items[pivot_index].left;
            self.register_intervals.items[pivot_index].left = root_index;
            self.updateRegisterMaxEnd(root_index);
            self.updateRegisterMaxEnd(pivot_index);
            return pivot_index;
        }

        fn updateRegisterMaxEnd(self: *Self, node_index: usize) void {
            const node = &self.register_intervals.items[node_index];
            node.max_end = node.end;
            if (node.left != no_interval) node.max_end = @max(node.max_end, self.register_intervals.items[node.left].max_end);
            if (node.right != no_interval) node.max_end = @max(node.max_end, self.register_intervals.items[node.right].max_end);
        }

        fn firstRegisterOverlap(self: Self, node_index: usize, start: u64, end: u64) ?usize {
            if (node_index == no_interval) return null;
            const node = self.register_intervals.items[node_index];
            if (node.left != no_interval and self.register_intervals.items[node.left].max_end >= start) {
                if (self.firstRegisterOverlap(node.left, start, end)) |range_index| return range_index;
            }
            if (node.start <= end and node.end >= start) return node.range_index;
            if (node.start > end) return null;
            return self.firstRegisterOverlap(node.right, start, end);
        }

        fn intervalBefore(lhs: IntervalNode, rhs: IntervalNode) bool {
            if (lhs.start != rhs.start) return lhs.start < rhs.start;
            return lhs.range_index < rhs.range_index;
        }

        fn intervalPriority(range_index: usize) u64 {
            var value = @as(u64, @intCast(range_index)) +% 0x9e3779b97f4a7c15;
            value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
            value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
            return value ^ (value >> 31);
        }

        fn appendDenseLink(
            heads: *std.ArrayListUnmanaged(Chain),
            links: *std.ArrayListUnmanaged(Link),
            key: usize,
            range_index: usize,
        ) void {
            std.debug.assert(key < heads.items.len);
            const link_index = links.items.len;
            std.debug.assert(link_index < links.capacity);
            links.appendAssumeCapacity(.{ .range_index = range_index, .next = null });
            const head = &heads.items[key];
            if (head.first != no_link) {
                links.items[head.last].next = link_index;
                head.last = link_index;
            } else {
                head.* = .{ .first = link_index, .last = link_index };
            }
        }

        fn resizeHeads(
            heads: *std.ArrayListUnmanaged(Chain),
            allocator: std.mem.Allocator,
            count: usize,
        ) !void {
            const old_len = heads.items.len;
            if (count <= old_len) return;
            try heads.ensureTotalCapacityPrecise(allocator, count);
            try heads.resize(allocator, count);
            @memset(heads.items[old_len..], .{});
        }

        fn headAt(heads: []const Chain, index: usize) ?Chain {
            if (index >= heads.len) return null;
            return if (heads[index].first == no_link) null else heads[index];
        }

        fn valueIndex(self: Self, value: *ir.Value) ?usize {
            return std.sort.binarySearch(usize, self.value_keys.items, valueKey(value), valueKeyOrder);
        }

        fn valueKey(value: *ir.Value) usize {
            return @intFromPtr(value);
        }

        fn valueKeyOrder(key: usize, candidate: usize) std.math.Order {
            return std.math.order(key, candidate);
        }
    };
}
