const class_policy = @import("class.zig");
const model = @import("../root.zig").model;

const Class = model.Class;
const Header = model.Header;

pub fn initializeHeader(base: [*]u8, class: Class) [*]u8 {
    const header: *Header = @ptrCast(@alignCast(base));
    header.* = .{
        .magic = model.medium_header_magic,
        .class_index = class.index,
    };
    return base + model.header_size;
}

pub fn headerFromUserPointer(ptr: [*]u8) *Header {
    return @ptrCast(@alignCast(ptr - model.header_size));
}

pub fn classFromHeader(header: *const Header) ?Class {
    if (header.magic != model.medium_header_magic) return null;
    if (header.class_index >= model.medium_class_count) return null;
    return class_policy.classForIndex(header.class_index);
}

pub fn baseFromUserPointer(ptr: [*]u8) [*]u8 {
    return ptr - model.header_size;
}
