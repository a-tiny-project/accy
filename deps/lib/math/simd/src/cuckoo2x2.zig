const std = @import("std");
const hash_mod = @import("hash.zig");
const indexed = @import("indexed.zig");
const random = @import("random.zig");
const shift = @import("shift.zig");
const tag = @import("tag.zig");

pub const minimum_bucket_count: usize = 262_144;
pub const configuration_count: usize = 3;
pub const max_attempts: usize = 512;
pub const max_displacements: usize = 500;

pub const Cuckoo2x2Config = struct {
    bucket_mask: u32 = 0,
    hash_key: u32 = 0,

    const Self = @This();

    pub fn init(num_buckets: usize, hash_key: u32) Self {
        std.debug.assert(num_buckets != 0);
        std.debug.assert(num_buckets <= std.math.maxInt(u32));
        std.debug.assert(std.math.isPowerOfTwo(num_buckets));
        return .{
            .bucket_mask = @intCast(num_buckets - 1),
            .hash_key = hash_key,
        };
    }

    pub fn numBuckets(self: Self) usize {
        return @as(usize, self.bucket_mask) + 1;
    }
};

pub const Cuckoo2x2Data = struct {
    config: Cuckoo2x2Config = .{},
    entries: []const u32 = &.{},
    config_idx: usize = 0,
    attempt_idx: usize = 0,
    num_primary: u32 = 0,
    num_secondary: u32 = 0,

    const Self = @This();

    pub fn isEmpty(self: Self) bool {
        return self.entries.len == 0;
    }

    pub fn numBuckets(self: Self) usize {
        if (self.isEmpty()) return 0;
        std.debug.assert(self.entries.len == self.config.numBuckets());
        return self.entries.len;
    }

    pub fn allocatedBytes(self: Self) usize {
        return self.entries.len * @sizeOf(u32);
    }
};

pub const Cuckoo2x2 = struct {
    hash1: hash_mod.WeakTwoMul,
    data: Cuckoo2x2Data,

    const Self = @This();

    pub fn init(data: Cuckoo2x2Data) Self {
        std.debug.assert(!data.isEmpty());
        std.debug.assert(data.numBuckets() >= minimum_bucket_count);
        return .{
            .hash1 = hash_mod.WeakTwoMul.initKey(data.config.hash_key),
            .data = data,
        };
    }

    pub fn getData(self: Self) Cuckoo2x2Data {
        return self.data;
    }

    pub fn contains(self: Self, key: u32) bool {
        const h1 = self.hash1.hash(key);
        const b1 = h1 & self.data.config.bucket_mask;
        const fingerprint = h1 >> 18;
        const b2 = b1 ^ (fingerprint + 1);
        const primary: u16 = @truncate(fingerprint | 0x4000);
        const secondary: u16 = @truncate(fingerprint | 0x8000);
        const e1 = self.data.entries[b1];
        const e2 = self.data.entries[b2];
        return primary == @as(u16, @truncate(e1)) or
            primary == @as(u16, @truncate(e1 >> 16)) or
            secondary == @as(u16, @truncate(e2)) or
            secondary == @as(u16, @truncate(e2 >> 16));
    }

    pub fn query(self: Self, comptime D: type, keys: D.Vector) D.Mask {
        requireTag(D);
        const h1 = self.hash1.oneVec(D, keys);
        const b1 = h1 & @as(D.Vector, @splat(self.data.config.bucket_mask));
        const fingerprint = shift.shiftRight(D, 18, h1);
        const b2 = b1 ^ (fingerprint +% @as(D.Vector, @splat(1)));
        const primary = fingerprint | @as(D.Vector, @splat(0x4000));
        const secondary = fingerprint | @as(D.Vector, @splat(0x8000));
        const e1 = indexed.gatherIndex(D, self.data.entries, b1);
        const e2 = indexed.gatherIndex(D, self.data.entries, b2);
        const low_mask: D.Vector = @splat(0xffff);
        const found = (e1 & low_mask == primary) |
            (shift.shiftRight(D, 16, e1) == primary) |
            (e2 & low_mask == secondary) |
            (shift.shiftRight(D, 16, e2) == secondary);
        return !found;
    }

    pub fn containsVec(self: Self, comptime D: type, keys: D.Vector) D.Mask {
        return !self.query(D, keys);
    }
};

pub const Cuckoo2x2BuildError = error{
    BuildFailed,
    CapacityExceeded,
    DuplicateKey,
    EntriesTooSmall,
    PlanMismatch,
    ScratchTooSmall,
};

pub const Cuckoo2x2Plan = struct {
    key_count: usize,
    bucket_counts: [configuration_count]usize,
    max_bucket_count: usize,
    entries_len: usize,
    scratch_len: usize,

    const Self = @This();

    pub fn inspect(key_count: usize) Cuckoo2x2BuildError!Self {
        if (key_count > std.math.maxInt(u32)) return error.CapacityExceeded;
        const quarter = key_count / 4;
        const base = if (quarter <= 1)
            @as(usize, 1)
        else
            std.math.ceilPowerOfTwo(usize, quarter) catch return error.CapacityExceeded;
        var bucket_counts: [configuration_count]usize = undefined;
        inline for (0..configuration_count) |index| {
            const multiplier = @as(usize, 1) << index;
            const candidate = std.math.mul(usize, base, multiplier) catch
                return error.CapacityExceeded;
            const num_buckets = @max(candidate, minimum_bucket_count);
            if (num_buckets > std.math.maxInt(u32)) return error.CapacityExceeded;
            bucket_counts[index] = num_buckets;
        }
        const max_bucket_count = bucket_counts[configuration_count - 1];
        const bucket_key_count = std.math.mul(usize, max_bucket_count, 2) catch
            return error.CapacityExceeded;
        const byte_count = std.math.add(usize, key_count, max_bucket_count) catch
            return error.CapacityExceeded;
        const byte_words = std.math.divCeil(usize, byte_count, @sizeOf(u32)) catch
            unreachable;
        const hash_and_keys = std.math.add(usize, key_count, bucket_key_count) catch
            return error.CapacityExceeded;
        const scratch_len = std.math.add(usize, hash_and_keys, byte_words) catch
            return error.CapacityExceeded;
        return .{
            .key_count = key_count,
            .bucket_counts = bucket_counts,
            .max_bucket_count = max_bucket_count,
            .entries_len = max_bucket_count,
            .scratch_len = scratch_len,
        };
    }

    pub fn build(
        self: Self,
        scratch: []u32,
        entries: []u32,
        keys: []const u32,
    ) Cuckoo2x2BuildError!Cuckoo2x2Data {
        if (keys.len != self.key_count) return error.PlanMismatch;
        if (scratch.len < self.scratch_len) return error.ScratchTooSmall;
        if (entries.len < self.entries_len) return error.EntriesTooSmall;
        const parts = self.sections(scratch);
        const engine = random.AesCtrEngine.initDeterministic();
        const distinct_hash = hash_mod.WeakTwoMul.initSeed(&engine, 0);
        hash_mod.hashArray(tag.ScalableTag(u32), distinct_hash, keys, parts.hashes);
        std.mem.sort(u32, parts.hashes, {}, std.sort.asc(u32));
        const sorted_hashes = parts.hashes;
        if (sorted_hashes.len > 1) {
            const previous_hashes = sorted_hashes[0 .. sorted_hashes.len - 1];
            for (sorted_hashes[1..], previous_hashes) |current, previous| {
                if (current == previous) return error.DuplicateKey;
            }
        }

        for (self.bucket_counts, 0..) |num_buckets, config_idx| {
            for (0..max_attempts) |attempt_idx| {
                const hash_key: u32 = @truncate(engine.generate(attempt_idx, 0));
                const config = Cuckoo2x2Config.init(num_buckets, hash_key);
                const hash1 = hash_mod.WeakTwoMul.initKey(hash_key);
                @memset(parts.counts[0..num_buckets], 0);
                @memset(entries[0..num_buckets], 0);
                hash_mod.hashArray(tag.ScalableTag(u32), hash1, keys, parts.hashes);
                if (!cuckooAssign(
                    config,
                    parts.hashes,
                    parts.choices,
                    parts.counts[0..num_buckets],
                    parts.bucket_keys[0 .. num_buckets * 2],
                )) continue;
                populateEntries(
                    config,
                    parts.hashes,
                    parts.choices,
                    parts.counts[0..num_buckets],
                    entries[0..num_buckets],
                );
                var num_primary: u32 = 0;
                for (parts.choices) |choice| num_primary += @intFromBool(choice == 0);
                return .{
                    .config = config,
                    .entries = entries[0..num_buckets],
                    .config_idx = config_idx,
                    .attempt_idx = attempt_idx,
                    .num_primary = num_primary,
                    .num_secondary = @as(u32, @intCast(keys.len)) - num_primary,
                };
            }
        }
        return error.BuildFailed;
    }

    fn sections(self: Self, scratch: []u32) ScratchSections {
        const hashes = scratch[0..self.key_count];
        const bucket_keys_begin = self.key_count;
        const bucket_keys_end = bucket_keys_begin + self.max_bucket_count * 2;
        const bucket_keys = scratch[bucket_keys_begin..bucket_keys_end];
        const bytes = std.mem.sliceAsBytes(scratch[bucket_keys_end..self.scratch_len]);
        const choices = bytes[0..self.key_count];
        const counts = bytes[self.key_count .. self.key_count + self.max_bucket_count];
        return .{
            .hashes = hashes,
            .bucket_keys = bucket_keys,
            .choices = choices,
            .counts = counts,
        };
    }
};

pub fn cuckoo2x2ScratchLen(key_count: usize) Cuckoo2x2BuildError!usize {
    return (try Cuckoo2x2Plan.inspect(key_count)).scratch_len;
}

pub fn cuckoo2x2EntriesLen(key_count: usize) Cuckoo2x2BuildError!usize {
    return (try Cuckoo2x2Plan.inspect(key_count)).entries_len;
}

pub fn buildCuckoo2x2(
    scratch: []u32,
    entries: []u32,
    keys: []const u32,
) Cuckoo2x2BuildError!Cuckoo2x2Data {
    const plan = try Cuckoo2x2Plan.inspect(keys.len);
    return plan.build(scratch, entries, keys);
}

pub fn makeCuckoo2x2(
    scratch: []u32,
    entries: []u32,
    keys: []const u32,
) Cuckoo2x2BuildError!Cuckoo2x2 {
    return Cuckoo2x2.init(try buildCuckoo2x2(scratch, entries, keys));
}

const ScratchSections = struct {
    hashes: []u32,
    bucket_keys: []u32,
    choices: []u8,
    counts: []u8,
};

fn bucket(config: Cuckoo2x2Config, hashes: []const u32, key_idx: usize, which: u8) usize {
    const value = hashes[key_idx];
    const primary = value & config.bucket_mask;
    if (which == 0) return primary;
    return primary ^ ((value >> 18) + 1);
}

fn cuckooAssign(
    config: Cuckoo2x2Config,
    hashes: []const u32,
    choices: []u8,
    counts: []u8,
    bucket_keys: []u32,
) bool {
    std.debug.assert(hashes.len == choices.len);
    std.debug.assert(counts.len == config.numBuckets());
    std.debug.assert(bucket_keys.len == counts.len * 2);
    @memset(bucket_keys, std.math.maxInt(u32));
    for (0..hashes.len) |key_idx| {
        var displaced = key_idx;
        const primary = bucket(config, hashes, displaced, 0);
        const secondary = bucket(config, hashes, displaced, 1);
        if (counts[primary] <= counts[secondary] and counts[primary] < 2) {
            choices[displaced] = 0;
            bucket_keys[primary * 2 + counts[primary]] = @intCast(displaced);
            counts[primary] += 1;
            continue;
        }
        if (counts[secondary] < 2) {
            choices[displaced] = 1;
            bucket_keys[secondary * 2 + counts[secondary]] = @intCast(displaced);
            counts[secondary] += 1;
            continue;
        }
        if (counts[primary] < 2) {
            choices[displaced] = 0;
            bucket_keys[primary * 2 + counts[primary]] = @intCast(displaced);
            counts[primary] += 1;
            continue;
        }

        var which: u8 = 0;
        var placed = false;
        for (0..max_displacements) |_| {
            const destination = bucket(config, hashes, displaced, which);
            if (counts[destination] < 2) {
                choices[displaced] = which;
                bucket_keys[destination * 2 + counts[destination]] = @intCast(displaced);
                counts[destination] += 1;
                placed = true;
                break;
            }
            const evicted = bucket_keys[destination * 2];
            bucket_keys[destination * 2] = bucket_keys[destination * 2 + 1];
            bucket_keys[destination * 2 + 1] = @intCast(displaced);
            choices[displaced] = which;
            displaced = evicted;
            which = 1 - choices[evicted];
        }
        if (!placed) return false;
    }
    return true;
}

fn populateEntries(
    config: Cuckoo2x2Config,
    hashes: []const u32,
    choices: []const u8,
    counts: []u8,
    entries: []u32,
) void {
    std.debug.assert(hashes.len == choices.len);
    std.debug.assert(counts.len == entries.len);
    @memset(counts, 0);
    for (hashes, choices) |value, choice| {
        const primary = value & config.bucket_mask;
        const fingerprint = value >> 18;
        const destination = if (choice == 0) primary else primary ^ (fingerprint + 1);
        const tagged = fingerprint | if (choice == 0) @as(u32, 0x4000) else 0x8000;
        const slot = counts[destination];
        std.debug.assert(slot < 2);
        entries[destination] |= tagged << @intCast(slot * 16);
        counts[destination] += 1;
    }
    for (entries, counts) |*entry, count| {
        if (count == 1) entry.* |= entry.* << 16;
    }
}

fn requireTag(comptime D: type) void {
    if (comptime D.Lane != u32) @compileError("Cuckoo2x2 requires u32 lanes");
}
