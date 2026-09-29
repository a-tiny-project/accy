const std = @import("std");
const hypothesis = @import("hypothesis");
const wayland = @import("wayland");

const shm = wayland.shm;

const maximum_row_pixels: u32 = 257;
const maximum_rows: u32 = 3;
const maximum_slack_bytes: usize = 60;
const background: u8 = 0x5a;

fn settings(seed: u64) hypothesis.Settings {
    var value = hypothesis.Settings.quick();
    value.max_examples = 400;
    value.max_replays = 400;
    value.target_examples = 400;
    return value
        .withSeed(seed)
        .withDatabase("zig-out/hypothesis-failures/wayland-shm");
}

fn oracle(destination: []u8, source: []const u8, format: shm.Format) void {
    std.debug.assert(destination.len == source.len);
    std.debug.assert(destination.len % 4 == 0);
    var offset: usize = 0;
    while (offset < destination.len) : (offset += 4) {
        switch (format) {
            .argb8888, .xrgb8888 => {
                destination[offset] = source[offset + 2];
                destination[offset + 1] = source[offset + 1];
                destination[offset + 2] = source[offset];
            },
            .abgr8888, .xbgr8888 => {
                destination[offset] = source[offset];
                destination[offset + 1] = source[offset + 1];
                destination[offset + 2] = source[offset + 2];
            },
        }
        destination[offset + 3] = switch (format) {
            .argb8888, .abgr8888 => source[offset + 3],
            .xrgb8888, .xbgr8888 => 0xff,
        };
    }
}

const Shape = struct {
    width: u32,
    height: u32,
    region: shm.Region,
    source_slack: usize,
    destination_slack: usize,
    fill: u8,
    seed: u64,

    fn stride(self: Shape) usize {
        return @as(usize, self.width) * 4;
    }

    fn byteLen(self: Shape) usize {
        return self.stride() * self.height;
    }

    fn rowLen(self: Shape) usize {
        return @as(usize, self.region.width) * 4;
    }

    fn regionLen(self: Shape) usize {
        return self.rowLen() * self.region.height;
    }

    fn rowOffset(self: Shape, row: u32) usize {
        return (@as(usize, self.region.y) + row) * self.stride() +
            @as(usize, self.region.x) * 4;
    }
};

fn drawSlack(data: *hypothesis.ConjectureData) !usize {
    const words = try data.drawInteger(0, maximum_slack_bytes / 4, 0);
    return 4 * @as(usize, @intCast(words));
}

fn drawShape(data: *hypothesis.ConjectureData) !Shape {
    const width: u32 = @intCast(try data.drawInteger(1, maximum_row_pixels, 1));
    const height: u32 = @intCast(try data.drawInteger(1, maximum_rows, 1));
    const x: u32 = @intCast(try data.drawInteger(0, width - 1, 0));
    const region_width: u32 = @intCast(try data.drawInteger(1, width - x, 1));
    const y: u32 = @intCast(try data.drawInteger(0, height - 1, 0));
    const region_height: u32 = @intCast(try data.drawInteger(1, height - y, 1));
    return .{
        .width = width,
        .height = height,
        .region = .{
            .x = x,
            .y = y,
            .width = region_width,
            .height = region_height,
        },
        .source_slack = try drawSlack(data),
        .destination_slack = try drawSlack(data),
        .fill = @intCast(try data.drawInteger(0, 3, 0)),
        .seed = try data.drawInteger(0, std.math.maxInt(u64), 0),
    };
}

fn paint(bytes: []u8, fill: u8, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    switch (fill) {
        0 => random.bytes(bytes),
        1 => @memset(bytes, 0x00),
        2 => @memset(bytes, 0xff),
        else => for (bytes) |*byte| {
            byte.* = if (random.boolean()) 0xff else 0x00;
        },
    }
}

fn mount(
    mapping: []align(std.heap.page_size_min) u8,
    shape: Shape,
    format: shm.Format,
) shm.Buffer {
    return .{
        .object_id = 1,
        .mapping = mapping,
        .byte_len = shape.byteLen(),
        .width = shape.width,
        .height = shape.height,
        .stride = @intCast(shape.stride()),
        .format = format,
    };
}

fn writeThroughOracle(reference: []u8, source: []const u8, shape: Shape, format: shm.Format) void {
    var row: u32 = 0;
    while (row < shape.region.height) : (row += 1) {
        const offset = shape.rowOffset(row);
        oracle(
            reference[offset..][0..shape.rowLen()],
            source[offset..][0..shape.rowLen()],
            format,
        );
    }
}

fn copyThroughOracle(reference: []u8, mapping: []const u8, shape: Shape, format: shm.Format) void {
    var row: u32 = 0;
    while (row < shape.region.height) : (row += 1) {
        oracle(
            reference[@as(usize, row) * shape.rowLen() ..][0..shape.rowLen()],
            mapping[shape.rowOffset(row)..][0..shape.rowLen()],
            format,
        );
    }
}

const WriteMatchesOracle = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: std.mem.Allocator) !void {
        const shape = try drawShape(data);
        const frame = try allocator.alloc(u8, shape.byteLen() + maximum_slack_bytes);
        defer allocator.free(frame);
        paint(frame, shape.fill, shape.seed);
        const source = frame[shape.source_slack..];

        const mapping = try allocator.alignedAlloc(
            u8,
            .fromByteUnits(std.heap.page_size_min),
            shape.byteLen(),
        );
        defer allocator.free(mapping);
        const reference = try allocator.alloc(u8, shape.byteLen());
        defer allocator.free(reference);

        for (std.meta.tags(shm.Format)) |format| {
            @memset(mapping, background);
            @memset(reference, background);
            var buffer = mount(mapping, shape, format);
            try buffer.writeRgba8(source, shape.region);
            writeThroughOracle(reference, source, shape, format);
            try std.testing.expectEqualSlices(u8, reference, mapping);
        }
    }
};

const CopyMatchesOracle = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: std.mem.Allocator) !void {
        const shape = try drawShape(data);
        const mapping = try allocator.alignedAlloc(
            u8,
            .fromByteUnits(std.heap.page_size_min),
            shape.byteLen(),
        );
        defer allocator.free(mapping);
        paint(mapping, shape.fill, shape.seed);

        const held = try allocator.alloc(u8, shape.regionLen() + maximum_slack_bytes);
        defer allocator.free(held);
        const reference = try allocator.alloc(u8, held.len);
        defer allocator.free(reference);

        for (std.meta.tags(shm.Format)) |format| {
            @memset(held, background);
            @memset(reference, background);
            const buffer = mount(mapping, shape, format);
            try buffer.copyRegionRgba8(shape.region, held[shape.destination_slack..]);
            copyThroughOracle(reference[shape.destination_slack..], mapping, shape, format);
            try std.testing.expectEqualSlices(u8, reference, held);
        }
    }
};

const RoundTripPreservesColour = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: std.mem.Allocator) !void {
        const shape = try drawShape(data);
        const frame = try allocator.alloc(u8, shape.byteLen());
        defer allocator.free(frame);
        paint(frame, shape.fill, shape.seed);
        const mapping = try allocator.alignedAlloc(
            u8,
            .fromByteUnits(std.heap.page_size_min),
            shape.byteLen(),
        );
        defer allocator.free(mapping);
        const decoded = try allocator.alloc(u8, shape.regionLen());
        defer allocator.free(decoded);

        for (std.meta.tags(shm.Format)) |format| {
            @memset(mapping, background);
            var buffer = mount(mapping, shape, format);
            try buffer.writeRgba8(frame, shape.region);
            try buffer.copyRegionRgba8(shape.region, decoded);
            try expectRoundTrip(decoded, frame, shape, format);
        }
    }
};

fn expectRoundTrip(decoded: []const u8, frame: []const u8, shape: Shape, format: shm.Format) !void {
    var row: u32 = 0;
    while (row < shape.region.height) : (row += 1) {
        const origin = shape.rowOffset(row);
        const carried = decoded[@as(usize, row) * shape.rowLen() ..][0..shape.rowLen()];
        var offset: usize = 0;
        while (offset < carried.len) : (offset += 4) {
            try std.testing.expectEqualSlices(
                u8,
                frame[origin + offset ..][0..3],
                carried[offset..][0..3],
            );
            const expected: u8 = switch (format) {
                .argb8888, .abgr8888 => frame[origin + offset + 3],
                .xrgb8888, .xbgr8888 => 0xff,
            };
            try std.testing.expectEqual(expected, carried[offset + 3]);
        }
    }
}

test "property: the vector shared memory swizzle equals the scalar oracle" {
    try hypothesis.checkNamed(
        WriteMatchesOracle,
        "wayland-shm-write-matches-oracle",
        settings(0x5741_594c_414e_4421),
    );
}

test "property: the vector shared memory readback equals the scalar oracle" {
    try hypothesis.checkNamed(
        CopyMatchesOracle,
        "wayland-shm-copy-matches-oracle",
        settings(0x5741_594c_414e_4422),
    );
}

test "property: a shared memory round trip preserves colour under the alpha rule" {
    try hypothesis.checkNamed(
        RoundTripPreservesColour,
        "wayland-shm-round-trip",
        settings(0x5741_594c_414e_4423),
    );
}

fn expectShapeMatchesOracle(allocator: std.mem.Allocator, shape: Shape) !void {
    const frame = try allocator.alloc(u8, shape.byteLen() + maximum_slack_bytes);
    defer allocator.free(frame);
    paint(frame, shape.fill, shape.seed);
    const source = frame[shape.source_slack..];
    const mapping = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        shape.byteLen(),
    );
    defer allocator.free(mapping);
    const reference = try allocator.alloc(u8, shape.byteLen());
    defer allocator.free(reference);
    const held = try allocator.alloc(u8, shape.regionLen() + maximum_slack_bytes);
    defer allocator.free(held);
    const copied = try allocator.alloc(u8, held.len);
    defer allocator.free(copied);

    for (std.meta.tags(shm.Format)) |format| {
        @memset(mapping, background);
        @memset(reference, background);
        var buffer = mount(mapping, shape, format);
        try buffer.writeRgba8(source, shape.region);
        writeThroughOracle(reference, source, shape, format);
        try std.testing.expectEqualSlices(u8, reference, mapping);

        paint(mapping, shape.fill +% 1, shape.seed +% 1);
        @memset(held, background);
        @memset(copied, background);
        try buffer.copyRegionRgba8(shape.region, held[shape.destination_slack..]);
        copyThroughOracle(copied[shape.destination_slack..], mapping, shape, format);
        try std.testing.expectEqualSlices(u8, copied, held);
    }
}

test "every row length from one to 257 pixels swizzles like the scalar oracle" {
    var pixels: u32 = 1;
    while (pixels <= maximum_row_pixels) : (pixels += 1) {
        try expectShapeMatchesOracle(std.testing.allocator, .{
            .width = pixels,
            .height = 1,
            .region = .{ .x = 0, .y = 0, .width = pixels, .height = 1 },
            .source_slack = 4 * (pixels % 16),
            .destination_slack = 4 * (pixels % 4),
            .fill = @intCast(pixels % 4),
            .seed = pixels,
        });
    }
}

test "production row widths swizzle like the scalar oracle" {
    const widths = [_]u32{ 512, 1023, 1024, 1920, 3839, 3840 };
    for (widths, 0..) |width, index| {
        const inset: u32 = @intCast(index % 4);
        try expectShapeMatchesOracle(std.testing.allocator, .{
            .width = width,
            .height = 2,
            .region = .{
                .x = inset,
                .y = 0,
                .width = width - inset,
                .height = 2,
            },
            .source_slack = 4 * index,
            .destination_slack = 4 * (index % 8),
            .fill = @intCast(index % 4),
            .seed = width,
        });
    }
}
