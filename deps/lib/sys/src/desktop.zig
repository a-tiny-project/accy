const std = @import("std");

const capabilities = @import("capabilities.zig");
const window_chrome = @import("chrome.zig");

pub const required_capabilities = capabilities.pure();

pub const GuiPolicyOptions = struct {
    uses_client_chrome_hit_test: bool = false,
};

pub const GuiPolicy = struct {
    use_vsync_hint: bool,
    use_custom_frame_control: bool,
    use_highdpi_framebuffer: bool,
    use_manual_framebuffer_draw_scale: bool,
    window_chrome: window_chrome.Mode,
    client_decorations: bool,
};

pub const DpiScale = struct {
    x: f32,
    y: f32,
};

pub const DrawArea = struct {
    width: i32,
    height: i32,
};

pub const Pointer = struct {
    x: f32,
    y: f32,
};

pub const PointerVector = struct {
    x: f32,
    y: f32,

    pub fn nonzero(self: PointerVector) bool {
        return self.x != 0 or self.y != 0;
    }
};

pub const DisplayScaleEvidence = struct {
    window_display: f32 = 1.0,
    display_content: f32 = 1.0,
    physical_dpi: f32 = 1.0,
    display_density: f32 = 1.0,
    pixel_density: f32 = 1.0,
};

pub const WindowScale = struct {
    ui: f32 = 1.0,
    window_display: f32 = 1.0,
    display_content: f32 = 1.0,
    physical_dpi: f32 = 1.0,
    display_density: f32 = 1.0,
    pixel_density: f32 = 1.0,
};

pub const WindowScaleEvidence = struct {
    has_window_content_scale: bool = false,
    window_display: f32 = 1.0,
    display_content: f32 = 1.0,
    physical_dpi: f32 = 1.0,
    display_density: f32 = 1.0,
    pixel_density: f32 = 1.0,
    ui_override: ?f32 = null,
};

pub const FramebufferScaleEvidence = struct {
    dpi_x: f32 = 1.0,
    dpi_y: f32 = 1.0,
    screen_width: f32 = 0,
    screen_height: f32 = 0,
    render_width: f32 = 0,
    render_height: f32 = 0,
};

const custom_frame_idle_wait_seconds: f64 = 0.001;

pub fn guiPolicy(options: GuiPolicyOptions) GuiPolicy {
    return guiPolicyFor(capabilities.current.os, options);
}

pub fn guiPolicyFor(os_tag: std.Target.Os.Tag, options: GuiPolicyOptions) GuiPolicy {
    const chrome = defaultWindowChromeFor(os_tag, options);
    return .{
        .use_vsync_hint = !os_tag.isDarwin(),
        .use_custom_frame_control = os_tag == .macos,
        .use_highdpi_framebuffer = true,
        .use_manual_framebuffer_draw_scale = os_tag.isDarwin() and options.uses_client_chrome_hit_test,
        .window_chrome = chrome,
        .client_decorations = chrome == .client,
    };
}

pub fn customFrameWaitSeconds(target_fps: ?i32) f64 {
    const fps = target_fps orelse return custom_frame_idle_wait_seconds;
    if (fps <= 0) return custom_frame_idle_wait_seconds;
    return 1.0 / @as(f64, @floatFromInt(fps));
}

pub fn shouldManualSwapScreenBuffer(policy: GuiPolicy, drew_frame: bool) bool {
    return policy.use_custom_frame_control and drew_frame;
}

pub fn shouldUseDensityScaleFallback(scale: DisplayScaleEvidence) bool {
    return shouldUseDensityScaleFallbackFor(capabilities.current.os, scale);
}

pub fn shouldUseDensityScaleFallbackFor(os_tag: std.Target.Os.Tag, scale: DisplayScaleEvidence) bool {
    if (os_tag != .linux) return false;
    return scale.window_display <= 1.0 and
        scale.display_content <= 1.0 and
        scale.pixel_density <= 1.0 and
        @max(scale.physical_dpi, scale.display_density) > 1.0;
}

pub fn scaleEvidence(scale: WindowScale) DisplayScaleEvidence {
    return .{
        .window_display = scale.window_display,
        .display_content = scale.display_content,
        .physical_dpi = scale.physical_dpi,
        .display_density = scale.display_density,
        .pixel_density = scale.pixel_density,
    };
}

pub fn windowScaleFromEvidence(evidence: WindowScaleEvidence) WindowScale {
    return windowScaleFromEvidenceFor(capabilities.current.os, evidence);
}

pub fn windowScaleFromEvidenceFor(os_tag: std.Target.Os.Tag, evidence: WindowScaleEvidence) WindowScale {
    var scale = WindowScale{
        .window_display = usableScale(evidence.window_display),
        .display_content = usableScale(evidence.display_content),
        .physical_dpi = usableScale(evidence.physical_dpi),
        .display_density = usableScale(evidence.display_density),
        .pixel_density = usableScale(evidence.pixel_density),
    };
    scale.ui = logicalContentScale(scale.window_display, scale.display_content, scale.pixel_density);

    if ((!evidence.has_window_content_scale or shouldUseDensityScaleFallbackFor(os_tag, scaleEvidence(scale))) and scale.ui <= 1.0) {
        scale.ui = @max(scale.physical_dpi, scale.display_density);
    }

    if (evidence.ui_override) |override| {
        scale.ui = usableScale(override);
    }

    return scale;
}

pub fn logicalContentScale(window_display: f32, display_content: f32, pixel_density: f32) f32 {
    var scale: f32 = 1.0;
    const density = usableScale(pixel_density);
    const window_scale = usableScale(window_display);
    if (window_scale > 0 and density > 0) {
        scale = @max(scale, window_scale / density);
    }
    scale = @max(scale, usableScale(display_content));
    return scale;
}

pub fn framebufferScaleFromDimensions(
    screen_width: f32,
    screen_height: f32,
    render_width: f32,
    render_height: f32,
) ?f32 {
    var scale: f32 = 1.0;
    var have_dimension = false;
    if (screen_width > 0 and render_width > 0) {
        scale = @max(scale, render_width / screen_width);
        have_dimension = true;
    }
    if (screen_height > 0 and render_height > 0) {
        scale = @max(scale, render_height / screen_height);
        have_dimension = true;
    }
    return if (have_dimension) scale else null;
}

pub fn framebufferScaleFromEvidence(evidence: FramebufferScaleEvidence) f32 {
    var scale = @max(usableScale(evidence.dpi_x), usableScale(evidence.dpi_y));
    if (framebufferScaleFromDimensions(evidence.screen_width, evidence.screen_height, evidence.render_width, evidence.render_height)) |dimension_scale| {
        scale = @max(scale, dimension_scale);
    }
    return scale;
}

pub fn displayDensityScaleFor(width: f32, height: f32, display_name: ?[]const u8) f32 {
    if (width <= 0 or height <= 0) return 1.0;

    if (display_name) |name| {
        if (displayNameDiagonalInches(name)) |diagonal_inches| {
            if (diagonal_inches > 0) {
                const diagonal_pixels = @sqrt(width * width + height * height);
                return scaleFromDpi(diagonal_pixels / diagonal_inches);
            }
        }
    }

    const long_edge = @max(width, height);
    const short_edge = @min(width, height);
    if (long_edge >= 3800 and short_edge >= 2100) return 1.25;
    if (long_edge >= 3000 and short_edge >= 1800) return 1.15;
    return 1.0;
}

pub fn displayNameDiagonalInches(name: []const u8) ?f32 {
    const quote_index = std.mem.lastIndexOfScalar(u8, name, '"') orelse return null;
    var end = quote_index;
    while (end > 0 and std.ascii.isWhitespace(name[end - 1])) : (end -= 1) {}

    var start = end;
    while (start > 0) {
        const byte = name[start - 1];
        if (!std.ascii.isDigit(byte) and byte != '.') break;
        start -= 1;
    }
    if (start == end) return null;
    return std.fmt.parseFloat(f32, name[start..end]) catch null;
}

pub fn scaleFromDpi(dpi: f32) f32 {
    const scale = dpi / 96.0;
    if (!std.math.isFinite(scale) or scale < 1.15) return 1.0;
    return scale;
}

pub fn scaleFromPhysicalWidthMm(pixel_width: f32, physical_width_mm: f32) f32 {
    if (pixel_width <= 0 or physical_width_mm <= 0) return 1.0;
    return scaleFromDpi(pixel_width / (physical_width_mm / 25.4));
}

fn usableScale(raw_scale: f32) f32 {
    if (!std.math.isFinite(raw_scale) or raw_scale <= 0) return 1.0;
    return raw_scale;
}

pub fn supportsGraphicalWindows() bool {
    return supportsGraphicalWindowsFor(capabilities.current.os);
}

pub fn supportsGraphicalWindowsFor(os_tag: std.Target.Os.Tag) bool {
    return os_tag == .linux or os_tag == .macos;
}

fn defaultWindowChromeFor(os_tag: std.Target.Os.Tag, options: GuiPolicyOptions) window_chrome.Mode {
    if (os_tag.isDarwin()) return .native;
    return if (options.uses_client_chrome_hit_test) .client else .native;
}

test "GUI policy captures desktop platform choices" {
    const mac = guiPolicyFor(.macos, .{ .uses_client_chrome_hit_test = true });
    try std.testing.expect(!mac.use_vsync_hint);
    try std.testing.expect(mac.use_custom_frame_control);
    try std.testing.expect(mac.use_highdpi_framebuffer);
    try std.testing.expect(mac.use_manual_framebuffer_draw_scale);
    try std.testing.expectEqual(window_chrome.Mode.native, mac.window_chrome);
    try std.testing.expect(shouldManualSwapScreenBuffer(mac, true));
    try std.testing.expect(!shouldManualSwapScreenBuffer(mac, false));
    try std.testing.expectEqual(@as(f64, custom_frame_idle_wait_seconds), customFrameWaitSeconds(null));
    try std.testing.expectEqual(@as(f64, 1.0 / 30.0), customFrameWaitSeconds(30));

    const linux = guiPolicyFor(.linux, .{ .uses_client_chrome_hit_test = true });
    try std.testing.expect(linux.use_vsync_hint);
    try std.testing.expect(!linux.use_custom_frame_control);
    try std.testing.expect(linux.use_highdpi_framebuffer);
    try std.testing.expect(!linux.use_manual_framebuffer_draw_scale);
    try std.testing.expectEqual(window_chrome.Mode.client, linux.window_chrome);
    try std.testing.expect(linux.client_decorations);
    try std.testing.expect(!shouldManualSwapScreenBuffer(linux, true));
}

test "Linux density fallback requires only density evidence" {
    try std.testing.expect(shouldUseDensityScaleFallbackFor(.linux, .{
        .window_display = 1.0,
        .display_content = 1.0,
        .physical_dpi = 1.0,
        .display_density = 1.43,
        .pixel_density = 1.0,
    }));
    try std.testing.expect(!shouldUseDensityScaleFallbackFor(.macos, .{
        .window_display = 1.0,
        .display_content = 1.0,
        .physical_dpi = 1.0,
        .display_density = 1.43,
        .pixel_density = 1.0,
    }));
}

test "display scale helpers separate framebuffer and logical UI scale" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), logicalContentScale(2.0, 1.0, 2.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), logicalContentScale(2.5, 1.25, 2.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), logicalContentScale(1.5, 1.0, 1.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), framebufferScaleFromDimensions(640, 480, 640, 480).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), framebufferScaleFromDimensions(640, 480, 1280, 960).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), framebufferScaleFromEvidence(.{ .dpi_x = 1.0, .dpi_y = 1.0, .screen_width = 640, .screen_height = 480, .render_width = 1280, .render_height = 960 }), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), framebufferScaleFromEvidence(.{ .dpi_x = 2.0, .dpi_y = 1.0 }), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), scaleFromPhysicalWidthMm(1920, 508), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), scaleFromPhysicalWidthMm(1920, 254), 0.001);
}

test "window scale evidence applies platform fallback policy" {
    const linux = windowScaleFromEvidenceFor(.linux, .{
        .has_window_content_scale = true,
        .window_display = 1.0,
        .display_content = 1.0,
        .physical_dpi = 1.0,
        .display_density = 1.43,
        .pixel_density = 1.0,
    });
    try std.testing.expectApproxEqAbs(@as(f32, 1.43), linux.ui, 0.001);

    const mac_without_window_evidence = windowScaleFromEvidenceFor(.macos, .{
        .has_window_content_scale = false,
        .physical_dpi = 2.0,
    });
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), mac_without_window_evidence.ui, 0.001);

    const override = windowScaleFromEvidenceFor(.linux, .{
        .ui_override = 1.75,
        .display_density = 1.25,
    });
    try std.testing.expectApproxEqAbs(@as(f32, 1.75), override.ui, 0.001);
}

test "display density scale uses monitor names and resolution fallbacks" {
    try std.testing.expectApproxEqAbs(@as(f32, 32), displayNameDiagonalInches("HDMI-A-2 32\"").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 13.5), displayNameDiagonalInches("Built-in Display 13.5\"").?, 0.001);
    try std.testing.expectEqual(@as(?f32, null), displayNameDiagonalInches("HDMI-A-2"));
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), displayDensityScaleFor(3840, 2160, null), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.15), displayDensityScaleFor(3000, 1800, null), 0.001);
}

test "graphical window capability names supported desktop targets" {
    try std.testing.expect(supportsGraphicalWindowsFor(.linux));
    try std.testing.expect(supportsGraphicalWindowsFor(.macos));
    try std.testing.expect(!supportsGraphicalWindowsFor(.windows));
}
