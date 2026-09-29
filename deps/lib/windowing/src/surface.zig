const std = @import("std");
const sys = @import("sys");

pub const Kind = enum {
    wayland,
    x11,
    cocoa,
    unsupported,
};

pub const Extent = struct {
    width: u32,
    height: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    scale_x: f32,
    scale_y: f32,

    pub fn pixelCount(self: Extent) ?usize {
        return std.math.mul(usize, @as(usize, self.framebuffer_width), @as(usize, self.framebuffer_height)) catch null;
    }
};

pub const Surface = union(Kind) {
    wayland: Wayland,
    x11: X11,
    cocoa: Cocoa,
    unsupported: Unsupported,

    pub fn kind(self: Surface) Kind {
        return switch (self) {
            .wayland => .wayland,
            .x11 => .x11,
            .cocoa => .cocoa,
            .unsupported => .unsupported,
        };
    }

    pub fn extent(self: Surface) Extent {
        return switch (self) {
            .wayland => |value| value.extent,
            .x11 => |value| value.extent,
            .cocoa => |value| value.extent,
            .unsupported => |value| value.extent,
        };
    }
};

pub const Wayland = struct {
    descriptor: sys.fd.Descriptor,
    surface_id: u32,
    extent: Extent,
};

pub const X11 = struct {
    connection: *sys.x11.Connection,
    display: sys.x11.display.Target,
    window: u32,
    screen: u32,
    root: u32,
    visual: u32,
    depth: u8,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    extent: Extent,
};

pub const Cocoa = struct {
    app: sys.apple.objc.Id,
    window: sys.apple.objc.Id,
    layer: sys.apple.objc.Id,
    extent: Extent,
};

pub const Unsupported = struct {
    extent: Extent,
};

pub fn extentFromSizes(
    width: u32,
    height: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    scale_x: f32,
    scale_y: f32,
) Extent {
    return .{
        .width = width,
        .height = height,
        .framebuffer_width = framebuffer_width,
        .framebuffer_height = framebuffer_height,
        .scale_x = usableScale(scale_x),
        .scale_y = usableScale(scale_y),
    };
}

fn usableScale(value: f32) f32 {
    if (!std.math.isFinite(value) or value <= 0) return 1;
    return value;
}

test "native surface extents sanitize scale and count framebuffer pixels" {
    const extent = extentFromSizes(320, 200, 640, 400, 2, -1);
    try std.testing.expectEqual(@as(u32, 320), extent.width);
    try std.testing.expectEqual(@as(u32, 400), extent.framebuffer_height);
    try std.testing.expectEqual(@as(f32, 2), extent.scale_x);
    try std.testing.expectEqual(@as(f32, 1), extent.scale_y);
    try std.testing.expectEqual(@as(usize, 640 * 400), extent.pixelCount().?);
}

test "native surface union exposes kind and extent" {
    const extent = extentFromSizes(10, 20, 10, 20, 1, 1);
    const native = Surface{ .unsupported = .{ .extent = extent } };
    try std.testing.expectEqual(Kind.unsupported, native.kind());
    try std.testing.expectEqual(extent, native.extent());
}
