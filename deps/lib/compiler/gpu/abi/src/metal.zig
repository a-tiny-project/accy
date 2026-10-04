//! Where Choir's MSL render stages read their resources, which a Metal host binds to match.
//! Metal gives each stage one flat index space per resource kind, so every binding of group 0
//! maps to fixed indices.

const std = @import("std");

/// Sampled-texture bindings one stage reaches. Metal gives each stage 16 samplers, and binding
/// `b` is the index of both its texture and its sampler.
pub const max_texture_bindings = 16;

/// Uniform blocks one stage reaches, all of group 0.
pub const max_uniform_bindings = 8;
/// The buffer index of uniform binding 0. Indices below it stay free for vertex buffers.
pub const uniform_buffer_base = 16;
/// The buffer index of the push-constant words, Metal's last.
pub const push_buffer = 30;

comptime {
    std.debug.assert(uniform_buffer_base + max_uniform_bindings <= push_buffer);
}
