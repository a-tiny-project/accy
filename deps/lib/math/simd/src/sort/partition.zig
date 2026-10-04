const std = @import("std");
const key = @import("key.zig");

pub const Bounds = struct {
    before: usize,
    after: usize,
};

pub fn around(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []Key,
    pivot: Key,
) Bounds {
    if (comptime !key.supported(Key)) @compileError("VQSort key type is not supported");
    var before: usize = 0;
    var scan: usize = 0;
    var after = values.len;
    var iterations: usize = 0;
    while (scan < after) : (iterations += 1) {
        std.debug.assert(iterations < values.len);
        if (key.before(Key, direction, values[scan], pivot)) {
            std.mem.swap(Key, &values[before], &values[scan]);
            before += 1;
            scan += 1;
        } else if (key.before(Key, direction, pivot, values[scan])) {
            after -= 1;
            std.mem.swap(Key, &values[scan], &values[after]);
        } else {
            scan += 1;
        }
    }
    std.debug.assert(before <= after);
    std.debug.assert(after <= values.len);
    return .{ .before = before, .after = after };
}

pub fn nanToBack(comptime Key: type, values: []Key) usize {
    if (comptime !key.supported(Key)) @compileError("VQSort key type is not supported");
    if (comptime floating(Key)) {
        var write: usize = 0;
        for (values) |value| {
            if (!std.math.isNan(value)) {
                values[write] = value;
                write += 1;
            }
        }
        @memset(values[write..], canonicalNaN(Key));
        return values.len - write;
    }
    return 0;
}

pub fn canonicalNaN(comptime Float: type) Float {
    if (comptime !floating(Float)) @compileError("canonical NaN requires a floating type");
    const UInt = @Int(.unsigned, @bitSizeOf(Float));
    const bits: UInt = std.math.maxInt(UInt) >> 1;
    return @bitCast(bits);
}

fn floating(comptime Key: type) bool {
    return switch (@typeInfo(Key)) {
        .float => true,
        else => false,
    };
}

fn Order(comptime Key: type, comptime direction: key.Direction) type {
    return struct {
        fn lessThan(_: void, a: Key, b: Key) bool {
            return key.networkBefore(Key, direction, a, b);
        }
    };
}
