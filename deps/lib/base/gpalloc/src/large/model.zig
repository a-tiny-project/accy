const std = @import("std");
const size_class = @import("../root.zig").class;

const Alignment = std.mem.Alignment;

pub const class_step: usize = 4 * 1024;
pub const max_small_cached_size: usize = 256 * 1024;
pub const huge_class_step: usize = 4 * 1024 * 1024;
pub const min_huge_cached_size: usize = 4 * 1024 * 1024;
pub const max_cached_size: usize = 32 * 1024 * 1024;
pub const medium_class_step: usize = 64 * 1024;
pub const min_medium_cached_size: usize = max_small_cached_size + medium_class_step;
pub const max_medium_cached_size: usize = 512 * 1024;
pub const medium_default_limit_bytes: usize = 16 * 1024 * 1024;
pub const alignment = Alignment.fromByteUnits(size_class.min_alignment);

pub const min_cached_size = size_class.max_small_size + class_step;
pub const small_class_count = (max_small_cached_size - min_cached_size) / class_step + 1;
pub const huge_class_count = (max_cached_size - min_huge_cached_size) / huge_class_step + 1;
pub const class_count = small_class_count + huge_class_count;
pub const medium_class_count =
    (max_medium_cached_size - min_medium_cached_size) / medium_class_step + 1;
pub const bin_capacity: u16 = 64;
pub const header_magic: u64 = 0x5441_4c47_4341_0001;
pub const medium_header_magic: u64 = 0x5441_4d47_4341_0001;

pub const Class = struct {
    index: usize,
    size: usize,
};

pub const Entry = struct {
    class: Class,
    ptr: [*]u8,
};

pub const Header = extern struct {
    magic: u64,
    class_index: usize,
};

pub const header_size = std.mem.alignForward(
    usize,
    @sizeOf(Header),
    size_class.min_alignment,
);
