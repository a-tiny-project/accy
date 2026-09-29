const std = @import("std");
const subject = @import("root.zig");

const supported = subject.supported;
const cpu_id_uninitialized = subject.cpu_id_uninitialized;
const cpu_id_registration_failed = subject.cpu_id_registration_failed;
const CriticalSection = subject.CriticalSection;
const Area = subject.Area;
const RegistrationState = subject.RegistrationState;
const registrationPolicy = subject.registrationPolicy;
const currentState = subject.currentState;
const registered = subject.registered;
const ensureRegistered = subject.ensureRegistered;
const currentArea = subject.currentArea;
const currentCpu = subject.currentCpu;
const clearCriticalSection = subject.clearCriticalSection;
const validCpuId = subject.validCpuId;

test "rseq ABI layout matches linux header" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(CriticalSection));
    try std.testing.expectEqual(@as(usize, 32), @alignOf(CriticalSection));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CriticalSection, "version"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(CriticalSection, "flags"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CriticalSection, "start_ip"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(CriticalSection, "post_commit_offset"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(CriticalSection, "abort_ip"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(CriticalSection, "end"));

    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Area));
    try std.testing.expectEqual(@as(usize, 32), @alignOf(Area));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Area, "cpu_id_start"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(Area, "cpu_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Area, "rseq_cs"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Area, "flags"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(Area, "node_id"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Area, "mm_cid"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Area, "end"));

    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), cpu_id_uninitialized);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -2))), cpu_id_registration_failed);
}

test "rseq unsupported targets remain inert" {
    if (comptime supported) return;
    try std.testing.expectEqual(RegistrationState.unsupported, currentState());
    try std.testing.expectEqual(false, registered());
    try std.testing.expectEqual(@as(?*Area, null), currentArea());
    try std.testing.expectEqual(@as(?u32, null), currentCpu());
    try std.testing.expectError(error.UnsupportedPlatform, ensureRegistered());
}

test "rseq registration state is queryable" {
    if (comptime !supported) return;

    switch (registrationPolicy()) {
        .direct_syscall, .direct_syscall_with_libc_owner_detection => {},
        else => return error.TestUnexpectedResult,
    }

    const area = ensureRegistered() catch |err| switch (err) {
        error.SystemOutdated,
        error.AlreadyRegistered,
        error.KernelRejectedArea,
        error.PermissionDenied,
        error.RegistrationFailed,
        => return,
        error.UnsupportedPlatform => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(true, registered());
    switch (currentState()) {
        .direct_registered, .libc_registered => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(area, currentArea().?);

    const cpu = currentCpu() orelse return error.TestUnexpectedResult;
    try std.testing.expect(validCpuId(cpu));
    try std.testing.expectEqual(@as(u64, 0), area.rseq_cs);
    clearCriticalSection();
}
