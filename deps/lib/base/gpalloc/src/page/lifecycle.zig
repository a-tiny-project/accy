const std = @import("std");
const config = @import("../root.zig").config;
const sys = @import("sys");
const model = @import("model.zig");

const Page = model.Page;
const page_size = config.page_size;

pub fn discardUnused(page: *Page) ?usize {
    if (page.discarded) return null;
    const discardable = page.discardableSlice() orelse return null;
    if (discardable.len == 0) return null;
    sys.memory.discard(discardable) catch return null;
    page.discarded = true;
    page.discarded_bytes = @intCast(discardable.len);
    page.free_list = null;
    page.next_unallocated = 0;
    return discardable.len;
}

pub fn restoreDiscarded(page: *Page) ?usize {
    if (!page.discarded) return null;
    const discarded_bytes: usize = @intCast(page.discarded_bytes);
    page.free_list = null;
    page.next_unallocated = 0;
    page.discarded = false;
    page.discarded_bytes = 0;
    return discarded_bytes;
}
