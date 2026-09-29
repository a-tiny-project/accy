const std = @import("std");
const windowing = @import("../../root.zig");

pub fn coordinate(value: f64) i32 {
    if (!std.math.isFinite(value)) return 0;
    const rounded = @round(value);
    if (rounded <= std.math.minInt(i32)) return std.math.minInt(i32);
    if (rounded >= std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intFromFloat(rounded);
}

pub fn cursorShapeValue(shape: windowing.CursorShape) u32 {
    return switch (shape) {
        .default => 1,
        .resize_ew => 26,
        .resize_ns => 27,
        .resize_nesw => 28,
        .resize_nwse => 29,
    };
}
