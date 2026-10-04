const std = @import("std");

pub const CGFloat = f64;
pub const ColorSpace = *opaque {};
pub const DataProvider = *opaque {};
pub const Event = *opaque {};
pub const EventFlags = u64;
pub const EventType = u32;
pub const Image = *opaque {};
pub const MouseButton = u32;
pub const Point = extern struct {
    x: CGFloat,
    y: CGFloat,
};

const image_alpha_last: u32 = 3;
const bitmap_byte_order_32_big: u32 = 4 << 12;
pub const event_left_mouse_down: EventType = 1;
pub const event_left_mouse_up: EventType = 2;
pub const event_right_mouse_down: EventType = 3;
pub const event_right_mouse_up: EventType = 4;
pub const event_other_mouse_down: EventType = 25;
pub const event_other_mouse_up: EventType = 26;
pub const event_other_mouse_dragged: EventType = 27;
const rendering_intent_default: c_int = 0;
const keyboard_event_autorepeat: u32 = 8;

extern fn CFRelease(value: *const anyopaque) void;
extern fn CGColorSpaceCreateDeviceRGB() ?ColorSpace;
extern fn CGColorSpaceRelease(space: ColorSpace) void;
extern fn CGDataProviderCreateWithData(
    info: ?*anyopaque,
    data: *const anyopaque,
    size: usize,
    release_data: ?*const fn (?*anyopaque, *const anyopaque, usize) callconv(.c) void,
) ?DataProvider;
extern fn CGDataProviderRelease(provider: DataProvider) void;
extern fn CGImageCreate(
    width: usize,
    height: usize,
    bits_per_component: usize,
    bits_per_pixel: usize,
    bytes_per_row: usize,
    color_space: ColorSpace,
    bitmap_info: u32,
    provider: DataProvider,
    decode: ?[*]const CGFloat,
    should_interpolate: bool,
    intent: c_int,
) ?Image;
extern fn CGImageRelease(image: Image) void;
extern fn CGEventCreateKeyboardEvent(
    source: ?*const anyopaque,
    virtual_key: u16,
    key_down: bool,
) ?Event;
extern fn CGEventCreateMouseEvent(
    source: ?*const anyopaque,
    mouse_type: EventType,
    mouse_cursor_position: Point,
    mouse_button: MouseButton,
) ?Event;
extern fn CGEventSetFlags(event: ?Event, flags: EventFlags) void;
extern fn CGEventSetIntegerValueField(event: ?Event, field: u32, value: i64) void;

pub fn createDeviceRgbColorSpace() ?ColorSpace {
    return CGColorSpaceCreateDeviceRGB();
}

pub fn releaseColorSpace(space: ColorSpace) void {
    CGColorSpaceRelease(space);
}

pub fn createDataProvider(data: []const u8) ?DataProvider {
    if (data.len == 0) return null;
    return CGDataProviderCreateWithData(null, data.ptr, data.len, null);
}

pub fn releaseDataProvider(provider: DataProvider) void {
    CGDataProviderRelease(provider);
}

pub fn createRgba8Image(
    width: u32,
    height: u32,
    bytes_per_row: usize,
    color_space: ColorSpace,
    provider: DataProvider,
) ?Image {
    return CGImageCreate(
        @as(usize, width),
        @as(usize, height),
        8,
        32,
        bytes_per_row,
        color_space,
        image_alpha_last | bitmap_byte_order_32_big,
        provider,
        null,
        false,
        rendering_intent_default,
    );
}

pub fn releaseImage(image: Image) void {
    CGImageRelease(image);
}

pub fn createKeyboardEvent(virtual_key: u16, key_down: bool) ?Event {
    return CGEventCreateKeyboardEvent(null, virtual_key, key_down);
}

pub fn createMouseEvent(
    event_type: EventType,
    position: Point,
    button: MouseButton,
) ?Event {
    return CGEventCreateMouseEvent(null, event_type, position, button);
}

pub fn setKeyboardEventFlags(event: Event, flags: EventFlags) void {
    CGEventSetFlags(event, flags);
}

pub fn setKeyboardEventRepeated(event: Event, repeated: bool) void {
    CGEventSetIntegerValueField(event, keyboard_event_autorepeat, @intFromBool(repeated));
}

pub fn releaseEvent(event: Event) void {
    CFRelease(event);
}

test "CoreGraphics ABI uses 64-bit scalars and opaque pointer handles" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(CGFloat));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(ColorSpace));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(DataProvider));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(Event));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(EventFlags));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(EventType));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(Image));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(MouseButton));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Point));
}
