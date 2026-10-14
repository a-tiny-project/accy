const std = @import("std");
const elf = @import("../root.zig");

const MergePieceLayout = elf.layout.MergePieceLayout;

pub const Record = struct {
    bytes: []const u8,
    piece: *MergePieceLayout,
    ordinal: u32,
    alignment: u64,
    reverse_prefix: u64,
    section_type: u32,
    output_index: u8,
    external_start: bool,
};

pub fn sameStorageGroup(left: Record, right: Record) bool {
    return left.section_type == right.section_type and
        left.output_index == right.output_index and
        left.alignment == right.alignment;
}

pub const reverse_prefix_bytes = @sizeOf(u64);

pub fn reversePrefix(bytes: []const u8) u64 {
    if (bytes.len == 0) return 0;
    const content_len = bytes.len - 1;
    const count = @min(content_len, reverse_prefix_bytes);
    if (count == 0) return 0;
    var key: u64 = 0;
    for (0..count) |index| {
        key = (key << 8) | @as(u64, bytes[content_len - 1 - index]);
    }
    const remaining_bytes: usize = reverse_prefix_bytes - count;
    const remaining_bits: u6 = @intCast(remaining_bytes * 8);
    return key << remaining_bits;
}
