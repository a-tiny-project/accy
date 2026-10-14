const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const required_capabilities = capabilities.pure();

pub const separator = std.fs.path.sep;

pub fn join(
    allocator: std.mem.Allocator,
    parts: []const []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fs.path.join(allocator, parts);
}

pub fn dirname(path: []const u8) ?[]const u8 {
    return std.fs.path.dirname(path);
}

pub fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

pub fn extension(path: []const u8) []const u8 {
    return std.fs.path.extension(path);
}

pub fn isAbsolute(path: []const u8) bool {
    return std.fs.path.isAbsolute(path);
}

pub fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and isSeparator(path[end - 1])) : (end -= 1) {}
    return path[0..end];
}

pub fn isSeparator(byte: u8) bool {
    return std.fs.path.isSep(byte);
}
