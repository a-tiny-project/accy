//! The host ABI of a vertex or fragment stage lowered to a CPU function.
//!
//! A lowered stage is `fn (inputs: [*]const f32, outputs: [*]f32, context: *anyopaque) callconv(.c)
//! void`. Both buffers hold `io_words` 32-bit words in the layout below, and a value of an integer
//! type travels as its bits. A rasterizer fills `inputs`, calls the stage, and reads `outputs`.
//!
//! A fragment stage that takes a derivative reads its 2x2 quad instead. Its symbol is the stage's
//! name followed by `quad_suffix`, and it is `fn (quad: [*]const f32, lane: usize, outputs: [*]f32,
//! context: *anyopaque) callconv(.c) void`. `quad` holds `quad_lanes` input blocks of `io_words`
//! words for the pixels of a quad aligned to even coordinates, in lane order `2 * (y & 1) + (x & 1)`,
//! and `lane` names the fragment's own. A rasterizer fills every block, including those of helper
//! pixels the primitive does not cover, from the same plane equations.
//!
//! Words, per buffer:
//! - `[smooth, smooth + slot_words)`: location `l` component `c` at `4 * l + c`, for float values.
//!   A vertex stage reads its attributes here, whatever their type. Between the stages these
//!   words are interpolated across a primitive.
//! - `[flat, flat + slot_words)`: the same indexing, for integer values between the stages. They
//!   are copied from the provoking vertex.
//! - `builtin`: a vertex stage reads `vertex_index` and `instance_index` there; a fragment stage
//!   reads `frag_coord` (x, y, z, 1/w) and `front_facing` (1 or 0).
//! - `position`: the clip position a vertex stage writes.
//! - `sample`: a sample stores `u`, `v` and `lod` in the first three words and calls
//!   `sample_symbol` with the context, the texture's key and `outputs`. The callee leaves the
//!   texel's red, green, blue and alpha in the four words.
//! - `masks`: a vertex stage writes which smooth and which flat words it writes, as two 64-bit
//!   masks split into low and high 32-bit words, so a rasterizer interpolates only those.
//!
//! `context` points at `context_words` words a rasterizer fills before each draw, which a stage
//! only reads:
//! - `[push, push + push_words)`: the draw's push-constant block, byte `o` at word `o / 4`.
//! - `uniform + uniform_window_words * b`: the first `uniform_window_bytes` of the uniform buffer
//!   at binding `b` of group 0, for `b < uniform_bindings`, zero past the buffer's end.
//! A stage reads a member there with one load per component, so a read costs what a load does.
//! A member the context cannot hold is refused when the stage is lowered.

/// Interface locations per direction, as in the gpu dialect.
pub const max_locations = 16;
/// Components one location holds.
pub const location_components = 4;
pub const slot_words = max_locations * location_components;

pub const smooth = 0;
pub const flat = smooth + slot_words;
pub const builtin = flat + slot_words;
pub const vertex_index = builtin;
pub const instance_index = builtin + 1;
pub const frag_coord = builtin;
pub const front_facing = builtin + 4;
pub const position = builtin + 8;
pub const sample = position + 4;
pub const masks = sample + 4;
pub const smooth_mask_low = masks;
pub const smooth_mask_high = masks + 1;
pub const flat_mask_low = masks + 2;
pub const flat_mask_high = masks + 3;
pub const io_words = masks + 4;

/// The suffix a quad fragment stage's symbol takes, and the lanes of its quad.
pub const quad_suffix = ".quad";
pub const quad_lanes = 4;

/// Words of the push-constant block: Vulkan's guaranteed 128 bytes.
pub const push_words = 32;
pub const push = 0;
/// Uniform bindings of group 0 a context holds, and the bytes of each it holds. A window holds
/// an array of 42 elements of three 16-byte rows, such as 3x4 matrices.
pub const uniform_bindings = 8;
pub const uniform_window_bytes = 2048;
pub const uniform_window_words = uniform_window_bytes / 4;
pub const uniform = push + push_words;
pub const context_words = uniform + uniform_bindings * uniform_window_words;

/// The context word holding byte `offset` of the uniform buffer at `binding` of group 0.
pub fn uniformWord(binding: u32, offset: u32) u32 {
    return uniform + binding * uniform_window_words + offset / 4;
}

/// The host function a sample calls: `fn (context: *anyopaque, key: i32, outputs: [*]f32)
/// callconv(.c) void`.
pub const sample_symbol = "tiny_gpu_sample";

/// The key of the texture at `binding` of `group`, as a sample passes it.
pub fn textureKey(group: u32, binding: u32) i32 {
    return @intCast((group << 16) | binding);
}

/// The word of location `location` component `component` in `region` (`smooth` or `flat`).
pub fn slot(region: u32, location: u32, component: u32) u32 {
    return region + location * location_components + component;
}

comptime {
    if (textureKey(0xff, 0xffff) < 0) @compileError("texture keys stay positive");
}
