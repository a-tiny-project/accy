const std = @import("std");

const Allocator = std.mem.Allocator;

const TestInfo = struct {
    name: []const u8,

    pub fn init(name: []const u8) TestInfo {
        return .{ .name = name };
    }

    pub fn deinit(_: *TestInfo, _: Allocator) void {}
};

const TestInlineInfo = struct {
    name: []const u8,
    first_items: []u64,
    second_items: []u32,
    third_items: []u16,
    fourth_items: []u8,

    pub fn initEntryStorage(
        name: []const u8,
        first_storage: *[4]u64,
        second_storage: *[2]u32,
        third_storage: []u16,
        fourth_storage: []u8,
    ) TestInlineInfo {
        return .{
            .name = name,
            .first_items = first_storage[0..0],
            .second_items = second_storage[0..0],
            .third_items = third_storage[0..0],
            .fourth_items = fourth_storage[0..0],
        };
    }

    pub fn deinit(_: *TestInlineInfo, _: Allocator) void {}
};

pub fn InlineList(comptime Item: type, comptime inline_capacity: usize) type {
    const inline_mask = @as(usize, 1) << (@bitSizeOf(usize) - 1);

    return struct {
        const Self = @This();

        slice: []Item = &.{},
        capacity_and_inline: usize = 0,

        pub fn initInline(storage: *[inline_capacity]Item) Self {
            return initBorrowed(storage);
        }

        pub fn initBorrowed(storage: []Item) Self {
            std.debug.assert(storage.len & inline_mask == 0);
            return .{
                .slice = storage[0..0],
                .capacity_and_inline = inline_mask | storage.len,
            };
        }

        pub fn initBorrowedValues(storage: []Item, values_to_copy: []const Item) Self {
            std.debug.assert(storage.len & inline_mask == 0);
            std.debug.assert(values_to_copy.len <= storage.len);
            @memcpy(storage[0..values_to_copy.len], values_to_copy);
            return .{
                .slice = storage[0..values_to_copy.len],
                .capacity_and_inline = inline_mask | storage.len,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (!self.isInline() and self.capacity() > 0) {
                allocator.free(self.slice.ptr[0..self.capacity()]);
            }
            self.* = .{};
        }

        pub fn append(self: *Self, allocator: Allocator, item: Item) Allocator.Error!void {
            const capacity_value = self.capacity();
            if (self.slice.len < capacity_value) {
                self.slice.ptr[self.slice.len] = item;
                self.slice.len += 1;
                return;
            }

            if (self.isInline()) {
                std.debug.assert(self.slice.len == capacity_value);
                const heap_capacity = std.math.add(usize, capacity_value, 1) catch {
                    return error.OutOfMemory;
                };
                const heap_items = try allocator.alloc(Item, heap_capacity);
                errdefer allocator.free(heap_items);
                @memcpy(heap_items[0..capacity_value], self.slice);
                heap_items[capacity_value] = item;
                self.slice = heap_items;
                self.capacity_and_inline = heap_items.len;
                return;
            }

            var heap: std.ArrayListUnmanaged(Item) = .{
                .items = self.slice,
                .capacity = capacity_value,
                .pointer_stability = .{},
            };
            try heap.append(allocator, item);
            std.debug.assert(heap.capacity & inline_mask == 0);
            self.slice = heap.items;
            self.capacity_and_inline = heap.capacity;
        }

        pub fn values(self: *const Self) []const Item {
            return self.slice;
        }

        pub fn valuesMut(self: *Self) []Item {
            return self.slice;
        }

        fn capacity(self: *const Self) usize {
            return self.capacity_and_inline & ~inline_mask;
        }

        fn isInline(self: *const Self) bool {
            return self.capacity_and_inline & inline_mask != 0;
        }
    };
}

pub fn Storage(comptime Info: type) type {
    const alignment = std.mem.Alignment.fromByteUnits(@alignOf(Info));

    return struct {
        const Self = @This();

        pub fn capacity(name_len: usize) error{CapacityOverflow}!usize {
            return std.math.add(usize, @sizeOf(Info), name_len) catch error.CapacityOverflow;
        }

        pub fn create(allocator: Allocator, name: []const u8) Allocator.Error!*Info {
            const total_bytes = Self.capacity(name.len) catch return error.OutOfMemory;
            std.debug.assert(total_bytes >= @sizeOf(Info));
            const bytes = allocator.rawAlloc(
                total_bytes,
                alignment,
                @returnAddress(),
            ) orelse return error.OutOfMemory;
            const info: *Info = @ptrCast(@alignCast(bytes));
            const owned_name = bytes[@sizeOf(Info)..total_bytes];
            std.debug.assert(owned_name.len == name.len);
            @memcpy(owned_name, name);
            info.* = Info.init(owned_name);
            return info;
        }

        pub fn destroy(allocator: Allocator, info: *Info) void {
            const total_bytes = Self.capacity(info.name.len) catch unreachable;
            const bytes: [*]u8 = @ptrCast(info);
            const name_address = std.math.add(
                usize,
                @intFromPtr(info),
                @sizeOf(Info),
            ) catch unreachable;
            std.debug.assert(name_address == @intFromPtr(info.name.ptr));
            info.deinit(allocator);
            info.* = undefined;
            allocator.rawFree(bytes[0..total_bytes], alignment, @returnAddress());
        }
    };
}

pub fn BatchStorage(comptime Info: type) type {
    const Region = struct {
        next: ?*@This(),
        total_bytes: usize,
    };
    const alignment = std.mem.Alignment.fromByteUnits(@max(@alignOf(Region), @alignOf(Info)));
    const infos_offset = std.mem.alignForward(usize, @sizeOf(Region), @alignOf(Info));

    return struct {
        const Self = @This();

        pub const RegionOwner = Region;

        pub const Allocation = struct {
            region: *RegionOwner,
            infos: []Info,
            names: []u8,
        };

        pub fn capacity(info_count: usize, name_bytes: usize) error{CapacityOverflow}!usize {
            const info_bytes = std.math.mul(
                usize,
                info_count,
                @sizeOf(Info),
            ) catch return error.CapacityOverflow;
            const names_offset = std.math.add(
                usize,
                infos_offset,
                info_bytes,
            ) catch return error.CapacityOverflow;
            return std.math.add(usize, names_offset, name_bytes) catch error.CapacityOverflow;
        }

        pub fn create(
            allocator: Allocator,
            info_count: usize,
            name_bytes: usize,
        ) Allocator.Error!Allocation {
            std.debug.assert(info_count > 0);
            const total_bytes = Self.capacity(info_count, name_bytes) catch return error.OutOfMemory;
            const bytes = allocator.rawAlloc(
                total_bytes,
                alignment,
                @returnAddress(),
            ) orelse return error.OutOfMemory;
            const region: *RegionOwner = @ptrCast(@alignCast(bytes));
            const infos_ptr: [*]Info = @ptrCast(@alignCast(bytes + infos_offset));
            const infos = infos_ptr[0..info_count];
            const names_offset = infos_offset + info_count * @sizeOf(Info);
            const names = bytes[names_offset..total_bytes];
            std.debug.assert(names.len == name_bytes);
            region.* = .{
                .next = null,
                .total_bytes = total_bytes,
            };
            return .{
                .region = region,
                .infos = infos,
                .names = names,
            };
        }

        pub fn contains(region: *const RegionOwner, info: *const Info) bool {
            const region_address = @intFromPtr(region);
            const end_address = std.math.add(
                usize,
                region_address,
                region.total_bytes,
            ) catch unreachable;
            const info_address = @intFromPtr(info);
            const first_info_address = std.math.add(
                usize,
                region_address,
                infos_offset,
            ) catch unreachable;
            return info_address >= first_info_address and info_address < end_address;
        }

        pub fn destroy(allocator: Allocator, region: *RegionOwner) void {
            const bytes: [*]u8 = @ptrCast(region);
            allocator.rawFree(bytes[0..region.total_bytes], alignment, @returnAddress());
        }
    };
}

pub fn InlineStorage(
    comptime Info: type,
    comptime FirstItem: type,
    comptime first_capacity: usize,
    comptime SecondItem: type,
    comptime second_capacity: usize,
    comptime ThirdItem: type,
    comptime FourthItem: type,
) type {
    const alignment_bytes = @max(
        @alignOf(Info),
        @max(
            @alignOf(FirstItem),
            @max(@alignOf(SecondItem), @max(@alignOf(ThirdItem), @alignOf(FourthItem))),
        ),
    );
    const alignment = std.mem.Alignment.fromByteUnits(alignment_bytes);
    const first_offset = std.mem.alignForward(usize, @sizeOf(Info), @alignOf(FirstItem));
    const first_bytes = @sizeOf([first_capacity]FirstItem);
    const second_offset = std.mem.alignForward(
        usize,
        first_offset + first_bytes,
        @alignOf(SecondItem),
    );
    const second_bytes = @sizeOf([second_capacity]SecondItem);
    const third_offset = std.mem.alignForward(
        usize,
        second_offset + second_bytes,
        @alignOf(ThirdItem),
    );

    return struct {
        const Self = @This();

        pub const BatchStorage = struct {
            const Region = struct {
                next: ?*@This(),
                total_bytes: usize,
            };
            const region_alignment = std.mem.Alignment.fromByteUnits(
                @max(@alignOf(Region), alignment_bytes),
            );
            const entries_offset = std.mem.alignForward(
                usize,
                @sizeOf(Region),
                alignment_bytes,
            );

            pub const RegionOwner = Region;

            pub const Capacity = struct {
                entry_count: usize = 0,
                total_bytes: usize = entries_offset,

                pub fn add(
                    self: *@This(),
                    name_len: usize,
                    third_capacity: usize,
                    fourth_capacity: usize,
                ) error{CapacityOverflow}!void {
                    const entry_bytes = try Self.capacity(
                        name_len,
                        third_capacity,
                        fourth_capacity,
                    );
                    const entry_offset = try Self.alignForward(
                        self.total_bytes,
                        alignment_bytes,
                    );
                    const total_bytes = std.math.add(
                        usize,
                        entry_offset,
                        entry_bytes,
                    ) catch return error.CapacityOverflow;
                    const entry_count = std.math.add(
                        usize,
                        self.entry_count,
                        1,
                    ) catch return error.CapacityOverflow;
                    self.total_bytes = total_bytes;
                    self.entry_count = entry_count;
                }
            };

            pub const Allocation = struct {
                region: *RegionOwner,
                entries: []u8,
            };

            pub const Cursor = struct {
                entries: []u8,
                offset: usize = 0,

                pub fn init(entries: []u8) Cursor {
                    return .{ .entries = entries };
                }

                pub fn create(
                    self: *Cursor,
                    name: []const u8,
                    third_capacity: usize,
                    fourth_capacity: usize,
                ) *Info {
                    const entry_offset = Self.alignForward(
                        self.offset,
                        alignment_bytes,
                    ) catch unreachable;
                    const entry_bytes = Self.capacity(
                        name.len,
                        third_capacity,
                        fourth_capacity,
                    ) catch unreachable;
                    const entry_end = std.math.add(
                        usize,
                        entry_offset,
                        entry_bytes,
                    ) catch unreachable;
                    std.debug.assert(entry_end <= self.entries.len);
                    const info = Self.initInPlace(
                        self.entries[entry_offset..entry_end],
                        name,
                        third_capacity,
                        fourth_capacity,
                    );
                    self.offset = entry_end;
                    return info;
                }
            };

            pub fn create(
                allocator: Allocator,
                capacity_value: Capacity,
            ) Allocator.Error!Allocation {
                std.debug.assert(capacity_value.entry_count > 0);
                const bytes = allocator.rawAlloc(
                    capacity_value.total_bytes,
                    region_alignment,
                    @returnAddress(),
                ) orelse return error.OutOfMemory;
                const region: *RegionOwner = @ptrCast(@alignCast(bytes));
                region.* = .{
                    .next = null,
                    .total_bytes = capacity_value.total_bytes,
                };
                return .{
                    .region = region,
                    .entries = bytes[entries_offset..capacity_value.total_bytes],
                };
            }

            pub fn contains(region: *const RegionOwner, info: *const Info) bool {
                const region_address = @intFromPtr(region);
                const end_address = std.math.add(
                    usize,
                    region_address,
                    region.total_bytes,
                ) catch unreachable;
                const first_entry_address = std.math.add(
                    usize,
                    region_address,
                    entries_offset,
                ) catch unreachable;
                const info_address = @intFromPtr(info);
                return info_address >= first_entry_address and info_address < end_address;
            }

            pub fn destroy(allocator: Allocator, region: *RegionOwner) void {
                const bytes: [*]u8 = @ptrCast(region);
                allocator.rawFree(
                    bytes[0..region.total_bytes],
                    region_alignment,
                    @returnAddress(),
                );
            }
        };

        const Layout = struct {
            fourth_offset: usize,
            name_offset: usize,
            total_bytes: usize,
        };

        fn alignForward(value: usize, comptime item_alignment: usize) error{CapacityOverflow}!usize {
            const mask = item_alignment - 1;
            const adjusted = std.math.add(usize, value, mask) catch return error.CapacityOverflow;
            return adjusted & ~mask;
        }

        fn layout(
            name_len: usize,
            third_capacity: usize,
            fourth_capacity: usize,
        ) error{CapacityOverflow}!Layout {
            const third_bytes = std.math.mul(
                usize,
                third_capacity,
                @sizeOf(ThirdItem),
            ) catch return error.CapacityOverflow;
            const third_end = std.math.add(
                usize,
                third_offset,
                third_bytes,
            ) catch return error.CapacityOverflow;
            const fourth_offset = try alignForward(third_end, @alignOf(FourthItem));
            const fourth_bytes = std.math.mul(
                usize,
                fourth_capacity,
                @sizeOf(FourthItem),
            ) catch return error.CapacityOverflow;
            const name_offset = std.math.add(
                usize,
                fourth_offset,
                fourth_bytes,
            ) catch return error.CapacityOverflow;
            const total_bytes = std.math.add(
                usize,
                name_offset,
                name_len,
            ) catch return error.CapacityOverflow;
            return .{
                .fourth_offset = fourth_offset,
                .name_offset = name_offset,
                .total_bytes = total_bytes,
            };
        }

        pub fn capacity(
            name_len: usize,
            third_capacity: usize,
            fourth_capacity: usize,
        ) error{CapacityOverflow}!usize {
            return (try layout(name_len, third_capacity, fourth_capacity)).total_bytes;
        }

        pub fn create(
            allocator: Allocator,
            name: []const u8,
            third_capacity: usize,
            fourth_capacity: usize,
        ) Allocator.Error!*Info {
            const entry_layout = Self.layout(
                name.len,
                third_capacity,
                fourth_capacity,
            ) catch return error.OutOfMemory;
            const bytes = allocator.rawAlloc(
                entry_layout.total_bytes,
                alignment,
                @returnAddress(),
            ) orelse return error.OutOfMemory;
            return initialize(
                bytes[0..entry_layout.total_bytes],
                entry_layout,
                name,
                third_capacity,
                fourth_capacity,
            );
        }

        pub fn initInPlace(
            bytes: []u8,
            name: []const u8,
            third_capacity: usize,
            fourth_capacity: usize,
        ) *Info {
            const entry_layout = Self.layout(
                name.len,
                third_capacity,
                fourth_capacity,
            ) catch unreachable;
            std.debug.assert(bytes.len == entry_layout.total_bytes);
            std.debug.assert(@intFromPtr(bytes.ptr) % alignment_bytes == 0);
            return initialize(
                bytes,
                entry_layout,
                name,
                third_capacity,
                fourth_capacity,
            );
        }

        fn initialize(
            bytes: []u8,
            entry_layout: Layout,
            name: []const u8,
            third_capacity: usize,
            fourth_capacity: usize,
        ) *Info {
            const info: *Info = @ptrCast(@alignCast(bytes));
            const first_items: *[first_capacity]FirstItem = @ptrCast(@alignCast(bytes.ptr + first_offset));
            const second_items: *[second_capacity]SecondItem = @ptrCast(@alignCast(bytes.ptr + second_offset));
            const third_items_ptr: [*]ThirdItem = @ptrCast(@alignCast(bytes.ptr + third_offset));
            const third_items = third_items_ptr[0..third_capacity];
            const fourth_items_ptr: [*]FourthItem = @ptrCast(
                @alignCast(bytes.ptr + entry_layout.fourth_offset),
            );
            const fourth_items = fourth_items_ptr[0..fourth_capacity];
            const owned_name = bytes[entry_layout.name_offset..entry_layout.total_bytes];
            std.debug.assert(owned_name.len == name.len);
            @memcpy(owned_name, name);
            info.* = Info.initEntryStorage(
                owned_name,
                first_items,
                second_items,
                third_items,
                fourth_items,
            );
            return info;
        }

        pub fn destroy(allocator: Allocator, info: *Info) void {
            const bytes: [*]u8 = @ptrCast(info);
            const minimum_name_address = std.math.add(
                usize,
                @intFromPtr(info),
                third_offset,
            ) catch unreachable;
            const name_address = @intFromPtr(info.name.ptr);
            std.debug.assert(name_address >= minimum_name_address);
            const end_address = std.math.add(
                usize,
                name_address,
                info.name.len,
            ) catch unreachable;
            const total_bytes = std.math.sub(
                usize,
                end_address,
                @intFromPtr(info),
            ) catch unreachable;
            info.deinit(allocator);
            info.* = undefined;
            allocator.rawFree(bytes[0..total_bytes], alignment, @returnAddress());
        }
    };
}
