const std = @import("std");
const sys = @import("sys");
const clipboard = @import("clipboard.zig");
const EventIterator = @import("event.zig").EventIterator;
const WindowConfig = @import("config.zig").WindowConfig;
const Backend = @import("backend.zig").Backend;
const input = @import("input.zig");
const Key = @import("key.zig").Key;
const MouseButton = @import("mouse.zig").MouseButton;
const Modifier = @import("modifier.zig").Modifier;
const CursorShape = @import("cursor.zig").CursorShape;
const gamepads = @import("gamepad.zig");
const presentation = @import("presentation.zig");
const surface = @import("surface.zig");
const WaylandStorageStatus = @import("wayland").runtime.StorageStatus;
const WaylandDmabuf = @import("wayland/root.zig").DmabufSurface;

pub const Size = struct {
    width: u32,
    height: u32,
};

pub const Scale = struct {
    x: f32,
    y: f32,
};

pub const EventSource = struct {
    descriptor: sys.fd.Descriptor,
    readable: bool = true,
    writable: bool = false,
};

pub const max_present_regions: usize = 16;

pub const PresentRegion = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn full(width: u32, height: u32) PresentRegion {
        return .{ .width = width, .height = height };
    }

    pub fn pixelCount(self: PresentRegion) usize {
        return @as(usize, self.width) * @as(usize, self.height);
    }

    pub fn clamped(self: PresentRegion, width: u32, height: u32) PresentRegion {
        if (self.x >= width or self.y >= height) return .{ .x = self.x, .y = self.y };
        return .{
            .x = self.x,
            .y = self.y,
            .width = @min(self.width, width - self.x),
            .height = @min(self.height, height - self.y),
        };
    }
};

pub const CreateError = error{
    ConnectionFailed,
    InvalidCapacity,
    WindowCreationFailed,
    UnsupportedPlatform,
    OutOfMemory,
};

pub const PollError = error{
    ConnectionLost,
    PresentationFailed,
};

pub const PresentError = error{
    SubmissionIdsExhausted,
    TooManyRegions,
    UnsupportedPlatform,
    UnsupportedFormat,
    CapacityExceeded,
    Unexpected,
    OutOfMemory,
    /// The Wayland surface presents dma-bufs with explicit synchronization, and every commit of
    /// it must carry sync points that a shared-memory frame lacks.
    ExplicitSyncSurface,
};

pub const Window = struct {
    allocator: std.mem.Allocator,
    backend: *Backend,

    pub fn create(allocator: std.mem.Allocator, config: WindowConfig) CreateError!Window {
        const backend = allocator.create(Backend) catch return error.OutOfMemory;
        errdefer allocator.destroy(backend);
        try backend.init(allocator, config);
        return .{ .allocator = allocator, .backend = backend };
    }

    pub fn destroy(self: *Window) void {
        self.backend.deinit();
        self.allocator.destroy(self.backend);
        self.* = undefined;
    }

    pub fn pollEvents(self: *Window) PollError!EventIterator {
        return self.backend.pollEvents();
    }

    pub fn droppedEventCount(self: *const Window) u64 {
        return self.backend.droppedEventCount();
    }

    pub fn eventSource(self: *const Window) ?EventSource {
        return self.backend.eventSource();
    }

    pub fn shouldClose(self: *const Window) bool {
        return self.backend.shouldClose();
    }

    pub fn getSize(self: *const Window) Size {
        return self.backend.getSize();
    }

    pub fn getFramebufferSize(self: *const Window) Size {
        return self.backend.getFramebufferSize();
    }

    pub fn getDrawArea(self: *const Window) sys.desktop.DrawArea {
        return sizeToDrawArea(self.getSize());
    }

    pub fn getFramebufferArea(self: *const Window) sys.desktop.DrawArea {
        return sizeToDrawArea(self.getFramebufferSize());
    }

    pub fn getNativeSurface(self: *Window) surface.Surface {
        return self.backend.nativeSurface();
    }

    pub fn getScaleEvidence(self: *const Window) sys.desktop.WindowScaleEvidence {
        return scaleEvidenceFromSizes(self.getSize(), self.getFramebufferSize(), self.getContentScale());
    }

    pub fn presentRgba8(
        self: *Window,
        rgba8: []const u8,
        width: u32,
        height: u32,
    ) PresentError!void {
        return self.backend.presentRgba8(rgba8, width, height);
    }

    pub fn presentRgba8Region(
        self: *Window,
        rgba8: []const u8,
        width: u32,
        height: u32,
        region: PresentRegion,
    ) PresentError!void {
        return self.backend.presentRgba8Region(rgba8, width, height, region);
    }

    /// Presents a complete, tightly packed RGBA8 frame with non-zero dimensions and up to sixteen update
    /// regions (`max_present_regions`). The caller retains ownership of the source buffer because the
    /// backend copies all needed bytes into internal storage before returning. Supplying no regions, or
    /// supplying regions that all clip outside window bounds, falls back to updating the full frame:
    /// the all-clipped fallback increments `empty_region_fallback_count` in presentation storage status
    /// when regions were passed. Overlapping rectangles copy subsequent source pixels over earlier ones
    /// without alpha blending. The call returns a monotonically increasing, non-zero per-window submission
    /// identifier shared across legacy RGBA presents and Wayland dma-buf commits: exhausting the range
    /// fails with `error.SubmissionIdsExhausted`.
    ///
    /// On the initial present or after a resize, the backend initializes complete storage
    /// for the full frame extent. Each backend publishes all active regions in a single presentation
    /// operation, with two platform-specific storage paths: Cocoa copies the complete source buffer into
    /// its inactive slot before issuing a single layer update, while X11 falls back to direct window
    /// uploads of the complete source that increment `x11_direct_frame_count` whenever pixmap allocation fails with
    /// `BadAlloc` or pixmap acquisition remains pending.
    pub fn presentRgba8Frame(
        self: *Window,
        rgba8: []const u8,
        width: u32,
        height: u32,
        regions: []const PresentRegion,
    ) PresentError!u64 {
        return self.backend.presentRgba8Frame(rgba8, width, height, regions);
    }

    pub fn getContentScale(self: *const Window) Scale {
        return self.backend.getContentScale();
    }

    pub fn isKeyDown(self: *const Window, key: Key) bool {
        return self.backend.inputState().isKeyDown(key);
    }

    pub fn isKeyPressed(self: *const Window, key: Key) bool {
        return self.backend.inputState().isKeyPressed(key);
    }

    pub fn isKeyReleased(self: *const Window, key: Key) bool {
        return self.backend.inputState().isKeyReleased(key);
    }

    pub fn nextPressedKey(self: *Window) ?Key {
        return self.backend.inputStateMut().nextPressedKey();
    }

    pub fn modifiers(self: *const Window) Modifier {
        return self.backend.modifiers();
    }

    pub fn isMouseButtonDown(self: *const Window, button: MouseButton) bool {
        return self.backend.inputState().isMouseButtonDown(button);
    }

    pub fn isMouseButtonPressed(self: *const Window, button: MouseButton) bool {
        return self.backend.inputState().isMouseButtonPressed(button);
    }

    pub fn isMouseButtonReleased(self: *const Window, button: MouseButton) bool {
        return self.backend.inputState().isMouseButtonReleased(button);
    }

    pub fn getMousePosition(self: *const Window) input.Point {
        return self.backend.inputState().mouse_position;
    }

    pub fn getMouseDelta(self: *const Window) input.Point {
        return self.backend.inputState().mouse_delta;
    }

    pub fn getMouseWheel(self: *const Window) input.Wheel {
        return self.backend.inputState().mouse_wheel;
    }

    pub fn nextTextCodepoint(self: *Window) ?u21 {
        return self.backend.inputStateMut().nextTextCodepoint();
    }

    pub fn inputStatus(self: *const Window) input.Status {
        return self.backend.inputState().status();
    }

    pub fn setCursor(self: *Window, shape: CursorShape) void {
        self.backend.setCursor(shape);
    }

    pub fn isCursorOnScreen(self: *const Window) bool {
        return self.backend.isCursorOnScreen();
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        self.backend.setTitle(title);
    }

    pub fn setMinSize(self: *Window, width: u32, height: u32) void {
        self.backend.setMinSize(width, height);
    }

    pub fn minimize(self: *Window) void {
        self.backend.minimize();
    }

    pub fn maximize(self: *Window) void {
        self.backend.maximize();
    }

    pub fn restore(self: *Window) void {
        self.backend.restore();
    }

    pub fn isMaximized(self: *Window) bool {
        return self.backend.isMaximized();
    }

    pub fn toggleMaximize(self: *Window) void {
        if (self.isMaximized()) {
            self.restore();
        } else {
            self.maximize();
        }
    }

    pub fn getClipboardTextAlloc(self: *Window, allocator: std.mem.Allocator) !?[]u8 {
        return self.backend.getClipboardTextAlloc(allocator);
    }

    pub fn setClipboardText(self: *Window, text: []const u8) clipboard.PublishError!void {
        return self.backend.setClipboardText(text);
    }

    pub fn clipboardStatus(self: *const Window) clipboard.Status {
        return self.backend.clipboardStatus();
    }

    pub fn x11StorageStatus(self: *const Window) sys.x11.Status {
        return self.backend.x11StorageStatus();
    }

    /// The window's dma-buf presentation with explicit synchronization, when it is a Wayland
    /// window and the compositor offers `zwp_linux_dmabuf_v1` 4 or later and
    /// `wp_linux_drm_syncobj_manager_v1`. Its first commit makes shared-memory presents of the
    /// window fail with `ExplicitSyncSurface`.
    pub fn waylandDmabuf(self: *Window) ?WaylandDmabuf {
        return self.backend.waylandDmabuf();
    }

    pub fn waylandStorageStatus(self: *const Window) WaylandStorageStatus {
        return self.backend.waylandStorageStatus();
    }

    /// Retrieves the next presentation outcome for an accepted submission from backends that support
    /// presentation timing. Backends generate one outcome per accepted identifier, subject to bounded
    /// unpolled delivery: A host that drains feedback (polls until false) at least once every N accepted
    /// frames receives exactly one outcome for every id; draining once per frame meets this. Here N represents
    /// the pending feedback capacity (`pending_feedback_count`, default 256), while the outcome queue holds
    /// at least 2N entries (`retained_outcome_count`, default 512). When unpolled delivery fills this queue,
    /// the queue drops the oldest outcome and increments `feedback_dropped_outcome_count`. Backends without
    /// timing support return null.
    ///
    /// An `unknown` outcome marks an accepted submission for which the compositor or backend will never
    /// report a physical display result, leaving all timestamp and clock fields set to zero. Callers must
    /// never treat an unknown outcome as evidence of physical display.
    pub fn nextPresentationOutcome(self: *Window) ?presentation.Outcome {
        return self.backend.nextPresentationOutcome();
    }

    pub fn presentationStatus(self: *const Window) presentation.Status {
        return self.backend.presentationStatus();
    }

    pub fn presentationStorageStatus(self: *const Window) presentation.StorageStatus {
        return self.backend.presentationStorageStatus();
    }

    pub fn gamepadCount(self: *const Window) usize {
        return self.backend.gamepadState().connectedCount();
    }

    pub fn gamepad(self: *const Window, index: usize) *const gamepads.Gamepad {
        return self.backend.gamepadState().gamepad(index);
    }

    pub fn gamepadStatus(self: *const Window) gamepads.Status {
        return self.backend.gamepadState().status();
    }
};

pub fn scaleEvidenceFromSizes(size: Size, framebuffer: Size, content_scale: Scale) sys.desktop.WindowScaleEvidence {
    return .{
        .has_window_content_scale = true,
        .window_display = usableScale(@max(content_scale.x, content_scale.y)),
        .display_content = usableScale(@max(content_scale.x, content_scale.y)),
        .pixel_density = sys.desktop.framebufferScaleFromDimensions(
            @floatFromInt(size.width),
            @floatFromInt(size.height),
            @floatFromInt(framebuffer.width),
            @floatFromInt(framebuffer.height),
        ) orelse 1.0,
    };
}

fn sizeToDrawArea(size: Size) sys.desktop.DrawArea {
    return .{
        .width = u32ToI32(size.width),
        .height = u32ToI32(size.height),
    };
}

fn u32ToI32(value: u32) i32 {
    return if (value > @as(u32, @intCast(std.math.maxInt(i32)))) std.math.maxInt(i32) else @intCast(value);
}

fn usableScale(scale: f32) f32 {
    if (!std.math.isFinite(scale) or scale <= 0) return 1.0;
    return scale;
}

test "scale evidence derives pixel density from framebuffer dimensions" {
    const evidence = scaleEvidenceFromSizes(
        .{ .width = 640, .height = 480 },
        .{ .width = 1280, .height = 960 },
        .{ .x = 2, .y = 2 },
    );
    try std.testing.expect(evidence.has_window_content_scale);
    try std.testing.expectEqual(@as(f32, 2), evidence.display_content);
    try std.testing.expectEqual(@as(f32, 2), evidence.pixel_density);
}

test "draw areas clamp to signed GUI dimensions" {
    try std.testing.expectEqual(
        sys.desktop.DrawArea{ .width = 10, .height = std.math.maxInt(i32) },
        sizeToDrawArea(.{ .width = 10, .height = std.math.maxInt(u32) }),
    );
}

test "present region clamps to framebuffer bounds" {
    try std.testing.expectEqual(
        PresentRegion{ .x = 4, .y = 3, .width = 6, .height = 5 },
        (PresentRegion{ .x = 4, .y = 3, .width = 20, .height = 20 }).clamped(10, 8),
    );
    try std.testing.expectEqual(
        PresentRegion{ .x = 12, .y = 3 },
        (PresentRegion{ .x = 12, .y = 3, .width = 2, .height = 2 }).clamped(10, 8),
    );
    try std.testing.expectEqual(@as(usize, 30), (PresentRegion{ .width = 6, .height = 5 }).pixelCount());
}
