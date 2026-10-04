const std = @import("std");
const gpu_abi = @import("gpu_abi");

const backend = @import("root.zig");

const RecordedSurface = struct {
    id: ?backend.BackendObjectId = null,
    platform: backend.SurfacePlatformKind = .headless,
    extent: backend.SurfaceExtent = .{},
    format: backend.TextureFormat = .rgba8_unorm,
    color_space: backend.ColorSpace = .srgb,
    present_mode: backend.PresentMode = .fifo,
    generation: u64 = 1,
    acquired_frame: ?backend.BackendObjectId = null,
    acquired_texture: ?backend.BackendObjectId = null,
    destroyed: bool = false,
};

const RecordedTexture = struct {
    id: ?backend.BackendObjectId = null,
    extent: backend.TextureExtent = .{},
    format: backend.TextureFormat = .rgba8_unorm,
    usage: backend.TextureUsage = .{},
    sample_count: u32 = 1,
    ownership: backend.TextureOwnership = .backend,
    destroyed: bool = false,
};

const RecordedFrame = struct {
    id: ?backend.BackendObjectId = null,
    surface_id: backend.BackendObjectId = 0,
    texture_id: backend.BackendObjectId = 0,
    generation: u64 = 1,
    written: bool = false,
    presented: bool = false,
};

const RecordedRenderArtifact = struct {
    id: ?backend.BackendObjectId = null,
    format: backend.RenderArtifactFormat = .external,
    target_format: backend.TextureFormat = .rgba8_unorm,
    blend_mode: backend.RenderBlendMode = .replace,
    topology: backend.RenderPrimitiveTopology = .triangle_list,
    destroyed: bool = false,
};

pub const BackendState = struct {
    allocator: std.mem.Allocator,
    kind: backend.BackendKind = .cuda,
    format: backend.ArtifactFormat = .cuda_ptx,
    next_id: backend.BackendObjectId = 1,
    create_count: usize = 0,
    last_create_had_payload: bool = false,
    last_create_argument_count: u32 = 0,
    last_create_required_dtype_bits: u64 = 0,
    load_count: usize = 0,
    fail_load_after_count: ?usize = null,
    fail_launch_after_count: ?usize = null,
    fail_record: bool = false,
    fail_sync: bool = false,
    fail_read: bool = false,
    launch_count: usize = 0,
    destroy_count: usize = 0,
    destroyed_ids: [64]backend.BackendObjectId = @splat(0),
    last_loaded_id: ?backend.BackendObjectId = null,
    last_destroyed_id: ?backend.BackendObjectId = null,
    last_launch_loaded_id: ?backend.BackendObjectId = null,
    last_launch_buffer_count: usize = 0,
    last_launch_scalar_count: usize = 0,
    last_launch_scalar_u32: ?u32 = null,
    last_launch_scalar_u32_values: [16]u32 = @splat(0),
    last_launch_scalar_f32_values: [16]f32 = @splat(0),
    last_launch_grid: [3]u32 = .{ 0, 0, 0 },
    last_launch_threadgroup: [3]u32 = .{ 0, 0, 0 },
    last_launch_dynamic_shared_memory_bytes: u32 = 0,
    last_buffer_ids: [8]backend.BackendObjectId = @splat(0),
    last_buffer_access: [8]backend.BufferAccess = @splat(.read_only),
    last_launch_stream: ?backend.BackendObjectId = null,
    last_launch_wait_count: usize = 0,
    last_launch_wait_events: [8]backend.BackendObjectId = @splat(0),
    last_launch_signal_event: ?backend.BackendObjectId = null,
    buffer_allocate_count: usize = 0,
    fail_buffer_allocate_after_count: ?usize = null,
    allocated_buffer_ids: [64]backend.BackendObjectId = @splat(0),
    allocated_buffer_byte_sizes: [64]usize = @splat(0),
    last_buffer_allocation_byte_size: usize = 0,
    last_buffer_allocation_alignment: u32 = 0,
    last_buffer_allocation_element_count: ?u64 = null,
    write_count: usize = 0,
    last_write_buffer_id: ?backend.BackendObjectId = null,
    last_write_byte_count: usize = 0,
    last_write_u32: ?u32 = null,
    launch_streams: [8]?backend.BackendObjectId = @splat(null),
    launch_grids: [8][3]u32 = @splat(.{ 0, 0, 0 }),
    launch_scalar_u32s: [8]?u32 = @splat(null),
    launch_wait_counts: [8]usize = @splat(0),
    launch_wait_events: [8][4]backend.BackendObjectId = @splat(@splat(0)),
    launch_signal_events: [8]?backend.BackendObjectId = @splat(null),
    launch_buffer_counts: [8]usize = @splat(0),
    launch_buffer_ids: [8][8]backend.BackendObjectId = @splat(@splat(0)),
    launch_buffer_access: [8][8]backend.BufferAccess = @splat(@splat(.read_only)),
    created_stream_count: usize = 0,
    created_streams: [8]backend.BackendObjectId = @splat(0),
    created_event_count: usize = 0,
    created_events: [8]backend.BackendObjectId = @splat(0),
    ready_event_count: usize = 0,
    ready_events: [16]backend.BackendObjectId = @splat(0),
    last_event_query_id: ?backend.BackendObjectId = null,
    record_event_count: usize = 0,
    record_streams: [8]?backend.BackendObjectId = @splat(null),
    record_events: [8]?backend.BackendObjectId = @splat(null),
    elapsed_event_count: usize = 0,
    elapsed_start_events: [8]?backend.BackendObjectId = @splat(null),
    elapsed_end_events: [8]?backend.BackendObjectId = @splat(null),
    event_elapsed_ns: u64 = 0,
    sync_count: usize = 0,
    last_sync_scope: ?backend.SyncScope = null,
    last_sync_stream: ?backend.BackendObjectId = null,
    last_sync_event: ?backend.BackendObjectId = null,
    read_count: usize = 0,
    last_read_buffer_id: ?backend.BackendObjectId = null,
    last_read_byte_count: usize = 0,
    surface_create_count: usize = 0,
    texture_allocate_count: usize = 0,
    surface_destroy_count: usize = 0,
    texture_destroy_count: usize = 0,
    surface_acquire_count: usize = 0,
    surface_present_count: usize = 0,
    surface_write_count: usize = 0,
    render_create_count: usize = 0,
    render_load_count: usize = 0,
    render_count: usize = 0,
    render_bindings_count: usize = 0,
    bundle_record_count: usize = 0,
    bundle_submit_count: usize = 0,
    texture_write_count: usize = 0,
    surfaces: [16]RecordedSurface = @as([16]RecordedSurface, @splat(.{})),
    textures: [32]RecordedTexture = @as([32]RecordedTexture, @splat(.{})),
    frames: [16]RecordedFrame = @as([16]RecordedFrame, @splat(.{})),
    render_artifacts: [16]RecordedRenderArtifact = @as([16]RecordedRenderArtifact, @splat(.{})),
    last_surface_id: ?backend.BackendObjectId = null,
    last_texture_id: ?backend.BackendObjectId = null,
    last_surface_frame_id: ?backend.BackendObjectId = null,
    last_presented_frame_id: ?backend.BackendObjectId = null,
    last_present_wait_count: usize = 0,
    last_present_wait_events: [8]backend.BackendObjectId = @splat(0),
    last_written_frame_id: ?backend.BackendObjectId = null,
    last_surface_write_op_count: usize = 0,
    last_surface_write_copy_buffer_id: ?backend.BackendObjectId = null,
    last_surface_write_wait_count: usize = 0,
    last_surface_write_wait_events: [8]backend.BackendObjectId = @splat(0),
    last_surface_write_signal_event: ?backend.BackendObjectId = null,
    last_render_artifact_id: ?backend.BackendObjectId = null,
    last_loaded_render_artifact_id: ?backend.BackendObjectId = null,
    last_render_loaded_artifact_id: ?backend.BackendObjectId = null,
    last_render_target_texture_id: ?backend.BackendObjectId = null,
    last_render_draw_count: usize = 0,
    last_render_vertex_buffer_count: usize = 0,
    last_render_indexed: bool = false,
    last_render_vertex_count: u32 = 0,
    last_render_index_count: u32 = 0,
    last_render_instance_count: u32 = 0,
    last_render_viewport: backend.RenderViewport = .{ .width = 1, .height = 1 },
    last_render_scissor: backend.RenderScissor = .{ .width = 1, .height = 1 },
    last_surface_platform: ?backend.SurfacePlatformKind = null,
    last_surface_format: ?backend.TextureFormat = null,
    last_texture_format: ?backend.TextureFormat = null,
    last_render_format: ?backend.RenderArtifactFormat = null,

    pub fn handle(self: *BackendState) backend.BackendHandle {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .kind = self.kind,
        };
    }
};

fn queryCapabilities(ptr: *anyopaque) backend.BackendError!backend.BackendCapabilities {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    const family: backend.DeviceFamily = switch (state.kind) {
        .cuda => .nvidia_cuda,
        .vulkan => .vulkan,
        .metal => .apple_metal,
        .webgpu => .webgpu,
        .wasm => .webassembly,
        else => .external,
    };
    return .{
        .identity = .{
            .backend = state.kind,
            .family = family,
            .name = "recording",
        },
        .subgroup = switch (state.kind) {
            .cuda => .{
                .supported = true,
                .size_min = 32,
                .size_max = 32,
                .shuffle = true,
                .ballot = true,
                .vote = true,
                .arithmetic = true,
                .scan = true,
            },
            .metal, .vulkan => .{
                .supported = true,
                .size_min = 32,
                .size_max = 32,
                .shuffle = true,
                .ballot = true,
                .vote = true,
                .arithmetic = true,
                .scan = true,
            },
            else => .{},
        },
        .threadgroup = .{
            .max_threads = 1024,
            .max_blocks = .{ 65_535, 65_535, 65_535 },
            .max_threads_per_dim = .{ 1024, 1024, 64 },
            .max_grid_per_dim = .{ 65_535, 65_535, 65_535 },
            .shared_memory_bytes = 48 * 1024,
        },
        .dtypes = dtypes(state.kind),
        .features = .{
            .atomic_i32 = state.kind != .webgpu and state.kind != .wasm,
            .atomic_u32 = state.kind != .webgpu and state.kind != .wasm,
            .atomic_index = state.kind != .webgpu and state.kind != .wasm,
            .atomic_f32_add_device = state.kind == .cuda or state.kind == .metal,
            .atomic_f32_add_shared = state.kind == .cuda,
            .async_copy = state.kind == .metal,
            .tensor_cores = state.kind == .cuda,
            .dynamic_shared_memory = state.kind == .cuda,
        },
        .runtime = .{
            .driver_loaded = true,
            .device_context = true,
            .streams = true,
            .events = true,
        },
        .textures = switch (state.kind) {
            .vulkan, .metal, .webgpu => .{
                .supported = true,
                .formats = backend.TextureFormatSet.init(&.{ .rgba8_unorm, .bgra8_unorm, .depth32_float }),
                .usages = .{
                    .copy_src = true,
                    .copy_dst = true,
                    .sampled = true,
                    .storage = true,
                    .color_attachment = true,
                    .depth_attachment = true,
                    .present = true,
                },
                .max_extent = .{ .width = 16_384, .height = 16_384, .depth = 256 },
                .max_sample_count = 4,
            },
            else => .{},
        },
        .surfaces = switch (state.kind) {
            .vulkan => .{
                .supported = true,
                .platforms = backend.SurfacePlatformSet.init(&.{ .x11, .headless }),
                .formats = backend.TextureFormatSet.init(&.{ .rgba8_unorm, .bgra8_unorm }),
                .color_spaces = backend.ColorSpaceSet.init(&.{ .srgb, .linear }),
                .present_modes = backend.PresentModeSet.init(&.{ .fifo, .mailbox, .immediate }),
                .usages = .{ .copy_dst = true, .storage = true, .color_attachment = true, .present = true },
                .max_extent = .{ .width = 16_384, .height = 16_384 },
                .max_frames_in_flight = 3,
            },
            .metal => .{
                .supported = true,
                .platforms = backend.SurfacePlatformSet.init(&.{ .cocoa, .headless }),
                .formats = backend.TextureFormatSet.init(&.{ .rgba8_unorm, .bgra8_unorm }),
                .color_spaces = backend.ColorSpaceSet.init(&.{ .srgb, .linear }),
                .present_modes = backend.PresentModeSet.init(&.{ .fifo, .mailbox }),
                .usages = .{ .copy_dst = true, .color_attachment = true, .present = true },
                .max_extent = .{ .width = 16_384, .height = 16_384 },
                .max_frames_in_flight = 3,
            },
            .webgpu => .{
                .supported = true,
                .platforms = backend.SurfacePlatformSet.init(&.{ .webgpu_canvas, .headless }),
                .formats = backend.TextureFormatSet.init(&.{ .rgba8_unorm, .bgra8_unorm }),
                .color_spaces = backend.ColorSpaceSet.init(&.{.srgb}),
                .present_modes = backend.PresentModeSet.init(&.{.fifo}),
                .usages = .{ .copy_dst = true, .storage = true, .color_attachment = true, .present = true },
                .max_extent = .{ .width = 16_384, .height = 16_384 },
                .max_frames_in_flight = 2,
            },
            else => .{},
        },
        .raster = switch (state.kind) {
            .vulkan, .metal, .webgpu => .{
                .supported = true,
                .artifact_formats = backend.RenderArtifactFormatSet.init(&.{renderFormatForKind(state.kind)}),
                .target_formats = backend.TextureFormatSet.init(&.{ .rgba8_unorm, .bgra8_unorm }),
                .depth_formats = backend.TextureFormatSet.init(&.{.depth32_float}),
                .blend_modes = backend.RenderBlendModeSet.init(&.{ .replace, .alpha_premultiplied, .alpha_straight, .additive }),
                .topologies = backend.RenderPrimitiveTopologySet.init(&.{ .triangle_list, .triangle_strip, .line_list, .line_strip }),
                .vertex_formats = backend.RenderVertexFormatSet.init(&.{ .float32, .float32x2, .float32x3, .float32x4, .uint32, .uint32x2, .uint32x4 }),
                .binding_kinds = backend.RenderBindingKindSet.init(&.{ .uniform_buffer, .storage_buffer, .sampled_texture, .storage_texture }),
                .index_formats = backend.RenderIndexFormatSet.init(&.{ .none, .u16, .u32 }),
                .max_vertex_buffers = 16,
                .max_vertex_attributes = 32,
                .max_bindings = 32,
                .instancing = true,
            },
            else => .{},
        },
        .artifact_formats = backend.ArtifactFormatSet.init(&.{state.format}),
    };
}

fn dtypes(kind: backend.BackendKind) backend.DTypeSet {
    return switch (kind) {
        .cuda => backend.DTypeSet.init(&.{
            .i1,  .i8,   .i16, .i32, .i64, .u8, .u16, .u32, .u64,
            .f16, .bf16, .f32, .f64, .key,
        }),
        .webgpu => backend.DTypeSet.init(&.{ .i1, .f32, .i32, .u32 }),
        .wasm => backend.DTypeSet.init(&.{ .i1, .f32, .f64, .i32, .u32, .i64, .u64 }),
        else => backend.DTypeSet.init(&.{ .i1, .f32, .f16, .i32, .u32, .u64, .key }),
    };
}

fn renderFormatForKind(kind: backend.BackendKind) backend.RenderArtifactFormat {
    return switch (kind) {
        .vulkan => .vulkan_spirv,
        .metal => .metal_msl,
        .webgpu => .webgpu_wgsl,
        else => .external,
    };
}

fn createArtifact(
    ptr: *anyopaque,
    request: backend.CompileRequest,
) backend.BackendError!backend.KernelArtifact {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    if (request.requested_format != state.format) return error.UnsupportedArtifactFormat;
    state.create_count += 1;
    state.last_create_had_payload = switch (request.payload) {
        .none => false,
        else => true,
    };
    state.last_create_argument_count = request.argument_count;
    state.last_create_required_dtype_bits = request.required_dtypes.bits;
    var artifact = backend.KernelArtifact.init(state.allocator, .{
        .backend = state.kind,
        .format = state.format,
        .entry_name = request.kernel_name,
        .argument_count = request.argument_count,
        .scalar_argument_count = request.scalar_argument_count,
        .diagnostic_id = request.diagnostic_id,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    switch (state.format) {
        .cuda_ptx, .metal_msl, .webgpu_wgsl => artifact.setBorrowedText("recording"),
        .vulkan_spirv => artifact.setBorrowedWords(&spirv),
        .webassembly_module => artifact.setBorrowedBytes(&.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 }),
        else => return error.UnsupportedArtifactFormat,
    }
    return artifact;
}

const spirv = [_]u32{ 0x07230203, 0x00010000, 0, 0 };

fn loadArtifact(
    ptr: *anyopaque,
    artifact: *const backend.KernelArtifact,
) backend.BackendError!backend.LoadedArtifact {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    if (artifact.backend != state.kind or artifact.format != state.format) return error.InvalidArtifact;
    if (state.fail_load_after_count) |limit| {
        if (state.load_count >= limit) return error.RuntimeUnavailable;
    }
    const id = state.next_id;
    state.next_id += 1;
    state.load_count += 1;
    state.last_loaded_id = id;
    return .{
        .id = id,
        .backend = state.kind,
        .format = state.format,
    };
}

fn createRenderArtifact(
    ptr: *anyopaque,
    desc: backend.RenderPipelineDesc,
) backend.BackendError!backend.RenderArtifact {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    if (desc.format != renderFormatForKind(state.kind)) return error.UnsupportedArtifactFormat;
    const slot = freeRenderArtifactSlot(state) orelse return error.OutOfMemory;
    const id = state.next_id;
    state.next_id += 1;
    slot.* = .{
        .id = id,
        .format = desc.format,
        .target_format = desc.target_format,
        .blend_mode = desc.blend_mode,
        .topology = desc.topology,
    };
    state.render_create_count += 1;
    state.last_render_artifact_id = id;
    state.last_render_format = desc.format;
    var artifact = backend.RenderArtifact.init(state.allocator, .{
        .backend = state.kind,
        .pipeline = desc,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    switch (desc.format) {
        .vulkan_spirv => artifact.setBorrowedWords(&spirv),
        .metal_msl, .webgpu_wgsl => artifact.setBorrowedText("recording-render"),
        .metal_metallib => artifact.setBorrowedBytes(&.{ 0xca, 0xfe, 0xba, 0xbe }),
        .external => artifact.setBorrowedText("recording-render-external"),
        .cpu_object => artifact.setBorrowedBytes(&.{ 0x7f, 'E', 'L', 'F' }),
    }
    return artifact;
}

fn loadRenderArtifact(
    ptr: *anyopaque,
    artifact: *const backend.RenderArtifact,
) backend.BackendError!backend.LoadedRenderArtifact {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    if (artifact.backend != state.kind or artifact.format != renderFormatForKind(state.kind)) return error.InvalidRenderArtifact;
    const id = state.next_id;
    state.next_id += 1;
    state.render_load_count += 1;
    state.last_loaded_render_artifact_id = id;
    state.last_render_format = artifact.format;
    return backend.LoadedRenderArtifact.describing(artifact, id);
}

/// Records the pass's last draw. The recording backend holds no texels, so it draws nothing and
/// refuses texture reads.
fn render(
    ptr: *anyopaque,
    request: backend.RenderRequest,
) backend.BackendError!void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    try recordPass(state, request.pass);
    if (request.signal_event) |event| try markEventReady(state, event);
}

fn recordPass(state: *BackendState, pass: backend.RenderPass) backend.BackendError!void {
    _ = try recordedTexture(state, pass.color.view.texture.id);
    if (pass.depth) |depth| _ = try recordedTexture(state, depth.view.texture.id);
    state.render_count += 1;
    state.last_render_draw_count = pass.draws.len;
    state.last_render_target_texture_id = pass.color.view.texture.id;
    state.last_render_viewport = pass.viewport;
    state.last_render_scissor = pass.scissor;
    for (pass.draws) |draw| {
        if (draw.pipeline.backend != state.kind) return error.InvalidRenderArtifact;
        state.last_render_loaded_artifact_id = draw.pipeline.id;
        state.last_render_vertex_buffer_count = draw.vertex_buffers.len;
        state.last_render_indexed = draw.range.index_count != 0;
        state.last_render_vertex_count = draw.range.vertex_count;
        state.last_render_index_count = draw.range.index_count;
        state.last_render_instance_count = draw.range.instance_count;
        state.last_render_format = draw.pipeline.format;
    }
}

fn createRenderBindings(
    ptr: *anyopaque,
    request: backend.RenderBindingsRequest,
) backend.BackendError!backend.RenderBindings {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    const id = state.next_id;
    state.next_id += 1;
    state.render_bindings_count += 1;
    return .{ .id = id, .backend = state.kind, .pipeline = request.pipeline.id };
}

fn recordRenderBundle(
    ptr: *anyopaque,
    pass: backend.RenderPass,
) backend.BackendError!backend.RenderBundle {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    const id = state.next_id;
    state.next_id += 1;
    state.bundle_record_count += 1;
    return .{ .id = id, .backend = state.kind, .draw_count = @intCast(pass.draws.len) };
}

fn submitRenderBundle(
    ptr: *anyopaque,
    request: backend.RenderBundleSubmit,
) backend.BackendError!void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    state.bundle_submit_count += 1;
    if (request.signal_event) |event| try markEventReady(state, event);
}

fn writeTexture(
    ptr: *anyopaque,
    request: backend.TextureWriteRequest,
) backend.BackendError!void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    _ = try recordedTexture(state, request.texture.id);
    state.texture_write_count += 1;
}

fn allocateBuffer(
    ptr: *anyopaque,
    request: backend.BufferAllocation,
) backend.BackendError!backend.BufferHandle {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    if (state.fail_buffer_allocate_after_count) |limit| {
        if (state.buffer_allocate_count >= limit) return error.OutOfMemory;
    }
    const id = state.next_id;
    state.next_id += 1;
    if (state.buffer_allocate_count >= state.allocated_buffer_ids.len) return error.OutOfMemory;
    state.allocated_buffer_ids[state.buffer_allocate_count] = id;
    state.allocated_buffer_byte_sizes[state.buffer_allocate_count] = request.byte_size;
    state.buffer_allocate_count += 1;
    state.last_buffer_allocation_byte_size = request.byte_size;
    state.last_buffer_allocation_alignment = request.alignment;
    state.last_buffer_allocation_element_count = request.element_count;
    return .{
        .id = id,
        .backend = state.kind,
        .byte_size = request.byte_size,
        .ownership = .backend,
    };
}

fn createSurface(
    ptr: *anyopaque,
    request: backend.SurfaceCreationRequest,
) backend.BackendError!backend.SurfaceHandle {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    const slot = freeSurfaceSlot(state) orelse return error.OutOfMemory;
    const id = state.next_id;
    state.next_id += 1;
    slot.* = .{
        .id = id,
        .platform = request.platform.kind(),
        .extent = request.extent,
        .format = request.format,
        .color_space = request.color_space,
        .present_mode = request.present_mode,
        .generation = 1,
    };
    state.surface_create_count += 1;
    state.last_surface_id = id;
    state.last_surface_platform = request.platform.kind();
    state.last_surface_format = request.format;
    return .{
        .id = id,
        .backend = state.kind,
        .platform = request.platform.kind(),
        .extent = request.extent,
        .format = request.format,
        .color_space = request.color_space,
        .present_mode = request.present_mode,
        .generation = 1,
    };
}

fn destroySurface(
    ptr: *anyopaque,
    handle: backend.SurfaceHandle,
) backend.BackendError!void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    const surface = try recordedSurface(state, handle.id);
    if (surface.generation != handle.generation) return error.SurfaceFrameExpired;
    if (surface.acquired_frame != null) return error.SurfaceAlreadyAcquired;
    surface.destroyed = true;
    state.surface_destroy_count += 1;
    state.last_destroyed_id = handle.id;
}

fn allocateTexture(
    ptr: *anyopaque,
    request: backend.TextureAllocation,
) backend.BackendError!backend.TextureHandle {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    const slot = freeTextureSlot(state) orelse return error.OutOfMemory;
    const id = state.next_id;
    state.next_id += 1;
    slot.* = .{
        .id = id,
        .extent = request.extent,
        .format = request.format,
        .usage = request.usage,
        .sample_count = request.sample_count,
        .ownership = .backend,
    };
    state.texture_allocate_count += 1;
    state.last_texture_id = id;
    state.last_texture_format = request.format;
    return .{
        .id = id,
        .backend = state.kind,
        .extent = request.extent,
        .format = request.format,
        .usage = request.usage,
        .sample_count = request.sample_count,
        .ownership = .backend,
    };
}

fn destroyTexture(
    ptr: *anyopaque,
    handle: backend.TextureHandle,
) backend.BackendError!void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    const texture = try recordedTexture(state, handle.id);
    for (state.surfaces) |surface| {
        if (surface.id != null and !surface.destroyed and surface.acquired_texture == handle.id) return error.SurfaceAlreadyAcquired;
    }
    texture.destroyed = true;
    state.texture_destroy_count += 1;
    state.last_destroyed_id = handle.id;
}

fn acquireSurfaceFrame(
    ptr: *anyopaque,
    request: backend.SurfaceFrameAcquireRequest,
) backend.BackendError!backend.SurfaceFrame {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    const surface = try recordedSurface(state, request.surface.id);
    if (surface.generation != request.surface.generation) return error.SurfaceFrameExpired;
    if (surface.acquired_frame != null) return error.SurfaceAlreadyAcquired;
    const texture_slot = freeTextureSlot(state) orelse return error.OutOfMemory;
    const frame_slot = freeFrameSlot(state) orelse return error.OutOfMemory;
    const texture_id = state.next_id;
    state.next_id += 1;
    const frame_id = state.next_id;
    state.next_id += 1;
    const texture = backend.TextureHandle{
        .id = texture_id,
        .backend = state.kind,
        .extent = .{
            .width = surface.extent.width,
            .height = surface.extent.height,
            .depth = 1,
        },
        .format = surface.format,
        .usage = .{ .copy_dst = true, .storage = true, .color_attachment = true, .present = true },
        .sample_count = 1,
        .ownership = .acquired_surface,
    };
    texture_slot.* = .{
        .id = texture_id,
        .extent = texture.extent,
        .format = texture.format,
        .usage = texture.usage,
        .sample_count = texture.sample_count,
        .ownership = texture.ownership,
    };
    frame_slot.* = .{
        .id = frame_id,
        .surface_id = request.surface.id,
        .texture_id = texture_id,
        .generation = surface.generation,
    };
    surface.acquired_frame = frame_id;
    surface.acquired_texture = texture_id;
    state.surface_acquire_count += 1;
    state.last_surface_frame_id = frame_id;
    state.last_texture_id = texture_id;
    const surface_handle = backend.SurfaceHandle{
        .id = request.surface.id,
        .backend = state.kind,
        .platform = surface.platform,
        .extent = surface.extent,
        .format = surface.format,
        .color_space = surface.color_space,
        .present_mode = surface.present_mode,
        .generation = surface.generation,
    };
    const view = backend.TextureView{
        .texture = texture,
        .format = texture.format,
    };
    return .{
        .id = frame_id,
        .backend = state.kind,
        .surface = surface_handle,
        .texture = texture,
        .view = view,
        .index = @intCast(state.surface_acquire_count - 1),
        .generation = surface.generation,
        .token = frame_id,
    };
}

fn presentSurfaceFrame(
    ptr: *anyopaque,
    request: backend.PresentRequest,
) backend.BackendError!void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    if (request.signal_event != null) return error.UnsupportedOperation;
    const surface = try recordedSurface(state, request.surface.id);
    const frame = try recordedFrame(state, request.frame.id);
    if (surface.generation != request.surface.generation) return error.SurfaceFrameExpired;
    if (surface.generation != frame.generation or request.frame.generation != frame.generation) return error.SurfaceFrameExpired;
    if (frame.presented) return error.SurfaceFrameExpired;
    if (frame.surface_id != surface.id.?) return error.InvalidSurfaceFrame;
    if (surface.acquired_frame == null or surface.acquired_frame.? != request.frame.id) return error.InvalidSurfaceFrame;
    _ = try recordedTexture(state, frame.texture_id);
    if (request.wait_events.len > state.last_present_wait_events.len) return error.LaunchArgumentMismatch;
    for (request.wait_events) |event| {
        if (!eventReady(state, event)) return error.InvalidEvent;
    }
    state.last_present_wait_count = request.wait_events.len;
    for (request.wait_events, 0..) |event, index| {
        state.last_present_wait_events[index] = event.id;
    }
    frame.presented = true;
    surface.acquired_frame = null;
    surface.acquired_texture = null;
    state.surface_present_count += 1;
    state.last_presented_frame_id = request.frame.id;
}

fn writeSurfaceFrame(
    ptr: *anyopaque,
    request: backend.SurfaceFrameWriteRequest,
) backend.BackendError!void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    const surface = try recordedSurface(state, request.surface.id);
    const frame = try recordedFrame(state, request.frame.id);
    if (surface.generation != request.surface.generation) return error.SurfaceFrameExpired;
    if (surface.generation != frame.generation or request.frame.generation != frame.generation) return error.SurfaceFrameExpired;
    if (frame.presented or frame.written) return error.SurfaceFrameExpired;
    if (frame.surface_id != surface.id.?) return error.InvalidSurfaceFrame;
    if (frame.texture_id != request.frame.texture.id) return error.InvalidSurfaceFrame;
    if (surface.acquired_frame == null or surface.acquired_frame.? != request.frame.id) return error.InvalidSurfaceFrame;
    const texture = try recordedTexture(state, frame.texture_id);
    if (!texture.usage.copy_dst) return error.InvalidTexture;
    var copy_buffer_id: ?backend.BackendObjectId = null;
    for (request.operations) |op| switch (op) {
        .clear => {},
        .copy_buffer => |buffer| copy_buffer_id = buffer.id,
    };
    if (request.wait_events.len > state.last_surface_write_wait_events.len) return error.LaunchArgumentMismatch;
    state.last_surface_write_wait_count = request.wait_events.len;
    for (request.wait_events, 0..) |event, index| {
        state.last_surface_write_wait_events[index] = event.id;
    }
    state.last_surface_write_signal_event = if (request.signal_event) |event| event.id else null;
    if (request.signal_event) |event| try markEventReady(state, event);
    frame.written = true;
    state.surface_write_count += 1;
    state.last_written_frame_id = request.frame.id;
    state.last_surface_write_op_count = request.operations.len;
    state.last_surface_write_copy_buffer_id = copy_buffer_id;
}

fn freeSurfaceSlot(state: *BackendState) ?*RecordedSurface {
    for (&state.surfaces) |*slot| {
        if (slot.id == null or slot.destroyed) return slot;
    }
    return null;
}

fn freeTextureSlot(state: *BackendState) ?*RecordedTexture {
    for (&state.textures) |*slot| {
        if (slot.id == null or slot.destroyed) return slot;
    }
    return null;
}

fn freeFrameSlot(state: *BackendState) ?*RecordedFrame {
    for (&state.frames) |*slot| {
        if (slot.id == null or slot.presented) return slot;
    }
    return null;
}

fn freeRenderArtifactSlot(state: *BackendState) ?*RecordedRenderArtifact {
    for (&state.render_artifacts) |*slot| {
        if (slot.id == null or slot.destroyed) return slot;
    }
    return null;
}

fn recordedSurface(state: *BackendState, id: backend.BackendObjectId) backend.BackendError!*RecordedSurface {
    for (&state.surfaces) |*slot| {
        if (slot.id) |actual| {
            if (actual == id and !slot.destroyed) return slot;
        }
    }
    return error.InvalidSurface;
}

fn recordedTexture(state: *BackendState, id: backend.BackendObjectId) backend.BackendError!*RecordedTexture {
    for (&state.textures) |*slot| {
        if (slot.id) |actual| {
            if (actual == id and !slot.destroyed) return slot;
        }
    }
    return error.InvalidTexture;
}

fn recordedFrame(state: *BackendState, id: backend.BackendObjectId) backend.BackendError!*RecordedFrame {
    for (&state.frames) |*slot| {
        if (slot.id) |actual| {
            if (actual == id) return slot;
        }
    }
    return error.InvalidSurfaceFrame;
}

fn createStream(ptr: *anyopaque, _: backend.StreamAllocation) backend.BackendError!backend.StreamHandle {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    const id = state.next_id;
    state.next_id += 1;
    if (state.created_stream_count >= state.created_streams.len) return error.OutOfMemory;
    state.created_streams[state.created_stream_count] = id;
    state.created_stream_count += 1;
    return .{
        .id = id,
        .backend = state.kind,
    };
}

fn createEvent(ptr: *anyopaque, _: backend.EventAllocation) backend.BackendError!backend.EventHandle {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    const id = state.next_id;
    state.next_id += 1;
    if (state.created_event_count >= state.created_events.len) return error.OutOfMemory;
    state.created_events[state.created_event_count] = id;
    state.created_event_count += 1;
    return .{
        .id = id,
        .backend = state.kind,
    };
}

fn markEventReady(state: *BackendState, event: backend.EventHandle) backend.BackendError!void {
    for (state.ready_events[0..state.ready_event_count]) |ready| {
        if (ready == event.id) return;
    }
    if (state.ready_event_count >= state.ready_events.len) return error.OutOfMemory;
    state.ready_events[state.ready_event_count] = event.id;
    state.ready_event_count += 1;
}

fn eventReady(state: *const BackendState, event: backend.EventHandle) bool {
    for (state.ready_events[0..state.ready_event_count]) |ready| {
        if (ready == event.id) return true;
    }
    return false;
}

fn queryEvent(ptr: *anyopaque, request: backend.EventQueryRequest) backend.BackendError!bool {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    state.last_event_query_id = request.event.id;
    return eventReady(state, request.event);
}

fn launch(ptr: *anyopaque, request: backend.LaunchRequest) backend.BackendError!void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    const loaded = request.loaded_artifact orelse return error.InvalidArtifact;
    if (state.fail_launch_after_count) |limit| {
        if (state.launch_count >= limit) return error.RuntimeUnavailable;
    }
    const launch_index = state.launch_count;
    state.launch_count += 1;
    state.last_launch_loaded_id = loaded.id;
    state.last_launch_buffer_count = request.buffers.len;
    state.last_launch_scalar_count = request.scalar_arguments.len;
    state.last_launch_grid = request.geometry.grid;
    state.last_launch_threadgroup = request.geometry.threadgroup;
    state.last_launch_dynamic_shared_memory_bytes = request.geometry.dynamic_shared_memory_bytes;
    state.last_launch_scalar_u32 = null;
    for (request.scalar_arguments, 0..) |arg, index| {
        if (index >= state.last_launch_scalar_u32_values.len) return error.LaunchArgumentMismatch;
        state.last_launch_scalar_u32_values[index] = 0;
        state.last_launch_scalar_f32_values[index] = 0;
        switch (arg) {
            .u32 => |value| state.last_launch_scalar_u32_values[index] = value,
            .f32 => |value| state.last_launch_scalar_f32_values[index] = value,
            else => {},
        }
        if (index == 0) state.last_launch_scalar_u32 = state.last_launch_scalar_u32_values[index];
    }
    for (request.buffers, 0..) |binding, index| {
        if (index >= state.last_buffer_ids.len) return error.LaunchArgumentMismatch;
        state.last_buffer_ids[index] = binding.handle.id;
        state.last_buffer_access[index] = binding.access;
    }
    state.last_launch_stream = if (request.stream) |stream| stream.id else null;
    state.last_launch_wait_count = request.wait_events.len;
    for (request.wait_events, 0..) |event, index| {
        if (index >= state.last_launch_wait_events.len) return error.LaunchArgumentMismatch;
        state.last_launch_wait_events[index] = event.id;
    }
    state.last_launch_signal_event = if (request.signal_event) |event| event.id else null;
    if (request.signal_event) |event| try markEventReady(state, event);
    if (launch_index < state.launch_streams.len) {
        state.launch_streams[launch_index] = state.last_launch_stream;
        state.launch_grids[launch_index] = request.geometry.grid;
        state.launch_scalar_u32s[launch_index] = state.last_launch_scalar_u32;
        state.launch_wait_counts[launch_index] = request.wait_events.len;
        if (request.wait_events.len > state.launch_wait_events[launch_index].len) return error.LaunchArgumentMismatch;
        for (request.wait_events, 0..) |event, index| {
            state.launch_wait_events[launch_index][index] = event.id;
        }
        state.launch_signal_events[launch_index] = state.last_launch_signal_event;
        state.launch_buffer_counts[launch_index] = request.buffers.len;
        if (request.buffers.len > state.launch_buffer_ids[launch_index].len) return error.LaunchArgumentMismatch;
        for (request.buffers, 0..) |binding, index| {
            state.launch_buffer_ids[launch_index][index] = binding.handle.id;
            state.launch_buffer_access[launch_index][index] = binding.access;
        }
    }
}

fn writeBuffer(
    ptr: *anyopaque,
    request: backend.BufferWriteRequest,
) backend.BackendError!void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    if (request.bytes.len > request.handle.byte_size) return error.InvalidBuffer;
    state.write_count += 1;
    state.last_write_buffer_id = request.handle.id;
    state.last_write_byte_count = request.bytes.len;
    state.last_write_u32 = null;
    if (request.bytes.len == @sizeOf(u32)) {
        var value: u32 = 0;
        @memcpy(std.mem.asBytes(&value), request.bytes);
        state.last_write_u32 = value;
    }
}

fn fillBuffer(
    ptr: *anyopaque,
    request: backend.BufferFillRequest,
) backend.BackendError!void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    state.write_count += 1;
    state.last_write_buffer_id = request.handle.id;
    state.last_write_byte_count = request.handle.byte_size;
    state.last_write_u32 = request.pattern;
}

fn readBuffer(
    ptr: *anyopaque,
    request: backend.BufferReadRequest,
) backend.BackendError!void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    if (request.bytes.len < request.handle.byte_size) return error.ReadBufferDestinationTooSmall;
    state.read_count += 1;
    if (state.fail_read) return error.DeviceLost;
    state.last_read_buffer_id = request.handle.id;
    state.last_read_byte_count = request.bytes.len;
    @memset(request.bytes, 0);
}

fn recordEvent(ptr: *anyopaque, request: backend.EventRecordRequest) backend.BackendError!void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    if (state.fail_record) return error.DeviceLost;
    if (state.record_event_count >= state.record_events.len) return error.OutOfMemory;
    state.record_streams[state.record_event_count] = request.stream.id;
    state.record_events[state.record_event_count] = request.event.id;
    state.record_event_count += 1;
    try markEventReady(state, request.event);
}

fn elapsedEventNs(ptr: *anyopaque, request: backend.EventElapsedRequest) backend.BackendError!u64 {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    if (state.elapsed_event_count >= state.elapsed_start_events.len) return error.OutOfMemory;
    state.elapsed_start_events[state.elapsed_event_count] = request.start.id;
    state.elapsed_end_events[state.elapsed_event_count] = request.end.id;
    state.elapsed_event_count += 1;
    return state.event_elapsed_ns;
}

fn destroyObject(ptr: *anyopaque, id: backend.BackendObjectId) void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    if (state.destroy_count < state.destroyed_ids.len) state.destroyed_ids[state.destroy_count] = id;
    state.destroy_count += 1;
    state.last_destroyed_id = id;
}

fn synchronize(ptr: *anyopaque, request: backend.SyncRequest) backend.BackendError!void {
    const state: *BackendState = @ptrCast(@alignCast(ptr));
    state.sync_count += 1;
    if (state.fail_sync) return error.DeviceLost;
    state.last_sync_scope = request.scope;
    state.last_sync_stream = if (request.stream) |stream| stream.id else null;
    state.last_sync_event = if (request.event) |event| event.id else null;
}

const vtable = backend.BackendVTable{
    .query_capabilities = queryCapabilities,
    .create_artifact = createArtifact,
    .load_artifact = loadArtifact,
    .create_render_artifact = createRenderArtifact,
    .load_render_artifact = loadRenderArtifact,
    .allocate_buffer = allocateBuffer,
    .allocate_texture = allocateTexture,
    .create_surface = createSurface,
    .destroy_surface = destroySurface,
    .destroy_texture = destroyTexture,
    .acquire_surface_frame = acquireSurfaceFrame,
    .present_surface_frame = presentSurfaceFrame,
    .write_surface_frame = writeSurfaceFrame,
    .create_stream = createStream,
    .create_event = createEvent,
    .write_buffer = writeBuffer,
    .fill_buffer = fillBuffer,
    .read_buffer = readBuffer,
    .launch = launch,
    .render = render,
    .create_render_bindings = createRenderBindings,
    .record_render_bundle = recordRenderBundle,
    .submit_render_bundle = submitRenderBundle,
    .write_texture = writeTexture,
    .synchronize = synchronize,
    .query_event = queryEvent,
    .record_event = recordEvent,
    .elapsed_event_ns = elapsedEventNs,
    .destroy_object = destroyObject,
};

test "recording backend reports accelerator feature support by backend kind" {
    const allocator = std.testing.allocator;

    var cuda_state = BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var metal_state = BackendState{
        .allocator = allocator,
        .kind = .metal,
        .format = .metal_msl,
    };
    var vulkan_state = BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };

    try std.testing.expect((try cuda_state.handle().queryCapabilities()).features.atomic_i32);
    try std.testing.expect((try metal_state.handle().queryCapabilities()).features.atomic_i32);
    try std.testing.expect((try vulkan_state.handle().queryCapabilities()).features.atomic_i32);
    try std.testing.expect((try cuda_state.handle().queryCapabilities()).features.atomic_f32_add_device);
    try std.testing.expect((try metal_state.handle().queryCapabilities()).features.atomic_f32_add_device);
    try std.testing.expect(!(try vulkan_state.handle().queryCapabilities()).features.atomic_f32_add_device);
    try std.testing.expect((try cuda_state.handle().queryCapabilities()).features.atomic_f32_add_shared);
    try std.testing.expect(!(try metal_state.handle().queryCapabilities()).features.atomic_f32_add_shared);
    try std.testing.expect(!(try vulkan_state.handle().queryCapabilities()).features.atomic_f32_add_shared);
    try std.testing.expect(!(try cuda_state.handle().queryCapabilities()).features.async_copy);
    try std.testing.expect((try metal_state.handle().queryCapabilities()).features.async_copy);
    try std.testing.expect(!(try vulkan_state.handle().queryCapabilities()).features.async_copy);
    try std.testing.expect((try cuda_state.handle().queryCapabilities()).features.tensor_cores);
    try std.testing.expect(!(try metal_state.handle().queryCapabilities()).features.tensor_cores);
    try std.testing.expect(!(try vulkan_state.handle().queryCapabilities()).features.tensor_cores);
    try std.testing.expect((try cuda_state.handle().queryCapabilities()).features.dynamic_shared_memory);
    try std.testing.expect(!(try metal_state.handle().queryCapabilities()).features.dynamic_shared_memory);
    try std.testing.expect(!(try vulkan_state.handle().queryCapabilities()).features.dynamic_shared_memory);
}

test "recording backend records mixed launch scalar arguments" {
    const allocator = std.testing.allocator;
    var state = BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };
    const handle = state.handle();
    var artifact = try handle.createArtifact(.{
        .kernel_name = "mixed_scalars",
        .requested_format = .vulkan_spirv,
        .argument_count = 3,
        .scalar_argument_count = 2,
    });
    defer artifact.deinit();
    const loaded = try handle.loadArtifact(&artifact);
    const buffer = try handle.allocateBuffer(.{
        .byte_size = 16,
        .alignment = 4,
    });
    const bindings = [_]backend.BufferBinding{.{
        .handle = buffer,
        .access = .read_write,
        .ownership = buffer.ownership,
        .byte_size = buffer.byte_size,
    }};
    const scalars = [_]gpu_abi.ScalarArgument{
        .{ .u32 = 17 },
        .{ .f32 = 1.25 },
    };
    const signal = try handle.createEvent(.{});
    try std.testing.expect(!try handle.queryEvent(.{ .event = signal }));
    try std.testing.expectEqual(signal.id, state.last_event_query_id.?);

    try handle.launch(.{
        .artifact = &artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = scalars[0..],
        .geometry = .{
            .grid = .{ 1, 1, 1 },
            .threadgroup = .{ 1, 1, 1 },
        },
        .signal_event = signal,
    });

    try std.testing.expectEqual(@as(usize, 1), state.launch_count);
    try std.testing.expectEqual(@as(usize, 2), state.last_launch_scalar_count);
    try std.testing.expectEqual(@as(u32, 17), state.last_launch_scalar_u32_values[0]);
    try std.testing.expectEqual(@as(f32, 1.25), state.last_launch_scalar_f32_values[1]);
    try std.testing.expectEqual(signal.id, state.last_launch_signal_event.?);
    try std.testing.expect(try handle.queryEvent(.{ .event = signal }));
}

test "recording backend records elapsed event timing requests" {
    const allocator = std.testing.allocator;
    var state = BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
        .event_elapsed_ns = 123_456,
    };
    const handle = state.handle();

    const start = try handle.createEvent(.{});
    const end = try handle.createEvent(.{});

    try std.testing.expectEqual(@as(u64, 123_456), try handle.elapsedEventNs(.{
        .start = start,
        .end = end,
    }));
    try std.testing.expectEqual(@as(usize, 1), state.elapsed_event_count);
    try std.testing.expectEqual(start.id, state.elapsed_start_events[0].?);
    try std.testing.expectEqual(end.id, state.elapsed_end_events[0].?);
}

test "recording backend reports presentation capabilities by backend kind" {
    const allocator = std.testing.allocator;

    var cuda_state = BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var vulkan_state = BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };
    var metal_state = BackendState{
        .allocator = allocator,
        .kind = .metal,
        .format = .metal_msl,
    };
    var webgpu_state = BackendState{
        .allocator = allocator,
        .kind = .webgpu,
        .format = .webgpu_wgsl,
    };

    try std.testing.expect(!(try cuda_state.handle().queryCapabilities()).surfaces.supported);
    try std.testing.expect(!(try cuda_state.handle().queryCapabilities()).textures.supported);
    try std.testing.expect((try vulkan_state.handle().queryCapabilities()).surfaces.supportsPlatform(.{ .headless = .{} }));
    try std.testing.expect((try vulkan_state.handle().queryCapabilities()).surfaces.supportsPlatform(.{ .x11 = .{ .display = 1, .window = 2 } }));
    try std.testing.expect((try metal_state.handle().queryCapabilities()).surfaces.supportsPlatform(.{ .cocoa = .{ .layer = 1 } }));
    try std.testing.expect((try webgpu_state.handle().queryCapabilities()).surfaces.supportsPlatform(.{ .webgpu_canvas = .{ .context = 1 } }));
    try std.testing.expect((try vulkan_state.handle().queryCapabilities()).textures.supportsFormat(.rgba8_unorm));
}

test "recording backend reports raster capabilities by backend kind" {
    const allocator = std.testing.allocator;

    var cuda_state = BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };
    var vulkan_state = BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };
    var metal_state = BackendState{
        .allocator = allocator,
        .kind = .metal,
        .format = .metal_msl,
    };
    var webgpu_state = BackendState{
        .allocator = allocator,
        .kind = .webgpu,
        .format = .webgpu_wgsl,
    };

    try std.testing.expect(!(try cuda_state.handle().queryCapabilities()).raster.supported);
    try std.testing.expect((try vulkan_state.handle().queryCapabilities()).raster.supportsArtifactFormat(.vulkan_spirv));
    try std.testing.expect((try metal_state.handle().queryCapabilities()).raster.supportsArtifactFormat(.metal_msl));
    try std.testing.expect((try webgpu_state.handle().queryCapabilities()).raster.supportsArtifactFormat(.webgpu_wgsl));
    try std.testing.expect((try vulkan_state.handle().queryCapabilities()).raster.instancing);
    try std.testing.expect((try vulkan_state.handle().queryCapabilities()).raster.supportsTopology(.triangle_list));
    try std.testing.expect((try vulkan_state.handle().queryCapabilities()).raster.supportsBlendMode(.alpha_premultiplied));
}

test "recording backend records instanced raster draws into surface frames" {
    const allocator = std.testing.allocator;
    var state = BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };
    const handle = state.handle();

    const vertex_attributes = [_]backend.RenderVertexAttribute{
        .{ .location = 0, .format = .float32x2, .offset = 0 },
        .{ .location = 1, .format = .float32x4, .offset = 8 },
    };
    const vertex_layouts = [_]backend.RenderVertexBufferLayout{
        .{
            .binding = 0,
            .stride = 24,
            .step_mode = .instance,
            .attribute_start = 0,
            .attribute_count = vertex_attributes.len,
        },
    };
    var artifact = try handle.createRenderArtifact(.{
        .format = .vulkan_spirv,
        .vertex_entry_name = "quad_vs",
        .fragment_entry_name = "quad_fs",
        .target_format = .rgba8_unorm,
        .push_extent = 0,
        .blend_mode = .alpha_premultiplied,
        .topology = .triangle_list,
        .vertex_layouts = vertex_layouts[0..],
        .vertex_attributes = vertex_attributes[0..],
    });
    defer artifact.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.render_create_count);
    try std.testing.expectEqual(backend.RenderArtifactFormat.vulkan_spirv, state.last_render_format.?);

    const loaded = try handle.loadRenderArtifact(&artifact);
    try std.testing.expectEqual(@as(usize, 1), state.render_load_count);
    try std.testing.expectEqual(loaded.id, state.last_loaded_render_artifact_id.?);

    const instances = try handle.allocateBuffer(.{
        .byte_size = 24 * 3,
        .alignment = 8,
    });
    const surface = try handle.createSurface(.{
        .platform = .{ .headless = .{} },
        .extent = .{ .width = 320, .height = 180 },
        .format = .rgba8_unorm,
        .usage = .{ .present = true, .copy_dst = true, .color_attachment = true },
    });
    const frame = try handle.acquireSurfaceFrame(.{ .surface = surface });
    const render_done = try handle.createEvent(.{});
    try std.testing.expect(!try handle.queryEvent(.{ .event = render_done }));

    const pass = backend.RenderPass{
        .color = .{ .view = frame.view, .load = .{ .clear = .{} } },
        .viewport = .{ .width = 320, .height = 180 },
        .scissor = .{ .width = 320, .height = 180 },
        .draws = &.{.{
            .pipeline = loaded,
            .vertex_buffers = &.{.{ .buffer = instances }},
            .range = .{ .vertex_count = 6, .instance_count = 3 },
        }},
    };
    try handle.render(.{ .pass = pass, .signal_event = render_done });
    try std.testing.expectEqual(@as(usize, 1), state.render_count);
    try std.testing.expectEqual(@as(usize, 1), state.last_render_draw_count);
    try std.testing.expectEqual(loaded.id, state.last_render_loaded_artifact_id.?);
    try std.testing.expectEqual(frame.texture.id, state.last_render_target_texture_id.?);
    try std.testing.expectEqual(@as(usize, 1), state.last_render_vertex_buffer_count);
    try std.testing.expect(!state.last_render_indexed);
    try std.testing.expectEqual(@as(u32, 6), state.last_render_vertex_count);
    try std.testing.expectEqual(@as(u32, 3), state.last_render_instance_count);
    try std.testing.expect(try handle.queryEvent(.{ .event = render_done }));

    try handle.presentSurfaceFrame(.{
        .surface = surface,
        .frame = frame,
        .wait_events = &.{render_done},
    });
    try std.testing.expectEqual(@as(usize, 1), state.surface_present_count);
    try std.testing.expectEqual(@as(usize, 1), state.last_present_wait_count);
    try std.testing.expectEqual(render_done.id, state.last_present_wait_events[0]);

    const bundle = try handle.recordRenderBundle(pass);
    try handle.submitRenderBundle(.{ .bundle = bundle });
    try handle.submitRenderBundle(.{ .bundle = bundle });
    try std.testing.expectEqual(@as(usize, 1), state.bundle_record_count);
    try std.testing.expectEqual(@as(usize, 2), state.bundle_submit_count);
    const readable = try handle.allocateTexture(.{
        .extent = .{ .width = 4, .height = 4, .depth = 1 },
        .format = .rgba8_unorm,
        .usage = .{ .color_attachment = true, .copy_src = true },
    });
    var texels: [4 * 4 * 4]u8 = undefined;
    try std.testing.expectError(error.UnsupportedOperation, handle.readTexture(.{
        .texture = readable,
        .bytes = &texels,
    }));
}

test "recording backend records texture surface acquire and present calls" {
    const allocator = std.testing.allocator;
    var state = BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };
    const handle = state.handle();

    const texture = try handle.allocateTexture(.{
        .extent = .{ .width = 128, .height = 64 },
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true, .copy_dst = true },
    });
    try std.testing.expectEqual(@as(usize, 1), state.texture_allocate_count);
    try std.testing.expectEqual(texture.id, state.last_texture_id.?);

    const surface = try handle.createSurface(.{
        .platform = .{ .headless = .{} },
        .extent = .{ .width = 320, .height = 180 },
        .format = .rgba8_unorm,
        .usage = .{ .present = true, .copy_dst = true },
    });
    try std.testing.expectEqual(@as(usize, 1), state.surface_create_count);
    try std.testing.expectEqual(surface.id, state.last_surface_id.?);
    try std.testing.expectEqual(backend.SurfacePlatformKind.headless, state.last_surface_platform.?);

    const frame = try handle.acquireSurfaceFrame(.{ .surface = surface });
    try std.testing.expectEqual(@as(usize, 1), state.surface_acquire_count);
    try std.testing.expectEqual(frame.id, state.last_surface_frame_id.?);
    try std.testing.expectEqual(backend.TextureOwnership.acquired_surface, frame.texture.ownership);

    const frame_pixels = try handle.allocateBuffer(.{
        .byte_size = @as(usize, frame.texture.extent.width) * @as(usize, frame.texture.extent.height) * 4,
        .alignment = 16,
    });
    const stream = try handle.createStream(.{});
    const wait_a = try handle.createEvent(.{});
    const wait_b = try handle.createEvent(.{});
    const signal = try handle.createEvent(.{});
    try handle.recordEvent(.{ .stream = stream, .event = wait_a });
    try handle.recordEvent(.{ .stream = stream, .event = wait_b });
    try std.testing.expect(try handle.queryEvent(.{ .event = wait_a }));
    try std.testing.expect(try handle.queryEvent(.{ .event = wait_b }));
    try std.testing.expect(!try handle.queryEvent(.{ .event = signal }));
    const ops = [_]backend.SurfaceFrameWriteOp{
        .{ .clear = .{ .r = 0, .g = 0, .b = 0, .a = 1 } },
        .{ .copy_buffer = frame_pixels },
    };
    try handle.writeSurfaceFrame(.{
        .surface = surface,
        .frame = frame,
        .operations = &ops,
        .wait_events = &.{ wait_a, wait_b },
        .signal_event = signal,
    });
    try std.testing.expectEqual(@as(usize, 1), state.surface_write_count);
    try std.testing.expectEqual(frame.id, state.last_written_frame_id.?);
    try std.testing.expectEqual(@as(usize, 2), state.last_surface_write_op_count);
    try std.testing.expectEqual(frame_pixels.id, state.last_surface_write_copy_buffer_id.?);
    try std.testing.expectEqual(@as(usize, 2), state.last_surface_write_wait_count);
    try std.testing.expectEqual(wait_a.id, state.last_surface_write_wait_events[0]);
    try std.testing.expectEqual(wait_b.id, state.last_surface_write_wait_events[1]);
    try std.testing.expectEqual(signal.id, state.last_surface_write_signal_event.?);
    try std.testing.expect(try handle.queryEvent(.{ .event = signal }));
    try std.testing.expectEqual(@as(usize, 0), state.sync_count);
    try std.testing.expectError(error.SurfaceFrameExpired, handle.writeSurfaceFrame(.{
        .surface = surface,
        .frame = frame,
        .operations = &ops,
        .wait_events = &.{ wait_a, wait_b },
    }));
    try std.testing.expectEqual(@as(usize, 1), state.surface_write_count);

    const unready_present_wait = try handle.createEvent(.{});
    try std.testing.expectError(error.InvalidEvent, handle.presentSurfaceFrame(.{
        .surface = surface,
        .frame = frame,
        .wait_events = &.{unready_present_wait},
    }));
    try std.testing.expectEqual(@as(usize, 0), state.surface_present_count);

    const present_signal = try handle.createEvent(.{});
    try std.testing.expectError(error.UnsupportedOperation, handle.presentSurfaceFrame(.{
        .surface = surface,
        .frame = frame,
        .signal_event = present_signal,
    }));
    try std.testing.expectEqual(@as(usize, 0), state.surface_present_count);

    try handle.presentSurfaceFrame(.{
        .surface = surface,
        .frame = frame,
        .wait_events = &.{signal},
    });
    try std.testing.expectEqual(@as(usize, 1), state.surface_present_count);
    try std.testing.expectEqual(frame.id, state.last_presented_frame_id.?);
    try std.testing.expectEqual(@as(usize, 1), state.last_present_wait_count);
    try std.testing.expectEqual(signal.id, state.last_present_wait_events[0]);

    try handle.destroyTexture(texture);
    try std.testing.expectEqual(@as(usize, 1), state.texture_destroy_count);
    try handle.destroySurface(surface);
    try std.testing.expectEqual(@as(usize, 1), state.surface_destroy_count);
}

test "recording backend rejects invalid surface frame bracketing" {
    const allocator = std.testing.allocator;
    var state = BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };
    const handle = state.handle();

    const surface = try handle.createSurface(.{
        .platform = .{ .headless = .{} },
        .extent = .{ .width = 320, .height = 180 },
        .format = .rgba8_unorm,
        .usage = .{ .present = true, .copy_dst = true },
    });
    const fake_texture = backend.TextureHandle{
        .id = 99,
        .backend = .vulkan,
        .extent = .{ .width = 320, .height = 180 },
        .format = .rgba8_unorm,
        .usage = .{ .present = true },
        .ownership = .acquired_surface,
    };
    const fake_frame = backend.SurfaceFrame{
        .id = 77,
        .backend = .vulkan,
        .surface = surface,
        .texture = fake_texture,
        .view = .{ .texture = fake_texture, .format = .rgba8_unorm },
        .generation = surface.generation,
    };
    try std.testing.expectError(error.InvalidSurfaceFrame, handle.presentSurfaceFrame(.{
        .surface = surface,
        .frame = fake_frame,
    }));

    const frame = try handle.acquireSurfaceFrame(.{ .surface = surface });
    try std.testing.expectError(error.SurfaceAlreadyAcquired, handle.acquireSurfaceFrame(.{ .surface = surface }));
    try std.testing.expectError(error.SurfaceAlreadyAcquired, handle.destroySurface(surface));
    try std.testing.expectError(error.SurfaceAlreadyAcquired, handle.destroyTexture(frame.texture));

    try handle.presentSurfaceFrame(.{
        .surface = surface,
        .frame = frame,
    });
    try std.testing.expectError(error.SurfaceFrameExpired, handle.presentSurfaceFrame(.{
        .surface = surface,
        .frame = frame,
    }));
}

test "recording backend rejects stale surface frame generations" {
    const allocator = std.testing.allocator;
    var state = BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };
    const handle = state.handle();

    const surface = try handle.createSurface(.{
        .platform = .{ .headless = .{} },
        .extent = .{ .width = 320, .height = 180 },
        .format = .rgba8_unorm,
        .usage = .{ .present = true, .copy_dst = true },
    });
    const frame = try handle.acquireSurfaceFrame(.{ .surface = surface });
    state.surfaces[0].generation += 1;
    try std.testing.expectError(error.SurfaceFrameExpired, handle.presentSurfaceFrame(.{
        .surface = surface,
        .frame = frame,
    }));
}

test "recording backend replaces surfaces for resized presentation" {
    const allocator = std.testing.allocator;
    var state = BackendState{
        .allocator = allocator,
        .kind = .vulkan,
        .format = .vulkan_spirv,
    };
    const handle = state.handle();

    const old_surface = try handle.createSurface(.{
        .platform = .{ .headless = .{} },
        .extent = .{ .width = 320, .height = 180 },
        .format = .rgba8_unorm,
        .usage = .{ .present = true, .copy_dst = true },
    });
    const old_frame = try handle.acquireSurfaceFrame(.{ .surface = old_surface });
    try handle.presentSurfaceFrame(.{
        .surface = old_surface,
        .frame = old_frame,
    });
    try handle.destroyTexture(old_frame.texture);
    try handle.destroySurface(old_surface);

    const surface = try handle.createSurface(.{
        .platform = .{ .headless = .{} },
        .extent = .{ .width = 640, .height = 360 },
        .format = .rgba8_unorm,
        .usage = .{ .present = true, .copy_dst = true },
    });
    try std.testing.expect(surface.id != old_surface.id);
    try std.testing.expectEqual(@as(u32, 640), surface.extent.width);
    try std.testing.expectEqual(@as(u32, 360), surface.extent.height);
    try std.testing.expectError(error.InvalidSurfaceFrame, handle.presentSurfaceFrame(.{
        .surface = surface,
        .frame = old_frame,
    }));
    try std.testing.expectError(error.InvalidSurface, handle.acquireSurfaceFrame(.{ .surface = old_surface }));

    const frame = try handle.acquireSurfaceFrame(.{ .surface = surface });
    try std.testing.expectEqual(@as(u32, 640), frame.texture.extent.width);
    try std.testing.expectEqual(@as(u32, 360), frame.texture.extent.height);
    try handle.presentSurfaceFrame(.{
        .surface = surface,
        .frame = frame,
    });

    try std.testing.expectEqual(@as(usize, 2), state.surface_create_count);
    try std.testing.expectEqual(@as(usize, 2), state.surface_present_count);
    try std.testing.expectEqual(@as(usize, 1), state.surface_destroy_count);
}
