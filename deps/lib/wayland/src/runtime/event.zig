const std = @import("std");
const sys = @import("sys");
const wayland = @import("../root.zig");
const message = @import("message.zig");

pub const maximum_descriptor_count = maximumDescriptorCount(
    &wayland.protocol.interfaces,
);

pub const Limits = struct {
    payload_byte_count: usize = wayland.protocol.value.maximum_payload_size,
    descriptor_count: usize = maximum_descriptor_count,
};

pub const CapacityError = error{
    EventPayloadStorageTooLarge,
    EventDescriptorStorageTooLarge,
    CapacityOverflow,
};

pub const Capacity = struct {
    payload_byte_count: usize,
    descriptor_count: usize,
    descriptor_bytes: usize,
    total_requested_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        if (limits.payload_byte_count > wayland.protocol.value.maximum_payload_size) {
            return error.EventPayloadStorageTooLarge;
        }
        if (limits.descriptor_count > maximum_descriptor_count) {
            return error.EventDescriptorStorageTooLarge;
        }
        const descriptor_bytes = std.math.mul(
            usize,
            limits.descriptor_count,
            @sizeOf(sys.fd.Descriptor),
        ) catch return error.CapacityOverflow;
        const total_requested_bytes = std.math.add(
            usize,
            limits.payload_byte_count,
            descriptor_bytes,
        ) catch return error.CapacityOverflow;
        return .{
            .payload_byte_count = limits.payload_byte_count,
            .descriptor_count = limits.descriptor_count,
            .descriptor_bytes = descriptor_bytes,
            .total_requested_bytes = total_requested_bytes,
        };
    }
};

pub const StorageError = error{
    EventPayloadCapacityExceeded,
    EventDescriptorCapacityExceeded,
};

pub const Status = struct {
    event_payload_capacity_rejection_count: u64 = 0,
    event_descriptor_capacity_rejection_count: u64 = 0,
};

pub const default_capacity = Capacity.derive(.{}) catch unreachable;

pub const FatalView = struct {
    object_id: u32,
    code: u32,
    message: []const u8,
};

pub const GlobalView = struct {
    registry_id: u32,
    name: u32,
    interface: []const u8,
    version: u32,
};

pub const CallbackDone = struct {
    callback_id: u32,
    data: u32,
};

pub const GlobalRemoved = struct {
    registry_id: u32,
    name: u32,
};

pub const EventView = union(enum) {
    fatal: FatalView,
    delete_id: u32,
    callback_done: CallbackDone,
    global: GlobalView,
    global_remove: GlobalRemoved,
    routed: message.RoutedView,
};

pub const Step = union(enum) {
    event: EventView,
    pending,
    closed,
};

pub const StoredRouted = struct {
    payload: []const u8,
    descriptors: []sys.fd.Descriptor,
};

pub const Storage = struct {
    session_allocator: std.mem.Allocator,
    payload: []u8,
    descriptors: []sys.fd.Descriptor,
    payload_count: usize = 0,
    descriptor_count: usize = 0,
    payload_capacity_rejection_count: u64 = 0,
    descriptor_capacity_rejection_count: u64 = 0,

    pub fn init(
        session_allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!Storage {
        const payload = try session_allocator.alloc(u8, capacity.payload_byte_count);
        errdefer if (payload.len != 0) session_allocator.free(payload);
        return .{
            .session_allocator = session_allocator,
            .payload = payload,
            .descriptors = try session_allocator.alloc(
                sys.fd.Descriptor,
                capacity.descriptor_count,
            ),
        };
    }

    pub fn deinit(self: *Storage) void {
        self.reset();
        if (self.payload.len != 0) self.session_allocator.free(self.payload);
        if (self.descriptors.len != 0) self.session_allocator.free(self.descriptors);
        self.* = undefined;
    }

    pub fn reset(self: *Storage) void {
        self.assertValid();
        for (self.descriptors[0..self.descriptor_count]) |descriptor| {
            if (descriptor >= 0) sys.fd.close(descriptor);
        }
        self.payload_count = 0;
        self.descriptor_count = 0;
        self.assertValid();
    }

    pub fn admit(
        self: *Storage,
        payload_byte_count: usize,
        descriptor_count: usize,
    ) StorageError!void {
        self.assertValid();
        std.debug.assert(self.payload_count == 0);
        std.debug.assert(self.descriptor_count == 0);
        var failure: ?StorageError = null;
        if (payload_byte_count > self.payload.len) {
            self.payload_capacity_rejection_count +|= 1;
            failure = error.EventPayloadCapacityExceeded;
        }
        if (descriptor_count > self.descriptors.len) {
            self.descriptor_capacity_rejection_count +|= 1;
            if (failure == null) failure = error.EventDescriptorCapacityExceeded;
        }
        if (failure) |err| return err;
    }

    pub fn storePayloadAssumeCapacity(
        self: *Storage,
        payload: []const u8,
    ) []const u8 {
        self.assertValid();
        std.debug.assert(self.payload_count == 0);
        std.debug.assert(self.descriptor_count == 0);
        std.debug.assert(payload.len <= self.payload.len);
        @memcpy(self.payload[0..payload.len], payload);
        self.payload_count = payload.len;
        self.assertValid();
        return self.payload[0..self.payload_count];
    }

    pub fn storeRoutedAssumeCapacity(
        self: *Storage,
        payload: []const u8,
        owned_descriptors: []const sys.fd.Descriptor,
    ) StoredRouted {
        const stored_payload = self.storePayloadAssumeCapacity(payload);
        std.debug.assert(owned_descriptors.len <= self.descriptors.len);
        @memcpy(self.descriptors[0..owned_descriptors.len], owned_descriptors);
        self.descriptor_count = owned_descriptors.len;
        self.assertValid();
        return .{
            .payload = stored_payload,
            .descriptors = self.descriptors[0..self.descriptor_count],
        };
    }

    pub fn status(self: *const Storage) Status {
        self.assertValid();
        return .{
            .event_payload_capacity_rejection_count = self.payload_capacity_rejection_count,
            .event_descriptor_capacity_rejection_count = self.descriptor_capacity_rejection_count,
        };
    }

    fn assertValid(self: *const Storage) void {
        std.debug.assert(self.payload_count <= self.payload.len);
        std.debug.assert(self.descriptor_count <= self.descriptors.len);
    }
};

fn maximumDescriptorCount(
    interfaces: []const wayland.protocol.schema.Interface,
) usize {
    var maximum: usize = 0;
    for (interfaces) |interface| {
        for (interface.events) |item| {
            maximum = @max(maximum, item.descriptor_count);
        }
    }
    return maximum;
}

test "runtime event capacity derives exact reusable storage" {
    const capacity = try Capacity.derive(.{
        .payload_byte_count = 13,
        .descriptor_count = 1,
    });
    try std.testing.expectEqual(@as(usize, 13), capacity.payload_byte_count);
    try std.testing.expectEqual(@as(usize, 1), capacity.descriptor_count);
    try std.testing.expectEqual(
        @sizeOf(sys.fd.Descriptor),
        capacity.descriptor_bytes,
    );
    try std.testing.expectEqual(
        13 + @sizeOf(sys.fd.Descriptor),
        capacity.total_requested_bytes,
    );
    try std.testing.expectEqual(@as(usize, 1), maximum_descriptor_count);
    try std.testing.expectEqual(
        @as(usize, wayland.protocol.value.maximum_payload_size),
        default_capacity.payload_byte_count,
    );
    try std.testing.expectEqual(
        maximum_descriptor_count,
        default_capacity.descriptor_count,
    );
    try std.testing.expectError(
        error.EventPayloadStorageTooLarge,
        Capacity.derive(.{
            .payload_byte_count = wayland.protocol.value.maximum_payload_size + 1,
        }),
    );
    try std.testing.expectError(
        error.EventDescriptorStorageTooLarge,
        Capacity.derive(.{ .descriptor_count = maximum_descriptor_count + 1 }),
    );
    for (wayland.protocol.interfaces) |interface| {
        for (interface.events) |item| {
            try std.testing.expect(item.descriptor_count <= maximum_descriptor_count);
        }
    }
}

test "runtime event storage acquires both regions before use" {
    const capacity = try Capacity.derive(.{});
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        try std.testing.expectError(
            error.OutOfMemory,
            Storage.init(failing.allocator(), capacity),
        );
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 2,
    });
    var storage = try Storage.init(failing.allocator(), capacity);
    defer storage.deinit();
    try std.testing.expectEqual(@as(usize, 2), failing.allocations);
}

test "runtime event storage rejects max plus one without mutation" {
    var storage = try Storage.init(
        std.testing.allocator,
        try Capacity.derive(.{ .payload_byte_count = 3, .descriptor_count = 1 }),
    );
    defer storage.deinit();
    const payload_pointer = storage.payload.ptr;
    const descriptor_pointer = storage.descriptors.ptr;

    try std.testing.expectError(
        error.EventPayloadCapacityExceeded,
        storage.admit(4, 2),
    );
    try std.testing.expectEqual(@as(usize, 0), storage.payload_count);
    try std.testing.expectEqual(@as(usize, 0), storage.descriptor_count);
    try std.testing.expectEqual(payload_pointer, storage.payload.ptr);
    try std.testing.expectEqual(descriptor_pointer, storage.descriptors.ptr);
    try std.testing.expectEqual(
        @as(u64, 1),
        storage.status().event_payload_capacity_rejection_count,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        storage.status().event_descriptor_capacity_rejection_count,
    );

    storage.payload_capacity_rejection_count = std.math.maxInt(u64);
    storage.descriptor_capacity_rejection_count = std.math.maxInt(u64);
    try std.testing.expectError(
        error.EventPayloadCapacityExceeded,
        storage.admit(4, 2),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        storage.status().event_payload_capacity_rejection_count,
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        storage.status().event_descriptor_capacity_rejection_count,
    );
}

test "runtime event storage closes only untaken descriptors on reset" {
    var storage = try Storage.init(std.testing.allocator, try Capacity.derive(.{}));
    defer storage.deinit();
    const pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(pipe[0]);

    try storage.admit(4, 1);
    const stored = storage.storeRoutedAssumeCapacity("data", &.{pipe[1]});
    var routed: message.RoutedView = .{
        .object_id = 2,
        .interface = &wayland.protocol.core.wl_keyboard.metadata,
        .version = 1,
        .metadata = &wayland.protocol.core.wl_keyboard.events.keymap,
        .payload = stored.payload,
        .descriptors = stored.descriptors,
    };
    const taken = try routed.takeDescriptor(0);
    defer sys.fd.close(taken);
    storage.reset();
    try std.testing.expectEqual(@as(usize, 1), try sys.fd.write(taken, "x"));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try sys.fd.read(pipe[0], &byte));
    try std.testing.expectEqual(@as(u8, 'x'), byte[0]);

    const untaken_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    defer sys.fd.close(untaken_pipe[0]);
    try storage.admit(4, 1);
    _ = storage.storeRoutedAssumeCapacity("next", &.{untaken_pipe[1]});
    storage.reset();
    try std.testing.expectEqual(
        @as(usize, 0),
        try sys.fd.read(untaken_pipe[0], &byte),
    );
}
