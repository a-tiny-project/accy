const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys");
const clipboard = @import("clipboard.zig");
const event_module = @import("event.zig");
const Event = event_module.Event;
const MouseButtonEvent = event_module.MouseButtonEvent;
const CursorShape = @import("cursor.zig").CursorShape;
const gamepad = @import("gamepad.zig");
const input = @import("input.zig");
const Key = @import("key.zig").Key;
const MouseButton = @import("mouse.zig").MouseButton;
const Modifier = @import("modifier.zig").Modifier;
const surface = @import("surface.zig");
const WindowConfig = @import("config.zig").WindowConfig;
const CreateError = @import("window.zig").CreateError;
const Size = @import("window.zig").Size;
const Scale = @import("window.zig").Scale;
const PollError = @import("window.zig").PollError;
const PresentError = @import("window.zig").PresentError;
const PresentRegion = @import("window.zig").PresentRegion;
const EventIterator = event_module.EventIterator;
const presentation = @import("presentation.zig");
const PresentationOutcome = presentation.Outcome;
const PresentationStatus = presentation.Status;
const PresentationStorageStatus = presentation.StorageStatus;
const WaylandStorageStatus = @import("wayland").runtime.StorageStatus;

const cocoa = sys.apple.cocoa;
const foundation = sys.apple.foundation;
const coregraphics = sys.apple.coregraphics;
const objc = sys.apple.objc;

fn cls(name: [*:0]const u8) CreateError!objc.Id {
    return objc.class(name) orelse return error.WindowCreationFailed;
}

const window_delegate_class_name: [*:0]const u8 = "TinyWindowingWindowDelegate";
const window_delegate_backend_ivar: [*:0]const u8 = "tinyBackend";
const window_delegate_bool_method: [*:0]const u8 = if (objc.BOOL == bool) "B@:@" else "c@:@";
const window_delegate_void_method: [*:0]const u8 = "v@:@";

fn windowDelegateClass() CreateError!objc.Class {
    if (objc.lookupClass(window_delegate_class_name)) |class_value| return class_value;

    const superclass = objc.lookupClass("NSObject") orelse return error.WindowCreationFailed;
    const class_value = objc.allocateClassPair(
        superclass,
        window_delegate_class_name,
    ) orelse return error.WindowCreationFailed;
    errdefer objc.disposeClassPair(class_value);
    if (!objc.addPointerIvar(class_value, window_delegate_backend_ivar)) {
        return error.WindowCreationFailed;
    }
    if (!objc.addMethod(
        class_value,
        objc.selector("windowShouldClose:"),
        @ptrCast(&windowShouldCloseCallback),
        window_delegate_bool_method,
    )) return error.WindowCreationFailed;
    if (!objc.addMethod(
        class_value,
        objc.selector("windowDidBecomeKey:"),
        @ptrCast(&windowDidBecomeKeyCallback),
        window_delegate_void_method,
    )) return error.WindowCreationFailed;
    if (!objc.addMethod(
        class_value,
        objc.selector("windowDidResignKey:"),
        @ptrCast(&windowDidResignKeyCallback),
        window_delegate_void_method,
    )) return error.WindowCreationFailed;
    objc.registerClassPair(class_value);
    return class_value;
}

fn delegateBackend(delegate: objc.Id) *CocoaBackend {
    const pointer = objc.instancePointer(delegate, window_delegate_backend_ivar).?;
    return @ptrCast(@alignCast(pointer));
}

fn windowShouldCloseCallback(
    delegate: objc.Id,
    _: objc.SEL,
    _: objc.Id,
) callconv(.c) objc.BOOL {
    delegateBackend(delegate).recordClose();
    return objc.boolean(true);
}

fn windowDidBecomeKeyCallback(
    delegate: objc.Id,
    _: objc.SEL,
    _: objc.Id,
) callconv(.c) void {
    delegateBackend(delegate).recordFocus(true);
}

fn windowDidResignKeyCallback(
    delegate: objc.Id,
    _: objc.SEL,
    _: objc.Id,
) callconv(.c) void {
    delegateBackend(delegate).recordFocus(false);
}

const Selectors = struct {
    shared_application: objc.SEL,
    set_activation_policy: objc.SEL,
    alloc: objc.SEL,
    object_init: objc.SEL,
    init_with_content_rect: objc.SEL,
    set_delegate: objc.SEL,
    set_released_when_closed: objc.SEL,
    set_title: objc.SEL,
    set_content_min_size: objc.SEL,
    backing_scale_factor: objc.SEL,
    perform_miniaturize: objc.SEL,
    zoom: objc.SEL,
    is_zoomed: objc.SEL,
    mouse_location_outside_of_event_stream: objc.SEL,
    make_key_and_order_front: objc.SEL,
    next_event: objc.SEL,
    send_event: objc.SEL,
    event_type: objc.SEL,
    key_code: objc.SEL,
    modifier_flags: objc.SEL,
    is_a_repeat: objc.SEL,
    button_number: objc.SEL,
    location_in_window: objc.SEL,
    scrolling_delta_x: objc.SEL,
    scrolling_delta_y: objc.SEL,
    characters: objc.SEL,
    utf8_string: objc.SEL,
    general_pasteboard: objc.SEL,
    string_for_type: objc.SEL,
    clear_contents: objc.SEL,
    set_string_for_type: objc.SEL,
    distant_past: objc.SEL,
    close: objc.SEL,
    content_view: objc.SEL,
    frame: objc.SEL,
    set_wants_layer: objc.SEL,
    layer: objc.SEL,
    set_contents: objc.SEL,
    set_contents_scale: objc.SEL,
    finish_launching: objc.SEL,
    init_with_utf8: objc.SEL,
    arrow_cursor: objc.SEL,
    resize_up_down_cursor: objc.SEL,
    resize_left_right_cursor: objc.SEL,
    set_cursor: objc.SEL,

    fn init() Selectors {
        return .{
            .shared_application = objc.selector("sharedApplication"),
            .set_activation_policy = objc.selector("setActivationPolicy:"),
            .alloc = objc.selector("alloc"),
            .object_init = objc.selector("init"),
            .init_with_content_rect = objc.selector("initWithContentRect:styleMask:backing:defer:"),
            .set_delegate = objc.selector("setDelegate:"),
            .set_released_when_closed = objc.selector("setReleasedWhenClosed:"),
            .set_title = objc.selector("setTitle:"),
            .set_content_min_size = objc.selector("setContentMinSize:"),
            .backing_scale_factor = objc.selector("backingScaleFactor"),
            .perform_miniaturize = objc.selector("performMiniaturize:"),
            .zoom = objc.selector("zoom:"),
            .is_zoomed = objc.selector("isZoomed"),
            .mouse_location_outside_of_event_stream = objc.selector("mouseLocationOutsideOfEventStream"),
            .make_key_and_order_front = objc.selector("makeKeyAndOrderFront:"),
            .next_event = objc.selector("nextEventMatchingMask:untilDate:inMode:dequeue:"),
            .send_event = objc.selector("sendEvent:"),
            .event_type = objc.selector("type"),
            .key_code = objc.selector("keyCode"),
            .modifier_flags = objc.selector("modifierFlags"),
            .is_a_repeat = objc.selector("isARepeat"),
            .button_number = objc.selector("buttonNumber"),
            .location_in_window = objc.selector("locationInWindow"),
            .scrolling_delta_x = objc.selector("scrollingDeltaX"),
            .scrolling_delta_y = objc.selector("scrollingDeltaY"),
            .characters = objc.selector("characters"),
            .utf8_string = objc.selector("UTF8String"),
            .general_pasteboard = objc.selector("generalPasteboard"),
            .string_for_type = objc.selector("stringForType:"),
            .clear_contents = objc.selector("clearContents"),
            .set_string_for_type = objc.selector("setString:forType:"),
            .distant_past = objc.selector("distantPast"),
            .close = objc.selector("close"),
            .content_view = objc.selector("contentView"),
            .frame = objc.selector("frame"),
            .set_wants_layer = objc.selector("setWantsLayer:"),
            .layer = objc.selector("layer"),
            .set_contents = objc.selector("setContents:"),
            .set_contents_scale = objc.selector("setContentsScale:"),
            .finish_launching = objc.selector("finishLaunching"),
            .init_with_utf8 = objc.selector("initWithUTF8String:"),
            .arrow_cursor = objc.selector("arrowCursor"),
            .resize_up_down_cursor = objc.selector("resizeUpDownCursor"),
            .resize_left_right_cursor = objc.selector("resizeLeftRightCursor"),
            .set_cursor = objc.selector("set"),
        };
    }
};

const Lifecycle = struct {
    should_close: bool = false,
    focused: bool = false,
    pending_focus: ?bool = null,
    pending_close: bool = false,
    polling: bool = false,
};

const CocoaStorage = struct {
    clipboard_capacity: clipboard.Capacity,
    clipboard_source: clipboard.Source,
    gamepads: gamepad.State,
    input: input.State,
    events: event_module.Queue,
    frames: FrameStorage,

    fn init(allocator: std.mem.Allocator, config: WindowConfig) CreateError!CocoaStorage {
        const clipboard_capacity = clipboard.Capacity.derive(config.clipboard) catch
            return error.InvalidCapacity;
        const event_capacity = event_module.Capacity.derive(config.events) catch
            return error.InvalidCapacity;
        const input_capacity = input.Capacity.derive(config.input) catch
            return error.InvalidCapacity;
        const gamepad_capacity = gamepad.Capacity.derive(config.gamepads) catch
            return error.InvalidCapacity;
        const presentation_capacity = presentation.Capacity.derive(config.presentation) catch
            return error.InvalidCapacity;
        var frames = FrameStorage.init(allocator, presentation_capacity) catch
            return error.OutOfMemory;
        errdefer frames.deinit();
        var events = event_module.Queue.init(allocator, event_capacity) catch
            return error.OutOfMemory;
        errdefer events.deinit();
        var input_state = input.State.init(allocator, input_capacity) catch
            return error.OutOfMemory;
        errdefer input_state.deinit();
        var gamepad_state = gamepad.State.init(allocator, gamepad_capacity) catch
            return error.OutOfMemory;
        errdefer gamepad_state.deinit();
        const clipboard_source = clipboard.Source.init(allocator, clipboard_capacity) catch
            return error.OutOfMemory;
        return .{
            .clipboard_capacity = clipboard_capacity,
            .clipboard_source = clipboard_source,
            .gamepads = gamepad_state,
            .input = input_state,
            .events = events,
            .frames = frames,
        };
    }

    fn deinit(self: *CocoaStorage) void {
        self.clipboard_source.deinit();
        self.gamepads.deinit();
        self.input.deinit();
        self.events.deinit();
        self.frames.deinit();
        self.* = undefined;
    }
};

const NativeWindow = struct {
    app: objc.Id,
    window: objc.Id,
    delegate: objc.Id,
    layer: objc.Id,

    fn init(sels: Selectors, config: WindowConfig) CreateError!NativeWindow {
        const delegate_class = try windowDelegateClass();
        const delegate_alloc = objc.send(?objc.Id, @ptrCast(delegate_class), sels.alloc, .{}) orelse
            return error.WindowCreationFailed;
        const delegate = objc.send(?objc.Id, delegate_alloc, sels.object_init, .{}) orelse
            return error.WindowCreationFailed;
        errdefer objc.release(delegate);

        const app_class = try cls("NSApplication");
        const app = objc.send(objc.Id, app_class, sels.shared_application, .{});
        objc.send(void, app, sels.set_activation_policy, .{@as(foundation.NSInteger, 0)});

        const window_class = try cls("NSWindow");
        const allocated = objc.send(objc.Id, window_class, sels.alloc, .{});
        const rect = cocoa.NSRect{
            .origin = .{ .x = 100, .y = 100 },
            .size = .{
                .width = @floatFromInt(config.width),
                .height = @floatFromInt(config.height),
            },
        };
        const window = objc.send(?objc.Id, allocated, sels.init_with_content_rect, .{
            rect,
            windowStyle(config.resizable),
            @as(foundation.NSUInteger, 2),
            objc.boolean(false),
        }) orelse return error.WindowCreationFailed;
        errdefer releaseWindow(window, sels);
        objc.send(void, window, sels.set_released_when_closed, .{objc.boolean(false)});

        const title = retainedString(sels, config.title) orelse
            return error.WindowCreationFailed;
        defer objc.release(title);
        objc.send(void, window, sels.set_title, .{title});
        const content_view = objc.send(objc.Id, window, sels.content_view, .{});
        objc.send(void, content_view, sels.set_wants_layer, .{objc.boolean(true)});
        return .{
            .app = app,
            .window = window,
            .delegate = delegate,
            .layer = objc.send(objc.Id, content_view, sels.layer, .{}),
        };
    }

    fn deinit(self: NativeWindow, sels: Selectors) void {
        releaseWindow(self.window, sels);
        objc.release(self.delegate);
    }
};

fn windowStyle(resizable: bool) foundation.NSUInteger {
    var style = cocoa.NSWindowStyleMaskTitled |
        cocoa.NSWindowStyleMaskClosable |
        cocoa.NSWindowStyleMaskMiniaturizable;
    if (resizable) style |= cocoa.NSWindowStyleMaskResizable;
    return style;
}

fn releaseWindow(window: objc.Id, sels: Selectors) void {
    objc.send(void, window, sels.close, .{});
    objc.release(window);
}

fn retainedString(sels: Selectors, bytes: [:0]const u8) ?objc.Id {
    const string_class = objc.class("NSString") orelse return null;
    const allocated = objc.send(?objc.Id, string_class, sels.alloc, .{}) orelse return null;
    return objc.send(?objc.Id, allocated, sels.init_with_utf8, .{bytes.ptr});
}

pub const CocoaBackend = struct {
    ids: @import("frame.zig").Ids = .{},
    empty_region_fallback_count: u64 = 0,
    app: objc.Id,
    window: objc.Id,
    delegate: objc.Id,
    layer: objc.Id,
    sels: Selectors,
    lifecycle: Lifecycle,
    width: u32,
    height: u32,
    clipboard_capacity: clipboard.Capacity,
    clipboard_source: clipboard.Source,
    gamepads: gamepad.State,
    input: input.State,
    events: event_module.Queue,
    frames: FrameStorage,

    pub fn init(
        self: *CocoaBackend,
        allocator: std.mem.Allocator,
        config: WindowConfig,
    ) CreateError!void {
        if (config.backend != .auto) return error.UnsupportedPlatform;
        var autorelease_pool = objc.AutoreleasePool.init();
        defer autorelease_pool.deinit();
        const sels = Selectors.init();
        var storage = try CocoaStorage.init(allocator, config);
        errdefer storage.deinit();
        const native = try NativeWindow.init(sels, config);
        errdefer native.deinit(sels);

        self.* = .{
            .app = native.app,
            .window = native.window,
            .delegate = native.delegate,
            .layer = native.layer,
            .sels = sels,
            .lifecycle = .{},
            .width = config.width,
            .height = config.height,
            .clipboard_capacity = storage.clipboard_capacity,
            .clipboard_source = storage.clipboard_source,
            .gamepads = storage.gamepads,
            .input = storage.input,
            .events = storage.events,
            .frames = storage.frames,
        };
        const backend_set = objc.setInstancePointer(
            native.delegate,
            window_delegate_backend_ivar,
            @ptrCast(self),
        );
        if (!backend_set) {
            return error.WindowCreationFailed;
        }
        objc.send(void, native.window, sels.set_delegate, .{native.delegate});

        if (config.visible) {
            objc.send(void, native.window, sels.make_key_and_order_front, .{objc.nil});
        }
        objc.send(void, native.app, sels.finish_launching, .{});
    }

    pub fn deinit(self: *CocoaBackend) void {
        objc.send(void, self.window, self.sels.set_delegate, .{objc.nil});
        _ = objc.setInstancePointer(self.delegate, window_delegate_backend_ivar, null);
        objc.send(void, self.layer, self.sels.set_contents, .{objc.nil});
        self.frames.deinit();
        objc.send(void, self.window, self.sels.close, .{});
        objc.release(self.window);
        objc.release(self.delegate);
        self.gamepads.deinit();
        self.input.deinit();
        self.events.deinit();
        self.clipboard_source.deinit();
        self.* = undefined;
    }

    pub fn pollEvents(self: *CocoaBackend) PollError!EventIterator {
        var autorelease_pool = objc.AutoreleasePool.init();
        defer autorelease_pool.deinit();
        self.input.beginPoll();
        self.gamepads.poll();
        self.events.beginPoll();
        self.flushPendingLifecycle();
        self.lifecycle.polling = true;
        defer self.lifecycle.polling = false;

        const ns_date_cls = cls("NSDate") catch return self.events.iterator();
        const distant_past = objc.send(objc.Id, ns_date_cls, self.sels.distant_past, .{});

        const mode = foundation.stringFromBytes("kCFRunLoopDefaultMode") orelse
            return self.events.iterator();
        defer objc.release(mode);

        while (true) {
            const ns_event = objc.send(
                ?objc.Id,
                self.app,
                self.sels.next_event,
                .{
                    cocoa.NSAnyEventMask,
                    distant_past,
                    mode,
                    objc.boolean(true),
                },
            ) orelse break;

            self.translateEvent(ns_event);

            objc.send(void, self.app, self.sels.send_event, .{ns_event});
        }

        self.syncContentSize();

        return self.events.iterator();
    }

    pub fn shouldClose(self: *const CocoaBackend) bool {
        return self.lifecycle.should_close;
    }

    fn recordClose(self: *CocoaBackend) void {
        if (self.lifecycle.should_close) return;
        self.lifecycle.should_close = true;
        if (self.lifecycle.polling) {
            self.pushEvent(.window_close);
        } else {
            self.lifecycle.pending_close = true;
        }
    }

    fn recordFocus(self: *CocoaBackend, focused: bool) void {
        if (self.lifecycle.focused == focused) return;
        self.lifecycle.focused = focused;
        if (self.lifecycle.polling) {
            self.pushEvent(.{ .window_focus = .{ .focused = focused } });
        } else {
            self.lifecycle.pending_focus = focused;
        }
    }

    fn flushPendingLifecycle(self: *CocoaBackend) void {
        std.debug.assert(!self.lifecycle.polling);
        if (self.lifecycle.pending_focus) |focused| {
            self.lifecycle.pending_focus = null;
            self.pushEvent(.{ .window_focus = .{ .focused = focused } });
        }
        if (self.lifecycle.pending_close) {
            self.lifecycle.pending_close = false;
            self.pushEvent(.window_close);
        }
    }

    pub fn eventSource(_: *const CocoaBackend) ?@import("window.zig").EventSource {
        return null;
    }

    pub fn getSize(self: *const CocoaBackend) Size {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn inputState(self: *const CocoaBackend) *const input.State {
        return &self.input;
    }

    pub fn inputStateMut(self: *CocoaBackend) *input.State {
        return &self.input;
    }

    pub fn modifiers(self: *const CocoaBackend) Modifier {
        return self.input.modifiers();
    }

    pub fn gamepadState(self: *const CocoaBackend) *const gamepad.State {
        return &self.gamepads;
    }

    pub fn setTitle(self: *CocoaBackend, title: [:0]const u8) void {
        const title_str = retainedString(self.sels, title) orelse return;
        defer objc.release(title_str);
        objc.send(void, self.window, self.sels.set_title, .{title_str});
    }

    pub fn setMinSize(self: *CocoaBackend, width: u32, height: u32) void {
        objc.send(void, self.window, self.sels.set_content_min_size, .{cocoa.NSSize{
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        }});
    }

    pub fn setCursor(self: *CocoaBackend, shape: CursorShape) void {
        const ns_cursor_cls = cls("NSCursor") catch return;
        const cursor = objc.send(objc.Id, ns_cursor_cls, self.cursorSelector(shape), .{});
        objc.send(void, cursor, self.sels.set_cursor, .{});
    }

    pub fn isCursorOnScreen(self: *const CocoaBackend) bool {
        const loc = objc.send(cocoa.NSPoint, self.window, self.sels.mouse_location_outside_of_event_stream, .{});
        return pointInsideSize(loc, self.width, self.height);
    }

    pub fn minimize(self: *CocoaBackend) void {
        objc.send(void, self.window, self.sels.perform_miniaturize, .{objc.nil});
    }

    pub fn maximize(self: *CocoaBackend) void {
        if (!self.isMaximized()) objc.send(void, self.window, self.sels.zoom, .{objc.nil});
    }

    pub fn restore(self: *CocoaBackend) void {
        if (self.isMaximized()) objc.send(void, self.window, self.sels.zoom, .{objc.nil});
    }

    pub fn isMaximized(self: *const CocoaBackend) bool {
        return objc.isTrue(objc.send(objc.BOOL, self.window, self.sels.is_zoomed, .{}));
    }

    pub fn getClipboardTextAlloc(self: *CocoaBackend, allocator: std.mem.Allocator) !?[]u8 {
        const pasteboard_cls = cls("NSPasteboard") catch return null;
        const pasteboard = objc.send(objc.Id, pasteboard_cls, self.sels.general_pasteboard, .{});
        const type_string = foundation.stringFromBytes(std.mem.span(pasteboard_string_type)) orelse
            return null;
        defer objc.release(type_string);
        const string = objc.send(?objc.Id, pasteboard, self.sels.string_for_type, .{type_string}) orelse return null;
        const raw = objc.send(?[*:0]const u8, string, self.sels.utf8_string, .{}) orelse return null;
        const text = std.mem.span(raw);
        if (text.len > self.clipboard_capacity.received_text_byte_count) {
            return error.TransferTooLarge;
        }
        return try allocator.dupe(u8, text);
    }

    pub fn setClipboardText(self: *CocoaBackend, text: []const u8) clipboard.PublishError!void {
        try self.clipboard_source.replace(text);
        const publication = clipboardPublication(&self.clipboard_source);
        var autorelease_pool = objc.AutoreleasePool.init();
        defer autorelease_pool.deinit();
        const pasteboard_cls = cls("NSPasteboard") catch return error.Unavailable;
        const pasteboard = objc.send(objc.Id, pasteboard_cls, self.sels.general_pasteboard, .{});
        const type_string = foundation.stringFromBytes(publication.pasteboard_type) orelse
            return error.Unexpected;
        defer objc.release(type_string);
        const string = foundation.stringFromBytes(publication.text) orelse
            return error.Unexpected;
        defer objc.release(string);
        _ = objc.send(foundation.NSInteger, pasteboard, self.sels.clear_contents, .{});
        const accepted = objc.send(objc.BOOL, pasteboard, self.sels.set_string_for_type, .{
            string,
            type_string,
        });
        if (!objc.isTrue(accepted)) return error.Unexpected;
    }

    pub fn clipboardStatus(self: *const CocoaBackend) clipboard.Status {
        return self.clipboard_source.status();
    }

    pub fn x11StorageStatus(_: *const CocoaBackend) sys.x11.Status {
        return .{};
    }

    pub fn waylandDmabuf(_: *CocoaBackend) ?@import("wayland/root.zig").DmabufSurface {
        return null;
    }

    pub fn waylandStorageStatus(_: *const CocoaBackend) WaylandStorageStatus {
        return .{};
    }

    pub fn nextPresentationOutcome(_: *CocoaBackend) ?PresentationOutcome {
        return null;
    }

    pub fn presentationStatus(_: *const CocoaBackend) PresentationStatus {
        return .unavailable;
    }

    pub fn presentationStorageStatus(self: *const CocoaBackend) PresentationStorageStatus {
        return .{
            .frame_capacity_rejection_count = self.frames.capacity_rejection_count,
            .empty_region_fallback_count = self.empty_region_fallback_count,
        };
    }

    pub fn droppedEventCount(self: *const CocoaBackend) u64 {
        return self.events.droppedEventCount();
    }

    pub fn getFramebufferSize(self: *const CocoaBackend) Size {
        const scale = self.getContentScale();
        return .{
            .width = scaledToU32(self.width, scale.x),
            .height = scaledToU32(self.height, scale.y),
        };
    }

    pub fn nativeSurface(self: *CocoaBackend) surface.Surface {
        const scale = self.getContentScale();
        const framebuffer = self.getFramebufferSize();
        return .{ .cocoa = .{
            .app = self.app,
            .window = self.window,
            .layer = self.layer,
            .extent = surface.extentFromSizes(
                self.width,
                self.height,
                framebuffer.width,
                framebuffer.height,
                scale.x,
                scale.y,
            ),
        } };
    }

    pub fn presentRgba8(
        self: *CocoaBackend,
        rgba8: []const u8,
        width: u32,
        height: u32,
    ) PresentError!void {
        _ = try self.presentRgba8Frame(rgba8, width, height, &.{});
    }

    pub fn presentRgba8Region(
        self: *CocoaBackend,
        rgba8: []const u8,
        width: u32,
        height: u32,
        region: PresentRegion,
    ) PresentError!void {
        const byte_count = presentation.rgba8ByteCount(width, height) orelse return error.UnsupportedFormat;
        if (rgba8.len < byte_count) return error.UnsupportedFormat;
        const active_region = region.clamped(width, height);
        if (active_region.pixelCount() == 0) return;
        _ = try self.presentRgba8Frame(rgba8, width, height, &.{active_region});
    }

    pub fn presentRgba8Frame(
        self: *CocoaBackend,
        rgba8: []const u8,
        width: u32,
        height: u32,
        regions: []const PresentRegion,
    ) PresentError!u64 {
        const frame = try @import("frame.zig").Frame.init(rgba8, width, height, regions);
        const id = try self.ids.reserve();
        const next = try self.frames.prepare(frame.byte_count);
        @memcpy(next.pixels, rgba8[0..frame.byte_count]);
        try self.setLayerRgba8(next.pixels, width, height);
        self.frames.commit(next.index, width, height);
        self.ids.accept(id);
        if (frame.empty_fallback) self.empty_region_fallback_count +|= 1;
        return id;
    }

    pub fn getContentScale(self: *const CocoaBackend) Scale {
        const scale: f32 = @floatCast(objc.send(coregraphics.CGFloat, self.window, self.sels.backing_scale_factor, .{}));
        const sanitized = sanitizeScale(scale);
        return .{ .x = sanitized, .y = sanitized };
    }

    fn cursorSelector(self: *const CocoaBackend, shape: CursorShape) objc.SEL {
        return switch (shape) {
            .default => self.sels.arrow_cursor,
            .resize_ns => self.sels.resize_up_down_cursor,
            .resize_ew => self.sels.resize_left_right_cursor,
            .resize_nwse, .resize_nesw => self.sels.arrow_cursor,
        };
    }

    fn translateEvent(self: *CocoaBackend, ns_event: objc.Id) void {
        const event_type = objc.send(foundation.NSUInteger, ns_event, self.sels.event_type, .{});

        switch (event_type) {
            cocoa.NSEventTypeKeyDown => self.translateKeyDown(ns_event),
            cocoa.NSEventTypeKeyUp => self.translateKeyUp(ns_event),
            cocoa.NSEventTypeFlagsChanged => self.translateModifier(ns_event),
            cocoa.NSEventTypeLeftMouseDown,
            cocoa.NSEventTypeRightMouseDown,
            cocoa.NSEventTypeOtherMouseDown,
            => self.translateMouseButton(ns_event, true),
            cocoa.NSEventTypeLeftMouseUp,
            cocoa.NSEventTypeRightMouseUp,
            cocoa.NSEventTypeOtherMouseUp,
            => self.translateMouseButton(ns_event, false),
            cocoa.NSEventTypeMouseMoved,
            cocoa.NSEventTypeLeftMouseDragged,
            cocoa.NSEventTypeRightMouseDragged,
            cocoa.NSEventTypeOtherMouseDragged,
            => {
                const loc = objc.send(cocoa.NSPoint, ns_event, self.sels.location_in_window, .{});
                self.input.moveMouse(@intFromFloat(loc.x), @intFromFloat(loc.y));
                self.pushEvent(.{ .mouse_move = .{
                    .x = @intFromFloat(loc.x),
                    .y = @intFromFloat(loc.y),
                } });
            },
            cocoa.NSEventTypeScrollWheel => {
                const loc = objc.send(cocoa.NSPoint, ns_event, self.sels.location_in_window, .{});
                const mods = objc.send(foundation.NSUInteger, ns_event, self.sels.modifier_flags, .{});
                const delta_x: f32 = @floatCast(objc.send(coregraphics.CGFloat, ns_event, self.sels.scrolling_delta_x, .{}));
                const delta_y: f32 = @floatCast(objc.send(coregraphics.CGFloat, ns_event, self.sels.scrolling_delta_y, .{}));
                self.input.setMousePosition(@intFromFloat(loc.x), @intFromFloat(loc.y));
                self.input.addMouseWheel(delta_x, delta_y);
                self.pushEvent(.{ .mouse_wheel = .{
                    .x = @intFromFloat(loc.x),
                    .y = @intFromFloat(loc.y),
                    .delta_x = delta_x,
                    .delta_y = delta_y,
                    .modifiers = cocoaModsToModifier(mods),
                } });
            },
            else => {},
        }
    }

    fn translateMouseButton(self: *CocoaBackend, ns_event: objc.Id, pressed: bool) void {
        const location = objc.send(
            cocoa.NSPoint,
            ns_event,
            self.sels.location_in_window,
            .{},
        );
        const flags = objc.send(
            foundation.NSUInteger,
            ns_event,
            self.sels.modifier_flags,
            .{},
        );
        const number = objc.send(
            foundation.NSInteger,
            ns_event,
            self.sels.button_number,
            .{},
        );
        const button = cocoaMouseButton(number) orelse return;
        const event: MouseButtonEvent = .{
            .button = button,
            .x = @as(i32, @intFromFloat(location.x)),
            .y = @as(i32, @intFromFloat(location.y)),
            .modifiers = cocoaModsToModifier(flags),
        };
        self.input.setMousePosition(event.x, event.y);
        if (pressed) {
            self.input.pressMouse(button);
            self.pushEvent(.{ .mouse_press = event });
        } else {
            self.input.releaseMouse(button);
            self.pushEvent(.{ .mouse_release = event });
        }
    }

    fn translateKeyDown(self: *CocoaBackend, ns_event: objc.Id) void {
        const keycode = objc.send(u16, ns_event, self.sels.key_code, .{});
        const flags = objc.send(
            foundation.NSUInteger,
            ns_event,
            self.sels.modifier_flags,
            .{},
        );
        const repeated = objc.isTrue(objc.send(
            objc.BOOL,
            ns_event,
            self.sels.is_a_repeat,
            .{},
        ));
        const active_modifiers = cocoaModsToModifier(flags);
        self.recordKey(macKeycodeToKey(keycode), active_modifiers, true, repeated);
        self.pushTextInput(ns_event, active_modifiers);
    }

    fn translateKeyUp(self: *CocoaBackend, ns_event: objc.Id) void {
        const keycode = objc.send(u16, ns_event, self.sels.key_code, .{});
        const flags = objc.send(
            foundation.NSUInteger,
            ns_event,
            self.sels.modifier_flags,
            .{},
        );
        self.recordKey(macKeycodeToKey(keycode), cocoaModsToModifier(flags), false, false);
    }

    fn translateModifier(self: *CocoaBackend, ns_event: objc.Id) void {
        const keycode = objc.send(u16, ns_event, self.sels.key_code, .{});
        const flags = objc.send(
            foundation.NSUInteger,
            ns_event,
            self.sels.modifier_flags,
            .{},
        );
        const key = macKeycodeToKey(keycode);
        const key_flag = cocoaModifierFlag(key) orelse return;
        const pressed = cocoaModifierPressed(self.input.isKeyDown(key), key_flag, flags);
        self.recordKey(key, cocoaModsToModifier(flags), pressed, false);
    }

    fn recordKey(
        self: *CocoaBackend,
        key: Key,
        active_modifiers: Modifier,
        pressed: bool,
        repeated: bool,
    ) void {
        if (pressed) {
            self.input.pressKey(key);
            self.pushEvent(.{ .key_press = .{
                .key = key,
                .modifiers = active_modifiers,
                .repeated = repeated,
            } });
        } else {
            self.input.releaseKey(key);
            self.pushEvent(.{ .key_release = .{
                .key = key,
                .modifiers = active_modifiers,
            } });
        }
    }

    fn pushEvent(self: *CocoaBackend, event: Event) void {
        _ = self.events.push(event);
    }

    fn pushTextInput(self: *CocoaBackend, ns_event: objc.Id, active_modifiers: Modifier) void {
        const string = objc.send(?objc.Id, ns_event, self.sels.characters, .{}) orelse return;
        const raw = objc.send(?[*:0]const u8, string, self.sels.utf8_string, .{}) orelse return;
        if (Event.textInput(std.mem.span(raw), active_modifiers)) |event| {
            _ = self.input.pushTextInput(event.text_input.text());
            self.pushEvent(event);
        }
    }

    fn syncContentSize(self: *CocoaBackend) void {
        const view = objc.send(objc.Id, self.window, self.sels.content_view, .{});
        const frame = objc.send(cocoa.NSRect, view, self.sels.frame, .{});
        const size = frameToSize(frame);
        if (size.width != self.width or size.height != self.height) {
            self.width = size.width;
            self.height = size.height;
            self.pushEvent(.{ .window_resize = .{ .width = size.width, .height = size.height } });
        }
    }

    fn setLayerRgba8(self: *CocoaBackend, pixels: []u8, width: u32, height: u32) PresentError!void {
        const color_space = coregraphics.createDeviceRgbColorSpace() orelse return error.Unexpected;
        defer coregraphics.releaseColorSpace(color_space);

        const provider = coregraphics.createDataProvider(pixels) orelse return error.Unexpected;
        defer coregraphics.releaseDataProvider(provider);

        const image = coregraphics.createRgba8Image(width, height, @as(usize, width) * 4, color_space, provider) orelse return error.Unexpected;
        defer coregraphics.releaseImage(image);

        objc.send(void, self.layer, self.sels.set_contents_scale, .{layerContentsScale(width, self.width)});
        objc.send(void, self.layer, self.sels.set_contents, .{@as(objc.Id, @ptrCast(image))});
    }
};

const PreparedFrame = struct {
    index: usize,
    pixels: []u8,
};

const FrameStorage = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    slot_byte_count: usize,
    active_index: ?usize = null,
    width: u32 = 0,
    height: u32 = 0,
    capacity_rejection_count: u64 = 0,

    fn init(
        allocator: std.mem.Allocator,
        capacity: presentation.Capacity,
    ) std.mem.Allocator.Error!FrameStorage {
        std.debug.assert(capacity.cocoa_frame_slot_count == 2);
        std.debug.assert(
            capacity.cocoa_frame_storage_bytes / capacity.cocoa_frame_slot_count ==
                capacity.retained_frame_byte_count,
        );
        return .{
            .allocator = allocator,
            .bytes = try allocator.alloc(u8, capacity.cocoa_frame_storage_bytes),
            .slot_byte_count = capacity.retained_frame_byte_count,
        };
    }

    fn deinit(self: *FrameStorage) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    fn prepare(self: *FrameStorage, byte_count: usize) error{CapacityExceeded}!PreparedFrame {
        if (byte_count > self.slot_byte_count) {
            self.capacity_rejection_count +|= 1;
            return error.CapacityExceeded;
        }
        const index = if (self.active_index) |active_index| active_index ^ 1 else 0;
        return .{ .index = index, .pixels = self.slot(index)[0..byte_count] };
    }

    fn active(self: *FrameStorage, byte_count: usize) []const u8 {
        std.debug.assert(byte_count <= self.slot_byte_count);
        return self.slot(self.active_index.?)[0..byte_count];
    }

    fn matches(self: *const FrameStorage, width: u32, height: u32) bool {
        return self.active_index != null and self.width == width and self.height == height;
    }

    fn commit(self: *FrameStorage, index: usize, width: u32, height: u32) void {
        std.debug.assert(index < 2);
        self.active_index = index;
        self.width = width;
        self.height = height;
    }

    fn slot(self: *FrameStorage, index: usize) []u8 {
        std.debug.assert(index < 2);
        const start = index * self.slot_byte_count;
        return self.bytes[start..][0..self.slot_byte_count];
    }
};

const pasteboard_string_type: [*:0]const u8 = "public.utf8-plain-text";

const ClipboardPublication = struct {
    pasteboard_type: []const u8,
    text: []const u8,
};

fn clipboardPublication(source: *const clipboard.Source) ClipboardPublication {
    return .{
        .pasteboard_type = std.mem.span(pasteboard_string_type),
        .text = source.text(),
    };
}

fn frameToSize(frame: cocoa.NSRect) Size {
    return .{
        .width = floatToU32(frame.size.width),
        .height = floatToU32(frame.size.height),
    };
}

fn sanitizeScale(scale: f32) f32 {
    if (!std.math.isFinite(scale) or scale <= 0) return 1;
    return scale;
}

fn layerContentsScale(pixel_width: u32, logical_width: u32) coregraphics.CGFloat {
    if (pixel_width == 0 or logical_width == 0) return 1;
    return @as(coregraphics.CGFloat, @floatFromInt(pixel_width)) / @as(coregraphics.CGFloat, @floatFromInt(logical_width));
}

fn scaledToU32(value: u32, scale: f32) u32 {
    return floatToU32(@as(f64, @floatFromInt(value)) * @as(f64, sanitizeScale(scale)));
}

fn copyRgba8Region(dst: []u8, src: []const u8, frame_width: u32, region: PresentRegion) void {
    const row_bytes = @as(usize, region.width) * 4;
    var row: u32 = 0;
    while (row < region.height) : (row += 1) {
        const offset = (@as(usize, region.y + row) * @as(usize, frame_width) + @as(usize, region.x)) * 4;
        @memcpy(dst[offset..][0..row_bytes], src[offset..][0..row_bytes]);
    }
}

fn floatToU32(value: f64) u32 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    if (value >= @as(f64, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
    return @intFromFloat(@round(value));
}

fn pointInsideSize(point: cocoa.NSPoint, width: u32, height: u32) bool {
    return point.x >= 0 and
        point.y >= 0 and
        point.x < @as(coregraphics.CGFloat, @floatFromInt(width)) and
        point.y < @as(coregraphics.CGFloat, @floatFromInt(height));
}

fn macKeycodeToKey(keycode: u16) Key {
    return switch (keycode) {
        0x00 => .a,
        0x01 => .s,
        0x02 => .d,
        0x03 => .f,
        0x04 => .h,
        0x05 => .g,
        0x06 => .z,
        0x07 => .x,
        0x08 => .c,
        0x09 => .v,
        0x0B => .b,
        0x0C => .q,
        0x0D => .w,
        0x0E => .e,
        0x0F => .r,
        0x10 => .y,
        0x11 => .t,
        0x12 => .@"1",
        0x13 => .@"2",
        0x14 => .@"3",
        0x15 => .@"4",
        0x16 => .@"6",
        0x17 => .@"5",
        0x18 => .equal,
        0x19 => .@"9",
        0x1A => .@"7",
        0x1B => .minus,
        0x1C => .@"8",
        0x1D => .@"0",
        0x1E => .right_bracket,
        0x1F => .o,
        0x20 => .u,
        0x21 => .left_bracket,
        0x22 => .i,
        0x23 => .p,
        0x24 => .enter,
        0x25 => .l,
        0x26 => .j,
        0x27 => .apostrophe,
        0x28 => .k,
        0x29 => .semicolon,
        0x2A => .backslash,
        0x2B => .comma,
        0x2C => .slash,
        0x2D => .n,
        0x2E => .m,
        0x2F => .period,
        0x30 => .tab,
        0x31 => .space,
        0x32 => .grave,
        0x33 => .backspace,
        0x35 => .escape,
        0x36 => .right_super,
        0x37 => .left_super,
        0x38 => .left_shift,
        0x39 => .caps_lock,
        0x3A => .left_alt,
        0x3B => .left_ctrl,
        0x3C => .right_shift,
        0x3D => .right_alt,
        0x3E => .right_ctrl,
        0x60 => .f5,
        0x61 => .f6,
        0x62 => .f7,
        0x63 => .f3,
        0x64 => .f8,
        0x65 => .f9,
        0x67 => .f11,
        0x6D => .f10,
        0x6F => .f12,
        0x72 => .insert,
        0x73 => .home,
        0x74 => .page_up,
        0x75 => .delete,
        0x76 => .f4,
        0x77 => .end,
        0x78 => .f2,
        0x79 => .page_down,
        0x7A => .f1,
        0x7B => .left,
        0x7C => .right,
        0x7D => .down,
        0x7E => .up,
        else => .unknown,
    };
}

fn cocoaModifierFlag(key: Key) ?foundation.NSUInteger {
    return switch (key) {
        .caps_lock => cocoa.NSEventModifierFlagCapsLock,
        .left_shift, .right_shift => cocoa.NSEventModifierFlagShift,
        .left_ctrl, .right_ctrl => cocoa.NSEventModifierFlagControl,
        .left_alt, .right_alt => cocoa.NSEventModifierFlagOption,
        .left_super, .right_super => cocoa.NSEventModifierFlagCommand,
        else => null,
    };
}

fn cocoaModifierPressed(
    key_down: bool,
    key_flag: foundation.NSUInteger,
    flags: foundation.NSUInteger,
) bool {
    return flags & key_flag != 0 and !key_down;
}

fn cocoaMouseButton(number: foundation.NSInteger) ?MouseButton {
    return switch (number) {
        0 => .left,
        1 => .right,
        2 => .middle,
        3 => .x1,
        4 => .x2,
        else => null,
    };
}

fn cocoaModsToModifier(flags: foundation.NSUInteger) Modifier {
    return .{
        .shift = (flags & cocoa.NSEventModifierFlagShift) != 0,
        .ctrl = (flags & cocoa.NSEventModifierFlagControl) != 0,
        .alt = (flags & cocoa.NSEventModifierFlagOption) != 0,
        .super = (flags & cocoa.NSEventModifierFlagCommand) != 0,
    };
}

test "Cocoa cursor screen check compares point to window size" {
    try std.testing.expect(pointInsideSize(.{ .x = 0, .y = 0 }, 10, 10));
    try std.testing.expect(pointInsideSize(.{ .x = 9.5, .y = 9.5 }, 10, 10));
    try std.testing.expect(!pointInsideSize(.{ .x = -0.5, .y = 0 }, 10, 10));
    try std.testing.expect(!pointInsideSize(.{ .x = 10, .y = 0 }, 10, 10));
    try std.testing.expect(!pointInsideSize(.{ .x = 0, .y = 10 }, 10, 10));
}

test "Cocoa modifier flags preserve side transitions and caps lock" {
    const shift = cocoa.NSEventModifierFlagShift;
    try std.testing.expectEqual(shift, cocoaModifierFlag(.left_shift).?);
    try std.testing.expectEqual(shift, cocoaModifierFlag(.right_shift).?);
    try std.testing.expectEqual(
        cocoa.NSEventModifierFlagCapsLock,
        cocoaModifierFlag(.caps_lock).?,
    );
    try std.testing.expect(cocoaModifierFlag(.a) == null);
    try std.testing.expect(cocoaModifierPressed(false, shift, shift));
    try std.testing.expect(!cocoaModifierPressed(true, shift, shift));
    try std.testing.expect(!cocoaModifierPressed(false, shift, 0));
    try std.testing.expectEqual(Key.caps_lock, macKeycodeToKey(0x39));
}

test "Cocoa mouse button numbers map the public domain" {
    try std.testing.expectEqual(MouseButton.left, cocoaMouseButton(0).?);
    try std.testing.expectEqual(MouseButton.right, cocoaMouseButton(1).?);
    try std.testing.expectEqual(MouseButton.middle, cocoaMouseButton(2).?);
    try std.testing.expectEqual(MouseButton.x1, cocoaMouseButton(3).?);
    try std.testing.expectEqual(MouseButton.x2, cocoaMouseButton(4).?);
    try std.testing.expect(cocoaMouseButton(-1) == null);
    try std.testing.expect(cocoaMouseButton(5) == null);
}

test "Cocoa backend declarations compile against Apple ABIs" {
    if (comptime builtin.os.tag != .macos) return;
    std.testing.refAllDecls(CocoaBackend);
}

test "Cocoa clipboard publication retains exact UTF-8 source bytes" {
    const capacity = try clipboard.Capacity.derive(.{
        .published_text_byte_count = 8,
    });
    var source = try clipboard.Source.init(std.testing.allocator, capacity);
    defer source.deinit();
    try source.replace("copy λ");
    const publication = clipboardPublication(&source);
    try std.testing.expectEqualStrings(
        "public.utf8-plain-text",
        publication.pasteboard_type,
    );
    try std.testing.expectEqualStrings("copy λ", publication.text);
    try std.testing.expectError(error.CapacityExceeded, source.replace("123456789"));
    try std.testing.expectEqualStrings("copy λ", clipboardPublication(&source).text);
}

test "Cocoa frame storage alternates exact bounded handoff slots" {
    const capacity = try presentation.Capacity.derive(.{
        .retained_frame_byte_count = 16,
    });
    var storage = try FrameStorage.init(std.testing.allocator, capacity);
    defer storage.deinit();

    const first = try storage.prepare(16);
    @memset(first.pixels, 0x31);
    storage.commit(first.index, 2, 2);
    try std.testing.expect(storage.matches(2, 2));
    const second = try storage.prepare(16);
    try std.testing.expect(first.pixels.ptr != second.pixels.ptr);
    @memcpy(second.pixels, storage.active(16));
    storage.commit(second.index, 2, 2);
    const third = try storage.prepare(16);
    try std.testing.expectEqual(first.pixels.ptr, third.pixels.ptr);
    try std.testing.expectError(error.CapacityExceeded, storage.prepare(17));
    try std.testing.expectEqual(@as(u64, 1), storage.capacity_rejection_count);
    storage.capacity_rejection_count = std.math.maxInt(u64);
    try std.testing.expectError(error.CapacityExceeded, storage.prepare(17));
    try std.testing.expectEqual(std.math.maxInt(u64), storage.capacity_rejection_count);
}

test "Cocoa frame storage reports acquisition failure" {
    const capacity = try presentation.Capacity.derive(.{
        .retained_frame_byte_count = 16,
    });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(
        error.OutOfMemory,
        FrameStorage.init(failing.allocator(), capacity),
    );
}

test "Cocoa region copy only mutates dirty rows" {
    const width: u32 = 4;
    const height: u32 = 3;
    var dst: [width * height * 4]u8 = @as([(width * height * 4)]u8, @splat(0x10));
    var src: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * width + x) * 4;
            src[offset + 0] = @intCast(40 + x);
            src[offset + 1] = @intCast(50 + y);
            src[offset + 2] = @intCast(60 + x + y);
            src[offset + 3] = 0xFF;
        }
    }

    const region = PresentRegion{ .x = 1, .y = 1, .width = 2, .height = 1 };
    copyRgba8Region(&dst, &src, width, region);

    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * width + x) * 4;
            const inside = x >= region.x and x < region.x + region.width and y >= region.y and y < region.y + region.height;
            if (inside) {
                try std.testing.expectEqualSlices(u8, src[offset..][0..4], dst[offset..][0..4]);
            } else {
                try std.testing.expectEqualSlices(u8, &[_]u8{ 0x10, 0x10, 0x10, 0x10 }, dst[offset..][0..4]);
            }
        }
    }
}
