const std = @import("std");
const apple = @import("root.zig");
const sys = @import("../root.zig");

pub const available = sys.capabilities.current.supportsAppleMetal();

pub const Device = *opaque {};
pub const CommandQueue = *opaque {};
pub const CommandBuffer = *opaque {};
pub const ComputeCommandEncoder = *opaque {};
pub const SharedEvent = *opaque {};
pub const Buffer = *opaque {};
pub const Library = *opaque {};
pub const Function = *opaque {};
pub const ComputePipelineState = *opaque {};
pub const CompileOptions = *opaque {};
pub const Texture = *opaque {};
pub const TextureDescriptor = *opaque {};
pub const SamplerDescriptor = *opaque {};
pub const SamplerState = *opaque {};
pub const VertexDescriptor = *opaque {};
pub const RenderPipelineDescriptor = *opaque {};
pub const RenderPipelineState = *opaque {};
pub const DepthStencilState = *opaque {};
pub const RenderPassDescriptor = *opaque {};
pub const RenderCommandEncoder = *opaque {};
pub const BlitCommandEncoder = *opaque {};
pub const IndirectCommandBufferDescriptor = *opaque {};
pub const IndirectCommandBuffer = *opaque {};
pub const IndirectRenderCommand = *opaque {};
pub const Drawable = *opaque {};
/// A `CAMetalLayer`.
pub const Layer = *opaque {};

pub const ResourceOptions = apple.foundation.NSUInteger;
pub const resource_storage_mode_shared: ResourceOptions = 0;

pub const Size = extern struct {
    width: apple.foundation.NSUInteger,
    height: apple.foundation.NSUInteger,
    depth: apple.foundation.NSUInteger,
};

pub const Origin = extern struct {
    x: apple.foundation.NSUInteger = 0,
    y: apple.foundation.NSUInteger = 0,
    z: apple.foundation.NSUInteger = 0,
};

/// `MTLViewport`: a pixel rectangle with its origin at the top left, and the depth range.
pub const Viewport = extern struct {
    origin_x: f64,
    origin_y: f64,
    width: f64,
    height: f64,
    znear: f64,
    zfar: f64,
};

pub const ScissorRect = extern struct {
    x: apple.foundation.NSUInteger,
    y: apple.foundation.NSUInteger,
    width: apple.foundation.NSUInteger,
    height: apple.foundation.NSUInteger,
};

pub const ClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

/// `NSRange`.
pub const Range = extern struct {
    location: apple.foundation.NSUInteger,
    length: apple.foundation.NSUInteger,
};

pub const PixelFormat = enum(apple.foundation.NSUInteger) {
    rgba8_unorm = 70,
    rgba8_unorm_srgb = 71,
    bgra8_unorm = 80,
    bgra8_unorm_srgb = 81,
    rgba16_float = 115,
    depth32_float = 252,
    _,
};

pub const VertexFormat = enum(apple.foundation.NSUInteger) {
    float = 28,
    float2 = 29,
    float3 = 30,
    float4 = 31,
    uint = 36,
    uint2 = 37,
    uint3 = 38,
    uint4 = 39,
    _,
};

pub const VertexStepFunction = enum(apple.foundation.NSUInteger) {
    per_vertex = 1,
    per_instance = 2,
    _,
};

pub const PrimitiveType = enum(apple.foundation.NSUInteger) {
    line = 1,
    line_strip = 2,
    triangle = 3,
    triangle_strip = 4,
    _,
};

pub const IndexType = enum(apple.foundation.NSUInteger) {
    uint16 = 0,
    uint32 = 1,
    _,
};

/// `MTLCompareFunction`, which applies as `fragment op stored`.
pub const CompareFunction = enum(apple.foundation.NSUInteger) {
    never = 0,
    less = 1,
    equal = 2,
    less_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_equal = 6,
    always = 7,
    _,
};

pub const BlendFactor = enum(apple.foundation.NSUInteger) {
    zero = 0,
    one = 1,
    source_alpha = 4,
    one_minus_source_alpha = 5,
    _,
};

/// The factors of one additive blend, `source * s + destination * d` per channel group.
pub const Blend = struct {
    source_rgb: BlendFactor,
    destination_rgb: BlendFactor,
    source_alpha: BlendFactor,
    destination_alpha: BlendFactor,
};

pub const LoadAction = enum(apple.foundation.NSUInteger) {
    dont_care = 0,
    load = 1,
    clear = 2,
    _,
};

pub const StorageMode = enum(apple.foundation.NSUInteger) {
    shared = 0,
    managed = 1,
    private = 2,
    _,
};

pub const TextureUsage = apple.foundation.NSUInteger;
pub const texture_usage_shader_read: TextureUsage = 1 << 0;
pub const texture_usage_render_target: TextureUsage = 1 << 2;

pub const SamplerFilter = enum(apple.foundation.NSUInteger) {
    nearest = 0,
    linear = 1,
    _,
};

pub const SamplerAddressMode = enum(apple.foundation.NSUInteger) {
    clamp_to_edge = 0,
    repeat = 2,
    _,
};

pub const SamplerMipFilter = enum(apple.foundation.NSUInteger) {
    not_mipmapped = 0,
    nearest = 1,
    linear = 2,
    _,
};

pub const IndirectCommandType = apple.foundation.NSUInteger;
pub const indirect_command_draw: IndirectCommandType = 1 << 0;
pub const indirect_command_draw_indexed: IndirectCommandType = 1 << 1;

pub const ResourceUsage = apple.foundation.NSUInteger;
pub const resource_usage_read: ResourceUsage = 1 << 0;

pub const RenderStages = apple.foundation.NSUInteger;
pub const render_stage_vertex: RenderStages = 1 << 0;
pub const render_stage_fragment: RenderStages = 1 << 1;

/// How a library compiled from source treats floating point.
pub const MathSetting = enum {
    /// `mathMode` is `MTLMathModeSafe`, which macOS 15 introduced.
    math_mode_safe,
    /// `fastMathEnabled` is `NO`, the older property the safe mode replaces.
    fast_math_disabled,
};

const math_mode_safe: apple.foundation.NSInteger = 0;

pub const CommandBufferStatus = enum(apple.foundation.NSUInteger) {
    not_enqueued = 0,
    enqueued = 1,
    committed = 2,
    scheduled = 3,
    completed = 4,
    failed = 5,
    _,
};

pub const CommandBufferError = enum(apple.foundation.NSUInteger) {
    none = 0,
    internal = 1,
    timeout = 2,
    page_fault = 3,
    access_revoked = 4,
    not_permitted = 7,
    out_of_memory = 8,
    invalid_resource = 9,
    memoryless = 10,
    device_removed = 11,
    stack_overflow = 12,
    _,
};

extern fn MTLCreateSystemDefaultDevice() ?Device;

pub fn systemDefaultDevice() ?Device {
    return MTLCreateSystemDefaultDevice();
}

pub fn newCommandQueue(device: Device) ?CommandQueue {
    return apple.objc.send(?CommandQueue, @ptrCast(device), apple.objc.selector("newCommandQueue"), .{});
}

pub fn newSharedEvent(device: Device) ?SharedEvent {
    return apple.objc.send(?SharedEvent, @ptrCast(device), apple.objc.selector("newSharedEvent"), .{});
}

pub fn newBuffer(device: Device, byte_size: usize) ?Buffer {
    return apple.objc.send(
        ?Buffer,
        @ptrCast(device),
        apple.objc.selector("newBufferWithLength:options:"),
        .{ byte_size, resource_storage_mode_shared },
    );
}

pub fn newLibraryWithSource(
    device: Device,
    source: apple.foundation.String,
    options: ?CompileOptions,
    out_error: *?apple.foundation.Error,
) ?Library {
    return apple.objc.send(
        ?Library,
        @ptrCast(device),
        apple.objc.selector("newLibraryWithSource:options:error:"),
        .{ source, options, out_error },
    );
}

pub fn newLibraryWithData(
    device: Device,
    data: apple.dispatch.Data,
    out_error: *?apple.foundation.Error,
) ?Library {
    return apple.objc.send(
        ?Library,
        @ptrCast(device),
        apple.objc.selector("newLibraryWithData:error:"),
        .{ data, out_error },
    );
}

pub fn newFunction(library: Library, name: apple.foundation.String) ?Function {
    return apple.objc.send(?Function, @ptrCast(library), apple.objc.selector("newFunctionWithName:"), .{name});
}

pub fn newComputePipelineState(
    device: Device,
    function: Function,
    out_error: *?apple.foundation.Error,
) ?ComputePipelineState {
    return apple.objc.send(
        ?ComputePipelineState,
        @ptrCast(device),
        apple.objc.selector("newComputePipelineStateWithFunction:error:"),
        .{ function, out_error },
    );
}

pub fn commandBuffer(queue: CommandQueue) ?CommandBuffer {
    return apple.objc.send(?CommandBuffer, @ptrCast(queue), apple.objc.selector("commandBuffer"), .{});
}

pub fn computeCommandEncoder(command_buffer: CommandBuffer) ?ComputeCommandEncoder {
    return apple.objc.send(
        ?ComputeCommandEncoder,
        @ptrCast(command_buffer),
        apple.objc.selector("computeCommandEncoder"),
        .{},
    );
}

pub fn setSignaledValue(event: SharedEvent, value: u64) void {
    apple.objc.send(void, @ptrCast(event), apple.objc.selector("setSignaledValue:"), .{value});
}

pub fn signaledValue(event: SharedEvent) u64 {
    return apple.objc.send(u64, @ptrCast(event), apple.objc.selector("signaledValue"), .{});
}

pub fn encodeSignalEvent(command_buffer: CommandBuffer, event: SharedEvent, value: u64) void {
    apple.objc.send(
        void,
        @ptrCast(command_buffer),
        apple.objc.selector("encodeSignalEvent:value:"),
        .{ event, value },
    );
}

pub fn encodeWaitForEvent(command_buffer: CommandBuffer, event: SharedEvent, value: u64) void {
    apple.objc.send(
        void,
        @ptrCast(command_buffer),
        apple.objc.selector("encodeWaitForEvent:value:"),
        .{ event, value },
    );
}

pub fn setComputePipelineState(encoder: ComputeCommandEncoder, pipeline: ComputePipelineState) void {
    apple.objc.send(
        void,
        @ptrCast(encoder),
        apple.objc.selector("setComputePipelineState:"),
        .{pipeline},
    );
}

pub fn setBuffer(
    encoder: ComputeCommandEncoder,
    buffer: Buffer,
    offset: apple.foundation.NSUInteger,
    index: apple.foundation.NSUInteger,
) void {
    apple.objc.send(
        void,
        @ptrCast(encoder),
        apple.objc.selector("setBuffer:offset:atIndex:"),
        .{ buffer, offset, index },
    );
}

pub fn setBytes(
    encoder: ComputeCommandEncoder,
    bytes: *const anyopaque,
    length: apple.foundation.NSUInteger,
    index: apple.foundation.NSUInteger,
) void {
    apple.objc.send(
        void,
        @ptrCast(encoder),
        apple.objc.selector("setBytes:length:atIndex:"),
        .{ bytes, length, index },
    );
}

pub fn dispatchThreadgroups(
    encoder: ComputeCommandEncoder,
    threadgroups: Size,
    threads_per_threadgroup: Size,
) void {
    apple.objc.send(
        void,
        @ptrCast(encoder),
        apple.objc.selector("dispatchThreadgroups:threadsPerThreadgroup:"),
        .{ threadgroups, threads_per_threadgroup },
    );
}

pub fn endEncoding(encoder: ComputeCommandEncoder) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("endEncoding"), .{});
}

pub fn commit(command_buffer: CommandBuffer) void {
    apple.objc.send(void, @ptrCast(command_buffer), apple.objc.selector("commit"), .{});
}

pub fn waitUntilCompleted(command_buffer: CommandBuffer) void {
    apple.objc.send(void, @ptrCast(command_buffer), apple.objc.selector("waitUntilCompleted"), .{});
}

pub fn commandBufferStatus(command_buffer: CommandBuffer) CommandBufferStatus {
    const raw = apple.objc.send(
        apple.foundation.NSUInteger,
        @ptrCast(command_buffer),
        apple.objc.selector("status"),
        .{},
    );
    return @fromBackingInt(@intCast(raw));
}

pub fn commandBufferError(command_buffer: CommandBuffer) ?apple.foundation.Error {
    return apple.objc.send(
        ?apple.foundation.Error,
        @ptrCast(command_buffer),
        apple.objc.selector("error"),
        .{},
    );
}

pub fn bufferContents(buffer: Buffer) ?*anyopaque {
    return apple.objc.send(?*anyopaque, @ptrCast(buffer), apple.objc.selector("contents"), .{});
}

/// Compile options with fast math off: no reassociation, no finite-math assumption and no flush of
/// subnormals beyond what the device does itself. The caller releases the options.
pub fn newSafeCompileOptions(setting: *MathSetting) ?CompileOptions {
    const options = newObject(CompileOptions, "MTLCompileOptions") orelse return null;
    if (apple.objc.respondsTo(@ptrCast(options), apple.objc.selector("setMathMode:"))) {
        apple.objc.send(void, @ptrCast(options), apple.objc.selector("setMathMode:"), .{math_mode_safe});
        setting.* = .math_mode_safe;
    } else {
        apple.objc.send(void, @ptrCast(options), apple.objc.selector("setFastMathEnabled:"), .{apple.objc.boolean(false)});
        setting.* = .fast_math_disabled;
    }
    return options;
}

pub fn deviceName(device: Device) ?apple.foundation.String {
    return apple.objc.send(?apple.foundation.String, @ptrCast(device), apple.objc.selector("name"), .{});
}

/// A private 2D texture without mipmaps. The caller releases it.
pub fn newTexture2D(
    device: Device,
    format: PixelFormat,
    width: u32,
    height: u32,
    usage: TextureUsage,
    storage: StorageMode,
) ?Texture {
    const descriptor_class = apple.objc.class("MTLTextureDescriptor") orelse return null;
    const descriptor = apple.objc.send(
        ?TextureDescriptor,
        descriptor_class,
        apple.objc.selector("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
        .{ @backingInt(format), @as(apple.foundation.NSUInteger, width), @as(apple.foundation.NSUInteger, height), apple.objc.boolean(false) },
    ) orelse return null;
    apple.objc.send(void, @ptrCast(descriptor), apple.objc.selector("setUsage:"), .{usage});
    apple.objc.send(void, @ptrCast(descriptor), apple.objc.selector("setStorageMode:"), .{@backingInt(storage)});
    return apple.objc.send(?Texture, @ptrCast(device), apple.objc.selector("newTextureWithDescriptor:"), .{descriptor});
}

/// A 2D texture of `levels` mip levels, level 0 of `width` by `height`. The caller releases it.
pub fn newTexture2DLevels(
    device: Device,
    format: PixelFormat,
    width: u32,
    height: u32,
    levels: u32,
    usage: TextureUsage,
    storage: StorageMode,
) ?Texture {
    const descriptor_class = apple.objc.class("MTLTextureDescriptor") orelse return null;
    const descriptor = apple.objc.send(
        ?TextureDescriptor,
        descriptor_class,
        apple.objc.selector("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
        .{ @backingInt(format), @as(apple.foundation.NSUInteger, width), @as(apple.foundation.NSUInteger, height), apple.objc.boolean(levels > 1) },
    ) orelse return null;
    apple.objc.send(void, @ptrCast(descriptor), apple.objc.selector("setMipmapLevelCount:"), .{@as(apple.foundation.NSUInteger, levels)});
    apple.objc.send(void, @ptrCast(descriptor), apple.objc.selector("setUsage:"), .{usage});
    apple.objc.send(void, @ptrCast(descriptor), apple.objc.selector("setStorageMode:"), .{@backingInt(storage)});
    return apple.objc.send(?Texture, @ptrCast(device), apple.objc.selector("newTextureWithDescriptor:"), .{descriptor});
}

/// A sampler that reads `mip` levels and averages up to `max_anisotropy` texels along a read's
/// long axis. The caller releases it.
pub fn newSamplerStateMipmapped(
    device: Device,
    filter: SamplerFilter,
    address: SamplerAddressMode,
    mip: SamplerMipFilter,
    max_anisotropy: u32,
) ?SamplerState {
    std.debug.assert(max_anisotropy >= 1 and max_anisotropy <= 16);
    const descriptor = newObject(SamplerDescriptor, "MTLSamplerDescriptor") orelse return null;
    defer apple.objc.release(descriptor);
    const target: apple.objc.Id = @ptrCast(descriptor);
    apple.objc.send(void, target, apple.objc.selector("setMinFilter:"), .{@backingInt(filter)});
    apple.objc.send(void, target, apple.objc.selector("setMagFilter:"), .{@backingInt(filter)});
    apple.objc.send(void, target, apple.objc.selector("setMipFilter:"), .{@backingInt(mip)});
    apple.objc.send(void, target, apple.objc.selector("setMaxAnisotropy:"), .{@as(apple.foundation.NSUInteger, max_anisotropy)});
    apple.objc.send(void, target, apple.objc.selector("setSAddressMode:"), .{@backingInt(address)});
    apple.objc.send(void, target, apple.objc.selector("setTAddressMode:"), .{@backingInt(address)});
    return apple.objc.send(?SamplerState, @ptrCast(device), apple.objc.selector("newSamplerStateWithDescriptor:"), .{descriptor});
}

/// A sampler without mipmaps. The caller releases it.
pub fn newSamplerState(device: Device, filter: SamplerFilter, address: SamplerAddressMode) ?SamplerState {
    const descriptor = newObject(SamplerDescriptor, "MTLSamplerDescriptor") orelse return null;
    defer apple.objc.release(descriptor);
    const target: apple.objc.Id = @ptrCast(descriptor);
    apple.objc.send(void, target, apple.objc.selector("setMinFilter:"), .{@backingInt(filter)});
    apple.objc.send(void, target, apple.objc.selector("setMagFilter:"), .{@backingInt(filter)});
    apple.objc.send(void, target, apple.objc.selector("setSAddressMode:"), .{@backingInt(address)});
    apple.objc.send(void, target, apple.objc.selector("setTAddressMode:"), .{@backingInt(address)});
    return apple.objc.send(?SamplerState, @ptrCast(device), apple.objc.selector("newSamplerStateWithDescriptor:"), .{descriptor});
}

/// An empty vertex descriptor, autoreleased.
pub fn vertexDescriptor() ?VertexDescriptor {
    const descriptor_class = apple.objc.class("MTLVertexDescriptor") orelse return null;
    return apple.objc.send(?VertexDescriptor, descriptor_class, apple.objc.selector("vertexDescriptor"), .{});
}

pub fn setVertexAttribute(
    descriptor: VertexDescriptor,
    index: u32,
    format: VertexFormat,
    offset: u32,
    buffer_index: u32,
) void {
    const attributes = apple.objc.send(apple.objc.Id, @ptrCast(descriptor), apple.objc.selector("attributes"), .{});
    const attribute = subscript(attributes, index);
    apple.objc.send(void, attribute, apple.objc.selector("setFormat:"), .{@backingInt(format)});
    apple.objc.send(void, attribute, apple.objc.selector("setOffset:"), .{@as(apple.foundation.NSUInteger, offset)});
    apple.objc.send(void, attribute, apple.objc.selector("setBufferIndex:"), .{@as(apple.foundation.NSUInteger, buffer_index)});
}

pub fn setVertexLayout(
    descriptor: VertexDescriptor,
    buffer_index: u32,
    stride: u32,
    step: VertexStepFunction,
) void {
    const layouts = apple.objc.send(apple.objc.Id, @ptrCast(descriptor), apple.objc.selector("layouts"), .{});
    const layout = subscript(layouts, buffer_index);
    apple.objc.send(void, layout, apple.objc.selector("setStride:"), .{@as(apple.foundation.NSUInteger, stride)});
    apple.objc.send(void, layout, apple.objc.selector("setStepFunction:"), .{@backingInt(step)});
    apple.objc.send(void, layout, apple.objc.selector("setStepRate:"), .{@as(apple.foundation.NSUInteger, 1)});
}

/// The description of a render pipeline with one color attachment. The caller releases it.
pub const RenderPipelineDesc = struct {
    vertex: Function,
    fragment: Function,
    vertex_descriptor: ?VertexDescriptor,
    color_format: PixelFormat,
    blend: ?Blend,
    depth_format: ?PixelFormat,
    /// Whether an indirect command buffer may set the pipeline.
    indirect: bool,
};

pub fn newRenderPipelineState(
    device: Device,
    desc: RenderPipelineDesc,
    out_error: *?apple.foundation.Error,
) ?RenderPipelineState {
    const descriptor = newObject(RenderPipelineDescriptor, "MTLRenderPipelineDescriptor") orelse return null;
    defer apple.objc.release(descriptor);
    const target: apple.objc.Id = @ptrCast(descriptor);
    apple.objc.send(void, target, apple.objc.selector("setVertexFunction:"), .{desc.vertex});
    apple.objc.send(void, target, apple.objc.selector("setFragmentFunction:"), .{desc.fragment});
    apple.objc.send(void, target, apple.objc.selector("setVertexDescriptor:"), .{desc.vertex_descriptor});
    if (desc.depth_format) |format| {
        apple.objc.send(void, target, apple.objc.selector("setDepthAttachmentPixelFormat:"), .{@backingInt(format)});
    }
    apple.objc.send(void, target, apple.objc.selector("setSupportIndirectCommandBuffers:"), .{apple.objc.boolean(desc.indirect)});
    const attachments = apple.objc.send(apple.objc.Id, target, apple.objc.selector("colorAttachments"), .{});
    const color = subscript(attachments, 0);
    apple.objc.send(void, color, apple.objc.selector("setPixelFormat:"), .{@backingInt(desc.color_format)});
    if (desc.blend) |blend| {
        apple.objc.send(void, color, apple.objc.selector("setBlendingEnabled:"), .{apple.objc.boolean(true)});
        apple.objc.send(void, color, apple.objc.selector("setSourceRGBBlendFactor:"), .{@backingInt(blend.source_rgb)});
        apple.objc.send(void, color, apple.objc.selector("setDestinationRGBBlendFactor:"), .{@backingInt(blend.destination_rgb)});
        apple.objc.send(void, color, apple.objc.selector("setSourceAlphaBlendFactor:"), .{@backingInt(blend.source_alpha)});
        apple.objc.send(void, color, apple.objc.selector("setDestinationAlphaBlendFactor:"), .{@backingInt(blend.destination_alpha)});
    }
    return apple.objc.send(
        ?RenderPipelineState,
        @ptrCast(device),
        apple.objc.selector("newRenderPipelineStateWithDescriptor:error:"),
        .{ descriptor, out_error },
    );
}

/// A depth test without stencil. The caller releases it.
pub fn newDepthStencilState(device: Device, compare: CompareFunction, write: bool) ?DepthStencilState {
    const descriptor = newObject(apple.objc.Id, "MTLDepthStencilDescriptor") orelse return null;
    defer apple.objc.release(descriptor);
    apple.objc.send(void, descriptor, apple.objc.selector("setDepthCompareFunction:"), .{@backingInt(compare)});
    apple.objc.send(void, descriptor, apple.objc.selector("setDepthWriteEnabled:"), .{apple.objc.boolean(write)});
    return apple.objc.send(?DepthStencilState, @ptrCast(device), apple.objc.selector("newDepthStencilStateWithDescriptor:"), .{descriptor});
}

/// An empty render pass descriptor, autoreleased.
pub fn renderPassDescriptor() ?RenderPassDescriptor {
    const descriptor_class = apple.objc.class("MTLRenderPassDescriptor") orelse return null;
    return apple.objc.send(?RenderPassDescriptor, descriptor_class, apple.objc.selector("renderPassDescriptor"), .{});
}

/// Makes `texture` color attachment 0, stored at the end of the pass.
pub fn setColorAttachment(descriptor: RenderPassDescriptor, texture: Texture, load: LoadAction, clear: ClearColor) void {
    const attachments = apple.objc.send(apple.objc.Id, @ptrCast(descriptor), apple.objc.selector("colorAttachments"), .{});
    const color = subscript(attachments, 0);
    setAttachment(color, @ptrCast(texture), load);
    apple.objc.send(void, color, apple.objc.selector("setClearColor:"), .{clear});
}

/// Makes `texture` the depth attachment, stored at the end of the pass.
pub fn setDepthAttachment(descriptor: RenderPassDescriptor, texture: Texture, load: LoadAction, clear: f64) void {
    const depth = apple.objc.send(apple.objc.Id, @ptrCast(descriptor), apple.objc.selector("depthAttachment"), .{});
    setAttachment(depth, @ptrCast(texture), load);
    apple.objc.send(void, depth, apple.objc.selector("setClearDepth:"), .{clear});
}

fn setAttachment(attachment: apple.objc.Id, texture: apple.objc.Id, load: LoadAction) void {
    const store_action_store: apple.foundation.NSUInteger = 1;
    apple.objc.send(void, attachment, apple.objc.selector("setTexture:"), .{texture});
    apple.objc.send(void, attachment, apple.objc.selector("setLoadAction:"), .{@backingInt(load)});
    apple.objc.send(void, attachment, apple.objc.selector("setStoreAction:"), .{store_action_store});
}

pub fn renderCommandEncoder(command_buffer: CommandBuffer, descriptor: RenderPassDescriptor) ?RenderCommandEncoder {
    return apple.objc.send(
        ?RenderCommandEncoder,
        @ptrCast(command_buffer),
        apple.objc.selector("renderCommandEncoderWithDescriptor:"),
        .{descriptor},
    );
}

pub fn blitCommandEncoder(command_buffer: CommandBuffer) ?BlitCommandEncoder {
    return apple.objc.send(?BlitCommandEncoder, @ptrCast(command_buffer), apple.objc.selector("blitCommandEncoder"), .{});
}

pub fn presentDrawable(command_buffer: CommandBuffer, drawable: Drawable) void {
    apple.objc.send(void, @ptrCast(command_buffer), apple.objc.selector("presentDrawable:"), .{drawable});
}

pub fn setRenderPipelineState(encoder: RenderCommandEncoder, pipeline: RenderPipelineState) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setRenderPipelineState:"), .{pipeline});
}

pub fn setDepthStencilState(encoder: RenderCommandEncoder, state: ?DepthStencilState) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setDepthStencilState:"), .{state});
}

pub fn setDepthBias(encoder: RenderCommandEncoder, constant: f32, slope: f32, clamp: f32) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setDepthBias:slopeScale:clamp:"), .{ constant, slope, clamp });
}

pub fn setViewport(encoder: RenderCommandEncoder, viewport: Viewport) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setViewport:"), .{viewport});
}

pub fn setScissorRect(encoder: RenderCommandEncoder, rect: ScissorRect) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setScissorRect:"), .{rect});
}

/// `MTLWinding`: the order, as seen on screen, of a front-facing triangle's vertices.
pub const Winding = enum(apple.foundation.NSUInteger) {
    clockwise = 0,
    counter_clockwise = 1,
};

pub fn setFrontFacingWinding(encoder: RenderCommandEncoder, winding: Winding) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setFrontFacingWinding:"), .{@backingInt(winding)});
}

/// `MTLCullMode`: the faces, by the encoder's front-facing winding, that it leaves undrawn.
pub const CullMode = enum(apple.foundation.NSUInteger) {
    none = 0,
    front = 1,
    back = 2,
};

pub fn setCullMode(encoder: RenderCommandEncoder, mode: CullMode) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setCullMode:"), .{@backingInt(mode)});
}

pub fn setVertexBuffer(encoder: RenderCommandEncoder, buffer: Buffer, offset: u64, index: u32) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setVertexBuffer:offset:atIndex:"), .{ buffer, offset, @as(apple.foundation.NSUInteger, index) });
}

pub fn setFragmentBuffer(encoder: RenderCommandEncoder, buffer: Buffer, offset: u64, index: u32) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setFragmentBuffer:offset:atIndex:"), .{ buffer, offset, @as(apple.foundation.NSUInteger, index) });
}

pub fn setVertexBytes(encoder: RenderCommandEncoder, bytes: []const u8, index: u32) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setVertexBytes:length:atIndex:"), .{ @as(*const anyopaque, bytes.ptr), @as(apple.foundation.NSUInteger, bytes.len), @as(apple.foundation.NSUInteger, index) });
}

pub fn setFragmentBytes(encoder: RenderCommandEncoder, bytes: []const u8, index: u32) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setFragmentBytes:length:atIndex:"), .{ @as(*const anyopaque, bytes.ptr), @as(apple.foundation.NSUInteger, bytes.len), @as(apple.foundation.NSUInteger, index) });
}

pub fn setVertexTexture(encoder: RenderCommandEncoder, texture: Texture, sampler: SamplerState, index: u32) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setVertexTexture:atIndex:"), .{ texture, @as(apple.foundation.NSUInteger, index) });
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setVertexSamplerState:atIndex:"), .{ sampler, @as(apple.foundation.NSUInteger, index) });
}

pub fn setFragmentTexture(encoder: RenderCommandEncoder, texture: Texture, sampler: SamplerState, index: u32) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setFragmentTexture:atIndex:"), .{ texture, @as(apple.foundation.NSUInteger, index) });
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("setFragmentSamplerState:atIndex:"), .{ sampler, @as(apple.foundation.NSUInteger, index) });
}

pub fn drawPrimitives(
    encoder: RenderCommandEncoder,
    primitive: PrimitiveType,
    first_vertex: u32,
    vertex_count: u32,
    instance_count: u32,
    first_instance: u32,
) void {
    apple.objc.send(
        void,
        @ptrCast(encoder),
        apple.objc.selector("drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:"),
        drawArguments(primitive, first_vertex, vertex_count, instance_count, first_instance),
    );
}

pub fn drawIndexedPrimitives(
    encoder: RenderCommandEncoder,
    primitive: PrimitiveType,
    index_count: u32,
    index_type: IndexType,
    index_buffer: Buffer,
    index_offset: u64,
    instance_count: u32,
    base_vertex: i32,
    first_instance: u32,
) void {
    apple.objc.send(
        void,
        @ptrCast(encoder),
        apple.objc.selector("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:"),
        drawIndexedArguments(primitive, index_count, index_type, index_buffer, index_offset, instance_count, base_vertex, first_instance),
    );
}

/// Makes `buffers` resident for the commands of an indirect command buffer that read them.
pub fn useResources(encoder: RenderCommandEncoder, buffers: []const Buffer) void {
    if (buffers.len == 0) return;
    apple.objc.send(
        void,
        @ptrCast(encoder),
        apple.objc.selector("useResources:count:usage:stages:"),
        .{ @as(*const anyopaque, @ptrCast(buffers.ptr)), @as(apple.foundation.NSUInteger, buffers.len), resource_usage_read, render_stage_vertex | render_stage_fragment },
    );
}

pub fn executeCommands(encoder: RenderCommandEncoder, commands: IndirectCommandBuffer, range: Range) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("executeCommandsInBuffer:withRange:"), .{ commands, range });
}

pub fn endRenderEncoding(encoder: RenderCommandEncoder) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("endEncoding"), .{});
}

pub fn endBlitEncoding(encoder: BlitCommandEncoder) void {
    apple.objc.send(void, @ptrCast(encoder), apple.objc.selector("endEncoding"), .{});
}

/// Copies rows of `bytes_per_row` from `buffer` into the whole of mip 0 of `texture`.
pub fn copyBufferToTexture(
    encoder: BlitCommandEncoder,
    buffer: Buffer,
    bytes_per_row: u64,
    texture: Texture,
    size: Size,
) void {
    copyBufferToTextureLevel(encoder, buffer, bytes_per_row, texture, size, 0);
}

/// Copies rows of `bytes_per_row` from `buffer` into the whole of mip `level` of `texture`, whose
/// extent is `size`.
pub fn copyBufferToTextureLevel(
    encoder: BlitCommandEncoder,
    buffer: Buffer,
    bytes_per_row: u64,
    texture: Texture,
    size: Size,
    level: u32,
) void {
    apple.objc.send(
        void,
        @ptrCast(encoder),
        apple.objc.selector("copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:"),
        .{ buffer, @as(apple.foundation.NSUInteger, 0), bytes_per_row, bytes_per_row * size.height, size, texture, @as(apple.foundation.NSUInteger, 0), @as(apple.foundation.NSUInteger, level), Origin{} },
    );
}

/// Copies the whole of mip 0 of `texture` into `buffer`, rows of `bytes_per_row` from the top.
pub fn copyTextureToBuffer(
    encoder: BlitCommandEncoder,
    texture: Texture,
    size: Size,
    buffer: Buffer,
    bytes_per_row: u64,
) void {
    copyTextureLevelToBuffer(encoder, texture, size, 0, buffer, bytes_per_row);
}

/// Copies the whole of mip `level` of `texture`, whose extent is `size`, into `buffer`, rows of
/// `bytes_per_row` from the top.
pub fn copyTextureLevelToBuffer(
    encoder: BlitCommandEncoder,
    texture: Texture,
    size: Size,
    level: u32,
    buffer: Buffer,
    bytes_per_row: u64,
) void {
    apple.objc.send(
        void,
        @ptrCast(encoder),
        apple.objc.selector("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:"),
        .{ texture, @as(apple.foundation.NSUInteger, 0), @as(apple.foundation.NSUInteger, level), Origin{}, size, buffer, @as(apple.foundation.NSUInteger, 0), bytes_per_row, bytes_per_row * size.height },
    );
}

/// An indirect command buffer of up to `max_commands` draws, each of which sets its own pipeline
/// and buffers and inherits every other state from the encoder that executes it. The caller
/// releases it.
pub fn newIndirectCommandBuffer(device: Device, max_commands: u32) ?IndirectCommandBuffer {
    const descriptor = newObject(IndirectCommandBufferDescriptor, "MTLIndirectCommandBufferDescriptor") orelse return null;
    defer apple.objc.release(descriptor);
    const target: apple.objc.Id = @ptrCast(descriptor);
    const bind_count: apple.foundation.NSUInteger = max_indirect_buffer_bindings;
    apple.objc.send(void, target, apple.objc.selector("setCommandTypes:"), .{indirect_command_draw | indirect_command_draw_indexed});
    apple.objc.send(void, target, apple.objc.selector("setInheritPipelineState:"), .{apple.objc.boolean(false)});
    apple.objc.send(void, target, apple.objc.selector("setInheritBuffers:"), .{apple.objc.boolean(false)});
    apple.objc.send(void, target, apple.objc.selector("setMaxVertexBufferBindCount:"), .{bind_count});
    apple.objc.send(void, target, apple.objc.selector("setMaxFragmentBufferBindCount:"), .{bind_count});
    return apple.objc.send(
        ?IndirectCommandBuffer,
        @ptrCast(device),
        apple.objc.selector("newIndirectCommandBufferWithDescriptor:maxCommandCount:options:"),
        .{ descriptor, @as(apple.foundation.NSUInteger, max_commands), resource_storage_mode_shared },
    );
}

/// Buffer indices an indirect command may bind, in each stage: all 31 of them.
pub const max_indirect_buffer_bindings = 31;

pub fn indirectRenderCommand(commands: IndirectCommandBuffer, index: u32) IndirectRenderCommand {
    return apple.objc.send(IndirectRenderCommand, @ptrCast(commands), apple.objc.selector("indirectRenderCommandAtIndex:"), .{@as(apple.foundation.NSUInteger, index)});
}

/// Whether an indirect render command can set its own depth-stencil state and depth bias, as
/// macOS 14 lets it, rather than inheriting both from the encoder.
pub fn indirectCommandsCarryDepthState(command: IndirectRenderCommand) bool {
    return apple.objc.respondsTo(@ptrCast(command), apple.objc.selector("setDepthStencilState:")) and
        apple.objc.respondsTo(@ptrCast(command), apple.objc.selector("setDepthBias:slopeScale:clamp:"));
}

pub fn setIndirectPipelineState(command: IndirectRenderCommand, pipeline: RenderPipelineState) void {
    apple.objc.send(void, @ptrCast(command), apple.objc.selector("setRenderPipelineState:"), .{pipeline});
}

pub fn setIndirectVertexBuffer(command: IndirectRenderCommand, buffer: Buffer, offset: u64, index: u32) void {
    apple.objc.send(void, @ptrCast(command), apple.objc.selector("setVertexBuffer:offset:atIndex:"), .{ buffer, offset, @as(apple.foundation.NSUInteger, index) });
}

pub fn setIndirectFragmentBuffer(command: IndirectRenderCommand, buffer: Buffer, offset: u64, index: u32) void {
    apple.objc.send(void, @ptrCast(command), apple.objc.selector("setFragmentBuffer:offset:atIndex:"), .{ buffer, offset, @as(apple.foundation.NSUInteger, index) });
}

pub fn indirectDrawPrimitives(
    command: IndirectRenderCommand,
    primitive: PrimitiveType,
    first_vertex: u32,
    vertex_count: u32,
    instance_count: u32,
    first_instance: u32,
) void {
    apple.objc.send(
        void,
        @ptrCast(command),
        apple.objc.selector("drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:"),
        drawArguments(primitive, first_vertex, vertex_count, instance_count, first_instance),
    );
}

pub fn indirectDrawIndexedPrimitives(
    command: IndirectRenderCommand,
    primitive: PrimitiveType,
    index_count: u32,
    index_type: IndexType,
    index_buffer: Buffer,
    index_offset: u64,
    instance_count: u32,
    base_vertex: i32,
    first_instance: u32,
) void {
    apple.objc.send(
        void,
        @ptrCast(command),
        apple.objc.selector("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:"),
        drawIndexedArguments(primitive, index_count, index_type, index_buffer, index_offset, instance_count, base_vertex, first_instance),
    );
}

fn drawArguments(
    primitive: PrimitiveType,
    first_vertex: u32,
    vertex_count: u32,
    instance_count: u32,
    first_instance: u32,
) struct { apple.foundation.NSUInteger, apple.foundation.NSUInteger, apple.foundation.NSUInteger, apple.foundation.NSUInteger, apple.foundation.NSUInteger } {
    return .{ @backingInt(primitive), first_vertex, vertex_count, instance_count, first_instance };
}

fn drawIndexedArguments(
    primitive: PrimitiveType,
    index_count: u32,
    index_type: IndexType,
    index_buffer: Buffer,
    index_offset: u64,
    instance_count: u32,
    base_vertex: i32,
    first_instance: u32,
) struct { apple.foundation.NSUInteger, apple.foundation.NSUInteger, apple.foundation.NSUInteger, Buffer, apple.foundation.NSUInteger, apple.foundation.NSUInteger, apple.foundation.NSInteger, apple.foundation.NSUInteger } {
    return .{ @backingInt(primitive), index_count, @backingInt(index_type), index_buffer, index_offset, instance_count, base_vertex, first_instance };
}

/// A `CAMetalLayer` that draws with `device` into drawables of `format`, readable by blits since
/// it is not framebuffer-only. The caller releases it.
pub fn newLayer(device: Device, format: PixelFormat, max_drawables: u32, display_sync: bool) ?Layer {
    const layer = newObject(Layer, "CAMetalLayer") orelse return null;
    const target: apple.objc.Id = @ptrCast(layer);
    apple.objc.send(void, target, apple.objc.selector("setDevice:"), .{device});
    apple.objc.send(void, target, apple.objc.selector("setPixelFormat:"), .{@backingInt(format)});
    apple.objc.send(void, target, apple.objc.selector("setFramebufferOnly:"), .{apple.objc.boolean(false)});
    apple.objc.send(void, target, apple.objc.selector("setMaximumDrawableCount:"), .{@as(apple.foundation.NSUInteger, max_drawables)});
    apple.objc.send(void, target, apple.objc.selector("setDisplaySyncEnabled:"), .{apple.objc.boolean(display_sync)});
    return layer;
}

/// Places `layer` over the whole of `parent`, with drawables of `width` by `height` pixels.
pub fn attachLayer(layer: Layer, parent: apple.objc.Id, width: u32, height: u32) void {
    const target: apple.objc.Id = @ptrCast(layer);
    const bounds = apple.objc.send(apple.cocoa.NSRect, parent, apple.objc.selector("bounds"), .{});
    apple.objc.send(void, target, apple.objc.selector("setFrame:"), .{bounds});
    const scale: apple.coregraphics.CGFloat = if (bounds.size.width > 0)
        @as(apple.coregraphics.CGFloat, @floatFromInt(width)) / bounds.size.width
    else
        1;
    apple.objc.send(void, target, apple.objc.selector("setContentsScale:"), .{scale});
    const drawable_size = apple.cocoa.NSSize{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
    apple.objc.send(void, target, apple.objc.selector("setDrawableSize:"), .{drawable_size});
    apple.objc.send(void, parent, apple.objc.selector("addSublayer:"), .{target});
}

pub fn detachLayer(layer: Layer) void {
    apple.objc.send(void, @ptrCast(layer), apple.objc.selector("removeFromSuperlayer"), .{});
}

/// The layer's next drawable, autoreleased, or null when none frees up within the layer's
/// one-second timeout.
pub fn nextDrawable(layer: Layer) ?Drawable {
    return apple.objc.send(?Drawable, @ptrCast(layer), apple.objc.selector("nextDrawable"), .{});
}

pub fn drawableTexture(drawable: Drawable) ?Texture {
    return apple.objc.send(?Texture, @ptrCast(drawable), apple.objc.selector("texture"), .{});
}

fn newObject(comptime T: type, class_name: [*:0]const u8) ?T {
    const object_class = apple.objc.class(class_name) orelse return null;
    const allocated = apple.objc.send(?apple.objc.Id, object_class, apple.objc.selector("alloc"), .{}) orelse return null;
    return apple.objc.send(?T, allocated, apple.objc.selector("init"), .{});
}

fn subscript(array: apple.objc.Id, index: u32) apple.objc.Id {
    return apple.objc.send(apple.objc.Id, array, apple.objc.selector("objectAtIndexedSubscript:"), .{@as(apple.foundation.NSUInteger, index)});
}
