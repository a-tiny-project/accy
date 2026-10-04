const random = @import("../root.zig");

const std = random.base.std;
const kernel = random.base.kernel;

pub const squares_lanes: u64 = 1;
pub const squares_default_key: u64 = 0x123456789abcdef0;

pub fn squaresBlock(counter: u64, key: u64) u32 {
    var x = counter *% key;
    const y = x;
    const z = y +% key;
    x = x *% x +% y;
    x = std.math.rotr(u64, x, 32);
    x = x *% x +% z;
    x = std.math.rotr(u64, x, 32);
    x = x *% x +% y;
    x = std.math.rotr(u64, x, 32);
    return @truncate((x *% x +% z) >> 32);
}

pub fn zeroExtendWord(k: anytype, word: kernel.Value) !kernel.Value {
    const wide = try k.cast(word, .i64);
    const mask = try k.constantInt(.i64, 0xFFFFFFFF);
    return k.and_(wide, mask);
}

pub fn rotateWide32(k: anytype, value: kernel.Value) !kernel.Value {
    const half = try k.constantInt(.i64, 32);
    const low = try k.ushr(value, half);
    const high = try k.shl(value, half);
    return k.or_(low, high);
}

pub fn squaresWord(
    k: anytype,
    counter: kernel.Value,
    key: kernel.Value,
) !kernel.Value {
    var x = try k.mul(counter, key);
    const y = x;
    const z = try k.add(y, key);
    x = try k.add(try k.mul(x, x), y);
    x = try rotateWide32(k, x);
    x = try k.add(try k.mul(x, x), z);
    x = try rotateWide32(k, x);
    x = try k.add(try k.mul(x, x), y);
    x = try rotateWide32(k, x);
    const final = try k.add(try k.mul(x, x), z);
    const half = try k.constantInt(.i64, 32);
    const high = try k.ushr(final, half);
    return k.cast(high, .i32);
}

pub fn squaresKeyValue(k: anytype, key_lo: kernel.Value, key_hi: kernel.Value) !kernel.Value {
    const lo = try zeroExtendWord(k, key_lo);
    const hi = try zeroExtendWord(k, key_hi);
    const half = try k.constantInt(.i64, 32);
    return k.or_(try k.shl(hi, half), lo);
}
