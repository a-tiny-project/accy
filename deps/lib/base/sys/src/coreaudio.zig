const std = @import("std");
const alloc_phase = @import("alloc_phase");
const builtin = @import("builtin");
const thread = @import("thread.zig");

pub const supported = builtin.os.tag == .macos and builtin.cpu.arch.endian() == .little;

pub const sample_format_s16_native: u8 = 1;
pub const buffer_count: usize = 3;
pub const maximum_frames_per_buffer: usize = 65_536;

const status_ok: i32 = 0;
const audio_format_linear_pcm = fourCC("lpcm");
const audio_format_flag_signed_integer: u32 = 1 << 2;
const audio_format_flag_packed: u32 = 1 << 3;
const audio_queue_property_is_running = fourCC("aqrn");
const audio_hardware_property_default_output_device = fourCC("dOut");
const audio_object_property_scope_global = fourCC("glob");
const audio_object_property_element_main: u32 = 0;
const audio_object_system: u32 = 1;
const audio_object_unknown: u32 = 0;
const all_buffers_free: u8 = (@as(u8, 1) << @intCast(buffer_count)) - 1;

pub const Error = error{
    UnsupportedPlatform,
    UnsupportedFormat,
    CapacityOverflow,
    ChannelLimitExceeded,
    ClientNameLimitExceeded,
    FrameLimitExceeded,
    BufferLimitExceeded,
    QueueCreationFailed,
    BufferAllocationFailed,
    PropertyListenerFailed,
    EnqueueFailed,
    StartFailed,
    StopFailed,
    OutOfMemory,
};

pub const Limits = struct {
    client_name_bytes: usize = 255,
    channels: u8 = 2,
};

pub const Spec = struct {
    format: u8 = sample_format_s16_native,
    channels: u8 = 2,
    rate: u32 = 48_000,
    frames_per_buffer: usize = 256,
};

pub const StorageLimits = struct {
    frames_per_buffer: usize,
    channels: u8,
};

pub const CapacityError = error{
    CapacityOverflow,
    ChannelLimitExceeded,
    FrameLimitExceeded,
};

pub const Capacity = struct {
    frames_per_buffer: usize,
    frame_bytes: u32,
    buffer_bytes: u32,
    foreign_audio_bytes: usize,
    callback_state_bytes: usize,

    pub fn derive(limits: StorageLimits) CapacityError!Capacity {
        if (limits.frames_per_buffer == 0 or limits.frames_per_buffer > maximum_frames_per_buffer) {
            return error.FrameLimitExceeded;
        }
        if (limits.channels == 0) return error.ChannelLimitExceeded;

        const frame_bytes = std.math.mul(
            usize,
            @sizeOf(i16),
            @as(usize, limits.channels),
        ) catch return error.CapacityOverflow;
        if (frame_bytes > std.math.maxInt(u32)) return error.CapacityOverflow;

        const buffer_bytes = std.math.mul(
            usize,
            limits.frames_per_buffer,
            frame_bytes,
        ) catch return error.CapacityOverflow;
        if (buffer_bytes > std.math.maxInt(u32)) return error.CapacityOverflow;

        const foreign_audio_bytes = std.math.mul(
            usize,
            buffer_count,
            buffer_bytes,
        ) catch return error.CapacityOverflow;

        return .{
            .frames_per_buffer = limits.frames_per_buffer,
            .frame_bytes = @intCast(frame_bytes),
            .buffer_bytes = @intCast(buffer_bytes),
            .foreign_audio_bytes = foreign_audio_bytes,
            .callback_state_bytes = @sizeOf(State),
        };
    }
};

const CoreAudioLimits = Limits;
const CoreAudioCapacity = Capacity;

pub const Storage = struct {
    phase: alloc_phase.capacity.Phase,
    capacity: CoreAudioCapacity,
    state: *State,

    pub const Limits: type = StorageLimits;
    pub const Capacity: type = CoreAudioCapacity;
    pub const Exhaustion = error{BufferLimitExceeded};
    pub const InitError = std.mem.Allocator.Error || CapacityError;

    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "sys.coreaudio_playback_storage",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "one_stable_coreaudio_callback_state",
                        .lifetime = .steady,
                        .detail = "one stable CoreAudio callback state",
                    },
                },
                .excluded = &.{
                    "caller-owned interleaved PCM frames",
                    "AudioQueue objects and framework-allocated playback buffers",
                    "CoreAudio device, converter, and callback thread storage",
                },
            },
            .capacity = .{
                .inputs = &.{},
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(State, "state"),
                },
                .nodes = &.{
                    .{ .constant = 1 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 1,
                }},
            },
            .overload = .{
                .kind = .reject_before_mutation,
                .detail = "oversize playback payloads reject before a free queue buffer is acquired",
            },
            .risks = .{
                .transitive = .{
                    .status = .open,
                    .detail = "playback synchronization enters the host thread implementation",
                },
                .foreign = .{
                    .status = .open,
                    .detail = "AudioQueue owns three bounded buffers and internal device state",
                },
            },
            .obligations = &.{
                .{ .key = "sys_coreaudio_playback_capacity_capacity_model", .role = .capacity_model },
                .{ .key = "sys_coreaudio_playback_capacity_overload", .role = .overload },
                .{ .key = "sys_coreaudio_playback_oom_retry", .role = .custom },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };

    pub fn init(allocator: std.mem.Allocator, limits: StorageLimits) InitError!Storage {
        const capacity = try CoreAudioCapacity.derive(limits);
        const state = try allocator.create(State);
        state.* = .{};
        return .{
            .phase = .initialization,
            .capacity = capacity,
            .state = state,
        };
    }

    pub fn activate(self: *Storage) void {
        std.debug.assert(self.phase == .initialization);
        self.phase = .steady;
    }

    pub fn validatePayload(self: *Storage, byte_count: usize) Exhaustion!void {
        std.debug.assert(self.phase == .steady);
        if (byte_count > self.capacity.buffer_bytes) return error.BufferLimitExceeded;
    }

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        std.debug.assert(self.phase != .teardown);
        self.phase = .teardown;
        allocator.destroy(self.state);
        self.state = undefined;
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorRejectingOwnerShape(Storage);
}

const CoreAudioStorage = Storage;

pub const Playback = struct {
    queue: AudioQueueRef,
    storage: CoreAudioStorage,

    pub const Limits: type = CoreAudioLimits;
    pub const Capacity: type = CoreAudioCapacity;
    pub const Storage: type = CoreAudioStorage;

    pub fn open(
        allocator: std.mem.Allocator,
        limits: CoreAudioLimits,
        spec: Spec,
        name: []const u8,
    ) Error!Playback {
        if (comptime !supported) return error.UnsupportedPlatform;
        if (name.len > limits.client_name_bytes) return error.ClientNameLimitExceeded;
        if (spec.channels == 0 or spec.channels > limits.channels) {
            return error.ChannelLimitExceeded;
        }
        if (spec.format != sample_format_s16_native or spec.rate == 0) {
            return error.UnsupportedFormat;
        }

        var storage = CoreAudioStorage.init(allocator, .{
            .frames_per_buffer = spec.frames_per_buffer,
            .channels = spec.channels,
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.CapacityOverflow => error.CapacityOverflow,
            error.ChannelLimitExceeded => error.ChannelLimitExceeded,
            error.FrameLimitExceeded => error.FrameLimitExceeded,
        };
        errdefer storage.deinit(allocator);

        const format = streamDescription(spec, storage.capacity);

        var optional_queue: ?AudioQueueRef = null;
        if (AudioQueueNewOutput(
            &format,
            bufferComplete,
            storage.state,
            null,
            null,
            0,
            &optional_queue,
        ) != status_ok) return error.QueueCreationFailed;
        const queue = optional_queue orelse return error.QueueCreationFailed;
        errdefer _ = AudioQueueDispose(queue, 1);

        if (AudioQueueAddPropertyListener(
            queue,
            audio_queue_property_is_running,
            runningChanged,
            storage.state,
        ) != status_ok) return error.PropertyListenerFailed;

        for (&storage.state.buffers) |*slot| {
            var optional_buffer: ?*AudioQueueBuffer = null;
            if (AudioQueueAllocateBuffer(
                queue,
                storage.capacity.buffer_bytes,
                &optional_buffer,
            ) != status_ok) return error.BufferAllocationFailed;
            slot.* = optional_buffer orelse return error.BufferAllocationFailed;
        }

        storage.activate();
        return .{
            .queue = queue,
            .storage = storage,
        };
    }

    pub fn close(self: *Playback, allocator: std.mem.Allocator) void {
        _ = AudioQueueDispose(self.queue, 1);
        self.storage.deinit(allocator);
        self.* = undefined;
    }

    pub fn writeFrames(self: *Playback, bytes: []const u8) Error!void {
        try self.storage.validatePayload(bytes.len);
        if (bytes.len == 0) return;
        if (bytes.len % self.storage.capacity.frame_bytes != 0) {
            return error.BufferLimitExceeded;
        }

        const state = self.storage.state;
        const buffer = acquireBuffer(state) catch return error.StartFailed;
        var submitted = false;
        defer if (!submitted) releaseBuffer(state, buffer);

        std.debug.assert(bytes.len <= buffer.data_capacity);
        const target: [*]u8 = @ptrCast(buffer.data);
        @memcpy(target[0..bytes.len], bytes);
        buffer.data_size = @intCast(bytes.len);

        if (AudioQueueEnqueueBuffer(self.queue, buffer, 0, null) != status_ok) {
            return error.EnqueueFailed;
        }
        submitted = true;

        state.mutex.lock();
        const needs_start = !state.started;
        if (needs_start) {
            state.started = true;
            state.running = true;
        }
        state.mutex.unlock();

        if (needs_start and AudioQueueStart(self.queue, null) != status_ok) {
            state.mutex.lock();
            state.failed = true;
            state.started = false;
            state.running = false;
            state.condition.broadcast();
            state.mutex.unlock();
            _ = AudioQueueStop(self.queue, 1);
            return error.StartFailed;
        }
    }

    pub fn drain(self: *Playback) Error!void {
        const state = self.storage.state;
        state.mutex.lock();
        const should_stop = state.started;
        state.mutex.unlock();
        if (!should_stop) return;

        if (AudioQueueStop(self.queue, 0) != status_ok) return error.StopFailed;

        state.mutex.lock();
        defer state.mutex.unlock();
        while (state.running) state.condition.wait(&state.mutex);
        std.debug.assert(state.free_mask == all_buffers_free);
    }
};

pub fn available() bool {
    if (comptime !supported) return false;

    const address = AudioObjectPropertyAddress{
        .selector = audio_hardware_property_default_output_device,
        .scope = audio_object_property_scope_global,
        .element = audio_object_property_element_main,
    };
    var output_device: u32 = audio_object_unknown;
    var byte_count: u32 = @sizeOf(@TypeOf(output_device));
    return AudioObjectGetPropertyData(
        audio_object_system,
        &address,
        0,
        null,
        &byte_count,
        &output_device,
    ) == status_ok and
        byte_count == @sizeOf(@TypeOf(output_device)) and
        output_device != audio_object_unknown;
}

const State = struct {
    mutex: thread.Mutex = .{},
    condition: thread.Condition = .{},
    buffers: [buffer_count]?*AudioQueueBuffer = @splat(null),
    free_mask: u8 = all_buffers_free,
    running: bool = false,
    started: bool = false,
    failed: bool = false,
};

const AudioQueue = opaque {};
const AudioQueueRef = *AudioQueue;

const AudioQueueBuffer = extern struct {
    data_capacity: u32,
    data: *anyopaque,
    data_size: u32,
    user_data: ?*anyopaque,
    packet_description_capacity: u32,
    packet_descriptions: ?*anyopaque,
    packet_description_count: u32,
};

const AudioStreamBasicDescription = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
};

const AudioObjectPropertyAddress = extern struct {
    selector: u32,
    scope: u32,
    element: u32,
};

const AudioQueueOutputCallback = *const fn (
    user_data: ?*anyopaque,
    queue: AudioQueueRef,
    buffer: *AudioQueueBuffer,
) callconv(.c) void;

const AudioQueuePropertyListener = *const fn (
    user_data: ?*anyopaque,
    queue: AudioQueueRef,
    property: u32,
) callconv(.c) void;

extern fn AudioQueueNewOutput(
    format: *const AudioStreamBasicDescription,
    callback: AudioQueueOutputCallback,
    user_data: ?*anyopaque,
    callback_run_loop: ?*anyopaque,
    callback_run_loop_mode: ?*anyopaque,
    flags: u32,
    queue: *?AudioQueueRef,
) i32;
extern fn AudioQueueDispose(queue: AudioQueueRef, immediate: u8) i32;
extern fn AudioQueueAllocateBuffer(
    queue: AudioQueueRef,
    byte_count: u32,
    buffer: *?*AudioQueueBuffer,
) i32;
extern fn AudioQueueEnqueueBuffer(
    queue: AudioQueueRef,
    buffer: *AudioQueueBuffer,
    packet_description_count: u32,
    packet_descriptions: ?*const anyopaque,
) i32;
extern fn AudioQueueStart(queue: AudioQueueRef, start_time: ?*const anyopaque) i32;
extern fn AudioQueueStop(queue: AudioQueueRef, immediate: u8) i32;
extern fn AudioQueueGetProperty(
    queue: AudioQueueRef,
    property: u32,
    output: *anyopaque,
    byte_count: *u32,
) i32;
extern fn AudioQueueAddPropertyListener(
    queue: AudioQueueRef,
    property: u32,
    listener: AudioQueuePropertyListener,
    user_data: ?*anyopaque,
) i32;
extern fn AudioObjectGetPropertyData(
    object: u32,
    address: *const AudioObjectPropertyAddress,
    qualifier_byte_count: u32,
    qualifier: ?*const anyopaque,
    output_byte_count: *u32,
    output: *anyopaque,
) i32;

fn acquireBuffer(state: *State) error{Failed}!*AudioQueueBuffer {
    state.mutex.lock();
    defer state.mutex.unlock();
    while (state.free_mask == 0 and !state.failed) {
        state.condition.wait(&state.mutex);
    }
    if (state.failed) return error.Failed;

    var index: usize = 0;
    while (index < buffer_count) : (index += 1) {
        const bit = bufferBit(index);
        if (state.free_mask & bit == 0) continue;
        state.free_mask &= ~bit;
        return state.buffers[index].?;
    }
    unreachable;
}

fn releaseBuffer(state: *State, buffer: *AudioQueueBuffer) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    for (state.buffers, 0..) |candidate, index| {
        if (candidate != buffer) continue;
        const bit = bufferBit(index);
        std.debug.assert(state.free_mask & bit == 0);
        state.free_mask |= bit;
        state.condition.signal();
        return;
    }
    unreachable;
}

fn bufferComplete(
    optional_state: ?*anyopaque,
    _: AudioQueueRef,
    buffer: *AudioQueueBuffer,
) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(optional_state.?));
    releaseBuffer(state, buffer);
}

fn runningChanged(
    optional_state: ?*anyopaque,
    queue: AudioQueueRef,
    property: u32,
) callconv(.c) void {
    std.debug.assert(property == audio_queue_property_is_running);
    var running: u32 = 0;
    var byte_count: u32 = @sizeOf(@TypeOf(running));
    const status = AudioQueueGetProperty(queue, property, &running, &byte_count);

    const state: *State = @ptrCast(@alignCast(optional_state.?));
    state.mutex.lock();
    defer state.mutex.unlock();
    state.running = status == status_ok and
        byte_count == @sizeOf(@TypeOf(running)) and
        running != 0;
    if (!state.running) state.started = false;
    state.condition.broadcast();
}

fn bufferBit(index: usize) u8 {
    std.debug.assert(index < buffer_count);
    return @as(u8, 1) << @intCast(index);
}

fn streamDescription(spec: Spec, capacity: Capacity) AudioStreamBasicDescription {
    std.debug.assert(spec.rate != 0);
    std.debug.assert(spec.channels != 0);
    std.debug.assert(capacity.frame_bytes == @sizeOf(i16) * @as(u32, spec.channels));
    return .{
        .sample_rate = @floatFromInt(spec.rate),
        .format_id = audio_format_linear_pcm,
        .format_flags = audio_format_flag_signed_integer | audio_format_flag_packed,
        .bytes_per_packet = capacity.frame_bytes,
        .frames_per_packet = 1,
        .bytes_per_frame = capacity.frame_bytes,
        .channels_per_frame = spec.channels,
        .bits_per_channel = 16,
        .reserved = 0,
    };
}

fn fourCC(comptime text: []const u8) u32 {
    if (text.len != 4) @compileError("fourCC requires four bytes");
    return @as(u32, text[0]) << 24 |
        @as(u32, text[1]) << 16 |
        @as(u32, text[2]) << 8 |
        @as(u32, text[3]);
}

test "coreaudio playback capacity bounds three queue buffers" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "sys_coreaudio_playback_capacity_capacity_model"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "sys_coreaudio_playback_capacity_overload"),
        );
    }

    const capacity = try Capacity.derive(.{
        .frames_per_buffer = 256,
        .channels = 2,
    });
    try std.testing.expectEqual(@as(u32, 4), capacity.frame_bytes);
    try std.testing.expectEqual(@as(u32, 1024), capacity.buffer_bytes);
    try std.testing.expectEqual(@as(usize, 3072), capacity.foreign_audio_bytes);
    try std.testing.expectEqual(@sizeOf(State), capacity.callback_state_bytes);

    try std.testing.expectError(
        error.FrameLimitExceeded,
        Capacity.derive(.{
            .frames_per_buffer = maximum_frames_per_buffer + 1,
            .channels = 2,
        }),
    );
}

fn checkStorageInitFailures(allocator: std.mem.Allocator) !void {
    var storage = try Storage.init(allocator, .{
        .frames_per_buffer = 256,
        .channels = 2,
    });
    storage.deinit(allocator);
}

test "coreaudio playback storage retries after allocation failure" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Storage, "sys_coreaudio_playback_oom_retry"),
        );
    }

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkStorageInitFailures,
        .{},
    );

    var storage = try Storage.init(std.testing.allocator, .{
        .frames_per_buffer = 256,
        .channels = 2,
    });
    defer storage.deinit(std.testing.allocator);
    storage.activate();
    try std.testing.expectEqual(alloc_phase.capacity.Phase.steady, storage.phase);
    try std.testing.expectError(
        error.BufferLimitExceeded,
        storage.validatePayload(@as(usize, storage.capacity.buffer_bytes) + 1),
    );
}
