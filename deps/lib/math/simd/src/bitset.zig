const std = @import("std");
const builtin = @import("builtin");

const runtime_assertions = builtin.mode == .debug or builtin.mode == .safe;

pub const BitSet64 = struct {
    bits: u64 = 0,

    pub const max_size: usize = 64;

    pub fn maxSize(_: *const @This()) usize {
        return max_size;
    }

    pub fn set(self: *@This(), index: usize) void {
        std.debug.assert(index < max_size);
        self.bits |= bit(index);
        std.debug.assert(self.get(index));
    }

    pub fn setNonzeroBitsFrom64(self: *@This(), bits: u64) void {
        self.bits |= bits;
    }

    pub fn clear(self: *@This(), index: usize) void {
        std.debug.assert(index < max_size);
        self.bits &= ~bit(index);
        std.debug.assert(!self.get(index));
    }

    pub fn get(self: *const @This(), index: usize) bool {
        std.debug.assert(index < max_size);
        return self.bits & bit(index) != 0;
    }

    pub fn any(self: *const @This()) bool {
        return self.bits != 0;
    }

    pub fn all(self: *const @This()) bool {
        return self.bits == std.math.maxInt(u64);
    }

    pub fn first(self: *const @This()) usize {
        std.debug.assert(self.any());
        return firstBit(self.bits);
    }

    pub fn first0(self: *const @This()) usize {
        std.debug.assert(!self.all());
        return firstBit(~self.bits);
    }

    pub fn get64(self: *const @This()) u64 {
        return self.bits;
    }

    pub fn foreach(self: *const @This(), function: anytype) void {
        visitWord(self.bits, 0, function);
    }

    pub fn count(self: *const @This()) usize {
        return @popCount(self.bits);
    }
};

pub fn BitSet(comptime size: usize) type {
    requireCapacity(size);
    const word_count = wordsFor(size);

    return struct {
        words: [word_count]BitSet64 = @as([word_count]BitSet64, @splat(.{})),

        const Self = @This();
        pub const capacity: usize = size;
        pub const max_size: usize = capacity;

        pub fn maxSize(_: *const Self) usize {
            return max_size;
        }

        pub fn set(self: *Self, index: usize) void {
            std.debug.assert(index < max_size);
            self.words[wordIndex(index)].set(bitIndex(index));
            std.debug.assert(self.get(index));
        }

        pub fn clear(self: *Self, index: usize) void {
            std.debug.assert(index < max_size);
            self.words[wordIndex(index)].clear(bitIndex(index));
            std.debug.assert(!self.get(index));
        }

        pub fn get(self: *const Self, index: usize) bool {
            std.debug.assert(index < max_size);
            return self.words[wordIndex(index)].get(bitIndex(index));
        }

        pub fn any(self: *const Self) bool {
            for (&self.words) |*word| {
                if (word.any()) return true;
            }
            return false;
        }

        pub fn all(self: *const Self) bool {
            for (self.words[0 .. word_count - 1]) |word| {
                if (!word.all()) return false;
            }
            const remainder = max_size % 64;
            return if (remainder == 0)
                self.words[word_count - 1].all()
            else
                self.words[word_count - 1].count() == remainder;
        }

        pub fn first(self: *const Self) usize {
            std.debug.assert(self.any());
            for (&self.words, 0..) |*word, word_index| {
                if (word.any()) return word_index * 64 + word.first();
            }
            unreachable;
        }

        pub fn first0(self: *const Self) usize {
            std.debug.assert(!self.all());
            for (&self.words, 0..) |*word, word_index| {
                if (!word.all()) {
                    const index = word_index * 64 + word.first0();
                    std.debug.assert(index < max_size);
                    return index;
                }
            }
            unreachable;
        }

        pub fn foreach(self: *const Self, function: anytype) void {
            for (&self.words, 0..) |*word, word_index| {
                visitWord(word.get64(), word_index * 64, function);
            }
        }

        pub fn count(self: *const Self) usize {
            var total: usize = 0;
            for (&self.words) |*word| total += word.count();
            std.debug.assert(total <= max_size);
            return total;
        }
    };
}

pub fn AtomicBitSet(comptime size: usize) type {
    requireCapacity(size);
    const Word = usize;
    const word_bits: usize = @bitSizeOf(Word);
    const word_count = std.math.divCeil(usize, size, word_bits) catch unreachable;
    const AtomicWord = std.atomic.Value(Word);

    return struct {
        words: [word_count]AtomicWord = @as([word_count]AtomicWord, @splat(AtomicWord.init(0))),

        const Self = @This();
        pub const capacity: usize = size;
        pub const max_size: usize = capacity;

        pub fn maxSize(_: *const Self) usize {
            return max_size;
        }

        pub fn set(self: *Self, index: usize) void {
            std.debug.assert(index < max_size);
            _ = self.words[atomicWordIndex(index)].fetchOr(
                atomicBit(atomicBitIndex(index)),
                .release,
            );
        }

        pub fn clear(self: *Self, index: usize) void {
            std.debug.assert(index < max_size);
            _ = self.words[atomicWordIndex(index)].fetchAnd(
                ~atomicBit(atomicBitIndex(index)),
                .release,
            );
            if (runtime_assertions) std.debug.assert(!self.get(index));
        }

        pub fn get(self: *const Self, index: usize) bool {
            std.debug.assert(index < max_size);
            return self.words[atomicWordIndex(index)].load(.acquire) &
                atomicBit(atomicBitIndex(index)) != 0;
        }

        pub fn any(self: *const Self) bool {
            for (&self.words) |*word| {
                if (word.load(.acquire) != 0) return true;
            }
            return false;
        }

        pub fn all(self: *const Self) bool {
            for (self.words[0 .. word_count - 1]) |*word| {
                if (word.load(.acquire) != std.math.maxInt(Word)) return false;
            }
            const last = self.words[word_count - 1].load(.acquire);
            const remainder = max_size % word_bits;
            return if (remainder == 0)
                last == std.math.maxInt(Word)
            else
                @popCount(last) == remainder;
        }

        pub fn first(self: *const Self) usize {
            if (runtime_assertions) std.debug.assert(self.any());
            for (&self.words, 0..) |*word, word_index| {
                const bits = word.load(.acquire);
                if (bits != 0) {
                    return word_index * word_bits + atomicFirstBit(bits);
                }
            }
            unreachable;
        }

        pub fn first0(self: *const Self) usize {
            if (runtime_assertions) std.debug.assert(!self.all());
            for (&self.words, 0..) |*word, word_index| {
                const inverted = ~word.load(.acquire);
                if (inverted != 0) {
                    const index = word_index * word_bits +
                        atomicFirstBit(inverted);
                    std.debug.assert(index < max_size);
                    return index;
                }
            }
            unreachable;
        }

        pub fn foreach(self: *const Self, function: anytype) void {
            for (&self.words, 0..) |*word, word_index| {
                visitAtomicWord(
                    word.load(.acquire),
                    word_index * word_bits,
                    function,
                );
            }
        }

        pub fn count(self: *const Self) usize {
            var total: usize = 0;
            for (&self.words) |*word| total += @popCount(word.load(.acquire));
            std.debug.assert(total <= max_size);
            return total;
        }

        fn atomicWordIndex(index: usize) usize {
            return index / word_bits;
        }

        fn atomicBitIndex(index: usize) usize {
            return index % word_bits;
        }

        fn atomicBit(index: usize) Word {
            std.debug.assert(index < word_bits);
            return @as(Word, 1) << @intCast(index);
        }

        fn atomicFirstBit(bits: Word) usize {
            std.debug.assert(bits != 0);
            return @ctz(bits);
        }

        fn visitAtomicWord(bits: Word, base: usize, function: anytype) void {
            var remaining = bits;
            while (remaining != 0) {
                const index = atomicFirstBit(remaining);
                remaining &= remaining - 1;
                function.call(base + index);
            }
        }
    };
}

pub fn BitSet4096(comptime size: usize) type {
    requireCapacity(size);
    if (size > 4096) @compileError("BitSet4096 supports at most 4096 bits");
    const word_count = wordsFor(size);

    return struct {
        nonzero: BitSet64 = .{},
        words: [word_count]BitSet64 = @as([word_count]BitSet64, @splat(.{})),

        const Self = @This();
        pub const capacity: usize = size;
        pub const max_size: usize = capacity;

        pub fn maxSize(_: *const Self) usize {
            return max_size;
        }

        pub fn set(self: *Self, index: usize) void {
            std.debug.assert(index < max_size);
            const word_index = wordIndex(index);
            self.words[word_index].set(bitIndex(index));
            self.nonzero.set(word_index);
            std.debug.assert(self.get(index));
        }

        pub fn setNonzeroBitsFrom64(self: *Self, bits: u64) void {
            const valid = bits & validBits(@min(max_size, 64));
            std.debug.assert(valid == bits);
            self.words[0].setNonzeroBitsFrom64(valid);
            if (valid != 0) self.nonzero.set(0);
        }

        pub fn clear(self: *Self, index: usize) void {
            std.debug.assert(index < max_size);
            const word_index = wordIndex(index);
            self.words[word_index].clear(bitIndex(index));
            if (!self.words[word_index].any()) self.nonzero.clear(word_index);
            std.debug.assert(!self.get(index));
        }

        pub fn get(self: *const Self, index: usize) bool {
            std.debug.assert(index < max_size);
            return self.words[wordIndex(index)].get(bitIndex(index));
        }

        pub fn any(self: *const Self) bool {
            return self.nonzero.any();
        }

        pub fn all(self: *const Self) bool {
            if (self.nonzero.count() != word_count) return false;
            return self.count() == max_size;
        }

        pub fn first(self: *const Self) usize {
            std.debug.assert(self.any());
            const word_index = self.nonzero.first();
            return word_index * 64 + self.words[word_index].first();
        }

        pub fn first0(self: *const Self) usize {
            std.debug.assert(!self.all());
            for (&self.words, 0..) |*word, word_index| {
                if (!word.all()) {
                    const index = word_index * 64 + word.first0();
                    std.debug.assert(index < max_size);
                    return index;
                }
            }
            unreachable;
        }

        pub fn get64(self: *const Self) u64 {
            return self.words[0].get64();
        }

        pub fn foreach(self: *const Self, function: anytype) void {
            var remaining_words = self.nonzero.get64();
            while (remaining_words != 0) {
                const word_index = firstBit(remaining_words);
                remaining_words &= remaining_words - 1;
                visitWord(self.words[word_index].get64(), word_index * 64, function);
            }
        }

        pub fn count(self: *const Self) usize {
            var total: usize = 0;
            var remaining_words = self.nonzero.get64();
            while (remaining_words != 0) {
                const word_index = firstBit(remaining_words);
                remaining_words &= remaining_words - 1;
                total += self.words[word_index].count();
            }
            std.debug.assert(total <= max_size);
            return total;
        }
    };
}

pub const DefaultBitSet4096 = BitSet4096(4096);

fn visitWord(bits: u64, base: usize, function: anytype) void {
    var remaining = bits;
    while (remaining != 0) {
        const index = firstBit(remaining);
        remaining &= remaining - 1;
        function.call(base + index);
    }
}

fn firstBit(bits: u64) usize {
    std.debug.assert(bits != 0);
    return @ctz(bits);
}

fn bit(index: usize) u64 {
    std.debug.assert(index < 64);
    return @as(u64, 1) << @intCast(index);
}

fn wordIndex(index: usize) usize {
    return index / 64;
}

fn bitIndex(index: usize) usize {
    return index % 64;
}

fn wordsFor(max_size: usize) usize {
    return (max_size + 63) / 64;
}

fn validBits(count: usize) u64 {
    std.debug.assert(count <= 64);
    return if (count == 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @intCast(count)) - 1;
}

fn requireCapacity(comptime max_size: usize) void {
    if (max_size == 0) @compileError("bit sets require a nonzero capacity");
}

const Collector = struct {
    values: []usize,
    count: usize = 0,

    pub fn call(self: *@This(), index: usize) void {
        std.debug.assert(self.count < self.values.len);
        self.values[self.count] = index;
        self.count += 1;
    }
};

fn smoke(comptime Set: type) !void {
    var set = Set{};
    try std.testing.expectEqual(Set.max_size, set.maxSize());
    try std.testing.expect(!set.any());
    try std.testing.expect(!set.all());
    try std.testing.expect(!set.get(0));
    try std.testing.expect(!set.get(Set.max_size - 1));
    try std.testing.expectEqual(@as(usize, 0), set.first0());
    var values: [Set.max_size]usize = undefined;
    var collector = Collector{ .values = &values };
    set.foreach(&collector);
    try std.testing.expectEqual(@as(usize, 0), collector.count);
    try std.testing.expectEqual(@as(usize, 0), set.count());

    const last = Set.max_size - 1;
    set.set(last);
    try std.testing.expect(set.get(last));
    try std.testing.expect(set.any());
    try std.testing.expect(!set.all());
    try std.testing.expectEqual(last, set.first());
    try std.testing.expectEqual(@as(usize, 0), set.first0());
    collector.count = 0;
    set.foreach(&collector);
    try std.testing.expectEqual(@as(usize, 1), collector.count);
    try std.testing.expectEqual(last, collector.values[0]);
    try std.testing.expectEqual(@as(usize, 1), set.count());

    set.clear(last);
    set.clear(0);
    try std.testing.expect(!set.any());
    try std.testing.expect(!set.all());
    try std.testing.expectEqual(@as(usize, 0), set.first0());
    try std.testing.expectEqual(@as(usize, 0), set.count());
}

fn verifyFull(comptime Set: type) !void {
    var set = Set{};
    for (0..Set.max_size) |index| set.set(index);
    try std.testing.expect(set.any());
    try std.testing.expect(set.all());
    try std.testing.expectEqual(@as(usize, 0), set.first());
    try std.testing.expectEqual(Set.max_size, set.count());
    const missing = Set.max_size / 2;
    set.clear(missing);
    try std.testing.expect(!set.all());
    try std.testing.expectEqual(missing, set.first0());
    set.set(missing);
    try std.testing.expect(set.all());
}

fn verifyModel(comptime Set: type, set: *const Set, model: *const [Set.max_size]bool) !void {
    var expected_count: usize = 0;
    var expected_first: usize = Set.max_size;
    var expected_first0: usize = Set.max_size;
    for (model, 0..) |present, index| {
        try std.testing.expectEqual(present, set.get(index));
        expected_count += @intFromBool(present);
        if (present and expected_first == Set.max_size) expected_first = index;
        if (!present and expected_first0 == Set.max_size) expected_first0 = index;
    }
    try std.testing.expectEqual(expected_count, set.count());
    try std.testing.expectEqual(expected_count != 0, set.any());
    try std.testing.expectEqual(expected_count == Set.max_size, set.all());
    if (expected_first != Set.max_size) try std.testing.expectEqual(expected_first, set.first());
    if (expected_first0 != Set.max_size) try std.testing.expectEqual(expected_first0, set.first0());

    var values: [Set.max_size]usize = undefined;
    var collector = Collector{ .values = &values };
    set.foreach(&collector);
    try std.testing.expectEqual(expected_count, collector.count);
    var seen: usize = 0;
    for (model, 0..) |present, index| {
        if (present) {
            try std.testing.expectEqual(index, collector.values[seen]);
            seen += 1;
        }
    }
}

fn randomWalk(comptime Set: type, grow_percent: u8, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed ^ Set.max_size);
    const random = prng.random();
    for (0..16) |_| {
        var set = Set{};
        var model: [Set.max_size]bool = @splat(false);
        for (0..128) |_| {
            const index = random.uintLessThan(usize, Set.max_size);
            if (random.uintLessThan(u8, 100) < grow_percent) {
                set.set(index);
                model[index] = true;
            } else {
                set.clear(index);
                model[index] = false;
            }
            try std.testing.expectEqual(model[index], set.get(index));
        }
        try verifyModel(Set, &set, &model);
    }
}

const Mutate64 = struct {
    set: *BitSet64,
    visited: *BitSet64,

    pub fn call(self: *@This(), index: usize) void {
        self.visited.set(index);
        if (index == 1) {
            self.set.clear(2);
            self.set.set(3);
        }
    }
};

fn MutateFuture(comptime Set: type) type {
    return struct {
        set: *Set,
        visited: *Set,

        pub fn call(self: *@This(), index: usize) void {
            self.visited.set(index);
            if (index == 1) {
                self.set.clear(70);
                self.set.set(71);
            }
        }
    };
}

fn verifyFutureMutation(comptime Set: type) !void {
    var set = Set{};
    set.set(1);
    set.set(70);
    var visited = Set{};
    var mutation = MutateFuture(Set){ .set = &set, .visited = &visited };
    set.foreach(&mutation);
    try std.testing.expect(visited.get(1));
    try std.testing.expect(!visited.get(70));
    try std.testing.expect(visited.get(71));
}

test "Highway bit sets default empty and preserve full-capacity boundaries" {
    inline for (.{
        BitSet64,
        BitSet(320),
        AtomicBitSet(400),
        DefaultBitSet4096,
    }) |Set| try smoke(Set);
    inline for (.{
        BitSet64,
        BitSet(41),
        BitSet(192),
        AtomicBitSet(32),
        AtomicBitSet(192),
        BitSet4096(3000),
        DefaultBitSet4096,
    }) |Set| try verifyFull(Set);
}

test "Highway bit sets import nonzero low words without clearing" {
    inline for (.{ BitSet64, DefaultBitSet4096 }) |Set| {
        var set = Set{};
        set.setNonzeroBitsFrom64(1);
        set.setNonzeroBitsFrom64(0x70);
        try std.testing.expectEqual(@as(u64, 0x71), set.get64());
        try std.testing.expectEqual(@as(usize, 4), set.count());
        try std.testing.expectEqual(@as(usize, 0), set.first());
        try std.testing.expectEqual(@as(usize, 1), set.first0());
    }
}

test "Highway bit set random walks match fixed scalar models" {
    inline for (.{
        BitSet64,
        BitSet(41),
        BitSet(199),
        AtomicBitSet(32),
        AtomicBitSet(192),
        BitSet4096(3000),
        DefaultBitSet4096,
    }, 0..) |Set, index| {
        try randomWalk(Set, 40, 0x4253_4554 + index);
        try randomWalk(Set, 60, 0x5345_5442 + index);
    }
}

test "Highway bit set foreach snapshots current words and observes future words" {
    var set64 = BitSet64{};
    set64.set(1);
    set64.set(2);
    var visited64 = BitSet64{};
    var mutation64 = Mutate64{ .set = &set64, .visited = &visited64 };
    set64.foreach(&mutation64);
    try std.testing.expect(visited64.get(1));
    try std.testing.expect(visited64.get(2));
    try std.testing.expect(!visited64.get(3));
    try verifyFutureMutation(BitSet(128));
    try verifyFutureMutation(AtomicBitSet(128));
    try verifyFutureMutation(BitSet4096(128));
}
