const std = @import("std");
const sys = @import("sys");

pub const WaitEvent = sys.x11.Message;

const x11_message_bytes = @sizeOf(WaitEvent);

pub const Limits = struct {
    received_text_byte_count: usize = 1 << 20,
    published_text_byte_count: usize = 64 * 1024,
    transfer_read_byte_count: usize = 4096,
    retained_wait_event_count: usize = 64,
};

pub const CapacityError = error{
    ReceivedTextEmpty,
    ReceivedTextTooLarge,
    PublishedTextEmpty,
    TransferReadStorageEmpty,
    WaitEventStorageEmpty,
    CapacityOverflow,
};

pub const Capacity = struct {
    received_text_byte_count: usize,
    published_text_byte_count: usize,
    transfer_read_byte_count: usize,
    retained_wait_event_count: usize,
    x11_property_long_count: u32,
    transfer_read_bytes: usize,
    retained_wait_event_bytes: usize,
    maximum_backend_working_storage_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        if (limits.received_text_byte_count == 0) return error.ReceivedTextEmpty;
        if (limits.received_text_byte_count > std.math.maxInt(u32)) {
            return error.ReceivedTextTooLarge;
        }
        if (limits.published_text_byte_count == 0) return error.PublishedTextEmpty;
        if (limits.transfer_read_byte_count == 0) return error.TransferReadStorageEmpty;
        if (limits.retained_wait_event_count == 0) return error.WaitEventStorageEmpty;
        const x11_property_long_count: u32 = @intCast(
            limits.received_text_byte_count / 4 +
                @intFromBool(limits.received_text_byte_count % 4 != 0),
        );
        const retained_wait_event_bytes = std.math.mul(
            usize,
            limits.retained_wait_event_count,
            x11_message_bytes,
        ) catch return error.CapacityOverflow;
        const maximum_backend_working_storage_bytes = @max(
            limits.transfer_read_byte_count,
            retained_wait_event_bytes,
        );
        return .{
            .received_text_byte_count = limits.received_text_byte_count,
            .published_text_byte_count = limits.published_text_byte_count,
            .transfer_read_byte_count = limits.transfer_read_byte_count,
            .retained_wait_event_count = limits.retained_wait_event_count,
            .x11_property_long_count = x11_property_long_count,
            .transfer_read_bytes = limits.transfer_read_byte_count,
            .retained_wait_event_bytes = retained_wait_event_bytes,
            .maximum_backend_working_storage_bytes = maximum_backend_working_storage_bytes,
        };
    }
};

pub const Status = struct {
    wait_event_capacity_rejection_count: u64 = 0,
    publication_capacity_rejection_count: u64 = 0,

    pub fn combine(a: Status, b: Status) Status {
        return .{
            .wait_event_capacity_rejection_count = a.wait_event_capacity_rejection_count +|
                b.wait_event_capacity_rejection_count,
            .publication_capacity_rejection_count = a.publication_capacity_rejection_count +|
                b.publication_capacity_rejection_count,
        };
    }
};

pub const PublishError = error{
    CapacityExceeded,
    Unavailable,
    Unexpected,
};

pub const Source = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    length: usize = 0,
    generation: u64 = 0,
    rejection_count: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!Source {
        std.debug.assert(capacity.published_text_byte_count > 0);
        return .{
            .allocator = allocator,
            .bytes = try allocator.alloc(u8, capacity.published_text_byte_count),
        };
    }

    pub fn deinit(self: *Source) void {
        std.debug.assert(self.length <= self.bytes.len);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn replace(self: *Source, source_bytes: []const u8) PublishError!void {
        std.debug.assert(self.length <= self.bytes.len);
        if (source_bytes.len > self.bytes.len) {
            self.rejection_count +|= 1;
            return error.CapacityExceeded;
        }
        @memcpy(self.bytes[0..source_bytes.len], source_bytes);
        self.length = source_bytes.len;
        self.generation +%= 1;
    }

    pub fn clear(self: *Source) void {
        std.debug.assert(self.length <= self.bytes.len);
        self.length = 0;
        self.generation +%= 1;
    }

    pub fn text(self: *const Source) []const u8 {
        std.debug.assert(self.length <= self.bytes.len);
        return self.bytes[0..self.length];
    }

    pub fn status(self: *const Source) Status {
        return .{
            .publication_capacity_rejection_count = self.rejection_count,
        };
    }
};

pub const WaitEvents = struct {
    allocator: std.mem.Allocator,
    items: []WaitEvent,
    retained_count: usize = 0,
    rejection_count: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!WaitEvents {
        std.debug.assert(capacity.retained_wait_event_count > 0);
        std.debug.assert(capacity.retained_wait_event_bytes % @sizeOf(WaitEvent) == 0);
        std.debug.assert(
            capacity.retained_wait_event_bytes / @sizeOf(WaitEvent) ==
                capacity.retained_wait_event_count,
        );
        return .{
            .allocator = allocator,
            .items = try allocator.alloc(WaitEvent, capacity.retained_wait_event_count),
        };
    }

    pub fn deinit(self: *WaitEvents) void {
        std.debug.assert(self.retained_count <= self.items.len);
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn reset(self: *WaitEvents) void {
        std.debug.assert(self.retained_count <= self.items.len);
        self.retained_count = 0;
    }

    pub fn admitNext(self: *WaitEvents) bool {
        std.debug.assert(self.retained_count <= self.items.len);
        if (self.retained_count < self.items.len) return true;
        self.rejection_count +|= 1;
        return false;
    }

    pub fn appendAssumeCapacity(self: *WaitEvents, event: WaitEvent) void {
        std.debug.assert(self.retained_count < self.items.len);
        self.items[self.retained_count] = event;
        self.retained_count += 1;
    }

    pub fn full(self: *const WaitEvents) bool {
        std.debug.assert(self.retained_count <= self.items.len);
        return self.retained_count == self.items.len;
    }

    pub fn retained(self: *const WaitEvents) []const WaitEvent {
        std.debug.assert(self.retained_count <= self.items.len);
        return self.items[0..self.retained_count];
    }

    pub fn status(self: *const WaitEvents) Status {
        return .{ .wait_event_capacity_rejection_count = self.rejection_count };
    }
};

test "clipboard capacity derives exact storage and rejects invalid limits" {
    const capacity = try Capacity.derive(.{});
    try std.testing.expectEqual(@as(usize, 1 << 20), capacity.received_text_byte_count);
    try std.testing.expectEqual(@as(usize, 64 * 1024), capacity.published_text_byte_count);
    try std.testing.expectEqual(@as(usize, 4096), capacity.transfer_read_byte_count);
    try std.testing.expectEqual(@as(usize, 64), capacity.retained_wait_event_count);
    try std.testing.expectEqual(@as(u32, (1 << 20) / 4), capacity.x11_property_long_count);
    try std.testing.expectEqual(@as(usize, 4096), capacity.transfer_read_bytes);
    try std.testing.expectEqual(64 * x11_message_bytes, capacity.retained_wait_event_bytes);
    try std.testing.expectEqual(
        @max(capacity.transfer_read_bytes, capacity.retained_wait_event_bytes),
        capacity.maximum_backend_working_storage_bytes,
    );
    try std.testing.expectEqual(
        @as(u32, 2),
        (try Capacity.derive(.{ .received_text_byte_count = 5 })).x11_property_long_count,
    );
    try std.testing.expectError(error.ReceivedTextEmpty, Capacity.derive(.{
        .received_text_byte_count = 0,
    }));
    if (@sizeOf(usize) > @sizeOf(u32)) {
        try std.testing.expectError(error.ReceivedTextTooLarge, Capacity.derive(.{
            .received_text_byte_count = @as(usize, std.math.maxInt(u32)) + 1,
        }));
    }
    try std.testing.expectError(error.TransferReadStorageEmpty, Capacity.derive(.{
        .transfer_read_byte_count = 0,
    }));
    try std.testing.expectError(error.PublishedTextEmpty, Capacity.derive(.{
        .published_text_byte_count = 0,
    }));
    try std.testing.expectError(error.WaitEventStorageEmpty, Capacity.derive(.{
        .retained_wait_event_count = 0,
    }));
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(.{
        .retained_wait_event_count = std.math.maxInt(usize) / x11_message_bytes + 1,
    }));
}

test "clipboard source replaces transactionally through exact capacity" {
    const capacity = try Capacity.derive(.{
        .received_text_byte_count = 7,
        .published_text_byte_count = 7,
        .transfer_read_byte_count = 3,
        .retained_wait_event_count = 2,
    });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Source.init(failing.allocator(), capacity));

    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var source = try Source.init(failing.allocator(), capacity);
    defer source.deinit();
    try source.replace("before");
    try std.testing.expectEqualStrings("before", source.text());
    try std.testing.expectEqual(@as(u64, 1), source.generation);
    try std.testing.expectError(error.CapacityExceeded, source.replace("12345678"));
    try std.testing.expectEqualStrings("before", source.text());
    try std.testing.expectEqual(@as(u64, 1), source.generation);
    try std.testing.expectEqual(Status{
        .publication_capacity_rejection_count = 1,
    }, source.status());
    try source.replace("after");
    try std.testing.expectEqualStrings("after", source.text());
    try std.testing.expectEqual(@as(u64, 2), source.generation);
    source.clear();
    try std.testing.expectEqualStrings("", source.text());
    try std.testing.expectEqual(@as(u64, 3), source.generation);
    try std.testing.expectEqual(@as(usize, 1), failing.allocations);
}

test "clipboard wait storage rejects max plus one and reuses its allocation" {
    const capacity = try Capacity.derive(.{
        .received_text_byte_count = 7,
        .transfer_read_byte_count = 3,
        .retained_wait_event_count = 2,
    });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, WaitEvents.init(failing.allocator(), capacity));

    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var events = try WaitEvents.init(failing.allocator(), capacity);
    defer events.deinit();
    try std.testing.expect(events.admitNext());
    events.appendAssumeCapacity(@splat(1));
    try std.testing.expect(events.admitNext());
    events.appendAssumeCapacity(@splat(2));
    try std.testing.expect(events.full());
    try std.testing.expect(!events.admitNext());
    try std.testing.expectEqual(@as(usize, 2), events.retained().len);
    try std.testing.expectEqual(@as(u8, 1), events.retained()[0][0]);
    try std.testing.expectEqual(@as(u8, 2), events.retained()[1][0]);
    try std.testing.expectEqual(Status{
        .wait_event_capacity_rejection_count = 1,
    }, events.status());
    events.rejection_count = std.math.maxInt(u64);
    try std.testing.expect(!events.admitNext());
    try std.testing.expectEqual(Status{
        .wait_event_capacity_rejection_count = std.math.maxInt(u64),
    }, events.status());
    events.reset();
    try std.testing.expect(events.admitNext());
    events.appendAssumeCapacity(@splat(3));
    try std.testing.expectEqual(@as(usize, 1), events.retained().len);
    try std.testing.expectEqual(@as(usize, 1), failing.allocations);
}
