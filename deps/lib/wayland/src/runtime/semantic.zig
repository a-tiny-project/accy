const std = @import("std");
const sys = @import("sys");
const wayland = @import("../root.zig");
const catalog_model = @import("catalog.zig");
const creation = @import("creation.zig");
const object = @import("object.zig");

pub fn validateEvent(
    objects: *object.Table,
    catalog: catalog_model.Catalog,
    sender: object.Entry,
    metadata: *const wayland.protocol.schema.Message,
    payload: []const u8,
    descriptors: []const sys.fd.Descriptor,
    creations: *creation.Storage,
) !void {
    try creations.begin(metadata.newIdCount());
    errdefer creations.reset();
    var decoder = try wayland.protocol.value.Decoder.init(metadata, payload, descriptors);
    for (metadata.arguments) |argument| switch (argument.kind) {
        .int => _ = try decoder.signed(),
        .uint => _ = try decoder.unsigned(),
        .fixed => _ = try decoder.fixed(),
        .string => {
            if (argument.nullable) {
                _ = try decoder.optionalString();
            } else {
                _ = try decoder.string();
            }
        },
        .object => {
            const id = if (argument.nullable)
                if (try decoder.optionalObject()) |item| item.raw else continue
            else
                (try decoder.object()).raw;
            const referenced = referencedObject(objects, creations.items(), id) orelse {
                return error.UnknownObject;
            };
            if (argument.interface) |name| {
                if (referenced.interface != try catalog.require(name)) {
                    return error.ObjectInterfaceMismatch;
                }
            }
        },
        .new_id => {
            const id, const interface, const version = if (argument.interface) |name| fixed: {
                const interface = try catalog.require(name);
                break :fixed .{
                    (try decoder.newId()).raw,
                    interface,
                    @min(sender.version, interface.version),
                };
            } else dynamic: {
                const item = try decoder.dynamicNewId();
                const interface = try catalog.require(item.interface);
                if (item.version > interface.version) return error.InvalidVersion;
                break :dynamic .{ item.id.raw, interface, item.version };
            };
            try objects.validateServerInsertion(id);
            for (creations.items()) |item| {
                if (item.id == id) return error.DuplicateObject;
            }
            creations.appendAssumeCapacity(.{
                .id = id,
                .interface = interface,
                .version = version,
            });
        },
        .array => _ = try decoder.array(),
        .fd => _ = try decoder.descriptor(),
    };
    try decoder.finish();
    std.debug.assert(creations.items().len == metadata.newIdCount());
    try objects.ensureServerCapacity(creations.items().len);
}

pub fn commit(
    objects: *object.Table,
    creations: *creation.Storage,
) void {
    const items = creations.items();
    for (items) |item| {
        objects.addServerAssumeCapacity(
            item.id,
            item.interface,
            item.version,
        );
    }
    creations.reset();
}

fn referencedObject(
    objects: *const object.Table,
    creations: []const creation.Creation,
    id: u32,
) ?object.Entry {
    if (objects.getLive(id)) |entry| return entry;
    for (creations) |item| {
        if (item.id == id) return .{
            .interface = item.interface,
            .version = item.version,
            .origin = .server,
        };
    }
    return null;
}

test "event creation demand rejects before decoding or object mutation" {
    const catalog = catalog_model.Catalog.standard();
    var objects = try object.Table.init(std.testing.allocator, object.default_capacity);
    defer objects.deinit();
    try objects.addDisplay(try catalog.require("wl_display"));
    const data_offer = try catalog.require("wl_data_offer");
    const arguments = [_]wayland.protocol.schema.Argument{
        .{
            .name = "first",
            .kind = .new_id,
            .interface = "wl_data_offer",
            .enumeration = null,
            .nullable = false,
        },
        .{
            .name = "second",
            .kind = .new_id,
            .interface = "wl_data_offer",
            .enumeration = null,
            .nullable = false,
        },
    };
    const metadata: wayland.protocol.schema.Message = .{
        .name = "two_creations",
        .opcode = 0,
        .since = 1,
        .deprecated_since = null,
        .destructor = false,
        .signature = "nn",
        .descriptor_count = 0,
        .minimum_payload_size = 8,
        .arguments = &arguments,
    };
    var creations = try creation.Storage.init(
        std.testing.allocator,
        creation.default_capacity,
    );
    defer creations.deinit();
    try creations.begin(1);
    creations.appendAssumeCapacity(.{
        .id = wayland.ids.first_server_id,
        .interface = data_offer,
        .version = 1,
    });

    try std.testing.expectError(
        error.EventCreationCapacityExceeded,
        validateEvent(
            &objects,
            catalog,
            try objects.requireLive(wayland.ids.display_id),
            &metadata,
            &.{},
            &.{},
            &creations,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), creations.items().len);
    try std.testing.expect(objects.get(wayland.ids.first_server_id) == null);
    try std.testing.expectEqual(
        @as(u64, 1),
        creations.status().event_creation_capacity_rejection_count,
    );
}

test "server object capacity rejects before commit or object mutation" {
    const catalog = catalog_model.Catalog.standard();
    const object_capacity = try object.Capacity.derive(.{
        .client_object_count = 1,
        .server_object_count = 0,
    });
    var objects = try object.Table.init(std.testing.allocator, object_capacity);
    defer objects.deinit();
    try objects.addDisplay(try catalog.require("wl_display"));
    const device = try catalog.require("wl_data_device");
    try objects.addClient(wayland.ids.first_dynamic_id, device, 3);
    var encoder = try wayland.protocol.value.Encoder.init(
        std.testing.allocator,
        wayland.protocol.value.default_encoder_capacity,
    );
    defer encoder.deinit();
    try encoder.newId(try .init(wayland.ids.first_server_id));
    const encoded = try encoder.finish(device.event(0).?);
    var creations = try creation.Storage.init(
        std.testing.allocator,
        creation.default_capacity,
    );
    defer creations.deinit();

    try std.testing.expectError(
        error.ServerObjectCapacityExceeded,
        validateEvent(
            &objects,
            catalog,
            try objects.requireLive(wayland.ids.first_dynamic_id),
            encoded.metadata,
            encoded.payload,
            encoded.descriptors,
            &creations,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), creations.items().len);
    try std.testing.expect(objects.get(wayland.ids.first_server_id) == null);
    try std.testing.expectEqual(
        @as(u64, 1),
        objects.status().server_object_capacity_rejection_count,
    );
}

test "incoming fixed new IDs inherit sender versions and commit atomically" {
    const catalog = catalog_model.Catalog.standard();
    var objects = try object.Table.init(std.testing.allocator, object.default_capacity);
    defer objects.deinit();
    try objects.addDisplay(try catalog.require("wl_display"));
    const device = try catalog.require("wl_data_device");
    try objects.addClient(2, device, 3);
    var encoder = try wayland.protocol.value.Encoder.init(
        std.testing.allocator,
        wayland.protocol.value.default_encoder_capacity,
    );
    defer encoder.deinit();
    try encoder.newId(try .init(wayland.ids.first_server_id));
    const encoded = try encoder.finish(device.event(0).?);
    var creations = try creation.Storage.init(
        std.testing.allocator,
        creation.default_capacity,
    );
    defer creations.deinit();

    try validateEvent(
        &objects,
        catalog,
        try objects.requireLive(2),
        encoded.metadata,
        encoded.payload,
        encoded.descriptors,
        &creations,
    );
    try std.testing.expect(objects.get(wayland.ids.first_server_id) == null);
    commit(&objects, &creations);
    const offer = try objects.requireLive(wayland.ids.first_server_id);
    try std.testing.expectEqualStrings("wl_data_offer", offer.interface.name);
    try std.testing.expectEqual(@as(u32, 3), offer.version);

    try objects.retire(wayland.ids.first_server_id, .retired_request);
    encoder.reset();
    try encoder.newId(try .init(wayland.ids.first_server_id));
    const replacement = try encoder.finish(device.event(0).?);
    try validateEvent(
        &objects,
        catalog,
        try objects.requireLive(2),
        replacement.metadata,
        replacement.payload,
        replacement.descriptors,
        &creations,
    );
    commit(&objects, &creations);
    try std.testing.expectEqual(
        object.State.live,
        (try objects.require(wayland.ids.first_server_id)).state,
    );
}

test "incoming object references require the declared live interface" {
    const catalog = catalog_model.Catalog.standard();
    var objects = try object.Table.init(std.testing.allocator, object.default_capacity);
    defer objects.deinit();
    try objects.addDisplay(try catalog.require("wl_display"));
    const pointer = try catalog.require("wl_pointer");
    try objects.addServer(wayland.ids.first_server_id, pointer, 8);
    try objects.addClient(2, try catalog.require("wl_output"), 3);
    var encoder = try wayland.protocol.value.Encoder.init(
        std.testing.allocator,
        wayland.protocol.value.default_encoder_capacity,
    );
    defer encoder.deinit();
    try encoder.unsigned(1);
    try encoder.object(try .init(2));
    try encoder.fixed(.fromRaw(0));
    try encoder.fixed(.fromRaw(0));
    const encoded = try encoder.finish(pointer.event(0).?);
    var creations = try creation.Storage.init(
        std.testing.allocator,
        creation.default_capacity,
    );
    defer creations.deinit();

    try std.testing.expectError(
        error.ObjectInterfaceMismatch,
        validateEvent(
            &objects,
            catalog,
            try objects.requireLive(wayland.ids.first_server_id),
            encoded.metadata,
            encoded.payload,
            encoded.descriptors,
            &creations,
        ),
    );
}
