const std = @import("std");
const sys = @import("sys");
const wayland = @import("../root.zig");
const catalog_model = @import("catalog.zig");
const object = @import("object.zig");

pub const NewId = union(enum) {
    fixed,
    dynamic: Dynamic,

    pub const Dynamic = struct {
        interface: []const u8,
        version: u32,
    };
};

pub const Value = union(enum) {
    int: i32,
    uint: u32,
    fixed: wayland.protocol.value.Fixed,
    string: ?[]const u8,
    object: ?u32,
    new_id: NewId,
    array: []const u8,
    descriptor_owned: sys.fd.Descriptor,
};

pub const Prepared = struct {
    encoded: wayland.protocol.value.Encoded,
    created_ids: []u32,
};

pub fn prepare(
    ids: *wayland.ids.Pool,
    objects: *object.Table,
    catalog: catalog_model.Catalog,
    encoder: *wayland.protocol.value.Encoder,
    parent: object.Entry,
    metadata: *const wayland.protocol.schema.Message,
    values: []const Value,
    created_ids: []u32,
) !Prepared {
    if (values.len != metadata.arguments.len) return error.ArgumentCountMismatch;
    if (created_ids.len != metadata.newIdCount()) return error.CreatedIdCountMismatch;
    encoder.reset();
    errdefer encoder.reset();
    var created_count: usize = 0;
    errdefer rollback(ids, objects, created_ids[0..created_count]);

    for (metadata.arguments, values) |argument, value| switch (argument.kind) {
        .int => try encoder.signed(switch (value) {
            .int => |item| item,
            else => return error.ArgumentTypeMismatch,
        }),
        .uint => try encoder.unsigned(switch (value) {
            .uint => |item| item,
            else => return error.ArgumentTypeMismatch,
        }),
        .fixed => try encoder.fixed(switch (value) {
            .fixed => |item| item,
            else => return error.ArgumentTypeMismatch,
        }),
        .string => {
            const item = switch (value) {
                .string => |item| item,
                else => return error.ArgumentTypeMismatch,
            };
            if (argument.nullable) {
                try encoder.optionalString(item);
            } else {
                try encoder.string(item orelse return error.NullArgument);
            }
        },
        .object => {
            const id = switch (value) {
                .object => |item| item,
                else => return error.ArgumentTypeMismatch,
            };
            if (id) |present| {
                const referenced = try objects.requireLive(present);
                if (argument.interface) |name| {
                    if (referenced.interface != try catalog.require(name)) {
                        return error.ObjectInterfaceMismatch;
                    }
                }
                try encoder.object(try .init(present));
            } else {
                if (!argument.nullable) return error.NullArgument;
                try encoder.optionalObject(null);
            }
        },
        .new_id => {
            const specification = switch (value) {
                .new_id => |item| item,
                else => return error.ArgumentTypeMismatch,
            };
            const interface, const version = if (argument.interface) |name| fixed: {
                switch (specification) {
                    .fixed => {},
                    else => return error.ArgumentTypeMismatch,
                }
                const interface = try catalog.require(name);
                break :fixed .{ interface, @min(parent.version, interface.version) };
            } else dynamic: {
                const dynamic = switch (specification) {
                    .dynamic => |item| item,
                    else => return error.ArgumentTypeMismatch,
                };
                const interface = try catalog.require(dynamic.interface);
                if (dynamic.version == 0 or dynamic.version > interface.version) {
                    return error.InvalidVersion;
                }
                break :dynamic .{ interface, dynamic.version };
            };
            const id = try ids.allocate();
            var registered = false;
            errdefer if (!registered) ids.abandon(id) catch unreachable;
            try objects.addClient(id, interface, version);
            created_ids[created_count] = id;
            created_count += 1;
            registered = true;
            if (argument.interface != null) {
                try encoder.newId(try .init(id));
            } else {
                try encoder.dynamicNewId(interface.name, version, try .init(id));
            }
        },
        .array => try encoder.array(switch (value) {
            .array => |item| item,
            else => return error.ArgumentTypeMismatch,
        }),
        .fd => try encoder.descriptorBorrowed(switch (value) {
            .descriptor_owned => |item| item,
            else => return error.ArgumentTypeMismatch,
        }),
    };

    std.debug.assert(created_count == created_ids.len);
    return .{
        .encoded = try encoder.finish(metadata),
        .created_ids = created_ids,
    };
}

pub fn rollback(
    ids: *wayland.ids.Pool,
    objects: *object.Table,
    created_ids: []const u32,
) void {
    var index = created_ids.len;
    while (index != 0) {
        index -= 1;
        _ = objects.removeLive(created_ids[index]) catch unreachable;
        ids.abandon(created_ids[index]) catch unreachable;
    }
}

test "fixed constructors inherit negotiated parent versions transactionally" {
    const catalog = catalog_model.Catalog.standard();
    var ids = try wayland.ids.Pool.init(std.testing.allocator, wayland.ids.default_capacity);
    defer ids.deinit();
    var objects = try object.Table.init(std.testing.allocator, object.default_capacity);
    defer objects.deinit();
    try objects.addDisplay(try catalog.require("wl_display"));
    const compositor_id = try ids.allocate();
    try objects.addClient(compositor_id, try catalog.require("wl_compositor"), 4);
    var encoder = try wayland.protocol.value.Encoder.init(
        std.testing.allocator,
        wayland.protocol.value.default_encoder_capacity,
    );
    defer encoder.deinit();

    var created: [1]u32 = undefined;
    const compositor = try objects.requireLive(compositor_id);
    const prepared = try prepare(
        &ids,
        &objects,
        catalog,
        &encoder,
        compositor,
        compositor.interface.request(0).?,
        &.{.{ .new_id = .fixed }},
        &created,
    );
    try std.testing.expectEqualStrings(
        "wl_surface",
        (try objects.requireLive(created[0])).interface.name,
    );
    try std.testing.expectEqual(@as(u32, 4), (try objects.requireLive(created[0])).version);
    try wayland.protocol.value.validate.message(
        prepared.encoded.metadata,
        prepared.encoded.payload,
        prepared.encoded.descriptors,
    );
    rollback(&ids, &objects, &created);
    try std.testing.expectEqual(created[0], try ids.allocate());
}

test "object arguments require live objects of the declared interface" {
    const catalog = catalog_model.Catalog.standard();
    var ids = try wayland.ids.Pool.init(std.testing.allocator, wayland.ids.default_capacity);
    defer ids.deinit();
    var objects = try object.Table.init(std.testing.allocator, object.default_capacity);
    defer objects.deinit();
    try objects.addDisplay(try catalog.require("wl_display"));
    const device_id = try ids.allocate();
    try objects.addClient(device_id, try catalog.require("wl_data_device"), 3);
    const wrong_id = try ids.allocate();
    try objects.addClient(wrong_id, try catalog.require("wl_output"), 3);
    var encoder = try wayland.protocol.value.Encoder.init(
        std.testing.allocator,
        wayland.protocol.value.default_encoder_capacity,
    );
    defer encoder.deinit();
    var created: [0]u32 = .{};
    const start_drag = (try objects.requireLive(device_id)).interface.request(0).?;
    try std.testing.expectError(
        error.ObjectInterfaceMismatch,
        prepare(
            &ids,
            &objects,
            catalog,
            &encoder,
            try objects.requireLive(device_id),
            start_drag,
            &.{
                .{ .object = null },
                .{ .object = wrong_id },
                .{ .object = null },
                .{ .uint = 1 },
            },
            &created,
        ),
    );
}

test "constructor capacity failure rolls back every staged client object" {
    const catalog = catalog_model.Catalog.standard();
    const id_capacity = try wayland.ids.Capacity.derive(.{ .client_id_count = 1 });
    var ids = try wayland.ids.Pool.init(std.testing.allocator, id_capacity);
    defer ids.deinit();
    const object_capacity = try object.Capacity.derive(.{
        .client_object_count = 1,
        .server_object_count = 0,
    });
    var objects = try object.Table.init(std.testing.allocator, object_capacity);
    defer objects.deinit();
    try objects.addDisplay(try catalog.require("wl_display"));
    var encoder = try wayland.protocol.value.Encoder.init(
        std.testing.allocator,
        wayland.protocol.value.default_encoder_capacity,
    );
    defer encoder.deinit();
    const arguments = [_]wayland.protocol.schema.Argument{
        .{
            .name = "first",
            .kind = .new_id,
            .interface = "wl_callback",
            .enumeration = null,
            .nullable = false,
        },
        .{
            .name = "second",
            .kind = .new_id,
            .interface = "wl_callback",
            .enumeration = null,
            .nullable = false,
        },
    };
    const metadata: wayland.protocol.schema.Message = .{
        .name = "two_constructors",
        .opcode = 0,
        .since = 1,
        .deprecated_since = null,
        .destructor = false,
        .signature = "nn",
        .descriptor_count = 0,
        .minimum_payload_size = 8,
        .arguments = &arguments,
    };
    var created: [2]u32 = undefined;

    try std.testing.expectError(
        error.ClientIdCapacityExceeded,
        prepare(
            &ids,
            &objects,
            catalog,
            &encoder,
            try objects.requireLive(wayland.ids.display_id),
            &metadata,
            &.{ .{ .new_id = .fixed }, .{ .new_id = .fixed } },
            &created,
        ),
    );
    try std.testing.expect(objects.get(wayland.ids.first_dynamic_id) == null);
    try std.testing.expectEqual(
        @as(u64, 1),
        ids.status().client_id_capacity_rejection_count,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        objects.status().client_object_capacity_rejection_count,
    );
    try std.testing.expectEqual(wayland.ids.first_dynamic_id, try ids.allocate());
}
