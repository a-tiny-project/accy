const std = @import("std");
const sys = @import("sys");
const clipboard = @import("clipboard.zig");
const CursorShape = @import("cursor.zig").CursorShape;
const EventIterator = @import("event.zig").EventIterator;
const WindowConfig = @import("config.zig").WindowConfig;
const CreateError = @import("window.zig").CreateError;
const PollError = @import("window.zig").PollError;
const PresentError = @import("window.zig").PresentError;
const PresentRegion = @import("window.zig").PresentRegion;
const Scale = @import("window.zig").Scale;
const Size = @import("window.zig").Size;
const gamepad = @import("gamepad.zig");
const input = @import("input.zig");
const Modifier = @import("modifier.zig").Modifier;
const surface = @import("surface.zig");
const PresentationOutcome = @import("presentation.zig").Outcome;
const PresentationStatus = @import("presentation.zig").Status;
const PresentationStorageStatus = @import("presentation.zig").StorageStatus;
const WaylandStorageStatus = @import("wayland").runtime.StorageStatus;

pub const UnsupportedBackend = struct {
    width: u32 = 1,
    height: u32 = 1,
    should_close: bool = true,
    input: input.State = undefined,
    gamepads: gamepad.State = undefined,

    pub fn init(_: *UnsupportedBackend, _: std.mem.Allocator, config: WindowConfig) CreateError!void {
        _ = config;
        return error.UnsupportedPlatform;
    }

    pub fn deinit(_: *UnsupportedBackend) void {}

    pub fn pollEvents(_: *UnsupportedBackend) PollError!EventIterator {
        return .{ .events = &.{} };
    }

    pub fn droppedEventCount(_: *const UnsupportedBackend) u64 {
        return 0;
    }

    pub fn shouldClose(self: *const UnsupportedBackend) bool {
        return self.should_close;
    }

    pub fn eventSource(_: *const UnsupportedBackend) ?@import("window.zig").EventSource {
        return null;
    }

    pub fn getSize(self: *const UnsupportedBackend) Size {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn inputState(self: *const UnsupportedBackend) *const input.State {
        return &self.input;
    }

    pub fn inputStateMut(self: *UnsupportedBackend) *input.State {
        return &self.input;
    }

    pub fn modifiers(self: *const UnsupportedBackend) Modifier {
        return self.input.modifiers();
    }

    pub fn gamepadState(self: *const UnsupportedBackend) *const gamepad.State {
        return &self.gamepads;
    }

    pub fn setTitle(_: *UnsupportedBackend, _: [:0]const u8) void {}

    pub fn getFramebufferSize(self: *const UnsupportedBackend) Size {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn nativeSurface(self: *UnsupportedBackend) surface.Surface {
        return .{ .unsupported = .{ .extent = surface.extentFromSizes(
            self.width,
            self.height,
            self.width,
            self.height,
            1,
            1,
        ) } };
    }

    pub fn presentRgba8(
        _: *UnsupportedBackend,
        _: []const u8,
        _: u32,
        _: u32,
    ) PresentError!void {
        return error.UnsupportedPlatform;
    }

    pub fn presentRgba8Region(
        _: *UnsupportedBackend,
        _: []const u8,
        _: u32,
        _: u32,
        _: PresentRegion,
    ) PresentError!void {
        return error.UnsupportedPlatform;
    }

    pub fn presentRgba8Frame(_: *UnsupportedBackend, _: []const u8, _: u32, _: u32, _: []const PresentRegion) PresentError!u64 {
        return error.UnsupportedPlatform;
    }

    pub fn getContentScale(_: *const UnsupportedBackend) Scale {
        return .{ .x = 1, .y = 1 };
    }

    pub fn setMinSize(_: *UnsupportedBackend, _: u32, _: u32) void {}

    pub fn setCursor(_: *UnsupportedBackend, _: CursorShape) void {}

    pub fn isCursorOnScreen(_: *const UnsupportedBackend) bool {
        return false;
    }

    pub fn minimize(_: *UnsupportedBackend) void {}

    pub fn maximize(_: *UnsupportedBackend) void {}

    pub fn restore(_: *UnsupportedBackend) void {}

    pub fn isMaximized(_: *const UnsupportedBackend) bool {
        return false;
    }

    pub fn getClipboardTextAlloc(_: *UnsupportedBackend, _: std.mem.Allocator) !?[]u8 {
        return null;
    }

    pub fn setClipboardText(_: *UnsupportedBackend, _: []const u8) clipboard.PublishError!void {
        return error.Unavailable;
    }

    pub fn clipboardStatus(_: *const UnsupportedBackend) clipboard.Status {
        return .{};
    }

    pub fn x11StorageStatus(_: *const UnsupportedBackend) sys.x11.Status {
        return .{};
    }

    pub fn waylandDmabuf(_: *UnsupportedBackend) ?@import("wayland/root.zig").DmabufSurface {
        return null;
    }

    pub fn waylandStorageStatus(_: *const UnsupportedBackend) WaylandStorageStatus {
        return .{};
    }

    pub fn nextPresentationOutcome(_: *UnsupportedBackend) ?PresentationOutcome {
        return null;
    }

    pub fn presentationStatus(_: *const UnsupportedBackend) PresentationStatus {
        return .unavailable;
    }

    pub fn presentationStorageStatus(_: *const UnsupportedBackend) PresentationStorageStatus {
        return .{};
    }
};

test "unsupported backend rejects clipboard publication explicitly" {
    var backend = UnsupportedBackend{};
    try std.testing.expectError(
        error.Unavailable,
        backend.setClipboardText("unavailable"),
    );
}
