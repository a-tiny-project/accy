//! The CPU reference rasterizer: the triangle pipeline of the gpu contract run on the host, one
//! fragment at a time, with vertex and fragment stages lowered by Choir to host functions over the
//! buffers `gpu_abi.stage` lays out.
//!
//! A fragment stage that takes derivatives reads its 2x2 quad, and the rasterizer walks quads for
//! it. It interpolates the four blocks of a quad once when some lane of it shades, helper lanes
//! the triangle does not cover included, extrapolating the same plane equations. It then calls the
//! stage once per shaded lane. Every other fragment stage runs one pixel at a time and
//! interpolates only the pixels it shades.
//!
//! It keeps the contract the Vulkan path keeps. Clip space puts x = −1 at the viewport's left edge
//! and y = −1 at its top edge, and a primitive keeps the part of it where 0 ≤ z ≤ w. The viewport
//! maps z onto [min_depth, max_depth]. Positions snap to 1/256 pixel, the precision Vulkan drivers
//! report as `subPixelPrecisionBits` = 8. A pixel is covered when its center lies inside a
//! triangle, a center on a shared edge goes to one triangle by the top-left rule, and no triangle
//! is culled. A triangle is front-facing when counter-clockwise, Vulkan's `a > 0` with
//! `frontFace = COUNTER_CLOCKWISE`. Depth interpolates linearly in screen space and every other
//! smooth word perspective-correctly; flat words come from the first vertex of each primitive.
//!
//! Fragments are tested against depth before shading, which equals testing after, since no stage
//! discards a fragment or writes its depth. A depth bias adds its offset to the interpolated depth,
//! computed per triangle from the snapped positions as `contract.RenderDepthBias` states, with
//! the slope `m` taken as `max(|dz/dx|, |dz/dy|)`. Blending runs in f32 on values decoded from the target
//! and clamped to [0, 1], and the result converts to 8-bit unorm by rounding to nearest.
//!
//! Beyond the view volume in x and y, triangles are clipped only against a guard band, and the
//! viewport bounds the pixels instead. Inside the band a clip leaves coverage where the viewport
//! would put it.

const std = @import("std");
const stage = @import("gpu_abi").stage;
const contract = @import("../../contract.zig");

/// A lowered vertex or fragment stage.
pub const Stage = *const fn (inputs: [*]const f32, outputs: [*]f32, context: *anyopaque) callconv(.c) void;
/// A lowered fragment stage that reads its quad, as `gpu_abi.stage.quad_suffix` states.
pub const QuadStage = *const fn (quad: [*]const f32, lane: usize, outputs: [*]f32, context: *anyopaque) callconv(.c) void;

/// A fragment stage, by the inputs it reads.
pub const Fragment = union(enum) {
    pixel: Stage,
    quad: QuadStage,
};

pub const max_vertex_buffers = 8;
pub const max_vertex_attributes = 16;
pub const max_bindings = 16;
/// Pixels a target spans at most on each side. At 1/256 pixel inside a guard band of `guard_band`
/// viewports, a snapped coordinate stays below 2^25 in magnitude, and an edge function product
/// below 2^51, well inside i64.
pub const max_extent = 16384;
/// How far past the viewport, in viewports, a triangle may reach before it is clipped in x or y.
const guard_band: f32 = 4;
/// Subpixel steps per pixel.
const subpixel: i64 = 256;
/// Clip planes: near, far and the four sides of the guard band. Each plane adds one vertex to a
/// polygon at most.
const clip_planes = 6;
const max_clipped = 3 + clip_planes;

pub const Texture = struct {
    width: u32,
    height: u32,
    format: contract.TextureFormat,
    /// Rows from the top, `format.texelBytes()` per texel.
    bytes: []align(4) u8,

    pub fn depths(self: *const Texture) []f32 {
        std.debug.assert(self.format == .depth32_float);
        return std.mem.bytesAsSlice(f32, self.bytes);
    }
};

/// One texture a stage samples, under the key its `sampled_texture` names.
pub const Sampled = struct {
    key: i32,
    texture: *const Texture,
    sampler: contract.RenderSampler,
};

/// One uniform buffer a stage reads, under its binding in group 0.
pub const Uniform = struct {
    binding: u32,
    bytes: []const u8,
};

/// What a draw's bindings name: the textures its samples read and the uniform buffers its block
/// reads reach.
pub const Resources = struct {
    sampled: []const Sampled = &.{},
    uniforms: []const Uniform = &.{},
};

/// What a stage's context points at: the words `gpu_abi.stage` lays out for block reads, then
/// the resources a sample finds from them. Each draw copies its push constants and the first
/// `uniform_window_bytes` of each uniform buffer in, and every other word reads zero: those past
/// its push constants, past a shorter buffer, and in the windows no binding fills. A read past a
/// buffer's end thus reads zero, as Vulkan's robust buffer access may. One frame serves every draw
/// of a backend and remembers how far each area was written, so a draw costs the bytes it copies
/// and the bytes the last draw left beyond them, not the whole frame.
pub const Frame = struct {
    words: [stage.context_words]f32 align(16),
    resources: *const Resources,
    /// Bytes of the push constants that may be nonzero.
    push_extent: u32 = 0,
    /// Bytes of each uniform window that may be nonzero.
    extents: [stage.uniform_bindings]u32 = @splat(0),

    /// A frame over `resources` with every word zero.
    pub fn init(resources: *const Resources) Frame {
        return .{ .words = @splat(0), .resources = resources };
    }

    /// The pointer a stage takes as its context.
    pub fn context(self: *Frame) *anyopaque {
        return @ptrCast(&self.words);
    }

    /// Copies a draw's push constants and uniform buffers in.
    pub fn fill(self: *Frame, resources: *const Resources, push_constants: []const u8) void {
        self.resources = resources;
        const push = std.mem.sliceAsBytes(self.words[stage.push..][0..stage.push_words]);
        std.debug.assert(push_constants.len <= push.len);
        const push_size: u32 = @intCast(push_constants.len);
        @memcpy(push[0..push_size], push_constants);
        if (self.push_extent > push_size) @memset(push[push_size..self.push_extent], 0);
        self.push_extent = push_size;
        var filled: u32 = 0;
        for (resources.uniforms) |uniform| {
            std.debug.assert(uniform.binding < stage.uniform_bindings);
            const bytes = self.window(uniform.binding);
            const size: u32 = @intCast(@min(uniform.bytes.len, bytes.len));
            @memcpy(bytes[0..size], uniform.bytes[0..size]);
            const extent = &self.extents[uniform.binding];
            if (extent.* > size) @memset(bytes[size..extent.*], 0);
            extent.* = size;
            filled |= @as(u32, 1) << @intCast(uniform.binding);
        }
        for (&self.extents, 0..) |*extent, binding| {
            if (filled & (@as(u32, 1) << @intCast(binding)) != 0) continue;
            if (extent.* == 0) continue;
            @memset(self.window(@intCast(binding))[0..extent.*], 0);
            extent.* = 0;
        }
    }

    fn window(self: *Frame, binding: u32) []u8 {
        const first = stage.uniformWord(binding, 0);
        return std.mem.sliceAsBytes(self.words[first..][0..stage.uniform_window_words]);
    }

    fn of(pointer: *anyopaque) *const Frame {
        const words: *[stage.context_words]f32 = @ptrCast(@alignCast(pointer));
        return @alignCast(@fieldParentPtr("words", words));
    }
};

pub const Attribute = struct {
    location: u32,
    format: contract.RenderVertexFormat,
    offset: u32,
};

pub const Layout = struct {
    stride: u32,
    per_instance: bool,
    attribute_start: u32,
    attribute_count: u32,
};

pub const Pipeline = struct {
    vertex: Stage,
    fragment: Fragment,
    blend: contract.RenderBlendMode,
    topology: contract.RenderPrimitiveTopology,
    depth: ?contract.RenderDepthState,
    target_format: contract.TextureFormat,
    layouts: []const Layout,
    attributes: []const Attribute,
};

pub const Indices = union(enum) {
    none,
    u16: []const u8,
    u32: []const u8,
};

/// One draw, with each vertex buffer already advanced to its bound offset.
pub const Draw = struct {
    pipeline: *const Pipeline,
    resources: *const Resources,
    vertex_buffers: []const []const u8,
    indices: Indices = .none,
    range: contract.RenderDrawRange,
    push_constants: []const u8 = &.{},
};

pub const Pass = struct {
    color: *Texture,
    depth: ?*Texture = null,
    viewport: contract.RenderViewport,
    scissor: contract.RenderScissor,
};

/// Work a rasterizer did: triangles set up after clipping, fragments shaded, and input blocks
/// interpolated. A pixel stage interpolates one block per fragment; a quad stage interpolates four
/// per quad with a shaded lane, which is its floor.
pub const Counters = struct {
    triangles: u64 = 0,
    fragments: u64 = 0,
    interpolations: u64 = 0,
};

/// The pixel rectangle [x0, x1) by [y0, y1) a pass may touch: viewport, scissor and target.
const Bounds = struct {
    x0: i64,
    y0: i64,
    x1: i64,
    y1: i64,

    /// A center on the viewport's left or top edge lies on a clipped triangle's left or top edge
    /// and is covered; one on its right or bottom edge is not.
    fn of(pass: Pass) ?Bounds {
        const viewport = pass.viewport;
        const scissor = pass.scissor;
        const bounds = Bounds{
            .x0 = @max(ceilPixel(viewport.x - 0.5), scissor.x, 0),
            .y0 = @max(ceilPixel(viewport.y - 0.5), scissor.y, 0),
            .x1 = @min(ceilPixel(viewport.x + viewport.width - 0.5), @as(i64, scissor.x) + scissor.width, pass.color.width),
            .y1 = @min(ceilPixel(viewport.y + viewport.height - 0.5), @as(i64, scissor.y) + scissor.height, pass.color.height),
        };
        if (bounds.x0 >= bounds.x1 or bounds.y0 >= bounds.y1) return null;
        return bounds;
    }
};

fn ceilPixel(value: f32) i64 {
    const limit: f32 = 2 * max_extent;
    return @intFromFloat(@ceil(std.math.clamp(value, -limit, limit)));
}

pub fn clearColor(target: *Texture, color: contract.SurfaceClearColor) void {
    const texel = encode(target.format, .{ color.r, color.g, color.b, color.a });
    const texels = std.mem.bytesAsSlice([4]u8, target.bytes);
    @memset(texels, texel);
}

pub fn clearDepth(target: *Texture, value: f32) void {
    @memset(target.depths(), value);
}

/// Runs one draw into `pass`, adding its work to `counters`. A vertex an index or range names
/// beyond the end of a vertex buffer reads zero in x, y and z and one in w, as Vulkan's robust
/// buffer access may.
pub fn draw(pass: Pass, request: *const Draw, frame: *Frame, counters: *Counters) void {
    const pipeline = request.pipeline;
    std.debug.assert(pipeline.target_format == pass.color.format);
    std.debug.assert((pipeline.depth != null) == (pass.depth != null));
    std.debug.assert(request.vertex_buffers.len == pipeline.layouts.len);
    const bounds = Bounds.of(pass) orelse return;
    const range = request.range;
    const count = if (request.indices == .none) range.vertex_count else range.index_count;
    const primitives: u32 = switch (pipeline.topology) {
        .triangle_list => count / 3,
        .triangle_strip => if (count < 3) 0 else count - 2,
        .line_list, .line_strip => unreachable,
    };

    frame.fill(request.resources, request.push_constants);
    var raster = Raster{
        .pass = pass,
        .bounds = bounds,
        .draw = request,
        .counters = counters,
        .depths = if (pass.depth) |target| target.depths() else &.{},
        .frame = frame,
    };
    for (0..range.instance_count) |instance_offset| {
        const instance = range.first_instance +% @as(u32, @intCast(instance_offset));
        for (0..primitives) |primitive| {
            const first: u32 = switch (pipeline.topology) {
                .triangle_list => @intCast(primitive * 3),
                else => @intCast(primitive),
            };
            const odd: u32 = if (pipeline.topology == .triangle_strip) first & 1 else 0;
            const order = [3]u32{ first, first + 1 + odd, first + 2 - odd };
            for (order, &raster.vertices) |element, *outputs| raster.shadeVertex(element, instance, outputs);
            raster.triangle();
        }
    }
}

const Raster = struct {
    pass: Pass,
    bounds: Bounds,
    draw: *const Draw,
    counters: *Counters,
    /// The depth target's texels, empty without one.
    depths: []f32,
    vertex_inputs: [stage.io_words]f32 = @splat(0),
    vertices: [3][stage.io_words]f32 = @splat(@splat(0)),
    /// One input block per lane of a quad. A pixel stage reads the first.
    fragment_inputs: [stage.quad_lanes][stage.io_words]f32 = @splat(@splat(0)),
    fragment_outputs: [stage.io_words]f32 = @splat(0),
    /// The smooth words the vertex stage writes, `smooth_count` of them.
    smooth: [stage.slot_words]u8 = undefined,
    smooth_count: u32 = 0,
    frame: *Frame,

    fn context(self: *Raster) *anyopaque {
        return self.frame.context();
    }

    fn shadeVertex(self: *Raster, element: u32, instance: u32, outputs: *[stage.io_words]f32) void {
        const request = self.draw;
        const vertex: i64 = switch (request.indices) {
            .none => @as(i64, request.range.first_vertex) + element,
            .u16 => |bytes| readIndex(u16, bytes, request.range.first_index +% element) + @as(i64, request.range.base_vertex),
            .u32 => |bytes| readIndex(u32, bytes, request.range.first_index +% element) + @as(i64, request.range.base_vertex),
        };
        const inputs = &self.vertex_inputs;
        inputs[stage.vertex_index] = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(vertex)))));
        inputs[stage.instance_index] = @bitCast(instance);
        for (request.pipeline.layouts, request.vertex_buffers) |layout, buffer| {
            const index: i64 = if (layout.per_instance) instance else vertex;
            const attributes = request.pipeline.attributes[layout.attribute_start..][0..layout.attribute_count];
            for (attributes) |attribute| fetch(inputs, attribute, buffer, index, layout.stride);
        }
        request.pipeline.vertex(inputs, outputs, self.context());
    }

    fn triangle(self: *Raster) void {
        const first = &self.vertices[0];
        const smooth_mask = mask(first, stage.smooth_mask_low);
        const flat_mask = mask(first, stage.flat_mask_low);
        self.smooth_count = 0;
        var bits = smooth_mask;
        while (bits != 0) : (bits &= bits - 1) {
            self.smooth[self.smooth_count] = @ctz(bits);
            self.smooth_count += 1;
        }
        bits = flat_mask;
        while (bits != 0) : (bits &= bits - 1) {
            const word = stage.flat + @as(u32, @ctz(bits));
            for (self.blocks()) |*inputs| inputs[word] = first[word];
        }

        var outside_all: u8 = clip_all;
        var outside_any: u8 = 0;
        var vertices: [3]Vertex = undefined;
        for (&self.vertices, &vertices) |*outputs, *vertex| {
            vertex.* = .{ .position = outputs[stage.position..][0..4].*, .smooth = outputs[stage.smooth..][0..stage.slot_words] };
            const code = outcode(vertex.position);
            outside_all &= code;
            outside_any |= code;
        }
        if (outside_all != 0) return;
        if (outside_any == 0) return self.setup(vertices);
        self.clipped(vertices);
    }

    /// Clips the triangle against every plane some vertex lies outside of, then draws the polygon
    /// left as a fan around its first vertex, which keeps the triangle's winding.
    fn clipped(self: *Raster, triangle_vertices: [3]Vertex) void {
        var storage: [2][max_clipped]ClipVertex = undefined;
        var polygon: []ClipVertex = storage[0][0..3];
        for (polygon, triangle_vertices) |*vertex, source| {
            vertex.position = source.position;
            for (self.smooth[0..self.smooth_count]) |word| vertex.smooth[word] = source.smooth[word];
        }
        var target: usize = 1;
        for (0..clip_planes) |plane| {
            polygon = self.clipPolygon(polygon, @intCast(plane), &storage[target]);
            target = 1 - target;
            if (polygon.len < 3) return;
        }
        for (1..polygon.len - 1) |index| {
            self.setup(.{ polygon[0].vertex(), polygon[index].vertex(), polygon[index + 1].vertex() });
        }
    }

    fn clipPolygon(self: *const Raster, polygon: []const ClipVertex, plane: u3, out: *[max_clipped]ClipVertex) []ClipVertex {
        var count: usize = 0;
        for (polygon, 0..) |current, index| {
            const next = polygon[(index + 1) % polygon.len];
            const d_current = distance(current.position, plane);
            const d_next = distance(next.position, plane);
            if (d_current >= 0) {
                out[count] = current;
                count += 1;
            }
            if ((d_current >= 0) != (d_next >= 0)) {
                const t = d_current / (d_current - d_next);
                const vertex = &out[count];
                for (&vertex.position, current.position, next.position) |*value, a, b| value.* = a + t * (b - a);
                for (self.smooth[0..self.smooth_count]) |word| {
                    vertex.smooth[word] = current.smooth[word] + t * (next.smooth[word] - current.smooth[word]);
                }
                count += 1;
            }
        }
        std.debug.assert(count <= max_clipped);
        return out[0..count];
    }

    fn setup(self: *Raster, input: [3]Vertex) void {
        var points: [3]Point = undefined;
        for (input, &points) |vertex, *point| {
            const w = vertex.position[3];
            if (!(w > 0)) return;
            const inverse_w = 1 / w;
            const viewport = self.pass.viewport;
            const x = viewport.x + (vertex.position[0] * inverse_w + 1) * viewport.width * 0.5;
            const y = viewport.y + (vertex.position[1] * inverse_w + 1) * viewport.height * 0.5;
            const z = viewport.min_depth + vertex.position[2] * inverse_w * (viewport.max_depth - viewport.min_depth);
            if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(z)) return;
            point.* = .{ .x = snap(x), .y = snap(y), .z = z, .inverse_w = inverse_w, .smooth = vertex.smooth };
        }
        var area = edge(points[1], points[2], points[0]);
        if (area == 0) return;
        const front = area < 0;
        if (front) {
            std.mem.swap(Point, &points[1], &points[2]);
            area = -area;
        }
        self.counters.triangles += 1;
        for (self.blocks()) |*inputs| inputs[stage.front_facing] = @bitCast(@as(u32, @intFromBool(front)));
        const offset = if (self.draw.pipeline.depth) |depth| depthOffset(points, depth.bias) else 0;
        self.cover(points, area, offset);
    }

    /// The input blocks the fragment stage reads: one, or a quad's four.
    fn blocks(self: *Raster) [][stage.io_words]f32 {
        return switch (self.draw.pipeline.fragment) {
            .pixel => self.fragment_inputs[0..1],
            .quad => &self.fragment_inputs,
        };
    }

    fn cover(self: *Raster, points: [3]Point, area: i64, depth_offset: f32) void {
        const x0 = @max(self.bounds.x0, pixelAtOrAfter(@min(points[0].x, points[1].x, points[2].x)));
        const x1 = @min(self.bounds.x1, pixelAtOrAfter(@max(points[0].x, points[1].x, points[2].x) + 1));
        const y0 = @max(self.bounds.y0, pixelAtOrAfter(@min(points[0].y, points[1].y, points[2].y)));
        const y1 = @min(self.bounds.y1, pixelAtOrAfter(@max(points[0].y, points[1].y, points[2].y) + 1));
        if (x0 >= x1 or y0 >= y1) return;

        var plane = Plane{
            .points = points,
            .inverse_area = 1 / @as(f32, @floatFromInt(area)),
            .deltas = undefined,
            .depth_offset = depth_offset,
            .depth_low = @min(self.pass.viewport.min_depth, self.pass.viewport.max_depth),
            .depth_high = @max(self.pass.viewport.min_depth, self.pass.viewport.max_depth),
        };
        for (self.smooth[0..self.smooth_count]) |word| {
            plane.deltas[0][word] = points[1].smooth[word] - points[0].smooth[word];
            plane.deltas[1][word] = points[2].smooth[word] - points[0].smooth[word];
        }
        const box = Box{ .x0 = x0, .x1 = x1, .y0 = y0, .y1 = y1 };
        switch (self.draw.pipeline.fragment) {
            .pixel => |fragment| self.coverPixels(&plane, box, fragment),
            .quad => |fragment| self.coverQuads(&plane, box, fragment),
        }
    }

    fn coverPixels(self: *Raster, plane: *const Plane, box: Box, fragment: Stage) void {
        const edges = plane.edgesAt(box.x0, box.y0);
        const inputs = &self.fragment_inputs[0];
        var y = box.y0;
        var row = edges;
        while (y < box.y1) : (y += 1) {
            var x = box.x0;
            var weights = [3]i64{ row[0].value, row[1].value, row[2].value };
            while (x < box.x1) : (x += 1) {
                defer for (&weights, edges) |*weight, e| {
                    weight.* += e.step_x;
                };
                if (!covers(edges, weights)) continue;
                const b = plane.barycentric(weights);
                const z = plane.depth(b);
                const pixel = self.pixelIndex(x, y);
                if (!self.depthTest(pixel, z)) continue;
                self.interpolate(plane, inputs, b, x, y, z);
                const outputs = self.clearedOutputs();
                fragment(inputs, outputs, self.context());
                self.shaded(pixel);
            }
            for (&row, edges) |*e, step| e.value += step.step_y;
        }
    }

    /// Walks the quads aligned to even pixels that meet `box`. A lane outside `box` or the
    /// triangle is a helper: interpolated for its neighbours' derivatives and never shaded.
    fn coverQuads(self: *Raster, plane: *const Plane, box: Box, fragment: QuadStage) void {
        const qx0 = box.x0 - @mod(box.x0, 2);
        const qy0 = box.y0 - @mod(box.y0, 2);
        const edges = plane.edgesAt(qx0, qy0);
        const quad: [*]const f32 = @ptrCast(&self.fragment_inputs);
        var y = qy0;
        var row = [3]i64{ edges[0].value, edges[1].value, edges[2].value };
        while (y < box.y1) : (y += 2) {
            var x = qx0;
            var origin = row;
            while (x < box.x1) : (x += 2) {
                defer for (&origin, edges) |*weight, e| {
                    weight.* += 2 * e.step_x;
                };
                var lanes: [stage.quad_lanes]Lane = undefined;
                var shading: u8 = 0;
                for (&lanes, 0..) |*lane, index| {
                    const dx: i64 = @intCast(index & 1);
                    const dy: i64 = @intCast(index >> 1);
                    lane.x = x + dx;
                    lane.y = y + dy;
                    for (&lane.weights, origin, edges) |*weight, base, e| weight.* = base + dx * e.step_x + dy * e.step_y;
                    lane.b = plane.barycentric(lane.weights);
                    lane.z = plane.depth(lane.b);
                    if (!box.contains(lane.x, lane.y) or !covers(edges, lane.weights)) continue;
                    if (!self.depthTest(self.pixelIndex(lane.x, lane.y), lane.z)) continue;
                    shading |= @as(u8, 1) << @intCast(index);
                }
                if (shading == 0) continue;
                for (lanes, &self.fragment_inputs) |lane, *inputs| self.interpolate(plane, inputs, lane.b, lane.x, lane.y, lane.z);
                for (lanes, 0..) |lane, index| {
                    if (shading & (@as(u8, 1) << @intCast(index)) == 0) continue;
                    const outputs = self.clearedOutputs();
                    fragment(quad, index, outputs, self.context());
                    self.shaded(self.pixelIndex(lane.x, lane.y));
                }
            }
            for (&row, edges) |*weight, e| weight.* += 2 * e.step_y;
        }
    }

    fn pixelIndex(self: *const Raster, x: i64, y: i64) usize {
        return @as(usize, @intCast(y)) * self.pass.color.width + @as(usize, @intCast(x));
    }

    /// Tests `z` against the stored depth and writes it on pass, when the pipeline has depth.
    fn depthTest(self: *Raster, pixel: usize, z: f32) bool {
        const depth = self.draw.pipeline.depth orelse return true;
        if (!compare(depth.compare, z, self.depths[pixel])) return false;
        if (depth.write) self.depths[pixel] = z;
        return true;
    }

    /// Fills the smooth words and `frag_coord` of `inputs` for the pixel at (x, y).
    fn interpolate(self: *Raster, plane: *const Plane, inputs: *[stage.io_words]f32, b: [3]f32, x: i64, y: i64, z: f32) void {
        const points = &plane.points;
        const q = [3]f32{ b[0] * points[0].inverse_w, b[1] * points[1].inverse_w, b[2] * points[2].inverse_w };
        const q_sum = q[0] + q[1] + q[2];
        const p1 = q[1] / q_sum;
        const p2 = q[2] / q_sum;
        for (self.smooth[0..self.smooth_count]) |word| {
            inputs[word] = points[0].smooth[word] + p1 * plane.deltas[0][word] + p2 * plane.deltas[1][word];
        }
        inputs[stage.frag_coord..][0..4].* = .{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, z, q_sum };
        self.counters.interpolations += 1;
    }

    fn clearedOutputs(self: *Raster) *[stage.io_words]f32 {
        const outputs = &self.fragment_outputs;
        outputs[stage.smooth..][0..4].* = @splat(0);
        return outputs;
    }

    /// Blends the color the fragment stage left in its outputs into `pixel`.
    fn shaded(self: *Raster, pixel: usize) void {
        self.counters.fragments += 1;
        const texels = std.mem.bytesAsSlice([4]u8, self.pass.color.bytes);
        const color = self.fragment_outputs[stage.smooth..][0..4].*;
        texels[pixel] = blend(self.draw.pipeline.blend, self.pass.color.format, color, texels[pixel]);
    }
};

/// The pixels a triangle's bounding box keeps inside a pass's bounds, [x0, x1) by [y0, y1).
const Box = struct {
    x0: i64,
    x1: i64,
    y0: i64,
    y1: i64,

    fn contains(self: Box, x: i64, y: i64) bool {
        return x >= self.x0 and x < self.x1 and y >= self.y0 and y < self.y1;
    }
};

/// A triangle's plane equations over its snapped vertices, from which every pixel, covered or a
/// helper, interpolates its depth and inputs.
const Plane = struct {
    points: [3]Point,
    inverse_area: f32,
    /// Each smooth word's change from the first vertex to the second and to the third.
    deltas: [2][stage.slot_words]f32,
    depth_offset: f32,
    depth_low: f32,
    depth_high: f32,

    fn edgesAt(self: *const Plane, x: i64, y: i64) [3]Edge {
        const center = Fixed{ .x = x * subpixel + subpixel / 2, .y = y * subpixel + subpixel / 2 };
        var edges: [3]Edge = undefined;
        for (&edges, 0..) |*e, index| e.* = .init(self.points[(index + 1) % 3], self.points[(index + 2) % 3], center);
        return edges;
    }

    fn barycentric(self: *const Plane, weights: [3]i64) [3]f32 {
        return .{
            @as(f32, @floatFromInt(weights[0])) * self.inverse_area,
            @as(f32, @floatFromInt(weights[1])) * self.inverse_area,
            @as(f32, @floatFromInt(weights[2])) * self.inverse_area,
        };
    }

    /// Depth interpolated in screen space, clamped to the viewport's range, then biased.
    fn depth(self: *const Plane, b: [3]f32) f32 {
        const points = &self.points;
        const interpolated = std.math.clamp(points[0].z + b[1] * (points[1].z - points[0].z) + b[2] * (points[2].z - points[0].z), self.depth_low, self.depth_high);
        return if (self.depth_offset == 0) interpolated else interpolated + self.depth_offset;
    }
};

/// One pixel of a quad: where it lies, its edge weights, and what it interpolates.
const Lane = struct {
    x: i64,
    y: i64,
    weights: [3]i64,
    b: [3]f32,
    z: f32,
};

/// Whether a pixel center with edge weights `weights` lies inside the triangle.
fn covers(edges: [3]Edge, weights: [3]i64) bool {
    return weights[0] + edges[0].bias >= 0 and weights[1] + edges[1].bias >= 0 and weights[2] + edges[2].bias >= 0;
}

/// The offset `bias` adds to a triangle's depths: `m * slope + r * constant`, clamped. `m` is the
/// larger of |dz/dx| and |dz/dy| over the snapped positions, and `r` is `2^(e - 23)` for `e` the
/// exponent of the largest vertex depth, or of the smallest normal f32 when every depth is zero.
/// The slope and step are formed in f64, where the snapped positions and f32 depths are exact.
fn depthOffset(points: [3]Point, bias: contract.RenderDepthBias) f32 {
    if (!bias.enabled()) return 0;
    const pixel: f64 = @floatFromInt(subpixel);
    const dx1 = @as(f64, @floatFromInt(points[1].x - points[0].x)) / pixel;
    const dy1 = @as(f64, @floatFromInt(points[1].y - points[0].y)) / pixel;
    const dx2 = @as(f64, @floatFromInt(points[2].x - points[0].x)) / pixel;
    const dy2 = @as(f64, @floatFromInt(points[2].y - points[0].y)) / pixel;
    const dz1: f64 = points[1].z - points[0].z;
    const dz2: f64 = points[2].z - points[0].z;
    const determinant = dx1 * dy2 - dx2 * dy1;
    std.debug.assert(determinant != 0);
    const dz_dx = (dz1 * dy2 - dz2 * dy1) / determinant;
    const dz_dy = (dx1 * dz2 - dx2 * dz1) / determinant;
    const slope = @max(@abs(dz_dx), @abs(dz_dy));
    const largest = @max(@abs(points[0].z), @abs(points[1].z), @abs(points[2].z));
    const exponent: i32 = if (largest == 0) -126 else std.math.frexp(largest).exponent - 1;
    const step = std.math.ldexp(@as(f64, 1), exponent - 23);
    const offset: f32 = @floatCast(slope * bias.slope + step * bias.constant);
    if (bias.clamp > 0) return @min(offset, bias.clamp);
    if (bias.clamp < 0) return @max(offset, bias.clamp);
    return offset;
}

const Vertex = struct {
    position: [4]f32,
    smooth: *const [stage.slot_words]f32,
};

const ClipVertex = struct {
    position: [4]f32,
    smooth: [stage.slot_words]f32,

    fn vertex(self: *const ClipVertex) Vertex {
        return .{ .position = self.position, .smooth = &self.smooth };
    }
};

const Point = struct {
    x: i64,
    y: i64,
    z: f32,
    inverse_w: f32,
    smooth: *const [stage.slot_words]f32,
};

const Fixed = struct { x: i64, y: i64 };

/// The edge function of the edge from `a` to `b` at a pixel center, with its steps between
/// neighboring centers. Inside a triangle wound with positive area, every edge function is
/// non-negative. `bias` is −1 on edges that are neither top nor left, so a center on such an edge
/// is outside.
const Edge = struct {
    value: i64,
    step_x: i64,
    step_y: i64,
    bias: i64,

    fn init(a: Point, b: Point, center: Fixed) Edge {
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const top_left = dy < 0 or (dy == 0 and dx > 0);
        return .{
            .value = dx * (center.y - a.y) - dy * (center.x - a.x),
            .step_x = -dy * subpixel,
            .step_y = dx * subpixel,
            .bias = if (top_left) 0 else -1,
        };
    }
};

/// Twice the signed area of the triangle `a`, `b`, `c` in snapped units, as the edge function of
/// `a` to `b` at `c`.
fn edge(a: Point, b: Point, c: Point) i64 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

fn snap(value: f32) i64 {
    return @intFromFloat(@round(value * @as(f32, @floatFromInt(subpixel))));
}

/// The first pixel whose center lies at or after the snapped coordinate `value`.
fn pixelAtOrAfter(value: i64) i64 {
    return std.math.divCeil(i64, value - subpixel / 2, subpixel) catch unreachable;
}

const clip_all: u8 = (1 << clip_planes) - 1;

fn distance(position: [4]f32, plane: u3) f32 {
    const x, const y, const z, const w = position;
    return switch (plane) {
        0 => z,
        1 => w - z,
        2 => x + guard_band * w,
        3 => guard_band * w - x,
        4 => y + guard_band * w,
        5 => guard_band * w - y,
        else => unreachable,
    };
}

/// One bit per plane the position lies outside of. A coordinate that is not a number lies outside
/// every plane.
fn outcode(position: [4]f32) u8 {
    var code: u8 = 0;
    for (0..clip_planes) |plane| {
        if (!(distance(position, @intCast(plane)) >= 0)) code |= @as(u8, 1) << @intCast(plane);
    }
    return code;
}

fn mask(outputs: *const [stage.io_words]f32, low_word: u32) u64 {
    const low: u32 = @bitCast(outputs[low_word]);
    const high: u32 = @bitCast(outputs[low_word + 1]);
    return @as(u64, high) << 32 | low;
}

fn readIndex(comptime T: type, bytes: []const u8, index: u32) i64 {
    const offset = @as(usize, index) * @sizeOf(T);
    if (offset + @sizeOf(T) > bytes.len) return -1;
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn fetch(inputs: *[stage.io_words]f32, attribute: Attribute, buffer: []const u8, index: i64, stride: u32) void {
    const components: u32, const float = switch (attribute.format) {
        .float32 => .{ 1, true },
        .float32x2 => .{ 2, true },
        .float32x3 => .{ 3, true },
        .float32x4 => .{ 4, true },
        .uint32 => .{ 1, false },
        .uint32x2 => .{ 2, false },
        .uint32x4 => .{ 4, false },
    };
    const one: u32 = if (float) @bitCast(@as(f32, 1)) else 1;
    var words = [4]u32{ 0, 0, 0, one };
    const offset = @as(i128, index) * stride + attribute.offset;
    if (offset >= 0 and offset + components * 4 <= buffer.len) {
        const start: usize = @intCast(offset);
        for (words[0..components], 0..) |*word, component| {
            word.* = std.mem.readInt(u32, buffer[start + component * 4 ..][0..4], .little);
        }
    }
    const slots = inputs[stage.slot(stage.smooth, attribute.location, 0)..][0..4];
    for (slots, words) |*slot, word| slot.* = @bitCast(word);
}

fn compare(op: contract.RenderCompare, fragment: f32, stored: f32) bool {
    return switch (op) {
        .never => false,
        .less => fragment < stored,
        .equal => fragment == stored,
        .less_equal => fragment <= stored,
        .greater => fragment > stored,
        .not_equal => fragment != stored,
        .greater_equal => fragment >= stored,
        .always => true,
    };
}

/// Combines a fragment's color with the target texel by the contract's equation for `mode`.
fn blend(mode: contract.RenderBlendMode, format: contract.TextureFormat, color: [4]f32, texel: [4]u8) [4]u8 {
    var source: [4]f32 = undefined;
    for (&source, color) |*value, channel| value.* = std.math.clamp(channel, 0, 1);
    if (mode == .replace) return encode(format, source);
    const destination = decode(format, texel);
    const alpha = source[3];
    var result: [4]f32 = undefined;
    for (&result, source, destination, 0..) |*value, s, d, channel| value.* = switch (mode) {
        .replace => unreachable,
        .alpha_premultiplied => s + d * (1 - alpha),
        .alpha_straight => if (channel == 3) alpha + d * (1 - alpha) else s * alpha + d * (1 - alpha),
        .additive => s + d,
    };
    return encode(format, result);
}

/// A texel's channels in red, green, blue, alpha order, linear for sRGB formats.
fn decode(format: contract.TextureFormat, texel: [4]u8) [4]f32 {
    const ordered: [4]u8 = switch (format) {
        .bgra8_unorm, .bgra8_srgb => .{ texel[2], texel[1], texel[0], texel[3] },
        else => texel,
    };
    var value: [4]f32 = undefined;
    for (&value, ordered) |*channel, byte| channel.* = @as(f32, @floatFromInt(byte)) / 255;
    switch (format) {
        .rgba8_srgb, .bgra8_srgb => for (value[0..3]) |*channel| {
            channel.* = srgbToLinear(channel.*);
        },
        .depth32_float => {
            value = .{ @bitCast(texel), 0, 0, 1 };
        },
        .rgba8_unorm, .bgra8_unorm => {},
    }
    return value;
}

fn encode(format: contract.TextureFormat, color: [4]f32) [4]u8 {
    var value = color;
    switch (format) {
        .rgba8_srgb, .bgra8_srgb => for (value[0..3]) |*channel| {
            channel.* = linearToSrgb(std.math.clamp(channel.*, 0, 1));
        },
        .depth32_float => return @bitCast(color[0]),
        .rgba8_unorm, .bgra8_unorm => {},
    }
    var bytes: [4]u8 = undefined;
    for (&bytes, value) |*byte, channel| {
        const clamped = if (channel > 0) @min(channel, 1) else 0;
        byte.* = @intFromFloat(@round(clamped * 255));
    }
    return switch (format) {
        .bgra8_unorm, .bgra8_srgb => .{ bytes[2], bytes[1], bytes[0], bytes[3] },
        else => bytes,
    };
}

fn srgbToLinear(value: f32) f32 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(value: f32) f32 {
    return if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f32, value, 1.0 / 2.4) - 0.055;
}

/// The function a lowered stage calls for `sample` and `sample_lod`, under
/// `gpu_abi.stage.sample_symbol`. A texture has one level, so the level of detail is ignored,
/// and a key no binding names samples zero. Once textures gain levels, or separate filters for
/// minifying and magnifying, an implicit-level `sample` needs its coordinates' derivatives to
/// choose between them, and the stage lowering must refuse it by name until it computes them.
pub fn sample(context: *anyopaque, key: i32, outputs: [*]f32) callconv(.c) void {
    const resources = Frame.of(context).resources;
    const u = outputs[stage.sample];
    const v = outputs[stage.sample + 1];
    const texel = for (resources.sampled) |sampled| {
        if (sampled.key == key) break filter(sampled, u, v);
    } else @as([4]f32, @splat(0));
    outputs[stage.sample..][0..4].* = texel;
}

/// Nearest reads the texel holding (u, v); linear weighs the four texels around it by their
/// distance from (u·width − ½, v·height − ½), in f32. A GPU quantizes that weight to
/// `subTexelPrecisionBits` (8 on common drivers), so linear results may differ from a GPU's by
/// a step of 8-bit unorm.
fn filter(sampled: Sampled, u: f32, v: f32) [4]f32 {
    const texture = sampled.texture;
    const address = sampled.sampler.address;
    switch (sampled.sampler.filter) {
        .nearest => {
            const x = wrap(floorIndex(u * @as(f32, @floatFromInt(texture.width))), texture.width, address);
            const y = wrap(floorIndex(v * @as(f32, @floatFromInt(texture.height))), texture.height, address);
            return texelAt(texture, x, y);
        },
        .linear => {
            const fx = u * @as(f32, @floatFromInt(texture.width)) - 0.5;
            const fy = v * @as(f32, @floatFromInt(texture.height)) - 0.5;
            const ix = floorIndex(fx);
            const iy = floorIndex(fy);
            const ax = if (std.math.isFinite(fx)) fx - @floor(fx) else 0;
            const ay = if (std.math.isFinite(fy)) fy - @floor(fy) else 0;
            const x0 = wrap(ix, texture.width, address);
            const x1 = wrap(ix + 1, texture.width, address);
            const y0 = wrap(iy, texture.height, address);
            const y1 = wrap(iy + 1, texture.height, address);
            const t00 = texelAt(texture, x0, y0);
            const t10 = texelAt(texture, x1, y0);
            const t01 = texelAt(texture, x0, y1);
            const t11 = texelAt(texture, x1, y1);
            var value: [4]f32 = undefined;
            for (&value, t00, t10, t01, t11) |*channel, a, b, c, d| {
                const top = a + ax * (b - a);
                const bottom = c + ax * (d - c);
                channel.* = top + ay * (bottom - top);
            }
            return value;
        },
    }
}

/// The floor of `value` as a texel index, held to ±2^30 so every index a wrap reads fits in i64;
/// a value that is not a number reads index zero.
fn floorIndex(value: f32) i64 {
    if (std.math.isNan(value)) return 0;
    const limit: f32 = 1 << 30;
    return @intFromFloat(@floor(std.math.clamp(value, -limit, limit)));
}

fn wrap(index: i64, size: u32, address: contract.RenderAddressMode) u32 {
    return switch (address) {
        .clamp_to_edge => @intCast(std.math.clamp(index, 0, @as(i64, size) - 1)),
        .repeat => @intCast(@mod(index, @as(i64, size))),
    };
}

fn texelAt(texture: *const Texture, x: u32, y: u32) [4]f32 {
    std.debug.assert(x < texture.width);
    std.debug.assert(y < texture.height);
    const index = @as(usize, y) * texture.width + x;
    return decode(texture.format, texture.bytes[index * 4 ..][0..4].*);
}

comptime {
    std.debug.assert(stage.slot_words <= std.math.maxInt(u8) + 1);
    std.debug.assert(max_vertex_attributes <= stage.max_locations);
}

const testing = std.testing;

/// A vertex stage over the fixture layout: position at location 0 with w = 1, and location 1
/// passed on as smooth location 0.
fn testVertex(inputs: [*]const f32, outputs: [*]f32, _: *anyopaque) callconv(.c) void {
    outputs[stage.smooth_mask_low] = @bitCast(@as(u32, 0xf));
    outputs[stage.smooth_mask_high] = @bitCast(@as(u32, 0));
    outputs[stage.flat_mask_low] = @bitCast(@as(u32, 0));
    outputs[stage.flat_mask_high] = @bitCast(@as(u32, 0));
    outputs[stage.position..][0..4].* = .{ inputs[0], inputs[1], inputs[2], inputs[3] };
    for (0..4) |component| outputs[stage.smooth + component] = inputs[stage.slot(stage.smooth, 1, @intCast(component))];
}

/// A fragment stage writing its smooth location 0 as its color.
fn testFragment(inputs: [*]const f32, outputs: [*]f32, _: *anyopaque) callconv(.c) void {
    for (0..4) |component| outputs[stage.smooth + component] = inputs[stage.smooth + component];
}

/// A fragment stage writing red when front-facing and blue otherwise.
fn facingFragment(inputs: [*]const f32, outputs: [*]f32, _: *anyopaque) callconv(.c) void {
    const front: u32 = @bitCast(inputs[stage.front_facing]);
    outputs[stage.smooth..][0..4].* = if (front != 0) .{ 1, 0, 0, 1 } else .{ 0, 0, 1, 1 };
}

/// A fragment stage sampling binding 0 of group 0 at its smooth location 0.
fn sampleFragment(inputs: [*]const f32, outputs: [*]f32, context: *anyopaque) callconv(.c) void {
    outputs[stage.sample] = inputs[stage.smooth];
    outputs[stage.sample + 1] = inputs[stage.smooth + 1];
    outputs[stage.sample + 2] = 0;
    sample(context, stage.textureKey(0, 0), outputs);
    for (0..4) |component| outputs[stage.smooth + component] = outputs[stage.sample + component];
}

/// A quad stage writing the fine dpdx of smooth word 0 as red and the fine dpdy of smooth word 1
/// as green: the odd lane's value minus the even lane's, in the fragment's own row or column.
fn derivativeFragment(quad: [*]const f32, lane: usize, outputs: [*]f32, _: *anyopaque) callconv(.c) void {
    const row = lane & 2;
    const column = lane & 1;
    const dx = quad[(row | 1) * stage.io_words + stage.smooth] - quad[row * stage.io_words + stage.smooth];
    const dy = quad[(2 | column) * stage.io_words + stage.smooth + 1] - quad[column * stage.io_words + stage.smooth + 1];
    outputs[stage.smooth..][0..4].* = .{ dx, dy, 0, 1 };
}

const TestVertex = extern struct {
    position: [4]f32,
    color: [4]f32,
};

const test_layouts = [_]Layout{.{ .stride = @sizeOf(TestVertex), .per_instance = false, .attribute_start = 0, .attribute_count = 2 }};
const test_attributes = [_]Attribute{
    .{ .location = 0, .format = .float32x4, .offset = 0 },
    .{ .location = 1, .format = .float32x4, .offset = 16 },
};

const TestTarget = struct {
    color_bytes: [16 * 16 * 4]u8 align(4) = @splat(0),
    depth_bytes: [16 * 16 * 4]u8 align(4) = @splat(0),
    color: Texture = undefined,
    depth: Texture = undefined,

    fn init(self: *TestTarget, size: u32) void {
        std.debug.assert(size <= 16);
        self.color = .{ .width = size, .height = size, .format = .rgba8_unorm, .bytes = self.color_bytes[0 .. size * size * 4] };
        self.depth = .{ .width = size, .height = size, .format = .depth32_float, .bytes = self.depth_bytes[0 .. size * size * 4] };
    }

    fn pass(self: *TestTarget, with_depth: bool) Pass {
        const size: f32 = @floatFromInt(self.color.width);
        return .{
            .color = &self.color,
            .depth = if (with_depth) &self.depth else null,
            .viewport = .{ .width = size, .height = size },
            .scissor = .{ .width = self.color.width, .height = self.color.height },
        };
    }

    fn texel(self: *const TestTarget, x: u32, y: u32) [4]u8 {
        return std.mem.bytesAsSlice([4]u8, self.color.bytes)[y * self.color.width + x];
    }
};

/// A vertex at pixel (x, y) of a `size`-pixel square target.
fn at(size: f32, x: f32, y: f32, z: f32, color: [4]f32) TestVertex {
    return .{ .position = .{ x / size * 2 - 1, y / size * 2 - 1, z, 1 }, .color = color };
}

fn testPipeline(fragment: Fragment, blend_mode: contract.RenderBlendMode, depth: ?contract.RenderDepthState) Pipeline {
    return .{
        .vertex = testVertex,
        .fragment = fragment,
        .blend = blend_mode,
        .topology = .triangle_list,
        .depth = depth,
        .target_format = .rgba8_unorm,
        .layouts = &test_layouts,
        .attributes = &test_attributes,
    };
}

fn drawVertices(pass: Pass, pipeline: *const Pipeline, resources: *const Resources, vertices: []const TestVertex, counters: *Counters) void {
    const buffers = [_][]const u8{std.mem.sliceAsBytes(vertices)};
    var frame = Frame.init(resources);
    draw(pass, &.{
        .pipeline = pipeline,
        .resources = resources,
        .vertex_buffers = &buffers,
        .range = .{ .vertex_count = @intCast(vertices.len) },
    }, &frame, counters);
}

test "triangles sharing edges cover each pixel center once" {
    var target: TestTarget = .{};
    target.init(16);
    clearColor(&target.color, .{ .a = 0 });
    const pipeline = testPipeline(.{ .pixel = testFragment }, .additive, null);
    const step: [4]f32 = .{ 1.0 / 255.0, 0, 0, 0 };
    const size = 16;
    const vertices = [_]TestVertex{
        at(size, 0, 0, 0, step),   at(size, 16, 0, 0, step),  at(size, 8, 8, 0, step),
        at(size, 16, 0, 0, step),  at(size, 16, 16, 0, step), at(size, 8, 8, 0, step),
        at(size, 16, 16, 0, step), at(size, 0, 16, 0, step),  at(size, 8, 8, 0, step),
        at(size, 0, 16, 0, step),  at(size, 0, 0, 0, step),   at(size, 8, 8, 0, step),
    };
    var counters: Counters = .{};
    drawVertices(target.pass(false), &pipeline, &.{}, &vertices, &counters);
    for (0..16) |y| {
        for (0..16) |x| try testing.expectEqual(@as(u8, 1), target.texel(@intCast(x), @intCast(y))[0]);
    }
    try testing.expectEqual(@as(u64, 256), counters.fragments);
    try testing.expectEqual(@as(u64, 256), counters.interpolations);
    try testing.expectEqual(@as(u64, 4), counters.triangles);
}

test "a quad stage reads helper lanes past a triangle's edge and past an odd-width target" {
    var target: TestTarget = .{};
    target.init(7);
    clearColor(&target.color, .{ .a = 0 });
    const pipeline = testPipeline(.{ .quad = derivativeFragment }, .replace, null);
    const vertices = [_]TestVertex{
        at(7, 0, 0, 0, .{ 0, 0, 0, 0 }), at(7, 0, 9.5, 0, .{ 0, 2.375, 0, 0 }), at(7, 9.5, 0, 0, .{ 1.1875, 0, 0, 0 }),
    };
    var counters: Counters = .{};
    drawVertices(target.pass(false), &pipeline, &.{}, &vertices, &counters);
    for (0..7) |y| {
        for (0..7) |x| {
            const expected: [4]u8 = if (x + y <= 8) .{ 32, 64, 0, 255 } else @splat(0);
            try testing.expectEqual(expected, target.texel(@intCast(x), @intCast(y)));
        }
    }
    try testing.expectEqual(@as(u64, 39), counters.fragments);
    try testing.expectEqual(@as(u64, 13 * 4), counters.interpolations);
}

test "front faces are counter-clockwise on screen and neither face is culled" {
    var target: TestTarget = .{};
    target.init(8);
    clearColor(&target.color, .{ .a = 0 });
    const pipeline = testPipeline(.{ .pixel = facingFragment }, .replace, null);
    const white: [4]f32 = @splat(1);
    const counter_clockwise = [_]TestVertex{ at(8, 0, 0, 0, white), at(8, 0, 4, 0, white), at(8, 8, 0, 0, white) };
    const clockwise = [_]TestVertex{ at(8, 0, 8, 0, white), at(8, 8, 4, 0, white), at(8, 8, 8, 0, white) };
    var counters: Counters = .{};
    drawVertices(target.pass(false), &pipeline, &.{}, &counter_clockwise, &counters);
    drawVertices(target.pass(false), &pipeline, &.{}, &clockwise, &counters);
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.texel(0, 0));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, target.texel(7, 7));
}

test "a strip alternates vertex order so every triangle keeps the first one's winding" {
    var target: TestTarget = .{};
    target.init(8);
    clearColor(&target.color, .{ .a = 0 });
    var pipeline = testPipeline(.{ .pixel = facingFragment }, .replace, null);
    pipeline.topology = .triangle_strip;
    const white: [4]f32 = @splat(1);
    const strip = [_]TestVertex{ at(8, 0, 0, 0, white), at(8, 0, 8, 0, white), at(8, 4, 0, 0, white), at(8, 4, 8, 0, white), at(8, 8, 0, 0, white) };
    var counters: Counters = .{};
    drawVertices(target.pass(false), &pipeline, &.{}, &strip, &counters);
    try testing.expectEqual(@as(u64, 3), counters.triangles);
    for ([_][2]u32{ .{ 0, 0 }, .{ 3, 6 }, .{ 5, 1 } }) |pixel| {
        try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.texel(pixel[0], pixel[1]));
    }
}

test "depth tests the fragment against the stored depth and writes on pass" {
    var target: TestTarget = .{};
    target.init(4);
    clearColor(&target.color, .{ .a = 0 });
    clearDepth(&target.depth, 1);
    const pipeline = testPipeline(.{ .pixel = testFragment }, .replace, .{ .compare = .less, .write = true });
    const red: [4]f32 = .{ 1, 0, 0, 1 };
    const green: [4]f32 = .{ 0, 1, 0, 1 };
    const near = [_]TestVertex{ at(4, 0, 0, 0.25, red), at(4, 0, 8, 0.25, red), at(4, 8, 0, 0.25, red) };
    const far = [_]TestVertex{ at(4, 0, 0, 0.75, green), at(4, 0, 8, 0.75, green), at(4, 8, 0, 0.75, green) };
    var counters: Counters = .{};
    drawVertices(target.pass(true), &pipeline, &.{}, &near, &counters);
    drawVertices(target.pass(true), &pipeline, &.{}, &far, &counters);
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.texel(2, 2));
    try testing.expectEqual(@as(f32, 0.25), target.depth.depths()[2 * 4 + 2]);
}

test "blend modes follow the contract's equations" {
    const color: [4]f32 = .{ 0.4, 0.4, 0, 0.6 };
    const texel: [4]u8 = .{ 0, 100, 200, 255 };
    try testing.expectEqual([4]u8{ 102, 102, 0, 153 }, blend(.replace, .rgba8_unorm, color, texel));
    try testing.expectEqual([4]u8{ 102, 142, 80, 255 }, blend(.alpha_premultiplied, .rgba8_unorm, color, texel));
    try testing.expectEqual([4]u8{ 61, 101, 80, 255 }, blend(.alpha_straight, .rgba8_unorm, color, texel));
    try testing.expectEqual([4]u8{ 102, 202, 200, 255 }, blend(.additive, .rgba8_unorm, color, texel));
    try testing.expectEqual([4]u8{ 0, 102, 102, 153 }, blend(.replace, .bgra8_unorm, color, texel));
}

test "a triangle crossing the near plane keeps the part in front of it" {
    var target: TestTarget = .{};
    target.init(8);
    clearColor(&target.color, .{ .a = 0 });
    const pipeline = testPipeline(.{ .pixel = testFragment }, .replace, null);
    const white: [4]f32 = @splat(1);
    const vertices = [_]TestVertex{
        .{ .position = .{ -1, -1, -1, 1 }, .color = white },
        .{ .position = .{ -1, 1, 1, 1 }, .color = white },
        .{ .position = .{ 1, -1, 1, 1 }, .color = white },
    };
    var counters: Counters = .{};
    drawVertices(target.pass(false), &pipeline, &.{}, &vertices, &counters);
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, target.texel(0, 0));
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, target.texel(1, 5));
    try testing.expectEqual(@as(u64, 2), counters.triangles);
}

test "samplers read the nearest or weighed texels and wrap by address mode" {
    var bytes: [16]u8 align(4) = .{ 0, 0, 0, 255, 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255 };
    const texture = Texture{ .width = 2, .height = 2, .format = .rgba8_unorm, .bytes = &bytes };
    const nearest = Sampled{ .key = 0, .texture = &texture, .sampler = .{} };
    try testing.expectEqual([4]f32{ 1, 0, 0, 1 }, filter(nearest, 0.75, 0.25));
    try testing.expectEqual([4]f32{ 1, 0, 0, 1 }, filter(nearest, 7, -3));
    const repeat = Sampled{ .key = 0, .texture = &texture, .sampler = .{ .address = .repeat } };
    try testing.expectEqual([4]f32{ 0, 0, 1, 1 }, filter(repeat, 1.75, 1.75));
    const linear = Sampled{ .key = 0, .texture = &texture, .sampler = .{ .filter = .linear } };
    try testing.expectEqual([4]f32{ 0.25, 0.25, 0.25, 1 }, filter(linear, 0.5, 0.5));

    var target: TestTarget = .{};
    target.init(2);
    const pipeline = testPipeline(.{ .pixel = sampleFragment }, .replace, null);
    const sampled = [_]Sampled{nearest};
    const resources = Resources{ .sampled = &sampled };
    const vertices = [_]TestVertex{
        at(2, 0, 0, 0, .{ 0, 0, 0, 0 }), at(2, 0, 4, 0, .{ 0, 2, 0, 0 }), at(2, 4, 0, 0, .{ 2, 0, 0, 0 }),
    };
    var counters: Counters = .{};
    drawVertices(target.pass(false), &pipeline, &resources, &vertices, &counters);
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, target.texel(0, 0));
    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, target.texel(1, 0));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, target.texel(1, 1));
}

fn biasPoint(x: i64, y: i64, z: f32) Point {
    const no_smooth: [stage.slot_words]f32 = @splat(0);
    return .{ .x = x * subpixel, .y = y * subpixel, .z = z, .inverse_w = 1, .smooth = &no_smooth };
}

test "depth bias steps by the exponent of the largest depth and scales the steeper slope" {
    const flat = [3]Point{ biasPoint(0, 0, 0.5), biasPoint(8, 0, 0.5), biasPoint(0, 8, 0.5) };
    try testing.expectEqual(@as(f32, -0x1p-20), depthOffset(flat, .{ .constant = -16 }));
    try testing.expectEqual(@as(f32, 0), depthOffset(flat, .{ .slope = 3 }));
    const sloped = [3]Point{ biasPoint(0, 0, 0.25), biasPoint(8, 0, 0.5), biasPoint(0, 8, 0.25) };
    try testing.expectEqual(@as(f32, -0x1p-15), depthOffset(sloped, .{ .slope = -0x1p-10 }));
    try testing.expectEqual(@as(f32, -0x1p-20), depthOffset(sloped, .{ .slope = -1, .clamp = -0x1p-20 }));
    try testing.expectEqual(@as(f32, 0x1p-20), depthOffset(sloped, .{ .slope = 1, .clamp = 0x1p-20 }));
    try testing.expectEqual(@as(f32, 1.0 / 32.0), depthOffset(sloped, .{ .slope = 1 }));
    const steeper = [3]Point{ biasPoint(0, 0, 0.25), biasPoint(8, 0, 0.5), biasPoint(0, 8, 0.75) };
    try testing.expectEqual(@as(f32, 1.0 / 16.0), depthOffset(steeper, .{ .slope = 1 }));
    const zero = [3]Point{ biasPoint(0, 0, 0), biasPoint(8, 0, 0), biasPoint(0, 8, 0) };
    try testing.expectEqual(@as(f32, 0x1p-149), depthOffset(zero, .{ .constant = 1 }));
}

test "a frame zeroes the words a draw does not supply" {
    const push = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const long: [8]u8 = @splat(0xff);
    const short: [4]u8 = @splat(0x11);
    const zeros: [4]u8 = @splat(0);
    const both = [_]Uniform{ .{ .binding = 1, .bytes = &long }, .{ .binding = 3, .bytes = &long } };
    const one = [_]Uniform{.{ .binding = 3, .bytes = &short }};
    var frame = Frame.init(&.{});
    frame.fill(&.{ .uniforms = &both }, &push);
    const words = std.mem.sliceAsBytes(&frame.words);
    try testing.expectEqualSlices(u8, &push, words[0..8]);
    try testing.expectEqualSlices(u32, &.{ 0, 8, 0, 8, 0, 0, 0, 0 }, &frame.extents);
    frame.fill(&.{ .uniforms = &one }, push[0..4]);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 4, 0, 0, 0, 0 }, &frame.extents);
    try testing.expectEqual(@as(u32, 4), frame.push_extent);
    try testing.expectEqualSlices(u8, &(push[0..4].* ++ zeros), words[0..8]);
    const window_bytes = stage.uniform_window_bytes;
    const third = words[stage.uniformWord(3, 0) * 4 ..][0..window_bytes];
    try testing.expectEqualSlices(u8, &(short ++ zeros), third[0..8]);
    for (std.mem.sliceAsBytes(&frame.words)[stage.uniformWord(1, 0) * 4 ..][0..window_bytes]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}
