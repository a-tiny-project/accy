const std = @import("std");
const wayland = @import("../root.zig");

pub const default_client_object_count: usize = wayland.ids.default_client_id_count;
pub const default_server_object_count: usize = 256;
pub const maximum_client_object_count: usize = wayland.ids.maximum_client_id_count;
pub const maximum_server_object_count: usize =
    @as(usize, std.math.maxInt(u32) - wayland.ids.first_server_id) + 1;

pub const Origin = enum {
    display,
    client,
    server,
};

pub const State = enum {
    live,
    retired_request,
    retired_event,
};

pub const Entry = struct {
    interface: *const wayland.protocol.schema.Interface,
    version: u32,
    origin: Origin,
    state: State = .live,
};

pub const ClientSlot = ?Entry;

pub const ServerSlot = struct {
    id: u32,
    entry: Entry,
};

pub const Limits = struct {
    client_object_count: usize = default_client_object_count,
    server_object_count: usize = default_server_object_count,
};

pub const CapacityError = error{
    ClientObjectStorageTooLarge,
    ServerObjectStorageTooLarge,
    CapacityOverflow,
};

pub const Capacity = struct {
    client_object_count: usize,
    server_object_count: usize,
    client_slot_bytes: usize,
    server_slot_bytes: usize,
    total_requested_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        if (limits.client_object_count > maximum_client_object_count) {
            return error.ClientObjectStorageTooLarge;
        }
        if (limits.server_object_count > maximum_server_object_count) {
            return error.ServerObjectStorageTooLarge;
        }
        const client_slot_bytes = std.math.mul(
            usize,
            limits.client_object_count,
            @sizeOf(ClientSlot),
        ) catch return error.CapacityOverflow;
        const server_slot_bytes = std.math.mul(
            usize,
            limits.server_object_count,
            @sizeOf(ServerSlot),
        ) catch return error.CapacityOverflow;
        const total_requested_bytes = std.math.add(
            usize,
            client_slot_bytes,
            server_slot_bytes,
        ) catch return error.CapacityOverflow;
        return .{
            .client_object_count = limits.client_object_count,
            .server_object_count = limits.server_object_count,
            .client_slot_bytes = client_slot_bytes,
            .server_slot_bytes = server_slot_bytes,
            .total_requested_bytes = total_requested_bytes,
        };
    }
};

pub const StorageError = error{
    ClientObjectCapacityExceeded,
    ServerObjectCapacityExceeded,
};

pub const ModelError = error{
    DuplicateObject,
    InvalidObjectId,
    InvalidVersion,
    ObjectAlreadyRetired,
    ObjectStillLive,
    UnknownObject,
};

pub const Error = StorageError || ModelError;

pub const Status = struct {
    client_object_capacity_rejection_count: u64 = 0,
    server_object_capacity_rejection_count: u64 = 0,
};

pub const default_capacity = Capacity.derive(.{}) catch unreachable;

pub const Table = struct {
    session_allocator: std.mem.Allocator,
    display: ?Entry = null,
    clients: []ClientSlot,
    servers: []ServerSlot,
    server_count: usize = 0,
    server_live_count: usize = 0,
    client_capacity_rejection_count: u64 = 0,
    server_capacity_rejection_count: u64 = 0,

    pub fn init(
        session_allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!Table {
        const clients = try session_allocator.alloc(ClientSlot, capacity.client_object_count);
        errdefer if (clients.len != 0) session_allocator.free(clients);
        @memset(clients, null);
        return .{
            .session_allocator = session_allocator,
            .clients = clients,
            .servers = try session_allocator.alloc(ServerSlot, capacity.server_object_count),
        };
    }

    pub fn deinit(self: *Table) void {
        self.assertValid();
        if (self.servers.len != 0) self.session_allocator.free(self.servers);
        if (self.clients.len != 0) self.session_allocator.free(self.clients);
        self.* = undefined;
    }

    pub fn addDisplay(
        self: *Table,
        interface: *const wayland.protocol.schema.Interface,
    ) ModelError!void {
        self.assertValid();
        if (self.display != null) return error.DuplicateObject;
        try validateVersion(interface, 1);
        self.display = .{
            .interface = interface,
            .version = 1,
            .origin = .display,
        };
    }

    pub fn addClient(
        self: *Table,
        id: u32,
        interface: *const wayland.protocol.schema.Interface,
        version: u32,
    ) Error!void {
        self.assertValid();
        const at = clientIndex(id) orelse return error.InvalidObjectId;
        try validateVersion(interface, version);
        if (at >= self.clients.len) {
            self.client_capacity_rejection_count +|= 1;
            return error.ClientObjectCapacityExceeded;
        }
        if (self.clients[at] != null) return error.DuplicateObject;
        self.clients[at] = .{
            .interface = interface,
            .version = version,
            .origin = .client,
        };
    }

    pub fn addServer(
        self: *Table,
        id: u32,
        interface: *const wayland.protocol.schema.Interface,
        version: u32,
    ) Error!void {
        try self.validateServerInsertion(id);
        try validateVersion(interface, version);
        try self.ensureServerCapacity(1);
        self.addServerAssumeCapacity(id, interface, version);
    }

    pub fn ensureServerCapacity(self: *Table, additional_live_count: usize) StorageError!void {
        self.assertValid();
        if (additional_live_count > self.servers.len - self.server_live_count) {
            self.server_capacity_rejection_count +|= 1;
            return error.ServerObjectCapacityExceeded;
        }
    }

    pub fn validateServerInsertion(self: *const Table, id: u32) ModelError!void {
        self.assertValid();
        if (id < wayland.ids.first_server_id) return error.InvalidObjectId;
        if (self.get(id)) |entry| {
            if (entry.origin != .server or entry.state == .live) return error.DuplicateObject;
        }
    }

    pub fn addServerAssumeCapacity(
        self: *Table,
        id: u32,
        interface: *const wayland.protocol.schema.Interface,
        version: u32,
    ) void {
        self.assertValid();
        std.debug.assert(id >= wayland.ids.first_server_id);
        std.debug.assert(version != 0);
        std.debug.assert(version <= interface.version);
        if (self.serverIndex(id)) |at| {
            std.debug.assert(self.servers[at].entry.state != .live);
            self.servers[at].entry = .{
                .interface = interface,
                .version = version,
                .origin = .server,
            };
            self.server_live_count += 1;
            self.assertValid();
            return;
        }
        std.debug.assert(self.server_live_count < self.servers.len);
        if (self.server_count == self.servers.len) {
            self.removeServerAt(self.firstRetiredIndex().?);
        }
        const at = self.lowerBoundServer(id);
        std.mem.copyBackwards(
            ServerSlot,
            self.servers[at + 1 .. self.server_count + 1],
            self.servers[at..self.server_count],
        );
        self.servers[at] = .{
            .id = id,
            .entry = .{
                .interface = interface,
                .version = version,
                .origin = .server,
            },
        };
        self.server_count += 1;
        self.server_live_count += 1;
        self.assertValid();
    }

    pub fn get(self: *const Table, id: u32) ?Entry {
        self.assertValid();
        if (id == wayland.ids.display_id) return self.display;
        if (clientIndex(id)) |at| {
            if (at >= self.clients.len) return null;
            return self.clients[at];
        }
        const at = self.serverIndex(id) orelse return null;
        return self.servers[at].entry;
    }

    pub fn getLive(self: *const Table, id: u32) ?Entry {
        const entry = self.get(id) orelse return null;
        return if (entry.state == .live) entry else null;
    }

    pub fn require(self: *const Table, id: u32) ModelError!Entry {
        return self.get(id) orelse error.UnknownObject;
    }

    pub fn requireLive(self: *const Table, id: u32) ModelError!Entry {
        const entry = try self.require(id);
        if (entry.state != .live) return error.UnknownObject;
        return entry;
    }

    pub fn retire(self: *Table, id: u32, state: State) ModelError!void {
        self.assertValid();
        std.debug.assert(state != .live);
        const entry = self.getPtr(id) orelse return error.UnknownObject;
        if (entry.state != .live) return error.ObjectAlreadyRetired;
        if (entry.origin == .server) {
            std.debug.assert(self.server_live_count != 0);
            self.server_live_count -= 1;
        }
        entry.state = state;
        self.assertValid();
    }

    pub fn removeLive(self: *Table, id: u32) ModelError!Entry {
        const entry = try self.requireLive(id);
        switch (entry.origin) {
            .display => self.display = null,
            .client => self.clients[clientIndex(id).?] = null,
            .server => self.removeServerAt(self.serverIndex(id).?),
        }
        self.assertValid();
        return entry;
    }

    pub fn removeRetiredClient(self: *Table, id: u32) ModelError!Entry {
        const entry = try self.require(id);
        if (entry.origin != .client or entry.state == .live) return error.ObjectStillLive;
        self.clients[clientIndex(id).?] = null;
        self.assertValid();
        return entry;
    }

    pub fn status(self: *const Table) Status {
        self.assertValid();
        return .{
            .client_object_capacity_rejection_count = self.client_capacity_rejection_count,
            .server_object_capacity_rejection_count = self.server_capacity_rejection_count,
        };
    }

    fn getPtr(self: *Table, id: u32) ?*Entry {
        if (id == wayland.ids.display_id) {
            return if (self.display) |*entry| entry else null;
        }
        if (clientIndex(id)) |at| {
            if (at >= self.clients.len) return null;
            return if (self.clients[at]) |*entry| entry else null;
        }
        const at = self.serverIndex(id) orelse return null;
        return &self.servers[at].entry;
    }

    fn serverIndex(self: *const Table, id: u32) ?usize {
        if (id < wayland.ids.first_server_id) return null;
        const at = self.lowerBoundServer(id);
        if (at == self.server_count or self.servers[at].id != id) return null;
        return at;
    }

    fn lowerBoundServer(self: *const Table, id: u32) usize {
        var low: usize = 0;
        var high = self.server_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.servers[middle].id < id) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low;
    }

    fn firstRetiredIndex(self: *const Table) ?usize {
        for (self.servers[0..self.server_count], 0..) |slot, at| {
            if (slot.entry.state != .live) return at;
        }
        return null;
    }

    fn removeServerAt(self: *Table, at: usize) void {
        std.debug.assert(at < self.server_count);
        if (self.servers[at].entry.state == .live) {
            std.debug.assert(self.server_live_count != 0);
            self.server_live_count -= 1;
        }
        std.mem.copyForwards(
            ServerSlot,
            self.servers[at .. self.server_count - 1],
            self.servers[at + 1 .. self.server_count],
        );
        self.server_count -= 1;
    }

    fn assertValid(self: *const Table) void {
        std.debug.assert(self.clients.len <= maximum_client_object_count);
        std.debug.assert(self.servers.len <= maximum_server_object_count);
        std.debug.assert(self.server_live_count <= self.server_count);
        std.debug.assert(self.server_count <= self.servers.len);
        if (self.display) |entry| std.debug.assert(entry.origin == .display);
        for (self.clients) |slot| {
            if (slot) |entry| std.debug.assert(entry.origin == .client);
        }
        var live_count: usize = 0;
        for (self.servers[0..self.server_count], 0..) |slot, at| {
            std.debug.assert(slot.id >= wayland.ids.first_server_id);
            std.debug.assert(slot.entry.origin == .server);
            if (at != 0) std.debug.assert(self.servers[at - 1].id < slot.id);
            live_count += @intFromBool(slot.entry.state == .live);
        }
        std.debug.assert(live_count == self.server_live_count);
    }
};

fn clientIndex(id: u32) ?usize {
    if (id < wayland.ids.first_dynamic_id or id >= wayland.ids.first_server_id) return null;
    return @intCast(id - wayland.ids.first_dynamic_id);
}

fn validateVersion(
    interface: *const wayland.protocol.schema.Interface,
    version: u32,
) ModelError!void {
    if (version == 0 or version > interface.version) return error.InvalidVersion;
}

test "object capacity derives exact client and server storage" {
    try std.testing.expectEqual(@as(usize, 256), default_capacity.client_object_count);
    try std.testing.expectEqual(@as(usize, 256), default_capacity.server_object_count);
    const capacity = try Capacity.derive(.{
        .client_object_count = 3,
        .server_object_count = 5,
    });
    try std.testing.expectEqual(@as(usize, 3), capacity.client_object_count);
    try std.testing.expectEqual(@as(usize, 5), capacity.server_object_count);
    try std.testing.expectEqual(3 * @sizeOf(ClientSlot), capacity.client_slot_bytes);
    try std.testing.expectEqual(5 * @sizeOf(ServerSlot), capacity.server_slot_bytes);
    try std.testing.expectEqual(
        capacity.client_slot_bytes + capacity.server_slot_bytes,
        capacity.total_requested_bytes,
    );
    try std.testing.expectError(
        error.ClientObjectStorageTooLarge,
        Capacity.derive(.{ .client_object_count = maximum_client_object_count + 1 }),
    );
    try std.testing.expectError(
        error.ServerObjectStorageTooLarge,
        Capacity.derive(.{ .server_object_count = maximum_server_object_count + 1 }),
    );
}

test "object table acquires both regions before use" {
    const capacity = try Capacity.derive(.{
        .client_object_count = 3,
        .server_object_count = 5,
    });
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        try std.testing.expectError(error.OutOfMemory, Table.init(failing.allocator(), capacity));
    }
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 2,
    });
    var table = try Table.init(failing.allocator(), capacity);
    defer table.deinit();
    try std.testing.expectEqual(@as(usize, 2), failing.allocations);
}

test "object table retains client tombstones through deletion acknowledgement" {
    const display = &wayland.protocol.core.interfaces[0];
    const registry = &wayland.protocol.core.interfaces[1];
    var table = try Table.init(std.testing.allocator, default_capacity);
    defer table.deinit();
    try table.addDisplay(display);
    try table.addClient(2, registry, 1);

    try table.retire(2, .retired_request);
    try std.testing.expect(table.getLive(2) == null);
    try std.testing.expectEqual(State.retired_request, (try table.require(2)).state);
    try std.testing.expectEqual(Origin.client, (try table.removeRetiredClient(2)).origin);
    try std.testing.expectError(error.UnknownObject, table.require(2));
}

test "server IDs replace only retired server tombstones" {
    const callback = &wayland.protocol.core.interfaces[2];
    const id = wayland.ids.first_server_id;
    var table = try Table.init(std.testing.allocator, default_capacity);
    defer table.deinit();
    try table.addServer(id, callback, 1);
    try std.testing.expectError(error.DuplicateObject, table.addServer(id, callback, 1));
    try table.retire(id, .retired_event);
    try table.addServer(id, callback, 1);
    try std.testing.expectEqual(State.live, (try table.require(id)).state);
    try std.testing.expectError(error.InvalidObjectId, table.addServer(9, callback, 1));
}

test "server object storage reclaims retired slots and preserves sorted lookup" {
    const callback = &wayland.protocol.core.interfaces[2];
    const capacity = try Capacity.derive(.{
        .client_object_count = 0,
        .server_object_count = 2,
    });
    var table = try Table.init(std.testing.allocator, capacity);
    defer table.deinit();
    const base = wayland.ids.first_server_id;

    try table.addServer(base + 10, callback, 1);
    try table.addServer(base + 2, callback, 1);
    try std.testing.expectEqual(base + 2, table.servers[0].id);
    try std.testing.expectEqual(base + 10, table.servers[1].id);
    try table.retire(base + 2, .retired_event);
    try table.addServer(base + 5, callback, 1);
    try std.testing.expect(table.get(base + 2) == null);
    try std.testing.expectEqual(base + 5, table.servers[0].id);
    try std.testing.expectEqual(base + 10, table.servers[1].id);
    try table.retire(base + 10, .retired_request);
    try table.addServer(base + 10, callback, 1);
    try std.testing.expectEqual(State.live, (try table.require(base + 10)).state);
}

test "object max plus one preserves storage and saturates status" {
    const registry = &wayland.protocol.core.interfaces[1];
    const callback = &wayland.protocol.core.interfaces[2];
    const capacity = try Capacity.derive(.{
        .client_object_count = 1,
        .server_object_count = 1,
    });
    var table = try Table.init(std.testing.allocator, capacity);
    defer table.deinit();
    const clients = table.clients.ptr;
    const servers = table.servers.ptr;

    try table.addClient(2, registry, 1);
    try std.testing.expectError(
        error.ClientObjectCapacityExceeded,
        table.addClient(3, registry, 1),
    );
    try table.addServer(wayland.ids.first_server_id, callback, 1);
    try std.testing.expectError(
        error.ServerObjectCapacityExceeded,
        table.addServer(wayland.ids.first_server_id + 1, callback, 1),
    );
    try std.testing.expectEqual(clients, table.clients.ptr);
    try std.testing.expectEqual(servers, table.servers.ptr);
    try std.testing.expectEqual(
        @as(u64, 1),
        table.status().client_object_capacity_rejection_count,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        table.status().server_object_capacity_rejection_count,
    );

    table.client_capacity_rejection_count = std.math.maxInt(u64);
    table.server_capacity_rejection_count = std.math.maxInt(u64);
    try std.testing.expectError(
        error.ClientObjectCapacityExceeded,
        table.addClient(3, registry, 1),
    );
    try std.testing.expectError(
        error.ServerObjectCapacityExceeded,
        table.ensureServerCapacity(1),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        table.status().client_object_capacity_rejection_count,
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        table.status().server_object_capacity_rejection_count,
    );
}

test "object table rejects client ranges and impossible versions" {
    const registry = &wayland.protocol.core.interfaces[1];
    var table = try Table.init(std.testing.allocator, default_capacity);
    defer table.deinit();
    try std.testing.expectError(
        error.InvalidObjectId,
        table.addClient(wayland.ids.first_server_id, registry, 1),
    );
    try std.testing.expectError(error.InvalidVersion, table.addClient(2, registry, 2));
}
