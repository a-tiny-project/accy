const std = @import("std");
const vk = @import("sys").vulkan;
const runtime = @import("runtime.zig");
const launch = @import("launch.zig");

pub const Error = vk.Error;
const all_commands: u64 = 0x10000;
pub const max_dispatches: usize = 16;

pub const Dispatch = struct {
    kernel: *launch.Kernel,
    buffers: []const *runtime.DeviceBuffer,
    push_constants: []const u8,
    grid: [3]u32,
    threadgroup: [3]u32,
};

pub const Sequence = struct {
    rt: *runtime.Runtime,
    command_pool: vk.VkCommandPool,
    descriptor_pool: vk.VkDescriptorPool,
    command_buffer: vk.VkCommandBuffer,

    pub fn record(rt: *runtime.Runtime, dispatches: []const Dispatch, failed_index: *?usize) Error!Sequence {
        failed_index.* = null;
        std.debug.assert(dispatches.len > 0);
        std.debug.assert(dispatches.len <= max_dispatches);
        const drv = &rt._driver;
        const pool_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = rt.device.queueFamilyIndex(),
        };
        var command_pool: vk.VkCommandPool = null;
        try drv.fromResult(drv.vkCreateCommandPool(rt._logical_device, &pool_info, null, &command_pool));
        errdefer drv.vkDestroyCommandPool(rt._logical_device, command_pool, null);
        const pool_size = [_]vk.VkDescriptorPoolSize{.{
            .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = max_dispatches * runtime.max_buffers_per_set,
        }};
        const descriptor_info = vk.VkDescriptorPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = max_dispatches,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };
        var descriptor_pool: vk.VkDescriptorPool = null;
        try drv.fromResult(drv.vkCreateDescriptorPool(rt._logical_device, &descriptor_info, null, &descriptor_pool));
        errdefer drv.vkDestroyDescriptorPool(rt._logical_device, descriptor_pool, null);
        const allocate_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var cb: vk.VkCommandBuffer = null;
        try drv.fromResult(drv.vkAllocateCommandBuffers(rt._logical_device, &allocate_info, @ptrCast(&cb)));
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT,
            .pInheritanceInfo = null,
        };
        try drv.fromResult(drv.vkBeginCommandBuffer(cb, &begin_info));
        for (dispatches, 0..) |dispatch, index| {
            failed_index.* = index;
            if (dispatch.buffers.len != dispatch.kernel.num_buffers or
                dispatch.push_constants.len > dispatch.kernel.push_constant_size or
                dispatch.push_constants.len % 4 != 0) return error.InitializationFailed;
            if (index != 0) {
                const barrier = vk.VkMemoryBarrier{
                    .srcAccessMask = vk.VK_ACCESS_SHADER_WRITE_BIT,
                    .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT | vk.VK_ACCESS_SHADER_WRITE_BIT,
                };
                drv.vkCmdPipelineBarrier(
                    cb,
                    vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                    vk.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                    0,
                    1,
                    @ptrCast(&barrier),
                    0,
                    null,
                    0,
                    null,
                );
            }
            const pipeline = try dispatch.kernel.pipelineForWorkgroup(dispatch.threadgroup);
            var layout = dispatch.kernel._set_layout;
            const set_info = vk.VkDescriptorSetAllocateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                .pNext = null,
                .descriptorPool = descriptor_pool,
                .descriptorSetCount = 1,
                .pSetLayouts = @ptrCast(&layout),
            };
            var set: vk.VkDescriptorSet = null;
            try drv.fromResult(drv.vkAllocateDescriptorSets(rt._logical_device, &set_info, @ptrCast(&set)));
            var infos: [runtime.max_buffers_per_set]vk.VkDescriptorBufferInfo = undefined;
            var writes: [runtime.max_buffers_per_set]vk.VkWriteDescriptorSet = undefined;
            for (dispatch.buffers, 0..) |buffer, i| {
                infos[i] = .{ .buffer = buffer._buffer, .offset = 0, .range = vk.VK_WHOLE_SIZE };
                writes[i] = .{
                    .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                    .pNext = null,
                    .dstSet = set,
                    .dstBinding = @intCast(i),
                    .dstArrayElement = 0,
                    .descriptorCount = 1,
                    .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                    .pImageInfo = null,
                    .pBufferInfo = @ptrCast(&infos[i]),
                    .pTexelBufferView = null,
                };
            }
            drv.vkUpdateDescriptorSets(rt._logical_device, @intCast(dispatch.buffers.len), @ptrCast(&writes), 0, null);
            drv.vkCmdBindPipeline(cb, vk.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
            drv.vkCmdBindDescriptorSets(cb, vk.VK_PIPELINE_BIND_POINT_COMPUTE, dispatch.kernel._pipeline_layout, 0, 1, @ptrCast(&set), 0, null);
            if (dispatch.push_constants.len != 0) drv.vkCmdPushConstants(
                cb,
                dispatch.kernel._pipeline_layout,
                vk.VK_SHADER_STAGE_COMPUTE_BIT,
                0,
                @intCast(dispatch.push_constants.len),
                @ptrCast(dispatch.push_constants.ptr),
            );
            drv.vkCmdDispatch(cb, dispatch.grid[0], dispatch.grid[1], dispatch.grid[2]);
        }
        failed_index.* = null;
        try drv.fromResult(drv.vkEndCommandBuffer(cb));
        return .{ .rt = rt, .command_pool = command_pool, .descriptor_pool = descriptor_pool, .command_buffer = cb };
    }

    pub fn submit(self: *Sequence, stream: *runtime.Stream, waits: []const *runtime.Event, signal: ?*runtime.Event) Error!void {
        if (stream.poisoned) return error.StreamPoisoned;
        if (waits.len > launch.max_wait_events) return error.InitializationFailed;
        const drv = &self.rt._driver;
        var wait_infos: [launch.max_wait_events + 1]vk.VkSemaphoreSubmitInfo = undefined;
        wait_infos[0] = semaphoreInfo(stream._semaphore, stream.counter);
        for (waits, 1..) |event, index| {
            if (!event.recorded) return error.InitializationFailed;
            wait_infos[index] = semaphoreInfo(event._semaphore, event.value);
        }
        const next = stream.counter + 1;
        const signal_info = semaphoreInfo(stream._semaphore, next);
        const cb_info = vk.VkCommandBufferSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .pNext = null,
            .commandBuffer = self.command_buffer,
            .deviceMask = 0,
        };
        const submit_info = vk.VkSubmitInfo2{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .pNext = null,
            .flags = 0,
            .waitSemaphoreInfoCount = @intCast(waits.len + 1),
            .pWaitSemaphoreInfos = @ptrCast(&wait_infos),
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = @ptrCast(&cb_info),
            .signalSemaphoreInfoCount = 1,
            .pSignalSemaphoreInfos = @ptrCast(&signal_info),
        };
        drv.fromResult(drv.vkQueueSubmit2(self.rt._queue, 1, @ptrCast(&submit_info), null)) catch |err| {
            stream.poisoned = true;
            return err;
        };
        stream.counter = next;
        if (signal) |event| {
            event._semaphore = stream._semaphore;
            event.value = next;
            event.recorded = true;
        }
    }

    pub fn deinit(self: *Sequence) void {
        const drv = &self.rt._driver;
        drv.fromResult(drv.vkDeviceWaitIdle(self.rt._logical_device)) catch @panic("Vulkan sequence destruction requires completion");
        drv.vkDestroyDescriptorPool(self.rt._logical_device, self.descriptor_pool, null);
        drv.vkDestroyCommandPool(self.rt._logical_device, self.command_pool, null);
        self.* = undefined;
    }
};

fn semaphoreInfo(semaphore: vk.VkSemaphore, value: u64) vk.VkSemaphoreSubmitInfo {
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = semaphore,
        .value = value,
        .stageMask = all_commands,
        .deviceIndex = 0,
    };
}
