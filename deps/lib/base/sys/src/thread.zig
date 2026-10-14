const std = @import("std");
const builtin = @import("builtin");
const sys_allocator = @import("allocator.zig");
const capabilities = @import("capabilities.zig");
const cgroup = @import("cgroup.zig");

const linux = std.os.linux;
const native_os = builtin.os.tag;
const posix = std.posix;

pub const required_capabilities = capabilities.host(&.{ .threads, .descriptors, .filesystem });

pub const ThreadSpecificError = error{
    UnsupportedPlatform,
    SystemResources,
};

pub const SpawnError = error{
    UnsupportedPlatform,
    OutOfMemory,
    SystemResources,
};

pub const Placement = struct {
    cpu_id: usize,
    numa_node: usize,
};

pub const PlacementError = error{ UnsupportedPlatform, QueryFailed };
pub const CpuSet = linux.cpu_set_t;
pub const AffinityError = error{ UnsupportedPlatform, QueryFailed, ApplyFailed };

pub const ThreadSpecificDestructor = *const fn (value: *anyopaque) callconv(.c) void;
pub const Id = std.Thread.Id;
pub const ThreadedIo = std.Io.Threaded;
pub const ThreadedIoOptions = std.Io.Threaded.InitOptions;

pub const ThreadSpecificDestructorPolicy = enum {
    unsupported,
    native_spawn_exit,
};

fn threadedIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn initThreadedIo(allocator: std.mem.Allocator, options: ThreadedIoOptions) ThreadedIo {
    return ThreadedIo.init(allocator, options);
}

pub fn initProcessThreadedIo(allocator: std.mem.Allocator) ThreadedIo {
    return ThreadedIo.init(allocator, .{
        .environ = @import("env.zig").processEnviron(),
    });
}

pub const Mutex = struct {
    raw: std.Io.Mutex = .init,

    pub fn tryLock(self: *Mutex) bool {
        return self.raw.tryLock();
    }

    pub fn lock(self: *Mutex) void {
        std.Io.Threaded.mutexLockUncancelable(&self.raw);
    }

    pub fn unlock(self: *Mutex) void {
        std.Io.Threaded.mutexUnlock(&self.raw);
    }
};

pub const Condition = struct {
    raw: std.Io.Condition = .init,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.raw.waitUncancelable(threadedIo(), &mutex.raw);
    }

    pub fn signal(self: *Condition) void {
        self.raw.signal(threadedIo());
    }

    pub fn broadcast(self: *Condition) void {
        self.raw.broadcast(threadedIo());
    }
};

pub const Semaphore = struct {
    raw: std.Io.Semaphore = .{},

    pub fn post(self: *Semaphore) void {
        self.raw.post(threadedIo());
    }

    pub fn wait(self: *Semaphore) void {
        self.raw.waitUncancelable(threadedIo());
    }
};

pub const ThreadSpecificKey = struct {
    index: usize = invalid_thread_specific_key,
};

const invalid_thread_specific_key = std.math.maxInt(usize);
const native_thread_specific_destructor_iterations = 4;

const NativeThreadSpecificRegistry = struct {
    mutex: std.atomic.Mutex = .unlocked,
    destructors: std.ArrayList(ThreadSpecificDestructor) = .empty,

    fn createKey(self: *NativeThreadSpecificRegistry, allocator: std.mem.Allocator, callback: ThreadSpecificDestructor) ThreadSpecificError!ThreadSpecificKey {
        self.lock();
        defer self.mutex.unlock();
        const index = self.destructors.items.len;
        if (index == invalid_thread_specific_key) return error.SystemResources;
        self.destructors.append(allocator, callback) catch return error.SystemResources;
        return .{ .index = index };
    }

    fn destructor(self: *NativeThreadSpecificRegistry, key_index: usize) ?ThreadSpecificDestructor {
        self.lock();
        defer self.mutex.unlock();
        if (key_index >= self.destructors.items.len) return null;
        return self.destructors.items[key_index];
    }

    fn lock(self: *NativeThreadSpecificRegistry) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

const NativeThreadSpecificValues = struct {
    values: std.ArrayList(?*anyopaque) = .empty,

    fn set(self: *NativeThreadSpecificValues, allocator: std.mem.Allocator, key: ThreadSpecificKey, value: ?*anyopaque) bool {
        if (key.index == invalid_thread_specific_key) return false;
        if (value == null and key.index >= self.values.items.len) return true;
        while (self.values.items.len <= key.index) {
            self.values.append(allocator, null) catch return false;
        }
        self.values.items[key.index] = value;
        return true;
    }

    fn get(self: *NativeThreadSpecificValues, key: ThreadSpecificKey) ?*anyopaque {
        if (key.index == invalid_thread_specific_key or key.index >= self.values.items.len) return null;
        return self.values.items[key.index];
    }

    fn runDestructors(self: *NativeThreadSpecificValues, allocator: std.mem.Allocator) void {
        defer {
            self.values.deinit(allocator);
            self.* = .{};
        }

        var iteration: usize = 0;
        while (iteration < native_thread_specific_destructor_iterations) : (iteration += 1) {
            var called = false;
            var index: usize = 0;
            while (index < self.values.items.len) : (index += 1) {
                const value = self.values.items[index] orelse continue;
                const destructor = native_thread_specific_registry.destructor(index) orelse continue;
                self.values.items[index] = null;
                called = true;
                destructor(value);
            }
            if (!called) break;
        }
    }
};

var native_thread_specific_registry: NativeThreadSpecificRegistry = .{};
threadlocal var native_thread_specific_values: NativeThreadSpecificValues = .{};

pub const JoinHandle = struct {
    raw: std.Thread,

    pub fn join(self: JoinHandle) void {
        self.raw.join();
    }

    pub fn detach(self: JoinHandle) void {
        self.raw.detach();
    }

    pub fn setName(
        self: JoinHandle,
        name: []const u8,
    ) std.Thread.SetNameError!void {
        try self.raw.setName(std.Options.debug_io, name);
    }
};

pub fn blockUntilDifferent(
    previous: u32,
    current: *const std.atomic.Value(u32),
) u32 {
    while (true) {
        const next = current.load(.acquire);
        if (next != previous) return next;
        std.Io.futexWaitUncancelable(threadedIo(), u32, &current.raw, previous);
    }
}

pub fn wakeAll(current: *std.atomic.Value(u32)) void {
    std.Io.futexWake(threadedIo(), u32, &current.raw, std.math.maxInt(u32));
}

pub fn threadsSupported() bool {
    return comptime capabilities.current.supportsThreads();
}

pub fn spawn(comptime func: anytype, args: anytype) SpawnError!JoinHandle {
    return spawnWithStack(std.Thread.SpawnConfig.default_stack_size, func, args);
}

/// Spawns as `spawn` does, on a stack of `stack_bytes` for a thread whose stack is budgeted.
pub fn spawnWithStack(
    stack_bytes: usize,
    comptime func: anytype,
    args: anytype,
) SpawnError!JoinHandle {
    if (comptime !threadsSupported()) return error.UnsupportedPlatform;
    const Runner = struct {
        fn run(captured_args: @TypeOf(args)) void {
            defer runNativeThreadSpecificDestructors();
            _ = @call(.auto, func, captured_args);
        }
    };
    const config: std.Thread.SpawnConfig = .{ .stack_size = stack_bytes };
    return .{ .raw = std.Thread.spawn(config, Runner.run, .{args}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SystemResources,
    } };
}

pub fn yield() void {
    if (comptime !threadsSupported()) return;
    std.Thread.yield() catch {};
}

/// The CPUs this thread may run on: the count of its affinity set. A CPU
/// quota does not lower it, because a quota throttles threads over each period
/// without limiting how many run at once. Size a worker pool by `parallelism`.
pub fn cpuCount() usize {
    if (comptime !threadsSupported()) return 1;
    return std.Thread.getCpuCount() catch 1;
}

/// The workers that can keep busy without exceeding this process's CPU time:
/// `cpuCount`, lowered on Linux to the tightest cgroup v2 `cpu.max` quota on
/// the process's group or any ancestor, in whole CPUs rounded up. A host
/// without a readable quota gives `cpuCount`. Each call reads the hierarchy
/// again, a few files per level, so a limit changed at run time takes effect
/// at the next call.
pub fn parallelism() usize {
    const affinity = cpuCount();
    if (comptime native_os != .linux or !threadsSupported()) return affinity;
    const limit = (cgroup.cpuLimit() catch null) orelse return affinity;
    std.debug.assert(limit >= 1);
    const workers = @min(affinity, std.math.cast(usize, limit) orelse affinity);
    std.debug.assert(workers >= 1);
    std.debug.assert(workers <= affinity);
    return workers;
}

pub fn currentId() Id {
    if (comptime !threadsSupported()) return 0;
    return std.Thread.getCurrentId();
}

pub fn currentPlacement() PlacementError!Placement {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    var cpu_id: usize = 0;
    var numa_node: usize = 0;
    return switch (linux.errno(linux.getcpu(&cpu_id, &numa_node))) {
        .SUCCESS => .{ .cpu_id = cpu_id, .numa_node = numa_node },
        .NOSYS => error.UnsupportedPlatform,
        else => error.QueryFailed,
    };
}

pub fn currentAffinity() AffinityError!CpuSet {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    return posix.sched_getaffinity(0) catch return error.QueryFailed;
}

pub fn setCurrentAffinity(set: *const CpuSet) AffinityError!void {
    if (comptime native_os != .linux) return error.UnsupportedPlatform;
    linux.sched_setaffinity(0, set) catch return error.ApplyFailed;
}

pub fn threadSpecificDestructorPolicy() ThreadSpecificDestructorPolicy {
    if (comptime threadsSupported()) return .native_spawn_exit;
    return .unsupported;
}

pub fn threadSpecificDestructorsSupported() bool {
    return threadSpecificDestructorPolicy() != .unsupported;
}

pub fn createThreadSpecificKey(destructor: ThreadSpecificDestructor) ThreadSpecificError!ThreadSpecificKey {
    if (comptime !threadSpecificDestructorsSupported()) return error.UnsupportedPlatform;
    return native_thread_specific_registry.createKey(sys_allocator.processAllocator(), destructor);
}

pub fn setThreadSpecificValue(key: ThreadSpecificKey, value: ?*anyopaque) bool {
    if (comptime !threadSpecificDestructorsSupported()) return false;
    return native_thread_specific_values.set(sys_allocator.processAllocator(), key, value);
}

pub fn getThreadSpecificValue(key: ThreadSpecificKey) ?*anyopaque {
    if (comptime !threadSpecificDestructorsSupported()) return null;
    return native_thread_specific_values.get(key);
}

fn runNativeThreadSpecificDestructors() void {
    if (comptime !threadSpecificDestructorsSupported()) return;
    native_thread_specific_values.runDestructors(sys_allocator.processAllocator());
}

const FutexProbe = struct {
    current: *std.atomic.Value(u32),
    ready: *std.atomic.Value(bool),
    observed: *u32,

    fn wait(self: FutexProbe) void {
        self.ready.store(true, .release);
        self.observed.* = blockUntilDifferent(7, self.current);
    }
};

const ThreadSpecificProbe = struct {
    fn destroy(value: *anyopaque) callconv(.c) void {
        const counter: *std.atomic.Value(usize) = @ptrCast(@alignCast(value));
        _ = counter.fetchAdd(1, .monotonic);
    }

    fn setValue(key: ThreadSpecificKey, counter: *std.atomic.Value(usize)) void {
        if (!setThreadSpecificValue(key, counter)) @panic("thread specific set failed");
    }

    fn isolate(key: ThreadSpecificKey, expected_missing: *bool, value: *usize, result: *usize) void {
        expected_missing.* = getThreadSpecificValue(key) == null;
        if (!setThreadSpecificValue(key, value)) @panic("thread specific set failed");
        result.* = @intFromPtr(getThreadSpecificValue(key) orelse return);
    }
};
