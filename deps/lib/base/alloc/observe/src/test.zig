const std = @import("std");
const observe = @import("root.zig");

const Recorder = struct {
    events: [16]observe.Event = undefined,
    count: usize = 0,

    fn sink(self: *Recorder) observe.Sink {
        return .{
            .context = self,
            .record = record,
        };
    }

    fn record(context: *anyopaque, event: observe.Event) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        std.debug.assert(self.count < self.events.len);
        self.events[self.count] = event;
        self.count += 1;
        var suppressed = observe.begin(
            event.producer_id,
            .custom,
            .alloc,
            0,
            0,
            1,
            1,
            @returnAddress(),
        );
        suppressed.finish(.{ .address = 1, .succeeded = true });
    }
};

test "instrumented observer correlates nested allocator operations" {
    if (!observe.enabled) return error.SkipZigTest;
    var recorder = Recorder{};
    var sink = recorder.sink();
    var session = try observe.install(&sink);

    const arena_id = observe.producerId();
    const backing_id = observe.producerId();
    var outer = observe.begin(
        arena_id,
        .arena,
        .alloc,
        0,
        0,
        24,
        8,
        101,
    );
    try std.testing.expect(outer.active);
    try std.testing.expectEqual(outer.operation_id, observe.currentOperationId());
    var inner = observe.begin(
        backing_id,
        .boundary,
        .alloc,
        0,
        0,
        4096,
        16,
        202,
    );
    try std.testing.expect(inner.active);
    inner.finish(.{ .address = 0x2000, .succeeded = true });
    outer.finish(.{ .address = 0x2010, .succeeded = true });
    try std.testing.expectEqual(@as(u64, 0), observe.currentOperationId());

    try std.testing.expectEqual(@as(usize, 2), recorder.count);
    const backing = recorder.events[0];
    const logical = recorder.events[1];
    try std.testing.expectEqual(inner.operation_id, backing.operation_id);
    try std.testing.expectEqual(outer.operation_id, backing.parent_operation_id);
    try std.testing.expectEqual(outer.operation_id, logical.operation_id);
    try std.testing.expectEqual(@as(u64, 0), logical.parent_operation_id);
    try std.testing.expectEqual(observe.Producer.boundary, backing.producer);
    try std.testing.expectEqual(observe.Producer.arena, logical.producer);

    session.deinit();
    var unobserved = observe.begin(
        arena_id,
        .arena,
        .free,
        0x2010,
        24,
        0,
        8,
        303,
    );
    try std.testing.expect(!unobserved.active);
    unobserved.finish(.{ .address = 0x2010, .succeeded = true });
    try std.testing.expectEqual(@as(usize, 2), recorder.count);
}

test "instrumented observer permits only one installed sink" {
    if (!observe.enabled) return error.SkipZigTest;
    var first_recorder = Recorder{};
    var first_sink = first_recorder.sink();
    var first = try observe.install(&first_sink);
    defer first.deinit();
    var second_recorder = Recorder{};
    var second_sink = second_recorder.sink();
    try std.testing.expectError(
        error.AlreadyInstalled,
        observe.install(&second_sink),
    );
}

test "session floor and lifecycle identity distinguish owned generations" {
    if (!observe.enabled) return error.SkipZigTest;
    const before_install = observe.producerId();
    var recorder = Recorder{};
    var sink = recorder.sink();
    var session = try observe.install(&sink);
    defer session.deinit();
    const after_install = observe.producerId();
    try std.testing.expect(before_install < session.producerIdFloor());
    try std.testing.expect(after_install >= session.producerIdFloor());

    const identity = observe.Identity{
        .producer_id = after_install,
        .producer = .arena,
        .generation = 7,
        .owner_cookie = 0x1234,
    };
    var lifecycle = observe.beginLifecycle(
        identity,
        .invalidate,
        .reset,
        0x5678,
    );
    lifecycle.finish(.{ .succeeded = true });

    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    const event = recorder.events[0];
    try std.testing.expectEqual(observe.Operation.lifecycle, event.operation);
    try std.testing.expectEqual(after_install, event.producer_id);
    try std.testing.expectEqual(@as(u64, 7), event.generation);
    try std.testing.expectEqual(@as(usize, 0x1234), event.owner_cookie);
    try std.testing.expectEqual(
        observe.LifecycleDisposition.invalidate,
        event.lifecycle_disposition,
    );
    try std.testing.expectEqual(
        observe.LifecycleReason.reset,
        event.lifecycle_reason,
    );
}

test "silent context links logical operations across a backing boundary" {
    if (!observe.enabled) return error.SkipZigTest;
    var recorder = Recorder{};
    var sink = recorder.sink();
    var session = try observe.install(&sink);
    defer session.deinit();

    const producer_id = observe.producerId();
    var outer = observe.begin(
        producer_id,
        .arena,
        .alloc,
        0,
        0,
        24,
        8,
        101,
    );
    var boundary = observe.beginContext();
    try std.testing.expect(boundary.id() != 0);
    try std.testing.expectEqual(outer.operation_id, boundary.parentId());
    var inner = observe.begin(
        producer_id,
        .debug,
        .alloc,
        0,
        0,
        4096,
        16,
        202,
    );
    inner.finish(.{ .address = 0x2000, .succeeded = true });
    boundary.finish();
    outer.finish(.{ .address = 0x2010, .succeeded = true });

    try std.testing.expectEqual(@as(usize, 2), recorder.count);
    try std.testing.expectEqual(
        boundary.id(),
        recorder.events[0].parent_operation_id,
    );
    try std.testing.expectEqual(
        outer.operation_id,
        recorder.events[1].operation_id,
    );
}

test "disabled observer has a zero-event surface" {
    if (observe.enabled) return error.SkipZigTest;
    var recorder = Recorder{};
    var sink = recorder.sink();
    var session = try observe.install(&sink);
    defer session.deinit();
    try std.testing.expectEqual(@as(u64, 0), observe.producerId());
    var span = observe.begin(
        0,
        .arena,
        .alloc,
        0,
        0,
        8,
        8,
        101,
    );
    var context = observe.beginContext();
    try std.testing.expectEqual(@as(u64, 0), context.id());
    context.finish();
    span.finish(.{ .address = 0x1000, .succeeded = true });
    try std.testing.expectEqual(@as(usize, 0), recorder.count);
}

test "owned adapters report buffer-first and debug operations" {
    if (comptime !observe.enabled) return error.SkipZigTest;
    var recorder = Recorder{};
    var sink = recorder.sink();
    var session = try observe.install(&sink);
    defer session.deinit();

    var inline_storage: [64]u8 = undefined;
    var buffer = observe.buffer.First.init(
        &inline_storage,
        std.testing.allocator,
    );
    const buffer_allocator = buffer.allocator();
    const inline_block = try buffer_allocator.alloc(u8, 16);
    buffer_allocator.free(inline_block);

    var debug = observe.debug.Allocator(.{}).init(std.testing.allocator);
    const debug_allocator = debug.allocator();
    const mapped = try debug_allocator.alloc(u8, 32);
    debug_allocator.free(mapped);
    try std.testing.expectEqual(std.heap.Check.ok, debug.deinit());

    try std.testing.expectEqual(@as(usize, 4), recorder.count);
    try std.testing.expectEqual(
        observe.Producer.buffer_first,
        recorder.events[0].producer,
    );
    try std.testing.expectEqual(
        observe.Producer.buffer_first,
        recorder.events[1].producer,
    );
    try std.testing.expectEqual(observe.Producer.debug, recorder.events[2].producer);
    try std.testing.expectEqual(observe.Producer.debug, recorder.events[3].producer);
}

test "allocator observer package namespace" {
    std.testing.refAllDecls(observe);
}
