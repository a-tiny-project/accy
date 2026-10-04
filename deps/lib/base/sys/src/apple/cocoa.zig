const std = @import("std");
const apple = @import("root.zig");

pub const NSPoint = extern struct {
    x: apple.coregraphics.CGFloat,
    y: apple.coregraphics.CGFloat,
};

pub const NSSize = extern struct {
    width: apple.coregraphics.CGFloat,
    height: apple.coregraphics.CGFloat,
};

pub const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

pub const NSEventTypeLeftMouseDown: apple.foundation.NSUInteger = 1;
pub const NSEventTypeLeftMouseUp: apple.foundation.NSUInteger = 2;
pub const NSEventTypeRightMouseDown: apple.foundation.NSUInteger = 3;
pub const NSEventTypeRightMouseUp: apple.foundation.NSUInteger = 4;
pub const NSEventTypeMouseMoved: apple.foundation.NSUInteger = 5;
pub const NSEventTypeLeftMouseDragged: apple.foundation.NSUInteger = 6;
pub const NSEventTypeRightMouseDragged: apple.foundation.NSUInteger = 7;
pub const NSEventTypeKeyDown: apple.foundation.NSUInteger = 10;
pub const NSEventTypeKeyUp: apple.foundation.NSUInteger = 11;
pub const NSEventTypeFlagsChanged: apple.foundation.NSUInteger = 12;
pub const NSEventTypeScrollWheel: apple.foundation.NSUInteger = 22;
pub const NSEventTypeOtherMouseDown: apple.foundation.NSUInteger = 25;
pub const NSEventTypeOtherMouseUp: apple.foundation.NSUInteger = 26;
pub const NSEventTypeOtherMouseDragged: apple.foundation.NSUInteger = 27;

pub const NSEventModifierFlagCapsLock: apple.foundation.NSUInteger = 1 << 16;
pub const NSEventModifierFlagShift: apple.foundation.NSUInteger = 1 << 17;
pub const NSEventModifierFlagControl: apple.foundation.NSUInteger = 1 << 18;
pub const NSEventModifierFlagOption: apple.foundation.NSUInteger = 1 << 19;
pub const NSEventModifierFlagCommand: apple.foundation.NSUInteger = 1 << 20;

pub const NSWindowStyleMaskTitled: apple.foundation.NSUInteger = 1 << 0;
pub const NSWindowStyleMaskClosable: apple.foundation.NSUInteger = 1 << 1;
pub const NSWindowStyleMaskMiniaturizable: apple.foundation.NSUInteger = 1 << 2;
pub const NSWindowStyleMaskResizable: apple.foundation.NSUInteger = 1 << 3;

pub const NSAnyEventMask: apple.foundation.NSUInteger = std.math.maxInt(apple.foundation.NSUInteger);
