const std = @import("std");
const abi = @import("abi.zig");

pub const ThroughputPoint = struct {
    name: []const u8,
    counter: abi.Counter = .{},

    pub fn init(name: []const u8) ThroughputPoint {
        return .{ .name = name };
    }

    pub fn save(self: *const ThroughputPoint) ThroughputSnapshot {
        return .{
            .origin = self,
            .start_count = self.getCount(),
        };
    }

    pub fn visit(self: *ThroughputPoint, visits: usize) void {
        _ = @atomicRmw(usize, &self.counter.count, .Add, visits, .monotonic);
    }

    pub fn getCount(self: *const ThroughputPoint) usize {
        return @atomicLoad(usize, &self.counter.count, .monotonic);
    }

    pub fn counterStruct(self: *ThroughputPoint) *abi.Counter {
        return &self.counter;
    }
};

pub const ThroughputSnapshot = struct {
    origin: *const ThroughputPoint,
    start_count: usize,

    pub fn log(self: ThroughputSnapshot, writer: *std.Io.Writer) !void {
        try writer.print("throughput-point\tname={s}\tdelta={d}\n", .{
            self.getName(),
            self.getDelta(),
        });
    }

    pub fn getDelta(self: ThroughputSnapshot) usize {
        return self.origin.getCount() -% self.start_count;
    }

    pub fn getName(self: ThroughputSnapshot) []const u8 {
        return self.origin.name;
    }
};

pub const LatencyPoint = struct {
    name: []const u8,
    begin_counter: abi.Counter = .{},
    end_counter: abi.Counter = .{},

    pub fn init(name: []const u8) LatencyPoint {
        return .{ .name = name };
    }

    pub fn save(self: *const LatencyPoint) LatencySnapshot {
        return .{
            .origin = self,
            .begin_start_count = self.getBeginCount(),
            .end_start_count = self.getEndCount(),
        };
    }

    pub fn visitBegin(self: *LatencyPoint, visits: usize) void {
        _ = @atomicRmw(usize, &self.begin_counter.count, .Add, visits, .monotonic);
    }

    pub fn visitEnd(self: *LatencyPoint, visits: usize) void {
        _ = @atomicRmw(usize, &self.end_counter.count, .Add, visits, .monotonic);
    }

    pub fn getBeginCount(self: *const LatencyPoint) usize {
        return @atomicLoad(usize, &self.begin_counter.count, .monotonic);
    }

    pub fn getEndCount(self: *const LatencyPoint) usize {
        return @atomicLoad(usize, &self.end_counter.count, .monotonic);
    }

    pub fn beginCounterStruct(self: *LatencyPoint) *abi.Counter {
        return &self.begin_counter;
    }

    pub fn endCounterStruct(self: *LatencyPoint) *abi.Counter {
        return &self.end_counter;
    }
};

pub const LatencySnapshot = struct {
    origin: *const LatencyPoint,
    begin_start_count: usize,
    end_start_count: usize,

    pub fn log(self: LatencySnapshot, writer: *std.Io.Writer) !void {
        try writer.print("latency-point\tname={s}\tarrivals={d}\tdepartures={d}\tdifference={d}\n", .{
            self.getName(),
            self.getBeginDelta(),
            self.getEndDelta(),
            self.getDifference(),
        });
    }

    pub fn getBeginDelta(self: LatencySnapshot) usize {
        return self.origin.getBeginCount() -% self.begin_start_count;
    }

    pub fn getEndDelta(self: LatencySnapshot) usize {
        return self.origin.getEndCount() -% self.end_start_count;
    }

    pub fn getDifference(self: LatencySnapshot) usize {
        return self.origin.getBeginCount() -% self.origin.getEndCount();
    }

    pub fn getName(self: LatencySnapshot) []const u8 {
        return self.origin.name;
    }
};
