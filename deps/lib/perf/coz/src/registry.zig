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
