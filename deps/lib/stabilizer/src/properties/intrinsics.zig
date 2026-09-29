const std = @import("std");
const hypothesis = @import("hypothesis");
const stabilizer = @import("stabilizer");

const Allocator = std.mem.Allocator;

const powif = stabilizer.powif;
const memset_i8 = stabilizer.memset_i8;
const memset_i16 = stabilizer.memset_i16;
const memset_i32 = stabilizer.memset_i32;
const memset_i64 = stabilizer.memset_i64;

fn settings() hypothesis.Settings {
    return hypothesis.Settings.quick()
        .withSeed(0x57ab_11e5)
        .withDatabase("zig-out/hypothesis-failures/stabilizer");
}

fn drawUsize(data: *hypothesis.ConjectureData, min: usize, max: usize, shrink_towards: usize) !usize {
    return @intCast(try data.drawInteger(
        @intCast(min),
        @intCast(max),
        @intCast(shrink_towards),
    ));
}

fn drawI32(data: *hypothesis.ConjectureData, min: i32, max: i32, shrink_towards: i32) !i32 {
    return hypothesis.strategies.u64ToInt(i32, try data.drawInteger(
        hypothesis.strategies.intToU64(i32, min),
        hypothesis.strategies.intToU64(i32, max),
        hypothesis.strategies.intToU64(i32, shrink_towards),
    ));
}

const IntrinsicPowProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        _ = allocator;
        const base_i = try drawI32(data, -32, 32, 2);
        const exponent = try drawI32(data, -8, 8, 0);
        const base: f32 = @floatFromInt(base_i);
        const expected = std.math.pow(f32, base, @floatFromInt(exponent));
        const actual = powif(base, @intCast(exponent));
        if (std.math.isNan(expected)) {
            try std.testing.expect(std.math.isNan(actual));
        } else {
            try std.testing.expectEqual(expected, actual);
        }
    }
};

test "pbt: powif matches upstream float exponent cast" {
    try hypothesis.checkNamed(IntrinsicPowProperty, "stabilizer-powif", settings());
}

const IntrinsicMemsetProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        const variant = try drawUsize(data, 0, 3, 0);
        const len = try drawUsize(data, 0, if (variant == 0) 255 else 256, 0);
        const prefix = try drawUsize(data, 0, 16, 0);
        const suffix = try drawUsize(data, 0, 16, 0);
        const value: u8 = @truncate(try drawUsize(data, 0, 255, 0));
        const total = prefix + len + suffix;
        const bytes = try allocator.alloc(u8, total);
        defer allocator.free(bytes);
        @memset(bytes, 0xa5);

        switch (variant) {
            0 => memset_i8(bytes[prefix..].ptr, value, @intCast(len), 1, false),
            1 => memset_i16(bytes[prefix..].ptr, value, @intCast(len), 1, false),
            2 => memset_i32(bytes[prefix..].ptr, value, @intCast(len), 1, false),
            else => memset_i64(bytes[prefix..].ptr, value, @intCast(len), 1, true),
        }

        for (bytes[0..prefix]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        for (bytes[prefix..][0..len]) |byte| try std.testing.expectEqual(value, byte);
        for (bytes[prefix + len ..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    }
};

test "pbt: memset intrinsics preserve exact byte ranges" {
    try hypothesis.checkNamed(IntrinsicMemsetProperty, "stabilizer-memset-intrinsics", settings());
}
