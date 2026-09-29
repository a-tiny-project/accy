const std = @import("std");

pub const code = @import("code.zig");
pub const config = @import("config.zig");
pub const heap = @import("heap.zig");
pub const image = @import("image.zig");
pub const intrinsics = @import("intrinsics.zig");
pub const reference = @import("reference.zig");
pub const runtime = @import("runtime.zig");
pub const stack = @import("stack.zig");

test "pbt: stabilizer properties namespace" {
    std.testing.refAllDecls(@This());
}
