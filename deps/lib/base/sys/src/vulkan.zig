//! Vulkan loader bindings: ABI types, the dynamically loaded entry points,
//! and `VkResult` mapped to typed errors.

const std = @import("std");
const capabilities = @import("capabilities.zig");
const dynamic = @import("dynamic.zig");

pub const required_capabilities = capabilities.host(&.{ .allocator, .dynamic_loading });

const log = std.log.scoped(.vulkan_driver);

pub const VkInstance = ?*opaque {};
pub const VkPhysicalDevice = ?*opaque {};
pub const VkDevice = ?*opaque {};
pub const VkQueue = ?*opaque {};
pub const VkSemaphore = ?*opaque {};
pub const VkCommandPool = ?*opaque {};
pub const VkCommandBuffer = ?*opaque {};
pub const VkFence = ?*opaque {};
pub const VkShaderModule = ?*opaque {};
pub const VkPipeline = ?*opaque {};
pub const VkPipelineLayout = ?*opaque {};
pub const VkPipelineCache = ?*opaque {};
pub const VkDescriptorSet = ?*opaque {};
pub const VkDescriptorSetLayout = ?*opaque {};
pub const VkDescriptorPool = ?*opaque {};
pub const VkBuffer = ?*opaque {};
pub const VkDeviceMemory = ?*opaque {};
pub const VkQueryPool = u64;
pub const VkSurfaceKHR = u64;
pub const VkSwapchainKHR = u64;
pub const VkImage = u64;
pub const VkImageView = u64;
pub const VkSampler = u64;
pub const VkRenderPass = u64;
pub const VkDisplay = ?*opaque {};
pub const VkWindow = u64;
pub const VkVisualID = u64;

pub const PFN_vkVoidFunction = ?*const fn () callconv(.c) void;

pub const VkBool32 = u32;
pub const VK_TRUE: VkBool32 = 1;
pub const VK_FALSE: VkBool32 = 0;

pub const VkStructureType = u32;
pub const VK_STRUCTURE_TYPE_APPLICATION_INFO: VkStructureType = 0;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: VkStructureType = 1;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: VkStructureType = 2;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO: VkStructureType = 3;
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: VkStructureType = 5;
pub const VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE: VkStructureType = 6;
pub const VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO: VkStructureType = 14;
pub const VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO: VkStructureType = 15;
pub const VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO: VkStructureType = 9;
pub const VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO: VkStructureType = 11;
pub const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO: VkStructureType = 12;
pub const VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO: VkStructureType = 16;
pub const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO: VkStructureType = 18;
pub const VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO: VkStructureType = 19;
pub const VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO: VkStructureType = 20;
pub const VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO: VkStructureType = 22;
pub const VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO: VkStructureType = 23;
pub const VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO: VkStructureType = 24;
pub const VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO: VkStructureType = 25;
pub const VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO: VkStructureType = 26;
pub const VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO: VkStructureType = 27;
pub const VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO: VkStructureType = 28;
pub const VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO: VkStructureType = 29;
pub const VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO: VkStructureType = 30;
pub const VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO: VkStructureType = 31;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO: VkStructureType = 32;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO: VkStructureType = 33;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO: VkStructureType = 34;
pub const VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET: VkStructureType = 35;
pub const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO: VkStructureType = 39;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO: VkStructureType = 40;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO: VkStructureType = 42;
pub const VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER: VkStructureType = 44;
pub const VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER: VkStructureType = 45;
pub const VK_STRUCTURE_TYPE_MEMORY_BARRIER: VkStructureType = 46;
pub const VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR: VkStructureType = 1000001000;
pub const VK_STRUCTURE_TYPE_PRESENT_INFO_KHR: VkStructureType = 1000001001;
pub const VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR: VkStructureType = 1000004000;
pub const VK_STRUCTURE_TYPE_RENDERING_INFO: VkStructureType = 1000044000;
pub const VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO: VkStructureType = 1000044001;
pub const VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO: VkStructureType = 1000044002;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES: VkStructureType = 53;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2: VkStructureType = 1000059000;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2: VkStructureType = 1000059001;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES: VkStructureType = 1000083000;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES: VkStructureType = 1000094000;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_8BIT_STORAGE_FEATURES: VkStructureType = 1000177000;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES: VkStructureType = 1000207000;
pub const VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO: VkStructureType = 1000207002;
pub const VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO: VkStructureType = 1000207003;
pub const VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO: VkStructureType = 1000207004;
pub const VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO: VkStructureType = 1000207005;
pub const VK_STRUCTURE_TYPE_SUBMIT_INFO_2: VkStructureType = 1000314004;
pub const VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO: VkStructureType = 1000314005;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO: VkStructureType = 1000314006;
pub const VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2: VkStructureType = 1000059002;
pub const VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO: VkStructureType = 1000072001;
pub const VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO: VkStructureType = 1000072002;
pub const VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR: VkStructureType = 1000074002;
pub const VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO: VkStructureType = 1000077000;
pub const VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR: VkStructureType = 1000079001;
pub const VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO: VkStructureType = 1000127001;
pub const VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT: VkStructureType = 1000158000;
pub const VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT: VkStructureType = 1000158003;
pub const VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT: VkStructureType = 1000158005;
pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT: VkStructureType = 1000353000;

pub const VkSemaphoreType = u32;
pub const VK_SEMAPHORE_TYPE_BINARY: VkSemaphoreType = 0;
pub const VK_SEMAPHORE_TYPE_TIMELINE: VkSemaphoreType = 1;

pub const VkQueueFlags = u32;
pub const VK_QUEUE_GRAPHICS_BIT: VkQueueFlags = 0x00000001;
pub const VK_QUEUE_COMPUTE_BIT: VkQueueFlags = 0x00000002;
pub const VK_QUEUE_TRANSFER_BIT: VkQueueFlags = 0x00000004;
pub const VK_QUEUE_SPARSE_BINDING_BIT: VkQueueFlags = 0x00000008;

pub const VkCommandPoolCreateFlags = u32;
pub const VK_COMMAND_POOL_CREATE_TRANSIENT_BIT: VkCommandPoolCreateFlags = 0x00000001;
pub const VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT: VkCommandPoolCreateFlags = 0x00000002;

pub const VkDescriptorPoolResetFlags = u32;

pub const VkCommandBufferLevel = u32;
pub const VK_COMMAND_BUFFER_LEVEL_PRIMARY: VkCommandBufferLevel = 0;
pub const VK_COMMAND_BUFFER_LEVEL_SECONDARY: VkCommandBufferLevel = 1;

pub const VkCommandBufferUsageFlags = u32;
pub const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: VkCommandBufferUsageFlags = 0x00000001;
pub const VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT: VkCommandBufferUsageFlags = 0x00000002;
pub const VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT: VkCommandBufferUsageFlags = 0x00000004;

pub const VkBufferUsageFlags = u32;
pub const VK_BUFFER_USAGE_TRANSFER_SRC_BIT: VkBufferUsageFlags = 0x00000001;
pub const VK_BUFFER_USAGE_TRANSFER_DST_BIT: VkBufferUsageFlags = 0x00000002;
pub const VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT: VkBufferUsageFlags = 0x00000010;
pub const VK_BUFFER_USAGE_STORAGE_BUFFER_BIT: VkBufferUsageFlags = 0x00000020;
pub const VK_BUFFER_USAGE_INDEX_BUFFER_BIT: VkBufferUsageFlags = 0x00000040;
pub const VK_BUFFER_USAGE_VERTEX_BUFFER_BIT: VkBufferUsageFlags = 0x00000080;

pub const VkImageUsageFlags = u32;
pub const VK_IMAGE_USAGE_TRANSFER_SRC_BIT: VkImageUsageFlags = 0x00000001;
pub const VK_IMAGE_USAGE_TRANSFER_DST_BIT: VkImageUsageFlags = 0x00000002;
pub const VK_IMAGE_USAGE_SAMPLED_BIT: VkImageUsageFlags = 0x00000004;
pub const VK_IMAGE_USAGE_STORAGE_BIT: VkImageUsageFlags = 0x00000008;
pub const VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT: VkImageUsageFlags = 0x00000010;
pub const VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT: VkImageUsageFlags = 0x00000020;

pub const VkImageLayout = u32;
pub const VK_IMAGE_LAYOUT_UNDEFINED: VkImageLayout = 0;
pub const VK_IMAGE_LAYOUT_GENERAL: VkImageLayout = 1;
pub const VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL: VkImageLayout = 2;
pub const VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL: VkImageLayout = 5;
pub const VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL: VkImageLayout = 6;
pub const VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL: VkImageLayout = 7;
pub const VK_IMAGE_LAYOUT_PRESENT_SRC_KHR: VkImageLayout = 1000001002;
pub const VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL: VkImageLayout = 1000241000;

pub const VkAccessFlags = u32;
pub const VK_ACCESS_INDEX_READ_BIT: VkAccessFlags = 0x00000002;
pub const VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT: VkAccessFlags = 0x00000004;
pub const VK_ACCESS_UNIFORM_READ_BIT: VkAccessFlags = 0x00000008;
pub const VK_ACCESS_SHADER_READ_BIT: VkAccessFlags = 0x00000020;
pub const VK_ACCESS_SHADER_WRITE_BIT: VkAccessFlags = 0x00000040;
pub const VK_ACCESS_COLOR_ATTACHMENT_READ_BIT: VkAccessFlags = 0x00000080;
pub const VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT: VkAccessFlags = 0x00000100;
pub const VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT: VkAccessFlags = 0x00000200;
pub const VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT: VkAccessFlags = 0x00000400;
pub const VK_ACCESS_TRANSFER_READ_BIT: VkAccessFlags = 0x00000800;
pub const VK_ACCESS_TRANSFER_WRITE_BIT: VkAccessFlags = 0x00001000;
pub const VK_ACCESS_HOST_READ_BIT: VkAccessFlags = 0x00002000;
pub const VK_ACCESS_HOST_WRITE_BIT: VkAccessFlags = 0x00004000;
pub const VK_ACCESS_MEMORY_READ_BIT: VkAccessFlags = 0x00008000;
pub const VK_ACCESS_MEMORY_WRITE_BIT: VkAccessFlags = 0x00010000;

pub const VkPipelineStageFlags = u32;
pub const VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT: VkPipelineStageFlags = 0x00000001;
pub const VK_PIPELINE_STAGE_VERTEX_INPUT_BIT: VkPipelineStageFlags = 0x00000004;
pub const VK_PIPELINE_STAGE_VERTEX_SHADER_BIT: VkPipelineStageFlags = 0x00000008;
pub const VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT: VkPipelineStageFlags = 0x00000080;
pub const VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT: VkPipelineStageFlags = 0x00000100;
pub const VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT: VkPipelineStageFlags = 0x00000200;
pub const VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT: VkPipelineStageFlags = 0x00000400;
pub const VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT: VkPipelineStageFlags = 0x00000800;
pub const VK_PIPELINE_STAGE_TRANSFER_BIT: VkPipelineStageFlags = 0x00001000;
pub const VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT: VkPipelineStageFlags = 0x00002000;
pub const VK_PIPELINE_STAGE_HOST_BIT: VkPipelineStageFlags = 0x00004000;
pub const VK_PIPELINE_STAGE_ALL_COMMANDS_BIT: VkPipelineStageFlags = 0x00010000;

pub const VkDependencyFlags = u32;

pub const VkQueryType = u32;
pub const VK_QUERY_TYPE_TIMESTAMP: VkQueryType = 2;

pub const VkQueryResultFlags = u32;
pub const VK_QUERY_RESULT_64_BIT: VkQueryResultFlags = 0x00000001;

pub const VkImageAspectFlags = u32;
pub const VK_IMAGE_ASPECT_COLOR_BIT: VkImageAspectFlags = 0x00000001;
pub const VK_IMAGE_ASPECT_DEPTH_BIT: VkImageAspectFlags = 0x00000002;
pub const VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT: VkImageAspectFlags = 0x00000080;
pub const VK_IMAGE_ASPECT_MEMORY_PLANE_1_BIT_EXT: VkImageAspectFlags = 0x00000100;
pub const VK_IMAGE_ASPECT_MEMORY_PLANE_2_BIT_EXT: VkImageAspectFlags = 0x00000200;
pub const VK_IMAGE_ASPECT_MEMORY_PLANE_3_BIT_EXT: VkImageAspectFlags = 0x00000400;

pub const VK_QUEUE_FAMILY_IGNORED: u32 = std.math.maxInt(u32);
/// `~2U`: the queue family of every agent outside this Vulkan instance, such as a compositor.
pub const VK_QUEUE_FAMILY_FOREIGN_EXT: u32 = std.math.maxInt(u32) - 2;

pub const VkExternalMemoryHandleTypeFlags = u32;
pub const VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT: VkExternalMemoryHandleTypeFlags = 0x00000200;
pub const VkExternalSemaphoreHandleTypeFlags = u32;
pub const VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT: VkExternalSemaphoreHandleTypeFlags = 0x00000010;

pub const VkSharingMode = u32;
pub const VK_SHARING_MODE_EXCLUSIVE: VkSharingMode = 0;
pub const VK_SHARING_MODE_CONCURRENT: VkSharingMode = 1;

pub const VkMemoryPropertyFlags = u32;
pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT: VkMemoryPropertyFlags = 0x00000001;
pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: VkMemoryPropertyFlags = 0x00000002;
pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT: VkMemoryPropertyFlags = 0x00000004;
pub const VK_MEMORY_PROPERTY_HOST_CACHED_BIT: VkMemoryPropertyFlags = 0x00000008;
pub const VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT: VkMemoryPropertyFlags = 0x00000010;

pub const VkDescriptorType = u32;
pub const VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER: VkDescriptorType = 1;
pub const VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER: VkDescriptorType = 6;
pub const VK_DESCRIPTOR_TYPE_STORAGE_BUFFER: VkDescriptorType = 7;

pub const VkShaderStageFlags = u32;
pub const VK_SHADER_STAGE_VERTEX_BIT: VkShaderStageFlags = 0x00000001;
pub const VK_SHADER_STAGE_FRAGMENT_BIT: VkShaderStageFlags = 0x00000010;
pub const VK_SHADER_STAGE_COMPUTE_BIT: VkShaderStageFlags = 0x00000020;
pub const VK_SHADER_STAGE_ALL: VkShaderStageFlags = 0x7FFFFFFF;

pub const VkSubgroupFeatureFlags = u32;
pub const VK_SUBGROUP_FEATURE_BASIC_BIT: VkSubgroupFeatureFlags = 0x00000001;
pub const VK_SUBGROUP_FEATURE_VOTE_BIT: VkSubgroupFeatureFlags = 0x00000002;
pub const VK_SUBGROUP_FEATURE_ARITHMETIC_BIT: VkSubgroupFeatureFlags = 0x00000004;
pub const VK_SUBGROUP_FEATURE_BALLOT_BIT: VkSubgroupFeatureFlags = 0x00000008;
pub const VK_SUBGROUP_FEATURE_SHUFFLE_BIT: VkSubgroupFeatureFlags = 0x00000010;
pub const VK_SUBGROUP_FEATURE_SHUFFLE_RELATIVE_BIT: VkSubgroupFeatureFlags = 0x00000020;

pub const VkPipelineBindPoint = u32;
pub const VK_PIPELINE_BIND_POINT_GRAPHICS: VkPipelineBindPoint = 0;
pub const VK_PIPELINE_BIND_POINT_COMPUTE: VkPipelineBindPoint = 1;

pub const VkDescriptorPoolCreateFlags = u32;
pub const VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT: VkDescriptorPoolCreateFlags = 0x00000001;

pub const VK_MAX_EXTENSION_NAME_SIZE: usize = 256;
pub const VK_MAX_PHYSICAL_DEVICE_NAME_SIZE: usize = 256;
pub const VK_UUID_SIZE: usize = 16;
pub const VK_MAX_MEMORY_TYPES: usize = 32;
pub const VK_MAX_MEMORY_HEAPS: usize = 16;

pub const VK_WHOLE_TIMEOUT: u64 = std.math.maxInt(u64);

pub const VK_WHOLE_SIZE: u64 = std.math.maxInt(u64);

pub const VK_API_VERSION_1_0: u32 = (0 << 22) | (0 << 12) | 0;
pub const VK_API_VERSION_1_1: u32 = (1 << 22) | (1 << 12) | 0;
pub const VK_API_VERSION_1_2: u32 = (1 << 22) | (2 << 12) | 0;
pub const VK_API_VERSION_1_3: u32 = (1 << 22) | (3 << 12) | 0;

pub const VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME = "VK_KHR_timeline_semaphore";
pub const VK_KHR_SURFACE_EXTENSION_NAME = "VK_KHR_surface";
pub const VK_KHR_XLIB_SURFACE_EXTENSION_NAME = "VK_KHR_xlib_surface";
pub const VK_KHR_SWAPCHAIN_EXTENSION_NAME = "VK_KHR_swapchain";
pub const VK_KHR_16BIT_STORAGE_EXTENSION_NAME = "VK_KHR_16bit_storage";
pub const VK_KHR_8BIT_STORAGE_EXTENSION_NAME = "VK_KHR_8bit_storage";
pub const VK_KHR_SHADER_FLOAT16_INT8_EXTENSION_NAME = "VK_KHR_shader_float16_int8";
pub const VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME = "VK_EXT_image_drm_format_modifier";
pub const VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME = "VK_KHR_external_memory_fd";
pub const VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME = "VK_EXT_external_memory_dma_buf";
pub const VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME = "VK_KHR_external_semaphore_fd";
pub const VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME = "VK_EXT_queue_family_foreign";
pub const VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME = "VK_EXT_physical_device_drm";

pub const VkFormat = u32;
pub const VK_FORMAT_UNDEFINED: VkFormat = 0;
pub const VK_FORMAT_R8G8B8A8_UNORM: VkFormat = 37;
pub const VK_FORMAT_R8G8B8A8_SRGB: VkFormat = 43;
pub const VK_FORMAT_B8G8R8A8_UNORM: VkFormat = 44;
pub const VK_FORMAT_B8G8R8A8_SRGB: VkFormat = 50;
pub const VK_FORMAT_R32_UINT: VkFormat = 98;
pub const VK_FORMAT_R32_SFLOAT: VkFormat = 100;
pub const VK_FORMAT_R32G32_UINT: VkFormat = 101;
pub const VK_FORMAT_R32G32_SFLOAT: VkFormat = 103;
pub const VK_FORMAT_R32G32B32_SFLOAT: VkFormat = 106;
pub const VK_FORMAT_R32G32B32A32_UINT: VkFormat = 107;
pub const VK_FORMAT_R32G32B32A32_SFLOAT: VkFormat = 109;
pub const VK_FORMAT_D32_SFLOAT: VkFormat = 126;

pub const VkFormatFeatureFlags = u32;
pub const VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT: VkFormatFeatureFlags = 0x00000001;
pub const VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT: VkFormatFeatureFlags = 0x00000080;
pub const VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT: VkFormatFeatureFlags = 0x00000100;
pub const VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT: VkFormatFeatureFlags = 0x00000200;
pub const VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT: VkFormatFeatureFlags = 0x00001000;
pub const VK_FORMAT_FEATURE_TRANSFER_SRC_BIT: VkFormatFeatureFlags = 0x00004000;
pub const VK_FORMAT_FEATURE_TRANSFER_DST_BIT: VkFormatFeatureFlags = 0x00008000;

pub const VkImageType = u32;
pub const VK_IMAGE_TYPE_2D: VkImageType = 1;

pub const VkImageViewType = u32;
pub const VK_IMAGE_VIEW_TYPE_2D: VkImageViewType = 1;

pub const VkImageTiling = u32;
pub const VK_IMAGE_TILING_OPTIMAL: VkImageTiling = 0;
pub const VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT: VkImageTiling = 1000158000;

pub const VK_SAMPLE_COUNT_1_BIT: VkSampleCountFlags = 0x00000001;

pub const VkComponentSwizzle = u32;
pub const VK_COMPONENT_SWIZZLE_IDENTITY: VkComponentSwizzle = 0;

pub const VkFilter = u32;
pub const VK_FILTER_NEAREST: VkFilter = 0;
pub const VK_FILTER_LINEAR: VkFilter = 1;

pub const VkSamplerMipmapMode = u32;
pub const VK_SAMPLER_MIPMAP_MODE_NEAREST: VkSamplerMipmapMode = 0;

pub const VkSamplerAddressMode = u32;
pub const VK_SAMPLER_ADDRESS_MODE_REPEAT: VkSamplerAddressMode = 0;
pub const VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE: VkSamplerAddressMode = 2;

pub const VkBorderColor = u32;
pub const VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK: VkBorderColor = 0;

pub const VkCompareOp = u32;
pub const VK_COMPARE_OP_NEVER: VkCompareOp = 0;
pub const VK_COMPARE_OP_LESS: VkCompareOp = 1;
pub const VK_COMPARE_OP_EQUAL: VkCompareOp = 2;
pub const VK_COMPARE_OP_LESS_OR_EQUAL: VkCompareOp = 3;
pub const VK_COMPARE_OP_GREATER: VkCompareOp = 4;
pub const VK_COMPARE_OP_NOT_EQUAL: VkCompareOp = 5;
pub const VK_COMPARE_OP_GREATER_OR_EQUAL: VkCompareOp = 6;
pub const VK_COMPARE_OP_ALWAYS: VkCompareOp = 7;

pub const VkVertexInputRate = u32;
pub const VK_VERTEX_INPUT_RATE_VERTEX: VkVertexInputRate = 0;
pub const VK_VERTEX_INPUT_RATE_INSTANCE: VkVertexInputRate = 1;

pub const VkPrimitiveTopology = u32;
pub const VK_PRIMITIVE_TOPOLOGY_LINE_LIST: VkPrimitiveTopology = 1;
pub const VK_PRIMITIVE_TOPOLOGY_LINE_STRIP: VkPrimitiveTopology = 2;
pub const VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST: VkPrimitiveTopology = 3;
pub const VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP: VkPrimitiveTopology = 4;

pub const VkPolygonMode = u32;
pub const VK_POLYGON_MODE_FILL: VkPolygonMode = 0;

pub const VkCullModeFlags = u32;
pub const VK_CULL_MODE_NONE: VkCullModeFlags = 0;

pub const VkFrontFace = u32;
pub const VK_FRONT_FACE_COUNTER_CLOCKWISE: VkFrontFace = 0;
pub const VK_FRONT_FACE_CLOCKWISE: VkFrontFace = 1;

pub const VkBlendFactor = u32;
pub const VK_BLEND_FACTOR_ZERO: VkBlendFactor = 0;
pub const VK_BLEND_FACTOR_ONE: VkBlendFactor = 1;
pub const VK_BLEND_FACTOR_SRC_ALPHA: VkBlendFactor = 6;
pub const VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA: VkBlendFactor = 7;

pub const VkBlendOp = u32;
pub const VK_BLEND_OP_ADD: VkBlendOp = 0;

pub const VkColorComponentFlags = u32;
pub const VK_COLOR_COMPONENT_R_BIT: VkColorComponentFlags = 0x00000001;
pub const VK_COLOR_COMPONENT_G_BIT: VkColorComponentFlags = 0x00000002;
pub const VK_COLOR_COMPONENT_B_BIT: VkColorComponentFlags = 0x00000004;
pub const VK_COLOR_COMPONENT_A_BIT: VkColorComponentFlags = 0x00000008;

pub const VkDynamicState = u32;
pub const VK_DYNAMIC_STATE_VIEWPORT: VkDynamicState = 0;
pub const VK_DYNAMIC_STATE_SCISSOR: VkDynamicState = 1;

pub const VkAttachmentLoadOp = u32;
pub const VK_ATTACHMENT_LOAD_OP_LOAD: VkAttachmentLoadOp = 0;
pub const VK_ATTACHMENT_LOAD_OP_CLEAR: VkAttachmentLoadOp = 1;

pub const VkAttachmentStoreOp = u32;
pub const VK_ATTACHMENT_STORE_OP_STORE: VkAttachmentStoreOp = 0;

pub const VkResolveModeFlags = u32;
pub const VK_RESOLVE_MODE_NONE: VkResolveModeFlags = 0;

pub const VkIndexType = u32;
pub const VK_INDEX_TYPE_UINT16: VkIndexType = 0;
pub const VK_INDEX_TYPE_UINT32: VkIndexType = 1;

pub const VkColorSpaceKHR = u32;
pub const VK_COLOR_SPACE_SRGB_NONLINEAR_KHR: VkColorSpaceKHR = 0;

pub const VkPresentModeKHR = u32;
pub const VK_PRESENT_MODE_IMMEDIATE_KHR: VkPresentModeKHR = 0;
pub const VK_PRESENT_MODE_MAILBOX_KHR: VkPresentModeKHR = 1;
pub const VK_PRESENT_MODE_FIFO_KHR: VkPresentModeKHR = 2;

pub const VkSurfaceTransformFlagsKHR = u32;
pub const VkSurfaceTransformFlagBitsKHR = u32;
pub const VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR: VkSurfaceTransformFlagBitsKHR = 0x00000001;
pub const VK_SURFACE_TRANSFORM_INHERIT_BIT_KHR: VkSurfaceTransformFlagBitsKHR = 0x00000100;

pub const VkCompositeAlphaFlagsKHR = u32;
pub const VkCompositeAlphaFlagBitsKHR = u32;
pub const VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR: VkCompositeAlphaFlagBitsKHR = 0x00000001;
pub const VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR: VkCompositeAlphaFlagBitsKHR = 0x00000002;
pub const VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR: VkCompositeAlphaFlagBitsKHR = 0x00000004;
pub const VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR: VkCompositeAlphaFlagBitsKHR = 0x00000008;

pub const VkResult = enum(c_int) {
    success = 0,
    not_ready = 1,
    timeout = 2,
    event_set = 3,
    event_reset = 4,
    incomplete = 5,
    suboptimal_khr = 1000001003,
    error_out_of_host_memory = -1,
    error_out_of_device_memory = -2,
    error_initialization_failed = -3,
    error_device_lost = -4,
    error_memory_map_failed = -5,
    error_layer_not_present = -6,
    error_extension_not_present = -7,
    error_feature_not_present = -8,
    error_incompatible_driver = -9,
    error_too_many_objects = -10,
    error_format_not_supported = -11,
    error_fragmented_pool = -12,
    error_unknown = -13,
    error_out_of_pool_memory = -1000069000,
    error_surface_lost_khr = -1000000000,
    error_native_window_in_use_khr = -1000000001,
    error_out_of_date_khr = -1000001004,
    _,
};

pub const Error = error{
    DriverUnavailable,
    SymbolMissing,
    TimelineSemaphoreUnavailable,
    DeviceLost,
    OutOfHostMemory,
    OutOfDeviceMemory,
    InitializationFailed,
    MemoryMapFailed,
    LayerNotPresent,
    ExtensionNotPresent,
    FeatureNotPresent,
    IncompatibleDriver,
    TooManyObjects,
    FormatNotSupported,
    FragmentedPool,
    OutOfPoolMemory,
    VulkanUnknown,
    SurfaceLost,
    SurfaceOutOfDate,
    NativeWindowInUse,
    NoDevice,
    InvalidDevice,
    StreamPoisoned,
};

pub const VkApplicationInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    pApplicationName: ?[*:0]const u8,
    applicationVersion: u32,
    pEngineName: ?[*:0]const u8,
    engineVersion: u32,
    apiVersion: u32,
};

pub const VkInstanceCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    pApplicationInfo: ?*const VkApplicationInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const [*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8,
};

pub const VkDeviceQueueCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    queueFamilyIndex: u32,
    queueCount: u32,
    pQueuePriorities: [*]const f32,
};

pub const VkDeviceCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    queueCreateInfoCount: u32,
    pQueueCreateInfos: [*]const VkDeviceQueueCreateInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const [*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8,
    pEnabledFeatures: ?*const anyopaque,
};

pub const VkSemaphoreCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
};

pub const VkQueryPoolCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    queryType: VkQueryType,
    queryCount: u32,
    pipelineStatistics: u32,
};

pub const VkSemaphoreTypeCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    semaphoreType: VkSemaphoreType,
    initialValue: u64,
};

pub const VkSemaphoreWaitInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    semaphoreCount: u32,
    pSemaphores: [*]const VkSemaphore,
    pValues: [*]const u64,
};

pub const VkSemaphoreSignalInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    semaphore: VkSemaphore,
    value: u64,
};

pub const VkCommandPoolCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkCommandPoolCreateFlags,
    queueFamilyIndex: u32,
};

pub const VkCommandBufferAllocateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    commandPool: VkCommandPool,
    level: VkCommandBufferLevel,
    commandBufferCount: u32,
};

pub const VkSemaphoreSubmitInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    semaphore: VkSemaphore,
    value: u64,
    stageMask: u64,
    deviceIndex: u32,
};

pub const VkCommandBufferSubmitInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    commandBuffer: VkCommandBuffer,
    deviceMask: u32,
};

pub const VkSubmitInfo2 = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    waitSemaphoreInfoCount: u32,
    pWaitSemaphoreInfos: ?[*]const VkSemaphoreSubmitInfo,
    commandBufferInfoCount: u32,
    pCommandBufferInfos: ?[*]const VkCommandBufferSubmitInfo,
    signalSemaphoreInfoCount: u32,
    pSignalSemaphoreInfos: ?[*]const VkSemaphoreSubmitInfo,
};

pub const VkExtent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};

pub const VkOffset3D = extern struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const VkExtent2D = extern struct {
    width: u32,
    height: u32,
};

pub const VkImageSubresourceRange = extern struct {
    aspectMask: VkImageAspectFlags,
    baseMipLevel: u32,
    levelCount: u32,
    baseArrayLayer: u32,
    layerCount: u32,
};

pub const VkImageSubresourceLayers = extern struct {
    aspectMask: VkImageAspectFlags,
    mipLevel: u32,
    baseArrayLayer: u32,
    layerCount: u32,
};

pub const VkMemoryBarrier = extern struct {
    sType: VkStructureType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
    pNext: ?*const anyopaque = null,
    srcAccessMask: VkAccessFlags,
    dstAccessMask: VkAccessFlags,
};

pub const VkImageMemoryBarrier = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    srcAccessMask: VkAccessFlags,
    dstAccessMask: VkAccessFlags,
    oldLayout: VkImageLayout,
    newLayout: VkImageLayout,
    srcQueueFamilyIndex: u32,
    dstQueueFamilyIndex: u32,
    image: VkImage,
    subresourceRange: VkImageSubresourceRange,
};

pub const VkBufferMemoryBarrier = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    srcAccessMask: VkAccessFlags,
    dstAccessMask: VkAccessFlags,
    srcQueueFamilyIndex: u32,
    dstQueueFamilyIndex: u32,
    buffer: VkBuffer,
    offset: u64,
    size: u64,
};

pub const VkBufferCopy = extern struct {
    srcOffset: u64,
    dstOffset: u64,
    size: u64,
};

pub const VkBufferImageCopy = extern struct {
    bufferOffset: u64,
    bufferRowLength: u32,
    bufferImageHeight: u32,
    imageSubresource: VkImageSubresourceLayers,
    imageOffset: VkOffset3D,
    imageExtent: VkExtent3D,
};

pub const VkClearColorValue = extern union {
    float32: [4]f32,
    int32: [4]i32,
    uint32: [4]u32,
};

pub const VkSurfaceCapabilitiesKHR = extern struct {
    minImageCount: u32,
    maxImageCount: u32,
    currentExtent: VkExtent2D,
    minImageExtent: VkExtent2D,
    maxImageExtent: VkExtent2D,
    maxImageArrayLayers: u32,
    supportedTransforms: VkSurfaceTransformFlagsKHR,
    currentTransform: VkSurfaceTransformFlagBitsKHR,
    supportedCompositeAlpha: VkCompositeAlphaFlagsKHR,
    supportedUsageFlags: VkImageUsageFlags,
};

pub const VkSurfaceFormatKHR = extern struct {
    format: VkFormat,
    colorSpace: VkColorSpaceKHR,
};

pub const VkXlibSurfaceCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    dpy: VkDisplay,
    window: VkWindow,
};

pub const VkSwapchainCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    surface: VkSurfaceKHR,
    minImageCount: u32,
    imageFormat: VkFormat,
    imageColorSpace: VkColorSpaceKHR,
    imageExtent: VkExtent2D,
    imageArrayLayers: u32,
    imageUsage: VkImageUsageFlags,
    imageSharingMode: VkSharingMode,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
    preTransform: VkSurfaceTransformFlagBitsKHR,
    compositeAlpha: VkCompositeAlphaFlagBitsKHR,
    presentMode: VkPresentModeKHR,
    clipped: VkBool32,
    oldSwapchain: VkSwapchainKHR,
};

pub const VkPresentInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: ?[*]const VkSemaphore,
    swapchainCount: u32,
    pSwapchains: [*]const VkSwapchainKHR,
    pImageIndices: [*]const u32,
    pResults: ?[*]VkResult,
};

pub const VkQueueFamilyProperties = extern struct {
    queueFlags: VkQueueFlags,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: VkExtent3D,
};

pub const VkExtensionProperties = extern struct {
    extensionName: [VK_MAX_EXTENSION_NAME_SIZE]u8,
    specVersion: u32,

    pub fn name(self: *const VkExtensionProperties) []const u8 {
        return std.mem.sliceTo(self.extensionName[0..], 0);
    }
};

pub const VkPhysicalDeviceFeatures = extern struct {
    robustBufferAccess: VkBool32,
    fullDrawIndexUint32: VkBool32,
    imageCubeArray: VkBool32,
    independentBlend: VkBool32,
    geometryShader: VkBool32,
    tessellationShader: VkBool32,
    sampleRateShading: VkBool32,
    dualSrcBlend: VkBool32,
    logicOp: VkBool32,
    multiDrawIndirect: VkBool32,
    drawIndirectFirstInstance: VkBool32,
    depthClamp: VkBool32,
    depthBiasClamp: VkBool32,
    fillModeNonSolid: VkBool32,
    depthBounds: VkBool32,
    wideLines: VkBool32,
    largePoints: VkBool32,
    alphaToOne: VkBool32,
    multiViewport: VkBool32,
    samplerAnisotropy: VkBool32,
    textureCompressionETC2: VkBool32,
    textureCompressionASTC_LDR: VkBool32,
    textureCompressionBC: VkBool32,
    occlusionQueryPrecise: VkBool32,
    pipelineStatisticsQuery: VkBool32,
    vertexPipelineStoresAndAtomics: VkBool32,
    fragmentStoresAndAtomics: VkBool32,
    shaderTessellationAndGeometryPointSize: VkBool32,
    shaderImageGatherExtended: VkBool32,
    shaderStorageImageExtendedFormats: VkBool32,
    shaderStorageImageMultisample: VkBool32,
    shaderStorageImageReadWithoutFormat: VkBool32,
    shaderStorageImageWriteWithoutFormat: VkBool32,
    shaderUniformBufferArrayDynamicIndexing: VkBool32,
    shaderSampledImageArrayDynamicIndexing: VkBool32,
    shaderStorageBufferArrayDynamicIndexing: VkBool32,
    shaderStorageImageArrayDynamicIndexing: VkBool32,
    shaderClipDistance: VkBool32,
    shaderCullDistance: VkBool32,
    shaderFloat64: VkBool32,
    shaderInt64: VkBool32,
    shaderInt16: VkBool32,
    shaderResourceResidency: VkBool32,
    shaderResourceMinLod: VkBool32,
    sparseBinding: VkBool32,
    sparseResidencyBuffer: VkBool32,
    sparseResidencyImage2D: VkBool32,
    sparseResidencyImage3D: VkBool32,
    sparseResidency2Samples: VkBool32,
    sparseResidency4Samples: VkBool32,
    sparseResidency8Samples: VkBool32,
    sparseResidency16Samples: VkBool32,
    sparseResidencyAliased: VkBool32,
    variableMultisampleRate: VkBool32,
    inheritedQueries: VkBool32,
};

pub const VkPhysicalDeviceFeatures2 = extern struct {
    sType: VkStructureType,
    pNext: ?*anyopaque,
    features: VkPhysicalDeviceFeatures,
};

pub const VkPhysicalDevice16BitStorageFeatures = extern struct {
    sType: VkStructureType,
    pNext: ?*anyopaque,
    storageBuffer16BitAccess: VkBool32,
    uniformAndStorageBuffer16BitAccess: VkBool32,
    storagePushConstant16: VkBool32,
    storageInputOutput16: VkBool32,
};

pub const VkPhysicalDevice8BitStorageFeatures = extern struct {
    sType: VkStructureType,
    pNext: ?*anyopaque,
    storageBuffer8BitAccess: VkBool32,
    uniformAndStorageBuffer8BitAccess: VkBool32,
    storagePushConstant8: VkBool32,
};

pub const VkPhysicalDeviceTimelineSemaphoreFeatures = extern struct {
    sType: VkStructureType,
    pNext: ?*anyopaque,
    timelineSemaphore: VkBool32,
};

pub const VkSampleCountFlags = u32;

pub const VkPhysicalDeviceLimits = extern struct {
    maxImageDimension1D: u32,
    maxImageDimension2D: u32,
    maxImageDimension3D: u32,
    maxImageDimensionCube: u32,
    maxImageArrayLayers: u32,
    maxTexelBufferElements: u32,
    maxUniformBufferRange: u32,
    maxStorageBufferRange: u32,
    maxPushConstantsSize: u32,
    maxMemoryAllocationCount: u32,
    maxSamplerAllocationCount: u32,
    bufferImageGranularity: u64,
    sparseAddressSpaceSize: u64,
    maxBoundDescriptorSets: u32,
    maxPerStageDescriptorSamplers: u32,
    maxPerStageDescriptorUniformBuffers: u32,
    maxPerStageDescriptorStorageBuffers: u32,
    maxPerStageDescriptorSampledImages: u32,
    maxPerStageDescriptorStorageImages: u32,
    maxPerStageDescriptorInputAttachments: u32,
    maxPerStageResources: u32,
    maxDescriptorSetSamplers: u32,
    maxDescriptorSetUniformBuffers: u32,
    maxDescriptorSetUniformBuffersDynamic: u32,
    maxDescriptorSetStorageBuffers: u32,
    maxDescriptorSetStorageBuffersDynamic: u32,
    maxDescriptorSetSampledImages: u32,
    maxDescriptorSetStorageImages: u32,
    maxDescriptorSetInputAttachments: u32,
    maxVertexInputAttributes: u32,
    maxVertexInputBindings: u32,
    maxVertexInputAttributeOffset: u32,
    maxVertexInputBindingStride: u32,
    maxVertexOutputComponents: u32,
    maxTessellationGenerationLevel: u32,
    maxTessellationPatchSize: u32,
    maxTessellationControlPerVertexInputComponents: u32,
    maxTessellationControlPerVertexOutputComponents: u32,
    maxTessellationControlPerPatchOutputComponents: u32,
    maxTessellationControlTotalOutputComponents: u32,
    maxTessellationEvaluationInputComponents: u32,
    maxTessellationEvaluationOutputComponents: u32,
    maxGeometryShaderInvocations: u32,
    maxGeometryInputComponents: u32,
    maxGeometryOutputComponents: u32,
    maxGeometryOutputVertices: u32,
    maxGeometryTotalOutputComponents: u32,
    maxFragmentInputComponents: u32,
    maxFragmentOutputAttachments: u32,
    maxFragmentDualSrcAttachments: u32,
    maxFragmentCombinedOutputResources: u32,
    maxComputeSharedMemorySize: u32,
    maxComputeWorkGroupCount: [3]u32,
    maxComputeWorkGroupInvocations: u32,
    maxComputeWorkGroupSize: [3]u32,
    subPixelPrecisionBits: u32,
    subTexelPrecisionBits: u32,
    mipmapPrecisionBits: u32,
    maxDrawIndexedIndexValue: u32,
    maxDrawIndirectCount: u32,
    maxSamplerLodBias: f32,
    maxSamplerAnisotropy: f32,
    maxViewports: u32,
    maxViewportDimensions: [2]u32,
    viewportBoundsRange: [2]f32,
    viewportSubPixelBits: u32,
    minMemoryMapAlignment: usize,
    minTexelBufferOffsetAlignment: u64,
    minUniformBufferOffsetAlignment: u64,
    minStorageBufferOffsetAlignment: u64,
    minTexelOffset: i32,
    maxTexelOffset: u32,
    minTexelGatherOffset: i32,
    maxTexelGatherOffset: u32,
    minInterpolationOffset: f32,
    maxInterpolationOffset: f32,
    subPixelInterpolationOffsetBits: u32,
    maxFramebufferWidth: u32,
    maxFramebufferHeight: u32,
    maxFramebufferLayers: u32,
    framebufferColorSampleCounts: VkSampleCountFlags,
    framebufferDepthSampleCounts: VkSampleCountFlags,
    framebufferStencilSampleCounts: VkSampleCountFlags,
    framebufferNoAttachmentsSampleCounts: VkSampleCountFlags,
    maxColorAttachments: u32,
    sampledImageColorSampleCounts: VkSampleCountFlags,
    sampledImageIntegerSampleCounts: VkSampleCountFlags,
    sampledImageDepthSampleCounts: VkSampleCountFlags,
    sampledImageStencilSampleCounts: VkSampleCountFlags,
    storageImageSampleCounts: VkSampleCountFlags,
    maxSampleMaskWords: u32,
    timestampComputeAndGraphics: VkBool32,
    timestampPeriod: f32,
    maxClipDistances: u32,
    maxCullDistances: u32,
    maxCombinedClipAndCullDistances: u32,
    discreteQueuePriorities: u32,
    pointSizeRange: [2]f32,
    lineWidthRange: [2]f32,
    pointSizeGranularity: f32,
    lineWidthGranularity: f32,
    strictLines: VkBool32,
    standardSampleLocations: VkBool32,
    optimalBufferCopyOffsetAlignment: u64,
    optimalBufferCopyRowPitchAlignment: u64,
    nonCoherentAtomSize: u64,
};

pub const VkPhysicalDeviceSparseProperties = extern struct {
    residencyStandard2DBlockShape: VkBool32,
    residencyStandard2DMultisampleBlockShape: VkBool32,
    residencyStandard3DBlockShape: VkBool32,
    residencyAlignedMipSize: VkBool32,
    residencyNonResidentStrict: VkBool32,
};

pub const VkPhysicalDeviceProperties = extern struct {
    apiVersion: u32,
    driverVersion: u32,
    vendorID: u32,
    deviceID: u32,
    deviceType: u32,
    deviceName: [VK_MAX_PHYSICAL_DEVICE_NAME_SIZE]u8,
    pipelineCacheUUID: [VK_UUID_SIZE]u8,
    limits: VkPhysicalDeviceLimits,
    sparseProperties: VkPhysicalDeviceSparseProperties,
};

pub const VkPhysicalDeviceProperties2 = extern struct {
    sType: VkStructureType,
    pNext: ?*anyopaque,
    properties: VkPhysicalDeviceProperties,
};

pub const VkPhysicalDeviceSubgroupProperties = extern struct {
    sType: VkStructureType,
    pNext: ?*anyopaque,
    subgroupSize: u32,
    supportedStages: VkShaderStageFlags,
    supportedOperations: VkSubgroupFeatureFlags,
    quadOperationsInAllStages: VkBool32,
};

pub const VkMemoryType = extern struct {
    propertyFlags: VkMemoryPropertyFlags,
    heapIndex: u32,
};

pub const VkMemoryHeap = extern struct {
    size: u64,
    flags: u32,
    _pad: u32 = 0,
};

pub const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [VK_MAX_MEMORY_TYPES]VkMemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [VK_MAX_MEMORY_HEAPS]VkMemoryHeap align(8),
};

pub const VkMemoryRequirements = extern struct {
    size: u64,
    alignment: u64,
    memoryTypeBits: u32,
    _pad: u32 = 0,
};

pub const VkMemoryAllocateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    allocationSize: u64,
    memoryTypeIndex: u32,
    _pad: u32 = 0,
};

pub const VkMappedMemoryRange = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    memory: VkDeviceMemory,
    offset: u64,
    size: u64,
};

pub const VkBufferCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    _pad_flags: u32 = 0,
    size: u64,
    usage: VkBufferUsageFlags,
    sharingMode: VkSharingMode,
    queueFamilyIndexCount: u32,
    _pad_qfi: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32,
};

pub const VkShaderModuleCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    _pad: u32 = 0,
    codeSize: usize,
    pCode: [*]const u32,
};

pub const VkPushConstantRange = extern struct {
    stageFlags: VkShaderStageFlags,
    offset: u32,
    size: u32,
};

pub const VkPipelineLayoutCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    setLayoutCount: u32,
    pSetLayouts: ?[*]const VkDescriptorSetLayout,
    pushConstantRangeCount: u32,
    _pad_pcrc: u32 = 0,
    pPushConstantRanges: ?[*]const VkPushConstantRange,
};

pub const VkDescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: VkDescriptorType,
    descriptorCount: u32,
    stageFlags: VkShaderStageFlags,
    pImmutableSamplers: ?*const anyopaque,
};

pub const VkDescriptorSetLayoutCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    bindingCount: u32,
    pBindings: ?[*]const VkDescriptorSetLayoutBinding,
};

pub const VkSpecializationMapEntry = extern struct {
    constantID: u32,
    offset: u32,
    size: usize,
};

pub const VkSpecializationInfo = extern struct {
    mapEntryCount: u32,
    _pad: u32 = 0,
    pMapEntries: ?[*]const VkSpecializationMapEntry,
    dataSize: usize,
    pData: ?*const anyopaque,
};

pub const VkPipelineShaderStageCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    stage: VkShaderStageFlags,
    module: VkShaderModule,
    pName: [*:0]const u8,
    pSpecializationInfo: ?*const VkSpecializationInfo,
};

pub const VkComputePipelineCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    _pad_flags: u32 = 0,
    stage: VkPipelineShaderStageCreateInfo,
    layout: VkPipelineLayout,
    basePipelineHandle: VkPipeline,
    basePipelineIndex: i32,
    _pad_bpi: u32 = 0,
};

pub const VkDescriptorPoolSize = extern struct {
    type: VkDescriptorType,
    descriptorCount: u32,
};

pub const VkDescriptorPoolCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkDescriptorPoolCreateFlags,
    maxSets: u32,
    poolSizeCount: u32,
    _pad_psc: u32 = 0,
    pPoolSizes: ?[*]const VkDescriptorPoolSize,
};

pub const VkDescriptorSetAllocateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    descriptorPool: VkDescriptorPool,
    descriptorSetCount: u32,
    _pad_dsc: u32 = 0,
    pSetLayouts: ?[*]const VkDescriptorSetLayout,
};

pub const VkDescriptorBufferInfo = extern struct {
    buffer: VkBuffer,
    offset: u64,
    range: u64,
};

pub const VkWriteDescriptorSet = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    dstSet: VkDescriptorSet,
    dstBinding: u32,
    dstArrayElement: u32,
    descriptorCount: u32,
    descriptorType: VkDescriptorType,
    pImageInfo: ?*const anyopaque,
    pBufferInfo: ?[*]const VkDescriptorBufferInfo,
    pTexelBufferView: ?*const anyopaque,
};

pub const VkCommandBufferBeginInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkCommandBufferUsageFlags,
    _pad: u32 = 0,
    pInheritanceInfo: ?*const anyopaque,
};

pub const VkPhysicalDeviceVulkan13Features = extern struct {
    sType: VkStructureType,
    pNext: ?*anyopaque,
    robustImageAccess: VkBool32 = VK_FALSE,
    inlineUniformBlock: VkBool32 = VK_FALSE,
    descriptorBindingInlineUniformBlockUpdateAfterBind: VkBool32 = VK_FALSE,
    pipelineCreationCacheControl: VkBool32 = VK_FALSE,
    privateData: VkBool32 = VK_FALSE,
    shaderDemoteToHelperInvocation: VkBool32 = VK_FALSE,
    shaderTerminateInvocation: VkBool32 = VK_FALSE,
    subgroupSizeControl: VkBool32 = VK_FALSE,
    computeFullSubgroups: VkBool32 = VK_FALSE,
    synchronization2: VkBool32 = VK_FALSE,
    textureCompressionASTC_HDR: VkBool32 = VK_FALSE,
    shaderZeroInitializeWorkgroupMemory: VkBool32 = VK_FALSE,
    dynamicRendering: VkBool32 = VK_FALSE,
    shaderIntegerDotProduct: VkBool32 = VK_FALSE,
    maintenance4: VkBool32 = VK_FALSE,
};

pub const VkFormatProperties = extern struct {
    linearTilingFeatures: VkFormatFeatureFlags,
    optimalTilingFeatures: VkFormatFeatureFlags,
    bufferFeatures: VkFormatFeatureFlags,
};

pub const VkFormatProperties2 = extern struct {
    sType: VkStructureType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
    pNext: ?*anyopaque = null,
    formatProperties: VkFormatProperties = std.mem.zeroes(VkFormatProperties),
};

pub const VkDrmFormatModifierPropertiesEXT = extern struct {
    drmFormatModifier: u64,
    drmFormatModifierPlaneCount: u32,
    drmFormatModifierTilingFeatures: VkFormatFeatureFlags,
};

pub const VkDrmFormatModifierPropertiesListEXT = extern struct {
    sType: VkStructureType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
    pNext: ?*anyopaque = null,
    drmFormatModifierCount: u32 = 0,
    pDrmFormatModifierProperties: ?[*]VkDrmFormatModifierPropertiesEXT = null,
};

pub const VkImageDrmFormatModifierListCreateInfoEXT = extern struct {
    sType: VkStructureType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
    pNext: ?*const anyopaque = null,
    drmFormatModifierCount: u32,
    pDrmFormatModifiers: [*]const u64,
};

pub const VkImageDrmFormatModifierPropertiesEXT = extern struct {
    sType: VkStructureType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT,
    pNext: ?*anyopaque = null,
    drmFormatModifier: u64 = 0,
};

pub const VkExternalMemoryImageCreateInfo = extern struct {
    sType: VkStructureType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    handleTypes: VkExternalMemoryHandleTypeFlags,
};

pub const VkExportMemoryAllocateInfo = extern struct {
    sType: VkStructureType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    handleTypes: VkExternalMemoryHandleTypeFlags,
};

pub const VkMemoryDedicatedAllocateInfo = extern struct {
    sType: VkStructureType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
    pNext: ?*const anyopaque = null,
    image: VkImage,
    buffer: VkBuffer = null,
};

pub const VkMemoryGetFdInfoKHR = extern struct {
    sType: VkStructureType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
    pNext: ?*const anyopaque = null,
    memory: VkDeviceMemory,
    handleType: VkExternalMemoryHandleTypeFlags,
};

pub const VkExportSemaphoreCreateInfo = extern struct {
    sType: VkStructureType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
    pNext: ?*const anyopaque = null,
    handleTypes: VkExternalSemaphoreHandleTypeFlags,
};

pub const VkSemaphoreGetFdInfoKHR = extern struct {
    sType: VkStructureType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
    pNext: ?*const anyopaque = null,
    semaphore: VkSemaphore,
    handleType: VkExternalSemaphoreHandleTypeFlags,
};

pub const VkPhysicalDeviceDrmPropertiesEXT = extern struct {
    sType: VkStructureType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT,
    pNext: ?*anyopaque = null,
    hasPrimary: VkBool32 = VK_FALSE,
    hasRender: VkBool32 = VK_FALSE,
    primaryMajor: i64 = 0,
    primaryMinor: i64 = 0,
    renderMajor: i64 = 0,
    renderMinor: i64 = 0,
};

pub const VkImageSubresource = extern struct {
    aspectMask: VkImageAspectFlags,
    mipLevel: u32 = 0,
    arrayLayer: u32 = 0,
};

pub const VkSubresourceLayout = extern struct {
    offset: u64 = 0,
    size: u64 = 0,
    rowPitch: u64 = 0,
    arrayPitch: u64 = 0,
    depthPitch: u64 = 0,
};

pub const VkImageCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    imageType: VkImageType,
    format: VkFormat,
    extent: VkExtent3D,
    mipLevels: u32,
    arrayLayers: u32,
    samples: VkSampleCountFlags,
    tiling: VkImageTiling,
    usage: VkImageUsageFlags,
    sharingMode: VkSharingMode,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
    initialLayout: VkImageLayout,
};

pub const VkComponentMapping = extern struct {
    r: VkComponentSwizzle = VK_COMPONENT_SWIZZLE_IDENTITY,
    g: VkComponentSwizzle = VK_COMPONENT_SWIZZLE_IDENTITY,
    b: VkComponentSwizzle = VK_COMPONENT_SWIZZLE_IDENTITY,
    a: VkComponentSwizzle = VK_COMPONENT_SWIZZLE_IDENTITY,
};

pub const VkImageViewCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    image: VkImage,
    viewType: VkImageViewType,
    format: VkFormat,
    components: VkComponentMapping,
    subresourceRange: VkImageSubresourceRange,
};

pub const VkSamplerCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    magFilter: VkFilter,
    minFilter: VkFilter,
    mipmapMode: VkSamplerMipmapMode,
    addressModeU: VkSamplerAddressMode,
    addressModeV: VkSamplerAddressMode,
    addressModeW: VkSamplerAddressMode,
    mipLodBias: f32,
    anisotropyEnable: VkBool32,
    maxAnisotropy: f32,
    compareEnable: VkBool32,
    compareOp: VkCompareOp,
    minLod: f32,
    maxLod: f32,
    borderColor: VkBorderColor,
    unnormalizedCoordinates: VkBool32,
};

pub const VkDescriptorImageInfo = extern struct {
    sampler: VkSampler,
    imageView: VkImageView,
    imageLayout: VkImageLayout,
};

pub const VkVertexInputBindingDescription = extern struct {
    binding: u32,
    stride: u32,
    inputRate: VkVertexInputRate,
};

pub const VkVertexInputAttributeDescription = extern struct {
    location: u32,
    binding: u32,
    format: VkFormat,
    offset: u32,
};

pub const VkPipelineVertexInputStateCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    vertexBindingDescriptionCount: u32,
    pVertexBindingDescriptions: ?[*]const VkVertexInputBindingDescription,
    vertexAttributeDescriptionCount: u32,
    pVertexAttributeDescriptions: ?[*]const VkVertexInputAttributeDescription,
};

pub const VkPipelineInputAssemblyStateCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    topology: VkPrimitiveTopology,
    primitiveRestartEnable: VkBool32,
};

pub const VkViewport = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    minDepth: f32,
    maxDepth: f32,
};

pub const VkOffset2D = extern struct {
    x: i32,
    y: i32,
};

pub const VkRect2D = extern struct {
    offset: VkOffset2D,
    extent: VkExtent2D,
};

pub const VkPipelineViewportStateCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    viewportCount: u32,
    pViewports: ?[*]const VkViewport,
    scissorCount: u32,
    pScissors: ?[*]const VkRect2D,
};

pub const VkPipelineRasterizationStateCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    depthClampEnable: VkBool32,
    rasterizerDiscardEnable: VkBool32,
    polygonMode: VkPolygonMode,
    cullMode: VkCullModeFlags,
    frontFace: VkFrontFace,
    depthBiasEnable: VkBool32,
    depthBiasConstantFactor: f32,
    depthBiasClamp: f32,
    depthBiasSlopeFactor: f32,
    lineWidth: f32,
};

pub const VkPipelineMultisampleStateCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    rasterizationSamples: VkSampleCountFlags,
    sampleShadingEnable: VkBool32,
    minSampleShading: f32,
    pSampleMask: ?[*]const u32,
    alphaToCoverageEnable: VkBool32,
    alphaToOneEnable: VkBool32,
};

pub const VkStencilOpState = extern struct {
    failOp: u32 = 0,
    passOp: u32 = 0,
    depthFailOp: u32 = 0,
    compareOp: VkCompareOp = VK_COMPARE_OP_NEVER,
    compareMask: u32 = 0,
    writeMask: u32 = 0,
    reference: u32 = 0,
};

pub const VkPipelineDepthStencilStateCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    depthTestEnable: VkBool32,
    depthWriteEnable: VkBool32,
    depthCompareOp: VkCompareOp,
    depthBoundsTestEnable: VkBool32,
    stencilTestEnable: VkBool32,
    front: VkStencilOpState,
    back: VkStencilOpState,
    minDepthBounds: f32,
    maxDepthBounds: f32,
};

pub const VkPipelineColorBlendAttachmentState = extern struct {
    blendEnable: VkBool32,
    srcColorBlendFactor: VkBlendFactor,
    dstColorBlendFactor: VkBlendFactor,
    colorBlendOp: VkBlendOp,
    srcAlphaBlendFactor: VkBlendFactor,
    dstAlphaBlendFactor: VkBlendFactor,
    alphaBlendOp: VkBlendOp,
    colorWriteMask: VkColorComponentFlags,
};

pub const VkPipelineColorBlendStateCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    logicOpEnable: VkBool32,
    logicOp: u32,
    attachmentCount: u32,
    pAttachments: ?[*]const VkPipelineColorBlendAttachmentState,
    blendConstants: [4]f32,
};

pub const VkPipelineDynamicStateCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    dynamicStateCount: u32,
    pDynamicStates: ?[*]const VkDynamicState,
};

pub const VkPipelineRenderingCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    viewMask: u32,
    colorAttachmentCount: u32,
    pColorAttachmentFormats: ?[*]const VkFormat,
    depthAttachmentFormat: VkFormat,
    stencilAttachmentFormat: VkFormat,
};

pub const VkGraphicsPipelineCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    stageCount: u32,
    pStages: [*]const VkPipelineShaderStageCreateInfo,
    pVertexInputState: ?*const VkPipelineVertexInputStateCreateInfo,
    pInputAssemblyState: ?*const VkPipelineInputAssemblyStateCreateInfo,
    pTessellationState: ?*const anyopaque,
    pViewportState: ?*const VkPipelineViewportStateCreateInfo,
    pRasterizationState: ?*const VkPipelineRasterizationStateCreateInfo,
    pMultisampleState: ?*const VkPipelineMultisampleStateCreateInfo,
    pDepthStencilState: ?*const VkPipelineDepthStencilStateCreateInfo,
    pColorBlendState: ?*const VkPipelineColorBlendStateCreateInfo,
    pDynamicState: ?*const VkPipelineDynamicStateCreateInfo,
    layout: VkPipelineLayout,
    renderPass: VkRenderPass,
    subpass: u32,
    basePipelineHandle: VkPipeline,
    basePipelineIndex: i32,
};

pub const VkClearDepthStencilValue = extern struct {
    depth: f32,
    stencil: u32,
};

pub const VkClearValue = extern union {
    color: VkClearColorValue,
    depthStencil: VkClearDepthStencilValue,
};

pub const VkRenderingAttachmentInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    imageView: VkImageView,
    imageLayout: VkImageLayout,
    resolveMode: VkResolveModeFlags,
    resolveImageView: VkImageView,
    resolveImageLayout: VkImageLayout,
    loadOp: VkAttachmentLoadOp,
    storeOp: VkAttachmentStoreOp,
    clearValue: VkClearValue,
};

pub const VkRenderingInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: u32,
    renderArea: VkRect2D,
    layerCount: u32,
    viewMask: u32,
    colorAttachmentCount: u32,
    pColorAttachments: ?[*]const VkRenderingAttachmentInfo,
    pDepthAttachment: ?*const VkRenderingAttachmentInfo,
    pStencilAttachment: ?*const VkRenderingAttachmentInfo,
};

pub fn platformSupported() bool {
    return dynamic.hasHostCandidate(dynamic.vulkanLoaderCandidates());
}

fn openLoaderLibrary() Error!dynamic.Library {
    return dynamic.openVulkanLoader() catch return error.DriverUnavailable;
}

const ResultDiagnostic = enum {
    none,
    unexpected_positive,
    unmapped,
};

fn resultDiagnostic(r: VkResult) ResultDiagnostic {
    return switch (r) {
        .success,
        .error_out_of_host_memory,
        .error_out_of_device_memory,
        .error_initialization_failed,
        .error_device_lost,
        .error_memory_map_failed,
        .error_layer_not_present,
        .error_extension_not_present,
        .error_feature_not_present,
        .error_incompatible_driver,
        .error_too_many_objects,
        .error_format_not_supported,
        .error_fragmented_pool,
        .error_unknown,
        .error_out_of_pool_memory,
        .error_surface_lost_khr,
        .error_native_window_in_use_khr,
        .error_out_of_date_khr,
        .suboptimal_khr,
        => .none,
        .not_ready,
        .timeout,
        .event_set,
        .event_reset,
        .incomplete,
        => .unexpected_positive,
        _ => .unmapped,
    };
}

fn mapResultQuiet(r: VkResult) Error!void {
    if (r == .success) return;

    return switch (r) {
        .success => unreachable,
        .error_out_of_host_memory => Error.OutOfHostMemory,
        .error_out_of_device_memory => Error.OutOfDeviceMemory,
        .error_initialization_failed => Error.InitializationFailed,
        .error_device_lost => Error.DeviceLost,
        .error_memory_map_failed => Error.MemoryMapFailed,
        .error_layer_not_present => Error.LayerNotPresent,
        .error_extension_not_present => Error.ExtensionNotPresent,
        .error_feature_not_present => Error.FeatureNotPresent,
        .error_incompatible_driver => Error.IncompatibleDriver,
        .error_too_many_objects => Error.TooManyObjects,
        .error_format_not_supported => Error.FormatNotSupported,
        .error_fragmented_pool => Error.FragmentedPool,
        .error_out_of_pool_memory => Error.OutOfPoolMemory,
        .error_unknown => Error.VulkanUnknown,
        .error_surface_lost_khr => Error.SurfaceLost,
        .error_native_window_in_use_khr => Error.NativeWindowInUse,
        .error_out_of_date_khr, .suboptimal_khr => Error.SurfaceOutOfDate,
        .not_ready, .timeout, .event_set, .event_reset, .incomplete => Error.VulkanUnknown,
        _ => Error.VulkanUnknown,
    };
}

pub const Driver = struct {
    lib: dynamic.Library,

    vkGetInstanceProcAddr: *const fn (instance: VkInstance, pName: [*:0]const u8) callconv(.c) PFN_vkVoidFunction,
    vkCreateInstance: *const fn (pCreateInfo: *const VkInstanceCreateInfo, pAllocator: ?*const anyopaque, pInstance: *VkInstance) callconv(.c) VkResult,

    vkDestroyInstance: *const fn (instance: VkInstance, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkEnumeratePhysicalDevices: *const fn (instance: VkInstance, pCount: *u32, pDevices: ?[*]VkPhysicalDevice) callconv(.c) VkResult,
    vkGetPhysicalDeviceProperties: *const fn (physicalDevice: VkPhysicalDevice, pProperties: *VkPhysicalDeviceProperties) callconv(.c) void,
    vkGetPhysicalDeviceProperties2: *const fn (physicalDevice: VkPhysicalDevice, pProperties: *VkPhysicalDeviceProperties2) callconv(.c) void,
    vkGetPhysicalDeviceFeatures2: *const fn (physicalDevice: VkPhysicalDevice, pFeatures: *VkPhysicalDeviceFeatures2) callconv(.c) void,
    vkEnumerateDeviceExtensionProperties: *const fn (physicalDevice: VkPhysicalDevice, pLayerName: ?[*:0]const u8, pCount: *u32, pProperties: ?[*]VkExtensionProperties) callconv(.c) VkResult,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (physicalDevice: VkPhysicalDevice, pCount: *u32, pProperties: ?[*]VkQueueFamilyProperties) callconv(.c) void,
    vkGetPhysicalDeviceMemoryProperties: *const fn (physicalDevice: VkPhysicalDevice, pMemoryProperties: *VkPhysicalDeviceMemoryProperties) callconv(.c) void,
    vkGetPhysicalDeviceFormatProperties: *const fn (physicalDevice: VkPhysicalDevice, format: VkFormat, pFormatProperties: *VkFormatProperties) callconv(.c) void,
    vkCreateXlibSurfaceKHR: *const fn (instance: VkInstance, pCreateInfo: *const VkXlibSurfaceCreateInfoKHR, pAllocator: ?*const anyopaque, pSurface: *VkSurfaceKHR) callconv(.c) VkResult,
    vkDestroySurfaceKHR: *const fn (instance: VkInstance, surface: VkSurfaceKHR, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkGetPhysicalDeviceSurfaceSupportKHR: *const fn (physicalDevice: VkPhysicalDevice, queueFamilyIndex: u32, surface: VkSurfaceKHR, pSupported: *VkBool32) callconv(.c) VkResult,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: *const fn (physicalDevice: VkPhysicalDevice, surface: VkSurfaceKHR, pSurfaceCapabilities: *VkSurfaceCapabilitiesKHR) callconv(.c) VkResult,
    vkGetPhysicalDeviceSurfaceFormatsKHR: *const fn (physicalDevice: VkPhysicalDevice, surface: VkSurfaceKHR, pSurfaceFormatCount: *u32, pSurfaceFormats: ?[*]VkSurfaceFormatKHR) callconv(.c) VkResult,
    vkGetPhysicalDeviceSurfacePresentModesKHR: *const fn (physicalDevice: VkPhysicalDevice, surface: VkSurfaceKHR, pPresentModeCount: *u32, pPresentModes: ?[*]VkPresentModeKHR) callconv(.c) VkResult,
    vkCreateDevice: *const fn (physicalDevice: VkPhysicalDevice, pCreateInfo: *const VkDeviceCreateInfo, pAllocator: ?*const anyopaque, pDevice: *VkDevice) callconv(.c) VkResult,
    vkGetDeviceProcAddr: *const fn (device: VkDevice, pName: [*:0]const u8) callconv(.c) PFN_vkVoidFunction,

    vkDestroyDevice: *const fn (device: VkDevice, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkGetDeviceQueue: *const fn (device: VkDevice, queueFamilyIndex: u32, queueIndex: u32, pQueue: *VkQueue) callconv(.c) void,
    vkCreateCommandPool: *const fn (device: VkDevice, pCreateInfo: *const VkCommandPoolCreateInfo, pAllocator: ?*const anyopaque, pCommandPool: *VkCommandPool) callconv(.c) VkResult,
    vkDestroyCommandPool: *const fn (device: VkDevice, commandPool: VkCommandPool, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkAllocateCommandBuffers: *const fn (device: VkDevice, pAllocateInfo: *const VkCommandBufferAllocateInfo, pCommandBuffers: [*]VkCommandBuffer) callconv(.c) VkResult,
    vkFreeCommandBuffers: *const fn (device: VkDevice, commandPool: VkCommandPool, commandBufferCount: u32, pCommandBuffers: [*]const VkCommandBuffer) callconv(.c) void,
    vkCreateSemaphore: *const fn (device: VkDevice, pCreateInfo: *const VkSemaphoreCreateInfo, pAllocator: ?*const anyopaque, pSemaphore: *VkSemaphore) callconv(.c) VkResult,
    vkDestroySemaphore: *const fn (device: VkDevice, semaphore: VkSemaphore, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkCreateQueryPool: *const fn (device: VkDevice, pCreateInfo: *const VkQueryPoolCreateInfo, pAllocator: ?*const anyopaque, pQueryPool: *VkQueryPool) callconv(.c) VkResult,
    vkDestroyQueryPool: *const fn (device: VkDevice, queryPool: VkQueryPool, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkGetQueryPoolResults: *const fn (device: VkDevice, queryPool: VkQueryPool, firstQuery: u32, queryCount: u32, dataSize: usize, pData: *anyopaque, stride: u64, flags: VkQueryResultFlags) callconv(.c) VkResult,
    vkGetSemaphoreCounterValue: *const fn (device: VkDevice, semaphore: VkSemaphore, pValue: *u64) callconv(.c) VkResult,
    vkWaitSemaphores: *const fn (device: VkDevice, pWaitInfo: *const VkSemaphoreWaitInfo, timeout: u64) callconv(.c) VkResult,
    vkSignalSemaphore: *const fn (device: VkDevice, pSignalInfo: *const VkSemaphoreSignalInfo) callconv(.c) VkResult,
    vkQueueSubmit2: *const fn (queue: VkQueue, submitCount: u32, pSubmits: ?[*]const VkSubmitInfo2, fence: VkFence) callconv(.c) VkResult,
    vkDeviceWaitIdle: *const fn (device: VkDevice) callconv(.c) VkResult,
    vkCreateSwapchainKHR: *const fn (device: VkDevice, pCreateInfo: *const VkSwapchainCreateInfoKHR, pAllocator: ?*const anyopaque, pSwapchain: *VkSwapchainKHR) callconv(.c) VkResult,
    vkDestroySwapchainKHR: *const fn (device: VkDevice, swapchain: VkSwapchainKHR, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkGetSwapchainImagesKHR: *const fn (device: VkDevice, swapchain: VkSwapchainKHR, pSwapchainImageCount: *u32, pSwapchainImages: ?[*]VkImage) callconv(.c) VkResult,
    vkAcquireNextImageKHR: *const fn (device: VkDevice, swapchain: VkSwapchainKHR, timeout: u64, semaphore: VkSemaphore, fence: VkFence, pImageIndex: *u32) callconv(.c) VkResult,
    vkQueuePresentKHR: *const fn (queue: VkQueue, pPresentInfo: *const VkPresentInfoKHR) callconv(.c) VkResult,

    vkCreateShaderModule: *const fn (device: VkDevice, pCreateInfo: *const VkShaderModuleCreateInfo, pAllocator: ?*const anyopaque, pShaderModule: *VkShaderModule) callconv(.c) VkResult,
    vkDestroyShaderModule: *const fn (device: VkDevice, shaderModule: VkShaderModule, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkCreatePipelineLayout: *const fn (device: VkDevice, pCreateInfo: *const VkPipelineLayoutCreateInfo, pAllocator: ?*const anyopaque, pPipelineLayout: *VkPipelineLayout) callconv(.c) VkResult,
    vkDestroyPipelineLayout: *const fn (device: VkDevice, pipelineLayout: VkPipelineLayout, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkCreateDescriptorSetLayout: *const fn (device: VkDevice, pCreateInfo: *const VkDescriptorSetLayoutCreateInfo, pAllocator: ?*const anyopaque, pSetLayout: *VkDescriptorSetLayout) callconv(.c) VkResult,
    vkDestroyDescriptorSetLayout: *const fn (device: VkDevice, descriptorSetLayout: VkDescriptorSetLayout, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkCreateComputePipelines: *const fn (device: VkDevice, pipelineCache: VkPipelineCache, createInfoCount: u32, pCreateInfos: [*]const VkComputePipelineCreateInfo, pAllocator: ?*const anyopaque, pPipelines: [*]VkPipeline) callconv(.c) VkResult,
    vkDestroyPipeline: *const fn (device: VkDevice, pipeline: VkPipeline, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkCreateDescriptorPool: *const fn (device: VkDevice, pCreateInfo: *const VkDescriptorPoolCreateInfo, pAllocator: ?*const anyopaque, pDescriptorPool: *VkDescriptorPool) callconv(.c) VkResult,
    vkDestroyDescriptorPool: *const fn (device: VkDevice, descriptorPool: VkDescriptorPool, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkResetDescriptorPool: *const fn (device: VkDevice, descriptorPool: VkDescriptorPool, flags: VkDescriptorPoolResetFlags) callconv(.c) VkResult,
    vkAllocateDescriptorSets: *const fn (device: VkDevice, pAllocateInfo: *const VkDescriptorSetAllocateInfo, pDescriptorSets: [*]VkDescriptorSet) callconv(.c) VkResult,
    vkFreeDescriptorSets: *const fn (device: VkDevice, descriptorPool: VkDescriptorPool, descriptorSetCount: u32, pDescriptorSets: [*]const VkDescriptorSet) callconv(.c) VkResult,
    vkUpdateDescriptorSets: *const fn (device: VkDevice, descriptorWriteCount: u32, pDescriptorWrites: [*]const VkWriteDescriptorSet, descriptorCopyCount: u32, pDescriptorCopies: ?*const anyopaque) callconv(.c) void,
    vkCmdBindPipeline: *const fn (commandBuffer: VkCommandBuffer, pipelineBindPoint: VkPipelineBindPoint, pipeline: VkPipeline) callconv(.c) void,
    vkCmdBindDescriptorSets: *const fn (commandBuffer: VkCommandBuffer, pipelineBindPoint: VkPipelineBindPoint, layout: VkPipelineLayout, firstSet: u32, descriptorSetCount: u32, pDescriptorSets: [*]const VkDescriptorSet, dynamicOffsetCount: u32, pDynamicOffsets: ?[*]const u32) callconv(.c) void,
    vkCmdDispatch: *const fn (commandBuffer: VkCommandBuffer, groupCountX: u32, groupCountY: u32, groupCountZ: u32) callconv(.c) void,
    vkCmdPipelineBarrier: *const fn (commandBuffer: VkCommandBuffer, srcStageMask: VkPipelineStageFlags, dstStageMask: VkPipelineStageFlags, dependencyFlags: VkDependencyFlags, memoryBarrierCount: u32, pMemoryBarriers: ?*const anyopaque, bufferMemoryBarrierCount: u32, pBufferMemoryBarriers: ?[*]const VkBufferMemoryBarrier, imageMemoryBarrierCount: u32, pImageMemoryBarriers: ?[*]const VkImageMemoryBarrier) callconv(.c) void,
    vkCmdClearColorImage: *const fn (commandBuffer: VkCommandBuffer, image: VkImage, imageLayout: VkImageLayout, pColor: *const VkClearColorValue, rangeCount: u32, pRanges: [*]const VkImageSubresourceRange) callconv(.c) void,
    vkCmdCopyBuffer: *const fn (commandBuffer: VkCommandBuffer, srcBuffer: VkBuffer, dstBuffer: VkBuffer, regionCount: u32, pRegions: [*]const VkBufferCopy) callconv(.c) void,
    vkCmdCopyBufferToImage: *const fn (commandBuffer: VkCommandBuffer, srcBuffer: VkBuffer, dstImage: VkImage, dstImageLayout: VkImageLayout, regionCount: u32, pRegions: [*]const VkBufferImageCopy) callconv(.c) void,
    vkCmdResetQueryPool: *const fn (commandBuffer: VkCommandBuffer, queryPool: VkQueryPool, firstQuery: u32, queryCount: u32) callconv(.c) void,
    vkCmdWriteTimestamp: *const fn (commandBuffer: VkCommandBuffer, pipelineStage: VkPipelineStageFlags, queryPool: VkQueryPool, query: u32) callconv(.c) void,
    vkCmdPushConstants: *const fn (commandBuffer: VkCommandBuffer, layout: VkPipelineLayout, stageFlags: VkShaderStageFlags, offset: u32, size: u32, pValues: *const anyopaque) callconv(.c) void,
    vkBeginCommandBuffer: *const fn (commandBuffer: VkCommandBuffer, pBeginInfo: *const VkCommandBufferBeginInfo) callconv(.c) VkResult,
    vkEndCommandBuffer: *const fn (commandBuffer: VkCommandBuffer) callconv(.c) VkResult,
    vkResetCommandBuffer: *const fn (commandBuffer: VkCommandBuffer, flags: u32) callconv(.c) VkResult,
    vkAllocateMemory: *const fn (device: VkDevice, pAllocateInfo: *const VkMemoryAllocateInfo, pAllocator: ?*const anyopaque, pMemory: *VkDeviceMemory) callconv(.c) VkResult,
    vkFreeMemory: *const fn (device: VkDevice, memory: VkDeviceMemory, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkBindBufferMemory: *const fn (device: VkDevice, buffer: VkBuffer, memory: VkDeviceMemory, memoryOffset: u64) callconv(.c) VkResult,
    vkCreateBuffer: *const fn (device: VkDevice, pCreateInfo: *const VkBufferCreateInfo, pAllocator: ?*const anyopaque, pBuffer: *VkBuffer) callconv(.c) VkResult,
    vkDestroyBuffer: *const fn (device: VkDevice, buffer: VkBuffer, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkMapMemory: *const fn (device: VkDevice, memory: VkDeviceMemory, offset: u64, size: u64, flags: u32, ppData: *?*anyopaque) callconv(.c) VkResult,
    vkUnmapMemory: *const fn (device: VkDevice, memory: VkDeviceMemory) callconv(.c) void,
    vkGetBufferMemoryRequirements: *const fn (device: VkDevice, buffer: VkBuffer, pMemoryRequirements: *VkMemoryRequirements) callconv(.c) void,
    vkFlushMappedMemoryRanges: *const fn (device: VkDevice, memoryRangeCount: u32, pMemoryRanges: [*]const VkMappedMemoryRange) callconv(.c) VkResult,
    vkInvalidateMappedMemoryRanges: *const fn (device: VkDevice, memoryRangeCount: u32, pMemoryRanges: [*]const VkMappedMemoryRange) callconv(.c) VkResult,
    vkCreateImage: *const fn (device: VkDevice, pCreateInfo: *const VkImageCreateInfo, pAllocator: ?*const anyopaque, pImage: *VkImage) callconv(.c) VkResult,
    vkDestroyImage: *const fn (device: VkDevice, image: VkImage, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkGetImageMemoryRequirements: *const fn (device: VkDevice, image: VkImage, pMemoryRequirements: *VkMemoryRequirements) callconv(.c) void,
    vkBindImageMemory: *const fn (device: VkDevice, image: VkImage, memory: VkDeviceMemory, memoryOffset: u64) callconv(.c) VkResult,
    vkCreateImageView: *const fn (device: VkDevice, pCreateInfo: *const VkImageViewCreateInfo, pAllocator: ?*const anyopaque, pView: *VkImageView) callconv(.c) VkResult,
    vkDestroyImageView: *const fn (device: VkDevice, imageView: VkImageView, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkCreateSampler: *const fn (device: VkDevice, pCreateInfo: *const VkSamplerCreateInfo, pAllocator: ?*const anyopaque, pSampler: *VkSampler) callconv(.c) VkResult,
    vkDestroySampler: *const fn (device: VkDevice, sampler: VkSampler, pAllocator: ?*const anyopaque) callconv(.c) void,
    vkCreateGraphicsPipelines: *const fn (device: VkDevice, pipelineCache: VkPipelineCache, createInfoCount: u32, pCreateInfos: [*]const VkGraphicsPipelineCreateInfo, pAllocator: ?*const anyopaque, pPipelines: [*]VkPipeline) callconv(.c) VkResult,
    vkCmdBeginRendering: *const fn (commandBuffer: VkCommandBuffer, pRenderingInfo: *const VkRenderingInfo) callconv(.c) void,
    vkCmdEndRendering: *const fn (commandBuffer: VkCommandBuffer) callconv(.c) void,
    vkCmdBindVertexBuffers: *const fn (commandBuffer: VkCommandBuffer, firstBinding: u32, bindingCount: u32, pBuffers: [*]const VkBuffer, pOffsets: [*]const u64) callconv(.c) void,
    vkCmdBindIndexBuffer: *const fn (commandBuffer: VkCommandBuffer, buffer: VkBuffer, offset: u64, indexType: VkIndexType) callconv(.c) void,
    vkCmdDraw: *const fn (commandBuffer: VkCommandBuffer, vertexCount: u32, instanceCount: u32, firstVertex: u32, firstInstance: u32) callconv(.c) void,
    vkCmdDrawIndexed: *const fn (commandBuffer: VkCommandBuffer, indexCount: u32, instanceCount: u32, firstIndex: u32, vertexOffset: i32, firstInstance: u32) callconv(.c) void,
    vkCmdSetViewport: *const fn (commandBuffer: VkCommandBuffer, firstViewport: u32, viewportCount: u32, pViewports: [*]const VkViewport) callconv(.c) void,
    vkCmdSetScissor: *const fn (commandBuffer: VkCommandBuffer, firstScissor: u32, scissorCount: u32, pScissors: [*]const VkRect2D) callconv(.c) void,
    vkCmdCopyImageToBuffer: *const fn (commandBuffer: VkCommandBuffer, srcImage: VkImage, srcImageLayout: VkImageLayout, dstBuffer: VkBuffer, regionCount: u32, pRegions: [*]const VkBufferImageCopy) callconv(.c) void,
    vkGetPhysicalDeviceFormatProperties2: *const fn (physicalDevice: VkPhysicalDevice, format: VkFormat, pFormatProperties: *VkFormatProperties2) callconv(.c) void,
    vkGetImageSubresourceLayout: *const fn (device: VkDevice, image: VkImage, pSubresource: *const VkImageSubresource, pLayout: *VkSubresourceLayout) callconv(.c) void,
    /// Loaded by `loadDmabufFunctions`, once the device enables the extensions that define them.
    vkGetImageDrmFormatModifierPropertiesEXT: ?*const fn (device: VkDevice, image: VkImage, pProperties: *VkImageDrmFormatModifierPropertiesEXT) callconv(.c) VkResult = null,
    vkGetMemoryFdKHR: ?*const fn (device: VkDevice, pGetFdInfo: *const VkMemoryGetFdInfoKHR, pFd: *c_int) callconv(.c) VkResult = null,
    vkGetSemaphoreFdKHR: ?*const fn (device: VkDevice, pGetFdInfo: *const VkSemaphoreGetFdInfoKHR, pFd: *c_int) callconv(.c) VkResult = null,

    pub fn open(allocator: std.mem.Allocator) Error!Driver {
        _ = allocator;

        var lib = try openLoaderLibrary();
        errdefer lib.close();

        var driver: Driver = undefined;
        driver.lib = lib;

        const gipa = lib.lookup(@TypeOf(driver.vkGetInstanceProcAddr), "vkGetInstanceProcAddr") orelse {
            log.err("vulkan symbol missing from loader: vkGetInstanceProcAddr", .{});
            return error.SymbolMissing;
        };
        driver.vkGetInstanceProcAddr = gipa;

        driver.vkCreateInstance = try lookupGlobal(
            &driver,
            @TypeOf(driver.vkCreateInstance),
            "vkCreateInstance",
        );

        return driver;
    }

    fn lookupGlobal(self: *Driver, comptime T: type, comptime name: [:0]const u8) Error!T {
        const raw = self.vkGetInstanceProcAddr(null, name.ptr) orelse {
            log.err("vulkan global symbol missing: {s}", .{name});
            return error.SymbolMissing;
        };
        return @ptrCast(@alignCast(raw));
    }

    fn lookupInstance(self: *Driver, instance: VkInstance, comptime T: type, comptime name: [:0]const u8) Error!T {
        const raw = self.vkGetInstanceProcAddr(instance, name.ptr) orelse {
            log.err("vulkan instance symbol missing: {s}", .{name});
            return error.SymbolMissing;
        };
        return @ptrCast(@alignCast(raw));
    }

    fn lookupDevice(self: *Driver, device: VkDevice, comptime T: type, comptime name: [:0]const u8) Error!T {
        const raw = self.vkGetDeviceProcAddr(device, name.ptr) orelse {
            log.err("vulkan device symbol missing: {s}", .{name});
            return error.SymbolMissing;
        };
        return @ptrCast(@alignCast(raw));
    }

    pub fn loadInstanceFunctions(self: *Driver, instance: VkInstance) Error!void {
        self.vkDestroyInstance = try self.lookupInstance(instance, @TypeOf(self.vkDestroyInstance), "vkDestroyInstance");
        self.vkEnumeratePhysicalDevices = try self.lookupInstance(instance, @TypeOf(self.vkEnumeratePhysicalDevices), "vkEnumeratePhysicalDevices");
        self.vkGetPhysicalDeviceProperties = try self.lookupInstance(instance, @TypeOf(self.vkGetPhysicalDeviceProperties), "vkGetPhysicalDeviceProperties");
        self.vkGetPhysicalDeviceProperties2 = try self.lookupInstance(instance, @TypeOf(self.vkGetPhysicalDeviceProperties2), "vkGetPhysicalDeviceProperties2");
        self.vkGetPhysicalDeviceFeatures2 = try self.lookupInstance(instance, @TypeOf(self.vkGetPhysicalDeviceFeatures2), "vkGetPhysicalDeviceFeatures2");
        self.vkEnumerateDeviceExtensionProperties = try self.lookupInstance(instance, @TypeOf(self.vkEnumerateDeviceExtensionProperties), "vkEnumerateDeviceExtensionProperties");
        self.vkGetPhysicalDeviceQueueFamilyProperties = try self.lookupInstance(instance, @TypeOf(self.vkGetPhysicalDeviceQueueFamilyProperties), "vkGetPhysicalDeviceQueueFamilyProperties");
        self.vkGetPhysicalDeviceMemoryProperties = try self.lookupInstance(instance, @TypeOf(self.vkGetPhysicalDeviceMemoryProperties), "vkGetPhysicalDeviceMemoryProperties");
        self.vkGetPhysicalDeviceFormatProperties = try self.lookupInstance(instance, @TypeOf(self.vkGetPhysicalDeviceFormatProperties), "vkGetPhysicalDeviceFormatProperties");
        self.vkGetPhysicalDeviceFormatProperties2 = try self.lookupInstance(instance, @TypeOf(self.vkGetPhysicalDeviceFormatProperties2), "vkGetPhysicalDeviceFormatProperties2");
        self.vkCreateXlibSurfaceKHR = try self.lookupInstance(instance, @TypeOf(self.vkCreateXlibSurfaceKHR), "vkCreateXlibSurfaceKHR");
        self.vkDestroySurfaceKHR = try self.lookupInstance(instance, @TypeOf(self.vkDestroySurfaceKHR), "vkDestroySurfaceKHR");
        self.vkGetPhysicalDeviceSurfaceSupportKHR = try self.lookupInstance(instance, @TypeOf(self.vkGetPhysicalDeviceSurfaceSupportKHR), "vkGetPhysicalDeviceSurfaceSupportKHR");
        self.vkGetPhysicalDeviceSurfaceCapabilitiesKHR = try self.lookupInstance(instance, @TypeOf(self.vkGetPhysicalDeviceSurfaceCapabilitiesKHR), "vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
        self.vkGetPhysicalDeviceSurfaceFormatsKHR = try self.lookupInstance(instance, @TypeOf(self.vkGetPhysicalDeviceSurfaceFormatsKHR), "vkGetPhysicalDeviceSurfaceFormatsKHR");
        self.vkGetPhysicalDeviceSurfacePresentModesKHR = try self.lookupInstance(instance, @TypeOf(self.vkGetPhysicalDeviceSurfacePresentModesKHR), "vkGetPhysicalDeviceSurfacePresentModesKHR");
        self.vkCreateDevice = try self.lookupInstance(instance, @TypeOf(self.vkCreateDevice), "vkCreateDevice");
        self.vkGetDeviceProcAddr = try self.lookupInstance(instance, @TypeOf(self.vkGetDeviceProcAddr), "vkGetDeviceProcAddr");
    }

    pub fn loadDeviceFunctions(self: *Driver, device: VkDevice) Error!void {
        self.vkDestroyDevice = try self.lookupDevice(device, @TypeOf(self.vkDestroyDevice), "vkDestroyDevice");
        self.vkGetDeviceQueue = try self.lookupDevice(device, @TypeOf(self.vkGetDeviceQueue), "vkGetDeviceQueue");
        self.vkCreateCommandPool = try self.lookupDevice(device, @TypeOf(self.vkCreateCommandPool), "vkCreateCommandPool");
        self.vkDestroyCommandPool = try self.lookupDevice(device, @TypeOf(self.vkDestroyCommandPool), "vkDestroyCommandPool");
        self.vkAllocateCommandBuffers = try self.lookupDevice(device, @TypeOf(self.vkAllocateCommandBuffers), "vkAllocateCommandBuffers");
        self.vkFreeCommandBuffers = try self.lookupDevice(device, @TypeOf(self.vkFreeCommandBuffers), "vkFreeCommandBuffers");
        self.vkCreateSemaphore = try self.lookupDevice(device, @TypeOf(self.vkCreateSemaphore), "vkCreateSemaphore");
        self.vkDestroySemaphore = try self.lookupDevice(device, @TypeOf(self.vkDestroySemaphore), "vkDestroySemaphore");
        self.vkCreateQueryPool = try self.lookupDevice(device, @TypeOf(self.vkCreateQueryPool), "vkCreateQueryPool");
        self.vkDestroyQueryPool = try self.lookupDevice(device, @TypeOf(self.vkDestroyQueryPool), "vkDestroyQueryPool");
        self.vkGetQueryPoolResults = try self.lookupDevice(device, @TypeOf(self.vkGetQueryPoolResults), "vkGetQueryPoolResults");
        self.vkGetSemaphoreCounterValue = try self.lookupDevice(device, @TypeOf(self.vkGetSemaphoreCounterValue), "vkGetSemaphoreCounterValue");
        self.vkWaitSemaphores = try self.lookupDevice(device, @TypeOf(self.vkWaitSemaphores), "vkWaitSemaphores");
        self.vkSignalSemaphore = try self.lookupDevice(device, @TypeOf(self.vkSignalSemaphore), "vkSignalSemaphore");
        self.vkQueueSubmit2 = try self.lookupDevice(device, @TypeOf(self.vkQueueSubmit2), "vkQueueSubmit2");
        self.vkDeviceWaitIdle = try self.lookupDevice(device, @TypeOf(self.vkDeviceWaitIdle), "vkDeviceWaitIdle");
        self.vkCreateSwapchainKHR = try self.lookupDevice(device, @TypeOf(self.vkCreateSwapchainKHR), "vkCreateSwapchainKHR");
        self.vkDestroySwapchainKHR = try self.lookupDevice(device, @TypeOf(self.vkDestroySwapchainKHR), "vkDestroySwapchainKHR");
        self.vkGetSwapchainImagesKHR = try self.lookupDevice(device, @TypeOf(self.vkGetSwapchainImagesKHR), "vkGetSwapchainImagesKHR");
        self.vkAcquireNextImageKHR = try self.lookupDevice(device, @TypeOf(self.vkAcquireNextImageKHR), "vkAcquireNextImageKHR");
        self.vkQueuePresentKHR = try self.lookupDevice(device, @TypeOf(self.vkQueuePresentKHR), "vkQueuePresentKHR");

        self.vkCreateShaderModule = try self.lookupDevice(device, @TypeOf(self.vkCreateShaderModule), "vkCreateShaderModule");
        self.vkDestroyShaderModule = try self.lookupDevice(device, @TypeOf(self.vkDestroyShaderModule), "vkDestroyShaderModule");
        self.vkCreatePipelineLayout = try self.lookupDevice(device, @TypeOf(self.vkCreatePipelineLayout), "vkCreatePipelineLayout");
        self.vkDestroyPipelineLayout = try self.lookupDevice(device, @TypeOf(self.vkDestroyPipelineLayout), "vkDestroyPipelineLayout");
        self.vkCreateDescriptorSetLayout = try self.lookupDevice(device, @TypeOf(self.vkCreateDescriptorSetLayout), "vkCreateDescriptorSetLayout");
        self.vkDestroyDescriptorSetLayout = try self.lookupDevice(device, @TypeOf(self.vkDestroyDescriptorSetLayout), "vkDestroyDescriptorSetLayout");
        self.vkCreateComputePipelines = try self.lookupDevice(device, @TypeOf(self.vkCreateComputePipelines), "vkCreateComputePipelines");
        self.vkDestroyPipeline = try self.lookupDevice(device, @TypeOf(self.vkDestroyPipeline), "vkDestroyPipeline");
        self.vkCreateDescriptorPool = try self.lookupDevice(device, @TypeOf(self.vkCreateDescriptorPool), "vkCreateDescriptorPool");
        self.vkDestroyDescriptorPool = try self.lookupDevice(device, @TypeOf(self.vkDestroyDescriptorPool), "vkDestroyDescriptorPool");
        self.vkResetDescriptorPool = try self.lookupDevice(device, @TypeOf(self.vkResetDescriptorPool), "vkResetDescriptorPool");
        self.vkAllocateDescriptorSets = try self.lookupDevice(device, @TypeOf(self.vkAllocateDescriptorSets), "vkAllocateDescriptorSets");
        self.vkFreeDescriptorSets = try self.lookupDevice(device, @TypeOf(self.vkFreeDescriptorSets), "vkFreeDescriptorSets");
        self.vkUpdateDescriptorSets = try self.lookupDevice(device, @TypeOf(self.vkUpdateDescriptorSets), "vkUpdateDescriptorSets");
        self.vkCmdBindPipeline = try self.lookupDevice(device, @TypeOf(self.vkCmdBindPipeline), "vkCmdBindPipeline");
        self.vkCmdBindDescriptorSets = try self.lookupDevice(device, @TypeOf(self.vkCmdBindDescriptorSets), "vkCmdBindDescriptorSets");
        self.vkCmdDispatch = try self.lookupDevice(device, @TypeOf(self.vkCmdDispatch), "vkCmdDispatch");
        self.vkCmdPipelineBarrier = try self.lookupDevice(device, @TypeOf(self.vkCmdPipelineBarrier), "vkCmdPipelineBarrier");
        self.vkCmdClearColorImage = try self.lookupDevice(device, @TypeOf(self.vkCmdClearColorImage), "vkCmdClearColorImage");
        self.vkCmdCopyBuffer = try self.lookupDevice(device, @TypeOf(self.vkCmdCopyBuffer), "vkCmdCopyBuffer");
        self.vkCmdCopyBufferToImage = try self.lookupDevice(device, @TypeOf(self.vkCmdCopyBufferToImage), "vkCmdCopyBufferToImage");
        self.vkCmdResetQueryPool = try self.lookupDevice(device, @TypeOf(self.vkCmdResetQueryPool), "vkCmdResetQueryPool");
        self.vkCmdWriteTimestamp = try self.lookupDevice(device, @TypeOf(self.vkCmdWriteTimestamp), "vkCmdWriteTimestamp");
        self.vkCmdPushConstants = try self.lookupDevice(device, @TypeOf(self.vkCmdPushConstants), "vkCmdPushConstants");
        self.vkBeginCommandBuffer = try self.lookupDevice(device, @TypeOf(self.vkBeginCommandBuffer), "vkBeginCommandBuffer");
        self.vkEndCommandBuffer = try self.lookupDevice(device, @TypeOf(self.vkEndCommandBuffer), "vkEndCommandBuffer");
        self.vkResetCommandBuffer = try self.lookupDevice(device, @TypeOf(self.vkResetCommandBuffer), "vkResetCommandBuffer");
        self.vkAllocateMemory = try self.lookupDevice(device, @TypeOf(self.vkAllocateMemory), "vkAllocateMemory");
        self.vkFreeMemory = try self.lookupDevice(device, @TypeOf(self.vkFreeMemory), "vkFreeMemory");
        self.vkBindBufferMemory = try self.lookupDevice(device, @TypeOf(self.vkBindBufferMemory), "vkBindBufferMemory");
        self.vkCreateBuffer = try self.lookupDevice(device, @TypeOf(self.vkCreateBuffer), "vkCreateBuffer");
        self.vkDestroyBuffer = try self.lookupDevice(device, @TypeOf(self.vkDestroyBuffer), "vkDestroyBuffer");
        self.vkMapMemory = try self.lookupDevice(device, @TypeOf(self.vkMapMemory), "vkMapMemory");
        self.vkUnmapMemory = try self.lookupDevice(device, @TypeOf(self.vkUnmapMemory), "vkUnmapMemory");
        self.vkGetBufferMemoryRequirements = try self.lookupDevice(device, @TypeOf(self.vkGetBufferMemoryRequirements), "vkGetBufferMemoryRequirements");
        self.vkFlushMappedMemoryRanges = try self.lookupDevice(device, @TypeOf(self.vkFlushMappedMemoryRanges), "vkFlushMappedMemoryRanges");
        self.vkInvalidateMappedMemoryRanges = try self.lookupDevice(device, @TypeOf(self.vkInvalidateMappedMemoryRanges), "vkInvalidateMappedMemoryRanges");
        self.vkCreateImage = try self.lookupDevice(device, @TypeOf(self.vkCreateImage), "vkCreateImage");
        self.vkDestroyImage = try self.lookupDevice(device, @TypeOf(self.vkDestroyImage), "vkDestroyImage");
        self.vkGetImageMemoryRequirements = try self.lookupDevice(device, @TypeOf(self.vkGetImageMemoryRequirements), "vkGetImageMemoryRequirements");
        self.vkBindImageMemory = try self.lookupDevice(device, @TypeOf(self.vkBindImageMemory), "vkBindImageMemory");
        self.vkCreateImageView = try self.lookupDevice(device, @TypeOf(self.vkCreateImageView), "vkCreateImageView");
        self.vkDestroyImageView = try self.lookupDevice(device, @TypeOf(self.vkDestroyImageView), "vkDestroyImageView");
        self.vkCreateSampler = try self.lookupDevice(device, @TypeOf(self.vkCreateSampler), "vkCreateSampler");
        self.vkDestroySampler = try self.lookupDevice(device, @TypeOf(self.vkDestroySampler), "vkDestroySampler");
        self.vkCreateGraphicsPipelines = try self.lookupDevice(device, @TypeOf(self.vkCreateGraphicsPipelines), "vkCreateGraphicsPipelines");
        self.vkCmdBeginRendering = try self.lookupDevice(device, @TypeOf(self.vkCmdBeginRendering), "vkCmdBeginRendering");
        self.vkCmdEndRendering = try self.lookupDevice(device, @TypeOf(self.vkCmdEndRendering), "vkCmdEndRendering");
        self.vkCmdBindVertexBuffers = try self.lookupDevice(device, @TypeOf(self.vkCmdBindVertexBuffers), "vkCmdBindVertexBuffers");
        self.vkCmdBindIndexBuffer = try self.lookupDevice(device, @TypeOf(self.vkCmdBindIndexBuffer), "vkCmdBindIndexBuffer");
        self.vkCmdDraw = try self.lookupDevice(device, @TypeOf(self.vkCmdDraw), "vkCmdDraw");
        self.vkCmdDrawIndexed = try self.lookupDevice(device, @TypeOf(self.vkCmdDrawIndexed), "vkCmdDrawIndexed");
        self.vkCmdSetViewport = try self.lookupDevice(device, @TypeOf(self.vkCmdSetViewport), "vkCmdSetViewport");
        self.vkCmdSetScissor = try self.lookupDevice(device, @TypeOf(self.vkCmdSetScissor), "vkCmdSetScissor");
        self.vkCmdCopyImageToBuffer = try self.lookupDevice(device, @TypeOf(self.vkCmdCopyImageToBuffer), "vkCmdCopyImageToBuffer");
        self.vkGetImageSubresourceLayout = try self.lookupDevice(device, @TypeOf(self.vkGetImageSubresourceLayout), "vkGetImageSubresourceLayout");
    }

    /// Loads the entry points of VK_EXT_image_drm_format_modifier, VK_KHR_external_memory_fd and
    /// VK_KHR_external_semaphore_fd, which exist only on a device that enabled those extensions.
    pub fn loadDmabufFunctions(self: *Driver, device: VkDevice) Error!void {
        self.vkGetImageDrmFormatModifierPropertiesEXT = try self.lookupDevice(device, @typeInfo(@TypeOf(self.vkGetImageDrmFormatModifierPropertiesEXT)).optional.child, "vkGetImageDrmFormatModifierPropertiesEXT");
        self.vkGetMemoryFdKHR = try self.lookupDevice(device, @typeInfo(@TypeOf(self.vkGetMemoryFdKHR)).optional.child, "vkGetMemoryFdKHR");
        self.vkGetSemaphoreFdKHR = try self.lookupDevice(device, @typeInfo(@TypeOf(self.vkGetSemaphoreFdKHR)).optional.child, "vkGetSemaphoreFdKHR");
    }

    pub fn close(self: *Driver) void {
        self.lib.close();
    }

    pub fn fromResult(self: *const Driver, r: VkResult) Error!void {
        _ = self;
        switch (resultDiagnostic(r)) {
            .none => {},
            .unexpected_positive => {
                log.warn("unexpected positive VkResult {d} at fromResult boundary", .{@backingInt(r)});
            },
            .unmapped => {
                log.warn("unmapped VkResult {d}", .{@backingInt(r)});
            },
        }
        return mapResultQuiet(r);
    }
};

comptime {
    if (@sizeOf(VkResult) != @sizeOf(c_int)) {
        @compileError("VkResult ABI drift: storage must be c_int");
    }
    if (@sizeOf(VkQueueFamilyProperties) != 24) {
        @compileError("VkQueueFamilyProperties must be 24 bytes");
    }
    if (@sizeOf(VkExtensionProperties) != 260) {
        @compileError("VkExtensionProperties must be 260 bytes (256-byte name + u32 specVersion)");
    }
    if (@sizeOf(VkPhysicalDeviceProperties) != 824) {
        @compileError("VkPhysicalDeviceProperties must be 824 bytes (Vulkan ABI)");
    }
    if (@sizeOf(?*anyopaque) == 8 and @sizeOf(VkPhysicalDeviceProperties2) != 840) {
        @compileError("VkPhysicalDeviceProperties2 must be 840 bytes on 64-bit");
    }
    if (@sizeOf(?*anyopaque) == 8 and @sizeOf(VkPhysicalDeviceSubgroupProperties) != 32) {
        @compileError("VkPhysicalDeviceSubgroupProperties must be 32 bytes on 64-bit");
    }
    if (@sizeOf(VkPhysicalDeviceFeatures) != 220) {
        @compileError("VkPhysicalDeviceFeatures must be 220 bytes");
    }
    if (@sizeOf(?*anyopaque) == 8 and @sizeOf(VkPhysicalDeviceFeatures2) != 240) {
        @compileError("VkPhysicalDeviceFeatures2 must be 240 bytes on 64-bit");
    }
    if (@sizeOf(?*anyopaque) == 8 and @sizeOf(VkPhysicalDevice16BitStorageFeatures) != 32) {
        @compileError("VkPhysicalDevice16BitStorageFeatures must be 32 bytes on 64-bit");
    }
    if (@sizeOf(?*anyopaque) == 8 and @sizeOf(VkPhysicalDevice8BitStorageFeatures) != 32) {
        @compileError("VkPhysicalDevice8BitStorageFeatures must be 32 bytes on 64-bit");
    }
    if (@sizeOf(?*anyopaque) == 8 and @sizeOf(VkPhysicalDeviceTimelineSemaphoreFeatures) != 24) {
        @compileError("VkPhysicalDeviceTimelineSemaphoreFeatures must be 24 bytes on 64-bit");
    }
    if (@sizeOf(?*anyopaque) == 8 and @sizeOf(VkQueryPoolCreateInfo) != 32) {
        @compileError("VkQueryPoolCreateInfo must be 32 bytes on 64-bit");
    }
    if (@sizeOf(?*anyopaque) == 8 and @sizeOf(VkPhysicalDeviceLimits) != 504) {
        @compileError("VkPhysicalDeviceLimits must be 504 bytes on 64-bit");
    }
    if (@sizeOf(VkPhysicalDeviceSparseProperties) != 20) {
        @compileError("VkPhysicalDeviceSparseProperties must be 20 bytes");
    }
    if (@sizeOf(VkMemoryType) != 8) {
        @compileError("VkMemoryType must be 8 bytes (two u32 members)");
    }
    if (@sizeOf(VkMemoryHeap) != 16) {
        @compileError("VkMemoryHeap must be 16 bytes (u64 size + u32 flags + 4-byte pad)");
    }
    if (@sizeOf(VkPhysicalDeviceMemoryProperties) != 520) {
        @compileError("VkPhysicalDeviceMemoryProperties must be 520 bytes (Vulkan ABI)");
    }
    if (@sizeOf(VkMemoryRequirements) != 24) {
        @compileError("VkMemoryRequirements must be 24 bytes (u64 size + u64 align + u32 bits + pad)");
    }
    if (@sizeOf(VkSurfaceCapabilitiesKHR) != 52) {
        @compileError("VkSurfaceCapabilitiesKHR must be 52 bytes");
    }
    if (@sizeOf(VkSurfaceFormatKHR) != 8) {
        @compileError("VkSurfaceFormatKHR must be 8 bytes");
    }
    if (@sizeOf(?*anyopaque) == 8 and @sizeOf(VkXlibSurfaceCreateInfoKHR) != 40) {
        @compileError("VkXlibSurfaceCreateInfoKHR must be 40 bytes on 64-bit");
    }
    if (@sizeOf(?*anyopaque) == 8 and @sizeOf(VkSwapchainCreateInfoKHR) != 104) {
        @compileError("VkSwapchainCreateInfoKHR must be 104 bytes on 64-bit");
    }
    if (@sizeOf(?*anyopaque) == 8 and @sizeOf(VkPresentInfoKHR) != 64) {
        @compileError("VkPresentInfoKHR must be 64 bytes on 64-bit");
    }
    if (@sizeOf(VkImageSubresourceRange) != 20) {
        @compileError("VkImageSubresourceRange must be 20 bytes");
    }
    if (@sizeOf(VkImageSubresourceLayers) != 16) {
        @compileError("VkImageSubresourceLayers must be 16 bytes");
    }
    if (@sizeOf(VkOffset3D) != 12) {
        @compileError("VkOffset3D must be 12 bytes");
    }
    if (@sizeOf(?*anyopaque) == 8 and @sizeOf(VkImageMemoryBarrier) != 72) {
        @compileError("VkImageMemoryBarrier must be 72 bytes");
    }
    if (@sizeOf(?*anyopaque) == 8 and @sizeOf(VkBufferMemoryBarrier) != 56) {
        @compileError("VkBufferMemoryBarrier must be 56 bytes");
    }
    if (@sizeOf(VkBufferCopy) != 24) {
        @compileError("VkBufferCopy must be 24 bytes");
    }
    if (@sizeOf(VkBufferImageCopy) != 56) {
        @compileError("VkBufferImageCopy must be 56 bytes");
    }
    if (@sizeOf(VkClearColorValue) != 16) {
        @compileError("VkClearColorValue must be 16 bytes");
    }
}

fn skipIfHostHasDriver() !void {
    if (!platformSupported()) return error.SkipZigTest;
    if (dynamic.isVulkanLoaderLoadable()) return error.SkipZigTest;
}

test "Driver.open without libvulkan returns DriverUnavailable" {
    try skipIfHostHasDriver();
    try std.testing.expectError(Error.DriverUnavailable, Driver.open(std.testing.allocator));
}

test "VkResult pins the documented ABI values" {
    try std.testing.expectEqual(@as(c_int, 0), @backingInt(VkResult.success));
    try std.testing.expectEqual(@as(c_int, 1), @backingInt(VkResult.not_ready));
    try std.testing.expectEqual(@as(c_int, 2), @backingInt(VkResult.timeout));
    try std.testing.expectEqual(@as(c_int, 3), @backingInt(VkResult.event_set));
    try std.testing.expectEqual(@as(c_int, 4), @backingInt(VkResult.event_reset));
    try std.testing.expectEqual(@as(c_int, 5), @backingInt(VkResult.incomplete));
    try std.testing.expectEqual(@as(c_int, 1000001003), @backingInt(VkResult.suboptimal_khr));
    try std.testing.expectEqual(@as(c_int, -1), @backingInt(VkResult.error_out_of_host_memory));
    try std.testing.expectEqual(@as(c_int, -2), @backingInt(VkResult.error_out_of_device_memory));
    try std.testing.expectEqual(@as(c_int, -3), @backingInt(VkResult.error_initialization_failed));
    try std.testing.expectEqual(@as(c_int, -4), @backingInt(VkResult.error_device_lost));
    try std.testing.expectEqual(@as(c_int, -5), @backingInt(VkResult.error_memory_map_failed));
    try std.testing.expectEqual(@as(c_int, -6), @backingInt(VkResult.error_layer_not_present));
    try std.testing.expectEqual(@as(c_int, -7), @backingInt(VkResult.error_extension_not_present));
    try std.testing.expectEqual(@as(c_int, -8), @backingInt(VkResult.error_feature_not_present));
    try std.testing.expectEqual(@as(c_int, -9), @backingInt(VkResult.error_incompatible_driver));
    try std.testing.expectEqual(@as(c_int, -10), @backingInt(VkResult.error_too_many_objects));
    try std.testing.expectEqual(@as(c_int, -11), @backingInt(VkResult.error_format_not_supported));
    try std.testing.expectEqual(@as(c_int, -12), @backingInt(VkResult.error_fragmented_pool));
    try std.testing.expectEqual(@as(c_int, -1000069000), @backingInt(VkResult.error_out_of_pool_memory));
    try std.testing.expectEqual(@as(c_int, -13), @backingInt(VkResult.error_unknown));
    try std.testing.expectEqual(@as(c_int, -1000000000), @backingInt(VkResult.error_surface_lost_khr));
    try std.testing.expectEqual(@as(c_int, -1000000001), @backingInt(VkResult.error_native_window_in_use_khr));
    try std.testing.expectEqual(@as(c_int, -1000001004), @backingInt(VkResult.error_out_of_date_khr));
}

test "VkResult is storage-compatible with c_int and non-exhaustive" {
    try std.testing.expectEqual(@sizeOf(c_int), @sizeOf(VkResult));
    const unknown_code: VkResult = @fromBackingInt(@intCast(1_000_000_000));
    try std.testing.expectEqual(@as(c_int, 1_000_000_000), @backingInt(unknown_code));
}

test "fromResult on success returns without error" {
    var stub: Driver = undefined;
    try stub.fromResult(.success);
}

test "fromResult maps documented error codes onto the typed Error set" {
    var stub: Driver = undefined;
    const cases = [_]struct { r: VkResult, err: Error }{
        .{ .r = .error_out_of_host_memory, .err = Error.OutOfHostMemory },
        .{ .r = .error_out_of_device_memory, .err = Error.OutOfDeviceMemory },
        .{ .r = .error_initialization_failed, .err = Error.InitializationFailed },
        .{ .r = .error_device_lost, .err = Error.DeviceLost },
        .{ .r = .error_memory_map_failed, .err = Error.MemoryMapFailed },
        .{ .r = .error_layer_not_present, .err = Error.LayerNotPresent },
        .{ .r = .error_extension_not_present, .err = Error.ExtensionNotPresent },
        .{ .r = .error_feature_not_present, .err = Error.FeatureNotPresent },
        .{ .r = .error_incompatible_driver, .err = Error.IncompatibleDriver },
        .{ .r = .error_too_many_objects, .err = Error.TooManyObjects },
        .{ .r = .error_format_not_supported, .err = Error.FormatNotSupported },
        .{ .r = .error_fragmented_pool, .err = Error.FragmentedPool },
        .{ .r = .error_unknown, .err = Error.VulkanUnknown },
        .{ .r = .error_out_of_pool_memory, .err = Error.OutOfPoolMemory },
        .{ .r = .error_surface_lost_khr, .err = Error.SurfaceLost },
        .{ .r = .error_native_window_in_use_khr, .err = Error.NativeWindowInUse },
        .{ .r = .error_out_of_date_khr, .err = Error.SurfaceOutOfDate },
        .{ .r = .suboptimal_khr, .err = Error.SurfaceOutOfDate },
    };
    for (cases) |c| {
        try std.testing.expectError(c.err, stub.fromResult(c.r));
    }
}

test "VkResult quiet mapping collapses unmapped positive codes to VulkanUnknown" {
    try std.testing.expectError(Error.VulkanUnknown, mapResultQuiet(.not_ready));
    try std.testing.expectError(Error.VulkanUnknown, mapResultQuiet(.timeout));
    try std.testing.expectError(Error.VulkanUnknown, mapResultQuiet(.incomplete));
}

test "VkResult quiet mapping collapses unknown codes to VulkanUnknown" {
    const unknown_code: VkResult = @fromBackingInt(@intCast(-1337));
    try std.testing.expectError(Error.VulkanUnknown, mapResultQuiet(unknown_code));
}

test "Driver field signatures match the Vulkan loader ABI" {
    const vkGetInstanceProcAddrT = *const fn (
        instance: VkInstance,
        pName: [*:0]const u8,
    ) callconv(.c) PFN_vkVoidFunction;
    const vkCreateInstanceT = *const fn (
        pCreateInfo: *const VkInstanceCreateInfo,
        pAllocator: ?*const anyopaque,
        pInstance: *VkInstance,
    ) callconv(.c) VkResult;
    const vkEnumeratePhysicalDevicesT = *const fn (
        instance: VkInstance,
        pCount: *u32,
        pDevices: ?[*]VkPhysicalDevice,
    ) callconv(.c) VkResult;
    const vkCreateDeviceT = *const fn (
        physicalDevice: VkPhysicalDevice,
        pCreateInfo: *const VkDeviceCreateInfo,
        pAllocator: ?*const anyopaque,
        pDevice: *VkDevice,
    ) callconv(.c) VkResult;
    const vkGetSemaphoreCounterValueT = *const fn (
        device: VkDevice,
        semaphore: VkSemaphore,
        pValue: *u64,
    ) callconv(.c) VkResult;
    const vkWaitSemaphoresT = *const fn (
        device: VkDevice,
        pWaitInfo: *const VkSemaphoreWaitInfo,
        timeout: u64,
    ) callconv(.c) VkResult;
    const vkCreateXlibSurfaceKHRT = *const fn (
        instance: VkInstance,
        pCreateInfo: *const VkXlibSurfaceCreateInfoKHR,
        pAllocator: ?*const anyopaque,
        pSurface: *VkSurfaceKHR,
    ) callconv(.c) VkResult;
    const vkGetPhysicalDeviceSurfaceSupportKHRT = *const fn (
        physicalDevice: VkPhysicalDevice,
        queueFamilyIndex: u32,
        surface: VkSurfaceKHR,
        pSupported: *VkBool32,
    ) callconv(.c) VkResult;
    const vkCreateSwapchainKHRT = *const fn (
        device: VkDevice,
        pCreateInfo: *const VkSwapchainCreateInfoKHR,
        pAllocator: ?*const anyopaque,
        pSwapchain: *VkSwapchainKHR,
    ) callconv(.c) VkResult;
    const vkAcquireNextImageKHRT = *const fn (
        device: VkDevice,
        swapchain: VkSwapchainKHR,
        timeout: u64,
        semaphore: VkSemaphore,
        fence: VkFence,
        pImageIndex: *u32,
    ) callconv(.c) VkResult;
    const vkQueuePresentKHRT = *const fn (
        queue: VkQueue,
        pPresentInfo: *const VkPresentInfoKHR,
    ) callconv(.c) VkResult;
    const vkCmdPipelineBarrierT = *const fn (
        commandBuffer: VkCommandBuffer,
        srcStageMask: VkPipelineStageFlags,
        dstStageMask: VkPipelineStageFlags,
        dependencyFlags: VkDependencyFlags,
        memoryBarrierCount: u32,
        pMemoryBarriers: ?*const anyopaque,
        bufferMemoryBarrierCount: u32,
        pBufferMemoryBarriers: ?[*]const VkBufferMemoryBarrier,
        imageMemoryBarrierCount: u32,
        pImageMemoryBarriers: ?[*]const VkImageMemoryBarrier,
    ) callconv(.c) void;
    const vkResetDescriptorPoolT = *const fn (
        device: VkDevice,
        descriptorPool: VkDescriptorPool,
        flags: VkDescriptorPoolResetFlags,
    ) callconv(.c) VkResult;
    const vkCmdCopyBufferT = *const fn (
        commandBuffer: VkCommandBuffer,
        srcBuffer: VkBuffer,
        dstBuffer: VkBuffer,
        regionCount: u32,
        pRegions: [*]const VkBufferCopy,
    ) callconv(.c) void;
    const vkInvalidateMappedMemoryRangesT = *const fn (
        device: VkDevice,
        memoryRangeCount: u32,
        pMemoryRanges: [*]const VkMappedMemoryRange,
    ) callconv(.c) VkResult;
    const vkCmdClearColorImageT = *const fn (
        commandBuffer: VkCommandBuffer,
        image: VkImage,
        imageLayout: VkImageLayout,
        pColor: *const VkClearColorValue,
        rangeCount: u32,
        pRanges: [*]const VkImageSubresourceRange,
    ) callconv(.c) void;
    const vkCmdCopyBufferToImageT = *const fn (
        commandBuffer: VkCommandBuffer,
        srcBuffer: VkBuffer,
        dstImage: VkImage,
        dstImageLayout: VkImageLayout,
        regionCount: u32,
        pRegions: [*]const VkBufferImageCopy,
    ) callconv(.c) void;

    comptime {
        std.debug.assert(@FieldType(Driver, "vkGetInstanceProcAddr") == vkGetInstanceProcAddrT);
        std.debug.assert(@FieldType(Driver, "vkCreateInstance") == vkCreateInstanceT);
        std.debug.assert(@FieldType(Driver, "vkEnumeratePhysicalDevices") == vkEnumeratePhysicalDevicesT);
        std.debug.assert(@FieldType(Driver, "vkCreateDevice") == vkCreateDeviceT);
        std.debug.assert(@FieldType(Driver, "vkGetSemaphoreCounterValue") == vkGetSemaphoreCounterValueT);
        std.debug.assert(@FieldType(Driver, "vkWaitSemaphores") == vkWaitSemaphoresT);
        std.debug.assert(@FieldType(Driver, "vkCreateXlibSurfaceKHR") == vkCreateXlibSurfaceKHRT);
        std.debug.assert(@FieldType(Driver, "vkGetPhysicalDeviceSurfaceSupportKHR") == vkGetPhysicalDeviceSurfaceSupportKHRT);
        std.debug.assert(@FieldType(Driver, "vkCreateSwapchainKHR") == vkCreateSwapchainKHRT);
        std.debug.assert(@FieldType(Driver, "vkAcquireNextImageKHR") == vkAcquireNextImageKHRT);
        std.debug.assert(@FieldType(Driver, "vkQueuePresentKHR") == vkQueuePresentKHRT);
        std.debug.assert(@FieldType(Driver, "vkCmdPipelineBarrier") == vkCmdPipelineBarrierT);
        std.debug.assert(@FieldType(Driver, "vkResetDescriptorPool") == vkResetDescriptorPoolT);
        std.debug.assert(@FieldType(Driver, "vkCmdCopyBuffer") == vkCmdCopyBufferT);
        std.debug.assert(@FieldType(Driver, "vkInvalidateMappedMemoryRanges") == vkInvalidateMappedMemoryRangesT);
        std.debug.assert(@FieldType(Driver, "vkCmdClearColorImage") == vkCmdClearColorImageT);
        std.debug.assert(@FieldType(Driver, "vkCmdCopyBufferToImage") == vkCmdCopyBufferToImageT);
    }
}

test "opaque handle widths match the documented ABI" {
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(VkInstance));
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(VkPhysicalDevice));
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(VkDevice));
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(VkQueue));
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(VkSemaphore));
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(VkCommandPool));
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(VkCommandBuffer));
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(VkFence));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(VkSurfaceKHR));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(VkSwapchainKHR));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(VkImage));
}

test "structure-type sTypes match the spec" {
    try std.testing.expectEqual(@as(u32, 0), VK_STRUCTURE_TYPE_APPLICATION_INFO);
    try std.testing.expectEqual(@as(u32, 1), VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO);
    try std.testing.expectEqual(@as(u32, 2), VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO);
    try std.testing.expectEqual(@as(u32, 3), VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO);
    try std.testing.expectEqual(@as(u32, 9), VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO);
    try std.testing.expectEqual(@as(u32, 11), VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO);
    try std.testing.expectEqual(@as(u32, 39), VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO);
    try std.testing.expectEqual(@as(u32, 40), VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO);
    try std.testing.expectEqual(@as(u32, 44), VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER);
    try std.testing.expectEqual(@as(u32, 45), VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER);
    try std.testing.expectEqual(@as(u32, 1000001000), VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR);
    try std.testing.expectEqual(@as(u32, 1000001001), VK_STRUCTURE_TYPE_PRESENT_INFO_KHR);
    try std.testing.expectEqual(@as(u32, 1000004000), VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR);
    try std.testing.expectEqual(@as(u32, 1000059000), VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2);
    try std.testing.expectEqual(@as(u32, 1000059001), VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2);
    try std.testing.expectEqual(@as(u32, 1000083000), VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES);
    try std.testing.expectEqual(@as(u32, 1000094000), VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES);
    try std.testing.expectEqual(@as(u32, 1000177000), VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_8BIT_STORAGE_FEATURES);
    try std.testing.expectEqual(@as(u32, 1000207000), VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES);
    try std.testing.expectEqual(@as(u32, 1000207002), VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO);
    try std.testing.expectEqual(@as(u32, 1000207004), VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO);
    try std.testing.expectEqual(@as(u32, 1000207005), VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO);
    try std.testing.expectEqual(@as(u32, 1000314004), VK_STRUCTURE_TYPE_SUBMIT_INFO_2);
    try std.testing.expectEqual(@as(u32, 1000314005), VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO);
    try std.testing.expectEqual(@as(u32, 1000314006), VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO);
    try std.testing.expectEqual(@as(u32, 1), VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT);
}

test "surface and swapchain constants match the spec" {
    try std.testing.expectEqual(@as(u32, 37), VK_FORMAT_R8G8B8A8_UNORM);
    try std.testing.expectEqual(@as(u32, 44), VK_FORMAT_B8G8R8A8_UNORM);
    try std.testing.expectEqual(@as(u32, 0), VK_COLOR_SPACE_SRGB_NONLINEAR_KHR);
    try std.testing.expectEqual(@as(u32, 0), VK_PRESENT_MODE_IMMEDIATE_KHR);
    try std.testing.expectEqual(@as(u32, 1), VK_PRESENT_MODE_MAILBOX_KHR);
    try std.testing.expectEqual(@as(u32, 2), VK_PRESENT_MODE_FIFO_KHR);
    try std.testing.expectEqual(@as(u32, 0x1), VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    try std.testing.expectEqual(@as(u32, 0x2), VK_IMAGE_USAGE_TRANSFER_DST_BIT);
    try std.testing.expectEqual(@as(u32, 0x4), VK_IMAGE_USAGE_SAMPLED_BIT);
    try std.testing.expectEqual(@as(u32, 0x8), VK_IMAGE_USAGE_STORAGE_BIT);
    try std.testing.expectEqual(@as(u32, 0x10), VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT);
    try std.testing.expectEqual(@as(u32, 0), VK_IMAGE_LAYOUT_UNDEFINED);
    try std.testing.expectEqual(@as(u32, 7), VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    try std.testing.expectEqual(@as(u32, 1000001002), VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
    try std.testing.expectEqual(@as(u32, 0x1000), VK_ACCESS_TRANSFER_WRITE_BIT);
    try std.testing.expectEqual(@as(u32, 0x20), VK_ACCESS_SHADER_READ_BIT);
    try std.testing.expectEqual(@as(u32, 0x40), VK_ACCESS_SHADER_WRITE_BIT);
    try std.testing.expectEqual(@as(u32, 0x800), VK_ACCESS_TRANSFER_READ_BIT);
    try std.testing.expectEqual(@as(u32, 0x1), VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT);
    try std.testing.expectEqual(@as(u32, 0x800), VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
    try std.testing.expectEqual(@as(u32, 0x1000), VK_PIPELINE_STAGE_TRANSFER_BIT);
    try std.testing.expectEqual(@as(u32, 0x2000), VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
    try std.testing.expectEqual(@as(u32, 0x1), VK_IMAGE_ASPECT_COLOR_BIT);
    try std.testing.expectEqual(std.math.maxInt(u32), VK_QUEUE_FAMILY_IGNORED);
    try std.testing.expectEqual(@as(u32, 0x1), VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR);
    try std.testing.expectEqual(@as(u32, 0x100), VK_SURFACE_TRANSFORM_INHERIT_BIT_KHR);
    try std.testing.expectEqual(@as(u32, 0x1), VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR);
    try std.testing.expectEqual(@as(u32, 0x2), VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR);
    try std.testing.expectEqual(@as(u32, 0x4), VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR);
    try std.testing.expectEqual(@as(u32, 0x8), VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR);
    try std.testing.expectEqualStrings("VK_KHR_surface", VK_KHR_SURFACE_EXTENSION_NAME);
    try std.testing.expectEqualStrings("VK_KHR_xlib_surface", VK_KHR_XLIB_SURFACE_EXTENSION_NAME);
    try std.testing.expectEqualStrings("VK_KHR_swapchain", VK_KHR_SWAPCHAIN_EXTENSION_NAME);
    try std.testing.expectEqualStrings("VK_KHR_16bit_storage", VK_KHR_16BIT_STORAGE_EXTENSION_NAME);
    try std.testing.expectEqualStrings("VK_KHR_8bit_storage", VK_KHR_8BIT_STORAGE_EXTENSION_NAME);
    try std.testing.expectEqualStrings("VK_KHR_shader_float16_int8", VK_KHR_SHADER_FLOAT16_INT8_EXTENSION_NAME);
}

test "timeline-semaphore constants match the spec" {
    try std.testing.expectEqual(@as(u32, 0), VK_SEMAPHORE_TYPE_BINARY);
    try std.testing.expectEqual(@as(u32, 1), VK_SEMAPHORE_TYPE_TIMELINE);
    try std.testing.expectEqual(@as(u32, 1), VK_TRUE);
    try std.testing.expectEqual(@as(u32, 0), VK_FALSE);
    try std.testing.expectEqual(std.math.maxInt(u64), VK_WHOLE_TIMEOUT);
    try std.testing.expectEqualStrings(
        "VK_KHR_timeline_semaphore",
        VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME,
    );
}

test "API-version constants encode the VK_MAKE_API_VERSION packing" {
    try std.testing.expectEqual(@as(u32, (1 << 22) | (2 << 12)), VK_API_VERSION_1_2);
    try std.testing.expectEqual(@as(u32, (1 << 22) | (3 << 12)), VK_API_VERSION_1_3);
    try std.testing.expect(VK_API_VERSION_1_2 > VK_API_VERSION_1_1);
    try std.testing.expect(VK_API_VERSION_1_1 > VK_API_VERSION_1_0);
}

test "queue-flag bits match the spec" {
    try std.testing.expectEqual(@as(u32, 0x1), VK_QUEUE_GRAPHICS_BIT);
    try std.testing.expectEqual(@as(u32, 0x2), VK_QUEUE_COMPUTE_BIT);
    try std.testing.expectEqual(@as(u32, 0x4), VK_QUEUE_TRANSFER_BIT);
    try std.testing.expectEqual(@as(u32, 0x8), VK_QUEUE_SPARSE_BINDING_BIT);
}

test "subgroup operation bits match the spec" {
    try std.testing.expectEqual(@as(u32, 0x01), VK_SUBGROUP_FEATURE_BASIC_BIT);
    try std.testing.expectEqual(@as(u32, 0x02), VK_SUBGROUP_FEATURE_VOTE_BIT);
    try std.testing.expectEqual(@as(u32, 0x04), VK_SUBGROUP_FEATURE_ARITHMETIC_BIT);
    try std.testing.expectEqual(@as(u32, 0x08), VK_SUBGROUP_FEATURE_BALLOT_BIT);
    try std.testing.expectEqual(@as(u32, 0x10), VK_SUBGROUP_FEATURE_SHUFFLE_BIT);
    try std.testing.expectEqual(@as(u32, 0x20), VK_SUBGROUP_FEATURE_SHUFFLE_RELATIVE_BIT);
}

test "extension-name helper reads up to the first null byte" {
    var ext = VkExtensionProperties{
        .extensionName = @as([VK_MAX_EXTENSION_NAME_SIZE]u8, @splat(0)),
        .specVersion = 42,
    };
    const src = "VK_KHR_timeline_semaphore";
    @memcpy(ext.extensionName[0..src.len], src);
    try std.testing.expectEqualStrings(src, ext.name());
}

test "platformSupported reflects the loader-target set" {
    try std.testing.expectEqual(
        dynamic.hasHostCandidate(dynamic.vulkanLoaderCandidates()),
        platformSupported(),
    );
}

test "graphics structures match the C layouts of vulkan_core.h 1.4.341" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(VkPhysicalDeviceVulkan13Features));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(VkPhysicalDeviceVulkan13Features, "dynamicRendering"));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(VkFormatProperties));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(VkMemoryBarrier));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(VkMemoryBarrier, "dstAccessMask"));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(VkImageCreateInfo));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(VkImageCreateInfo, "initialLayout"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(VkImageCreateInfo, "pQueueFamilyIndices"));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(VkComponentMapping));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(VkImageViewCreateInfo));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(VkImageViewCreateInfo, "subresourceRange"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(VkImageViewCreateInfo, "image"));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(VkSamplerCreateInfo));
    try std.testing.expectEqual(@as(usize, 76), @offsetOf(VkSamplerCreateInfo, "unnormalizedCoordinates"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(VkDescriptorImageInfo));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(VkVertexInputBindingDescription));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(VkVertexInputAttributeDescription));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(VkPipelineVertexInputStateCreateInfo));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(VkPipelineVertexInputStateCreateInfo, "pVertexAttributeDescriptions"));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(VkPipelineInputAssemblyStateCreateInfo));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(VkViewport));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(VkOffset2D));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(VkRect2D));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(VkPipelineViewportStateCreateInfo));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(VkPipelineViewportStateCreateInfo, "pScissors"));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(VkPipelineRasterizationStateCreateInfo));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(VkPipelineRasterizationStateCreateInfo, "lineWidth"));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(VkPipelineMultisampleStateCreateInfo));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(VkPipelineMultisampleStateCreateInfo, "pSampleMask"));
    try std.testing.expectEqual(@as(usize, 44), @offsetOf(VkPipelineMultisampleStateCreateInfo, "alphaToOneEnable"));
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(VkStencilOpState));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(VkPipelineDepthStencilStateCreateInfo));
    try std.testing.expectEqual(@as(usize, 100), @offsetOf(VkPipelineDepthStencilStateCreateInfo, "maxDepthBounds"));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(VkPipelineColorBlendAttachmentState));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(VkPipelineColorBlendStateCreateInfo));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(VkPipelineColorBlendStateCreateInfo, "blendConstants"));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(VkPipelineDynamicStateCreateInfo));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(VkPipelineRenderingCreateInfo));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(VkPipelineRenderingCreateInfo, "depthAttachmentFormat"));
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(VkGraphicsPipelineCreateInfo));
    try std.testing.expectEqual(@as(usize, 104), @offsetOf(VkGraphicsPipelineCreateInfo, "layout"));
    try std.testing.expectEqual(@as(usize, 136), @offsetOf(VkGraphicsPipelineCreateInfo, "basePipelineIndex"));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(VkClearDepthStencilValue));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(VkClearValue));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(VkRenderingAttachmentInfo));
    try std.testing.expectEqual(@as(usize, 52), @offsetOf(VkRenderingAttachmentInfo, "clearValue"));
    try std.testing.expectEqual(@as(usize, 44), @offsetOf(VkRenderingAttachmentInfo, "loadOp"));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(VkRenderingInfo));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(VkRenderingInfo, "pColorAttachments"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(VkRenderingInfo, "pStencilAttachment"));
}

test "dmabuf export structures match the C layouts of vulkan_core.h 1.4.341" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(VkFormatProperties2));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(VkFormatProperties2, "formatProperties"));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(VkDrmFormatModifierPropertiesEXT));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(VkDrmFormatModifierPropertiesEXT, "drmFormatModifierTilingFeatures"));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(VkDrmFormatModifierPropertiesListEXT));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(VkDrmFormatModifierPropertiesListEXT, "pDrmFormatModifierProperties"));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(VkImageDrmFormatModifierListCreateInfoEXT));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(VkImageDrmFormatModifierListCreateInfoEXT, "pDrmFormatModifiers"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(VkImageDrmFormatModifierPropertiesEXT));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(VkImageDrmFormatModifierPropertiesEXT, "drmFormatModifier"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(VkExternalMemoryImageCreateInfo));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(VkExternalMemoryImageCreateInfo, "handleTypes"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(VkExportMemoryAllocateInfo));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(VkMemoryDedicatedAllocateInfo));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(VkMemoryDedicatedAllocateInfo, "buffer"));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(VkMemoryGetFdInfoKHR));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(VkMemoryGetFdInfoKHR, "handleType"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(VkExportSemaphoreCreateInfo));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(VkSemaphoreGetFdInfoKHR));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(VkSemaphoreGetFdInfoKHR, "handleType"));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(VkPhysicalDeviceDrmPropertiesEXT));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(VkPhysicalDeviceDrmPropertiesEXT, "renderMinor"));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(VkImageSubresource));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(VkSubresourceLayout));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(VkSubresourceLayout, "depthPitch"));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFD), VK_QUEUE_FAMILY_FOREIGN_EXT);
    try std.testing.expectEqual(@as(u32, 1000158000), VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT);
}
