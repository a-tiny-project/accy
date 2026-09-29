//! Scenes for a triangle rasterizer, each with the texels and depths a correct rasterizer leaves.
//!
//! A scene draws with one of two stage modules. In `textured` a vertex carries a position, a
//! texture coordinate and a color, and a fragment writes the nearest texel at its coordinate times
//! its color. In `pushed` a vertex scales and translates its position by push constants, and a
//! fragment multiplies its color by a uniform color, a uniform tint and a push-constant factor.
//! Positions are clip coordinates with w = 1: x grows right, y grows down, and z is the depth the
//! viewport maps onto [0, 1]. The scenes place vertices at pixel coordinates through `at`, so each
//! expectation reads in pixels.
//!
//! An expectation lists regions; a pixel takes the first region that holds its center, or the
//! scene's clear value. Colors are bytes k/255 throughout, so a draw without blending lands on
//! its exact byte. A factor of 1/2 or 1/4 keeps that exactness on bytes it divides, since scaling
//! by a power of two commutes with rounding to f32. A blend multiplies by a fractional alpha, and a
//! conversion to 8-bit unorm may round its exact result either way, so blended regions allow one
//! step either side.
//!
//! Depths are dyadic, and so are the depth biases the decal scenes apply, so each biased depth
//! is exact in f32 and every backend must match it exactly.

const gpu = @import("gpu");

pub const Vertex = extern struct {
    position: [3]f32,
    uv: [2]f32,
    color: [4]f32,
};

/// Bytes between consecutive vertices, and where each attribute starts in one.
pub const vertex_stride: u32 = @sizeOf(Vertex);
pub const position_offset: u32 = @offsetOf(Vertex, "position");
pub const uv_offset: u32 = @offsetOf(Vertex, "uv");
pub const color_offset: u32 = @offsetOf(Vertex, "color");

/// The interface of the `textured` stage module. `pushed` reads the same position and color
/// locations and no texture coordinate.
pub const position_location: u32 = 0;
pub const uv_location: u32 = 1;
pub const color_location: u32 = 2;
pub const texture_binding: u32 = 0;
/// The uniform buffer `pushed` reads, in group 0.
pub const uniform_binding: u32 = 1;

pub const ModuleKind = enum { textured, pushed };

/// The push constants of `pushed`: a vertex's position becomes `position * scale + translate` in
/// x and y, and a fragment's red, green and blue are multiplied by `factor`.
pub const Push = extern struct {
    translate: [2]f32 = .{ 0, 0 },
    scale: f32 = 1,
    factor: f32 = 1,
};

/// The uniform buffer of `pushed`, laid out as std140 places a vec3, a float and a vec4. A
/// fragment's red, green and blue are multiplied by `rgb` and `tint`, and its alpha by `alpha`
/// and the tint's.
pub const Uniform = extern struct {
    rgb: [3]f32 = .{ 1, 1, 1 },
    alpha: f32 = 1,
    tint: [4]f32 = .{ 1, 1, 1, 1 },
};

/// How one pipeline of a scene draws. An instanced pipeline reads its color per instance from the
/// scene's `instance_colors` instead of per vertex. A `pushed` pipeline reads the scene's uniform
/// and each draw's push constants.
pub const Pipeline = struct {
    module: ModuleKind = .textured,
    blend: gpu.RenderBlendMode = .replace,
    depth: ?gpu.RenderDepthState = null,
    instanced: bool = false,
};

pub const Indexed = struct {
    format: gpu.RenderIndexFormat,
    first_index: u32,
    index_count: u32,
    base_vertex: i32 = 0,
};

pub const Draw = struct {
    pipeline: u32 = 0,
    first_vertex: u32 = 0,
    vertex_count: u32 = 0,
    indexed: ?Indexed = null,
    instance_count: u32 = 1,
    push: Push = .{},
};

pub const Texture = struct {
    width: u32,
    height: u32,
    /// Rows from the top, texels from the left.
    texels: []const [4]u8,
};

pub const Region = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    rgba: [4]u8,
    /// Steps of 1/255 a channel may differ by.
    tolerance: u8 = 0,
};

pub const DepthRegion = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    depth: f32,
};

pub const Scene = struct {
    name: []const u8,
    width: u32,
    height: u32,
    clear: [4]u8 = .{ 0, 0, 0, 0 },
    /// Present exactly when the scene draws with a depth attachment, cleared to this value.
    depth_clear: ?f32 = null,
    texture: Texture = white,
    pipelines: []const Pipeline,
    vertices: []const Vertex,
    instance_colors: []const [4]f32 = &.{},
    indices16: []const u16 = &.{},
    indices32: []const u32 = &.{},
    uniform: Uniform = .{},
    draws: []const Draw,
    expected: []const Region,
    expected_depth: []const DepthRegion = &.{},

    /// The color a correct rasterizer leaves at pixel (x, y) and the steps it may differ by.
    pub fn expectedColor(self: Scene, x: u32, y: u32) struct { [4]u8, u8 } {
        for (self.expected) |region| {
            if (x >= region.x0 and x < region.x1 and y >= region.y0 and y < region.y1) return .{ region.rgba, region.tolerance };
        }
        return .{ self.clear, 0 };
    }

    pub fn expectedDepth(self: Scene, x: u32, y: u32) f32 {
        for (self.expected_depth) |region| {
            if (x >= region.x0 and x < region.x1 and y >= region.y0 and y < region.y1) return region.depth;
        }
        return self.depth_clear.?;
    }
};

pub const white = Texture{ .width = 1, .height = 1, .texels = &.{.{ 255, 255, 255, 255 }} };

/// The color bytes `rgba` as the values a fragment computes with.
pub fn unit(rgba: [4]u8) [4]f32 {
    var value: [4]f32 = undefined;
    for (&value, rgba) |*channel, byte| channel.* = @as(f32, @floatFromInt(byte)) / 255.0;
    return value;
}

/// A vertex at pixel coordinates (x, y) of a `width` by `height` target.
pub fn at(width: u32, height: u32, x: f32, y: f32, z: f32, uv: [2]f32, rgba: [4]u8) Vertex {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    return .{ .position = .{ x / w * 2 - 1, y / h * 2 - 1, z }, .uv = uv, .color = unit(rgba) };
}

/// Two triangles covering the pixel rectangle [x0, x1) by [y0, y1) at depth z, with texture
/// coordinates running from (0, 0) at the top left to (1, 1) at the bottom right.
fn quad(width: u32, height: u32, x0: f32, y0: f32, x1: f32, y1: f32, z: f32, rgba: [4]u8) [6]Vertex {
    const top_left = at(width, height, x0, y0, z, .{ 0, 0 }, rgba);
    const top_right = at(width, height, x1, y0, z, .{ 1, 0 }, rgba);
    const bottom_left = at(width, height, x0, y1, z, .{ 0, 1 }, rgba);
    const bottom_right = at(width, height, x1, y1, z, .{ 1, 1 }, rgba);
    return .{ top_left, bottom_left, bottom_right, top_left, bottom_right, top_right };
}

/// Two triangles covering the pixel rectangle [x0, x1) by [y0, y1), with depth running linearly
/// from `z_left` at x0 to `z_right` at x1.
fn slopedQuad(width: u32, height: u32, x0: f32, y0: f32, x1: f32, y1: f32, z_left: f32, z_right: f32, rgba: [4]u8) [6]Vertex {
    const top_left = at(width, height, x0, y0, z_left, .{ 0, 0 }, rgba);
    const top_right = at(width, height, x1, y0, z_right, .{ 1, 0 }, rgba);
    const bottom_left = at(width, height, x0, y1, z_left, .{ 0, 1 }, rgba);
    const bottom_right = at(width, height, x1, y1, z_right, .{ 1, 1 }, rgba);
    return .{ top_left, bottom_left, bottom_right, top_left, bottom_right, top_right };
}

/// The four corners of a quad for indexed draws: top left, bottom left, top right, bottom right.
fn corners(width: u32, height: u32, x0: f32, y0: f32, x1: f32, y1: f32, rgba: [4]u8) [4]Vertex {
    return .{
        at(width, height, x0, y0, 0, .{ 0, 0 }, rgba),
        at(width, height, x0, y1, 0, .{ 0, 1 }, rgba),
        at(width, height, x1, y0, 0, .{ 1, 0 }, rgba),
        at(width, height, x1, y1, 0, .{ 1, 1 }, rgba),
    };
}

/// The bytes the contract's equation for `mode` gives for fragment `s` over target `d`, rounded
/// to nearest.
pub fn blended(mode: gpu.RenderBlendMode, s: [4]u8, d: [4]u8) [4]u8 {
    const sa: f64 = @as(f64, @floatFromInt(s[3])) / 255.0;
    var result: [4]u8 = undefined;
    for (0..4) |channel| {
        const sc: f64 = @as(f64, @floatFromInt(s[channel])) / 255.0;
        const dc: f64 = @as(f64, @floatFromInt(d[channel])) / 255.0;
        const value = switch (mode) {
            .replace => sc,
            .alpha_premultiplied => sc + dc * (1 - sa),
            .alpha_straight => if (channel == 3) sa + dc * (1 - sa) else sc * sa + dc * (1 - sa),
            .additive => sc + dc,
        };
        result[channel] = @intFromFloat(@round(@min(value, 1.0) * 255.0));
    }
    return result;
}

const shade = [4]u8{ 64, 64, 64, 64 };

/// A square whose edges run through pixel centers, split along its diagonal. The top-left rule
/// covers the centers on its left and top edges and leaves those on its right and bottom edges,
/// and covers each center on the shared diagonal once. Additive blending shows a center covered
/// twice as a doubled value.
pub const coverage = Scene{
    .name = "coverage",
    .width = 8,
    .height = 8,
    .pipelines = &.{.{ .blend = .additive }},
    .vertices = &.{
        at(8, 8, 2.5, 2.5, 0, .{ 0, 0 }, shade),
        at(8, 8, 5.5, 5.5, 0, .{ 0, 0 }, shade),
        at(8, 8, 2.5, 5.5, 0, .{ 0, 0 }, shade),
        at(8, 8, 2.5, 2.5, 0, .{ 0, 0 }, shade),
        at(8, 8, 5.5, 2.5, 0, .{ 0, 0 }, shade),
        at(8, 8, 5.5, 5.5, 0, .{ 0, 0 }, shade),
    },
    .draws = &.{.{ .vertex_count = 6 }},
    .expected = &.{.{ .x0 = 2, .y0 = 2, .x1 = 5, .y1 = 5, .rgba = shade }},
};

const red = [4]u8{ 255, 0, 0, 255 };
const green = [4]u8{ 0, 255, 0, 255 };
const blue = [4]u8{ 0, 0, 255, 255 };

/// A far quad over columns [0, 6) at depth 0.5 and a near quad over columns [2, 8) at depth 0.25.
const far_quad = quad(8, 8, 0, 0, 6, 8, 0.5, red);
const near_quad = quad(8, 8, 2, 0, 8, 8, 0.25, green);
const far_then_near = far_quad ++ near_quad;
const near_then_far = near_quad ++ far_quad;

/// The near quad drawn last covers the overlap and leaves its depth there.
pub const depth_near_last = Scene{
    .name = "depth-near-last",
    .width = 8,
    .height = 8,
    .depth_clear = 1,
    .pipelines = &.{.{ .depth = .{} }},
    .vertices = &far_then_near,
    .draws = &.{ .{ .vertex_count = 6 }, .{ .first_vertex = 6, .vertex_count = 6 } },
    .expected = &.{
        .{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 8, .rgba = red },
        .{ .x0 = 2, .y0 = 0, .x1 = 8, .y1 = 8, .rgba = green },
    },
    .expected_depth = &.{
        .{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 8, .depth = 0.5 },
        .{ .x0 = 2, .y0 = 0, .x1 = 8, .y1 = 8, .depth = 0.25 },
    },
};

/// The far quad drawn last fails the depth test wherever the near quad already is.
pub const depth_near_first = Scene{
    .name = "depth-near-first",
    .width = 8,
    .height = 8,
    .depth_clear = 1,
    .pipelines = &.{.{ .depth = .{} }},
    .vertices = &near_then_far,
    .draws = &.{ .{ .vertex_count = 6 }, .{ .first_vertex = 6, .vertex_count = 6 } },
    .expected = depth_near_last.expected,
    .expected_depth = depth_near_last.expected_depth,
};

/// With depth writes off every fragment tests against the cleared depth, so the far quad drawn
/// last covers the overlap and the depth stays cleared.
pub const depth_write_off = Scene{
    .name = "depth-write-off",
    .width = 8,
    .height = 8,
    .depth_clear = 1,
    .pipelines = &.{.{ .depth = .{ .write = false } }},
    .vertices = &near_then_far,
    .draws = &.{ .{ .vertex_count = 6 }, .{ .first_vertex = 6, .vertex_count = 6 } },
    .expected = &.{
        .{ .x0 = 0, .y0 = 0, .x1 = 6, .y1 = 8, .rgba = red },
        .{ .x0 = 6, .y0 = 0, .x1 = 8, .y1 = 8, .rgba = green },
    },
};

const blend_source = [4]u8{ 200, 100, 50, 128 };
const blend_target = [4]u8{ 40, 120, 200, 160 };
const blend_columns = quad(8, 2, 0, 0, 2, 2, 0, blend_source) ++ quad(8, 2, 2, 0, 4, 2, 0, blend_source) ++
    quad(8, 2, 4, 0, 6, 2, 0, blend_source) ++ quad(8, 2, 6, 0, 8, 2, 0, blend_source);

/// One fragment color over one cleared color, blended by each mode in its own pair of columns.
pub const blend = Scene{
    .name = "blend",
    .width = 8,
    .height = 2,
    .clear = blend_target,
    .pipelines = &.{
        .{ .blend = .replace },
        .{ .blend = .alpha_premultiplied },
        .{ .blend = .alpha_straight },
        .{ .blend = .additive },
    },
    .vertices = &blend_columns,
    .draws = &.{
        .{ .pipeline = 0, .first_vertex = 0, .vertex_count = 6 },
        .{ .pipeline = 1, .first_vertex = 6, .vertex_count = 6 },
        .{ .pipeline = 2, .first_vertex = 12, .vertex_count = 6 },
        .{ .pipeline = 3, .first_vertex = 18, .vertex_count = 6 },
    },
    .expected = &.{
        .{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 2, .rgba = blended(.replace, blend_source, blend_target) },
        .{ .x0 = 2, .y0 = 0, .x1 = 4, .y1 = 2, .rgba = blended(.alpha_premultiplied, blend_source, blend_target), .tolerance = 1 },
        .{ .x0 = 4, .y0 = 0, .x1 = 6, .y1 = 2, .rgba = blended(.alpha_straight, blend_source, blend_target), .tolerance = 1 },
        .{ .x0 = 6, .y0 = 0, .x1 = 8, .y1 = 2, .rgba = blended(.additive, blend_source, blend_target) },
    },
};

fn checkerTexel(x: u32, y: u32) [4]u8 {
    return .{ @intCast(32 * x + 16), @intCast(32 * y + 16), @intCast(40 * (x + y)), 255 };
}

const checker_texels = blk: {
    var texels: [16][4]u8 = undefined;
    for (0..4) |y| {
        for (0..4) |x| texels[y * 4 + x] = checkerTexel(x, y);
    }
    break :blk texels;
};

const checker_regions = blk: {
    var regions: [16]Region = undefined;
    for (0..4) |y| {
        for (0..4) |x| regions[y * 4 + x] = .{
            .x0 = 2 * x,
            .y0 = 2 * y,
            .x1 = 2 * x + 2,
            .y1 = 2 * y + 2,
            .rgba = checkerTexel(x, y),
        };
    }
    break :blk regions;
};

/// A 4 by 4 texture stretched over an 8 by 8 target. Each pixel center samples a quarter of the
/// way into one texel, far from any texel edge, so nearest filtering picks one texel per 2 by 2
/// block of pixels.
pub const texture_nearest = Scene{
    .name = "texture-nearest",
    .width = 8,
    .height = 8,
    .texture = .{ .width = 4, .height = 4, .texels = &checker_texels },
    .pipelines = &.{.{}},
    .vertices = &quad(8, 8, 0, 0, 8, 8, 0, .{ 255, 255, 255, 255 }),
    .draws = &.{.{ .vertex_count = 6 }},
    .expected = &checker_regions,
};

const instance_bytes = [3][4]u8{ .{ 10, 20, 30, 40 }, .{ 50, 60, 70, 80 }, .{ 1, 2, 3, 4 } };

/// One triangle over the whole target, drawn three times with a color per instance. Additive
/// blending sums the instances, so each pixel holds their exact sum.
pub const instanced = Scene{
    .name = "instanced",
    .width = 4,
    .height = 4,
    .pipelines = &.{.{ .blend = .additive, .instanced = true }},
    .vertices = &.{
        at(4, 4, 0, 0, 0, .{ 0, 0 }, .{ 0, 0, 0, 0 }),
        at(4, 4, 0, 8, 0, .{ 0, 0 }, .{ 0, 0, 0, 0 }),
        at(4, 4, 8, 0, 0, .{ 0, 0 }, .{ 0, 0, 0, 0 }),
    },
    .instance_colors = &.{ unit(instance_bytes[0]), unit(instance_bytes[1]), unit(instance_bytes[2]) },
    .draws = &.{.{ .vertex_count = 3, .instance_count = 3 }},
    .expected = &.{.{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 4, .rgba = .{ 61, 82, 103, 124 } }},
};

/// Two quads that share one list of six indices: 16-bit indices from the first index draw the
/// red quad, and 32-bit indices from the fourth index, offset by four vertices, draw the blue.
pub const indexed = Scene{
    .name = "indexed",
    .width = 8,
    .height = 8,
    .pipelines = &.{.{}},
    .vertices = &(corners(8, 8, 0, 0, 4, 4, red) ++ corners(8, 8, 4, 4, 8, 8, blue)),
    .indices16 = &.{ 0, 1, 2, 2, 1, 3 },
    .indices32 = &.{ 3, 3, 3, 0, 1, 2, 2, 1, 3 },
    .draws = &.{
        .{ .indexed = .{ .format = .u16, .first_index = 0, .index_count = 6 } },
        .{ .indexed = .{ .format = .u32, .first_index = 3, .index_count = 6, .base_vertex = 4 } },
    },
    .expected = &.{
        .{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 4, .rgba = red },
        .{ .x0 = 4, .y0 = 4, .x1 = 8, .y1 = 8, .rgba = blue },
    },
};

const warm = [4]u8{ 200, 100, 40, 255 };

/// One 2 by 2 quad at pixels [4, 6) drawn four times, each draw placing it with its own push
/// constants: at its size in the top left corner, twice its size to its right at half the color,
/// at half its size near the bottom right at a quarter of the color, and at its size again below
/// the first. Each placement is a scale and translation by powers of two, so every corner lands
/// on a pixel edge.
pub const push_transform = Scene{
    .name = "push-transform",
    .width = 8,
    .height = 8,
    .pipelines = &.{.{ .module = .pushed }},
    .vertices = &quad(8, 8, 4, 4, 6, 6, 0, warm),
    .draws = &.{
        .{ .vertex_count = 6, .push = .{ .translate = .{ -1, -1 } } },
        .{ .vertex_count = 6, .push = .{ .translate = .{ -0.5, -1 }, .scale = 2, .factor = 0.5 } },
        .{ .vertex_count = 6, .push = .{ .translate = .{ 0.5, 0.5 }, .scale = 0.5, .factor = 0.25 } },
        .{ .vertex_count = 6, .push = .{ .translate = .{ -1, 0.25 } } },
    },
    .expected = &.{
        .{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 2, .rgba = warm },
        .{ .x0 = 2, .y0 = 0, .x1 = 6, .y1 = 4, .rgba = .{ 100, 50, 20, 255 } },
        .{ .x0 = 6, .y0 = 6, .x1 = 7, .y1 = 7, .rgba = .{ 50, 25, 10, 255 } },
        .{ .x0 = 0, .y0 = 5, .x1 = 2, .y1 = 7, .rgba = warm },
    },
};

const white_rgba = [4]u8{ 255, 255, 255, 255 };

/// A white quad over the whole target colored by the uniform alone: its color, alpha and a tint
/// that halves red, green and blue.
pub const uniform_color = Scene{
    .name = "uniform-color",
    .width = 4,
    .height = 4,
    .pipelines = &.{.{ .module = .pushed }},
    .vertices = &quad(4, 4, 0, 0, 4, 4, 0, white_rgba),
    .uniform = .{
        .rgb = .{ unit(warm)[0], unit(warm)[1], unit(warm)[2] },
        .alpha = unit(.{ 0, 0, 0, 128 })[3],
        .tint = .{ 0.5, 0.5, 0.5, 1 },
    },
    .draws = &.{.{ .vertex_count = 6 }},
    .expected = &.{.{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 4, .rgba = .{ 100, 50, 20, 128 } }},
};

/// The step of depth32_float at depth 0.5, and the offset a constant factor of −16 gives there.
const half_step: f32 = 0x1p-24;
const decal_offset: f32 = -16 * half_step;

/// A red surface over the whole target at depth 0.5, and two decals on it at the same depth. The
/// left decal has no bias and ties the surface, so the less-than test hides it. The right decal's
/// constant factor of −16 moves it 16 steps nearer, and it shows.
pub const decal_coplanar = Scene{
    .name = "decal-coplanar",
    .width = 8,
    .height = 8,
    .depth_clear = 1,
    .pipelines = &.{
        .{ .depth = .{} },
        .{ .depth = .{ .bias = .{ .constant = -16 } } },
    },
    .vertices = &(quad(8, 8, 0, 0, 8, 8, 0.5, red) ++ quad(8, 8, 0, 2, 4, 6, 0.5, green) ++ quad(8, 8, 4, 2, 8, 6, 0.5, blue)),
    .draws = &.{
        .{ .vertex_count = 6 },
        .{ .first_vertex = 6, .vertex_count = 6 },
        .{ .pipeline = 1, .first_vertex = 12, .vertex_count = 6 },
    },
    .expected = &.{
        .{ .x0 = 4, .y0 = 2, .x1 = 8, .y1 = 6, .rgba = blue },
        .{ .x0 = 0, .y0 = 0, .x1 = 8, .y1 = 8, .rgba = red },
    },
    .expected_depth = &.{
        .{ .x0 = 4, .y0 = 2, .x1 = 8, .y1 = 6, .depth = 0.5 + decal_offset },
        .{ .x0 = 0, .y0 = 0, .x1 = 8, .y1 = 8, .depth = 0.5 },
    },
};

/// Depth rises by 1/32 per pixel across the sloped surface, from 0.25 at its left edge.
const surface_slope: f32 = 1.0 / 32.0;
/// The slope factor's offset on that surface, and the clamp that caps a steeper factor's.
const sloped_offset: f32 = -0x1p-10 * surface_slope;
const clamp_offset: f32 = -0x1p-20;

fn surfaceDepth(x: u32) f32 {
    return 0.25 + (@as(f32, @floatFromInt(x)) + 0.5) * surface_slope;
}

const sloped_depths = blk: {
    var regions: [16]DepthRegion = undefined;
    for (0..8) |x| {
        const offset = if (x < 4) sloped_offset else clamp_offset;
        regions[x] = .{ .x0 = x, .y0 = 2, .x1 = x + 1, .y1 = 6, .depth = surfaceDepth(x) + offset };
        regions[8 + x] = .{ .x0 = x, .y0 = 0, .x1 = x + 1, .y1 = 8, .depth = surfaceDepth(x) };
    }
    break :blk regions;
};

/// A red surface sloping in x, and two decals on it at its depths. The left decal's slope factor
/// of −2^−10 moves it 2^−15 nearer. The right decal's slope factor of −1 would move it 1/32
/// nearer, and its clamp of −2^−20 limits that to 2^−20. Both show.
pub const decal_sloped = Scene{
    .name = "decal-sloped",
    .width = 8,
    .height = 8,
    .depth_clear = 1,
    .pipelines = &.{
        .{ .depth = .{} },
        .{ .depth = .{ .bias = .{ .slope = -0x1p-10 } } },
        .{ .depth = .{ .bias = .{ .slope = -1, .clamp = clamp_offset } } },
    },
    .vertices = &(slopedQuad(8, 8, 0, 0, 8, 8, 0.25, 0.5, red) ++ slopedQuad(8, 8, 0, 2, 4, 6, 0.25, 0.375, green) ++
        slopedQuad(8, 8, 4, 2, 8, 6, 0.375, 0.5, blue)),
    .draws = &.{
        .{ .vertex_count = 6 },
        .{ .pipeline = 1, .first_vertex = 6, .vertex_count = 6 },
        .{ .pipeline = 2, .first_vertex = 12, .vertex_count = 6 },
    },
    .expected = &.{
        .{ .x0 = 0, .y0 = 2, .x1 = 4, .y1 = 6, .rgba = green },
        .{ .x0 = 4, .y0 = 2, .x1 = 8, .y1 = 6, .rgba = blue },
        .{ .x0 = 0, .y0 = 0, .x1 = 8, .y1 = 8, .rgba = red },
    },
    .expected_depth = &sloped_depths,
};

pub const scenes = [_]Scene{
    coverage,
    depth_near_last,
    depth_near_first,
    depth_write_off,
    blend,
    texture_nearest,
    instanced,
    indexed,
    push_transform,
    uniform_color,
    decal_coplanar,
    decal_sloped,
};

/// Side of the square target the throughput pass draws into; it draws one small triangle per
/// pixel, `throughput_side` squared in all.
pub const throughput_side: u32 = 64;

/// The small triangle over pixel `index` of the throughput target. Its corners sit a tenth of a
/// pixel in from the pixel's top left and reach past its center, so it covers that center alone.
pub fn throughputTriangle(index: u32) [3]Vertex {
    const x: f32 = @floatFromInt(index % throughput_side);
    const y: f32 = @floatFromInt(index / throughput_side);
    const side = throughput_side;
    const color = [4]u8{ 255, 255, 255, 255 };
    return .{
        at(side, side, x + 0.1, y + 0.1, 0, .{ 0, 0 }, color),
        at(side, side, x + 0.95, y + 0.1, 0, .{ 0, 0 }, color),
        at(side, side, x + 0.1, y + 0.95, 0, .{ 0, 0 }, color),
    };
}
