const std = @import("std");

pub const maximum_vector_bytes: usize = 65_536;

pub fn FixedTag(comptime T: type, comptime lanes: usize) type {
    return Descriptor(T, lanes, 0);
}

pub fn Descriptor(comptime T: type, comptime lanes: usize, comptime power: i8) type {
    @setEvalBranchQuota(2_000);
    validateLane(T);
    if (power < -3) @compileError("Highway descriptor power must be at least -3");
    if (lanes == 0) @compileError("SIMD vectors require at least one lane");
    if (!std.math.isPowerOfTwo(lanes)) {
        @compileError("fixed SIMD lane counts must be powers of two");
    }
    if (lanes > maximum_vector_bytes / @sizeOf(T)) {
        @compileError("fixed SIMD vector exceeds the Highway maximum byte width");
    }
    const Storage = if (isBFloat16(T)) T.Storage else T;

    return struct {
        pub const Lane = Storage;
        pub const Scalar = T;
        pub const lane_count: usize = lanes;
        pub const byte_count: usize = lanes * @sizeOf(T);
        pub const descriptor_power: i8 = power;
        pub const is_bfloat16 = isBFloat16(T);
        pub const Vector = @Vector(lanes, Storage);
        pub const Mask = @Vector(lanes, bool);

        pub fn rebind(comptime NewLane: type) type {
            return Descriptor(
                NewLane,
                lanes,
                power + laneSizePower(NewLane) - laneSizePower(T),
            );
        }

        pub fn repartition(comptime NewLane: type) type {
            validateLane(NewLane);
            const new_lanes = @max(1, (byte_count + @sizeOf(NewLane) - 1) /
                @sizeOf(NewLane));
            return Descriptor(NewLane, new_lanes, power);
        }

        pub fn half() type {
            return Descriptor(T, @max(1, lanes / 2), power - 1);
        }

        pub fn twice() type {
            return Descriptor(T, lanes * 2, power + 1);
        }

        pub fn withLanes(comptime new_lanes: usize, comptime new_power: i8) type {
            return Descriptor(T, new_lanes, new_power);
        }
    };
}

pub fn ScalableTag(comptime T: type) type {
    validateLane(T);
    return FixedTag(T, suggestedLanes(T));
}

pub fn ScalableTagPow2(comptime T: type, comptime power: comptime_int) type {
    validateLane(T);
    const descriptor_power = clampedPower(power);
    return Descriptor(T, scaleLanes(suggestedLanes(T), descriptor_power), descriptor_power);
}

pub fn CappedTag(comptime T: type, comptime limit: usize) type {
    validateLane(T);
    if (limit == 0) @compileError("capped SIMD vectors require a nonzero limit");
    const native_lanes = suggestedLanes(T);
    const lanes = std.math.floorPowerOfTwo(usize, @min(limit, native_lanes));
    return FixedTag(T, @max(1, lanes));
}

pub fn CappedTagPow2(
    comptime T: type,
    comptime limit: usize,
    comptime power: comptime_int,
) type {
    const descriptor_power = clampedPower(power);
    return Descriptor(
        T,
        scaleLanes(CappedTag(T, limit).lane_count, descriptor_power),
        descriptor_power,
    );
}

pub fn CappedTagIfFixed(comptime T: type, comptime limit: usize) type {
    return CappedTag(T, limit);
}

pub fn CappedTagIfFixedPow2(
    comptime T: type,
    comptime limit: usize,
    comptime power: comptime_int,
) type {
    return CappedTagPow2(T, limit, power);
}

pub fn Full16(comptime T: type) type {
    return FullBytes(T, 2);
}

pub fn Full32(comptime T: type) type {
    return FullBytes(T, 4);
}

pub fn Full64(comptime T: type) type {
    return FullBytes(T, 8);
}

pub fn Full128(comptime T: type) type {
    return FullBytes(T, 16);
}

pub fn TFromD(comptime D: type) type {
    return if (@hasDecl(D, "Scalar")) D.Scalar else D.Lane;
}

pub fn DFromV(comptime V: type) type {
    return switch (@typeInfo(V)) {
        .vector => |info| FixedTag(info.child, info.len),
        else => @compileError("DFromV requires a Zig vector type"),
    };
}

pub fn TFromV(comptime V: type) type {
    return switch (@typeInfo(V)) {
        .vector => |info| info.child,
        else => @compileError("TFromV requires a Zig vector type"),
    };
}

pub fn VFromD(comptime D: type) type {
    return D.Vector;
}

pub fn MFromD(comptime D: type) type {
    return D.Mask;
}

pub fn Vec(comptime D: type) type {
    return VFromD(D);
}

pub fn Mask(comptime D: type) type {
    return MFromD(D);
}

pub fn maxLanes(comptime D: type) usize {
    return D.lane_count;
}

pub fn laneCount(comptime D: type) usize {
    return D.lane_count;
}

pub fn maxBytes(comptime D: type) usize {
    return D.byte_count;
}

pub fn maxBlocks(comptime D: type) usize {
    return (D.byte_count + 15) / 16;
}

pub fn pow2(comptime D: type) i8 {
    return D.descriptor_power;
}

pub fn Rebind(comptime T: type, comptime D: type) type {
    return D.rebind(T);
}

pub fn RebindToSigned(comptime D: type) type {
    return D.rebind(MakeSigned(TFromD(D)));
}

pub fn RebindToUnsigned(comptime D: type) type {
    return D.rebind(MakeUnsigned(TFromD(D)));
}

pub fn RebindToFloat(comptime D: type) type {
    return D.rebind(MakeFloat(TFromD(D)));
}

pub fn Repartition(comptime T: type, comptime D: type) type {
    return D.repartition(T);
}

pub fn RepartitionToWide(comptime D: type) type {
    return D.repartition(MakeWide(TFromD(D)));
}

pub fn RepartitionToNarrow(comptime D: type) type {
    return D.repartition(MakeNarrow(TFromD(D)));
}

pub fn RepartitionToWideX2(comptime D: type) type {
    return RepartitionToWide(RepartitionToWide(D));
}

pub fn RepartitionToWideX3(comptime D: type) type {
    return RepartitionToWide(RepartitionToWideX2(D));
}

pub fn Half(comptime D: type) type {
    return D.half();
}

pub fn Twice(comptime D: type) type {
    return D.twice();
}

pub fn BlockDFromD(comptime D: type) type {
    const block_lanes = @max(1, 16 / @sizeOf(TFromD(D)));
    return D.withLanes(@min(D.lane_count, block_lanes), 0);
}

pub fn MakeUnsigned(comptime T: type) type {
    if (isBFloat16(T)) return u16;
    return switch (@typeInfo(T)) {
        .int => |info| switch (info.bits) {
            8, 16, 32, 64, 128 => @Int(.unsigned, info.bits),
            else => @compileError("unsupported Highway integer width"),
        },
        .float => |info| switch (info.bits) {
            16 => u16,
            32 => u32,
            64 => u64,
            else => @compileError("unsupported Highway floating-point width"),
        },
        else => @compileError("type has no Highway unsigned relation"),
    };
}

pub fn MakeSigned(comptime T: type) type {
    if (isBFloat16(T)) return i16;
    return switch (@typeInfo(T)) {
        .int => |info| switch (info.bits) {
            8, 16, 32, 64 => @Int(.signed, info.bits),
            else => @compileError("type has no Highway signed relation"),
        },
        .float => |info| switch (info.bits) {
            16 => i16,
            32 => i32,
            64 => i64,
            else => @compileError("unsupported Highway floating-point width"),
        },
        else => @compileError("type has no Highway signed relation"),
    };
}

pub fn MakeFloat(comptime T: type) type {
    if (isBFloat16(T)) @compileError("type has no Highway floating-point relation");
    return switch (@typeInfo(T)) {
        .int => |info| switch (info.bits) {
            16 => f16,
            32 => f32,
            64 => f64,
            else => @compileError("type has no Highway floating-point relation"),
        },
        .float => |info| switch (info.bits) {
            16 => f16,
            32 => f32,
            64 => f64,
            else => @compileError("type has no Highway floating-point relation"),
        },
        else => @compileError("type has no Highway floating-point relation"),
    };
}

pub fn MakeWide(comptime T: type) type {
    if (isBFloat16(T)) return f32;
    return switch (@typeInfo(T)) {
        .int => |info| switch (info.bits) {
            8 => @Int(info.signedness, 16),
            16 => @Int(info.signedness, 32),
            32 => @Int(info.signedness, 64),
            64 => if (info.signedness == .unsigned)
                u128
            else
                @compileError("type has no Highway wide relation"),
            else => @compileError("type has no Highway wide relation"),
        },
        .float => |info| switch (info.bits) {
            16 => f32,
            32 => f64,
            else => @compileError("type has no Highway wide relation"),
        },
        else => @compileError("type has no Highway wide relation"),
    };
}

pub fn MakeNarrow(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int => |info| switch (info.bits) {
            16 => @Int(info.signedness, 8),
            32 => @Int(info.signedness, 16),
            64 => @Int(info.signedness, 32),
            128 => if (info.signedness == .unsigned)
                u64
            else
                @compileError("type has no Highway narrow relation"),
            else => @compileError("type has no Highway narrow relation"),
        },
        .float => |info| switch (info.bits) {
            32 => f16,
            64 => f32,
            else => @compileError("type has no Highway narrow relation"),
        },
        else => @compileError("type has no Highway narrow relation"),
    };
}

pub fn UnsignedFromSize(comptime bytes: usize) type {
    return switch (bytes) {
        1 => u8,
        2 => u16,
        4 => u32,
        8 => u64,
        16 => u128,
        else => @compileError("unsupported Highway unsigned byte width"),
    };
}

pub fn SignedFromSize(comptime bytes: usize) type {
    return switch (bytes) {
        1 => i8,
        2 => i16,
        4 => i32,
        8 => i64,
        else => @compileError("unsupported Highway signed byte width"),
    };
}

pub fn FloatFromSize(comptime bytes: usize) type {
    return switch (bytes) {
        2 => f16,
        4 => f32,
        8 => f64,
        else => @compileError("unsupported Highway floating-point byte width"),
    };
}

pub fn isLane(comptime T: type) bool {
    if (isBFloat16(T)) return true;
    return switch (@typeInfo(T)) {
        .int => |info| info.bits == 8 or info.bits == 16 or
            info.bits == 32 or info.bits == 64,
        .float => |info| info.bits == 16 or info.bits == 32 or info.bits == 64,
        else => false,
    };
}

pub fn isIntegerLane(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |info| info.bits == 8 or info.bits == 16 or
            info.bits == 32 or info.bits == 64,
        else => false,
    };
}

pub fn isSpecialFloat(comptime T: type) bool {
    return T == f16 or isBFloat16(T);
}

pub fn isFloat3264(comptime T: type) bool {
    return T == f32 or T == f64;
}

pub fn isFloat(comptime T: type) bool {
    return T == f16 or isFloat3264(T);
}

pub fn isSigned(comptime T: type) bool {
    if (isBFloat16(T)) return true;
    return switch (@typeInfo(T)) {
        .int => |info| info.signedness == .signed,
        .float => true,
        else => false,
    };
}

pub fn isUnsigned(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |info| info.signedness == .unsigned,
        else => false,
    };
}

fn FullBytes(comptime T: type, comptime bytes: usize) type {
    validateLane(T);
    if (@sizeOf(T) > bytes) @compileError("lane type exceeds fixed Highway vector width");
    return FixedTag(T, bytes / @sizeOf(T));
}

fn scaleLanes(comptime lanes: usize, comptime power: i8) usize {
    if (power < 0) return @max(1, lanes >> @intCast(-power));
    return lanes << @intCast(power);
}

fn clampedPower(comptime power: comptime_int) i8 {
    if (power < -3) @compileError("Highway scalable power must be at least -3");
    return @intCast(@min(power, 3));
}

fn suggestedLanes(comptime T: type) usize {
    const Storage = if (isBFloat16(T)) T.Storage else T;
    return std.simd.suggestVectorLength(Storage) orelse 1;
}

fn laneSizePower(comptime T: type) i8 {
    validateLane(T);
    return switch (@sizeOf(T)) {
        1 => 0,
        2 => 1,
        4 => 2,
        8 => 3,
        else => @compileError("unsupported Highway lane size"),
    };
}

fn isBFloat16(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "is_bfloat16") and T.is_bfloat16,
        else => false,
    };
}

fn validateLane(comptime T: type) void {
    if (!isLane(T)) {
        @compileError("SIMD lanes must be 8/16/32/64-bit integers or 16/32/64-bit floats");
    }
}

fn descriptorDigestRecord(comptime D: type, digest: *u64) void {
    digest.* = descriptorDigestStep(digest.*, maxLanes(D));
    digest.* = descriptorDigestStep(digest.*, maxBytes(D));
    digest.* = descriptorDigestStep(digest.*, maxBlocks(D));
    digest.* = descriptorDigestStep(digest.*, @bitCast(@as(i64, pow2(D))));
}

fn descriptorDigestStep(digest: u64, value: u64) u64 {
    return (digest ^ value) *% 0x0000_0100_0000_01b3;
}
