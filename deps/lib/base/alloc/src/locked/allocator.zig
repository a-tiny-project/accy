const std = @import("std");
const sys = @import("sys");

pub const LockedAllocator = struct {
    child: std.mem.Allocator,
    mutex: sys.thread.Mutex = .{},

    pub fn init(child: std.mem.Allocator) LockedAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *LockedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.child.rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.child.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *LockedAllocator = @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.child.rawFree(memory, alignment, return_address);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};
