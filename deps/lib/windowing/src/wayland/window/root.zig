const std = @import("std");
const sys = @import("sys");
const windowing = @import("../../root.zig");
const native = @import("wayland");
const wayland = @import("../root.zig");

const present = wayland.present;
const present_dmabuf = present.dmabuf;
const seat = wayland.seat;
const session = wayland.session;
const toplevel = wayland.toplevel;
const runtime = native.runtime;

pub const WaylandBackend = struct {
    allocator: std.mem.Allocator,
    session: session.Session = .{},
    toplevel: toplevel.Toplevel = .{},
    seat: seat.Seat = .{},
    presenter: present.Presenter = .{},
    /// Present when the compositor offers dma-buf feedback and explicit synchronization.
    dmabuf: ?present.dmabuf.Dmabuf = null,
    gamepads: windowing.gamepad.State,
    events: windowing.event.Queue,

    pub fn init(self: *WaylandBackend, allocator: std.mem.Allocator, config: windowing.WindowConfig) windowing.CreateError!void {
        if (config.width == 0 or config.height == 0 or config.width > std.math.maxInt(i32) or config.height > std.math.maxInt(i32)) {
            return error.WindowCreationFailed;
        }
        const clipboard_capacity = windowing.clipboard.Capacity.derive(config.clipboard) catch
            return error.InvalidCapacity;
        const event_capacity = windowing.event.Capacity.derive(config.events) catch
            return error.InvalidCapacity;
        const input_capacity = windowing.input.Capacity.derive(config.input) catch
            return error.InvalidCapacity;
        const gamepad_capacity = windowing.gamepad.Capacity.derive(config.gamepads) catch
            return error.InvalidCapacity;
        _ = windowing.WaylandComposeCapacity.derive(config.wayland_compose) catch
            return error.InvalidCapacity;
        _ = windowing.WaylandComposeScratchCapacity.derive(
            config.wayland_compose_scratch,
        ) catch return error.InvalidCapacity;
        const session_capacity = session.Capacity.derive(
            config.wayland_output_count,
        ) catch return error.InvalidCapacity;
        const runtime_capacity = runtime.Capacity.derive(
            config.wayland_runtime,
        ) catch return error.InvalidCapacity;
        const presentation_capacity = wayland.presentation.Capacity.derive(
            config.presentation,
        ) catch return error.InvalidCapacity;
        var presenter = present.Presenter.init(
            allocator,
            presentation_capacity.frames,
        ) catch return error.OutOfMemory;
        var presenter_owned = true;
        errdefer if (presenter_owned) presenter.deinit();
        var gamepads = windowing.gamepad.State.init(allocator, gamepad_capacity) catch
            return error.OutOfMemory;
        const events = windowing.event.Queue.init(allocator, event_capacity) catch {
            gamepads.deinit();
            return error.OutOfMemory;
        };
        self.* = .{
            .allocator = allocator,
            .presenter = presenter,
            .gamepads = gamepads,
            .events = events,
        };
        presenter_owned = false;
        errdefer self.deinit();

        self.session.open(allocator, session_capacity, runtime_capacity) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.ConnectionFailed => error.ConnectionFailed,
            else => error.UnsupportedPlatform,
        };
        if (!self.session.hasRequiredGlobals()) return error.WindowCreationFailed;

        self.seat.open(
            allocator,
            &self.session.client,
            &self.session.globals,
            input_capacity,
            clipboard_capacity,
            config.wayland_compose,
            config.wayland_compose_scratch,
            .{
                .context = self,
                .event = seatEvent,
                .focus_changed = seatFocusChanged,
                .synchronize = synchronizeSeat,
            },
        ) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.SequenceSymbolCapacityExceeded,
            error.TextByteCapacityExceeded,
            error.LineByteCapacityExceeded,
            error.PathByteCapacityExceeded,
            => error.InvalidCapacity,
            else => error.UnsupportedPlatform,
        };

        self.presenter.open(
            &self.session.client,
            self.session.takePresentation(),
            presentation_capacity,
            .{ .context = self, .flush = flushSession },
        ) catch return error.OutOfMemory;

        self.toplevel.open(&self.session.client, &self.session.globals, config, .{
            .context = self,
            .output_entered = outputEntered,
            .extent_changed = extentChanged,
            .focus_changed = toplevelFocusChanged,
            .close_requested = closeRequested,
        }) catch return error.WindowCreationFailed;
        const target = self.toplevel.target() orelse return error.WindowCreationFailed;
        self.presenter.updateTarget(target);
        self.seat.setSurface(target.surface);
        if (self.session.globals.linux_dmabuf) |dmabuf_id| if (self.session.globals.syncobj_manager) |manager_id| {
            self.dmabuf = present.dmabuf.Dmabuf.open(allocator, &self.session.client, dmabuf_id, manager_id, target.surface) catch |failure| switch (failure) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
        };

        self.session.activate(.{
            .context = self,
            .seat_capabilities = seatCapabilities,
            .seat_removed = seatRemoved,
            .output_scale_changed = outputScaleChanged,
            .callback_done = callbackDone,
            .routed = routed,
        });
        self.session.roundtrip() catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ConnectionFailed,
        };
        self.presenter.configure(
            self.session.globals.shm.?,
            if (self.session.has_xbgr8888) .xbgr8888 else .xrgb8888,
        );
        self.session.roundtrip() catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ConnectionFailed,
        };
        if (self.session.callback_failed or self.seat.callback_failed or self.toplevel.callback_failed) {
            return error.ConnectionFailed;
        }
        if (!self.toplevel.configured or !self.toplevel.server_decorated) return error.WindowCreationFailed;
    }

    pub fn deinit(self: *WaylandBackend) void {
        self.gamepads.deinit();
        if (self.dmabuf) |*explicit| explicit.deinit();
        self.presenter.deinit();
        self.seat.deinit();
        self.toplevel.deinit();
        self.session.deinit();
        self.events.deinit();
        self.* = undefined;
    }

    pub fn pollEvents(self: *WaylandBackend) windowing.PollError!windowing.EventIterator {
        self.seat.input.beginPoll();
        self.gamepads.poll();
        self.events.beginPoll();
        self.session.poll() catch return error.ConnectionLost;
        if (self.toplevel.callback_failed) return error.ConnectionLost;
        self.seat.poll() catch return error.ConnectionLost;
        self.presenter.poll() catch return error.PresentationFailed;
        return self.events.iterator();
    }

    pub fn eventSource(self: *const WaylandBackend) ?windowing.EventSource {
        const descriptor = self.session.descriptor() orelse return null;
        return .{
            .descriptor = descriptor,
            .writable = self.session.flush_pending,
        };
    }

    pub fn shouldClose(self: *const WaylandBackend) bool {
        return self.toplevel.should_close;
    }

    pub fn getSize(self: *const WaylandBackend) windowing.Size {
        return self.toplevel.size();
    }

    pub fn getFramebufferSize(self: *const WaylandBackend) windowing.Size {
        return self.toplevel.framebufferSize();
    }

    pub fn nativeSurface(self: *WaylandBackend) windowing.Surface {
        const descriptor = self.session.descriptor() orelse unreachable;
        const target = self.toplevel.target() orelse unreachable;
        const factor = target.scale_state.factor();
        return .{ .wayland = .{
            .descriptor = descriptor,
            .surface_id = target.surface,
            .extent = windowing.surface.extentFromSizes(
                target.logical.width,
                target.logical.height,
                target.framebuffer.width,
                target.framebuffer.height,
                factor,
                factor,
            ),
        } };
    }

    pub fn presentRgba8(
        self: *WaylandBackend,
        rgba8: []const u8,
        width: u32,
        height: u32,
    ) windowing.PresentError!void {
        const target = self.toplevel.target() orelse return error.Unexpected;
        return self.presenter.present(target, rgba8, width, height, windowing.PresentRegion.full(width, height));
    }

    pub fn presentRgba8Region(
        self: *WaylandBackend,
        rgba8: []const u8,
        width: u32,
        height: u32,
        region: windowing.PresentRegion,
    ) windowing.PresentError!void {
        const target = self.toplevel.target() orelse return error.Unexpected;
        return self.presenter.present(target, rgba8, width, height, region);
    }

    pub fn presentRgba8Frame(
        self: *WaylandBackend,
        rgba8: []const u8,
        width: u32,
        height: u32,
        regions: []const windowing.PresentRegion,
    ) windowing.PresentError!u64 {
        const target = self.toplevel.target() orelse return error.Unexpected;
        return self.presenter.presentFrame(target, rgba8, width, height, regions);
    }

    pub fn getContentScale(self: *const WaylandBackend) windowing.Scale {
        return self.toplevel.contentScale();
    }

    pub fn inputState(self: *const WaylandBackend) *const windowing.input.State {
        return self.seat.inputState();
    }

    pub fn inputStateMut(self: *WaylandBackend) *windowing.input.State {
        return self.seat.inputStateMut();
    }

    pub fn modifiers(self: *const WaylandBackend) windowing.Modifier {
        return self.seat.modifiers();
    }

    pub fn gamepadState(self: *const WaylandBackend) *const windowing.gamepad.State {
        return &self.gamepads;
    }

    pub fn setTitle(self: *WaylandBackend, title: [:0]const u8) void {
        self.toplevel.setTitle(title);
    }

    pub fn setMinSize(self: *WaylandBackend, width: u32, height: u32) void {
        self.toplevel.setMinSize(width, height);
    }

    pub fn setCursor(self: *WaylandBackend, shape: windowing.CursorShape) void {
        self.seat.setCursor(shape);
    }

    pub fn isCursorOnScreen(self: *const WaylandBackend) bool {
        return self.seat.cursor_on_screen;
    }

    pub fn minimize(self: *WaylandBackend) void {
        self.toplevel.minimize();
    }

    pub fn maximize(self: *WaylandBackend) void {
        self.toplevel.maximize();
    }

    pub fn restore(self: *WaylandBackend) void {
        self.toplevel.restore();
    }

    pub fn isMaximized(self: *const WaylandBackend) bool {
        return self.toplevel.maximized;
    }

    pub fn getClipboardTextAlloc(self: *WaylandBackend, allocator: std.mem.Allocator) !?[]u8 {
        return self.seat.getClipboardTextAlloc(allocator);
    }

    pub fn setClipboardText(
        self: *WaylandBackend,
        text: []const u8,
    ) windowing.clipboard.PublishError!void {
        try self.seat.setClipboardText(text);
    }

    pub fn clipboardStatus(self: *const WaylandBackend) windowing.clipboard.Status {
        return self.seat.clipboardStatus();
    }

    pub fn x11StorageStatus(_: *const WaylandBackend) sys.x11.Status {
        return .{};
    }

    pub fn waylandStorageStatus(self: *const WaylandBackend) windowing.WaylandRuntimeStorageStatus {
        return self.session.storageStatus();
    }

    pub fn nextPresentationOutcome(self: *WaylandBackend) ?windowing.presentation.Outcome {
        return self.presenter.nextPresentationOutcome();
    }

    pub fn presentationStatus(self: *const WaylandBackend) windowing.presentation.Status {
        return self.presenter.presentationStatus();
    }

    pub fn presentationStorageStatus(
        self: *const WaylandBackend,
    ) windowing.presentation.StorageStatus {
        var status = self.presenter.presentationStorageStatus();
        status.wayland_output_capacity_rejection_count = self.session.outputCapacityRejectionCount();
        return status;
    }

    /// The window's dma-buf presentation, when the compositor offers it.
    pub fn waylandDmabuf(self: *WaylandBackend) ?DmabufSurface {
        if (self.dmabuf == null) return null;
        return .{ .backend = self };
    }

    pub fn droppedEventCount(self: *const WaylandBackend) u64 {
        return self.events.droppedEventCount();
    }

    fn push(self: *WaylandBackend, event: windowing.Event) void {
        _ = self.events.push(event);
    }

    fn seatEvent(context: *anyopaque, event: windowing.Event) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(context));
        self.push(event);
    }

    fn seatFocusChanged(context: *anyopaque, focused: bool) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(context));
        self.toplevel.setFocused(focused);
    }

    fn synchronizeSeat(context: *anyopaque, timeout_ms: u32) anyerror!void {
        const self: *WaylandBackend = @ptrCast(@alignCast(context));
        try self.session.synchronize(timeout_ms);
    }

    fn seatCapabilities(context: *anyopaque, capabilities: u32) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(context));
        self.seat.setGlobals(&self.session.globals) catch {
            self.seat.callback_failed = true;
            return;
        };
        self.seat.capabilities(capabilities);
    }

    fn seatRemoved(context: *anyopaque) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(context));
        self.seat.seatRemoved();
    }

    fn outputScaleChanged(context: *anyopaque, integer_scale: u32) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(context));
        self.toplevel.setIntegerScale(integer_scale);
    }

    fn outputEntered(context: *anyopaque, object_id: u32, entered: bool) u32 {
        const self: *WaylandBackend = @ptrCast(@alignCast(context));
        return self.session.setOutputEntered(object_id, entered);
    }

    fn extentChanged(context: *anyopaque, target: toplevel.Target, notify_resize: bool) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(context));
        self.presenter.updateTarget(target);
        if (notify_resize) self.push(.{ .window_resize = .{
            .width = target.logical.width,
            .height = target.logical.height,
        } });
    }

    fn toplevelFocusChanged(context: *anyopaque, focused: bool) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(context));
        self.push(.{ .window_focus = .{ .focused = focused } });
    }

    fn closeRequested(context: *anyopaque) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(context));
        self.push(.window_close);
    }

    fn flushSession(context: *anyopaque) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(context));
        self.session.flush();
    }

    fn callbackDone(context: *anyopaque, callback_id: u32, data: u32) anyerror!void {
        const self: *WaylandBackend = @ptrCast(@alignCast(context));
        if (try self.presenter.dispatchCallback(callback_id, data)) return;
        return error.UnhandledCallback;
    }

    fn routed(context: *anyopaque, event: *@import("wayland").runtime.RoutedView) anyerror!void {
        const self: *WaylandBackend = @ptrCast(@alignCast(context));
        if (try self.toplevel.dispatch(event)) return;
        if (try self.seat.dispatch(event)) return;
        if (self.dmabuf) |*explicit| if (try explicit.dispatch(event)) return;
        if (try self.presenter.dispatch(event)) return;
        return error.UnhandledEvent;
    }
};

/// Presents buffers another device rendered on a Wayland window, as dma-bufs with explicit
/// synchronization. `Window.waylandDmabuf` hands one out when the compositor offers both
/// protocols. It stays valid as long as the window.
pub const DmabufSurface = struct {
    backend: *WaylandBackend,

    fn explicit(self: DmabufSurface) *present_dmabuf.Dmabuf {
        return &self.backend.dmabuf.?;
    }

    /// The `zwp_linux_dmabuf_v1` version the window bound.
    pub fn version(self: DmabufSurface) u32 {
        return self.explicit().version();
    }

    /// The compositor's latest complete feedback for the window's surface.
    pub fn feedback(self: DmabufSurface) ?*const present_dmabuf.Feedback {
        return self.explicit().currentFeedback();
    }

    pub fn importBuffer(self: DmabufSurface, desc: present_dmabuf.BufferDesc) present_dmabuf.Error!present_dmabuf.Buffer {
        return self.explicit().importBuffer(desc);
    }

    pub fn releaseBuffer(self: DmabufSurface, buffer: present_dmabuf.Buffer) void {
        self.explicit().releaseBuffer(buffer);
    }

    pub fn importTimeline(self: DmabufSurface, fd: sys.fd.Descriptor) present_dmabuf.Error!present_dmabuf.Timeline {
        return self.explicit().importTimeline(fd);
    }

    pub fn destroyTimeline(self: DmabufSurface, timeline: present_dmabuf.Timeline) void {
        self.explicit().destroyTimeline(timeline);
    }

    /// Whether the compositor has asked for the next frame.
    pub fn frameReady(self: DmabufSurface) bool {
        return self.backend.presenter.frameReady();
    }

    /// Commits `frame`. See `Presenter.presentDmabuf`.
    pub fn present(self: DmabufSurface, frame: present_dmabuf.Frame) present_dmabuf.PresentError!?u64 {
        const target = self.backend.toplevel.target() orelse return error.Unexpected;
        return self.backend.presenter.presentDmabuf(target, self.explicit(), frame);
    }
};
