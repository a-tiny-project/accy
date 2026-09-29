const std = @import("std");
const sys = @import("sys");
const native = @import("wayland");
const windowing = @import("../../root.zig");

const core = native.protocol.core;
const runtime = native.runtime;

pub const receive_timeout_ms: u32 = 1000;

pub const Error = error{
    OutOfMemory,
    CreateFailed,
    SynchronizeFailed,
    TransferFailed,
    TransferTimedOut,
    TransferTooLarge,
};

pub const Synchronizer = struct {
    context: ?*anyopaque,
    run: *const fn (context: ?*anyopaque) anyerror!void,

    fn synchronize(self: Synchronizer) Error!void {
        self.run(self.context) catch return error.SynchronizeFailed;
    }
};

pub const Clipboard = struct {
    allocator: std.mem.Allocator,
    client: *runtime.Client,
    received_text_byte_count: usize,
    transfer_read: []u8,
    source: windowing.clipboard.Source,
    manager: ?u32 = null,
    device: ?u32 = null,
    source_id: ?u32 = null,
    offers: OfferSet = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        client: *runtime.Client,
        capacity: windowing.clipboard.Capacity,
    ) std.mem.Allocator.Error!Clipboard {
        std.debug.assert(capacity.received_text_byte_count > 0);
        std.debug.assert(capacity.transfer_read_byte_count > 0);
        const transfer_read = try allocator.alloc(u8, capacity.transfer_read_byte_count);
        errdefer allocator.free(transfer_read);
        const source = try windowing.clipboard.Source.init(allocator, capacity);
        return .{
            .allocator = allocator,
            .client = client,
            .received_text_byte_count = capacity.received_text_byte_count,
            .transfer_read = transfer_read,
            .source = source,
        };
    }

    pub fn bindSeat(self: *Clipboard, manager: u32, seat: u32) !void {
        self.resetDevice();
        self.manager = manager;
        var created: [1]u32 = undefined;
        try self.client.request(
            manager,
            core.wl_data_device_manager.requests.get_data_device.opcode,
            &.{ .{ .new_id = .fixed }, .{ .object = seat } },
            &created,
        );
        self.device = created[0];
    }

    pub fn unbindSeat(self: *Clipboard) void {
        self.resetDevice();
    }

    pub fn dispatch(self: *Clipboard, event: *runtime.RoutedView) !bool {
        if (event.object_id == self.source_id) {
            try self.dispatchSource(event, true);
            return true;
        }
        if (event.object_id == self.device) {
            try self.dispatchDevice(event, true);
            return true;
        }
        if (self.offers.find(event.object_id)) |offer| {
            try self.dispatchOffer(offer, event);
            return true;
        }
        if (std.mem.eql(u8, event.interface.name, core.wl_data_device.metadata.name)) {
            try self.dispatchDevice(event, false);
            return true;
        }
        if (std.mem.eql(u8, event.interface.name, core.wl_data_source.metadata.name)) {
            try self.dispatchSource(event, false);
            return true;
        }
        return false;
    }

    pub fn setText(
        self: *Clipboard,
        text: []const u8,
        serial: u32,
    ) windowing.clipboard.PublishError!void {
        try self.source.replace(text);
        self.destroySource(false);
        const manager = self.manager orelse return error.Unavailable;
        const device = self.device orelse return error.Unavailable;
        var created: [1]u32 = undefined;
        self.client.request(
            manager,
            core.wl_data_device_manager.requests.create_data_source.opcode,
            &.{.{ .new_id = .fixed }},
            &created,
        ) catch return error.Unexpected;
        const source_id = created[0];
        for (text_mime_preference) |mime| {
            self.client.request(
                source_id,
                core.wl_data_source.requests.offer.opcode,
                &.{.{ .string = mime }},
                &.{},
            ) catch {
                self.destroyDetachedSource(source_id);
                return error.Unexpected;
            };
        }
        self.client.request(
            device,
            core.wl_data_device.requests.set_selection.opcode,
            &.{ .{ .object = source_id }, .{ .uint = serial } },
            &.{},
        ) catch {
            self.destroyDetachedSource(source_id);
            return error.Unexpected;
        };
        self.source_id = source_id;
    }

    pub fn getTextAlloc(
        self: *Clipboard,
        output_allocator: std.mem.Allocator,
        synchronizer: Synchronizer,
    ) Error!?[]u8 {
        const selection = self.offers.selection orelse return null;
        const mime = selection.mimes.preferred() orelse return null;

        const descriptors = transferPipe() catch return error.TransferFailed;
        defer sys.fd.close(descriptors[0]);
        var write_owned = true;
        defer if (write_owned) sys.fd.close(descriptors[1]);

        self.client.request(
            selection.id,
            core.wl_data_offer.requests.receive.opcode,
            &.{ .{ .string = mime }, .{ .descriptor_owned = descriptors[1] } },
            &.{},
        ) catch return error.TransferFailed;
        write_owned = false;
        try synchronizer.synchronize();

        return try readBoundedAlloc(
            output_allocator,
            descriptors[0],
            receive_timeout_ms,
            self.received_text_byte_count,
            self.transfer_read,
        );
    }

    pub fn deinit(self: *Clipboard) void {
        self.resetDevice();
        self.source.deinit();
        self.allocator.free(self.transfer_read);
        self.* = undefined;
    }

    fn resetDevice(self: *Clipboard) void {
        self.destroySource(true);
        if (self.offers.takePending()) |offer| self.destroyDetachedOffer(offer, true);
        if (self.offers.takeSelection()) |offer| self.destroyDetachedOffer(offer, true);
        const device = self.device orelse return;
        if (self.client.object(device)) |object| {
            if (object.version >= core.wl_data_device.requests.release.since) {
                self.client.request(
                    device,
                    core.wl_data_device.requests.release.opcode,
                    &.{},
                    &.{},
                ) catch {};
            }
        }
        self.device = null;
        self.manager = null;
    }

    fn destroySource(self: *Clipboard, clear: bool) void {
        if (self.source_id) |source_id| self.destroyDetachedSource(source_id);
        self.source_id = null;
        if (clear) self.source.clear();
    }

    fn destroyDetachedSource(self: *Clipboard, source_id: u32) void {
        self.client.request(
            source_id,
            core.wl_data_source.requests.destroy.opcode,
            &.{},
            &.{},
        ) catch {};
    }

    fn introduceOffer(self: *Clipboard, id: u32) void {
        if (self.offers.introduce(id)) |displaced| self.destroyDetachedOffer(displaced, true);
    }

    fn replaceSelection(self: *Clipboard, id: ?u32) void {
        const transition = self.offers.replaceSelection(id);
        if (transition.displaced) |offer| self.destroyDetachedOffer(offer, true);
        if (transition.orphaned) |offer| self.destroyDetachedOffer(offer, true);
    }

    fn discardDragOffer(self: *Clipboard, id: ?u32) void {
        if (self.offers.discardDrag(id)) |offer| self.destroyDetachedOffer(offer, true);
    }

    fn destroyDetachedOffer(self: *Clipboard, offer: Offer, send_destroy: bool) void {
        if (send_destroy) {
            self.client.request(
                offer.id,
                core.wl_data_offer.requests.destroy.opcode,
                &.{},
                &.{},
            ) catch {};
        }
    }

    fn dispatchDevice(self: *Clipboard, event: *runtime.RoutedView, active: bool) !void {
        var decoder = try event.borrowedDecoder();
        switch (event.metadata.opcode) {
            core.wl_data_device.events.data_offer.opcode => {
                const offer_id = (try decoder.newId()).raw;
                try decoder.finish();
                if (active) {
                    self.introduceOffer(offer_id);
                } else {
                    self.client.request(
                        offer_id,
                        core.wl_data_offer.requests.destroy.opcode,
                        &.{},
                        &.{},
                    ) catch {};
                }
            },
            core.wl_data_device.events.enter.opcode => {
                _ = try decoder.unsigned();
                _ = try decoder.object();
                _ = try decoder.fixed();
                _ = try decoder.fixed();
                const offer_id = if (try decoder.optionalObject()) |value| value.raw else null;
                try decoder.finish();
                if (active) self.discardDragOffer(offer_id);
            },
            core.wl_data_device.events.leave.opcode,
            core.wl_data_device.events.drop.opcode,
            => try decoder.finish(),
            core.wl_data_device.events.motion.opcode => {
                _ = try decoder.unsigned();
                _ = try decoder.fixed();
                _ = try decoder.fixed();
                try decoder.finish();
            },
            core.wl_data_device.events.selection.opcode => {
                const offer_id = if (try decoder.optionalObject()) |value| value.raw else null;
                try decoder.finish();
                if (active) self.replaceSelection(offer_id);
            },
            else => return error.InvalidDataDeviceEvent,
        }
    }

    fn dispatchOffer(_: *Clipboard, offer: *Offer, event: *runtime.RoutedView) !void {
        var decoder = try event.borrowedDecoder();
        switch (event.metadata.opcode) {
            core.wl_data_offer.events.offer.opcode => {
                const mime = try decoder.string();
                try decoder.finish();
                offer.mimes.add(mime);
            },
            core.wl_data_offer.events.source_actions.opcode,
            core.wl_data_offer.events.action.opcode,
            => {
                _ = try decoder.unsigned();
                try decoder.finish();
            },
            else => return error.InvalidDataOfferEvent,
        }
    }

    fn dispatchSource(self: *Clipboard, event: *runtime.RoutedView, active: bool) !void {
        var decoder = try event.borrowedDecoder();
        switch (event.metadata.opcode) {
            core.wl_data_source.events.target.opcode => {
                _ = try decoder.optionalString();
                try decoder.finish();
            },
            core.wl_data_source.events.send.opcode => {
                const mime = try decoder.string();
                _ = try decoder.descriptor();
                try decoder.finish();
                const descriptor = try event.takeDescriptor(0);
                defer sys.fd.close(descriptor);
                if (active and isTextMime(mime)) writeSource(descriptor, self.source.text());
            },
            core.wl_data_source.events.cancelled.opcode => {
                try decoder.finish();
                if (active) self.destroySource(true);
            },
            core.wl_data_source.events.dnd_drop_performed.opcode,
            core.wl_data_source.events.dnd_finished.opcode,
            => try decoder.finish(),
            core.wl_data_source.events.action.opcode => {
                _ = try decoder.unsigned();
                try decoder.finish();
            },
            else => return error.InvalidDataSourceEvent,
        }
    }

    pub fn status(self: *const Clipboard) windowing.clipboard.Status {
        return self.source.status();
    }
};

const Offer = struct {
    id: u32,
    mimes: MimeTypes = .{},
};

const SelectionTransition = struct {
    displaced: ?Offer = null,
    orphaned: ?Offer = null,
};

const MimeTypes = struct {
    present: [text_mime_preference.len]bool = @splat(false),

    fn add(self: *MimeTypes, mime: []const u8) void {
        for (text_mime_preference, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, mime)) self.present[index] = true;
        }
    }

    fn preferred(self: *const MimeTypes) ?[:0]const u8 {
        for (text_mime_preference, self.present) |candidate, present| {
            if (present) return candidate;
        }
        return null;
    }
};

const OfferSet = struct {
    pending: ?Offer = null,
    selection: ?Offer = null,

    fn find(self: *OfferSet, id: u32) ?*Offer {
        if (self.pending) |*offer| if (offer.id == id) return offer;
        if (self.selection) |*offer| if (offer.id == id) return offer;
        return null;
    }

    fn introduce(self: *OfferSet, id: u32) ?Offer {
        const pending = self.pending;
        self.pending = .{ .id = id };
        return pending;
    }

    fn replaceSelection(self: *OfferSet, id: ?u32) SelectionTransition {
        if (id) |value| {
            if (self.selection) |offer| {
                if (offer.id == value) return .{};
            }
            if (self.pending) |offer| {
                if (offer.id == value) {
                    const displaced = self.selection;
                    self.selection = offer;
                    self.pending = null;
                    return .{ .displaced = displaced };
                }
            }
        }
        const displaced = self.selection;
        const orphaned = self.pending;
        self.selection = null;
        self.pending = null;
        return .{ .displaced = displaced, .orphaned = orphaned };
    }

    fn discardDrag(self: *OfferSet, id: ?u32) ?Offer {
        const value = id orelse return null;
        if (self.selection) |offer| {
            if (offer.id == value) return null;
        }
        const pending = self.pending orelse return null;
        if (pending.id != value) return null;
        self.pending = null;
        return pending;
    }

    fn takePending(self: *OfferSet) ?Offer {
        const offer = self.pending;
        self.pending = null;
        return offer;
    }

    fn takeSelection(self: *OfferSet) ?Offer {
        const offer = self.selection;
        self.selection = null;
        return offer;
    }
};

const text_mime_preference = [_][:0]const u8{
    "text/plain;charset=utf-8",
    "UTF8_STRING",
    "text/plain",
};

fn isTextMime(mime: []const u8) bool {
    for (text_mime_preference) |candidate| {
        if (std.mem.eql(u8, candidate, mime)) return true;
    }
    return false;
}

fn writeSource(descriptor: sys.fd.Descriptor, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = sys.fd.write(descriptor, bytes[offset..]) catch return;
        if (written == 0) return;
        offset += written;
    }
}

fn readBoundedAlloc(
    allocator: std.mem.Allocator,
    descriptor: sys.fd.Descriptor,
    timeout_ms: u32,
    max_bytes: usize,
    scratch: []u8,
) Error![]u8 {
    std.debug.assert(max_bytes > 0);
    std.debug.assert(scratch.len > 0);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    const now = sys.time.nanoTimestamp();
    const timeout_ns = @as(i128, timeout_ms) * std.time.ns_per_ms;
    const deadline = now + timeout_ns;

    while (true) {
        const remaining = deadline - sys.time.nanoTimestamp();
        if (remaining <= 0) return error.TransferTimedOut;
        const rounded_ms = @divFloor(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        const poll_timeout: i32 = @intCast(@min(rounded_ms, std.math.maxInt(i32)));
        var poll_fds = [_]sys.poll.Descriptor{.{
            .fd = descriptor,
            .events = sys.poll.Event.input,
            .revents = 0,
        }};
        const ready = sys.poll.wait(&poll_fds, poll_timeout) catch return error.TransferFailed;
        if (ready == 0) return error.TransferTimedOut;
        if ((poll_fds[0].revents & sys.poll.Event.invalid) != 0) return error.TransferFailed;

        while (true) {
            const read_count = sys.fd.read(descriptor, scratch) catch |failure| switch (failure) {
                error.WouldBlock => break,
                else => return error.TransferFailed,
            };
            if (read_count == 0) return try bytes.toOwnedSlice(allocator);
            if (read_count > max_bytes -| bytes.items.len) return error.TransferTooLarge;
            try bytes.appendSlice(allocator, scratch[0..read_count]);
        }
    }
}

fn transferPipe() ![2]sys.fd.Descriptor {
    const descriptors = try sys.fd.pipeWithOptions(.{ .close_on_exec = true });
    errdefer sys.fd.close(descriptors[0]);
    errdefer sys.fd.close(descriptors[1]);
    try sys.fd.setNonBlocking(descriptors[0]);
    return descriptors;
}

test "clipboard MIME preference is deterministic" {
    var mimes: MimeTypes = .{};
    mimes.add("text/plain");
    mimes.add("application/octet-stream");
    mimes.add("UTF8_STRING");
    mimes.add("text/plain;charset=utf-8");
    mimes.add("text/plain");
    try std.testing.expectEqual([3]bool{ true, true, true }, mimes.present);
    try std.testing.expectEqualStrings("text/plain;charset=utf-8", mimes.preferred().?);
}

test "clipboard offers follow pending selection and discarded drag roles" {
    var offers: OfferSet = .{};
    try std.testing.expect(offers.introduce(10) == null);
    offers.find(10).?.mimes.add("text/plain");
    const first = offers.replaceSelection(10);
    try std.testing.expect(first.displaced == null);
    try std.testing.expect(first.orphaned == null);
    try std.testing.expect(offers.pending == null);
    try std.testing.expectEqual(@as(u32, 10), offers.selection.?.id);

    try std.testing.expect(offers.introduce(20) == null);
    const second = offers.replaceSelection(20);
    try std.testing.expectEqual(@as(u32, 10), second.displaced.?.id);
    try std.testing.expect(second.orphaned == null);
    try std.testing.expectEqual(@as(u32, 20), offers.selection.?.id);

    try std.testing.expect(offers.introduce(30) == null);
    try std.testing.expectEqual(@as(u32, 30), offers.discardDrag(30).?.id);
    try std.testing.expect(offers.pending == null);
    try std.testing.expectEqual(@as(u32, 20), offers.selection.?.id);

    try std.testing.expect(offers.introduce(40) == null);
    try std.testing.expectEqual(@as(u32, 40), offers.introduce(50).?.id);
    const cleared = offers.replaceSelection(null);
    try std.testing.expectEqual(@as(u32, 20), cleared.displaced.?.id);
    try std.testing.expectEqual(@as(u32, 50), cleared.orphaned.?.id);
    try std.testing.expect(offers.pending == null);
    try std.testing.expect(offers.selection == null);
}

test "clipboard initialization owns exact read and publication storage" {
    const capacity = try windowing.clipboard.Capacity.derive(.{
        .received_text_byte_count = 7,
        .published_text_byte_count = 5,
        .transfer_read_byte_count = 3,
        .retained_wait_event_count = 2,
    });
    const client: *runtime.Client = undefined;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        Clipboard.init(failing.allocator(), client, capacity),
    );

    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(
        error.OutOfMemory,
        Clipboard.init(failing.allocator(), client, capacity),
    );

    failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var clipboard = try Clipboard.init(failing.allocator(), client, capacity);
    defer clipboard.deinit();
    try std.testing.expectEqual(@as(usize, 3), clipboard.transfer_read.len);
    try std.testing.expectEqual(@as(usize, 7), clipboard.received_text_byte_count);
    try std.testing.expectEqual(@as(usize, 5), clipboard.source.bytes.len);
    try std.testing.expectEqual(@as(usize, 2), failing.allocations);
}

test "clipboard data source send transfers its descriptor and exact retained bytes" {
    const capacity = try windowing.clipboard.Capacity.derive(.{
        .received_text_byte_count = 7,
        .published_text_byte_count = 16,
        .transfer_read_byte_count = 3,
        .retained_wait_event_count = 2,
    });
    const client: *runtime.Client = undefined;
    var clipboard = try Clipboard.init(std.testing.allocator, client, capacity);
    defer clipboard.deinit();
    try clipboard.source.replace("exact λ");
    clipboard.source_id = 77;

    const descriptors = try transferPipe();
    defer sys.fd.close(descriptors[0]);
    var encoder = try native.protocol.value.Encoder.init(
        std.testing.allocator,
        native.protocol.value.default_encoder_capacity,
    );
    defer encoder.deinit();
    try encoder.string(text_mime_preference[0]);
    try encoder.descriptorBorrowed(descriptors[1]);
    const encoded = try encoder.finish(&core.wl_data_source.events.send);
    var routed_descriptors = [_]sys.fd.Descriptor{descriptors[1]};
    var event: runtime.RoutedView = .{
        .object_id = 77,
        .interface = &core.wl_data_source.metadata,
        .version = 3,
        .metadata = encoded.metadata,
        .payload = encoded.payload,
        .descriptors = &routed_descriptors,
    };
    try std.testing.expect(try clipboard.dispatch(&event));
    clipboard.source_id = null;
    try std.testing.expectEqual(@as(sys.fd.Descriptor, -1), routed_descriptors[0]);

    var received: [16]u8 = undefined;
    const received_count = try sys.fd.read(descriptors[0], &received);
    try std.testing.expectEqualStrings("exact λ", received[0..received_count]);
}

test "clipboard data source cancellation clears retained bytes" {
    const capacity = try windowing.clipboard.Capacity.derive(.{
        .received_text_byte_count = 7,
        .published_text_byte_count = 16,
        .transfer_read_byte_count = 3,
        .retained_wait_event_count = 2,
    });
    const client: *runtime.Client = undefined;
    var clipboard = try Clipboard.init(std.testing.allocator, client, capacity);
    defer clipboard.deinit();
    try clipboard.source.replace("retained");

    var no_descriptors: [0]sys.fd.Descriptor = .{};
    var event: runtime.RoutedView = .{
        .object_id = 78,
        .interface = &core.wl_data_source.metadata,
        .version = 3,
        .metadata = &core.wl_data_source.events.cancelled,
        .payload = &.{},
        .descriptors = &no_descriptors,
    };
    try clipboard.dispatchSource(&event, true);
    try std.testing.expectEqualStrings("", clipboard.source.text());
}

test "clipboard transfer reader enforces its byte bound" {
    const descriptors = try transferPipe();
    defer sys.fd.close(descriptors[0]);
    var write_open = true;
    defer if (write_open) sys.fd.close(descriptors[1]);
    try writeAll(descriptors[1], "large");
    sys.fd.close(descriptors[1]);
    write_open = false;
    var scratch: [2]u8 = undefined;
    try std.testing.expectError(
        error.TransferTooLarge,
        readBoundedAlloc(std.testing.allocator, descriptors[0], 100, 4, &scratch),
    );
}

test "clipboard transfer reader reuses nondefault scratch across reads" {
    const descriptors = try transferPipe();
    defer sys.fd.close(descriptors[0]);
    var write_open = true;
    defer if (write_open) sys.fd.close(descriptors[1]);
    try writeAll(descriptors[1], "hello");
    sys.fd.close(descriptors[1]);
    write_open = false;
    var scratch: [2]u8 = undefined;
    const text = try readBoundedAlloc(std.testing.allocator, descriptors[0], 100, 5, &scratch);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "clipboard transfer reader times out while a source stays silent" {
    const descriptors = try transferPipe();
    defer sys.fd.close(descriptors[0]);
    defer sys.fd.close(descriptors[1]);
    var scratch: [3]u8 = undefined;
    try std.testing.expectError(
        error.TransferTimedOut,
        readBoundedAlloc(std.testing.allocator, descriptors[0], 5, 8, &scratch),
    );
}

fn writeAll(descriptor: sys.fd.Descriptor, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) offset += try sys.fd.write(descriptor, bytes[offset..]);
}
