const std = @import("std");

pub const min_alignment: usize = 16;
pub const page_size: usize = 64 * 1024;
pub const max_small_size: usize = 32 * 1024;

pub const sizes = [_]usize{
    16,    32,    48,    64,    80,    96,    112,   128,
    160,   192,   224,   256,   320,   384,   448,   512,
    640,   768,   896,   1024,  1280,  1536,  1792,  2048,
    2560,  3072,  3584,  4096,  5120,  6144,  7168,  8192,
    10240, 12288, 14336, 16384, 20480, 24576, 28672, 32768,
};

pub const count = sizes.len;

const size_lookup_count = max_small_size / min_alignment + 1;
const min_alignment_shift = @ctz(@as(usize, min_alignment));
const lookup = buildLookup();

pub fn indexFor(len: usize, alignment: std.mem.Alignment) ?usize {
    if (isDefaultAligned(alignment)) return indexForDefaultAlignment(len);
    return indexForOveraligned(len, alignment);
}

fn isDefaultAligned(alignment: std.mem.Alignment) bool {
    return @backingInt(alignment) <= min_alignment_shift;
}

fn indexForDefaultAlignment(len: usize) ?usize {
    std.debug.assert(len > 0);
    if (len > max_small_size) return null;

    return lookup[(len + min_alignment - 1) >> min_alignment_shift];
}

fn indexForOveraligned(len: usize, alignment: std.mem.Alignment) ?usize {
    std.debug.assert(len > 0);
    if (len > max_small_size) return null;

    const alignment_bytes = alignment.toByteUnits();
    if (alignment_bytes > max_small_size) return null;
    const aligned_len = std.mem.alignForward(usize, len, alignment_bytes);
    return lookup[(aligned_len + min_alignment - 1) >> min_alignment_shift];
}

fn indexForByScan(len: usize, alignment: std.mem.Alignment) ?usize {
    const requested_len = @max(len, min_alignment);
    if (requested_len > max_small_size) return null;

    const requested_alignment = alignment.toByteUnits();
    const effective_alignment = @max(requested_alignment, min_alignment);
    for (sizes, 0..) |class_size, index| {
        if (class_size >= requested_len and class_size % effective_alignment == 0) {
            return index;
        }
    }
    return null;
}

fn buildLookup() [size_lookup_count]u8 {
    @setEvalBranchQuota(2_000_000);
    var table: [size_lookup_count]u8 = undefined;
    table[0] = 0;
    for (1..size_lookup_count) |size_index| {
        const requested_len = size_index * min_alignment;
        const class_index = indexForByScan(requested_len, .fromByteUnits(min_alignment)) orelse
            @compileError("size class lookup must cover the small range");
        table[size_index] = @intCast(class_index);
    }
    return table;
}

pub fn size(index: usize) usize {
    return sizes[index];
}

pub fn blockAlignment(class_size: usize) usize {
    var alignment: usize = min_alignment;
    while (alignment < page_size and alignment * 2 <= class_size and class_size % (alignment * 2) == 0) {
        alignment *= 2;
    }
    return alignment;
}

test "classes are sorted and cover the small range" {
    var previous: usize = 0;
    for (sizes) |class_size| {
        try std.testing.expect(class_size > previous);
        try std.testing.expectEqual(@as(usize, 0), class_size % min_alignment);
        previous = class_size;
    }
    try std.testing.expectEqual(max_small_size, sizes[sizes.len - 1]);
}

test "class lookup respects requested alignment" {
    inline for (.{ 1, 2, 4, 8, 16, 32, 64, 256, 4096, 32768 }) |alignment| {
        const index = indexFor(17, .fromByteUnits(alignment)) orelse return error.MissingClass;
        const class_size = size(index);
        try std.testing.expect(class_size >= 17);
        try std.testing.expectEqual(@as(usize, 0), class_size % @max(alignment, min_alignment));
    }
}

test "oversized or over-aligned requests bypass small classes" {
    try std.testing.expect(indexFor(max_small_size + 1, .@"1") == null);
    try std.testing.expect(indexFor(1, .fromByteUnits(page_size * 2)) == null);
}

test "class lookup table matches scan" {
    inline for (.{
        1,   2,    4,    8,    16,   32,    64,    128,   256,
        512, 1024, 2048, 4096, 8192, 16384, 32768, 65536,
    }) |alignment| {
        var len: usize = 1;
        while (len <= max_small_size) : (len += 1) {
            try std.testing.expectEqual(
                indexForByScan(len, .fromByteUnits(alignment)),
                indexFor(len, .fromByteUnits(alignment)),
            );
        }
    }
}

test "default aligned lookup avoids alignment scan" {
    inline for (.{ 1, 2, 4, 8, 16 }) |alignment| {
        var len: usize = 1;
        while (len <= max_small_size) : (len += 1) {
            try std.testing.expectEqual(
                indexForByScan(len, .fromByteUnits(alignment)),
                indexForDefaultAlignment(len),
            );
        }
    }
}
