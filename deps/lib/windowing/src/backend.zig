const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys");
const clipboard = @import("clipboard.zig");
const EventIterator = @import("event.zig").EventIterator;
const CursorShape = @import("cursor.zig").CursorShape;
const gamepad = @import("gamepad.zig");
const input = @import("input.zig");
const Modifier = @import("modifier.zig").Modifier;
const surface = @import("surface.zig");
const presentation = @import("presentation.zig");
const BackendPreference = @import("config.zig").BackendPreference;
const WindowConfig = @import("config.zig").WindowConfig;
const window = @import("window.zig");
const WaylandStorageStatus = @import("wayland").runtime.StorageStatus;

const Allocator = std.mem.Allocator;
const CocoaBackend = @import("cocoa.zig").CocoaBackend;
const UnsupportedBackend = @import("unsupported.zig").UnsupportedBackend;
const WaylandBackend = @import("wayland/root.zig").WaylandBackend;
const WaylandDmabuf = @import("wayland/root.zig").DmabufSurface;
const X11Backend = @import("x11.zig").X11Backend;

pub const Backend = switch (builtin.os.tag) {
    .linux => LinuxBackend,
    .macos => CocoaBackend,
    else => UnsupportedBackend,
};

const SelectionOrder = struct {
    first: BackendPreference,
    fallback: ?BackendPreference,
};

pub const LinuxBackend = union(enum) {
    wayland: WaylandBackend,
    x11: X11Backend,

    pub fn init(self: *LinuxBackend, allocator: Allocator, config: WindowConfig) window.CreateError!void {
        const order = selectionOrder(config.backend, waylandAdvertised());
        self.initPreferred(allocator, config, order.first) catch |err| {
            const fallback = order.fallback orelse return err;
            if (!shouldFallback(err)) return err;
            return self.initPreferred(allocator, config, fallback);
        };
    }

    fn initPreferred(self: *LinuxBackend, allocator: Allocator, config: WindowConfig, preference: BackendPreference) window.CreateError!void {
        switch (preference) {
            .auto => unreachable,
            .wayland => {
                self.* = .{ .wayland = undefined };
                try self.wayland.init(allocator, config);
            },
            .x11 => {
                self.* = .{ .x11 = undefined };
                try self.x11.init(allocator, config);
            },
        }
    }

    pub fn deinit(self: *LinuxBackend) void {
        switch (self.*) {
            .wayland => |*backend| backend.deinit(),
            .x11 => |*backend| backend.deinit(),
        }
    }

    pub fn pollEvents(self: *LinuxBackend) window.PollError!EventIterator {
        return switch (self.*) {
            .wayland => |*backend| backend.pollEvents(),
            .x11 => |*backend| backend.pollEvents(),
        };
    }

    pub fn droppedEventCount(self: *const LinuxBackend) u64 {
        return switch (self.*) {
            .wayland => |*backend| backend.droppedEventCount(),
            .x11 => |*backend| backend.droppedEventCount(),
        };
    }

    pub fn eventSource(self: *const LinuxBackend) ?window.EventSource {
        return switch (self.*) {
            .wayland => |*backend| backend.eventSource(),
            .x11 => |*backend| backend.eventSource(),
        };
    }

    pub fn shouldClose(self: *const LinuxBackend) bool {
        return switch (self.*) {
            .wayland => |*backend| backend.shouldClose(),
            .x11 => |*backend| backend.shouldClose(),
        };
    }

    pub fn getSize(self: *const LinuxBackend) window.Size {
        return switch (self.*) {
            .wayland => |*backend| backend.getSize(),
            .x11 => |*backend| backend.getSize(),
        };
    }

    pub fn getFramebufferSize(self: *const LinuxBackend) window.Size {
        return switch (self.*) {
            .wayland => |*backend| backend.getFramebufferSize(),
            .x11 => |*backend| backend.getFramebufferSize(),
        };
    }

    pub fn nativeSurface(self: *LinuxBackend) surface.Surface {
        return switch (self.*) {
            .wayland => |*backend| backend.nativeSurface(),
            .x11 => |*backend| backend.nativeSurface(),
        };
    }

    pub fn presentRgba8(
        self: *LinuxBackend,
        rgba8: []const u8,
        width: u32,
        height: u32,
    ) window.PresentError!void {
        return switch (self.*) {
            .wayland => |*backend| backend.presentRgba8(rgba8, width, height),
            .x11 => |*backend| backend.presentRgba8(rgba8, width, height),
        };
    }

    pub fn presentRgba8Region(
        self: *LinuxBackend,
        rgba8: []const u8,
        width: u32,
        height: u32,
        region: window.PresentRegion,
    ) window.PresentError!void {
        return switch (self.*) {
            .wayland => |*backend| backend.presentRgba8Region(rgba8, width, height, region),
            .x11 => |*backend| backend.presentRgba8Region(rgba8, width, height, region),
        };
    }

    pub fn presentRgba8Frame(
        self: *LinuxBackend,
        rgba8: []const u8,
        width: u32,
        height: u32,
        regions: []const window.PresentRegion,
    ) window.PresentError!u64 {
        return switch (self.*) {
            inline else => |*backend| backend.presentRgba8Frame(rgba8, width, height, regions),
        };
    }

    pub fn getContentScale(self: *const LinuxBackend) window.Scale {
        return switch (self.*) {
            .wayland => |*backend| backend.getContentScale(),
            .x11 => |*backend| backend.getContentScale(),
        };
    }

    pub fn inputState(self: *const LinuxBackend) *const input.State {
        return switch (self.*) {
            .wayland => |*backend| backend.inputState(),
            .x11 => |*backend| backend.inputState(),
        };
    }

    pub fn inputStateMut(self: *LinuxBackend) *input.State {
        return switch (self.*) {
            .wayland => |*backend| backend.inputStateMut(),
            .x11 => |*backend| backend.inputStateMut(),
        };
    }

    pub fn modifiers(self: *const LinuxBackend) Modifier {
        return switch (self.*) {
            .wayland => |*backend| backend.modifiers(),
            .x11 => |*backend| backend.inputState().modifiers(),
        };
    }

    pub fn gamepadState(self: *const LinuxBackend) *const gamepad.State {
        return switch (self.*) {
            .wayland => |*backend| backend.gamepadState(),
            .x11 => |*backend| backend.gamepadState(),
        };
    }

    pub fn setCursor(self: *LinuxBackend, shape: CursorShape) void {
        switch (self.*) {
            .wayland => |*backend| backend.setCursor(shape),
            .x11 => |*backend| backend.setCursor(shape),
        }
    }

    pub fn isCursorOnScreen(self: *const LinuxBackend) bool {
        return switch (self.*) {
            .wayland => |*backend| backend.isCursorOnScreen(),
            .x11 => |*backend| backend.isCursorOnScreen(),
        };
    }

    pub fn setTitle(self: *LinuxBackend, title: [:0]const u8) void {
        switch (self.*) {
            .wayland => |*backend| backend.setTitle(title),
            .x11 => |*backend| backend.setTitle(title),
        }
    }

    pub fn setMinSize(self: *LinuxBackend, width: u32, height: u32) void {
        switch (self.*) {
            .wayland => |*backend| backend.setMinSize(width, height),
            .x11 => |*backend| backend.setMinSize(width, height),
        }
    }

    pub fn minimize(self: *LinuxBackend) void {
        switch (self.*) {
            .wayland => |*backend| backend.minimize(),
            .x11 => |*backend| backend.minimize(),
        }
    }

    pub fn maximize(self: *LinuxBackend) void {
        switch (self.*) {
            .wayland => |*backend| backend.maximize(),
            .x11 => |*backend| backend.maximize(),
        }
    }

    pub fn restore(self: *LinuxBackend) void {
        switch (self.*) {
            .wayland => |*backend| backend.restore(),
            .x11 => |*backend| backend.restore(),
        }
    }

    pub fn isMaximized(self: *LinuxBackend) bool {
        return switch (self.*) {
            .wayland => |*backend| backend.isMaximized(),
            .x11 => |*backend| backend.isMaximized(),
        };
    }

    pub fn getClipboardTextAlloc(self: *LinuxBackend, allocator: Allocator) !?[]u8 {
        return switch (self.*) {
            .wayland => |*backend| backend.getClipboardTextAlloc(allocator),
            .x11 => |*backend| backend.getClipboardTextAlloc(allocator),
        };
    }

    pub fn setClipboardText(self: *LinuxBackend, text: []const u8) clipboard.PublishError!void {
        return switch (self.*) {
            .wayland => |*backend| backend.setClipboardText(text),
            .x11 => |*backend| backend.setClipboardText(text),
        };
    }

    pub fn clipboardStatus(self: *const LinuxBackend) clipboard.Status {
        return switch (self.*) {
            .wayland => |*backend| backend.clipboardStatus(),
            .x11 => |*backend| backend.clipboardStatus(),
        };
    }

    pub fn x11StorageStatus(self: *const LinuxBackend) sys.x11.Status {
        return switch (self.*) {
            .wayland => |*backend| backend.x11StorageStatus(),
            .x11 => |*backend| backend.x11StorageStatus(),
        };
    }

    pub fn waylandDmabuf(self: *LinuxBackend) ?WaylandDmabuf {
        return switch (self.*) {
            .wayland => |*backend| backend.waylandDmabuf(),
            .x11 => null,
        };
    }

    pub fn waylandStorageStatus(self: *const LinuxBackend) WaylandStorageStatus {
        return switch (self.*) {
            .wayland => |*backend| backend.waylandStorageStatus(),
            .x11 => |*backend| backend.waylandStorageStatus(),
        };
    }

    pub fn nextPresentationOutcome(self: *LinuxBackend) ?presentation.Outcome {
        return switch (self.*) {
            .wayland => |*backend| backend.nextPresentationOutcome(),
            .x11 => |*backend| backend.nextPresentationOutcome(),
        };
    }

    pub fn presentationStatus(self: *const LinuxBackend) presentation.Status {
        return switch (self.*) {
            .wayland => |*backend| backend.presentationStatus(),
            .x11 => |*backend| backend.presentationStatus(),
        };
    }

    pub fn presentationStorageStatus(self: *const LinuxBackend) presentation.StorageStatus {
        return switch (self.*) {
            .wayland => |*backend| backend.presentationStorageStatus(),
            .x11 => |*backend| backend.presentationStorageStatus(),
        };
    }
};

fn waylandAdvertised() bool {
    if (sys.env.contains("WAYLAND_DISPLAY") or sys.env.contains("WAYLAND_SOCKET")) return true;
    return if (sys.env.getConstant("XDG_SESSION_TYPE")) |session_type|
        std.mem.eql(u8, session_type, "wayland")
    else
        false;
}

fn shouldFallback(failure: window.CreateError) bool {
    return switch (failure) {
        error.ConnectionFailed, error.WindowCreationFailed, error.UnsupportedPlatform => true,
        error.InvalidCapacity, error.OutOfMemory => false,
    };
}

fn selectionOrder(preference: BackendPreference, wayland_display_present: bool) SelectionOrder {
    return switch (preference) {
        .auto => if (wayland_display_present)
            .{ .first = .wayland, .fallback = .x11 }
        else
            .{ .first = .x11, .fallback = null },
        .wayland => .{ .first = .wayland, .fallback = null },
        .x11 => .{ .first = .x11, .fallback = null },
    };
}

test "Linux backend selection prefers Wayland only when advertised" {
    try std.testing.expectEqual(
        SelectionOrder{ .first = .wayland, .fallback = .x11 },
        selectionOrder(.auto, true),
    );
    try std.testing.expectEqual(
        SelectionOrder{ .first = .x11, .fallback = null },
        selectionOrder(.auto, false),
    );
}

test "explicit Linux backend selections never redirect" {
    try std.testing.expectEqual(
        SelectionOrder{ .first = .wayland, .fallback = null },
        selectionOrder(.wayland, false),
    );
    try std.testing.expectEqual(
        SelectionOrder{ .first = .x11, .fallback = null },
        selectionOrder(.x11, true),
    );
}

test "automatic Linux fallback preserves allocation failures" {
    try std.testing.expect(shouldFallback(error.ConnectionFailed));
    try std.testing.expect(shouldFallback(error.WindowCreationFailed));
    try std.testing.expect(shouldFallback(error.UnsupportedPlatform));
    try std.testing.expect(!shouldFallback(error.InvalidCapacity));
    try std.testing.expect(!shouldFallback(error.OutOfMemory));
}

test "live automatic unreachable Wayland falls back to invisible X11 window under Xvfb" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const marker = sys.env.getConstant("TINY_WINDOWING_LIVE_AUTO_FALLBACK") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, marker, "1")) return error.SkipZigTest;

    try std.testing.expect(sys.env.get("WAYLAND_DISPLAY") == null);
    try std.testing.expect(sys.env.get("WAYLAND_SOCKET") == null);
    try std.testing.expectEqualStrings(
        "wayland",
        sys.env.getConstant("XDG_SESSION_TYPE") orelse return error.TestUnexpectedResult,
    );
    try std.testing.expectEqualStrings(
        "/tmp/windowing-test-missing-runtime",
        sys.env.getConstant("XDG_RUNTIME_DIR") orelse return error.TestUnexpectedResult,
    );
    try std.testing.expect(sys.env.get("DISPLAY") != null);

    const allocator = std.testing.allocator;
    var live_window = try window.Window.create(allocator, .{
        .title = "windowing-auto-fallback-live",
        .width = 37,
        .height = 19,
        .visible = false,
        .backend = .auto,
    });
    defer live_window.destroy();

    const native = live_window.getNativeSurface();
    try std.testing.expectEqual(surface.Kind.x11, native.kind());
    const extent = native.extent();
    try std.testing.expectEqual(@as(u32, 37), extent.width);
    try std.testing.expectEqual(@as(u32, 19), extent.height);
    try std.testing.expectEqual(@as(u32, 37), extent.framebuffer_width);
    try std.testing.expectEqual(@as(u32, 19), extent.framebuffer_height);
}
