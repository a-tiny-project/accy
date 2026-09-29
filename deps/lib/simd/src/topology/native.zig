const std = @import("std");
const builtin = @import("builtin");
const topology = @import("root.zig");
const linux = if (builtin.target.os.tag == .linux)
    @import("linux/root.zig")
else
    struct {};
const apple = if (builtin.target.os.tag.isDarwin())
    @import("apple/root.zig")
else
    struct {};
const windows = if (builtin.target.os.tag == .windows)
    @import("windows/root.zig")
else
    struct {};
const freebsd = if (builtin.target.os.tag == .freebsd)
    @import("freebsd/root.zig")
else
    struct {};
const wasm = if (builtin.target.os.tag == .emscripten)
    @import("wasm/root.zig")
else
    struct {};

var cache_guard: std.atomic.Mutex = .unlocked;
var cache_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var cache_storage: [4]topology.Cache align(64) = @splat(.{});

pub fn haveThreadingSupport() bool {
    if (comptime builtin.target.os.tag == .emscripten) {
        return wasm.haveThreadingSupport();
    }
    return if (comptime builtin.target.cpu.arch.isWasm())
        !builtin.single_threaded
    else
        true;
}

pub fn totalLogicalProcessors() usize {
    if (comptime builtin.target.os.tag == .linux) {
        return linux.totalLogicalProcessors();
    }
    if (comptime builtin.target.os.tag.isDarwin()) {
        return apple.totalLogicalProcessors();
    }
    if (comptime builtin.target.os.tag == .windows) {
        return windows.totalLogicalProcessors();
    }
    if (comptime builtin.target.os.tag == .emscripten) {
        return wasm.totalLogicalProcessors();
    }
    if (comptime builtin.target.os.tag == .freestanding) return 1;
    const count = std.Thread.getCpuCount() catch 1;
    return std.math.clamp(count, 1, topology.max_logical_processors);
}

pub fn getThreadAffinity(out: *topology.LogicalProcessorSet) bool {
    if (comptime builtin.target.os.tag == .linux) {
        return linux.getThreadAffinity(out);
    } else if (comptime builtin.target.os.tag == .windows) {
        return windows.getThreadAffinity(out);
    } else if (comptime builtin.target.os.tag == .freebsd) {
        return freebsd.getThreadAffinity(out);
    } else {
        return false;
    }
}

pub fn setThreadAffinity(lps: *const topology.LogicalProcessorSet) bool {
    if (comptime builtin.target.os.tag == .linux) {
        return linux.setThreadAffinity(lps);
    } else if (comptime builtin.target.os.tag == .windows) {
        return windows.setThreadAffinity(lps);
    } else if (comptime builtin.target.os.tag == .freebsd) {
        return freebsd.setThreadAffinity(lps);
    } else {
        return false;
    }
}

pub fn pinThreadToLogicalProcessor(lp: usize) bool {
    if (lp >= topology.max_logical_processors) return false;
    var lps = topology.LogicalProcessorSet{};
    lps.set(lp);
    return setThreadAffinity(&lps);
}

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!topology.Topology {
    if (comptime builtin.target.os.tag == .linux) {
        var records: [topology.max_logical_processors]topology.ProcessorRecord =
            undefined;
        const count = linux.fillRecords(&records);
        if (count == 0) return .{};
        var detected = topology.Topology.initFromRecords(
            allocator,
            records[0..count],
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{},
        };
        linux.fillClusterCacheSizes(&detected);
        return detected;
    }
    if (comptime builtin.target.os.tag.isDarwin()) {
        var records: [topology.max_logical_processors]topology.ProcessorRecord =
            undefined;
        const count = apple.fillRecords(&records);
        if (count == 0) return .{};
        return topology.Topology.initFromRecords(
            allocator,
            records[0..count],
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{},
        };
    }
    if (comptime builtin.target.os.tag == .windows) {
        var records: [topology.max_logical_processors]topology.ProcessorRecord =
            undefined;
        const count = try windows.fillRecords(allocator, &records);
        if (count == 0) return .{};
        return topology.Topology.initFromRecords(
            allocator,
            records[0..count],
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{},
        };
    }
    return .{};
}

pub fn dataCaches() ?*const [4]topology.Cache {
    const state = cache_state.load(.acquire);
    if (state != 0) return if (state == 1) &cache_storage else null;
    while (!cache_guard.tryLock()) std.atomic.spinLoopHint();
    defer cache_guard.unlock();
    const locked_state = cache_state.load(.monotonic);
    if (locked_state == 0) {
        const detected = if (comptime builtin.target.os.tag == .linux)
            linux.dataCaches()
        else if (comptime builtin.target.os.tag.isDarwin())
            apple.dataCaches()
        else if (comptime builtin.target.os.tag == .windows)
            windows.dataCaches()
        else
            null;
        if (detected) |caches| {
            cache_storage = caches;
            cache_state.store(1, .release);
        } else {
            cache_state.store(2, .release);
        }
    }
    return if (cache_state.load(.acquire) == 1) &cache_storage else null;
}
