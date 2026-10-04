const std = @import("std");
const simd = @import("../root.zig");
const image_api = @import("root.zig");
const tag = simd.tag;

const vector_size = image_api.vector_size;
const storage_alignment = image_api.storage_alignment;
const bytesPerRow = image_api.bytesPerRow;
const bytesPerRowFor = image_api.bytesPerRowFor;
const Image = image_api.Image;
const Image3 = image_api.Image3;
const Rect = image_api.Rect;
const sameSize = image_api.sameSize;
const mirror = image_api.mirror;
const WrapRowMirror = image_api.WrapRowMirror;

fn verifyAlignedWrites(comptime T: type) !void {
    const D = tag.ScalableTag(T);
    const maximum_stride = comptime bytesPerRowFor(128, @sizeOf(T), vector_size) catch unreachable;
    var storage: [maximum_stride * 3]u8 align(storage_alignment) = undefined;
    for (1..4) |ysize| {
        for (1..64) |xsize| {
            const stride = try bytesPerRowFor(xsize, @sizeOf(T), vector_size);
            const image = try Image(T).initBorrowed(xsize, ysize, stride, &storage);
            for (0..ysize) |y| {
                const row = image.mutableRow(y);
                var x: usize = 0;
                while (x < xsize) : (x += D.lane_count) {
                    var values: D.Vector = undefined;
                    inline for (0..D.lane_count) |lane| values[lane] = @intCast(x + lane);
                    row[x..][0..D.lane_count].* = @bitCast(values);
                }
            }
            try std.testing.expect(image.constRow(ysize - 1)[xsize - 1] < xsize + D.lane_count);
        }
    }
}

fn verifyUnalignedWrites(comptime T: type) !void {
    const D = tag.ScalableTag(T);
    const maximum_stride = comptime bytesPerRowFor(128, @sizeOf(T), vector_size) catch unreachable;
    var storage: [maximum_stride * 3]u8 align(storage_alignment) = undefined;
    for (1..4) |ysize| {
        for (1..128) |xsize| {
            const stride = try bytesPerRowFor(xsize, @sizeOf(T), vector_size);
            var image = try Image(T).initBorrowed(xsize, ysize, stride, &storage);
            try image.initializePaddingForUnalignedAccesses();
            for (0..ysize) |y| {
                const row = image.mutableRow(y);
                for (row[0..xsize], 0..) |*value, x| value.* = @intCast(x);
                row[xsize - 1 ..][0..D.lane_count].* = @splat(0);
                for (row[0 .. xsize - 1], 0..) |value, x| {
                    try std.testing.expectEqual(@as(T, @intCast(x)), value);
                }
            }
        }
    }
}

fn checkImageInitFailures(allocator: std.mem.Allocator) !void {
    var image = try Image(u32).init(allocator, 127, 3);
    image.deinit(allocator);
    var image3 = try Image3(u32).init(allocator, 127, 3);
    image3.deinit(allocator);
}

test "pinned Highway image row layout oracle" {
    const widths = [_]usize{ 0, 1, 15, 16, 17, 31, 32, 63, 64, 127, 128, 255, 256, 511, 512, 1024 };
    const expected = [4][widths.len]usize{
        .{ 256, 256, 256, 256, 256, 256, 256, 256, 256, 384, 384, 512, 512, 768, 768, 1280 },
        .{ 256, 256, 256, 256, 256, 256, 256, 384, 384, 512, 512, 768, 768, 1280, 1280, 2304 },
        .{ 256, 256, 256, 256, 256, 384, 384, 512, 512, 768, 768, 1280, 1280, 2304, 2304, 4352 },
        .{ 256, 256, 256, 384, 384, 384, 512, 640, 768, 1152, 1280, 2176, 2304, 4224, 4352, 8448 },
    };
    const sizes = [_]usize{ 1, 2, 4, 8 };
    for (sizes, expected) |component_size, row| {
        for (widths, row) |width, oracle| {
            try std.testing.expectEqual(oracle, try bytesPerRowFor(width, component_size, 16));
        }
    }
}

test "Highway image permits full aligned vector writes" {
    try verifyAlignedWrites(u8);
    try verifyAlignedWrites(u16);
    try verifyAlignedWrites(u32);
    try verifyAlignedWrites(u64);
}

test "Highway image permits unaligned writes at the last sample" {
    try verifyUnalignedWrites(u8);
    try verifyUnalignedWrites(u16);
    try verifyUnalignedWrites(u32);
    try verifyUnalignedWrites(u64);
}

test "image borrowed storage validates alignment stride and capacity" {
    var storage: [512]u8 align(storage_alignment) = undefined;
    var image = try Image(u32).initBorrowed(17, 2, 256, &storage);
    try std.testing.expectEqual(@as(usize, 17), image.xsize());
    try std.testing.expectEqual(@as(usize, 2), image.ysize());
    try std.testing.expectEqual(@as(usize, 64), image.pixelsPerRow());
    image.mutableRow(1)[16] = 91;
    try std.testing.expectEqual(@as(u32, 91), image.constRow(1)[16]);
    image.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.MisalignedStorage,
        Image(u32).initBorrowed(1, 1, 256, storage[1..]),
    );
    try std.testing.expectError(
        error.InvalidStride,
        Image(u32).initBorrowed(17, 2, 64, &storage),
    );
    try std.testing.expectError(
        error.BufferTooSmall,
        Image(u32).initBorrowed(17, 2, 256, storage[0..511]),
    );
    var tight_storage: [vector_size]u8 align(storage_alignment) = undefined;
    var tight = try Image(u8).initBorrowed(
        vector_size,
        1,
        vector_size,
        &tight_storage,
    );
    if (vector_size == 1) {
        try tight.initializePaddingForUnalignedAccesses();
    } else {
        try std.testing.expectError(
            error.InsufficientRowPadding,
            tight.initializePaddingForUnalignedAccesses(),
        );
    }
}

test "zero-area images preserve each reported dimension without allocation" {
    var wide = try Image(u32).init(std.testing.allocator, 17, 0);
    defer wide.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 17), wide.xsize());
    try std.testing.expectEqual(@as(usize, 0), wide.ysize());
    try std.testing.expectEqual(@as(usize, 0), wide.bytesPerRow());
    try std.testing.expectEqual(@as(usize, 0), wide.bytes().len);

    var tall = try Image(u32).init(std.testing.allocator, 0, 3);
    defer tall.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), tall.xsize());
    try std.testing.expectEqual(@as(usize, 3), tall.ysize());
    try std.testing.expectEqual(@as(usize, 0), tall.constRow(2).len);

    var planes = try Image3(u32).init(std.testing.allocator, 19, 0);
    defer planes.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 19), planes.xsize());
    try std.testing.expectEqual(@as(usize, 0), planes.ysize());
}

test "image padding initialization preserves valid samples" {
    var image = try Image(u8).init(std.testing.allocator, 129, 2);
    defer image.deinit(std.testing.allocator);
    for (0..image.ysize()) |y| {
        @memset(image.mutableRow(y)[0..image.xsize()], 0xa5);
    }
    try image.initializePaddingForUnalignedAccesses();
    for (0..image.ysize()) |y| {
        const row = image.constRow(y);
        for (row[0..image.xsize()]) |value| try std.testing.expectEqual(@as(u8, 0xa5), value);
        for (row[image.xsize() .. image.xsize() + vector_size - 1]) |value| {
            try std.testing.expectEqual(@as(u8, 0), value);
        }
    }
}

test "image swap and shrink preserve storage layout" {
    var first = try Image(u16).init(std.testing.allocator, 31, 3);
    defer first.deinit(std.testing.allocator);
    var second = try Image(u16).init(std.testing.allocator, 7, 2);
    defer second.deinit(std.testing.allocator);
    const first_ptr = first.bytes().ptr;
    first.swap(&second);
    try std.testing.expectEqual(@as(usize, 7), first.xsize());
    try std.testing.expectEqual(first_ptr, second.bytes().ptr);
    try second.shrinkTo(9, 1);
    try std.testing.expectEqual(@as(usize, 9), second.xsize());
    try std.testing.expectError(error.InvalidShrink, second.shrinkTo(32, 1));
}

test "image3 owns one packed allocation and consumes matching planes" {
    var packed_image = try Image3(u32).init(std.testing.allocator, 17, 3);
    defer packed_image.deinit(std.testing.allocator);
    const plane_size = packed_image.bytesPerRow() * packed_image.ysize();
    try std.testing.expectEqual(
        plane_size,
        @intFromPtr(packed_image.plane(1).constBytes().ptr) -
            @intFromPtr(packed_image.plane(0).constBytes().ptr),
    );
    packed_image.mutablePlaneRow(2, 1)[16] = 0x1234;
    try std.testing.expectEqual(@as(u32, 0x1234), packed_image.constPlaneRow(2, 1)[16]);

    var p0 = try Image(u32).init(std.testing.allocator, 9, 2);
    var p1 = try Image(u32).init(std.testing.allocator, 9, 2);
    var p2 = try Image(u32).init(std.testing.allocator, 9, 2);
    var moved = try Image3(u32).initPlanes(&p0, &p1, &p2);
    defer moved.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), p0.xsize());
    try std.testing.expectEqual(@as(usize, 9), moved.xsize());
}

test "image3 borrowed planes and plane transfer reject broken invariants" {
    var storage: [3][768]u8 align(storage_alignment) = undefined;
    var borrowed = try Image3(u16).initBorrowed(
        31,
        2,
        256,
        .{ &storage[0], &storage[1], &storage[2] },
    );
    defer borrowed.deinit(std.testing.allocator);
    borrowed.mutablePlaneRow(1, 1)[30] = 73;
    try std.testing.expectEqual(@as(u16, 73), borrowed.constPlaneRow(1, 1)[30]);

    var small = try Image(u16).init(std.testing.allocator, 7, 2);
    defer small.deinit(std.testing.allocator);
    var large = try Image(u16).init(std.testing.allocator, 8, 2);
    defer large.deinit(std.testing.allocator);
    var third = try Image(u16).init(std.testing.allocator, 7, 2);
    defer third.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.PlaneSizeMismatch,
        Image3(u16).initPlanes(&small, &large, &third),
    );
    try std.testing.expectError(
        error.AliasedPlanes,
        Image3(u16).initPlanes(&small, &small, &third),
    );
    try std.testing.expectEqual(@as(usize, 7), small.xsize());

    var stride0 = try Image(u16).initBorrowed(7, 2, 256, &storage[0]);
    defer stride0.deinit(std.testing.allocator);
    var stride1 = try Image(u16).initBorrowed(7, 2, 384, &storage[1]);
    defer stride1.deinit(std.testing.allocator);
    var stride2 = try Image(u16).initBorrowed(7, 2, 256, &storage[2]);
    defer stride2.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.PlaneStrideMismatch,
        Image3(u16).initPlanes(&stride0, &stride1, &stride2),
    );
}

test "image construction recovers from every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkImageInitFailures,
        .{},
    );
}

test "rectangles clamp compose and address image rows" {
    var image = try Image(u32).init(std.testing.allocator, 20, 10);
    defer image.deinit(std.testing.allocator);
    const rect = Rect.initClamped(17, 8, 8, 8, image.xsize(), image.ysize());
    try std.testing.expectEqual(@as(usize, 3), rect.xsize());
    try std.testing.expectEqual(@as(usize, 2), rect.ysize());
    try std.testing.expect(rect.isInside(&image));
    rect.mutableRow(u32, &image, 1)[0] = 77;
    try std.testing.expectEqual(@as(u32, 77), image.constRow(9)[17]);
    const sub = try rect.subrect(2, 1, 9, 9);
    try std.testing.expectEqual(@as(usize, 1), sub.xsize());
    try std.testing.expectEqual(@as(usize, 1), sub.ysize());
    try std.testing.expect(sameSize(sub, Rect.init(0, 0, 1, 1)));
}

test "pinned Highway mirror and row wrappers agree" {
    const expected = [_]usize{
        3, 4, 4, 3, 2, 1, 0, 0, 1, 2, 3, 4, 4, 3, 2, 1, 0, 0,
        1, 2, 3, 4, 4, 3, 2, 1, 0, 0, 1, 2, 3, 4, 4, 3, 2,
    };
    for (expected, 0..) |oracle, index| {
        try std.testing.expectEqual(oracle, mirror(@as(i64, @intCast(index)) - 17, 5));
    }
    var image = try Image(f32).init(std.testing.allocator, 8, 4);
    defer image.deinit(std.testing.allocator);
    const wrap = WrapRowMirror.init(&image, image.ysize());
    const stride: i64 = @intCast(image.pixelsPerRow());
    const first = image.constRow(0).ptr;
    const last = image.constRow(3).ptr;
    try std.testing.expectEqual(first, wrap.call(first - @as(usize, @intCast(stride)), stride));
    try std.testing.expectEqual(last, wrap.call(last + @as(usize, @intCast(stride)), stride));
    try std.testing.expectEqual(
        first + @as(usize, @intCast(stride)),
        wrap.call(first - 2 * @as(usize, @intCast(stride)), stride),
    );
}

test "image capacity boundaries reject overflow before allocation" {
    try std.testing.expectError(error.RowSizeOverflow, bytesPerRow(std.math.maxInt(usize), 8));
    if (comptime @bitSizeOf(usize) > 32) {
        try std.testing.expectError(
            error.DimensionTooLarge,
            Image(u8).init(
                std.testing.allocator,
                @as(usize, std.math.maxInt(u32)) + 1,
                1,
            ),
        );
        try std.testing.expectError(
            error.AllocationSizeOverflow,
            Image(u64).init(
                std.testing.allocator,
                std.math.maxInt(u32),
                std.math.maxInt(u32),
            ),
        );
    }
}

test {
    std.testing.refAllDecls(image_api);
}
