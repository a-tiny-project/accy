const std = @import("std");
const gpu_abi = @import("gpu_abi");

const Allocator = std.mem.Allocator;
const DType = gpu_abi.DType;

pub const BackendError = error{
    UnsupportedOperation,
    UnsupportedArtifactFormat,
    CapabilityMismatch,
    CompilationFailed,
    InvalidArtifact,
    InvalidBuffer,
    ReadBufferDestinationTooSmall,
    InvalidSurface,
    InvalidTexture,
    InvalidSurfaceFrame,
    InvalidRenderArtifact,
    SurfaceAlreadyAcquired,
    SurfaceFrameExpired,
    InvalidStream,
    InvalidEvent,
    LaunchArgumentMismatch,
    SequenceCapacityExceeded,
    LaunchFailed,
    RenderArgumentMismatch,
    /// A render module's stages read push constants past the pipeline's declared bytes.
    PushConstantRangeExceeded,
    RenderFailed,
    ResultMismatch,
    RuntimeUnavailable,
    DeviceLost,
    MissingPayloadDeinit,
    OutOfMemory,
};

pub const BackendKind = enum(u8) {
    cuda = 0,
    vulkan = 1,
    metal = 2,
    external = 3,
    webgpu = 4,
    cpu = 5,
    wasm = 6,
};

pub const DeviceFamily = enum(u8) {
    nvidia_cuda = 0,
    vulkan = 1,
    apple_metal = 2,
    external = 3,
    webgpu = 4,
    native_cpu = 5,
    webassembly = 6,
};

pub const ArtifactFormat = enum(u8) {
    cuda_ptx = 0,
    cuda_cubin = 1,
    vulkan_spirv = 2,
    metal_msl = 3,
    metal_metallib = 4,
    external = 5,
    webgpu_wgsl = 6,
    cpu_machine_code = 7,
    cpu_object = 8,
    webassembly_module = 9,
};

/// A caller picks the math tier, the arithmetic contract compiled code follows, before compiling
/// for a device. Two choices exist: `exact`, the default, and `tf32_tensor`, which uses the
/// reduced-precision TF32 format on NVIDIA tensor cores. The option `tf32_tensor` is accepted only
/// for a CUDA backend, one device runtime behind the common interface, emitting PTX on a device
/// with tensor cores. Compiling fails with an error when a kernel cannot be compiled under
/// `tf32_tensor`, and the code never falls back to another tier on its own. The chosen tier is
/// hashed into the identity of the compiled artifact, so code compiled under one tier remains
/// distinct from code compiled under the other. A tier chooses arithmetic precision alone, and it
/// gives no license for algebraic rewrites that change which values are NaN, infinities or the sign
/// of zero.
pub const BackendMathTier = enum(u8) {
    exact = 0,
    tf32_tensor = 1,

    pub fn parse(text: []const u8) ?BackendMathTier {
        inline for (
            @typeInfo(BackendMathTier).@"enum".field_names,
            @typeInfo(BackendMathTier).@"enum".field_values,
        ) |field_name, field_name_value| {
            const field = .{ .name = field_name, .value = field_name_value };
            const value: BackendMathTier = @fromBackingInt(@intCast(field.value));
            if (std.mem.eql(u8, text, @tagName(value))) return value;
        }
        return null;
    }
};

pub fn familyForBackendKind(kind: BackendKind) DeviceFamily {
    return switch (kind) {
        .cuda => .nvidia_cuda,
        .vulkan => .vulkan,
        .metal => .apple_metal,
        .external => .external,
        .webgpu => .webgpu,
        .cpu => .native_cpu,
        .wasm => .webassembly,
    };
}

pub fn artifactFormatIsNativeCpu(format: ArtifactFormat) bool {
    return switch (format) {
        .cpu_machine_code, .cpu_object => true,
        else => false,
    };
}

pub fn artifactFormatUsesHostLoopLaunch(format: ArtifactFormat) bool {
    return switch (format) {
        .cpu_machine_code, .cpu_object, .webassembly_module => true,
        else => false,
    };
}

pub const PayloadOwnership = enum {
    borrowed,
    owned,
};

pub const BufferOwnership = enum {
    host,
    backend,
    borrowed_external,
};

pub const BufferAccess = enum {
    read_only,
    write_only,
    read_write,
};

pub const TextureOwnership = enum {
    backend,
    acquired_surface,
    borrowed_external,
};

pub const TextureFormat = enum(u8) {
    rgba8_unorm = 0,
    bgra8_unorm = 1,
    rgba8_srgb = 2,
    bgra8_srgb = 3,
    depth32_float = 4,
    /// Four IEEE 754 binary16 channels in red, green, blue, alpha order, each
    /// little-endian. A fragment's color lands unclamped, rounded to the
    /// nearest half, and a blend runs in at least half precision, so a blended
    /// texel may differ between backends by a step of the half that holds it.
    rgba16_float = 5,

    /// Bytes one texel occupies in a tightly packed transfer.
    pub fn texelBytes(self: TextureFormat) u32 {
        return switch (self) {
            .rgba8_unorm, .bgra8_unorm, .rgba8_srgb, .bgra8_srgb, .depth32_float => 4,
            .rgba16_float => 8,
        };
    }

    pub fn isDepth(self: TextureFormat) bool {
        return self == .depth32_float;
    }
};

pub const ColorSpace = enum(u8) {
    srgb = 0,
    linear = 1,
};

pub const PresentMode = enum(u8) {
    fifo = 0,
    mailbox = 1,
    immediate = 2,
};

pub const SurfaceAlphaMode = enum(u8) {
    solid = 0,
    premultiplied = 1,
    postmultiplied = 2,
    inherit = 3,
};

pub const SurfacePlatformKind = enum(u8) {
    x11 = 0,
    cocoa = 1,
    webgpu_canvas = 2,
    headless = 3,
    external = 4,
};

pub const X11Surface = struct {
    display: usize,
    window: u64,
    visual_id: u32 = 0,
    depth: u8 = 0,
};

pub const CocoaSurface = struct {
    app: usize = 0,
    window: usize = 0,
    layer: usize,
};

pub const WebGpuCanvasSurface = struct {
    context: usize,
    canvas_id: u64 = 0,
};

pub const HeadlessSurface = struct {
    token: u64 = 0,
};

pub const ExternalSurface = struct {
    ptr: *anyopaque,
    type_id: []const u8,
};

pub const SurfacePlatform = union(SurfacePlatformKind) {
    x11: X11Surface,
    cocoa: CocoaSurface,
    webgpu_canvas: WebGpuCanvasSurface,
    headless: HeadlessSurface,
    external: ExternalSurface,

    pub fn kind(self: SurfacePlatform) SurfacePlatformKind {
        return switch (self) {
            .x11 => .x11,
            .cocoa => .cocoa,
            .webgpu_canvas => .webgpu_canvas,
            .headless => .headless,
            .external => .external,
        };
    }
};

pub const SurfaceExtent = struct {
    width: u32 = 0,
    height: u32 = 0,

    pub fn valid(self: SurfaceExtent) bool {
        return self.width != 0 and self.height != 0;
    }
};

pub const TextureExtent = struct {
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 1,

    pub fn valid(self: TextureExtent) bool {
        return self.width != 0 and self.height != 0 and self.depth != 0;
    }

    /// The extent of mip level `level`: each side halved per level, rounded
    /// down, and at least one.
    pub fn mip(self: TextureExtent, level: u32) TextureExtent {
        std.debug.assert(self.valid());
        std.debug.assert(level < 32);
        const shift: u5 = @intCast(level);
        return .{
            .width = @max(1, self.width >> shift),
            .height = @max(1, self.height >> shift),
            .depth = @max(1, self.depth >> shift),
        };
    }

    /// The levels of a full mip chain, from this extent down to one texel.
    pub fn mipLevels(self: TextureExtent) u32 {
        std.debug.assert(self.valid());
        const largest = @max(self.width, self.height, self.depth);
        return 32 - @clz(largest);
    }
};

pub const TextureUsage = struct {
    copy_src: bool = false,
    copy_dst: bool = false,
    sampled: bool = false,
    storage: bool = false,
    color_attachment: bool = false,
    depth_attachment: bool = false,
    present: bool = false,

    pub fn any(self: TextureUsage) bool {
        return self.copy_src or self.copy_dst or self.sampled or self.storage or
            self.color_attachment or self.depth_attachment or self.present;
    }

    pub fn containsAll(self: TextureUsage, required: TextureUsage) bool {
        if (required.copy_src and !self.copy_src) return false;
        if (required.copy_dst and !self.copy_dst) return false;
        if (required.sampled and !self.sampled) return false;
        if (required.storage and !self.storage) return false;
        if (required.color_attachment and !self.color_attachment) return false;
        if (required.depth_attachment and !self.depth_attachment) return false;
        if (required.present and !self.present) return false;
        return true;
    }
};

pub const RenderArtifactFormat = enum(u8) {
    vulkan_spirv = 0,
    metal_msl = 1,
    metal_metallib = 2,
    webgpu_wgsl = 3,
    external = 4,
    /// One relocatable object for the host that defines both stages as functions of the
    /// `gpu_abi.stage` layout.
    cpu_object = 5,
};

/// How a fragment's color `s` combines with the target's color `d`. Each mode applies one equation
/// per channel, with `as` the fragment's alpha:
/// - `replace`: s.
/// - `alpha_premultiplied`: s + d·(1 − as), for color and alpha alike.
/// - `alpha_straight`: color s·as + d·(1 − as), alpha as + ad·(1 − as).
/// - `additive`: s + d, for color and alpha alike.
///
/// An 8-bit unorm target stores each result as a byte. A color k/255 written without blending
/// lands on byte k on every backend, since interpolation, sampling and the conversion move it by
/// far less than half a step. A blend's exact result can fall between two bytes, and Vulkan only
/// recommends rounding to nearest when it converts, so a blended byte may differ between
/// backends by one step. The CPU backend rounds to nearest.
pub const RenderBlendMode = enum(u8) {
    replace = 0,
    alpha_premultiplied = 1,
    alpha_straight = 2,
    additive = 3,
};

/// The faces a pipeline leaves undrawn. A triangle faces front when its vertices, in the order
/// the draw gives them, run counter-clockwise on the target, where y grows down. That is Vulkan's
/// `frontFace = COUNTER_CLOCKWISE` and Metal's counter-clockwise winding.
pub const RenderCullMode = enum(u8) {
    none = 0,
    back = 1,
    front = 2,
};

pub const RenderPrimitiveTopology = enum(u8) {
    triangle_list = 0,
    triangle_strip = 1,
    line_list = 2,
    line_strip = 3,
};

pub const RenderVertexStepMode = enum(u8) {
    vertex = 0,
    instance = 1,
};

pub const RenderVertexFormat = enum(u8) {
    float32 = 0,
    float32x2 = 1,
    float32x3 = 2,
    float32x4 = 3,
    uint32 = 4,
    uint32x2 = 5,
    uint32x4 = 6,
};

pub const RenderBindingKind = enum(u8) {
    uniform_buffer = 0,
    storage_buffer = 1,
    sampled_texture = 2,
    storage_texture = 3,
};

pub const RenderIndexFormat = enum(u8) {
    none = 0,
    u16 = 1,
    u32 = 2,
};

pub const RenderVertexAttribute = struct {
    location: u32,
    format: RenderVertexFormat,
    offset: u32,
};

pub const RenderVertexBufferLayout = struct {
    binding: u32,
    stride: u32,
    step_mode: RenderVertexStepMode = .vertex,
    attribute_start: u32,
    attribute_count: u32,
};

pub const RenderBindingDesc = struct {
    group: u32 = 0,
    binding: u32,
    kind: RenderBindingKind,
    access: BufferAccess = .read_only,
};

pub const RenderViewport = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,

    pub fn valid(self: RenderViewport) bool {
        if (!std.math.isFinite(self.x) or !std.math.isFinite(self.y)) return false;
        if (!std.math.isFinite(self.width) or !std.math.isFinite(self.height)) return false;
        if (!std.math.isFinite(self.min_depth) or !std.math.isFinite(self.max_depth)) return false;
        if (self.width <= 0 or self.height <= 0) return false;
        if (self.min_depth < 0 or self.max_depth > 1 or self.min_depth > self.max_depth) return false;
        return true;
    }
};

pub const RenderScissor = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,

    pub fn valid(self: RenderScissor) bool {
        return self.width != 0 and self.height != 0;
    }
};

pub const RenderDrawRange = struct {
    first_vertex: u32 = 0,
    vertex_count: u32 = 0,
    first_index: u32 = 0,
    index_count: u32 = 0,
    base_vertex: i32 = 0,
    first_instance: u32 = 0,
    instance_count: u32 = 1,
    index_format: RenderIndexFormat = .none,

    pub fn valid(self: RenderDrawRange) bool {
        if (self.instance_count == 0) return false;
        const indexed = self.index_count != 0 or self.index_format != .none;
        if (indexed) return self.index_count != 0 and self.index_format != .none and self.vertex_count == 0;
        return self.vertex_count != 0;
    }
};

/// The comparison a depth test applies as `fragment op stored`.
pub const RenderCompare = enum(u8) {
    never = 0,
    less = 1,
    equal = 2,
    less_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_equal = 6,
    always = 7,
};

/// A pipeline's depth test. Its draws need a pass whose depth attachment has `format`. A fragment
/// that fails `compare` is discarded, and one that passes writes its depth when `write` is set.
pub const RenderDepthState = struct {
    format: TextureFormat = .depth32_float,
    compare: RenderCompare = .less,
    write: bool = true,
    bias: RenderDepthBias = .{},
};

/// An offset added to each fragment's depth before the depth test, so that a decal drawn over a
/// coplanar surface passes a test the surface's own depth would tie. With `m` the triangle's
/// depth slope in pixels and `r` the step of depth32_float at the triangle's largest vertex depth
/// `z`, the offset is `o = m * slope + r * constant`, where `r = 2^(e - 23)` for `z = f * 2^e`
/// with `f` in [1, 2). A positive `clamp` caps `o` at `clamp`, a negative one floors `o` at
/// `clamp`, and zero leaves `o` unclamped. A bias that moves a depth outside [0, 1] leaves what
/// is stored to the backend: the CPU backend stores it as computed.
///
/// Vulkan lets `m` be `sqrt(dz/dx^2 + dz/dy^2)` or `max(|dz/dx|, |dz/dy|)`. The CPU backend takes
/// the maximum. The two agree when depth changes along one screen axis, and otherwise the maximum is
/// at most the root and at least 1/sqrt(2) of it, so a sloped bias matches another backend only
/// to that factor.
pub const RenderDepthBias = struct {
    constant: f32 = 0,
    slope: f32 = 0,
    clamp: f32 = 0,

    pub fn valid(self: RenderDepthBias) bool {
        if (!std.math.isFinite(self.constant)) return false;
        if (!std.math.isFinite(self.slope)) return false;
        return std.math.isFinite(self.clamp);
    }

    pub fn enabled(self: RenderDepthBias) bool {
        return self.constant != 0 or self.slope != 0;
    }
};

pub const RenderFilter = enum(u8) {
    nearest = 0,
    linear = 1,
};

pub const RenderAddressMode = enum(u8) {
    clamp_to_edge = 0,
    repeat = 1,
};

/// How a sampled texture picks among its mip levels.
pub const RenderMipFilter = enum(u8) {
    /// Reads level 0 alone, as a texture of one level does.
    none = 0,
    /// Reads the nearest level to the one the footprint asks for.
    nearest = 1,
    /// Blends the two levels around the one the footprint asks for.
    linear = 2,
};

/// How a sampled texture reads between and beyond its texels. The defaults
/// read level 0 alone, isotropically, without bias.
pub const RenderSampler = struct {
    filter: RenderFilter = .nearest,
    address: RenderAddressMode = .clamp_to_edge,
    mip_filter: RenderMipFilter = .none,
    /// The most texels a read averages along its footprint's long axis, from
    /// 1, none, to the raster's `max_anisotropy`.
    max_anisotropy: u8 = 1,
    /// Levels added to the one the footprint asks for; negative reads finer.
    /// Nonzero needs the raster's `mip_lod_bias`.
    lod_bias: f32 = 0,
};

pub const RenderSampledTexture = struct {
    texture: TextureHandle,
    sampler: RenderSampler = .{},
};

/// One resource for one binding of a pipeline, of the kind that binding names.
pub const RenderResource = union(RenderBindingKind) {
    uniform_buffer: BufferHandle,
    storage_buffer: BufferHandle,
    sampled_texture: RenderSampledTexture,
    storage_texture: TextureHandle,
};

/// Resources for every binding of `pipeline`, in the order of `artifact.bindings`.
pub const RenderBindingsRequest = struct {
    artifact: *const RenderArtifact,
    pipeline: LoadedRenderArtifact,
    resources: []const RenderResource,
};

/// A pipeline's resources, written once and bound by every draw that names them. The resources
/// must outlive it, and `destroyObject` releases it.
pub const RenderBindings = struct {
    id: BackendObjectId,
    backend: BackendKind,
    pipeline: BackendObjectId,
};

pub const RenderColorLoad = union(enum) {
    load,
    clear: SurfaceClearColor,
};

pub const RenderDepthLoad = union(enum) {
    load,
    clear: f32,
};

pub const RenderColorAttachment = struct {
    view: TextureView,
    load: RenderColorLoad = .load,
};

pub const RenderDepthAttachment = struct {
    view: TextureView,
    load: RenderDepthLoad = .{ .clear = 1 },
};

/// A buffer bound to one vertex layout, read from `offset` bytes on.
pub const RenderBufferRange = struct {
    buffer: BufferHandle,
    offset: u64 = 0,
};

/// One draw of a pass. `vertex_buffers` follows the pipeline's vertex layouts in order, and an
/// indexed range reads `index_buffer` in the range's index format. A backend checks every range it
/// can see without reading buffer contents: instances, a non-indexed draw's vertices and the
/// indices. The vertices an index names are the caller's to keep inside each per-vertex buffer.
/// `push_constants` holds exactly the pipeline's `push_constant_bytes`, which both stages read for
/// this draw alone. A bundle copies them when it records the draw.
pub const RenderDraw = struct {
    pipeline: LoadedRenderArtifact,
    bindings: ?RenderBindings = null,
    vertex_buffers: []const RenderBufferRange = &.{},
    index_buffer: ?RenderBufferRange = null,
    range: RenderDrawRange,
    push_constants: []const u8 = &.{},
};

/// Draws into one color target and an optional depth target, in order. Every draw's pipeline
/// targets the color format, and a pipeline with a depth state needs the depth attachment. A clear
/// covers the whole target, whatever the scissor, and draws touch only pixels inside the scissor.
pub const RenderPass = struct {
    color: RenderColorAttachment,
    depth: ?RenderDepthAttachment = null,
    viewport: RenderViewport,
    scissor: RenderScissor,
    draws: []const RenderDraw,
    diagnostic_id: ?[]const u8 = null,
};

/// A pass recorded once and submitted any number of times. The objects it names must outlive it,
/// and their contents may change between submissions.
pub const RenderBundle = struct {
    id: BackendObjectId,
    backend: BackendKind,
    draw_count: u32,
};

pub const SyncScope = enum {
    default_stream,
    stream,
    event,
    device,
};

pub const BackendObjectId = u64;

pub const DTypeSet = struct {
    bits: u64 = 0,

    pub fn init(values: []const DType) DTypeSet {
        var set: DTypeSet = .{};
        for (values) |value| set.insert(value);
        return set;
    }

    pub fn insert(self: *DTypeSet, value: DType) void {
        self.bits |= bitForDType(value);
    }

    pub fn contains(self: DTypeSet, value: DType) bool {
        return (self.bits & bitForDType(value)) != 0;
    }

    pub fn containsAll(self: DTypeSet, required: DTypeSet) bool {
        return (self.bits & required.bits) == required.bits;
    }
};

pub const ArtifactFormatSet = struct {
    bits: u64 = 0,

    pub fn init(values: []const ArtifactFormat) ArtifactFormatSet {
        var set: ArtifactFormatSet = .{};
        for (values) |value| set.insert(value);
        return set;
    }

    pub fn insert(self: *ArtifactFormatSet, value: ArtifactFormat) void {
        self.bits |= bitForArtifactFormat(value);
    }

    pub fn contains(self: ArtifactFormatSet, value: ArtifactFormat) bool {
        return (self.bits & bitForArtifactFormat(value)) != 0;
    }
};

pub const TextureFormatSet = struct {
    bits: u64 = 0,

    pub fn init(values: []const TextureFormat) TextureFormatSet {
        var set: TextureFormatSet = .{};
        for (values) |value| set.insert(value);
        return set;
    }

    pub fn insert(self: *TextureFormatSet, value: TextureFormat) void {
        self.bits |= bitForTextureFormat(value);
    }

    pub fn contains(self: TextureFormatSet, value: TextureFormat) bool {
        return (self.bits & bitForTextureFormat(value)) != 0;
    }
};

pub const PresentModeSet = struct {
    bits: u64 = 0,

    pub fn init(values: []const PresentMode) PresentModeSet {
        var set: PresentModeSet = .{};
        for (values) |value| set.insert(value);
        return set;
    }

    pub fn insert(self: *PresentModeSet, value: PresentMode) void {
        self.bits |= bitForPresentMode(value);
    }

    pub fn contains(self: PresentModeSet, value: PresentMode) bool {
        return (self.bits & bitForPresentMode(value)) != 0;
    }
};

pub const ColorSpaceSet = struct {
    bits: u64 = 0,

    pub fn init(values: []const ColorSpace) ColorSpaceSet {
        var set: ColorSpaceSet = .{};
        for (values) |value| set.insert(value);
        return set;
    }

    pub fn insert(self: *ColorSpaceSet, value: ColorSpace) void {
        self.bits |= bitForColorSpace(value);
    }

    pub fn contains(self: ColorSpaceSet, value: ColorSpace) bool {
        return (self.bits & bitForColorSpace(value)) != 0;
    }
};

pub const SurfacePlatformSet = struct {
    bits: u64 = 0,

    pub fn init(values: []const SurfacePlatformKind) SurfacePlatformSet {
        var set: SurfacePlatformSet = .{};
        for (values) |value| set.insert(value);
        return set;
    }

    pub fn insert(self: *SurfacePlatformSet, value: SurfacePlatformKind) void {
        self.bits |= bitForSurfacePlatformKind(value);
    }

    pub fn contains(self: SurfacePlatformSet, value: SurfacePlatformKind) bool {
        return (self.bits & bitForSurfacePlatformKind(value)) != 0;
    }
};

pub const RenderArtifactFormatSet = struct {
    bits: u64 = 0,

    pub fn init(values: []const RenderArtifactFormat) RenderArtifactFormatSet {
        var set: RenderArtifactFormatSet = .{};
        for (values) |value| set.insert(value);
        return set;
    }

    pub fn insert(self: *RenderArtifactFormatSet, value: RenderArtifactFormat) void {
        self.bits |= bitForRenderArtifactFormat(value);
    }

    pub fn contains(self: RenderArtifactFormatSet, value: RenderArtifactFormat) bool {
        return (self.bits & bitForRenderArtifactFormat(value)) != 0;
    }
};

pub const RenderBlendModeSet = struct {
    bits: u64 = 0,

    pub fn init(values: []const RenderBlendMode) RenderBlendModeSet {
        var set: RenderBlendModeSet = .{};
        for (values) |value| set.insert(value);
        return set;
    }

    pub fn insert(self: *RenderBlendModeSet, value: RenderBlendMode) void {
        self.bits |= bitForRenderBlendMode(value);
    }

    pub fn contains(self: RenderBlendModeSet, value: RenderBlendMode) bool {
        return (self.bits & bitForRenderBlendMode(value)) != 0;
    }
};

pub const RenderPrimitiveTopologySet = struct {
    bits: u64 = 0,

    pub fn init(values: []const RenderPrimitiveTopology) RenderPrimitiveTopologySet {
        var set: RenderPrimitiveTopologySet = .{};
        for (values) |value| set.insert(value);
        return set;
    }

    pub fn insert(self: *RenderPrimitiveTopologySet, value: RenderPrimitiveTopology) void {
        self.bits |= bitForRenderPrimitiveTopology(value);
    }

    pub fn contains(self: RenderPrimitiveTopologySet, value: RenderPrimitiveTopology) bool {
        return (self.bits & bitForRenderPrimitiveTopology(value)) != 0;
    }
};

pub const RenderVertexFormatSet = struct {
    bits: u64 = 0,

    pub fn init(values: []const RenderVertexFormat) RenderVertexFormatSet {
        var set: RenderVertexFormatSet = .{};
        for (values) |value| set.insert(value);
        return set;
    }

    pub fn insert(self: *RenderVertexFormatSet, value: RenderVertexFormat) void {
        self.bits |= bitForRenderVertexFormat(value);
    }

    pub fn contains(self: RenderVertexFormatSet, value: RenderVertexFormat) bool {
        return (self.bits & bitForRenderVertexFormat(value)) != 0;
    }
};

pub const RenderBindingKindSet = struct {
    bits: u64 = 0,

    pub fn init(values: []const RenderBindingKind) RenderBindingKindSet {
        var set: RenderBindingKindSet = .{};
        for (values) |value| set.insert(value);
        return set;
    }

    pub fn insert(self: *RenderBindingKindSet, value: RenderBindingKind) void {
        self.bits |= bitForRenderBindingKind(value);
    }

    pub fn contains(self: RenderBindingKindSet, value: RenderBindingKind) bool {
        return (self.bits & bitForRenderBindingKind(value)) != 0;
    }
};

pub const RenderIndexFormatSet = struct {
    bits: u64 = 0,

    pub fn init(values: []const RenderIndexFormat) RenderIndexFormatSet {
        var set: RenderIndexFormatSet = .{};
        for (values) |value| set.insert(value);
        return set;
    }

    pub fn insert(self: *RenderIndexFormatSet, value: RenderIndexFormat) void {
        self.bits |= bitForRenderIndexFormat(value);
    }

    pub fn contains(self: RenderIndexFormatSet, value: RenderIndexFormat) bool {
        return (self.bits & bitForRenderIndexFormat(value)) != 0;
    }
};

pub const DeviceIdentity = struct {
    backend: BackendKind,
    family: DeviceFamily,
    name: []const u8 = "unknown",
    vendor_id: ?u32 = null,
    device_id: ?u32 = null,
    driver_version: ?[]const u8 = null,
};

pub const MemoryLimits = struct {
    global_bytes: ?u64 = null,
    max_allocation_bytes: ?u64 = null,
    shared_memory_per_threadgroup_bytes: ?u32 = null,
    constant_memory_bytes: ?u64 = null,
    min_buffer_alignment: u32 = 1,
    unified_memory: bool = false,
    host_visible_device_memory: bool = false,
};

pub const SubgroupFacts = struct {
    supported: bool = false,
    size_min: u32 = 0,
    size_max: u32 = 0,
    shuffle: bool = false,
    ballot: bool = false,
    vote: bool = false,
    arithmetic: bool = false,
    scan: bool = false,

    pub fn satisfies(self: SubgroupFacts, required: gpu_abi.SubgroupRequirements) bool {
        if (required.supported and !self.supported) return false;
        if (required.size_min != 0 and (!self.supported or self.size_max < required.size_min)) return false;
        if (required.size_max != 0 and (!self.supported or self.size_min > required.size_max)) return false;
        if (required.shuffle and (!self.supported or !self.shuffle)) return false;
        if (required.ballot and (!self.supported or !self.ballot)) return false;
        if (required.vote and (!self.supported or !self.vote)) return false;
        if (required.arithmetic and (!self.supported or !self.arithmetic)) return false;
        if (required.scan and (!self.supported or !self.scan)) return false;
        return true;
    }
};

pub const ThreadgroupFacts = struct {
    max_threads: u32 = 1,
    max_blocks: [3]u32 = .{ 1, 1, 1 },
    max_threads_per_dim: [3]u32 = .{ 1, 1, 1 },
    max_grid_per_dim: [3]u32 = .{ 1, 1, 1 },
    shared_memory_bytes: u32 = 0,
};

pub const LayoutFeatures = struct {
    row_major: bool = true,
    column_major: bool = false,
    compact_strides: bool = true,
    arbitrary_strides: bool = false,
    broadcast_strides: bool = false,
    tiled: bool = false,
    vectorized: bool = false,
    opaque_backend_layouts: bool = false,
};

pub const RuntimeRequirements = struct {
    driver_loaded: bool = false,
    device_context: bool = false,
    streams: bool = false,
    events: bool = false,
    timeline_events: bool = false,
    host_pinned_memory: bool = false,
    external_allocator: bool = false,

    pub fn containsAll(self: RuntimeRequirements, required: RuntimeRequirements) bool {
        if (required.driver_loaded and !self.driver_loaded) return false;
        if (required.device_context and !self.device_context) return false;
        if (required.streams and !self.streams) return false;
        if (required.events and !self.events) return false;
        if (required.timeline_events and !self.timeline_events) return false;
        if (required.host_pinned_memory and !self.host_pinned_memory) return false;
        if (required.external_allocator and !self.external_allocator) return false;
        return true;
    }
};

pub const TextureCapabilities = struct {
    supported: bool = false,
    formats: TextureFormatSet = .{},
    usages: TextureUsage = .{},
    max_extent: TextureExtent = .{},
    max_sample_count: u32 = 1,
    /// The most mip levels a texture may hold. A backend that samples one
    /// level only reports 1.
    max_mip_levels: u32 = 1,

    pub fn supportsFormat(self: TextureCapabilities, format: TextureFormat) bool {
        return self.formats.contains(format);
    }

    pub fn supportsUsage(self: TextureCapabilities, usage: TextureUsage) bool {
        return self.usages.containsAll(usage);
    }

    pub fn supportsExtent(self: TextureCapabilities, extent: TextureExtent) bool {
        if (!extent.valid()) return false;
        if (self.max_extent.width != 0 and extent.width > self.max_extent.width) return false;
        if (self.max_extent.height != 0 and extent.height > self.max_extent.height) return false;
        if (self.max_extent.depth != 0 and extent.depth > self.max_extent.depth) return false;
        return true;
    }
};

pub const SurfaceCapabilities = struct {
    supported: bool = false,
    platforms: SurfacePlatformSet = .{},
    formats: TextureFormatSet = .{},
    color_spaces: ColorSpaceSet = .{},
    present_modes: PresentModeSet = .{},
    usages: TextureUsage = .{},
    max_extent: SurfaceExtent = .{},
    max_frames_in_flight: u32 = 0,

    pub fn supportsPlatform(self: SurfaceCapabilities, platform: SurfacePlatform) bool {
        return self.platforms.contains(platform.kind());
    }

    pub fn supportsFormat(self: SurfaceCapabilities, format: TextureFormat) bool {
        return self.formats.contains(format);
    }

    pub fn supportsColorSpace(self: SurfaceCapabilities, color_space: ColorSpace) bool {
        return self.color_spaces.contains(color_space);
    }

    pub fn supportsPresentMode(self: SurfaceCapabilities, present_mode: PresentMode) bool {
        return self.present_modes.contains(present_mode);
    }

    pub fn supportsUsage(self: SurfaceCapabilities, usage: TextureUsage) bool {
        return self.usages.containsAll(usage);
    }

    pub fn supportsExtent(self: SurfaceCapabilities, extent: SurfaceExtent) bool {
        if (!extent.valid()) return false;
        if (self.max_extent.width != 0 and extent.width > self.max_extent.width) return false;
        if (self.max_extent.height != 0 and extent.height > self.max_extent.height) return false;
        return true;
    }
};

pub const RasterCapabilities = struct {
    supported: bool = false,
    artifact_formats: RenderArtifactFormatSet = .{},
    target_formats: TextureFormatSet = .{},
    depth_formats: TextureFormatSet = .{},
    blend_modes: RenderBlendModeSet = .{},
    topologies: RenderPrimitiveTopologySet = .{},
    vertex_formats: RenderVertexFormatSet = .{},
    binding_kinds: RenderBindingKindSet = .{},
    index_formats: RenderIndexFormatSet = .{},
    max_vertex_buffers: u32 = 0,
    max_vertex_attributes: u32 = 0,
    max_bindings: u32 = 0,
    instancing: bool = false,
    /// The largest push-constant block a pipeline may declare, in bytes.
    max_push_constant_bytes: u32 = 0,
    depth_bias: bool = false,
    depth_bias_clamp: bool = false,
    /// The most texels a sampler may average along a read's long axis; 1
    /// when the raster reads isotropically only.
    max_anisotropy: u8 = 1,
    /// Whether a sampler may bias the mip level it reads.
    mip_lod_bias: bool = false,

    /// Checks that `sampled` names a sampled texture and asks no more of
    /// the sampler than the raster reads.
    pub fn validateSampler(self: RasterCapabilities, sampled: RenderSampledTexture) BackendError!void {
        if (!sampled.texture.usage.sampled) return error.InvalidTexture;
        const sampler = sampled.sampler;
        if (sampler.max_anisotropy == 0 or !std.math.isFinite(sampler.lod_bias)) return error.RenderArgumentMismatch;
        if (sampler.max_anisotropy > self.max_anisotropy) return error.CapabilityMismatch;
        if (sampler.lod_bias != 0 and !self.mip_lod_bias) return error.CapabilityMismatch;
    }

    pub fn supportsArtifactFormat(self: RasterCapabilities, format: RenderArtifactFormat) bool {
        return self.artifact_formats.contains(format);
    }

    pub fn supportsTargetFormat(self: RasterCapabilities, format: TextureFormat) bool {
        return self.target_formats.contains(format);
    }

    pub fn supportsDepthFormat(self: RasterCapabilities, format: TextureFormat) bool {
        return self.depth_formats.contains(format);
    }

    pub fn supportsBlendMode(self: RasterCapabilities, blend_mode: RenderBlendMode) bool {
        return self.blend_modes.contains(blend_mode);
    }

    pub fn supportsTopology(self: RasterCapabilities, topology: RenderPrimitiveTopology) bool {
        return self.topologies.contains(topology);
    }

    pub fn supportsVertexFormat(self: RasterCapabilities, format: RenderVertexFormat) bool {
        return self.vertex_formats.contains(format);
    }

    pub fn supportsBindingKind(self: RasterCapabilities, kind: RenderBindingKind) bool {
        return self.binding_kinds.contains(kind);
    }

    pub fn supportsIndexFormat(self: RasterCapabilities, format: RenderIndexFormat) bool {
        return self.index_formats.contains(format);
    }
};

pub const FloatControlWidths = struct {
    f16: bool = false,
    f32: bool = false,
    f64: bool = false,
};

pub const FloatControlIndependence = enum(u32) {
    bit32_only = 0,
    all = 1,
    none = 2,
};

/// The f32 contract a compiler may claim for this device. In the flush profile,
/// any subnormal operand, result, or intermediate may become zero. Stage 0 must
/// refuse constant folds whose operand or result is subnormal under it. Both
/// profiles preserve signed zero, infinities and NaNs.
pub const FloatArithmeticProfile = enum {
    exact,
    flush_permitting,
};

/// Properties reported by the selected Vulkan physical device.
pub const FloatControlFacts = struct {
    denorm_preserve: FloatControlWidths = .{},
    signed_zero_inf_nan_preserve: FloatControlWidths = .{},
    rounding_rte: FloatControlWidths = .{},
    denorm_behavior_independence: ?FloatControlIndependence = null,

    /// A missing signed-zero/Inf/NaN guarantee refuses the f32 target by name.
    pub fn f32Profile(self: FloatControlFacts) BackendError!FloatArithmeticProfile {
        if (!self.signed_zero_inf_nan_preserve.f32) return error.CapabilityMismatch;
        return if (self.denorm_preserve.f32) .exact else .flush_permitting;
    }
};

pub const BackendCapabilities = struct {
    identity: DeviceIdentity,
    memory: MemoryLimits = .{},
    subgroup: SubgroupFacts = .{},
    float_controls: FloatControlFacts = .{},
    threadgroup: ThreadgroupFacts = .{},
    dtypes: DTypeSet = .{},
    layouts: LayoutFeatures = .{},
    runtime: RuntimeRequirements = .{},
    features: gpu_abi.Features = .{},
    artifact_formats: ArtifactFormatSet = .{},
    textures: TextureCapabilities = .{},
    surfaces: SurfaceCapabilities = .{},
    raster: RasterCapabilities = .{},

    pub fn supportsDType(self: BackendCapabilities, value: DType) bool {
        return self.dtypes.contains(value);
    }

    pub fn supportsArtifactFormat(self: BackendCapabilities, format: ArtifactFormat) bool {
        return self.artifact_formats.contains(format);
    }

    pub fn supportsTextureFormat(self: BackendCapabilities, format: TextureFormat) bool {
        return self.textures.supportsFormat(format);
    }

    pub fn supportsSurfaceFormat(self: BackendCapabilities, format: TextureFormat) bool {
        return self.surfaces.supportsFormat(format);
    }

    pub fn supportsRenderArtifactFormat(self: BackendCapabilities, format: RenderArtifactFormat) bool {
        return self.raster.supportsArtifactFormat(format);
    }

    pub fn supportsFeatures(self: BackendCapabilities, required: gpu_abi.Features) bool {
        return self.features.containsAll(required);
    }

    pub fn supportsSubgroup(self: BackendCapabilities, required: gpu_abi.SubgroupRequirements) bool {
        return self.subgroup.satisfies(required);
    }

    pub fn supportsRuntime(self: BackendCapabilities, required: RuntimeRequirements) bool {
        return self.runtime.containsAll(required);
    }

    pub fn validateCompileRequest(self: BackendCapabilities, request: CompileRequest) BackendError!void {
        if (!self.supportsArtifactFormat(request.requested_format)) return error.UnsupportedArtifactFormat;
        if (!self.dtypes.containsAll(request.required_dtypes)) return error.CapabilityMismatch;
        if (!self.supportsFeatures(request.required_features)) return error.CapabilityMismatch;
        if (!self.supportsSubgroup(request.required_subgroup)) return error.CapabilityMismatch;
    }

    pub fn validateRuntimeRequirements(self: BackendCapabilities, required: RuntimeRequirements) BackendError!void {
        if (!self.supportsRuntime(required)) return error.CapabilityMismatch;
    }

    pub fn validateBufferAllocation(self: BackendCapabilities, request: BufferAllocation) BackendError!void {
        if (request.byte_size == 0) return error.InvalidBuffer;
        if (request.alignment == 0) return error.InvalidBuffer;
        if ((request.alignment & (request.alignment - 1)) != 0) return error.InvalidBuffer;
        if (request.alignment < self.memory.min_buffer_alignment) return error.CapabilityMismatch;

        const byte_size = std.math.cast(u64, request.byte_size) orelse return error.CapabilityMismatch;
        if (self.memory.max_allocation_bytes) |limit| {
            if (byte_size > limit) return error.CapabilityMismatch;
        }
        if (self.memory.global_bytes) |limit| {
            if (byte_size > limit) return error.CapabilityMismatch;
        }
        if (request.dtype) |dtype| {
            if (!self.supportsDType(dtype)) return error.CapabilityMismatch;
            if (request.element_count) |count| {
                const required_bytes = std.math.mul(u64, count, dtype.sizeOf()) catch return error.CapabilityMismatch;
                if (required_bytes > byte_size) return error.InvalidBuffer;
            }
        }
    }

    pub fn validateTextureAllocation(self: BackendCapabilities, request: TextureAllocation) BackendError!void {
        if (!request.extent.valid()) return error.InvalidTexture;
        if (!request.usage.any()) return error.InvalidTexture;
        if (request.sample_count == 0) return error.InvalidTexture;
        if (!self.textures.supported) return error.CapabilityMismatch;
        if (!self.textures.supportsFormat(request.format)) return error.CapabilityMismatch;
        if (!self.textures.supportsUsage(request.usage)) return error.CapabilityMismatch;
        if (!self.textures.supportsExtent(request.extent)) return error.CapabilityMismatch;
        if (request.sample_count > self.textures.max_sample_count) return error.CapabilityMismatch;
        if (request.mip_levels == 0 or request.mip_levels > request.extent.mipLevels()) return error.InvalidTexture;
        // A pass draws into one level, so a chain is sampled only.
        if (request.mip_levels > 1 and (request.sample_count > 1 or request.usage.color_attachment or
            request.usage.depth_attachment or request.usage.present)) return error.InvalidTexture;
        if (request.mip_levels > self.textures.max_mip_levels) return error.CapabilityMismatch;
    }

    pub fn validateSurfaceCreation(self: BackendCapabilities, request: SurfaceCreationRequest) BackendError!void {
        if (!request.extent.valid()) return error.InvalidSurface;
        if (!request.usage.any() or !request.usage.present) return error.InvalidSurface;
        if (request.max_frames_in_flight == 0) return error.InvalidSurface;
        if (!self.surfaces.supported) return error.CapabilityMismatch;
        if (!self.surfaces.supportsPlatform(request.platform)) return error.CapabilityMismatch;
        if (!self.surfaces.supportsFormat(request.format)) return error.CapabilityMismatch;
        if (!self.surfaces.supportsColorSpace(request.color_space)) return error.CapabilityMismatch;
        if (!self.surfaces.supportsPresentMode(request.present_mode)) return error.CapabilityMismatch;
        if (!self.surfaces.supportsUsage(request.usage)) return error.CapabilityMismatch;
        if (!self.surfaces.supportsExtent(request.extent)) return error.CapabilityMismatch;
        if (request.max_frames_in_flight > self.surfaces.max_frames_in_flight) return error.CapabilityMismatch;
    }

    pub fn validateRenderPipelineDesc(self: BackendCapabilities, desc: RenderPipelineDesc) BackendError!void {
        if (desc.vertex_entry_name.len == 0 or desc.fragment_entry_name.len == 0) return error.InvalidRenderArtifact;
        if (!self.raster.supported) return error.CapabilityMismatch;
        if (!self.raster.supportsArtifactFormat(desc.format)) return error.CapabilityMismatch;
        if (desc.target_format.isDepth()) return error.InvalidRenderArtifact;
        if (!self.raster.supportsTargetFormat(desc.target_format)) return error.CapabilityMismatch;
        if (desc.depth) |depth| {
            if (!depth.format.isDepth()) return error.InvalidRenderArtifact;
            if (!self.raster.supportsDepthFormat(depth.format)) return error.CapabilityMismatch;
            if (!depth.bias.valid()) return error.InvalidRenderArtifact;
            if (depth.bias.enabled() and !self.raster.depth_bias) return error.CapabilityMismatch;
            if (depth.bias.clamp != 0 and !self.raster.depth_bias_clamp) return error.CapabilityMismatch;
        }
        if (desc.push_constant_bytes % 4 != 0) return error.InvalidRenderArtifact;
        if (desc.push_constant_bytes > self.raster.max_push_constant_bytes) return error.CapabilityMismatch;
        if (desc.push_extent > desc.push_constant_bytes) return error.PushConstantRangeExceeded;
        if (!self.raster.supportsBlendMode(desc.blend_mode)) return error.CapabilityMismatch;
        if (!self.raster.supportsTopology(desc.topology)) return error.CapabilityMismatch;
        if (desc.vertex_layouts.len > self.raster.max_vertex_buffers) return error.CapabilityMismatch;
        if (desc.vertex_attributes.len > self.raster.max_vertex_attributes) return error.CapabilityMismatch;
        if (desc.bindings.len > self.raster.max_bindings) return error.CapabilityMismatch;

        for (desc.vertex_layouts) |layout| {
            if (layout.stride == 0) return error.InvalidRenderArtifact;
            if (layout.step_mode == .instance and !self.raster.instancing) return error.CapabilityMismatch;
            const start: usize = @intCast(layout.attribute_start);
            const count: usize = @intCast(layout.attribute_count);
            if (count == 0) return error.InvalidRenderArtifact;
            if (start > desc.vertex_attributes.len or count > desc.vertex_attributes.len - start) return error.InvalidRenderArtifact;
            for (desc.vertex_attributes[start..][0..count]) |attribute| {
                if (!self.raster.supportsVertexFormat(attribute.format)) return error.CapabilityMismatch;
                const size = renderVertexFormatByteSize(attribute.format);
                if (attribute.offset > layout.stride or size > layout.stride - attribute.offset) return error.InvalidRenderArtifact;
            }
        }

        for (desc.bindings) |binding| {
            if (!self.raster.supportsBindingKind(binding.kind)) return error.CapabilityMismatch;
        }
    }

    /// Checks a pass against these capabilities and against the facts each draw's pipeline
    /// reported. A draw's pipeline declares a depth state exactly when the pass has a depth
    /// attachment, because a pipeline is built for the attachments it draws into.
    pub fn validateRenderPass(self: BackendCapabilities, pass: RenderPass) BackendError!void {
        if (!self.raster.supported) return error.CapabilityMismatch;
        if (!pass.viewport.valid()) return error.RenderArgumentMismatch;
        if (!pass.scissor.valid()) return error.RenderArgumentMismatch;
        const color = pass.color.view;
        if (color.texture.format != color.format) return error.InvalidTexture;
        if (!color.texture.usage.color_attachment) return error.InvalidTexture;
        if (!self.raster.supportsTargetFormat(color.format)) return error.CapabilityMismatch;
        switch (pass.color.load) {
            .load => {},
            .clear => |clear| if (!clear.valid()) return error.RenderArgumentMismatch,
        }
        const extent = color.texture.extent;
        if (!scissorWithin(pass.scissor, extent)) return error.RenderArgumentMismatch;
        if (pass.depth) |depth| {
            if (depth.view.texture.format != depth.view.format) return error.InvalidTexture;
            if (!depth.view.texture.usage.depth_attachment) return error.InvalidTexture;
            if (!self.raster.supportsDepthFormat(depth.view.format)) return error.CapabilityMismatch;
            if (!sameTextureExtent(depth.view.texture.extent, extent)) return error.RenderArgumentMismatch;
            switch (depth.load) {
                .load => {},
                .clear => |clear| if (!(clear >= 0 and clear <= 1)) return error.RenderArgumentMismatch,
            }
        }
        for (pass.draws) |draw| try self.validateRenderDraw(pass, draw);
    }

    fn validateRenderDraw(self: BackendCapabilities, pass: RenderPass, draw: RenderDraw) BackendError!void {
        const pipeline = draw.pipeline;
        if (!draw.range.valid()) return error.RenderArgumentMismatch;
        if (pipeline.target_format != pass.color.view.format) return error.RenderArgumentMismatch;
        if ((pipeline.depth == null) != (pass.depth == null)) return error.RenderArgumentMismatch;
        if (pipeline.depth) |depth| {
            if (depth.format != pass.depth.?.view.format) return error.RenderArgumentMismatch;
        }
        if (draw.vertex_buffers.len != pipeline.vertex_buffer_count) return error.RenderArgumentMismatch;
        if ((pipeline.binding_count == 0) != (draw.bindings == null)) return error.RenderArgumentMismatch;
        if (draw.bindings) |bindings| {
            if (bindings.pipeline != pipeline.id) return error.RenderArgumentMismatch;
        }
        const range = draw.range;
        if (range.instance_count > 1 and !self.raster.instancing) return error.CapabilityMismatch;
        if (range.index_format != .none and !self.raster.supportsIndexFormat(range.index_format)) {
            return error.CapabilityMismatch;
        }
        if ((range.index_count != 0) != (draw.index_buffer != null)) return error.RenderArgumentMismatch;
        if (draw.push_constants.len != pipeline.push_constant_bytes) return error.RenderArgumentMismatch;
    }

    /// Checks that `request` names one resource of the right kind for each pipeline binding.
    pub fn validateRenderBindings(self: BackendCapabilities, request: RenderBindingsRequest) BackendError!void {
        if (!self.raster.supported) return error.CapabilityMismatch;
        const bindings = request.artifact.bindings;
        if (request.pipeline.binding_count != bindings.len) return error.RenderArgumentMismatch;
        if (request.resources.len != bindings.len) return error.RenderArgumentMismatch;
        for (bindings, request.resources) |binding, resource| {
            if (std.meta.activeTag(resource) != binding.kind) return error.RenderArgumentMismatch;
            if (!self.raster.supportsBindingKind(binding.kind)) return error.CapabilityMismatch;
            switch (resource) {
                .uniform_buffer, .storage_buffer => {},
                .sampled_texture => |sampled| try self.raster.validateSampler(sampled),
                .storage_texture => |texture| if (!texture.usage.storage) return error.InvalidTexture,
            }
        }
    }

    /// Checks that `byte_count` covers every texel of `texture`'s level `level` exactly once.
    pub fn validateTextureTransfer(texture: TextureHandle, level: u32, byte_count: usize, usage: TextureUsage) BackendError!void {
        if (!texture.usage.containsAll(usage)) return error.InvalidTexture;
        if (level >= texture.mip_levels) return error.InvalidTexture;
        if (byte_count != try textureByteSize(texture, level)) return error.InvalidTexture;
    }

    pub fn validateLaunchRuntime(self: BackendCapabilities, request: LaunchRequest) BackendError!void {
        if (request.stream != null) try self.validateRuntimeRequirements(.{ .streams = true });
        if (request.wait_events.len != 0 or request.signal_event != null) try self.validateRuntimeRequirements(.{ .events = true });
    }

    pub fn validateSubmitRuntime(
        self: BackendCapabilities,
        stream: ?StreamHandle,
        wait_events: []const EventHandle,
        signal_event: ?EventHandle,
    ) BackendError!void {
        if (stream != null) try self.validateRuntimeRequirements(.{ .streams = true });
        if (wait_events.len != 0 or signal_event != null) try self.validateRuntimeRequirements(.{ .events = true });
    }

    pub fn validateSyncRuntime(self: BackendCapabilities, request: SyncRequest) BackendError!void {
        switch (request.scope) {
            .default_stream, .device => {},
            .stream => try self.validateRuntimeRequirements(.{ .streams = true }),
            .event => try self.validateRuntimeRequirements(.{ .events = true }),
        }
    }

    pub fn validateLaunchGeometry(self: BackendCapabilities, geometry: gpu_abi.LaunchGeometry) BackendError!void {
        if (geometry.grid[0] == 0 or geometry.grid[1] == 0 or geometry.grid[2] == 0) {
            return error.LaunchArgumentMismatch;
        }
        if (geometry.threadgroup[0] == 0 or geometry.threadgroup[1] == 0 or geometry.threadgroup[2] == 0) {
            return error.LaunchArgumentMismatch;
        }

        const total_threads =
            @as(u64, geometry.threadgroup[0]) *
            @as(u64, geometry.threadgroup[1]) *
            @as(u64, geometry.threadgroup[2]);
        if (total_threads > self.threadgroup.max_threads) return error.CapabilityMismatch;

        for (geometry.threadgroup, self.threadgroup.max_threads_per_dim) |requested, limit| {
            if (requested > limit) return error.CapabilityMismatch;
        }
        for (geometry.grid, self.threadgroup.max_blocks) |requested, limit| {
            if (requested > limit) return error.CapabilityMismatch;
        }
        for (geometry.grid, self.threadgroup.max_grid_per_dim) |requested, limit| {
            if (requested > limit) return error.CapabilityMismatch;
        }
        if (geometry.dynamic_shared_memory_bytes != 0 and !self.features.dynamic_shared_memory) {
            return error.CapabilityMismatch;
        }
        if (geometry.dynamic_shared_memory_bytes > self.threadgroup.shared_memory_bytes) {
            return error.CapabilityMismatch;
        }
    }
};

pub const ArtifactPayload = union(enum) {
    none,
    bytes: []const u8,
    words_u32: []const u32,
    text: []const u8,
    external: ExternalPayload,
};

pub const ExternalPayload = struct {
    ptr: *anyopaque,
    type_id: []const u8,
    deinit_fn: ?*const fn (Allocator, *anyopaque) void = null,
};

pub const KernelArtifactDesc = struct {
    backend: BackendKind,
    format: ArtifactFormat,
    entry_name: []const u8,
    argument_count: u32,
    scalar_argument_count: u32 = 0,
    diagnostic_id: ?[]const u8 = null,
    interface: gpu_abi.Interface = .{},
};

pub const KernelArtifact = struct {
    allocator: Allocator,
    backend: BackendKind,
    format: ArtifactFormat,
    entry_name: []const u8,
    argument_count: u32,
    scalar_argument_count: u32 = 0,
    diagnostic_id: ?[]const u8 = null,
    /// Requirements and push-constant layout the compiler recorded for this
    /// entry. Load checks the requirements; launch packs through the layout.
    interface: gpu_abi.Interface = .{},
    payload: ArtifactPayload = .none,
    payload_ownership: PayloadOwnership = .borrowed,

    pub fn init(allocator: Allocator, desc: KernelArtifactDesc) Allocator.Error!KernelArtifact {
        const entry_name = try dupeString(allocator, desc.entry_name);
        errdefer freeString(allocator, entry_name);

        return .{
            .allocator = allocator,
            .backend = desc.backend,
            .format = desc.format,
            .entry_name = entry_name,
            .argument_count = desc.argument_count,
            .scalar_argument_count = desc.scalar_argument_count,
            .diagnostic_id = try dupeOpt(allocator, desc.diagnostic_id),
            .interface = desc.interface,
        };
    }

    pub fn bufferArgumentCount(self: *const KernelArtifact) BackendError!u32 {
        if (self.scalar_argument_count > self.argument_count) return error.InvalidArtifact;
        return self.argument_count - self.scalar_argument_count;
    }

    pub fn deinit(self: *KernelArtifact) void {
        self.clearPayload();
        freeString(self.allocator, self.entry_name);
        freeOpt(self.allocator, self.diagnostic_id);
        self.* = undefined;
    }

    pub fn setBorrowedBytes(self: *KernelArtifact, bytes: []const u8) void {
        self.clearPayload();
        self.payload = .{ .bytes = bytes };
        self.payload_ownership = .borrowed;
    }

    pub fn setOwnedBytes(self: *KernelArtifact, bytes: []const u8) BackendError!void {
        const owned = self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        self.clearPayload();
        self.payload = .{ .bytes = owned };
        self.payload_ownership = .owned;
    }

    pub fn setBorrowedWords(self: *KernelArtifact, words: []const u32) void {
        self.clearPayload();
        self.payload = .{ .words_u32 = words };
        self.payload_ownership = .borrowed;
    }

    pub fn setOwnedWords(self: *KernelArtifact, words: []const u32) BackendError!void {
        const owned = self.allocator.dupe(u32, words) catch return error.OutOfMemory;
        self.clearPayload();
        self.payload = .{ .words_u32 = owned };
        self.payload_ownership = .owned;
    }

    pub fn setBorrowedText(self: *KernelArtifact, text: []const u8) void {
        self.clearPayload();
        self.payload = .{ .text = text };
        self.payload_ownership = .borrowed;
    }

    pub fn setOwnedText(self: *KernelArtifact, text: []const u8) BackendError!void {
        const owned = self.allocator.dupe(u8, text) catch return error.OutOfMemory;
        self.clearPayload();
        self.payload = .{ .text = owned };
        self.payload_ownership = .owned;
    }

    pub fn setExternalPayload(self: *KernelArtifact, payload: ExternalPayload, ownership: PayloadOwnership) BackendError!void {
        if (ownership == .owned and payload.deinit_fn == null) return error.MissingPayloadDeinit;
        self.clearPayload();
        self.payload = .{ .external = payload };
        self.payload_ownership = ownership;
    }

    fn clearPayload(self: *KernelArtifact) void {
        if (self.payload_ownership == .owned) {
            switch (self.payload) {
                .bytes => |bytes| freeString(self.allocator, bytes),
                .words_u32 => |words| self.allocator.free(@constCast(words)),
                .text => |text| freeString(self.allocator, text),
                .external => |payload| if (payload.deinit_fn) |deinit_fn| deinit_fn(self.allocator, payload.ptr),
                .none => {},
            }
        }
        self.payload = .none;
        self.payload_ownership = .borrowed;
    }
};

/// A caller holds this value for compiled code loaded on a device and uses it to launch that code.
/// The value names compiled code that the backend owns, by id, backend kind and code format. The
/// caller releases the id through the backend handle that loaded it, only after all queued work
/// that can refer to it has finished. That handle is the interface value through which a caller
/// creates buffers, loads compiled code and launches kernels.
pub const LoadedArtifact = struct {
    id: BackendObjectId,
    backend: BackendKind,
    format: ArtifactFormat,
};

/// A graphics pipeline. Clip space puts x = −1 at the target's left edge, y = −1 at its top edge
/// and depth z in [0, 1], so y grows downward in pixels. A triangle is drawn unless `cull` names
/// the way it faces. A pixel is covered when its center lies inside a triangle, with centers on a
/// shared edge going to exactly one triangle by the top-left rule.
pub const RenderPipelineDesc = struct {
    format: RenderArtifactFormat,
    vertex_entry_name: []const u8,
    fragment_entry_name: []const u8,
    target_format: TextureFormat,
    blend_mode: RenderBlendMode = .replace,
    cull: RenderCullMode = .none,
    topology: RenderPrimitiveTopology = .triangle_list,
    depth: ?RenderDepthState = null,
    vertex_layouts: []const RenderVertexBufferLayout = &.{},
    vertex_attributes: []const RenderVertexAttribute = &.{},
    bindings: []const RenderBindingDesc = &.{},
    /// Bytes of the push-constant block both stages read, a multiple of 4. Each draw supplies
    /// exactly this many, and a stage must read inside them.
    push_constant_bytes: u32 = 0,
    /// Bytes of the push-constant block the payload's stages read, as the emitter reported them
    /// with the payload, the way `CompileRequest.push_constants` carries a kernel's layout. It has
    /// no default, so a caller states it, and it may not exceed `push_constant_bytes`.
    push_extent: u32,
    diagnostic_id: ?[]const u8 = null,
    payload: CompilePayload = .none,
};

pub const RenderArtifactDesc = struct {
    backend: BackendKind,
    pipeline: RenderPipelineDesc,
};

pub const RenderArtifact = struct {
    allocator: Allocator,
    backend: BackendKind,
    format: RenderArtifactFormat,
    vertex_entry_name: []const u8,
    fragment_entry_name: []const u8,
    target_format: TextureFormat,
    blend_mode: RenderBlendMode,
    cull: RenderCullMode = .none,
    topology: RenderPrimitiveTopology,
    depth: ?RenderDepthState,
    vertex_layouts: []const RenderVertexBufferLayout,
    vertex_attributes: []const RenderVertexAttribute,
    bindings: []const RenderBindingDesc,
    push_constant_bytes: u32 = 0,
    push_extent: u32 = 0,
    diagnostic_id: ?[]const u8 = null,
    payload: ArtifactPayload = .none,
    payload_ownership: PayloadOwnership = .borrowed,

    pub fn init(allocator: Allocator, desc: RenderArtifactDesc) Allocator.Error!RenderArtifact {
        const vertex_entry_name = try dupeString(allocator, desc.pipeline.vertex_entry_name);
        errdefer freeString(allocator, vertex_entry_name);
        const fragment_entry_name = try dupeString(allocator, desc.pipeline.fragment_entry_name);
        errdefer freeString(allocator, fragment_entry_name);
        const vertex_layouts = try allocator.dupe(RenderVertexBufferLayout, desc.pipeline.vertex_layouts);
        errdefer allocator.free(vertex_layouts);
        const vertex_attributes = try allocator.dupe(RenderVertexAttribute, desc.pipeline.vertex_attributes);
        errdefer allocator.free(vertex_attributes);
        const bindings = try allocator.dupe(RenderBindingDesc, desc.pipeline.bindings);
        errdefer allocator.free(bindings);

        return .{
            .allocator = allocator,
            .backend = desc.backend,
            .format = desc.pipeline.format,
            .vertex_entry_name = vertex_entry_name,
            .fragment_entry_name = fragment_entry_name,
            .target_format = desc.pipeline.target_format,
            .blend_mode = desc.pipeline.blend_mode,
            .cull = desc.pipeline.cull,
            .topology = desc.pipeline.topology,
            .depth = desc.pipeline.depth,
            .vertex_layouts = vertex_layouts,
            .vertex_attributes = vertex_attributes,
            .bindings = bindings,
            .push_constant_bytes = desc.pipeline.push_constant_bytes,
            .push_extent = desc.pipeline.push_extent,
            .diagnostic_id = try dupeOpt(allocator, desc.pipeline.diagnostic_id),
        };
    }

    pub fn deinit(self: *RenderArtifact) void {
        self.clearPayload();
        freeString(self.allocator, self.vertex_entry_name);
        freeString(self.allocator, self.fragment_entry_name);
        self.allocator.free(@constCast(self.vertex_layouts));
        self.allocator.free(@constCast(self.vertex_attributes));
        self.allocator.free(@constCast(self.bindings));
        freeOpt(self.allocator, self.diagnostic_id);
        self.* = undefined;
    }

    pub fn setBorrowedBytes(self: *RenderArtifact, bytes: []const u8) void {
        self.clearPayload();
        self.payload = .{ .bytes = bytes };
        self.payload_ownership = .borrowed;
    }

    pub fn setOwnedBytes(self: *RenderArtifact, bytes: []const u8) BackendError!void {
        const owned = self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        self.clearPayload();
        self.payload = .{ .bytes = owned };
        self.payload_ownership = .owned;
    }

    pub fn setBorrowedWords(self: *RenderArtifact, words: []const u32) void {
        self.clearPayload();
        self.payload = .{ .words_u32 = words };
        self.payload_ownership = .borrowed;
    }

    pub fn setOwnedWords(self: *RenderArtifact, words: []const u32) BackendError!void {
        const owned = self.allocator.dupe(u32, words) catch return error.OutOfMemory;
        self.clearPayload();
        self.payload = .{ .words_u32 = owned };
        self.payload_ownership = .owned;
    }

    pub fn setBorrowedText(self: *RenderArtifact, text: []const u8) void {
        self.clearPayload();
        self.payload = .{ .text = text };
        self.payload_ownership = .borrowed;
    }

    pub fn setOwnedText(self: *RenderArtifact, text: []const u8) BackendError!void {
        const owned = self.allocator.dupe(u8, text) catch return error.OutOfMemory;
        self.clearPayload();
        self.payload = .{ .text = owned };
        self.payload_ownership = .owned;
    }

    pub fn setExternalPayload(self: *RenderArtifact, payload: ExternalPayload, ownership: PayloadOwnership) BackendError!void {
        if (ownership == .owned and payload.deinit_fn == null) return error.MissingPayloadDeinit;
        self.clearPayload();
        self.payload = .{ .external = payload };
        self.payload_ownership = ownership;
    }

    fn clearPayload(self: *RenderArtifact) void {
        if (self.payload_ownership == .owned) {
            switch (self.payload) {
                .bytes => |bytes| freeString(self.allocator, bytes),
                .words_u32 => |words| self.allocator.free(@constCast(words)),
                .text => |text| freeString(self.allocator, text),
                .external => |payload| if (payload.deinit_fn) |deinit_fn| deinit_fn(self.allocator, payload.ptr),
                .none => {},
            }
        }
        self.payload = .none;
        self.payload_ownership = .borrowed;
    }
};

/// A pipeline ready to draw, with the facts a pass checks its draws against.
pub const LoadedRenderArtifact = struct {
    id: BackendObjectId,
    backend: BackendKind,
    format: RenderArtifactFormat,
    target_format: TextureFormat,
    depth: ?RenderDepthState = null,
    vertex_buffer_count: u32 = 0,
    binding_count: u32 = 0,
    push_constant_bytes: u32 = 0,

    /// The facts a backend must report for a pipeline it loaded from `artifact`.
    pub fn describing(artifact: *const RenderArtifact, id: BackendObjectId) LoadedRenderArtifact {
        return .{
            .id = id,
            .backend = artifact.backend,
            .format = artifact.format,
            .target_format = artifact.target_format,
            .depth = artifact.depth,
            .vertex_buffer_count = @intCast(artifact.vertex_layouts.len),
            .binding_count = @intCast(artifact.bindings.len),
            .push_constant_bytes = artifact.push_constant_bytes,
        };
    }
};

/// A caller holds this value to name one device buffer in later transfers and launches. The value
/// names one buffer by id, with its backend, its size in bytes and who owns its memory. The backend
/// handle that created the buffer owns the id until the caller passes it to `destroyObject`.
pub const BufferHandle = struct {
    id: BackendObjectId,
    backend: BackendKind,
    byte_size: usize,
    ownership: BufferOwnership,
};

/// A caller holds this value to order work on one device queue. The value names one ordered queue
/// of device work by id and backend. The backend handle that created the queue owns the id until
/// the caller passes it to `destroyObject`.
pub const StreamHandle = struct {
    id: BackendObjectId,
    backend: BackendKind,
};

/// A caller holds this value to mark a point in queued device work and wait for it. The value names
/// one device event by id and backend. The backend handle that created the event owns the id until
/// the caller passes it to `destroyObject`.
pub const EventHandle = struct {
    id: BackendObjectId,
    backend: BackendKind,
};

pub const SurfaceHandle = struct {
    id: BackendObjectId,
    backend: BackendKind,
    platform: SurfacePlatformKind,
    extent: SurfaceExtent,
    format: TextureFormat,
    color_space: ColorSpace = .srgb,
    present_mode: PresentMode = .fifo,
    generation: u64 = 1,
};

pub const TextureHandle = struct {
    id: BackendObjectId,
    backend: BackendKind,
    extent: TextureExtent,
    format: TextureFormat,
    usage: TextureUsage,
    sample_count: u32 = 1,
    ownership: TextureOwnership = .backend,
    mip_levels: u32 = 1,
};

pub const TextureView = struct {
    texture: TextureHandle,
    format: TextureFormat,
    base_mip_level: u32 = 0,
    mip_level_count: u32 = 1,
    base_array_layer: u32 = 0,
    array_layer_count: u32 = 1,
};

pub const SurfaceFrame = struct {
    id: BackendObjectId,
    backend: BackendKind,
    surface: SurfaceHandle,
    texture: TextureHandle,
    view: TextureView,
    index: u32 = 0,
    generation: u64 = 1,
    token: u64 = 0,
};

/// Where a buffer's memory lies, which decides how a host write reaches it.
pub const BufferMemory = enum {
    /// The memory the device reads fastest. A backend may stage each host
    /// write through a copy the device runs.
    device,
    /// Memory the host writes in place, mapped once when the buffer is made,
    /// and local to the device where the device offers such memory. It suits
    /// small buffers the host rewrites often, such as uniforms. A host write
    /// lands outside the queue's order, so the caller must not write while a
    /// submitted command may read the buffer.
    upload,
};

pub const BufferAllocation = struct {
    byte_size: usize,
    alignment: u32 = 1,
    dtype: ?DType = null,
    element_count: ?u64 = null,
    memory: BufferMemory = .device,
};

/// A caller fills this request to let a backend use caller memory as a buffer without copying. The
/// request carries the caller's bytes, their alignment, and an optional element type and element
/// count. The caller keeps the bytes alive and at the same address until `destroyObject` releases
/// the handle the import returned. The backend never frees the bytes, and the CPU backend frees
/// nothing when it destroys a borrowed buffer.
pub const BufferImport = struct {
    bytes: []u8,
    alignment: u32 = 1,
    dtype: ?DType = null,
    element_count: ?u64 = null,
};

pub const TextureAllocation = struct {
    extent: TextureExtent,
    format: TextureFormat,
    usage: TextureUsage,
    sample_count: u32 = 1,
    /// Levels of the mip chain, from 1 to `extent.mipLevels()`. Each level is
    /// written on its own; none is made from another. A texture of more than
    /// one level is never an attachment.
    mip_levels: u32 = 1,
};

pub const SurfaceCreationRequest = struct {
    platform: SurfacePlatform,
    extent: SurfaceExtent,
    format: TextureFormat,
    color_space: ColorSpace = .srgb,
    present_mode: PresentMode = .fifo,
    alpha_mode: SurfaceAlphaMode = .solid,
    usage: TextureUsage = .{ .present = true, .copy_dst = true },
    max_frames_in_flight: u32 = 2,
};

pub const SurfaceFrameAcquireRequest = struct {
    surface: SurfaceHandle,
};

pub const PresentRequest = struct {
    surface: SurfaceHandle,
    frame: SurfaceFrame,
    wait_events: []const EventHandle = &.{},
    signal_event: ?EventHandle = null,
};

pub const SurfaceClearColor = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub fn valid(self: SurfaceClearColor) bool {
        return std.math.isFinite(self.r) and
            std.math.isFinite(self.g) and
            std.math.isFinite(self.b) and
            std.math.isFinite(self.a);
    }
};

pub const SurfaceFrameWriteOp = union(enum) {
    clear: SurfaceClearColor,
    copy_buffer: BufferHandle,
};

pub const SurfaceFrameWriteRequest = struct {
    surface: SurfaceHandle,
    frame: SurfaceFrame,
    operations: []const SurfaceFrameWriteOp,
    wait_events: []const EventHandle = &.{},
    signal_event: ?EventHandle = null,
};

/// Copies an acquired frame's pixels, as the work queued before the copy leaves them, into a
/// buffer: every row from the top, tightly packed, in the frame's format. A frame takes any number
/// of reads before its present, before or after its one write, and a read leaves the frame as it
/// found it. The frame's texture needs `copy_src`, and the buffer must hold the whole frame. The
/// copy runs on the default stream, so the caller synchronizes that stream before it reads the
/// buffer.
pub const SurfaceFrameReadRequest = struct {
    surface: SurfaceHandle,
    frame: SurfaceFrame,
    buffer: BufferHandle,
};

pub const StreamAllocation = struct {};

pub const EventAllocation = struct {};

pub const BufferBinding = struct {
    handle: BufferHandle,
    access: BufferAccess,
    ownership: BufferOwnership,
    byte_size: usize,
};

pub const BufferWriteRequest = struct {
    handle: BufferHandle,
    bytes: []const u8,
};

pub const BufferFillRequest = struct {
    handle: BufferHandle,
    pattern: u32,
};

pub const BufferReadRequest = struct {
    handle: BufferHandle,
    bytes: []u8,
};

pub const LaunchRequest = struct {
    artifact: *const KernelArtifact,
    loaded_artifact: ?LoadedArtifact = null,
    buffers: []const BufferBinding,
    scalar_arguments: []const gpu_abi.ScalarArgument = &.{},
    geometry: gpu_abi.LaunchGeometry,
    stream: ?StreamHandle = null,
    wait_events: []const EventHandle = &.{},
    signal_event: ?EventHandle = null,
    diagnostic_id: ?[]const u8 = null,
};

/// Five dispatches in the planned population call, doubled to ten and rounded
/// up to the next power of two. A caller can inspect this before recording.
pub const max_sequence_dispatches: usize = sequenceDispatchCapacity(5);
/// CUDA and Metal each allow 32 kernel arguments; Vulkan's limit is larger.
pub const max_sequence_arguments: usize = 32;
pub const max_sequence_scalar_bytes: usize = gpu_abi.max_push_constant_bytes;
pub const max_sequence_name_bytes: usize = 64;

pub fn sequenceDispatchCapacity(step_dispatches: usize) usize {
    std.debug.assert(step_dispatches > 0);
    // The rounded result must fit after doubling the requested step size.
    std.debug.assert(step_dispatches <= @as(usize, 1) << (@bitSizeOf(usize) - 2));
    return std.math.ceilPowerOfTwo(usize, step_dispatches * 2) catch unreachable;
}

/// Dispatches see all writes from earlier dispatches. Streams and events belong
/// to the sequence submission, rather than individual dispatches.
pub const SequenceDispatch = struct {
    launch: LaunchRequest,
    name: []const u8,
};

pub const SequenceFailure = struct {
    stage: enum { validate, record, submit } = .validate,
    dispatch_index: ?usize = null,
    dispatch_name: ?[]const u8 = null,
    limit_name: ?[]const u8 = null,
    limit: usize = 0,
    requested: usize = 0,
};

pub const SequenceRecordRequest = struct {
    /// Geometry and arguments are captured at record time. Loaded artifacts
    /// and device buffers must stay live until the sequence is destroyed.
    dispatches: []const SequenceDispatch,
    failure: ?*SequenceFailure = null,
};

pub const SequenceHandle = struct {
    /// Destroy through BackendHandle.destroyObject. Destruction waits for any
    /// replay still in flight before releasing driver resources.
    id: BackendObjectId,
    backend: BackendKind,
};

pub const SequenceSubmitRequest = struct {
    /// Replays submitted on one stream execute in submission order, including
    /// the dependency from the last dispatch to the next replay's first.
    sequence: SequenceHandle,
    stream: ?StreamHandle = null,
    wait_events: []const EventHandle = &.{},
    signal_event: ?EventHandle = null,
    failure: ?*SequenceFailure = null,
};

/// Records `pass` and submits it once.
pub const RenderRequest = struct {
    pass: RenderPass,
    stream: ?StreamHandle = null,
    wait_events: []const EventHandle = &.{},
    signal_event: ?EventHandle = null,
};

/// Submits a recorded pass again.
pub const RenderBundleSubmit = struct {
    bundle: RenderBundle,
    stream: ?StreamHandle = null,
    wait_events: []const EventHandle = &.{},
    signal_event: ?EventHandle = null,
};

/// Replaces every texel of `texture`'s level `mip_level` with `bytes`, rows tightly packed from the
/// top.
pub const TextureWriteRequest = struct {
    texture: TextureHandle,
    bytes: []const u8,
    mip_level: u32 = 0,
};

/// Copies every texel of `texture`'s level `mip_level` into `bytes`, rows tightly packed from the
/// top.
pub const TextureReadRequest = struct {
    texture: TextureHandle,
    bytes: []u8,
    mip_level: u32 = 0,
};

pub const CompileRequest = struct {
    kernel_name: []const u8,
    requested_format: ArtifactFormat,
    argument_count: u32 = 0,
    scalar_argument_count: u32 = 0,
    required_dtypes: DTypeSet = .{},
    required_features: gpu_abi.Features = .{},
    required_subgroup: gpu_abi.SubgroupRequirements = .{},
    /// Layout the emitter gave the entry's push-constant block, if any.
    push_constants: gpu_abi.PushConstants = .{},
    diagnostic_id: ?[]const u8 = null,
    payload: CompilePayload = .none,
};

pub const CompilePayload = union(enum) {
    none,
    bytes: []const u8,
    words_u32: []const u32,
    text: []const u8,
};

pub const SyncRequest = struct {
    scope: SyncScope,
    stream: ?StreamHandle = null,
    event: ?EventHandle = null,

    pub fn valid(self: SyncRequest) bool {
        return switch (self.scope) {
            .default_stream, .device => self.stream == null and self.event == null,
            .stream => self.stream != null and self.event == null,
            .event => self.stream == null and self.event != null,
        };
    }
};

pub const EventQueryRequest = struct {
    event: EventHandle,
};

pub const EventRecordRequest = struct {
    stream: StreamHandle,
    event: EventHandle,
};

pub const EventElapsedRequest = struct {
    start: EventHandle,
    end: EventHandle,
};

pub const BackendVTable = struct {
    query_capabilities: *const fn (*anyopaque) BackendError!BackendCapabilities,
    create_artifact: ?*const fn (*anyopaque, CompileRequest) BackendError!KernelArtifact = null,
    load_artifact: ?*const fn (*anyopaque, *const KernelArtifact) BackendError!LoadedArtifact = null,
    create_render_artifact: ?*const fn (*anyopaque, RenderPipelineDesc) BackendError!RenderArtifact = null,
    load_render_artifact: ?*const fn (*anyopaque, *const RenderArtifact) BackendError!LoadedRenderArtifact = null,
    allocate_buffer: ?*const fn (*anyopaque, BufferAllocation) BackendError!BufferHandle = null,
    import_buffer: ?*const fn (*anyopaque, BufferImport) BackendError!BufferHandle = null,
    allocate_texture: ?*const fn (*anyopaque, TextureAllocation) BackendError!TextureHandle = null,
    create_surface: ?*const fn (*anyopaque, SurfaceCreationRequest) BackendError!SurfaceHandle = null,
    destroy_surface: ?*const fn (*anyopaque, SurfaceHandle) BackendError!void = null,
    destroy_texture: ?*const fn (*anyopaque, TextureHandle) BackendError!void = null,
    acquire_surface_frame: ?*const fn (*anyopaque, SurfaceFrameAcquireRequest) BackendError!SurfaceFrame = null,
    present_surface_frame: ?*const fn (*anyopaque, PresentRequest) BackendError!void = null,
    write_surface_frame: ?*const fn (*anyopaque, SurfaceFrameWriteRequest) BackendError!void = null,
    read_surface_frame: ?*const fn (*anyopaque, SurfaceFrameReadRequest) BackendError!void = null,
    create_stream: ?*const fn (*anyopaque, StreamAllocation) BackendError!StreamHandle = null,
    create_event: ?*const fn (*anyopaque, EventAllocation) BackendError!EventHandle = null,
    write_buffer: ?*const fn (*anyopaque, BufferWriteRequest) BackendError!void = null,
    fill_buffer: ?*const fn (*anyopaque, BufferFillRequest) BackendError!void = null,
    read_buffer: ?*const fn (*anyopaque, BufferReadRequest) BackendError!void = null,
    launch: ?*const fn (*anyopaque, LaunchRequest) BackendError!void = null,
    record_sequence: ?*const fn (*anyopaque, SequenceRecordRequest) BackendError!SequenceHandle = null,
    submit_sequence: ?*const fn (*anyopaque, SequenceSubmitRequest) BackendError!void = null,
    render: ?*const fn (*anyopaque, RenderRequest) BackendError!void = null,
    create_render_bindings: ?*const fn (*anyopaque, RenderBindingsRequest) BackendError!RenderBindings = null,
    record_render_bundle: ?*const fn (*anyopaque, RenderPass) BackendError!RenderBundle = null,
    submit_render_bundle: ?*const fn (*anyopaque, RenderBundleSubmit) BackendError!void = null,
    write_texture: ?*const fn (*anyopaque, TextureWriteRequest) BackendError!void = null,
    read_texture: ?*const fn (*anyopaque, TextureReadRequest) BackendError!void = null,
    synchronize: ?*const fn (*anyopaque, SyncRequest) BackendError!void = null,
    query_event: ?*const fn (*anyopaque, EventQueryRequest) BackendError!bool = null,
    record_event: ?*const fn (*anyopaque, EventRecordRequest) BackendError!void = null,
    elapsed_event_ns: ?*const fn (*anyopaque, EventElapsedRequest) BackendError!u64 = null,
    destroy_object: ?*const fn (*anyopaque, BackendObjectId) void = null,
    deinit: ?*const fn (*anyopaque, Allocator) void = null,
};

pub const BackendHandle = struct {
    ptr: *anyopaque,
    vtable: *const BackendVTable,
    kind: ?BackendKind = null,

    pub fn backendKind(self: BackendHandle) ?BackendKind {
        return self.kind;
    }

    pub fn queryCapabilities(self: BackendHandle) BackendError!BackendCapabilities {
        return self.vtable.query_capabilities(self.ptr);
    }

    pub fn createArtifact(self: BackendHandle, request: CompileRequest) BackendError!KernelArtifact {
        const caps = try self.queryCapabilities();
        try caps.validateCompileRequest(request);

        const create = self.vtable.create_artifact orelse return error.UnsupportedOperation;
        var artifact = try create(self.ptr, request);
        artifact.interface = .{
            .features = request.required_features,
            .subgroup = request.required_subgroup,
            .push_constants = request.push_constants,
        };
        return artifact;
    }

    pub fn loadArtifact(self: BackendHandle, artifact: *const KernelArtifact) BackendError!LoadedArtifact {
        try self.expectArtifactBackend(artifact);
        if (!artifact.interface.push_constants.valid()) return error.InvalidArtifact;
        const caps = try self.queryCapabilities();
        if (!caps.supportsFeatures(artifact.interface.features)) return error.CapabilityMismatch;
        if (!caps.supportsSubgroup(artifact.interface.subgroup)) return error.CapabilityMismatch;
        const load = self.vtable.load_artifact orelse return error.UnsupportedOperation;
        return load(self.ptr, artifact);
    }

    pub fn createRenderArtifact(self: BackendHandle, desc: RenderPipelineDesc) BackendError!RenderArtifact {
        const caps = try self.queryCapabilities();
        try caps.validateRenderPipelineDesc(desc);

        const create = self.vtable.create_render_artifact orelse return error.UnsupportedOperation;
        var artifact = try create(self.ptr, desc);
        errdefer artifact.deinit();
        try self.expectRenderArtifactBackend(&artifact);
        if (artifact.format != desc.format) return error.InvalidRenderArtifact;
        if (artifact.target_format != desc.target_format) return error.InvalidRenderArtifact;
        if (artifact.blend_mode != desc.blend_mode) return error.InvalidRenderArtifact;
        if (artifact.cull != desc.cull) return error.InvalidRenderArtifact;
        if (artifact.topology != desc.topology) return error.InvalidRenderArtifact;
        return artifact;
    }

    pub fn loadRenderArtifact(self: BackendHandle, artifact: *const RenderArtifact) BackendError!LoadedRenderArtifact {
        try self.expectRenderArtifactBackend(artifact);
        if (artifact.push_extent > artifact.push_constant_bytes) return error.PushConstantRangeExceeded;
        const load = self.vtable.load_render_artifact orelse return error.UnsupportedOperation;
        const loaded = try load(self.ptr, artifact);
        try self.expectLoadedRenderArtifactBackend(loaded);
        const expected = LoadedRenderArtifact.describing(artifact, loaded.id);
        if (!std.meta.eql(loaded, expected)) return error.InvalidRenderArtifact;
        return loaded;
    }

    pub fn createRenderBindings(self: BackendHandle, request: RenderBindingsRequest) BackendError!RenderBindings {
        try self.expectRenderArtifactBackend(request.artifact);
        try self.expectLoadedRenderArtifactBackend(request.pipeline);
        for (request.resources) |resource| switch (resource) {
            .uniform_buffer, .storage_buffer => |buffer| try self.expectBufferBackend(buffer),
            .sampled_texture => |sampled| try self.expectTextureBackend(sampled.texture),
            .storage_texture => |texture| try self.expectTextureBackend(texture),
        };
        const caps = try self.queryCapabilities();
        try caps.validateRenderBindings(request);
        const create = self.vtable.create_render_bindings orelse return error.UnsupportedOperation;
        const bindings = try create(self.ptr, request);
        if (self.kind) |kind| {
            if (bindings.backend != kind) return error.CapabilityMismatch;
        }
        if (bindings.pipeline != request.pipeline.id) return error.InvalidRenderArtifact;
        return bindings;
    }

    pub fn allocateBuffer(self: BackendHandle, request: BufferAllocation) BackendError!BufferHandle {
        const caps = try self.queryCapabilities();
        try caps.validateBufferAllocation(request);
        const allocate = self.vtable.allocate_buffer orelse return error.UnsupportedOperation;
        const handle = try allocate(self.ptr, request);
        try self.expectBufferBackend(handle);
        if (handle.byte_size < request.byte_size) return error.InvalidBuffer;
        return handle;
    }

    /// A caller uses this to hand its own memory to a backend as a buffer without copying it. The
    /// call binds the caller's bytes and returns a buffer whose ownership is `borrowed_external`
    /// and whose size equals the length of the caller's bytes. The call first checks the size,
    /// element type and alignment against the backend's limits, and returns `error.InvalidBuffer`
    /// when the pointer lacks the requested alignment. A backend that does not offer imports
    /// returns `error.UnsupportedOperation`, and at present only the CPU backend offers them.
    pub fn importBuffer(self: BackendHandle, request: BufferImport) BackendError!BufferHandle {
        const caps = try self.queryCapabilities();
        try caps.validateBufferAllocation(.{
            .byte_size = request.bytes.len,
            .alignment = request.alignment,
            .dtype = request.dtype,
            .element_count = request.element_count,
        });
        std.debug.assert(std.math.isPowerOfTwo(request.alignment));
        if (!std.mem.isAligned(@intFromPtr(request.bytes.ptr), request.alignment)) {
            return error.InvalidBuffer;
        }
        const import_fn = self.vtable.import_buffer orelse return error.UnsupportedOperation;
        const handle = try import_fn(self.ptr, request);
        try self.expectBufferBackend(handle);
        if (handle.ownership != .borrowed_external) return error.InvalidBuffer;
        if (handle.byte_size != request.bytes.len) return error.InvalidBuffer;
        return handle;
    }

    pub fn allocateTexture(self: BackendHandle, request: TextureAllocation) BackendError!TextureHandle {
        const caps = try self.queryCapabilities();
        try caps.validateTextureAllocation(request);
        const allocate = self.vtable.allocate_texture orelse return error.UnsupportedOperation;
        const handle = try allocate(self.ptr, request);
        try self.expectTextureBackend(handle);
        if (!sameTextureExtent(handle.extent, request.extent)) return error.InvalidTexture;
        if (handle.format != request.format) return error.InvalidTexture;
        if (!handle.usage.containsAll(request.usage)) return error.InvalidTexture;
        if (handle.sample_count != request.sample_count) return error.InvalidTexture;
        if (handle.mip_levels != request.mip_levels) return error.InvalidTexture;
        return handle;
    }

    pub fn createSurface(self: BackendHandle, request: SurfaceCreationRequest) BackendError!SurfaceHandle {
        const caps = try self.queryCapabilities();
        try caps.validateSurfaceCreation(request);
        const create = self.vtable.create_surface orelse return error.UnsupportedOperation;
        const handle = try create(self.ptr, request);
        try self.expectSurfaceBackend(handle);
        if (handle.platform != request.platform.kind()) return error.InvalidSurface;
        if (!caps.surfaces.supportsExtent(handle.extent)) return error.InvalidSurface;
        if (handle.format != request.format) return error.InvalidSurface;
        if (handle.color_space != request.color_space) return error.InvalidSurface;
        if (handle.present_mode != request.present_mode) return error.InvalidSurface;
        return handle;
    }

    pub fn destroySurface(self: BackendHandle, surface: SurfaceHandle) BackendError!void {
        try self.expectSurfaceBackend(surface);
        const destroy = self.vtable.destroy_surface orelse return error.UnsupportedOperation;
        return destroy(self.ptr, surface);
    }

    pub fn destroyTexture(self: BackendHandle, texture: TextureHandle) BackendError!void {
        try self.expectTextureBackend(texture);
        const destroy = self.vtable.destroy_texture orelse return error.UnsupportedOperation;
        return destroy(self.ptr, texture);
    }

    pub fn acquireSurfaceFrame(self: BackendHandle, request: SurfaceFrameAcquireRequest) BackendError!SurfaceFrame {
        try self.expectSurfaceBackend(request.surface);
        const acquire = self.vtable.acquire_surface_frame orelse return error.UnsupportedOperation;
        const frame = try acquire(self.ptr, request);
        try self.expectSurfaceFrameBackend(frame);
        try expectFrameMatchesSurface(frame, request.surface);
        return frame;
    }

    pub fn presentSurfaceFrame(self: BackendHandle, request: PresentRequest) BackendError!void {
        try self.expectSurfaceBackend(request.surface);
        try self.expectSurfaceFrameBackend(request.frame);
        try expectFrameMatchesSurface(request.frame, request.surface);
        for (request.wait_events) |event| try self.expectEventBackend(event);
        if (request.signal_event) |event| try self.expectEventBackend(event);
        const present = self.vtable.present_surface_frame orelse return error.UnsupportedOperation;
        return present(self.ptr, request);
    }

    pub fn writeSurfaceFrame(self: BackendHandle, request: SurfaceFrameWriteRequest) BackendError!void {
        try self.expectSurfaceBackend(request.surface);
        try self.expectSurfaceFrameBackend(request.frame);
        try expectFrameMatchesSurface(request.frame, request.surface);
        try expectSurfaceFrameWriteRequest(request);
        for (request.operations) |op| switch (op) {
            .clear => {},
            .copy_buffer => |buffer| try self.expectBufferBackend(buffer),
        };
        for (request.wait_events) |event| try self.expectEventBackend(event);
        if (request.signal_event) |event| try self.expectEventBackend(event);
        const write = self.vtable.write_surface_frame orelse return error.UnsupportedOperation;
        return write(self.ptr, request);
    }

    pub fn readSurfaceFrame(self: BackendHandle, request: SurfaceFrameReadRequest) BackendError!void {
        try self.expectSurfaceBackend(request.surface);
        try self.expectSurfaceFrameBackend(request.frame);
        try expectFrameMatchesSurface(request.frame, request.surface);
        try self.expectBufferBackend(request.buffer);
        if (!request.frame.texture.usage.copy_src) return error.InvalidTexture;
        if (request.buffer.byte_size < try textureByteSize(request.frame.texture, 0)) return error.InvalidBuffer;
        const read = self.vtable.read_surface_frame orelse return error.UnsupportedOperation;
        return read(self.ptr, request);
    }

    pub fn createStream(self: BackendHandle, request: StreamAllocation) BackendError!StreamHandle {
        const caps = try self.queryCapabilities();
        try caps.validateRuntimeRequirements(.{ .streams = true });
        const create = self.vtable.create_stream orelse return error.UnsupportedOperation;
        return create(self.ptr, request);
    }

    pub fn createEvent(self: BackendHandle, request: EventAllocation) BackendError!EventHandle {
        const caps = try self.queryCapabilities();
        try caps.validateRuntimeRequirements(.{ .events = true });
        const create = self.vtable.create_event orelse return error.UnsupportedOperation;
        return create(self.ptr, request);
    }

    pub fn writeBuffer(self: BackendHandle, request: BufferWriteRequest) BackendError!void {
        try self.expectBufferBackend(request.handle);
        const write = self.vtable.write_buffer orelse return error.UnsupportedOperation;
        return write(self.ptr, request);
    }

    pub fn fillBuffer(self: BackendHandle, request: BufferFillRequest) BackendError!void {
        try self.expectBufferBackend(request.handle);
        const fill = self.vtable.fill_buffer orelse return error.UnsupportedOperation;
        return fill(self.ptr, request);
    }

    pub fn readBuffer(self: BackendHandle, request: BufferReadRequest) BackendError!void {
        try self.expectBufferBackend(request.handle);
        if (request.bytes.len < request.handle.byte_size) return error.ReadBufferDestinationTooSmall;
        const read = self.vtable.read_buffer orelse return error.UnsupportedOperation;
        return read(self.ptr, request);
    }

    pub fn launch(self: BackendHandle, request: LaunchRequest) BackendError!void {
        try self.expectLaunchBackends(request);
        try expectLaunchArgumentCount(request);
        const caps = try self.queryCapabilities();
        try caps.validateLaunchGeometry(request.geometry);
        try caps.validateLaunchRuntime(request);

        const launch_fn = self.vtable.launch orelse return error.UnsupportedOperation;
        return launch_fn(self.ptr, request);
    }

    pub fn recordSequence(self: BackendHandle, request: SequenceRecordRequest) BackendError!SequenceHandle {
        if (request.failure) |failure| failure.* = .{};
        if (request.dispatches.len > max_sequence_dispatches) {
            if (request.failure) |failure| failure.* = .{
                .limit_name = "max_sequence_dispatches",
                .limit = max_sequence_dispatches,
                .requested = request.dispatches.len,
            };
            return error.SequenceCapacityExceeded;
        }
        if (request.dispatches.len == 0) return error.LaunchArgumentMismatch;
        for (request.dispatches, 0..) |dispatch, index| {
            const launch_request = dispatch.launch;
            if (request.failure) |failure| failure.* = .{
                .dispatch_index = index,
                .dispatch_name = dispatch.name,
            };
            if (launch_request.stream != null or launch_request.wait_events.len != 0 or
                launch_request.signal_event != null) return error.LaunchArgumentMismatch;
            if (dispatch.name.len == 0) return error.LaunchArgumentMismatch;
            if (launch_request.buffers.len + launch_request.scalar_arguments.len > max_sequence_arguments) {
                if (request.failure) |failure| {
                    failure.limit_name = "max_sequence_arguments";
                    failure.limit = max_sequence_arguments;
                    failure.requested = launch_request.buffers.len + launch_request.scalar_arguments.len;
                }
                return error.SequenceCapacityExceeded;
            }
            var scalar_bytes: usize = 0;
            for (launch_request.scalar_arguments) |scalar| scalar_bytes += switch (scalar) {
                .i32, .u32, .f32 => 4,
                .i64, .u64, .f64 => 8,
            };
            if (scalar_bytes > max_sequence_scalar_bytes) {
                if (request.failure) |failure| {
                    failure.limit_name = "max_sequence_scalar_bytes";
                    failure.limit = max_sequence_scalar_bytes;
                    failure.requested = scalar_bytes;
                }
                return error.SequenceCapacityExceeded;
            }
            if (dispatch.name.len > max_sequence_name_bytes) {
                if (request.failure) |failure| {
                    failure.limit_name = "max_sequence_name_bytes";
                    failure.limit = max_sequence_name_bytes;
                    failure.requested = dispatch.name.len;
                }
                return error.SequenceCapacityExceeded;
            }
        }
        const caps = try self.queryCapabilities();
        for (request.dispatches, 0..) |dispatch, index| {
            if (request.failure) |failure| failure.* = .{
                .dispatch_index = index,
                .dispatch_name = dispatch.name,
            };
            try self.expectLaunchBackends(dispatch.launch);
            try expectLaunchArgumentCount(dispatch.launch);
            try caps.validateLaunchGeometry(dispatch.launch.geometry);
        }
        if (request.failure) |failure| failure.* = .{ .stage = .record };
        const record = self.vtable.record_sequence orelse return error.UnsupportedOperation;
        const sequence = try record(self.ptr, request);
        if (self.kind) |kind| if (sequence.backend != kind) return error.CapabilityMismatch;
        if (request.failure) |failure| failure.* = .{};
        return sequence;
    }

    pub fn submitSequence(self: BackendHandle, request: SequenceSubmitRequest) BackendError!void {
        if (request.failure) |failure| failure.* = .{ .stage = .submit };
        if (self.kind) |kind| if (request.sequence.backend != kind) return error.InvalidArtifact;
        try self.expectSubmitBackends(request.stream, request.wait_events, request.signal_event);
        const caps = try self.queryCapabilities();
        try caps.validateSubmitRuntime(request.stream, request.wait_events, request.signal_event);
        const submit = self.vtable.submit_sequence orelse return error.UnsupportedOperation;
        try submit(self.ptr, request);
        if (request.failure) |failure| failure.* = .{};
    }

    pub fn render(self: BackendHandle, request: RenderRequest) BackendError!void {
        try self.expectRenderPassBackends(request.pass);
        try self.expectSubmitBackends(request.stream, request.wait_events, request.signal_event);
        const caps = try self.queryCapabilities();
        try caps.validateRenderPass(request.pass);
        try caps.validateSubmitRuntime(request.stream, request.wait_events, request.signal_event);

        const render_fn = self.vtable.render orelse return error.UnsupportedOperation;
        return render_fn(self.ptr, request);
    }

    pub fn recordRenderBundle(self: BackendHandle, pass: RenderPass) BackendError!RenderBundle {
        try self.expectRenderPassBackends(pass);
        const caps = try self.queryCapabilities();
        try caps.validateRenderPass(pass);
        const record = self.vtable.record_render_bundle orelse return error.UnsupportedOperation;
        const bundle = try record(self.ptr, pass);
        if (self.kind) |kind| {
            if (bundle.backend != kind) return error.CapabilityMismatch;
        }
        if (bundle.draw_count != pass.draws.len) return error.RenderFailed;
        return bundle;
    }

    pub fn submitRenderBundle(self: BackendHandle, request: RenderBundleSubmit) BackendError!void {
        if (self.kind) |kind| {
            if (request.bundle.backend != kind) return error.RenderArgumentMismatch;
        }
        try self.expectSubmitBackends(request.stream, request.wait_events, request.signal_event);
        const caps = try self.queryCapabilities();
        try caps.validateSubmitRuntime(request.stream, request.wait_events, request.signal_event);
        const submit = self.vtable.submit_render_bundle orelse return error.UnsupportedOperation;
        return submit(self.ptr, request);
    }

    pub fn writeTexture(self: BackendHandle, request: TextureWriteRequest) BackendError!void {
        try self.expectTextureBackend(request.texture);
        try BackendCapabilities.validateTextureTransfer(request.texture, request.mip_level, request.bytes.len, .{ .copy_dst = true });
        const write = self.vtable.write_texture orelse return error.UnsupportedOperation;
        return write(self.ptr, request);
    }

    pub fn readTexture(self: BackendHandle, request: TextureReadRequest) BackendError!void {
        try self.expectTextureBackend(request.texture);
        try BackendCapabilities.validateTextureTransfer(request.texture, request.mip_level, request.bytes.len, .{ .copy_src = true });
        const read = self.vtable.read_texture orelse return error.UnsupportedOperation;
        return read(self.ptr, request);
    }

    pub fn synchronize(self: BackendHandle, request: SyncRequest) BackendError!void {
        if (!request.valid()) return error.UnsupportedOperation;
        try self.expectSyncBackends(request);
        const caps = try self.queryCapabilities();
        try caps.validateSyncRuntime(request);
        const sync = self.vtable.synchronize orelse return error.UnsupportedOperation;
        return sync(self.ptr, request);
    }

    pub fn queryEvent(self: BackendHandle, request: EventQueryRequest) BackendError!bool {
        try self.expectEventBackend(request.event);
        const caps = try self.queryCapabilities();
        try caps.validateRuntimeRequirements(.{ .events = true });
        const query = self.vtable.query_event orelse return error.UnsupportedOperation;
        return query(self.ptr, request);
    }

    pub fn recordEvent(self: BackendHandle, request: EventRecordRequest) BackendError!void {
        try self.expectStreamBackend(request.stream);
        try self.expectEventBackend(request.event);
        const caps = try self.queryCapabilities();
        try caps.validateRuntimeRequirements(.{ .streams = true, .events = true });
        const record = self.vtable.record_event orelse return error.UnsupportedOperation;
        return record(self.ptr, request);
    }

    pub fn elapsedEventNs(self: BackendHandle, request: EventElapsedRequest) BackendError!u64 {
        try self.expectEventBackend(request.start);
        try self.expectEventBackend(request.end);
        const caps = try self.queryCapabilities();
        try caps.validateRuntimeRequirements(.{ .events = true });
        const elapsed = self.vtable.elapsed_event_ns orelse return error.UnsupportedOperation;
        return elapsed(self.ptr, request);
    }

    /// A caller uses this to release a buffer, queue, event or loaded code that this backend handle
    /// created. The call releases one object this handle created. Before the call, the caller makes
    /// sure all launches, copies, queues and events still in flight have finished using the object.
    /// The call leaves state unchanged on a backend lacking a release function.
    pub fn destroyObject(self: BackendHandle, id: BackendObjectId) void {
        if (self.vtable.destroy_object) |destroy| destroy(self.ptr, id);
    }

    pub fn deinit(self: BackendHandle, allocator: Allocator) void {
        if (self.vtable.deinit) |deinit_fn| deinit_fn(self.ptr, allocator);
    }

    fn expectArtifactBackend(self: BackendHandle, artifact: *const KernelArtifact) BackendError!void {
        const kind = self.kind orelse return;
        if (artifact.backend != kind) return error.CapabilityMismatch;
    }

    fn expectLoadedArtifactBackend(self: BackendHandle, loaded: LoadedArtifact) BackendError!void {
        const kind = self.kind orelse return;
        if (loaded.backend != kind) return error.InvalidArtifact;
    }

    fn expectRenderArtifactBackend(self: BackendHandle, artifact: *const RenderArtifact) BackendError!void {
        const kind = self.kind orelse return;
        if (artifact.backend != kind) return error.CapabilityMismatch;
    }

    fn expectLoadedRenderArtifactBackend(self: BackendHandle, loaded: LoadedRenderArtifact) BackendError!void {
        const kind = self.kind orelse return;
        if (loaded.backend != kind) return error.InvalidRenderArtifact;
    }

    fn expectBufferBackend(self: BackendHandle, handle: BufferHandle) BackendError!void {
        const kind = self.kind orelse return;
        if (handle.backend != kind) return error.InvalidBuffer;
    }

    fn expectSurfaceBackend(self: BackendHandle, handle: SurfaceHandle) BackendError!void {
        const kind = self.kind orelse return;
        if (handle.backend != kind) return error.InvalidSurface;
    }

    fn expectTextureBackend(self: BackendHandle, handle: TextureHandle) BackendError!void {
        const kind = self.kind orelse return;
        if (handle.backend != kind) return error.InvalidTexture;
    }

    fn expectTextureViewBackend(self: BackendHandle, view: TextureView) BackendError!void {
        try self.expectTextureBackend(view.texture);
    }

    fn expectSurfaceFrameBackend(self: BackendHandle, frame: SurfaceFrame) BackendError!void {
        const kind = self.kind orelse return;
        if (frame.backend != kind) return error.InvalidSurfaceFrame;
        try self.expectSurfaceBackend(frame.surface);
        try self.expectTextureBackend(frame.texture);
        try self.expectTextureViewBackend(frame.view);
    }

    fn expectStreamBackend(self: BackendHandle, handle: StreamHandle) BackendError!void {
        const kind = self.kind orelse return;
        if (handle.backend != kind) return error.InvalidStream;
    }

    fn expectEventBackend(self: BackendHandle, handle: EventHandle) BackendError!void {
        const kind = self.kind orelse return;
        if (handle.backend != kind) return error.InvalidEvent;
    }

    fn expectLaunchBackends(self: BackendHandle, request: LaunchRequest) BackendError!void {
        try self.expectArtifactBackend(request.artifact);
        if (request.loaded_artifact) |loaded| {
            try self.expectLoadedArtifactBackend(loaded);
            if (loaded.backend != request.artifact.backend or loaded.format != request.artifact.format) {
                return error.InvalidArtifact;
            }
        }
        for (request.buffers) |binding| {
            try self.expectBufferBackend(binding.handle);
        }
        if (request.stream) |stream| try self.expectStreamBackend(stream);
        for (request.wait_events) |event| try self.expectEventBackend(event);
        if (request.signal_event) |event| try self.expectEventBackend(event);
    }

    fn expectRenderPassBackends(self: BackendHandle, pass: RenderPass) BackendError!void {
        try self.expectTextureViewBackend(pass.color.view);
        if (pass.depth) |depth| try self.expectTextureViewBackend(depth.view);
        for (pass.draws) |draw| {
            try self.expectLoadedRenderArtifactBackend(draw.pipeline);
            if (draw.bindings) |bindings| {
                if (self.kind) |kind| {
                    if (bindings.backend != kind) return error.RenderArgumentMismatch;
                }
            }
            for (draw.vertex_buffers) |range| try self.expectBufferBackend(range.buffer);
            if (draw.index_buffer) |range| try self.expectBufferBackend(range.buffer);
        }
    }

    fn expectSubmitBackends(
        self: BackendHandle,
        stream: ?StreamHandle,
        wait_events: []const EventHandle,
        signal_event: ?EventHandle,
    ) BackendError!void {
        if (stream) |handle| try self.expectStreamBackend(handle);
        for (wait_events) |event| try self.expectEventBackend(event);
        if (signal_event) |event| try self.expectEventBackend(event);
    }

    fn expectLaunchArgumentCount(request: LaunchRequest) BackendError!void {
        const actual = request.buffers.len + request.scalar_arguments.len;
        const expected: usize = @intCast(request.artifact.argument_count);
        if (actual != expected) return error.LaunchArgumentMismatch;
    }

    fn expectSyncBackends(self: BackendHandle, request: SyncRequest) BackendError!void {
        switch (request.scope) {
            .default_stream, .device => {},
            .stream => if (request.stream) |stream| try self.expectStreamBackend(stream),
            .event => if (request.event) |event| try self.expectEventBackend(event),
        }
    }
};

fn sameSurfaceExtent(a: SurfaceExtent, b: SurfaceExtent) bool {
    return a.width == b.width and a.height == b.height;
}

fn scissorWithin(scissor: RenderScissor, extent: TextureExtent) bool {
    const right = @as(u64, scissor.x) + scissor.width;
    const bottom = @as(u64, scissor.y) + scissor.height;
    return right <= extent.width and bottom <= extent.height;
}

fn sameTextureExtent(a: TextureExtent, b: TextureExtent) bool {
    return a.width == b.width and a.height == b.height and a.depth == b.depth;
}

fn expectFrameMatchesSurface(frame: SurfaceFrame, surface: SurfaceHandle) BackendError!void {
    if (frame.surface.id != surface.id) return error.InvalidSurfaceFrame;
    if (frame.surface.backend != surface.backend) return error.InvalidSurfaceFrame;
    if (frame.surface.generation != surface.generation) return error.SurfaceFrameExpired;
    if (frame.generation != surface.generation) return error.SurfaceFrameExpired;
    if (!sameSurfaceExtent(frame.surface.extent, surface.extent)) return error.SurfaceFrameExpired;
    if (frame.surface.format != surface.format) return error.SurfaceFrameExpired;
    if (frame.texture.backend != surface.backend) return error.InvalidTexture;
    if (frame.texture.format != surface.format) return error.InvalidTexture;
    if (frame.view.texture.id != frame.texture.id) return error.InvalidTexture;
    if (frame.view.format != frame.texture.format) return error.InvalidTexture;
}

fn expectSurfaceFrameWriteRequest(request: SurfaceFrameWriteRequest) BackendError!void {
    if (request.operations.len == 0) return error.InvalidSurfaceFrame;
    if (!request.frame.texture.usage.copy_dst) return error.InvalidTexture;
    const required_bytes = try textureByteSize(request.frame.texture, 0);
    for (request.operations) |op| switch (op) {
        .clear => |color| if (!color.valid()) return error.InvalidSurfaceFrame,
        .copy_buffer => |buffer| if (buffer.byte_size < required_bytes) return error.InvalidBuffer,
    };
}

fn textureByteSize(texture: TextureHandle, level: u32) BackendError!usize {
    if (!texture.extent.valid()) return error.InvalidTexture;
    if (level >= texture.mip_levels) return error.InvalidTexture;
    const extent = texture.extent.mip(level);
    const width: usize = @intCast(extent.width);
    const height: usize = @intCast(extent.height);
    const depth: usize = @intCast(extent.depth);
    const wh = std.math.mul(usize, width, height) catch return error.InvalidTexture;
    const pixels = std.math.mul(usize, wh, depth) catch return error.InvalidTexture;
    return std.math.mul(usize, pixels, texture.format.texelBytes()) catch return error.InvalidTexture;
}

fn bitForDType(value: DType) u64 {
    const shift: u6 = @intCast(@backingInt(value));
    return @as(u64, 1) << shift;
}

fn bitForArtifactFormat(value: ArtifactFormat) u64 {
    const shift: u6 = @intCast(@backingInt(value));
    return @as(u64, 1) << shift;
}

fn bitForTextureFormat(value: TextureFormat) u64 {
    const shift: u6 = @intCast(@backingInt(value));
    return @as(u64, 1) << shift;
}

fn bitForPresentMode(value: PresentMode) u64 {
    const shift: u6 = @intCast(@backingInt(value));
    return @as(u64, 1) << shift;
}

fn bitForColorSpace(value: ColorSpace) u64 {
    const shift: u6 = @intCast(@backingInt(value));
    return @as(u64, 1) << shift;
}

fn bitForSurfacePlatformKind(value: SurfacePlatformKind) u64 {
    const shift: u6 = @intCast(@backingInt(value));
    return @as(u64, 1) << shift;
}

fn bitForRenderArtifactFormat(value: RenderArtifactFormat) u64 {
    const shift: u6 = @intCast(@backingInt(value));
    return @as(u64, 1) << shift;
}

fn bitForRenderBlendMode(value: RenderBlendMode) u64 {
    const shift: u6 = @intCast(@backingInt(value));
    return @as(u64, 1) << shift;
}

fn bitForRenderPrimitiveTopology(value: RenderPrimitiveTopology) u64 {
    const shift: u6 = @intCast(@backingInt(value));
    return @as(u64, 1) << shift;
}

fn bitForRenderVertexFormat(value: RenderVertexFormat) u64 {
    const shift: u6 = @intCast(@backingInt(value));
    return @as(u64, 1) << shift;
}

fn bitForRenderBindingKind(value: RenderBindingKind) u64 {
    const shift: u6 = @intCast(@backingInt(value));
    return @as(u64, 1) << shift;
}

fn bitForRenderIndexFormat(value: RenderIndexFormat) u64 {
    const shift: u6 = @intCast(@backingInt(value));
    return @as(u64, 1) << shift;
}

fn renderVertexFormatByteSize(format: RenderVertexFormat) u32 {
    return switch (format) {
        .float32, .uint32 => 4,
        .float32x2, .uint32x2 => 8,
        .float32x3 => 12,
        .float32x4, .uint32x4 => 16,
    };
}

fn dupeOpt(allocator: Allocator, value: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (value) |actual| try dupeString(allocator, actual) else null;
}

fn freeOpt(allocator: Allocator, value: ?[]const u8) void {
    if (value) |actual| freeString(allocator, actual);
}

fn dupeString(allocator: Allocator, value: []const u8) Allocator.Error![]const u8 {
    return try allocator.dupe(u8, value);
}

fn freeString(allocator: Allocator, value: []const u8) void {
    allocator.free(@constCast(value));
}

const OwnedExternalPayloadState = struct {
    destroyed: *bool,

    fn destroy(allocator: Allocator, ptr: *anyopaque) void {
        const state: *@This() = @ptrCast(@alignCast(ptr));
        state.destroyed.* = true;
        allocator.destroy(state);
    }
};

const FakeBackendState = struct {
    launched: bool = false,
    last_buffer_ownership: ?BufferOwnership = null,
    event_ready: bool = false,
    queried_event: ?BackendObjectId = null,
    recorded_event: ?BackendObjectId = null,
    record_stream: ?BackendObjectId = null,
    elapsed_start_event: ?BackendObjectId = null,
    elapsed_end_event: ?BackendObjectId = null,
    elapsed_ns: u64 = 0,
    next_id: BackendObjectId = 1,
    allocation_count: usize = 0,
    last_allocation: ?BufferAllocation = null,
    allocated_byte_size: ?usize = null,
    allocated_backend: BackendKind = .cuda,
    created_stream: bool = false,
    created_event: bool = false,
    supports_streams: bool = true,
    supports_events: bool = true,
    supports_timeline_events: bool = false,
    sync_count: usize = 0,
    last_sync_request: ?SyncRequest = null,
    global_bytes: ?u64 = null,
    max_allocation_bytes: ?u64 = null,
    min_buffer_alignment: u32 = 1,
    supports_textures: bool = true,
    supports_surfaces: bool = true,
    texture_allocate_count: usize = 0,
    created_surface_count: usize = 0,
    acquired_frame_count: usize = 0,
    present_count: usize = 0,
    surface_write_count: usize = 0,
    last_surface_write_frame_id: ?BackendObjectId = null,
    last_surface_write_op_count: usize = 0,
    surface_read_count: usize = 0,
    last_surface_read_buffer_id: ?BackendObjectId = null,
    destroyed_surface_count: usize = 0,
    destroyed_texture_count: usize = 0,
    allocated_texture_backend: BackendKind = .cuda,
    created_surface_backend: BackendKind = .cuda,
    created_surface_extent: ?SurfaceExtent = null,
    supports_raster: bool = true,
    render_create_count: usize = 0,
    render_load_count: usize = 0,
    render_count: usize = 0,
    created_render_backend: BackendKind = .cuda,
    loaded_render_backend: BackendKind = .cuda,
    last_render_draw_count: usize = 0,
    last_render_vertex_count: u32 = 0,
    last_render_instance_count: u32 = 0,
    render_bindings_count: usize = 0,
    bundle_record_count: usize = 0,
    bundle_submit_count: usize = 0,
    texture_write_count: usize = 0,
    texture_read_count: usize = 0,
};

fn fakeQueryCapabilities(ptr: *anyopaque) BackendError!BackendCapabilities {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    return .{
        .identity = .{
            .backend = .cuda,
            .family = .nvidia_cuda,
            .name = "fake-cuda",
        },
        .memory = .{
            .global_bytes = state.global_bytes,
            .max_allocation_bytes = state.max_allocation_bytes,
            .min_buffer_alignment = state.min_buffer_alignment,
        },
        .dtypes = DTypeSet.init(&.{ .f32, .u32 }),
        .artifact_formats = ArtifactFormatSet.init(&.{.cuda_ptx}),
        .runtime = .{
            .streams = state.supports_streams,
            .events = state.supports_events,
            .timeline_events = state.supports_timeline_events,
        },
        .features = .{
            .dynamic_shared_memory = true,
        },
        .textures = if (state.supports_textures) .{
            .supported = true,
            .formats = TextureFormatSet.init(&.{ .rgba8_unorm, .bgra8_unorm, .depth32_float }),
            .usages = .{
                .copy_src = true,
                .copy_dst = true,
                .sampled = true,
                .storage = true,
                .color_attachment = true,
                .depth_attachment = true,
                .present = true,
            },
            .max_extent = .{ .width = 8192, .height = 8192, .depth = 16 },
            .max_sample_count = 4,
        } else .{},
        .surfaces = if (state.supports_surfaces) .{
            .supported = true,
            .platforms = SurfacePlatformSet.init(&.{.headless}),
            .formats = TextureFormatSet.init(&.{ .rgba8_unorm, .bgra8_unorm }),
            .color_spaces = ColorSpaceSet.init(&.{ .srgb, .linear }),
            .present_modes = PresentModeSet.init(&.{ .fifo, .mailbox }),
            .usages = .{
                .copy_dst = true,
                .storage = true,
                .color_attachment = true,
                .present = true,
            },
            .max_extent = .{ .width = 8192, .height = 8192 },
            .max_frames_in_flight = 3,
        } else .{},
        .raster = if (state.supports_raster) .{
            .supported = true,
            .artifact_formats = RenderArtifactFormatSet.init(&.{.external}),
            .target_formats = TextureFormatSet.init(&.{ .rgba8_unorm, .bgra8_unorm }),
            .depth_formats = TextureFormatSet.init(&.{.depth32_float}),
            .blend_modes = RenderBlendModeSet.init(&.{ .replace, .alpha_premultiplied }),
            .topologies = RenderPrimitiveTopologySet.init(&.{ .triangle_list, .triangle_strip }),
            .vertex_formats = RenderVertexFormatSet.init(&.{ .float32x2, .float32x4, .uint32 }),
            .binding_kinds = RenderBindingKindSet.init(&.{ .uniform_buffer, .sampled_texture }),
            .index_formats = RenderIndexFormatSet.init(&.{ .none, .u16, .u32 }),
            .max_vertex_buffers = 4,
            .max_vertex_attributes = 8,
            .max_bindings = 8,
            .instancing = true,
        } else .{},
        .threadgroup = .{
            .max_threads = 256,
            .max_blocks = .{ 65_535, 65_535, 65_535 },
            .max_threads_per_dim = .{ 256, 16, 16 },
            .max_grid_per_dim = .{ 65_535, 65_535, 64 },
            .shared_memory_bytes = 48 * 1024,
        },
    };
}

fn fakeLaunch(ptr: *anyopaque, request: LaunchRequest) BackendError!void {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    if (request.buffers.len + request.scalar_arguments.len != request.artifact.argument_count) {
        return error.LaunchArgumentMismatch;
    }
    state.launched = true;
    state.last_buffer_ownership = request.buffers[0].ownership;
}

fn fakeAllocateBuffer(ptr: *anyopaque, request: BufferAllocation) BackendError!BufferHandle {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    defer state.next_id += 1;
    state.allocation_count += 1;
    state.last_allocation = request;
    return .{
        .id = state.next_id,
        .backend = state.allocated_backend,
        .byte_size = state.allocated_byte_size orelse request.byte_size,
        .ownership = .backend,
    };
}

fn fakeAllocateTexture(ptr: *anyopaque, request: TextureAllocation) BackendError!TextureHandle {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    defer state.next_id += 1;
    state.texture_allocate_count += 1;
    return .{
        .id = state.next_id,
        .backend = state.allocated_texture_backend,
        .extent = request.extent,
        .format = request.format,
        .usage = request.usage,
        .sample_count = request.sample_count,
        .ownership = .backend,
    };
}

fn fakeCreateSurface(ptr: *anyopaque, request: SurfaceCreationRequest) BackendError!SurfaceHandle {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    defer state.next_id += 1;
    state.created_surface_count += 1;
    const extent = state.created_surface_extent orelse request.extent;
    return .{
        .id = state.next_id,
        .backend = state.created_surface_backend,
        .platform = request.platform.kind(),
        .extent = extent,
        .format = request.format,
        .color_space = request.color_space,
        .present_mode = request.present_mode,
        .generation = 1,
    };
}

fn fakeDestroySurface(ptr: *anyopaque, _: SurfaceHandle) BackendError!void {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.destroyed_surface_count += 1;
}

fn fakeDestroyTexture(ptr: *anyopaque, _: TextureHandle) BackendError!void {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.destroyed_texture_count += 1;
}

fn fakeAcquireSurfaceFrame(ptr: *anyopaque, request: SurfaceFrameAcquireRequest) BackendError!SurfaceFrame {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    const texture_id = state.next_id;
    state.next_id += 1;
    const frame_id = state.next_id;
    state.next_id += 1;
    state.acquired_frame_count += 1;
    const texture = TextureHandle{
        .id = texture_id,
        .backend = request.surface.backend,
        .extent = .{
            .width = request.surface.extent.width,
            .height = request.surface.extent.height,
            .depth = 1,
        },
        .format = request.surface.format,
        .usage = .{ .present = true, .color_attachment = true, .copy_dst = true },
        .sample_count = 1,
        .ownership = .acquired_surface,
    };
    const view = TextureView{
        .texture = texture,
        .format = texture.format,
    };
    return .{
        .id = frame_id,
        .backend = request.surface.backend,
        .surface = request.surface,
        .texture = texture,
        .view = view,
        .generation = request.surface.generation,
    };
}

fn fakePresentSurfaceFrame(ptr: *anyopaque, _: PresentRequest) BackendError!void {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.present_count += 1;
}

fn fakeWriteSurfaceFrame(ptr: *anyopaque, request: SurfaceFrameWriteRequest) BackendError!void {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.surface_write_count += 1;
    state.last_surface_write_frame_id = request.frame.id;
    state.last_surface_write_op_count = request.operations.len;
}

fn fakeReadSurfaceFrame(ptr: *anyopaque, request: SurfaceFrameReadRequest) BackendError!void {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.surface_read_count += 1;
    state.last_surface_read_buffer_id = request.buffer.id;
}

fn fakeCreateRenderArtifact(ptr: *anyopaque, desc: RenderPipelineDesc) BackendError!RenderArtifact {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.render_create_count += 1;
    var artifact = RenderArtifact.init(std.testing.allocator, .{
        .backend = state.created_render_backend,
        .pipeline = desc,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    artifact.setBorrowedText("fake-render");
    return artifact;
}

fn fakeLoadRenderArtifact(ptr: *anyopaque, artifact: *const RenderArtifact) BackendError!LoadedRenderArtifact {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    defer state.next_id += 1;
    state.render_load_count += 1;
    var loaded = LoadedRenderArtifact.describing(artifact, state.next_id);
    loaded.backend = state.loaded_render_backend;
    return loaded;
}

fn fakeRender(ptr: *anyopaque, request: RenderRequest) BackendError!void {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.render_count += 1;
    state.last_render_draw_count = request.pass.draws.len;
    const first = request.pass.draws[0].range;
    state.last_render_vertex_count = first.vertex_count;
    state.last_render_instance_count = first.instance_count;
}

fn fakeCreateRenderBindings(ptr: *anyopaque, request: RenderBindingsRequest) BackendError!RenderBindings {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    defer state.next_id += 1;
    state.render_bindings_count += 1;
    return .{ .id = state.next_id, .backend = .cuda, .pipeline = request.pipeline.id };
}

fn fakeRecordRenderBundle(ptr: *anyopaque, pass: RenderPass) BackendError!RenderBundle {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    defer state.next_id += 1;
    state.bundle_record_count += 1;
    return .{ .id = state.next_id, .backend = .cuda, .draw_count = @intCast(pass.draws.len) };
}

fn fakeSubmitRenderBundle(ptr: *anyopaque, _: RenderBundleSubmit) BackendError!void {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.bundle_submit_count += 1;
}

fn fakeWriteTexture(ptr: *anyopaque, _: TextureWriteRequest) BackendError!void {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.texture_write_count += 1;
}

fn fakeReadTexture(ptr: *anyopaque, _: TextureReadRequest) BackendError!void {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.texture_read_count += 1;
}

fn fakeCreateStream(ptr: *anyopaque, _: StreamAllocation) BackendError!StreamHandle {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    defer state.next_id += 1;
    state.created_stream = true;
    return .{
        .id = state.next_id,
        .backend = .cuda,
    };
}

fn fakeCreateEvent(ptr: *anyopaque, _: EventAllocation) BackendError!EventHandle {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    defer state.next_id += 1;
    state.created_event = true;
    return .{
        .id = state.next_id,
        .backend = .cuda,
    };
}

fn fakeQueryEvent(ptr: *anyopaque, request: EventQueryRequest) BackendError!bool {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.queried_event = request.event.id;
    return state.event_ready;
}

fn fakeRecordEvent(ptr: *anyopaque, request: EventRecordRequest) BackendError!void {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.recorded_event = request.event.id;
    state.record_stream = request.stream.id;
}

fn fakeElapsedEventNs(ptr: *anyopaque, request: EventElapsedRequest) BackendError!u64 {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.elapsed_start_event = request.start.id;
    state.elapsed_end_event = request.end.id;
    return state.elapsed_ns;
}

fn fakeSynchronize(ptr: *anyopaque, request: SyncRequest) BackendError!void {
    const state: *FakeBackendState = @ptrCast(@alignCast(ptr));
    state.sync_count += 1;
    state.last_sync_request = request;
}

const fake_vtable = BackendVTable{
    .query_capabilities = fakeQueryCapabilities,
    .launch = fakeLaunch,
    .allocate_buffer = fakeAllocateBuffer,
    .allocate_texture = fakeAllocateTexture,
    .create_surface = fakeCreateSurface,
    .destroy_surface = fakeDestroySurface,
    .destroy_texture = fakeDestroyTexture,
    .acquire_surface_frame = fakeAcquireSurfaceFrame,
    .present_surface_frame = fakePresentSurfaceFrame,
    .write_surface_frame = fakeWriteSurfaceFrame,
    .read_surface_frame = fakeReadSurfaceFrame,
    .create_render_artifact = fakeCreateRenderArtifact,
    .load_render_artifact = fakeLoadRenderArtifact,
    .render = fakeRender,
    .create_render_bindings = fakeCreateRenderBindings,
    .record_render_bundle = fakeRecordRenderBundle,
    .submit_render_bundle = fakeSubmitRenderBundle,
    .write_texture = fakeWriteTexture,
    .read_texture = fakeReadTexture,
    .create_stream = fakeCreateStream,
    .create_event = fakeCreateEvent,
    .query_event = fakeQueryEvent,
    .record_event = fakeRecordEvent,
    .elapsed_event_ns = fakeElapsedEventNs,
    .synchronize = fakeSynchronize,
};
