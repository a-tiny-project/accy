const std = @import("std");
const gpu_abi = @import("gpu_abi");

const backend = @import("root.zig");

pub const Binding = extern struct {
    handle_id: u64,
    access: u8,
    ownership: u8,
    reserved: [6]u8 = @splat(0),
    byte_size: u64,
};

pub const Scalar = extern struct {
    tag: u8,
    reserved: [7]u8 = @splat(0),
    bits: u64,
};

pub const ScalarTag = enum(u8) {
    i32 = 0,
    u32 = 1,
    i64 = 2,
    u64 = 3,
    f32 = 4,
    f64 = 5,
};

pub const Status = enum(i32) {
    ok = 0,
    invalid_artifact = 1,
    invalid_buffer = 2,
    launch_failed = 3,
    out_of_memory = 4,
    runtime_unavailable = 5,
};

pub fn binding(source: backend.BufferBinding) backend.BackendError!Binding {
    const byte_size = std.math.cast(u64, source.byte_size) orelse return error.InvalidBuffer;
    return .{
        .handle_id = source.handle.id,
        .access = @backingInt(source.access),
        .ownership = @backingInt(source.ownership),
        .byte_size = byte_size,
    };
}

pub fn scalar(argument: gpu_abi.ScalarArgument) Scalar {
    return switch (argument) {
        .i32 => |value| .{ .tag = @backingInt(ScalarTag.i32), .bits = @as(u32, @bitCast(value)) },
        .u32 => |value| .{ .tag = @backingInt(ScalarTag.u32), .bits = value },
        .i64 => |value| .{ .tag = @backingInt(ScalarTag.i64), .bits = @as(u64, @bitCast(value)) },
        .u64 => |value| .{ .tag = @backingInt(ScalarTag.u64), .bits = value },
        .f32 => |value| .{ .tag = @backingInt(ScalarTag.f32), .bits = @as(u32, @bitCast(value)) },
        .f64 => |value| .{ .tag = @backingInt(ScalarTag.f64), .bits = @as(u64, @bitCast(value)) },
    };
}

pub fn status(code: i32) backend.BackendError!void {
    return switch (code) {
        @backingInt(Status.ok) => {},
        @backingInt(Status.invalid_artifact) => error.InvalidArtifact,
        @backingInt(Status.invalid_buffer) => error.InvalidBuffer,
        @backingInt(Status.launch_failed) => error.LaunchFailed,
        @backingInt(Status.out_of_memory) => error.OutOfMemory,
        @backingInt(Status.runtime_unavailable) => error.RuntimeUnavailable,
        else => error.RuntimeUnavailable,
    };
}

pub fn pointer(slice: anytype) usize {
    return if (slice.len == 0) 0 else @intFromPtr(slice.ptr);
}

test "host binding narrows buffer bindings to the wire layout" {
    const wire = try binding(.{
        .handle = .{ .id = 7, .backend = .wasm, .byte_size = 64, .ownership = .backend },
        .access = .read_write,
        .ownership = .backend,
        .byte_size = 64,
    });
    try std.testing.expectEqual(@as(u64, 7), wire.handle_id);
    try std.testing.expectEqual(@as(u64, 64), wire.byte_size);
    try std.testing.expectEqual(@backingInt(backend.BufferAccess.read_write), wire.access);
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Binding));
}

test "host scalar preserves bit patterns per tag" {
    const float_scalar = scalar(.{ .f32 = -1.5 });
    try std.testing.expectEqual(@backingInt(ScalarTag.f32), float_scalar.tag);
    try std.testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, -1.5)))), float_scalar.bits);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Scalar));
}

test "host status maps wire codes onto backend errors" {
    try status(0);
    try std.testing.expectError(error.InvalidArtifact, status(1));
    try std.testing.expectError(error.InvalidBuffer, status(2));
    try std.testing.expectError(error.LaunchFailed, status(3));
    try std.testing.expectError(error.OutOfMemory, status(4));
    try std.testing.expectError(error.RuntimeUnavailable, status(5));
    try std.testing.expectError(error.RuntimeUnavailable, status(99));
}
