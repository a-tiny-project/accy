const std = @import("std");
const sys = @import("sys");
const windowing = @import("windowing");

const window_chrome = sys.window_chrome;

pub const Config = struct {
    client_decorations: bool,
    vsync: bool,
    highdpi_framebuffer: bool,
};

pub const DpiScale = sys.desktop.DpiScale;

pub const DrawArea = sys.desktop.DrawArea;

pub const Pointer = sys.desktop.Pointer;

pub const PointerVector = sys.desktop.PointerVector;

pub fn backendName() []const u8 {
    return "windowing";
}

pub fn supportsClientChromeHitTest() bool {
    return false;
}

pub const State = struct {
    allocator: std.mem.Allocator,
    window: ?windowing.Window = null,
    polled_events: bool = false,
    poll_failed: bool = false,
    target_frame_ns: u64 = 0,
    last_present_ns: i128 = 0,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        self.close();
    }

    pub fn configure(_: *State, _: Config) void {}

    pub fn open(self: *State, width: i32, height: i32, title: [:0]const u8) void {
        self.last_present_ns = 0;
        self.window = windowing.Window.create(self.allocator, .{
            .title = title,
            .width = positiveI32ToU32(width),
            .height = positiveI32ToU32(height),
            .resizable = true,
            .visible = true,
        }) catch |err| std.debug.panic("native window creation failed: {s}", .{@errorName(err)});
    }

    pub fn close(self: *State) void {
        if (self.window) |*window| window.destroy();
        self.window = null;
        self.polled_events = false;
        self.poll_failed = false;
        self.last_present_ns = 0;
    }

    pub fn dpiScale(self: *State) DpiScale {
        const scale = self.activeWindow().getContentScale();
        return .{ .x = scale.x, .y = scale.y };
    }

    pub fn screenArea(self: *State) DrawArea {
        return self.activeWindow().getDrawArea();
    }

    pub fn renderArea(self: *State) ?DrawArea {
        return self.activeWindow().getFramebufferArea();
    }

    pub fn configureHitTest(
        _: *State,
        _: window_chrome.Mode,
        _: window_chrome.HitTestFn,
        _: ?*anyopaque,
    ) window_chrome.ConfigureResult {
        return .{ .unavailable = "windowing desktop does not expose client chrome hit testing" };
    }

    pub fn setHitTestChrome(_: *State, _: window_chrome.Mode) void {}

    pub fn scaleEvidence(self: *State) sys.desktop.WindowScaleEvidence {
        return self.activeWindow().getScaleEvidence();
    }

    pub fn setMinimumSize(self: *State, width: i32, height: i32) void {
        self.activeWindow().setMinSize(positiveI32ToU32(width), positiveI32ToU32(height));
    }

    pub fn disableExitKey(_: *State) void {}

    pub fn setTargetFps(self: *State, fps: i32) void {
        self.target_frame_ns = targetFrameNanosecondsForFps(fps);
        self.last_present_ns = 0;
    }

    pub fn setIconFromPng(_: *State, _: []const u8) !void {}

    pub fn pollInputEvents(self: *State) void {
        self.pollEvents();
    }

    pub fn shouldClose(self: *State) bool {
        if (!self.polled_events) self.pollEvents();
        self.polled_events = false;
        const window = self.window orelse return true;
        return self.poll_failed or window.shouldClose();
    }

    pub fn swapBuffers(_: *State) void {}

    pub fn presentRgba8(
        self: *State,
        rgba8: []const u8,
        width: i32,
        height: i32,
        draw_scale: f32,
    ) !void {
        _ = draw_scale;
        try self.activeWindow().presentRgba8(
            rgba8,
            try frameI32ToU32(width),
            try frameI32ToU32(height),
        );
        self.waitForTargetFrame();
    }

    pub fn presentRgba8Region(
        self: *State,
        rgba8: []const u8,
        width: i32,
        height: i32,
        region: windowing.PresentRegion,
        draw_scale: f32,
    ) !void {
        _ = draw_scale;
        try self.activeWindow().presentRgba8Region(
            rgba8,
            try frameI32ToU32(width),
            try frameI32ToU32(height),
            region,
        );
        self.waitForTargetFrame();
    }

    pub fn presentRgba8Frame(
        self: *State,
        rgba8: []const u8,
        width: i32,
        height: i32,
        regions: []const windowing.PresentRegion,
        draw_scale: f32,
    ) !u64 {
        _ = draw_scale;
        const id = try self.activeWindow().presentRgba8Frame(
            rgba8,
            try frameI32ToU32(width),
            try frameI32ToU32(height),
            regions,
        );
        self.waitForTargetFrame();
        return id;
    }

    pub fn clipboardTextAlloc(self: *State, allocator: std.mem.Allocator) ![]u8 {
        if (try self.activeWindow().getClipboardTextAlloc(allocator)) |text| return text;
        return try allocator.dupe(u8, "");
    }

    pub fn setClipboardText(self: *State, text: []const u8) !void {
        try self.activeWindow().setClipboardText(text);
    }

    pub fn setTitle(self: *State, title: [:0]const u8) void {
        self.activeWindow().setTitle(title);
    }

    pub fn setCursor(self: *State, shape: windowing.CursorShape) void {
        self.activeWindow().setCursor(shape);
    }

    pub fn minimize(self: *State) void {
        self.activeWindow().minimize();
    }

    pub fn toggleMaximize(self: *State) void {
        self.activeWindow().toggleMaximize();
    }

    pub fn pointerPosition(self: *State) Pointer {
        const point = self.activeWindow().getMousePosition();
        return .{ .x = @floatFromInt(point.x), .y = @floatFromInt(point.y) };
    }

    pub fn wheelMove(self: *State) PointerVector {
        const wheel = self.activeWindow().getMouseWheel();
        return .{ .x = wheel.x, .y = wheel.y };
    }

    pub fn pointerDelta(self: *State) PointerVector {
        const moved = self.activeWindow().getMouseDelta();
        return .{ .x = @floatFromInt(moved.x), .y = @floatFromInt(moved.y) };
    }

    pub fn cursorOnScreen(self: *State) bool {
        return self.activeWindow().isCursorOnScreen();
    }

    pub fn buttonPressed(self: *State, button: windowing.MouseButton) bool {
        return self.activeWindow().isMouseButtonPressed(button);
    }

    pub fn buttonDown(self: *State, button: windowing.MouseButton) bool {
        return self.activeWindow().isMouseButtonDown(button);
    }

    pub fn buttonReleased(self: *State, button: windowing.MouseButton) bool {
        return self.activeWindow().isMouseButtonReleased(button);
    }

    pub fn modifiers(self: *State) windowing.Modifier {
        return self.activeWindow().modifiers();
    }

    pub fn inputKeyDown(self: *State, key: windowing.Key) bool {
        return self.activeWindow().isKeyDown(key);
    }

    pub fn nextPressedInputKey(self: *State) ?windowing.Key {
        return self.activeWindow().nextPressedKey();
    }

    pub fn nextTextCodepoint(self: *State) ?u21 {
        return self.activeWindow().nextTextCodepoint();
    }

    fn pollEvents(self: *State) void {
        if (self.window) |*window| {
            _ = window.pollEvents() catch {
                self.poll_failed = true;
                return;
            };
        }
        self.polled_events = true;
    }

    fn activeWindow(self: *State) *windowing.Window {
        if (self.window) |*window| return window;
        @panic("windowing desktop window is not open");
    }

    fn waitForTargetFrame(self: *State) void {
        if (self.target_frame_ns == 0) return;

        var now = sys.time.nanoTimestamp();
        if (self.last_present_ns > 0) {
            const target_ns: i128 = @intCast(self.target_frame_ns);
            const next_present_ns = self.last_present_ns + target_ns;
            if (now < next_present_ns) {
                sys.time.sleepNanoseconds(@intCast(next_present_ns - now));
                now = sys.time.nanoTimestamp();
            }
        }
        self.last_present_ns = now;
    }
};

fn positiveI32ToU32(value: i32) u32 {
    return @intCast(@max(1, value));
}

fn frameI32ToU32(value: i32) !u32 {
    if (value <= 0) return error.InvalidFrame;
    return @intCast(value);
}

fn targetFrameNanosecondsForFps(fps: i32) u64 {
    if (fps <= 0) return 0;
    return @max(1, @divTrunc(@as(u64, std.time.ns_per_s), @as(u64, @intCast(fps))));
}

test "windowing desktop reports no client chrome hit testing" {
    try std.testing.expect(!supportsClientChromeHitTest());
    var state = State.init(std.testing.allocator);
    const result = state.configureHitTest(.native, undefined, null);
    switch (result) {
        .unavailable => |message| try std.testing.expectEqualStrings(
            "windowing desktop does not expose client chrome hit testing",
            std.mem.span(message),
        ),
        else => return error.ExpectedUnavailable,
    }
}

test "windowing desktop clamps positive window dimensions" {
    try std.testing.expectEqual(@as(u32, 1), positiveI32ToU32(-10));
    try std.testing.expectEqual(@as(u32, 1), positiveI32ToU32(0));
    try std.testing.expectEqual(@as(u32, 42), positiveI32ToU32(42));
    try std.testing.expectError(error.InvalidFrame, frameI32ToU32(0));
    try std.testing.expectEqual(@as(u32, 42), try frameI32ToU32(42));
}

test "windowing desktop tracks target frame interval" {
    try std.testing.expectEqual(@as(u64, 0), targetFrameNanosecondsForFps(0));
    try std.testing.expectEqual(@as(u64, 0), targetFrameNanosecondsForFps(-1));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s / 60), targetFrameNanosecondsForFps(60));
    try std.testing.expectEqual(@as(u64, 1), targetFrameNanosecondsForFps(std.math.maxInt(i32)));

    var state = State.init(std.testing.allocator);
    state.setTargetFps(30);
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s / 30), state.target_frame_ns);
    try std.testing.expectEqual(@as(i128, 0), state.last_present_ns);
}
