const std = @import("std");

pub const display_id: u32 = 1;
pub const first_dynamic_id: u32 = 2;
pub const first_server_id: u32 = 0xff000000;
pub const maximum_client_id_count: usize = first_server_id - first_dynamic_id;
pub const default_client_id_count: usize = 256;

pub const Limits = struct {
    client_id_count: usize = default_client_id_count,
};

pub const CapacityError = error{
    ClientIdStorageTooLarge,
    CapacityOverflow,
};

pub const Capacity = struct {
    client_id_count: usize,
    state_bytes: usize,
    reusable_id_bytes: usize,
    total_requested_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        if (limits.client_id_count > maximum_client_id_count) {
            return error.ClientIdStorageTooLarge;
        }
        const state_bytes = std.math.mul(
            usize,
            limits.client_id_count,
            @sizeOf(State),
        ) catch return error.CapacityOverflow;
        const reusable_id_bytes = std.math.mul(
            usize,
            limits.client_id_count,
            @sizeOf(u32),
        ) catch return error.CapacityOverflow;
        const total_requested_bytes = std.math.add(
            usize,
            state_bytes,
            reusable_id_bytes,
        ) catch return error.CapacityOverflow;
        return .{
            .client_id_count = limits.client_id_count,
            .state_bytes = state_bytes,
            .reusable_id_bytes = reusable_id_bytes,
            .total_requested_bytes = total_requested_bytes,
        };
    }
};

pub const StorageError = error{ClientIdCapacityExceeded};

pub const LifecycleError = error{
    InvalidObjectId,
    UnknownObject,
    ObjectAlreadyRetired,
    ObjectStillLive,
    DeleteAlreadyAcknowledged,
};

pub const Error = StorageError || LifecycleError;

pub const Status = struct {
    client_id_capacity_rejection_count: u64 = 0,
};

pub const default_capacity = Capacity.derive(.{}) catch unreachable;

const State = enum {
    live,
    awaiting_delete,
    reusable,
};

pub const Pool = struct {
    session_allocator: std.mem.Allocator,
    states: []State,
    reusable: []u32,
    state_count: usize = 0,
    reusable_count: usize = 0,
    capacity_rejection_count: u64 = 0,

    pub fn init(
        session_allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!Pool {
        const states = try session_allocator.alloc(State, capacity.client_id_count);
        errdefer if (states.len != 0) session_allocator.free(states);
        return .{
            .session_allocator = session_allocator,
            .states = states,
            .reusable = try session_allocator.alloc(u32, capacity.client_id_count),
        };
    }

    pub fn deinit(self: *Pool) void {
        self.assertValid();
        if (self.reusable.len != 0) self.session_allocator.free(self.reusable);
        if (self.states.len != 0) self.session_allocator.free(self.states);
        self.* = undefined;
    }

    pub fn allocate(self: *Pool) StorageError!u32 {
        self.assertValid();
        if (self.reusable_count != 0) {
            self.reusable_count -= 1;
            const id = self.reusable[self.reusable_count];
            self.states[index(id)] = .live;
            return id;
        }

        if (self.state_count == self.states.len) {
            self.capacity_rejection_count +|= 1;
            return error.ClientIdCapacityExceeded;
        }
        const id = first_dynamic_id + @as(u32, @intCast(self.state_count));
        self.states[self.state_count] = .live;
        self.state_count += 1;
        return id;
    }

    pub fn abandon(self: *Pool, id: u32) LifecycleError!void {
        const at = try self.knownIndex(id);
        switch (self.states[at]) {
            .live => {
                std.debug.assert(self.reusable_count < self.reusable.len);
                self.states[at] = .reusable;
                self.reusable[self.reusable_count] = id;
                self.reusable_count += 1;
            },
            .awaiting_delete => return error.ObjectAlreadyRetired,
            .reusable => return error.DeleteAlreadyAcknowledged,
        }
    }

    pub fn retire(self: *Pool, id: u32) LifecycleError!void {
        const at = try self.knownIndex(id);
        switch (self.states[at]) {
            .live => self.states[at] = .awaiting_delete,
            .awaiting_delete => return error.ObjectAlreadyRetired,
            .reusable => return error.DeleteAlreadyAcknowledged,
        }
    }

    pub fn acknowledgeDelete(self: *Pool, id: u32) LifecycleError!void {
        const at = try self.knownIndex(id);
        switch (self.states[at]) {
            .live => return error.ObjectStillLive,
            .awaiting_delete => {
                std.debug.assert(self.reusable_count < self.reusable.len);
                self.reusable[self.reusable_count] = id;
                self.reusable_count += 1;
                self.states[at] = .reusable;
            },
            .reusable => return error.DeleteAlreadyAcknowledged,
        }
    }

    pub fn isLive(self: *const Pool, id: u32) bool {
        const at = self.knownIndex(id) catch return false;
        return self.states[at] == .live;
    }

    pub fn status(self: *const Pool) Status {
        self.assertValid();
        return .{
            .client_id_capacity_rejection_count = self.capacity_rejection_count,
        };
    }

    fn knownIndex(self: *const Pool, id: u32) LifecycleError!usize {
        self.assertValid();
        if (id < first_dynamic_id or id >= first_server_id) return error.InvalidObjectId;
        const at = index(id);
        if (at >= self.state_count) return error.UnknownObject;
        return at;
    }

    fn assertValid(self: *const Pool) void {
        std.debug.assert(self.states.len == self.reusable.len);
        std.debug.assert(self.states.len <= maximum_client_id_count);
        std.debug.assert(self.state_count <= self.states.len);
        std.debug.assert(self.reusable_count <= self.state_count);
    }
};

fn index(id: u32) usize {
    return @intCast(id - first_dynamic_id);
}

test "client ID capacity derives two exact storage regions" {
    try std.testing.expectEqual(@as(usize, 256), default_capacity.client_id_count);
    const capacity = try Capacity.derive(.{ .client_id_count = 3 });
    try std.testing.expectEqual(@as(usize, 3), capacity.client_id_count);
    try std.testing.expectEqual(3 * @sizeOf(State), capacity.state_bytes);
    try std.testing.expectEqual(3 * @sizeOf(u32), capacity.reusable_id_bytes);
    try std.testing.expectEqual(
        capacity.state_bytes + capacity.reusable_id_bytes,
        capacity.total_requested_bytes,
    );
    try std.testing.expectError(
        error.ClientIdStorageTooLarge,
        Capacity.derive(.{ .client_id_count = maximum_client_id_count + 1 }),
    );
}

test "client ID storage is acquired before use" {
    const capacity = try Capacity.derive(.{ .client_id_count = 3 });
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        try std.testing.expectError(error.OutOfMemory, Pool.init(failing.allocator(), capacity));
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 2,
    });
    var pool = try Pool.init(failing.allocator(), capacity);
    defer pool.deinit();
    try std.testing.expectEqual(@as(usize, 2), failing.allocations);
}

test "object IDs become reusable only after delete_id acknowledgement" {
    var pool = try Pool.init(std.testing.allocator, default_capacity);
    defer pool.deinit();

    try std.testing.expectEqual(@as(u32, 2), try pool.allocate());
    try std.testing.expectEqual(@as(u32, 3), try pool.allocate());
    try pool.retire(2);
    try std.testing.expectEqual(@as(u32, 4), try pool.allocate());
    try pool.acknowledgeDelete(2);
    try std.testing.expectEqual(@as(u32, 2), try pool.allocate());
}

test "delete_id lifecycle rejects invalid transitions" {
    var pool = try Pool.init(std.testing.allocator, default_capacity);
    defer pool.deinit();

    const id = try pool.allocate();
    try std.testing.expectError(error.ObjectStillLive, pool.acknowledgeDelete(id));
    try pool.retire(id);
    try std.testing.expectError(error.ObjectAlreadyRetired, pool.retire(id));
    try pool.acknowledgeDelete(id);
    try std.testing.expectError(error.DeleteAlreadyAcknowledged, pool.acknowledgeDelete(id));
}

test "unsent object IDs can be abandoned without server acknowledgement" {
    var pool = try Pool.init(std.testing.allocator, default_capacity);
    defer pool.deinit();

    const id = try pool.allocate();
    try pool.abandon(id);
    try std.testing.expectEqual(id, try pool.allocate());
    try pool.abandon(id);
    try std.testing.expectError(error.DeleteAlreadyAcknowledged, pool.abandon(id));
}

test "client ID max plus one preserves storage and saturates status" {
    const capacity = try Capacity.derive(.{ .client_id_count = 2 });
    var pool = try Pool.init(std.testing.allocator, capacity);
    defer pool.deinit();
    const states = pool.states.ptr;
    const reusable = pool.reusable.ptr;

    try std.testing.expectEqual(@as(u32, 2), try pool.allocate());
    try std.testing.expectEqual(@as(u32, 3), try pool.allocate());
    try std.testing.expectError(error.ClientIdCapacityExceeded, pool.allocate());
    try std.testing.expectEqual(states, pool.states.ptr);
    try std.testing.expectEqual(reusable, pool.reusable.ptr);
    try std.testing.expectEqual(
        @as(u64, 1),
        pool.status().client_id_capacity_rejection_count,
    );

    pool.capacity_rejection_count = std.math.maxInt(u64);
    try std.testing.expectError(error.ClientIdCapacityExceeded, pool.allocate());
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        pool.status().client_id_capacity_rejection_count,
    );
}

test "every allocated ID has infallible rollback capacity" {
    const capacity = try Capacity.derive(.{ .client_id_count = 65 });
    var pool = try Pool.init(std.testing.allocator, capacity);
    defer pool.deinit();

    var allocated: [65]u32 = undefined;
    for (&allocated) |*id| id.* = try pool.allocate();
    for (allocated) |id| try pool.abandon(id);
    for (0..allocated.len) |_| _ = try pool.allocate();
}
