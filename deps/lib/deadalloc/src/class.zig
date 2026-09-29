const std = @import("std");

pub const min_alignment: usize = 16;
pub const page_size: usize = 4096;
pub const max_small_size: usize = 1024 * 1024;

pub const sizes = [_]usize{
    16,
    32,
    64,
    128,
    256,
    512,
    1024,
    2048,
    4096,
    8192,
    16384,
    32768,
    65536,
    131072,
    262144,
    524288,
    1048576,
};

pub const count = sizes.len;

pub fn indexFor(len: usize, alignment: std.mem.Alignment) ?usize {
    const requested_len = @max(len, min_alignment);
    if (requested_len > max_small_size) return null;

    const requested_alignment = @max(alignment.toByteUnits(), min_alignment);
    for (sizes, 0..) |class_size, index| {
        if (class_size >= requested_len and class_size >= requested_alignment) return index;
    }
    return null;
}

pub fn size(index: usize) usize {
    return sizes[index];
}

pub fn nextPowerOfTwo(value: usize) ?usize {
    if (value == 0) return 1;
    if (value > (std.math.maxInt(usize) >> 1) + 1) return null;
    return std.math.ceilPowerOfTwo(usize, value) catch null;
}

test "classes are powers of two and cover the small range" {
    var previous: usize = 0;
    for (sizes) |class_size| {
        try std.testing.expect(class_size > previous);
        try std.testing.expect(std.math.isPowerOfTwo(class_size));
        previous = class_size;
    }
    try std.testing.expectEqual(max_small_size, sizes[sizes.len - 1]);
}

test "lookup respects requested size and alignment" {
    inline for (.{ 1, 8, 16, 32, 4096, 65536 }) |alignment| {
        var len: usize = 1;
        while (len <= max_small_size) : (len *= 2) {
            const index = indexFor(len, .fromByteUnits(alignment)) orelse return error.MissingClass;
            const class_size = size(index);
            try std.testing.expect(class_size >= len);
            try std.testing.expect(class_size >= @max(alignment, min_alignment));
        }
    }
}
