const std = @import("std");

pub fn powif(base: f32, exponent: c_int) f32 {
    return std.math.pow(f32, base, @floatFromInt(exponent));
}

pub fn memset_i8(dest: ?[*]u8, value: u8, len: u8, align_bytes: u32, is_volatile: bool) void {
    _ = align_bytes;
    _ = is_volatile;
    fill(dest, value, len);
}

pub fn memset_i16(dest: ?[*]u8, value: u8, len: u16, align_bytes: u32, is_volatile: bool) void {
    _ = align_bytes;
    _ = is_volatile;
    fill(dest, value, len);
}

pub fn memset_i32(dest: ?[*]u8, value: u8, len: u32, align_bytes: u32, is_volatile: bool) void {
    _ = align_bytes;
    _ = is_volatile;
    fill(dest, value, len);
}

pub fn memset_i64(dest: ?[*]u8, value: u8, len: u64, align_bytes: u32, is_volatile: bool) void {
    _ = align_bytes;
    _ = is_volatile;
    fill(dest, value, len);
}

fn fill(dest: ?[*]u8, value: u8, len: anytype) void {
    @setRuntimeSafety(false);
    const ptr = dest orelse return;
    for (0..@as(usize, @intCast(len))) |index| ptr[index] = value;
}

test "intrinsics expose upstream powif semantics" {
    try std.testing.expectEqual(@as(f32, 8.0), powif(2.0, 3));
    try std.testing.expectEqual(@as(f32, 0.25), powif(2.0, -2));
    try std.testing.expectEqual(@as(f32, -8.0), powif(-2.0, 3));
    try std.testing.expectEqual(@as(f32, 1.0), powif(-2.0, 0));
}

test "intrinsics expose upstream memset variants" {
    var bytes = @as([32]u8, @splat(0xaa));

    memset_i8(bytes[1..].ptr, 0x11, 3, 1, false);
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[0]);
    try std.testing.expectEqualSlices(u8, &@as([3]u8, @splat(0x11)), bytes[1..4]);

    memset_i16(bytes[4..].ptr, 0x22, 5, 2, false);
    try std.testing.expectEqualSlices(u8, &@as([5]u8, @splat(0x22)), bytes[4..9]);

    memset_i32(bytes[9..].ptr, 0x33, 7, 4, false);
    try std.testing.expectEqualSlices(u8, &@as([7]u8, @splat(0x33)), bytes[9..16]);

    memset_i64(bytes[16..].ptr, 0x44, 9, 8, true);
    try std.testing.expectEqualSlices(u8, &@as([9]u8, @splat(0x44)), bytes[16..25]);
    try std.testing.expectEqualSlices(u8, &@as([7]u8, @splat(0xaa)), bytes[25..]);

    memset_i8(null, 0xff, 0, 1, false);
    memset_i16(null, 0xff, 0, 1, false);
    memset_i32(null, 0xff, 0, 1, false);
    memset_i64(null, 0xff, 0, 1, false);
}
