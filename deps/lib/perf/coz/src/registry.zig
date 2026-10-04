const std = @import("std");

const abi = @import("abi.zig");
const progress_point = @import("point.zig");

pub const Registry = struct {
    mutex: std.atomic.Mutex = .unlocked,
    throughput_points: std.StringHashMapUnmanaged(*progress_point.ThroughputPoint) = .empty,
    latency_points: std.StringHashMapUnmanaged(*progress_point.LatencyPoint) = .empty,

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        var throughput_iter = self.throughput_points.iterator();
        while (throughput_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.destroy(entry.value_ptr.*);
        }
        self.throughput_points.deinit(allocator);

        var latency_iter = self.latency_points.iterator();
        while (latency_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.destroy(entry.value_ptr.*);
        }
        self.latency_points.deinit(allocator);

        self.throughput_points = .empty;
        self.latency_points = .empty;
    }

    pub fn getThroughputPoint(
        self: *Registry,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !*progress_point.ThroughputPoint {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        if (self.throughput_points.get(name)) |point| return point;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        const point = try allocator.create(progress_point.ThroughputPoint);
        errdefer allocator.destroy(point);
        point.* = progress_point.ThroughputPoint.init(owned_name);

        try self.throughput_points.put(allocator, owned_name, point);
        return point;
    }

    pub fn getLatencyPoint(
        self: *Registry,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) !*progress_point.LatencyPoint {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        if (self.latency_points.get(name)) |point| return point;

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        const point = try allocator.create(progress_point.LatencyPoint);
        errdefer allocator.destroy(point);
        point.* = progress_point.LatencyPoint.init(owned_name);

        try self.latency_points.put(allocator, owned_name, point);
        return point;
    }

    pub fn getCounter(
        self: *Registry,
        allocator: std.mem.Allocator,
        kind: abi.CounterKind,
        name: []const u8,
    ) !*abi.Counter {
        return switch (kind) {
            .throughput => (try self.getThroughputPoint(allocator, name)).counterStruct(),
            .begin => (try self.getLatencyPoint(allocator, name)).beginCounterStruct(),
            .end => (try self.getLatencyPoint(allocator, name)).endCounterStruct(),
        };
    }

    pub fn saveThroughputSnapshots(
        self: *Registry,
        allocator: std.mem.Allocator,
    ) ![]progress_point.ThroughputSnapshot {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        var snapshots: std.ArrayListUnmanaged(progress_point.ThroughputSnapshot) = .empty;
        errdefer snapshots.deinit(allocator);

        var iter = self.throughput_points.valueIterator();
        while (iter.next()) |point| {
            try snapshots.append(allocator, point.*.save());
        }

        return snapshots.toOwnedSlice(allocator);
    }

    pub fn saveLatencySnapshots(
        self: *Registry,
        allocator: std.mem.Allocator,
    ) ![]progress_point.LatencySnapshot {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        var snapshots: std.ArrayListUnmanaged(progress_point.LatencySnapshot) = .empty;
        errdefer snapshots.deinit(allocator);

        var iter = self.latency_points.valueIterator();
        while (iter.next()) |point| {
            try snapshots.append(allocator, point.*.save());
        }

        return snapshots.toOwnedSlice(allocator);
    }
};

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

test "registry returns a stable throughput counter by name" {
    var registry: Registry = .{};
    defer registry.deinit(std.testing.allocator);

    const first = try registry.getThroughputPoint(std.testing.allocator, "items");
    const second = try registry.getThroughputPoint(std.testing.allocator, "items");

    try std.testing.expectEqual(first, second);

    const counter = try registry.getCounter(std.testing.allocator, .throughput, "items");
    _ = @atomicRmw(usize, &counter.count, .Add, 3, .monotonic);

    try std.testing.expectEqual(@as(usize, 3), first.getCount());
}

test "registry keeps throughput and latency points separate" {
    var registry: Registry = .{};
    defer registry.deinit(std.testing.allocator);

    const throughput = try registry.getThroughputPoint(std.testing.allocator, "operation");
    const latency = try registry.getLatencyPoint(std.testing.allocator, "operation");

    throughput.visit(4);
    latency.visitBegin(5);
    latency.visitEnd(2);

    try std.testing.expectEqual(@as(usize, 4), throughput.getCount());
    try std.testing.expectEqual(@as(usize, 5), latency.getBeginCount());
    try std.testing.expectEqual(@as(usize, 2), latency.getEndCount());
}

test "registry returns stable latency begin and end counters by name" {
    var registry: Registry = .{};
    defer registry.deinit(std.testing.allocator);

    const first_begin = try registry.getCounter(std.testing.allocator, .begin, "request");
    const second_begin = try registry.getCounter(std.testing.allocator, .begin, "request");
    const end = try registry.getCounter(std.testing.allocator, .end, "request");

    try std.testing.expectEqual(first_begin, second_begin);
    try std.testing.expect(first_begin != end);

    _ = @atomicRmw(usize, &first_begin.count, .Add, 7, .monotonic);
    _ = @atomicRmw(usize, &end.count, .Add, 3, .monotonic);

    const point = try registry.getLatencyPoint(std.testing.allocator, "request");
    try std.testing.expectEqual(@as(usize, 7), point.getBeginCount());
    try std.testing.expectEqual(@as(usize, 3), point.getEndCount());
}

test "registry snapshots record deltas from all owned points" {
    var registry: Registry = .{};
    defer registry.deinit(std.testing.allocator);

    const throughput = try registry.getThroughputPoint(std.testing.allocator, "items");
    const latency = try registry.getLatencyPoint(std.testing.allocator, "request");

    throughput.visit(2);
    latency.visitBegin(1);

    const throughput_snapshots = try registry.saveThroughputSnapshots(std.testing.allocator);
    defer std.testing.allocator.free(throughput_snapshots);

    const latency_snapshots = try registry.saveLatencySnapshots(std.testing.allocator);
    defer std.testing.allocator.free(latency_snapshots);

    throughput.visit(5);
    latency.visitBegin(4);
    latency.visitEnd(3);

    try std.testing.expectEqual(@as(usize, 1), throughput_snapshots.len);
    try std.testing.expectEqual(@as(usize, 1), latency_snapshots.len);
    try std.testing.expectEqualStrings("items", throughput_snapshots[0].getName());
    try std.testing.expectEqual(@as(usize, 5), throughput_snapshots[0].getDelta());
    try std.testing.expectEqualStrings("request", latency_snapshots[0].getName());
    try std.testing.expectEqual(@as(usize, 4), latency_snapshots[0].getBeginDelta());
    try std.testing.expectEqual(@as(usize, 3), latency_snapshots[0].getEndDelta());
}
