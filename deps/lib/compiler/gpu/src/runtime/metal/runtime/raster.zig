//! Metal render objects: textures and their transfers, render pipelines, the command buffers a
//! pass records into, and surfaces that present `CAMetalLayer` drawables. Every call that makes
//! or uses autoreleased objects holds its own autorelease pool, except where a function says its
//! caller holds one.

const std = @import("std");
const sys = @import("sys");

const runtime = @import("root.zig");
const Runtime = @import("device.zig").Runtime;
const LibrarySource = @import("device.zig").LibrarySource;
const foundation = sys.apple.foundation;
const metal = sys.apple.metal;
const objc = sys.apple.objc;

const native_available = metal.available;

/// A private 2D texture of `levels` mip levels, `size` the extent of level 0.
pub const Texture = struct {
    texture: metal.Texture,
    size: metal.Size,
    texel_bytes: u32,
    levels: u32 = 1,

    pub fn create(
        rt: *Runtime,
        format: metal.PixelFormat,
        width: u32,
        height: u32,
        texel_bytes: u32,
        usage: metal.TextureUsage,
        levels: u32,
    ) runtime.Error!Texture {
        if (comptime !native_available) return error.UnsupportedPlatform;
        std.debug.assert(levels >= 1);
        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const texture = if (levels == 1)
            metal.newTexture2D(rt.device, format, width, height, usage, .private) orelse return error.OutOfMemory
        else
            metal.newTexture2DLevels(rt.device, format, width, height, levels, usage, .private) orelse
                return error.OutOfMemory;
        return .{
            .texture = texture,
            .size = .{ .width = width, .height = height, .depth = 1 },
            .texel_bytes = texel_bytes,
            .levels = levels,
        };
    }

    /// The extent of mip level `level`.
    pub fn levelSize(self: *const Texture, level: u32) metal.Size {
        std.debug.assert(level < self.levels);
        const shift: u6 = @intCast(level);
        return .{ .width = @max(1, self.size.width >> shift), .height = @max(1, self.size.height >> shift), .depth = 1 };
    }

    pub fn deinit(self: *Texture) void {
        if (comptime !native_available) return;
        objc.release(self.texture);
        self.* = undefined;
    }
};

pub const Transfer = union(enum) {
    write: []const u8,
    read: []u8,
};

/// Copies every texel of mip `level` of `texture`, whose extent is `size`, to or from tightly
/// packed rows, through a shared staging buffer and a blit on the default stream, after the work
/// already queued there. It waits for the blit.
pub fn transferTexture(
    rt: *Runtime,
    texture: metal.Texture,
    size: metal.Size,
    level: u32,
    texel_bytes: u32,
    transfer: Transfer,
) runtime.Error!void {
    if (comptime !native_available) return error.UnsupportedPlatform;
    const bytes_per_row = size.width * texel_bytes;
    const byte_count: usize = @intCast(bytes_per_row * size.height);
    const length = switch (transfer) {
        .write => |bytes| bytes.len,
        .read => |bytes| bytes.len,
    };
    if (length != byte_count) return error.InvalidBuffer;
    var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
    defer pool.deinit();
    const staging = metal.newBuffer(rt.device, byte_count) orelse return error.OutOfMemory;
    defer objc.release(staging);
    const contents: [*]u8 = @ptrCast(metal.bufferContents(staging) orelse return error.RuntimeUnavailable);
    switch (transfer) {
        .write => |bytes| @memcpy(contents[0..byte_count], bytes),
        .read => {},
    }
    var submission = try Submission.begin(rt, null, &.{});
    const blit = metal.blitCommandEncoder(submission.command_buffer) orelse return error.LaunchFailed;
    switch (transfer) {
        .write => metal.copyBufferToTextureLevel(blit, staging, bytes_per_row, texture, size, level),
        .read => metal.copyTextureLevelToBuffer(blit, texture, size, level, staging, bytes_per_row),
    }
    metal.endBlitEncoding(blit);
    try submission.finish(null);
    try submission.stream.synchronize();
    switch (transfer) {
        .write => {},
        .read => |bytes| @memcpy(bytes, contents[0..byte_count]),
    }
}

pub const VertexLayout = struct {
    buffer_index: u32,
    stride: u32,
    per_instance: bool,
};

pub const VertexAttribute = struct {
    location: u32,
    format: metal.VertexFormat,
    offset: u32,
    buffer_index: u32,
};

pub const PipelineDesc = struct {
    library: LibrarySource,
    vertex_entry: []const u8,
    fragment_entry: []const u8,
    color_format: metal.PixelFormat,
    blend: ?metal.Blend,
    depth_format: ?metal.PixelFormat,
    layouts: []const VertexLayout,
    attributes: []const VertexAttribute,
    /// Whether indirect command buffers may set the pipeline. Metal refuses this for a shader that
    /// takes a texture as a direct argument.
    indirect: bool,
};

/// Builds a render pipeline. A failed compile or build leaves its message in the runtime's
/// compile log.
pub fn createPipelineState(rt: *Runtime, desc: PipelineDesc) runtime.Error!metal.RenderPipelineState {
    if (comptime !native_available) return error.UnsupportedPlatform;
    var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
    defer pool.deinit();
    const library = try rt.newLibrary(desc.library);
    defer objc.release(library);
    const vertex = try libraryFunction(library, desc.vertex_entry);
    defer objc.release(vertex);
    const fragment = try libraryFunction(library, desc.fragment_entry);
    defer objc.release(fragment);
    const vertex_descriptor = if (desc.layouts.len == 0) null else metal.vertexDescriptor() orelse
        return error.RuntimeUnavailable;
    if (vertex_descriptor) |descriptor| {
        for (desc.layouts) |layout| {
            metal.setVertexLayout(descriptor, layout.buffer_index, layout.stride, if (layout.per_instance) .per_instance else .per_vertex);
        }
        for (desc.attributes) |attribute| {
            metal.setVertexAttribute(descriptor, attribute.location, attribute.format, attribute.offset, attribute.buffer_index);
        }
    }
    var build_error: ?foundation.Error = null;
    return metal.newRenderPipelineState(rt.device, .{
        .vertex = vertex,
        .fragment = fragment,
        .vertex_descriptor = vertex_descriptor,
        .color_format = desc.color_format,
        .blend = desc.blend,
        .depth_format = desc.depth_format,
        .indirect = desc.indirect,
    }, &build_error) orelse {
        rt.recordCompileError(build_error);
        return error.CompilationFailed;
    };
}

fn libraryFunction(library: metal.Library, name: []const u8) runtime.Error!metal.Function {
    const name_string = foundation.stringFromBytes(name) orelse return error.InvalidArtifact;
    defer objc.release(name_string);
    return metal.newFunction(library, name_string) orelse error.InvalidArtifact;
}

pub fn createDepthState(rt: *Runtime, compare: metal.CompareFunction, write: bool) runtime.Error!metal.DepthStencilState {
    if (comptime !native_available) return error.UnsupportedPlatform;
    var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
    defer pool.deinit();
    return metal.newDepthStencilState(rt.device, compare, write) orelse error.OutOfMemory;
}

/// An indirect command buffer of `count` draws. The caller releases it.
pub fn createIndirectCommands(rt: *Runtime, count: u32) runtime.Error!metal.IndirectCommandBuffer {
    if (comptime !native_available) return error.UnsupportedPlatform;
    var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
    defer pool.deinit();
    return metal.newIndirectCommandBuffer(rt.device, count) orelse error.OutOfMemory;
}

/// A shared buffer the caller releases.
pub fn createSharedBuffer(rt: *Runtime, byte_size: usize) runtime.Error!metal.Buffer {
    if (comptime !native_available) return error.UnsupportedPlatform;
    var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
    defer pool.deinit();
    return metal.newBuffer(rt.device, byte_size) orelse error.OutOfMemory;
}

/// One command buffer on a stream: it waits for `waits` before its work, and `finish` signals an
/// event after it and commits it. The caller holds an autorelease pool from `begin` to `finish`.
pub const Submission = struct {
    stream: *runtime.Stream,
    command_buffer: metal.CommandBuffer,

    pub fn begin(rt: *Runtime, stream: ?*runtime.Stream, waits: []const *runtime.Event) runtime.Error!Submission {
        if (comptime !native_available) return error.UnsupportedPlatform;
        const actual = stream orelse try rt.defaultStream();
        if (actual.failed) return error.LaunchFailed;
        for (waits) |event| if (!event.recorded) return error.InvalidEvent;
        const command_buffer = metal.commandBuffer(actual.command_queue) orelse return error.LaunchFailed;
        for (waits) |event| metal.encodeWaitForEvent(command_buffer, event.event, event.value);
        return .{ .stream = actual, .command_buffer = command_buffer };
    }

    pub fn finish(self: *Submission, signal: ?*runtime.Event) runtime.Error!void {
        if (comptime !native_available) return error.UnsupportedPlatform;
        const signal_value = if (signal) |event| try event.reserveSignal() else 0;
        if (signal) |event| metal.encodeSignalEvent(self.command_buffer, event.event, signal_value);
        metal.commit(self.command_buffer);
        self.stream.replaceLastCommandBuffer(self.command_buffer);
        if (signal) |event| {
            event.value = signal_value;
            event.recorded = true;
            event.replaceCommandBuffer(self.command_buffer);
        }
    }
};

/// A `CAMetalLayer` over the Cocoa layer a window gave.
pub const Surface = struct {
    layer: metal.Layer,
    /// The command buffer that presented the last frame.
    presented: ?metal.CommandBuffer = null,

    pub fn create(
        rt: *Runtime,
        parent: objc.Id,
        format: metal.PixelFormat,
        width: u32,
        height: u32,
        max_drawables: u32,
        display_sync: bool,
    ) runtime.Error!Surface {
        if (comptime !native_available) return error.UnsupportedPlatform;
        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const layer = metal.newLayer(rt.device, format, max_drawables, display_sync) orelse return error.SurfaceUnavailable;
        metal.attachLayer(layer, parent, width, height);
        return .{ .layer = layer };
    }

    pub fn deinit(self: *Surface) void {
        if (comptime !native_available) return;
        if (self.presented) |command_buffer| {
            metal.waitUntilCompleted(command_buffer);
            objc.release(command_buffer);
        }
        metal.detachLayer(self.layer);
        objc.release(self.layer);
        self.* = undefined;
    }

    /// The layer's next drawable and its texture, both retained, or `FrameUnavailable` when none
    /// frees up within the layer's one-second timeout.
    pub fn acquire(self: *Surface) runtime.Error!Frame {
        if (comptime !native_available) return error.UnsupportedPlatform;
        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const drawable = metal.nextDrawable(self.layer) orelse return error.FrameUnavailable;
        const texture = metal.drawableTexture(drawable) orelse return error.FrameUnavailable;
        return .{ .drawable = objc.retain(drawable), .texture = objc.retain(texture) };
    }

    /// Presents `frame` after the work queued on the default stream and releases the frame.
    pub fn present(self: *Surface, rt: *Runtime, frame: *Frame, waits: []const *runtime.Event) runtime.Error!void {
        if (comptime !native_available) return error.UnsupportedPlatform;
        defer frame.release();
        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        var submission = try Submission.begin(rt, null, waits);
        metal.presentDrawable(submission.command_buffer, frame.drawable);
        try submission.finish(null);
        const retained = objc.retain(submission.command_buffer);
        if (self.presented) |previous| objc.release(previous);
        self.presented = retained;
    }
};

pub const Frame = struct {
    drawable: metal.Drawable,
    texture: metal.Texture,

    pub fn release(self: *Frame) void {
        if (comptime !native_available) return;
        objc.release(self.texture);
        objc.release(self.drawable);
        self.* = undefined;
    }
};
