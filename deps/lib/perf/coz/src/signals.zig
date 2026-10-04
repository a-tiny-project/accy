const std = @import("std");
const sys = @import("sys");

const timer = sys.timer;

pub const Signal = sys.signal.RawSignal;
pub const SignalInfo = sys.signal.SignalInfo;
pub const Action = sys.signal.SignalAction;
pub const Handler = sys.signal.FaultHandler;

pub const Installed = struct {
    signal: Signal,
    previous: Action,
    active: bool = true,

    pub fn restore(self: *Installed) void {
        if (!self.active) return;
        sys.signal.installAction(self.signal, &self.previous, null) catch {};
        self.active = false;
    }
};

pub fn installSampleHandler(handler: Handler) Installed {
    return install(timer.sample_signal, handler);
}

pub fn install(signal: Signal, handler: Handler) Installed {
    const act = siginfoAction(handler);
    var previous: Action = undefined;
    sys.signal.installAction(signal, &act, &previous) catch return .{
        .signal = signal,
        .previous = previous,
        .active = false,
    };
    return .{ .signal = signal, .previous = previous };
}

pub fn siginfoAction(handler: Handler) Action {
    return sys.signal.siginfoAction(handler);
}

var test_signal_count: std.atomic.Value(u32) = .init(0);

fn countSignal(_: Signal, _: *const SignalInfo, _: ?*anyopaque) callconv(.c) void {
    _ = test_signal_count.fetchAdd(1, .monotonic);
}
