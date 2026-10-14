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
        /// One bit per range, set while `start <= live_position < end`. A query moves it to its
        /// own position by the start and end events between, in either direction, so a walk in
        /// position order touches each range twice in all.
        live_words: std.ArrayListUnmanaged(u64) = .empty,
        /// The indices of the nonzero `live_words`, so a query reads only the words that hold a
        /// live range rather than every word.
        occupied: std.ArrayListUnmanaged(usize) = .empty,
        /// Per word, its slot in `occupied`, or `not_occupied`.
        occupied_slots: std.ArrayListUnmanaged(usize) = .empty,
        /// The position `live_words` describes, or null before the first query.
        live_position: ?u32 = null,
        /// The answer of the last `rangesAtPoint`, which a range count bounds.
        found: std.ArrayListUnmanaged(usize) = .empty,

        const Self = @This();
        const not_occupied = std.math.maxInt(usize);

        /// The memory one function's index holds, derived from the counts `prepare` takes, so a
        /// caller can print it, check it, or size a limit from it before asking for it.
        pub const Capacity = struct {
            value_count: usize,
            position_count: usize,
            range_count: usize,
            register_count: usize,
            /// Value keys and value chain heads.
            value_bytes: usize,
            /// Start and end chain heads, one per position each.
            position_bytes: usize,
            /// Value, start and end links, interval nodes and the found list, each one per range.
            range_bytes: usize,
            /// Live words, the occupied list and its slots, each one per 64 ranges.
            word_bytes: usize,

            pub const Error = error{CapacityOverflow};

            pub fn derive(
                value_count: usize,
                position_count: usize,
                range_count: usize,
                register_count: usize,
            ) Error!Capacity {
                const per_value = @sizeOf(usize) + @sizeOf(Chain);
                const per_range = 3 * @sizeOf(Link) + @sizeOf(IntervalNode) + @sizeOf(usize);
                const word_count = std.math.divCeil(usize, range_count, 64) catch unreachable;
                return .{
                    .value_count = value_count,
                    .position_count = position_count,
                    .range_count = range_count,
                    .register_count = register_count,
                    .value_bytes = std.math.mul(usize, value_count, per_value) catch
                        return error.CapacityOverflow,
                    .position_bytes = std.math.mul(usize, position_count, 2 * @sizeOf(Chain)) catch
                        return error.CapacityOverflow,
                    .range_bytes = std.math.mul(usize, range_count, per_range) catch
                        return error.CapacityOverflow,
                    .word_bytes = std.math.mul(usize, word_count, @sizeOf(u64) + 2 * @sizeOf(usize)) catch
                        return error.CapacityOverflow,
                };
            }

            /// Every byte above, plus the register roots, whose hash map sizes itself.
            pub fn listBytes(self: Capacity) Error!usize {
                var total = std.math.add(usize, self.value_bytes, self.position_bytes) catch
                    return error.CapacityOverflow;
                total = std.math.add(usize, total, self.range_bytes) catch
                    return error.CapacityOverflow;
                return std.math.add(usize, total, self.word_bytes) catch
                    return error.CapacityOverflow;
            }
        };

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
            self.live_words.deinit(allocator);
            self.occupied.deinit(allocator);
            self.occupied_slots.deinit(allocator);
            self.found.deinit(allocator);
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
            self.live_words.clearRetainingCapacity();
            self.occupied.clearRetainingCapacity();
            self.occupied_slots.clearRetainingCapacity();
            self.live_position = null;
            self.found.clearRetainingCapacity();
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
            const word_count = std.math.divCeil(usize, range_capacity, 64) catch unreachable;
            try self.live_words.ensureTotalCapacityPrecise(allocator, word_count);
            self.live_words.appendNTimesAssumeCapacity(0, word_count);
            try self.occupied.ensureTotalCapacityPrecise(allocator, word_count);
            try self.occupied_slots.ensureTotalCapacityPrecise(allocator, word_count);
            self.occupied_slots.appendNTimesAssumeCapacity(not_occupied, word_count);
            try self.found.ensureTotalCapacityPrecise(allocator, range_capacity);
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
            std.debug.assert(entry.start < entry.end);
            const value_index = self.valueIndex(entry.value) orelse unreachable;
            appendDenseLink(&self.value_heads, &self.value_links, value_index, range_index);
            self.appendRegisterInterval(range_index, entry);
            appendDenseLink(&self.start_heads, &self.start_links, entry.start, range_index);
            appendDenseLink(&self.end_heads, &self.end_links, entry.end, range_index);
            std.debug.assert(range_index / 64 < self.live_words.items.len);
            if (self.live_position != null) {
                for (self.occupied.items) |word_index| {
                    self.live_words.items[word_index] = 0;
                    self.occupied_slots.items[word_index] = not_occupied;
                }
                self.occupied.clearRetainingCapacity();
                self.live_position = null;
            }
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

        /// The values with at least one location range, each counted once however many it has.
        pub fn rangedValues(self: Self) usize {
            var count: usize = 0;
            for (0..self.value_keys.items.len) |value_index| {
                if (headAt(self.value_heads.items, value_index) != null) count += 1;
            }
            return count;
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

        /// The ranges appended to the index, which equals the ranges it answers for.
        pub fn rangeCount(self: Self) usize {
            return self.register_intervals.items.len;
        }

        /// The index of every range of `ranges` that holds `point`, in ascending range index,
        /// which is the order a scan of `ranges` would meet them in. The slice is the index's own
        /// and holds until the next query.
        ///
        /// A query costs the start and end events between the last queried position and this
        /// one, in either direction, then a sort of the occupied words and a read of their live
        /// bits. There are no more occupied words than live ranges, the sort leaves them in order
        /// for the next query, and the live ranges that miss the point are those starting or
        /// ending at its position on the other side of its phase, so the work follows the answer.
        pub fn rangesAtPoint(self: *Self, ranges: []const Range, point: position.Point) []const usize {
            std.debug.assert(ranges.len == self.rangeCount());
            self.sweepTo(point.position);
            std.mem.sortUnstable(usize, self.occupied.items, {}, std.sort.asc(usize));
            for (self.occupied.items, 0..) |word_index, slot| self.occupied_slots.items[word_index] = slot;
            self.found.clearRetainingCapacity();
            for (self.occupied.items) |word_index| {
                var bits = self.live_words.items[word_index];
                std.debug.assert(bits != 0);
                while (bits != 0) : (bits &= bits - 1) {
                    const range_index = word_index * 64 + @ctz(bits);
                    if (ranges[range_index].containsPoint(point)) self.found.appendAssumeCapacity(range_index);
                }
            }
            return self.found.items;
        }

        /// Moves `live_words` to the ranges with `start <= target < end`. Forward, a position adds the
        /// ranges starting there and drops those ending there. Backward, it undoes that: every
        /// range ends after it starts, so a range ending at a position started before it.
        fn sweepTo(self: *Self, target: u32) void {
            const last_event: u32 = @intCast(@max(self.start_heads.items.len, self.end_heads.items.len));
            const current = self.live_position orelse {
                var at: u32 = 0;
                while (at <= @min(target, last_event)) : (at += 1) self.advanceThrough(at);
                self.live_position = target;
                return;
            };
            if (current < target) {
                var at = current + 1;
                while (at <= @min(target, last_event)) : (at += 1) self.advanceThrough(at);
            } else {
                var at = @min(current, last_event);
                while (at > target) : (at -= 1) self.retreatThrough(at);
            }
            self.live_position = target;
        }

        fn advanceThrough(self: *Self, at: u32) void {
            var starts = self.rangesStartingAt(at);
            while (starts.next()) |range_index| self.enliven(range_index);
            var ends = self.rangesEndingAt(at);
            while (ends.next()) |range_index| self.retire(range_index);
        }

        fn retreatThrough(self: *Self, at: u32) void {
            var starts = self.rangesStartingAt(at);
            while (starts.next()) |range_index| self.retire(range_index);
            var ends = self.rangesEndingAt(at);
            while (ends.next()) |range_index| self.enliven(range_index);
        }

        fn enliven(self: *Self, range_index: usize) void {
            const word_index = range_index / 64;
            const bit = @as(u64, 1) << @intCast(range_index % 64);
            const word = &self.live_words.items[word_index];
            std.debug.assert(word.* & bit == 0);
            if (word.* == 0) {
                self.occupied_slots.items[word_index] = self.occupied.items.len;
                self.occupied.appendAssumeCapacity(word_index);
            }
            word.* |= bit;
        }

        fn retire(self: *Self, range_index: usize) void {
            const word_index = range_index / 64;
            const bit = @as(u64, 1) << @intCast(range_index % 64);
            const word = &self.live_words.items[word_index];
            std.debug.assert(word.* & bit != 0);
            word.* &= ~bit;
            if (word.* != 0) return;
            const slot = self.occupied_slots.items[word_index];
            const moved = self.occupied.items[self.occupied.items.len - 1];
            self.occupied.items[slot] = moved;
            self.occupied_slots.items[moved] = slot;
            self.occupied.items.len -= 1;
            self.occupied_slots.items[word_index] = not_occupied;
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

/// Fails unless `index`'s occupied list names exactly its nonzero live words, each once, and
/// each word's slot names its place in that list.
fn expectOccupiedConsistent(index: *const ValueLocationIndex(u8)) !void {
    const not_occupied = ValueLocationIndex(u8).not_occupied;
    var nonzero: usize = 0;
    for (index.live_words.items, index.occupied_slots.items, 0..) |word, slot, word_index| {
        if (word == 0) {
            try std.testing.expectEqual(not_occupied, slot);
            continue;
        }
        nonzero += 1;
        try std.testing.expect(slot < index.occupied.items.len);
        try std.testing.expectEqual(word_index, index.occupied.items[slot]);
    }
    try std.testing.expectEqual(nonzero, index.occupied.items.len);
}

/// Fails unless the sweep's answer at `point` is the ranges a scan finds there, in range order,
/// and leaves the occupied words sorted with their slots repaired.
fn expectSweepIsScan(
    index: *ValueLocationIndex(u8),
    ranges: []const range.ValueLocationRange(u8),
    point: position.Point,
) !void {
    const found = index.rangesAtPoint(ranges, point);
    var next: usize = 0;
    for (ranges, 0..) |entry, range_index| {
        if (!entry.containsPoint(point)) continue;
        try std.testing.expect(next < found.len);
        try std.testing.expectEqual(range_index, found[next]);
        next += 1;
    }
    try std.testing.expectEqual(found.len, next);
    try std.testing.expect(std.sort.isSorted(usize, index.occupied.items, {}, std.sort.asc(usize)));
    try expectOccupiedConsistent(index);
}
