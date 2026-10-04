const std = @import("std");

/// Raw objects on the compute witness path. Bytes of opaque driver objects are
/// unknown; only buffer payload, device-memory backing and mapped backing have
/// byte units. This does not observe images, raster resources or driver internals.
pub const Resource = enum {
    instance,
    device,
    buffer,
    transfer_buffer,
    backing,
    mapped_backing,
    command_pool,
    command_buffer,
    semaphore,
    descriptor_pool,
    descriptor_set,
    shader,
    descriptor_layout,
    pipeline_layout,
    pipeline,
    query_pool,
};
pub const Route = enum { mapped_upload, staged_upload, mapped_download, staged_download };

pub const Counter = struct {
    attempts: u64 = 0,
    successes: u64 = 0,
    partial_results: u64 = 0,
    failures: u64 = 0,
    releases: u64 = 0,
    rollbacks: u64 = 0,
    live: u64 = 0,
    peak: u64 = 0,
    requested_bytes: u64 = 0,
    successful_bytes: u64 = 0,
    live_bytes: u64 = 0,
    peak_bytes: u64 = 0,
};
pub const MemoryType = struct {
    flags: u32 = 0,
    backing: Counter = .{},
    mapped: Counter = .{},
    suballocations: Counter = .{},
};
pub const Transfer = struct {
    attempts: u64 = 0,
    completions: u64 = 0,
    failures: u64 = 0,
    requested_bytes: u64 = 0,
    completed_bytes: u64 = 0,
};

/// Borrowed by exactly one runtime lifecycle, including failed initialization
/// and teardown. The caller must serialize that runtime's operations under its
/// existing contract and read only at quiescent boundaries. No atomics, locks,
/// allocations or callbacks; an overflowed record cannot establish exact totals.
pub const AllocationObservation = struct {
    overflow: bool = false,
    resources: [std.enums.values(Resource).len]Counter = @splat(.{}),
    memory_types: [32]MemoryType = @splat(.{}),
    suballocations: Counter = .{},
    requirement_bytes: u64 = 0,
    alignment_bytes: u64 = 0,
    transfers: [std.enums.values(Route).len]Transfer = @splat(.{}),
    upload_noops: u64 = 0,
    download_noops: u64 = 0,

    pub fn resource(self: *const AllocationObservation, kind: Resource) Counter {
        return self.resources[@backingInt(kind)];
    }

    pub fn add(self: *AllocationObservation, value: *u64, amount: u64) void {
        const sum = @addWithOverflow(value.*, amount);
        if (sum[1] != 0) self.overflow = true;
        value.* = if (sum[1] != 0) std.math.maxInt(u64) else sum[0];
    }
    fn subtract(self: *AllocationObservation, value: *u64, amount: u64) void {
        if (amount > value.*) self.overflow = true;
        value.* -|= amount;
    }
    fn created(self: *AllocationObservation, counter: *Counter, bytes: u64, partial: bool) void {
        self.add(if (partial) &counter.partial_results else &counter.successes, 1);
        self.add(&counter.live, 1);
        self.add(&counter.successful_bytes, bytes);
        self.add(&counter.live_bytes, bytes);
        counter.peak = @max(counter.peak, counter.live);
        counter.peak_bytes = @max(counter.peak_bytes, counter.live_bytes);
    }
    fn released(self: *AllocationObservation, counter: *Counter, bytes: u64, rollback: bool) void {
        self.add(&counter.releases, 1);
        if (rollback) self.add(&counter.rollbacks, 1);
        self.subtract(&counter.live, 1);
        self.subtract(&counter.live_bytes, bytes);
    }
    pub fn suballocationAttempt(self: *AllocationObservation, size: u64, alignment: u64) void {
        self.add(&self.suballocations.attempts, 1);
        self.add(&self.requirement_bytes, size);
        self.add(&self.alignment_bytes, alignment);
    }
    pub fn suballocationCreated(self: *AllocationObservation, index: u32, size: u64) void {
        std.debug.assert(index < self.memory_types.len);
        self.created(&self.suballocations, size, false);
        self.created(&self.memory_types[index].suballocations, size, false);
    }
    pub fn suballocationReleased(self: *AllocationObservation, index: u32, size: u64) void {
        self.released(&self.suballocations, size, false);
        self.released(&self.memory_types[index].suballocations, size, false);
    }
    pub fn memoryCreated(self: *AllocationObservation, index: u32, flags: u32, size: u64, mapped: bool) void {
        std.debug.assert(index < self.memory_types.len);
        self.memory_types[index].flags = flags;
        self.created(if (mapped) &self.memory_types[index].mapped else &self.memory_types[index].backing, size, false);
    }
    pub fn memoryReleased(self: *AllocationObservation, index: u32, size: u64, mapped: bool, rollback: bool) void {
        self.released(if (mapped) &self.memory_types[index].mapped else &self.memory_types[index].backing, size, rollback);
    }
};

pub fn attempt(observer: ?*AllocationObservation, kind: Resource) void {
    if (observer) |o| o.add(&o.resources[@backingInt(kind)].attempts, 1);
}
pub fn success(observer: ?*AllocationObservation, kind: Resource, bytes: u64) void {
    if (observer) |o| o.created(&o.resources[@backingInt(kind)], bytes, false);
}
pub fn partialResult(observer: ?*AllocationObservation, kind: Resource, bytes: u64) void {
    if (observer) |o| o.created(&o.resources[@backingInt(kind)], bytes, true);
}
pub fn failure(observer: ?*AllocationObservation, kind: Resource) void {
    if (observer) |o| o.add(&o.resources[@backingInt(kind)].failures, 1);
}
pub fn release(observer: ?*AllocationObservation, kind: Resource, bytes: u64, rollback: bool) void {
    if (observer) |o| o.released(&o.resources[@backingInt(kind)], bytes, rollback);
}

/// Records the result of one raw Vulkan call, before wrapper bookkeeping.
pub fn result(observer: ?*AllocationObservation, kind: Resource, bytes: u64, raw: anytype) @TypeOf(raw) {
    attempt(observer, kind);
    if (kind == .buffer or kind == .transfer_buffer) {
        if (observer) |o| o.add(&o.resources[@backingInt(kind)].requested_bytes, bytes);
    }
    if (raw) |_| success(observer, kind, bytes) else |_| failure(observer, kind);
    return raw;
}
pub fn transferAttempt(observer: ?*AllocationObservation, route: Route, bytes: u64) void {
    if (observer) |o| {
        o.add(&o.transfers[@backingInt(route)].attempts, 1);
        o.add(&o.transfers[@backingInt(route)].requested_bytes, bytes);
    }
}
pub fn transferFailure(observer: ?*AllocationObservation, route: Route) void {
    if (observer) |o| o.add(&o.transfers[@backingInt(route)].failures, 1);
}
pub fn transferComplete(observer: ?*AllocationObservation, route: Route, bytes: u64) void {
    if (observer) |o| {
        const counter = &o.transfers[@backingInt(route)];
        o.add(&counter.completions, 1);
        o.add(&counter.completed_bytes, bytes);
    }
}
pub fn noop(observer: ?*AllocationObservation, upload: bool) void {
    if (observer) |o| o.add(if (upload) &o.upload_noops else &o.download_noops, 1);
}
