const sys = @import("sys");
const composition = @import("../root.zig");

const source = composition.source;

pub const LifecycleEvent = union(enum) {
    invocation_destroyed: u64,
    fragment_destroyed: source.FragmentId,
    composition_destroyed,
};

pub const LifecycleObserver = struct {
    ptr: *anyopaque,
    record_fn: *const fn (*anyopaque, LifecycleEvent) void,

    pub fn record(self: LifecycleObserver, event: LifecycleEvent) void {
        self.record_fn(self.ptr, event);
    }
};

pub const Recorder = struct {
    mutex: sys.thread.Mutex = .{},
    target: ?LifecycleObserver,

    pub fn init(target: ?LifecycleObserver) Recorder {
        return .{ .target = target };
    }

    pub fn record(self: *Recorder, event: LifecycleEvent) void {
        const target = self.target orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();
        target.record(event);
    }

    pub fn serialized(self: *Recorder) ?LifecycleObserver {
        if (self.target == null) return null;
        return .{
            .ptr = self,
            .record_fn = recordSerialized,
        };
    }

    fn recordSerialized(ptr: *anyopaque, event: LifecycleEvent) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.record(event);
    }
};
