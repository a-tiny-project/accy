const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const sys = @import("sys");
const driver_mod = sys.vulkan;
const memory_mod = @import("memory.zig");
const observation = @import("observation.zig");

pub const Error = driver_mod.Error;
pub const MemoryPreference = memory_mod.Preference;

const Driver = driver_mod.Driver;
const VkInstance = driver_mod.VkInstance;
const VkPhysicalDevice = driver_mod.VkPhysicalDevice;
const VkDevice = driver_mod.VkDevice;
const VkQueue = driver_mod.VkQueue;
const VkSemaphore = driver_mod.VkSemaphore;
const VkCommandPool = driver_mod.VkCommandPool;
const VkCommandBuffer = driver_mod.VkCommandBuffer;
const VkFence = driver_mod.VkFence;
const VkBuffer = driver_mod.VkBuffer;
const VkDeviceMemory = driver_mod.VkDeviceMemory;
const VkQueryPool = driver_mod.VkQueryPool;
const VkSurfaceKHR = driver_mod.VkSurfaceKHR;
const VkSwapchainKHR = driver_mod.VkSwapchainKHR;
const VkImage = driver_mod.VkImage;
const VkImageView = driver_mod.VkImageView;
const VkSemaphoreWaitInfo = driver_mod.VkSemaphoreWaitInfo;
const VkSemaphoreSignalInfo = driver_mod.VkSemaphoreSignalInfo;
const VkSemaphoreCreateInfo = driver_mod.VkSemaphoreCreateInfo;
const VkCommandPoolCreateInfo = driver_mod.VkCommandPoolCreateInfo;
const VkCommandBufferAllocateInfo = driver_mod.VkCommandBufferAllocateInfo;
const VkBufferCreateInfo = driver_mod.VkBufferCreateInfo;
const VkMemoryAllocateInfo = driver_mod.VkMemoryAllocateInfo;
const VkMemoryRequirements = driver_mod.VkMemoryRequirements;
const VkPhysicalDeviceMemoryProperties = driver_mod.VkPhysicalDeviceMemoryProperties;
const VkMappedMemoryRange = driver_mod.VkMappedMemoryRange;
const VkBufferMemoryBarrier = driver_mod.VkBufferMemoryBarrier;
const VkBufferCopy = driver_mod.VkBufferCopy;
const VkSubmitInfo2 = driver_mod.VkSubmitInfo2;
const VkExtent2D = driver_mod.VkExtent2D;
const VkImageLayout = driver_mod.VkImageLayout;
const VkImageMemoryBarrier = driver_mod.VkImageMemoryBarrier;
const VkImageSubresourceRange = driver_mod.VkImageSubresourceRange;
const VkImageSubresourceLayers = driver_mod.VkImageSubresourceLayers;
const VkBufferImageCopy = driver_mod.VkBufferImageCopy;
const VkClearColorValue = driver_mod.VkClearColorValue;
const VkSurfaceCapabilitiesKHR = driver_mod.VkSurfaceCapabilitiesKHR;
const VkSurfaceFormatKHR = driver_mod.VkSurfaceFormatKHR;
const VkXlibSurfaceCreateInfoKHR = driver_mod.VkXlibSurfaceCreateInfoKHR;
const VkSwapchainCreateInfoKHR = driver_mod.VkSwapchainCreateInfoKHR;
const VkPresentInfoKHR = driver_mod.VkPresentInfoKHR;
const VkPresentModeKHR = driver_mod.VkPresentModeKHR;
const VkFormat = driver_mod.VkFormat;
const VkColorSpaceKHR = driver_mod.VkColorSpaceKHR;
const VkImageUsageFlags = driver_mod.VkImageUsageFlags;
const VkShaderModule = driver_mod.VkShaderModule;
const VkPipeline = driver_mod.VkPipeline;
const VkPipelineLayout = driver_mod.VkPipelineLayout;
const VkDescriptorSet = driver_mod.VkDescriptorSet;
const VkDescriptorSetLayout = driver_mod.VkDescriptorSetLayout;
const VkDescriptorPool = driver_mod.VkDescriptorPool;
const VkResult = driver_mod.VkResult;

pub const max_descriptor_sets_per_stream: u32 = 1024;

pub const max_buffers_per_set: u32 = 64;

const max_retired_command_buffers: usize = 64;

const max_retired_descriptor_sets: usize = 64;

const log = std.log.scoped(.vulkan_runtime);

const pipeline_stage_2_all_commands: u64 = 0x10000;

pub const Device = struct {
    _physical: VkPhysicalDevice,
    _api_version: u32 = 0,
    _queue_family_index: u32 = 0,
    _graphics: bool = false,
    _render_node: ?sys.drm.DeviceNumber = null,
    _name_buf: [driver_mod.VK_MAX_PHYSICAL_DEVICE_NAME_SIZE]u8 = @as([driver_mod.VK_MAX_PHYSICAL_DEVICE_NAME_SIZE]u8, @splat(0)),
    _name_len: usize = 0,

    pub fn name(self: *const Device) []const u8 {
        return self._name_buf[0..self._name_len];
    }

    pub fn apiVersion(self: *const Device) u32 {
        return self._api_version;
    }

    pub fn queueFamilyIndex(self: *const Device) u32 {
        return self._queue_family_index;
    }

    /// Whether the queue this runtime submits to also runs graphics work.
    pub fn graphics(self: *const Device) bool {
        return self._graphics;
    }

    /// The device's DRM render node when it can export images as dma-bufs and fences as sync
    /// files, which is what handing frames to a Wayland compositor takes.
    pub fn dmabufRenderNode(self: *const Device) ?sys.drm.DeviceNumber {
        return self._render_node;
    }
};

/// The device extensions that export images as dma-bufs and fences as sync files, and that name
/// the device's render node. The runtime enables them only when the device has every one.
const dmabuf_extensions = [_][*:0]const u8{
    driver_mod.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
    driver_mod.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
    driver_mod.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
    driver_mod.VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
    driver_mod.VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME,
    driver_mod.VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME,
};

fn renderNode(drv: *const Driver, allocator: std.mem.Allocator, phys: VkPhysicalDevice) Error!?sys.drm.DeviceNumber {
    for (dmabuf_extensions) |extension| {
        if (!try deviceHasExtension(drv, allocator, phys, std.mem.span(extension))) return null;
    }
    var drm_properties = driver_mod.VkPhysicalDeviceDrmPropertiesEXT{};
    var properties = driver_mod.VkPhysicalDeviceProperties2{
        .sType = driver_mod.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
        .pNext = @ptrCast(&drm_properties),
        .properties = undefined,
    };
    drv.vkGetPhysicalDeviceProperties2(phys, &properties);
    if (drm_properties.hasRender != driver_mod.VK_TRUE) return null;
    return .{ .major = @intCast(drm_properties.renderMajor), .minor = @intCast(drm_properties.renderMinor) };
}

pub const Runtime = struct {
    observer: ?*observation.AllocationObservation = null,
    allocator: std.mem.Allocator,
    device: Device,
    _driver: Driver,
    _instance: VkInstance,
    _physical_device: VkPhysicalDevice,
    _logical_device: VkDevice,
    _queue: VkQueue,
    _memory: memory_mod.Pool,
    _timestamp_period_ns: f32,
    /// Whether the device enabled `depthBiasClamp`, which a pipeline with a clamped bias needs.
    _depth_bias_clamp: bool = false,
    /// Whether the device enabled `samplerAnisotropy`, which an anisotropic sampler needs.
    _sampler_anisotropy: bool = false,
    _queue_timestamp_valid_bits: u32,
    _default_stream_cached: ?*Stream,
    _live_streams: std.AutoHashMapUnmanaged(*Stream, void),
    _shader_cache: ShaderModuleCache,
    _pipeline_layout_cache: PipelineLayoutCache,

    pub const Caps = struct {
        shader_float16: bool,
        shader_float64: bool,
        shader_int8: bool,
        shader_int16: bool,
        shader_int64: bool,
        storage_buffer8: bool,
        storage_buffer16: bool,
        subgroup_size: u32,
        subgroup_supported_stages: driver_mod.VkShaderStageFlags = 0,
        subgroup_supported_operations: driver_mod.VkSubgroupFeatureFlags = 0,
        vendor_id: u32,
        vendor_name: []const u8,
    };

    /// What a caller may set when it opens the runtime.
    pub const InitOptions = struct {
        /// The application name the instance reports to drivers and layers. Null leaves the
        /// application unnamed, which Vulkan permits.
        application_name: ?[*:0]const u8 = null,
        /// Counts the runtime's Vulkan objects. The caller retains it through failed
        /// initialization and teardown.
        observer: ?*observation.AllocationObservation = null,
    };

    pub fn init(allocator: std.mem.Allocator, device_ordinal: i32) Error!Runtime {
        return initWith(allocator, device_ordinal, .{});
    }

    pub fn initWith(allocator: std.mem.Allocator, device_ordinal: i32, options: InitOptions) Error!Runtime {
        const observer = options.observer;
        var drv = try Driver.open(allocator);
        errdefer drv.close();

        const app_info = driver_mod.VkApplicationInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = options.application_name,
            .applicationVersion = 0,
            .pEngineName = "gpu",
            .engineVersion = 0,
            .apiVersion = driver_mod.VK_API_VERSION_1_3,
        };
        const instance_ext_names = [_][*:0]const u8{
            driver_mod.VK_KHR_SURFACE_EXTENSION_NAME,
            driver_mod.VK_KHR_XLIB_SURFACE_EXTENSION_NAME,
        };
        const instance_ext_count: u32 = @intCast(instance_ext_names.len);
        const instance_ci = driver_mod.VkInstanceCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = instance_ext_count,
            .ppEnabledExtensionNames = @ptrCast(&instance_ext_names),
        };
        var instance: VkInstance = null;
        try observation.result(observer, .instance, 0, drv.fromResult(drv.vkCreateInstance(&instance_ci, null, &instance)));
        errdefer if (destroyInstanceSafe(&drv, instance)) observation.release(observer, .instance, 0, true);

        try drv.loadInstanceFunctions(instance);

        var phys_count: u32 = 0;
        try drv.fromResult(drv.vkEnumeratePhysicalDevices(instance, &phys_count, null));
        if (phys_count == 0) return Error.NoDevice;
        if (device_ordinal < 0 or @as(u32, @intCast(device_ordinal)) >= phys_count) {
            return Error.InvalidDevice;
        }

        const phys_devs = allocator.alloc(VkPhysicalDevice, phys_count) catch return Error.OutOfHostMemory;
        defer allocator.free(phys_devs);
        try drv.fromResult(drv.vkEnumeratePhysicalDevices(instance, &phys_count, phys_devs.ptr));

        const selected_phys = phys_devs[@as(usize, @intCast(device_ordinal))];

        var props: driver_mod.VkPhysicalDeviceProperties = undefined;
        drv.vkGetPhysicalDeviceProperties(selected_phys, &props);
        if (props.apiVersion < driver_mod.VK_API_VERSION_1_3) return Error.IncompatibleDriver;

        const has_timeline_ext = try deviceHasExtension(
            &drv,
            allocator,
            selected_phys,
            driver_mod.VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME,
        );
        const has_swapchain_ext = try deviceHasExtension(
            &drv,
            allocator,
            selected_phys,
            driver_mod.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
        );
        if (!has_swapchain_ext) return Error.ExtensionNotPresent;
        const has_core_11 = props.apiVersion >= driver_mod.VK_API_VERSION_1_1;
        const has_core_12 = props.apiVersion >= driver_mod.VK_API_VERSION_1_2;
        if (!has_timeline_ext and !has_core_12) {
            log.warn(
                "physical device apiVersion {d} lacks VK_KHR_timeline_semaphore and < 1.2 core",
                .{props.apiVersion},
            );
            return Error.TimelineSemaphoreUnavailable;
        }

        const narrow_support = try queryNarrowFeatureStructSupport(
            &drv,
            allocator,
            selected_phys,
            props.apiVersion,
        );
        var available_narrow = NarrowFeatureStructs.init();
        const query_narrow_chain = available_narrow.chain(narrow_support);
        var timeline_features = driver_mod.VkPhysicalDeviceTimelineSemaphoreFeatures{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES,
            .pNext = query_narrow_chain,
            .timelineSemaphore = driver_mod.VK_FALSE,
        };
        var core13_features = driver_mod.VkPhysicalDeviceVulkan13Features{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .pNext = @ptrCast(&timeline_features),
        };
        var features2 = driver_mod.VkPhysicalDeviceFeatures2{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = @ptrCast(&core13_features),
            .features = std.mem.zeroes(driver_mod.VkPhysicalDeviceFeatures),
        };
        drv.vkGetPhysicalDeviceFeatures2(selected_phys, &features2);
        if (timeline_features.timelineSemaphore != driver_mod.VK_TRUE) {
            log.warn("physical device advertises timeline extension/core but feature is VK_FALSE", .{});
            return Error.TimelineSemaphoreUnavailable;
        }
        if (core13_features.synchronization2 != driver_mod.VK_TRUE or
            core13_features.dynamicRendering != driver_mod.VK_TRUE)
        {
            log.warn("physical device reports Vulkan 1.3 without synchronization2 or dynamicRendering", .{});
            return Error.FeatureNotPresent;
        }

        const queue_selection = try selectQueueFamily(&drv, allocator, selected_phys);

        const queue_priority: f32 = 1.0;
        const queue_ci = driver_mod.VkDeviceQueueCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = queue_selection.index,
            .queueCount = 1,
            .pQueuePriorities = @ptrCast(&queue_priority),
        };

        var enable_timeline = driver_mod.VkPhysicalDeviceTimelineSemaphoreFeatures{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES,
            .pNext = null,
            .timelineSemaphore = driver_mod.VK_TRUE,
        };
        var enable_features = std.mem.zeroes(driver_mod.VkPhysicalDeviceFeatures);
        enable_features.shaderInt16 = features2.features.shaderInt16;
        enable_features.shaderFloat64 = features2.features.shaderFloat64;
        enable_features.shaderInt64 = features2.features.shaderInt64;
        enable_features.depthBiasClamp = features2.features.depthBiasClamp;
        enable_features.samplerAnisotropy = features2.features.samplerAnisotropy;
        var enable_narrow = NarrowFeatureStructs.init();
        enable_narrow.shader_f16_i8.shaderFloat16 = available_narrow.shader_f16_i8.shaderFloat16;
        enable_narrow.shader_f16_i8.shaderInt8 = available_narrow.shader_f16_i8.shaderInt8;
        enable_narrow.storage16.storageBuffer16BitAccess = available_narrow.storage16.storageBuffer16BitAccess;
        enable_narrow.storage8.storageBuffer8BitAccess = available_narrow.storage8.storageBuffer8BitAccess;
        const enable_narrow_support = NarrowFeatureStructSupport{
            .shader_f16_i8 = has_core_12 or (narrow_support.shader_f16_i8 and (enable_narrow.shader_f16_i8.shaderFloat16 == driver_mod.VK_TRUE or enable_narrow.shader_f16_i8.shaderInt8 == driver_mod.VK_TRUE)),
            .storage8 = has_core_12 or (narrow_support.storage8 and enable_narrow.storage8.storageBuffer8BitAccess == driver_mod.VK_TRUE),
            .storage16 = has_core_11 or (narrow_support.storage16 and enable_narrow.storage16.storageBuffer16BitAccess == driver_mod.VK_TRUE),
        };
        var enable_core13 = driver_mod.VkPhysicalDeviceVulkan13Features{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .pNext = enable_narrow.chain(enable_narrow_support),
            .synchronization2 = driver_mod.VK_TRUE,
            .dynamicRendering = driver_mod.VK_TRUE,
        };
        enable_timeline.pNext = @ptrCast(&enable_core13);
        const wants_ext = !has_core_12 and has_timeline_ext;
        const render_node = try renderNode(&drv, allocator, selected_phys);
        var ext_names: [5 + dmabuf_extensions.len][*:0]const u8 = undefined;
        var ext_count: usize = 0;
        if (wants_ext) {
            ext_names[ext_count] = driver_mod.VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME;
            ext_count += 1;
        }
        if (!has_core_12 and enable_narrow_support.shader_f16_i8) {
            ext_names[ext_count] = driver_mod.VK_KHR_SHADER_FLOAT16_INT8_EXTENSION_NAME;
            ext_count += 1;
        }
        if (!has_core_12 and enable_narrow_support.storage8) {
            ext_names[ext_count] = driver_mod.VK_KHR_8BIT_STORAGE_EXTENSION_NAME;
            ext_count += 1;
        }
        if (!has_core_11 and enable_narrow_support.storage16) {
            ext_names[ext_count] = driver_mod.VK_KHR_16BIT_STORAGE_EXTENSION_NAME;
            ext_count += 1;
        }
        ext_names[ext_count] = driver_mod.VK_KHR_SWAPCHAIN_EXTENSION_NAME;
        ext_count += 1;
        if (render_node != null) {
            @memcpy(ext_names[ext_count..][0..dmabuf_extensions.len], &dmabuf_extensions);
            ext_count += dmabuf_extensions.len;
        }

        const device_ci = driver_mod.VkDeviceCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = @ptrCast(&enable_timeline),
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = @ptrCast(&queue_ci),
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = @intCast(ext_count),
            .ppEnabledExtensionNames = @ptrCast(&ext_names),
            .pEnabledFeatures = @ptrCast(&enable_features),
        };
        var logical: VkDevice = null;
        try observation.result(observer, .device, 0, drv.fromResult(drv.vkCreateDevice(selected_phys, &device_ci, null, &logical)));
        errdefer if (destroyDeviceSafe(&drv, logical)) observation.release(observer, .device, 0, true);

        try drv.loadDeviceFunctions(logical);
        if (render_node != null) try drv.loadDmabufFunctions(logical);

        var queue: VkQueue = null;
        drv.vkGetDeviceQueue(logical, queue_selection.index, 0, &queue);

        var memory_properties: VkPhysicalDeviceMemoryProperties = undefined;
        drv.vkGetPhysicalDeviceMemoryProperties(selected_phys, &memory_properties);
        if (!memory_mod.hostVisibleMemoryAvailable(memory_properties)) {
            log.warn("physical device exposes no HOST_VISIBLE memory type", .{});
            return Error.InitializationFailed;
        }

        var dev = Device{
            ._physical = selected_phys,
            ._api_version = props.apiVersion,
            ._queue_family_index = queue_selection.index,
            ._graphics = queue_selection.graphics,
            ._render_node = render_node,
        };
        const name_raw = std.mem.sliceTo(props.deviceName[0..], 0);
        const name_copy_len = @min(name_raw.len, dev._name_buf.len);
        @memcpy(dev._name_buf[0..name_copy_len], name_raw[0..name_copy_len]);
        dev._name_len = name_copy_len;

        return .{
            .allocator = allocator,
            .device = dev,
            ._driver = drv,
            ._instance = instance,
            ._physical_device = selected_phys,
            ._logical_device = logical,
            ._queue = queue,
            ._memory = blk: {
                var pool = memory_mod.Pool.init(allocator, memory_properties, props.limits.nonCoherentAtomSize);
                pool.observer = observer;
                break :blk pool;
            },
            .observer = observer,
            ._timestamp_period_ns = props.limits.timestampPeriod,
            ._depth_bias_clamp = enable_features.depthBiasClamp == driver_mod.VK_TRUE,
            ._sampler_anisotropy = enable_features.samplerAnisotropy == driver_mod.VK_TRUE,
            ._queue_timestamp_valid_bits = queue_selection.timestamp_valid_bits,
            ._default_stream_cached = null,
            ._live_streams = .{},
            ._shader_cache = .{},
            ._pipeline_layout_cache = .{},
        };
    }

    pub fn deinit(self: *Runtime) void {
        if (self._live_streams.count() != 0) {
            std.debug.panic(
                "vulkan.Runtime.deinit: {d} caller-created stream(s) still live",
                .{self._live_streams.count()},
            );
        }
        self._live_streams.deinit(self.allocator);
        if (self._default_stream_cached) |s| {
            releaseStreamResources(self, s);
            self.allocator.destroy(s);
        }
        self._shader_cache.deinit(self);
        self._pipeline_layout_cache.deinit(self);
        self._memory.deinit(&self._driver, self._logical_device);
        if (destroyDeviceSafe(&self._driver, self._logical_device)) observation.release(self.observer, .device, 0, false);
        if (destroyInstanceSafe(&self._driver, self._instance)) observation.release(self.observer, .instance, 0, false);
        self._driver.close();
        self.* = undefined;
    }

    pub fn synchronize(self: *Runtime) Error!void {
        try self._driver.fromResult(self._driver.vkDeviceWaitIdle(self._logical_device));
    }

    pub fn defaultStream(self: *Runtime) Error!*Stream {
        if (self._default_stream_cached) |s| return s;
        const s = self.allocator.create(Stream) catch return Error.OutOfHostMemory;
        errdefer self.allocator.destroy(s);
        s.* = .{
            ._runtime = self,
            ._command_pool = null,
            ._semaphore = null,
            .counter = 0,
            .is_default = true,
            .poisoned = false,
            ._descriptor_pool = null,
        };
        try createStreamResources(self, s);
        self._default_stream_cached = s;
        return s;
    }

    pub fn createStream(self: *Runtime) Error!*Stream {
        const stream = self.allocator.create(Stream) catch return Error.OutOfHostMemory;
        errdefer self.allocator.destroy(stream);

        stream.* = .{
            ._runtime = self,
            ._command_pool = null,
            ._semaphore = null,
            .counter = 0,
            .is_default = false,
            .poisoned = false,
            ._descriptor_pool = null,
        };
        try createStreamResources(self, stream);
        errdefer releaseStreamResources(self, stream);

        self._live_streams.put(self.allocator, stream, {}) catch return Error.OutOfHostMemory;
        return stream;
    }

    pub fn destroyStream(self: *Runtime, stream: *Stream) void {
        std.debug.assert(!stream.is_default);
        if (self._live_streams.remove(stream)) {
            releaseStreamResources(self, stream);
            self.allocator.destroy(stream);
        } else {
            std.debug.panic("vulkan.Runtime.destroyStream: unknown stream {*}", .{stream});
        }
    }

    pub fn createEvent(self: *Runtime) Error!*Event {
        const event = self.allocator.create(Event) catch return Error.OutOfHostMemory;
        errdefer self.allocator.destroy(event);
        var query_pool: VkQueryPool = 0;
        if (self._queue_timestamp_valid_bits != 0 and self._timestamp_period_ns > 0) {
            const query_ci = driver_mod.VkQueryPoolCreateInfo{
                .sType = driver_mod.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queryType = driver_mod.VK_QUERY_TYPE_TIMESTAMP,
                .queryCount = 1,
                .pipelineStatistics = 0,
            };
            try observation.result(self.observer, .query_pool, 0, self._driver.fromResult(self._driver.vkCreateQueryPool(
                self._logical_device,
                &query_ci,
                null,
                &query_pool,
            )));
        }
        event.* = .{
            ._runtime = self,
            ._semaphore = null,
            ._query_pool = query_pool,
            .value = 0,
            .recorded = false,
            .timestamp_recorded = false,
        };
        return event;
    }

    pub fn destroyEvent(self: *Runtime, event: *Event) void {
        if (event._query_pool != 0) {
            self._driver.vkDestroyQueryPool(self._logical_device, event._query_pool, null);
            observation.release(self.observer, .query_pool, 0, false);
        }
        self.allocator.destroy(event);
    }

    pub fn createXlibSurface(self: *Runtime, desc: SurfaceDesc) Error!Surface {
        return Surface.create(self, desc);
    }

    pub fn queryCapabilities(self: *Runtime) Error!Caps {
        const drv = &self._driver;

        var shader_f16_i8 = VkPhysicalDeviceShaderFloat16Int8Features{
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_FLOAT16_INT8_FEATURES,
            .pNext = null,
            .shaderFloat16 = driver_mod.VK_FALSE,
            .shaderInt8 = driver_mod.VK_FALSE,
        };
        const feature_support = try queryNarrowFeatureStructSupport(
            drv,
            self.allocator,
            self._physical_device,
            self.device.apiVersion(),
        );
        var narrow_features = NarrowFeatureStructs.init();
        shader_f16_i8.pNext = narrow_features.chain(.{
            .shader_f16_i8 = false,
            .storage8 = feature_support.storage8,
            .storage16 = feature_support.storage16,
        });
        var features2 = driver_mod.VkPhysicalDeviceFeatures2{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = if (feature_support.shader_f16_i8) @ptrCast(&shader_f16_i8) else shader_f16_i8.pNext,
            .features = std.mem.zeroes(driver_mod.VkPhysicalDeviceFeatures),
        };
        drv.vkGetPhysicalDeviceFeatures2(self._physical_device, &features2);

        var subgroup_props = driver_mod.VkPhysicalDeviceSubgroupProperties{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES,
            .pNext = null,
            .subgroupSize = 0,
            .supportedStages = 0,
            .supportedOperations = 0,
            .quadOperationsInAllStages = driver_mod.VK_FALSE,
        };
        var props = driver_mod.VkPhysicalDeviceProperties2{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
            .pNext = @ptrCast(&subgroup_props),
            .properties = undefined,
        };
        drv.vkGetPhysicalDeviceProperties2(self._physical_device, &props);

        return .{
            .shader_float16 = shader_f16_i8.shaderFloat16 == driver_mod.VK_TRUE,
            .shader_float64 = features2.features.shaderFloat64 == driver_mod.VK_TRUE,
            .shader_int8 = shader_f16_i8.shaderInt8 == driver_mod.VK_TRUE,
            .shader_int16 = features2.features.shaderInt16 == driver_mod.VK_TRUE,
            .shader_int64 = features2.features.shaderInt64 == driver_mod.VK_TRUE,
            .storage_buffer8 = narrow_features.storage8.storageBuffer8BitAccess == driver_mod.VK_TRUE,
            .storage_buffer16 = narrow_features.storage16.storageBuffer16BitAccess == driver_mod.VK_TRUE,
            .subgroup_size = subgroup_props.subgroupSize,
            .subgroup_supported_stages = subgroup_props.supportedStages,
            .subgroup_supported_operations = subgroup_props.supportedOperations,
            .vendor_id = props.properties.vendorID,
            .vendor_name = self.device.name(),
        };
    }

    pub fn hostSignalStream(self: *Runtime, stream: *Stream, value: u64) Error!void {
        const signal_info = driver_mod.VkSemaphoreSignalInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO,
            .pNext = null,
            .semaphore = stream._semaphore,
            .value = value,
        };
        try self._driver.fromResult(self._driver.vkSignalSemaphore(self._logical_device, &signal_info));
    }
};

pub const SurfaceDesc = struct {
    display: usize,
    window: u64,
    extent: VkExtent2D,
    format: VkFormat,
    color_space: VkColorSpaceKHR,
    present_mode: VkPresentModeKHR,
    usage: VkImageUsageFlags,
    min_image_count: u32,
    composite_alpha: driver_mod.VkCompositeAlphaFlagBitsKHR = driver_mod.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
};

/// The image a surface hands over for one frame. `view` is null unless passes may draw into it.
pub const SurfaceImage = struct {
    image: VkImage,
    view: VkImageView,
    image_index: u32,
    generation: u64,
    extent: VkExtent2D,
    format: VkFormat,
    color_space: VkColorSpaceKHR,
    usage: VkImageUsageFlags,
};

pub const ClearColor = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const SurfaceWriteOp = union(enum) {
    clear: ClearColor,
    copy_buffer: *DeviceBuffer,
};

pub const max_surface_wait_events: usize = 32;

/// The most images a swapchain may hold. Drivers give two to four for the frame counts the
/// contract allows.
pub const max_swapchain_images: usize = 16;

fn appendSubmitWait(
    waits: []driver_mod.VkSemaphoreSubmitInfo,
    wait_count: *usize,
    semaphore: VkSemaphore,
    value: u64,
) void {
    for (waits[0..wait_count.*]) |*wait| {
        if (wait.semaphore == semaphore) {
            wait.value = @max(wait.value, value);
            return;
        }
    }
    waits[wait_count.*] = .{
        .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = semaphore,
        .value = value,
        .stageMask = pipeline_stage_2_all_commands,
        .deviceIndex = 0,
    };
    wait_count.* += 1;
}

/// A point on a timeline semaphore. The submission it names has completed once `semaphore`
/// reaches `value`.
pub const Mark = struct {
    semaphore: VkSemaphore,
    value: u64,
};

/// One image of a swapchain: the image, its view when passes may draw into it, the layout its last
/// use left it in, and the binary semaphore its presentation waits on. The image comes back from
/// the swapchain only after its previous presentation has read it, so a presentation signals the
/// image's semaphore again only after the previous wait on it is done.
const SwapchainImage = struct {
    image: VkImage,
    view: VkImageView,
    layout: VkImageLayout,
    present_semaphore: VkSemaphore,
};

/// A semaphore that acquisitions signal in turn, and the submission that last waited on it. A
/// binary semaphore takes a new signal only once its last wait has completed, so the surface waits
/// for that submission before it hands the semaphore to another acquisition.
const AcquireSlot = struct {
    semaphore: VkSemaphore,
    consumer: ?Mark = null,
};

/// The image a caller holds between `acquire` and `present`, the acquisition slot that signalled
/// it, whether a submission has waited on that slot's semaphore yet, and the last submission that
/// drew into or wrote the image.
const Held = struct {
    index: u32,
    slot: u32,
    waited: bool = false,
    last: ?Mark = null,
};

/// An X11 window's swapchain. A caller acquires one image, draws into it or writes it with any
/// number of submissions, and presents it. The first submission that touches the image waits for
/// the swapchain to hand it over, and every submission leaves it ready to present. Presenting
/// submits one more batch, after the image's last submission, that signals the image's present
/// semaphore, and the swapchain waits on that semaphore. A swapchain that stops matching its
/// window marks the surface stale, and every later acquisition fails until the caller makes a new
/// surface.
pub const Surface = struct {
    _runtime: *Runtime,
    _surface: VkSurfaceKHR,
    _swapchain: VkSwapchainKHR,
    _images: []SwapchainImage,
    _acquire: []AcquireSlot,
    _next_slot: u32,
    extent: VkExtent2D,
    format: VkFormat,
    color_space: VkColorSpaceKHR,
    present_mode: VkPresentModeKHR,
    usage: VkImageUsageFlags,
    generation: u64,
    held: ?Held,
    stale: bool,

    fn create(rt: *Runtime, desc: SurfaceDesc) Error!Surface {
        if (desc.display == 0 or desc.window == 0) return Error.InitializationFailed;
        if (desc.extent.width == 0 or desc.extent.height == 0) return Error.InitializationFailed;
        if (desc.min_image_count == 0) return Error.InitializationFailed;

        const ci = VkXlibSurfaceCreateInfoKHR{
            .sType = driver_mod.VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .dpy = @ptrFromInt(desc.display),
            .window = desc.window,
        };
        var surface: VkSurfaceKHR = 0;
        try rt._driver.fromResult(rt._driver.vkCreateXlibSurfaceKHR(rt._instance, &ci, null, &surface));
        errdefer if (surface != 0) rt._driver.vkDestroySurfaceKHR(rt._instance, surface, null);

        var supported = driver_mod.VK_FALSE;
        try rt._driver.fromResult(rt._driver.vkGetPhysicalDeviceSurfaceSupportKHR(
            rt._physical_device,
            rt.device.queueFamilyIndex(),
            surface,
            &supported,
        ));
        if (supported != driver_mod.VK_TRUE) return Error.FeatureNotPresent;

        var self = Surface{
            ._runtime = rt,
            ._surface = surface,
            ._swapchain = 0,
            ._images = &.{},
            ._acquire = &.{},
            ._next_slot = 0,
            .extent = desc.extent,
            .format = desc.format,
            .color_space = desc.color_space,
            .present_mode = desc.present_mode,
            .usage = desc.usage,
            .generation = 0,
            .held = null,
            .stale = false,
        };
        surface = 0;
        errdefer self.deinit();
        try self.configureSwapchain(desc);
        return self;
    }

    /// Waits for the device to finish every submission, then destroys the swapchain, its views and
    /// semaphores, and the surface.
    pub fn deinit(self: *Surface) void {
        const rt = self._runtime;
        const drv = &rt._driver;
        _ = drv.vkDeviceWaitIdle(rt._logical_device);
        for (self._images) |entry| {
            if (entry.view != 0) drv.vkDestroyImageView(rt._logical_device, entry.view, null);
            if (entry.present_semaphore != null) drv.vkDestroySemaphore(rt._logical_device, entry.present_semaphore, null);
        }
        if (self._images.len != 0) rt.allocator.free(self._images);
        for (self._acquire) |slot| {
            if (slot.semaphore != null) drv.vkDestroySemaphore(rt._logical_device, slot.semaphore, null);
        }
        if (self._acquire.len != 0) rt.allocator.free(self._acquire);
        if (self._swapchain != 0) drv.vkDestroySwapchainKHR(rt._logical_device, self._swapchain, null);
        if (self._surface != 0) drv.vkDestroySurfaceKHR(rt._instance, self._surface, null);
        self.* = undefined;
    }

    /// Takes the next image from the swapchain. The acquisition slot it uses waits first for the
    /// submission that last waited on its semaphore. A swapchain that only suboptimally matches its
    /// window still hands over the image and marks the surface stale. One that no longer matches
    /// returns `SurfaceOutOfDate` and marks it stale.
    pub fn acquire(self: *Surface) Error!SurfaceImage {
        if (self.held != null) return Error.InitializationFailed;
        if (self.stale) return Error.SurfaceOutOfDate;
        const rt = self._runtime;
        const drv = &rt._driver;
        const slot_index = self._next_slot;
        const slot = &self._acquire[slot_index];
        if (slot.consumer) |mark| {
            try waitMark(rt, mark);
            slot.consumer = null;
        }

        var image_index: u32 = 0;
        const result = drv.vkAcquireNextImageKHR(
            rt._logical_device,
            self._swapchain,
            driver_mod.VK_WHOLE_TIMEOUT,
            slot.semaphore,
            null,
            &image_index,
        );
        if (result == .suboptimal_khr) {
            self.stale = true;
        } else drv.fromResult(result) catch |err| {
            if (err == Error.SurfaceOutOfDate) self.stale = true;
            return err;
        };
        if (image_index >= self._images.len) {
            self.stale = true;
            return Error.InitializationFailed;
        }
        self._next_slot = @intCast((slot_index + 1) % self._acquire.len);
        self.held = .{ .index = image_index, .slot = slot_index };
        const entry = self._images[image_index];
        return .{
            .image = entry.image,
            .view = entry.view,
            .image_index = image_index,
            .generation = self.generation,
            .extent = self.extent,
            .format = self.format,
            .color_space = self.color_space,
            .usage = self.usage,
        };
    }

    /// Checks that `image` is the held image of this swapchain.
    pub fn expectHeld(self: *const Surface, image: SurfaceImage) Error!void {
        if (self.generation != image.generation) return Error.InitializationFailed;
        const held = self.held orelse return Error.InitializationFailed;
        if (held.index != image.image_index) return Error.InitializationFailed;
        if (self._images[held.index].image != image.image) return Error.InitializationFailed;
    }

    /// The layout the held image is in, where the next submission that touches it starts.
    pub fn heldLayout(self: *const Surface) VkImageLayout {
        const held = self.held.?;
        return self._images[held.index].layout;
    }

    /// The semaphore a submission that touches the held image waits on: the acquisition's, until
    /// a submission has waited on it.
    pub fn acquireWait(self: *const Surface) ?VkSemaphore {
        const held = self.held.?;
        if (held.waited) return null;
        return self._acquire[held.slot].semaphore;
    }

    /// Records a submission that touched the held image, waited as `acquireWait` asked, left the
    /// image ready to present, and completes at `mark`.
    pub fn touched(self: *Surface, mark: Mark) void {
        const held = &self.held.?;
        if (!held.waited) {
            self._acquire[held.slot].consumer = mark;
            held.waited = true;
        }
        held.last = mark;
        self._images[held.index].layout = driver_mod.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    }

    /// Hands the held image back to the swapchain to show. A batch on the default stream waits for
    /// the image's last submission and the acquisition, moves an image nothing touched into the
    /// present layout, and signals the image's present semaphore, which the presentation waits on.
    /// The image goes back whether or not the presentation succeeds. A swapchain that only
    /// suboptimally matches its window presents and marks the surface stale.
    pub fn present(self: *Surface, image_index: u32, generation: u64) Error!void {
        if (self.generation != generation) return Error.InitializationFailed;
        const held = self.held orelse return Error.InitializationFailed;
        if (held.index != image_index) return Error.InitializationFailed;
        self.held = null;
        errdefer self.stale = true;

        const rt = self._runtime;
        const drv = &rt._driver;
        const stream = try rt.defaultStream();
        if (stream.poisoned) return Error.StreamPoisoned;
        const entry = &self._images[image_index];
        const present_layout = driver_mod.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        var cb: VkCommandBuffer = null;
        if (entry.layout != present_layout) {
            cb = try acquireStreamCommandBuffer(stream);
            const begin_info = driver_mod.VkCommandBufferBeginInfo{
                .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                .pNext = null,
                .flags = driver_mod.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
                .pInheritanceInfo = null,
            };
            try drv.fromResult(drv.vkBeginCommandBuffer(cb, &begin_info));
            transitionImage(
                drv,
                cb,
                entry.image,
                entry.layout,
                present_layout,
                0,
                0,
                driver_mod.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                driver_mod.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            );
            try drv.fromResult(drv.vkEndCommandBuffer(cb));
        }

        var waits: [3]driver_mod.VkSemaphoreSubmitInfo = undefined;
        var wait_count: usize = 0;
        appendSubmitWait(&waits, &wait_count, stream._semaphore, stream.counter);
        if (held.last) |last| appendSubmitWait(&waits, &wait_count, last.semaphore, last.value);
        if (!held.waited) appendSubmitWait(&waits, &wait_count, self._acquire[held.slot].semaphore, 0);
        const signal_value = stream.counter + 1;
        const signals = [_]driver_mod.VkSemaphoreSubmitInfo{
            semaphoreSignal(stream._semaphore, signal_value),
            semaphoreSignal(entry.present_semaphore, 0),
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
            .waitSemaphoreInfoCount = @intCast(wait_count),
            .pWaitSemaphoreInfos = @ptrCast(&waits),
            .commandBufferInfoCount = if (cb != null) 1 else 0,
            .pCommandBufferInfos = if (cb != null) @ptrCast(&cb_info) else null,
            .signalSemaphoreInfoCount = signals.len,
            .pSignalSemaphoreInfos = @ptrCast(&signals),
        }};
        drv.fromResult(drv.vkQueueSubmit2(rt._queue, 1, @ptrCast(&submits), null)) catch |err| {
            stream.poisoned = true;
            return err;
        };
        if (cb != null) retireStreamCommandBuffer(stream, cb, signal_value);
        stream.counter = signal_value;
        if (!held.waited) self._acquire[held.slot].consumer = .{ .semaphore = stream._semaphore, .value = signal_value };
        entry.layout = present_layout;

        var present_semaphore = entry.present_semaphore;
        var swapchain = self._swapchain;
        var index = image_index;
        var result: VkResult = .success;
        const present_info = VkPresentInfoKHR{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = @ptrCast(&present_semaphore),
            .swapchainCount = 1,
            .pSwapchains = @ptrCast(&swapchain),
            .pImageIndices = @ptrCast(&index),
            .pResults = @ptrCast(&result),
        };
        const queued = drv.vkQueuePresentKHR(rt._queue, &present_info);
        if (queued == .suboptimal_khr or result == .suboptimal_khr) {
            self.stale = true;
            return;
        }
        try drv.fromResult(queued);
        try drv.fromResult(result);
    }

    /// Clears the held image or copies a buffer into it, in one submission on the default stream
    /// that leaves the image ready to present.
    pub fn write(
        self: *Surface,
        image: SurfaceImage,
        ops: []const SurfaceWriteOp,
        wait_events: []const *Event,
        signal_event: ?*Event,
    ) Error!void {
        if (ops.len == 0) return Error.InitializationFailed;
        try self.expectHeld(image);
        if ((self.usage & driver_mod.VK_IMAGE_USAGE_TRANSFER_DST_BIT) == 0) return Error.FeatureNotPresent;
        if (wait_events.len > max_surface_wait_events) return Error.InitializationFailed;

        const pixel_bytes = surfacePixelBytes(image.extent) catch return Error.InitializationFailed;
        for (ops) |op| switch (op) {
            .clear => {},
            .copy_buffer => |buffer| {
                if (buffer._runtime != self._runtime) return Error.InitializationFailed;
                if (buffer.size < pixel_bytes) return Error.InitializationFailed;
            },
        };
        for (wait_events) |event| {
            if (!event.recorded) return Error.InitializationFailed;
        }

        const rt = self._runtime;
        const drv = &rt._driver;
        const stream = try rt.defaultStream();
        if (stream.poisoned) return Error.StreamPoisoned;
        errdefer stream.poisoned = true;

        const cb = try acquireStreamCommandBuffer(stream);

        const begin_info = driver_mod.VkCommandBufferBeginInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = driver_mod.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try drv.fromResult(drv.vkBeginCommandBuffer(cb, &begin_info));

        const layout = self.heldLayout();
        transitionImage(
            drv,
            cb,
            image.image,
            layout,
            driver_mod.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            0,
            driver_mod.VK_ACCESS_TRANSFER_WRITE_BIT,
            if (layout == driver_mod.VK_IMAGE_LAYOUT_UNDEFINED)
                driver_mod.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
            else
                driver_mod.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            driver_mod.VK_PIPELINE_STAGE_TRANSFER_BIT,
        );

        for (ops) |op| switch (op) {
            .clear => |color| {
                var clear = VkClearColorValue{ .float32 = .{ color.r, color.g, color.b, color.a } };
                var range = colorRange();
                drv.vkCmdClearColorImage(
                    cb,
                    image.image,
                    driver_mod.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    &clear,
                    1,
                    @ptrCast(&range),
                );
            },
            .copy_buffer => |buffer| {
                var region = VkBufferImageCopy{
                    .bufferOffset = 0,
                    .bufferRowLength = 0,
                    .bufferImageHeight = 0,
                    .imageSubresource = .{
                        .aspectMask = driver_mod.VK_IMAGE_ASPECT_COLOR_BIT,
                        .mipLevel = 0,
                        .baseArrayLayer = 0,
                        .layerCount = 1,
                    },
                    .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                    .imageExtent = .{ .width = image.extent.width, .height = image.extent.height, .depth = 1 },
                };
                drv.vkCmdCopyBufferToImage(
                    cb,
                    buffer._buffer,
                    image.image,
                    driver_mod.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    1,
                    @ptrCast(&region),
                );
            },
        };

        transitionImage(
            drv,
            cb,
            image.image,
            driver_mod.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            driver_mod.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            driver_mod.VK_ACCESS_TRANSFER_WRITE_BIT,
            0,
            driver_mod.VK_PIPELINE_STAGE_TRANSFER_BIT,
            driver_mod.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        );
        try drv.fromResult(drv.vkEndCommandBuffer(cb));
        try self.submitTouch(stream, cb, wait_events, signal_event);
    }

    /// Copies the held image, as the submissions before the copy leave it, into `buffer`: every
    /// row from the top, tightly packed. The copy is not the frame's write, so a frame takes any
    /// number of reads, and it leaves the image ready to present, as a write does.
    pub fn read(self: *Surface, image: SurfaceImage, buffer: *const DeviceBuffer) Error!void {
        try self.expectHeld(image);
        if ((self.usage & driver_mod.VK_IMAGE_USAGE_TRANSFER_SRC_BIT) == 0) return Error.FeatureNotPresent;
        if (buffer._runtime != self._runtime) return Error.InitializationFailed;
        const pixel_bytes = surfacePixelBytes(image.extent) catch return Error.InitializationFailed;
        if (buffer.size < pixel_bytes) return Error.InitializationFailed;

        const rt = self._runtime;
        const drv = &rt._driver;
        const stream = try rt.defaultStream();
        if (stream.poisoned) return Error.StreamPoisoned;
        errdefer stream.poisoned = true;

        const cb = try acquireStreamCommandBuffer(stream);
        const begin_info = driver_mod.VkCommandBufferBeginInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = driver_mod.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try drv.fromResult(drv.vkBeginCommandBuffer(cb, &begin_info));

        const layout = self.heldLayout();
        transitionImage(
            drv,
            cb,
            image.image,
            layout,
            driver_mod.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            0,
            driver_mod.VK_ACCESS_TRANSFER_READ_BIT,
            if (layout == driver_mod.VK_IMAGE_LAYOUT_UNDEFINED)
                driver_mod.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
            else
                driver_mod.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            driver_mod.VK_PIPELINE_STAGE_TRANSFER_BIT,
        );
        var region = VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = driver_mod.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = image.extent.width, .height = image.extent.height, .depth = 1 },
        };
        drv.vkCmdCopyImageToBuffer(
            cb,
            image.image,
            driver_mod.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            buffer._buffer,
            1,
            @ptrCast(&region),
        );
        transitionImage(
            drv,
            cb,
            image.image,
            driver_mod.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            driver_mod.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            0,
            0,
            driver_mod.VK_PIPELINE_STAGE_TRANSFER_BIT,
            driver_mod.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        );
        try drv.fromResult(drv.vkEndCommandBuffer(cb));
        try self.submitTouch(stream, cb, &.{}, null);
    }

    /// Submits `cb`, which touched the held image, on `stream` after the stream's last submission,
    /// `wait_events`, and the acquisition when nothing has waited on it yet, and records the
    /// submission as the image's last.
    fn submitTouch(
        self: *Surface,
        stream: *Stream,
        cb: VkCommandBuffer,
        wait_events: []const *Event,
        signal_event: ?*Event,
    ) Error!void {
        const rt = self._runtime;
        const drv = &rt._driver;
        var waits: [max_surface_wait_events + 2]driver_mod.VkSemaphoreSubmitInfo = undefined;
        var wait_count: usize = 0;
        appendSubmitWait(&waits, &wait_count, stream._semaphore, stream.counter);
        for (wait_events) |event| appendSubmitWait(&waits, &wait_count, event._semaphore, event.value);
        if (self.acquireWait()) |semaphore| appendSubmitWait(&waits, &wait_count, semaphore, 0);
        const signal_value = stream.counter + 1;
        const signals = [_]driver_mod.VkSemaphoreSubmitInfo{semaphoreSignal(stream._semaphore, signal_value)};
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
            .waitSemaphoreInfoCount = @intCast(wait_count),
            .pWaitSemaphoreInfos = @ptrCast(&waits),
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = @ptrCast(&cb_info),
            .signalSemaphoreInfoCount = signals.len,
            .pSignalSemaphoreInfos = @ptrCast(&signals),
        }};
        try drv.fromResult(drv.vkQueueSubmit2(rt._queue, 1, @ptrCast(&submits), null));

        retireStreamCommandBuffer(stream, cb, signal_value);
        stream.counter = signal_value;
        if (signal_event) |event| {
            event._semaphore = stream._semaphore;
            event.value = stream.counter;
            event.recorded = true;
            event.timestamp_recorded = false;
        }
        self.touched(.{ .semaphore = stream._semaphore, .value = signal_value });
    }

    fn configureSwapchain(self: *Surface, desc: SurfaceDesc) Error!void {
        const rt = self._runtime;
        const drv = &rt._driver;
        std.debug.assert(self._swapchain == 0);

        var caps: VkSurfaceCapabilitiesKHR = undefined;
        try drv.fromResult(drv.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
            rt._physical_device,
            self._surface,
            &caps,
        ));
        if ((caps.supportedUsageFlags & desc.usage) != desc.usage) return Error.FeatureNotPresent;
        if ((caps.supportedCompositeAlpha & desc.composite_alpha) != desc.composite_alpha) return Error.FeatureNotPresent;

        try self.expectFormatSupported(desc.format, desc.color_space);
        try self.expectPresentModeSupported(desc.present_mode);

        const extent = surfaceExtent(caps, desc.extent);
        if (extent.width == 0 or extent.height == 0) return Error.InitializationFailed;

        var image_count = @max(caps.minImageCount, desc.min_image_count);
        if (caps.maxImageCount != 0) image_count = @min(image_count, caps.maxImageCount);
        if (image_count == 0) return Error.InitializationFailed;

        const ci = VkSwapchainCreateInfoKHR{
            .sType = driver_mod.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self._surface,
            .minImageCount = image_count,
            .imageFormat = desc.format,
            .imageColorSpace = desc.color_space,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = desc.usage,
            .imageSharingMode = driver_mod.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = caps.currentTransform,
            .compositeAlpha = desc.composite_alpha,
            .presentMode = desc.present_mode,
            .clipped = driver_mod.VK_TRUE,
            .oldSwapchain = 0,
        };
        try drv.fromResult(drv.vkCreateSwapchainKHR(rt._logical_device, &ci, null, &self._swapchain));

        var actual_count: u32 = 0;
        try drv.fromResult(drv.vkGetSwapchainImagesKHR(rt._logical_device, self._swapchain, &actual_count, null));
        if (actual_count == 0) return Error.InitializationFailed;
        var handles: [max_swapchain_images]VkImage = undefined;
        if (actual_count > handles.len) return Error.InitializationFailed;
        try drv.fromResult(drv.vkGetSwapchainImagesKHR(rt._logical_device, self._swapchain, &actual_count, &handles));

        // Each piece goes into the surface as soon as it exists, so `deinit` frees whatever a
        // failure leaves.
        self._images = rt.allocator.alloc(SwapchainImage, actual_count) catch return Error.OutOfHostMemory;
        for (self._images, handles[0..actual_count]) |*entry, image| {
            entry.* = .{ .image = image, .view = 0, .layout = driver_mod.VK_IMAGE_LAYOUT_UNDEFINED, .present_semaphore = null };
        }
        for (self._images) |*entry| {
            entry.present_semaphore = try createBinarySemaphore(rt);
            if (desc.usage & driver_mod.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT != 0) {
                entry.view = try createColorView(rt, entry.image, desc.format);
            }
        }
        self._acquire = rt.allocator.alloc(AcquireSlot, actual_count + 1) catch return Error.OutOfHostMemory;
        for (self._acquire) |*slot| slot.* = .{ .semaphore = null };
        for (self._acquire) |*slot| slot.semaphore = try createBinarySemaphore(rt);

        self.extent = extent;
        self.format = desc.format;
        self.color_space = desc.color_space;
        self.present_mode = desc.present_mode;
        self.usage = desc.usage;
        self.generation += 1;
    }

    fn expectFormatSupported(self: *Surface, format: VkFormat, color_space: VkColorSpaceKHR) Error!void {
        const rt = self._runtime;
        var count: u32 = 0;
        try rt._driver.fromResult(rt._driver.vkGetPhysicalDeviceSurfaceFormatsKHR(
            rt._physical_device,
            self._surface,
            &count,
            null,
        ));
        if (count == 0) return Error.FormatNotSupported;
        const formats = rt.allocator.alloc(VkSurfaceFormatKHR, count) catch return Error.OutOfHostMemory;
        defer rt.allocator.free(formats);
        try rt._driver.fromResult(rt._driver.vkGetPhysicalDeviceSurfaceFormatsKHR(
            rt._physical_device,
            self._surface,
            &count,
            formats.ptr,
        ));
        for (formats[0..count]) |candidate| {
            if (candidate.format == format and candidate.colorSpace == color_space) return;
        }
        return Error.FormatNotSupported;
    }

    fn expectPresentModeSupported(self: *Surface, present_mode: VkPresentModeKHR) Error!void {
        const rt = self._runtime;
        var count: u32 = 0;
        try rt._driver.fromResult(rt._driver.vkGetPhysicalDeviceSurfacePresentModesKHR(
            rt._physical_device,
            self._surface,
            &count,
            null,
        ));
        if (count == 0) return Error.FeatureNotPresent;
        const modes = rt.allocator.alloc(VkPresentModeKHR, count) catch return Error.OutOfHostMemory;
        defer rt.allocator.free(modes);
        try rt._driver.fromResult(rt._driver.vkGetPhysicalDeviceSurfacePresentModesKHR(
            rt._physical_device,
            self._surface,
            &count,
            modes.ptr,
        ));
        for (modes[0..count]) |candidate| {
            if (candidate == present_mode) return;
        }
        return Error.FeatureNotPresent;
    }
};

fn transitionImage(
    drv: *const Driver,
    cb: VkCommandBuffer,
    image: VkImage,
    old_layout: VkImageLayout,
    new_layout: VkImageLayout,
    src_access: driver_mod.VkAccessFlags,
    dst_access: driver_mod.VkAccessFlags,
    src_stage: driver_mod.VkPipelineStageFlags,
    dst_stage: driver_mod.VkPipelineStageFlags,
) void {
    var barrier = VkImageMemoryBarrier{
        .sType = driver_mod.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = src_access,
        .dstAccessMask = dst_access,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = driver_mod.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = driver_mod.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = colorRange(),
    };
    drv.vkCmdPipelineBarrier(
        cb,
        src_stage,
        dst_stage,
        0,
        0,
        null,
        0,
        null,
        1,
        @ptrCast(&barrier),
    );
}

fn colorRange() VkImageSubresourceRange {
    return .{
        .aspectMask = driver_mod.VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
}

fn surfacePixelBytes(extent: VkExtent2D) !usize {
    const width: usize = @intCast(extent.width);
    const height: usize = @intCast(extent.height);
    const pixels = try std.math.mul(usize, width, height);
    return std.math.mul(usize, pixels, 4);
}

fn createBinarySemaphore(rt: *Runtime) Error!VkSemaphore {
    const sem_ci = driver_mod.VkSemaphoreCreateInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    };
    var sem: VkSemaphore = null;
    try rt._driver.fromResult(rt._driver.vkCreateSemaphore(
        rt._logical_device,
        &sem_ci,
        null,
        &sem,
    ));
    return sem;
}

fn createColorView(rt: *Runtime, image: VkImage, format: VkFormat) Error!VkImageView {
    const ci = driver_mod.VkImageViewCreateInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = driver_mod.VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .components = .{},
        .subresourceRange = colorRange(),
    };
    var view: VkImageView = 0;
    try rt._driver.fromResult(rt._driver.vkCreateImageView(rt._logical_device, &ci, null, &view));
    return view;
}

fn semaphoreSignal(semaphore: VkSemaphore, value: u64) driver_mod.VkSemaphoreSubmitInfo {
    return .{
        .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = semaphore,
        .value = value,
        .stageMask = pipeline_stage_2_all_commands,
        .deviceIndex = 0,
    };
}

/// Blocks until the submission `mark` names has completed.
fn waitMark(rt: *Runtime, mark: Mark) Error!void {
    var semaphore = mark.semaphore;
    var value = mark.value;
    const wait_info = driver_mod.VkSemaphoreWaitInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
        .pNext = null,
        .flags = 0,
        .semaphoreCount = 1,
        .pSemaphores = @ptrCast(&semaphore),
        .pValues = @ptrCast(&value),
    };
    try rt._driver.fromResult(rt._driver.vkWaitSemaphores(rt._logical_device, &wait_info, driver_mod.VK_WHOLE_TIMEOUT));
}

fn surfaceExtent(caps: VkSurfaceCapabilitiesKHR, requested: VkExtent2D) VkExtent2D {
    const dynamic_extent = std.math.maxInt(u32);
    if (caps.currentExtent.width != dynamic_extent and caps.currentExtent.height != dynamic_extent) {
        return caps.currentExtent;
    }
    return .{
        .width = clampU32(requested.width, caps.minImageExtent.width, caps.maxImageExtent.width),
        .height = clampU32(requested.height, caps.minImageExtent.height, caps.maxImageExtent.height),
    };
}

fn clampU32(value: u32, min: u32, max: u32) u32 {
    if (value < min) return min;
    if (max != 0 and value > max) return max;
    return value;
}

const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_FLOAT16_INT8_FEATURES: driver_mod.VkStructureType = 1000082000;

const VkPhysicalDeviceShaderFloat16Int8Features = extern struct {
    sType: driver_mod.VkStructureType,
    pNext: ?*anyopaque,
    shaderFloat16: driver_mod.VkBool32,
    shaderInt8: driver_mod.VkBool32,
};

const NarrowFeatureStructSupport = struct {
    shader_f16_i8: bool,
    storage8: bool,
    storage16: bool,
};

const NarrowFeatureStructs = struct {
    shader_f16_i8: VkPhysicalDeviceShaderFloat16Int8Features,
    storage16: driver_mod.VkPhysicalDevice16BitStorageFeatures,
    storage8: driver_mod.VkPhysicalDevice8BitStorageFeatures,

    fn init() NarrowFeatureStructs {
        return .{
            .shader_f16_i8 = .{
                .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_FLOAT16_INT8_FEATURES,
                .pNext = null,
                .shaderFloat16 = driver_mod.VK_FALSE,
                .shaderInt8 = driver_mod.VK_FALSE,
            },
            .storage16 = .{
                .sType = driver_mod.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES,
                .pNext = null,
                .storageBuffer16BitAccess = driver_mod.VK_FALSE,
                .uniformAndStorageBuffer16BitAccess = driver_mod.VK_FALSE,
                .storagePushConstant16 = driver_mod.VK_FALSE,
                .storageInputOutput16 = driver_mod.VK_FALSE,
            },
            .storage8 = .{
                .sType = driver_mod.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_8BIT_STORAGE_FEATURES,
                .pNext = null,
                .storageBuffer8BitAccess = driver_mod.VK_FALSE,
                .uniformAndStorageBuffer8BitAccess = driver_mod.VK_FALSE,
                .storagePushConstant8 = driver_mod.VK_FALSE,
            },
        };
    }

    fn chain(self: *NarrowFeatureStructs, support: NarrowFeatureStructSupport) ?*anyopaque {
        var next: ?*anyopaque = null;
        if (support.storage8) {
            self.storage8.pNext = next;
            next = @ptrCast(&self.storage8);
        }
        if (support.storage16) {
            self.storage16.pNext = next;
            next = @ptrCast(&self.storage16);
        }
        if (support.shader_f16_i8) {
            self.shader_f16_i8.pNext = next;
            next = @ptrCast(&self.shader_f16_i8);
        }
        return next;
    }
};

fn queryNarrowFeatureStructSupport(
    drv: *const Driver,
    allocator: std.mem.Allocator,
    phys: VkPhysicalDevice,
    api_version: u32,
) Error!NarrowFeatureStructSupport {
    const has_core_11 = api_version >= driver_mod.VK_API_VERSION_1_1;
    const has_core_12 = api_version >= driver_mod.VK_API_VERSION_1_2;
    return .{
        .shader_f16_i8 = has_core_12 or try deviceHasExtension(
            drv,
            allocator,
            phys,
            driver_mod.VK_KHR_SHADER_FLOAT16_INT8_EXTENSION_NAME,
        ),
        .storage8 = has_core_12 or try deviceHasExtension(
            drv,
            allocator,
            phys,
            driver_mod.VK_KHR_8BIT_STORAGE_EXTENSION_NAME,
        ),
        .storage16 = has_core_11 or try deviceHasExtension(
            drv,
            allocator,
            phys,
            driver_mod.VK_KHR_16BIT_STORAGE_EXTENSION_NAME,
        ),
    };
}

pub fn requireFp16(caps: Runtime.Caps) error{Fp16Unavailable}!void {
    if (!caps.shader_float16) return error.Fp16Unavailable;
}

pub const Stream = struct {
    _runtime: *Runtime,
    _command_pool: VkCommandPool,
    _semaphore: VkSemaphore,
    counter: u64,
    is_default: bool,
    poisoned: bool,
    _descriptor_pool: VkDescriptorPool = null,
    _retired_command_buffers: [max_retired_command_buffers]RetiredCommandBuffer = undefined,
    _observed_command_buffers: u64 = 0,
    _observed_descriptor_sets: u64 = 0,
    _retired_command_buffer_count: usize = 0,
    _retired_descriptor_sets: [max_retired_descriptor_sets]RetiredDescriptorSet = undefined,
    _retired_descriptor_set_count: usize = 0,

    pub fn synchronize(self: *Stream) Error!void {
        if (self.poisoned) return Error.StreamPoisoned;
        var sem_handle = self._semaphore;
        var target = self.counter;
        const wait_info = driver_mod.VkSemaphoreWaitInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
            .pNext = null,
            .flags = 0,
            .semaphoreCount = 1,
            .pSemaphores = @ptrCast(&sem_handle),
            .pValues = @ptrCast(&target),
        };
        self._runtime._driver.fromResult(self._runtime._driver.vkWaitSemaphores(
            self._runtime._logical_device,
            &wait_info,
            driver_mod.VK_WHOLE_TIMEOUT,
        )) catch |err| {
            self.poisoned = true;
            return err;
        };
    }

    pub fn query(self: *Stream) Error!bool {
        if (self.poisoned) return Error.StreamPoisoned;
        var value: u64 = 0;
        self._runtime._driver.fromResult(self._runtime._driver.vkGetSemaphoreCounterValue(
            self._runtime._logical_device,
            self._semaphore,
            &value,
        )) catch |err| {
            self.poisoned = true;
            return err;
        };
        return value >= self.counter;
    }
};

const RetiredCommandBuffer = struct {
    command_buffer: VkCommandBuffer,
    ready_value: u64,
};

const RetiredDescriptorSet = struct {
    descriptor_set: VkDescriptorSet,
    layout: VkDescriptorSetLayout,
    ready_value: u64,
};

fn streamCompletedValue(stream: *Stream) Error!u64 {
    const rt = stream._runtime;
    const drv = &rt._driver;
    var completed: u64 = 0;
    try drv.fromResult(drv.vkGetSemaphoreCounterValue(
        rt._logical_device,
        stream._semaphore,
        &completed,
    ));
    return completed;
}

pub fn acquireStreamCommandBuffer(stream: *Stream) Error!VkCommandBuffer {
    const rt = stream._runtime;
    const drv = &rt._driver;
    if (stream._retired_command_buffer_count != 0) {
        const completed = try streamCompletedValue(stream);
        var i: usize = 0;
        while (i < stream._retired_command_buffer_count) {
            const retired = stream._retired_command_buffers[i];
            if (retired.ready_value <= completed) {
                stream._retired_command_buffer_count -= 1;
                if (i != stream._retired_command_buffer_count) {
                    stream._retired_command_buffers[i] =
                        stream._retired_command_buffers[stream._retired_command_buffer_count];
                }
                try drv.fromResult(drv.vkResetCommandBuffer(retired.command_buffer, 0));
                return retired.command_buffer;
            }
            i += 1;
        }
    }

    if (stream._retired_command_buffer_count == stream._retired_command_buffers.len) {
        try stream.synchronize();
        stream._retired_command_buffer_count -= 1;
        const retired = stream._retired_command_buffers[stream._retired_command_buffer_count];
        try drv.fromResult(drv.vkResetCommandBuffer(retired.command_buffer, 0));
        return retired.command_buffer;
    }

    var cb: VkCommandBuffer = null;
    const cb_alloc_info = driver_mod.VkCommandBufferAllocateInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = stream._command_pool,
        .level = driver_mod.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    try observation.result(rt.observer, .command_buffer, 0, drv.fromResult(drv.vkAllocateCommandBuffers(rt._logical_device, &cb_alloc_info, @ptrCast(&cb))));
    if (rt.observer) |o| o.add(&stream._observed_command_buffers, 1);
    return cb;
}

pub fn retireStreamCommandBuffer(stream: *Stream, command_buffer: VkCommandBuffer, ready_value: u64) void {
    std.debug.assert(stream._retired_command_buffer_count < stream._retired_command_buffers.len);
    stream._retired_command_buffers[stream._retired_command_buffer_count] = .{
        .command_buffer = command_buffer,
        .ready_value = ready_value,
    };
    stream._retired_command_buffer_count += 1;
}

pub fn acquireStreamDescriptorSet(stream: *Stream, layout: VkDescriptorSetLayout) Error!VkDescriptorSet {
    try ensureDescriptorPool(stream);
    const rt = stream._runtime;
    const drv = &rt._driver;

    if (stream._retired_descriptor_set_count != 0) {
        const completed = try streamCompletedValue(stream);
        var i: usize = 0;
        while (i < stream._retired_descriptor_set_count) {
            const retired = stream._retired_descriptor_sets[i];
            if (retired.layout == layout and retired.ready_value <= completed) {
                stream._retired_descriptor_set_count -= 1;
                if (i != stream._retired_descriptor_set_count) {
                    stream._retired_descriptor_sets[i] =
                        stream._retired_descriptor_sets[stream._retired_descriptor_set_count];
                }
                return retired.descriptor_set;
            }
            i += 1;
        }
    }

    if (stream._retired_descriptor_set_count == stream._retired_descriptor_sets.len) {
        try stream.synchronize();
        try drv.fromResult(drv.vkResetDescriptorPool(rt._logical_device, stream._descriptor_pool, 0));
        while (stream._observed_descriptor_sets != 0) : (stream._observed_descriptor_sets -= 1) observation.release(rt.observer, .descriptor_set, 0, false);
        stream._retired_descriptor_set_count = 0;
    }

    var ds: VkDescriptorSet = null;
    var set_layout_local = layout;
    const ds_alloc_info = driver_mod.VkDescriptorSetAllocateInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = stream._descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = @ptrCast(&set_layout_local),
    };
    try observation.result(rt.observer, .descriptor_set, 0, drv.fromResult(drv.vkAllocateDescriptorSets(rt._logical_device, &ds_alloc_info, @ptrCast(&ds))));
    if (rt.observer) |o| o.add(&stream._observed_descriptor_sets, 1);
    return ds;
}

pub fn retireStreamDescriptorSet(
    stream: *Stream,
    descriptor_set: VkDescriptorSet,
    layout: VkDescriptorSetLayout,
    ready_value: u64,
) void {
    std.debug.assert(stream._retired_descriptor_set_count < stream._retired_descriptor_sets.len);
    stream._retired_descriptor_sets[stream._retired_descriptor_set_count] = .{
        .descriptor_set = descriptor_set,
        .layout = layout,
        .ready_value = ready_value,
    };
    stream._retired_descriptor_set_count += 1;
}

pub const Event = struct {
    _runtime: *Runtime,
    _semaphore: VkSemaphore,
    _query_pool: VkQueryPool,
    value: u64,
    recorded: bool,
    timestamp_recorded: bool,

    pub fn record(self: *Event, stream: *Stream) Error!void {
        if (stream.poisoned) return Error.StreamPoisoned;
        if (self._query_pool == 0) {
            self._semaphore = stream._semaphore;
            self.value = stream.counter;
            self.recorded = true;
            self.timestamp_recorded = false;
            return;
        }

        errdefer stream.poisoned = true;
        const rt = self._runtime;
        const drv = &rt._driver;

        const cb = try acquireStreamCommandBuffer(stream);

        const begin_info = driver_mod.VkCommandBufferBeginInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = driver_mod.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try drv.fromResult(drv.vkBeginCommandBuffer(cb, &begin_info));
        drv.vkCmdResetQueryPool(cb, self._query_pool, 0, 1);
        drv.vkCmdWriteTimestamp(cb, driver_mod.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, self._query_pool, 0);
        try drv.fromResult(drv.vkEndCommandBuffer(cb));

        const wait_info = driver_mod.VkSemaphoreSubmitInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .pNext = null,
            .semaphore = stream._semaphore,
            .value = stream.counter,
            .stageMask = pipeline_stage_2_all_commands,
            .deviceIndex = 0,
        };
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
            .waitSemaphoreInfoCount = 1,
            .pWaitSemaphoreInfos = @ptrCast(&wait_info),
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = @ptrCast(&cb_info),
            .signalSemaphoreInfoCount = 1,
            .pSignalSemaphoreInfos = @ptrCast(&signal_info),
        }};
        try drv.fromResult(drv.vkQueueSubmit2(rt._queue, 1, @ptrCast(&submits), null));
        retireStreamCommandBuffer(stream, cb, signal_value);
        stream.counter = signal_value;
        self._semaphore = stream._semaphore;
        self.value = stream.counter;
        self.recorded = true;
        self.timestamp_recorded = true;
    }

    pub fn synchronize(self: *Event) Error!void {
        var sem_handle = self._semaphore;
        var target = self.value;
        const wait_info = driver_mod.VkSemaphoreWaitInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
            .pNext = null,
            .flags = 0,
            .semaphoreCount = 1,
            .pSemaphores = @ptrCast(&sem_handle),
            .pValues = @ptrCast(&target),
        };
        try self._runtime._driver.fromResult(self._runtime._driver.vkWaitSemaphores(
            self._runtime._logical_device,
            &wait_info,
            driver_mod.VK_WHOLE_TIMEOUT,
        ));
    }

    pub fn query(self: *Event) Error!bool {
        var value: u64 = 0;
        try self._runtime._driver.fromResult(self._runtime._driver.vkGetSemaphoreCounterValue(
            self._runtime._logical_device,
            self._semaphore,
            &value,
        ));
        return value >= self.value;
    }

    pub fn elapsedNs(self: *Event, start: *Event) Error!u64 {
        if (!self.recorded or !start.recorded) return Error.InitializationFailed;
        if (!self.timestamp_recorded or !start.timestamp_recorded) return Error.FeatureNotPresent;
        const start_ticks = try start.timestampTicks();
        const end_ticks = try self.timestampTicks();
        const valid_bits = self._runtime._queue_timestamp_valid_bits;
        if (valid_bits == 0 or self._runtime._timestamp_period_ns <= 0) return Error.FeatureNotPresent;

        const delta_ticks = if (valid_bits >= 64)
            end_ticks -% start_ticks
        else blk: {
            const mask = (@as(u64, 1) << @intCast(valid_bits)) - 1;
            break :blk (end_ticks -% start_ticks) & mask;
        };
        const elapsed_float = @as(f64, @floatFromInt(delta_ticks)) * @as(f64, self._runtime._timestamp_period_ns);
        if (!std.math.isFinite(elapsed_float) or elapsed_float > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return Error.VulkanUnknown;
        return @intFromFloat(@round(elapsed_float));
    }

    fn timestampTicks(self: *Event) Error!u64 {
        var value: u64 = 0;
        try self._runtime._driver.fromResult(self._runtime._driver.vkGetQueryPoolResults(
            self._runtime._logical_device,
            self._query_pool,
            0,
            1,
            @sizeOf(u64),
            @ptrCast(&value),
            @sizeOf(u64),
            driver_mod.VK_QUERY_RESULT_64_BIT,
        ));
        return value;
    }
};

pub const ShaderModuleCache = struct {
    map: std.AutoHashMapUnmanaged([32]u8, VkShaderModule) = .{},

    pub fn populateCache(
        self: *ShaderModuleCache,
        rt: *Runtime,
        spirv_words: []const u32,
    ) Error!VkShaderModule {
        const bytes = std.mem.sliceAsBytes(spirv_words);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (self.map.get(digest)) |existing| return existing;

        const ci = driver_mod.VkShaderModuleCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = bytes.len,
            .pCode = spirv_words.ptr,
        };
        var handle: VkShaderModule = null;
        try observation.result(rt.observer, .shader, 0, rt._driver.fromResult(rt._driver.vkCreateShaderModule(
            rt._logical_device,
            &ci,
            null,
            &handle,
        )));
        errdefer {
            rt._driver.vkDestroyShaderModule(rt._logical_device, handle, null);
            observation.release(rt.observer, .shader, 0, true);
        }

        self.map.put(rt.allocator, digest, handle) catch return Error.OutOfHostMemory;
        return handle;
    }

    pub fn deinit(self: *ShaderModuleCache, rt: *Runtime) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            rt._driver.vkDestroyShaderModule(rt._logical_device, entry.value_ptr.*, null);
            observation.release(rt.observer, .shader, 0, false);
        }
        self.map.deinit(rt.allocator);
    }
};

pub const PipelineLayoutCache = struct {
    map: std.AutoHashMapUnmanaged(u64, Entry) = .{},

    pub const Key = struct {
        num_buffers: u32,
        push_constant_size: u32,

        fn packed64(self: Key) u64 {
            return (@as(u64, self.num_buffers) << 32) | @as(u64, self.push_constant_size);
        }
    };

    pub const Entry = struct {
        set_layout: VkDescriptorSetLayout,
        pipeline_layout: VkPipelineLayout,
    };

    pub fn getOrCreate(
        self: *PipelineLayoutCache,
        rt: *Runtime,
        key: Key,
    ) Error!Entry {
        if (key.num_buffers > max_buffers_per_set) return Error.InitializationFailed;
        const packed_key = key.packed64();
        if (self.map.get(packed_key)) |existing| return existing;

        var bindings: [max_buffers_per_set]driver_mod.VkDescriptorSetLayoutBinding = undefined;
        var i: u32 = 0;
        while (i < key.num_buffers) : (i += 1) {
            bindings[i] = .{
                .binding = i,
                .descriptorType = driver_mod.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = driver_mod.VK_SHADER_STAGE_COMPUTE_BIT,
                .pImmutableSamplers = null,
            };
        }
        const dsl_ci = driver_mod.VkDescriptorSetLayoutCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = key.num_buffers,
            .pBindings = if (key.num_buffers == 0) null else @ptrCast(&bindings),
        };
        var set_layout: VkDescriptorSetLayout = null;
        try observation.result(rt.observer, .descriptor_layout, 0, rt._driver.fromResult(rt._driver.vkCreateDescriptorSetLayout(
            rt._logical_device,
            &dsl_ci,
            null,
            &set_layout,
        )));
        errdefer {
            rt._driver.vkDestroyDescriptorSetLayout(rt._logical_device, set_layout, null);
            observation.release(rt.observer, .descriptor_layout, 0, true);
        }

        const push_range = driver_mod.VkPushConstantRange{
            .stageFlags = driver_mod.VK_SHADER_STAGE_COMPUTE_BIT,
            .offset = 0,
            .size = key.push_constant_size,
        };
        const pl_ci = driver_mod.VkPipelineLayoutCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = @ptrCast(&set_layout),
            .pushConstantRangeCount = if (key.push_constant_size == 0) 0 else 1,
            .pPushConstantRanges = if (key.push_constant_size == 0) null else @ptrCast(&push_range),
        };
        var pipeline_layout: VkPipelineLayout = null;
        try observation.result(rt.observer, .pipeline_layout, 0, rt._driver.fromResult(rt._driver.vkCreatePipelineLayout(
            rt._logical_device,
            &pl_ci,
            null,
            &pipeline_layout,
        )));
        errdefer {
            rt._driver.vkDestroyPipelineLayout(rt._logical_device, pipeline_layout, null);
            observation.release(rt.observer, .pipeline_layout, 0, true);
        }

        const entry: Entry = .{
            .set_layout = set_layout,
            .pipeline_layout = pipeline_layout,
        };
        self.map.put(rt.allocator, packed_key, entry) catch return Error.OutOfHostMemory;
        return entry;
    }

    pub fn deinit(self: *PipelineLayoutCache, rt: *Runtime) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            rt._driver.vkDestroyPipelineLayout(rt._logical_device, kv.value_ptr.pipeline_layout, null);
            observation.release(rt.observer, .pipeline_layout, 0, false);
            rt._driver.vkDestroyDescriptorSetLayout(rt._logical_device, kv.value_ptr.set_layout, null);
            observation.release(rt.observer, .descriptor_layout, 0, false);
        }
        self.map.deinit(rt.allocator);
    }
};

pub fn ensureDescriptorPool(stream: *Stream) Error!void {
    if (stream._descriptor_pool != null) return;
    const pool_sizes = [_]driver_mod.VkDescriptorPoolSize{.{
        .type = driver_mod.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = max_descriptor_sets_per_stream * max_buffers_per_set,
    }};
    const ci = driver_mod.VkDescriptorPoolCreateInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = max_descriptor_sets_per_stream,
        .poolSizeCount = pool_sizes.len,
        .pPoolSizes = @ptrCast(&pool_sizes),
    };
    var pool: VkDescriptorPool = null;
    try observation.result(stream._runtime.observer, .descriptor_pool, 0, stream._runtime._driver.fromResult(stream._runtime._driver.vkCreateDescriptorPool(
        stream._runtime._logical_device,
        &ci,
        null,
        &pool,
    )));
    stream._descriptor_pool = pool;
}

/// Host-visible staging for one copy between the host and a device resource.
pub const TransferBuffer = struct {
    bytes: usize,
    runtime: *Runtime,
    buffer: VkBuffer,
    allocation: memory_mod.Allocation,

    pub fn init(runtime: *Runtime, bytes: usize) Error!TransferBuffer {
        const buffer_ci = driver_mod.VkBufferCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = bytes,
            .usage = driver_mod.VK_BUFFER_USAGE_TRANSFER_SRC_BIT |
                driver_mod.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = driver_mod.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        var buffer: VkBuffer = null;
        try observation.result(runtime.observer, .transfer_buffer, bytes, runtime._driver.fromResult(runtime._driver.vkCreateBuffer(
            runtime._logical_device,
            &buffer_ci,
            null,
            &buffer,
        )));
        errdefer {
            runtime._driver.vkDestroyBuffer(runtime._logical_device, buffer, null);
            observation.release(runtime.observer, .transfer_buffer, bytes, true);
        }

        var requirements: VkMemoryRequirements = undefined;
        runtime._driver.vkGetBufferMemoryRequirements(runtime._logical_device, buffer, &requirements);
        const allocation = try runtime._memory.allocate(
            &runtime._driver,
            runtime._logical_device,
            requirements,
            .host,
        );
        errdefer runtime._memory.release(allocation);
        try runtime._driver.fromResult(runtime._driver.vkBindBufferMemory(
            runtime._logical_device,
            buffer,
            runtime._memory.deviceMemory(allocation),
            allocation.offset,
        ));
        if (runtime._memory.mapped(allocation) == null) return Error.MemoryMapFailed;
        return .{ .bytes = bytes, .runtime = runtime, .buffer = buffer, .allocation = allocation };
    }

    pub fn deinit(self: *TransferBuffer) void {
        self.runtime._driver.vkDestroyBuffer(self.runtime._logical_device, self.buffer, null);
        observation.release(self.runtime.observer, .transfer_buffer, self.bytes, false);
        self.runtime._memory.release(self.allocation);
        self.* = undefined;
    }
};

const TransferDirection = enum {
    upload,
    download,
};

fn recordBufferBarrier(
    driver: *const Driver,
    command_buffer: VkCommandBuffer,
    buffer: VkBuffer,
    size: u64,
    src_access: driver_mod.VkAccessFlags,
    dst_access: driver_mod.VkAccessFlags,
    src_stage: driver_mod.VkPipelineStageFlags,
    dst_stage: driver_mod.VkPipelineStageFlags,
) void {
    const barrier = VkBufferMemoryBarrier{
        .sType = driver_mod.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = src_access,
        .dstAccessMask = dst_access,
        .srcQueueFamilyIndex = driver_mod.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = driver_mod.VK_QUEUE_FAMILY_IGNORED,
        .buffer = buffer,
        .offset = 0,
        .size = size,
    };
    driver.vkCmdPipelineBarrier(
        command_buffer,
        src_stage,
        dst_stage,
        0,
        0,
        null,
        1,
        @ptrCast(&barrier),
        0,
        null,
    );
}

/// Makes every earlier device write on the queue visible to host reads, once the host has waited
/// for a signal submitted after this barrier. A fence or semaphore wait covers device accesses
/// only, so a host read of mapped memory needs this barrier before the signal it waits for.
pub fn recordHostReadBarrier(driver: *const Driver, command_buffer: VkCommandBuffer) void {
    const memory = driver_mod.VkMemoryBarrier{
        .srcAccessMask = driver_mod.VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask = driver_mod.VK_ACCESS_HOST_READ_BIT,
    };
    driver.vkCmdPipelineBarrier(
        command_buffer,
        driver_mod.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        driver_mod.VK_PIPELINE_STAGE_HOST_BIT,
        0,
        1,
        @ptrCast(&memory),
        0,
        null,
        0,
        null,
    );
}

/// Submits the host-read barrier alone on the default stream and waits for it. Every stream
/// submits to the one queue, so the barrier orders every earlier device write before the host
/// reads mapped memory.
fn awaitHostReads(runtime: *Runtime) Error!void {
    const stream = try runtime.defaultStream();
    if (stream.poisoned) return Error.StreamPoisoned;
    errdefer stream.poisoned = true;
    const command_buffer = try acquireStreamCommandBuffer(stream);
    const begin_info = driver_mod.VkCommandBufferBeginInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = driver_mod.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try runtime._driver.fromResult(runtime._driver.vkBeginCommandBuffer(command_buffer, &begin_info));
    recordHostReadBarrier(&runtime._driver, command_buffer);
    try runtime._driver.fromResult(runtime._driver.vkEndCommandBuffer(command_buffer));
    try submitStreamCommandBuffer(stream, command_buffer);
    try stream.synchronize();
}

pub fn submitStreamCommandBuffer(stream: *Stream, command_buffer: VkCommandBuffer) Error!void {
    const runtime = stream._runtime;
    const driver = &runtime._driver;
    var wait_info = driver_mod.VkSemaphoreSubmitInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = stream._semaphore,
        .value = stream.counter,
        .stageMask = pipeline_stage_2_all_commands,
        .deviceIndex = 0,
    };
    const signal_value = stream.counter + 1;
    var signal_info = driver_mod.VkSemaphoreSubmitInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = stream._semaphore,
        .value = signal_value,
        .stageMask = pipeline_stage_2_all_commands,
        .deviceIndex = 0,
    };
    var command_info = driver_mod.VkCommandBufferSubmitInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .pNext = null,
        .commandBuffer = command_buffer,
        .deviceMask = 0,
    };
    const submit = driver_mod.VkSubmitInfo2{
        .sType = driver_mod.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .pNext = null,
        .flags = 0,
        .waitSemaphoreInfoCount = 1,
        .pWaitSemaphoreInfos = @ptrCast(&wait_info),
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = @ptrCast(&command_info),
        .signalSemaphoreInfoCount = 1,
        .pSignalSemaphoreInfos = @ptrCast(&signal_info),
    };
    try driver.fromResult(driver.vkQueueSubmit2(runtime._queue, 1, @ptrCast(&submit), null));
    retireStreamCommandBuffer(stream, command_buffer, signal_value);
    stream.counter = signal_value;
}

fn transferDeviceBuffer(
    target: *DeviceBuffer,
    staging: *const TransferBuffer,
    bytes: usize,
    direction: TransferDirection,
) Error!void {
    const runtime = target._runtime;
    const stream = try runtime.defaultStream();
    errdefer stream.poisoned = true;
    const command_buffer = try acquireStreamCommandBuffer(stream);
    const begin_info = driver_mod.VkCommandBufferBeginInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = driver_mod.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try runtime._driver.fromResult(runtime._driver.vkBeginCommandBuffer(command_buffer, &begin_info));

    const shader_access = driver_mod.VK_ACCESS_SHADER_READ_BIT |
        driver_mod.VK_ACCESS_SHADER_WRITE_BIT;
    switch (direction) {
        .upload => recordBufferBarrier(
            &runtime._driver,
            command_buffer,
            target._buffer,
            bytes,
            shader_access,
            driver_mod.VK_ACCESS_TRANSFER_WRITE_BIT,
            driver_mod.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            driver_mod.VK_PIPELINE_STAGE_TRANSFER_BIT,
        ),
        .download => recordBufferBarrier(
            &runtime._driver,
            command_buffer,
            target._buffer,
            bytes,
            driver_mod.VK_ACCESS_SHADER_WRITE_BIT,
            driver_mod.VK_ACCESS_TRANSFER_READ_BIT,
            driver_mod.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            driver_mod.VK_PIPELINE_STAGE_TRANSFER_BIT,
        ),
    }
    const copy = VkBufferCopy{ .srcOffset = 0, .dstOffset = 0, .size = bytes };
    runtime._driver.vkCmdCopyBuffer(
        command_buffer,
        if (direction == .upload) staging.buffer else target._buffer,
        if (direction == .upload) target._buffer else staging.buffer,
        1,
        @ptrCast(&copy),
    );
    switch (direction) {
        .upload => recordBufferBarrier(
            &runtime._driver,
            command_buffer,
            target._buffer,
            bytes,
            driver_mod.VK_ACCESS_TRANSFER_WRITE_BIT,
            shader_access,
            driver_mod.VK_PIPELINE_STAGE_TRANSFER_BIT,
            driver_mod.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        ),
        .download => recordBufferBarrier(
            &runtime._driver,
            command_buffer,
            target._buffer,
            bytes,
            driver_mod.VK_ACCESS_TRANSFER_READ_BIT,
            shader_access,
            driver_mod.VK_PIPELINE_STAGE_TRANSFER_BIT,
            driver_mod.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        ),
    }
    if (direction == .download) recordHostReadBarrier(&runtime._driver, command_buffer);
    try runtime._driver.fromResult(runtime._driver.vkEndCommandBuffer(command_buffer));
    try submitStreamCommandBuffer(stream, command_buffer);
    try stream.synchronize();
}

/// Every use a device buffer may serve: kernel storage, transfers, and the vertex, index and
/// uniform reads of a draw. One buffer can feed a kernel and then a draw without a copy.
pub const device_buffer_usage: driver_mod.VkBufferUsageFlags = driver_mod.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
    driver_mod.VK_BUFFER_USAGE_TRANSFER_SRC_BIT |
    driver_mod.VK_BUFFER_USAGE_TRANSFER_DST_BIT |
    driver_mod.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT |
    driver_mod.VK_BUFFER_USAGE_INDEX_BUFFER_BIT |
    driver_mod.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;

pub const DeviceBuffer = struct {
    _runtime: *Runtime,
    _buffer: VkBuffer,
    _allocation: memory_mod.Allocation,
    size: usize,

    pub fn alloc(runtime: *Runtime, bytes: usize) Error!DeviceBuffer {
        return allocIn(runtime, bytes, .device);
    }

    /// A buffer of `bytes` in memory chosen by `preference`. Upload memory
    /// is mapped, so `copyFromHost` writes it in place.
    pub fn allocIn(runtime: *Runtime, bytes: usize, preference: MemoryPreference) Error!DeviceBuffer {
        if (bytes == 0) return Error.InitializationFailed;
        const buffer_ci = driver_mod.VkBufferCreateInfo{
            .sType = driver_mod.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = bytes,
            .usage = device_buffer_usage,
            .sharingMode = driver_mod.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        var buffer: VkBuffer = null;
        try observation.result(runtime.observer, .buffer, bytes, runtime._driver.fromResult(runtime._driver.vkCreateBuffer(
            runtime._logical_device,
            &buffer_ci,
            null,
            &buffer,
        )));
        errdefer {
            runtime._driver.vkDestroyBuffer(runtime._logical_device, buffer, null);
            observation.release(runtime.observer, .buffer, bytes, true);
        }

        var requirements: VkMemoryRequirements = undefined;
        runtime._driver.vkGetBufferMemoryRequirements(runtime._logical_device, buffer, &requirements);
        const allocation = try runtime._memory.allocate(
            &runtime._driver,
            runtime._logical_device,
            requirements,
            preference,
        );
        errdefer runtime._memory.release(allocation);
        try runtime._driver.fromResult(runtime._driver.vkBindBufferMemory(
            runtime._logical_device,
            buffer,
            runtime._memory.deviceMemory(allocation),
            allocation.offset,
        ));
        return .{
            ._runtime = runtime,
            ._buffer = buffer,
            ._allocation = allocation,
            .size = bytes,
        };
    }

    pub fn deinit(self: *DeviceBuffer) void {
        self._runtime._driver.vkDestroyBuffer(self._runtime._logical_device, self._buffer, null);
        observation.release(self._runtime.observer, .buffer, self.size, false);
        self._runtime._memory.release(self._allocation);
        self.* = undefined;
    }

    pub fn copyFromHost(self: *DeviceBuffer, host: []const u8) Error!void {
        if (host.len > self.size) return Error.InitializationFailed;
        if (host.len == 0) {
            observation.noop(self._runtime.observer, true);
            return;
        }
        const route: observation.Route = if (self._runtime._memory.mapped(self._allocation) != null) .mapped_upload else .staged_upload;
        observation.transferAttempt(self._runtime.observer, route, host.len);
        errdefer observation.transferFailure(self._runtime.observer, route);
        if (self._runtime._memory.mapped(self._allocation)) |mapped| {
            @memcpy(mapped[0..host.len], host);
            try self._runtime._memory.flush(&self._runtime._driver, self._runtime._logical_device, .{
                .block_index = self._allocation.block_index,
                .offset = self._allocation.offset,
                .size = host.len,
            });
            observation.transferComplete(self._runtime.observer, route, host.len);
            return;
        }
        var staging = try TransferBuffer.init(self._runtime, host.len);
        defer staging.deinit();
        const mapped = self._runtime._memory.mapped(staging.allocation) orelse return Error.MemoryMapFailed;
        @memcpy(mapped[0..host.len], host);
        try self._runtime._memory.flush(&self._runtime._driver, self._runtime._logical_device, staging.allocation);
        try transferDeviceBuffer(self, &staging, host.len, .upload);
        observation.transferComplete(self._runtime.observer, route, host.len);
    }

    pub fn copyToHost(self: *DeviceBuffer, host: []u8) Error!void {
        if (host.len < self.size) return Error.InitializationFailed;
        if (self.size == 0) {
            observation.noop(self._runtime.observer, false);
            return;
        }
        const route: observation.Route = if (self._runtime._memory.mapped(self._allocation) != null) .mapped_download else .staged_download;
        observation.transferAttempt(self._runtime.observer, route, self.size);
        errdefer observation.transferFailure(self._runtime.observer, route);
        if (self._runtime._memory.mapped(self._allocation)) |mapped| {
            try awaitHostReads(self._runtime);
            try self._runtime._memory.invalidate(&self._runtime._driver, self._runtime._logical_device, self._allocation);
            @memcpy(host[0..self.size], mapped[0..self.size]);
            observation.transferComplete(self._runtime.observer, route, self.size);
            return;
        }
        var staging = try TransferBuffer.init(self._runtime, self.size);
        defer staging.deinit();
        try transferDeviceBuffer(self, &staging, self.size, .download);
        try self._runtime._memory.invalidate(&self._runtime._driver, self._runtime._logical_device, staging.allocation);
        const mapped = self._runtime._memory.mapped(staging.allocation) orelse return Error.MemoryMapFailed;
        @memcpy(host[0..self.size], mapped[0..self.size]);
        observation.transferComplete(self._runtime.observer, route, self.size);
    }
};

fn deviceHasExtension(
    drv: *const Driver,
    allocator: std.mem.Allocator,
    phys: VkPhysicalDevice,
    name: []const u8,
) Error!bool {
    var count: u32 = 0;
    try drv.fromResult(drv.vkEnumerateDeviceExtensionProperties(phys, null, &count, null));
    if (count == 0) return false;

    const exts = allocator.alloc(driver_mod.VkExtensionProperties, count) catch return Error.OutOfHostMemory;
    defer allocator.free(exts);
    try drv.fromResult(drv.vkEnumerateDeviceExtensionProperties(phys, null, &count, exts.ptr));

    for (exts) |*ext| {
        if (std.mem.eql(u8, ext.name(), name)) {
            return true;
        }
    }
    return false;
}

const QueueFamilySelection = struct {
    index: u32,
    timestamp_valid_bits: u32,
    graphics: bool,
};

/// Picks the first family that runs both compute and graphics, so kernels and draws share one
/// queue and one timeline. A device with no such family keeps compute and reports no graphics.
fn selectQueueFamily(
    drv: *const Driver,
    allocator: std.mem.Allocator,
    phys: VkPhysicalDevice,
) Error!QueueFamilySelection {
    var count: u32 = 0;
    drv.vkGetPhysicalDeviceQueueFamilyProperties(phys, &count, null);
    if (count == 0) return Error.NoDevice;

    const qfams = allocator.alloc(driver_mod.VkQueueFamilyProperties, count) catch return Error.OutOfHostMemory;
    defer allocator.free(qfams);
    drv.vkGetPhysicalDeviceQueueFamilyProperties(phys, &count, qfams.ptr);

    const both = driver_mod.VK_QUEUE_COMPUTE_BIT | driver_mod.VK_QUEUE_GRAPHICS_BIT;
    var compute_only: ?QueueFamilySelection = null;
    for (qfams, 0..) |*qf, i| {
        if (qf.queueCount == 0) continue;
        if ((qf.queueFlags & both) == both) {
            return .{
                .index = @intCast(i),
                .timestamp_valid_bits = qf.timestampValidBits,
                .graphics = true,
            };
        }
        if ((qf.queueFlags & driver_mod.VK_QUEUE_COMPUTE_BIT) != 0 and compute_only == null) {
            compute_only = .{
                .index = @intCast(i),
                .timestamp_valid_bits = qf.timestampValidBits,
                .graphics = false,
            };
        }
    }
    return compute_only orelse Error.NoDevice;
}

fn createStreamResources(rt: *Runtime, stream: *Stream) Error!void {
    const pool_ci = driver_mod.VkCommandPoolCreateInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = driver_mod.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT |
            driver_mod.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = rt.device.queueFamilyIndex(),
    };
    var pool: VkCommandPool = null;
    try observation.result(rt.observer, .command_pool, 0, rt._driver.fromResult(rt._driver.vkCreateCommandPool(
        rt._logical_device,
        &pool_ci,
        null,
        &pool,
    )));
    errdefer {
        rt._driver.vkDestroyCommandPool(rt._logical_device, pool, null);
        observation.release(rt.observer, .command_pool, 0, true);
    }

    const timeline_info = driver_mod.VkSemaphoreTypeCreateInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
        .pNext = null,
        .semaphoreType = driver_mod.VK_SEMAPHORE_TYPE_TIMELINE,
        .initialValue = 0,
    };
    const sem_ci = driver_mod.VkSemaphoreCreateInfo{
        .sType = driver_mod.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = @ptrCast(&timeline_info),
        .flags = 0,
    };
    var sem: VkSemaphore = null;
    try observation.result(rt.observer, .semaphore, 0, rt._driver.fromResult(rt._driver.vkCreateSemaphore(
        rt._logical_device,
        &sem_ci,
        null,
        &sem,
    )));

    stream._command_pool = pool;
    stream._semaphore = sem;
}

fn releaseStreamResources(rt: *Runtime, stream: *Stream) void {
    if (stream._descriptor_pool != null) {
        rt._driver.vkDestroyDescriptorPool(rt._logical_device, stream._descriptor_pool, null);
        observation.release(rt.observer, .descriptor_pool, 0, false);
        stream._descriptor_pool = null;
        while (stream._observed_descriptor_sets != 0) : (stream._observed_descriptor_sets -= 1) observation.release(rt.observer, .descriptor_set, 0, false);
        stream._retired_descriptor_set_count = 0;
    }
    stream._retired_command_buffer_count = 0;
    if (stream._semaphore != null) {
        rt._driver.vkDestroySemaphore(rt._logical_device, stream._semaphore, null);
        observation.release(rt.observer, .semaphore, 0, false);
        stream._semaphore = null;
    }
    if (stream._command_pool != null) {
        rt._driver.vkDestroyCommandPool(rt._logical_device, stream._command_pool, null);
        observation.release(rt.observer, .command_pool, 0, false);
        while (stream._observed_command_buffers != 0) : (stream._observed_command_buffers -= 1) observation.release(rt.observer, .command_buffer, 0, false);
        stream._command_pool = null;
    }
}

fn destroyInstanceSafe(drv: *Driver, instance: VkInstance) bool {
    if (instance == null) return false;
    drv.loadInstanceFunctions(instance) catch |err| {
        log.warn("vulkan: late-load of phase-2 fns for destroy failed: {s}", .{@errorName(err)});
        return false;
    };
    drv.vkDestroyInstance(instance, null);
    return true;
}

fn destroyDeviceSafe(drv: *Driver, device: VkDevice) bool {
    if (device == null) return false;
    drv.loadDeviceFunctions(device) catch |err| {
        log.warn("vulkan: late-load of phase-3 fns for destroy failed: {s}", .{@errorName(err)});
        return false;
    };
    drv.vkDestroyDevice(device, null);
    return true;
}

const max_captured_waits: usize = 64;

const fake_pipeline_capacity = 64;
const PipelineLedger = struct {
    raw_attempts: u32 = 0,
    returned: [fake_pipeline_capacity]VkPipeline = @splat(null),
    returned_count: usize = 0,
    destroyed: [fake_pipeline_capacity]VkPipeline = @splat(null),
    destroyed_count: usize = 0,
    live: [fake_pipeline_capacity]VkPipeline = @splat(null),
    live_count: usize = 0,
    duplicate_or_unknown_destroys: u32 = 0,
    overflow: bool = false,

    fn created(self: *PipelineLedger, handle: VkPipeline) void {
        if (handle == null) return;
        if (self.returned_count == self.returned.len) {
            self.overflow = true;
            return;
        }
        self.returned[self.returned_count] = handle;
        self.live[self.returned_count] = handle;
        self.returned_count += 1;
        self.live_count += 1;
    }
    fn release(self: *PipelineLedger, handle: VkPipeline) void {
        if (self.destroyed_count < self.destroyed.len) {
            self.destroyed[self.destroyed_count] = handle;
            self.destroyed_count += 1;
        } else self.overflow = true;
        for (self.live[0..self.returned_count]) |*live| {
            if (live.* == handle and handle != null) {
                live.* = null;
                self.live_count -= 1;
                return;
            }
        }
        self.duplicate_or_unknown_destroys += 1;
    }
};

// Raw fake-driver ownership, independent of AllocationObservation. Each test reset
// bounds the census; a saturated ledger is evidence failure, never silent loss.
const HandleLedger = struct {
    const capacity = 2 * max_retired_descriptor_sets;
    attempts: u32 = 0,
    returned: [capacity]usize = @splat(0),
    destroyed: [capacity]usize = @splat(0),
    live: [capacity]usize = @splat(0),
    owners: [capacity]usize = @splat(0),
    returned_count: usize = 0,
    destroyed_count: usize = 0,
    live_count: usize = 0,
    unknown_destroys: u32 = 0,
    overflow: bool = false,

    fn created(self: *HandleLedger, handle: usize) void {
        std.debug.assert(handle != 0);
        if (self.returned_count == capacity) {
            self.overflow = true;
            return;
        }
        self.returned[self.returned_count] = handle;
        self.live[self.returned_count] = handle;
        self.returned_count += 1;
        self.live_count += 1;
    }

    fn createdOwned(self: *HandleLedger, handle: usize, owner: usize) void {
        const index = self.returned_count;
        self.created(handle);
        if (index < capacity) self.owners[index] = owner;
    }

    fn releaseOwned(self: *HandleLedger, owner: usize) void {
        for (self.live[0..self.returned_count], 0..) |handle, index| {
            if (handle != 0 and self.owners[index] == owner) self.release(handle);
        }
    }

    fn release(self: *HandleLedger, handle: usize) void {
        std.debug.assert(handle != 0);
        if (self.destroyed_count == capacity) {
            self.overflow = true;
        } else {
            self.destroyed[self.destroyed_count] = handle;
            self.destroyed_count += 1;
        }
        for (self.live[0..self.returned_count]) |*candidate| {
            if (candidate.* != handle) continue;
            candidate.* = 0;
            self.live_count -= 1;
            return;
        }
        self.unknown_destroys += 1;
    }
};

const RawEffects = struct {
    buffer: HandleLedger = .{},
    memory: HandleLedger = .{},
    command_pool: HandleLedger = .{},
    semaphore: HandleLedger = .{},
    query_pool: HandleLedger = .{},
    shader: HandleLedger = .{},
    pipeline_layout: HandleLedger = .{},
    descriptor_layout: HandleLedger = .{},
    descriptor_pool: HandleLedger = .{},
    descriptor_set: HandleLedger = .{},
    command_buffer: HandleLedger = .{},
};

const FakeState = struct {
    effects: RawEffects = .{},
    desc_pool_reset_return: VkResult = .success,
    cb_reset_return: VkResult = .success,
    cb_alloc_return: VkResult = .success,
    desc_set_return: VkResult = .success,
    desc_pool_return: VkResult = .success,
    set_layout_return: VkResult = .success,
    pipeline_layout_return: VkResult = .success,
    shader_module_return: VkResult = .success,
    pool_creates: u32 = 0,
    pool_destroys: u32 = 0,
    pool_create_return: VkResult = .success,
    next_pool_handle: usize = 0xa000,
    last_pool_queue_family: u32 = 0,
    last_pool_flags: u32 = 0,

    sem_creates: u32 = 0,
    sem_destroys: u32 = 0,
    sem_create_return: VkResult = .success,
    next_sem_handle: usize = 0xb000,
    last_sem_type: u32 = 0,
    last_sem_initial: u64 = 0,

    query_pool_creates: u32 = 0,
    query_pool_destroys: u32 = 0,
    query_pool_results: u32 = 0,
    query_pool_create_return: VkResult = .success,
    query_pool_results_return: VkResult = .success,
    next_query_pool_handle: VkQueryPool = 0x4100,
    last_query_type: driver_mod.VkQueryType = 0,
    last_query_count: u32 = 0,
    query_result_values: [8]u64 = @as([8]u64, @splat(0)),
    query_result_index: usize = 0,

    counter_queries: u32 = 0,
    waits: u32 = 0,
    counter_value: u64 = 0,
    counter_return: VkResult = .success,
    wait_return: VkResult = .success,
    last_wait_value: u64 = 0,
    last_wait_semaphore: VkSemaphore = null,
    last_wait_timeout: u64 = 0,

    device_waits: u32 = 0,
    device_wait_return: VkResult = .success,

    surface_creates: u32 = 0,
    surface_destroys: u32 = 0,
    surface_support_queries: u32 = 0,
    surface_caps_queries: u32 = 0,
    surface_format_queries: u32 = 0,
    surface_mode_queries: u32 = 0,
    surface_create_return: VkResult = .success,
    surface_support_return: VkResult = .success,
    surface_caps_return: VkResult = .success,
    surface_formats_return: VkResult = .success,
    surface_modes_return: VkResult = .success,
    surface_supported: bool = true,
    next_surface_handle: VkSurfaceKHR = 0x1200_0000,
    last_xlib_display: driver_mod.VkDisplay = null,
    last_xlib_window: driver_mod.VkWindow = 0,
    surface_caps: VkSurfaceCapabilitiesKHR = .{
        .minImageCount = 2,
        .maxImageCount = 4,
        .currentExtent = .{
            .width = std.math.maxInt(u32),
            .height = std.math.maxInt(u32),
        },
        .minImageExtent = .{ .width = 1, .height = 1 },
        .maxImageExtent = .{ .width = 4096, .height = 4096 },
        .maxImageArrayLayers = 1,
        .supportedTransforms = driver_mod.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
        .currentTransform = driver_mod.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
        .supportedCompositeAlpha = driver_mod.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .supportedUsageFlags = driver_mod.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
            driver_mod.VK_IMAGE_USAGE_TRANSFER_DST_BIT |
            driver_mod.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
    },
    surface_formats: [4]VkSurfaceFormatKHR = .{
        .{ .format = driver_mod.VK_FORMAT_B8G8R8A8_UNORM, .colorSpace = driver_mod.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
        .{ .format = driver_mod.VK_FORMAT_R8G8B8A8_UNORM, .colorSpace = driver_mod.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
        .{ .format = 0, .colorSpace = 0 },
        .{ .format = 0, .colorSpace = 0 },
    },
    surface_format_count: u32 = 2,
    surface_modes: [3]VkPresentModeKHR = .{
        driver_mod.VK_PRESENT_MODE_FIFO_KHR,
        driver_mod.VK_PRESENT_MODE_MAILBOX_KHR,
        driver_mod.VK_PRESENT_MODE_IMMEDIATE_KHR,
    },
    surface_mode_count: u32 = 3,

    swapchain_creates: u32 = 0,
    swapchain_destroys: u32 = 0,
    swapchain_image_queries: u32 = 0,
    swapchain_create_return: VkResult = .success,
    swapchain_images_return: VkResult = .success,
    next_swapchain_handle: VkSwapchainKHR = 0x1300_0000,
    swapchain_images: [4]VkImage = .{ 0x1400_0001, 0x1400_0002, 0x1400_0003, 0x1400_0004 },
    swapchain_image_count: u32 = 2,
    last_swapchain_surface: VkSurfaceKHR = 0,
    last_swapchain_min_image_count: u32 = 0,
    last_swapchain_format: VkFormat = 0,
    last_swapchain_color_space: VkColorSpaceKHR = 0,
    last_swapchain_extent: VkExtent2D = .{ .width = 0, .height = 0 },
    last_swapchain_usage: VkImageUsageFlags = 0,
    last_swapchain_present_mode: VkPresentModeKHR = 0,
    last_swapchain_composite_alpha: driver_mod.VkCompositeAlphaFlagBitsKHR = 0,
    last_swapchain_old: VkSwapchainKHR = 0,

    view_creates: u32 = 0,
    view_destroys: u32 = 0,
    view_create_return: VkResult = .success,
    next_view_handle: VkImageView = 0x1500_0000,
    last_view_image: VkImage = 0,

    acquires: u32 = 0,
    acquire_return: VkResult = .success,
    acquire_index: u32 = 0,
    last_acquire_swapchain: VkSwapchainKHR = 0,
    last_acquire_semaphore: VkSemaphore = null,

    presents: u32 = 0,
    present_return: VkResult = .success,
    present_result: VkResult = .success,
    last_present_wait_count: u32 = 0,
    last_present_wait_semaphore: VkSemaphore = null,
    last_present_swapchain: VkSwapchainKHR = 0,
    last_present_index: u32 = 0,

    buffer_creates: u32 = 0,
    buffer_destroys: u32 = 0,
    buffer_create_return: VkResult = .success,
    next_buffer_handle: usize = 0xc000,
    last_buffer_size: u64 = 0,
    last_buffer_usage: u32 = 0,
    last_buffer_sharing: u32 = 0,

    mem_allocs: u32 = 0,
    mem_frees: u32 = 0,
    mem_alloc_return: VkResult = .success,
    next_memory_handle: usize = 0xd000,
    last_alloc_size: u64 = 0,
    last_alloc_type_index: u32 = 0,

    binds: u32 = 0,
    bind_return: VkResult = .success,
    last_bind_offset: u64 = 0,
    last_bind_buffer: VkBuffer = null,
    last_bind_memory: VkDeviceMemory = null,

    maps: u32 = 0,
    unmaps: u32 = 0,
    map_return: VkResult = .success,
    flush_return: VkResult = .success,
    invalidate_return: VkResult = .success,
    last_map_offset: u64 = 0,
    last_map_size: u64 = 0,
    map_override_ptr: ?*anyopaque = null,
    mapped_memory: [1024 * 1024]u8 = @splat(0),
    flushes: u32 = 0,
    invalidates: u32 = 0,
    last_invalidate_offset: u64 = 0,
    last_invalidate_size: u64 = 0,

    req_queries: u32 = 0,
    req_size: u64 = 0,
    req_alignment: u64 = 256,
    req_type_bits: u32 = 0xFFFFFFFF,

    mem_props_queries: u32 = 0,
    mem_props: VkPhysicalDeviceMemoryProperties = .{
        .memoryTypeCount = 1,
        .memoryTypes = @as([driver_mod.VK_MAX_MEMORY_TYPES]driver_mod.VkMemoryType, @splat(.{ .propertyFlags = 0, .heapIndex = 0 })),
        .memoryHeapCount = 1,
        .memoryHeaps = @as([driver_mod.VK_MAX_MEMORY_HEAPS]driver_mod.VkMemoryHeap, @splat(.{ .size = 0, .flags = 0 })),
    },

    shader_module_creates: u32 = 0,
    shader_module_destroys: u32 = 0,
    next_shader_module_handle: usize = 0xe000,
    last_shader_code_size: usize = 0,

    pipeline_layout_creates: u32 = 0,
    pipeline_layout_destroys: u32 = 0,
    next_pipeline_layout_handle: usize = 0xe100,

    set_layout_creates: u32 = 0,
    set_layout_destroys: u32 = 0,
    next_set_layout_handle: usize = 0xe200,
    last_set_layout_binding_count: u32 = 0,

    pipeline_ledger: PipelineLedger = .{},
    compute_pipeline_creates: u32 = 0,
    compute_pipeline_return: VkResult = .success,
    compute_pipeline_return_handle: bool = true,
    pipeline_destroys: u32 = 0,
    next_pipeline_handle: usize = 0xe300,

    desc_pool_creates: u32 = 0,
    desc_pool_destroys: u32 = 0,
    desc_pool_resets: u32 = 0,
    next_desc_pool_handle: usize = 0xe400,
    last_desc_pool_max_sets: u32 = 0,

    desc_set_allocs: u32 = 0,
    next_desc_set_handle: usize = 0xe500,

    update_desc_sets_calls: u32 = 0,
    last_write_count: u32 = 0,

    cb_allocs: u32 = 0,
    cb_resets: u32 = 0,
    next_cb_handle: usize = 0xf000,

    cb_begins: u32 = 0,
    cb_ends: u32 = 0,
    cmd_bind_pipelines: u32 = 0,
    cmd_bind_desc_sets: u32 = 0,
    cmd_dispatches: u32 = 0,
    cmd_push_constants: u32 = 0,
    cmd_reset_query_pools: u32 = 0,
    cmd_write_timestamps: u32 = 0,
    last_timestamp_stage: driver_mod.VkPipelineStageFlags = 0,
    last_timestamp_query_pool: VkQueryPool = 0,
    last_push_constant_size: u32 = 0,
    last_push_constant_bytes: [128]u8 = @splat(0),
    last_dispatch: [3]u32 = .{ 0, 0, 0 },

    submits: u32 = 0,
    queue_submit_return: VkResult = .success,
    last_submit_wait_count: u32 = 0,
    last_submit_signal_count: u32 = 0,
    last_submit_cb_count: u32 = 0,
    last_submit_signal_semaphore: VkSemaphore = null,
    last_submit_signal_value: u64 = 0,
    last_submit_wait_semaphores: [max_captured_waits]VkSemaphore = @as([max_captured_waits]VkSemaphore, @splat(null)),
    last_submit_wait_values: [max_captured_waits]u64 = @as([max_captured_waits]u64, @splat(0)),
    last_submit_signal_semaphores: [max_captured_waits]VkSemaphore = @as([max_captured_waits]VkSemaphore, @splat(null)),
    last_submit_signal_values: [max_captured_waits]u64 = @as([max_captured_waits]u64, @splat(0)),

    cmd_barriers: u32 = 0,
    host_read_barriers: u32 = 0,
    /// Buffer copies and submits recorded before the last host-read barrier.
    host_read_barrier_after_copies: u32 = 0,
    host_read_barrier_after_submits: u32 = 0,
    first_barrier_old_layout: VkImageLayout = 0,
    first_barrier_new_layout: VkImageLayout = 0,
    last_barrier_old_layout: VkImageLayout = 0,
    last_barrier_new_layout: VkImageLayout = 0,
    last_barrier_image: VkImage = 0,
    cmd_clears: u32 = 0,
    last_clear_image: VkImage = 0,
    last_clear_layout: VkImageLayout = 0,
    last_clear_color: [4]f32 = .{ 0, 0, 0, 0 },
    cmd_copies: u32 = 0,
    cmd_buffer_copies: u32 = 0,
    last_copy_src_buffer: VkBuffer = null,
    last_copy_dst_image: VkImage = 0,
    last_copy_layout: VkImageLayout = 0,
    last_copy_extent: driver_mod.VkExtent3D = .{ .width = 0, .height = 0, .depth = 0 },
    cmd_image_copies: u32 = 0,
    last_copy_src_image: VkImage = 0,
    last_copy_dst_buffer: VkBuffer = null,
    last_copy_src_layout: VkImageLayout = 0,

    fn reset(self: *FakeState) void {
        self.* = .{};
        self.seedHostCoherentMemoryType();
    }

    fn seedHostCoherentMemoryType(self: *FakeState) void {
        self.mem_props.memoryTypeCount = 1;
        self.mem_props.memoryTypes[0] = .{
            .propertyFlags = driver_mod.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                driver_mod.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            .heapIndex = 0,
        };
        self.mem_props.memoryHeapCount = 1;
        self.mem_props.memoryHeaps[0] = .{ .size = 1 << 30, .flags = 0 };
    }
};

var fake: FakeState = .{};

fn fakeGipa(_: VkInstance, _: [*:0]const u8) callconv(.c) driver_mod.PFN_vkVoidFunction {
    return null;
}
fn fakeCreateInstance(_: *const driver_mod.VkInstanceCreateInfo, _: ?*const anyopaque, _: *VkInstance) callconv(.c) VkResult {
    return .success;
}
fn fakeDestroyInstance(_: VkInstance, _: ?*const anyopaque) callconv(.c) void {}
fn fakeEnumPhys(_: VkInstance, _: *u32, _: ?[*]VkPhysicalDevice) callconv(.c) VkResult {
    return .success;
}
fn fakeGetProps(_: VkPhysicalDevice, props: *driver_mod.VkPhysicalDeviceProperties) callconv(.c) void {
    props.* = std.mem.zeroes(driver_mod.VkPhysicalDeviceProperties);
    props.apiVersion = driver_mod.VK_API_VERSION_1_3;
    props.limits.timestampPeriod = 2.5;
}
fn fakeGetProps2(device: VkPhysicalDevice, props: *driver_mod.VkPhysicalDeviceProperties2) callconv(.c) void {
    fakeGetProps(device, &props.properties);
    const next = props.pNext orelse return;
    const subgroup: *driver_mod.VkPhysicalDeviceSubgroupProperties = @ptrCast(@alignCast(next));
    subgroup.subgroupSize = 32;
    subgroup.supportedStages = driver_mod.VK_SHADER_STAGE_COMPUTE_BIT;
    subgroup.supportedOperations = driver_mod.VK_SUBGROUP_FEATURE_BASIC_BIT |
        driver_mod.VK_SUBGROUP_FEATURE_VOTE_BIT |
        driver_mod.VK_SUBGROUP_FEATURE_ARITHMETIC_BIT |
        driver_mod.VK_SUBGROUP_FEATURE_BALLOT_BIT |
        driver_mod.VK_SUBGROUP_FEATURE_SHUFFLE_BIT |
        driver_mod.VK_SUBGROUP_FEATURE_SHUFFLE_RELATIVE_BIT;
}
fn fakeGetFeatures2(_: VkPhysicalDevice, _: *driver_mod.VkPhysicalDeviceFeatures2) callconv(.c) void {}
fn fakeEnumDevExts(_: VkPhysicalDevice, _: ?[*:0]const u8, _: *u32, _: ?[*]driver_mod.VkExtensionProperties) callconv(.c) VkResult {
    return .success;
}
fn fakeGetQF(_: VkPhysicalDevice, count: *u32, out: ?[*]driver_mod.VkQueueFamilyProperties) callconv(.c) void {
    if (out) |props| {
        props[0] = .{
            .queueFlags = driver_mod.VK_QUEUE_COMPUTE_BIT,
            .queueCount = 1,
            .timestampValidBits = 64,
            .minImageTransferGranularity = .{ .width = 1, .height = 1, .depth = 1 },
        };
    }
    count.* = 1;
}
fn fakeCreateDevice(_: VkPhysicalDevice, _: *const driver_mod.VkDeviceCreateInfo, _: ?*const anyopaque, _: *VkDevice) callconv(.c) VkResult {
    return .success;
}
fn fakeGdpa(_: VkDevice, _: [*:0]const u8) callconv(.c) driver_mod.PFN_vkVoidFunction {
    return null;
}

fn fakeDestroyDevice(_: VkDevice, _: ?*const anyopaque) callconv(.c) void {}
fn fakeGetDeviceQueue(_: VkDevice, _: u32, _: u32, _: *VkQueue) callconv(.c) void {}

fn fakeCreateCommandPool(
    _: VkDevice,
    pCreateInfo: *const VkCommandPoolCreateInfo,
    _: ?*const anyopaque,
    pPool: *VkCommandPool,
) callconv(.c) VkResult {
    fake.effects.command_pool.attempts += 1;
    fake.pool_creates += 1;
    fake.last_pool_queue_family = pCreateInfo.queueFamilyIndex;
    fake.last_pool_flags = pCreateInfo.flags;
    if (fake.pool_create_return != .success) return fake.pool_create_return;
    fake.next_pool_handle += 0x10;
    pPool.* = @ptrFromInt(fake.next_pool_handle);
    fake.effects.command_pool.created(fake.next_pool_handle);
    return .success;
}

fn fakeDestroyCommandPool(_: VkDevice, handle: VkCommandPool, _: ?*const anyopaque) callconv(.c) void {
    fake.effects.command_buffer.releaseOwned(@intFromPtr(handle));
    fake.effects.command_pool.release(@intFromPtr(handle));
    fake.pool_destroys += 1;
}

fn fakeAllocCommandBuffers(
    _: VkDevice,
    pInfo: *const VkCommandBufferAllocateInfo,
    pBuffers: [*]VkCommandBuffer,
) callconv(.c) VkResult {
    fake.effects.command_buffer.attempts += 1;
    fake.cb_allocs += 1;
    if (fake.cb_alloc_return != .success) return fake.cb_alloc_return;
    var i: u32 = 0;
    while (i < pInfo.commandBufferCount) : (i += 1) {
        fake.next_cb_handle += 0x10;
        pBuffers[i] = @ptrFromInt(fake.next_cb_handle);
        fake.effects.command_buffer.createdOwned(fake.next_cb_handle, @intFromPtr(pInfo.commandPool));
    }
    return .success;
}
fn fakeFreeCommandBuffers(_: VkDevice, _: VkCommandPool, count: u32, buffers: [*]const VkCommandBuffer) callconv(.c) void {
    for (buffers[0..count]) |buffer| fake.effects.command_buffer.release(@intFromPtr(buffer));
}

fn fakeCreateSemaphore(
    _: VkDevice,
    pCreateInfo: *const VkSemaphoreCreateInfo,
    _: ?*const anyopaque,
    pSem: *VkSemaphore,
) callconv(.c) VkResult {
    fake.effects.semaphore.attempts += 1;
    fake.sem_creates += 1;
    fake.last_sem_type = driver_mod.VK_SEMAPHORE_TYPE_BINARY;
    fake.last_sem_initial = 0;
    if (pCreateInfo.pNext) |next| {
        const type_info: *const driver_mod.VkSemaphoreTypeCreateInfo = @ptrCast(@alignCast(next));
        fake.last_sem_type = type_info.semaphoreType;
        fake.last_sem_initial = type_info.initialValue;
    }
    if (fake.sem_create_return != .success) return fake.sem_create_return;
    fake.next_sem_handle += 0x10;
    pSem.* = @ptrFromInt(fake.next_sem_handle);
    fake.effects.semaphore.created(fake.next_sem_handle);
    return .success;
}

fn fakeDestroySemaphore(_: VkDevice, handle: VkSemaphore, _: ?*const anyopaque) callconv(.c) void {
    fake.effects.semaphore.release(@intFromPtr(handle));
    fake.sem_destroys += 1;
}

fn fakeCreateQueryPool(
    _: VkDevice,
    pCreateInfo: *const driver_mod.VkQueryPoolCreateInfo,
    _: ?*const anyopaque,
    pQueryPool: *VkQueryPool,
) callconv(.c) VkResult {
    fake.effects.query_pool.attempts += 1;
    fake.query_pool_creates += 1;
    fake.last_query_type = pCreateInfo.queryType;
    fake.last_query_count = pCreateInfo.queryCount;
    if (fake.query_pool_create_return != .success) return fake.query_pool_create_return;
    fake.next_query_pool_handle += 1;
    pQueryPool.* = fake.next_query_pool_handle;
    fake.effects.query_pool.created(fake.next_query_pool_handle);
    return .success;
}

fn fakeDestroyQueryPool(_: VkDevice, handle: VkQueryPool, _: ?*const anyopaque) callconv(.c) void {
    fake.effects.query_pool.release(handle);
    fake.query_pool_destroys += 1;
}

fn fakeGetQueryPoolResults(
    _: VkDevice,
    _: VkQueryPool,
    _: u32,
    _: u32,
    _: usize,
    pData: *anyopaque,
    _: u64,
    _: driver_mod.VkQueryResultFlags,
) callconv(.c) VkResult {
    fake.query_pool_results += 1;
    if (fake.query_pool_results_return != .success) return fake.query_pool_results_return;
    const out: *u64 = @ptrCast(@alignCast(pData));
    const index = @min(fake.query_result_index, fake.query_result_values.len - 1);
    out.* = fake.query_result_values[index];
    if (fake.query_result_index < fake.query_result_values.len - 1) fake.query_result_index += 1;
    return .success;
}

fn fakeGetSemaphoreCounterValue(_: VkDevice, _: VkSemaphore, pValue: *u64) callconv(.c) VkResult {
    fake.counter_queries += 1;
    pValue.* = fake.counter_value;
    return fake.counter_return;
}

fn fakeWaitSemaphores(_: VkDevice, pWaitInfo: *const VkSemaphoreWaitInfo, timeout: u64) callconv(.c) VkResult {
    fake.waits += 1;
    fake.last_wait_timeout = timeout;
    if (pWaitInfo.semaphoreCount >= 1) {
        fake.last_wait_semaphore = pWaitInfo.pSemaphores[0];
        fake.last_wait_value = pWaitInfo.pValues[0];
    }
    return fake.wait_return;
}

fn fakeSignalSemaphore(_: VkDevice, _: *const VkSemaphoreSignalInfo) callconv(.c) VkResult {
    return .success;
}

fn fakeQueueSubmit2(
    _: VkQueue,
    submitCount: u32,
    pSubmits: ?[*]const VkSubmitInfo2,
    _: VkFence,
) callconv(.c) VkResult {
    fake.submits += 1;
    if (submitCount >= 1) {
        const s = pSubmits.?[0];
        fake.last_submit_wait_count = s.waitSemaphoreInfoCount;
        fake.last_submit_signal_count = s.signalSemaphoreInfoCount;
        fake.last_submit_cb_count = s.commandBufferInfoCount;
        if (s.signalSemaphoreInfoCount >= 1) {
            const sig = s.pSignalSemaphoreInfos.?[0];
            fake.last_submit_signal_semaphore = sig.semaphore;
            fake.last_submit_signal_value = sig.value;
        }
        const captured_signals = @min(@as(usize, s.signalSemaphoreInfoCount), max_captured_waits);
        var sig_i: usize = 0;
        while (sig_i < captured_signals) : (sig_i += 1) {
            const sig = s.pSignalSemaphoreInfos.?[sig_i];
            fake.last_submit_signal_semaphores[sig_i] = sig.semaphore;
            fake.last_submit_signal_values[sig_i] = sig.value;
        }
        const captured = @min(@as(usize, s.waitSemaphoreInfoCount), max_captured_waits);
        var i: usize = 0;
        while (i < captured) : (i += 1) {
            const w = s.pWaitSemaphoreInfos.?[i];
            fake.last_submit_wait_semaphores[i] = w.semaphore;
            fake.last_submit_wait_values[i] = w.value;
        }
    }
    return fake.queue_submit_return;
}

fn fakeDeviceWaitIdle(_: VkDevice) callconv(.c) VkResult {
    fake.device_waits += 1;
    return fake.device_wait_return;
}

fn fakeCreateXlibSurfaceKHR(
    _: VkInstance,
    pCreateInfo: *const VkXlibSurfaceCreateInfoKHR,
    _: ?*const anyopaque,
    pSurface: *VkSurfaceKHR,
) callconv(.c) VkResult {
    fake.surface_creates += 1;
    fake.last_xlib_display = pCreateInfo.dpy;
    fake.last_xlib_window = pCreateInfo.window;
    if (fake.surface_create_return != .success) return fake.surface_create_return;
    fake.next_surface_handle += 1;
    pSurface.* = fake.next_surface_handle;
    return .success;
}

fn fakeDestroySurfaceKHR(_: VkInstance, _: VkSurfaceKHR, _: ?*const anyopaque) callconv(.c) void {
    fake.surface_destroys += 1;
}

fn fakeGetPhysicalDeviceSurfaceSupportKHR(
    _: VkPhysicalDevice,
    _: u32,
    _: VkSurfaceKHR,
    pSupported: *driver_mod.VkBool32,
) callconv(.c) VkResult {
    fake.surface_support_queries += 1;
    pSupported.* = if (fake.surface_supported) driver_mod.VK_TRUE else driver_mod.VK_FALSE;
    return fake.surface_support_return;
}

fn fakeGetPhysicalDeviceSurfaceCapabilitiesKHR(
    _: VkPhysicalDevice,
    _: VkSurfaceKHR,
    pSurfaceCapabilities: *VkSurfaceCapabilitiesKHR,
) callconv(.c) VkResult {
    fake.surface_caps_queries += 1;
    pSurfaceCapabilities.* = fake.surface_caps;
    return fake.surface_caps_return;
}

fn fakeGetPhysicalDeviceSurfaceFormatsKHR(
    _: VkPhysicalDevice,
    _: VkSurfaceKHR,
    pSurfaceFormatCount: *u32,
    pSurfaceFormats: ?[*]VkSurfaceFormatKHR,
) callconv(.c) VkResult {
    fake.surface_format_queries += 1;
    if (pSurfaceFormats) |formats| {
        const n = @min(pSurfaceFormatCount.*, fake.surface_format_count);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            formats[i] = fake.surface_formats[i];
        }
        pSurfaceFormatCount.* = n;
    } else {
        pSurfaceFormatCount.* = fake.surface_format_count;
    }
    return fake.surface_formats_return;
}

fn fakeGetPhysicalDeviceSurfacePresentModesKHR(
    _: VkPhysicalDevice,
    _: VkSurfaceKHR,
    pPresentModeCount: *u32,
    pPresentModes: ?[*]VkPresentModeKHR,
) callconv(.c) VkResult {
    fake.surface_mode_queries += 1;
    if (pPresentModes) |modes| {
        const n = @min(pPresentModeCount.*, fake.surface_mode_count);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            modes[i] = fake.surface_modes[i];
        }
        pPresentModeCount.* = n;
    } else {
        pPresentModeCount.* = fake.surface_mode_count;
    }
    return fake.surface_modes_return;
}

fn fakeCreateSwapchainKHR(
    _: VkDevice,
    pCreateInfo: *const VkSwapchainCreateInfoKHR,
    _: ?*const anyopaque,
    pSwapchain: *VkSwapchainKHR,
) callconv(.c) VkResult {
    fake.swapchain_creates += 1;
    fake.last_swapchain_surface = pCreateInfo.surface;
    fake.last_swapchain_min_image_count = pCreateInfo.minImageCount;
    fake.last_swapchain_format = pCreateInfo.imageFormat;
    fake.last_swapchain_color_space = pCreateInfo.imageColorSpace;
    fake.last_swapchain_extent = pCreateInfo.imageExtent;
    fake.last_swapchain_usage = pCreateInfo.imageUsage;
    fake.last_swapchain_present_mode = pCreateInfo.presentMode;
    fake.last_swapchain_composite_alpha = pCreateInfo.compositeAlpha;
    fake.last_swapchain_old = pCreateInfo.oldSwapchain;
    if (fake.swapchain_create_return != .success) return fake.swapchain_create_return;
    fake.next_swapchain_handle += 1;
    pSwapchain.* = fake.next_swapchain_handle;
    return .success;
}

fn fakeDestroySwapchainKHR(_: VkDevice, _: VkSwapchainKHR, _: ?*const anyopaque) callconv(.c) void {
    fake.swapchain_destroys += 1;
}

fn fakeGetSwapchainImagesKHR(
    _: VkDevice,
    _: VkSwapchainKHR,
    pSwapchainImageCount: *u32,
    pSwapchainImages: ?[*]VkImage,
) callconv(.c) VkResult {
    fake.swapchain_image_queries += 1;
    if (pSwapchainImages) |images| {
        const n = @min(pSwapchainImageCount.*, fake.swapchain_image_count);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            images[i] = fake.swapchain_images[i];
        }
        pSwapchainImageCount.* = n;
    } else {
        pSwapchainImageCount.* = fake.swapchain_image_count;
    }
    return fake.swapchain_images_return;
}

fn fakeCreateImageView(
    _: VkDevice,
    pCreateInfo: *const driver_mod.VkImageViewCreateInfo,
    _: ?*const anyopaque,
    pView: *VkImageView,
) callconv(.c) VkResult {
    fake.view_creates += 1;
    fake.last_view_image = pCreateInfo.image;
    if (fake.view_create_return != .success) return fake.view_create_return;
    fake.next_view_handle += 1;
    pView.* = fake.next_view_handle;
    return .success;
}

fn fakeDestroyImageView(_: VkDevice, _: VkImageView, _: ?*const anyopaque) callconv(.c) void {
    fake.view_destroys += 1;
}

fn fakeAcquireNextImageKHR(
    _: VkDevice,
    swapchain: VkSwapchainKHR,
    _: u64,
    semaphore: VkSemaphore,
    _: VkFence,
    pImageIndex: *u32,
) callconv(.c) VkResult {
    fake.acquires += 1;
    fake.last_acquire_swapchain = swapchain;
    fake.last_acquire_semaphore = semaphore;
    pImageIndex.* = fake.acquire_index;
    return fake.acquire_return;
}

fn fakeQueuePresentKHR(_: VkQueue, pPresentInfo: *const VkPresentInfoKHR) callconv(.c) VkResult {
    fake.presents += 1;
    fake.last_present_wait_count = pPresentInfo.waitSemaphoreCount;
    if (pPresentInfo.waitSemaphoreCount >= 1) {
        fake.last_present_wait_semaphore = pPresentInfo.pWaitSemaphores.?[0];
    }
    if (pPresentInfo.swapchainCount >= 1) {
        fake.last_present_swapchain = pPresentInfo.pSwapchains[0];
        fake.last_present_index = pPresentInfo.pImageIndices[0];
        if (pPresentInfo.pResults) |results| results[0] = fake.present_result;
    }
    return fake.present_return;
}

fn fakeGetPhysicalDeviceMemoryProperties(
    _: VkPhysicalDevice,
    pProps: *VkPhysicalDeviceMemoryProperties,
) callconv(.c) void {
    fake.mem_props_queries += 1;
    pProps.* = fake.mem_props;
}

fn fakeCreateBuffer(
    _: VkDevice,
    pCreateInfo: *const VkBufferCreateInfo,
    _: ?*const anyopaque,
    pBuffer: *VkBuffer,
) callconv(.c) VkResult {
    fake.effects.buffer.attempts += 1;
    fake.buffer_creates += 1;
    fake.last_buffer_size = pCreateInfo.size;
    fake.last_buffer_usage = pCreateInfo.usage;
    fake.last_buffer_sharing = pCreateInfo.sharingMode;
    if (fake.buffer_create_return != .success) return fake.buffer_create_return;
    fake.next_buffer_handle += 0x10;
    pBuffer.* = @ptrFromInt(fake.next_buffer_handle);
    fake.effects.buffer.created(fake.next_buffer_handle);
    return .success;
}

fn fakeDestroyBuffer(_: VkDevice, buffer: VkBuffer, _: ?*const anyopaque) callconv(.c) void {
    fake.effects.buffer.release(@intFromPtr(buffer));
    fake.buffer_destroys += 1;
}

fn fakeGetBufferMemoryRequirements(
    _: VkDevice,
    _: VkBuffer,
    pReqs: *VkMemoryRequirements,
) callconv(.c) void {
    fake.req_queries += 1;
    pReqs.* = .{
        .size = if (fake.req_size != 0) fake.req_size else fake.last_buffer_size,
        .alignment = fake.req_alignment,
        .memoryTypeBits = fake.req_type_bits,
    };
}

fn fakeAllocateMemory(
    _: VkDevice,
    pAllocateInfo: *const VkMemoryAllocateInfo,
    _: ?*const anyopaque,
    pMemory: *VkDeviceMemory,
) callconv(.c) VkResult {
    fake.effects.memory.attempts += 1;
    fake.mem_allocs += 1;
    fake.last_alloc_size = pAllocateInfo.allocationSize;
    fake.last_alloc_type_index = pAllocateInfo.memoryTypeIndex;
    if (fake.mem_alloc_return != .success) return fake.mem_alloc_return;
    fake.next_memory_handle += 0x10;
    pMemory.* = @ptrFromInt(fake.next_memory_handle);
    fake.effects.memory.created(fake.next_memory_handle);
    return .success;
}

fn fakeFreeMemory(_: VkDevice, memory: VkDeviceMemory, _: ?*const anyopaque) callconv(.c) void {
    fake.effects.memory.release(@intFromPtr(memory));
    fake.mem_frees += 1;
}

fn fakeBindBufferMemory(
    _: VkDevice,
    buffer: VkBuffer,
    memory: VkDeviceMemory,
    memoryOffset: u64,
) callconv(.c) VkResult {
    fake.binds += 1;
    fake.last_bind_buffer = buffer;
    fake.last_bind_memory = memory;
    fake.last_bind_offset = memoryOffset;
    return fake.bind_return;
}

fn fakeMapMemory(
    _: VkDevice,
    _: VkDeviceMemory,
    offset: u64,
    size: u64,
    _: u32,
    ppData: *?*anyopaque,
) callconv(.c) VkResult {
    fake.maps += 1;
    fake.last_map_offset = offset;
    fake.last_map_size = size;
    if (fake.map_return != .success) return fake.map_return;
    if (fake.map_override_ptr) |p| {
        ppData.* = p;
    } else {
        ppData.* = &fake.mapped_memory;
    }
    return .success;
}

fn fakeUnmapMemory(_: VkDevice, _: VkDeviceMemory) callconv(.c) void {
    fake.unmaps += 1;
}

fn fakeFlushMappedMemoryRanges(
    _: VkDevice,
    _: u32,
    _: [*]const VkMappedMemoryRange,
) callconv(.c) VkResult {
    fake.flushes += 1;
    return fake.flush_return;
}

fn fakeInvalidateMappedMemoryRanges(
    _: VkDevice,
    _: u32,
    pRanges: [*]const VkMappedMemoryRange,
) callconv(.c) VkResult {
    fake.invalidates += 1;
    fake.last_invalidate_offset = pRanges[0].offset;
    fake.last_invalidate_size = pRanges[0].size;
    return fake.invalidate_return;
}

fn fakeCreateShaderModule(
    _: VkDevice,
    pCreateInfo: *const driver_mod.VkShaderModuleCreateInfo,
    _: ?*const anyopaque,
    pModule: *driver_mod.VkShaderModule,
) callconv(.c) VkResult {
    fake.effects.shader.attempts += 1;
    fake.shader_module_creates += 1;
    fake.last_shader_code_size = pCreateInfo.codeSize;
    if (fake.shader_module_return != .success) return fake.shader_module_return;
    fake.next_shader_module_handle += 0x10;
    pModule.* = @ptrFromInt(fake.next_shader_module_handle);
    fake.effects.shader.created(fake.next_shader_module_handle);
    return .success;
}
fn fakeDestroyShaderModule(_: VkDevice, handle: driver_mod.VkShaderModule, _: ?*const anyopaque) callconv(.c) void {
    fake.effects.shader.release(@intFromPtr(handle));
    fake.shader_module_destroys += 1;
}

fn fakeCreatePipelineLayout(
    _: VkDevice,
    _: *const driver_mod.VkPipelineLayoutCreateInfo,
    _: ?*const anyopaque,
    pLayout: *driver_mod.VkPipelineLayout,
) callconv(.c) VkResult {
    fake.effects.pipeline_layout.attempts += 1;
    fake.pipeline_layout_creates += 1;
    if (fake.pipeline_layout_return != .success) return fake.pipeline_layout_return;
    fake.next_pipeline_layout_handle += 0x10;
    pLayout.* = @ptrFromInt(fake.next_pipeline_layout_handle);
    fake.effects.pipeline_layout.created(fake.next_pipeline_layout_handle);
    return .success;
}
fn fakeDestroyPipelineLayout(_: VkDevice, handle: driver_mod.VkPipelineLayout, _: ?*const anyopaque) callconv(.c) void {
    fake.effects.pipeline_layout.release(@intFromPtr(handle));
    fake.pipeline_layout_destroys += 1;
}

fn fakeCreateDescriptorSetLayout(
    _: VkDevice,
    pCreateInfo: *const driver_mod.VkDescriptorSetLayoutCreateInfo,
    _: ?*const anyopaque,
    pLayout: *driver_mod.VkDescriptorSetLayout,
) callconv(.c) VkResult {
    fake.effects.descriptor_layout.attempts += 1;
    fake.set_layout_creates += 1;
    fake.last_set_layout_binding_count = pCreateInfo.bindingCount;
    if (fake.set_layout_return != .success) return fake.set_layout_return;
    fake.next_set_layout_handle += 0x10;
    pLayout.* = @ptrFromInt(fake.next_set_layout_handle);
    fake.effects.descriptor_layout.created(fake.next_set_layout_handle);
    return .success;
}
fn fakeDestroyDescriptorSetLayout(_: VkDevice, handle: driver_mod.VkDescriptorSetLayout, _: ?*const anyopaque) callconv(.c) void {
    fake.effects.descriptor_layout.release(@intFromPtr(handle));
    fake.set_layout_destroys += 1;
}

fn fakeCreateComputePipelines(
    _: VkDevice,
    _: driver_mod.VkPipelineCache,
    count: u32,
    _: [*]const driver_mod.VkComputePipelineCreateInfo,
    _: ?*const anyopaque,
    pPipelines: [*]driver_mod.VkPipeline,
) callconv(.c) VkResult {
    fake.pipeline_ledger.raw_attempts += 1;
    fake.compute_pipeline_creates += count;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        fake.next_pipeline_handle += 0x10;
        pPipelines[i] = if (fake.compute_pipeline_return_handle) @ptrFromInt(fake.next_pipeline_handle) else null;
        fake.pipeline_ledger.created(pPipelines[i]);
    }
    return fake.compute_pipeline_return;
}
fn fakeDestroyPipeline(_: VkDevice, pipeline: driver_mod.VkPipeline, _: ?*const anyopaque) callconv(.c) void {
    fake.pipeline_destroys += 1;
    fake.pipeline_ledger.release(pipeline);
}

fn fakeCreateDescriptorPool(
    _: VkDevice,
    pCreateInfo: *const driver_mod.VkDescriptorPoolCreateInfo,
    _: ?*const anyopaque,
    pPool: *driver_mod.VkDescriptorPool,
) callconv(.c) VkResult {
    fake.effects.descriptor_pool.attempts += 1;
    fake.desc_pool_creates += 1;
    fake.last_desc_pool_max_sets = pCreateInfo.maxSets;
    if (fake.desc_pool_return != .success) return fake.desc_pool_return;
    fake.next_desc_pool_handle += 0x10;
    pPool.* = @ptrFromInt(fake.next_desc_pool_handle);
    fake.effects.descriptor_pool.created(fake.next_desc_pool_handle);
    return .success;
}
fn fakeDestroyDescriptorPool(_: VkDevice, handle: driver_mod.VkDescriptorPool, _: ?*const anyopaque) callconv(.c) void {
    fake.effects.descriptor_set.releaseOwned(@intFromPtr(handle));
    fake.effects.descriptor_pool.release(@intFromPtr(handle));
    fake.desc_pool_destroys += 1;
}

fn fakeAllocateDescriptorSets(
    _: VkDevice,
    pInfo: *const driver_mod.VkDescriptorSetAllocateInfo,
    pSets: [*]driver_mod.VkDescriptorSet,
) callconv(.c) VkResult {
    fake.effects.descriptor_set.attempts += 1;
    fake.desc_set_allocs += 1;
    if (fake.desc_set_return != .success) return fake.desc_set_return;
    var i: u32 = 0;
    while (i < pInfo.descriptorSetCount) : (i += 1) {
        fake.next_desc_set_handle += 0x10;
        pSets[i] = @ptrFromInt(fake.next_desc_set_handle);
        fake.effects.descriptor_set.createdOwned(fake.next_desc_set_handle, @intFromPtr(pInfo.descriptorPool));
    }
    return .success;
}
fn fakeFreeDescriptorSets(_: VkDevice, _: driver_mod.VkDescriptorPool, count: u32, sets: [*]const driver_mod.VkDescriptorSet) callconv(.c) VkResult {
    for (sets[0..count]) |set| fake.effects.descriptor_set.release(@intFromPtr(set));
    return .success;
}
fn fakeUpdateDescriptorSets(
    _: VkDevice,
    writeCount: u32,
    _: [*]const driver_mod.VkWriteDescriptorSet,
    _: u32,
    _: ?*const anyopaque,
) callconv(.c) void {
    fake.update_desc_sets_calls += 1;
    fake.last_write_count = writeCount;
}

fn fakeCmdBindPipeline(_: VkCommandBuffer, _: driver_mod.VkPipelineBindPoint, _: driver_mod.VkPipeline) callconv(.c) void {
    fake.cmd_bind_pipelines += 1;
}
fn fakeCmdBindDescriptorSets(_: VkCommandBuffer, _: driver_mod.VkPipelineBindPoint, _: driver_mod.VkPipelineLayout, _: u32, _: u32, _: [*]const driver_mod.VkDescriptorSet, _: u32, _: ?[*]const u32) callconv(.c) void {
    fake.cmd_bind_desc_sets += 1;
}
fn fakeCmdDispatch(_: VkCommandBuffer, x: u32, y: u32, z: u32) callconv(.c) void {
    fake.cmd_dispatches += 1;
    fake.last_dispatch = .{ x, y, z };
}
fn fakeCmdPipelineBarrier(
    _: VkCommandBuffer,
    _: driver_mod.VkPipelineStageFlags,
    dstStageMask: driver_mod.VkPipelineStageFlags,
    _: driver_mod.VkDependencyFlags,
    memoryBarrierCount: u32,
    pMemoryBarriers: ?*const anyopaque,
    _: u32,
    _: ?[*]const VkBufferMemoryBarrier,
    imageMemoryBarrierCount: u32,
    pImageMemoryBarriers: ?[*]const VkImageMemoryBarrier,
) callconv(.c) void {
    if ((dstStageMask & driver_mod.VK_PIPELINE_STAGE_HOST_BIT) != 0 and memoryBarrierCount != 0) {
        const memory: [*]const driver_mod.VkMemoryBarrier = @ptrCast(@alignCast(pMemoryBarriers.?));
        for (memory[0..memoryBarrierCount]) |barrier| {
            if ((barrier.srcAccessMask & driver_mod.VK_ACCESS_MEMORY_WRITE_BIT) == 0) continue;
            if ((barrier.dstAccessMask & driver_mod.VK_ACCESS_HOST_READ_BIT) == 0) continue;
            fake.host_read_barriers += 1;
            fake.host_read_barrier_after_copies = fake.cmd_buffer_copies;
            fake.host_read_barrier_after_submits = fake.submits;
        }
    }
    if (imageMemoryBarrierCount == 0) return;
    const barriers = pImageMemoryBarriers.?;
    var i: u32 = 0;
    while (i < imageMemoryBarrierCount) : (i += 1) {
        const barrier = barriers[i];
        if (fake.cmd_barriers == 0) {
            fake.first_barrier_old_layout = barrier.oldLayout;
            fake.first_barrier_new_layout = barrier.newLayout;
        }
        fake.cmd_barriers += 1;
        fake.last_barrier_old_layout = barrier.oldLayout;
        fake.last_barrier_new_layout = barrier.newLayout;
        fake.last_barrier_image = barrier.image;
    }
}
fn fakeCmdClearColorImage(
    _: VkCommandBuffer,
    image: VkImage,
    imageLayout: VkImageLayout,
    pColor: *const VkClearColorValue,
    _: u32,
    _: [*]const VkImageSubresourceRange,
) callconv(.c) void {
    fake.cmd_clears += 1;
    fake.last_clear_image = image;
    fake.last_clear_layout = imageLayout;
    fake.last_clear_color = pColor.*.float32;
}
fn fakeCmdCopyBuffer(
    _: VkCommandBuffer,
    _: VkBuffer,
    _: VkBuffer,
    _: u32,
    _: [*]const VkBufferCopy,
) callconv(.c) void {
    fake.cmd_buffer_copies += 1;
}
fn fakeCmdCopyBufferToImage(
    _: VkCommandBuffer,
    srcBuffer: VkBuffer,
    dstImage: VkImage,
    dstImageLayout: VkImageLayout,
    regionCount: u32,
    pRegions: [*]const VkBufferImageCopy,
) callconv(.c) void {
    fake.cmd_copies += 1;
    fake.last_copy_src_buffer = srcBuffer;
    fake.last_copy_dst_image = dstImage;
    fake.last_copy_layout = dstImageLayout;
    if (regionCount >= 1) fake.last_copy_extent = pRegions[0].imageExtent;
}
fn fakeCmdCopyImageToBuffer(
    _: VkCommandBuffer,
    srcImage: VkImage,
    srcImageLayout: VkImageLayout,
    dstBuffer: VkBuffer,
    regionCount: u32,
    pRegions: [*]const VkBufferImageCopy,
) callconv(.c) void {
    fake.cmd_image_copies += 1;
    fake.last_copy_src_image = srcImage;
    fake.last_copy_src_layout = srcImageLayout;
    fake.last_copy_dst_buffer = dstBuffer;
    if (regionCount >= 1) fake.last_copy_extent = pRegions[0].imageExtent;
}
fn fakeCmdResetQueryPool(_: VkCommandBuffer, _: VkQueryPool, _: u32, _: u32) callconv(.c) void {
    fake.cmd_reset_query_pools += 1;
}
fn fakeCmdWriteTimestamp(_: VkCommandBuffer, stage: driver_mod.VkPipelineStageFlags, queryPool: VkQueryPool, _: u32) callconv(.c) void {
    fake.cmd_write_timestamps += 1;
    fake.last_timestamp_stage = stage;
    fake.last_timestamp_query_pool = queryPool;
}
fn fakeCmdPushConstants(_: VkCommandBuffer, _: driver_mod.VkPipelineLayout, _: driver_mod.VkShaderStageFlags, offset: u32, size: u32, values: *const anyopaque) callconv(.c) void {
    fake.cmd_push_constants += 1;
    fake.last_push_constant_size = size;
    const bytes: [*]const u8 = @ptrCast(values);
    const copy_len = @min(@as(usize, size), fake.last_push_constant_bytes.len - @as(usize, offset));
    @memcpy(fake.last_push_constant_bytes[offset..][0..copy_len], bytes[0..copy_len]);
}
fn fakeBeginCommandBuffer(_: VkCommandBuffer, _: *const driver_mod.VkCommandBufferBeginInfo) callconv(.c) VkResult {
    fake.cb_begins += 1;
    return .success;
}
fn fakeEndCommandBuffer(_: VkCommandBuffer) callconv(.c) VkResult {
    fake.cb_ends += 1;
    return .success;
}
fn fakeResetCommandBuffer(_: VkCommandBuffer, _: u32) callconv(.c) VkResult {
    fake.cb_resets += 1;
    return fake.cb_reset_return;
}

fn fakeResetDescriptorPool(_: VkDevice, pool: VkDescriptorPool, _: u32) callconv(.c) VkResult {
    fake.desc_pool_resets += 1;
    if (fake.desc_pool_reset_return != .success) return fake.desc_pool_reset_return;
    fake.effects.descriptor_set.releaseOwned(@intFromPtr(pool));
    return .success;
}

fn makeFakeDriver() Driver {
    var drv: Driver = undefined;
    drv.vkGetInstanceProcAddr = fakeGipa;
    drv.vkCreateInstance = fakeCreateInstance;
    drv.vkDestroyInstance = fakeDestroyInstance;
    drv.vkEnumeratePhysicalDevices = fakeEnumPhys;
    drv.vkGetPhysicalDeviceProperties = fakeGetProps;
    drv.vkGetPhysicalDeviceProperties2 = fakeGetProps2;
    drv.vkGetPhysicalDeviceFeatures2 = fakeGetFeatures2;
    drv.vkEnumerateDeviceExtensionProperties = fakeEnumDevExts;
    drv.vkGetPhysicalDeviceQueueFamilyProperties = fakeGetQF;
    drv.vkGetPhysicalDeviceMemoryProperties = fakeGetPhysicalDeviceMemoryProperties;
    drv.vkCreateDevice = fakeCreateDevice;
    drv.vkGetDeviceProcAddr = fakeGdpa;
    drv.vkDestroyDevice = fakeDestroyDevice;
    drv.vkGetDeviceQueue = fakeGetDeviceQueue;
    drv.vkCreateCommandPool = fakeCreateCommandPool;
    drv.vkDestroyCommandPool = fakeDestroyCommandPool;
    drv.vkAllocateCommandBuffers = fakeAllocCommandBuffers;
    drv.vkFreeCommandBuffers = fakeFreeCommandBuffers;
    drv.vkCreateSemaphore = fakeCreateSemaphore;
    drv.vkDestroySemaphore = fakeDestroySemaphore;
    drv.vkCreateQueryPool = fakeCreateQueryPool;
    drv.vkDestroyQueryPool = fakeDestroyQueryPool;
    drv.vkGetQueryPoolResults = fakeGetQueryPoolResults;
    drv.vkGetSemaphoreCounterValue = fakeGetSemaphoreCounterValue;
    drv.vkWaitSemaphores = fakeWaitSemaphores;
    drv.vkSignalSemaphore = fakeSignalSemaphore;
    drv.vkQueueSubmit2 = fakeQueueSubmit2;
    drv.vkDeviceWaitIdle = fakeDeviceWaitIdle;
    drv.vkCreateXlibSurfaceKHR = fakeCreateXlibSurfaceKHR;
    drv.vkDestroySurfaceKHR = fakeDestroySurfaceKHR;
    drv.vkGetPhysicalDeviceSurfaceSupportKHR = fakeGetPhysicalDeviceSurfaceSupportKHR;
    drv.vkGetPhysicalDeviceSurfaceCapabilitiesKHR = fakeGetPhysicalDeviceSurfaceCapabilitiesKHR;
    drv.vkGetPhysicalDeviceSurfaceFormatsKHR = fakeGetPhysicalDeviceSurfaceFormatsKHR;
    drv.vkGetPhysicalDeviceSurfacePresentModesKHR = fakeGetPhysicalDeviceSurfacePresentModesKHR;
    drv.vkCreateSwapchainKHR = fakeCreateSwapchainKHR;
    drv.vkDestroySwapchainKHR = fakeDestroySwapchainKHR;
    drv.vkGetSwapchainImagesKHR = fakeGetSwapchainImagesKHR;
    drv.vkAcquireNextImageKHR = fakeAcquireNextImageKHR;
    drv.vkQueuePresentKHR = fakeQueuePresentKHR;
    drv.vkCreateImageView = fakeCreateImageView;
    drv.vkDestroyImageView = fakeDestroyImageView;

    drv.vkCreateBuffer = fakeCreateBuffer;
    drv.vkDestroyBuffer = fakeDestroyBuffer;
    drv.vkGetBufferMemoryRequirements = fakeGetBufferMemoryRequirements;
    drv.vkAllocateMemory = fakeAllocateMemory;
    drv.vkFreeMemory = fakeFreeMemory;
    drv.vkBindBufferMemory = fakeBindBufferMemory;
    drv.vkMapMemory = fakeMapMemory;
    drv.vkUnmapMemory = fakeUnmapMemory;
    drv.vkFlushMappedMemoryRanges = fakeFlushMappedMemoryRanges;
    drv.vkInvalidateMappedMemoryRanges = fakeInvalidateMappedMemoryRanges;

    drv.vkCreateShaderModule = fakeCreateShaderModule;
    drv.vkDestroyShaderModule = fakeDestroyShaderModule;
    drv.vkCreatePipelineLayout = fakeCreatePipelineLayout;
    drv.vkDestroyPipelineLayout = fakeDestroyPipelineLayout;
    drv.vkCreateDescriptorSetLayout = fakeCreateDescriptorSetLayout;
    drv.vkDestroyDescriptorSetLayout = fakeDestroyDescriptorSetLayout;
    drv.vkCreateComputePipelines = fakeCreateComputePipelines;
    drv.vkDestroyPipeline = fakeDestroyPipeline;
    drv.vkCreateDescriptorPool = fakeCreateDescriptorPool;
    drv.vkDestroyDescriptorPool = fakeDestroyDescriptorPool;
    drv.vkResetDescriptorPool = fakeResetDescriptorPool;
    drv.vkAllocateDescriptorSets = fakeAllocateDescriptorSets;
    drv.vkFreeDescriptorSets = fakeFreeDescriptorSets;
    drv.vkUpdateDescriptorSets = fakeUpdateDescriptorSets;
    drv.vkCmdBindPipeline = fakeCmdBindPipeline;
    drv.vkCmdBindDescriptorSets = fakeCmdBindDescriptorSets;
    drv.vkCmdDispatch = fakeCmdDispatch;
    drv.vkCmdPipelineBarrier = fakeCmdPipelineBarrier;
    drv.vkCmdClearColorImage = fakeCmdClearColorImage;
    drv.vkCmdCopyBuffer = fakeCmdCopyBuffer;
    drv.vkCmdCopyBufferToImage = fakeCmdCopyBufferToImage;
    drv.vkCmdCopyImageToBuffer = fakeCmdCopyImageToBuffer;
    drv.vkCmdResetQueryPool = fakeCmdResetQueryPool;
    drv.vkCmdWriteTimestamp = fakeCmdWriteTimestamp;
    drv.vkCmdPushConstants = fakeCmdPushConstants;
    drv.vkBeginCommandBuffer = fakeBeginCommandBuffer;
    drv.vkEndCommandBuffer = fakeEndCommandBuffer;
    drv.vkResetCommandBuffer = fakeResetCommandBuffer;
    return drv;
}

fn makeFakeRuntime(allocator: std.mem.Allocator) Runtime {
    return .{
        .allocator = allocator,
        ._driver = makeFakeDriver(),
        ._instance = @ptrFromInt(0x1234_0000),
        ._physical_device = @ptrFromInt(0x1234_0100),
        ._logical_device = @ptrFromInt(0x1234_0200),
        ._queue = @ptrFromInt(0x1234_0300),
        ._timestamp_period_ns = 2.5,
        ._queue_timestamp_valid_bits = 64,
        .device = .{
            ._physical = @ptrFromInt(0x1234_0100),
            ._api_version = driver_mod.VK_API_VERSION_1_3,
            ._queue_family_index = 0,
        },
        ._memory = memory_mod.Pool.init(allocator, fake.mem_props, 256),
        ._default_stream_cached = null,
        ._live_streams = .{},
        ._shader_cache = .{},
        ._pipeline_layout_cache = .{},
    };
}

fn deinitDeviceMemoryBlocks(runtime: *Runtime) void {
    runtime._memory.deinit(&runtime._driver, runtime._logical_device);
}

pub const testing = if (builtin.is_test) struct {
    pub const FakeSnapshot = struct {
        submits: u32,
        last_submit_wait_count: u32,
        last_submit_signal_count: u32,
        last_submit_cb_count: u32,
        last_submit_signal_semaphore: VkSemaphore,
        last_submit_signal_value: u64,
        last_submit_wait_semaphores: [max_captured_waits]VkSemaphore,
        last_submit_wait_values: [max_captured_waits]u64,
        last_submit_signal_semaphores: [max_captured_waits]VkSemaphore,
        last_submit_signal_values: [max_captured_waits]u64,
        query_pool_creates: u32,
        query_pool_destroys: u32,
        query_pool_results: u32,
        last_query_type: driver_mod.VkQueryType,
        last_query_count: u32,
        cb_allocs: u32,
        cb_resets: u32,
        desc_set_allocs: u32,
        update_desc_sets_calls: u32,
        last_write_count: u32,
        cb_begins: u32,
        cb_ends: u32,
        cmd_bind_pipelines: u32,
        cmd_bind_desc_sets: u32,
        cmd_dispatches: u32,
        last_dispatch: [3]u32,
        cmd_push_constants: u32,
        cmd_reset_query_pools: u32,
        cmd_write_timestamps: u32,
        last_timestamp_stage: driver_mod.VkPipelineStageFlags,
        last_timestamp_query_pool: VkQueryPool,
        last_push_constant_size: u32,
        last_push_constant_bytes: [128]u8,
        cmd_barriers: u32,
        waits: u32,
        last_wait_value: u64,
        last_wait_semaphore: VkSemaphore,
        first_barrier_old_layout: VkImageLayout,
        first_barrier_new_layout: VkImageLayout,
        last_barrier_old_layout: VkImageLayout,
        last_barrier_new_layout: VkImageLayout,
        last_barrier_image: VkImage,
        cmd_clears: u32,
        last_clear_image: VkImage,
        last_clear_layout: VkImageLayout,
        last_clear_color: [4]f32,
        cmd_copies: u32,
        last_copy_src_buffer: VkBuffer,
        last_copy_dst_image: VkImage,
        last_copy_layout: VkImageLayout,
        last_copy_extent: driver_mod.VkExtent3D,
        pipeline_ledger: PipelineLedger,
        compute_pipeline_creates: u32,
        pipeline_destroys: u32,
        surface_creates: u32,
        surface_destroys: u32,
        swapchain_creates: u32,
        swapchain_destroys: u32,
        acquires: u32,
        presents: u32,
    };

    pub fn rawEffects() RawEffects {
        return fake.effects;
    }

    pub fn resetFake() void {
        fake.reset();
    }

    pub fn fakeRuntime(allocator: std.mem.Allocator) Runtime {
        return makeFakeRuntime(allocator);
    }

    pub fn releaseDefaultStream(runtime: *Runtime) void {
        if (runtime._default_stream_cached) |stream| {
            releaseStreamResources(runtime, stream);
            runtime.allocator.destroy(stream);
            runtime._default_stream_cached = null;
        }
    }

    pub fn deinitMemoryBlocks(runtime: *Runtime) void {
        deinitDeviceMemoryBlocks(runtime);
    }

    pub fn observeFake(runtime: *Runtime, observer: *observation.AllocationObservation) void {
        runtime.observer = observer;
        runtime._memory.observer = observer;
    }

    pub const ObjectFailure = enum {
        command_pool,
        semaphore,
        query_pool,
        shader,
        pipeline_layout,
        descriptor_layout,
        descriptor_pool,
        descriptor_set,
        command_buffer,
        command_reset,
        descriptor_reset,
    };
    pub fn setObjectFailure(point: ObjectFailure) void {
        switch (point) {
            .command_pool => fake.pool_create_return = .error_out_of_device_memory,
            .semaphore => fake.sem_create_return = .error_out_of_device_memory,
            .query_pool => fake.query_pool_create_return = .error_out_of_device_memory,
            .shader => fake.shader_module_return = .error_out_of_device_memory,
            .pipeline_layout => fake.pipeline_layout_return = .error_out_of_device_memory,
            .descriptor_layout => fake.set_layout_return = .error_out_of_device_memory,
            .descriptor_pool => fake.desc_pool_return = .error_out_of_device_memory,
            .descriptor_set => fake.desc_set_return = .error_out_of_device_memory,
            .command_buffer => fake.cb_alloc_return = .error_out_of_device_memory,
            .command_reset => fake.cb_reset_return = .error_device_lost,
            .descriptor_reset => fake.desc_pool_reset_return = .error_device_lost,
        }
    }

    pub const AllocationFailure = enum { buffer, memory, map, bind, flush, invalidate };
    pub fn setAllocationFailure(point: AllocationFailure) void {
        switch (point) {
            .buffer => fake.buffer_create_return = .error_out_of_device_memory,
            .memory => fake.mem_alloc_return = .error_out_of_device_memory,
            .map => fake.map_return = .error_memory_map_failed,
            .bind => fake.bind_return = .error_out_of_device_memory,
            .flush => fake.flush_return = .error_device_lost,
            .invalidate => fake.invalidate_return = .error_device_lost,
        }
    }

    pub fn setStagedMemory() void {
        fake.mem_props.memoryTypeCount = 2;
        fake.mem_props.memoryTypes[1] = .{ .propertyFlags = driver_mod.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, .heapIndex = 0 };
    }

    pub fn setNonCoherentMemory() void {
        fake.mem_props.memoryTypes[0].propertyFlags = driver_mod.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
    }

    pub fn setWaitReturn(value: VkResult) void {
        fake.wait_return = value;
    }

    pub fn setPipelineReturn(value: VkResult, handle: bool) void {
        fake.compute_pipeline_return = value;
        fake.compute_pipeline_return_handle = handle;
    }

    pub fn setQueueSubmitReturn(value: VkResult) void {
        fake.queue_submit_return = value;
    }

    pub fn setQueryResults(values: []const u64) void {
        fake.query_result_values = @as([fake.query_result_values.len]u64, @splat(0));
        const count = @min(values.len, fake.query_result_values.len);
        @memcpy(fake.query_result_values[0..count], values[0..count]);
        fake.query_result_index = 0;
    }

    pub fn setCounterValue(value: u64) void {
        fake.counter_value = value;
    }

    pub fn snapshot() FakeSnapshot {
        return .{
            .submits = fake.submits,
            .last_submit_wait_count = fake.last_submit_wait_count,
            .last_submit_signal_count = fake.last_submit_signal_count,
            .last_submit_cb_count = fake.last_submit_cb_count,
            .last_submit_signal_semaphore = fake.last_submit_signal_semaphore,
            .last_submit_signal_value = fake.last_submit_signal_value,
            .last_submit_wait_semaphores = fake.last_submit_wait_semaphores,
            .last_submit_wait_values = fake.last_submit_wait_values,
            .last_submit_signal_semaphores = fake.last_submit_signal_semaphores,
            .last_submit_signal_values = fake.last_submit_signal_values,
            .query_pool_creates = fake.query_pool_creates,
            .query_pool_destroys = fake.query_pool_destroys,
            .query_pool_results = fake.query_pool_results,
            .last_query_type = fake.last_query_type,
            .last_query_count = fake.last_query_count,
            .cb_allocs = fake.cb_allocs,
            .cb_resets = fake.cb_resets,
            .desc_set_allocs = fake.desc_set_allocs,
            .update_desc_sets_calls = fake.update_desc_sets_calls,
            .last_write_count = fake.last_write_count,
            .cb_begins = fake.cb_begins,
            .cb_ends = fake.cb_ends,
            .cmd_bind_pipelines = fake.cmd_bind_pipelines,
            .cmd_bind_desc_sets = fake.cmd_bind_desc_sets,
            .cmd_dispatches = fake.cmd_dispatches,
            .cmd_push_constants = fake.cmd_push_constants,
            .cmd_reset_query_pools = fake.cmd_reset_query_pools,
            .cmd_write_timestamps = fake.cmd_write_timestamps,
            .last_timestamp_stage = fake.last_timestamp_stage,
            .last_timestamp_query_pool = fake.last_timestamp_query_pool,
            .last_push_constant_size = fake.last_push_constant_size,
            .last_push_constant_bytes = fake.last_push_constant_bytes,
            .cmd_barriers = fake.cmd_barriers,
            .waits = fake.waits,
            .last_wait_value = fake.last_wait_value,
            .last_wait_semaphore = fake.last_wait_semaphore,
            .first_barrier_old_layout = fake.first_barrier_old_layout,
            .first_barrier_new_layout = fake.first_barrier_new_layout,
            .last_barrier_old_layout = fake.last_barrier_old_layout,
            .last_barrier_new_layout = fake.last_barrier_new_layout,
            .last_barrier_image = fake.last_barrier_image,
            .cmd_clears = fake.cmd_clears,
            .last_clear_image = fake.last_clear_image,
            .last_clear_layout = fake.last_clear_layout,
            .last_clear_color = fake.last_clear_color,
            .cmd_copies = fake.cmd_copies,
            .last_copy_src_buffer = fake.last_copy_src_buffer,
            .last_copy_dst_image = fake.last_copy_dst_image,
            .last_copy_layout = fake.last_copy_layout,
            .last_copy_extent = fake.last_copy_extent,
            .pipeline_ledger = fake.pipeline_ledger,
            .compute_pipeline_creates = fake.compute_pipeline_creates,
            .pipeline_destroys = fake.pipeline_destroys,
            .last_dispatch = fake.last_dispatch,
            .surface_creates = fake.surface_creates,
            .surface_destroys = fake.surface_destroys,
            .swapchain_creates = fake.swapchain_creates,
            .swapchain_destroys = fake.swapchain_destroys,
            .acquires = fake.acquires,
            .presents = fake.presents,
        };
    }
} else struct {};

fn makeTestSurface(rt: *Runtime, usage: VkImageUsageFlags) Error!Surface {
    return rt.createXlibSurface(.{
        .display = 0x5151_0000,
        .window = 0x6161,
        .extent = .{ .width = 16, .height = 8 },
        .format = driver_mod.VK_FORMAT_B8G8R8A8_UNORM,
        .color_space = driver_mod.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        .present_mode = driver_mod.VK_PRESENT_MODE_FIFO_KHR,
        .usage = usage,
        .min_image_count = 2,
    });
}

const drawn_usage = driver_mod.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | driver_mod.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
const read_usage = drawn_usage | driver_mod.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;

fn releaseFakeDefaultStream(rt: *Runtime) void {
    const stream = rt._default_stream_cached orelse return;
    releaseStreamResources(rt, stream);
    rt.allocator.destroy(stream);
    rt._default_stream_cached = null;
}
