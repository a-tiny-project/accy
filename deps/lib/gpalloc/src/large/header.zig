const std = @import("std");
const size_class = @import("../root.zig").class;
const class_policy = @import("class.zig");
const model = @import("model.zig");

const Class = model.Class;
const Header = model.Header;

pub fn initializeHeader(base: [*]u8, class: Class) [*]u8 {
    const header: *Header = @ptrCast(@alignCast(base));
    header.* = .{
        .magic = model.header_magic,
        .class_index = class.index,
    };
    return base + model.header_size;
}

pub fn headerFromUserPointer(ptr: [*]u8) *Header {
    return @ptrCast(@alignCast(ptr - model.header_size));
}

pub fn classFromHeader(header: *const Header) ?Class {
    if (header.magic != model.header_magic) return null;
    if (header.class_index >= model.class_count) return null;
    return class_policy.classForIndex(header.class_index);
}

pub fn baseFromUserPointer(ptr: [*]u8) [*]u8 {
    return ptr - model.header_size;
}

test "large cache header stores only class identity" {
    try std.testing.expectEqual(@as(usize, size_class.min_alignment), model.header_size);
    const class = class_policy.classFor(size_class.max_small_size + 1, .@"1").?;
    const storage_len = model.header_size + size_class.min_alignment;
    var storage: [storage_len]u8 align(size_class.min_alignment) = undefined;
    const user = initializeHeader(&storage, class);
    try std.testing.expectEqual(@intFromPtr(&storage) + model.header_size, @intFromPtr(user));
    try std.testing.expectEqual(class.index, classFromHeader(headerFromUserPointer(user)).?.index);

    var invalid: Header = .{ .magic = model.header_magic, .class_index = model.class_count };
    try std.testing.expect(classFromHeader(&invalid) == null);
    invalid = .{ .magic = 0, .class_index = class.index };
    try std.testing.expect(classFromHeader(&invalid) == null);
}
