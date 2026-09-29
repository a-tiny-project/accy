const std = @import("std");

pub const Error = error{
    CapacityOverflow,
    SampleSetStorageTooSmall,
};

pub const Cursor = struct {
    values: []u64,
    offset: usize = 0,

    pub fn init(values: []u64) Cursor {
        return .{ .values = values };
    }

    pub fn take(
        self: *Cursor,
        comptime set_count: usize,
        sample_count: u32,
    ) Error![set_count][]u64 {
        std.debug.assert(self.offset <= self.values.len);
        const required = try valueCapacity(set_count, sample_count);
        if (required > self.values.len - self.offset) return error.SampleSetStorageTooSmall;
        const end = self.offset + required;
        const result = try partition(set_count, self.values[self.offset..end], sample_count);
        self.offset = end;
        return result;
    }

    pub fn complete(self: *const Cursor) bool {
        std.debug.assert(self.offset <= self.values.len);
        return self.offset == self.values.len;
    }
};

pub fn valueCapacity(comptime set_count: usize, sample_count: u32) Error!usize {
    return std.math.mul(usize, set_count, sample_count) catch error.CapacityOverflow;
}

pub fn partition(
    comptime set_count: usize,
    values: []u64,
    sample_count: u32,
) Error![set_count][]u64 {
    const required = try valueCapacity(set_count, sample_count);
    if (values.len < required) return error.SampleSetStorageTooSmall;
    const used = values[0..required];
    @memset(used, 0);
    var result: [set_count][]u64 = undefined;
    for (&result, 0..) |*set, index| {
        const start = index * @as(usize, sample_count);
        set.* = used[start..][0..sample_count];
    }
    return result;
}
