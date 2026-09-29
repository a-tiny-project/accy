const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const required_capabilities = capabilities.noLibc(&.{.threads});

pub const ThreadSpecificError = error{
    UnsupportedPlatform,
    SystemResources,
};

pub const SpawnError = error{
    UnsupportedPlatform,
    OutOfMemory,
    SystemResources,
};

pub const ThreadSpecificDestructor = *const fn (value: *anyopaque) callconv(.c) void;
pub const Id = usize;
pub const ThreadedIo = std.Io.Threaded;
pub const ThreadedIoOptions = std.Io.Threaded.InitOptions;

pub const ThreadSpecificDestructorPolicy = enum {
    unsupported,
};

pub const Mutex = struct {
    raw: std.atomic.Mutex = .unlocked,

    pub fn tryLock(self: *Mutex) bool {
        return self.raw.tryLock();
    }

    pub fn lock(self: *Mutex) void {
        while (!self.tryLock()) yield();
    }

    pub fn unlock(self: *Mutex) void {
        self.raw.unlock();
    }
};

pub const Condition = struct {
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = self;
        mutex.unlock();
        mutex.lock();
    }

    pub fn signal(self: *Condition) void {
        _ = self;
    }

    pub fn broadcast(self: *Condition) void {
        _ = self;
    }
};

pub const ThreadSpecificKey = struct {};

pub const JoinHandle = struct {
    pub fn join(self: JoinHandle) void {
        _ = self;
    }

    pub fn detach(self: JoinHandle) void {
        _ = self;
    }
};

pub fn initThreadedIo(allocator: std.mem.Allocator, options: ThreadedIoOptions) ThreadedIo {
    return ThreadedIo.init(allocator, options);
}

pub fn threadsSupported() bool {
    return false;
}

pub fn spawn(comptime func: anytype, args: anytype) SpawnError!JoinHandle {
    _ = func;
    _ = args;
    return error.UnsupportedPlatform;
}

pub fn yield() void {
    std.atomic.spinLoopHint();
}

pub fn cpuCount() usize {
    return 1;
}

pub fn currentId() Id {
    return 0;
}

pub fn threadSpecificDestructorPolicy() ThreadSpecificDestructorPolicy {
    return .unsupported;
}

pub fn threadSpecificDestructorsSupported() bool {
    return false;
}

pub fn createThreadSpecificKey(destructor: ThreadSpecificDestructor) ThreadSpecificError!ThreadSpecificKey {
    _ = destructor;
    return error.UnsupportedPlatform;
}

pub fn setThreadSpecificValue(key: ThreadSpecificKey, value: ?*anyopaque) bool {
    _ = key;
    _ = value;
    return false;
}

pub fn getThreadSpecificValue(key: ThreadSpecificKey) ?*anyopaque {
    _ = key;
    return null;
}

test "no-libc thread policy is sequential" {
    try std.testing.expect(!threadsSupported());
    try std.testing.expectEqual(@as(usize, 1), cpuCount());
    try std.testing.expectEqual(@as(Id, 0), currentId());
    try std.testing.expectEqual(ThreadSpecificDestructorPolicy.unsupported, threadSpecificDestructorPolicy());
    try std.testing.expect(!threadSpecificDestructorsSupported());
}
