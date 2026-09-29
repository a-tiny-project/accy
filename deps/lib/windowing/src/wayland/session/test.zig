const std = @import("std");
const native = @import("wayland");

const session_api = @import("root.zig");
const global = @import("global.zig");
const storage_api = @import("storage.zig");

const runtime = native.runtime;
const Kind = global.Kind;
const classify = global.classify;
const output = session_api.output;
const Capacity = session_api.Capacity;
const OutputStorage = storage_api.OutputStorage;
const Session = session_api.Session;

test "registry classification owns every bound desktop protocol" {
    try std.testing.expectEqual(Kind.compositor, classify("wl_compositor"));
    try std.testing.expectEqual(Kind.data_device_manager, classify("wl_data_device_manager"));
    try std.testing.expectEqual(Kind.fractional_scale_manager, classify("wp_fractional_scale_manager_v1"));
    try std.testing.expectEqual(Kind.presentation, classify("wp_presentation"));
    try std.testing.expectEqual(Kind.linux_dmabuf, classify("zwp_linux_dmabuf_v1"));
    try std.testing.expectEqual(Kind.syncobj_manager, classify("wp_linux_drm_syncobj_manager_v1"));
    try std.testing.expectEqual(Kind.unknown, classify("example_future_protocol"));
}

test "Wayland session capacity derives exact output storage" {
    const capacity = try Capacity.derive(3);
    try std.testing.expectEqual(@as(usize, 3), capacity.retained_output_count);
    try std.testing.expectEqual(3 * @sizeOf(output.Output), capacity.retained_output_bytes);
    try std.testing.expectError(error.RetainedOutputsEmpty, Capacity.derive(0));
    try std.testing.expectError(
        error.CapacityOverflow,
        Capacity.derive(std.math.maxInt(usize) / @sizeOf(output.Output) + 1),
    );
}

test "Wayland output storage rejects max plus one and reuses removed slots" {
    var storage = try OutputStorage.init(std.testing.allocator, try Capacity.derive(2));
    defer storage.deinit();

    const first = storage.reserve().?;
    storage.commit(first, .{ .global_name = 7, .id = 70 });
    const second = storage.reserve().?;
    storage.commit(second, .{ .global_name = 8, .id = 80 });
    try std.testing.expect(storage.reserve() == null);
    try std.testing.expectEqual(@as(u64, 1), storage.capacity_rejection_count);
    try std.testing.expectEqual(@as(usize, 2), storage.retained().len);
    try std.testing.expectEqual(@as(u32, 7), storage.retained()[0].global_name);
    try std.testing.expectEqual(@as(u32, 8), storage.retained()[1].global_name);

    const removed = storage.removeGlobal(7).?;
    try std.testing.expectEqual(@as(u32, 70), removed.id);
    const reused = storage.reserve().?;
    storage.commit(reused, .{ .global_name = 9, .id = 90 });
    try std.testing.expectEqual(@as(usize, 2), storage.retained().len);
    try std.testing.expectEqual(@as(u32, 8), storage.retained()[0].global_name);
    try std.testing.expectEqual(@as(u32, 9), storage.retained()[1].global_name);

    storage.capacity_rejection_count = std.math.maxInt(u64);
    try std.testing.expect(storage.reserve() == null);
    try std.testing.expectEqual(std.math.maxInt(u64), storage.capacity_rejection_count);
}

test "Wayland session reports output acquisition failure before connection" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    var session = Session{};
    try std.testing.expectError(
        error.OutOfMemory,
        session.open(
            failing.allocator(),
            try Capacity.derive(2),
            try runtime.Capacity.derive(.{}),
        ),
    );
}
