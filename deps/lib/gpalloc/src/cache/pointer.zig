const std = @import("std");

pub fn PointerBin(comptime capacity: u16) type {
    return struct {
        count: usize = 0,
        items: [capacity][*]u8 = undefined,

        const Self = @This();

        pub fn pop(bin: *Self) ?[*]u8 {
            if (bin.count == 0) return null;
            bin.count -= 1;
            return bin.items[bin.count];
        }

        pub fn push(bin: *Self, ptr: [*]u8, limit: usize) bool {
            std.debug.assert(limit <= capacity);
            if (bin.count >= limit) return false;
            bin.items[bin.count] = ptr;
            bin.count += 1;
            return true;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
