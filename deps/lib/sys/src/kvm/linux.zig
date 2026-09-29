const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../root.zig");
const abi = @import("abi.zig");
const types = @import("types.zig");

pub const supported = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64;

const LinuxOperations = struct {
    pub fn platformSupported(_: *@This()) bool {
        return supported;
    }

    pub fn openDevice(_: *@This()) types.RawResult {
        if (comptime !supported) return .{ .failure = .NOSYS };
        const result = std.os.linux.open(abi.device_path, .{
            .ACCMODE = .RDWR,
            .CLOEXEC = true,
        }, 0);
        return rawResult(result);
    }

    pub fn control(
        _: *@This(),
        descriptor: types.Descriptor,
        request: u32,
        argument: usize,
    ) types.RawResult {
        if (comptime !supported) return .{ .failure = .NOSYS };
        return rawResult(std.os.linux.ioctl(descriptor, request, argument));
    }

    pub fn mapRun(
        _: *@This(),
        descriptor: types.Descriptor,
        len: usize,
    ) types.MapResult {
        if (comptime !supported) return .{ .failure = .NOSYS };
        const mapping = sys.memory.mapSharedFile(
            descriptor,
            len,
            .{ .read = true, .write = true },
            0,
        ) catch |failure| return .{ .failure = mapErrno(failure) };
        return .{ .mapping = mapping };
    }

    pub fn unmap(_: *@This(), mapping: []align(types.page_size) u8) void {
        if (comptime !supported) return;
        sys.memory.unmap(mapping);
    }

    pub fn close(_: *@This(), descriptor: types.Descriptor) void {
        if (comptime !supported) return;
        const code = std.os.linux.errno(std.os.linux.close(descriptor));
        switch (code) {
            .SUCCESS, .INTR => {},
            else => unreachable,
        }
    }
};

var linux_operations: LinuxOperations = .{};

pub fn operations() types.Operations {
    return types.operationsFor(&linux_operations);
}

fn rawResult(result: usize) types.RawResult {
    const code = std.os.linux.errno(result);
    return if (code == .SUCCESS)
        .{ .value = result }
    else
        .{ .failure = code };
}

fn mapErrno(failure: sys.memory.MapError) types.Errno {
    return switch (failure) {
        error.AccessDenied => .ACCES,
        error.PermissionDenied => .PERM,
        error.OutOfMemory => .NOMEM,
        error.UnsupportedPlatform => .NOSYS,
        error.MapFailed => .IO,
    };
}
