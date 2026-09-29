const std = @import("std");

const Allocator = std.mem.Allocator;
pub const Sequence = u64;

pub const Record = struct {
    address: usize = 0,
    len: usize = 0,
    allocation_sequence: Sequence = 0,
    allocation_return_address: usize = 0,
    resize_return_address: usize = 0,
    remap_return_address: usize = 0,
    free_sequence: Sequence = 0,
    free_return_address: usize = 0,
    active: bool = false,
};

pub const AllocationLedger = struct {
    backing: Allocator,
    records: []Record,
    count: usize = 0,
    sequence: Sequence = 0,

    pub fn init(backing: Allocator, records: []Record) AllocationLedger {
        std.debug.assert(records.len != 0);
        return .{
            .backing = backing,
            .records = records,
        };
    }

    pub fn allocator(self: *AllocationLedger) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn exhausted(self: *const AllocationLedger) bool {
        return self.count == self.records.len;
    }

    pub fn allocationCount(self: *const AllocationLedger) usize {
        return self.count;
    }

    pub fn allocation(
        self: *const AllocationLedger,
        id: usize,
    ) Record {
        std.debug.assert(id < self.count);
        return self.records[id];
    }

    pub fn allocationContaining(
        self: *const AllocationLedger,
        pointer: anytype,
        len: usize,
    ) ?usize {
        const address = @intFromPtr(pointer);
        var index = self.count;
        while (index != 0) {
            index -= 1;
            if (rangeContains(self.records[index], address, len)) return index;
        }
        return null;
    }

    pub fn liveAllocationContaining(
        self: *const AllocationLedger,
        pointer: anytype,
        len: usize,
    ) ?usize {
        const address = @intFromPtr(pointer);
        var index = self.count;
        while (index != 0) {
            index -= 1;
            const record = self.records[index];
            if (record.active and rangeContains(record, address, len)) {
                return index;
            }
        }
        return null;
    }

    pub fn isActive(
        self: *const AllocationLedger,
        id: usize,
    ) bool {
        return self.allocation(id).active;
    }

    pub fn freeSequence(
        self: *const AllocationLedger,
        id: usize,
    ) Sequence {
        const record = self.allocation(id);
        std.debug.assert(!record.active);
        return record.free_sequence;
    }

    fn nextSequence(self: *AllocationLedger) Sequence {
        std.debug.assert(self.sequence != std.math.maxInt(Sequence));
        self.sequence += 1;
        return self.sequence;
    }

    fn append(
        self: *AllocationLedger,
        pointer: [*]u8,
        len: usize,
        return_address: usize,
    ) void {
        std.debug.assert(self.count < self.records.len);
        self.records[self.count] = .{
            .address = @intFromPtr(pointer),
            .len = len,
            .allocation_sequence = self.nextSequence(),
            .allocation_return_address = return_address,
            .active = true,
        };
        self.count += 1;
    }

    fn findActiveExact(
        self: *const AllocationLedger,
        pointer: [*]u8,
    ) usize {
        const address = @intFromPtr(pointer);
        var index = self.count;
        while (index != 0) {
            index -= 1;
            const record = self.records[index];
            if (record.active and record.address == address) return index;
        }
        unreachable;
    }

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *AllocationLedger = @ptrCast(@alignCast(context));
        if (self.exhausted()) return null;
        const result = self.backing.rawAlloc(
            len,
            alignment,
            return_address,
        ) orelse return null;
        self.append(result, len, return_address);
        return result;
    }

    fn rawResize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *AllocationLedger = @ptrCast(@alignCast(context));
        const resized = self.backing.rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
        if (resized) {
            const id = self.findActiveExact(memory.ptr);
            _ = self.nextSequence();
            self.records[id].len = new_len;
            self.records[id].resize_return_address = return_address;
        }
        return resized;
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *AllocationLedger = @ptrCast(@alignCast(context));
        const id = self.findActiveExact(memory.ptr);
        const result = self.backing.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse return null;
        _ = self.nextSequence();
        self.records[id].address = @intFromPtr(result);
        self.records[id].len = new_len;
        self.records[id].remap_return_address = return_address;
        return result;
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *AllocationLedger = @ptrCast(@alignCast(context));
        const id = self.findActiveExact(memory.ptr);
        self.backing.rawFree(memory, alignment, return_address);
        const sequence = self.nextSequence();
        self.records[id].active = false;
        self.records[id].free_sequence = sequence;
        self.records[id].free_return_address = return_address;
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };
};

fn rangeContains(record: Record, address: usize, len: usize) bool {
    if (address < record.address) return false;
    const end = std.math.add(usize, address, len) catch return false;
    const record_end = std.math.add(
        usize,
        record.address,
        record.len,
    ) catch return false;
    return end <= record_end;
}

test "allocation ledger attributes ranges and teardown order" {
    const testing = std.testing;
    var records: [4]Record = undefined;
    var ledger = AllocationLedger.init(testing.allocator, &records);
    const allocator = ledger.allocator();
    const first = try allocator.alloc(u8, 64);
    const second = try allocator.alloc(u8, 128);
    const first_id = ledger.liveAllocationContaining(
        first.ptr + 7,
        8,
    ) orelse return error.TestUnexpectedResult;
    const second_id = ledger.liveAllocationContaining(
        second.ptr + 31,
        16,
    ) orelse return error.TestUnexpectedResult;
    try testing.expect(first_id != second_id);
    try testing.expect(
        ledger.allocation(first_id).allocation_return_address != 0,
    );
    allocator.free(second);
    allocator.free(first);
    try testing.expect(!ledger.isActive(first_id));
    try testing.expect(!ledger.isActive(second_id));
    try testing.expect(
        ledger.freeSequence(second_id) < ledger.freeSequence(first_id),
    );
}

test "allocation ledger applies its caller-provided record bound" {
    const testing = std.testing;
    var records: [1]Record = undefined;
    var ledger = AllocationLedger.init(testing.allocator, &records);
    const allocator = ledger.allocator();
    const first = try allocator.alloc(u8, 1);
    defer allocator.free(first);
    try testing.expect(ledger.exhausted());
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
}

test "allocation ledger tracks successful resize and remap operations" {
    const testing = std.testing;
    var backing_storage: [256]u8 = undefined;
    var backing = std.heap.FixedBufferAllocator.init(&backing_storage);
    var records: [1]Record = undefined;
    var ledger = AllocationLedger.init(backing.allocator(), &records);
    const allocator = ledger.allocator();
    var memory = try allocator.alloc(u8, 64);
    const id = ledger.liveAllocationContaining(
        memory.ptr,
        memory.len,
    ) orelse return error.TestUnexpectedResult;

    try testing.expect(!allocator.resize(memory, backing_storage.len + 1));
    try testing.expectEqual(@as(usize, 64), ledger.allocation(id).len);
    try testing.expectEqual(@as(usize, 0), ledger.allocation(id).resize_return_address);
    try testing.expect(allocator.resize(memory, 96));
    memory = memory.ptr[0..96];
    try testing.expectEqual(@as(usize, 96), ledger.allocation(id).len);
    try testing.expect(ledger.allocation(id).resize_return_address != 0);

    try testing.expect(allocator.remap(memory, backing_storage.len + 1) == null);
    try testing.expectEqual(@intFromPtr(memory.ptr), ledger.allocation(id).address);
    try testing.expectEqual(@as(usize, 96), ledger.allocation(id).len);
    try testing.expectEqual(@as(usize, 0), ledger.allocation(id).remap_return_address);
    memory = allocator.remap(memory, 128) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@intFromPtr(memory.ptr), ledger.allocation(id).address);
    try testing.expectEqual(@as(usize, 128), ledger.allocation(id).len);
    try testing.expect(ledger.allocation(id).remap_return_address != 0);
    try testing.expect(ledger.isActive(id));

    allocator.free(memory);
    try testing.expect(!ledger.isActive(id));
}
