const std = @import("std");
const sys = @import("sys");
const wayland = @import("../root.zig");
const catalog_model = @import("catalog.zig");
const creation = @import("creation.zig");
const dispatch = @import("dispatch.zig");
const event = @import("event.zig");
const global_state = @import("global.zig");
const lifecycle = @import("lifecycle.zig");
const object_model = @import("object.zig");
const request_model = @import("request.zig");

pub const default_client_object_count = object_model.default_client_object_count;
pub const default_server_object_count = object_model.default_server_object_count;
pub const default_retained_global_count = global_state.default_retained_global_count;
pub const default_global_interface_name_byte_count =
    global_state.default_interface_name_byte_count_per_global;

pub const Limits = struct {
    transport: wayland.TransportLimits = .{},
    client_object_count: usize = object_model.default_client_object_count,
    server_object_count: usize = object_model.default_server_object_count,
    retained_global_count: usize = global_state.default_retained_global_count,
    global_interface_name_byte_count: usize =
        global_state.default_interface_name_byte_count_per_global,
};

pub const CapacityError = wayland.TransportCapacityError ||
    wayland.protocol.value.EncoderCapacityError ||
    event.CapacityError ||
    wayland.ids.CapacityError ||
    object_model.CapacityError ||
    global_state.CapacityError ||
    error{CapacityOverflow};

pub const Capacity = struct {
    transport: wayland.TransportCapacity,
    request_encoder: wayland.protocol.value.EncoderCapacity,
    event_storage: event.Capacity,
    event_creations: creation.Capacity,
    client_ids: wayland.ids.Capacity,
    objects: object_model.Capacity,
    globals: global_state.Capacity,
    total_requested_bytes: usize,

    pub fn derive(limits: Limits) CapacityError!Capacity {
        const transport = try wayland.TransportCapacity.derive(limits.transport);
        const request_encoder = try wayland.protocol.value.EncoderCapacity.derive(.{
            .payload_byte_count = @min(
                transport.outbound_byte_count - wayland.wire.header_size,
                wayland.protocol.value.maximum_payload_size,
            ),
            .descriptor_count = @min(
                transport.outbound_descriptor_count,
                sys.ancillary.maximum_descriptors,
            ),
        });
        const event_storage = try event.Capacity.derive(.{
            .payload_byte_count = @min(
                transport.inbound_byte_count - wayland.wire.header_size,
                wayland.protocol.value.maximum_payload_size,
            ),
            .descriptor_count = @min(
                transport.inbound_descriptor_count,
                event.maximum_descriptor_count,
            ),
        });
        const event_creations = creation.default_capacity;
        const client_ids = try wayland.ids.Capacity.derive(.{
            .client_id_count = limits.client_object_count,
        });
        const objects = try object_model.Capacity.derive(.{
            .client_object_count = limits.client_object_count,
            .server_object_count = limits.server_object_count,
        });
        const globals = try global_state.Capacity.derive(.{
            .retained_global_count = limits.retained_global_count,
            .interface_name_byte_count_per_global = limits.global_interface_name_byte_count,
        });
        const total_requested_bytes = try totalRequestedBytes(&.{
            transport.total_requested_bytes,
            request_encoder.total_requested_bytes,
            event_storage.total_requested_bytes,
            event_creations.total_requested_bytes,
            client_ids.total_requested_bytes,
            objects.total_requested_bytes,
            globals.total_requested_bytes,
        });
        return .{
            .transport = transport,
            .request_encoder = request_encoder,
            .event_storage = event_storage,
            .event_creations = event_creations,
            .client_ids = client_ids,
            .objects = objects,
            .globals = globals,
            .total_requested_bytes = total_requested_bytes,
        };
    }
};

fn totalRequestedBytes(parts: []const usize) error{CapacityOverflow}!usize {
    var total: usize = 0;
    for (parts) |part| {
        total = std.math.add(usize, total, part) catch return error.CapacityOverflow;
    }
    return total;
}

pub const StorageStatus = struct {
    transport: wayland.TransportStatus = .{},
    request_encoder: wayland.protocol.value.EncoderStatus = .{},
    event_storage: event.Status = .{},
    event_creations: creation.Status = .{},
    client_ids: wayland.ids.Status = .{},
    objects: object_model.Status = .{},
    globals: global_state.Status = .{},
};

const InitialStorage = struct {
    encoder: wayland.protocol.value.Encoder,
    event_storage: event.Storage,
    event_creations: creation.Storage,
    ids: wayland.ids.Pool,
    objects: object_model.Table,
    globals: global_state.Set,

    fn init(
        session_allocator: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!InitialStorage {
        var encoder = try wayland.protocol.value.Encoder.init(
            session_allocator,
            capacity.request_encoder,
        );
        errdefer encoder.deinit();
        var event_storage = try event.Storage.init(
            session_allocator,
            capacity.event_storage,
        );
        errdefer event_storage.deinit();
        var event_creations = try creation.Storage.init(
            session_allocator,
            capacity.event_creations,
        );
        errdefer event_creations.deinit();
        var ids = try wayland.ids.Pool.init(session_allocator, capacity.client_ids);
        errdefer ids.deinit();
        var objects = try object_model.Table.init(session_allocator, capacity.objects);
        errdefer objects.deinit();
        objects.addDisplay(
            catalog_model.Catalog.standard().require("wl_display") catch unreachable,
        ) catch unreachable;
        return .{
            .encoder = encoder,
            .event_storage = event_storage,
            .event_creations = event_creations,
            .ids = ids,
            .objects = objects,
            .globals = try global_state.Set.init(session_allocator, capacity.globals),
        };
    }

    fn deinit(self: *InitialStorage) void {
        self.globals.deinit();
        self.objects.deinit();
        self.ids.deinit();
        self.event_creations.deinit();
        self.event_storage.deinit();
        self.encoder.deinit();
        self.* = undefined;
    }
};

pub const Client = struct {
    transport: wayland.Transport,
    catalog: catalog_model.Catalog,
    ids: wayland.ids.Pool,
    objects: object_model.Table,
    globals: global_state.Set,
    encoder: wayland.protocol.value.Encoder,
    event_storage: event.Storage,
    event_creations: creation.Storage,
    fatal_state: ?event.FatalView = null,
    terminal_error: ?anyerror = null,

    pub fn connect(
        session_allocator: std.mem.Allocator,
        capacity: Capacity,
    ) !Client {
        var initial_storage = try InitialStorage.init(session_allocator, capacity);
        errdefer initial_storage.deinit();
        const transport = try wayland.connect(session_allocator, capacity.transport);
        return initOwnedParts(transport, &initial_storage);
    }

    pub fn connectNamed(
        session_allocator: std.mem.Allocator,
        display_name: []const u8,
        capacity: Capacity,
    ) !Client {
        var initial_storage = try InitialStorage.init(session_allocator, capacity);
        errdefer initial_storage.deinit();
        const transport = try wayland.connectNamed(
            session_allocator,
            display_name,
            capacity.transport,
        );
        return initOwnedParts(transport, &initial_storage);
    }

    pub fn initOwned(
        session_allocator: std.mem.Allocator,
        owned_descriptor: sys.fd.Descriptor,
        capacity: Capacity,
    ) !Client {
        var initial_storage = InitialStorage.init(session_allocator, capacity) catch |err| {
            sys.fd.close(owned_descriptor);
            return err;
        };
        errdefer initial_storage.deinit();
        const transport = try wayland.Transport.initOwned(
            session_allocator,
            owned_descriptor,
            capacity.transport,
        );
        return initOwnedParts(transport, &initial_storage);
    }

    fn initOwnedParts(
        transport: wayland.Transport,
        initial_storage: *InitialStorage,
    ) Client {
        const catalog = catalog_model.Catalog.standard();
        const client: Client = .{
            .transport = transport,
            .catalog = catalog,
            .ids = initial_storage.ids,
            .objects = initial_storage.objects,
            .globals = initial_storage.globals,
            .encoder = initial_storage.encoder,
            .event_storage = initial_storage.event_storage,
            .event_creations = initial_storage.event_creations,
        };
        initial_storage.* = undefined;
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.event_creations.deinit();
        self.event_storage.deinit();
        self.encoder.deinit();
        self.globals.deinit();
        self.objects.deinit();
        self.ids.deinit();
        self.transport.deinit();
        self.* = undefined;
    }

    pub fn fatal(self: *const Client) ?event.FatalView {
        const state = self.fatal_state orelse return null;
        return .{
            .object_id = state.object_id,
            .code = state.code,
            .message = state.message,
        };
    }

    pub fn descriptor(self: *const Client) sys.fd.Descriptor {
        return self.transport.descriptor;
    }

    pub fn storageStatus(self: *const Client) StorageStatus {
        return .{
            .transport = self.transport.status(),
            .request_encoder = self.encoder.status(),
            .event_storage = self.event_storage.status(),
            .event_creations = self.event_creations.status(),
            .client_ids = self.ids.status(),
            .objects = self.objects.status(),
            .globals = self.globals.status(),
        };
    }

    pub fn object(self: *const Client, id: u32) ?object_model.Entry {
        return self.objects.getLive(id);
    }

    pub fn global(self: *const Client, registry_id: u32, name: u32) ?event.GlobalView {
        const item = self.globals.get(registry_id, name) orelse return null;
        return .{
            .registry_id = item.registry_id,
            .name = item.name,
            .interface = item.interface,
            .version = item.version,
        };
    }

    pub fn sync(self: *Client) !u32 {
        var created: [1]u32 = undefined;
        try self.request(
            wayland.ids.display_id,
            0,
            &.{.{ .new_id = .fixed }},
            &created,
        );
        return created[0];
    }

    pub fn getRegistry(self: *Client) !u32 {
        var created: [1]u32 = undefined;
        try self.request(
            wayland.ids.display_id,
            1,
            &.{.{ .new_id = .fixed }},
            &created,
        );
        return created[0];
    }

    pub fn bind(
        self: *Client,
        registry_id: u32,
        name: u32,
        interface: *const wayland.protocol.schema.Interface,
        version: u32,
    ) !u32 {
        try self.ensureActive();
        const registry_interface = try self.catalog.require("wl_registry");
        const registry = try self.objects.requireLive(registry_id);
        if (registry.interface != registry_interface) return error.NotRegistry;
        const canonical = try self.catalog.canonical(interface);
        const advertised = try self.globals.require(registry_id, name);
        if (!std.mem.eql(u8, advertised.interface, canonical.name)) {
            return error.InterfaceMismatch;
        }
        if (version == 0 or version > advertised.version or version > canonical.version) {
            return error.InvalidVersion;
        }

        var created: [1]u32 = undefined;
        try self.request(
            registry_id,
            0,
            &.{
                .{ .uint = name },
                .{ .new_id = .{ .dynamic = .{
                    .interface = canonical.name,
                    .version = version,
                } } },
            },
            &created,
        );
        return created[0];
    }

    pub fn request(
        self: *Client,
        object_id: u32,
        opcode: u16,
        values: []const request_model.Value,
        created_ids: []u32,
    ) !void {
        try self.ensureActive();
        const parent = try self.objects.requireLive(object_id);
        const metadata = parent.interface.request(opcode) orelse {
            return error.UnknownRequestOpcode;
        };
        if (!metadata.supportedBy(parent.version)) return error.UnsupportedRequestVersion;
        if (metadata.destructor and parent.origin == .display) return error.CannotDestroyDisplay;

        const prepared = try request_model.prepare(
            &self.ids,
            &self.objects,
            self.catalog,
            &self.encoder,
            parent,
            metadata,
            values,
            created_ids,
        );
        errdefer request_model.rollback(&self.ids, &self.objects, prepared.created_ids);
        try self.transport.queueOwned(
            object_id,
            metadata.opcode,
            prepared.encoded.payload,
            prepared.encoded.descriptors,
        );
        if (metadata.destructor) {
            lifecycle.retire(
                &self.ids,
                &self.objects,
                object_id,
                parent,
                .retired_request,
            );
        }
    }

    pub fn flush(self: *Client) !wayland.stream.FlushStatus {
        try self.ensureActive();
        return self.transport.flush() catch |err| {
            self.terminal_error = err;
            return err;
        };
    }

    pub fn step(self: *Client) !event.Step {
        try self.ensureActive();
        self.event_storage.reset();
        return dispatch.step(self);
    }

    fn ensureActive(self: *const Client) !void {
        if (self.terminal_error) |err| return err;
    }
};

test "runtime capacity derives request and event scratch" {
    const capacity = try Capacity.derive(.{
        .transport = .{
            .inbound_byte_count = 13,
            .inbound_descriptor_count = 2,
            .outbound_byte_count = 17,
            .outbound_descriptor_count = 3,
        },
        .client_object_count = 5,
        .server_object_count = 7,
        .retained_global_count = 3,
        .global_interface_name_byte_count = 11,
    });
    try std.testing.expectEqual(@as(usize, 13), capacity.transport.inbound_byte_count);
    try std.testing.expectEqual(@as(usize, 2), capacity.transport.inbound_descriptor_count);
    try std.testing.expectEqual(@as(usize, 17), capacity.transport.outbound_byte_count);
    try std.testing.expectEqual(@as(usize, 3), capacity.transport.outbound_descriptor_count);
    try std.testing.expectEqual(@as(usize, 9), capacity.request_encoder.payload_byte_count);
    try std.testing.expectEqual(@as(usize, 3), capacity.request_encoder.descriptor_count);
    try std.testing.expectEqual(@as(usize, 5), capacity.event_storage.payload_byte_count);
    try std.testing.expectEqual(@as(usize, 1), capacity.event_storage.descriptor_count);
    try std.testing.expectEqual(
        creation.maximum_event_creation_count,
        capacity.event_creations.event_creation_count,
    );
    try std.testing.expectEqual(
        @sizeOf(creation.Creation),
        capacity.event_creations.event_creation_bytes,
    );
    try std.testing.expectEqual(@as(usize, 5), capacity.client_ids.client_id_count);
    try std.testing.expectEqual(@as(usize, 5), capacity.objects.client_object_count);
    try std.testing.expectEqual(@as(usize, 7), capacity.objects.server_object_count);
    try std.testing.expectEqual(@as(usize, 3), capacity.globals.retained_global_count);
    try std.testing.expectEqual(
        @as(usize, 11),
        capacity.globals.interface_name_byte_count_per_global,
    );
    try std.testing.expectEqual(
        capacity.transport.total_requested_bytes +
            capacity.request_encoder.total_requested_bytes +
            capacity.event_storage.total_requested_bytes +
            capacity.event_creations.total_requested_bytes +
            capacity.client_ids.total_requested_bytes +
            capacity.objects.total_requested_bytes +
            capacity.globals.total_requested_bytes,
        capacity.total_requested_bytes,
    );
}

test "runtime request scratch caps at one protocol message" {
    const capacity = try Capacity.derive(.{ .transport = .{
        .outbound_byte_count = 2 * @as(usize, wayland.wire.maximum_message_size),
        .outbound_descriptor_count = 2 * sys.ancillary.maximum_descriptors,
    } });
    try std.testing.expectEqual(
        @as(usize, wayland.protocol.value.maximum_payload_size),
        capacity.request_encoder.payload_byte_count,
    );
    try std.testing.expectEqual(
        @as(usize, sys.ancillary.maximum_descriptors),
        capacity.request_encoder.descriptor_count,
    );
}

test "owned descriptor closes when any cold storage acquisition fails" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    for (0..15) |fail_index| {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err|
            switch (err) {
                error.UnsupportedPlatform => return error.SkipZigTest,
                else => return err,
            };
        defer sys.fd.close(sockets[1]);
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        try std.testing.expectError(
            error.OutOfMemory,
            Client.initOwned(
                failing.allocator(),
                sockets[0],
                try Capacity.derive(.{}),
            ),
        );
        try std.testing.expect(!sys.fd.isOpen(sockets[0]));
    }
}

test "runtime storage status composes event rejections" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err|
        switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
    defer sys.fd.close(sockets[1]);
    var client = try Client.initOwned(
        std.testing.allocator,
        sockets[0],
        try Capacity.derive(.{}),
    );
    defer client.deinit();

    try std.testing.expectError(
        error.EventPayloadCapacityExceeded,
        client.event_storage.admit(client.event_storage.payload.len + 1, 0),
    );
    try std.testing.expectError(
        error.EventDescriptorCapacityExceeded,
        client.event_storage.admit(0, client.event_storage.descriptors.len + 1),
    );
    const status = client.storageStatus().event_storage;
    try std.testing.expectEqual(
        @as(u64, 1),
        status.event_payload_capacity_rejection_count,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        status.event_descriptor_capacity_rejection_count,
    );
}

test "runtime storage status composes ID object and global rejections" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;
    const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err|
        switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
    defer sys.fd.close(sockets[1]);
    var client = try Client.initOwned(
        std.testing.allocator,
        sockets[0],
        try Capacity.derive(.{
            .client_object_count = 1,
            .server_object_count = 1,
            .retained_global_count = 1,
            .global_interface_name_byte_count = 3,
        }),
    );
    defer client.deinit();
    const callback = try client.catalog.require("wl_callback");

    const client_id = try client.ids.allocate();
    try client.objects.addClient(client_id, callback, 1);
    try std.testing.expectError(error.ClientIdCapacityExceeded, client.ids.allocate());
    try std.testing.expectError(
        error.ClientObjectCapacityExceeded,
        client.objects.addClient(client_id + 1, callback, 1),
    );
    try client.objects.addServer(wayland.ids.first_server_id, callback, 1);
    try std.testing.expectError(
        error.ServerObjectCapacityExceeded,
        client.objects.addServer(wayland.ids.first_server_id + 1, callback, 1),
    );
    _ = try client.globals.add(2, 7, "abc", 1);
    try std.testing.expectError(
        error.GlobalCapacityExceeded,
        client.globals.add(2, 8, "a", 1),
    );
    try client.globals.remove(2, 7);
    try std.testing.expectError(
        error.GlobalInterfaceNameCapacityExceeded,
        client.globals.add(2, 8, "abcd", 1),
    );
    const status = client.storageStatus();
    try std.testing.expectEqual(
        @as(u64, 1),
        status.client_ids.client_id_capacity_rejection_count,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        status.objects.client_object_capacity_rejection_count,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        status.objects.server_object_capacity_rejection_count,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        status.globals.global_capacity_rejection_count,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        status.globals.global_interface_name_capacity_rejection_count,
    );
}
