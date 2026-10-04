const std = @import("std");

const driver_mod = @import("sys").vulkan;
const runtime_mod = @import("runtime.zig");
const observation = @import("observation.zig");

pub const Error = driver_mod.Error;

const Runtime = runtime_mod.Runtime;
const Stream = runtime_mod.Stream;
const Event = runtime_mod.Event;
const DeviceBuffer = runtime_mod.DeviceBuffer;

const VkCommandBuffer = driver_mod.VkCommandBuffer;
const VkDescriptorSet = driver_mod.VkDescriptorSet;
const VkPipeline = driver_mod.VkPipeline;
const VkPipelineLayout = driver_mod.VkPipelineLayout;
const VkDescriptorSetLayout = driver_mod.VkDescriptorSetLayout;
const VkShaderModule = driver_mod.VkShaderModule;

pub const max_wait_events: usize = 32;

const pipeline_stage_2_all_commands: u64 = 0x10000;

pub const SpecializedPipeline = struct {
    workgroup: [3]u32,
    pipeline: VkPipeline,
};

pub const Kernel = struct {
    _runtime: *Runtime,
    _module_handle: VkShaderModule,
    _pipelines: std.ArrayListUnmanaged(SpecializedPipeline) = .empty,
    _set_layout: VkDescriptorSetLayout,
    _pipeline_layout: VkPipelineLayout,
    num_buffers: u32,
    push_constant_size: u32,
    entry_point: [:0]const u8,

    pub fn launch(
        self: *Kernel,
        stream: *Stream,
        args: []const *DeviceBuffer,
        push_constants: []const u8,
        grid: [3]u32,
        workgroup: [3]u32,
        wait_events: []const *Event,
        signal_event: ?*Event,
    ) Error!void {
        if (stream.poisoned) return Error.StreamPoisoned;
        if (args.len != self.num_buffers) return Error.InitializationFailed;
        if (push_constants.len > self.push_constant_size) return Error.InitializationFailed;
        if (push_constants.len % 4 != 0) return Error.InitializationFailed;
        if (wait_events.len > max_wait_events) return Error.InitializationFailed;
        if (args.len > runtime_mod.max_buffers_per_set) return Error.InitializationFailed;
        for (workgroup) |extent| if (extent == 0) return Error.InitializationFailed;

        const pipeline = try self.pipelineForWorkgroup(workgroup);

        errdefer stream.poisoned = true;

        const rt = self._runtime;
        const drv = &rt._driver;

        const cb = try runtime_mod.acquireStreamCommandBuffer(stream);

        const ds = try runtime_mod.acquireStreamDescriptorSet(stream, self._set_layout);

        var buffer_infos: [runtime_mod.max_buffers_per_set]driver_mod.VkDescriptorBufferInfo = undefined;
        var writes: [runtime_mod.max_buffers_per_set]driver_mod.VkWriteDescriptorSet = undefined;
        for (args, 0..) |buf, i| {
            buffer_infos[i] = .{
                .buffer = buf._buffer,
                .offset = 0,
                .range = driver_mod.VK_WHOLE_SIZE,
            };
            writes[i] = .{
                .sType = driver_mod.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = ds,
                .dstBinding = @intCast(i),
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = driver_mod.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = @ptrCast(&buffer_infos[i]),
                .pTexelBufferView = null,
            };
        }
        drv.vkUpdateDescriptorSets(
            rt._logical_device,
            @intCast(args.len),
            @ptrCast(&writes),
            0,
            null,
        );

        const begin_info = driver_mod.VkCommandBufferBeginInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = driver_mod.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try drv.fromResult(drv.vkBeginCommandBuffer(cb, &begin_info));
        drv.vkCmdBindPipeline(cb, driver_mod.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
        drv.vkCmdBindDescriptorSets(
            cb,
            driver_mod.VK_PIPELINE_BIND_POINT_COMPUTE,
            self._pipeline_layout,
            0,
            1,
            @ptrCast(&ds),
            0,
            null,
        );
        if (push_constants.len > 0) {
            drv.vkCmdPushConstants(
                cb,
                self._pipeline_layout,
                driver_mod.VK_SHADER_STAGE_COMPUTE_BIT,
                0,
                @intCast(push_constants.len),
                @ptrCast(push_constants.ptr),
            );
        }
        drv.vkCmdDispatch(cb, grid[0], grid[1], grid[2]);
        try drv.fromResult(drv.vkEndCommandBuffer(cb));

        var waits_buf: [max_wait_events + 1]driver_mod.VkSemaphoreSubmitInfo = undefined;
        waits_buf[0] = .{
            .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .pNext = null,
            .semaphore = stream._semaphore,
            .value = stream.counter,
            .stageMask = pipeline_stage_2_all_commands,
            .deviceIndex = 0,
        };
        for (wait_events, 1..) |ev, i| {
            waits_buf[i] = .{
                .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
                .pNext = null,
                .semaphore = ev._semaphore,
                .value = ev.value,
                .stageMask = pipeline_stage_2_all_commands,
                .deviceIndex = 0,
            };
        }
        const wait_count: u32 = @intCast(1 + wait_events.len);

        const signal_value = stream.counter + 1;
        const signal_info = driver_mod.VkSemaphoreSubmitInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .pNext = null,
            .semaphore = stream._semaphore,
            .value = signal_value,
            .stageMask = pipeline_stage_2_all_commands,
            .deviceIndex = 0,
        };

        const cb_info = driver_mod.VkCommandBufferSubmitInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .pNext = null,
            .commandBuffer = cb,
            .deviceMask = 0,
        };

        const submits = [_]driver_mod.VkSubmitInfo2{.{
            .sType = driver_mod.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .pNext = null,
            .flags = 0,
            .waitSemaphoreInfoCount = wait_count,
            .pWaitSemaphoreInfos = @ptrCast(&waits_buf),
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = @ptrCast(&cb_info),
            .signalSemaphoreInfoCount = 1,
            .pSignalSemaphoreInfos = @ptrCast(&signal_info),
        }};
        try drv.fromResult(drv.vkQueueSubmit2(rt._queue, 1, @ptrCast(&submits), null));

        runtime_mod.retireStreamCommandBuffer(stream, cb, signal_value);
        runtime_mod.retireStreamDescriptorSet(stream, ds, self._set_layout, signal_value);
        stream.counter = signal_value;
        if (signal_event) |ev| {
            ev._semaphore = stream._semaphore;
            ev.value = stream.counter;
            ev.recorded = true;
        }
    }

    pub fn pipelineForWorkgroup(self: *Kernel, workgroup: [3]u32) Error!VkPipeline {
        for (self._pipelines.items) |entry| {
            if (entry.workgroup[0] == workgroup[0] and
                entry.workgroup[1] == workgroup[1] and
                entry.workgroup[2] == workgroup[2]) return entry.pipeline;
        }

        const rt = self._runtime;
        const spec_entries = [_]driver_mod.VkSpecializationMapEntry{
            .{ .constantID = 0, .offset = 0, .size = 4 },
            .{ .constantID = 1, .offset = 4, .size = 4 },
            .{ .constantID = 2, .offset = 8, .size = 4 },
        };
        const spec_info = driver_mod.VkSpecializationInfo{
            .mapEntryCount = spec_entries.len,
            .pMapEntries = &spec_entries,
            .dataSize = @sizeOf([3]u32),
            .pData = @ptrCast(&workgroup),
        };
        const stage_ci = driver_mod.VkPipelineShaderStageCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = driver_mod.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = self._module_handle,
            .pName = self.entry_point.ptr,
            .pSpecializationInfo = &spec_info,
        };
        const pipeline_ci = [_]driver_mod.VkComputePipelineCreateInfo{.{
            .sType = driver_mod.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = stage_ci,
            .layout = self._pipeline_layout,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        }};
        var pipeline: VkPipeline = null;
        observation.attempt(rt.observer, .pipeline);
        rt._driver.fromResult(rt._driver.vkCreateComputePipelines(
            rt._logical_device,
            null,
            1,
            @ptrCast(&pipeline_ci),
            null,
            @ptrCast(&pipeline),
        )) catch |err| {
            observation.failure(rt.observer, .pipeline);
            if (pipeline != null) {
                observation.partialResult(rt.observer, .pipeline, 0);
                rt._driver.vkDestroyPipeline(rt._logical_device, pipeline, null);
                observation.release(rt.observer, .pipeline, 0, true);
            }
            return err;
        };
        observation.success(rt.observer, .pipeline, 0);
        errdefer {
            rt._driver.vkDestroyPipeline(rt._logical_device, pipeline, null);
            observation.release(rt.observer, .pipeline, 0, true);
        }

        self._pipelines.append(rt.allocator, .{ .workgroup = workgroup, .pipeline = pipeline }) catch {
            return Error.OutOfHostMemory;
        };
        return pipeline;
    }

    pub fn deinit(self: *Kernel) void {
        for (self._pipelines.items) |entry| {
            self._runtime._driver.vkDestroyPipeline(self._runtime._logical_device, entry.pipeline, null);
            observation.release(self._runtime.observer, .pipeline, 0, false);
        }
        self._pipelines.deinit(self._runtime.allocator);
        self.* = undefined;
    }
};

pub fn compile(
    runtime: *Runtime,
    spirv_words: []const u32,
    entry_point: [:0]const u8,
    num_buffers: u32,
    push_constant_size: u32,
) Error!Kernel {
    const module_handle = try runtime._shader_cache.populateCache(runtime, spirv_words);
    const layout = try runtime._pipeline_layout_cache.getOrCreate(runtime, .{
        .num_buffers = num_buffers,
        .push_constant_size = push_constant_size,
    });

    return .{
        ._runtime = runtime,
        ._module_handle = module_handle,
        ._set_layout = layout.set_layout,
        ._pipeline_layout = layout.pipeline_layout,
        .num_buffers = num_buffers,
        .push_constant_size = push_constant_size,
        .entry_point = entry_point,
    };
}

fn makeFakeKernel(runtime: *Runtime, num_buffers: u32) !Kernel {
    const words = [_]u32{ 0x07230203, 0x00010000, 0x1, 0x2, 0x3, 0x4 };
    return compile(runtime, &words, "accy_main", num_buffers, 0);
}

fn makeFakePushKernel(runtime: *Runtime, num_buffers: u32, push_constant_size: u32) !Kernel {
    const words = [_]u32{ 0x07230203, 0x00010000, 0x1, 0x2, 0x3, 0x4 };
    return compile(runtime, &words, "accy_main", num_buffers, push_constant_size);
}
