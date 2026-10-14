const std = @import("std");
const generated = @import("__tiny_compiled_inputs_v1");

pub const refusal: ?[]const u8 = if (generated.qualified) null else generated.refusal;

/// A plain consumer build has no compiler invocation record, so sealed-product
/// tests cannot run; a recorded build with failed qualification must still fail.
pub const unrecorded: bool = if (refusal) |reason|
    std.mem.eql(u8, reason, "UnrecordedCompilerBuild")
else
    false;

/// Only the final build graph can provide this foreign-input record.
/// An unrecorded build remains usable for transient compiler work.
pub fn manifest() error{UnrecordedCompilerBuild}![]const u8 {
    if (!generated.qualified) return error.UnrecordedCompilerBuild;
    return generated.bytes;
}
