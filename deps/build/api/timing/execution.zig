const std = @import("std");
const Io = std.Io;
const testing = std.testing;

pub const Status = enum {
    ok,
    skip,
    fail,
    leak,
    fail_leak,
};

pub const Row = struct {
    name: []const u8,
    test_ns: i128,
    teardown_ns: i128,
    status: Status,
    leaked: bool,
};

pub const Result = struct {
    test_ns: i128,
    teardown_ns: i128,
    status: Status,
    leaked: bool,
    error_name: []const u8 = "",
    leak_message: []const u8 = "",
};

/// A literal null guard keeps standalone runners independent of the deadline backend.
pub fn run(
    allocator: std.mem.Allocator,
    init: std.process.Init.Minimal,
    clock_io: std.Io,
    test_fn: anytype,
    guard: anytype,
    test_index: usize,
    repeat_index: usize,
) Result {
    const generation = if (guard) |active| active.arm(test_index, repeat_index) else 0;
    testing.allocator_instance = .init(allocator, .{});
    testing.io_instance = .init(testing.allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    testing.log_level = .warn;
    testing.environ = init.environ;

    const t0 = Io.Clock.Timestamp.now(clock_io, .awake);
    const result = test_fn.func();
    if (result) |_| {} else |err| {
        if (err != error.SkipZigTest) {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        }
    }
    const t1 = Io.Clock.Timestamp.now(clock_io, .awake);

    testing.io_instance.deinit();
    const allocator_status = testing.allocator_instance.deinit();
    if (guard) |active| active.complete(generation);
    const leaked = allocator_status != 0;
    const t2 = Io.Clock.Timestamp.now(clock_io, .awake);

    const timings = Result{
        .test_ns = t0.durationTo(t1).raw.nanoseconds,
        .teardown_ns = t1.durationTo(t2).raw.nanoseconds,
        .status = .ok,
        .leaked = leaked,
    };

    if (result) |_| {
        if (!leaked) return timings;
        return .{
            .test_ns = timings.test_ns,
            .teardown_ns = timings.teardown_ns,
            .status = .leak,
            .leaked = true,
            .leak_message = "std.testing.allocator leaked during teardown",
        };
    } else |err| switch (err) {
        error.SkipZigTest => {
            if (!leaked) return .{
                .test_ns = timings.test_ns,
                .teardown_ns = timings.teardown_ns,
                .status = .skip,
                .leaked = false,
            };
            return .{
                .test_ns = timings.test_ns,
                .teardown_ns = timings.teardown_ns,
                .status = .leak,
                .leaked = true,
                .leak_message = "skipped test leaked during teardown",
            };
        },
        else => return .{
            .test_ns = timings.test_ns,
            .teardown_ns = timings.teardown_ns,
            .status = if (leaked) .fail_leak else .fail,
            .leaked = leaked,
            .error_name = @errorName(err),
            .leak_message = if (leaked) "failing test also leaked during teardown" else "",
        },
    }
}
