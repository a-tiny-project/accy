const std = @import("std");
const observation = @import("observation.zig");

const driver_mod = @import("sys").vulkan;

const Driver = driver_mod.Driver;
const Error = driver_mod.Error;
const VkDevice = driver_mod.VkDevice;
const VkDeviceMemory = driver_mod.VkDeviceMemory;
const VkMappedMemoryRange = driver_mod.VkMappedMemoryRange;
const VkMemoryRequirements = driver_mod.VkMemoryRequirements;
const VkPhysicalDeviceMemoryProperties = driver_mod.VkPhysicalDeviceMemoryProperties;

const preferred_block_bytes: u64 = 64 * 1024 * 1024;

pub const Preference = enum {
    device,
    host,
};

pub const Allocation = struct {
    block_index: usize,
    offset: u64,
    size: u64,
};

const Range = struct {
    offset: u64,
    size: u64,
};

const Block = struct {
    memory: VkDeviceMemory,
    size: u64,
    memory_type_index: u32,
    properties: driver_mod.VkMemoryPropertyFlags,
    mapped: ?[*]u8,
    free_ranges: std.ArrayListUnmanaged(Range) = .empty,
    live_allocations: usize = 0,

    fn deinit(
        self: *Block,
        allocator: std.mem.Allocator,
        driver: *const Driver,
        device: VkDevice,
        observer: ?*observation.AllocationObservation,
        rollback: bool,
    ) void {
        std.debug.assert(self.live_allocations == 0);
        self.free_ranges.deinit(allocator);
        if (self.mapped != null) {
            driver.vkUnmapMemory(device, self.memory);
            observation.release(observer, .mapped_backing, self.size, rollback);
            if (observer) |o| o.memoryReleased(self.memory_type_index, self.size, true, rollback);
        }
        driver.vkFreeMemory(device, self.memory, null);
        observation.release(observer, .backing, self.size, rollback);
        if (observer) |o| o.memoryReleased(self.memory_type_index, self.size, false, rollback);
        self.* = undefined;
    }
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    observer: ?*observation.AllocationObservation = null,
    properties: VkPhysicalDeviceMemoryProperties,
    non_coherent_atom_size: u64,
    blocks: std.ArrayListUnmanaged(Block) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        properties: VkPhysicalDeviceMemoryProperties,
        non_coherent_atom_size: u64,
    ) Pool {
        return .{
            .allocator = allocator,
            .properties = properties,
            .non_coherent_atom_size = @max(non_coherent_atom_size, 1),
        };
    }

    pub fn deinit(self: *Pool, driver: *const Driver, device: VkDevice) void {
        for (self.blocks.items) |*block| block.deinit(self.allocator, driver, device, self.observer, false);
        self.blocks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn allocate(
        self: *Pool,
        driver: *const Driver,
        device: VkDevice,
        requirements: VkMemoryRequirements,
        preference: Preference,
    ) Error!Allocation {
        if (self.observer) |o| o.suballocationAttempt(requirements.size, requirements.alignment);
        errdefer if (self.observer) |o| o.add(&o.suballocations.failures, 1);
        const memory_type_index = memoryTypeForRequirements(self.properties, requirements, preference) orelse {
            return Error.OutOfDeviceMemory;
        };
        for (self.blocks.items, 0..) |block, block_index| {
            if (block.memory_type_index != memory_type_index) continue;
            if (try self.allocateBlockRange(block_index, requirements)) |allocation| return allocation;
        }

        const block_alignment = @max(requirements.alignment, 4096);
        const required_bytes = std.mem.alignForward(u64, requirements.size, block_alignment);
        const memory_type = self.properties.memoryTypes[memory_type_index];
        const heap_size = self.properties.memoryHeaps[memory_type.heapIndex].size;
        const heap_share = if (heap_size == 0) preferred_block_bytes else @max(heap_size / 16, required_bytes);
        const preferred_bytes = @min(preferred_block_bytes, heap_share);
        const block_size = std.mem.alignForward(u64, @max(preferred_bytes, required_bytes), block_alignment);
        const alloc_info = driver_mod.VkMemoryAllocateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = block_size,
            .memoryTypeIndex = memory_type_index,
        };
        var memory: VkDeviceMemory = null;
        try observation.result(self.observer, .backing, block_size, driver.fromResult(driver.vkAllocateMemory(device, &alloc_info, null, &memory)));
        if (self.observer) |o| o.memoryCreated(memory_type_index, memory_type.propertyFlags, block_size, false);

        const properties = self.properties.memoryTypes[memory_type_index].propertyFlags;
        var mapped_base: ?[*]u8 = null;
        if ((properties & driver_mod.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0) {
            var raw_ptr: ?*anyopaque = null;
            observation.attempt(self.observer, .mapped_backing);
            driver.fromResult(driver.vkMapMemory(
                device,
                memory,
                0,
                driver_mod.VK_WHOLE_SIZE,
                0,
                &raw_ptr,
            )) catch |err| {
                observation.failure(self.observer, .mapped_backing);
                driver.vkFreeMemory(device, memory, null);
                observation.release(self.observer, .backing, block_size, true);
                if (self.observer) |o| o.memoryReleased(memory_type_index, block_size, false, true);
                return err;
            };
            mapped_base = @ptrCast(raw_ptr orelse {
                observation.failure(self.observer, .mapped_backing);
                driver.vkFreeMemory(device, memory, null);
                observation.release(self.observer, .backing, block_size, true);
                if (self.observer) |o| o.memoryReleased(memory_type_index, block_size, false, true);
                return Error.MemoryMapFailed;
            });
            observation.success(self.observer, .mapped_backing, block_size);
            if (self.observer) |o| o.memoryCreated(memory_type_index, properties, block_size, true);
        }

        var block = Block{
            .memory = memory,
            .size = block_size,
            .memory_type_index = memory_type_index,
            .properties = properties,
            .mapped = mapped_base,
        };
        var owns_block = true;
        errdefer if (owns_block) block.deinit(self.allocator, driver, device, self.observer, true);
        block.free_ranges.append(self.allocator, .{ .offset = 0, .size = block_size }) catch {
            return Error.OutOfHostMemory;
        };
        self.blocks.append(self.allocator, block) catch return Error.OutOfHostMemory;
        owns_block = false;
        const block_index = self.blocks.items.len - 1;
        return (try self.allocateBlockRange(block_index, requirements)) orelse unreachable;
    }

    pub fn release(self: *Pool, allocation: Allocation) void {
        const block = &self.blocks.items[allocation.block_index];
        std.debug.assert(block.live_allocations != 0);
        block.free_ranges.appendAssumeCapacity(.{ .offset = allocation.offset, .size = allocation.size });
        std.mem.sort(Range, block.free_ranges.items, {}, struct {
            fn lessThan(_: void, a: Range, b: Range) bool {
                return a.offset < b.offset;
            }
        }.lessThan);

        var read_index: usize = 0;
        var write_index: usize = 0;
        while (read_index < block.free_ranges.items.len) : (read_index += 1) {
            const range = block.free_ranges.items[read_index];
            if (write_index != 0) {
                const previous = &block.free_ranges.items[write_index - 1];
                if (previous.offset + previous.size == range.offset) {
                    previous.size += range.size;
                    continue;
                }
            }
            block.free_ranges.items[write_index] = range;
            write_index += 1;
        }
        block.free_ranges.items.len = write_index;
        block.live_allocations -= 1;
        if (self.observer) |o| o.suballocationReleased(block.memory_type_index, allocation.size);
    }

    /// The memory type an allocation's block came from.
    pub fn memoryTypeIndex(self: *const Pool, allocation: Allocation) u32 {
        return self.blocks.items[allocation.block_index].memory_type_index;
    }

    /// The memory type the pool would pick for `requirements`, for memory allocated outside it.
    pub fn typeFor(self: *const Pool, requirements: VkMemoryRequirements, preference: Preference) ?u32 {
        return memoryTypeForRequirements(self.properties, requirements, preference);
    }

    pub fn deviceMemory(self: *const Pool, allocation: Allocation) VkDeviceMemory {
        return self.blocks.items[allocation.block_index].memory;
    }

    pub fn mapped(self: *const Pool, allocation: Allocation) ?[*]u8 {
        const block = self.blocks.items[allocation.block_index];
        const base = block.mapped orelse return null;
        return base + @as(usize, @intCast(allocation.offset));
    }

    pub fn flush(
        self: *const Pool,
        driver: *const Driver,
        device: VkDevice,
        allocation: Allocation,
    ) Error!void {
        const block = self.blocks.items[allocation.block_index];
        if ((block.properties & driver_mod.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0) return;
        var range = self.mappedRange(allocation);
        try driver.fromResult(driver.vkFlushMappedMemoryRanges(device, 1, @ptrCast(&range)));
    }

    pub fn invalidate(
        self: *const Pool,
        driver: *const Driver,
        device: VkDevice,
        allocation: Allocation,
    ) Error!void {
        const block = self.blocks.items[allocation.block_index];
        if ((block.properties & driver_mod.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0) return;
        var range = self.mappedRange(allocation);
        try driver.fromResult(driver.vkInvalidateMappedMemoryRanges(device, 1, @ptrCast(&range)));
    }

    fn allocateBlockRange(
        self: *Pool,
        block_index: usize,
        requirements: VkMemoryRequirements,
    ) Error!?Allocation {
        const block = &self.blocks.items[block_index];
        const alignment = @max(requirements.alignment, 1);
        var range_index: usize = 0;
        while (range_index < block.free_ranges.items.len) : (range_index += 1) {
            const range = block.free_ranges.items[range_index];
            const aligned_offset = std.mem.alignForward(u64, range.offset, alignment);
            const allocation_end = std.math.add(u64, aligned_offset, requirements.size) catch continue;
            const range_end = std.math.add(u64, range.offset, range.size) catch continue;
            if (allocation_end > range_end) continue;

            block.free_ranges.ensureTotalCapacity(
                self.allocator,
                block.free_ranges.items.len + block.live_allocations + 2,
            ) catch return Error.OutOfHostMemory;

            const before_size = aligned_offset - range.offset;
            const after_size = range_end - allocation_end;
            if (before_size != 0 and after_size != 0) {
                block.free_ranges.items[range_index].size = before_size;
                block.free_ranges.appendAssumeCapacity(.{ .offset = allocation_end, .size = after_size });
            } else if (before_size != 0) {
                block.free_ranges.items[range_index].size = before_size;
            } else if (after_size != 0) {
                block.free_ranges.items[range_index] = .{ .offset = allocation_end, .size = after_size };
            } else {
                _ = block.free_ranges.orderedRemove(range_index);
            }
            block.live_allocations += 1;
            if (self.observer) |o| o.suballocationCreated(block.memory_type_index, requirements.size);
            return .{
                .block_index = block_index,
                .offset = aligned_offset,
                .size = requirements.size,
            };
        }
        return null;
    }

    fn mappedRange(self: *const Pool, allocation: Allocation) VkMappedMemoryRange {
        const block = self.blocks.items[allocation.block_index];
        const atom = self.non_coherent_atom_size;
        const start = allocation.offset - allocation.offset % atom;
        const allocation_end = allocation.offset + allocation.size;
        const aligned_end = std.mem.alignForward(u64, allocation_end, atom);
        const end = @min(aligned_end, block.size);
        return .{
            .sType = driver_mod.VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .pNext = null,
            .memory = block.memory,
            .offset = start,
            .size = end - start,
        };
    }
};

pub fn hostVisibleMemoryAvailable(properties: VkPhysicalDeviceMemoryProperties) bool {
    return selectMemoryType(
        properties,
        std.math.maxInt(u32),
        driver_mod.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
        driver_mod.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT |
            driver_mod.VK_MEMORY_PROPERTY_HOST_CACHED_BIT,
        0,
    ) != null;
}

fn memoryTypeForRequirements(
    properties: VkPhysicalDeviceMemoryProperties,
    requirements: VkMemoryRequirements,
    preference: Preference,
) ?u32 {
    return switch (preference) {
        .device => selectMemoryType(
            properties,
            requirements.memoryTypeBits,
            driver_mod.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            driver_mod.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT |
                driver_mod.VK_MEMORY_PROPERTY_HOST_CACHED_BIT,
            driver_mod.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
        ) orelse selectMemoryType(
            properties,
            requirements.memoryTypeBits,
            driver_mod.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
            driver_mod.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT |
                driver_mod.VK_MEMORY_PROPERTY_HOST_CACHED_BIT,
            0,
        ),
        .host => selectMemoryType(
            properties,
            requirements.memoryTypeBits,
            driver_mod.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
            driver_mod.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT |
                driver_mod.VK_MEMORY_PROPERTY_HOST_CACHED_BIT,
            0,
        ),
    };
}

fn selectMemoryType(
    properties: VkPhysicalDeviceMemoryProperties,
    compatible_bits: u32,
    required: driver_mod.VkMemoryPropertyFlags,
    preferred: driver_mod.VkMemoryPropertyFlags,
    avoided: driver_mod.VkMemoryPropertyFlags,
) ?u32 {
    const count = @min(@as(usize, properties.memoryTypeCount), driver_mod.VK_MAX_MEMORY_TYPES);
    var selected: ?u32 = null;
    var selected_preferred_score: u32 = 0;
    var selected_avoided_score: u32 = std.math.maxInt(u32);
    for (properties.memoryTypes[0..count], 0..) |memory_type, index| {
        const shift: u5 = @intCast(index);
        if ((compatible_bits & (@as(u32, 1) << shift)) == 0) continue;
        if ((memory_type.propertyFlags & required) != required) continue;
        const preferred_score: u32 = @popCount(memory_type.propertyFlags & preferred);
        const avoided_score: u32 = @popCount(memory_type.propertyFlags & avoided);
        if (selected == null or
            avoided_score < selected_avoided_score or
            (avoided_score == selected_avoided_score and preferred_score > selected_preferred_score))
        {
            selected = @intCast(index);
            selected_preferred_score = preferred_score;
            selected_avoided_score = avoided_score;
        }
    }
    return selected;
}

test "device allocation prefers unmapped device-local memory" {
    var properties = std.mem.zeroes(VkPhysicalDeviceMemoryProperties);
    properties.memoryTypeCount = 2;
    properties.memoryTypes[0] = .{
        .propertyFlags = driver_mod.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT |
            driver_mod.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
            driver_mod.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        .heapIndex = 0,
    };
    properties.memoryTypes[1] = .{
        .propertyFlags = driver_mod.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .heapIndex = 0,
    };
    const requirements = VkMemoryRequirements{
        .size = 16,
        .alignment = 16,
        .memoryTypeBits = 0b11,
    };

    try std.testing.expectEqual(@as(?u32, 1), memoryTypeForRequirements(properties, requirements, .device));
}

test "host allocation respects requirement compatibility" {
    var properties = std.mem.zeroes(VkPhysicalDeviceMemoryProperties);
    properties.memoryTypeCount = 2;
    properties.memoryTypes[0] = .{
        .propertyFlags = driver_mod.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
            driver_mod.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        .heapIndex = 0,
    };
    properties.memoryTypes[1] = .{
        .propertyFlags = driver_mod.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .heapIndex = 0,
    };
    const requirements = VkMemoryRequirements{
        .size = 16,
        .alignment = 16,
        .memoryTypeBits = 0b10,
    };

    try std.testing.expectEqual(@as(?u32, null), memoryTypeForRequirements(properties, requirements, .host));
}
