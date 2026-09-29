const std = @import("std");
const hypothesis = @import("hypothesis");
const wayland = @import("wayland");

const maximum_ids = 16;
const maximum_globals = 8;
const maximum_event_payload_bytes = 64;
const global_names = [_][]const u8{
    "a",
    "bb",
    "ccc",
    "dddd",
    "eeeee",
    "ffffff",
    "ggggggg",
    "hhhhhhhh",
};

const ClientIdLifecycle = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: std.mem.Allocator) !void {
        const count: usize = @intCast(try data.drawInteger(1, maximum_ids, 4));
        const capacity = try wayland.ClientIdCapacity.derive(.{ .client_id_count = count });
        var pool = try wayland.ids.Pool.init(allocator, capacity);
        defer pool.deinit();
        var ids: [maximum_ids]u32 = undefined;
        var reusable: [maximum_ids]u32 = undefined;
        var reusable_count: usize = 0;

        for (ids[0..count], 0..) |*id, at| {
            id.* = try pool.allocate();
            try std.testing.expectEqual(
                wayland.ids.first_dynamic_id + @as(u32, @intCast(at)),
                id.*,
            );
            try std.testing.expect(pool.isLive(id.*));
        }
        for (ids[0..count]) |id| {
            const action = try data.drawInteger(0, 3, 0);
            switch (action) {
                0 => {},
                1 => {
                    try pool.retire(id);
                    try std.testing.expect(!pool.isLive(id));
                },
                2 => {
                    try pool.retire(id);
                    try pool.acknowledgeDelete(id);
                    reusable[reusable_count] = id;
                    reusable_count += 1;
                },
                3 => {
                    try pool.abandon(id);
                    reusable[reusable_count] = id;
                    reusable_count += 1;
                },
                else => unreachable,
            }
        }
        var at = reusable_count;
        while (at != 0) {
            at -= 1;
            try std.testing.expectEqual(reusable[at], try pool.allocate());
        }
        try std.testing.expectError(error.ClientIdCapacityExceeded, pool.allocate());
        try std.testing.expectEqual(
            @as(u64, 1),
            pool.status().client_id_capacity_rejection_count,
        );
    }
};

const GlobalStorageLifecycle = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: std.mem.Allocator) !void {
        const count: usize = @intCast(try data.drawInteger(1, maximum_globals, 3));
        const capacity = try wayland.runtime.GlobalCapacity.derive(.{
            .retained_global_count = count,
            .interface_name_byte_count_per_global = maximum_globals,
        });
        var storage = try wayland.runtime.GlobalStorage.init(allocator, capacity);
        defer storage.deinit();
        var retained: [maximum_globals]bool = @splat(false);
        var removed_count: usize = 0;

        for (0..count) |at| {
            const name: u32 = @intCast(at + 1);
            _ = try storage.add(2, name, global_names[at], 1);
            retained[at] = true;
        }
        for (0..count) |at| {
            if (!try data.drawBoolean()) continue;
            try storage.remove(2, @intCast(at + 1));
            retained[at] = false;
            removed_count += 1;
        }
        for (retained[0..count], 0..) |is_retained, at| {
            const item = storage.get(2, @intCast(at + 1));
            if (!is_retained) {
                try std.testing.expect(item == null);
                continue;
            }
            try std.testing.expectEqualStrings(global_names[at], item.?.interface);
        }
        for (0..removed_count) |at| {
            _ = try storage.add(3, @intCast(at + 1), global_names[at], 1);
        }
        try std.testing.expectError(
            error.GlobalCapacityExceeded,
            storage.add(4, 1, "a", 1),
        );
        try std.testing.expectEqual(
            @as(u64, 1),
            storage.status().global_capacity_rejection_count,
        );
    }
};

const EventStorageLifecycle = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: std.mem.Allocator) !void {
        const payload_capacity: usize = @intCast(try data.drawInteger(
            0,
            maximum_event_payload_bytes,
            16,
        ));
        const capacity = try wayland.runtime.EventStorageCapacity.derive(.{
            .payload_byte_count = payload_capacity,
            .descriptor_count = 0,
        });
        var storage = try wayland.runtime.EventStorage.init(allocator, capacity);
        defer storage.deinit();
        const pointer = storage.payload.ptr;
        const cycle_count: usize = @intCast(try data.drawInteger(1, 16, 4));

        for (0..cycle_count) |_| {
            const payload_len: usize = @intCast(try data.drawInteger(
                0,
                payload_capacity,
                0,
            ));
            const payload = try data.drawBytes(payload_len, payload_len);
            try storage.admit(payload.len, 0);
            try std.testing.expectEqualSlices(
                u8,
                payload,
                storage.storePayloadAssumeCapacity(payload),
            );
            try std.testing.expectEqual(pointer, storage.payload.ptr);
            storage.reset();
        }

        try std.testing.expectError(
            error.EventPayloadCapacityExceeded,
            storage.admit(payload_capacity + 1, 0),
        );
        try std.testing.expectEqual(
            @as(u64, 1),
            storage.status().event_payload_capacity_rejection_count,
        );
    }
};

test "property: client ID storage preserves lifecycle within its fixed capacity" {
    try hypothesis.checkNamed(
        ClientIdLifecycle,
        "wayland-client-id-lifecycle",
        hypothesis.Settings.quick()
            .withSeed(0x5741_594c_414e_4403)
            .withDatabase("zig-out/hypothesis-failures/wayland"),
    );
}

test "property: global storage preserves scoped entries across removal and reuse" {
    try hypothesis.checkNamed(
        GlobalStorageLifecycle,
        "wayland-global-storage-lifecycle",
        hypothesis.Settings.quick()
            .withSeed(0x5741_594c_414e_4404)
            .withDatabase("zig-out/hypothesis-failures/wayland"),
    );
}

test "property: event storage reuses one fixed payload region" {
    try hypothesis.checkNamed(
        EventStorageLifecycle,
        "wayland-event-storage-lifecycle",
        hypothesis.Settings.quick()
            .withSeed(0x5741_594c_414e_4405)
            .withDatabase("zig-out/hypothesis-failures/wayland"),
    );
}
