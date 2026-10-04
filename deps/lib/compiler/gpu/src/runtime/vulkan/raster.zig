//! Graphics on the runtime's one queue: images, graphics pipelines built for dynamic rendering,
//! descriptor sets written once, and passes recorded into command buffers.
//!
//! Every image rests in one home layout chosen from its usage. A pass or a transfer moves an image
//! out of its home and back inside the same command buffer, so a command buffer recorded once
//! stays valid for every later submission. Each pass opens with a barrier over all earlier work on
//! the queue, which makes kernel, transfer and earlier pass writes visible to the pass's vertex,
//! index, uniform, sampler and attachment reads.

const std = @import("std");

const driver_mod = @import("sys").vulkan;
const memory_mod = @import("memory.zig");
const runtime_mod = @import("runtime.zig");

pub const Error = driver_mod.Error;

const Driver = driver_mod.Driver;
const Runtime = runtime_mod.Runtime;
const Stream = runtime_mod.Stream;
const Event = runtime_mod.Event;

const VkBuffer = driver_mod.VkBuffer;
const VkCommandBuffer = driver_mod.VkCommandBuffer;
const VkCommandPool = driver_mod.VkCommandPool;
const VkDescriptorPool = driver_mod.VkDescriptorPool;
const VkDescriptorSet = driver_mod.VkDescriptorSet;
const VkDescriptorSetLayout = driver_mod.VkDescriptorSetLayout;
const VkDescriptorSetLayoutBinding = driver_mod.VkDescriptorSetLayoutBinding;
const VkFormat = driver_mod.VkFormat;
const VkImage = driver_mod.VkImage;
const VkImageAspectFlags = driver_mod.VkImageAspectFlags;
const VkImageLayout = driver_mod.VkImageLayout;
const VkImageUsageFlags = driver_mod.VkImageUsageFlags;
const VkImageView = driver_mod.VkImageView;
const VkPipeline = driver_mod.VkPipeline;
const VkPipelineLayout = driver_mod.VkPipelineLayout;
const VkSampler = driver_mod.VkSampler;

/// Waits one submission may name besides its stream's own timeline.
pub const max_wait_events: usize = 32;

/// Resources one binding set holds.
pub const max_descriptors: u32 = 16;

/// Vertex buffers one pipeline reads.
pub const max_vertex_buffers: u32 = 8;

/// Vertex attributes one pipeline reads.
pub const max_vertex_attributes: u32 = 16;

/// Push-constant bytes a pipeline may declare: the 128 Vulkan guarantees on every device.
pub const max_push_constant_bytes: u32 = 128;

/// Sets one descriptor pool holds. Each pool reserves `max_descriptors` of every descriptor type
/// per set, so a pool with a free set always has room for its descriptors.
const sets_per_pool: u32 = 256;

const descriptor_types = [_]driver_mod.VkDescriptorType{
    driver_mod.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    driver_mod.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    driver_mod.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
};

const pipeline_stage_2_all_commands: u64 = 0x10000;

const all_access = driver_mod.VK_ACCESS_MEMORY_READ_BIT | driver_mod.VK_ACCESS_MEMORY_WRITE_BIT;

pub const SamplerKey = struct {
    filter: driver_mod.VkFilter,
    address: driver_mod.VkSamplerAddressMode,
};

const max_samplers = 8;

const DescriptorPool = struct {
    pool: VkDescriptorPool,
    live: u32,
};

/// The graphics state one backend keeps beside a runtime: a command pool for reusable command
/// buffers, descriptor pools for binding sets, samplers shared by every set, and the device limits
/// that shape images and pipelines.
pub const Raster = struct {
    runtime: *Runtime,
    command_pool: VkCommandPool,
    descriptor_pools: std.ArrayListUnmanaged(DescriptorPool) = .empty,
    sampler_keys: [max_samplers]SamplerKey = undefined,
    samplers: [max_samplers]VkSampler = undefined,
    sampler_count: usize = 0,
    buffer_image_granularity: u64,
    max_image_extent: u32,
    max_vertex_buffers: u32,
    max_vertex_attributes: u32,
    /// The device's push-constant bytes, at most `max_push_constant_bytes`.
    max_push_constant_bytes: u32,
    /// Set when work that may read raster objects was submitted after the device last went idle.
    pending: bool = false,

    pub fn init(runtime: *Runtime) Error!Raster {
        if (!runtime.device.graphics()) return Error.FeatureNotPresent;
        const drv = &runtime._driver;
        var props: driver_mod.VkPhysicalDeviceProperties = undefined;
        drv.vkGetPhysicalDeviceProperties(runtime._physical_device, &props);
        const pool_ci = driver_mod.VkCommandPoolCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = driver_mod.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = runtime.device.queueFamilyIndex(),
        };
        var pool: VkCommandPool = null;
        try drv.fromResult(drv.vkCreateCommandPool(runtime._logical_device, &pool_ci, null, &pool));
        return .{
            .runtime = runtime,
            .command_pool = pool,
            .buffer_image_granularity = @max(props.limits.bufferImageGranularity, 1),
            .max_image_extent = props.limits.maxImageDimension2D,
            .max_vertex_buffers = @min(props.limits.maxVertexInputBindings, max_vertex_buffers),
            .max_vertex_attributes = @min(props.limits.maxVertexInputAttributes, max_vertex_attributes),
            .max_push_constant_bytes = @min(props.limits.maxPushConstantsSize, max_push_constant_bytes),
        };
    }

    /// Waits for the device, then releases the pools and samplers. Every image, pipeline, set and
    /// bundle made from this raster must already be destroyed.
    pub fn deinit(self: *Raster) void {
        self.idle();
        const rt = self.runtime;
        const drv = &rt._driver;
        for (self.descriptor_pools.items) |entry| {
            std.debug.assert(entry.live == 0);
            drv.vkDestroyDescriptorPool(rt._logical_device, entry.pool, null);
        }
        self.descriptor_pools.deinit(rt.allocator);
        for (self.samplers[0..self.sampler_count]) |handle| {
            drv.vkDestroySampler(rt._logical_device, handle, null);
        }
        drv.vkDestroyCommandPool(rt._logical_device, self.command_pool, null);
        self.* = undefined;
    }

    /// Waits until the device has finished every submission that may still read a raster object.
    /// Destruction calls it, so a caller may destroy an object right after submitting work that
    /// names it.
    pub fn idle(self: *Raster) void {
        if (!self.pending) return;
        self.runtime.synchronize() catch |err| {
            std.log.scoped(.vulkan_raster).warn("device wait before destroy failed: {s}", .{@errorName(err)});
            return;
        };
        self.pending = false;
    }

    pub fn formatFeatures(self: *const Raster, format: VkFormat) driver_mod.VkFormatFeatureFlags {
        var props: driver_mod.VkFormatProperties = undefined;
        self.runtime._driver.vkGetPhysicalDeviceFormatProperties(self.runtime._physical_device, format, &props);
        return props.optimalTilingFeatures;
    }

    /// The sampler for `key`, made on first use and shared by every set that names it.
    pub fn sampler(self: *Raster, key: SamplerKey) Error!VkSampler {
        for (self.sampler_keys[0..self.sampler_count], self.samplers[0..self.sampler_count]) |existing, handle| {
            if (std.meta.eql(existing, key)) return handle;
        }
        if (self.sampler_count == max_samplers) return Error.TooManyObjects;
        const ci = driver_mod.VkSamplerCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = key.filter,
            .minFilter = key.filter,
            .mipmapMode = driver_mod.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = key.address,
            .addressModeV = key.address,
            .addressModeW = key.address,
            .mipLodBias = 0,
            .anisotropyEnable = driver_mod.VK_FALSE,
            .maxAnisotropy = 1,
            .compareEnable = driver_mod.VK_FALSE,
            .compareOp = driver_mod.VK_COMPARE_OP_ALWAYS,
            .minLod = 0,
            .maxLod = 0,
            .borderColor = driver_mod.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
            .unnormalizedCoordinates = driver_mod.VK_FALSE,
        };
        var handle: VkSampler = 0;
        const rt = self.runtime;
        try rt._driver.fromResult(rt._driver.vkCreateSampler(rt._logical_device, &ci, null, &handle));
        self.sampler_keys[self.sampler_count] = key;
        self.samplers[self.sampler_count] = handle;
        self.sampler_count += 1;
        return handle;
    }

    /// A primary command buffer from the raster's own pool, for a pass recorded once and
    /// submitted many times. Stream pools recycle their buffers, so a bundle cannot live there.
    pub fn allocateBundle(self: *Raster) Error!VkCommandBuffer {
        const rt = self.runtime;
        const info = driver_mod.VkCommandBufferAllocateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = driver_mod.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var cb: VkCommandBuffer = null;
        try rt._driver.fromResult(rt._driver.vkAllocateCommandBuffers(rt._logical_device, &info, @ptrCast(&cb)));
        return cb;
    }

    pub fn freeBundle(self: *Raster, cb: VkCommandBuffer) void {
        self.idle();
        self.discardBundle(cb);
    }

    /// Frees a bundle's command buffer that was never submitted, without waiting for the device.
    pub fn discardBundle(self: *Raster, cb: VkCommandBuffer) void {
        const rt = self.runtime;
        var handle = cb;
        rt._driver.vkFreeCommandBuffers(rt._logical_device, self.command_pool, 1, @ptrCast(&handle));
    }

    fn allocateSet(self: *Raster, layout: VkDescriptorSetLayout) Error!BindingSet {
        const rt = self.runtime;
        const drv = &rt._driver;
        var index: usize = 0;
        while (index <= self.descriptor_pools.items.len) : (index += 1) {
            if (index == self.descriptor_pools.items.len) try self.addDescriptorPool();
            const entry = &self.descriptor_pools.items[index];
            if (entry.live == sets_per_pool) continue;
            var set_layout = layout;
            const info = driver_mod.VkDescriptorSetAllocateInfo{
                .sType = driver_mod.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                .pNext = null,
                .descriptorPool = entry.pool,
                .descriptorSetCount = 1,
                .pSetLayouts = @ptrCast(&set_layout),
            };
            var set: VkDescriptorSet = null;
            drv.fromResult(drv.vkAllocateDescriptorSets(rt._logical_device, &info, @ptrCast(&set))) catch |err| switch (err) {
                error.FragmentedPool, error.OutOfPoolMemory => continue,
                else => return err,
            };
            entry.live += 1;
            return .{ .set = set, .pool_index = @intCast(index) };
        }
        unreachable;
    }

    fn addDescriptorPool(self: *Raster) Error!void {
        const rt = self.runtime;
        var sizes: [descriptor_types.len]driver_mod.VkDescriptorPoolSize = undefined;
        for (&sizes, descriptor_types) |*size, kind| {
            size.* = .{ .type = kind, .descriptorCount = sets_per_pool * max_descriptors };
        }
        const ci = driver_mod.VkDescriptorPoolCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = driver_mod.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
            .maxSets = sets_per_pool,
            .poolSizeCount = sizes.len,
            .pPoolSizes = &sizes,
        };
        var pool: VkDescriptorPool = null;
        try rt._driver.fromResult(rt._driver.vkCreateDescriptorPool(rt._logical_device, &ci, null, &pool));
        errdefer rt._driver.vkDestroyDescriptorPool(rt._logical_device, pool, null);
        self.descriptor_pools.append(rt.allocator, .{ .pool = pool, .live = 0 }) catch return Error.OutOfHostMemory;
    }
};

/// The layout an image rests in between passes and transfers. A sampled image rests where a
/// shader can read it, an attachment where a pass writes it, and anything else in the general
/// layout.
pub fn homeLayout(usage: VkImageUsageFlags) VkImageLayout {
    if (usage & driver_mod.VK_IMAGE_USAGE_SAMPLED_BIT != 0) return driver_mod.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    if (usage & driver_mod.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT != 0) return driver_mod.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL;
    if (usage & driver_mod.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT != 0) return driver_mod.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    return driver_mod.VK_IMAGE_LAYOUT_GENERAL;
}

pub const ImageDesc = struct {
    width: u32,
    height: u32,
    format: VkFormat,
    usage: VkImageUsageFlags,
    aspect: VkImageAspectFlags,
    /// Bytes one texel occupies in a tightly packed transfer.
    texel_bytes: u32,
};

/// The memory behind an image: a range of a pooled block, or an allocation of its own that another
/// process may share, which the image frees with itself.
pub const Backing = union(enum) {
    pooled: memory_mod.Allocation,
    dedicated: driver_mod.VkDeviceMemory,
};

/// A 2D image with one mip level and one layer, its view, and the memory behind it. It rests in
/// `home` whenever no command buffer is using it.
pub const Image = struct {
    image: VkImage,
    view: VkImageView,
    backing: Backing,
    width: u32,
    height: u32,
    format: VkFormat,
    aspect: VkImageAspectFlags,
    texel_bytes: u32,
    home: VkImageLayout,

    /// Makes the image and moves it into its home layout before returning, so every later
    /// command buffer can assume it.
    pub fn create(raster: *Raster, desc: ImageDesc) Error!Image {
        std.debug.assert(desc.texel_bytes != 0);
        if (desc.width == 0 or desc.height == 0) return Error.InitializationFailed;
        if (desc.width > raster.max_image_extent or desc.height > raster.max_image_extent) return Error.InitializationFailed;
        const rt = raster.runtime;
        const drv = &rt._driver;
        const ci = driver_mod.VkImageCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = driver_mod.VK_IMAGE_TYPE_2D,
            .format = desc.format,
            .extent = .{ .width = desc.width, .height = desc.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = driver_mod.VK_SAMPLE_COUNT_1_BIT,
            .tiling = driver_mod.VK_IMAGE_TILING_OPTIMAL,
            .usage = desc.usage,
            .sharingMode = driver_mod.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = driver_mod.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        var image: VkImage = 0;
        try drv.fromResult(drv.vkCreateImage(rt._logical_device, &ci, null, &image));
        errdefer drv.vkDestroyImage(rt._logical_device, image, null);

        var requirements: driver_mod.VkMemoryRequirements = undefined;
        drv.vkGetImageMemoryRequirements(rt._logical_device, image, &requirements);
        const allocation = try rt._memory.allocate(drv, rt._logical_device, granular(requirements, raster.buffer_image_granularity), .device);
        errdefer rt._memory.release(allocation);
        try drv.fromResult(drv.vkBindImageMemory(
            rt._logical_device,
            image,
            rt._memory.deviceMemory(allocation),
            allocation.offset,
        ));

        const view_ci = driver_mod.VkImageViewCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = image,
            .viewType = driver_mod.VK_IMAGE_VIEW_TYPE_2D,
            .format = desc.format,
            .components = .{},
            .subresourceRange = subresourceRange(desc.aspect),
        };
        var view: VkImageView = 0;
        try drv.fromResult(drv.vkCreateImageView(rt._logical_device, &view_ci, null, &view));
        errdefer drv.vkDestroyImageView(rt._logical_device, view, null);

        const created = Image{
            .image = image,
            .view = view,
            .backing = .{ .pooled = allocation },
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .aspect = desc.aspect,
            .texel_bytes = desc.texel_bytes,
            .home = homeLayout(desc.usage),
        };
        const stream = try rt.defaultStream();
        const cb = try beginOneShot(stream);
        recordBarrier(drv, cb, &.{created.transition(driver_mod.VK_IMAGE_LAYOUT_UNDEFINED, created.home)});
        try finishOneShot(stream, cb);
        return created;
    }

    pub fn destroy(self: *Image, raster: *Raster) void {
        raster.idle();
        const rt = raster.runtime;
        rt._driver.vkDestroyImageView(rt._logical_device, self.view, null);
        rt._driver.vkDestroyImage(rt._logical_device, self.image, null);
        switch (self.backing) {
            .pooled => |allocation| rt._memory.release(allocation),
            .dedicated => |memory| rt._driver.vkFreeMemory(rt._logical_device, memory, null),
        }
        self.* = undefined;
    }

    pub fn byteSize(self: *const Image) usize {
        return @as(usize, self.width) * @as(usize, self.height) * @as(usize, self.texel_bytes);
    }

    /// Replaces every texel with `bytes`, tightly packed rows from the top.
    pub fn write(self: *const Image, raster: *Raster, bytes: []const u8) Error!void {
        if (bytes.len != self.byteSize()) return Error.InitializationFailed;
        const rt = raster.runtime;
        var staging = try runtime_mod.TransferBuffer.init(rt, bytes.len);
        defer staging.deinit();
        const mapped = rt._memory.mapped(staging.allocation) orelse return Error.MemoryMapFailed;
        @memcpy(mapped[0..bytes.len], bytes);
        try rt._memory.flush(&rt._driver, rt._logical_device, staging.allocation);
        try self.copy(raster, staging.buffer, .upload);
    }

    /// Copies every texel into `bytes`, tightly packed rows from the top.
    pub fn read(self: *const Image, raster: *Raster, bytes: []u8) Error!void {
        if (bytes.len != self.byteSize()) return Error.InitializationFailed;
        const rt = raster.runtime;
        var staging = try runtime_mod.TransferBuffer.init(rt, bytes.len);
        defer staging.deinit();
        try self.copy(raster, staging.buffer, .download);
        try rt._memory.invalidate(&rt._driver, rt._logical_device, staging.allocation);
        const mapped = rt._memory.mapped(staging.allocation) orelse return Error.MemoryMapFailed;
        @memcpy(bytes, mapped[0..bytes.len]);
    }

    /// Records and waits for one copy between the image and `buffer` on the default stream.
    fn copy(self: *const Image, raster: *Raster, buffer: VkBuffer, direction: enum { upload, download }) Error!void {
        const rt = raster.runtime;
        const drv = &rt._driver;
        const stream = try rt.defaultStream();
        const cb = try beginOneShot(stream);
        const transfer_layout = switch (direction) {
            .upload => driver_mod.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .download => driver_mod.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        };
        recordBarrier(drv, cb, &.{self.transition(self.home, transfer_layout)});
        const region = driver_mod.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{ .aspectMask = self.aspect, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = self.width, .height = self.height, .depth = 1 },
        };
        switch (direction) {
            .upload => drv.vkCmdCopyBufferToImage(cb, buffer, self.image, transfer_layout, 1, @ptrCast(&region)),
            .download => drv.vkCmdCopyImageToBuffer(cb, self.image, transfer_layout, buffer, 1, @ptrCast(&region)),
        }
        recordBarrier(drv, cb, &.{self.transition(transfer_layout, self.home)});
        try finishOneShot(stream, cb);
    }

    /// A barrier that moves the whole image from `old` to `new` after all earlier work on the queue.
    pub fn transition(self: *const Image, old: VkImageLayout, new: VkImageLayout) driver_mod.VkImageMemoryBarrier {
        return layoutBarrier(self.image, self.aspect, old, new);
    }

    /// The image as a pass attachment that rests in its home layout before and after the pass.
    pub fn attachment(self: *const Image, clear: ?driver_mod.VkClearValue) Attachment {
        return .{
            .image = self.image,
            .view = self.view,
            .aspect = self.aspect,
            .width = self.width,
            .height = self.height,
            .before = self.home,
            .after = self.home,
            .clear = clear,
        };
    }
};

/// A barrier that moves the whole of `image` from `old` to `new` after all earlier work on the
/// queue.
pub fn layoutBarrier(image: VkImage, aspect: VkImageAspectFlags, old: VkImageLayout, new: VkImageLayout) driver_mod.VkImageMemoryBarrier {
    return .{
        .sType = driver_mod.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = driver_mod.VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask = all_access,
        .oldLayout = old,
        .newLayout = new,
        .srcQueueFamilyIndex = driver_mod.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = driver_mod.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = subresourceRange(aspect),
    };
}

pub fn subresourceRange(aspect: VkImageAspectFlags) driver_mod.VkImageSubresourceRange {
    return .{ .aspectMask = aspect, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
}

/// Pads an image's requirements to whole granularity pages, so an optimal-tiling image never
/// shares a page with a linear buffer in the same memory block.
fn granular(requirements: driver_mod.VkMemoryRequirements, granularity: u64) driver_mod.VkMemoryRequirements {
    std.debug.assert(granularity != 0);
    return .{
        .size = std.mem.alignForward(u64, requirements.size, granularity),
        .alignment = @max(requirements.alignment, granularity),
        .memoryTypeBits = requirements.memoryTypeBits,
    };
}

/// A full barrier over all earlier work on the queue: every write before it becomes visible to
/// every read and write after it, and each image in `images` changes layout in between.
pub fn recordBarrier(drv: *const Driver, cb: VkCommandBuffer, images: []const driver_mod.VkImageMemoryBarrier) void {
    const memory = driver_mod.VkMemoryBarrier{
        .srcAccessMask = driver_mod.VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask = all_access,
    };
    drv.vkCmdPipelineBarrier(
        cb,
        driver_mod.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        driver_mod.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        0,
        1,
        @ptrCast(&memory),
        0,
        null,
        @intCast(images.len),
        if (images.len == 0) null else images.ptr,
    );
}

fn beginOneShot(stream: *Stream) Error!VkCommandBuffer {
    if (stream.poisoned) return Error.StreamPoisoned;
    const cb = try runtime_mod.acquireStreamCommandBuffer(stream);
    try beginCommandBuffer(&stream._runtime._driver, cb, driver_mod.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
    return cb;
}

/// Ends, submits and waits for a command buffer from `beginOneShot`. A failure poisons the stream,
/// since the image layouts it promised may not hold.
fn finishOneShot(stream: *Stream, cb: VkCommandBuffer) Error!void {
    errdefer stream.poisoned = true;
    const drv = &stream._runtime._driver;
    runtime_mod.recordHostReadBarrier(drv, cb);
    try drv.fromResult(drv.vkEndCommandBuffer(cb));
    try runtime_mod.submitStreamCommandBuffer(stream, cb);
    try stream.synchronize();
}

pub fn beginCommandBuffer(drv: *const Driver, cb: VkCommandBuffer, flags: driver_mod.VkCommandBufferUsageFlags) Error!void {
    const info = driver_mod.VkCommandBufferBeginInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = flags,
        .pInheritanceInfo = null,
    };
    try drv.fromResult(drv.vkBeginCommandBuffer(cb, &info));
}

/// How a fragment's color combines with the target's. The equations are the contract's
/// `RenderBlendMode` equations, spelled in Vulkan blend factors by `blendState`.
pub const Blend = enum {
    replace,
    alpha_premultiplied,
    alpha_straight,
    additive,
};

pub fn blendState(blend: Blend) driver_mod.VkPipelineColorBlendAttachmentState {
    const one = driver_mod.VK_BLEND_FACTOR_ONE;
    const inverse_alpha = driver_mod.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    const color_factors: [2]driver_mod.VkBlendFactor, const alpha_factors: [2]driver_mod.VkBlendFactor = switch (blend) {
        .replace => .{ .{ one, driver_mod.VK_BLEND_FACTOR_ZERO }, .{ one, driver_mod.VK_BLEND_FACTOR_ZERO } },
        .alpha_premultiplied => .{ .{ one, inverse_alpha }, .{ one, inverse_alpha } },
        .alpha_straight => .{ .{ driver_mod.VK_BLEND_FACTOR_SRC_ALPHA, inverse_alpha }, .{ one, inverse_alpha } },
        .additive => .{ .{ one, one }, .{ one, one } },
    };
    return .{
        .blendEnable = if (blend == .replace) driver_mod.VK_FALSE else driver_mod.VK_TRUE,
        .srcColorBlendFactor = color_factors[0],
        .dstColorBlendFactor = color_factors[1],
        .colorBlendOp = driver_mod.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = alpha_factors[0],
        .dstAlphaBlendFactor = alpha_factors[1],
        .alphaBlendOp = driver_mod.VK_BLEND_OP_ADD,
        .colorWriteMask = driver_mod.VK_COLOR_COMPONENT_R_BIT | driver_mod.VK_COLOR_COMPONENT_G_BIT |
            driver_mod.VK_COLOR_COMPONENT_B_BIT | driver_mod.VK_COLOR_COMPONENT_A_BIT,
    };
}

pub const DepthTest = struct {
    format: VkFormat,
    compare: driver_mod.VkCompareOp,
    write: bool,
    bias_constant: f32 = 0,
    bias_slope: f32 = 0,
    bias_clamp: f32 = 0,

    fn biased(self: DepthTest) bool {
        return self.bias_constant != 0 or self.bias_slope != 0;
    }
};

/// The stages a push-constant range reaches: both, since either stage may read the block.
pub const push_constant_stages = driver_mod.VK_SHADER_STAGE_VERTEX_BIT | driver_mod.VK_SHADER_STAGE_FRAGMENT_BIT;

/// A graphics pipeline in Vulkan terms. Both entries come from one SPIR-V module, every descriptor
/// lives in set 0 and is visible to both stages, and viewport and scissor are set per pass. A
/// nonzero `push_constant_bytes` declares one range at offset 0 that both stages see.
pub const PipelineDesc = struct {
    words: []const u32,
    vertex_entry: [*:0]const u8,
    fragment_entry: [*:0]const u8,
    color_format: VkFormat,
    depth: ?DepthTest,
    blend: Blend,
    /// The faces left undrawn, by the front face `Pipeline.create` sets.
    cull: driver_mod.VkCullModeFlags = driver_mod.VK_CULL_MODE_NONE,
    topology: driver_mod.VkPrimitiveTopology,
    vertex_bindings: []const driver_mod.VkVertexInputBindingDescription,
    vertex_attributes: []const driver_mod.VkVertexInputAttributeDescription,
    descriptors: []const VkDescriptorSetLayoutBinding,
    push_constant_bytes: u32 = 0,
};

pub const Pipeline = struct {
    pipeline: VkPipeline,
    layout: VkPipelineLayout,
    set_layout: VkDescriptorSetLayout,

    /// Front faces wind counter-clockwise in framebuffer space, where y grows down, and
    /// `desc.cull` names the faces culled.
    pub fn create(raster: *Raster, desc: PipelineDesc) Error!Pipeline {
        if (desc.descriptors.len > max_descriptors) return Error.InitializationFailed;
        if (desc.vertex_bindings.len > raster.max_vertex_buffers) return Error.InitializationFailed;
        if (desc.vertex_attributes.len > raster.max_vertex_attributes) return Error.InitializationFailed;
        const rt = raster.runtime;
        const drv = &rt._driver;
        const module = try rt._shader_cache.populateCache(rt, desc.words);

        const set_ci = driver_mod.VkDescriptorSetLayoutCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = @intCast(desc.descriptors.len),
            .pBindings = if (desc.descriptors.len == 0) null else desc.descriptors.ptr,
        };
        var set_layout: VkDescriptorSetLayout = null;
        try drv.fromResult(drv.vkCreateDescriptorSetLayout(rt._logical_device, &set_ci, null, &set_layout));
        errdefer drv.vkDestroyDescriptorSetLayout(rt._logical_device, set_layout, null);

        std.debug.assert(desc.push_constant_bytes % 4 == 0);
        const push_range = driver_mod.VkPushConstantRange{
            .stageFlags = push_constant_stages,
            .offset = 0,
            .size = desc.push_constant_bytes,
        };
        const pushes = desc.push_constant_bytes != 0;
        const layout_ci = driver_mod.VkPipelineLayoutCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = @ptrCast(&set_layout),
            .pushConstantRangeCount = if (pushes) 1 else 0,
            .pPushConstantRanges = if (pushes) @ptrCast(&push_range) else null,
        };
        var layout: VkPipelineLayout = null;
        try drv.fromResult(drv.vkCreatePipelineLayout(rt._logical_device, &layout_ci, null, &layout));
        errdefer drv.vkDestroyPipelineLayout(rt._logical_device, layout, null);

        const stages = [2]driver_mod.VkPipelineShaderStageCreateInfo{
            .{
                .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = driver_mod.VK_SHADER_STAGE_VERTEX_BIT,
                .module = module,
                .pName = desc.vertex_entry,
                .pSpecializationInfo = null,
            },
            .{
                .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .stage = driver_mod.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = module,
                .pName = desc.fragment_entry,
                .pSpecializationInfo = null,
            },
        };
        const vertex_input = driver_mod.VkPipelineVertexInputStateCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = @intCast(desc.vertex_bindings.len),
            .pVertexBindingDescriptions = if (desc.vertex_bindings.len == 0) null else desc.vertex_bindings.ptr,
            .vertexAttributeDescriptionCount = @intCast(desc.vertex_attributes.len),
            .pVertexAttributeDescriptions = if (desc.vertex_attributes.len == 0) null else desc.vertex_attributes.ptr,
        };
        const input_assembly = driver_mod.VkPipelineInputAssemblyStateCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = desc.topology,
            .primitiveRestartEnable = driver_mod.VK_FALSE,
        };
        const viewport = driver_mod.VkPipelineViewportStateCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null,
            .scissorCount = 1,
            .pScissors = null,
        };
        const depth_test: DepthTest = desc.depth orelse .{
            .format = driver_mod.VK_FORMAT_UNDEFINED,
            .compare = driver_mod.VK_COMPARE_OP_ALWAYS,
            .write = false,
        };
        const rasterization = driver_mod.VkPipelineRasterizationStateCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = driver_mod.VK_FALSE,
            .rasterizerDiscardEnable = driver_mod.VK_FALSE,
            .polygonMode = driver_mod.VK_POLYGON_MODE_FILL,
            .cullMode = desc.cull,
            .frontFace = driver_mod.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = if (depth_test.biased()) driver_mod.VK_TRUE else driver_mod.VK_FALSE,
            .depthBiasConstantFactor = depth_test.bias_constant,
            .depthBiasClamp = depth_test.bias_clamp,
            .depthBiasSlopeFactor = depth_test.bias_slope,
            .lineWidth = 1,
        };
        const multisample = driver_mod.VkPipelineMultisampleStateCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = driver_mod.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = driver_mod.VK_FALSE,
            .minSampleShading = 0,
            .pSampleMask = null,
            .alphaToCoverageEnable = driver_mod.VK_FALSE,
            .alphaToOneEnable = driver_mod.VK_FALSE,
        };
        const depth_stencil = if (desc.depth) |depth| driver_mod.VkPipelineDepthStencilStateCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthTestEnable = driver_mod.VK_TRUE,
            .depthWriteEnable = if (depth.write) driver_mod.VK_TRUE else driver_mod.VK_FALSE,
            .depthCompareOp = depth.compare,
            .depthBoundsTestEnable = driver_mod.VK_FALSE,
            .stencilTestEnable = driver_mod.VK_FALSE,
            .front = .{},
            .back = .{},
            .minDepthBounds = 0,
            .maxDepthBounds = 1,
        } else null;
        const attachment = blendState(desc.blend);
        const color_blend = driver_mod.VkPipelineColorBlendStateCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = driver_mod.VK_FALSE,
            .logicOp = 0,
            .attachmentCount = 1,
            .pAttachments = @ptrCast(&attachment),
            .blendConstants = .{ 0, 0, 0, 0 },
        };
        const dynamic_states = [_]driver_mod.VkDynamicState{
            driver_mod.VK_DYNAMIC_STATE_VIEWPORT,
            driver_mod.VK_DYNAMIC_STATE_SCISSOR,
        };
        const dynamic = driver_mod.VkPipelineDynamicStateCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };
        var color_format = desc.color_format;
        const rendering = driver_mod.VkPipelineRenderingCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .pNext = null,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats = @ptrCast(&color_format),
            .depthAttachmentFormat = if (desc.depth) |depth| depth.format else driver_mod.VK_FORMAT_UNDEFINED,
            .stencilAttachmentFormat = driver_mod.VK_FORMAT_UNDEFINED,
        };
        const ci = driver_mod.VkGraphicsPipelineCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = @ptrCast(&rendering),
            .flags = 0,
            .stageCount = stages.len,
            .pStages = &stages,
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport,
            .pRasterizationState = &rasterization,
            .pMultisampleState = &multisample,
            .pDepthStencilState = if (depth_stencil) |*state| state else null,
            .pColorBlendState = &color_blend,
            .pDynamicState = &dynamic,
            .layout = layout,
            .renderPass = 0,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };
        var pipeline: VkPipeline = null;
        try drv.fromResult(drv.vkCreateGraphicsPipelines(rt._logical_device, null, 1, @ptrCast(&ci), null, @ptrCast(&pipeline)));
        return .{ .pipeline = pipeline, .layout = layout, .set_layout = set_layout };
    }

    pub fn destroy(self: *Pipeline, raster: *Raster) void {
        raster.idle();
        const rt = raster.runtime;
        rt._driver.vkDestroyPipeline(rt._logical_device, self.pipeline, null);
        rt._driver.vkDestroyPipelineLayout(rt._logical_device, self.layout, null);
        rt._driver.vkDestroyDescriptorSetLayout(rt._logical_device, self.set_layout, null);
        self.* = undefined;
    }
};

/// One resource for one binding of set 0.
pub const Descriptor = struct {
    binding: u32,
    resource: union(enum) {
        buffer: struct { buffer: VkBuffer, kind: driver_mod.VkDescriptorType },
        image: struct { view: VkImageView, layout: VkImageLayout, sampler: VkSampler },
    },
};

/// A descriptor set written once when it is made and bound by every draw that names it.
pub const BindingSet = struct {
    set: VkDescriptorSet,
    pool_index: u32,

    pub fn create(raster: *Raster, pipeline: *const Pipeline, descriptors: []const Descriptor) Error!BindingSet {
        if (descriptors.len > max_descriptors) return Error.InitializationFailed;
        var created = try raster.allocateSet(pipeline.set_layout);
        errdefer created.destroy(raster);
        var buffers: [max_descriptors]driver_mod.VkDescriptorBufferInfo = undefined;
        var images: [max_descriptors]driver_mod.VkDescriptorImageInfo = undefined;
        var writes: [max_descriptors]driver_mod.VkWriteDescriptorSet = undefined;
        for (descriptors, 0..) |descriptor, index| {
            writes[index] = .{
                .sType = driver_mod.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = created.set,
                .dstBinding = descriptor.binding,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = undefined,
                .pImageInfo = null,
                .pBufferInfo = null,
                .pTexelBufferView = null,
            };
            switch (descriptor.resource) {
                .buffer => |buffer| {
                    buffers[index] = .{ .buffer = buffer.buffer, .offset = 0, .range = driver_mod.VK_WHOLE_SIZE };
                    writes[index].descriptorType = buffer.kind;
                    writes[index].pBufferInfo = @ptrCast(&buffers[index]);
                },
                .image => |image| {
                    images[index] = .{ .sampler = image.sampler, .imageView = image.view, .imageLayout = image.layout };
                    writes[index].descriptorType = driver_mod.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                    writes[index].pImageInfo = @ptrCast(&images[index]);
                },
            }
        }
        const rt = raster.runtime;
        rt._driver.vkUpdateDescriptorSets(rt._logical_device, @intCast(descriptors.len), @ptrCast(&writes), 0, null);
        return created;
    }

    pub fn destroy(self: *BindingSet, raster: *Raster) void {
        raster.idle();
        const rt = raster.runtime;
        const entry = &raster.descriptor_pools.items[self.pool_index];
        std.debug.assert(entry.live != 0);
        var set = self.set;
        _ = rt._driver.vkFreeDescriptorSets(rt._logical_device, entry.pool, 1, @ptrCast(&set));
        entry.live -= 1;
        self.* = undefined;
    }
};

/// A pass attachment: the image and view a pass draws into, its size, the layouts it holds before
/// and after the pass, and whether the pass clears it to `clear` or keeps its contents. An image
/// this backend made rests in its home layout on both sides. A swapchain image arrives in the
/// layout its last use left and leaves ready to present.
pub const Attachment = struct {
    image: VkImage,
    view: VkImageView,
    aspect: VkImageAspectFlags,
    width: u32,
    height: u32,
    before: VkImageLayout,
    after: VkImageLayout,
    clear: ?driver_mod.VkClearValue,
};

pub const Targets = struct {
    color: Attachment,
    depth: ?Attachment,
    viewport: driver_mod.VkViewport,
    scissor: driver_mod.VkRect2D,
};

const color_layout = driver_mod.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
const depth_layout = driver_mod.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL;

/// Opens a pass over the whole color target: a full barrier, each attachment moved out of the
/// layout it held before the pass, then dynamic rendering with the pass's viewport and scissor.
pub fn beginPass(drv: *const Driver, cb: VkCommandBuffer, targets: Targets) void {
    var barriers: [2]driver_mod.VkImageMemoryBarrier = undefined;
    var count: usize = 0;
    const color = targets.color;
    if (color.before != color_layout) {
        barriers[count] = layoutBarrier(color.image, color.aspect, color.before, color_layout);
        count += 1;
    }
    if (targets.depth) |depth| if (depth.before != depth_layout) {
        barriers[count] = layoutBarrier(depth.image, depth.aspect, depth.before, depth_layout);
        count += 1;
    };
    recordBarrier(drv, cb, barriers[0..count]);

    const color_info = attachmentInfo(targets.color, color_layout);
    const depth_info = if (targets.depth) |depth| attachmentInfo(depth, depth_layout) else undefined;
    const info = driver_mod.VkRenderingInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .pNext = null,
        .flags = 0,
        .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = color.width, .height = color.height } },
        .layerCount = 1,
        .viewMask = 0,
        .colorAttachmentCount = 1,
        .pColorAttachments = @ptrCast(&color_info),
        .pDepthAttachment = if (targets.depth != null) &depth_info else null,
        .pStencilAttachment = null,
    };
    drv.vkCmdBeginRendering(cb, &info);
    drv.vkCmdSetViewport(cb, 0, 1, @ptrCast(&targets.viewport));
    drv.vkCmdSetScissor(cb, 0, 1, @ptrCast(&targets.scissor));
}

/// Closes a pass and moves each attachment to the layout it holds after the pass, behind a full
/// barrier.
pub fn endPass(drv: *const Driver, cb: VkCommandBuffer, targets: Targets) void {
    drv.vkCmdEndRendering(cb);
    var barriers: [2]driver_mod.VkImageMemoryBarrier = undefined;
    var count: usize = 0;
    const color = targets.color;
    if (color.after != color_layout) {
        barriers[count] = layoutBarrier(color.image, color.aspect, color_layout, color.after);
        count += 1;
    }
    if (targets.depth) |depth| if (depth.after != depth_layout) {
        barriers[count] = layoutBarrier(depth.image, depth.aspect, depth_layout, depth.after);
        count += 1;
    };
    recordBarrier(drv, cb, barriers[0..count]);
}

fn attachmentInfo(attachment: Attachment, layout: VkImageLayout) driver_mod.VkRenderingAttachmentInfo {
    return .{
        .sType = driver_mod.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .pNext = null,
        .imageView = attachment.view,
        .imageLayout = layout,
        .resolveMode = driver_mod.VK_RESOLVE_MODE_NONE,
        .resolveImageView = 0,
        .resolveImageLayout = driver_mod.VK_IMAGE_LAYOUT_UNDEFINED,
        .loadOp = if (attachment.clear != null) driver_mod.VK_ATTACHMENT_LOAD_OP_CLEAR else driver_mod.VK_ATTACHMENT_LOAD_OP_LOAD,
        .storeOp = driver_mod.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = attachment.clear orelse std.mem.zeroes(driver_mod.VkClearValue),
    };
}

/// A command buffer from `stream`'s pool, begun for one submission.
pub fn beginStreamPass(stream: *Stream) Error!VkCommandBuffer {
    return beginOneShot(stream);
}

/// A command buffer from the raster's pool, begun so it may be pending more than once.
pub fn beginBundle(raster: *Raster) Error!VkCommandBuffer {
    const cb = try raster.allocateBundle();
    errdefer raster.discardBundle(cb);
    try beginCommandBuffer(&raster.runtime._driver, cb, driver_mod.VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT);
    return cb;
}

pub const Submission = struct {
    stream: *Stream,
    cb: VkCommandBuffer,
    wait_events: []const *Event,
    signal_event: ?*Event,
    /// Whether the stream takes the command buffer back for reuse once the submission finishes.
    /// A bundle's command buffer stays with its bundle.
    retire: bool,
    /// A binary semaphore the submission also signals, for a waiter outside the stream.
    signal_semaphore: ?driver_mod.VkSemaphore = null,
    /// A binary semaphore the submission also waits on, such as the one a swapchain signals when
    /// it hands over the image a pass draws into.
    wait_semaphore: ?driver_mod.VkSemaphore = null,
};

/// Submits a recorded command buffer after the stream's previous work and every wait event, and
/// advances the stream's timeline past it.
pub fn submit(raster: *Raster, submission: Submission) Error!void {
    const stream = submission.stream;
    if (stream.poisoned) return Error.StreamPoisoned;
    if (submission.wait_events.len > max_wait_events) return Error.InitializationFailed;
    const rt = raster.runtime;
    const drv = &rt._driver;
    var waits: [max_wait_events + 2]driver_mod.VkSemaphoreSubmitInfo = undefined;
    waits[0] = semaphoreInfo(stream._semaphore, stream.counter);
    for (submission.wait_events, 1..) |event, index| {
        if (!event.recorded) return Error.InitializationFailed;
        waits[index] = semaphoreInfo(event._semaphore, event.value);
    }
    var wait_count: usize = 1 + submission.wait_events.len;
    if (submission.wait_semaphore) |semaphore| {
        waits[wait_count] = semaphoreInfo(semaphore, 0);
        wait_count += 1;
    }
    const signal_value = stream.counter + 1;
    var signals = [2]driver_mod.VkSemaphoreSubmitInfo{ semaphoreInfo(stream._semaphore, signal_value), undefined };
    if (submission.signal_semaphore) |semaphore| signals[1] = semaphoreInfo(semaphore, 0);
    const command = driver_mod.VkCommandBufferSubmitInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .pNext = null,
        .commandBuffer = submission.cb,
        .deviceMask = 0,
    };
    const info = driver_mod.VkSubmitInfo2{
        .sType = driver_mod.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .pNext = null,
        .flags = 0,
        .waitSemaphoreInfoCount = @intCast(wait_count),
        .pWaitSemaphoreInfos = @ptrCast(&waits),
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = @ptrCast(&command),
        .signalSemaphoreInfoCount = if (submission.signal_semaphore != null) 2 else 1,
        .pSignalSemaphoreInfos = @ptrCast(&signals),
    };
    drv.fromResult(drv.vkQueueSubmit2(rt._queue, 1, @ptrCast(&info), null)) catch |err| {
        stream.poisoned = true;
        return err;
    };
    raster.pending = true;
    if (submission.retire) runtime_mod.retireStreamCommandBuffer(stream, submission.cb, signal_value);
    stream.counter = signal_value;
    if (submission.signal_event) |event| {
        event._semaphore = stream._semaphore;
        event.value = signal_value;
        event.recorded = true;
    }
}

fn semaphoreInfo(semaphore: driver_mod.VkSemaphore, value: u64) driver_mod.VkSemaphoreSubmitInfo {
    return .{
        .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = semaphore,
        .value = value,
        .stageMask = pipeline_stage_2_all_commands,
        .deviceIndex = 0,
    };
}
