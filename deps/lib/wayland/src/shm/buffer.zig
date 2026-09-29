const builtin = @import("builtin");
const std = @import("std");
const sys = @import("sys");
const wayland = @import("../root.zig");

const core = wayland.protocol.core;
const runtime = wayland.runtime;

pub const Format = enum(u32) {
    argb8888 = 0,
    xrgb8888 = 1,
    abgr8888 = 0x3432_4241,
    xbgr8888 = 0x3432_4258,

    pub fn fromRaw(raw: u32) ?Format {
        return std.enums.fromInt(Format, raw);
    }
};

pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Error = error{
    OutOfMemory,
    DimensionsTooLarge,
    CreateFailed,
};

pub const PixelError = error{
    InvalidRegion,
    DestinationTooSmall,
};

pub const Buffer = struct {
    object_id: u32,
    mapping: []align(std.heap.page_size_min) u8,
    byte_len: usize,
    width: u32,
    height: u32,
    stride: u32,
    format: Format,
    busy: bool = false,

    pub fn open(
        client: *runtime.Client,
        shm: u32,
        width: u32,
        height: u32,
        format: Format,
    ) Error!Buffer {
        const dimensions = try Dimensions.init(width, height);
        const descriptor = try createDescriptor();
        var descriptor_owned = true;
        defer if (descriptor_owned) sys.fd.close(descriptor);
        try truncate(descriptor, dimensions.byte_len);

        const mapping = try mapDescriptor(descriptor, dimensions.byte_len);
        errdefer sys.memory.unmap(mapping);

        const pool = try createPool(client, shm, descriptor, dimensions.byte_len);
        descriptor_owned = false;
        var pool_live = true;
        defer if (pool_live) destroy(client, pool, core.wl_shm_pool.requests.destroy.opcode);

        const buffer_id = try createBuffer(
            client,
            pool,
            width,
            height,
            dimensions.stride,
            format,
        );
        errdefer destroy(
            client,
            buffer_id,
            core.wl_buffer.requests.destroy.opcode,
        );
        try closePool(client, pool);
        pool_live = false;

        return .{
            .object_id = buffer_id,
            .mapping = mapping,
            .byte_len = dimensions.byte_len,
            .width = width,
            .height = height,
            .stride = dimensions.stride,
            .format = format,
        };
    }

    pub fn deinit(self: *Buffer, client: *runtime.Client) void {
        destroy(client, self.object_id, core.wl_buffer.requests.destroy.opcode);
        sys.memory.unmap(self.mapping);
        self.* = undefined;
    }

    pub fn dispatch(self: *Buffer, event: *runtime.RoutedView) !void {
        if (event.object_id != self.object_id or
            event.metadata.opcode != core.wl_buffer.events.release.opcode)
        {
            return error.InvalidBufferEvent;
        }
        var decoder = try event.borrowedDecoder();
        try decoder.finish();
        self.busy = false;
    }

    /// Converts the pixels of the rectangle `region` of the full frame `rgba8`
    /// into the buffer, reordering each pixel's bytes into the buffer's format.
    /// The slice `rgba8` covers the whole buffer at the buffer's extent and
    /// stride, so a rectangle sits at the same byte offset in both. A present
    /// calls this to copy the changed part of a frame into the buffer the
    /// compositor will read. A present of the whole image passes the whole
    /// buffer as the rectangle, and a present of one change passes that
    /// change's rectangle and touches those rows alone. A source shorter than
    /// the buffer fails with `error.DestinationTooSmall`. A rectangle with zero
    /// width or height, or one reaching past the buffer's extent, fails with
    /// `error.InvalidRegion`.
    pub fn writeRgba8(self: *Buffer, rgba8: []const u8, region: Region) PixelError!void {
        if (rgba8.len < self.byte_len) return error.DestinationTooSmall;
        _ = try regionByteLen(self, region);
        std.debug.assert(self.stride == self.width * 4);
        const row_byte_len = @as(usize, region.width) * 4;
        var row: u32 = 0;
        while (row < region.height) : (row += 1) {
            const offset =
                @as(usize, region.y + row) * self.stride +
                @as(usize, region.x) * 4;
            convertToShm(
                self.mapping[offset..][0..row_byte_len],
                rgba8[offset..][0..row_byte_len],
                self.format,
            );
        }
    }

    /// Returns the rectangle covering the whole buffer, so a caller that sends
    /// the whole image passes this rectangle to `writeRgba8` for a present with
    /// no damage list.
    pub fn fullRegion(self: *const Buffer) Region {
        return .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
    }

    pub fn copyRegionRgba8(
        self: *const Buffer,
        region: Region,
        destination: []u8,
    ) PixelError!void {
        const byte_len = try regionByteLen(self, region);
        if (destination.len < byte_len) return error.DestinationTooSmall;
        var row: u32 = 0;
        while (row < region.height) : (row += 1) {
            const source_offset =
                @as(usize, region.y + row) * self.stride +
                @as(usize, region.x) * 4;
            const destination_offset = @as(usize, row) * region.width * 4;
            const row_byte_len = @as(usize, region.width) * 4;
            convertFromShm(
                destination[destination_offset..][0..row_byte_len],
                self.mapping[source_offset..][0..row_byte_len],
                self.format,
            );
        }
    }
};

const Dimensions = struct {
    stride: u32,
    byte_len: usize,

    fn init(width: u32, height: u32) Error!Dimensions {
        if (width == 0 or height == 0) return error.DimensionsTooLarge;
        const stride = std.math.mul(
            u32,
            width,
            4,
        ) catch return error.DimensionsTooLarge;
        const byte_len_u64 = @as(u64, stride) * height;
        if (width > std.math.maxInt(i32) or
            height > std.math.maxInt(i32) or
            stride > std.math.maxInt(i32) or
            byte_len_u64 > std.math.maxInt(i32))
        {
            return error.DimensionsTooLarge;
        }
        return .{ .stride = stride, .byte_len = @intCast(byte_len_u64) };
    }
};

fn createDescriptor() Error!sys.fd.Descriptor {
    if (comptime builtin.os.tag != .linux) return error.CreateFailed;
    return sys.fs.createAnonymousFile("tiny-wayland") catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CreateFailed,
    };
}

fn mapDescriptor(
    descriptor: sys.fd.Descriptor,
    byte_len: usize,
) Error![]align(std.heap.page_size_min) u8 {
    return sys.memory.mapSharedFile(
        descriptor,
        byte_len,
        .{ .read = true, .write = true },
        0,
    ) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CreateFailed,
    };
}

fn createPool(
    client: *runtime.Client,
    shm: u32,
    descriptor: sys.fd.Descriptor,
    byte_len: usize,
) Error!u32 {
    var created: [1]u32 = undefined;
    client.request(
        shm,
        core.wl_shm.requests.create_pool.opcode,
        &.{
            .{ .new_id = .fixed },
            .{ .descriptor_owned = descriptor },
            .{ .int = @intCast(byte_len) },
        },
        &created,
    ) catch return error.CreateFailed;
    return created[0];
}

fn createBuffer(
    client: *runtime.Client,
    pool: u32,
    width: u32,
    height: u32,
    stride: u32,
    format: Format,
) Error!u32 {
    var created: [1]u32 = undefined;
    client.request(
        pool,
        core.wl_shm_pool.requests.create_buffer.opcode,
        &.{
            .{ .new_id = .fixed },
            .{ .int = 0 },
            .{ .int = @intCast(width) },
            .{ .int = @intCast(height) },
            .{ .int = @intCast(stride) },
            .{ .uint = @backingInt(format) },
        },
        &created,
    ) catch return error.CreateFailed;
    return created[0];
}

fn closePool(client: *runtime.Client, pool: u32) Error!void {
    client.request(
        pool,
        core.wl_shm_pool.requests.destroy.opcode,
        &.{},
        &.{},
    ) catch return error.CreateFailed;
}

fn regionByteLen(buffer: *const Buffer, region: Region) PixelError!usize {
    if (region.width == 0 or region.height == 0) return error.InvalidRegion;
    if (region.x > buffer.width or region.y > buffer.height) {
        return error.InvalidRegion;
    }
    if (region.width > buffer.width - region.x or
        region.height > buffer.height - region.y)
    {
        return error.InvalidRegion;
    }
    const pixels = std.math.mul(
        usize,
        region.width,
        region.height,
    ) catch return error.InvalidRegion;
    return std.math.mul(usize, pixels, 4) catch return error.InvalidRegion;
}

const lane_steps = [_]comptime_int{ 16, 4 };

fn swizzleLanes(
    comptime format: Format,
    comptime lanes: comptime_int,
    words: @Vector(lanes, u32),
) @Vector(lanes, u32) {
    const Words = @Vector(lanes, u32);
    const half: @Vector(lanes, u5) = @splat(16);
    const blue: Words = @splat(0x0000_00ff);
    const green: Words = @splat(0x0000_ff00);
    const red: Words = @splat(0x00ff_0000);
    const alpha: Words = @splat(0xff00_0000);
    const colour: Words = @splat(0x00ff_ffff);
    return switch (format) {
        .argb8888 => ((words >> half) & blue) | (words & green) |
            ((words << half) & red) | (words & alpha),
        .xrgb8888 => ((words >> half) & blue) | (words & green) |
            ((words << half) & red) | alpha,
        .abgr8888 => words,
        .xbgr8888 => (words & colour) | alpha,
    };
}

fn swizzleSpan(
    comptime format: Format,
    destination: []u8,
    source: []const u8,
) void {
    std.debug.assert(destination.len == source.len);
    std.debug.assert(destination.len % 4 == 0);
    var offset: usize = 0;
    inline for (lane_steps) |lanes| {
        const Words = @Vector(lanes, u32);
        const step = lanes * 4;
        comptime std.debug.assert(@sizeOf(Words) == step);
        while (offset + step <= destination.len) : (offset += step) {
            const read: *align(1) const Words = @ptrCast(source[offset..][0..step]);
            const write: *align(1) Words = @ptrCast(destination[offset..][0..step]);
            write.* = swizzleLanes(format, lanes, read.*);
        }
    }
    while (offset + 4 <= destination.len) : (offset += 4) {
        const read: *align(1) const u32 = @ptrCast(source[offset..][0..4]);
        const write: *align(1) u32 = @ptrCast(destination[offset..][0..4]);
        const word: @Vector(1, u32) = @splat(read.*);
        write.* = swizzleLanes(format, 1, word)[0];
    }
    std.debug.assert(offset == destination.len);
}

fn swizzle(destination: []u8, source: []const u8, format: Format) void {
    std.debug.assert(destination.len == source.len);
    std.debug.assert(destination.len % 4 == 0);
    switch (format) {
        inline else => |tag| swizzleSpan(tag, destination, source),
    }
}

fn convertToShm(destination: []u8, rgba8: []const u8, format: Format) void {
    swizzle(destination, rgba8, format);
}

fn convertFromShm(destination: []u8, source: []const u8, format: Format) void {
    swizzle(destination, source, format);
}

fn destroy(client: *runtime.Client, object_id: u32, opcode: u16) void {
    client.request(object_id, opcode, &.{}, &.{}) catch {};
}

fn truncate(descriptor: sys.fd.Descriptor, byte_len: usize) Error!void {
    return sys.fs.truncateDescriptor(descriptor, byte_len) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedPlatform, error.TruncateFailed => error.CreateFailed,
    };
}

test "shared memory dimensions enforce protocol integer bounds" {
    try std.testing.expectEqual(
        Dimensions{ .stride = 256, .byte_len = 8192 },
        try Dimensions.init(64, 32),
    );
    try std.testing.expectError(
        error.DimensionsTooLarge,
        Dimensions.init(0, 32),
    );
    try std.testing.expectError(
        error.DimensionsTooLarge,
        Dimensions.init(std.math.maxInt(u32), 2),
    );
}

test "shared memory pixel formats round trip canonical rgba" {
    const rgba = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    inline for (std.meta.tags(Format)) |format| {
        var shared: [4]u8 = undefined;
        var decoded: [4]u8 = undefined;
        convertToShm(&shared, &rgba, format);
        convertFromShm(&decoded, &shared, format);
        try std.testing.expectEqualSlices(u8, rgba[0..3], decoded[0..3]);
        const expected_alpha: u8 = switch (format) {
            .argb8888, .abgr8888 => rgba[3],
            .xrgb8888, .xbgr8888 => 0xff,
        };
        try std.testing.expectEqual(expected_alpha, decoded[3]);
    }
}

test "a region write swizzles its own rows and preserves every other byte" {
    const width: u32 = 4;
    const height: u32 = 3;
    var mapping: [width * height * 4]u8 align(std.heap.page_size_min) = @splat(0x5a);
    var value = Buffer{
        .object_id = 11,
        .mapping = @alignCast(mapping[0..]),
        .byte_len = mapping.len,
        .width = width,
        .height = height,
        .stride = width * 4,
        .format = .xrgb8888,
    };
    var frame: [width * height * 4]u8 = undefined;
    for (&frame, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% 1);

    try value.writeRgba8(&frame, .{ .x = 1, .y = 1, .width = 2, .height = 1 });

    var mutated: usize = 0;
    for (mapping, 0..) |byte, index| {
        const row = index / (width * 4);
        const column = (index % (width * 4)) / 4;
        const inside = row == 1 and column >= 1 and column < 3;
        if (inside) {
            const channel = index % 4;
            const expected: u8 = switch (channel) {
                0 => frame[index + 2],
                1 => frame[index],
                2 => frame[index - 2],
                else => 0xff,
            };
            try std.testing.expectEqual(expected, byte);
            mutated += 1;
        } else {
            try std.testing.expectEqual(@as(u8, 0x5a), byte);
        }
    }
    try std.testing.expectEqual(@as(usize, 8), mutated);
}

test "a full region write equals the region writes that cover it" {
    const width: u32 = 4;
    const height: u32 = 4;
    var whole: [width * height * 4]u8 align(std.heap.page_size_min) = @splat(0);
    var split: [width * height * 4]u8 align(std.heap.page_size_min) = @splat(0);
    var frame: [width * height * 4]u8 = undefined;
    for (&frame, 0..) |*byte, index| byte.* = @truncate(index *% 13 +% 5);

    var full = Buffer{
        .object_id = 12,
        .mapping = @alignCast(whole[0..]),
        .byte_len = whole.len,
        .width = width,
        .height = height,
        .stride = width * 4,
        .format = .argb8888,
    };
    var partial = full;
    partial.object_id = 13;
    partial.mapping = @alignCast(split[0..]);

    try full.writeRgba8(&frame, full.fullRegion());
    try partial.writeRgba8(&frame, .{ .x = 0, .y = 0, .width = 4, .height = 2 });
    try partial.writeRgba8(&frame, .{ .x = 0, .y = 2, .width = 4, .height = 2 });
    try std.testing.expectEqualSlices(u8, &whole, &split);

    try std.testing.expectError(
        error.InvalidRegion,
        full.writeRgba8(&frame, .{ .x = 3, .y = 0, .width = 2, .height = 1 }),
    );
    try std.testing.expectError(
        error.DestinationTooSmall,
        full.writeRgba8(frame[0 .. frame.len - 1], full.fullRegion()),
    );
}
