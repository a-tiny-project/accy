const std = @import("std");
const sys = @import("sys");

const debug_info = @import("debug.zig");
const delay = @import("delay.zig");
const perf = sys.perf;
const profiler_mod = @import("profiler.zig");
const sampler_mod = @import("sampler.zig");
const timer = sys.timer;

pub const record_scratch_size = perf.data_size;
pub const callchain_scratch_len = 128;

pub const Thread = struct {
    delay_state: delay.ThreadState = .{},
    sampler: sampler_mod.Sampler = .{},
    record_scratch: [record_scratch_size]u8 = undefined,
    callchain_scratch: [callchain_scratch_len]usize = undefined,

    pub fn openCurrent(options: sampler_mod.Options) !Thread {
        return .{ .sampler = try sampler_mod.Sampler.openCurrentThread(options) };
    }

    pub fn openAndStartCurrent(options: sampler_mod.Options) !Thread {
        var thread = try openCurrent(options);
        errdefer thread.close();
        try thread.sampler.start();
        return thread;
    }

    pub fn close(self: *Thread) void {
        self.sampler.close();
    }

    pub fn process(
        self: *Thread,
        profiler: *profiler_mod.Profiler,
        record_scratch: []u8,
        callchain_scratch: []usize,
        wait: sampler_mod.WaitFn,
    ) !usize {
        if (!self.delay_state.acquireUse()) return 0;
        defer self.delay_state.setInUse(false);
        return profiler.processSampler(&self.delay_state, &self.sampler, record_scratch, callchain_scratch, wait);
    }

    pub fn processDefault(
        self: *Thread,
        profiler: *profiler_mod.Profiler,
        wait: sampler_mod.WaitFn,
    ) !usize {
        return self.process(profiler, &self.record_scratch, &self.callchain_scratch, wait);
    }

    pub fn drain(
        self: *Thread,
        profiler: *profiler_mod.Profiler,
        record_scratch: []u8,
        callchain_scratch: []usize,
    ) !usize {
        if (!self.delay_state.acquireUse()) return 0;
        defer self.delay_state.setInUse(false);
        return profiler.drainSampler(
            &self.delay_state,
            &self.sampler,
            record_scratch,
            callchain_scratch,
        );
    }

    pub fn drainDefault(self: *Thread, profiler: *profiler_mod.Profiler) !usize {
        return self.drain(profiler, &self.record_scratch, &self.callchain_scratch);
    }

    pub fn drainResolved(
        self: *Thread,
        profiler: *profiler_mod.Profiler,
        allocator: std.mem.Allocator,
        scope: debug_info.Scope,
        record_scratch: []u8,
        callchain_scratch: []usize,
    ) !usize {
        if (!self.delay_state.acquireUse()) return 0;
        defer self.delay_state.setInUse(false);
        return profiler.drainResolvedSampler(allocator, &self.delay_state, &self.sampler, record_scratch, callchain_scratch, scope);
    }

    pub fn drainResolvedDefault(
        self: *Thread,
        profiler: *profiler_mod.Profiler,
        allocator: std.mem.Allocator,
        scope: debug_info.Scope,
    ) !usize {
        return self.drainResolved(profiler, allocator, scope, &self.record_scratch, &self.callchain_scratch);
    }
};

fn exactWait(ns: u64) u64 {
    return ns;
}
