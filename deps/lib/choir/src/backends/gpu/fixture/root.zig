//! Shared support for the gpu emitter tests: textual kernels and the stage
//! modules that every stage emitter and the SPIR-V validation gate read.

const text = @import("text.zig");

pub const stages = @import("stages.zig");

/// A kernel that takes arith.rem on i32, u32 and index, which every emitter
/// test of the remainder reads.
pub const remainder = @embedFile("remainder.txt");
/// A kernel declared [8, 8] that stores each invocation's local index at its
/// global linear slot, which the emitter tests of the workgroup shape read.
pub const shaped = @embedFile("shaped.txt");
/// A kernel whose u32, i64 and f32 arguments share one push-constant block. It
/// stores the f32 into a storage buffer.
pub const scalars = @embedFile("scalars.txt");
/// A kernel whose subgroup reductions and scans raise its module to SPIR-V 1.3.
pub const subgroup = @embedFile("subgroup.txt");

pub const parse = text.parse;
pub const lower = text.lower;
pub const emitText = text.emitText;
pub const expectContains = text.expectContains;
pub const expectAbsent = text.expectAbsent;
