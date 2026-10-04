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
