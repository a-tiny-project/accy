const sys = @import("sys");
const native_wayland = @import("wayland");
const native_xkb = @import("xkb");
const clipboard = @import("clipboard.zig");
const event = @import("event.zig");
const gamepad = @import("gamepad.zig");
const input = @import("input.zig");
const presentation = @import("presentation.zig");

pub const BackendPreference = enum {
    auto,
    wayland,
    x11,
};

pub const default_wayland_output_count: usize = 16;
pub const default_wayland_compose_limits = native_xkb.compose.Limits{
    .sequence_symbols = 8 * 1024,
    .text_bytes = 24 * 1024,
};
pub const default_wayland_compose_scratch_limits = native_xkb.compose.default_scratch_limits;

pub const WindowConfig = struct {
    title: [:0]const u8 = "windowing",
    app_id: [:0]const u8 = "tiny.windowing",
    width: u32 = 800,
    height: u32 = 600,
    resizable: bool = true,
    visible: bool = true,
    backend: BackendPreference = .auto,
    clipboard: clipboard.Limits = .{},
    events: event.Limits = .{},
    gamepads: gamepad.Limits = .{},
    input: input.Limits = .{},
    presentation: presentation.Limits = .{},
    wayland_runtime: native_wayland.runtime.Limits = .{},
    wayland_compose: native_xkb.compose.Limits = default_wayland_compose_limits,
    wayland_compose_scratch: native_xkb.compose.ScratchLimits =
        default_wayland_compose_scratch_limits,
    wayland_output_count: usize = default_wayland_output_count,
    x11_request_byte_count: usize = sys.x11.protocol.maximum_request_byte_count,
    x11_reply_byte_count: usize = sys.x11.default_reply_byte_count,
};
