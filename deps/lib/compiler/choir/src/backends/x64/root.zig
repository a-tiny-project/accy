const profile = @import("sys").capabilities.current;
const executes = profile.os == .linux and profile.arch == .x86_64 and profile.pointerWidthBits() == 64;

// The ABI describes emitted code on every host. Only entering that code needs a native target.
pub const registers = @import("registers/root.zig");
pub const encoding = @import("encoding.zig");
pub const abi = @import("abi.zig");
pub const cast = @import("cast.zig");
pub const calls = @import("calls.zig");
pub const data = @import("data.zig");
pub const emit = @import("emit.zig");
pub const execution = if (executes) @import("execution.zig") else struct {};
pub const failures = @import("failures.zig");
pub const invoke = if (executes) @import("invoke.zig") else struct {};
pub const labels = @import("labels.zig");
pub const legality = @import("legality.zig");
pub const memory = @import("memory.zig");
pub const moves = @import("moves.zig");
pub const object = @import("object.zig");
pub const scalar = @import("scalar.zig");
pub const slots = @import("slots.zig");
pub const stack = @import("stack/root.zig");
pub const vector = @import("vector.zig");
pub const regalloc = @import("regalloc.zig");
pub const backend = @import("backend.zig");

pub const GPR = registers.GPR;
pub const XMM = registers.XMM;
pub const Mem = encoding.Mem;
pub const Encoding = encoding.Encoding;
pub const Scale = encoding.Scale;
pub const FrameLayout = abi.FrameLayout;
pub const Emitter = emit.Emitter;
