const std = @import("std");
const arithmetic = @import("arithmetic.zig");
const compact = @import("compact.zig");
const compare = @import("compare.zig");
const construct = @import("construct.zig");
const memory = @import("memory.zig");
const reduce = @import("reduce.zig");

pub fn fill(comptime D: type, output: []D.Lane, value: D.Lane) void {
    const vector: D.Vector = @splat(value);
    var index: usize = 0;
    while (index + D.lane_count <= output.len) : (index += D.lane_count) {
        memory.store(D, vector, output[index..]);
    }
    if (index != output.len) memory.storeN(D, vector, output[index..], output.len - index);
}

pub fn copy(comptime D: type, input: []const D.Lane, output: []D.Lane) void {
    std.debug.assert(output.len >= input.len);
    var index: usize = 0;
    while (index + D.lane_count <= input.len) : (index += D.lane_count) {
        memory.store(D, memory.load(D, input[index..]), output[index..]);
    }
    if (index != input.len) {
        const remaining = input.len - index;
        const value = memory.loadN(D, input[index..], remaining);
        memory.storeN(D, value, output[index..input.len], remaining);
    }
}

pub fn copyIf(
    comptime D: type,
    input: []const D.Lane,
    output: []D.Lane,
    predicate: anytype,
) usize {
    if (@sizeOf(D.Lane) == 1) @compileError("copyIf requires 16/32/64-bit lanes");
    std.debug.assert(output.len >= input.len);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index + D.lane_count <= input.len) : (input_index += D.lane_count) {
        const value = memory.load(D, input[input_index..]);
        output_index += compact.compressBlendedStore(
            D,
            value,
            predicate.call(D, value),
            output[output_index..],
        );
    }
    if (input_index != input.len) {
        const remaining = input.len - input_index;
        const value = memory.loadN(D, input[input_index..], remaining);
        const mask = predicate.call(D, value) & construct.firstN(D, remaining);
        output_index += compact.compressBlendedStore(D, value, mask, output[output_index..]);
    }
    std.debug.assert(output_index <= input.len);
    return output_index;
}

pub fn count(comptime D: type, input: []const D.Lane, value: D.Lane) usize {
    const broadcast: D.Vector = @splat(value);
    var total: usize = 0;
    var index: usize = 0;
    while (index + D.lane_count <= input.len) : (index += D.lane_count) {
        total += compare.countTrue(D, memory.load(D, input[index..]) == broadcast);
    }
    if (index != input.len) {
        const remaining = input.len - index;
        const matches = memory.loadN(D, input[index..], remaining) == broadcast;
        total += compare.countTrue(D, matches & construct.firstN(D, remaining));
    }
    std.debug.assert(total <= input.len);
    return total;
}

pub fn countIf(comptime D: type, input: []const D.Lane, predicate: anytype) usize {
    var total: usize = 0;
    var index: usize = 0;
    while (index + D.lane_count <= input.len) : (index += D.lane_count) {
        total += compare.countTrue(D, predicate.call(D, memory.load(D, input[index..])));
    }
    if (index != input.len) {
        const remaining = input.len - index;
        const matches = predicate.call(D, memory.loadN(D, input[index..], remaining));
        total += compare.countTrue(D, matches & construct.firstN(D, remaining));
    }
    std.debug.assert(total <= input.len);
    return total;
}

pub fn find(comptime D: type, input: []const D.Lane, value: D.Lane) usize {
    const broadcast: D.Vector = @splat(value);
    var index: usize = 0;
    while (index + D.lane_count <= input.len) : (index += D.lane_count) {
        const position = compare.findFirstTrue(D, memory.load(D, input[index..]) == broadcast);
        if (position >= 0) return index + @as(usize, @intCast(position));
    }
    if (index != input.len) {
        const remaining = input.len - index;
        const loaded = memory.loadN(D, input[index..], remaining);
        const matches = (loaded == broadcast) & construct.firstN(D, remaining);
        const position = compare.findFirstTrue(D, matches);
        if (position >= 0) return index + @as(usize, @intCast(position));
    }
    return input.len;
}

pub fn findIf(comptime D: type, input: []const D.Lane, predicate: anytype) usize {
    var index: usize = 0;
    while (index + D.lane_count <= input.len) : (index += D.lane_count) {
        const value = memory.load(D, input[index..]);
        const position = compare.findFirstTrue(D, predicate.call(D, value));
        if (position >= 0) return index + @as(usize, @intCast(position));
    }
    if (index != input.len) {
        const remaining = input.len - index;
        const value = memory.loadN(D, input[index..], remaining);
        const matches = predicate.call(D, value) & construct.firstN(D, remaining);
        const position = compare.findFirstTrue(D, matches);
        if (position >= 0) return index + @as(usize, @intCast(position));
    }
    return input.len;
}

pub fn equal(comptime D: type, left: []const D.Lane, right: []const D.Lane) bool {
    requireInteger(D.Lane, "equal");
    if (left.len != right.len) return false;
    if (left.len <= D.lane_count) return std.mem.eql(D.Lane, left, right);
    if (left.ptr == right.ptr) return true;
    const last = left.len - D.lane_count;
    var index: usize = 0;
    while (index < last) : (index += D.lane_count) {
        const first: D.Vector = left[index..][0..D.lane_count].*;
        const second: D.Vector = right[index..][0..D.lane_count].*;
        if (@reduce(.Or, first != second)) return false;
    }
    std.debug.assert(index >= last);
    std.debug.assert(index - last < D.lane_count);
    const first: D.Vector = left[last..][0..D.lane_count].*;
    const second: D.Vector = right[last..][0..D.lane_count].*;
    return !@reduce(.Or, first != second);
}

/// Returns whether every lane of `input` equals `value`, as
/// `std.mem.allEqual` does. Whole vectors compare with the broadcast value,
/// and the last vector overlaps lanes already compared. A span shorter than
/// a vector compares lane by lane.
pub fn allEqual(comptime D: type, input: []const D.Lane, value: D.Lane) bool {
    if (input.len < D.lane_count) {
        for (input) |lane| {
            if (lane != value) return false;
        }
        return true;
    }
    const broadcast: D.Vector = @splat(value);
    const last = input.len - D.lane_count;
    var index: usize = 0;
    while (index < last) : (index += D.lane_count) {
        const lanes: D.Vector = input[index..][0..D.lane_count].*;
        if (@reduce(.Or, lanes != broadcast)) return false;
    }
    std.debug.assert(index >= last);
    std.debug.assert(index - last < D.lane_count);
    const lanes: D.Vector = input[last..][0..D.lane_count].*;
    return !@reduce(.Or, lanes != broadcast);
}

/// Returns the index of the first lane where two equal-length spans differ,
/// or their length when every lane agrees. Whole vectors compare first, and
/// the last vector overlaps lanes already known equal. A byte span shorter
/// than a vector compares eight bytes at a time the same way.
pub fn mismatch(comptime D: type, left: []const D.Lane, right: []const D.Lane) usize {
    requireInteger(D.Lane, "mismatch");
    std.debug.assert(left.len == right.len);
    if (left.len >= D.lane_count) return vectorMismatch(D, left, right);
    if (D.Lane == u8 and left.len >= word_bytes) return wordMismatch(left, right);
    for (left, right, 0..) |first, second, index| {
        if (first != second) return index;
    }
    return left.len;
}

/// Orders two spans of integer lanes lexicographically, as `std.mem.order`
/// orders slices. The first differing lane decides, and a span that is a
/// prefix of the other orders first. Byte spans that share less than a
/// vector compare as big-endian words, which order as their bytes do. Longer
/// spans compare vectors out of line, so ordering a short key reserves no
/// registers for the vector loop.
pub fn order(comptime D: type, left: []const D.Lane, right: []const D.Lane) std.math.Order {
    requireInteger(D.Lane, "order");
    const shared = @min(left.len, right.len);
    if (shared >= D.lane_count) return vectorOrder(D, left, right);
    if (D.Lane == u8 and shared >= word_bytes) return wordOrder(left, right);
    for (left[0..shared], right[0..shared]) |first, second| {
        if (first != second) return std.math.order(first, second);
    }
    return std.math.order(left.len, right.len);
}

const word_bytes = 8;

/// Orders spans that share at least one vector by their first differing
/// lane, or by length when one is a prefix of the other.
noinline fn vectorOrder(
    comptime D: type,
    left: []const D.Lane,
    right: []const D.Lane,
) std.math.Order {
    const shared = @min(left.len, right.len);
    const index = vectorMismatch(D, left[0..shared], right[0..shared]);
    if (index != shared) return std.math.order(left[index], right[index]);
    return std.math.order(left.len, right.len);
}

/// Returns the first differing lane of equal-length spans of at least one
/// vector, or their length when they agree.
fn vectorMismatch(comptime D: type, left: []const D.Lane, right: []const D.Lane) usize {
    std.debug.assert(left.len == right.len);
    std.debug.assert(left.len >= D.lane_count);
    if (left.ptr == right.ptr) return left.len;
    const last = left.len - D.lane_count;
    var index: usize = 0;
    while (index < last) : (index += D.lane_count) {
        if (vectorDifference(D, left, right, index)) |position| return position;
    }
    return vectorDifference(D, left, right, last) orelse left.len;
}

/// Returns the first differing lane of the vectors at `start`, or null when
/// they agree. An or-reduction tests each vector, and only a vector that
/// differs pays to locate its first differing lane.
inline fn vectorDifference(
    comptime D: type,
    left: []const D.Lane,
    right: []const D.Lane,
    start: usize,
) ?usize {
    const first: D.Vector = left[start..][0..D.lane_count].*;
    const second: D.Vector = right[start..][0..D.lane_count].*;
    const differs = first != second;
    if (!@reduce(.Or, differs)) return null;
    return start + compare.findKnownFirstTrue(D, differs);
}

/// Returns the first differing byte of equal-length spans of at least one
/// word, or their length when they agree. A little-endian load puts the
/// first byte in the low bits, so the lowest set bit of a difference names
/// it.
fn wordMismatch(left: []const u8, right: []const u8) usize {
    std.debug.assert(left.len == right.len);
    std.debug.assert(left.len >= word_bytes);
    const last = left.len - word_bytes;
    var index: usize = 0;
    while (index < last) : (index += word_bytes) {
        const differs = littleWord(left, index) ^ littleWord(right, index);
        if (differs != 0) return index + @ctz(differs) / 8;
    }
    const differs = littleWord(left, last) ^ littleWord(right, last);
    if (differs != 0) return last + @ctz(differs) / 8;
    return left.len;
}

/// Orders byte spans that share at least one word. A big-endian load puts
/// the first byte in the high bits, so the first differing word orders the
/// spans as their first differing byte does.
fn wordOrder(left: []const u8, right: []const u8) std.math.Order {
    const shared = @min(left.len, right.len);
    std.debug.assert(shared >= word_bytes);
    const last = shared - word_bytes;
    var index: usize = 0;
    while (index < last) : (index += word_bytes) {
        const first = bigWord(left, index);
        const second = bigWord(right, index);
        if (first != second) return std.math.order(first, second);
    }
    const first = bigWord(left, last);
    const second = bigWord(right, last);
    if (first != second) return std.math.order(first, second);
    return std.math.order(left.len, right.len);
}

fn littleWord(bytes: []const u8, start: usize) u64 {
    return std.mem.readInt(u64, bytes[start..][0..word_bytes], .little);
}

fn bigWord(bytes: []const u8, start: usize) u64 {
    return std.mem.readInt(u64, bytes[start..][0..word_bytes], .big);
}

pub fn unique(comptime D: type, input: []D.Lane) usize {
    requireInteger(D.Lane, "unique");
    if (input.len <= 1) return input.len;
    var written: usize = 1;
    var index: usize = 1;
    while (index < input.len) : (index += 1) {
        if (input[index] != input[written - 1]) {
            input[written] = input[index];
            written += 1;
        }
    }
    std.debug.assert(written <= input.len);
    return written;
}

pub fn allUnique(comptime D: type, input: []const D.Lane) bool {
    requireInteger(D.Lane, "allUnique");
    if (input.len <= 1) return true;
    for (input[1..], input[0 .. input.len - 1]) |current, previous| {
        if (current == previous) return false;
    }
    return true;
}

pub fn minValue(comptime D: type, input: []const D.Lane) D.Lane {
    const identity = positiveIdentity(D.Lane);
    var accumulator: D.Vector = @splat(identity);
    var index: usize = 0;
    while (index + D.lane_count <= input.len) : (index += D.lane_count) {
        accumulator = arithmetic.min(D, accumulator, memory.load(D, input[index..]));
    }
    if (index != input.len) {
        const remaining = input.len - index;
        const value = memory.loadNOr(D, @splat(identity), input[index..], remaining);
        accumulator = arithmetic.min(D, accumulator, value);
    }
    return reduce.min(D, accumulator);
}

pub fn maxValue(comptime D: type, input: []const D.Lane) D.Lane {
    const identity = negativeIdentity(D.Lane);
    var accumulator: D.Vector = @splat(identity);
    var index: usize = 0;
    while (index + D.lane_count <= input.len) : (index += D.lane_count) {
        accumulator = arithmetic.max(D, accumulator, memory.load(D, input[index..]));
    }
    if (index != input.len) {
        const remaining = input.len - index;
        const value = memory.loadNOr(D, @splat(identity), input[index..], remaining);
        accumulator = arithmetic.max(D, accumulator, value);
    }
    return reduce.max(D, accumulator);
}

pub fn isSorted(comptime D: type, input: []const D.Lane) bool {
    return isSortedBy(D, input, Less{});
}

pub fn isSortedBy(comptime D: type, input: []const D.Lane, comparator: anytype) bool {
    if (input.len < 2) return true;
    const pairs = input.len - 1;
    var index: usize = 0;
    while (index + D.lane_count <= pairs) : (index += D.lane_count) {
        const current = memory.load(D, input[index..]);
        const next = memory.load(D, input[index + 1 ..]);
        if (!compare.allFalse(D, comparator.call(D, next, current))) return false;
    }
    if (index != pairs) {
        const remaining = pairs - index;
        const current = memory.loadN(D, input[index .. input.len - 1], remaining);
        const next = memory.loadN(D, input[index + 1 ..], remaining);
        const valid = construct.firstN(D, remaining);
        if (!compare.allFalse(D, comparator.call(D, next, current) & valid)) return false;
    }
    return true;
}

pub fn generate(comptime D: type, output: []D.Lane, generator: anytype) void {
    const U = @Int(.unsigned, @bitSizeOf(D.Lane));
    const DU = D.rebind(U);
    var indices = construct.iota(DU, 0);
    var index: usize = 0;
    while (index + D.lane_count <= output.len) : (index += D.lane_count) {
        memory.store(D, generator.call(D, indices), output[index..]);
        indices +%= @as(DU.Vector, @splat(@intCast(D.lane_count)));
    }
    if (index != output.len) {
        memory.storeN(D, generator.call(D, indices), output[index..], output.len - index);
    }
}

pub fn foreach(
    comptime D: type,
    input: []const D.Lane,
    no: D.Vector,
    function: anytype,
) void {
    var index: usize = 0;
    while (index + D.lane_count <= input.len) : (index += D.lane_count) {
        function.call(D, memory.load(D, input[index..]));
    }
    if (index != input.len) {
        function.call(D, memory.loadNOr(D, no, input[index..], input.len - index));
    }
}

pub fn transform(comptime D: type, input_output: []D.Lane, function: anytype) void {
    var index: usize = 0;
    while (index + D.lane_count <= input_output.len) : (index += D.lane_count) {
        const value = memory.load(D, input_output[index..]);
        memory.store(D, function.call(D, value), input_output[index..]);
    }
    if (index != input_output.len) {
        const remaining = input_output.len - index;
        const value = memory.loadN(D, input_output[index..], remaining);
        memory.storeN(D, function.call(D, value), input_output[index..], remaining);
    }
}

pub fn transform1(
    comptime D: type,
    input_output: []D.Lane,
    input: []const D.Lane,
    function: anytype,
) void {
    std.debug.assert(input.len >= input_output.len);
    var index: usize = 0;
    while (index + D.lane_count <= input_output.len) : (index += D.lane_count) {
        const value = memory.load(D, input_output[index..]);
        const other = memory.load(D, input[index..]);
        memory.store(D, function.call(D, value, other), input_output[index..]);
    }
    if (index != input_output.len) {
        const remaining = input_output.len - index;
        const value = memory.loadN(D, input_output[index..], remaining);
        const other = memory.loadN(D, input[index..input_output.len], remaining);
        memory.storeN(D, function.call(D, value, other), input_output[index..], remaining);
    }
}

pub fn transform2(
    comptime D: type,
    input_output: []D.Lane,
    input1: []const D.Lane,
    input2: []const D.Lane,
    function: anytype,
) void {
    std.debug.assert(input1.len >= input_output.len);
    std.debug.assert(input2.len >= input_output.len);
    var index: usize = 0;
    while (index + D.lane_count <= input_output.len) : (index += D.lane_count) {
        const value = memory.load(D, input_output[index..]);
        const first = memory.load(D, input1[index..]);
        const second = memory.load(D, input2[index..]);
        memory.store(D, function.call(D, value, first, second), input_output[index..]);
    }
    if (index != input_output.len) {
        const remaining = input_output.len - index;
        const value = memory.loadN(D, input_output[index..], remaining);
        const first = memory.loadN(D, input1[index..input_output.len], remaining);
        const second = memory.loadN(D, input2[index..input_output.len], remaining);
        memory.storeN(D, function.call(D, value, first, second), input_output[index..], remaining);
    }
}

pub fn replace(comptime D: type, input_output: []D.Lane, old: D.Lane, new: D.Lane) void {
    const old_vector: D.Vector = @splat(old);
    const new_vector: D.Vector = @splat(new);
    var index: usize = 0;
    while (index + D.lane_count <= input_output.len) : (index += D.lane_count) {
        const value = memory.load(D, input_output[index..]);
        const result = @select(D.Lane, value == old_vector, new_vector, value);
        memory.store(D, result, input_output[index..]);
    }
    if (index != input_output.len) {
        const remaining = input_output.len - index;
        const value = memory.loadN(D, input_output[index..], remaining);
        const result = @select(D.Lane, value == old_vector, new_vector, value);
        memory.storeN(D, result, input_output[index..], remaining);
    }
}

pub fn replaceIf(
    comptime D: type,
    input_output: []D.Lane,
    new: D.Lane,
    predicate: anytype,
) void {
    const new_vector: D.Vector = @splat(new);
    var index: usize = 0;
    while (index + D.lane_count <= input_output.len) : (index += D.lane_count) {
        const value = memory.load(D, input_output[index..]);
        const result = @select(D.Lane, predicate.call(D, value), new_vector, value);
        memory.store(D, result, input_output[index..]);
    }
    if (index != input_output.len) {
        const remaining = input_output.len - index;
        const value = memory.loadN(D, input_output[index..], remaining);
        const result = @select(D.Lane, predicate.call(D, value), new_vector, value);
        memory.storeN(D, result, input_output[index..], remaining);
    }
}

const Less = struct {
    fn call(_: @This(), comptime D: type, a: D.Vector, b: D.Vector) D.Mask {
        return a < b;
    }
};

fn positiveIdentity(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .float => std.math.inf(T),
        .int => std.math.maxInt(T),
        else => @compileError("minimum requires numeric lanes"),
    };
}

fn negativeIdentity(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .float => -std.math.inf(T),
        .int => std.math.minInt(T),
        else => @compileError("maximum requires numeric lanes"),
    };
}

fn requireInteger(comptime T: type, comptime operation: []const u8) void {
    if (@typeInfo(T) != .int) @compileError(operation ++ " requires integer lanes");
}

fn scalar(comptime T: type, value: u8) T {
    return switch (@typeInfo(T)) {
        .int => @intCast(value),
        .float => @floatFromInt(value),
        else => unreachable,
    };
}

fn verifyAllTypeAlgorithms(comptime T: type) !void {
    const simd = @import("root.zig");
    const D = simd.FixedTag(T, 4);
    const length: usize = D.lane_count * 2 + 1;
    const sentinel = scalar(T, 31);
    var input_storage = @as([(length + 2)]T, @splat(sentinel));
    var output_storage = @as([(length + 2)]T, @splat(sentinel));
    const input = input_storage[1 .. length + 1];
    const output = output_storage[1 .. length + 1];
    for (input, 0..) |*value, index| value.* = scalar(T, @intCast(index % 5));
    copy(D, input, output);
    try std.testing.expectEqualSlices(T, input, output);
    try std.testing.expectEqual(sentinel, output_storage[0]);
    try std.testing.expectEqual(sentinel, output_storage[length + 1]);
    if (@typeInfo(T) == .int) {
        try std.testing.expect(equal(D, input, output));
        output[length - 1] = sentinel;
        try std.testing.expect(!equal(D, input, output));
        try std.testing.expect(!equal(D, input, output[0 .. length - 1]));
        output[length - 1] = input[length - 1];
    }
    try std.testing.expectEqual(@as(usize, 2), count(D, input, scalar(T, 3)));
    try std.testing.expectEqual(@as(usize, 3), find(D, input, scalar(T, 3)));
    try std.testing.expectEqual(scalar(T, 0), minValue(D, input));
    try std.testing.expectEqual(scalar(T, 4), maxValue(D, input));
    const GreaterTwo = struct {
        fn call(_: @This(), comptime Tag: type, value: Tag.Vector) Tag.Mask {
            return value > @as(Tag.Vector, @splat(scalar(Tag.Lane, 2)));
        }
    };
    try std.testing.expectEqual(@as(usize, 3), countIf(D, input, GreaterTwo{}));
    try std.testing.expectEqual(@as(usize, 3), findIf(D, input, GreaterTwo{}));
    if (@sizeOf(T) != 1) {
        const written = copyIf(D, input, output, GreaterTwo{});
        try std.testing.expectEqual(@as(usize, 3), written);
        const expected = [_]T{ scalar(T, 3), scalar(T, 4), scalar(T, 3) };
        try std.testing.expectEqualSlices(T, &expected, output[0..written]);
    }
    var sorted: [length]T = undefined;
    for (&sorted, 0..) |*value, index| value.* = scalar(T, @intCast(index / 2));
    try std.testing.expect(isSorted(D, &sorted));
    sorted[length / 2] = scalar(T, 0);
    try std.testing.expect(!isSorted(D, &sorted));
    fill(D, output, scalar(T, 7));
    try std.testing.expect(allEqual(D, output, scalar(T, 7)));
    replace(D, output, scalar(T, 7), scalar(T, 9));
    for (output) |value| try std.testing.expectEqual(scalar(T, 9), value);
    try std.testing.expect(!allEqual(D, output, scalar(T, 7)));
    try std.testing.expect(!allEqual(D, input, scalar(T, 0)));
}

fn verifyUniformSpan(comptime D: type) !void {
    const capacity = 4 * D.lane_count + 9;
    var storage: [capacity + 2]D.Lane = undefined;
    var prng = std.Random.DefaultPrng.init(0x3c1e40a7);
    const U = @Int(.unsigned, @bitSizeOf(D.Lane));
    const flips = [_]D.Lane{ 1, @bitCast(@as(U, 1) << (@bitSizeOf(D.Lane) - 1)) };
    for ([_]usize{ 0, 1 }) |offset| {
        const value = prng.random().int(D.Lane);
        const input = storage[offset..][0..capacity];
        for (0..capacity + 1) |length| {
            @memset(&storage, value ^ flips[0]);
            @memset(input[0..length], value);
            try std.testing.expect(allEqual(D, input[0..length], value));
            if (length != 0) {
                try std.testing.expect(!allEqual(D, input[0..length], value ^ flips[1]));
            }
            for (0..length) |position| {
                for (flips) |flip| {
                    input[position] ^= flip;
                    try std.testing.expect(!allEqual(D, input[0..length], value));
                    input[position] ^= flip;
                }
            }
        }
    }
}

fn verifySpanOrder(comptime D: type) !void {
    const capacity = 4 * D.lane_count + 9;
    var left_storage: [capacity + 1]D.Lane = undefined;
    var right_storage: [capacity + 1]D.Lane = undefined;
    var prng = std.Random.DefaultPrng.init(0x0bd34a11);
    prng.random().bytes(std.mem.sliceAsBytes(left_storage[0..]));
    const U = @Int(.unsigned, @bitSizeOf(D.Lane));
    const flips = [_]D.Lane{ 1, @bitCast(@as(U, 1) << (@bitSizeOf(D.Lane) - 1)) };
    for ([_]usize{ 0, 1 }) |offset| {
        const left = left_storage[offset..][0..capacity];
        const right = right_storage[offset..][0..capacity];
        for (0..capacity + 1) |length| {
            @memcpy(right[0..length], left[0..length]);
            try expectSpanOrder(D, left[0..length], right[0..length]);
            try expectSpanOrder(D, left[0..length], left[0..length]);
            if (length != 0) try expectSpanOrder(D, left[0..length], right[0 .. length - 1]);
            for (0..length) |position| {
                for (flips) |flip| {
                    right[position] ^= flip;
                    try expectSpanOrder(D, left[0..length], right[0..length]);
                    try expectSpanOrder(D, right[0..length], left[0..length]);
                    right[position] ^= flip;
                    reverseAfter(D.Lane, left[0..length], right[0..length], position, flip);
                    try expectSpanOrder(D, left[0..length], right[0..length]);
                    try expectSpanOrder(D, right[0..length], left[0..length]);
                    @memcpy(right[position..length], left[position..length]);
                }
            }
        }
    }
}

/// Makes `right` differ from `left` at `position` by `flip` and order the
/// other way in every later lane that can. A comparison that lets a later
/// lane outweigh the first differing one then reports the wrong order.
fn reverseAfter(
    comptime Lane: type,
    left: []const Lane,
    right: []Lane,
    position: usize,
    flip: Lane,
) void {
    std.debug.assert(left.len == right.len);
    right[position] = left[position] ^ flip;
    const rises = right[position] > left[position];
    @memset(right[position + 1 ..], if (rises) std.math.minInt(Lane) else std.math.maxInt(Lane));
}

fn expectSpanOrder(comptime D: type, left: []const D.Lane, right: []const D.Lane) !void {
    try std.testing.expectEqual(std.mem.order(D.Lane, left, right), order(D, left, right));
    const shared = @min(left.len, right.len);
    var expected: usize = 0;
    while (expected < shared and left[expected] == right[expected]) expected += 1;
    try std.testing.expectEqual(expected, mismatch(D, left[0..shared], right[0..shared]));
}

fn verifySpanEquality(comptime D: type) !void {
    const capacity = 4 * D.lane_count + 9;
    var left_storage: [capacity + 1]D.Lane = undefined;
    var right_storage: [capacity + 1]D.Lane = undefined;
    var prng = std.Random.DefaultPrng.init(0x507c9c25);
    prng.random().bytes(std.mem.sliceAsBytes(left_storage[0..]));
    const flips = [_]D.Lane{ 1, @as(D.Lane, 1) << (@bitSizeOf(D.Lane) - 1) };
    for ([_]usize{ 0, 1 }) |offset| {
        const left = left_storage[offset..][0..capacity];
        const right = right_storage[offset..][0..capacity];
        for (0..capacity + 1) |length| {
            @memcpy(right[0..length], left[0..length]);
            try std.testing.expect(equal(D, left[0..length], right[0..length]));
            try std.testing.expect(equal(D, left[0..length], left[0..length]));
            if (length != 0) {
                try std.testing.expect(!equal(D, left[0..length], right[0 .. length - 1]));
            }
            for (0..length) |position| {
                for (flips) |flip| {
                    right[position] ^= flip;
                    try std.testing.expect(!equal(D, left[0..length], right[0..length]));
                    right[position] ^= flip;
                }
            }
        }
    }
}

test "Highway span copy count find and extrema preserve awkward tails" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i32, 8);
    const input = [_]i32{ 4, 1, 7, 4, 9, 4, 2, 8, 4, 5, 6, 4, 3, 0, 4, 10, 11, 4, 12 };
    var output = @as([input.len]i32, @splat(99));
    copy(D, &input, &output);
    try std.testing.expectEqualSlices(i32, &input, &output);
    try std.testing.expectEqual(@as(usize, 7), count(D, &input, 4));
    try std.testing.expectEqual(@as(usize, 0), find(D, &input, 4));
    try std.testing.expectEqual(input.len, find(D, &input, 13));
    try std.testing.expectEqual(@as(i32, 0), minValue(D, &input));
    try std.testing.expectEqual(@as(i32, 12), maxValue(D, &input));
    try std.testing.expectEqual(std.math.maxInt(i32), minValue(D, &.{}));
    try std.testing.expectEqual(std.math.minInt(i32), maxValue(D, &.{}));

    fill(D, &output, -3);
    try std.testing.expectEqualSlices(i32, &(@as([input.len]i32, @splat(-3))), &output);
}

test "span equality agrees with element equality at every length and mismatch position" {
    const simd = @import("root.zig");
    try verifySpanEquality(simd.ScalableTag(u8));
    try verifySpanEquality(simd.FixedTag(u8, 16));
    try verifySpanEquality(simd.FixedTag(u32, 8));
    try verifySpanEquality(simd.ScalableTag(u64));
}

test "uniform spans agree with element equality at every length and differing position" {
    const simd = @import("root.zig");
    try verifyUniformSpan(simd.ScalableTag(u8));
    try verifyUniformSpan(simd.FixedTag(u8, 16));
    try verifyUniformSpan(simd.FixedTag(i16, 8));
    try verifyUniformSpan(simd.FixedTag(u32, 8));
    try verifyUniformSpan(simd.ScalableTag(u64));
}

test "span mismatch and order agree with element order at every length and mismatch position" {
    const simd = @import("root.zig");
    try verifySpanOrder(simd.ScalableTag(u8));
    try verifySpanOrder(simd.FixedTag(u8, 16));
    try verifySpanOrder(simd.FixedTag(i16, 8));
    try verifySpanOrder(simd.FixedTag(u32, 8));
    try verifySpanOrder(simd.ScalableTag(u64));
}

test "byte order compares unsigned bytes and breaks prefix ties by length" {
    const simd = @import("root.zig");
    const Bytes = simd.ScalableTag(u8);
    try std.testing.expectEqual(std.math.Order.lt, order(Bytes, "k0000001", "k0000002"));
    try std.testing.expectEqual(std.math.Order.gt, order(Bytes, "\xff", "\x00\xff"));
    try std.testing.expectEqual(std.math.Order.lt, order(Bytes, "k00000001\xff", "k00000002\x00"));
    try std.testing.expectEqual(std.math.Order.lt, order(Bytes, "abcdefgh", "abcdefghi"));
    try std.testing.expectEqual(std.math.Order.eq, order(Bytes, "abcdefghij", "abcdefghij"));
    try std.testing.expectEqual(std.math.Order.eq, order(Bytes, "", ""));
}

test "span equality finds one changed byte anywhere in a large span" {
    const simd = @import("root.zig");
    const D = simd.ScalableTag(u8);
    const capacity = (1 << 20) + 13;
    const left_storage = try std.testing.allocator.alloc(u8, capacity + 1);
    defer std.testing.allocator.free(left_storage);
    const right_storage = try std.testing.allocator.alloc(u8, capacity + 1);
    defer std.testing.allocator.free(right_storage);
    var prng = std.Random.DefaultPrng.init(0x507c9c25);
    prng.random().bytes(left_storage);
    const positions = [_]usize{ 0, capacity / 2 + 7, capacity - D.lane_count - 1, capacity - 1 };
    for ([_]usize{ 0, 1 }) |offset| {
        const left = left_storage[offset..][0..capacity];
        const right = right_storage[offset..][0..capacity];
        @memcpy(right, left);
        try std.testing.expect(equal(D, left, right));
        for (positions) |position| {
            right[position] ^= 0x40;
            try std.testing.expect(!equal(D, left, right));
            right[position] ^= 0x40;
        }
        try std.testing.expect(equal(D, left, right));
    }
}

test "Highway predicate algorithms retain stable order and callback tails" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i32, 8);
    const Positive = struct {
        fn call(_: @This(), comptime Tag: type, value: Tag.Vector) Tag.Mask {
            return value > @as(Tag.Vector, @splat(0));
        }
    };
    const predicate = Positive{};
    const input = [_]i32{ -4, 1, 7, -2, 9, 0, 2, 8, -3, 5, 6 };
    try std.testing.expectEqual(@as(usize, 7), countIf(D, &input, predicate));
    try std.testing.expectEqual(@as(usize, 1), findIf(D, &input, predicate));
    var selected = @as([input.len]i32, @splat(99));
    const written = copyIf(D, &input, &selected, predicate);
    try std.testing.expectEqual(@as(usize, 7), written);
    try std.testing.expectEqualSlices(i32, &.{ 1, 7, 9, 2, 8, 5, 6 }, selected[0..written]);

    var grouped = [_]i32{ 1, 1, 2, 2, 2, 4, 7, 7, 9 };
    try std.testing.expect(!allUnique(D, &grouped));
    const unique_count = unique(D, &grouped);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 4, 7, 9 }, grouped[0..unique_count]);
    try std.testing.expect(allUnique(D, grouped[0..unique_count]));
}

test "Highway sorted and transform algorithms honor vector callbacks" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i32, 8);
    const Descending = struct {
        fn call(_: @This(), comptime Tag: type, a: Tag.Vector, b: Tag.Vector) Tag.Mask {
            return a > b;
        }
    };
    try std.testing.expect(isSorted(D, &.{ -3, -1, -1, 0, 4, 9 }));
    try std.testing.expect(!isSorted(D, &.{ -3, 2, 1, 4 }));
    try std.testing.expect(isSortedBy(D, &.{ 9, 4, 4, 0, -1 }, Descending{}));

    const GenerateSquare = struct {
        fn call(_: @This(), comptime Tag: type, indices: Tag.rebind(u32).Vector) Tag.Vector {
            const signed: Tag.Vector = @bitCast(indices);
            return signed * signed;
        }
    };
    var values: [19]i32 = undefined;
    generate(D, &values, GenerateSquare{});
    for (&values, 0..) |value, index| {
        try std.testing.expectEqual(@as(i32, @intCast(index * index)), value);
    }

    const Scale = struct {
        factor: i32,
        fn call(self: @This(), comptime Tag: type, value: Tag.Vector) Tag.Vector {
            return value * @as(Tag.Vector, @splat(self.factor));
        }
    };
    transform(D, &values, Scale{ .factor = 2 });
    for (&values, 0..) |value, index| {
        try std.testing.expectEqual(@as(i32, @intCast(index * index * 2)), value);
    }

    const Add = struct {
        fn call(_: @This(), comptime Tag: type, a: Tag.Vector, b: Tag.Vector) Tag.Vector {
            return a + b;
        }
    };
    const ones = @as([values.len]i32, @splat(1));
    transform1(D, &values, &ones, Add{});
    const twos = @as([values.len]i32, @splat(2));
    transform2(D, &values, &ones, &twos, struct {
        fn call(
            _: @This(),
            comptime Tag: type,
            a: Tag.Vector,
            b: Tag.Vector,
            c: Tag.Vector,
        ) Tag.Vector {
            return a + b * c;
        }
    }{});
    replace(D, &values, 3, -3);
    replaceIf(D, &values, 0, struct {
        fn call(_: @This(), comptime Tag: type, value: Tag.Vector) Tag.Mask {
            return value > @as(Tag.Vector, @splat(100));
        }
    }{});
    try std.testing.expectEqual(@as(i32, -3), values[0]);
    try std.testing.expectEqual(@as(i32, 5), values[1]);
    try std.testing.expectEqual(@as(i32, 0), values[8]);
}

test "Highway foreach substitutes caller lanes beyond the input" {
    const simd = @import("root.zig");
    const D = simd.FixedTag(i32, 4);
    const Collector = struct {
        output: *[8]i32,
        index: *usize,
        fn call(self: @This(), comptime Tag: type, value: Tag.Vector) void {
            const lanes: [Tag.lane_count]Tag.Lane = value;
            for (lanes) |lane_value| {
                self.output[self.index.*] = lane_value;
                self.index.* += 1;
            }
        }
    };
    var output: [8]i32 = undefined;
    var index: usize = 0;
    foreach(D, &.{ 1, 2, 3, 4, 5, 6 }, @as(D.Vector, .{ 90, 91, 92, 93 }), Collector{
        .output = &output,
        .index = &index,
    });
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 5, 6, 92, 93 }, &output);
}

test "Highway algorithms instantiate every supported lane type" {
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, f16, f32, f64 }) |T| {
        try verifyAllTypeAlgorithms(T);
    }
}
