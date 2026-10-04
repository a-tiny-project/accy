const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const coreaudio = @import("coreaudio.zig");
const pulse = @import("pulse.zig");

const backend = if (builtin.os.tag == .macos) coreaudio else pulse;

pub const required_capabilities = capabilities.host(&.{.audio});

pub const Error = error{
    UnsupportedPlatform,
    OpenFailed,
    ConfigureFailed,
    Underrun,
    WriteFailed,
    OutOfMemory,
};

pub const channels: u8 = 2;
pub const PlaybackLimits = backend.Playback.Limits;
pub const PlaybackCapacity = backend.Playback.Capacity;
pub const PlaybackStorage = backend.Playback.Storage;

pub const default_playback_supported = backend.supported and builtin.cpu.arch.endian() == .little;

pub const PlaybackDevice = struct {
    playback: backend.Playback,

    pub fn openDefault(
        allocator: std.mem.Allocator,
        limits: PlaybackLimits,
        sample_rate: u32,
        frames_per_buffer: usize,
        name: []const u8,
    ) Error!PlaybackDevice {
        if (comptime !default_playback_supported) return error.UnsupportedPlatform;
        const playback = try openBackend(
            allocator,
            limits,
            sample_rate,
            frames_per_buffer,
            name,
        );
        return .{ .playback = playback };
    }

    pub fn drain(self: *PlaybackDevice) void {
        self.playback.drain() catch {};
    }

    pub fn close(self: *PlaybackDevice, allocator: std.mem.Allocator) void {
        self.playback.close(allocator);
    }

    pub fn writeInterleaved(
        self: *PlaybackDevice,
        samples: [*]const i16,
        frames: usize,
    ) Error!usize {
        const writable_frames = if (comptime builtin.os.tag == .macos)
            @min(frames, self.playback.storage.capacity.frames_per_buffer)
        else
            frames;
        const sample_count = std.math.mul(
            usize,
            writable_frames,
            channels,
        ) catch return error.WriteFailed;
        const bytes = std.mem.sliceAsBytes(samples[0..sample_count]);
        if (comptime builtin.os.tag == .macos) {
            self.playback.writeFrames(bytes) catch return error.WriteFailed;
        } else {
            self.playback.writeFrames(bytes) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.WriteFailed,
            };
        }
        return writable_frames;
    }

    pub fn prepare(_: *PlaybackDevice) void {}

    pub fn capacity(self: *const PlaybackDevice) PlaybackCapacity {
        return self.playback.storage.capacity;
    }
};

pub fn defaultPlaybackSupported() bool {
    return default_playback_supported and backend.available();
}

fn openBackend(
    allocator: std.mem.Allocator,
    limits: PlaybackLimits,
    sample_rate: u32,
    frames_per_buffer: usize,
    name: []const u8,
) Error!backend.Playback {
    if (comptime builtin.os.tag == .macos) {
        return coreaudio.Playback.open(
            allocator,
            limits,
            .{
                .format = coreaudio.sample_format_s16_native,
                .channels = channels,
                .rate = sample_rate,
                .frames_per_buffer = frames_per_buffer,
            },
            name,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnsupportedPlatform => error.UnsupportedPlatform,
            error.QueueCreationFailed => error.OpenFailed,
            else => error.ConfigureFailed,
        };
    }

    return pulse.Playback.open(
        allocator,
        limits,
        .{
            .format = pulse.sample_format_s16le,
            .channels = channels,
            .rate = sample_rate,
        },
        name,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.CapacityOverflow,
        error.ChannelLimitExceeded,
        error.ClientNameLimitExceeded,
        error.ControlPayloadCapacityExceeded,
        error.StreamRejected,
        error.ServerError,
        => error.ConfigureFailed,
        else => error.OpenFailed,
    };
}

pub fn openDefaultPlayback(
    allocator: std.mem.Allocator,
    limits: PlaybackLimits,
    sample_rate: u32,
    frames_per_buffer: usize,
    name: []const u8,
) Error!PlaybackDevice {
    return PlaybackDevice.openDefault(allocator, limits, sample_rate, frames_per_buffer, name);
}
