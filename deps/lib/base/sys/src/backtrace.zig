const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const required_capabilities = capabilities.pure();

pub fn supportsCapture() bool {
    return std.options.allow_stack_tracing and pointerStorageMatchesAddress();
}

pub fn capture(buffer: []?*anyopaque) usize {
    if (buffer.len == 0) return 0;
    if (!supportsCapture()) return 0;
    const addresses: []usize = @as([*]usize, @ptrCast(@alignCast(buffer.ptr)))[0..buffer.len];
    const trace = std.debug.captureCurrentStackTrace(.{}, addresses);
    for (trace.return_addresses, 0..) |address, index| {
        buffer[index] = @ptrFromInt(address);
    }
    return trace.return_addresses.len;
}

fn pointerStorageMatchesAddress() bool {
    return @sizeOf(?*anyopaque) == @sizeOf(usize) and @alignOf(?*anyopaque) >= @alignOf(usize);
}

test "backtrace capture support is queryable" {
    _ = supportsCapture();
}

test "backtrace capture tolerates empty buffers" {
    try std.testing.expectEqual(@as(usize, 0), capture(&.{}));
}

test "backtrace capture fits caller buffer" {
    var buffer = @as([16]?*anyopaque, @splat(null));
    const count = capture(&buffer);

    try std.testing.expect(count <= buffer.len);
    if (count > 0) {
        try std.testing.expect(buffer[0] != null);
    }
}
