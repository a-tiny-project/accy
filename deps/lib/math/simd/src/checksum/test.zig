const std = @import("std");
const checksum = @import("root.zig");

const Adler32 = checksum.Adler32;
const Crc32 = checksum.Crc32;

test {
    _ = checksum.adler;
    _ = checksum.crc;
}

/// The differential tests read every length up to this one.
const length_max = 4096;
/// Starting offsets the tests draw from, so that slices start at every
/// alignment below a cache line.
const offset_max = 64;

test "CRC-32 equals the standard library at every length to 4096 and random offsets" {
    var prng = std.Random.DefaultPrng.init(0x6372_6333_3264_6966);
    const random = prng.random();
    var bytes: [length_max + offset_max]u8 = undefined;
    random.bytes(&bytes);
    for (0..length_max + 1) |len| {
        const offset = random.uintLessThan(usize, offset_max);
        const input = bytes[offset..][0..len];
        try std.testing.expectEqual(std.hash.Crc32.hash(input), Crc32.hash(input));
    }
    for (0..offset_max) |offset| {
        for ([_]usize{ 63, 64, 65, 255, 256, 257, 1000 }) |len| {
            const input = bytes[offset..][0..len];
            try std.testing.expectEqual(std.hash.Crc32.hash(input), Crc32.hash(input));
        }
    }
}

test "Adler-32 equals the standard library at every length to 4096 and random offsets" {
    var prng = std.Random.DefaultPrng.init(0x6164_6c33_3264_6966);
    const random = prng.random();
    var bytes: [length_max + offset_max]u8 = undefined;
    random.bytes(&bytes);
    for (0..length_max + 1) |len| {
        const offset = random.uintLessThan(usize, offset_max);
        const input = bytes[offset..][0..len];
        try std.testing.expectEqual(std.hash.Adler32.hash(input), Adler32.hash(input));
    }
    for (0..offset_max) |offset| {
        for ([_]usize{ 15, 16, 17, 31, 32, 33, 63, 64, 65, 1000 }) |len| {
            const input = bytes[offset..][0..len];
            try std.testing.expectEqual(std.hash.Adler32.hash(input), Adler32.hash(input));
        }
    }
}

test "checksums of pieces equal checksums of the whole" {
    var prng = std.Random.DefaultPrng.init(0x7069_6563_6573_3332);
    const random = prng.random();
    var bytes: [length_max + offset_max]u8 = undefined;
    random.bytes(&bytes);
    for (0..200) |_| {
        const len = random.uintAtMost(usize, length_max);
        const input = bytes[random.uintLessThan(usize, offset_max)..][0..len];
        var crc = Crc32.init();
        var adler = Adler32.init();
        var start: usize = 0;
        while (start < len) {
            const piece = @min(len - start, random.uintAtMost(usize, 300));
            crc.update(input[start..][0..piece]);
            adler.update(input[start..][0..piece]);
            start += piece;
        }
        try std.testing.expectEqual(Crc32.hash(input), crc.final());
        try std.testing.expectEqual(Adler32.hash(input), adler.final());
    }
}

test "long inputs past the Adler-32 reduction bound equal the standard library" {
    var prng = std.Random.DefaultPrng.init(0x6c6f_6e67_3332_6966);
    const random = prng.random();
    var bytes: [70_001]u8 = undefined;
    random.bytes(&bytes);
    var saturated: [bytes.len]u8 = undefined;
    @memset(&saturated, 0xff);
    for ([_][]const u8{ &bytes, &saturated }) |source| {
        for ([_]usize{ 5_552, 5_553, 65_535, 65_536, source.len }) |len| {
            try std.testing.expectEqual(
                std.hash.Crc32.hash(source[0..len]),
                Crc32.hash(source[0..len]),
            );
            try std.testing.expectEqual(
                std.hash.Adler32.hash(source[0..len]),
                Adler32.hash(source[0..len]),
            );
        }
    }
}
