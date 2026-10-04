const std = @import("std");
const sys = @import("sys");

const runtime = @import("root.zig");
const Allocator = std.mem.Allocator;
const dispatch = sys.apple.dispatch;
const foundation = sys.apple.foundation;
const metal = sys.apple.metal;
const objc = sys.apple.objc;

const native_available = metal.available;

/// A library's code: MSL text the runtime compiles, or a metallib built ahead of time.
pub const LibrarySource = union(enum) {
    msl: []const u8,
    metallib: []const u8,
};

pub const SequenceDispatch = struct {
    kernel: *runtime.LoadedKernel,
    buffers: []const *runtime.DeviceBuffer,
    scalars: []const runtime.ScalarArgument,
    grid: [3]u32,
    threadgroup: [3]u32,
};

/// The text of the last compiler or pipeline error, truncated, for a caller to report.
pub const CompileLog = struct {
    bytes: [2048]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const CompileLog) []const u8 {
        return self.bytes[0..self.len];
    }

    fn record(self: *CompileLog, native_error: ?foundation.Error) void {
        self.len = 0;
        const described = native_error orelse return;
        const description = foundation.errorDescription(described) orelse return;
        const bytes = std.mem.span(foundation.utf8(description) orelse return);
        self.len = @min(bytes.len, self.bytes.len);
        @memcpy(self.bytes[0..self.len], bytes[0..self.len]);
    }
};

pub const Runtime = struct {
    allocator: Allocator,
    device: metal.Device,
    default_stream: ?*runtime.Stream = null,
    live_streams: std.AutoHashMapUnmanaged(*runtime.Stream, void) = .{},
    live_events: std.AutoHashMapUnmanaged(*runtime.Event, void) = .{},
    compile_log: CompileLog = .{},
    /// How the last library compiled from source treated floating point.
    math_setting: ?metal.MathSetting = null,
    /// One sampler per filter and address mode, made on first use.
    samplers: [2][2]?metal.SamplerState = @splat(@splat(null)),

    pub fn init(allocator: Allocator) runtime.Error!Runtime {
        if (comptime !native_available) return error.UnsupportedPlatform;

        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const device = metal.systemDefaultDevice() orelse return error.DeviceUnavailable;
        errdefer objc.release(device);
        const queue = metal.newCommandQueue(device) orelse return error.RuntimeUnavailable;
        objc.release(queue);
        return .{
            .allocator = allocator,
            .device = device,
        };
    }

    pub fn deinit(self: *Runtime) void {
        if (comptime !native_available) return;
        var event_it = self.live_events.keyIterator();
        while (event_it.next()) |event| {
            event.*.deinit();
            self.allocator.destroy(event.*);
        }
        self.live_events.deinit(self.allocator);
        var stream_it = self.live_streams.keyIterator();
        while (stream_it.next()) |stream| {
            stream.*.deinit();
            self.allocator.destroy(stream.*);
        }
        self.live_streams.deinit(self.allocator);
        for (self.samplers) |row| for (row) |entry| if (entry) |owned| objc.release(owned);
        if (self.default_stream) |stream| {
            stream.deinit();
            self.allocator.destroy(stream);
        }
        objc.release(self.device);
        self.* = undefined;
    }

    pub fn loadMsl(
        self: *Runtime,
        source: []const u8,
        entry_name: []const u8,
        argument_count: u32,
    ) runtime.Error!runtime.LoadedKernel {
        if (comptime !native_available) return error.UnsupportedPlatform;
        if (source.len == 0 or entry_name.len == 0) return error.InvalidArtifact;

        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const entry_string = foundation.stringFromBytes(entry_name) orelse return error.InvalidArtifact;
        defer objc.release(entry_string);
        const library = try self.newLibrary(.{ .msl = source });
        defer objc.release(library);
        return self.createKernel(library, entry_string, argument_count);
    }

    /// Compiles MSL with fast math off, as the owner's float model requires, or loads a metallib,
    /// which keeps the flags it was built with. The caller releases the library and holds an
    /// autorelease pool.
    pub fn newLibrary(self: *Runtime, source: LibrarySource) runtime.Error!metal.Library {
        if (comptime !native_available) return error.UnsupportedPlatform;
        var compile_error: ?foundation.Error = null;
        switch (source) {
            .msl => |text| {
                if (text.len == 0) return error.InvalidArtifact;
                const source_string = foundation.stringFromBytes(text) orelse return error.InvalidArtifact;
                defer objc.release(source_string);
                var setting: metal.MathSetting = undefined;
                const options = metal.newSafeCompileOptions(&setting) orelse return error.RuntimeUnavailable;
                defer objc.release(options);
                self.math_setting = setting;
                return metal.newLibraryWithSource(self.device, source_string, options, &compile_error) orelse {
                    self.compile_log.record(compile_error);
                    return error.CompilationFailed;
                };
            },
            .metallib => |bytes| {
                if (bytes.len == 0) return error.InvalidArtifact;
                const library_data = dispatch.copiedData(bytes) orelse return error.OutOfMemory;
                defer dispatch.release(library_data);
                return metal.newLibraryWithData(self.device, library_data, &compile_error) orelse {
                    self.compile_log.record(compile_error);
                    return error.CompilationFailed;
                };
            },
        }
    }

    /// Records the error a pipeline build returned, for `compile_log`.
    pub fn recordCompileError(self: *Runtime, native_error: ?foundation.Error) void {
        self.compile_log.record(native_error);
    }

    /// The runtime's sampler for `filter` and `address`, which it keeps until it ends.
    pub fn sampler(self: *Runtime, filter: metal.SamplerFilter, address: metal.SamplerAddressMode) runtime.Error!metal.SamplerState {
        if (comptime !native_available) return error.UnsupportedPlatform;
        const slot = &self.samplers[@intFromBool(filter == .linear)][@intFromBool(address == .repeat)];
        if (slot.*) |existing| return existing;
        const created = metal.newSamplerState(self.device, filter, address) orelse return error.OutOfMemory;
        slot.* = created;
        return created;
    }

    pub fn loadMetallib(
        self: *Runtime,
        bytes: []const u8,
        entry_name: []const u8,
        argument_count: u32,
    ) runtime.Error!runtime.LoadedKernel {
        if (comptime !native_available) return error.UnsupportedPlatform;
        if (bytes.len == 0 or entry_name.len == 0) return error.InvalidArtifact;

        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const entry_string = foundation.stringFromBytes(entry_name) orelse return error.InvalidArtifact;
        defer objc.release(entry_string);
        const library = try self.newLibrary(.{ .metallib = bytes });
        defer objc.release(library);
        return self.createKernel(library, entry_string, argument_count);
    }

    fn createKernel(
        self: *Runtime,
        library: metal.Library,
        entry_string: foundation.String,
        argument_count: u32,
    ) runtime.Error!runtime.LoadedKernel {
        if (comptime !native_available) return error.UnsupportedPlatform;
        const function = metal.newFunction(library, entry_string) orelse return error.CompilationFailed;
        defer objc.release(function);
        var pipeline_error: ?foundation.Error = null;
        const pipeline = metal.newComputePipelineState(
            self.device,
            function,
            &pipeline_error,
        ) orelse return error.CompilationFailed;
        return .{
            .pipeline = pipeline,
            .argument_count = argument_count,
        };
    }

    pub fn allocBuffer(self: *Runtime, byte_size: usize) runtime.Error!runtime.DeviceBuffer {
        if (comptime !native_available) return error.UnsupportedPlatform;
        if (byte_size == 0) return error.InvalidBuffer;

        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const buffer = metal.newBuffer(self.device, byte_size) orelse return error.OutOfMemory;
        return .{
            .buffer = buffer,
            .byte_size = byte_size,
        };
    }

    pub fn launch(
        self: *Runtime,
        kernel: *runtime.LoadedKernel,
        buffers: []const *runtime.DeviceBuffer,
        scalars: []const runtime.ScalarArgument,
        stream: ?*runtime.Stream,
        wait_events: []const *runtime.Event,
        signal_event: ?*runtime.Event,
        grid: [3]u32,
        threadgroup: [3]u32,
    ) runtime.Error!void {
        if (comptime !native_available) return error.UnsupportedPlatform;
        const argument_count = buffers.len + scalars.len;
        if (argument_count != kernel.argument_count) return error.InvalidBuffer;
        if (argument_count > runtime.max_kernel_arguments) return error.InvalidBuffer;
        if (wait_events.len > runtime.max_kernel_arguments) return error.InvalidEvent;
        for (grid) |dimension| if (dimension == 0) return error.LaunchFailed;
        for (threadgroup) |dimension| if (dimension == 0) return error.LaunchFailed;
        for (wait_events) |event| if (!event.recorded) return error.InvalidEvent;

        const actual_stream = stream orelse try self.defaultStream();
        if (actual_stream.failed) return error.LaunchFailed;
        const synchronize_after_launch = stream == null and wait_events.len == 0 and signal_event == null;

        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const command_buffer = metal.commandBuffer(actual_stream.command_queue) orelse return error.LaunchFailed;
        for (wait_events) |event| {
            metal.encodeWaitForEvent(command_buffer, event.event, event.value);
        }
        const encoder = metal.computeCommandEncoder(command_buffer) orelse return error.LaunchFailed;
        metal.setComputePipelineState(encoder, kernel.pipeline);
        for (buffers, 0..) |buffer, index| {
            metal.setBuffer(encoder, buffer.buffer, 0, @intCast(index));
        }
        for (scalars, 0..) |*scalar, index| {
            metal.setBytes(
                encoder,
                @ptrCast(&scalar.bits),
                scalar.byteSize(),
                @intCast(buffers.len + index),
            );
        }
        metal.dispatchThreadgroups(
            encoder,
            sizeFromDimensions(grid),
            sizeFromDimensions(threadgroup),
        );
        metal.endEncoding(encoder);

        const signal_value = if (signal_event) |event| try event.reserveSignal() else null;
        if (signal_event) |event| {
            metal.encodeSignalEvent(command_buffer, event.event, signal_value.?);
        }
        metal.commit(command_buffer);

        actual_stream.replaceLastCommandBuffer(command_buffer);
        if (signal_event) |event| {
            event.value = signal_value.?;
            event.recorded = true;
            event.replaceCommandBuffer(command_buffer);
        }

        if (synchronize_after_launch) try actual_stream.synchronize();
    }

    /// Re-encoding creates Metal driver objects each replay, but uses no Zig heap.
    pub fn launchSequence(
        self: *Runtime,
        dispatches: []const SequenceDispatch,
        stream: ?*runtime.Stream,
        wait_events: []const *runtime.Event,
        signal_event: ?*runtime.Event,
        failed_index: *?usize,
    ) runtime.Error!void {
        if (comptime !native_available) return error.UnsupportedPlatform;
        std.debug.assert(dispatches.len > 0);
        failed_index.* = null;
        for (dispatches, 0..) |entry, index| {
            failed_index.* = index;
            if (entry.buffers.len + entry.scalars.len != entry.kernel.argument_count) return error.InvalidBuffer;
            for (entry.grid) |dimension| if (dimension == 0) return error.LaunchFailed;
            for (entry.threadgroup) |dimension| if (dimension == 0) return error.LaunchFailed;
        }
        failed_index.* = null;
        for (wait_events) |event| if (!event.recorded) return error.InvalidEvent;
        const actual_stream = stream orelse try self.defaultStream();
        if (actual_stream.failed) return error.LaunchFailed;
        const synchronize_after = stream == null and wait_events.len == 0 and signal_event == null;
        var pool = foundation.AutoreleasePool.init() orelse return error.RuntimeUnavailable;
        defer pool.deinit();
        const command_buffer = metal.commandBuffer(actual_stream.command_queue) orelse return error.LaunchFailed;
        for (wait_events) |event| metal.encodeWaitForEvent(command_buffer, event.event, event.value);
        for (dispatches, 0..) |entry, index| {
            failed_index.* = index;
            const encoder = metal.computeCommandEncoder(command_buffer) orelse return error.LaunchFailed;
            metal.setComputePipelineState(encoder, entry.kernel.pipeline);
            for (entry.buffers, 0..) |buffer, i| metal.setBuffer(encoder, buffer.buffer, 0, @intCast(i));
            for (entry.scalars, 0..) |*scalar, i| metal.setBytes(
                encoder,
                @ptrCast(&scalar.bits),
                scalar.byteSize(),
                @intCast(entry.buffers.len + i),
            );
            metal.dispatchThreadgroups(encoder, sizeFromDimensions(entry.grid), sizeFromDimensions(entry.threadgroup));
            metal.endEncoding(encoder);
        }
        failed_index.* = null;
        const signal_value = if (signal_event) |event| try event.reserveSignal() else null;
        if (signal_event) |event| metal.encodeSignalEvent(command_buffer, event.event, signal_value.?);
        metal.commit(command_buffer);
        actual_stream.replaceLastCommandBuffer(command_buffer);
        if (signal_event) |event| {
            event.value = signal_value.?;
            event.recorded = true;
            event.replaceCommandBuffer(command_buffer);
        }
        if (synchronize_after) try actual_stream.synchronize();
    }

    pub fn synchronize(self: *Runtime) runtime.Error!void {
        if (comptime !native_available) return error.UnsupportedPlatform;
        if (self.default_stream) |stream| try stream.synchronize();
        var stream_it = self.live_streams.keyIterator();
        while (stream_it.next()) |stream| try stream.*.synchronize();
    }

    pub fn defaultStream(self: *Runtime) runtime.Error!*runtime.Stream {
        if (comptime !native_available) return error.UnsupportedPlatform;
        if (self.default_stream) |stream| return stream;
        const stream = self.allocator.create(runtime.Stream) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(stream);
        stream.* = try runtime.Stream.init(self.device);
        self.default_stream = stream;
        return stream;
    }

    pub fn createStream(self: *Runtime) runtime.Error!*runtime.Stream {
        if (comptime !native_available) return error.UnsupportedPlatform;
        const stream = self.allocator.create(runtime.Stream) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(stream);
        stream.* = try runtime.Stream.init(self.device);
        errdefer stream.deinit();
        self.live_streams.put(self.allocator, stream, {}) catch return error.OutOfMemory;
        return stream;
    }

    pub fn destroyStream(self: *Runtime, stream: *runtime.Stream) void {
        if (self.live_streams.remove(stream)) {
            stream.deinit();
            self.allocator.destroy(stream);
        } else {
            std.debug.panic("metal.Runtime.destroyStream: unknown stream {*}", .{stream});
        }
    }

    pub fn createEvent(self: *Runtime) runtime.Error!*runtime.Event {
        if (comptime !native_available) return error.UnsupportedPlatform;
        const event = self.allocator.create(runtime.Event) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(event);
        event.* = try runtime.Event.init(self.device);
        errdefer event.deinit();
        self.live_events.put(self.allocator, event, {}) catch return error.OutOfMemory;
        return event;
    }

    pub fn destroyEvent(self: *Runtime, event: *runtime.Event) void {
        if (self.live_events.remove(event)) {
            event.deinit();
            self.allocator.destroy(event);
        } else {
            std.debug.panic("metal.Runtime.destroyEvent: unknown event {*}", .{event});
        }
    }
};

fn sizeFromDimensions(dimensions: [3]u32) metal.Size {
    return .{
        .width = dimensions[0],
        .height = dimensions[1],
        .depth = dimensions[2],
    };
}
