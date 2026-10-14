//! Devices, memory, pipelines, surfaces and presentation for compiled
//! kernels. A backend loads an artifact whose interface `gpu_abi`
//! describes, checks the artifact's requirements against the device, and
//! launches it. The package links no compiler.

const build_options = @import("build_options");

pub const bindings = @import("bindings.zig");
pub const contract = @import("contract.zig");
pub const host = @import("host.zig");
pub const push = @import("push.zig");
pub const recording = @import("recording.zig");
pub const readback = @import("readback.zig");
pub const webgpu = @import("webgpu.zig");
pub const wasm = @import("wasm.zig");

pub const cpu = if (build_options.native_backend_modules)
    @import("cpu.zig")
else
    @compileError("The gpu CPU backend is only available in native builds");

pub const cuda = if (build_options.native_backend_modules)
    @import("cuda.zig")
else
    @compileError("The gpu CUDA backend is only available in native builds");

pub const vulkan = if (build_options.native_backend_modules)
    @import("vulkan.zig")
else
    @compileError("The gpu Vulkan backend is only available in native builds");

pub const metal = if (build_options.native_backend_modules)
    @import("metal.zig")
else
    @compileError("The gpu Metal backend is only available in native builds");

pub const BackendError = contract.BackendError;
pub const BackendKind = contract.BackendKind;
pub const DeviceFamily = contract.DeviceFamily;
pub const ArtifactFormat = contract.ArtifactFormat;
pub const BackendMathTier = contract.BackendMathTier;
pub const familyForBackendKind = contract.familyForBackendKind;
pub const artifactFormatIsNativeCpu = contract.artifactFormatIsNativeCpu;
pub const artifactFormatUsesHostLoopLaunch = contract.artifactFormatUsesHostLoopLaunch;
pub const PayloadOwnership = contract.PayloadOwnership;
pub const BufferOwnership = contract.BufferOwnership;
pub const BufferAccess = contract.BufferAccess;
pub const TextureOwnership = contract.TextureOwnership;
pub const TextureFormat = contract.TextureFormat;
pub const ColorSpace = contract.ColorSpace;
pub const PresentMode = contract.PresentMode;
pub const SurfaceAlphaMode = contract.SurfaceAlphaMode;
pub const SurfacePlatformKind = contract.SurfacePlatformKind;
pub const X11Surface = contract.X11Surface;
pub const CocoaSurface = contract.CocoaSurface;
pub const WebGpuCanvasSurface = contract.WebGpuCanvasSurface;
pub const HeadlessSurface = contract.HeadlessSurface;
pub const ExternalSurface = contract.ExternalSurface;
pub const SurfacePlatform = contract.SurfacePlatform;
pub const SurfaceExtent = contract.SurfaceExtent;
pub const TextureExtent = contract.TextureExtent;
pub const TextureUsage = contract.TextureUsage;
pub const RenderArtifactFormat = contract.RenderArtifactFormat;
pub const RenderBlendMode = contract.RenderBlendMode;
pub const RenderCullMode = contract.RenderCullMode;
pub const RenderPrimitiveTopology = contract.RenderPrimitiveTopology;
pub const RenderVertexStepMode = contract.RenderVertexStepMode;
pub const RenderVertexFormat = contract.RenderVertexFormat;
pub const RenderBindingKind = contract.RenderBindingKind;
pub const RenderIndexFormat = contract.RenderIndexFormat;
pub const RenderVertexAttribute = contract.RenderVertexAttribute;
pub const RenderVertexBufferLayout = contract.RenderVertexBufferLayout;
pub const RenderBindingDesc = contract.RenderBindingDesc;
pub const RenderViewport = contract.RenderViewport;
pub const RenderScissor = contract.RenderScissor;
pub const RenderDrawRange = contract.RenderDrawRange;
pub const SyncScope = contract.SyncScope;
pub const BackendObjectId = contract.BackendObjectId;
pub const DTypeSet = contract.DTypeSet;
pub const ArtifactFormatSet = contract.ArtifactFormatSet;
pub const TextureFormatSet = contract.TextureFormatSet;
pub const PresentModeSet = contract.PresentModeSet;
pub const ColorSpaceSet = contract.ColorSpaceSet;
pub const SurfacePlatformSet = contract.SurfacePlatformSet;
pub const RenderArtifactFormatSet = contract.RenderArtifactFormatSet;
pub const RenderBlendModeSet = contract.RenderBlendModeSet;
pub const RenderPrimitiveTopologySet = contract.RenderPrimitiveTopologySet;
pub const RenderVertexFormatSet = contract.RenderVertexFormatSet;
pub const RenderBindingKindSet = contract.RenderBindingKindSet;
pub const RenderIndexFormatSet = contract.RenderIndexFormatSet;
pub const DeviceIdentity = contract.DeviceIdentity;
pub const MemoryLimits = contract.MemoryLimits;
pub const SubgroupFacts = contract.SubgroupFacts;
pub const FloatControlWidths = contract.FloatControlWidths;
pub const FloatControlIndependence = contract.FloatControlIndependence;
pub const FloatArithmeticProfile = contract.FloatArithmeticProfile;
pub const FloatControlFacts = contract.FloatControlFacts;
pub const ThreadgroupFacts = contract.ThreadgroupFacts;
pub const LayoutFeatures = contract.LayoutFeatures;
pub const RuntimeRequirements = contract.RuntimeRequirements;
pub const TextureCapabilities = contract.TextureCapabilities;
pub const SurfaceCapabilities = contract.SurfaceCapabilities;
pub const RasterCapabilities = contract.RasterCapabilities;
pub const BackendCapabilities = contract.BackendCapabilities;
pub const ArtifactPayload = contract.ArtifactPayload;
pub const ExternalPayload = contract.ExternalPayload;
pub const KernelArtifactDesc = contract.KernelArtifactDesc;
pub const KernelArtifact = contract.KernelArtifact;
pub const LoadedArtifact = contract.LoadedArtifact;
pub const RenderPipelineDesc = contract.RenderPipelineDesc;
pub const RenderArtifactDesc = contract.RenderArtifactDesc;
pub const RenderArtifact = contract.RenderArtifact;
pub const LoadedRenderArtifact = contract.LoadedRenderArtifact;
pub const BufferHandle = contract.BufferHandle;
pub const StreamHandle = contract.StreamHandle;
pub const EventHandle = contract.EventHandle;
pub const SurfaceHandle = contract.SurfaceHandle;
pub const TextureHandle = contract.TextureHandle;
pub const TextureView = contract.TextureView;
pub const SurfaceFrame = contract.SurfaceFrame;
pub const BufferAllocation = contract.BufferAllocation;
pub const BufferMemory = contract.BufferMemory;
pub const BufferImport = contract.BufferImport;
pub const TextureAllocation = contract.TextureAllocation;
pub const SurfaceCreationRequest = contract.SurfaceCreationRequest;
pub const SurfaceFrameAcquireRequest = contract.SurfaceFrameAcquireRequest;
pub const PresentRequest = contract.PresentRequest;
pub const SurfaceClearColor = contract.SurfaceClearColor;
pub const SurfaceFrameWriteOp = contract.SurfaceFrameWriteOp;
pub const SurfaceFrameWriteRequest = contract.SurfaceFrameWriteRequest;
pub const SurfaceFrameReadRequest = contract.SurfaceFrameReadRequest;
pub const StreamAllocation = contract.StreamAllocation;
pub const EventAllocation = contract.EventAllocation;
pub const BufferBinding = contract.BufferBinding;
pub const BufferWriteRequest = contract.BufferWriteRequest;
pub const BufferFillRequest = contract.BufferFillRequest;
pub const BufferReadRequest = contract.BufferReadRequest;
pub const LaunchRequest = contract.LaunchRequest;
pub const RenderRequest = contract.RenderRequest;
pub const RenderBundleSubmit = contract.RenderBundleSubmit;
pub const TextureWriteRequest = contract.TextureWriteRequest;
pub const TextureReadRequest = contract.TextureReadRequest;
pub const RenderCompare = contract.RenderCompare;
pub const RenderDepthState = contract.RenderDepthState;
pub const RenderDepthBias = contract.RenderDepthBias;
pub const RenderFilter = contract.RenderFilter;
pub const RenderAddressMode = contract.RenderAddressMode;
pub const RenderMipFilter = contract.RenderMipFilter;
pub const RenderSampler = contract.RenderSampler;
pub const RenderSampledTexture = contract.RenderSampledTexture;
pub const RenderResource = contract.RenderResource;
pub const RenderBindingsRequest = contract.RenderBindingsRequest;
pub const RenderBindings = contract.RenderBindings;
pub const RenderColorLoad = contract.RenderColorLoad;
pub const RenderDepthLoad = contract.RenderDepthLoad;
pub const RenderColorAttachment = contract.RenderColorAttachment;
pub const RenderDepthAttachment = contract.RenderDepthAttachment;
pub const RenderBufferRange = contract.RenderBufferRange;
pub const RenderDraw = contract.RenderDraw;
pub const RenderPass = contract.RenderPass;
pub const RenderBundle = contract.RenderBundle;
pub const CompileRequest = contract.CompileRequest;
pub const CompilePayload = contract.CompilePayload;
pub const SyncRequest = contract.SyncRequest;
pub const EventQueryRequest = contract.EventQueryRequest;
pub const EventRecordRequest = contract.EventRecordRequest;
pub const EventElapsedRequest = contract.EventElapsedRequest;
pub const BackendVTable = contract.BackendVTable;
pub const BackendHandle = contract.BackendHandle;
pub const readPushExtent = push.readPushExtent;
pub const readBindings = bindings.readBindings;
