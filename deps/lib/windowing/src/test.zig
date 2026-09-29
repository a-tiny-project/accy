const std = @import("std");
const alloc_phase = @import("alloc_phase");
const builtin = @import("builtin");
const native_wayland = @import("wayland");
const native_xkb = @import("xkb");
const sys = @import("sys");

const windowing = @import("root.zig");
const window = @import("window.zig");
const key = @import("key.zig");
const mouse = @import("mouse.zig");
const modifier = @import("modifier.zig");
const cursor = @import("cursor.zig");
const clipboard_module = @import("clipboard.zig");
const gamepad_module = @import("gamepad.zig");
const input_module = @import("input.zig");
const config = @import("config.zig");
const backend = @import("backend.zig");
const wayland = @import("wayland/root.zig");
const surface_module = @import("surface.zig");

const event = windowing.event;
const presentation = windowing.presentation;
const Window = windowing.Window;
const Size = windowing.Size;
const Event = windowing.Event;
const EventIterator = windowing.EventIterator;
const KeyEvent = windowing.KeyEvent;
const MouseButtonEvent = windowing.MouseButtonEvent;
const MouseMoveEvent = windowing.MouseMoveEvent;
const Key = windowing.Key;
const MouseButton = windowing.MouseButton;
const clipboard = windowing.clipboard;
const input = windowing.input;
const WindowConfig = windowing.WindowConfig;
const default_wayland_compose_limits = windowing.default_wayland_compose_limits;
const default_wayland_compose_scratch_limits = windowing.default_wayland_compose_scratch_limits;
const SurfaceKind = windowing.SurfaceKind;
const CocoaSurface = windowing.CocoaSurface;
const ClipboardCapacity = windowing.ClipboardCapacity;
const EventQueueCapacity = windowing.EventQueueCapacity;
const GamepadCapacity = windowing.GamepadCapacity;
const InputCapacity = windowing.InputCapacity;
const PresentationCapacity = windowing.PresentationCapacity;
const WaylandSessionCapacity = windowing.WaylandSessionCapacity;
const WaylandPresentationCapacity = windowing.WaylandPresentationCapacity;
const WaylandRuntimeCapacity = windowing.WaylandRuntimeCapacity;
const WaylandComposeCapacity = windowing.WaylandComposeCapacity;
const WaylandComposeScratchLimits = windowing.WaylandComposeScratchLimits;
const WaylandComposeScratchCapacity = windowing.WaylandComposeScratchCapacity;
const WaylandEventStorageCapacity = windowing.WaylandEventStorageCapacity;
const wayland_process_environment_capacity = windowing.wayland_process_environment_capacity;

test "windowing package namespace" {
    std.testing.refAllDecls(window);
    std.testing.refAllDecls(event);
    std.testing.refAllDecls(key);
    std.testing.refAllDecls(mouse);
    std.testing.refAllDecls(modifier);
    std.testing.refAllDecls(cursor);
    std.testing.refAllDecls(clipboard_module);
    std.testing.refAllDecls(gamepad_module);
    std.testing.refAllDecls(input_module);
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(backend);
    if (comptime builtin.os.tag == .linux) {
        std.testing.refAllDecls(wayland);
        _ = @import("wayland/test.zig");
        _ = @import("wayland/toplevel/state.zig");
    }
    std.testing.refAllDecls(surface_module);
    std.testing.refAllDecls(presentation);
}

fn containsWindowClose(events: *EventIterator) bool {
    while (events.next()) |queued| {
        if (queued == .window_close) return true;
    }
    return false;
}

fn containsWindowFocus(events: *EventIterator, focused: bool) bool {
    while (events.next()) |queued| switch (queued) {
        .window_focus => |focus| if (focus.focused == focused) return true,
        else => {},
    };
    return false;
}

fn keyPress(events: *EventIterator, key_value: Key) ?KeyEvent {
    while (events.next()) |queued| switch (queued) {
        .key_press => |key_event| if (key_event.key == key_value) return key_event,
        else => {},
    };
    return null;
}

fn containsKeyRelease(events: *EventIterator, key_value: Key) bool {
    while (events.next()) |queued| switch (queued) {
        .key_release => |key_event| if (key_event.key == key_value) return true,
        else => {},
    };
    return false;
}

fn mousePress(events: *EventIterator, button: MouseButton) ?MouseButtonEvent {
    while (events.next()) |queued| switch (queued) {
        .mouse_press => |mouse_event| if (mouse_event.button == button) return mouse_event,
        else => {},
    };
    return null;
}

fn containsMouseRelease(events: *EventIterator, button: MouseButton) bool {
    while (events.next()) |queued| switch (queued) {
        .mouse_release => |mouse_event| if (mouse_event.button == button) return true,
        else => {},
    };
    return false;
}

fn mouseMove(events: *EventIterator) ?MouseMoveEvent {
    while (events.next()) |queued| switch (queued) {
        .mouse_move => |mouse_event| return mouse_event,
        else => {},
    };
    return null;
}

const CocoaMouseCase = struct {
    down_type: sys.apple.coregraphics.EventType,
    up_type: sys.apple.coregraphics.EventType,
    number: u32,
    button: MouseButton,
};

const cocoa_mouse_cases = [_]CocoaMouseCase{
    .{
        .down_type = sys.apple.coregraphics.event_left_mouse_down,
        .up_type = sys.apple.coregraphics.event_left_mouse_up,
        .number = 0,
        .button = .left,
    },
    .{
        .down_type = sys.apple.coregraphics.event_right_mouse_down,
        .up_type = sys.apple.coregraphics.event_right_mouse_up,
        .number = 1,
        .button = .right,
    },
    .{
        .down_type = sys.apple.coregraphics.event_other_mouse_down,
        .up_type = sys.apple.coregraphics.event_other_mouse_up,
        .number = 2,
        .button = .middle,
    },
    .{
        .down_type = sys.apple.coregraphics.event_other_mouse_down,
        .up_type = sys.apple.coregraphics.event_other_mouse_up,
        .number = 3,
        .button = .x1,
    },
    .{
        .down_type = sys.apple.coregraphics.event_other_mouse_down,
        .up_type = sys.apple.coregraphics.event_other_mouse_up,
        .number = 4,
        .button = .x2,
    },
};

fn postCocoaKeyEvent(
    native: CocoaSurface,
    keycode: u16,
    key_down: bool,
    flags: sys.apple.coregraphics.EventFlags,
    repeated: bool,
) !sys.apple.objc.Id {
    const cg_event = sys.apple.coregraphics.createKeyboardEvent(keycode, key_down) orelse
        return error.TestUnexpectedResult;
    defer sys.apple.coregraphics.releaseEvent(cg_event);
    sys.apple.coregraphics.setKeyboardEventFlags(cg_event, flags);
    sys.apple.coregraphics.setKeyboardEventRepeated(cg_event, repeated);
    return postCocoaEvent(native, cg_event);
}

fn postCocoaMouseEvent(
    native: CocoaSurface,
    event_type: sys.apple.coregraphics.EventType,
    button: sys.apple.coregraphics.MouseButton,
) !sys.apple.objc.Id {
    const cg_event = sys.apple.coregraphics.createMouseEvent(
        event_type,
        .{ .x = 16, .y = 16 },
        button,
    ) orelse return error.TestUnexpectedResult;
    defer sys.apple.coregraphics.releaseEvent(cg_event);
    return postCocoaEvent(native, cg_event);
}

fn postCocoaEvent(
    native: CocoaSurface,
    cg_event: sys.apple.coregraphics.Event,
) !sys.apple.objc.Id {
    var pool = sys.apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    const event_class = sys.apple.objc.class("NSEvent") orelse
        return error.TestUnexpectedResult;
    const ns_event = sys.apple.objc.send(
        ?sys.apple.objc.Id,
        event_class,
        sys.apple.objc.selector("eventWithCGEvent:"),
        .{cg_event},
    ) orelse return error.TestUnexpectedResult;
    const retained = sys.apple.objc.retain(ns_event);
    sys.apple.objc.send(
        void,
        native.app,
        sys.apple.objc.selector("postEvent:atStart:"),
        .{ retained, sys.apple.objc.boolean(true) },
    );
    return retained;
}

fn expectCocoaEventType(
    ns_event: sys.apple.objc.Id,
    expected: sys.apple.foundation.NSUInteger,
) !void {
    const actual = sys.apple.objc.send(
        sys.apple.foundation.NSUInteger,
        ns_event,
        sys.apple.objc.selector("type"),
        .{},
    );
    try std.testing.expectEqual(expected, actual);
}

fn expectCocoaMouseButton(ns_event: sys.apple.objc.Id, expected: sys.apple.foundation.NSInteger) !void {
    const actual = sys.apple.objc.send(
        sys.apple.foundation.NSInteger,
        ns_event,
        sys.apple.objc.selector("buttonNumber"),
        .{},
    );
    try std.testing.expectEqual(expected, actual);
}

test "windowing Cocoa window presents through the public lifecycle" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const width: u32 = 2;
    const height: u32 = 2;
    const frame_byte_count = width * height * 4;
    var app_window = try Window.create(std.testing.allocator, .{
        .width = width,
        .height = height,
        .visible = false,
        .presentation = .{ .retained_frame_byte_count = frame_byte_count },
    });
    defer app_window.destroy();

    try std.testing.expectEqual(Size{ .width = width, .height = height }, app_window.getSize());
    try std.testing.expectEqual(SurfaceKind.cocoa, app_window.getNativeSurface().kind());
    const first = @as([frame_byte_count]u8, @splat(0x31));
    const second = @as([frame_byte_count]u8, @splat(0x79));
    try app_window.presentRgba8(&first, width, height);
    try app_window.presentRgba8(&second, width, height);
    try app_window.presentRgba8Region(&first, width, height, .{
        .x = 1,
        .y = 1,
        .width = 1,
        .height = 1,
    });
    _ = try app_window.pollEvents();
    try std.testing.expectEqual(presentation.StorageStatus{}, app_window.presentationStorageStatus());
}

test "windowing Cocoa window reports native close through public state" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var app_window = try Window.create(std.testing.allocator, .{
        .title = "windowing close event",
        .width = 96,
        .height = 64,
        .visible = false,
    });
    defer app_window.destroy();

    const native = app_window.getNativeSurface().cocoa;
    sys.apple.objc.send(
        void,
        native.window,
        sys.apple.objc.selector("performClose:"),
        .{sys.apple.objc.nil},
    );
    try std.testing.expect(app_window.shouldClose());
    var events = try app_window.pollEvents();
    try std.testing.expect(containsWindowClose(&events));
}

test "windowing Cocoa window preserves empty title support" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var app_window = try Window.create(std.testing.allocator, .{
        .title = "",
        .width = 96,
        .height = 64,
        .visible = false,
    });
    defer app_window.destroy();
    app_window.setTitle("");

    const native = app_window.getNativeSurface().cocoa;
    const title = sys.apple.objc.send(
        sys.apple.foundation.String,
        native.window,
        sys.apple.objc.selector("title"),
        .{},
    );
    const length = sys.apple.objc.send(
        sys.apple.foundation.NSUInteger,
        @ptrCast(title),
        sys.apple.objc.selector("length"),
        .{},
    );
    try std.testing.expectEqual(@as(sys.apple.foundation.NSUInteger, 0), length);
}

test "windowing Cocoa delegate reports focus transitions through public events" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var app_window = try Window.create(std.testing.allocator, .{
        .title = "windowing focus events",
        .width = 96,
        .height = 64,
        .visible = false,
    });
    defer app_window.destroy();

    const native = app_window.getNativeSurface().cocoa;
    const delegate = sys.apple.objc.send(
        ?sys.apple.objc.Id,
        native.window,
        sys.apple.objc.selector("delegate"),
        .{},
    ) orelse return error.TestUnexpectedResult;
    sys.apple.objc.send(
        void,
        delegate,
        sys.apple.objc.selector("windowDidBecomeKey:"),
        .{sys.apple.objc.nil},
    );
    var events = try app_window.pollEvents();
    try std.testing.expect(containsWindowFocus(&events, true));

    sys.apple.objc.send(
        void,
        delegate,
        sys.apple.objc.selector("windowDidResignKey:"),
        .{sys.apple.objc.nil},
    );
    events = try app_window.pollEvents();
    try std.testing.expect(containsWindowFocus(&events, false));
}

test "windowing Cocoa modifier events update public key state" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var app_window = try Window.create(std.testing.allocator, .{
        .title = "windowing modifier events",
        .width = 96,
        .height = 64,
        .visible = false,
    });
    defer app_window.destroy();
    const native = app_window.getNativeSurface().cocoa;

    const pressed_event = try postCocoaKeyEvent(
        native,
        0x38,
        true,
        sys.apple.cocoa.NSEventModifierFlagShift,
        false,
    );
    defer sys.apple.objc.release(pressed_event);
    try expectCocoaEventType(pressed_event, sys.apple.cocoa.NSEventTypeFlagsChanged);
    var events = try app_window.pollEvents();
    const pressed = keyPress(&events, .left_shift) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(pressed.modifiers.shift);
    try std.testing.expect(app_window.isKeyDown(.left_shift));
    try std.testing.expect(app_window.modifiers().shift);

    const right_pressed_event = try postCocoaKeyEvent(
        native,
        0x3C,
        true,
        sys.apple.cocoa.NSEventModifierFlagShift,
        false,
    );
    defer sys.apple.objc.release(right_pressed_event);
    events = try app_window.pollEvents();
    const right_pressed = keyPress(&events, .right_shift) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(right_pressed.modifiers.shift);
    try std.testing.expect(app_window.isKeyDown(.left_shift));
    try std.testing.expect(app_window.isKeyDown(.right_shift));

    const left_released_event = try postCocoaKeyEvent(
        native,
        0x38,
        false,
        sys.apple.cocoa.NSEventModifierFlagShift,
        false,
    );
    defer sys.apple.objc.release(left_released_event);
    try expectCocoaEventType(left_released_event, sys.apple.cocoa.NSEventTypeFlagsChanged);
    events = try app_window.pollEvents();
    try std.testing.expect(containsKeyRelease(&events, .left_shift));
    try std.testing.expect(!app_window.isKeyDown(.left_shift));
    try std.testing.expect(app_window.isKeyDown(.right_shift));
    try std.testing.expect(app_window.modifiers().shift);

    const right_released_event = try postCocoaKeyEvent(native, 0x3C, false, 0, false);
    defer sys.apple.objc.release(right_released_event);
    events = try app_window.pollEvents();
    try std.testing.expect(containsKeyRelease(&events, .right_shift));
    try std.testing.expect(!app_window.isKeyDown(.right_shift));
    try std.testing.expect(!app_window.modifiers().shift);
}

test "windowing Cocoa key repeats preserve native metadata" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var app_window = try Window.create(std.testing.allocator, .{
        .title = "windowing repeat events",
        .width = 96,
        .height = 64,
        .visible = false,
    });
    defer app_window.destroy();
    const native = app_window.getNativeSurface().cocoa;

    const repeated_event = try postCocoaKeyEvent(native, 0x00, true, 0, true);
    defer sys.apple.objc.release(repeated_event);
    const native_repeated = sys.apple.objc.send(
        sys.apple.objc.BOOL,
        repeated_event,
        sys.apple.objc.selector("isARepeat"),
        .{},
    );
    try std.testing.expect(sys.apple.objc.isTrue(native_repeated));
    var events = try app_window.pollEvents();
    const pressed = keyPress(&events, .a) orelse return error.TestUnexpectedResult;
    try std.testing.expect(pressed.repeated);
}

test "windowing Cocoa other mouse buttons update public state" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var app_window = try Window.create(std.testing.allocator, .{
        .title = "windowing other mouse events",
        .width = 96,
        .height = 64,
        .visible = false,
    });
    defer app_window.destroy();
    const native = app_window.getNativeSurface().cocoa;
    for (cocoa_mouse_cases) |case| {
        const pressed_event = try postCocoaMouseEvent(
            native,
            case.down_type,
            case.number,
        );
        defer sys.apple.objc.release(pressed_event);
        try expectCocoaEventType(pressed_event, @intCast(case.down_type));
        try expectCocoaMouseButton(pressed_event, case.number);
        var events = try app_window.pollEvents();
        _ = mousePress(&events, case.button) orelse return error.TestUnexpectedResult;
        try std.testing.expect(app_window.isMouseButtonDown(case.button));

        const released_event = try postCocoaMouseEvent(
            native,
            case.up_type,
            case.number,
        );
        defer sys.apple.objc.release(released_event);
        try expectCocoaEventType(released_event, @intCast(case.up_type));
        try expectCocoaMouseButton(released_event, case.number);
        events = try app_window.pollEvents();
        try std.testing.expect(containsMouseRelease(&events, case.button));
        try std.testing.expect(!app_window.isMouseButtonDown(case.button));
    }
}

test "windowing Cocoa other mouse drag updates public position" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var app_window = try Window.create(std.testing.allocator, .{
        .title = "windowing other mouse drag",
        .width = 96,
        .height = 64,
        .visible = false,
    });
    defer app_window.destroy();
    const native = app_window.getNativeSurface().cocoa;
    const dragged_event = try postCocoaMouseEvent(
        native,
        sys.apple.coregraphics.event_other_mouse_dragged,
        3,
    );
    defer sys.apple.objc.release(dragged_event);
    try expectCocoaEventType(dragged_event, sys.apple.cocoa.NSEventTypeOtherMouseDragged);
    try expectCocoaMouseButton(dragged_event, 3);
    var events = try app_window.pollEvents();
    const moved = mouseMove(&events) orelse return error.TestUnexpectedResult;
    const position = app_window.getMousePosition();
    try std.testing.expectEqual(position.x, moved.x);
    try std.testing.expectEqual(position.y, moved.y);
}

test "windowing Cocoa window exposes consistent live backing scale" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const width: u32 = 96;
    const height: u32 = 64;
    var app_window = try Window.create(std.testing.allocator, .{
        .title = "windowing scale evidence",
        .width = width,
        .height = height,
        .visible = false,
    });
    defer app_window.destroy();

    _ = try app_window.pollEvents();
    const size = app_window.getSize();
    const scale = app_window.getContentScale();
    const framebuffer = app_window.getFramebufferSize();
    const native_surface = app_window.getNativeSurface();
    const extent = native_surface.extent();
    const evidence = app_window.getScaleEvidence();
    const resolved = sys.desktop.windowScaleFromEvidence(evidence);

    try std.testing.expectEqual(Size{ .width = width, .height = height }, size);
    try std.testing.expect(std.math.isFinite(scale.x));
    try std.testing.expect(std.math.isFinite(scale.y));
    try std.testing.expect(scale.x > 0);
    try std.testing.expect(scale.y > 0);
    try std.testing.expectApproxEqAbs(scale.x, scale.y, 0.001);
    try std.testing.expectEqual(
        Size{
            .width = @intFromFloat(@round(@as(f32, @floatFromInt(size.width)) * scale.x)),
            .height = @intFromFloat(@round(@as(f32, @floatFromInt(size.height)) * scale.y)),
        },
        framebuffer,
    );
    try std.testing.expectEqual(SurfaceKind.cocoa, native_surface.kind());
    try std.testing.expectEqual(size.width, extent.width);
    try std.testing.expectEqual(size.height, extent.height);
    try std.testing.expectEqual(framebuffer.width, extent.framebuffer_width);
    try std.testing.expectEqual(framebuffer.height, extent.framebuffer_height);
    try std.testing.expectApproxEqAbs(scale.x, extent.scale_x, 0.001);
    try std.testing.expectApproxEqAbs(scale.y, extent.scale_y, 0.001);
    try std.testing.expect(evidence.has_window_content_scale);
    try std.testing.expectApproxEqAbs(scale.x, evidence.window_display, 0.001);
    try std.testing.expectApproxEqAbs(scale.y, evidence.display_content, 0.001);
    try std.testing.expectApproxEqAbs(scale.x, evidence.pixel_density, 0.001);
    try std.testing.expectApproxEqAbs(scale.x, resolved.ui, 0.001);
}

test "windowing root composes Wayland presentation capacity from window limits" {
    const config_value = WindowConfig{ .presentation = .{
        .pending_feedback_count = 3,
        .retained_outcome_count = 6,
        .active_buffer_count = 2,
        .retired_buffer_count = 7,
        .retained_frame_byte_count = 13,
    } };
    const frames = try PresentationCapacity.derive(config_value.presentation);
    const capacity = try WaylandPresentationCapacity.derive(config_value.presentation);
    try std.testing.expectEqual(@as(usize, 13), frames.retained_frame_byte_count);
    try std.testing.expectEqual(@as(usize, 26), frames.maximum_backend_frame_storage_bytes);
    try std.testing.expectEqual(@as(usize, 3), capacity.pending_feedback_count);
    try std.testing.expectEqual(@as(usize, 6), capacity.retained_outcome_count);
    try std.testing.expectEqual(@as(usize, 2), capacity.swapchain.active_buffer_count);
    try std.testing.expectEqual(@as(usize, 7), capacity.swapchain.retired_buffer_count);
    try std.testing.expectEqual(@as(usize, 13), capacity.pending_frame_bytes);
    try std.testing.expectEqual(@as(usize, 11 * 13), capacity.maximum_foreign_mapped_frame_bytes);
}

test "window rejects invalid frame storage before backend effects" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, Window.create(std.testing.allocator, .{
        .presentation = .{ .retained_frame_byte_count = 0 },
    }));
}

test "windowing root composes Wayland output capacity from window config" {
    const config_value = WindowConfig{ .wayland_output_count = 3 };
    const capacity = try WaylandSessionCapacity.derive(config_value.wayland_output_count);
    try std.testing.expectEqual(@as(usize, 3), capacity.retained_output_count);
    try std.testing.expectEqual(
        3 * @sizeOf(wayland.session.output.Output),
        capacity.retained_output_bytes,
    );
}

test "windowing root composes Wayland runtime capacity" {
    const config_value = WindowConfig{ .wayland_runtime = .{
        .transport = .{
            .inbound_byte_count = 13,
            .inbound_descriptor_count = 2,
            .outbound_byte_count = 17,
            .outbound_descriptor_count = 3,
        },
        .client_object_count = 5,
        .server_object_count = 7,
        .retained_global_count = 3,
        .global_interface_name_byte_count = 11,
    } };
    const capacity = try WaylandRuntimeCapacity.derive(config_value.wayland_runtime);
    try std.testing.expectEqual(@as(usize, 13), capacity.transport.inbound_byte_count);
    try std.testing.expectEqual(@as(usize, 2), capacity.transport.inbound_descriptor_count);
    try std.testing.expectEqual(@as(usize, 17), capacity.transport.outbound_byte_count);
    try std.testing.expectEqual(@as(usize, 3), capacity.transport.outbound_descriptor_count);
    try std.testing.expectEqual(@as(usize, 9), capacity.request_encoder.payload_byte_count);
    try std.testing.expectEqual(@as(usize, 3), capacity.request_encoder.descriptor_count);
    try std.testing.expectEqual(@as(usize, 5), capacity.event_storage.payload_byte_count);
    try std.testing.expectEqual(@as(usize, 1), capacity.event_storage.descriptor_count);
    try std.testing.expectEqual(
        @sizeOf(@import("sys").fd.Descriptor),
        capacity.event_storage.descriptor_bytes,
    );
    try std.testing.expectEqual(
        capacity.event_storage,
        try WaylandEventStorageCapacity.derive(.{
            .payload_byte_count = 5,
            .descriptor_count = 1,
        }),
    );
    try std.testing.expectEqual(
        native_wayland.runtime.maximum_event_creation_count,
        capacity.event_creations.event_creation_count,
    );
    try std.testing.expectEqual(
        @sizeOf(native_wayland.runtime.creation.Creation),
        capacity.event_creations.event_creation_bytes,
    );
    try std.testing.expectEqual(@as(usize, 5), capacity.client_ids.client_id_count);
    try std.testing.expectEqual(@as(usize, 5), capacity.objects.client_object_count);
    try std.testing.expectEqual(@as(usize, 7), capacity.objects.server_object_count);
    try std.testing.expectEqual(@as(usize, 3), capacity.globals.retained_global_count);
    try std.testing.expectEqual(
        @as(usize, 11),
        capacity.globals.interface_name_byte_count_per_global,
    );
    try std.testing.expectEqual(
        5 * @sizeOf(native_wayland.runtime.ObjectClientSlot),
        capacity.objects.client_slot_bytes,
    );
    try std.testing.expectEqual(
        7 * @sizeOf(native_wayland.runtime.ObjectServerSlot),
        capacity.objects.server_slot_bytes,
    );
    try std.testing.expectEqual(
        3 * @sizeOf(native_wayland.runtime.GlobalStorageSlot),
        capacity.globals.retained_global_bytes,
    );
    try std.testing.expectEqual(@as(usize, 33), capacity.globals.interface_name_bytes);
}

test "windowing root composes Wayland Compose capacity from window limits" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(
                @import("xkb").compose.Storage,
                "xkb_compose_windowing_root",
            ),
        );
    }

    const config_value = WindowConfig{
        .wayland_compose = .{
            .sequence_symbols = 2,
            .text_bytes = 3,
        },
        .wayland_compose_scratch = .{
            .line_bytes = 32,
            .path_bytes = 64,
        },
    };
    const capacity = try WaylandComposeCapacity.derive(config_value.wayland_compose);
    const scratch_capacity = try WaylandComposeScratchCapacity.derive(
        config_value.wayland_compose_scratch,
    );
    try std.testing.expectEqual(@as(usize, 3), capacity.node_count);
    try std.testing.expectEqual(@as(usize, 2), capacity.edge_count);
    try std.testing.expectEqual(@as(usize, 75), capacity.storage_bytes);
    try std.testing.expectEqual(@as(usize, 743), scratch_capacity.storage_bytes);
    try std.testing.expectEqual(
        default_wayland_compose_limits,
        (WindowConfig{}).wayland_compose,
    );
    try std.testing.expectEqual(
        default_wayland_compose_scratch_limits,
        (WindowConfig{}).wayland_compose_scratch,
    );
    try std.testing.expectEqual(
        @as(usize, 253_968),
        (try WaylandComposeCapacity.derive(default_wayland_compose_limits)).storage_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 34_567),
        (try WaylandComposeScratchCapacity.derive(
            default_wayland_compose_scratch_limits,
        )).storage_bytes,
    );
}

test "windowing root composes Wayland Compose scratch capacity from window limits" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(
                @import("xkb").compose.ScratchStorage,
                "xkb_compose_scratch_windowing_root",
            ),
        );
    }

    const limits = WaylandComposeScratchLimits{
        .line_bytes = 32,
        .path_bytes = 64,
    };
    const capacity = try WaylandComposeScratchCapacity.derive(limits);
    try std.testing.expectEqual(@as(usize, 7), capacity.line_slot_count);
    try std.testing.expectEqual(@as(usize, 8), capacity.path_slot_count);
    try std.testing.expectEqual(@as(usize, 743), capacity.storage_bytes);
}

test "windowing root exposes the configured Wayland process environment capacity" {
    const capacity = wayland_process_environment_capacity;
    try std.testing.expectEqual(
        capacity.retained_entry_count + 1,
        capacity.source_entry_count,
    );
    try std.testing.expectEqual(
        capacity.source_entry_count,
        capacity.generation_entry_count,
    );
    try std.testing.expectEqual(
        capacity.generation_entry_count * @sizeOf(?[*:0]const u8) +
            capacity.generation_owner_bytes,
        capacity.total_static_bytes,
    );
}

test "windowing Wayland rejects invalid transport storage before backend effects" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, Window.create(std.testing.allocator, .{
        .backend = .wayland,
        .wayland_runtime = .{ .transport = .{ .inbound_byte_count = 0 } },
    }));
}

test "windowing Wayland rejects invalid object storage before backend effects" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, Window.create(std.testing.allocator, .{
        .backend = .wayland,
        .wayland_runtime = .{
            .server_object_count = native_wayland.runtime.maximum_server_object_count + 1,
        },
    }));
}

test "windowing Wayland rejects invalid global storage before backend effects" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, Window.create(std.testing.allocator, .{
        .backend = .wayland,
        .wayland_runtime = .{
            .retained_global_count = 2,
            .global_interface_name_byte_count = std.math.maxInt(usize),
        },
    }));
}

test "windowing Wayland rejects empty output storage before backend effects" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, Window.create(std.testing.allocator, .{
        .backend = .wayland,
        .wayland_output_count = 0,
    }));
}

test "windowing Wayland rejects invalid Compose storage before backend effects" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, Window.create(std.testing.allocator, .{
        .backend = .wayland,
        .wayland_compose = .{
            .sequence_symbols = native_xkb.compose.max_nodes,
            .text_bytes = 0,
        },
    }));
}

test "windowing Wayland rejects invalid Compose scratch before backend effects" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, Window.create(std.testing.allocator, .{
        .backend = .wayland,
        .wayland_compose_scratch = .{
            .line_bytes = 0,
            .path_bytes = 1,
        },
    }));
}

test "windowing Wayland rejects invalid swapchain capacity before backend effects" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, Window.create(std.testing.allocator, .{
        .backend = .wayland,
        .presentation = .{ .active_buffer_count = 0 },
    }));
}

test "windowing root composes clipboard capacity from window limits" {
    const config_value = WindowConfig{ .clipboard = .{
        .received_text_byte_count = 7,
        .transfer_read_byte_count = 3,
        .retained_wait_event_count = 2,
    } };
    const capacity = try ClipboardCapacity.derive(config_value.clipboard);
    try std.testing.expectEqual(@as(usize, 7), capacity.received_text_byte_count);
    try std.testing.expectEqual(@as(usize, 3), capacity.transfer_read_byte_count);
    try std.testing.expectEqual(@as(usize, 2), capacity.retained_wait_event_count);
}

test "window rejects invalid clipboard capacity before backend effects" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, Window.create(std.testing.allocator, .{
        .clipboard = .{ .transfer_read_byte_count = 0 },
    }));
}

test "windowing root composes event queue capacity from window limits" {
    const config_value = WindowConfig{ .events = .{ .retained_event_count = 3 } };
    const capacity = try EventQueueCapacity.derive(config_value.events);
    try std.testing.expectEqual(@as(usize, 3), capacity.retained_event_count);
    try std.testing.expectEqual(3 * @sizeOf(Event), capacity.retained_event_bytes);
}

test "window rejects invalid event queue capacity before backend effects" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, Window.create(std.testing.allocator, .{
        .events = .{ .retained_event_count = 0 },
    }));
}

test "windowing root composes gamepad capacity from window limits" {
    const config_value = WindowConfig{ .gamepads = .{
        .retained_gamepad_count = 2,
        .retained_name_byte_count_per_gamepad = 5,
        .read_event_count = 3,
        .scanned_source_count = 7,
    } };
    const capacity = try GamepadCapacity.derive(config_value.gamepads);
    const expected_read_event_count: usize = if (builtin.os.tag == .linux) 3 else 0;
    try std.testing.expectEqual(@as(usize, 2), capacity.retained_gamepad_count);
    try std.testing.expectEqual(@as(usize, 5), capacity.retained_name_byte_count_per_gamepad);
    try std.testing.expectEqual(expected_read_event_count, capacity.read_event_count);
    try std.testing.expectEqual(@as(u32, 7), capacity.scanned_source_count);
}

test "window rejects invalid gamepad capacity before backend effects" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, Window.create(std.testing.allocator, .{
        .gamepads = .{ .scanned_source_count = 0 },
    }));
}

test "windowing root composes input capacity from window limits" {
    const config_value = WindowConfig{ .input = .{
        .retained_pressed_key_count = 3,
        .retained_text_codepoint_count = 5,
    } };
    const capacity = try InputCapacity.derive(config_value.input);
    try std.testing.expectEqual(@as(usize, 3), capacity.retained_pressed_key_count);
    try std.testing.expectEqual(@as(usize, 5), capacity.retained_text_codepoint_count);
}

test "window rejects invalid input capacity before backend effects" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, Window.create(std.testing.allocator, .{
        .input = .{ .retained_pressed_key_count = 0 },
    }));
}
