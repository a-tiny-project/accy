const std = @import("std");
const sys = @import("sys");
const native = @import("wayland");

const core = native.protocol.core;
const desktop = native.protocol.desktop;
const runtime = native.runtime;

pub const output = @import("output.zig");

const global = @import("global.zig");
const dmabuf = @import("../present/dmabuf.zig");
const storage = @import("storage.zig");

pub const CapacityError = storage.CapacityError;
pub const Capacity = storage.Capacity;
const classify = global.classify;
const OutputStorage = storage.OutputStorage;

pub const Callbacks = struct {
    context: *anyopaque,
    seat_capabilities: *const fn (context: *anyopaque, capabilities: u32) void,
    seat_removed: *const fn (context: *anyopaque) void,
    output_scale_changed: *const fn (context: *anyopaque, scale: u32) void,
    callback_done: *const fn (context: *anyopaque, callback_id: u32, data: u32) anyerror!void,
    routed: *const fn (context: *anyopaque, event: *runtime.RoutedView) anyerror!void,
};

pub const Globals = struct {
    compositor: ?u32 = null,
    shm: ?u32 = null,
    seat: ?u32 = null,
    data_device_manager: ?u32 = null,
    xdg_wm_base: ?u32 = null,
    viewporter: ?u32 = null,
    fractional_scale_manager: ?u32 = null,
    decoration_manager: ?u32 = null,
    cursor_shape_manager: ?u32 = null,
    presentation: ?u32 = null,
    linux_dmabuf: ?u32 = null,
    syncobj_manager: ?u32 = null,
    seat_name: ?u32 = null,
};

pub const Session = struct {
    client: runtime.Client = undefined,
    client_open: bool = false,
    registry_id: ?u32 = null,
    globals: Globals = .{},
    outputs: OutputStorage = .{},
    callbacks: ?Callbacks = null,
    seat_capabilities: u32 = 0,
    has_xbgr8888: bool = false,
    callback_failed: bool = false,
    flush_pending: bool = false,

    pub fn open(
        self: *Session,
        allocator: std.mem.Allocator,
        capacity: Capacity,
        client_capacity: runtime.Capacity,
    ) !void {
        self.* = .{ .outputs = try OutputStorage.init(allocator, capacity) };
        errdefer self.deinit();

        self.client = try runtime.Client.connect(allocator, client_capacity);
        self.client_open = true;
        self.registry_id = try self.client.getRegistry();
        try self.roundtrip();
    }

    pub fn deinit(self: *Session) void {
        self.outputs.deinit();
        if (self.client_open) self.client.deinit();
        self.* = .{};
    }

    pub fn activate(self: *Session, callbacks: Callbacks) void {
        self.callbacks = callbacks;
        callbacks.seat_capabilities(callbacks.context, self.seat_capabilities);
        callbacks.output_scale_changed(callbacks.context, self.enteredScale());
    }

    pub fn roundtrip(self: *Session) !void {
        const callback_id = try self.client.sync();
        try self.flushBlocking(-1);
        while (true) {
            switch (try self.client.step()) {
                .event => |value| {
                    var event = value;
                    switch (event) {
                        .callback_done => |done| {
                            if (done.callback_id == callback_id) return;
                            try self.dispatchCallback(done.callback_id, done.data);
                        },
                        else => try self.dispatchEvent(&event),
                    }
                },
                .pending => {
                    if (!try sys.net.pollReadable(self.client.descriptor(), -1)) {
                        return error.ConnectionFailed;
                    }
                },
                .closed => return error.ConnectionFailed,
            }
        }
    }

    pub fn poll(self: *Session) !void {
        try self.drain();
        self.flush();
        if (try sys.net.pollReadable(self.client.descriptor(), 0)) try self.drain();
        self.flush();
        if (self.callback_failed) return error.ConnectionLost;
    }

    pub fn flush(self: *Session) void {
        const status = self.client.flush() catch {
            self.callback_failed = true;
            return;
        };
        self.flush_pending = status == .pending;
    }

    pub fn synchronize(self: *Session, timeout_ms: u32) !void {
        try self.flushBlocking(@intCast(@min(timeout_ms, std.math.maxInt(i32))));
    }

    pub fn descriptor(self: *const Session) ?sys.fd.Descriptor {
        if (!self.client_open) return null;
        return self.client.descriptor();
    }

    pub fn storageStatus(self: *const Session) runtime.StorageStatus {
        if (!self.client_open) return .{};
        return self.client.storageStatus();
    }

    pub fn takePresentation(self: *Session) ?u32 {
        const id = self.globals.presentation;
        self.globals.presentation = null;
        return id;
    }

    pub fn hasRequiredGlobals(self: *const Session) bool {
        const compositor_id = self.globals.compositor orelse return false;
        const compositor = self.client.object(compositor_id) orelse return false;
        return compositor.version >= 4 and
            self.globals.shm != null and
            self.globals.seat != null and
            self.globals.xdg_wm_base != null and
            self.globals.decoration_manager != null and
            self.globals.cursor_shape_manager != null;
    }

    pub fn setOutputEntered(self: *Session, object_id: u32, entered: bool) u32 {
        for (self.outputs.retainedMut()) |*value| {
            if (value.id != object_id) continue;
            if (value.setEntered(entered)) self.notifyOutputScale();
            break;
        }
        return self.enteredScale();
    }

    pub fn enteredScale(self: *const Session) u32 {
        var maximum: u32 = 1;
        for (self.outputs.retained()) |value| {
            if (value.entered) maximum = @max(maximum, value.integer_scale);
        }
        return maximum;
    }

    pub fn outputCapacityRejectionCount(self: *const Session) u64 {
        return self.outputs.capacity_rejection_count;
    }

    fn drain(self: *Session) !void {
        while (true) {
            switch (try self.client.step()) {
                .event => |value| {
                    var event = value;
                    try self.dispatchEvent(&event);
                },
                .pending => return,
                .closed => return error.ConnectionLost,
            }
        }
    }

    fn dispatchEvent(self: *Session, event: *runtime.EventView) !void {
        switch (event.*) {
            .fatal => return error.ConnectionLost,
            .delete_id => {},
            .callback_done => |done| try self.dispatchCallback(done.callback_id, done.data),
            .global => |item| try self.registryGlobal(item.name, item.interface, item.version),
            .global_remove => |item| self.registryRemove(item.name),
            .routed => |*routed| try self.dispatchRouted(routed),
        }
    }

    fn dispatchCallback(self: *Session, callback_id: u32, data: u32) !void {
        const callbacks = self.callbacks orelse return;
        try callbacks.callback_done(callbacks.context, callback_id, data);
    }

    fn dispatchRouted(self: *Session, event: *runtime.RoutedView) !void {
        const name = event.interface.name;
        if (std.mem.eql(u8, name, "wl_shm")) return self.dispatchShm(event);
        if (std.mem.eql(u8, name, "wl_seat")) return self.dispatchSeat(event);
        if (std.mem.eql(u8, name, "wl_output")) return self.dispatchOutput(event);
        if (std.mem.eql(u8, name, "xdg_wm_base")) return self.dispatchWmBase(event);
        const callbacks = self.callbacks orelse return error.UnhandledEvent;
        try callbacks.routed(callbacks.context, event);
    }

    fn dispatchShm(self: *Session, event: *runtime.RoutedView) !void {
        if (event.metadata.opcode != core.wl_shm.events.format.opcode) return error.InvalidEvent;
        var decoder = try event.borrowedDecoder();
        const format = try decoder.unsigned();
        try decoder.finish();
        if (format == 0x3432_4258) self.has_xbgr8888 = true;
    }

    fn dispatchSeat(self: *Session, event: *runtime.RoutedView) !void {
        if (event.object_id != self.globals.seat) return;
        switch (event.metadata.opcode) {
            core.wl_seat.events.capabilities.opcode => {
                var decoder = try event.borrowedDecoder();
                self.seat_capabilities = try decoder.unsigned();
                try decoder.finish();
                if (self.callbacks) |callbacks| {
                    callbacks.seat_capabilities(callbacks.context, self.seat_capabilities);
                }
            },
            core.wl_seat.events.name.opcode => {},
            else => return error.InvalidEvent,
        }
    }

    fn dispatchOutput(self: *Session, event: *runtime.RoutedView) !void {
        for (self.outputs.retainedMut()) |*value| {
            if (value.id != event.object_id) continue;
            if (try value.dispatch(event)) self.notifyOutputScale();
            return;
        }
    }

    fn dispatchWmBase(self: *Session, event: *runtime.RoutedView) !void {
        if (event.metadata.opcode != desktop.xdg_wm_base.events.ping.opcode) {
            return error.InvalidEvent;
        }
        var decoder = try event.borrowedDecoder();
        const serial = try decoder.unsigned();
        try decoder.finish();
        try self.client.request(
            event.object_id,
            desktop.xdg_wm_base.requests.pong.opcode,
            &.{.{ .uint = serial }},
            &.{},
        );
    }

    fn registryGlobal(self: *Session, name: u32, interface_name: []const u8, version: u32) !void {
        const registry_id = self.registry_id orelse return error.ConnectionFailed;
        switch (classify(interface_name)) {
            .compositor => try self.bindUnique(&self.globals.compositor, registry_id, name, version, &core.wl_compositor.metadata, 6),
            .shm => try self.bindUnique(&self.globals.shm, registry_id, name, version, &core.wl_shm.metadata, 1),
            .seat => {
                if (self.globals.seat != null) return;
                try self.bindUnique(&self.globals.seat, registry_id, name, version, &core.wl_seat.metadata, 9);
                if (self.globals.seat != null) self.globals.seat_name = name;
            },
            .output => try self.bindOutput(registry_id, name, version),
            .data_device_manager => try self.bindUnique(&self.globals.data_device_manager, registry_id, name, version, &core.wl_data_device_manager.metadata, 3),
            .xdg_wm_base => try self.bindUnique(&self.globals.xdg_wm_base, registry_id, name, version, &desktop.xdg_wm_base.metadata, 7),
            .viewporter => try self.bindUnique(&self.globals.viewporter, registry_id, name, version, &desktop.wp_viewporter.metadata, 1),
            .fractional_scale_manager => try self.bindUnique(&self.globals.fractional_scale_manager, registry_id, name, version, &desktop.wp_fractional_scale_manager_v1.metadata, 1),
            .decoration_manager => try self.bindUnique(&self.globals.decoration_manager, registry_id, name, version, &desktop.zxdg_decoration_manager_v1.metadata, 1),
            .cursor_shape_manager => try self.bindUnique(&self.globals.cursor_shape_manager, registry_id, name, version, &desktop.wp_cursor_shape_manager_v1.metadata, 2),
            .presentation => try self.bindUnique(&self.globals.presentation, registry_id, name, version, &desktop.wp_presentation.metadata, 2),
            .linux_dmabuf => if (version >= dmabuf.minimum_dmabuf_version) {
                try self.bindUnique(&self.globals.linux_dmabuf, registry_id, name, version, &desktop.zwp_linux_dmabuf_v1.metadata, dmabuf.maximum_dmabuf_version);
            },
            .syncobj_manager => try self.bindUnique(&self.globals.syncobj_manager, registry_id, name, version, &desktop.wp_linux_drm_syncobj_manager_v1.metadata, 1),
            .unknown => {},
        }
    }

    fn registryRemove(self: *Session, name: u32) void {
        if (self.globals.seat_name == name) {
            if (self.callbacks) |callbacks| callbacks.seat_removed(callbacks.context);
            self.destroyVersioned(&self.globals.seat, core.wl_seat.requests.release.opcode, 5);
            self.globals.seat_name = null;
            self.seat_capabilities = 0;
            return;
        }
        if (self.outputs.removeGlobal(name)) |value| {
            self.destroyVersionedId(value.id, core.wl_output.requests.release.opcode, 3);
            self.notifyOutputScale();
            return;
        }
    }

    fn bindUnique(
        self: *Session,
        slot: *?u32,
        registry_id: u32,
        name: u32,
        advertised_version: u32,
        interface: *const native.protocol.schema.Interface,
        supported_version: u32,
    ) !void {
        if (slot.* != null) return;
        slot.* = try self.client.bind(
            registry_id,
            name,
            interface,
            @min(advertised_version, supported_version),
        );
    }

    fn bindOutput(self: *Session, registry_id: u32, name: u32, advertised_version: u32) !void {
        const index = self.outputs.reserve() orelse return;
        const id = try self.client.bind(
            registry_id,
            name,
            &core.wl_output.metadata,
            @min(advertised_version, 4),
        );
        self.outputs.commit(index, .{
            .global_name = name,
            .id = id,
        });
    }

    fn notifyOutputScale(self: *Session) void {
        if (self.callbacks) |callbacks| {
            callbacks.output_scale_changed(callbacks.context, self.enteredScale());
        }
    }

    fn destroyVersioned(self: *Session, slot: *?u32, opcode: u16, since: u32) void {
        const id = slot.* orelse return;
        self.destroyVersionedId(id, opcode, since);
        slot.* = null;
    }

    fn destroyVersionedId(self: *Session, id: u32, opcode: u16, since: u32) void {
        const object = self.client.object(id) orelse return;
        if (object.version < since) return;
        self.client.request(id, opcode, &.{}, &.{}) catch {
            self.callback_failed = true;
        };
    }

    fn flushBlocking(self: *Session, timeout_ms: i32) !void {
        while (true) {
            const status = try self.client.flush();
            self.flush_pending = status == .pending;
            if (!self.flush_pending) return;
            if (!try sys.net.pollWritable(self.client.descriptor(), timeout_ms)) {
                return error.ConnectionLost;
            }
        }
    }
};
