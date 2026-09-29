const std = @import("std");
const sys = @import("sys");
const wayland = @import("../root.zig");
const event = @import("event.zig");
const lifecycle = @import("lifecycle.zig");
const object = @import("object.zig");
const semantic = @import("semantic.zig");

const Buffered = union(enum) {
    waiting,
    discarded,
    event: event.EventView,
};

pub fn step(client: anytype) !event.Step {
    while (true) {
        const dispatched = dispatchBuffered(client) catch |err| {
            if (err == error.OutOfMemory) return err;
            client.terminal_error = err;
            return err;
        };
        switch (dispatched) {
            .event => |item| return .{ .event = item },
            .discarded => continue,
            .waiting => {},
        }

        const received = client.transport.receive() catch |err| {
            client.terminal_error = err;
            return err;
        };
        switch (received) {
            .data => {},
            .pending => return .pending,
            .closed => {
                if (client.transport.inbox.queuedByteCount() != 0 or
                    client.transport.inbox.queuedDescriptorCount() != 0)
                {
                    client.terminal_error = error.TruncatedStream;
                    return error.TruncatedStream;
                }
                client.terminal_error = error.ConnectionClosed;
                return .closed;
            },
        }
    }
}

fn dispatchBuffered(client: anytype) !Buffered {
    const frame = (try client.transport.inbox.peek()) orelse return .waiting;
    const entry = try client.objects.require(frame.header.object_id);
    const metadata = entry.interface.event(frame.header.opcode) orelse {
        return error.UnknownEventOpcode;
    };
    if (!metadata.supportedBy(entry.version)) return error.UnsupportedEventVersion;
    const descriptors = client.transport.inbox.peekDescriptors(metadata.descriptor_count) orelse {
        return .waiting;
    };
    try wayland.protocol.value.validate.message(metadata, frame.payload, descriptors);

    switch (entry.state) {
        .retired_request => {
            discardFrame(client, metadata.descriptor_count);
            return .discarded;
        },
        .retired_event => return error.UnknownObject,
        .live => {},
    }

    if (entry.interface == try client.catalog.require("wl_display")) {
        return .{ .event = try dispatchDisplay(
            client,
            frame.header.opcode,
            frame.payload,
            descriptors,
        ) };
    }
    if (entry.interface == try client.catalog.require("wl_registry")) {
        return .{ .event = try dispatchRegistry(
            client,
            frame.header.object_id,
            frame.header.opcode,
            frame.payload,
            descriptors,
        ) };
    }
    if (entry.interface == try client.catalog.require("wl_callback")) {
        return .{ .event = try dispatchCallback(
            client,
            frame.header.object_id,
            frame.header.opcode,
            frame.payload,
            descriptors,
            entry,
        ) };
    }
    return .{ .event = try dispatchRouted(client, frame, descriptors, entry, metadata) };
}

fn discardFrame(client: anytype, descriptor_count: usize) void {
    for (0..descriptor_count) |_| {
        sys.fd.close(client.transport.inbox.takeDescriptor().?);
    }
    client.transport.inbox.consume() catch unreachable;
}

fn dispatchDisplay(
    client: anytype,
    opcode: u16,
    payload: []const u8,
    descriptors: []const sys.fd.Descriptor,
) !event.EventView {
    const decoded = try wayland.protocol.bootstrap.display.decodeEvent(
        opcode,
        payload,
        descriptors,
    );
    switch (decoded) {
        .delete_id => |item| {
            const entry = try client.objects.require(item.id);
            if (entry.origin != .client or entry.state == .live) {
                return error.ObjectStillLive;
            }
            try client.ids.acknowledgeDelete(item.id);
            _ = client.objects.removeRetiredClient(item.id) catch unreachable;
            client.transport.inbox.consume() catch unreachable;
            return .{ .delete_id = item.id };
        },
        .fatal => |item| {
            try client.event_storage.admit(item.message.len, 0);
            const message = client.event_storage.storePayloadAssumeCapacity(item.message);
            const fatal: event.FatalView = .{
                .object_id = item.object_id.raw,
                .code = item.code,
                .message = message,
            };
            client.fatal_state = fatal;
            client.terminal_error = error.FatalProtocol;
            client.transport.inbox.consume() catch unreachable;
            return .{ .fatal = fatal };
        },
    }
}

fn dispatchRegistry(
    client: anytype,
    registry_id: u32,
    opcode: u16,
    payload: []const u8,
    descriptors: []const sys.fd.Descriptor,
) !event.EventView {
    const decoded = try wayland.protocol.bootstrap.registry.decodeEvent(
        opcode,
        payload,
        descriptors,
    );
    switch (decoded) {
        .global => |item| {
            const admission = try client.globals.prepareAdd(
                registry_id,
                item.name,
                item.interface,
                item.version,
            );
            const global = client.globals.commitAdd(admission, item.interface);
            client.transport.inbox.consume() catch unreachable;
            return .{ .global = .{
                .registry_id = global.registry_id,
                .name = global.name,
                .interface = global.interface,
                .version = global.version,
            } };
        },
        .global_remove => |item| {
            try client.globals.remove(registry_id, item.name);
            client.transport.inbox.consume() catch unreachable;
            return .{ .global_remove = .{
                .registry_id = registry_id,
                .name = item.name,
            } };
        },
    }
}

fn dispatchCallback(
    client: anytype,
    callback_id: u32,
    opcode: u16,
    payload: []const u8,
    descriptors: []const sys.fd.Descriptor,
    entry: object.Entry,
) !event.EventView {
    const item = try wayland.protocol.bootstrap.callback.decodeEvent(opcode, payload, descriptors);
    lifecycle.retire(&client.ids, &client.objects, callback_id, entry, .retired_event);
    client.transport.inbox.consume() catch unreachable;
    return .{ .callback_done = .{
        .callback_id = callback_id,
        .data = item.data,
    } };
}

fn dispatchRouted(
    client: anytype,
    frame: wayland.stream.Frame,
    descriptors: []const sys.fd.Descriptor,
    entry: object.Entry,
    metadata: *const wayland.protocol.schema.Message,
) !event.EventView {
    try semantic.validateEvent(
        &client.objects,
        client.catalog,
        entry,
        metadata,
        frame.payload,
        descriptors,
        &client.event_creations,
    );
    try client.event_storage.admit(frame.payload.len, descriptors.len);
    semantic.commit(&client.objects, &client.event_creations);
    const stored = client.event_storage.storeRoutedAssumeCapacity(
        frame.payload,
        descriptors,
    );
    for (stored.descriptors) |descriptor| {
        std.debug.assert(descriptor == client.transport.inbox.takeDescriptor().?);
    }
    client.transport.inbox.consume() catch unreachable;
    if (metadata.destructor) {
        lifecycle.retire(
            &client.ids,
            &client.objects,
            frame.header.object_id,
            entry,
            .retired_event,
        );
    }
    return .{ .routed = .{
        .object_id = frame.header.object_id,
        .interface = entry.interface,
        .version = entry.version,
        .metadata = metadata,
        .payload = stored.payload,
        .descriptors = stored.descriptors,
    } };
}
