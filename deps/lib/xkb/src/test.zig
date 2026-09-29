const std = @import("std");
const alloc_phase = @import("alloc_phase");
const root = @import("root.zig");
const keysym_suite = @import("keysym/test.zig");
const keymap_suite = @import("keymap/test.zig");
const state_suite = @import("state/test.zig");
const compose_suite = @import("compose/test.zig");

const compose = root.compose;

test "xkb package namespace" {
    std.testing.refAllDecls(root);
    std.testing.refAllDecls(keysym_suite);
    std.testing.refAllDecls(keymap_suite);
    std.testing.refAllDecls(state_suite);
    std.testing.refAllDecls(compose_suite);
}

test "XKB root exposes caller-selected Compose bounds and storage" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(@import("./compose/root.zig").Storage, "xkb_compose_root"),
        );
    }

    const limits = compose.Limits{ .sequence_symbols = 2, .text_bytes = 2 };
    const capacity = try compose.Capacity.derive(limits);
    const scratch_limits = compose.ScratchLimits{ .line_bytes = 32, .path_bytes = 64 };
    const scratch_capacity = try compose.ScratchCapacity.derive(scratch_limits);
    var storage = try compose.Storage.init(std.testing.allocator, limits);
    defer storage.deinit(std.testing.allocator);
    var scratch_storage = try compose.ScratchStorage.init(std.testing.allocator, scratch_limits);
    defer scratch_storage.deinit(std.testing.allocator);
    storage.activate();
    scratch_storage.activate();
    const published = try compose.compile(
        &storage,
        &scratch_storage,
        "<A> <B> : \"ok\"\n",
        .{ .locale = "C" },
    );
    defer storage.reset();
    try std.testing.expectEqual(capacity.storage_bytes, storage.status().storage_bytes);
    try std.testing.expectEqual(
        scratch_capacity.storage_bytes,
        scratch_storage.status().storage_bytes,
    );
    try std.testing.expectEqual(@as(?u32, 1), published.transition(0, @fromBackingInt(@intCast('A'))));
}

test "XKB root exposes caller-selected Compose scratch bounds and storage" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(
                @import("./compose/workspace/root.zig").Storage,
                "xkb_compose_scratch_root",
            ),
        );
    }

    const limits = compose.ScratchLimits{
        .line_bytes = 32,
        .path_bytes = 64,
    };
    const capacity = try compose.ScratchCapacity.derive(limits);
    var storage = try compose.ScratchStorage.init(std.testing.allocator, limits);
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    try std.testing.expectEqual(capacity.storage_bytes, storage.status().storage_bytes);
}
