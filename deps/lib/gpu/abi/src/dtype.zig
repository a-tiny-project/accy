const std = @import("std");

pub const Bf16 = packed struct(u16) {
    bits: u16,

    pub fn fromF32(x: f32) Bf16 {
        const f32_bits: u32 = @bitCast(x);
        return .{ .bits = @truncate(f32_bits >> 16) };
    }

    pub fn toF32(self: Bf16) f32 {
        const widened: u32 = @as(u32, self.bits) << 16;
        return @bitCast(widened);
    }
};

pub const Key = packed struct(u64) {
    bits: u64,

    pub fn init(bits: u64) Key {
        return .{ .bits = bits };
    }

    pub fn fromWords(low: u32, high: u32) Key {
        return .{ .bits = @as(u64, low) | (@as(u64, high) << 32) };
    }

    pub fn lo(self: Key) u32 {
        return @truncate(self.bits);
    }

    pub fn hi(self: Key) u32 {
        return @truncate(self.bits >> 32);
    }
};

pub const DType = enum(u8) {
    i1 = 0,
    i8 = 1,
    i16 = 2,
    i32 = 3,
    i64 = 4,
    u8 = 5,
    u16 = 6,
    u32 = 7,
    u64 = 8,
    f16 = 9,
    bf16 = 10,
    f32 = 11,
    f64 = 12,
    key = 13,

    pub fn ZigType(comptime self: DType) type {
        return switch (self) {
            .i1 => bool,
            .i8 => i8,
            .i16 => i16,
            .i32 => i32,
            .i64 => i64,
            .u8 => u8,
            .u16 => u16,
            .u32 => u32,
            .u64 => u64,
            .f16 => f16,
            .bf16 => Bf16,
            .f32 => f32,
            .f64 => f64,
            .key => Key,
        };
    }

    pub fn sizeOf(self: DType) u8 {
        return switch (self) {
            inline else => |tag| @sizeOf(tag.ZigType()),
        };
    }

    pub fn alignOf(self: DType) u8 {
        return switch (self) {
            inline else => |tag| @alignOf(tag.ZigType()),
        };
    }

    pub fn name(self: DType) []const u8 {
        return @tagName(self);
    }

    pub fn isFloat(self: DType) bool {
        return switch (self) {
            .f16, .bf16, .f32, .f64 => true,
            else => false,
        };
    }

    pub fn isSignedInt(self: DType) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64 => true,
            else => false,
        };
    }

    pub fn isUnsignedInt(self: DType) bool {
        return switch (self) {
            .u8, .u16, .u32, .u64 => true,
            else => false,
        };
    }

    pub fn isBool(self: DType) bool {
        return self == .i1;
    }

    pub fn isKey(self: DType) bool {
        return self == .key;
    }

    pub fn isNumeric(self: DType) bool {
        return self.isFloat() or self.isSignedInt() or self.isUnsignedInt();
    }

    pub fn fromName(s: []const u8) ?DType {
        if (std.mem.eql(u8, s, "bool")) return .i1;
        inline for (
            @typeInfo(DType).@"enum".field_names,
            @typeInfo(DType).@"enum".field_values,
        ) |field_name, field_name_value| {
            const field = .{ .name = field_name, .value = field_name_value };
            if (std.mem.eql(u8, s, field.name)) return @fromBackingInt(@intCast(field.value));
        }
        return null;
    }

    pub fn fromZigType(comptime T: type) ?DType {
        inline for (
            @typeInfo(DType).@"enum".field_names,
            @typeInfo(DType).@"enum".field_values,
        ) |field_name, field_name_value| {
            const field = .{ .name = field_name, .value = field_name_value };
            const tag: DType = comptime @fromBackingInt(@intCast(field.value));
            if (T == comptime tag.ZigType()) return tag;
        }
        return null;
    }
};

test "name returns canonical tag spelling" {
    try std.testing.expectEqualStrings("i1", DType.i1.name());
    try std.testing.expectEqualStrings("i32", DType.i32.name());
    try std.testing.expectEqualStrings("u64", DType.u64.name());
    try std.testing.expectEqualStrings("f16", DType.f16.name());
    try std.testing.expectEqualStrings("bf16", DType.bf16.name());
    try std.testing.expectEqualStrings("f64", DType.f64.name());
    try std.testing.expectEqualStrings("key", DType.key.name());
}

test "fromName round-trips name for every variant" {
    inline for (
        @typeInfo(DType).@"enum".field_names,
        @typeInfo(DType).@"enum".field_values,
    ) |f_name, f_name_value| {
        const f = .{ .name = f_name, .value = f_name_value };
        const tag: DType = @fromBackingInt(@intCast(f.value));
        try std.testing.expectEqual(@as(?DType, tag), DType.fromName(tag.name()));
    }
}

test "fromName accepts the bool alias for i1" {
    try std.testing.expectEqual(@as(?DType, .i1), DType.fromName("bool"));
}

test "fromName rejects unknown spellings" {
    try std.testing.expectEqual(@as(?DType, null), DType.fromName(""));
    try std.testing.expectEqual(@as(?DType, null), DType.fromName("complex64"));
    try std.testing.expectEqual(@as(?DType, null), DType.fromName("F32"));
}

test "sizeOf widths match the IEEE / two's-complement layout" {
    try std.testing.expectEqual(@as(u8, 1), DType.i1.sizeOf());
    try std.testing.expectEqual(@as(u8, 1), DType.i8.sizeOf());
    try std.testing.expectEqual(@as(u8, 2), DType.i16.sizeOf());
    try std.testing.expectEqual(@as(u8, 4), DType.i32.sizeOf());
    try std.testing.expectEqual(@as(u8, 8), DType.i64.sizeOf());
    try std.testing.expectEqual(@as(u8, 1), DType.u8.sizeOf());
    try std.testing.expectEqual(@as(u8, 2), DType.u16.sizeOf());
    try std.testing.expectEqual(@as(u8, 4), DType.u32.sizeOf());
    try std.testing.expectEqual(@as(u8, 8), DType.u64.sizeOf());
    try std.testing.expectEqual(@as(u8, 2), DType.f16.sizeOf());
    try std.testing.expectEqual(@as(u8, 2), DType.bf16.sizeOf());
    try std.testing.expectEqual(@as(u8, 4), DType.f32.sizeOf());
    try std.testing.expectEqual(@as(u8, 8), DType.f64.sizeOf());
    try std.testing.expectEqual(@as(u8, 8), DType.key.sizeOf());
}

test "sizeOf and alignOf agree with ZigType for every variant" {
    inline for (
        @typeInfo(DType).@"enum".field_names,
        @typeInfo(DType).@"enum".field_values,
    ) |f_name, f_name_value| {
        const f = .{ .name = f_name, .value = f_name_value };
        const tag: DType = comptime @fromBackingInt(@intCast(f.value));
        const T = tag.ZigType();
        try std.testing.expectEqual(@as(u8, @sizeOf(T)), tag.sizeOf());
        try std.testing.expectEqual(@as(u8, @alignOf(T)), tag.alignOf());
    }
}

test "ZigType maps i1 to bool" {
    try std.testing.expect(DType.i1.ZigType() == bool);
}

test "ZigType maps integer dtypes to native Zig integers" {
    try std.testing.expect(DType.i8.ZigType() == i8);
    try std.testing.expect(DType.i16.ZigType() == i16);
    try std.testing.expect(DType.i32.ZigType() == i32);
    try std.testing.expect(DType.i64.ZigType() == i64);
    try std.testing.expect(DType.u8.ZigType() == u8);
    try std.testing.expect(DType.u16.ZigType() == u16);
    try std.testing.expect(DType.u32.ZigType() == u32);
    try std.testing.expect(DType.u64.ZigType() == u64);
}

test "ZigType maps float dtypes to native Zig floats and Bf16" {
    try std.testing.expect(DType.f16.ZigType() == f16);
    try std.testing.expect(DType.bf16.ZigType() == Bf16);
    try std.testing.expect(DType.f32.ZigType() == f32);
    try std.testing.expect(DType.f64.ZigType() == f64);
}

test "ZigType maps key dtype to opaque key payload" {
    try std.testing.expect(DType.key.ZigType() == Key);
}

test "fromZigType is the inverse of ZigType" {
    inline for (
        @typeInfo(DType).@"enum".field_names,
        @typeInfo(DType).@"enum".field_values,
    ) |f_name, f_name_value| {
        const f = .{ .name = f_name, .value = f_name_value };
        const tag: DType = comptime @fromBackingInt(@intCast(f.value));
        try std.testing.expectEqual(@as(?DType, tag), comptime DType.fromZigType(tag.ZigType()));
    }
}

test "fromZigType rejects types outside the dtype set" {
    try std.testing.expectEqual(@as(?DType, null), DType.fromZigType(u128));
    try std.testing.expectEqual(@as(?DType, null), DType.fromZigType(usize));
    try std.testing.expectEqual(@as(?DType, null), DType.fromZigType(f80));
}

test "isFloat / isSignedInt / isUnsignedInt / isBool / isKey partition the enum" {
    inline for (
        @typeInfo(DType).@"enum".field_names,
        @typeInfo(DType).@"enum".field_values,
    ) |f_name, f_name_value| {
        const f = .{ .name = f_name, .value = f_name_value };
        const tag: DType = @fromBackingInt(@intCast(f.value));
        const flags = [_]bool{ tag.isFloat(), tag.isSignedInt(), tag.isUnsignedInt(), tag.isBool(), tag.isKey() };
        var trues: u32 = 0;
        for (flags) |b| if (b) {
            trues += 1;
        };
        try std.testing.expectEqual(@as(u32, 1), trues);
    }
}

test "isFloat names the float dtypes" {
    try std.testing.expect(DType.f16.isFloat());
    try std.testing.expect(DType.bf16.isFloat());
    try std.testing.expect(DType.f32.isFloat());
    try std.testing.expect(DType.f64.isFloat());
    try std.testing.expect(!DType.i32.isFloat());
    try std.testing.expect(!DType.i1.isFloat());
}

test "key payload exposes stable counter words" {
    const key = Key.fromWords(0x89abcdef, 0x01234567);
    try std.testing.expectEqual(@as(u64, 0x01234567_89abcdef), key.bits);
    try std.testing.expectEqual(@as(u32, 0x89abcdef), key.lo());
    try std.testing.expectEqual(@as(u32, 0x01234567), key.hi());
    try std.testing.expect(!DType.key.isNumeric());
}

test "Bf16 fromF32 / toF32 round-trips simple values exactly" {
    const cases = [_]f32{ 0.0, 1.0, -1.0, 2.0, 0.5, -0.5, 4.0 };
    for (cases) |v| {
        const x = Bf16.fromF32(v);
        try std.testing.expectEqual(v, x.toF32());
    }
}

test "Bf16 truncates the low 16 bits of f32" {
    const x = Bf16.fromF32(1.0);
    const expected_bits: u32 = @bitCast(@as(f32, 1.0));
    try std.testing.expectEqual(@as(u16, @truncate(expected_bits >> 16)), x.bits);
}
