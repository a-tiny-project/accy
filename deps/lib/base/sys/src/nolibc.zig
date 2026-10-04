const std = @import("std");

pub const no_libc = true;

pub const allocator = @import("allocator.zig");
pub const atomic = @import("atomic/root.zig");
pub const capabilities = @import("capabilities.zig");
pub const errno = @import("errno.zig");
pub const kvm = @import("kvm/root.zig");
pub const memory = @import("memory.zig");
pub const net = @import("net.zig");
pub const panic = @import("panic.zig");
pub const random = @import("random.zig");
pub const rseq = @import("rseq/root.zig");
pub const stdio = @import("stdio.zig");
pub const std_options = @import("options.zig");
pub const thread = @import("threadraw.zig");
pub const time = @import("time.zig");
pub const tls = @import("tls.zig");

pub const required_capabilities = capabilities.noLibc(&.{
    .allocator,
    .descriptors,
    .filesystem,
    .libc_interop,
    .memory_mapping,
    .networking,
    .process,
    .random,
    .standard_streams,
    .threads,
    .time,
    .tls,
    .virtualization,
});

test "sys: no-libc namespace" {
    _ = allocator;
    _ = atomic;
    _ = capabilities;
    _ = errno;
    _ = kvm;
    _ = memory;
    _ = net;
    _ = panic;
    _ = random;
    _ = rseq;
    _ = stdio;
    _ = std_options;
    _ = thread;
    _ = time;
    _ = tls;
}

test "no-libc surface declares exported service requirements" {
    try std.testing.expectEqual(capabilities.CapabilityTier.no_libc, required_capabilities.tier);
    try std.testing.expect(required_capabilities.requires(.allocator));
    try std.testing.expect(required_capabilities.requires(.filesystem));
    try std.testing.expect(required_capabilities.requires(.libc_interop));
    try std.testing.expect(required_capabilities.requires(.memory_mapping));
    try std.testing.expect(required_capabilities.requires(.networking));
    try std.testing.expect(required_capabilities.requires(.process));
    try std.testing.expect(required_capabilities.requires(.random));
    try std.testing.expect(required_capabilities.requires(.standard_streams));
    try std.testing.expect(required_capabilities.requires(.threads));
    try std.testing.expect(required_capabilities.requires(.time));
    try std.testing.expect(required_capabilities.requires(.tls));
    try std.testing.expect(required_capabilities.requires(.virtualization));
}
