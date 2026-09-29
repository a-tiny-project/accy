//! Color images the runtime renders into and shares with another process, such as a Wayland
//! compositor, as dma-bufs. Each image has a DRM timeline syncobj that orders the two processes'
//! access to it.
//!
//! On its n-th use (n from 0) image i moves through two points of timeline i:
//! - acquire point 2n+1 signals when the device has finished rendering the frame;
//! - release point 2n+2 is the consumer's to signal once it has stopped reading the image.
//! Use n+1 waits on the host for release point 2n+2 before recording anything that touches the
//! image. Each image has its own timeline, so points on a timeline are always added in increasing
//! order, however the consumer orders its releases across images.
//!
//! Ownership moves between the runtime's queue family and `VK_QUEUE_FAMILY_FOREIGN_EXT`. A frame
//! acquires the image from the foreign family in the general layout, renders to it in
//! `COLOR_ATTACHMENT_OPTIMAL`, and releases it back in the general layout. The first use has
//! nothing to acquire and starts from `UNDEFINED`.
//!
//! The device's completion reaches the timeline through one binary semaphore. Each frame's
//! submission signals it, then it is exported as a sync_file, which also unsignals it (copy
//! transference). The sync_file is imported at the acquire point with one ioctl. Every Linux Vulkan
//! driver exports SYNC_FD. Importing a syncobj into Vulkan as a timeline semaphore would skip the
//! sync_file, but drivers need not support that import.

const std = @import("std");
const sys = @import("sys");

const driver_mod = sys.vulkan;
const drm = sys.drm;
const raster_mod = @import("raster.zig");
const runtime_mod = @import("runtime.zig");

pub const Error = driver_mod.Error || drm.Error || error{
    /// The device did not enable dma-buf export or cannot name its render node.
    NoDmabufDevice,
    /// The device supports no modifier of the format that the consumer lists.
    NoSharedModifier,
};

const Raster = raster_mod.Raster;
const Runtime = runtime_mod.Runtime;
const VkCommandBuffer = driver_mod.VkCommandBuffer;
const VkFormat = driver_mod.VkFormat;
const VkImage = driver_mod.VkImage;
const VkSemaphore = driver_mod.VkSemaphore;

/// Images in one target. Four covers a consumer that holds one image on screen, one queued, and
/// one being released while the renderer draws the fourth.
pub const max_images: u32 = 4;

/// Memory planes one image may have. A modifier with compression metadata uses more than one.
pub const max_planes: u32 = 4;

/// Modifiers of one format, as a device lists them or a consumer offers them.
pub const max_modifiers: u32 = 64;

/// How long `destroy` waits for the consumer to release each image before freeing it anyway.
const release_grace_ns: i64 = std.time.ns_per_s;

const color_layout = driver_mod.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
const shared_layout = driver_mod.VK_IMAGE_LAYOUT_GENERAL;
const all_access = driver_mod.VK_ACCESS_MEMORY_READ_BIT | driver_mod.VK_ACCESS_MEMORY_WRITE_BIT;
const dma_buf = driver_mod.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
const sync_fd = driver_mod.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;

const plane_aspects = [max_planes]driver_mod.VkImageAspectFlags{
    driver_mod.VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT,
    driver_mod.VK_IMAGE_ASPECT_MEMORY_PLANE_1_BIT_EXT,
    driver_mod.VK_IMAGE_ASPECT_MEMORY_PLANE_2_BIT_EXT,
    driver_mod.VK_IMAGE_ASPECT_MEMORY_PLANE_3_BIT_EXT,
};

pub const Plane = struct {
    offset: u32,
    stride: u32,
};

/// What a consumer needs to import one image: the dma-buf, the modifier the driver chose, and
/// where each memory plane sits in the dma-buf.
pub const Dmabuf = struct {
    /// Owned by the target and closed when it is destroyed. A consumer that takes ownership of a
    /// descriptor it is handed needs its own duplicate.
    fd: i32,
    modifier: u64,
    planes: [max_planes]Plane,
    plane_count: u32,
};

pub const Desc = struct {
    width: u32,
    height: u32,
    format: VkFormat,
    /// Modifiers of `format` the consumer can import.
    modifiers: []const u64,
    image_count: u32,
    /// The device the consumer wants buffers from, such as a compositor's main device.
    device: drm.DeviceNumber,
};

/// One image's turn: which image, and the points that bound it.
pub const Frame = struct {
    index: u32,
    acquire_point: u64,
    release_point: u64,
};

const Slot = struct {
    image: VkImage,
    dmabuf: Dmabuf,
    timeline: drm.Syncobj,
    /// The timeline exported for the consumer, owned by the target.
    timeline_fd: i32,
    /// Frames rendered into the image so far.
    uses: u64,
};

pub const Target = struct {
    runtime: *Runtime,
    node: drm.RenderNode,
    semaphore: VkSemaphore,
    slots: [max_images]Slot,
    count: u32,
    /// The image the next frame renders into.
    next: u32,
    /// The frame begun and not yet submitted.
    open: ?Frame,
    /// A timeline for `bridgeScratch`, made on its first call.
    scratch: ?drm.Syncobj = null,
    scratch_point: u64 = 0,

    /// Makes `desc.image_count` images from the modifiers the device and the consumer share, each
    /// with its view in `images`, its dma-buf and its timeline. The caller owns `images` and
    /// destroys them after the target.
    pub fn create(raster: *Raster, desc: Desc, images: *[max_images]raster_mod.Image) Error!Target {
        if (desc.image_count == 0 or desc.image_count > max_images) return error.InitializationFailed;
        if (desc.width == 0 or desc.height == 0) return error.InitializationFailed;
        if (desc.width > raster.max_image_extent or desc.height > raster.max_image_extent) return error.InitializationFailed;
        const rt = raster.runtime;
        const device = rt.device.dmabufRenderNode() orelse return error.NoDmabufDevice;
        if (!std.meta.eql(device, desc.device)) return error.DeviceMismatch;
        var shared_storage: [max_modifiers]u64 = undefined;
        const modifiers = try sharedModifiers(rt, desc.format, desc.modifiers, &shared_storage);

        const node = try drm.RenderNode.open(device);
        errdefer node.close();
        const semaphore = try exportableSemaphore(rt);
        errdefer rt._driver.vkDestroySemaphore(rt._logical_device, semaphore, null);

        var target = Target{
            .runtime = rt,
            .node = node,
            .semaphore = semaphore,
            .slots = undefined,
            .count = 0,
            .next = 0,
            .open = null,
        };
        errdefer while (target.count > 0) {
            target.count -= 1;
            target.closeSlot(target.count);
            images[target.count].destroy(raster);
        };
        while (target.count < desc.image_count) {
            const index = target.count;
            images[index] = try createImage(raster, desc, modifiers);
            errdefer images[index].destroy(raster);
            target.slots[index] = try target.openSlot(&images[index]);
            target.count += 1;
        }
        return target;
    }

    /// Waits for the consumer to release every image, up to a grace period, then frees the
    /// target's descriptors, syncobjs and semaphore. The caller then destroys the images.
    pub fn destroy(self: *Target, raster: *Raster) void {
        std.debug.assert(self.open == null);
        raster.idle();
        const deadline = drm.monotonicNow() + release_grace_ns;
        for (self.slots[0..self.count], 0..) |slot, index| {
            if (slot.uses != 0) self.node.waitPoint(slot.timeline, 2 * slot.uses, deadline) catch |err| {
                std.log.scoped(.vulkan_dmabuf).warn("image {d} not released before destroy: {s}", .{ index, @errorName(err) });
            };
            self.closeSlot(@intCast(index));
        }
        if (self.scratch) |scratch| self.node.destroySyncobj(scratch);
        self.runtime._driver.vkDestroySemaphore(self.runtime._logical_device, self.semaphore, null);
        self.node.close();
        self.* = undefined;
    }

    pub fn dmabuf(self: *const Target, index: u32) Dmabuf {
        std.debug.assert(index < self.count);
        return self.slots[index].dmabuf;
    }

    /// The descriptor of image `index`'s timeline, owned by the target.
    pub fn timelineFd(self: *const Target, index: u32) i32 {
        std.debug.assert(index < self.count);
        return self.slots[index].timeline_fd;
    }

    /// The highest point of image `index`'s timeline that has signalled.
    pub fn signalledPoint(self: *const Target, index: u32) Error!u64 {
        std.debug.assert(index < self.count);
        return self.node.signalledPoint(self.slots[index].timeline);
    }

    /// Picks the next image and waits, until `deadline_ns` on `CLOCK_MONOTONIC`, for the consumer
    /// to release it from its previous frame.
    pub fn begin(self: *Target, deadline_ns: i64) Error!Frame {
        std.debug.assert(self.open == null);
        const index = self.next;
        const slot = &self.slots[index];
        if (slot.uses != 0) try self.node.waitPoint(slot.timeline, 2 * slot.uses, deadline_ns);
        const frame = Frame{ .index = index, .acquire_point = 2 * slot.uses + 1, .release_point = 2 * slot.uses + 2 };
        self.open = frame;
        return frame;
    }

    /// Records the barrier that takes the frame's image from the consumer into the attachment
    /// layout a pass renders in.
    pub fn recordAcquire(self: *const Target, cb: VkCommandBuffer, frame: Frame) void {
        const slot = &self.slots[frame.index];
        const first = slot.uses == 0;
        const handoff = self.ownershipBarrier(slot.image, .{
            .src_access = 0,
            .dst_access = all_access,
            .old = if (first) driver_mod.VK_IMAGE_LAYOUT_UNDEFINED else shared_layout,
            .new = color_layout,
            .src_family = if (first) driver_mod.VK_QUEUE_FAMILY_IGNORED else driver_mod.VK_QUEUE_FAMILY_FOREIGN_EXT,
            .dst_family = if (first) driver_mod.VK_QUEUE_FAMILY_IGNORED else self.runtime.device.queueFamilyIndex(),
        });
        raster_mod.recordBarrier(&self.runtime._driver, cb, &.{handoff});
    }

    /// Records the barrier that hands the frame's image to the consumer once the pass has written it.
    pub fn recordRelease(self: *const Target, cb: VkCommandBuffer, frame: Frame) void {
        const handoff = self.ownershipBarrier(self.slots[frame.index].image, .{
            .src_access = driver_mod.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dst_access = 0,
            .old = color_layout,
            .new = shared_layout,
            .src_family = self.runtime.device.queueFamilyIndex(),
            .dst_family = driver_mod.VK_QUEUE_FAMILY_FOREIGN_EXT,
        });
        raster_mod.recordBarrier(&self.runtime._driver, cb, &.{handoff});
    }

    /// Attaches the fence of the submission that signalled `semaphore` to the frame's acquire
    /// point and moves to the next image. The frame's submission must already be queued.
    pub fn finish(self: *Target, frame: Frame) Error!void {
        std.debug.assert(std.meta.eql(self.open, frame));
        const slot = &self.slots[frame.index];
        try self.bridge(slot.timeline, frame.acquire_point);
        slot.uses += 1;
        self.next = (self.next + 1) % self.count;
        self.open = null;
    }

    /// Signals a finished frame's release point from the host, for a frame the consumer never
    /// received. The point still follows the frame's acquire point, since a timeline point
    /// signals only once every earlier point has.
    pub fn reclaim(self: *Target, frame: Frame) Error!void {
        std.debug.assert(frame.index < self.count);
        std.debug.assert(frame.release_point == 2 * self.slots[frame.index].uses);
        try self.node.signalPoint(self.slots[frame.index].timeline, frame.release_point);
    }

    /// Exports the semaphore that a submission just signalled as a sync_file, and attaches it to
    /// the next point of a scratch timeline. The same work `finish` does, on a timeline no
    /// consumer reads, so a caller can time it apart from any frame.
    pub fn bridgeScratch(self: *Target) Error!void {
        const scratch = self.scratch orelse blk: {
            const created = try self.node.createSyncobj();
            self.scratch = created;
            break :blk created;
        };
        self.scratch_point += 1;
        try self.bridge(scratch, self.scratch_point);
    }

    /// Gives up a begun frame whose submission never queued. The image keeps its previous state.
    pub fn abandon(self: *Target, frame: Frame) void {
        std.debug.assert(std.meta.eql(self.open, frame));
        self.open = null;
    }

    /// Moves the fence of the semaphore's last signal onto `point` of `timeline`. A fence that had
    /// already signalled when exported comes back as -1, and the point is signalled from the host
    /// instead.
    fn bridge(self: *Target, timeline: drm.Syncobj, point: u64) Error!void {
        const rt = self.runtime;
        const drv = &rt._driver;
        const get_fd = drv.vkGetSemaphoreFdKHR orelse return error.NoDmabufDevice;
        var fence: c_int = -1;
        const info = driver_mod.VkSemaphoreGetFdInfoKHR{ .semaphore = self.semaphore, .handleType = sync_fd };
        try drv.fromResult(get_fd(rt._logical_device, &info, &fence));
        if (fence < 0) return self.node.signalPoint(timeline, point);
        defer sys.fd.close(fence);
        try self.node.importSyncFile(timeline, point, fence);
    }

    const BarrierDesc = struct {
        src_access: driver_mod.VkAccessFlags,
        dst_access: driver_mod.VkAccessFlags,
        old: driver_mod.VkImageLayout,
        new: driver_mod.VkImageLayout,
        src_family: u32,
        dst_family: u32,
    };

    fn ownershipBarrier(_: *const Target, image: VkImage, desc: BarrierDesc) driver_mod.VkImageMemoryBarrier {
        return .{
            .sType = driver_mod.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = desc.src_access,
            .dstAccessMask = desc.dst_access,
            .oldLayout = desc.old,
            .newLayout = desc.new,
            .srcQueueFamilyIndex = desc.src_family,
            .dstQueueFamilyIndex = desc.dst_family,
            .image = image,
            .subresourceRange = raster_mod.subresourceRange(driver_mod.VK_IMAGE_ASPECT_COLOR_BIT),
        };
    }

    /// Exports `image`'s memory and plane layout and gives it a fresh timeline.
    fn openSlot(self: *const Target, image: *const raster_mod.Image) Error!Slot {
        const rt = self.runtime;
        const drv = &rt._driver;
        const device = rt._logical_device;
        const memory = image.backing.dedicated;
        const get_modifier = drv.vkGetImageDrmFormatModifierPropertiesEXT orelse return error.NoDmabufDevice;
        const get_memory_fd = drv.vkGetMemoryFdKHR orelse return error.NoDmabufDevice;

        var modifier_properties = driver_mod.VkImageDrmFormatModifierPropertiesEXT{};
        try drv.fromResult(get_modifier(device, image.image, &modifier_properties));
        const plane_count = try planeCount(rt, image.format, modifier_properties.drmFormatModifier);
        var planes: [max_planes]Plane = undefined;
        for (plane_aspects[0..plane_count], planes[0..plane_count]) |aspect, *plane| {
            var layout = driver_mod.VkSubresourceLayout{};
            drv.vkGetImageSubresourceLayout(device, image.image, &.{ .aspectMask = aspect }, &layout);
            plane.* = .{
                .offset = std.math.cast(u32, layout.offset) orelse return error.InitializationFailed,
                .stride = std.math.cast(u32, layout.rowPitch) orelse return error.InitializationFailed,
            };
        }

        var fd: c_int = -1;
        const fd_info = driver_mod.VkMemoryGetFdInfoKHR{ .memory = memory, .handleType = dma_buf };
        try drv.fromResult(get_memory_fd(device, &fd_info, &fd));
        errdefer sys.fd.close(fd);
        const timeline = try self.node.createSyncobj();
        errdefer self.node.destroySyncobj(timeline);
        const timeline_fd = try self.node.exportSyncobj(timeline);
        return .{
            .image = image.image,
            .dmabuf = .{
                .fd = fd,
                .modifier = modifier_properties.drmFormatModifier,
                .planes = planes,
                .plane_count = plane_count,
            },
            .timeline = timeline,
            .timeline_fd = timeline_fd,
            .uses = 0,
        };
    }

    fn closeSlot(self: *const Target, index: u32) void {
        const slot = self.slots[index];
        sys.fd.close(slot.timeline_fd);
        self.node.destroySyncobj(slot.timeline);
        sys.fd.close(slot.dmabuf.fd);
    }
};

/// The modifiers in `offered` that the device can render `format` to, in the consumer's order.
fn sharedModifiers(rt: *Runtime, format: VkFormat, offered: []const u64, storage: *[max_modifiers]u64) Error![]const u64 {
    var listed_storage: [max_modifiers]driver_mod.VkDrmFormatModifierPropertiesEXT = undefined;
    const listed = listModifiers(rt, format, &listed_storage);
    var count: usize = 0;
    for (offered) |modifier| {
        if (count == max_modifiers) break;
        for (listed) |entry| {
            if (entry.drmFormatModifier != modifier) continue;
            if (entry.drmFormatModifierTilingFeatures & driver_mod.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT == 0) break;
            if (entry.drmFormatModifierPlaneCount > max_planes) break;
            storage[count] = modifier;
            count += 1;
            break;
        }
    }
    if (count == 0) return error.NoSharedModifier;
    return storage[0..count];
}

fn listModifiers(
    rt: *Runtime,
    format: VkFormat,
    storage: *[max_modifiers]driver_mod.VkDrmFormatModifierPropertiesEXT,
) []const driver_mod.VkDrmFormatModifierPropertiesEXT {
    var list = driver_mod.VkDrmFormatModifierPropertiesListEXT{
        .drmFormatModifierCount = max_modifiers,
        .pDrmFormatModifierProperties = storage,
    };
    var properties = driver_mod.VkFormatProperties2{ .pNext = &list };
    rt._driver.vkGetPhysicalDeviceFormatProperties2(rt._physical_device, format, &properties);
    return storage[0..@min(list.drmFormatModifierCount, max_modifiers)];
}

fn planeCount(rt: *Runtime, format: VkFormat, modifier: u64) Error!u32 {
    var storage: [max_modifiers]driver_mod.VkDrmFormatModifierPropertiesEXT = undefined;
    for (listModifiers(rt, format, &storage)) |entry| {
        if (entry.drmFormatModifier == modifier) {
            if (entry.drmFormatModifierPlaneCount == 0 or entry.drmFormatModifierPlaneCount > max_planes) return error.InitializationFailed;
            return entry.drmFormatModifierPlaneCount;
        }
    }
    return error.NoSharedModifier;
}

fn exportableSemaphore(rt: *Runtime) Error!VkSemaphore {
    const export_info = driver_mod.VkExportSemaphoreCreateInfo{ .handleTypes = sync_fd };
    const info = driver_mod.VkSemaphoreCreateInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = &export_info,
        .flags = 0,
    };
    var semaphore: VkSemaphore = null;
    try rt._driver.fromResult(rt._driver.vkCreateSemaphore(rt._logical_device, &info, null, &semaphore));
    return semaphore;
}

/// A color attachment with a modifier the driver picks from `modifiers`, bound to a dedicated
/// allocation it can export, and its view. It stays in `UNDEFINED` until its first frame.
fn createImage(raster: *Raster, desc: Desc, modifiers: []const u64) Error!raster_mod.Image {
    const rt = raster.runtime;
    const drv = &rt._driver;
    const device = rt._logical_device;
    const modifier_list = driver_mod.VkImageDrmFormatModifierListCreateInfoEXT{
        .drmFormatModifierCount = @intCast(modifiers.len),
        .pDrmFormatModifiers = modifiers.ptr,
    };
    const external = driver_mod.VkExternalMemoryImageCreateInfo{ .pNext = &modifier_list, .handleTypes = dma_buf };
    const ci = driver_mod.VkImageCreateInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = &external,
        .flags = 0,
        .imageType = driver_mod.VK_IMAGE_TYPE_2D,
        .format = desc.format,
        .extent = .{ .width = desc.width, .height = desc.height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = driver_mod.VK_SAMPLE_COUNT_1_BIT,
        .tiling = driver_mod.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = driver_mod.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .sharingMode = driver_mod.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = driver_mod.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var image: VkImage = 0;
    try drv.fromResult(drv.vkCreateImage(device, &ci, null, &image));
    errdefer drv.vkDestroyImage(device, image, null);

    var requirements: driver_mod.VkMemoryRequirements = undefined;
    drv.vkGetImageMemoryRequirements(device, image, &requirements);
    const type_index = rt._memory.typeFor(requirements, .device) orelse return error.OutOfDeviceMemory;
    const dedicated = driver_mod.VkMemoryDedicatedAllocateInfo{ .image = image };
    const export_info = driver_mod.VkExportMemoryAllocateInfo{ .pNext = &dedicated, .handleTypes = dma_buf };
    const allocate_info = driver_mod.VkMemoryAllocateInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = &export_info,
        .allocationSize = requirements.size,
        .memoryTypeIndex = type_index,
    };
    var memory: driver_mod.VkDeviceMemory = null;
    try drv.fromResult(drv.vkAllocateMemory(device, &allocate_info, null, &memory));
    errdefer drv.vkFreeMemory(device, memory, null);
    try drv.fromResult(drv.vkBindImageMemory(device, image, memory, 0));

    const view_ci = driver_mod.VkImageViewCreateInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = driver_mod.VK_IMAGE_VIEW_TYPE_2D,
        .format = desc.format,
        .components = .{},
        .subresourceRange = raster_mod.subresourceRange(driver_mod.VK_IMAGE_ASPECT_COLOR_BIT),
    };
    var view: driver_mod.VkImageView = 0;
    try drv.fromResult(drv.vkCreateImageView(device, &view_ci, null, &view));
    return .{
        .image = image,
        .view = view,
        .backing = .{ .dedicated = memory },
        .width = desc.width,
        .height = desc.height,
        .format = desc.format,
        .aspect = driver_mod.VK_IMAGE_ASPECT_COLOR_BIT,
        .texel_bytes = 4,
        .home = color_layout,
    };
}
