const std = @import("std");
const reserve = @import("reserve.zig");

const Allocator = std.mem.Allocator;
const Reserve = reserve.Reserve;

pub const Router = struct {
    backing: Allocator,
    limits: Reserve.Limits,
    reserve: Reserve,
    state: State,

    pub const State = enum { unprovisioned, active, unavailable, finished };

    pub fn init(backing: Allocator, limits: Reserve.Limits) Router {
        return .{
            .backing = backing,
            .limits = limits,
            .reserve = undefined,
            .state = .unprovisioned,
        };
    }

    pub fn allocator(self: *Router) Allocator {
        std.debug.assert(self.state != .finished);
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn finish(self: *Router) void {
        std.debug.assert(self.state != .finished);
        const active = self.state == .active;
        self.state = .finished;
        if (!active) return;
        std.debug.assert(self.reserve.phase == .steady);
        if (self.reserve.held != 0) return;
        self.reserve.deinit(self.backing);
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn provision(self: *Router) ?*Reserve {
        switch (self.state) {
            .active => return &self.reserve,
            .unavailable => return null,
            .unprovisioned => {},
            .finished => unreachable,
        }
        std.debug.assert(self.state == .unprovisioned);
        self.reserve = Reserve.init(self.backing, self.limits) catch |err| switch (err) {
            error.OutOfMemory => {
                self.state = .unavailable;
                return null;
            },
            error.InvalidLimit => unreachable,
        };
        self.reserve.activate();
        std.debug.assert(self.reserve.held == 0);
        self.state = .active;
        return &self.reserve;
    }

    fn holder(self: *Router, memory: []const u8) ?*Reserve {
        std.debug.assert(self.state != .finished);
        if (self.state != .active) return null;
        if (!self.reserve.owns(memory)) return null;
        return &self.reserve;
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Router = @ptrCast(@alignCast(context));
        std.debug.assert(self.state != .finished);
        std.debug.assert(len > 0);
        if (len == reserve.page_bytes and alignment == reserve.page_alignment) {
            if (self.provision()) |pages| {
                if (pages.acquire()) |page| return page.ptr else |err| switch (err) {
                    error.PageReserveFull => {},
                }
            }
        }
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *Router = @ptrCast(@alignCast(context));
        std.debug.assert(memory.len > 0);
        std.debug.assert(new_len > 0);
        if (self.holder(memory) != null) return new_len == memory.len;
        return self.backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Router = @ptrCast(@alignCast(context));
        std.debug.assert(memory.len > 0);
        std.debug.assert(new_len > 0);
        if (self.holder(memory) != null) {
            return if (new_len == memory.len) memory.ptr else null;
        }
        return self.backing.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *Router = @ptrCast(@alignCast(context));
        std.debug.assert(memory.len > 0);
        const pages = self.holder(memory) orelse {
            return self.backing.rawFree(memory, alignment, return_address);
        };
        std.debug.assert(alignment == reserve.page_alignment);
        pages.release(memory);
    }
};

const page_bytes = reserve.page_bytes;
const page_alignment = reserve.page_alignment;

fn requestPage(allocator: Allocator) ![]u8 {
    const bytes = allocator.rawAlloc(page_bytes, page_alignment, @returnAddress());
    return (bytes orelse return error.OutOfMemory)[0..page_bytes];
}
