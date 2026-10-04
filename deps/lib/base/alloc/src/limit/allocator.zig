const std = @import("std");
const sys = @import("sys");

const Allocator = std.mem.Allocator;

pub const LimitAllocator = struct {
    backing: Allocator,
    capacity: usize,
    mutex: sys.thread.Mutex = .{},
    live_bytes: usize = 0,
    reserved_bytes: usize = 0,
    peak_live_bytes: usize = 0,
    denied_allocations: u64 = 0,

    pub const ClassifiedError = error{
        OutOfMemory,
        AllocationLimitExceeded,
    };

    pub const Request = struct {
        meter: *LimitAllocator,
        failure: Failure = .none,

        const Failure = enum {
            none,
            capacity,
            backing,
        };

        pub fn init(meter: *LimitAllocator) Request {
            return .{ .meter = meter };
        }

        pub fn allocator(self: *Request) Allocator {
            return .{ .ptr = self, .vtable = &Request.vtable };
        }

        pub fn reset(self: *Request) void {
            self.failure = .none;
        }

        pub fn classify(
            self: *const Request,
            err: Allocator.Error,
        ) ClassifiedError {
            std.debug.assert(err == error.OutOfMemory);
            return switch (self.failure) {
                .capacity => error.AllocationLimitExceeded,
                .none, .backing => error.OutOfMemory,
            };
        }

        const vtable: Allocator.VTable = .{
            .alloc = Request.rawAlloc,
            .resize = Request.rawResize,
            .remap = Request.rawRemap,
            .free = Request.rawFree,
        };

        fn rawAlloc(
            context: *anyopaque,
            len: usize,
            alignment: std.mem.Alignment,
            return_address: usize,
        ) ?[*]u8 {
            const self: *Request = @ptrCast(@alignCast(context));
            const pointer = self.meter.rawAllocClassified(
                len,
                alignment,
                return_address,
            ) catch |err| {
                self.failure = switch (err) {
                    error.AllocationLimitExceeded => .capacity,
                    error.OutOfMemory => .backing,
                };
                return null;
            };
            self.failure = .none;
            return pointer;
        }

        fn rawResize(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) bool {
            const self: *Request = @ptrCast(@alignCast(context));
            self.meter.rawResizeClassified(
                memory,
                alignment,
                new_len,
                return_address,
            ) catch |err| {
                self.failure = switch (err) {
                    error.AllocationLimitExceeded => .capacity,
                    error.OutOfMemory => .backing,
                };
                return false;
            };
            self.failure = .none;
            return true;
        }

        fn rawRemap(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            return_address: usize,
        ) ?[*]u8 {
            const self: *Request = @ptrCast(@alignCast(context));
            const pointer = self.meter.rawRemapClassified(
                memory,
                alignment,
                new_len,
                return_address,
            ) catch |err| {
                self.failure = switch (err) {
                    error.AllocationLimitExceeded => .capacity,
                    error.OutOfMemory => .backing,
                };
                return null;
            };
            self.failure = .none;
            return pointer;
        }

        fn rawFree(
            context: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            return_address: usize,
        ) void {
            const self: *Request = @ptrCast(@alignCast(context));
            self.meter.backing.rawFree(
                memory,
                alignment,
                return_address,
            );
            self.meter.release(memory.len);
        }
    };

    pub const Snapshot = struct {
        capacity_bytes: usize,
        live_bytes: usize,
        reserved_bytes: usize,
        peak_live_bytes: usize,
        denied_allocations: u64,
    };

    pub fn init(backing: Allocator, capacity: usize) LimitAllocator {
        return .{ .backing = backing, .capacity = capacity };
    }

    pub fn allocator(self: *LimitAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn allocClassified(
        self: *LimitAllocator,
        comptime T: type,
        count: usize,
    ) ClassifiedError![]T {
        return try self.alignedAllocClassified(T, null, count);
    }

    pub fn alignedAllocClassified(
        self: *LimitAllocator,
        comptime T: type,
        comptime optional_alignment: ?std.mem.Alignment,
        count: usize,
    ) ClassifiedError![]align(if (optional_alignment) |alignment|
        alignment.toByteUnits()
    else
        @alignOf(T)) T {
        const alignment = optional_alignment orelse comptime std.mem.Alignment.of(T);
        const len = std.math.mul(
            usize,
            @sizeOf(T),
            count,
        ) catch return error.OutOfMemory;
        if (len == 0) {
            const address = comptime alignment.backward(
                std.math.maxInt(usize),
            );
            const pointer: [*]align(alignment.toByteUnits()) T =
                @ptrFromInt(address);
            return pointer[0..count];
        }
        const pointer: [*]align(alignment.toByteUnits()) T = @ptrCast(
            @alignCast(try self.rawAllocClassified(
                len,
                alignment,
                @returnAddress(),
            )),
        );
        return pointer[0..count];
    }

    pub fn createClassified(
        self: *LimitAllocator,
        comptime T: type,
    ) ClassifiedError!*T {
        if (@sizeOf(T) == 0) {
            const address = comptime std.mem.alignBackward(
                usize,
                std.math.maxInt(usize),
                @alignOf(T),
            );
            return @ptrFromInt(address);
        }
        const pointer: *T = @ptrCast(
            @alignCast(try self.rawAllocClassified(
                @sizeOf(T),
                .of(T),
                @returnAddress(),
            )),
        );
        return pointer;
    }

    pub fn deinit(self: *LimitAllocator) void {
        self.mutex.lock();
        std.debug.assert(self.live_bytes == 0);
        std.debug.assert(self.reserved_bytes == 0);
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn snapshot(self: *const LimitAllocator) Snapshot {
        const mutable = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        return .{
            .capacity_bytes = self.capacity,
            .live_bytes = self.live_bytes,
            .reserved_bytes = self.reserved_bytes,
            .peak_live_bytes = self.peak_live_bytes,
            .denied_allocations = self.denied_allocations,
        };
    }

    pub fn liveBytes(self: *const LimitAllocator) usize {
        const mutable = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        return self.live_bytes;
    }

    pub fn remainingBytes(self: *const LimitAllocator) usize {
        const mutable = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        return self.capacity - self.live_bytes - self.reserved_bytes;
    }

    pub fn capacityBytes(self: *const LimitAllocator) usize {
        return self.capacity;
    }

    pub fn peakLiveBytes(self: *const LimitAllocator) usize {
        const mutable = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        return self.peak_live_bytes;
    }

    pub fn deniedAllocations(self: *const LimitAllocator) u64 {
        const mutable = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        return self.denied_allocations;
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };

    fn rawAlloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *LimitAllocator = @ptrCast(@alignCast(context));
        return self.rawAllocClassified(
            len,
            alignment,
            return_address,
        ) catch null;
    }

    fn rawAllocClassified(
        self: *LimitAllocator,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ClassifiedError![*]u8 {
        if (!self.reserve(len)) return error.AllocationLimitExceeded;
        const pointer = self.backing.rawAlloc(
            len,
            alignment,
            return_address,
        ) orelse {
            self.cancel(len);
            return error.OutOfMemory;
        };
        self.commit(len);
        return pointer;
    }

    fn rawResize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *LimitAllocator = @ptrCast(@alignCast(context));
        self.rawResizeClassified(
            memory,
            alignment,
            new_len,
            return_address,
        ) catch return false;
        return true;
    }

    fn rawResizeClassified(
        self: *LimitAllocator,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ClassifiedError!void {
        if (new_len <= memory.len) {
            if (!self.backing.rawResize(
                memory,
                alignment,
                new_len,
                return_address,
            )) return error.OutOfMemory;
            self.release(memory.len - new_len);
            return;
        }
        const growth = new_len - memory.len;
        if (!self.reserve(growth)) {
            return error.AllocationLimitExceeded;
        }
        if (self.backing.rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        )) {
            self.commit(growth);
            return;
        }
        self.cancel(growth);
        return error.OutOfMemory;
    }

    fn rawRemap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *LimitAllocator = @ptrCast(@alignCast(context));
        return self.rawRemapClassified(
            memory,
            alignment,
            new_len,
            return_address,
        ) catch null;
    }

    fn rawRemapClassified(
        self: *LimitAllocator,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ClassifiedError![*]u8 {
        if (new_len <= memory.len) {
            const remapped = self.backing.rawRemap(
                memory,
                alignment,
                new_len,
                return_address,
            ) orelse return error.OutOfMemory;
            self.release(memory.len - new_len);
            return remapped;
        }
        const growth = new_len - memory.len;
        if (!self.reserve(growth)) {
            return error.AllocationLimitExceeded;
        }
        const pointer = self.backing.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse {
            self.cancel(growth);
            return error.OutOfMemory;
        };
        self.commit(growth);
        return pointer;
    }

    fn rawFree(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *LimitAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, return_address);
        self.release(memory.len);
    }

    fn reserve(self: *LimitAllocator, bytes: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (bytes > self.capacity - self.live_bytes - self.reserved_bytes) {
            self.denied_allocations +|= 1;
            return false;
        }
        self.reserved_bytes += bytes;
        return true;
    }

    fn commit(self: *LimitAllocator, bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(bytes <= self.reserved_bytes);
        self.reserved_bytes -= bytes;
        self.live_bytes += bytes;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
    }

    fn cancel(self: *LimitAllocator, bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(bytes <= self.reserved_bytes);
        self.reserved_bytes -= bytes;
    }

    fn release(self: *LimitAllocator, bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(bytes <= self.live_bytes);
        self.live_bytes -= bytes;
    }
};
