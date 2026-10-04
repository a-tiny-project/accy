//! Linux DRM render nodes and the synchronization objects (syncobjs) they own, through the kernel
//! uAPI of `include/uapi/drm/drm.h`. A syncobj is a kernel handle to a fence or, as a timeline, to
//! a sequence of fences numbered by 64-bit points. Compositors and GPU drivers exchange timeline
//! syncobjs to say when a buffer's contents are ready and when its reader is done with it.
//!
//! A render node is `/dev/dri/renderD<minor>`. Syncobj handles are local to the open file that
//! created or imported them, so every call below takes the node that owns the handle.

const builtin = @import("builtin");
const std = @import("std");

pub const supported = builtin.os.tag == .linux;

const linux = std.os.linux;

pub const Error = error{
    UnsupportedPlatform,
    OpenFailed,
    AccessDenied,
    /// The node is not the device that was asked for.
    DeviceMismatch,
    /// The kernel rejected the request's arguments or does not know the request.
    Unsupported,
    InvalidHandle,
    OutOfMemory,
    /// The deadline passed before the point signalled.
    Timeout,
    Failed,
};

/// A Linux device number, as `stat` reports it in `st_rdev` and as Wayland's dmabuf feedback sends
/// it in native byte order.
pub const DeviceNumber = struct {
    major: u32,
    minor: u32,

    /// Decodes the kernel's `dev_t` layout, which splits each number across two fields.
    pub fn fromRaw(encoded: u64) DeviceNumber {
        return .{
            .major = @intCast(((encoded >> 8) & 0xfff) | ((encoded >> 32) & 0xffff_f000)),
            .minor = @intCast((encoded & 0xff) | ((encoded >> 12) & 0xffff_ff00)),
        };
    }

    pub fn raw(self: DeviceNumber) u64 {
        const major: u64 = self.major;
        const minor: u64 = self.minor;
        return (minor & 0xff) | ((major & 0xfff) << 8) | ((minor & ~@as(u64, 0xff)) << 12) | ((major & ~@as(u64, 0xfff)) << 32);
    }
};

/// A timeline syncobj handle, valid on the render node that created or imported it.
pub const Syncobj = struct {
    handle: u32,
};

const ioctl_base: u32 = 'd';

fn iowr(number: u8, comptime T: type) u32 {
    return (3 << 30) | (@as(u32, @sizeOf(T)) << 16) | (ioctl_base << 8) | number;
}

const SyncobjCreate = extern struct {
    handle: u32 = 0,
    flags: u32 = 0,
};

const SyncobjDestroy = extern struct {
    handle: u32,
    pad: u32 = 0,
};

const SyncobjHandle = extern struct {
    handle: u32 = 0,
    flags: u32 = 0,
    fd: i32 = -1,
    pad: u32 = 0,
    point: u64 = 0,
};

const SyncobjTimelineWait = extern struct {
    handles: u64,
    points: u64,
    timeout_nsec: i64,
    count_handles: u32,
    flags: u32,
    first_signaled: u32 = 0,
    pad: u32 = 0,
    deadline_nsec: u64 = 0,
};

const SyncobjTimelineArray = extern struct {
    handles: u64,
    points: u64,
    count_handles: u32,
    flags: u32 = 0,
};

const ioctl_syncobj_create = iowr(0xBF, SyncobjCreate);
const ioctl_syncobj_destroy = iowr(0xC0, SyncobjDestroy);
const ioctl_syncobj_handle_to_fd = iowr(0xC1, SyncobjHandle);
const ioctl_syncobj_fd_to_handle = iowr(0xC2, SyncobjHandle);
const ioctl_syncobj_timeline_wait = iowr(0xCA, SyncobjTimelineWait);
const ioctl_syncobj_query = iowr(0xCB, SyncobjTimelineArray);
const ioctl_syncobj_timeline_signal = iowr(0xCD, SyncobjTimelineArray);

const fd_to_handle_import_sync_file: u32 = 1 << 0;
const fd_to_handle_timeline: u32 = 1 << 1;
const wait_for_submit: u32 = 1 << 1;

pub const RenderNode = struct {
    fd: i32,

    /// Opens `/dev/dri/renderD<minor>` and checks that it is `device`, so a caller that learned a
    /// device number from a compositor or a driver reaches that device and no other.
    pub fn open(device: DeviceNumber) Error!RenderNode {
        if (comptime !supported) return error.UnsupportedPlatform;
        var path_buffer: [32]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "/dev/dri/renderD{d}", .{device.minor}, 0) catch
            return error.OpenFailed;
        const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        const fd: i32 = switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .ACCES, .PERM => return error.AccessDenied,
            else => return error.OpenFailed,
        };
        errdefer _ = linux.close(fd);
        var status = std.mem.zeroes(linux.Statx);
        const result = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &status);
        if (linux.errno(result) != .SUCCESS) return error.OpenFailed;
        if (status.rdev_major != device.major or status.rdev_minor != device.minor) return error.DeviceMismatch;
        return .{ .fd = fd };
    }

    pub fn close(self: RenderNode) void {
        if (comptime !supported) return;
        _ = linux.close(self.fd);
    }

    /// Creates a syncobj with no fence. As a timeline its last signalled point starts at 0.
    pub fn createSyncobj(self: RenderNode) Error!Syncobj {
        var request = SyncobjCreate{};
        try self.call(ioctl_syncobj_create, &request);
        return .{ .handle = request.handle };
    }

    pub fn destroySyncobj(self: RenderNode, syncobj: Syncobj) void {
        var request = SyncobjDestroy{ .handle = syncobj.handle };
        self.call(ioctl_syncobj_destroy, &request) catch {};
    }

    /// A new file descriptor for the whole syncobj, which another process imports as the same
    /// object. The caller owns the descriptor.
    pub fn exportSyncobj(self: RenderNode, syncobj: Syncobj) Error!i32 {
        var request = SyncobjHandle{ .handle = syncobj.handle };
        try self.call(ioctl_syncobj_handle_to_fd, &request);
        return request.fd;
    }

    /// Attaches the fence of `sync_file` to `point` of a timeline syncobj, so the point signals
    /// when that fence does. The caller keeps ownership of `sync_file`.
    pub fn importSyncFile(self: RenderNode, syncobj: Syncobj, point: u64, sync_file: i32) Error!void {
        std.debug.assert(point != 0);
        var request = SyncobjHandle{
            .handle = syncobj.handle,
            .flags = fd_to_handle_import_sync_file | fd_to_handle_timeline,
            .fd = sync_file,
            .point = point,
        };
        try self.call(ioctl_syncobj_fd_to_handle, &request);
    }

    /// Waits until `point` has a fence and that fence has signalled, or until `deadline_ns` on
    /// `CLOCK_MONOTONIC` passes. A point nobody has attached a fence to yet counts as unsignalled.
    pub fn waitPoint(self: RenderNode, syncobj: Syncobj, point: u64, deadline_ns: i64) Error!void {
        var handle = syncobj.handle;
        var wanted = point;
        var request = SyncobjTimelineWait{
            .handles = @intFromPtr(&handle),
            .points = @intFromPtr(&wanted),
            .timeout_nsec = deadline_ns,
            .count_handles = 1,
            .flags = wait_for_submit,
        };
        try self.call(ioctl_syncobj_timeline_wait, &request);
    }

    /// The highest point of the timeline that has signalled.
    pub fn signalledPoint(self: RenderNode, syncobj: Syncobj) Error!u64 {
        var handle = syncobj.handle;
        var point: u64 = 0;
        var request = SyncobjTimelineArray{
            .handles = @intFromPtr(&handle),
            .points = @intFromPtr(&point),
            .count_handles = 1,
        };
        try self.call(ioctl_syncobj_query, &request);
        return point;
    }

    /// Signals `point` from the host, as a reader that finished on the CPU does.
    pub fn signalPoint(self: RenderNode, syncobj: Syncobj, point: u64) Error!void {
        var handle = syncobj.handle;
        var signalled = point;
        var request = SyncobjTimelineArray{
            .handles = @intFromPtr(&handle),
            .points = @intFromPtr(&signalled),
            .count_handles = 1,
        };
        try self.call(ioctl_syncobj_timeline_signal, &request);
    }

    fn call(self: RenderNode, request_code: u32, argument: anytype) Error!void {
        if (comptime !supported) return error.UnsupportedPlatform;
        while (true) {
            const rc = linux.ioctl(self.fd, request_code, @intFromPtr(argument));
            return switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR, .AGAIN => continue,
                .TIME => error.Timeout,
                .NOENT => error.InvalidHandle,
                .NOMEM => error.OutOfMemory,
                .INVAL, .NOTTY, .OPNOTSUPP => error.Unsupported,
                else => error.Failed,
            };
        }
    }
};

/// The current `CLOCK_MONOTONIC` time, the clock syncobj deadlines are measured on.
pub fn monotonicNow() i64 {
    var now: linux.timespec = undefined;
    std.debug.assert(linux.errno(linux.clock_gettime(.MONOTONIC, &now)) == .SUCCESS);
    return @as(i64, now.sec) * std.time.ns_per_s + now.nsec;
}

test "device numbers round trip through the kernel dev_t layout" {
    const render = DeviceNumber{ .major = 226, .minor = 128 };
    try std.testing.expectEqual(@as(u64, 0xE280), render.raw());
    try std.testing.expectEqual(render, DeviceNumber.fromRaw(0xE280));
    const wide = DeviceNumber{ .major = 0x12345, .minor = 0x6789a };
    try std.testing.expectEqual(wide, DeviceNumber.fromRaw(wide.raw()));
}

test "syncobj requests match the uAPI structure sizes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SyncobjCreate));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(SyncobjHandle));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(SyncobjTimelineWait));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(SyncobjTimelineArray));
    try std.testing.expectEqual(@as(u32, 0xC00864BF), ioctl_syncobj_create);
    try std.testing.expectEqual(@as(u32, 0xC01864C2), ioctl_syncobj_fd_to_handle);
    try std.testing.expectEqual(@as(u32, 0xC03064CA), ioctl_syncobj_timeline_wait);
}

test "a timeline point signalled from the host ends a wait and a missing point times out" {
    if (comptime !supported) return error.SkipZigTest;
    const node = RenderNode.open(.{ .major = 226, .minor = 128 }) catch return error.SkipZigTest;
    defer node.close();
    const syncobj = try node.createSyncobj();
    defer node.destroySyncobj(syncobj);
    try std.testing.expectEqual(@as(u64, 0), try node.signalledPoint(syncobj));
    try std.testing.expectError(error.Timeout, node.waitPoint(syncobj, 1, monotonicNow() + std.time.ns_per_ms));
    try node.signalPoint(syncobj, 1);
    try node.waitPoint(syncobj, 1, monotonicNow() + std.time.ns_per_s);
    try std.testing.expectEqual(@as(u64, 1), try node.signalledPoint(syncobj));
    const exported = try node.exportSyncobj(syncobj);
    _ = linux.close(exported);
}
