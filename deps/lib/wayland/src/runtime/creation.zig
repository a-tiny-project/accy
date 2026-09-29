const std = @import("std");
const wayland = @import("../root.zig");

pub const Creation = struct {
    id: u32,
    interface: *const wayland.protocol.schema.Interface,
    version: u32,
};

pub const maximum_event_creation_count = maximumEventCreationCount(
    &wayland.protocol.interfaces,
);

pub const Limits = struct {
    event_creation_count: usize = maximum_event_creation_count,
};

pub const CapacityError = error{
    EventCreationStorageTooLarge,
    CapacityOverflow,
};

pub const Capacity = struct {
    event_creation_count: usize,
    event_creation_bytes: usize,
    total_requested_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        const event_creation_bytes = std.math.mul(
            usize,
            limits.event_creation_count,
            @sizeOf(Creation),
        ) catch return error.CapacityOverflow;
        if (limits.event_creation_count > maximum_event_creation_count) {
            return error.EventCreationStorageTooLarge;
        }
        return .{
            .event_creation_count = limits.event_creation_count,
            .event_creation_bytes = event_creation_bytes,
            .total_requested_bytes = event_creation_bytes,
        };
    }
};

pub const StorageError = error{EventCreationCapacityExceeded};

pub const Status = struct {
    event_creation_capacity_rejection_count: u64 = 0,
};

pub const default_capacity = Capacity.derive(.{}) catch unreachable;

pub const Storage = struct {
    session_allocator: std.mem.Allocator,
    creations: []Creation,
    count: usize = 0,
    capacity_rejection_count: u64 = 0,

    pub fn init(
        session_allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!Storage {
        return .{
            .session_allocator = session_allocator,
            .creations = try session_allocator.alloc(
                Creation,
                capacity.event_creation_count,
            ),
        };
    }

    pub fn deinit(self: *Storage) void {
        self.assertValid();
        if (self.creations.len != 0) self.session_allocator.free(self.creations);
        self.* = undefined;
    }

    pub fn begin(self: *Storage, required_count: usize) StorageError!void {
        self.assertValid();
        self.count = 0;
        if (required_count > self.creations.len) {
            self.capacity_rejection_count +|= 1;
            return error.EventCreationCapacityExceeded;
        }
    }

    pub fn appendAssumeCapacity(self: *Storage, creation: Creation) void {
        self.assertValid();
        std.debug.assert(self.count < self.creations.len);
        self.creations[self.count] = creation;
        self.count += 1;
    }

    pub fn reset(self: *Storage) void {
        self.assertValid();
        self.count = 0;
    }

    pub fn items(self: *const Storage) []const Creation {
        self.assertValid();
        return self.creations[0..self.count];
    }

    pub fn status(self: *const Storage) Status {
        self.assertValid();
        return .{
            .event_creation_capacity_rejection_count = self.capacity_rejection_count,
        };
    }

    fn assertValid(self: *const Storage) void {
        std.debug.assert(self.count <= self.creations.len);
    }
};

fn maximumEventCreationCount(
    interfaces: []const wayland.protocol.schema.Interface,
) usize {
    var maximum: usize = 0;
    for (interfaces) |interface| {
        for (interface.events) |event| {
            maximum = @max(maximum, event.newIdCount());
        }
    }
    return maximum;
}

test "generated events derive one exact creation slot" {
    try std.testing.expectEqual(@as(usize, 1), maximum_event_creation_count);
    for (wayland.protocol.interfaces) |interface| {
        for (interface.events) |event| {
            try std.testing.expect(event.newIdCount() <= maximum_event_creation_count);
        }
    }
    try std.testing.expectEqual(
        @as(usize, 1),
        wayland.protocol.core.wl_data_device.events.data_offer.newIdCount(),
    );
    try std.testing.expectEqual(@as(usize, 1), default_capacity.event_creation_count);
    try std.testing.expectEqual(
        @sizeOf(Creation),
        default_capacity.event_creation_bytes,
    );
    try std.testing.expectEqual(
        default_capacity.event_creation_bytes,
        default_capacity.total_requested_bytes,
    );
    try std.testing.expectError(
        error.EventCreationStorageTooLarge,
        Capacity.derive(.{
            .event_creation_count = maximum_event_creation_count + 1,
        }),
    );
    try std.testing.expectError(
        error.CapacityOverflow,
        Capacity.derive(.{ .event_creation_count = std.math.maxInt(usize) }),
    );
}

test "event creation storage acquires its region before use" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        Storage.init(failing.allocator(), default_capacity),
    );
    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    var storage = try Storage.init(failing.allocator(), default_capacity);
    defer storage.deinit();
    try std.testing.expectEqual(@as(usize, 1), failing.allocations);
}

test "event creation max plus one clears staging and saturates status" {
    var storage = try Storage.init(std.testing.allocator, default_capacity);
    defer storage.deinit();
    const creation: Creation = .{
        .id = wayland.ids.first_server_id,
        .interface = &wayland.protocol.core.wl_data_offer.metadata,
        .version = 1,
    };
    const pointer = storage.creations.ptr;
    try storage.begin(1);
    storage.appendAssumeCapacity(creation);
    try std.testing.expectEqualSlices(Creation, &.{creation}, storage.items());

    try std.testing.expectError(error.EventCreationCapacityExceeded, storage.begin(2));
    try std.testing.expectEqual(@as(usize, 0), storage.items().len);
    try std.testing.expectEqual(pointer, storage.creations.ptr);
    try std.testing.expectEqual(
        @as(u64, 1),
        storage.status().event_creation_capacity_rejection_count,
    );

    storage.capacity_rejection_count = std.math.maxInt(u64);
    try std.testing.expectError(error.EventCreationCapacityExceeded, storage.begin(2));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        storage.status().event_creation_capacity_rejection_count,
    );
}
