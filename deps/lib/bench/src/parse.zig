const std = @import("std");

pub fn parseU32(text: []const u8) !u32 {
    return parseUnsigned(u32, text);
}

pub fn parseU64(text: []const u8) !u64 {
    return parseUnsigned(u64, text);
}

pub fn parseUsize(text: []const u8) !usize {
    return parseUnsigned(usize, text);
}

pub fn parsePositiveU32(text: []const u8) !u32 {
    return parsePositiveUnsigned(u32, text);
}

pub fn parsePositiveUsize(text: []const u8) !usize {
    return parsePositiveUnsigned(usize, text);
}

pub fn parsePositiveU32List(text: []const u8, values: []u32) !usize {
    return parsePositiveList(u32, text, values);
}

pub fn parsePositiveUsizeList(text: []const u8, values: []usize) !usize {
    return parsePositiveList(usize, text, values);
}

fn parseUnsigned(comptime Int: type, text: []const u8) !Int {
    return std.fmt.parseUnsigned(Int, text, 10) catch return error.InvalidArguments;
}

fn parsePositiveUnsigned(comptime Int: type, text: []const u8) !Int {
    const value = try parseUnsigned(Int, text);
    if (value == 0) return error.InvalidArguments;
    return value;
}

fn parsePositiveList(comptime Int: type, text: []const u8, values: []Int) !usize {
    var parsed_count: usize = 0;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidArguments;
        if (parsed_count >= values.len) return error.InvalidArguments;
        values[parsed_count] = try parsePositiveUnsigned(Int, part);
        parsed_count += 1;
    }
    if (parsed_count == 0) return error.InvalidArguments;
    return parsed_count;
}

test "parse unsigned integers with InvalidArguments errors" {
    try std.testing.expectEqual(@as(u32, 0), try parseU32("0"));
    try std.testing.expectEqual(@as(u32, 42), try parseU32("42"));
    try std.testing.expectEqual(@as(u64, 42), try parseU64("42"));
    try std.testing.expectEqual(@as(usize, 42), try parseUsize("42"));

    try std.testing.expectError(error.InvalidArguments, parseU32(""));
    try std.testing.expectError(error.InvalidArguments, parseU32("nope"));
    try std.testing.expectError(error.InvalidArguments, parseU32("4294967296"));
}

test "parse positive integers rejects zero" {
    try std.testing.expectEqual(@as(u32, 7), try parsePositiveU32("7"));
    try std.testing.expectEqual(@as(usize, 7), try parsePositiveUsize("7"));

    try std.testing.expectError(error.InvalidArguments, parsePositiveU32("0"));
    try std.testing.expectError(error.InvalidArguments, parsePositiveUsize("0"));
}

test "parse positive lists writes bounded values" {
    var values: [3]u32 = undefined;
    const count = try parsePositiveU32List("1,4,16", values[0..]);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualSlices(u32, &.{ 1, 4, 16 }, values[0..count]);

    var widths: [2]usize = undefined;
    const width_count = try parsePositiveUsizeList("32,64", widths[0..]);
    try std.testing.expectEqual(@as(usize, 2), width_count);
    try std.testing.expectEqualSlices(usize, &.{ 32, 64 }, widths[0..width_count]);

    try std.testing.expectError(error.InvalidArguments, parsePositiveU32List("", values[0..]));
    try std.testing.expectError(error.InvalidArguments, parsePositiveU32List("1,,2", values[0..]));
    try std.testing.expectError(error.InvalidArguments, parsePositiveU32List("1,0", values[0..]));
    try std.testing.expectError(error.InvalidArguments, parsePositiveU32List("1,2,3,4", values[0..]));
}
