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

test "Highway VQSort heap fallback matches both scalar orders" {
    var ascending = [_]i64{ 9, -4, 7, 7, 0, std.math.minInt(i64), 11, -4, std.math.maxInt(i64) };
    var expected_ascending = ascending;
    std.mem.sort(i64, &expected_ascending, {}, Order(i64, .ascending).lessThan);
    sort(i64, .ascending, &ascending);
    try std.testing.expectEqualSlices(i64, &expected_ascending, &ascending);

    var descending = ascending;
    var expected_descending = descending;
    std.mem.sort(i64, &expected_descending, {}, Order(i64, .descending).lessThan);
    sort(i64, .descending, &descending);
    try std.testing.expectEqualSlices(i64, &expected_descending, &descending);
}

test "Highway VQSort heap fallback orders 128-bit records by key" {
    var values = [_]key.K64V64{
        key.K64V64.init(8, 1),
        key.K64V64.init(2, 7),
        key.K64V64.init(9, 4),
        key.K64V64.init(5, 3),
    };
    sort(key.K64V64, .descending, &values);
    for (values[1..], 1..) |value, index| try std.testing.expect(values[index - 1].key >= value.key);
}
