const std = @import("std");

pub fn parsePositiveUsize(text: []const u8) !usize {
    const value = try parseUsize(text);
    if (value == 0) return error.InvalidArguments;
    return value;
}

pub fn parseUsize(text: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, text, 10) catch error.InvalidArguments;
}

pub fn parseU64(text: []const u8) !u64 {
    return std.fmt.parseUnsigned(u64, text, 10) catch error.InvalidArguments;
}

pub fn parsePositiveU64(text: []const u8) !u64 {
    const value = try parseU64(text);
    if (value == 0) return error.InvalidArguments;
    return value;
}

pub fn parseAddress(text: []const u8) !u64 {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        return std.fmt.parseUnsigned(u64, text[2..], 16) catch error.InvalidArguments;
    }
    return parseU64(text);
}
