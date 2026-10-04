const std = @import("std");
const config = @import("../root.zig").config;
const size_class = @import("../root.zig").class;

const assert = std.debug.assert;
const page_size = config.page_size;

pub const magic: u64 = 0x5441_4c4c_4f43_0001;

pub const FreeNode = extern struct {
    next: ?*FreeNode,
};

pub const Page = struct {
    magic: u64,
    class_index: u16,
    block_size: u32,
    capacity: u16,
    live_count: u16,
    free_count: u16,
    next_unallocated: u16,
    block_area_offset: u16,
    mapping_base: [*]align(std.heap.page_size_min) u8,
    mapping_len: usize,
    discarded: bool,
    discarded_bytes: u32,
    free_list: ?*FreeNode,
    next_all: ?*Page,
    previous_all: ?*Page,
    next_partial: ?*Page,
    next_cached: ?*Page,

    pub fn init(
        page: *Page,
        class_index: usize,
        mapping_base: [*]align(std.heap.page_size_min) u8,
        mapping_len: usize,
    ) void {
        const block_size = size_class.size(class_index);
        const block_alignment = size_class.blockAlignment(block_size);
        const block_area_offset = std.mem.alignForward(usize, @sizeOf(Page), block_alignment);
        const capacity = (page_size - block_area_offset) / block_size;
        assert(capacity > 0);
        assert(capacity <= std.math.maxInt(u16));

        page.* = .{
            .magic = magic,
            .class_index = @intCast(class_index),
            .block_size = @intCast(block_size),
            .capacity = @intCast(capacity),
            .live_count = 0,
            .free_count = @intCast(capacity),
            .next_unallocated = 0,
            .block_area_offset = @intCast(block_area_offset),
            .mapping_base = mapping_base,
            .mapping_len = mapping_len,
            .discarded = false,
            .discarded_bytes = 0,
            .free_list = null,
            .next_all = null,
            .previous_all = null,
            .next_partial = null,
            .next_cached = null,
        };
    }

    pub fn blockPtr(page: *Page, index: usize) [*]u8 {
        return page.blockArea() + index * page.block_size;
    }

    fn blockArea(page: *Page) [*]u8 {
        return @as([*]u8, @ptrCast(page)) + page.block_area_offset;
    }

    pub fn allocationSlice(page: *Page) []u8 {
        return @as([*]u8, @ptrCast(page))[0..page_size];
    }

    pub fn mappingSlice(page: *Page) []align(std.heap.page_size_min) u8 {
        return page.mapping_base[0..page.mapping_len];
    }

    pub fn mappedBytes(page: *Page) usize {
        return page.mapping_len;
    }

    pub fn discardableSlice(page: *Page) ?[]align(std.heap.page_size_min) u8 {
        const start_offset = std.mem.alignForward(usize, page.block_area_offset, std.heap.page_size_min);
        if (start_offset >= page_size) return null;
        const start_addr = @intFromPtr(page) + start_offset;
        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start_addr);
        return ptr[0 .. page_size - start_offset];
    }

    pub fn allocate(page: *Page) [*]u8 {
        const ptr = if (page.free_list) |node| blk: {
            page.free_list = node.next;
            break :blk @as([*]u8, @ptrCast(node));
        } else blk: {
            assert(page.next_unallocated < page.capacity);
            const block = page.blockPtr(page.next_unallocated);
            page.next_unallocated += 1;
            break :blk block;
        };
        page.free_count -= 1;
        page.live_count += 1;
        return ptr;
    }

    pub fn free(page: *Page, ptr: [*]u8) void {
        assert(page.magic == magic);
        assert(page.live_count > 0);
        const node: *FreeNode = @ptrCast(@alignCast(ptr));
        node.* = .{ .next = page.free_list };
        page.free_list = node;
        page.free_count += 1;
        page.live_count -= 1;
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "page allocation materializes untouched blocks lazily" {
    const class_index = size_class.indexFor(64, .@"1").?;
    const memory = std.testing.allocator.rawAlloc(page_size, .fromByteUnits(page_size), @returnAddress()) orelse return error.OutOfMemory;
    defer std.testing.allocator.rawFree(memory[0..page_size], .fromByteUnits(page_size), @returnAddress());

    const page: *Page = @ptrCast(@alignCast(memory));
    Page.init(page, class_index, @ptrCast(@alignCast(memory)), page_size);

    try std.testing.expectEqual(@as(?*FreeNode, null), page.free_list);
    try std.testing.expectEqual(@as(u16, 0), page.next_unallocated);

    const first = page.allocate();
    const second = page.allocate();
    try std.testing.expectEqual(@as(u16, 2), page.next_unallocated);

    page.free(first);
    const reused = page.allocate();
    try std.testing.expectEqual(@intFromPtr(first), @intFromPtr(reused));
    try std.testing.expectEqual(@as(u16, 2), page.next_unallocated);

    const third = page.allocate();
    try std.testing.expectEqual(@intFromPtr(page.blockPtr(2)), @intFromPtr(third));
    try std.testing.expectEqual(@as(u16, 3), page.next_unallocated);
    try std.testing.expectEqual(@as(u16, 3), page.live_count);
    try std.testing.expectEqual(page.capacity - 3, page.free_count);
    try std.testing.expect(@intFromPtr(third) != @intFromPtr(second));
}
