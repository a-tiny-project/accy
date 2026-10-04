const std = @import("std");
const bfloat = @import("bfloat.zig");

pub const Window = struct {
    lane: usize = 0,
    max_lanes: usize = 7,
};

const Bounds = struct {
    begin: usize,
    end: usize,
};

const Big = struct {
    limbs: [40]u32 = @splat(0),
    len: usize = 0,

    fn init(value: u128) Big {
        var result = Big{};
        var remaining = value;
        while (remaining != 0) {
            result.limbs[result.len] = @truncate(remaining);
            result.len += 1;
            remaining >>= 32;
        }
        return result;
    }

    fn multiplySmall(self: *Big, factor: u32) void {
        var carry: u64 = 0;
        for (self.limbs[0..self.len]) |*limb| {
            const product = @as(u64, limb.*) * factor + carry;
            limb.* = @truncate(product);
            carry = product >> 32;
        }
        if (carry != 0) {
            std.debug.assert(self.len < self.limbs.len);
            self.limbs[self.len] = @truncate(carry);
            self.len += 1;
        }
    }

    fn multiplyPower5(self: *Big, count: usize) void {
        for (0..count) |_| self.multiplySmall(5);
    }

    fn shiftLeft(self: *Big, amount: usize) void {
        if (self.len == 0 or amount == 0) return;
        const words = amount / 32;
        const bits: u5 = @intCast(amount % 32);
        std.debug.assert(self.len + words + @intFromBool(bits != 0) <= self.limbs.len);
        var index = self.len;
        while (index != 0) {
            index -= 1;
            self.limbs[index + words] = self.limbs[index];
        }
        @memset(self.limbs[0..words], 0);
        self.len += words;
        if (bits == 0) return;
        var carry: u64 = 0;
        for (self.limbs[0..self.len]) |*limb| {
            const shifted = (@as(u64, limb.*) << bits) | carry;
            limb.* = @truncate(shifted);
            carry = shifted >> 32;
        }
        if (carry != 0) {
            self.limbs[self.len] = @truncate(carry);
            self.len += 1;
        }
    }

    fn shiftedU128(self: *const Big, shift: usize) u128 {
        var result: u128 = 0;
        for (0..4) |word| {
            result |= @as(u128, self.wordAt(shift + word * 32)) << @intCast(word * 32);
        }
        return result;
    }

    fn roundedShift(self: *const Big, shift: usize) u128 {
        if (shift == 0) return self.shiftedU128(0);
        var quotient = self.shiftedU128(shift);
        const half = self.bitAt(shift - 1);
        if (half and (self.anyBelow(shift - 1) or quotient & 1 != 0)) quotient += 1;
        return quotient;
    }

    fn wordAt(self: *const Big, bit: usize) u32 {
        const word = bit / 32;
        if (word >= self.len) return 0;
        const offset: u5 = @intCast(bit % 32);
        if (offset == 0) return self.limbs[word];
        var result = self.limbs[word] >> offset;
        if (word + 1 < self.len) {
            const remaining: u5 = @intCast(32 - @as(u6, offset));
            result |= self.limbs[word + 1] << remaining;
        }
        return result;
    }

    fn bitAt(self: *const Big, bit: usize) bool {
        const word = bit / 32;
        if (word >= self.len) return false;
        const offset: u5 = @intCast(bit % 32);
        return self.limbs[word] & (@as(u32, 1) << offset) != 0;
    }

    fn anyBelow(self: *const Big, bit: usize) bool {
        const words = @min(bit / 32, self.len);
        for (self.limbs[0..words]) |limb| if (limb != 0) return true;
        const remaining: u5 = @intCast(bit % 32);
        if (remaining == 0 or words >= self.len) return false;
        const mask = (@as(u32, 1) << remaining) - 1;
        return self.limbs[words] & mask != 0;
    }

    fn divideSmall(self: *Big, divisor: u32) u32 {
        var remainder: u64 = 0;
        var index = self.len;
        while (index != 0) {
            index -= 1;
            const value = (remainder << 32) | self.limbs[index];
            self.limbs[index] = @intCast(value / divisor);
            remainder = value % divisor;
        }
        while (self.len != 0 and self.limbs[self.len - 1] == 0) self.len -= 1;
        return @intCast(remainder);
    }
};

const FloatParts = struct {
    negative: bool,
    mantissa: u64,
    exponent: i32,
    special: enum { finite, infinity, nan },
};

pub fn writeTypeName(
    writer: *std.Io.Writer,
    comptime T: type,
    lane_count: usize,
) std.Io.Writer.Error!void {
    validateType(T);
    try writer.print("{c}{d}", .{ typePrefix(T), typeBits(T) });
    if (lane_count != 1) try writer.print("x{d}", .{lane_count});
}

pub fn writeValue(
    writer: *std.Io.Writer,
    value: anytype,
) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    validateType(T);
    if (T == bfloat.BFloat16) {
        return writeFloat(writer, @floatCast(value.toF32()), 3, 1e-3);
    }
    switch (@typeInfo(T)) {
        .int => |info| switch (info.bits) {
            8 => if (info.signedness == .signed)
                try writer.print("{d}", .{value})
            else
                try writer.print("0x{X:0>2}", .{value}),
            16 => try writer.print("0x{X:0>4}", .{@as(u16, @bitCast(value))}),
            32 => try writer.print("{d}", .{value}),
            64 => try writer.print("0x{x:0>16}", .{@as(u64, @bitCast(value))}),
            128 => {
                const bits: u128 = @bitCast(value);
                try writer.print(
                    "0x{x:0>16}_{x:0>16}",
                    .{ @as(u64, @truncate(bits >> 64)), @as(u64, @truncate(bits)) },
                );
            },
            else => unreachable,
        },
        .float => |info| switch (info.bits) {
            16 => try writeFloat(writer, @floatCast(value), 4, 1e-4),
            32 => try writeFloat(
                writer,
                @floatCast(value),
                9,
                @as(f64, @floatCast(@as(f32, 1e-6))),
            ),
            64 => try writeFloat(writer, value, 18, 1e-9),
            else => unreachable,
        },
        else => unreachable,
    }
}

pub fn writeArray(
    writer: *std.Io.Writer,
    caption: []const u8,
    values: anytype,
    options: Window,
) std.Io.Writer.Error!void {
    const Slice = @TypeOf(values);
    const pointer = switch (@typeInfo(Slice)) {
        .pointer => |info| info,
        else => @compileError("diagnostic arrays require a slice or array pointer"),
    };
    if (pointer.size != .slice and pointer.size != .one) {
        @compileError("diagnostic arrays require a slice or array pointer");
    }
    const T = switch (@typeInfo(pointer.child)) {
        .array => |info| info.child,
        else => pointer.child,
    };
    validateType(T);
    const slice: []const T = values;
    const bounds = try writeHeader(writer, T, caption, slice.len, options);
    for (slice[bounds.begin..bounds.end]) |value| {
        try writeValue(writer, value);
        try writer.writeByte(',');
    }
    try writeFooter(writer, bounds);
}

pub fn writeVector(
    writer: *std.Io.Writer,
    comptime D: type,
    caption: []const u8,
    value: D.Vector,
    options: Window,
) std.Io.Writer.Error!void {
    const is_bfloat = @hasDecl(D, "is_bfloat16") and D.is_bfloat16;
    const T = if (is_bfloat) bfloat.BFloat16 else D.Lane;
    validateType(T);
    const bounds = try writeHeader(writer, T, caption, D.lane_count, options);
    const lanes: [D.lane_count]D.Lane = @bitCast(value);
    for (bounds.begin..bounds.end) |index| {
        if (is_bfloat) {
            try writeValue(writer, bfloat.BFloat16.fromBits(lanes[index]));
        } else {
            try writeValue(writer, lanes[index]);
        }
        try writer.writeByte(',');
    }
    try writeFooter(writer, bounds);
}

fn writeHeader(
    writer: *std.Io.Writer,
    comptime T: type,
    caption: []const u8,
    lane_count: usize,
    options: Window,
) std.Io.Writer.Error!Bounds {
    const begin = options.lane -| 2;
    const end = @min(begin +| options.max_lanes, lane_count);
    try writeTypeName(writer, T, lane_count);
    try writer.print(" {s} [{d}+ ->]:\n  ", .{ caption, begin });
    return .{ .begin = @min(begin, lane_count), .end = end };
}

fn writeFooter(writer: *std.Io.Writer, bounds: Bounds) std.Io.Writer.Error!void {
    if (bounds.begin >= bounds.end) try writer.writeAll("(out of bounds)");
    try writer.writeByte('\n');
}

fn writeFloat(
    writer: *std.Io.Writer,
    value: f64,
    comptime precision: usize,
    threshold: f64,
) std.Io.Writer.Error!void {
    var buffer: [400]u8 = undefined;
    const text = if (@abs(value) < threshold)
        renderScientific(&buffer, value, precision)
    else
        renderFixed(&buffer, value, precision);
    try writer.writeAll(text[0..@min(text.len, 99)]);
}

fn renderScientific(
    buffer: []u8,
    value: f64,
    comptime precision: usize,
) []const u8 {
    const parts = decompose(value);
    if (parts.special != .finite) return renderSpecial(buffer, parts);
    var exponent: i32 = if (parts.mantissa == 0) 0 else decimalExponent(value);
    var significand = scientificSignificand(parts, precision, exponent);
    const lower = power10(precision);
    const upper = lower * 10;
    if (parts.mantissa != 0 and significand < lower) {
        exponent -= 1;
        significand = scientificSignificand(parts, precision, exponent);
    }
    if (significand >= upper) {
        significand /= 10;
        exponent += 1;
    }
    var writer = std.Io.Writer.fixed(buffer);
    if (parts.negative) writer.writeByte('-') catch unreachable;
    var digits: [19]u8 = undefined;
    var remaining = significand;
    var index = precision + 1;
    while (index != 0) {
        index -= 1;
        digits[index] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
    }
    writer.writeByte(digits[0]) catch unreachable;
    if (precision != 0) {
        writer.writeByte('.') catch unreachable;
        writer.writeAll(digits[1 .. precision + 1]) catch unreachable;
    }
    writer.writeByte('E') catch unreachable;
    if (exponent < 0) {
        writer.writeByte('-') catch unreachable;
    } else {
        writer.writeByte('+') catch unreachable;
    }
    writer.print("{d:0>2}", .{@abs(exponent)}) catch unreachable;
    return writer.buffered();
}

fn renderFixed(
    buffer: []u8,
    value: f64,
    comptime precision: usize,
) []const u8 {
    const parts = decompose(value);
    if (parts.special != .finite) return renderSpecial(buffer, parts);
    var scaled = Big.init(parts.mantissa);
    scaled.multiplyPower5(precision);
    const binary_exponent = parts.exponent + @as(i32, @intCast(precision));
    if (binary_exponent >= 0) {
        scaled.shiftLeft(@intCast(binary_exponent));
    } else {
        scaled = Big.init(scaled.roundedShift(@intCast(-binary_exponent)));
    }
    var digits_buffer: [400]u8 = undefined;
    const digits = renderBigDecimal(&digits_buffer, scaled);
    var writer = std.Io.Writer.fixed(buffer);
    if (parts.negative) writer.writeByte('-') catch unreachable;
    if (precision == 0) {
        writer.writeAll(digits) catch unreachable;
    } else if (digits.len > precision) {
        const point = digits.len - precision;
        writer.writeAll(digits[0..point]) catch unreachable;
        writer.writeByte('.') catch unreachable;
        writer.writeAll(digits[point..]) catch unreachable;
    } else {
        writer.writeAll("0.") catch unreachable;
        for (0..precision - digits.len) |_| writer.writeByte('0') catch unreachable;
        writer.writeAll(digits) catch unreachable;
    }
    return writer.buffered();
}

fn renderSpecial(buffer: []u8, parts: FloatParts) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    if (parts.negative) writer.writeByte('-') catch unreachable;
    writer.writeAll(if (parts.special == .nan) "nan" else "inf") catch unreachable;
    return writer.buffered();
}

fn renderBigDecimal(buffer: []u8, value: Big) []const u8 {
    var remaining = value;
    if (remaining.len == 0) {
        buffer[0] = '0';
        return buffer[0..1];
    }
    var chunks: [40]u32 = undefined;
    var count: usize = 0;
    while (remaining.len != 0) {
        chunks[count] = remaining.divideSmall(1_000_000_000);
        count += 1;
    }
    var writer = std.Io.Writer.fixed(buffer);
    writer.print("{d}", .{chunks[count - 1]}) catch unreachable;
    var index = count - 1;
    while (index != 0) {
        index -= 1;
        writer.print("{d:0>9}", .{chunks[index]}) catch unreachable;
    }
    return writer.buffered();
}

fn scientificSignificand(
    parts: FloatParts,
    comptime precision: usize,
    decimal_exponent: i32,
) u128 {
    if (parts.mantissa == 0) return 0;
    const decimal_shift = @as(i32, @intCast(precision)) - decimal_exponent;
    std.debug.assert(decimal_shift >= 0);
    var scaled = Big.init(parts.mantissa);
    scaled.multiplyPower5(@intCast(decimal_shift));
    const binary_exponent = parts.exponent + decimal_shift;
    if (binary_exponent >= 0) {
        scaled.shiftLeft(@intCast(binary_exponent));
        return scaled.shiftedU128(0);
    }
    return scaled.roundedShift(@intCast(-binary_exponent));
}

fn decimalExponent(value: f64) i32 {
    var normalized: f128 = @floatCast(@abs(value));
    var exponent: i32 = 0;
    while (normalized >= 10) {
        normalized /= 10;
        exponent += 1;
    }
    while (normalized < 1) {
        normalized *= 10;
        exponent -= 1;
    }
    return exponent;
}

fn decompose(value: f64) FloatParts {
    const bits: u64 = @bitCast(value);
    const exponent_bits: u11 = @truncate(bits >> 52);
    const fraction = bits & 0x000f_ffff_ffff_ffff;
    const negative = bits >> 63 != 0;
    if (exponent_bits == 0x7ff) {
        return .{
            .negative = negative,
            .mantissa = fraction,
            .exponent = 0,
            .special = if (fraction == 0) .infinity else .nan,
        };
    }
    if (exponent_bits == 0) {
        return .{
            .negative = negative,
            .mantissa = fraction,
            .exponent = -1074,
            .special = .finite,
        };
    }
    return .{
        .negative = negative,
        .mantissa = fraction | (@as(u64, 1) << 52),
        .exponent = @as(i32, exponent_bits) - 1023 - 52,
        .special = .finite,
    };
}

fn power10(comptime exponent: usize) u128 {
    var result: u128 = 1;
    for (0..exponent) |_| result *= 10;
    return result;
}

fn typePrefix(comptime T: type) u8 {
    if (T == bfloat.BFloat16) return 'i';
    return switch (@typeInfo(T)) {
        .float => 'f',
        .int => |info| if (info.signedness == .signed) 'i' else 'u',
        else => unreachable,
    };
}

fn typeBits(comptime T: type) usize {
    return if (T == bfloat.BFloat16) 16 else @bitSizeOf(T);
}

fn validateType(comptime T: type) void {
    if (T == bfloat.BFloat16) return;
    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.bits != 8 and info.bits != 16 and info.bits != 32 and
                info.bits != 64 and info.bits != 128)
            {
                @compileError("diagnostic integers require 8/16/32/64/128 bits");
            }
            if (info.bits == 128 and info.signedness == .signed) {
                @compileError("Highway diagnostics only support unsigned 128-bit lanes");
            }
        },
        .float => |info| if (info.bits != 16 and info.bits != 32 and info.bits != 64) {
            @compileError("diagnostic floats require 16/32/64 bits");
        },
        else => @compileError("unsupported Highway diagnostic lane type"),
    }
}
