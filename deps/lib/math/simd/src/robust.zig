const std = @import("std");

pub const Error = error{InsufficientScratch};
pub const max_array_scratch_bytes: usize = 16 * 1024;

pub fn CountingSortEntry(comptime T: type) type {
    comptime requireInteger(T);
    return struct {
        value: T,
        count: usize,
    };
}

pub fn countingSort(
    comptime T: type,
    values: []T,
    scratch: []CountingSortEntry(T),
) Error!void {
    comptime requireInteger(T);
    const Entry = CountingSortEntry(T);
    var unique_count: usize = 0;
    for (values) |value| {
        var unique_index: usize = 0;
        while (unique_index < unique_count and scratch[unique_index].value != value) {
            unique_index += 1;
        }
        if (unique_index == unique_count) {
            if (unique_count == scratch.len) return error.InsufficientScratch;
            scratch[unique_count] = .{ .value = value, .count = 1 };
            unique_count += 1;
        } else {
            scratch[unique_index].count += 1;
        }
    }

    std.mem.sort(Entry, scratch[0..unique_count], {}, EntryAscending(Entry).lessThan);

    var output_index: usize = 0;
    for (scratch[0..unique_count]) |entry| {
        const end = output_index + entry.count;
        @memset(values[output_index..end], entry.value);
        output_index = end;
    }
    std.debug.assert(output_index == values.len);
}

pub fn countingSortArray(values: anytype) void {
    const T = arrayElement(@TypeOf(values));
    const count = comptime arrayLength(@TypeOf(values));
    comptime requireArrayScratch(CountingSortEntry(T), count);
    var scratch: [count]CountingSortEntry(T) = undefined;
    countingSort(T, values[0..], &scratch) catch unreachable;
}

pub fn minRange(
    comptime T: type,
    sorted: []const T,
    index_begin: usize,
    half_count: usize,
) usize {
    comptime requireUnsignedInteger(T);
    std.debug.assert(half_count != 0);
    std.debug.assert(index_begin <= sorted.len);
    std.debug.assert(half_count <= (sorted.len - index_begin) / 2);
    var min_range: T = std.math.maxInt(T);
    var min_index = index_begin;
    for (index_begin..index_begin + half_count) |index| {
        std.debug.assert(sorted[index] <= sorted[index + half_count]);
        const range = sorted[index + half_count] - sorted[index];
        if (range < min_range) {
            min_range = range;
            min_index = index;
        }
    }
    return min_index;
}

pub fn modeOfSorted(comptime T: type, sorted: []const T) T {
    comptime requireUnsignedInteger(T);
    std.debug.assert(sorted.len != 0);
    var index_begin: usize = 0;
    var half_count = sorted.len / 2;
    while (half_count > 1) {
        index_begin = minRange(T, sorted, index_begin, half_count);
        half_count >>= 1;
    }
    const lower = sorted[index_begin];
    if (half_count == 0) return lower;
    std.debug.assert(half_count == 1);
    return roundedUnsignedAverage(lower, sorted[index_begin + 1]);
}

pub fn mode(
    comptime T: type,
    values: []T,
    scratch: []CountingSortEntry(T),
) Error!T {
    comptime requireUnsignedInteger(T);
    std.debug.assert(values.len != 0);
    try countingSort(T, values, scratch);
    return modeOfSorted(T, values);
}

pub fn modeArray(values: anytype) arrayElement(@TypeOf(values)) {
    const T = arrayElement(@TypeOf(values));
    const count = comptime arrayLength(@TypeOf(values));
    comptime if (count == 0) @compileError("mode requires at least one value");
    comptime requireArrayScratch(CountingSortEntry(T), count);
    var scratch: [count]CountingSortEntry(T) = undefined;
    return mode(T, values[0..], &scratch) catch unreachable;
}

pub fn median(comptime T: type, values: []T) T {
    comptime requireOrderType(T);
    std.debug.assert(values.len != 0);
    std.mem.sort(T, values, {}, std.sort.asc(T));
    const half = values.len / 2;
    if (values.len % 2 != 0) return values[half];
    return switch (@typeInfo(T)) {
        .int => roundedIntegerMedian(T, values[half - 1], values[half]),
        .float => (values[half - 1] + values[half]) / 2,
        else => unreachable,
    };
}

pub fn medianArray(values: anytype) arrayElement(@TypeOf(values)) {
    const T = arrayElement(@TypeOf(values));
    const count = comptime arrayLength(@TypeOf(values));
    comptime if (count == 0) @compileError("median requires at least one value");
    return median(T, values[0..]);
}

pub fn medianAbsoluteDeviation(
    comptime T: type,
    values: []const T,
    median_value: T,
    scratch: []T,
) Error!T {
    comptime requireOrderType(T);
    std.debug.assert(values.len != 0);
    if (scratch.len < values.len) return error.InsufficientScratch;
    for (values, scratch[0..values.len]) |value, *deviation| {
        deviation.* = absoluteDeviation(T, value, median_value);
    }
    return median(T, scratch[0..values.len]);
}

pub fn medianAbsoluteDeviationArray(
    values: anytype,
    median_value: arrayElement(@TypeOf(values)),
) arrayElement(@TypeOf(values)) {
    const T = arrayElement(@TypeOf(values));
    const count = comptime arrayLength(@TypeOf(values));
    comptime if (count == 0) @compileError("median absolute deviation requires at least one value");
    comptime requireArrayScratch(T, count);
    var scratch: [count]T = undefined;
    return medianAbsoluteDeviation(T, values[0..], median_value, &scratch) catch unreachable;
}

fn roundedUnsignedAverage(lower: anytype, upper: @TypeOf(lower)) @TypeOf(lower) {
    std.debug.assert(lower <= upper);
    const difference = upper - lower;
    return lower + difference / 2 + difference % 2;
}

fn EntryAscending(comptime Entry: type) type {
    return struct {
        fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
            return lhs.value < rhs.value;
        }
    };
}

fn roundedIntegerMedian(comptime T: type, lower: T, upper: T) T {
    std.debug.assert(lower <= upper);
    const info = @typeInfo(T).int;
    if (info.signedness == .unsigned) return roundedUnsignedAverage(lower, upper);
    if (info.bits > 64) @compileError("signed integer medians support up to 64 bits");
    const sum = @as(i128, lower) + @as(i128, upper) + 1;
    return @intCast(@divTrunc(sum, 2));
}

fn absoluteDeviation(comptime T: type, value: T, median_value: T) T {
    const value_i64 = asI64(T, value);
    const median_i64 = asI64(T, median_value);
    const difference = @as(i128, value_i64) - @as(i128, median_i64);
    const magnitude: u128 = @intCast(if (difference < 0) -difference else difference);
    return switch (@typeInfo(T)) {
        .int => |info| blk: {
            if (info.signedness == .signed) {
                std.debug.assert(magnitude <= std.math.maxInt(T));
            }
            break :blk @intCast(magnitude);
        },
        .float => @floatFromInt(magnitude),
        else => unreachable,
    };
}

fn asI64(comptime T: type, value: T) i64 {
    return switch (@typeInfo(T)) {
        .int => |info| blk: {
            if (info.bits > 64) @compileError("absolute deviations support up to 64-bit integers");
            if (info.signedness == .unsigned) {
                std.debug.assert(value <= std.math.maxInt(i64));
            }
            break :blk @intCast(value);
        },
        .float => blk: {
            std.debug.assert(std.math.isFinite(value));
            break :blk @intFromFloat(value);
        },
        else => unreachable,
    };
}

fn arrayElement(comptime Pointer: type) type {
    return switch (@typeInfo(Pointer)) {
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .array => |array| array.child,
            else => @compileError("expected a pointer to an array"),
        },
        else => @compileError("expected a pointer to an array"),
    };
}

fn arrayLength(comptime Pointer: type) usize {
    return switch (@typeInfo(Pointer)) {
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .array => |array| array.len,
            else => @compileError("expected a pointer to an array"),
        },
        else => @compileError("expected a pointer to an array"),
    };
}

fn requireInteger(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("counting sort requires an integer type"),
    }
}

fn requireUnsignedInteger(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => |info| if (info.signedness != .unsigned) {
            @compileError("half-sample mode requires an unsigned integer type");
        },
        else => @compileError("half-sample mode requires an unsigned integer type"),
    }
}

fn requireOrderType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .float => {},
        else => @compileError("robust order statistics require an integer or float type"),
    }
}

fn requireArrayScratch(comptime T: type, comptime count: usize) void {
    if (@sizeOf(T) == 0) return;
    if (count > max_array_scratch_bytes / @sizeOf(T)) {
        @compileError("fixed-array robust scratch exceeds max_array_scratch_bytes");
    }
}
