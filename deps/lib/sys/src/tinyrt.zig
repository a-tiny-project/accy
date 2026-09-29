const builtin = @import("builtin");
const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const required_capabilities = capabilities.noLibc(&.{ .descriptors, .libc_interop });

pub const stdout_fd: c_int = 1;

pub fn writeRaw(fd: c_int, bytes: [*]const u8, len: usize) usize {
    @setRuntimeSafety(false);
    return switch (builtin.os.tag) {
        .linux => std.os.linux.write(fd, bytes, len),
        .macos => @bitCast(darwin.write(fd, bytes, len)),
        else => @bitCast(@as(isize, -1)),
    };
}

const darwin = struct {
    extern "c" fn write(fd: c_int, bytes: [*]const u8, len: usize) isize;
};

pub export fn memmove(dest: ?[*]u8, src: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    const dest_ptr = dest orelse return dest;
    const src_ptr = src orelse return dest;
    if (@intFromPtr(dest_ptr) <= @intFromPtr(src_ptr)) {
        for (0..len) |index| dest_ptr[index] = src_ptr[index];
    } else {
        for (0..len) |index| dest_ptr[len - 1 - index] = src_ptr[len - 1 - index];
    }
    return dest;
}

pub export fn __divti3(a: i128, b: i128) callconv(.c) i128 {
    @setRuntimeSafety(false);
    const sign_a = a >> 127;
    const sign_b = b >> 127;
    const magnitude_a = (a ^ sign_a) -% sign_a;
    const magnitude_b = (b ^ sign_b) -% sign_b;
    const quotient = udivmod128(@bitCast(magnitude_a), @bitCast(magnitude_b), null);
    const sign = sign_a ^ sign_b;
    return (@as(i128, @bitCast(quotient)) ^ sign) -% sign;
}

pub export fn __modti3(a: i128, b: i128) callconv(.c) i128 {
    @setRuntimeSafety(false);
    const sign_a = a >> 127;
    const sign_b = b >> 127;
    const magnitude_a = (a ^ sign_a) -% sign_a;
    const magnitude_b = (b ^ sign_b) -% sign_b;
    var remainder: u128 = undefined;
    _ = udivmod128(@bitCast(magnitude_a), @bitCast(magnitude_b), &remainder);
    return (@as(i128, @bitCast(remainder)) ^ sign_a) -% sign_a;
}

pub export fn __udivti3(a: u128, b: u128) callconv(.c) u128 {
    @setRuntimeSafety(false);
    return udivmod128(a, b, null);
}

pub export fn __umodti3(a: u128, b: u128) callconv(.c) u128 {
    @setRuntimeSafety(false);
    var remainder: u128 = undefined;
    _ = udivmod128(a, b, &remainder);
    return remainder;
}

pub export fn __ashlti3(value: i128, shift: i32) callconv(.c) i128 {
    @setRuntimeSafety(false);
    if (shift <= 0) return value;
    if (shift >= 128) return 0;

    const bits: u128 = @bitCast(value);
    const low: u64 = @truncate(bits);
    const high: u64 = @truncate(bits >> 64);
    const shifted = if (shift >= 64) blk: {
        const amount: std.math.Log2Int(u64) = @intCast(shift - 64);
        break :blk joinU128(low << amount, 0);
    } else blk: {
        const amount: std.math.Log2Int(u64) = @intCast(shift);
        break :blk joinU128((high << amount) | (low >> @intCast(64 - shift)), low << amount);
    };
    return @bitCast(shifted);
}

pub export fn __lshrti3(value: i128, shift: i32) callconv(.c) i128 {
    @setRuntimeSafety(false);
    if (shift <= 0) return value;
    if (shift >= 128) return 0;

    const bits: u128 = @bitCast(value);
    const low: u64 = @truncate(bits);
    const high: u64 = @truncate(bits >> 64);
    const shifted = if (shift >= 64) blk: {
        const amount: std.math.Log2Int(u64) = @intCast(shift - 64);
        break :blk joinU128(0, high >> amount);
    } else blk: {
        const amount: std.math.Log2Int(u64) = @intCast(shift);
        break :blk joinU128(high >> amount, (low >> amount) | (high << @intCast(64 - shift)));
    };
    return @bitCast(shifted);
}

fn joinU128(high: u64, low: u64) u128 {
    @setRuntimeSafety(false);
    return (@as(u128, high) << 64) | low;
}

fn udivmod128(numerator: u128, denominator: u128, remainder_out: ?*u128) u128 {
    @setRuntimeSafety(false);
    if (denominator == 0) @trap();

    var quotient: u128 = 0;
    var remainder: u128 = 0;
    var bit_index: usize = 128;
    while (bit_index != 0) {
        bit_index -= 1;
        const shift: std.math.Log2Int(u128) = @intCast(bit_index);
        remainder = (remainder << 1) | ((numerator >> shift) & 1);
        if (remainder >= denominator) {
            remainder -= denominator;
            quotient |= @as(u128, 1) << shift;
        }
    }

    if (remainder_out) |out| out.* = remainder;
    return quotient;
}

pub export fn __zig_probe_stack() callconv(.c) void {}

test "tinyrt writeRaw reports invalid descriptor failure" {
    const bytes: []const u8 = "";
    const written = writeRaw(-1, bytes.ptr, bytes.len);
    const signed: isize = @bitCast(written);
    try std.testing.expect(signed < 0);
}

test "tinyrt compiler support helpers cover 128-bit arithmetic" {
    try std.testing.expectEqual(@divTrunc(@as(i128, -7), @as(i128, 3)), __divti3(-7, 3));
    try std.testing.expectEqual(@rem(@as(i128, -7), @as(i128, 3)), __modti3(-7, 3));
    try std.testing.expectEqual(@as(u128, 1) << 95, __udivti3(@as(u128, 1) << 100, 32));
    try std.testing.expectEqual(@as(u128, 17), __umodti3((@as(u128, 1) << 100) + 17, 32));
    try std.testing.expectEqual(@as(i128, 1) << 70, __ashlti3(1, 70));

    const high_bit: i128 = @bitCast(@as(u128, 1) << 127);
    const shifted_high_bit: i128 = @bitCast((@as(u128, 1) << 127) >> 65);
    try std.testing.expectEqual(shifted_high_bit, __lshrti3(high_bit, 65));
}
