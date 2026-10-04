const std = @import("std");
const builtin = @import("builtin");
const gpu_abi = @import("gpu_abi");
const sys = @import("sys");
const tldr = @import("tldr");

const backend = @import("root.zig");
/// The rasterizer this backend's passes run on.
pub const raster = @import("runtime/cpu/raster.zig");

/// `object_supported` is whether this host loads a `.cpu_object` artifact: tldr's loader is the
/// one that links and maps it. A test of the CPU object path skips where it is false.
pub const object_supported = tldr.load_supported;

const elf_object = tldr.formats.elf.object;

const max_launch_args = 32;

/// The number of absolute symbols a loaded kernel or stage links against: one
/// per function `sys.math.symbols` lists, `malloc` and `free` from `sys.heap`,
/// and the sampler a lowered stage calls. `runtimeSymbolsObject` sizes its
/// symbol array with it, so the array holds every name a kernel may call.
const runtime_symbol_count = sys.math.symbols.len + 3;

const LoadedKernel = struct {
    mapping: []align(std.heap.page_size_min) u8,
    entry_address: usize,
    code_len: usize,
    argument_count: u32,
};

const BufferRecord = struct {
    bytes: []u8,
    byte_size: usize,
    alignment: std.mem.Alignment,
    ownership: backend.BufferOwnership,
};

const TextureRecord = struct {
    handle: backend.TextureHandle,
    texture: raster.Texture,
};

/// A render pipeline: the object linked twice, once with each stage as its entry, and the vertex
/// layouts, attributes and texture keys the rasterizer reads.
const PipelineRecord = struct {
    loaded: backend.LoadedRenderArtifact,
    images: [2][]align(std.heap.page_size_min) u8,
    layouts: [raster.max_vertex_buffers]raster.Layout,
    attributes: [raster.max_vertex_attributes]raster.Attribute,
    keys: [raster.max_bindings]i32,
    pipeline: raster.Pipeline,
};

const BindingsRecord = struct {
    pipeline_id: backend.BackendObjectId,
    sampled: [raster.max_bindings]raster.Sampled,
    uniforms: [raster.max_bindings]raster.Uniform,
    resources: raster.Resources,
};

/// A recorded pass, copied with the draws, vertex buffer ranges and push constants it names.
const BundleRecord = struct {
    pass: backend.RenderPass,
    draws: []backend.RenderDraw,
    ranges: []backend.RenderBufferRange,
    push_constants: []u8,
};

/// Each render object lives at a fixed address, since pipelines, bindings and passes point into
/// one another.
const RenderObject = union(enum) {
    texture: *TextureRecord,
    pipeline: *PipelineRecord,
    bindings: *BindingsRecord,
    bundle: *BundleRecord,
};

pub const Stages = struct {
    vertex: raster.Stage,
    fragment: raster.Fragment,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    next_id: backend.BackendObjectId = 1,
    loaded: std.AutoHashMapUnmanaged(backend.BackendObjectId, LoadedKernel) = .empty,
    buffers: std.AutoHashMapUnmanaged(backend.BackendObjectId, BufferRecord) = .empty,
    render_objects: std.AutoHashMapUnmanaged(backend.BackendObjectId, RenderObject) = .empty,
    /// The triangles and fragments every pass so far has rasterized.
    counters: raster.Counters = .{},
    /// The context every draw's stages read, refilled per draw.
    frame: raster.Frame = .init(&no_resources),

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        var loaded_iter = self.loaded.valueIterator();
        while (loaded_iter.next()) |kernel| {
            sys.memory.unmap(kernel.mapping);
        }
        self.loaded.deinit(self.allocator);

        var buffer_iter = self.buffers.valueIterator();
        while (buffer_iter.next()) |record| freeBufferRecord(self.allocator, record.*);
        self.buffers.deinit(self.allocator);

        var render_iter = self.render_objects.valueIterator();
        while (render_iter.next()) |object| freeRenderObject(self.allocator, object.*);
        self.render_objects.deinit(self.allocator);
        self.* = undefined;
    }

    /// The lowered stages a loaded pipeline calls, for a caller that times them alone.
    pub fn pipelineStages(self: *State, pipeline: backend.LoadedRenderArtifact) backend.BackendError!Stages {
        const record = try getPipeline(self, pipeline.id);
        return .{ .vertex = record.pipeline.vertex, .fragment = record.pipeline.fragment };
    }

    pub fn handle(self: *State) backend.BackendHandle {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .kind = .cpu,
        };
    }
};

fn queryCapabilities(_: *anyopaque) backend.BackendError!backend.BackendCapabilities {
    return .{
        .identity = .{
            .backend = .cpu,
            .family = .native_cpu,
            .name = "native-cpu",
        },
        .memory = .{
            .min_buffer_alignment = 1,
            .host_visible_device_memory = true,
            .unified_memory = true,
        },
        .threadgroup = .{
            .max_threads = 1024,
            .max_blocks = .{ std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) },
            .max_threads_per_dim = .{ 1024, 1024, 1024 },
            .max_grid_per_dim = .{ std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) },
        },
        .dtypes = backend.DTypeSet.init(&.{ .i1, .i32, .u32, .i64, .u64, .f32, .f64, .key }),
        .layouts = .{
            .row_major = true,
            .compact_strides = true,
            .broadcast_strides = true,
        },
        .runtime = .{
            .driver_loaded = true,
            .device_context = false,
            .streams = false,
            .events = false,
        },
        .artifact_formats = backend.ArtifactFormatSet.init(&.{ .cpu_machine_code, .cpu_object }),
        .textures = .{
            .supported = true,
            .formats = backend.TextureFormatSet.init(&(color_formats ++ [_]backend.TextureFormat{.depth32_float})),
            .usages = .{
                .copy_src = true,
                .copy_dst = true,
                .sampled = true,
                .color_attachment = true,
                .depth_attachment = true,
            },
            .max_extent = .{ .width = raster.max_extent, .height = raster.max_extent, .depth = 1 },
            .max_sample_count = 1,
        },
        .raster = .{
            .supported = true,
            .artifact_formats = backend.RenderArtifactFormatSet.init(&.{.cpu_object}),
            .target_formats = backend.TextureFormatSet.init(&color_formats),
            .depth_formats = backend.TextureFormatSet.init(&.{.depth32_float}),
            .blend_modes = backend.RenderBlendModeSet.init(&.{ .replace, .alpha_premultiplied, .alpha_straight, .additive }),
            .topologies = backend.RenderPrimitiveTopologySet.init(&.{ .triangle_list, .triangle_strip }),
            .vertex_formats = backend.RenderVertexFormatSet.init(&.{ .float32, .float32x2, .float32x3, .float32x4, .uint32, .uint32x2, .uint32x4 }),
            .binding_kinds = backend.RenderBindingKindSet.init(&.{ .uniform_buffer, .sampled_texture }),
            .index_formats = backend.RenderIndexFormatSet.init(&.{ .none, .u16, .u32 }),
            .max_vertex_buffers = raster.max_vertex_buffers,
            .max_vertex_attributes = raster.max_vertex_attributes,
            .max_bindings = raster.max_bindings,
            .instancing = true,
            .max_push_constant_bytes = gpu_abi.stage.push_words * 4,
            .depth_bias = true,
            .depth_bias_clamp = true,
        },
    };
}

const color_formats = [_]backend.TextureFormat{ .rgba8_unorm, .bgra8_unorm, .rgba8_srgb, .bgra8_srgb };

fn createArtifact(
    ptr: *anyopaque,
    request: backend.CompileRequest,
) backend.BackendError!backend.KernelArtifact {
    const state: *State = @ptrCast(@alignCast(ptr));
    switch (request.requested_format) {
        .cpu_machine_code, .cpu_object => {},
        else => return error.UnsupportedArtifactFormat,
    }
    var artifact = backend.KernelArtifact.init(state.allocator, .{
        .backend = .cpu,
        .format = request.requested_format,
        .entry_name = request.kernel_name,
        .argument_count = request.argument_count,
        .scalar_argument_count = request.scalar_argument_count,
        .diagnostic_id = request.diagnostic_id,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    switch (request.payload) {
        .bytes => |bytes| try artifact.setOwnedBytes(bytes),
        else => return error.InvalidArtifact,
    }
    return artifact;
}

fn loadArtifact(
    ptr: *anyopaque,
    artifact: *const backend.KernelArtifact,
) backend.BackendError!backend.LoadedArtifact {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (artifact.backend != .cpu) return error.InvalidArtifact;
    const code = switch (artifact.payload) {
        .bytes => |bytes| bytes,
        else => return error.InvalidArtifact,
    };
    return switch (artifact.format) {
        .cpu_machine_code => loadNativeCode(state, code, artifact.argument_count, artifact.format),
        .cpu_object => loadObjectCode(state, code, artifact.entry_name, artifact.argument_count, artifact.format),
        else => error.UnsupportedArtifactFormat,
    };
}

fn loadNativeCode(
    state: *State,
    code: []const u8,
    argument_count: u32,
    format: backend.ArtifactFormat,
) backend.BackendError!backend.LoadedArtifact {
    if (code.len == 0) return error.InvalidArtifact;

    const mapping = sys.memory.mapAnonymous(code.len, .{ .read = true, .write = true }) catch return error.RuntimeUnavailable;
    errdefer sys.memory.unmap(mapping);
    @memcpy(mapping[0..code.len], code);
    sys.memory.protect(mapping, .{ .read = true, .execute = true }) catch return error.RuntimeUnavailable;

    const id = nextObjectId(state);
    state.loaded.put(state.allocator, id, .{
        .mapping = mapping,
        .entry_address = @intFromPtr(mapping.ptr),
        .code_len = code.len,
        .argument_count = argument_count,
    }) catch return error.OutOfMemory;

    return .{
        .id = id,
        .backend = .cpu,
        .format = format,
    };
}

fn loadObjectCode(
    state: *State,
    object: []const u8,
    entry_name: []const u8,
    argument_count: u32,
    format: backend.ArtifactFormat,
) backend.BackendError!backend.LoadedArtifact {
    if (object.len == 0 or entry_name.len == 0) return error.InvalidArtifact;

    var loaded_image = try linkObject(state.allocator, object, entry_name);
    errdefer loaded_image.deinit();

    const id = nextObjectId(state);
    state.loaded.put(state.allocator, id, .{
        .mapping = loaded_image.memory,
        .entry_address = loaded_image.entry_address,
        .code_len = loaded_image.memory.len,
        .argument_count = argument_count,
    }) catch return error.OutOfMemory;

    return .{
        .id = id,
        .backend = .cpu,
        .format = format,
    };
}

/// Links `object` beside the runtime symbols and maps it with `entry_name` as its entry.
fn linkObject(allocator: std.mem.Allocator, object: []const u8, entry_name: []const u8) backend.BackendError!tldr.LoadedImage {
    const runtime_symbols = try runtimeSymbolsObject(allocator);
    defer allocator.free(runtime_symbols);

    const inputs = [_]tldr.Input{
        .{
            .name = "gpu-cpu-kernel.o",
            .bytes = object,
        },
        .{
            .name = "gpu-cpu-runtime.o",
            .bytes = runtime_symbols,
        },
    };

    return tldr.loadExecutable(allocator, &inputs, .{
        .entry_symbol = entry_name,
        .incremental_mode = .off,
    }) catch |err| cpuLoadError(err);
}

/// Returns the bytes of one relocatable object that defines each function
/// `sys.math.symbols` lists, plus `malloc`, `free` and the stage sampler, as a
/// global absolute symbol whose value is the address of the host's own
/// function. `linkObject` builds it for each kernel or stage object it loads,
/// links it beside the object as `gpu-cpu-runtime.o`, and frees it once the
/// link returns. The
/// function gives the object writer a fixed count of global symbols with no
/// section and no relocation, all in one value that tells the writer what one
/// object holds (description). Running out of memory is therefore the one
/// failure the object writer can report here, and the function returns it as
/// `error.OutOfMemory`. The caller owns the returned bytes and frees them with
/// `allocator`.
fn runtimeSymbolsObject(allocator: std.mem.Allocator) backend.BackendError![]u8 {
    var symbols: [runtime_symbol_count]elf_object.Symbol = undefined;
    const math_symbols = symbols[0..sys.math.symbols.len];
    for (sys.math.symbols, math_symbols) |symbol, *entry| {
        entry.* = elf_object.Symbol.absoluteObject(symbol.name(), symbol.address(), 0);
    }
    const heap_symbols = symbols[sys.math.symbols.len..];
    heap_symbols[0] = elf_object.Symbol.absoluteObject("malloc", @intFromPtr(&sys.heap.malloc), 0);
    heap_symbols[1] = elf_object.Symbol.absoluteObject("free", @intFromPtr(&sys.heap.free), 0);
    heap_symbols[2] = elf_object.Symbol.absoluteObject(gpu_abi.stage.sample_symbol, @intFromPtr(&raster.sample), 0);

    const description = elf_object.Description{ .sections = &.{}, .symbols = &symbols };
    return elf_object.build(allocator, description) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

fn allocateBuffer(
    ptr: *anyopaque,
    request: backend.BufferAllocation,
) backend.BackendError!backend.BufferHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    const allocation_len = @max(request.byte_size, 1);
    const alignment = std.mem.Alignment.fromByteUnits(request.alignment);
    const memory = state.allocator.rawAlloc(allocation_len, alignment, @returnAddress()) orelse return error.OutOfMemory;
    const bytes = memory[0..allocation_len];
    errdefer state.allocator.rawFree(bytes, alignment, @returnAddress());
    @memset(bytes, 0);

    const id = nextObjectId(state);
    state.buffers.put(state.allocator, id, .{
        .bytes = bytes,
        .byte_size = request.byte_size,
        .alignment = alignment,
        .ownership = .backend,
    }) catch return error.OutOfMemory;

    return .{
        .id = id,
        .backend = .cpu,
        .byte_size = request.byte_size,
        .ownership = .backend,
    };
}

fn importBuffer(
    ptr: *anyopaque,
    request: backend.BufferImport,
) backend.BackendError!backend.BufferHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    std.debug.assert(request.bytes.len != 0);
    std.debug.assert(std.mem.isAligned(@intFromPtr(request.bytes.ptr), request.alignment));
    const id = nextObjectId(state);
    state.buffers.put(state.allocator, id, .{
        .bytes = request.bytes,
        .byte_size = request.bytes.len,
        .alignment = std.mem.Alignment.fromByteUnits(request.alignment),
        .ownership = .borrowed_external,
    }) catch return error.OutOfMemory;
    return .{
        .id = id,
        .backend = .cpu,
        .byte_size = request.bytes.len,
        .ownership = .borrowed_external,
    };
}

fn freeBufferRecord(allocator: std.mem.Allocator, record: BufferRecord) void {
    switch (record.ownership) {
        .backend => allocator.rawFree(record.bytes, record.alignment, @returnAddress()),
        .borrowed_external => {},
        .host => unreachable,
    }
}

fn writeBuffer(
    ptr: *anyopaque,
    request: backend.BufferWriteRequest,
) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const record = state.buffers.getPtr(request.handle.id) orelse return error.InvalidBuffer;
    if (request.bytes.len > record.byte_size) return error.InvalidBuffer;
    @memcpy(record.bytes[0..request.bytes.len], request.bytes);
}

fn readBuffer(
    ptr: *anyopaque,
    request: backend.BufferReadRequest,
) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const record = state.buffers.getPtr(request.handle.id) orelse return error.InvalidBuffer;
    if (request.bytes.len < record.byte_size) return error.ReadBufferDestinationTooSmall;
    @memcpy(request.bytes[0..record.byte_size], record.bytes[0..record.byte_size]);
}

fn launch(ptr: *anyopaque, request: backend.LaunchRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const loaded = request.loaded_artifact orelse return error.InvalidArtifact;
    if (loaded.backend != .cpu or !backend.artifactFormatIsNativeCpu(loaded.format)) return error.InvalidArtifact;
    const kernel = state.loaded.get(loaded.id) orelse return error.InvalidArtifact;
    if (request.buffers.len + request.scalar_arguments.len != kernel.argument_count) return error.LaunchArgumentMismatch;
    if (kernel.code_len == 0) return error.InvalidArtifact;

    var args: [max_launch_args]i64 = undefined;
    var index: usize = 0;
    for (request.buffers) |binding| {
        if (index >= args.len) return error.LaunchArgumentMismatch;
        const record = state.buffers.get(binding.handle.id) orelse return error.InvalidBuffer;
        if (binding.byte_size > record.byte_size) return error.InvalidBuffer;
        args[index] = @bitCast(@intFromPtr(record.bytes.ptr));
        index += 1;
    }
    for (request.scalar_arguments) |argument| {
        if (index >= args.len) return error.LaunchArgumentMismatch;
        args[index] = try scalarArgumentBits(argument);
        index += 1;
    }

    callVoidKernel(kernel.entry_address, args[0..index]) catch return error.LaunchFailed;
}

fn destroyObject(ptr: *anyopaque, id: backend.BackendObjectId) void {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (state.loaded.fetchRemove(id)) |entry| {
        sys.memory.unmap(entry.value.mapping);
        return;
    }
    if (state.buffers.fetchRemove(id)) |entry| {
        freeBufferRecord(state.allocator, entry.value);
        return;
    }
    if (state.render_objects.fetchRemove(id)) |entry| freeRenderObject(state.allocator, entry.value);
}

fn freeRenderObject(allocator: std.mem.Allocator, object: RenderObject) void {
    switch (object) {
        .texture => |record| {
            allocator.free(record.texture.bytes);
            allocator.destroy(record);
        },
        .pipeline => |record| {
            for (record.images) |image| sys.memory.unmap(image);
            allocator.destroy(record);
        },
        .bindings => |record| allocator.destroy(record),
        .bundle => |record| {
            allocator.free(record.draws);
            allocator.free(record.ranges);
            allocator.free(record.push_constants);
            allocator.destroy(record);
        },
    }
}

fn synchronize(_: *anyopaque, _: backend.SyncRequest) backend.BackendError!void {}

fn getTexture(state: *State, handle: backend.TextureHandle) backend.BackendError!*TextureRecord {
    return switch (state.render_objects.get(handle.id) orelse return error.InvalidTexture) {
        .texture => |record| record,
        else => error.InvalidTexture,
    };
}

fn getPipeline(state: *State, id: backend.BackendObjectId) backend.BackendError!*PipelineRecord {
    return switch (state.render_objects.get(id) orelse return error.InvalidRenderArtifact) {
        .pipeline => |record| record,
        else => error.InvalidRenderArtifact,
    };
}

fn getBindings(state: *State, id: backend.BackendObjectId) backend.BackendError!*BindingsRecord {
    return switch (state.render_objects.get(id) orelse return error.RenderArgumentMismatch) {
        .bindings => |record| record,
        else => error.RenderArgumentMismatch,
    };
}

fn getBundle(state: *State, id: backend.BackendObjectId) backend.BackendError!*BundleRecord {
    return switch (state.render_objects.get(id) orelse return error.RenderArgumentMismatch) {
        .bundle => |record| record,
        else => error.RenderArgumentMismatch,
    };
}

/// Makes a zeroed texture of one level and one sample. A depth texture is never a color
/// attachment and a color texture never a depth attachment, as on the Vulkan path.
fn allocateTexture(ptr: *anyopaque, request: backend.TextureAllocation) backend.BackendError!backend.TextureHandle {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (request.sample_count != 1 or request.extent.depth != 1) return error.CapabilityMismatch;
    if (request.usage.present or request.usage.storage) return error.CapabilityMismatch;
    const depth = request.format.isDepth();
    if (depth and request.usage.color_attachment) return error.CapabilityMismatch;
    if (!depth and request.usage.depth_attachment) return error.CapabilityMismatch;
    try state.render_objects.ensureUnusedCapacity(state.allocator, 1);

    const byte_count = @as(usize, request.extent.width) * request.extent.height * request.format.texelBytes();
    const bytes = state.allocator.alignedAlloc(u8, .@"4", byte_count) catch return error.OutOfMemory;
    errdefer state.allocator.free(bytes);
    @memset(bytes, 0);
    const record = state.allocator.create(TextureRecord) catch return error.OutOfMemory;
    const handle = backend.TextureHandle{
        .id = nextObjectId(state),
        .backend = .cpu,
        .extent = request.extent,
        .format = request.format,
        .usage = request.usage,
        .sample_count = 1,
        .ownership = .backend,
    };
    record.* = .{
        .handle = handle,
        .texture = .{ .width = request.extent.width, .height = request.extent.height, .format = request.format, .bytes = bytes },
    };
    state.render_objects.putAssumeCapacity(handle.id, .{ .texture = record });
    return handle;
}

fn destroyTexture(ptr: *anyopaque, handle: backend.TextureHandle) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    _ = try getTexture(state, handle);
    freeRenderObject(state.allocator, state.render_objects.fetchRemove(handle.id).?.value);
}

fn writeTexture(ptr: *anyopaque, request: backend.TextureWriteRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const record = try getTexture(state, request.texture);
    if (request.bytes.len != record.texture.bytes.len) return error.InvalidTexture;
    @memcpy(record.texture.bytes, request.bytes);
}

fn readTexture(ptr: *anyopaque, request: backend.TextureReadRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const record = try getTexture(state, request.texture);
    if (request.bytes.len != record.texture.bytes.len) return error.InvalidTexture;
    @memcpy(request.bytes, record.texture.bytes);
}

fn createRenderArtifact(ptr: *anyopaque, desc: backend.RenderPipelineDesc) backend.BackendError!backend.RenderArtifact {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (desc.format != .cpu_object) return error.UnsupportedArtifactFormat;
    const object = switch (desc.payload) {
        .bytes => |bytes| bytes,
        else => return error.InvalidRenderArtifact,
    };
    if (object.len == 0) return error.InvalidRenderArtifact;
    var artifact = backend.RenderArtifact.init(state.allocator, .{
        .backend = .cpu,
        .pipeline = desc,
    }) catch return error.OutOfMemory;
    errdefer artifact.deinit();
    try artifact.setOwnedBytes(object);
    return artifact;
}

/// Links the artifact's object once per stage. Each vertex layout's binding must be below the
/// vertex buffer limit and used once, every attribute location below Choir's interface limit, and
/// every resource binding a sampled texture or a uniform buffer whose group and binding form a
/// distinct key. A uniform buffer must sit in group 0 below `gpu_abi.stage.uniform_bindings`,
/// where the stage's context has a window for it. A fragment entry the object defines under
/// `gpu_abi.stage.quad_suffix` reads its quad, and the rasterizer shades quads for it.
fn loadRenderArtifact(ptr: *anyopaque, artifact: *const backend.RenderArtifact) backend.BackendError!backend.LoadedRenderArtifact {
    const state: *State = @ptrCast(@alignCast(ptr));
    if (artifact.backend != .cpu) return error.CapabilityMismatch;
    if (artifact.format != .cpu_object) return error.UnsupportedArtifactFormat;
    const object = switch (artifact.payload) {
        .bytes => |bytes| bytes,
        else => return error.InvalidRenderArtifact,
    };
    if (object.len == 0) return error.InvalidRenderArtifact;
    switch (artifact.topology) {
        .triangle_list, .triangle_strip => {},
        .line_list, .line_strip => return error.CapabilityMismatch,
    }
    if (artifact.vertex_layouts.len > raster.max_vertex_buffers) return error.CapabilityMismatch;
    if (artifact.bindings.len > raster.max_bindings) return error.CapabilityMismatch;
    if (artifact.push_constant_bytes > gpu_abi.stage.push_words * 4) return error.CapabilityMismatch;

    var layouts: [raster.max_vertex_buffers]raster.Layout = undefined;
    var attributes: [raster.max_vertex_attributes]raster.Attribute = undefined;
    var attribute_count: u32 = 0;
    var used_vertex_bindings: u32 = 0;
    for (artifact.vertex_layouts, layouts[0..artifact.vertex_layouts.len]) |layout, *out| {
        if (layout.binding >= raster.max_vertex_buffers) return error.CapabilityMismatch;
        const bit = @as(u32, 1) << @intCast(layout.binding);
        if (used_vertex_bindings & bit != 0) return error.InvalidRenderArtifact;
        used_vertex_bindings |= bit;
        const start: usize = layout.attribute_start;
        const count: usize = layout.attribute_count;
        if (start > artifact.vertex_attributes.len or count > artifact.vertex_attributes.len - start) return error.InvalidRenderArtifact;
        out.* = .{
            .stride = layout.stride,
            .per_instance = layout.step_mode == .instance,
            .attribute_start = attribute_count,
            .attribute_count = @intCast(count),
        };
        for (artifact.vertex_attributes[start..][0..count]) |attribute| {
            if (attribute_count == raster.max_vertex_attributes) return error.CapabilityMismatch;
            if (attribute.location >= gpu_abi.stage.max_locations) return error.CapabilityMismatch;
            attributes[attribute_count] = .{ .location = attribute.location, .format = attribute.format, .offset = attribute.offset };
            attribute_count += 1;
        }
    }
    var keys: [raster.max_bindings]i32 = undefined;
    for (artifact.bindings, keys[0..artifact.bindings.len], 0..) |binding, *key, index| {
        switch (binding.kind) {
            .sampled_texture => {},
            .uniform_buffer => {
                if (binding.group != 0) return error.CapabilityMismatch;
                if (binding.binding >= gpu_abi.stage.uniform_bindings) return error.CapabilityMismatch;
            },
            .storage_buffer, .storage_texture => return error.CapabilityMismatch,
        }
        if (binding.group > std.math.maxInt(i16) or binding.binding > std.math.maxInt(u16)) return error.CapabilityMismatch;
        key.* = gpu_abi.stage.textureKey(binding.group, binding.binding);
        if (std.mem.indexOfScalar(i32, keys[0..index], key.*) != null) return error.InvalidRenderArtifact;
    }
    try state.render_objects.ensureUnusedCapacity(state.allocator, 1);

    var vertex_image = try linkStage(state.allocator, object, artifact.vertex_entry_name);
    errdefer vertex_image.deinit();
    var quad_buffer: [max_entry_bytes]u8 = undefined;
    const quad_name = std.fmt.bufPrint(&quad_buffer, "{s}{s}", .{ artifact.fragment_entry_name, gpu_abi.stage.quad_suffix }) catch
        return error.InvalidRenderArtifact;
    const quad = try definesSymbol(state.allocator, object, quad_name);
    var fragment_image = try linkStage(state.allocator, object, if (quad) quad_name else artifact.fragment_entry_name);
    errdefer fragment_image.deinit();
    const record = state.allocator.create(PipelineRecord) catch return error.OutOfMemory;
    const id = nextObjectId(state);
    record.* = .{
        .loaded = backend.LoadedRenderArtifact.describing(artifact, id),
        .images = .{ vertex_image.memory, fragment_image.memory },
        .layouts = layouts,
        .attributes = attributes,
        .keys = keys,
        .pipeline = undefined,
    };
    record.pipeline = .{
        .vertex = @ptrFromInt(vertex_image.entry_address),
        .fragment = if (quad)
            .{ .quad = @ptrFromInt(fragment_image.entry_address) }
        else
            .{ .pixel = @ptrFromInt(fragment_image.entry_address) },
        .blend = artifact.blend_mode,
        .cull = artifact.cull,
        .topology = artifact.topology,
        .depth = artifact.depth,
        .target_format = artifact.target_format,
        .layouts = record.layouts[0..artifact.vertex_layouts.len],
        .attributes = record.attributes[0..attribute_count],
    };
    state.render_objects.putAssumeCapacity(id, .{ .pipeline = record });
    return record.loaded;
}

/// Bytes a fragment entry's quad symbol may take.
const max_entry_bytes = 256;

/// Whether `object` defines the symbol `name`. A fragment stage that reads its quad is defined
/// under its entry name and `gpu_abi.stage.quad_suffix`, and one that does not under its name.
fn definesSymbol(allocator: std.mem.Allocator, object: []const u8, name: []const u8) backend.BackendError!bool {
    var parsed = tldr.parseObject(allocator, .{ .name = "gpu-cpu-kernel.o", .bytes = object }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRenderArtifact,
    };
    defer parsed.deinit(allocator);
    for (parsed.symbols) |symbol| {
        if (!symbol.undefined and std.mem.eql(u8, symbol.name, name)) return true;
    }
    return false;
}

fn linkStage(allocator: std.mem.Allocator, object: []const u8, entry_name: []const u8) backend.BackendError!tldr.LoadedImage {
    return linkObject(allocator, object, entry_name) catch |err| switch (err) {
        error.InvalidArtifact => error.InvalidRenderArtifact,
        else => err,
    };
}

fn createRenderBindings(ptr: *anyopaque, request: backend.RenderBindingsRequest) backend.BackendError!backend.RenderBindings {
    const state: *State = @ptrCast(@alignCast(ptr));
    const pipeline = try getPipeline(state, request.pipeline.id);
    const count: usize = pipeline.loaded.binding_count;
    if (request.resources.len != count) return error.RenderArgumentMismatch;
    var sampled: [raster.max_bindings]raster.Sampled = undefined;
    var sampled_count: usize = 0;
    var uniforms: [raster.max_bindings]raster.Uniform = undefined;
    var uniform_count: usize = 0;
    for (request.resources, pipeline.keys[0..count]) |resource, key| switch (resource) {
        .sampled_texture => |binding| {
            const texture = try getTexture(state, binding.texture);
            if (!texture.handle.usage.sampled) return error.InvalidTexture;
            sampled[sampled_count] = .{ .key = key, .texture = &texture.texture, .sampler = binding.sampler };
            sampled_count += 1;
        },
        .uniform_buffer => |buffer| {
            const record = state.buffers.getPtr(buffer.id) orelse return error.InvalidBuffer;
            const binding: u32 = @intCast(key & 0xffff);
            uniforms[uniform_count] = .{ .binding = binding, .bytes = record.bytes[0..record.byte_size] };
            uniform_count += 1;
        },
        .storage_buffer, .storage_texture => return error.RenderArgumentMismatch,
    };
    try state.render_objects.ensureUnusedCapacity(state.allocator, 1);
    const record = state.allocator.create(BindingsRecord) catch return error.OutOfMemory;
    record.* = .{
        .pipeline_id = pipeline.loaded.id,
        .sampled = sampled,
        .uniforms = uniforms,
        .resources = undefined,
    };
    record.resources = .{
        .sampled = record.sampled[0..sampled_count],
        .uniforms = record.uniforms[0..uniform_count],
    };
    const id = nextObjectId(state);
    state.render_objects.putAssumeCapacity(id, .{ .bindings = record });
    return .{ .id = id, .backend = .cpu, .pipeline = pipeline.loaded.id };
}

fn render(ptr: *anyopaque, request: backend.RenderRequest) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    try runPass(state, request.pass);
}

/// Checks the pass as `render` would and keeps a copy of it. The copy names the same objects,
/// which must outlive the bundle.
fn recordRenderBundle(ptr: *anyopaque, pass: backend.RenderPass) backend.BackendError!backend.RenderBundle {
    const state: *State = @ptrCast(@alignCast(ptr));
    _ = try passTargets(state, pass);
    var range_count: usize = 0;
    var push_bytes: usize = 0;
    for (pass.draws) |draw| {
        var resolved: Resolved = undefined;
        try resolveDraw(state, pass, draw, &resolved);
        range_count += draw.vertex_buffers.len;
        push_bytes += draw.push_constants.len;
    }
    try state.render_objects.ensureUnusedCapacity(state.allocator, 1);
    const draws = state.allocator.dupe(backend.RenderDraw, pass.draws) catch return error.OutOfMemory;
    errdefer state.allocator.free(draws);
    const ranges = state.allocator.alloc(backend.RenderBufferRange, range_count) catch return error.OutOfMemory;
    errdefer state.allocator.free(ranges);
    const push_constants = state.allocator.alloc(u8, push_bytes) catch return error.OutOfMemory;
    errdefer state.allocator.free(push_constants);
    var next: usize = 0;
    var next_push: usize = 0;
    for (draws) |*draw| {
        const copy = ranges[next..][0..draw.vertex_buffers.len];
        @memcpy(copy, draw.vertex_buffers);
        draw.vertex_buffers = copy;
        next += copy.len;
        const push_copy = push_constants[next_push..][0..draw.push_constants.len];
        @memcpy(push_copy, draw.push_constants);
        draw.push_constants = push_copy;
        next_push += push_copy.len;
    }
    const record = state.allocator.create(BundleRecord) catch return error.OutOfMemory;
    record.* = .{ .pass = pass, .draws = draws, .ranges = ranges, .push_constants = push_constants };
    record.pass.draws = draws;
    record.pass.diagnostic_id = null;
    const id = nextObjectId(state);
    state.render_objects.putAssumeCapacity(id, .{ .bundle = record });
    return .{ .id = id, .backend = .cpu, .draw_count = @intCast(draws.len) };
}

fn submitRenderBundle(ptr: *anyopaque, request: backend.RenderBundleSubmit) backend.BackendError!void {
    const state: *State = @ptrCast(@alignCast(ptr));
    const bundle = try getBundle(state, request.bundle.id);
    try runPass(state, bundle.pass);
}

const Targets = struct {
    color: *TextureRecord,
    depth: ?*TextureRecord,
};

fn passTargets(state: *State, pass: backend.RenderPass) backend.BackendError!Targets {
    const color = try getTexture(state, pass.color.view.texture);
    if (!color.handle.usage.color_attachment or color.texture.format != pass.color.view.format) return error.InvalidTexture;
    const attachment = pass.depth orelse return .{ .color = color, .depth = null };
    const depth = try getTexture(state, attachment.view.texture);
    if (!depth.handle.usage.depth_attachment or depth.texture.format != attachment.view.format) return error.InvalidTexture;
    if (depth.texture.width != color.texture.width or depth.texture.height != color.texture.height) return error.RenderArgumentMismatch;
    return .{ .color = color, .depth = depth };
}

/// Resolves every draw before touching a target, so a pass that names a missing or mismatched
/// object fails whole, then clears and draws in order.
fn runPass(state: *State, pass: backend.RenderPass) backend.BackendError!void {
    const targets = try passTargets(state, pass);
    for (pass.draws) |draw| {
        var resolved: Resolved = undefined;
        try resolveDraw(state, pass, draw, &resolved);
    }
    switch (pass.color.load) {
        .load => {},
        .clear => |color| raster.clearColor(&targets.color.texture, color),
    }
    if (pass.depth) |attachment| switch (attachment.load) {
        .load => {},
        .clear => |value| raster.clearDepth(&targets.depth.?.texture, value),
    };
    const raster_pass = raster.Pass{
        .color = &targets.color.texture,
        .depth = if (targets.depth) |target| &target.texture else null,
        .viewport = pass.viewport,
        .scissor = pass.scissor,
    };
    for (pass.draws) |draw| {
        var resolved: Resolved = undefined;
        resolveDraw(state, pass, draw, &resolved) catch unreachable;
        raster.draw(raster_pass, &resolved.draw, &state.frame, &state.counters);
    }
}

const no_resources = raster.Resources{};

/// A draw resolved against the backend's objects. `draw.vertex_buffers` points into `buffers`.
const Resolved = struct {
    draw: raster.Draw,
    buffers: [raster.max_vertex_buffers][]const u8,
};

/// Checks one draw the way the Vulkan path records it and resolves it for the rasterizer: every
/// buffer range a draw reads by its range is checked, and the vertices an indexed draw reaches
/// through its indices are checked by the rasterizer as it reads each one.
fn resolveDraw(state: *State, pass: backend.RenderPass, draw: backend.RenderDraw, out: *Resolved) backend.BackendError!void {
    const pipeline = try getPipeline(state, draw.pipeline.id);
    if (pipeline.loaded.target_format != pass.color.view.format) return error.RenderArgumentMismatch;
    if ((pipeline.loaded.depth != null) != (pass.depth != null)) return error.RenderArgumentMismatch;
    const layouts = pipeline.pipeline.layouts;
    if (draw.vertex_buffers.len != layouts.len) return error.RenderArgumentMismatch;
    const resources: *const raster.Resources = if (draw.bindings) |bindings| blk: {
        const record = try getBindings(state, bindings.id);
        if (record.pipeline_id != pipeline.loaded.id) return error.RenderArgumentMismatch;
        break :blk &record.resources;
    } else if (pipeline.loaded.binding_count != 0) return error.RenderArgumentMismatch else &no_resources;

    if (draw.push_constants.len != pipeline.loaded.push_constant_bytes) return error.RenderArgumentMismatch;
    const range = draw.range;
    const indexed = range.index_format != .none;
    for (draw.vertex_buffers, layouts, out.buffers[0..layouts.len]) |buffer_range, layout, *bytes| {
        bytes.* = try bufferFrom(state, buffer_range);
        const elements: u64 = if (layout.per_instance)
            @as(u64, range.first_instance) + range.instance_count
        else if (indexed)
            0
        else
            @as(u64, range.first_vertex) + range.vertex_count;
        const needed = std.math.mul(u64, elements, layout.stride) catch return error.RenderArgumentMismatch;
        if (needed > bytes.len) return error.RenderArgumentMismatch;
    }
    const indices: raster.Indices = if (!indexed) blk: {
        if (draw.index_buffer != null) return error.RenderArgumentMismatch;
        break :blk .none;
    } else blk: {
        const buffer_range = draw.index_buffer orelse return error.RenderArgumentMismatch;
        const index_bytes: u64 = if (range.index_format == .u16) 2 else 4;
        if (buffer_range.offset % index_bytes != 0) return error.RenderArgumentMismatch;
        const bytes = try bufferFrom(state, buffer_range);
        if ((@as(u64, range.first_index) + range.index_count) * index_bytes > bytes.len) return error.RenderArgumentMismatch;
        break :blk if (range.index_format == .u16) .{ .u16 = bytes } else .{ .u32 = bytes };
    };
    out.draw = .{
        .pipeline = &pipeline.pipeline,
        .resources = resources,
        .vertex_buffers = out.buffers[0..layouts.len],
        .indices = indices,
        .range = range,
        .push_constants = draw.push_constants,
    };
}

/// The bytes of a buffer from a range's offset on, which must fall inside the buffer.
fn bufferFrom(state: *State, range: backend.RenderBufferRange) backend.BackendError![]const u8 {
    const record = state.buffers.getPtr(range.buffer.id) orelse return error.InvalidBuffer;
    if (range.offset >= record.byte_size) return error.RenderArgumentMismatch;
    return record.bytes[@intCast(range.offset)..record.byte_size];
}

fn nextObjectId(state: *State) backend.BackendObjectId {
    const id = state.next_id;
    state.next_id += 1;
    return id;
}

fn scalarArgumentBits(argument: gpu_abi.ScalarArgument) backend.BackendError!i64 {
    return switch (argument) {
        .i32 => |value| value,
        .u32 => |value| @intCast(value),
        .i64 => |value| value,
        .u64 => |value| @bitCast(value),
        .f32 => |value| @intCast(@as(u32, @bitCast(value))),
        .f64 => |value| @bitCast(@as(u64, @bitCast(value))),
    };
}

fn cpuLoadError(err: tldr.LoadError) backend.BackendError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied,
        error.InvalidMapping,
        error.MapFailed,
        error.PermissionDenied,
        error.ProtectFailed,
        error.UnsupportedPlatform,
        => error.RuntimeUnavailable,
        else => error.InvalidArtifact,
    };
}

fn callVoidKernel(address: usize, args: []const i64) backend.BackendError!void {
    switch (args.len) {
        0 => {
            const func: *const fn () callconv(.c) void = @ptrFromInt(address);
            func();
        },
        1 => {
            const func: *const fn (i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0]);
        },
        2 => {
            const func: *const fn (i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1]);
        },
        3 => {
            const func: *const fn (i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2]);
        },
        4 => {
            const func: *const fn (i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3]);
        },
        5 => {
            const func: *const fn (i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4]);
        },
        6 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5]);
        },
        7 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6]);
        },
        8 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]);
        },
        9 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8]);
        },
        10 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9]);
        },
        11 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10]);
        },
        12 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11]);
        },
        13 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12]);
        },
        14 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13]);
        },
        15 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14]);
        },
        16 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15]);
        },
        17 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16]);
        },
        18 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17]);
        },
        19 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18]);
        },
        20 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18], args[19]);
        },
        21 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18], args[19], args[20]);
        },
        22 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18], args[19], args[20], args[21]);
        },
        23 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18], args[19], args[20], args[21], args[22]);
        },
        24 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18], args[19], args[20], args[21], args[22], args[23]);
        },
        25 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18], args[19], args[20], args[21], args[22], args[23], args[24]);
        },
        26 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18], args[19], args[20], args[21], args[22], args[23], args[24], args[25]);
        },
        27 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18], args[19], args[20], args[21], args[22], args[23], args[24], args[25], args[26]);
        },
        28 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18], args[19], args[20], args[21], args[22], args[23], args[24], args[25], args[26], args[27]);
        },
        29 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18], args[19], args[20], args[21], args[22], args[23], args[24], args[25], args[26], args[27], args[28]);
        },
        30 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18], args[19], args[20], args[21], args[22], args[23], args[24], args[25], args[26], args[27], args[28], args[29]);
        },
        31 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18], args[19], args[20], args[21], args[22], args[23], args[24], args[25], args[26], args[27], args[28], args[29], args[30]);
        },
        32 => {
            const func: *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) void = @ptrFromInt(address);
            func(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15], args[16], args[17], args[18], args[19], args[20], args[21], args[22], args[23], args[24], args[25], args[26], args[27], args[28], args[29], args[30], args[31]);
        },
        else => return error.LaunchArgumentMismatch,
    }
}

const vtable = backend.BackendVTable{
    .query_capabilities = queryCapabilities,
    .create_artifact = createArtifact,
    .load_artifact = loadArtifact,
    .allocate_buffer = allocateBuffer,
    .import_buffer = importBuffer,
    .write_buffer = writeBuffer,
    .read_buffer = readBuffer,
    .launch = launch,
    .create_render_artifact = createRenderArtifact,
    .load_render_artifact = loadRenderArtifact,
    .allocate_texture = allocateTexture,
    .destroy_texture = destroyTexture,
    .write_texture = writeTexture,
    .read_texture = readTexture,
    .render = render,
    .create_render_bindings = createRenderBindings,
    .record_render_bundle = recordRenderBundle,
    .submit_render_bundle = submitRenderBundle,
    .synchronize = synchronize,
    .destroy_object = destroyObject,
};

var trampoline_probe: i64 = 0;

fn recordThirtyTwoArgs(
    a0: i64,
    a1: i64,
    a2: i64,
    a3: i64,
    a4: i64,
    a5: i64,
    a6: i64,
    a7: i64,
    a8: i64,
    a9: i64,
    a10: i64,
    a11: i64,
    a12: i64,
    a13: i64,
    a14: i64,
    a15: i64,
    a16: i64,
    a17: i64,
    a18: i64,
    a19: i64,
    a20: i64,
    a21: i64,
    a22: i64,
    a23: i64,
    a24: i64,
    a25: i64,
    a26: i64,
    a27: i64,
    a28: i64,
    a29: i64,
    a30: i64,
    a31: i64,
) callconv(.c) void {
    trampoline_probe = a0 + a7 + a15 + a23 + a31;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    _ = a5;
    _ = a6;
    _ = a8;
    _ = a9;
    _ = a10;
    _ = a11;
    _ = a12;
    _ = a13;
    _ = a14;
    _ = a16;
    _ = a17;
    _ = a18;
    _ = a19;
    _ = a20;
    _ = a21;
    _ = a22;
    _ = a24;
    _ = a25;
    _ = a26;
    _ = a27;
    _ = a28;
    _ = a29;
    _ = a30;
}

/// x86-64 code that jumps to `target`: `movabs rax, target; jmp rax`, padded with `int3`.
fn trampoline(target: usize) [16]u8 {
    var code: [16]u8 = @splat(0xcc);
    code[0..2].* = .{ 0x48, 0xb8 };
    std.mem.writeInt(u64, code[2..10], target, .little);
    code[10..12].* = .{ 0xff, 0xe0 };
    return code;
}

/// A vertex stage placing location 0 as the clip position and passing location 1 on.
fn testVertexStage(inputs: [*]const f32, outputs: [*]f32, _: *anyopaque) callconv(.c) void {
    const stage = gpu_abi.stage;
    outputs[stage.smooth_mask_low] = @bitCast(@as(u32, 0x3));
    outputs[stage.smooth_mask_high] = @bitCast(@as(u32, 0));
    outputs[stage.flat_mask_low] = @bitCast(@as(u32, 0));
    outputs[stage.flat_mask_high] = @bitCast(@as(u32, 0));
    outputs[stage.position..][0..4].* = .{ inputs[stage.slot(stage.smooth, 0, 0)], inputs[stage.slot(stage.smooth, 0, 1)], 0, 1 };
    outputs[stage.smooth] = inputs[stage.slot(stage.smooth, 1, 0)];
    outputs[stage.smooth + 1] = inputs[stage.slot(stage.smooth, 1, 1)];
}

/// A fragment stage writing the texel of binding 3 at the coordinate it receives.
fn testFragmentStage(inputs: [*]const f32, outputs: [*]f32, context: *anyopaque) callconv(.c) void {
    const stage = gpu_abi.stage;
    outputs[stage.sample..][0..3].* = .{ inputs[stage.smooth], inputs[stage.smooth + 1], 0 };
    raster.sample(context, stage.textureKey(0, 3), outputs);
    outputs[stage.smooth..][0..4].* = outputs[stage.sample..][0..4].*;
}

fn expectHalves(texels: *const [4 * 4 * 4]u8) !void {
    for (0..4) |y| for (0..4) |x| {
        const want: [4]u8 = if (x < 2) .{ 255, 0, 0, 255 } else .{ 0, 0, 255, 255 };
        try std.testing.expectEqual(want, texels[(y * 4 + x) * 4 ..][0..4].*);
    };
}

/// A fragment stage writing its first push-constant word as red and the first word of uniform
/// binding 2 as green.
fn blockFragmentStage(_: [*]const f32, outputs: [*]f32, context: *anyopaque) callconv(.c) void {
    const stage = gpu_abi.stage;
    const words: [*]const f32 = @ptrCast(@alignCast(context));
    outputs[stage.smooth..][0..4].* = .{ words[stage.push], words[stage.uniformWord(2, 0)], 0, 1 };
}
