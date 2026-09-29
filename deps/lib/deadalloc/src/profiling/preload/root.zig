pub const abi = @import("abi.zig");
pub const exports = @import("exports.zig");

comptime {
    _ = exports;
}
