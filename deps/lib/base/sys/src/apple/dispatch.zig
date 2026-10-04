const std = @import("std");

pub const Data = *opaque {};
pub const Queue = *opaque {};

extern fn dispatch_data_create(
    buffer: *const anyopaque,
    size: usize,
    queue: ?Queue,
    destructor: ?*const anyopaque,
) ?Data;
extern fn dispatch_release(object: *anyopaque) void;

pub fn copiedData(bytes: []const u8) ?Data {
    if (bytes.len == 0) return null;
    return dispatch_data_create(bytes.ptr, bytes.len, null, null);
}

pub fn release(data: Data) void {
    dispatch_release(@ptrCast(data));
}
