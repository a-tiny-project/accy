const std = @import("std");
const apple = @import("root.zig");

pub const NSUInteger = u64;
pub const NSInteger = i64;
pub const String = *opaque {};
pub const Error = *opaque {};

const utf8_string_encoding: NSUInteger = 4;

pub const AutoreleasePool = struct {
    handle: apple.objc.Id,

    pub fn init() ?AutoreleasePool {
        const pool_class = apple.objc.class("NSAutoreleasePool") orelse return null;
        const allocated = apple.objc.send(?apple.objc.Id, pool_class, apple.objc.selector("alloc"), .{}) orelse return null;
        const initialized = apple.objc.send(?apple.objc.Id, allocated, apple.objc.selector("init"), .{}) orelse return null;
        return .{ .handle = initialized };
    }

    pub fn deinit(self: *AutoreleasePool) void {
        apple.objc.send(void, self.handle, apple.objc.selector("drain"), .{});
        self.* = undefined;
    }
};

pub fn stringFromBytes(bytes: []const u8) ?String {
    if (bytes.len == 0) return null;
    const string_class = apple.objc.class("NSString") orelse return null;
    const allocated = apple.objc.send(?apple.objc.Id, string_class, apple.objc.selector("alloc"), .{}) orelse return null;
    return apple.objc.send(
        ?String,
        allocated,
        apple.objc.selector("initWithBytes:length:encoding:"),
        .{ bytes.ptr, bytes.len, utf8_string_encoding },
    );
}

/// The string's UTF-8 bytes, valid while the string lives and the current autorelease pool stands.
pub fn utf8(string: String) ?[*:0]const u8 {
    return apple.objc.send(?[*:0]const u8, @ptrCast(string), apple.objc.selector("UTF8String"), .{});
}

/// The error's localized description, autoreleased.
pub fn errorDescription(error_object: Error) ?String {
    return apple.objc.send(?String, @ptrCast(error_object), apple.objc.selector("localizedDescription"), .{});
}

pub fn errorCode(error_object: Error) NSInteger {
    return apple.objc.send(NSInteger, @ptrCast(error_object), apple.objc.selector("code"), .{});
}

test "Foundation uses the 64-bit Apple scalar ABI" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(NSUInteger));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(NSInteger));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(String));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(Error));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(AutoreleasePool));
}
