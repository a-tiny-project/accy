const std = @import("std");
const sys = @import("sys");

const runtime = @import("root.zig");
const foundation = sys.apple.foundation;
const metal = sys.apple.metal;
const objc = sys.apple.objc;

const native_available = metal.available;

pub const Stream = struct {
    command_queue: metal.CommandQueue,
    last_command_buffer: ?metal.CommandBuffer = null,
    failed: bool = false,

    pub fn init(device: metal.Device) runtime.Error!Stream {
        if (comptime !native_available) return error.UnsupportedPlatform;
        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const command_queue = metal.newCommandQueue(device) orelse return error.RuntimeUnavailable;
        return .{ .command_queue = command_queue };
    }

    pub fn deinit(self: *Stream) void {
        if (comptime !native_available) return;
        if (self.last_command_buffer) |command_buffer| objc.release(command_buffer);
        objc.release(self.command_queue);
        self.* = undefined;
    }

    pub fn replaceLastCommandBuffer(self: *Stream, command_buffer: metal.CommandBuffer) void {
        const retained = objc.retain(command_buffer);
        if (self.last_command_buffer) |previous| objc.release(previous);
        self.last_command_buffer = retained;
    }

    pub fn synchronize(self: *Stream) runtime.Error!void {
        if (comptime !native_available) return error.UnsupportedPlatform;
        if (self.failed) return error.LaunchFailed;
        const command_buffer = self.last_command_buffer orelse return;
        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        metal.waitUntilCompleted(command_buffer);
        commandBufferResult(command_buffer) catch |err| {
            self.failed = true;
            return err;
        };
    }
};

const SignalSequence = struct {
    next: u64 = 1,

    fn reserve(self: *SignalSequence) runtime.Error!u64 {
        const value = self.next;
        self.next = std.math.add(u64, self.next, 1) catch return error.InvalidEvent;
        return value;
    }
};

pub const Event = struct {
    event: metal.SharedEvent,
    sequence: SignalSequence = .{},
    value: u64 = 0,
    command_buffer: ?metal.CommandBuffer = null,
    recorded: bool = false,

    pub fn init(device: metal.Device) runtime.Error!Event {
        if (comptime !native_available) return error.UnsupportedPlatform;
        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const event = metal.newSharedEvent(device) orelse return error.RuntimeUnavailable;
        metal.setSignaledValue(event, 0);
        return .{ .event = event };
    }

    pub fn deinit(self: *Event) void {
        if (comptime !native_available) return;
        if (self.command_buffer) |command_buffer| objc.release(command_buffer);
        objc.release(self.event);
        self.* = undefined;
    }

    pub fn reserveSignal(self: *Event) runtime.Error!u64 {
        return self.sequence.reserve();
    }

    pub fn replaceCommandBuffer(self: *Event, command_buffer: metal.CommandBuffer) void {
        const retained = objc.retain(command_buffer);
        if (self.command_buffer) |previous| objc.release(previous);
        self.command_buffer = retained;
    }

    pub fn record(self: *Event, stream: *Stream) runtime.Error!void {
        if (comptime !native_available) return error.UnsupportedPlatform;
        if (stream.failed) return error.LaunchFailed;
        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const command_buffer = metal.commandBuffer(stream.command_queue) orelse return error.LaunchFailed;
        const signal_value = try self.reserveSignal();
        metal.encodeSignalEvent(command_buffer, self.event, signal_value);
        metal.commit(command_buffer);
        self.value = signal_value;
        self.recorded = true;
        stream.replaceLastCommandBuffer(command_buffer);
        self.replaceCommandBuffer(command_buffer);
    }

    pub fn synchronize(self: *Event) runtime.Error!void {
        if (comptime !native_available) return error.UnsupportedPlatform;
        if (!self.recorded) return error.InvalidEvent;
        if (metal.signaledValue(self.event) >= self.value) return;
        const command_buffer = self.command_buffer orelse return error.InvalidEvent;
        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        metal.waitUntilCompleted(command_buffer);
        try commandBufferResult(command_buffer);
        if (metal.signaledValue(self.event) < self.value) return error.LaunchFailed;
    }

    pub fn query(self: *Event) runtime.Error!bool {
        if (comptime !native_available) return error.UnsupportedPlatform;
        if (!self.recorded) return false;
        return metal.signaledValue(self.event) >= self.value;
    }
};

pub const LoadedKernel = struct {
    pipeline: metal.ComputePipelineState,
    argument_count: u32,

    pub fn deinit(self: *LoadedKernel) void {
        if (comptime !native_available) return;
        objc.release(self.pipeline);
        self.* = undefined;
    }
};

pub const DeviceBuffer = struct {
    buffer: metal.Buffer,
    byte_size: usize,

    pub fn deinit(self: *DeviceBuffer) void {
        if (comptime !native_available) return;
        objc.release(self.buffer);
        self.* = undefined;
    }

    pub fn write(self: *DeviceBuffer, bytes: []const u8) runtime.Error!void {
        if (comptime !native_available) return error.UnsupportedPlatform;
        if (bytes.len > self.byte_size) return error.InvalidBuffer;
        if (bytes.len == 0) return;
        const contents = metal.bufferContents(self.buffer) orelse return error.RuntimeUnavailable;
        const destination: [*]u8 = @ptrCast(contents);
        @memcpy(destination[0..bytes.len], bytes);
    }

    pub fn read(self: *DeviceBuffer, bytes: []u8) runtime.Error!void {
        if (comptime !native_available) return error.UnsupportedPlatform;
        if (bytes.len > self.byte_size) return error.InvalidBuffer;
        if (bytes.len == 0) return;
        const contents = metal.bufferContents(self.buffer) orelse return error.RuntimeUnavailable;
        const source: [*]const u8 = @ptrCast(contents);
        @memcpy(bytes, source[0..bytes.len]);
    }
};

fn commandBufferResult(command_buffer: metal.CommandBuffer) runtime.Error!void {
    if (comptime !native_available) return error.UnsupportedPlatform;
    if (metal.commandBufferStatus(command_buffer) == .completed) return;
    const native_error = metal.commandBufferError(command_buffer) orelse return error.LaunchFailed;
    return commandBufferErrorCode(foundation.errorCode(native_error));
}

fn commandBufferErrorCode(code: foundation.NSInteger) runtime.Error!void {
    if (code < 0) return error.LaunchFailed;
    const native_error: metal.CommandBufferError = @fromBackingInt(@intCast(@as(foundation.NSUInteger, @intCast(code))));
    return switch (native_error) {
        .access_revoked, .device_removed => error.DeviceLost,
        .out_of_memory => error.OutOfMemory,
        else => error.LaunchFailed,
    };
}

test "Metal user event signals stay monotonic across stream changes" {
    var sequence: SignalSequence = .{};
    const first_stream_value = try sequence.reserve();
    const busy_stream_value = try sequence.reserve();
    const lower_counter_stream_value = try sequence.reserve();
    try std.testing.expectEqual(@as(u64, 1), first_stream_value);
    try std.testing.expectEqual(@as(u64, 2), busy_stream_value);
    try std.testing.expectEqual(@as(u64, 3), lower_counter_stream_value);
}

test "Metal user event signal exhaustion never wraps" {
    var sequence = SignalSequence{ .next = std.math.maxInt(u64) };
    try std.testing.expectError(error.InvalidEvent, sequence.reserve());
    try std.testing.expectEqual(std.math.maxInt(u64), sequence.next);
}

test "Metal command buffer errors preserve device and memory failures" {
    try std.testing.expectError(error.DeviceLost, commandBufferErrorCode(@intCast(@backingInt(metal.CommandBufferError.device_removed))));
    try std.testing.expectError(error.DeviceLost, commandBufferErrorCode(@intCast(@backingInt(metal.CommandBufferError.access_revoked))));
    try std.testing.expectError(error.OutOfMemory, commandBufferErrorCode(@intCast(@backingInt(metal.CommandBufferError.out_of_memory))));
    try std.testing.expectError(error.LaunchFailed, commandBufferErrorCode(@intCast(@backingInt(metal.CommandBufferError.internal))));
    try std.testing.expectError(error.LaunchFailed, commandBufferErrorCode(-1));
}
