const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys");

pub const SpinType = enum(u8) {
    monitor_x = 1,
    u_monitor = 2,
    pause = 3,
};

pub const SpinResult = struct {
    value: u32,
    repetitions: u32,
};

pub const SpinPause = struct {
    pub fn spinType(_: SpinPause) SpinType {
        return .pause;
    }

    pub fn untilDifferent(
        _: SpinPause,
        previous: u32,
        watched: *const std.atomic.Value(u32),
    ) SpinResult {
        var repetitions: u32 = 0;
        while (true) : (repetitions +%= 1) {
            const current = watched.load(.acquire);
            if (current != previous) {
                return .{
                    .value = current,
                    .repetitions = repetitions,
                };
            }
            std.atomic.spinLoopHint();
        }
    }

    pub fn untilEqual(
        _: SpinPause,
        expected: u32,
        watched: *const std.atomic.Value(u32),
    ) usize {
        var repetitions: usize = 0;
        while (watched.load(.acquire) != expected) : (repetitions +%= 1) {
            std.atomic.spinLoopHint();
        }
        return repetitions;
    }
};

pub const SpinMonitorX = struct {
    pub fn spinType(_: SpinMonitorX) SpinType {
        return .monitor_x;
    }

    pub fn untilDifferent(
        _: SpinMonitorX,
        previous: u32,
        watched: *const std.atomic.Value(u32),
    ) SpinResult {
        if (comptime !haveMonitorX()) {
            return (SpinPause{}).untilDifferent(previous, watched);
        }
        var repetitions: u32 = 0;
        while (true) : (repetitions +%= 1) {
            var current = watched.load(.acquire);
            if (current != previous) {
                return .{
                    .value = current,
                    .repetitions = repetitions,
                };
            }
            monitorX(&watched.raw);
            current = watched.load(.acquire);
            if (current != previous) {
                return .{
                    .value = current,
                    .repetitions = repetitions,
                };
            }
            waitX();
        }
    }

    pub fn untilEqual(
        _: SpinMonitorX,
        expected: u32,
        watched: *const std.atomic.Value(u32),
    ) usize {
        if (comptime !haveMonitorX()) {
            return (SpinPause{}).untilEqual(expected, watched);
        }
        var repetitions: usize = 0;
        while (true) : (repetitions +%= 1) {
            var current = watched.load(.acquire);
            if (current == expected) return repetitions;
            monitorX(&watched.raw);
            current = watched.load(.acquire);
            if (current == expected) return repetitions;
            waitX();
        }
    }
};

pub const SpinUMonitor = struct {
    pub fn spinType(_: SpinUMonitor) SpinType {
        return .u_monitor;
    }

    pub fn untilDifferent(
        _: SpinUMonitor,
        previous: u32,
        watched: *const std.atomic.Value(u32),
    ) SpinResult {
        if (comptime !haveUMonitor()) {
            return (SpinPause{}).untilDifferent(previous, watched);
        }
        var repetitions: u32 = 0;
        while (true) : (repetitions +%= 1) {
            var current = watched.load(.acquire);
            if (current != previous) {
                return .{
                    .value = current,
                    .repetitions = repetitions,
                };
            }
            uMonitor(&watched.raw);
            current = watched.load(.acquire);
            if (current != previous) {
                return .{
                    .value = current,
                    .repetitions = repetitions,
                };
            }
            uWait();
        }
    }

    pub fn untilEqual(
        _: SpinUMonitor,
        expected: u32,
        watched: *const std.atomic.Value(u32),
    ) usize {
        if (comptime !haveUMonitor()) {
            return (SpinPause{}).untilEqual(expected, watched);
        }
        var repetitions: usize = 0;
        while (true) : (repetitions +%= 1) {
            var current = watched.load(.acquire);
            if (current == expected) return repetitions;
            uMonitor(&watched.raw);
            current = watched.load(.acquire);
            if (current == expected) return repetitions;
            uWait();
        }
    }
};

pub fn name(spin_type: SpinType) []const u8 {
    return switch (spin_type) {
        .monitor_x => "MonitorX_C1",
        .u_monitor => "UMonitor_C0.2",
        .pause => "Pause",
    };
}

pub fn detectSpin(disabled: u8) SpinType {
    if (comptime isX86()) {
        const leaf0 = cpuid(0, 0);
        if (comptime haveMonitorX()) {
            if (enabled(disabled, .monitor_x) and isAmd(leaf0)) {
                const extended = cpuid(0x8000_0000, 0);
                if (extended.eax >= 0x8000_0001) {
                    const features = cpuid(0x8000_0001, 0);
                    if (features.ecx & (@as(u32, 1) << 29) != 0) {
                        return .monitor_x;
                    }
                }
            }
        }
        if (comptime haveUMonitor()) {
            if (enabled(disabled, .u_monitor) and leaf0.eax >= 7) {
                const features = cpuid(7, 0);
                if (features.ecx & (@as(u32, 1) << 5) != 0) {
                    return .u_monitor;
                }
            }
        }
    }
    return .pause;
}

pub fn callWithSpin(
    spin_type: SpinType,
    context: anytype,
    comptime call: anytype,
) void {
    switch (spin_type) {
        .monitor_x => if (comptime haveMonitorX())
            call(context, SpinMonitorX{})
        else
            call(context, SpinPause{}),
        .u_monitor => if (comptime haveUMonitor())
            call(context, SpinUMonitor{})
        else
            call(context, SpinPause{}),
        .pause => call(context, SpinPause{}),
    }
}

const X86Leaf = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

fn isX86() bool {
    return builtin.cpu.arch == .x86 or builtin.cpu.arch == .x86_64;
}

fn haveMonitorX() bool {
    return builtin.cpu.arch == .x86_64;
}

fn haveUMonitor() bool {
    return builtin.cpu.arch == .x86_64;
}

fn enabled(disabled: u8, spin_type: SpinType) bool {
    const shift: u3 = @intCast(@backingInt(spin_type));
    return disabled & (@as(u8, 1) << shift) == 0;
}

fn cpuid(leaf: u32, subleaf: u32) X86Leaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn isAmd(leaf: X86Leaf) bool {
    return leaf.eax >= 1 and
        leaf.ebx == 0x6874_7541 and
        leaf.ecx == 0x444d_4163 and
        leaf.edx == 0x6974_6e65;
}

fn monitorX(address: *const u32) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\jmp 2f
            \\1:
            \\mov $0xc3fa010f, %%r11d
            \\2:
            \\lea 1b(%%rip), %%r11
            \\add $2, %%r11
            \\call *%%r11
            :
            : [address] "{rax}" (@intFromPtr(address)),
              [extensions] "{rcx}" (@as(usize, 0)),
              [hints] "{rdx}" (@as(usize, 0)),
            : .{ .cc = true, .r11 = true, .memory = true });
    } else unreachable;
}

fn waitX() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\jmp 2f
            \\1:
            \\mov $0xc3fb010f, %%r11d
            \\2:
            \\lea 1b(%%rip), %%r11
            \\add $2, %%r11
            \\call *%%r11
            :
            : [hints] "{eax}" (@as(u32, 0)),
              [cycles] "{ebx}" (@as(u32, 0)),
              [extensions] "{ecx}" (@as(u32, 0)),
            : .{ .cc = true, .r11 = true, .memory = true });
    } else unreachable;
}

fn uMonitor(address: *const u32) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\jmp 2f
            \\1:
            \\mov $0x000000c3f0ae0ff3, %%r11
            \\2:
            \\lea 1b(%%rip), %%r11
            \\add $2, %%r11
            \\call *%%r11
            :
            : [address] "{rax}" (@intFromPtr(address)),
            : .{ .cc = true, .r11 = true, .memory = true });
    } else unreachable;
}

fn uWait() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\jmp 2f
            \\1:
            \\mov $0x000000c3f1ae0ff2, %%r11
            \\2:
            \\lea 1b(%%rip), %%r11
            \\add $2, %%r11
            \\call *%%r11
            :
            : [control] "{ecx}" (@as(u32, 0)),
              [deadline_low] "{eax}" (std.math.maxInt(u32)),
              [deadline_high] "{edx}" (std.math.maxInt(u32)),
            : .{ .cc = true, .r11 = true, .memory = true });
    } else unreachable;
}

test "Highway spin names and disabled detection preserve pause fallback" {
    try std.testing.expectEqualStrings("MonitorX_C1", name(.monitor_x));
    try std.testing.expectEqualStrings("UMonitor_C0.2", name(.u_monitor));
    try std.testing.expectEqualStrings("Pause", name(.pause));
    try std.testing.expectEqual(
        SpinType.pause,
        detectSpin(
            (@as(u8, 1) << @as(u3, @intCast(@backingInt(SpinType.monitor_x)))) |
                (@as(u8, 1) << @as(u3, @intCast(@backingInt(SpinType.u_monitor)))),
        ),
    );
}

test "Highway spin pause observes changes and equality" {
    var watched = std.atomic.Value(u32).init(3);
    watched.store(5, .release);
    const result = (SpinPause{}).untilDifferent(3, &watched);
    try std.testing.expectEqual(@as(u32, 5), result.value);
    try std.testing.expectEqual(@as(u32, 0), result.repetitions);
    try std.testing.expectEqual(
        @as(usize, 0),
        (SpinPause{}).untilEqual(5, &watched),
    );
}

const PingPongState = struct {
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    observed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    first_repetitions: std.atomic.Value(u32) =
        std.atomic.Value(u32).init(0),
    second_repetitions: std.atomic.Value(usize) =
        std.atomic.Value(usize).init(0),
};

fn PingPongWorker(comptime Policy: type) type {
    return struct {
        const Context = struct {
            state: *PingPongState,
            policy: Policy,
        };

        fn run(context: Context) void {
            context.state.ready.store(true, .release);
            const result = context.policy.untilDifferent(
                0,
                &context.state.active,
            );
            context.state.observed.store(result.value, .release);
            context.state.first_repetitions.store(
                result.repetitions,
                .release,
            );
            sys.time.sleepNanoseconds(20 * std.time.ns_per_ms);
            context.state.done.store(1, .release);
        }
    };
}

const PingPongInvocation = struct {
    success: *bool,
    elapsed_ns: *u64,
};

fn runPingPong(context: PingPongInvocation, policy: anytype) void {
    var state = PingPongState{};
    const Worker = PingPongWorker(@TypeOf(policy));
    const handle = sys.thread.spawn(Worker.run, .{
        Worker.Context{ .state = &state, .policy = policy },
    }) catch return;
    const started = sys.time.nanoTimestamp();
    while (!state.ready.load(.acquire)) std.atomic.spinLoopHint();
    sys.time.sleepNanoseconds(30 * std.time.ns_per_ms);
    state.active.store(1, .release);
    const repetitions = policy.untilEqual(1, &state.done);
    state.second_repetitions.store(repetitions, .release);
    handle.join();
    const elapsed = sys.time.nanoTimestamp() - started;
    if (elapsed < 0) return;
    context.elapsed_ns.* = @intCast(elapsed);
    context.success.* =
        state.observed.load(.acquire) == 1 and
        state.done.load(.acquire) == 1 and
        context.elapsed_ns.* > 25 * std.time.ns_per_ms;
}

test "Highway detected spin policy completes delayed ping pong" {
    if (!sys.thread.threadsSupported() or
        !sys.time.supportsAwakeClock())
    {
        return error.SkipZigTest;
    }
    var success = false;
    var elapsed_ns: u64 = 0;
    callWithSpin(
        detectSpin(0),
        PingPongInvocation{
            .success = &success,
            .elapsed_ns = &elapsed_ns,
        },
        runPingPong,
    );
    try std.testing.expect(success);
    try std.testing.expect(elapsed_ns > 25 * std.time.ns_per_ms);
}
