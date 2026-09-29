const std = @import("std");
const config = @import("../root.zig").config;
const sys = @import("sys");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Page = model.Page;
const page_size = config.page_size;

pub fn createFromBacking(backing_allocator: Allocator, class_index: usize, ret_addr: usize) ?*Page {
    const memory = backing_allocator.rawAlloc(page_size, .fromByteUnits(page_size), ret_addr) orelse return null;
    const page: *Page = @ptrCast(@alignCast(memory));
    Page.init(page, class_index, @ptrCast(@alignCast(memory)), page_size);
    return page;
}

pub fn destroyInBacking(backing_allocator: Allocator, page: *Page, ret_addr: usize) void {
    page.magic = 0;
    backing_allocator.rawFree(page.allocationSlice(), .fromByteUnits(page_size), ret_addr);
}

pub fn createFromOs(class_index: usize) ?*Page {
    const mapping = sys.memory.mapAnonymous(page_size * 2, .{ .read = true, .write = true }) catch return null;
    const mapping_addr = @intFromPtr(mapping.ptr);
    const page_addr = std.mem.alignForward(usize, mapping_addr, page_size);
    const page_offset = page_addr - mapping_addr;
    const page_end = page_offset + page_size;
    std.debug.assert(page_end <= mapping.len);

    if (page_offset > 0) sys.memory.unmap(mapping[0..page_offset]);
    if (page_end < mapping.len) {
        const suffix: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(mapping_addr + page_end);
        sys.memory.unmap(suffix[0 .. mapping.len - page_end]);
    }

    const page: *Page = @ptrFromInt(page_addr);
    const page_mapping: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(page_addr);
    Page.init(page, class_index, page_mapping, page_size);
    return page;
}

pub fn destroyFromOs(page: *Page) void {
    const mapping = page.mappingSlice();
    page.magic = 0;
    sys.memory.unmap(mapping);
}

pub fn fromBlock(ptr: [*]u8) *Page {
    const page_addr = std.mem.alignBackward(usize, @intFromPtr(ptr), page_size);
    return @ptrFromInt(page_addr);
}

test {
    std.testing.refAllDecls(@This());
}
