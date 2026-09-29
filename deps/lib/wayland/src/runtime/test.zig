const std = @import("std");
const runtime = @import("root.zig");

const experience = struct {
    const sys = @import("sys");
    const wayland = @import("../root.zig");

    const core = wayland.protocol.core;
    const test_client_capacity = runtime.Capacity.derive(.{}) catch unreachable;
    const test_transport_capacity = wayland.TransportCapacity.derive(.{}) catch unreachable;

    const AllocationHarness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const sockets = try sys.fd.socketPairUnixStream(.{ .close_on_exec = true });
            var client = runtime.Client.initOwned(allocator, sockets[0], test_client_capacity) catch |err| {
                sys.fd.close(sockets[1]);
                return err;
            };
            defer client.deinit();
            defer sys.fd.close(sockets[1]);
            _ = try client.getRegistry();
            _ = try client.sync();
        }
    };

    const IncomingAllocationHarness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const sockets = try sys.fd.socketPairUnixStream(.{ .close_on_exec = true });
            var client = runtime.Client.initOwned(allocator, sockets[0], test_client_capacity) catch |err| {
                sys.fd.close(sockets[1]);
                return err;
            };
            defer client.deinit();
            var server = try wayland.Transport.initOwned(std.testing.allocator, sockets[1], test_transport_capacity);
            defer server.deinit();
            var encoder = try wayland.protocol.value.Encoder.init(
                std.testing.allocator,
                wayland.protocol.value.default_encoder_capacity,
            );
            defer encoder.deinit();

            const registry_id = try client.getRegistry();
            try queueGlobal(&server, &encoder, registry_id, 41, "wl_data_device", 3);
            try queueGlobal(&server, &encoder, registry_id, 42, "wl_keyboard", 3);
            _ = try server.flush();
            _ = try nextEvent(&client);
            _ = try nextEvent(&client);
            const device_id = try client.bind(
                registry_id,
                41,
                &core.wl_data_device.metadata,
                3,
            );
            const keyboard_id = try client.bind(
                registry_id,
                42,
                &core.wl_keyboard.metadata,
                3,
            );

            encoder.reset();
            try encoder.newId(try .init(wayland.ids.first_server_id));
            const offer = try encoder.finish(&core.wl_data_device.events.data_offer);
            try server.queueOwned(device_id, offer.opcode(), offer.payload, offer.descriptors);
            const pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
            defer sys.fd.close(pipe[0]);
            var write_queued = false;
            defer if (!write_queued) sys.fd.close(pipe[1]);
            encoder.reset();
            try encoder.unsigned(1);
            try encoder.descriptorBorrowed(pipe[1]);
            try encoder.unsigned(64);
            const keymap = try encoder.finish(&core.wl_keyboard.events.keymap);
            try server.queueOwned(keyboard_id, keymap.opcode(), keymap.payload, keymap.descriptors);
            write_queued = true;
            _ = try server.flush();

            _ = try nextEvent(&client);
            _ = try nextEvent(&client);
        }
    };

    fn nextEvent(client: *runtime.Client) !runtime.EventView {
        return switch (try client.step()) {
            .event => |event| event,
            .pending => error.UnexpectedPending,
            .closed => error.UnexpectedClose,
        };
    }

    fn nextFrame(transport: *wayland.Transport) !wayland.stream.Frame {
        while (true) {
            if (try transport.inbox.peek()) |frame| return frame;
            switch (try transport.receive()) {
                .data => {},
                .pending => return error.UnexpectedPending,
                .closed => return error.UnexpectedClose,
            }
        }
    }

    fn queueGlobal(
        transport: *wayland.Transport,
        encoder: *wayland.protocol.value.Encoder,
        registry_id: u32,
        name: u32,
        interface: []const u8,
        version: u32,
    ) !void {
        encoder.reset();
        try encoder.unsigned(name);
        try encoder.string(interface);
        try encoder.unsigned(version);
        const encoded = try encoder.finish(&core.wl_registry.events.global);
        try transport.queueOwned(registry_id, encoded.opcode(), encoded.payload, encoded.descriptors);
    }

    fn queueWordEvent(
        transport: *wayland.Transport,
        encoder: *wayland.protocol.value.Encoder,
        object_id: u32,
        metadata: *const wayland.protocol.schema.Message,
        value: u32,
    ) !void {
        encoder.reset();
        try encoder.unsigned(value);
        const encoded = try encoder.finish(metadata);
        try transport.queueOwned(object_id, encoded.opcode(), encoded.payload, encoded.descriptors);
    }

    test "client bootstraps registry and sync with deletion-gated ID reuse" {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
        var client = runtime.Client.initOwned(std.testing.allocator, sockets[0], test_client_capacity) catch |err| {
            sys.fd.close(sockets[1]);
            return err;
        };
        defer client.deinit();
        var server = try wayland.Transport.initOwned(std.testing.allocator, sockets[1], test_transport_capacity);
        defer server.deinit();
        var encoder = try wayland.protocol.value.Encoder.init(
            std.testing.allocator,
            wayland.protocol.value.default_encoder_capacity,
        );
        defer encoder.deinit();

        const registry_id = try client.getRegistry();
        const callback_id = try client.sync();
        try std.testing.expectEqual(@as(u32, 2), registry_id);
        try std.testing.expectEqual(@as(u32, 3), callback_id);
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try client.flush());

        const get_registry = try nextFrame(&server);
        try std.testing.expectEqual(wayland.ids.display_id, get_registry.header.object_id);
        try std.testing.expectEqual(core.wl_display.requests.get_registry.opcode, get_registry.header.opcode);
        var registry_decoder = try wayland.protocol.value.Decoder.init(
            &core.wl_display.requests.get_registry,
            get_registry.payload,
            &.{},
        );
        try std.testing.expectEqual(registry_id, (try registry_decoder.newId()).raw);
        try registry_decoder.finish();
        try server.inbox.consume();

        const sync = try nextFrame(&server);
        try std.testing.expectEqual(core.wl_display.requests.sync.opcode, sync.header.opcode);
        var sync_decoder = try wayland.protocol.value.Decoder.init(
            &core.wl_display.requests.sync,
            sync.payload,
            &.{},
        );
        try std.testing.expectEqual(callback_id, (try sync_decoder.newId()).raw);
        try sync_decoder.finish();
        try server.inbox.consume();

        try queueGlobal(&server, &encoder, registry_id, 44, "wl_keyboard", 1);
        try queueWordEvent(&server, &encoder, callback_id, &core.wl_callback.events.done, 91);
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());

        const global_event = try nextEvent(&client);
        try std.testing.expectEqual(@as(u32, 44), global_event.global.name);
        try std.testing.expectEqualStrings("wl_keyboard", global_event.global.interface);
        try std.testing.expectEqual(
            global_event.global.interface.ptr,
            client.global(registry_id, 44).?.interface.ptr,
        );
        try std.testing.expectEqualStrings(
            "wl_keyboard",
            client.global(registry_id, 44).?.interface,
        );
        try std.testing.expectError(
            error.InterfaceMismatch,
            client.bind(registry_id, 44, &core.wl_output.metadata, 1),
        );
        try std.testing.expectError(
            error.InvalidVersion,
            client.bind(registry_id, 44, &core.wl_keyboard.metadata, 2),
        );
        const keyboard_id = try client.bind(registry_id, 44, &core.wl_keyboard.metadata, 1);
        try std.testing.expectEqual(@as(u32, 4), keyboard_id);
        try std.testing.expectError(
            error.NotRegistry,
            client.bind(keyboard_id, 44, &core.wl_keyboard.metadata, 1),
        );

        const done_event = try nextEvent(&client);
        try std.testing.expectEqual(callback_id, done_event.callback_done.callback_id);
        try std.testing.expectEqual(@as(u32, 91), done_event.callback_done.data);
        try std.testing.expect(client.object(callback_id) == null);

        try std.testing.expectEqual(@as(u32, 5), try client.sync());
        try queueWordEvent(
            &server,
            &encoder,
            wayland.ids.display_id,
            &core.wl_display.events.delete_id,
            callback_id,
        );
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());
        const deleted = try nextEvent(&client);
        try std.testing.expectEqual(callback_id, deleted.delete_id);
        try std.testing.expectEqual(callback_id, try client.sync());

        try queueWordEvent(
            &server,
            &encoder,
            registry_id,
            &core.wl_registry.events.global_remove,
            44,
        );
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());
        const removed = try nextEvent(&client);
        try std.testing.expectEqual(@as(u32, 44), removed.global_remove.name);
        try std.testing.expect(client.global(registry_id, 44) == null);
    }

    test "routed event views transfer taken descriptors and close expired descriptors" {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
        var client = runtime.Client.initOwned(std.testing.allocator, sockets[0], test_client_capacity) catch |err| {
            sys.fd.close(sockets[1]);
            return err;
        };
        defer client.deinit();
        var server = try wayland.Transport.initOwned(std.testing.allocator, sockets[1], test_transport_capacity);
        defer server.deinit();
        var encoder = try wayland.protocol.value.Encoder.init(
            std.testing.allocator,
            wayland.protocol.value.default_encoder_capacity,
        );
        defer encoder.deinit();

        const registry_id = try client.getRegistry();
        try queueGlobal(&server, &encoder, registry_id, 8, "wl_keyboard", 1);
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());
        _ = try nextEvent(&client);
        const keyboard_id = try client.bind(registry_id, 8, &core.wl_keyboard.metadata, 1);

        const pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
        defer sys.fd.close(pipe[0]);
        var descriptor_queued = false;
        defer if (!descriptor_queued) sys.fd.close(pipe[1]);
        encoder.reset();
        try encoder.unsigned(1);
        try encoder.descriptorBorrowed(pipe[1]);
        try encoder.unsigned(4096);
        const keymap = try encoder.finish(&core.wl_keyboard.events.keymap);
        try server.queueOwned(keyboard_id, keymap.opcode(), keymap.payload, keymap.descriptors);
        descriptor_queued = true;
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());

        var event = try nextEvent(&client);
        try std.testing.expectEqualStrings("wl_keyboard", event.routed.interface.name);
        try std.testing.expectEqualStrings("keymap", event.routed.metadata.name);
        try std.testing.expectEqual(client.event_storage.payload.ptr, event.routed.payload.ptr);
        try std.testing.expectEqual(
            client.event_storage.descriptors.ptr,
            event.routed.descriptors.ptr,
        );
        var decoder = try event.routed.borrowedDecoder();
        try std.testing.expectEqual(@as(u32, 1), try decoder.unsigned());
        _ = try decoder.descriptor();
        try std.testing.expectEqual(@as(u32, 4096), try decoder.unsigned());
        try decoder.finish();
        const descriptor = try event.routed.takeDescriptor(0);
        defer sys.fd.close(descriptor);
        try std.testing.expectEqual(@as(usize, 1), try sys.fd.write(descriptor, "k"));
        var byte: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 1), try sys.fd.read(pipe[0], &byte));
        try std.testing.expectEqual(@as(u8, 'k'), byte[0]);

        const untaken_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
        defer sys.fd.close(untaken_pipe[0]);
        var untaken_queued = false;
        defer if (!untaken_queued) sys.fd.close(untaken_pipe[1]);
        encoder.reset();
        try encoder.unsigned(1);
        try encoder.descriptorBorrowed(untaken_pipe[1]);
        try encoder.unsigned(8192);
        const untaken_keymap = try encoder.finish(&core.wl_keyboard.events.keymap);
        try server.queueOwned(
            keyboard_id,
            untaken_keymap.opcode(),
            untaken_keymap.payload,
            untaken_keymap.descriptors,
        );
        untaken_queued = true;
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());
        const untaken_event = try nextEvent(&client);
        try std.testing.expectEqualStrings("keymap", untaken_event.routed.metadata.name);
        try std.testing.expectEqual(runtime.Step.pending, try client.step());
        try std.testing.expectEqual(@as(usize, 0), try sys.fd.read(untaken_pipe[0], &byte));
    }

    test "released objects discard stale descriptors until delete ID" {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
        var client = runtime.Client.initOwned(std.testing.allocator, sockets[0], test_client_capacity) catch |err| {
            sys.fd.close(sockets[1]);
            return err;
        };
        defer client.deinit();
        var server = try wayland.Transport.initOwned(std.testing.allocator, sockets[1], test_transport_capacity);
        defer server.deinit();
        var encoder = try wayland.protocol.value.Encoder.init(
            std.testing.allocator,
            wayland.protocol.value.default_encoder_capacity,
        );
        defer encoder.deinit();

        const registry_id = try client.getRegistry();
        try queueGlobal(&server, &encoder, registry_id, 21, "wl_keyboard", 3);
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());
        _ = try nextEvent(&client);
        const keyboard_id = try client.bind(registry_id, 21, &core.wl_keyboard.metadata, 3);
        try client.request(
            keyboard_id,
            core.wl_keyboard.requests.release.opcode,
            &.{},
            &.{},
        );
        try std.testing.expect(client.object(keyboard_id) == null);
        const later_callback = try client.sync();
        try std.testing.expect(keyboard_id != later_callback);

        const first_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
        defer sys.fd.close(first_pipe[0]);
        var first_write_queued = false;
        defer if (!first_write_queued) sys.fd.close(first_pipe[1]);
        encoder.reset();
        try encoder.unsigned(1);
        try encoder.descriptorBorrowed(first_pipe[1]);
        try encoder.unsigned(128);
        const first_stale = try encoder.finish(&core.wl_keyboard.events.keymap);
        try server.queueOwned(
            keyboard_id,
            first_stale.opcode(),
            first_stale.payload,
            first_stale.descriptors,
        );
        first_write_queued = true;
        const second_pipe = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
        defer sys.fd.close(second_pipe[0]);
        var second_write_queued = false;
        defer if (!second_write_queued) sys.fd.close(second_pipe[1]);
        encoder.reset();
        try encoder.unsigned(1);
        try encoder.descriptorBorrowed(second_pipe[1]);
        try encoder.unsigned(256);
        const second_stale = try encoder.finish(&core.wl_keyboard.events.keymap);
        try server.queueOwned(
            keyboard_id,
            second_stale.opcode(),
            second_stale.payload,
            second_stale.descriptors,
        );
        second_write_queued = true;
        try queueWordEvent(
            &server,
            &encoder,
            wayland.ids.display_id,
            &core.wl_display.events.delete_id,
            keyboard_id,
        );
        try queueWordEvent(
            &server,
            &encoder,
            later_callback,
            &core.wl_callback.events.done,
            77,
        );
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());

        const deleted = try nextEvent(&client);
        try std.testing.expectEqual(keyboard_id, deleted.delete_id);
        var byte: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 0), try sys.fd.read(first_pipe[0], &byte));
        try std.testing.expectEqual(@as(usize, 0), try sys.fd.read(second_pipe[0], &byte));
        const done = try nextEvent(&client);
        try std.testing.expectEqual(later_callback, done.callback_done.callback_id);
        try std.testing.expectEqual(@as(u32, 77), done.callback_done.data);
        try std.testing.expectEqual(keyboard_id, try client.sync());
    }

    test "generic constructors register both client and server objects" {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
        var client = runtime.Client.initOwned(std.testing.allocator, sockets[0], test_client_capacity) catch |err| {
            sys.fd.close(sockets[1]);
            return err;
        };
        defer client.deinit();
        var server = try wayland.Transport.initOwned(std.testing.allocator, sockets[1], test_transport_capacity);
        defer server.deinit();
        var encoder = try wayland.protocol.value.Encoder.init(
            std.testing.allocator,
            wayland.protocol.value.default_encoder_capacity,
        );
        defer encoder.deinit();

        const registry_id = try client.getRegistry();
        try queueGlobal(&server, &encoder, registry_id, 31, "wl_compositor", 4);
        try queueGlobal(&server, &encoder, registry_id, 32, "wl_data_device", 3);
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());
        _ = try nextEvent(&client);
        _ = try nextEvent(&client);

        const compositor_id = try client.bind(
            registry_id,
            31,
            &core.wl_compositor.metadata,
            4,
        );
        var created: [1]u32 = undefined;
        try client.request(
            compositor_id,
            core.wl_compositor.requests.create_surface.opcode,
            &.{.{ .new_id = .fixed }},
            &created,
        );
        const surface = client.object(created[0]).?;
        try std.testing.expectEqualStrings("wl_surface", surface.interface.name);
        try std.testing.expectEqual(@as(u32, 4), surface.version);

        const device_id = try client.bind(
            registry_id,
            32,
            &core.wl_data_device.metadata,
            3,
        );
        const offer_id = wayland.ids.first_server_id;
        encoder.reset();
        try encoder.newId(try .init(offer_id));
        const offer = try encoder.finish(&core.wl_data_device.events.data_offer);
        try server.queueOwned(device_id, offer.opcode(), offer.payload, offer.descriptors);
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());

        const routed = try nextEvent(&client);
        try std.testing.expectEqualStrings("data_offer", routed.routed.metadata.name);
        var decoder = try routed.routed.borrowedDecoder();
        try std.testing.expectEqual(offer_id, (try decoder.newId()).raw);
        try decoder.finish();
        const registered = client.object(offer_id).?;
        try std.testing.expectEqualStrings("wl_data_offer", registered.interface.name);
        try std.testing.expectEqual(@as(u32, 3), registered.version);
    }

    test "callback destruction makes a repeated event stale" {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
        var client = runtime.Client.initOwned(std.testing.allocator, sockets[0], test_client_capacity) catch |err| {
            sys.fd.close(sockets[1]);
            return err;
        };
        defer client.deinit();
        var server = try wayland.Transport.initOwned(std.testing.allocator, sockets[1], test_transport_capacity);
        defer server.deinit();
        var encoder = try wayland.protocol.value.Encoder.init(
            std.testing.allocator,
            wayland.protocol.value.default_encoder_capacity,
        );
        defer encoder.deinit();

        const callback_id = try client.sync();
        try queueWordEvent(&server, &encoder, callback_id, &core.wl_callback.events.done, 1);
        try queueWordEvent(&server, &encoder, callback_id, &core.wl_callback.events.done, 2);
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());
        _ = try nextEvent(&client);
        try std.testing.expectError(error.UnknownObject, client.step());
    }

    test "fatal display events are retained and stop further requests" {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
        var client = runtime.Client.initOwned(std.testing.allocator, sockets[0], test_client_capacity) catch |err| {
            sys.fd.close(sockets[1]);
            return err;
        };
        defer client.deinit();
        var server = try wayland.Transport.initOwned(std.testing.allocator, sockets[1], test_transport_capacity);
        defer server.deinit();
        var encoder = try wayland.protocol.value.Encoder.init(
            std.testing.allocator,
            wayland.protocol.value.default_encoder_capacity,
        );
        defer encoder.deinit();

        encoder.reset();
        try encoder.object(try .init(wayland.ids.display_id));
        try encoder.unsigned(3);
        try encoder.string("compositor stopped");
        const encoded = try encoder.finish(&core.wl_display.events.@"error");
        try server.queueOwned(
            wayland.ids.display_id,
            encoded.opcode(),
            encoded.payload,
            encoded.descriptors,
        );
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());

        const event = try nextEvent(&client);
        try std.testing.expectEqualStrings("compositor stopped", event.fatal.message);
        try std.testing.expectEqualStrings("compositor stopped", client.fatal().?.message);
        try std.testing.expectEqual(event.fatal.message.ptr, client.fatal().?.message.ptr);
        try std.testing.expectError(error.FatalProtocol, client.sync());
        try std.testing.expectError(error.FatalProtocol, client.step());
        try std.testing.expectEqualStrings("compositor stopped", client.fatal().?.message);
    }

    test "clean closure is reported once and then remains terminal" {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
        var client = runtime.Client.initOwned(std.testing.allocator, sockets[0], test_client_capacity) catch |err| {
            sys.fd.close(sockets[1]);
            return err;
        };
        defer client.deinit();
        sys.fd.close(sockets[1]);

        try std.testing.expectEqual(runtime.Step.closed, try client.step());
        try std.testing.expectError(error.ConnectionClosed, client.step());
        try std.testing.expectError(error.ConnectionClosed, client.sync());
    }

    test "unknown event objects poison the connection deterministically" {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
        var client = runtime.Client.initOwned(std.testing.allocator, sockets[0], test_client_capacity) catch |err| {
            sys.fd.close(sockets[1]);
            return err;
        };
        defer client.deinit();
        var server = try wayland.Transport.initOwned(std.testing.allocator, sockets[1], test_transport_capacity);
        defer server.deinit();
        try server.queueOwned(92, 0, &.{}, &.{});
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());

        try std.testing.expectError(error.UnknownObject, client.step());
        try std.testing.expectError(error.UnknownObject, client.step());
        try std.testing.expectError(error.UnknownObject, client.sync());
    }

    test "a closed stream with a message missing its descriptor is truncated" {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
        var client = runtime.Client.initOwned(std.testing.allocator, sockets[0], test_client_capacity) catch |err| {
            sys.fd.close(sockets[1]);
            return err;
        };
        defer client.deinit();
        var server = try wayland.Transport.initOwned(std.testing.allocator, sockets[1], test_transport_capacity);
        var encoder = try wayland.protocol.value.Encoder.init(
            std.testing.allocator,
            wayland.protocol.value.default_encoder_capacity,
        );
        defer encoder.deinit();
        const registry_id = try client.getRegistry();
        try queueGlobal(&server, &encoder, registry_id, 7, "wl_keyboard", 3);
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());
        _ = try nextEvent(&client);
        const keyboard_id = try client.bind(registry_id, 7, &core.wl_keyboard.metadata, 3);
        try client.request(
            keyboard_id,
            core.wl_keyboard.requests.release.opcode,
            &.{},
            &.{},
        );

        encoder.reset();
        try encoder.unsigned(1);
        try encoder.descriptorBorrowed(91);
        try encoder.unsigned(64);
        const encoded = try encoder.finish(&core.wl_keyboard.events.keymap);
        const header = try wayland.wire.Header.init(keyboard_id, encoded.opcode(), encoded.payload.len);
        var header_bytes: [wayland.wire.header_size]u8 = undefined;
        try header.encode(&header_bytes);
        try std.testing.expectEqual(header_bytes.len, try sys.fd.write(server.descriptor, &header_bytes));
        try std.testing.expectEqual(runtime.Step.pending, try client.step());
        try std.testing.expectEqual(encoded.payload.len, try sys.fd.write(server.descriptor, encoded.payload));
        server.deinit();

        try std.testing.expectError(error.TruncatedStream, client.step());
        try std.testing.expectError(error.TruncatedStream, client.step());
    }

    test "runtime rejects malformed event payload before mutating object state" {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
        var client = runtime.Client.initOwned(std.testing.allocator, sockets[0], test_client_capacity) catch |err| {
            sys.fd.close(sockets[1]);
            return err;
        };
        defer client.deinit();
        var server = try wayland.Transport.initOwned(std.testing.allocator, sockets[1], test_transport_capacity);
        defer server.deinit();

        const callback_id = try client.sync();
        try server.queueOwned(callback_id, core.wl_callback.events.done.opcode, &.{}, &.{});
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());
        try std.testing.expectError(error.PayloadTooSmall, client.step());
        try std.testing.expect(client.object(callback_id) != null);
        try std.testing.expectError(error.PayloadTooSmall, client.sync());
    }

    test "request dispatch enforces negotiated versions and retires destructors" {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err| switch (err) {
            error.UnsupportedPlatform => return error.SkipZigTest,
            else => return err,
        };
        var client = runtime.Client.initOwned(std.testing.allocator, sockets[0], test_client_capacity) catch |err| {
            sys.fd.close(sockets[1]);
            return err;
        };
        defer client.deinit();
        var server = try wayland.Transport.initOwned(std.testing.allocator, sockets[1], test_transport_capacity);
        defer server.deinit();
        var encoder = try wayland.protocol.value.Encoder.init(
            std.testing.allocator,
            wayland.protocol.value.default_encoder_capacity,
        );
        defer encoder.deinit();
        const registry_id = try client.getRegistry();
        try queueGlobal(&server, &encoder, registry_id, 11, "wl_keyboard", 1);
        try queueGlobal(&server, &encoder, registry_id, 12, "wl_keyboard", 3);
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());
        _ = try nextEvent(&client);
        _ = try nextEvent(&client);

        const old_keyboard = try client.bind(registry_id, 11, &core.wl_keyboard.metadata, 1);
        try std.testing.expectError(
            error.UnsupportedRequestVersion,
            client.request(old_keyboard, core.wl_keyboard.requests.release.opcode, &.{}, &.{}),
        );
        try std.testing.expect(client.object(old_keyboard) != null);

        const current_keyboard = try client.bind(registry_id, 12, &core.wl_keyboard.metadata, 3);
        try client.request(current_keyboard, core.wl_keyboard.requests.release.opcode, &.{}, &.{});
        try std.testing.expect(client.object(current_keyboard) == null);

        encoder.reset();
        try encoder.signed(20);
        try encoder.signed(300);
        const repeat = try encoder.finish(&core.wl_keyboard.events.repeat_info);
        try server.queueOwned(old_keyboard, repeat.opcode(), repeat.payload, repeat.descriptors);
        try std.testing.expectEqual(wayland.stream.FlushStatus.drained, try server.flush());
        try std.testing.expectError(error.UnsupportedEventVersion, client.step());
        try std.testing.expectError(error.UnsupportedEventVersion, client.step());
    }

    test "bootstrap allocation failures preserve descriptor and object ownership" {
        if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            AllocationHarness.run,
            .{},
        );
    }

    test "request encoder capacity rejection rolls back object creation" {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err|
            switch (err) {
                error.UnsupportedPlatform => return error.SkipZigTest,
                else => return err,
            };
        const capacity = try runtime.Capacity.derive(.{ .transport = .{
            .outbound_byte_count = wayland.wire.header_size,
        } });
        var client = runtime.Client.initOwned(std.testing.allocator, sockets[0], capacity) catch |err| {
            sys.fd.close(sockets[1]);
            return err;
        };
        defer client.deinit();
        defer sys.fd.close(sockets[1]);

        try std.testing.expectError(error.PayloadCapacityExceeded, client.getRegistry());
        try std.testing.expect(client.object(wayland.ids.first_dynamic_id) == null);
        try std.testing.expectEqual(
            @as(u64, 1),
            client.storageStatus().request_encoder.payload_capacity_rejection_count,
        );
    }

    test "outbound transport rejection preserves prior request and rolls back the next" {
        const sockets = sys.fd.socketPairUnixStream(.{ .close_on_exec = true }) catch |err|
            switch (err) {
                error.UnsupportedPlatform => return error.SkipZigTest,
                else => return err,
            };
        const capacity = try runtime.Capacity.derive(.{ .transport = .{
            .outbound_byte_count = wayland.wire.header_size + 4,
        } });
        var client = runtime.Client.initOwned(std.testing.allocator, sockets[0], capacity) catch |err| {
            sys.fd.close(sockets[1]);
            return err;
        };
        defer client.deinit();
        defer sys.fd.close(sockets[1]);

        const callback_id = try client.sync();
        try std.testing.expectError(error.OutboundByteCapacityExceeded, client.getRegistry());
        try std.testing.expect(client.object(callback_id) != null);
        try std.testing.expect(client.object(callback_id + 1) == null);
        try std.testing.expectEqual(
            @as(u64, 1),
            client.storageStatus().transport.outbound_byte_capacity_rejection_count,
        );
    }

    test "incoming allocation failures preserve frames descriptors and object transactions" {
        if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            IncomingAllocationHarness.run,
            .{},
        );
    }

    test "incoming events allocate only during client initialization" {
        if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = 15,
        });
        try IncomingAllocationHarness.run(failing.allocator());
        try std.testing.expectEqual(@as(usize, 15), failing.allocations);
    }
};

test "Wayland runtime namespace is complete" {
    std.testing.refAllDecls(runtime);
}

test {
    std.testing.refAllDecls(experience);
}
