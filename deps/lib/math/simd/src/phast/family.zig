const std = @import("std");
const simd = @import("../root.zig");
const hash_mod = simd.hash;
const multiply = simd.multiply;
const shift = simd.shift;

pub const PhastError = error{
    BuildFailed,
    CapacityExceeded,
    DuplicateKey,
    InputOutputOverlap,
    InvalidData,
    PlanMismatch,
    ScratchTooSmall,
    SeedsTooSmall,
};

pub const Placement = struct {
    num_slice_offsets: u32 = 0,
    slice_mask: u32 = 0,

    pub fn init(num_slots: usize, slice_length: usize) PhastError!Placement {
        if (slice_length == 0 or !std.math.isPowerOfTwo(slice_length)) {
            return error.InvalidData;
        }
        if (num_slots < slice_length or num_slots > std.math.maxInt(u32)) {
            return error.CapacityExceeded;
        }
        if (slice_length > std.math.maxInt(u32)) return error.CapacityExceeded;
        const num_slice_offsets = num_slots - slice_length + 1;
        return .{
            .num_slice_offsets = @intCast(num_slice_offsets),
            .slice_mask = @intCast(slice_length - 1),
        };
    }

    pub fn sliceLength(self: Placement) usize {
        return @as(usize, self.slice_mask) + 1;
    }
};

pub const Config = struct {
    num_slots: usize = 0,
    hash_key: u32 = 0,
    bucket_mask: u32 = 0,
    placement: Placement = .{},

    pub fn numBuckets(self: Config) usize {
        return @as(usize, self.bucket_mask) + 1;
    }

    pub fn allocatedBytes(self: Config, payload_bytes: usize) PhastError!usize {
        const payload = std.math.mul(usize, self.num_slots, payload_bytes) catch
            return error.CapacityExceeded;
        const seed_bytes = std.mem.alignForward(usize, self.numBuckets(), @sizeOf(u32));
        return std.math.add(usize, payload, seed_bytes) catch
            return error.CapacityExceeded;
    }

    pub fn seedWordsLen(self: Config) usize {
        return seedWordLength(self.numBuckets());
    }
};

pub const Seeds = struct {
    words: []const u32 = &.{},

    pub fn get(self: Seeds, bucket_index: u32) u32 {
        std.debug.assert(@as(usize, bucket_index) < self.words.len * @sizeOf(u32));
        const bit_index = (bucket_index & 3) * 8;
        return (self.words[bucket_index >> 2] >> @intCast(bit_index)) & 0xff;
    }
};

pub const Data = struct {
    config: Config = .{},
    seeds: Seeds = .{},
    config_index: usize = 0,
    attempt_index: usize = 0,

    pub fn numSlots(self: Data) usize {
        return self.config.num_slots;
    }

    pub fn allocatedBytes(self: Data, payload_bytes: usize) PhastError!usize {
        return self.config.allocatedBytes(payload_bytes);
    }

    pub fn isEmpty(self: Data) bool {
        return self.config.num_slots == 0;
    }
};

pub const Phast = struct {
    data: Data,
    hash: hash_mod.Triple32,

    const Self = @This();

    pub fn init(data: Data) PhastError!Self {
        if (data.isEmpty()) return error.BuildFailed;
        const num_buckets = data.config.numBuckets();
        const slice_length = data.config.placement.sliceLength();
        if (data.config.num_slots > std.math.maxInt(u32) or
            num_buckets > std.math.maxInt(u32) or
            !std.math.isPowerOfTwo(num_buckets) or
            data.seeds.words.len != data.config.seedWordsLen() or
            data.config.placement.num_slice_offsets == 0 or
            !std.math.isPowerOfTwo(slice_length) or
            slice_length > data.config.num_slots or
            data.config.placement.num_slice_offsets !=
                data.config.num_slots - slice_length + 1)
        {
            return error.InvalidData;
        }
        return .{
            .data = data,
            .hash = hash_mod.Triple32.initKey(data.config.hash_key),
        };
    }

    pub fn index(self: Self, key: u32) u32 {
        const hash = self.hash.hash(key);
        const seed = self.data.seeds.get(hash & self.data.config.bucket_mask);
        return positionFromHashAndSeed(self.data.config.placement, hash, seed);
    }

    pub fn twoVec(
        self: Self,
        comptime D: type,
        first_keys: D.Vector,
        second_keys: D.Vector,
    ) VectorPair(D) {
        requireTag(D);
        var first_hashes = first_keys;
        var second_hashes = second_keys;
        self.hash.twoVec(D, &first_hashes, &second_hashes);
        var first_seeds: D.Vector = undefined;
        var second_seeds: D.Vector = undefined;
        inline for (0..D.lane_count) |lane| {
            first_seeds[lane] = self.data.seeds.get(
                first_hashes[lane] & self.data.config.bucket_mask,
            );
            second_seeds[lane] = self.data.seeds.get(
                second_hashes[lane] & self.data.config.bucket_mask,
            );
        }
        return positionPairFromHashesAndSeeds(
            self.data.config.placement,
            D,
            first_hashes,
            second_hashes,
            first_seeds,
            second_seeds,
        );
    }

    pub fn indexBatch(
        self: Self,
        comptime D: type,
        keys: []const u32,
        indices: []u32,
    ) PhastError!void {
        requireTag(D);
        if (indices.len != keys.len) return error.PlanMismatch;
        var offset: usize = 0;
        while (offset + 2 * D.lane_count <= keys.len) : (offset += 2 * D.lane_count) {
            const first: D.Vector = keys[offset..][0..D.lane_count].*;
            const second: D.Vector = keys[offset + D.lane_count ..][0..D.lane_count].*;
            const result = self.twoVec(D, first, second);
            const first_indices: [D.lane_count]u32 = result.first;
            const second_indices: [D.lane_count]u32 = result.second;
            @memcpy(indices[offset..][0..D.lane_count], &first_indices);
            @memcpy(indices[offset + D.lane_count ..][0..D.lane_count], &second_indices);
        }
        for (keys[offset..], indices[offset..]) |key, *output| output.* = self.index(key);
    }
};

pub fn VectorPair(comptime D: type) type {
    requireTag(D);
    return struct {
        first: D.Vector,
        second: D.Vector,
    };
}

pub fn positionFromHashAndSeed(placement: Placement, hash: u32, seed: u32) u32 {
    std.debug.assert(seed < 256);
    const slice_offset = hash_mod.lemireMod(hash, placement.num_slice_offsets);
    const within_slice = @as(u32, hash16(@truncate((hash >> 16) +% seed))) &
        placement.slice_mask;
    return slice_offset + within_slice;
}

pub fn seedWordLength(num_buckets: usize) usize {
    return std.math.divCeil(usize, num_buckets, @sizeOf(u32)) catch unreachable;
}

pub fn positionPairFromHashesAndSeeds(
    placement: Placement,
    comptime D: type,
    first_hashes: D.Vector,
    second_hashes: D.Vector,
    first_seeds: D.Vector,
    second_seeds: D.Vector,
) VectorPair(D) {
    const D16 = D.repartition(u16);
    var combined: D16.Vector = undefined;
    inline for (0..D.lane_count) |lane| {
        combined[lane] = @as(u16, @truncate(first_hashes[lane] >> 16)) +%
            @as(u16, @truncate(first_seeds[lane]));
        combined[D.lane_count + lane] =
            @as(u16, @truncate(second_hashes[lane] >> 16)) +%
            @as(u16, @truncate(second_seeds[lane]));
    }
    const within = hash16Vector(D16, combined);
    const offsets: D.Vector = @splat(placement.num_slice_offsets);
    const mask: D.Vector = @splat(placement.slice_mask);
    var result: VectorPair(D) = .{
        .first = multiply.mulHigh(D, first_hashes, offsets),
        .second = multiply.mulHigh(D, second_hashes, offsets),
    };
    inline for (0..D.lane_count) |lane| {
        result.first[lane] += @as(u32, within[lane]) & mask[lane];
        result.second[lane] += @as(u32, within[D.lane_count + lane]) & mask[lane];
    }
    return result;
}

fn hash16(initial: u16) u16 {
    var value = initial;
    value ^= value >> 8;
    const squared = value *% value;
    value +%= squared *% 0xca32;
    value ^= value >> 12;
    value *%= 0x3929;
    return value;
}

fn hash16Vector(comptime D: type, initial: D.Vector) D.Vector {
    var value = initial;
    value ^= shift.shiftRight(D, 8, value);
    value +%= (value *% value) *% @as(D.Vector, @splat(0xca32));
    value ^= shift.shiftRight(D, 12, value);
    value *%= @splat(0x3929);
    return value;
}

fn requireTag(comptime D: type) void {
    if (comptime D.Lane != u32) @compileError("PHAST tags require u32 lanes");
}
