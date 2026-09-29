const std = @import("std");
const native = @import("wayland");
const windowing = @import("../../root.zig");
const wayland = @import("../root.zig");

const core = native.protocol.core;
const desktop = native.protocol.desktop;
const runtime = native.runtime;
const session = wayland.session;
const support = @import("support.zig");

pub const scale = @import("scale.zig");

const maximized_state: u32 = 1;
const focused_state: u32 = 4;
const server_side_decoration: u32 = 2;

pub const Callbacks = struct {
    context: *anyopaque,
    output_entered: *const fn (context: *anyopaque, object_id: u32, entered: bool) u32,
    extent_changed: *const fn (context: *anyopaque, target: Target, notify_resize: bool) void,
    focus_changed: *const fn (context: *anyopaque, focused: bool) void,
    close_requested: *const fn (context: *anyopaque) void,
};

pub const Target = struct {
    surface: u32,
    viewport: ?u32,
    logical: windowing.Size,
    framebuffer: windowing.Size,
    scale_state: scale.State,
    generation: u64,
    visible: bool,
};

const PendingConfigure = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    maximized: bool = false,
    focused: bool = false,
};

pub const Toplevel = struct {
    client: ?*runtime.Client = null,
    callbacks: ?Callbacks = null,
    surface: ?u32 = null,
    xdg_surface: ?u32 = null,
    toplevel: ?u32 = null,
    viewport: ?u32 = null,
    fractional_scale: ?u32 = null,
    decoration: ?u32 = null,
    width: u32 = 0,
    height: u32 = 0,
    scale_state: scale.State = .{},
    pending_configure: PendingConfigure = .{},
    configured: bool = false,
    server_decorated: bool = false,
    maximized: bool = false,
    focused: bool = false,
    should_close: bool = false,
    callback_failed: bool = false,
    generation: u64 = 0,
    visible: bool = true,

    pub fn open(
        self: *Toplevel,
        client: *runtime.Client,
        globals: *const session.Globals,
        config: windowing.WindowConfig,
        callbacks: Callbacks,
    ) !void {
        self.* = .{
            .client = client,
            .callbacks = callbacks,
            .width = config.width,
            .height = config.height,
            .visible = config.visible,
        };
        errdefer self.deinit();

        const compositor = globals.compositor orelse return error.CompositorUnavailable;
        const wm_base = globals.xdg_wm_base orelse return error.ShellUnavailable;

        var created: [1]u32 = undefined;
        try client.request(
            compositor,
            core.wl_compositor.requests.create_surface.opcode,
            &.{.{ .new_id = .fixed }},
            &created,
        );
        self.surface = created[0];

        try client.request(
            wm_base,
            desktop.xdg_wm_base.requests.get_xdg_surface.opcode,
            &.{ .{ .new_id = .fixed }, .{ .object = self.surface.? } },
            &created,
        );
        self.xdg_surface = created[0];

        try client.request(
            self.xdg_surface.?,
            desktop.xdg_surface.requests.get_toplevel.opcode,
            &.{.{ .new_id = .fixed }},
            &created,
        );
        self.toplevel = created[0];

        if (globals.viewporter != null and globals.fractional_scale_manager != null) {
            try self.createFractionalScaleObjects(globals);
        }
        try self.createDecoration(globals);

        try client.request(
            self.toplevel.?,
            desktop.xdg_toplevel.requests.set_title.opcode,
            &.{.{ .string = config.title }},
            &.{},
        );
        try client.request(
            self.toplevel.?,
            desktop.xdg_toplevel.requests.set_app_id.opcode,
            &.{.{ .string = config.app_id }},
            &.{},
        );
        if (!config.resizable) {
            try self.requestMinSize(config.width, config.height);
            try client.request(
                self.toplevel.?,
                desktop.xdg_toplevel.requests.set_max_size.opcode,
                &.{ .{ .int = clampedI32(config.width) }, .{ .int = clampedI32(config.height) } },
                &.{},
            );
        }
        try client.request(
            self.surface.?,
            core.wl_surface.requests.commit.opcode,
            &.{},
            &.{},
        );
    }

    pub fn deinit(self: *Toplevel) void {
        const client = self.client orelse {
            self.* = .{};
            return;
        };
        destroyRequest(client, &self.decoration, desktop.zxdg_toplevel_decoration_v1.requests.destroy.opcode);
        destroyRequest(client, &self.fractional_scale, desktop.wp_fractional_scale_v1.requests.destroy.opcode);
        destroyRequest(client, &self.viewport, desktop.wp_viewport.requests.destroy.opcode);
        destroyRequest(client, &self.toplevel, desktop.xdg_toplevel.requests.destroy.opcode);
        destroyRequest(client, &self.xdg_surface, desktop.xdg_surface.requests.destroy.opcode);
        destroyRequest(client, &self.surface, core.wl_surface.requests.destroy.opcode);
        self.* = .{};
    }

    pub fn dispatch(self: *Toplevel, event: *runtime.RoutedView) !bool {
        if (event.object_id == self.xdg_surface) {
            try self.dispatchXdgSurface(event);
            return true;
        }
        if (event.object_id == self.toplevel) {
            try self.dispatchToplevel(event);
            return true;
        }
        if (event.object_id == self.surface) {
            try self.dispatchSurface(event);
            return true;
        }
        if (event.object_id == self.fractional_scale) {
            try self.dispatchFractionalScale(event);
            return true;
        }
        if (event.object_id == self.decoration) {
            try self.dispatchDecoration(event);
            return true;
        }
        return false;
    }

    pub fn target(self: *const Toplevel) ?Target {
        const surface_id = self.surface orelse return null;
        return .{
            .surface = surface_id,
            .viewport = self.viewport,
            .logical = self.size(),
            .framebuffer = self.framebufferSize(),
            .scale_state = self.scale_state,
            .generation = self.generation,
            .visible = self.visible,
        };
    }

    pub fn size(self: *const Toplevel) windowing.Size {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn framebufferSize(self: *const Toplevel) windowing.Size {
        return .{
            .width = self.scale_state.framebufferDimension(self.width) catch std.math.maxInt(u32),
            .height = self.scale_state.framebufferDimension(self.height) catch std.math.maxInt(u32),
        };
    }

    pub fn contentScale(self: *const Toplevel) windowing.Scale {
        const factor = self.scale_state.factor();
        return .{ .x = factor, .y = factor };
    }

    pub fn setTitle(self: *Toplevel, title: [:0]const u8) void {
        self.request(
            self.toplevel,
            desktop.xdg_toplevel.requests.set_title.opcode,
            &.{.{ .string = title }},
        );
    }

    pub fn setMinSize(self: *Toplevel, width: u32, height: u32) void {
        self.requestMinSize(width, height) catch {
            self.callback_failed = true;
        };
    }

    pub fn minimize(self: *Toplevel) void {
        self.request(self.toplevel, desktop.xdg_toplevel.requests.set_minimized.opcode, &.{});
    }

    pub fn maximize(self: *Toplevel) void {
        self.request(self.toplevel, desktop.xdg_toplevel.requests.set_maximized.opcode, &.{});
    }

    pub fn restore(self: *Toplevel) void {
        self.request(self.toplevel, desktop.xdg_toplevel.requests.unset_maximized.opcode, &.{});
    }

    pub fn setFocused(self: *Toplevel, focused: bool) void {
        if (self.focused == focused) return;
        self.focused = focused;
        if (self.callbacks) |callbacks| callbacks.focus_changed(callbacks.context, focused);
    }

    pub fn setIntegerScale(self: *Toplevel, value: u32) void {
        if (self.fractional_scale != null) return;
        if (self.scale_state.setInteger(value)) self.scaleChanged();
    }

    fn createFractionalScaleObjects(self: *Toplevel, globals: *const session.Globals) !void {
        const client = self.client.?;
        var created: [1]u32 = undefined;
        try client.request(
            globals.fractional_scale_manager.?,
            desktop.wp_fractional_scale_manager_v1.requests.get_fractional_scale.opcode,
            &.{ .{ .new_id = .fixed }, .{ .object = self.surface.? } },
            &created,
        );
        self.fractional_scale = created[0];
        try client.request(
            globals.viewporter.?,
            desktop.wp_viewporter.requests.get_viewport.opcode,
            &.{ .{ .new_id = .fixed }, .{ .object = self.surface.? } },
            &created,
        );
        self.viewport = created[0];
    }

    fn createDecoration(self: *Toplevel, globals: *const session.Globals) !void {
        const client = self.client.?;
        const manager = globals.decoration_manager orelse return error.DecorationUnavailable;
        var created: [1]u32 = undefined;
        try client.request(
            manager,
            desktop.zxdg_decoration_manager_v1.requests.get_toplevel_decoration.opcode,
            &.{ .{ .new_id = .fixed }, .{ .object = self.toplevel.? } },
            &created,
        );
        self.decoration = created[0];
        try client.request(
            self.decoration.?,
            desktop.zxdg_toplevel_decoration_v1.requests.set_mode.opcode,
            &.{.{ .uint = server_side_decoration }},
            &.{},
        );
    }

    fn requestMinSize(self: *Toplevel, width: u32, height: u32) !void {
        const client = self.client orelse return error.ConnectionLost;
        const toplevel_id = self.toplevel orelse return error.ConnectionLost;
        try client.request(
            toplevel_id,
            desktop.xdg_toplevel.requests.set_min_size.opcode,
            &.{ .{ .int = clampedI32(width) }, .{ .int = clampedI32(height) } },
            &.{},
        );
    }

    fn request(self: *Toplevel, object_id: ?u32, opcode: u16, values: []const runtime.Value) void {
        const client = self.client orelse return;
        const id = object_id orelse return;
        client.request(id, opcode, values, &.{}) catch {
            self.callback_failed = true;
        };
    }

    fn configure(self: *Toplevel, serial: u32) !void {
        const client = self.client orelse return error.ConnectionLost;
        const xdg_surface_id = self.xdg_surface orelse return error.ConnectionLost;
        try client.request(
            xdg_surface_id,
            desktop.xdg_surface.requests.ack_configure.opcode,
            &.{.{ .uint = serial }},
            &.{},
        );

        const old_width = self.width;
        const old_height = self.height;
        if (self.pending_configure.width) |value| self.width = value;
        if (self.pending_configure.height) |value| self.height = value;
        self.maximized = self.pending_configure.maximized;
        self.setFocused(self.pending_configure.focused);
        self.pending_configure.width = null;
        self.pending_configure.height = null;
        self.configured = true;
        if (old_width != self.width or old_height != self.height) self.extentChanged(true);
    }

    fn pendingConfigure(self: *Toplevel, raw_width: i32, raw_height: i32, states: []const u8) void {
        self.pending_configure.width = if (raw_width > 0) @intCast(raw_width) else null;
        self.pending_configure.height = if (raw_height > 0) @intCast(raw_height) else null;
        self.pending_configure.maximized = stateArrayContains(states, maximized_state);
        self.pending_configure.focused = stateArrayContains(states, focused_state);
    }

    fn close(self: *Toplevel) void {
        if (self.should_close) return;
        self.should_close = true;
        if (self.callbacks) |callbacks| callbacks.close_requested(callbacks.context);
    }

    fn surfaceOutput(self: *Toplevel, object_id: u32, entered: bool) void {
        const callbacks = self.callbacks orelse return;
        const integer_scale = callbacks.output_entered(callbacks.context, object_id, entered);
        self.setIntegerScale(integer_scale);
    }

    fn preferredBufferScale(self: *Toplevel, raw: i32) void {
        self.setIntegerScale(if (raw > 0) @intCast(raw) else 1);
    }

    fn fractionalScaleChanged(self: *Toplevel, numerator: u32) void {
        if (self.scale_state.setFractional(numerator)) self.scaleChanged();
    }

    fn decorationConfigured(self: *Toplevel, mode: u32) void {
        self.server_decorated = mode == server_side_decoration;
        if (self.configured and !self.server_decorated) self.callback_failed = true;
    }

    fn scaleChanged(self: *Toplevel) void {
        self.extentChanged(self.configured);
    }

    fn extentChanged(self: *Toplevel, notify_resize: bool) void {
        self.generation +%= 1;
        const target_value = self.target() orelse return;
        if (self.callbacks) |callbacks| callbacks.extent_changed(callbacks.context, target_value, notify_resize);
    }

    fn dispatchXdgSurface(self: *Toplevel, event: *runtime.RoutedView) !void {
        if (event.metadata.opcode != desktop.xdg_surface.events.configure.opcode) return error.InvalidEvent;
        var decoder = try event.borrowedDecoder();
        const serial = try decoder.unsigned();
        try decoder.finish();
        try self.configure(serial);
    }

    fn dispatchToplevel(self: *Toplevel, event: *runtime.RoutedView) !void {
        switch (event.metadata.opcode) {
            desktop.xdg_toplevel.events.configure.opcode => {
                var decoder = try event.borrowedDecoder();
                const width = try decoder.signed();
                const height = try decoder.signed();
                const states = try decoder.array();
                try decoder.finish();
                self.pendingConfigure(width, height, states);
            },
            desktop.xdg_toplevel.events.close.opcode => self.close(),
            desktop.xdg_toplevel.events.configure_bounds.opcode,
            desktop.xdg_toplevel.events.wm_capabilities.opcode,
            => {},
            else => return error.InvalidEvent,
        }
    }

    fn dispatchSurface(self: *Toplevel, event: *runtime.RoutedView) !void {
        switch (event.metadata.opcode) {
            core.wl_surface.events.enter.opcode, core.wl_surface.events.leave.opcode => {
                var decoder = try event.borrowedDecoder();
                const output_id = (try decoder.object()).raw;
                try decoder.finish();
                self.surfaceOutput(output_id, event.metadata.opcode == core.wl_surface.events.enter.opcode);
            },
            core.wl_surface.events.preferred_buffer_scale.opcode => {
                var decoder = try event.borrowedDecoder();
                const factor = try decoder.signed();
                try decoder.finish();
                self.preferredBufferScale(factor);
            },
            core.wl_surface.events.preferred_buffer_transform.opcode => {},
            else => return error.InvalidEvent,
        }
    }

    fn dispatchFractionalScale(self: *Toplevel, event: *runtime.RoutedView) !void {
        if (event.metadata.opcode != desktop.wp_fractional_scale_v1.events.preferred_scale.opcode) {
            return error.InvalidEvent;
        }
        var decoder = try event.borrowedDecoder();
        const numerator = try decoder.unsigned();
        try decoder.finish();
        self.fractionalScaleChanged(numerator);
    }

    fn dispatchDecoration(self: *Toplevel, event: *runtime.RoutedView) !void {
        if (event.metadata.opcode != desktop.zxdg_toplevel_decoration_v1.events.configure.opcode) {
            return error.InvalidEvent;
        }
        var decoder = try event.borrowedDecoder();
        const mode = try decoder.unsigned();
        try decoder.finish();
        self.decorationConfigured(mode);
    }
};

fn destroyRequest(client: *runtime.Client, slot: *?u32, opcode: u16) void {
    const id = slot.* orelse return;
    client.request(id, opcode, &.{}, &.{}) catch {};
    slot.* = null;
}

const stateArrayContains = support.stateArrayContains;
const clampedI32 = support.clampedI32;

test "xdg decoration mode distinguishes server ownership" {
    var target = Toplevel{};
    target.decorationConfigured(1);
    try std.testing.expect(!target.server_decorated);
    try std.testing.expect(!target.callback_failed);

    target.decorationConfigured(2);
    try std.testing.expect(target.server_decorated);
    try std.testing.expect(!target.callback_failed);

    target.configured = true;
    target.decorationConfigured(1);
    try std.testing.expect(!target.server_decorated);
    try std.testing.expect(target.callback_failed);
}
