const std = @import("std");
const key = @import("key.zig");

pub fn sort(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []Key,
) void {
    if (comptime !key.supported(Key)) @compileError("VQSort key type is not supported");
    if (values.len < 2) return;

    var start = values.len / 2;
    while (start != 0) {
        start -= 1;
        siftDown(Key, direction, values, start);
    }

    var end = values.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(Key, &values[0], &values[end]);
        siftDown(Key, direction, values[0..end], 0);
    }
}

fn siftDown(
    comptime Key: type,
    comptime direction: key.Direction,
    values: []Key,
    start: usize,
) void {
    std.debug.assert(start < values.len);
    var root = start;
    var iterations: usize = 0;
    while (root < values.len / 2) : (iterations += 1) {
        std.debug.assert(iterations < @bitSizeOf(usize));
        const left = root * 2 + 1;
        const right = left + 1;
        var later = left;
        if (right < values.len and key.before(Key, direction, values[left], values[right])) {
            later = right;
        }
        if (!key.before(Key, direction, values[root], values[later])) return;
        std.mem.swap(Key, &values[root], &values[later]);
        root = later;
    }
}

fn Order(comptime Key: type, comptime direction: key.Direction) type {
    return struct {
        fn lessThan(_: void, a: Key, b: Key) bool {
            return key.before(Key, direction, a, b);
        }
    };
}
