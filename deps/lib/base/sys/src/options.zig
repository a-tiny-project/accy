const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const required_capabilities = capabilities.pure();

pub const no_libc: std.Options = .{
    .allow_stack_tracing = false,
    .enable_segfault_handler = false,
    .logFn = noOpLog,
    .unexpected_error_tracing = false,
};

pub const no_libc_debug_threaded_io: ?*std.Io.Threaded = null;
pub const no_libc_debug_io: std.Io = .failing;

fn noOpLog(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = message_level;
    _ = scope;
    _ = format;
    _ = args;
}
