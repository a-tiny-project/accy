const std = @import("std");
const coz = @import("coz");
const model = @import("model.zig");

const stage_count = @typeInfo(model.ProductStage).@"enum".field_names.len;

pub const PhaseTimers = struct {
    totals_ns: [stage_count]u64 = @as([stage_count]u64, @splat(0)),
    calls: [stage_count]u64 = @as([stage_count]u64, @splat(0)),

    pub fn record(self: *PhaseTimers, stage: model.ProductStage, elapsed_ns: u64) void {
        const index = @backingInt(stage);
        _ = @atomicRmw(u64, &self.totals_ns[index], .Add, elapsed_ns, .monotonic);
        _ = @atomicRmw(u64, &self.calls[index], .Add, 1, .monotonic);
    }

    pub fn totalNs(self: *const PhaseTimers, stage: model.ProductStage) u64 {
        return self.totals_ns[@backingInt(stage)];
    }

    pub fn callCount(self: *const PhaseTimers, stage: model.ProductStage) u64 {
        return self.calls[@backingInt(stage)];
    }

    pub fn sumNs(self: *const PhaseTimers) u64 {
        var sum: u64 = 0;
        for (self.totals_ns) |value| sum += value;
        return sum;
    }
};

pub const Clock = *const fn () i128;

var active_timers: ?*PhaseTimers = null;
var active_clock: ?Clock = null;

pub fn beginPhaseTiming(timers: *PhaseTimers, clock: Clock) void {
    active_timers = timers;
    active_clock = clock;
}

pub fn endPhaseTiming() void {
    active_timers = null;
    active_clock = null;
}

pub inline fn scope(comptime name: []const u8) coz.Scope("tldr." ++ name) {
    return coz.scope("tldr." ++ name);
}

pub inline fn product(comptime stage: model.ProductStage) ProductScope(stage) {
    return ProductScope(stage).begin();
}

fn ProductScope(comptime stage: model.ProductStage) type {
    const trace_name = "tldr." ++ stage.traceName();
    const CozScope = coz.Scope(trace_name);
    return struct {
        coz_scope: CozScope,
        start_ns: i128,

        const Self = @This();

        inline fn begin() Self {
            return .{
                .coz_scope = coz.scope(trace_name),
                .start_ns = if (active_clock) |clock| clock() else 0,
            };
        }

        pub inline fn end(self: Self) void {
            if (active_timers) |timers| {
                if (active_clock) |clock| {
                    const elapsed = clock() - self.start_ns;
                    timers.record(stage, if (elapsed < 0) 0 else @intCast(elapsed));
                }
            }
            self.coz_scope.end();
        }
    };
}

fn zeroClock() i128 {
    return 0;
}
