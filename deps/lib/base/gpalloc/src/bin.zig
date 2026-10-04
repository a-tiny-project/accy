const std = @import("std");
const cache = @import("cache/root.zig");
const page_mod = @import("page/root.zig");

const Page = page_mod.Page;
const TransferCacheBin = cache.PointerBin(cache.transfer_capacity);

pub const Bin = struct {
    all: ?*Page = null,
    partial: ?*Page = null,
    local_transfer: TransferCacheBin = .{},
    empty_count: usize = 0,

    pub fn addPage(bin: *Bin, page: *Page) void {
        page.next_all = bin.all;
        page.previous_all = null;
        if (bin.all) |head| head.previous_all = page;
        bin.all = page;
        bin.pushPartial(page);
    }

    pub fn pushPartial(bin: *Bin, page: *Page) void {
        page.next_partial = bin.partial;
        bin.partial = page;
    }

    pub fn popIfFull(bin: *Bin, page: *Page) void {
        if (page.free_count != 0) return;
        std.debug.assert(bin.partial == page);
        bin.partial = page.next_partial;
        page.next_partial = null;
    }

    pub fn removePartial(bin: *Bin, page: *Page) void {
        var link: *?*Page = &bin.partial;
        while (link.*) |current| {
            if (current == page) {
                link.* = current.next_partial;
                current.next_partial = null;
                return;
            }
            link = &current.next_partial;
        }
    }

    pub fn removeAll(bin: *Bin, page: *Page) void {
        if (page.previous_all) |previous| {
            previous.next_all = page.next_all;
        } else {
            std.debug.assert(bin.all == page);
            bin.all = page.next_all;
        }
        if (page.next_all) |next| next.previous_all = page.previous_all;
        page.next_all = null;
        page.previous_all = null;
    }

    pub fn clear(bin: *Bin) void {
        bin.all = null;
        bin.partial = null;
        bin.local_transfer.count = 0;
        bin.empty_count = 0;
    }
};

test {
    std.testing.refAllDecls(@This());
}
