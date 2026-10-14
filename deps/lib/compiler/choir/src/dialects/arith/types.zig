const std = @import("std");
const ir = @import("../../core/root.zig");

pub const ScalarKind = enum {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f16,
    bf16,
    f32,
    f64,
    index,
    bool,
};

pub const ScalarClass = enum {
    boolean,
    signed_integer,
    unsigned_integer,
    float,
    index,
};

pub const ScalarDescriptor = struct {
    kind: ScalarKind,
    suffix: []const u8,
    name: []const u8,
    class: ScalarClass,
    bit_width: u8,
    vector_lanes: []const u32,
};

pub const ScalarSet = struct {
    bits: u16 = 0,

    pub fn init(comptime kinds: []const ScalarKind) ScalarSet {
        comptime {
            for (kinds, 0..) |kind, index| {
                for (kinds[0..index]) |previous| {
                    if (kind == previous) @compileError("duplicate scalar kind in set");
                }
            }
        }
        var set: ScalarSet = .{};
        inline for (kinds) |kind| {
            set.insert(kind);
        }
        return set;
    }

    pub fn insert(self: *ScalarSet, kind: ScalarKind) void {
        self.bits |= scalarBit(kind);
    }

    pub fn contains(self: ScalarSet, kind: ScalarKind) bool {
        return self.bits & scalarBit(kind) != 0;
    }

    pub fn containsAll(self: ScalarSet, required: ScalarSet) bool {
        return self.bits & required.bits == required.bits;
    }

    pub fn kindFromTypeName(self: ScalarSet, name: []const u8) ?ScalarKind {
        const kind = scalarKindFromTypeName(name) orelse return null;
        return if (self.contains(kind)) kind else null;
    }

    pub fn kindFromType(self: ScalarSet, ty: ir.Type) ?ScalarKind {
        return self.kindFromTypeName(ty.getDialectTypeName() orelse return null);
    }
};

const VectorTypeSpec = struct {
    kind: ScalarKind,
    width: u32,
    name: []const u8,
};

fn arithTypeName(comptime suffix: []const u8) []const u8 {
    return "arith." ++ suffix;
}

fn scalarDescriptorValue(
    comptime kind: ScalarKind,
    class: ScalarClass,
    bit_width: u8,
    vector_lanes: []const u32,
) ScalarDescriptor {
    const suffix = @tagName(kind);
    return .{
        .kind = kind,
        .suffix = suffix,
        .name = arithTypeName(suffix),
        .class = class,
        .bit_width = bit_width,
        .vector_lanes = vector_lanes,
    };
}

const scalar_descriptors = [_]ScalarDescriptor{
    scalarDescriptorValue(.i8, .signed_integer, 8, &.{ 2, 4, 8, 16 }),
    scalarDescriptorValue(.i16, .signed_integer, 16, &.{ 2, 4, 8, 16 }),
    scalarDescriptorValue(.i32, .signed_integer, 32, &.{ 2, 4, 8, 16 }),
    scalarDescriptorValue(.i64, .signed_integer, 64, &.{ 2, 4, 8 }),
    scalarDescriptorValue(.u8, .unsigned_integer, 8, &.{ 2, 4, 8, 16 }),
    scalarDescriptorValue(.u16, .unsigned_integer, 16, &.{ 2, 4, 8, 16 }),
    scalarDescriptorValue(.u32, .unsigned_integer, 32, &.{ 2, 4, 8, 16 }),
    scalarDescriptorValue(.u64, .unsigned_integer, 64, &.{ 2, 4, 8 }),
    scalarDescriptorValue(.f16, .float, 16, &.{ 2, 4, 8, 16 }),
    scalarDescriptorValue(.bf16, .float, 16, &.{ 2, 4, 8, 16 }),
    scalarDescriptorValue(.f32, .float, 32, &.{ 2, 4, 8, 16 }),
    scalarDescriptorValue(.f64, .float, 64, &.{ 2, 4, 8 }),
    scalarDescriptorValue(.index, .index, 64, &.{ 2, 4, 8, 16 }),
    scalarDescriptorValue(.bool, .boolean, 1, &.{}),
};

comptime {
    const field_names = @typeInfo(ScalarKind).@"enum".field_names;
    if (field_names.len > @bitSizeOf(u16)) @compileError("ScalarSet storage is too small");
    if (field_names.len != scalar_descriptors.len) @compileError("scalar descriptor catalog is incomplete");
    for (scalar_descriptors, 0..) |descriptor, index| {
        if (@backingInt(descriptor.kind) != index) @compileError("scalar descriptor catalog order drifted");
    }
}

fn scalarBit(kind: ScalarKind) u16 {
    return @as(u16, 1) << @intCast(@backingInt(kind));
}

pub fn scalarDescriptor(kind: ScalarKind) *const ScalarDescriptor {
    return &scalar_descriptors[@backingInt(kind)];
}

pub fn scalarTypeName(kind: ScalarKind) []const u8 {
    return scalarDescriptor(kind).name;
}

pub fn scalarTypeSuffix(kind: ScalarKind) []const u8 {
    return scalarDescriptor(kind).suffix;
}

pub fn scalarKindFromTypeName(name: []const u8) ?ScalarKind {
    const prefix = "arith.";
    if (name.len <= prefix.len or !std.mem.eql(u8, name[0..prefix.len], prefix)) return null;
    return scalarKindFromSuffix(name[prefix.len..]);
}

pub fn scalarKindFromType(ty: ir.Type) ?ScalarKind {
    return scalarKindFromTypeName(ty.getDialectTypeName() orelse return null);
}

pub fn scalarKindFromSuffix(suffix: []const u8) ?ScalarKind {
    return std.meta.stringToEnum(ScalarKind, suffix);
}

pub fn scalarKindIsInteger(kind: ScalarKind) bool {
    return scalarKindIsSignedInteger(kind) or scalarKindIsUnsignedInteger(kind);
}

pub fn scalarKindIsSignedInteger(kind: ScalarKind) bool {
    const class = scalarDescriptor(kind).class;
    return class == .signed_integer or class == .index;
}

pub fn scalarKindIsUnsignedInteger(kind: ScalarKind) bool {
    return scalarDescriptor(kind).class == .unsigned_integer;
}

pub fn scalarKindIsFloat(kind: ScalarKind) bool {
    return scalarDescriptor(kind).class == .float;
}

pub fn scalarBitWidth(kind: ScalarKind) u8 {
    return scalarDescriptor(kind).bit_width;
}

fn vectorTypeNameStatic(comptime width: u32, comptime kind: ScalarKind) []const u8 {
    @setEvalBranchQuota(32_000);
    return std.fmt.comptimePrint("arith.vec{d}x{s}", .{ width, scalarTypeSuffix(kind) });
}

fn vectorTypeSpecCount() usize {
    comptime var count: usize = 0;
    inline for (scalar_descriptors) |spec| {
        count += spec.vector_lanes.len;
    }
    return count;
}

const vector_type_specs = blk: {
    const count = vectorTypeSpecCount();
    var out: [count]VectorTypeSpec = undefined;
    var index: usize = 0;
    for (scalar_descriptors) |spec| {
        for (spec.vector_lanes) |width| {
            out[index] = .{
                .kind = spec.kind,
                .width = width,
                .name = vectorTypeNameStatic(width, spec.kind),
            };
            index += 1;
        }
    }
    break :blk out;
};

const registered_type_specs = blk: {
    const count = scalar_descriptors.len + vector_type_specs.len;
    var out: [count]ir.dialects.TypeSpec = undefined;
    var index: usize = 0;
    for (scalar_descriptors) |spec| {
        out[index] = ir.dialects.typeName(spec.name);
        index += 1;
    }
    for (vector_type_specs) |spec| {
        out[index] = ir.dialects.typeName(spec.name);
        index += 1;
    }
    break :blk out;
};

pub fn vectorTypeName(width: u32, kind: ScalarKind) ?[]const u8 {
    inline for (vector_type_specs) |spec| {
        if (spec.width == width and spec.kind == kind) return spec.name;
    }
    return null;
}

pub fn vectorTypeNameForElement(width: u32, element_type_name: []const u8) ?[]const u8 {
    const kind = scalarKindFromTypeName(element_type_name) orelse return null;
    return vectorTypeName(width, kind);
}

pub fn registeredTypeSpecs() []const ir.dialects.TypeSpec {
    return &registered_type_specs;
}

pub const type_names = struct {
    pub const int8 = scalarTypeName(.i8);
    pub const int16 = scalarTypeName(.i16);
    pub const int32 = scalarTypeName(.i32);
    pub const int64 = scalarTypeName(.i64);
    pub const uint8 = scalarTypeName(.u8);
    pub const uint16 = scalarTypeName(.u16);
    pub const uint32 = scalarTypeName(.u32);
    pub const uint64 = scalarTypeName(.u64);
    pub const float16 = scalarTypeName(.f16);
    pub const bfloat16 = scalarTypeName(.bf16);
    pub const float32 = scalarTypeName(.f32);
    pub const float64 = scalarTypeName(.f64);
    pub const index = scalarTypeName(.index);
    pub const boolean = scalarTypeName(.bool);

    pub const vec2xi8 = vectorTypeName(2, .i8).?;
    pub const vec4xi8 = vectorTypeName(4, .i8).?;
    pub const vec8xi8 = vectorTypeName(8, .i8).?;
    pub const vec16xi8 = vectorTypeName(16, .i8).?;
    pub const vec2xi16 = vectorTypeName(2, .i16).?;
    pub const vec4xi16 = vectorTypeName(4, .i16).?;
    pub const vec8xi16 = vectorTypeName(8, .i16).?;
    pub const vec16xi16 = vectorTypeName(16, .i16).?;
    pub const vec2xi32 = vectorTypeName(2, .i32).?;
    pub const vec4xi32 = vectorTypeName(4, .i32).?;
    pub const vec8xi32 = vectorTypeName(8, .i32).?;
    pub const vec16xi32 = vectorTypeName(16, .i32).?;
    pub const vec2xi64 = vectorTypeName(2, .i64).?;
    pub const vec4xi64 = vectorTypeName(4, .i64).?;
    pub const vec8xi64 = vectorTypeName(8, .i64).?;
    pub const vec2xu8 = vectorTypeName(2, .u8).?;
    pub const vec4xu8 = vectorTypeName(4, .u8).?;
    pub const vec8xu8 = vectorTypeName(8, .u8).?;
    pub const vec16xu8 = vectorTypeName(16, .u8).?;
    pub const vec2xu16 = vectorTypeName(2, .u16).?;
    pub const vec4xu16 = vectorTypeName(4, .u16).?;
    pub const vec8xu16 = vectorTypeName(8, .u16).?;
    pub const vec16xu16 = vectorTypeName(16, .u16).?;
    pub const vec2xu32 = vectorTypeName(2, .u32).?;
    pub const vec4xu32 = vectorTypeName(4, .u32).?;
    pub const vec8xu32 = vectorTypeName(8, .u32).?;
    pub const vec16xu32 = vectorTypeName(16, .u32).?;
    pub const vec2xu64 = vectorTypeName(2, .u64).?;
    pub const vec4xu64 = vectorTypeName(4, .u64).?;
    pub const vec8xu64 = vectorTypeName(8, .u64).?;
    pub const vec2xf16 = vectorTypeName(2, .f16).?;
    pub const vec4xf16 = vectorTypeName(4, .f16).?;
    pub const vec8xf16 = vectorTypeName(8, .f16).?;
    pub const vec16xf16 = vectorTypeName(16, .f16).?;
    pub const vec2xbf16 = vectorTypeName(2, .bf16).?;
    pub const vec4xbf16 = vectorTypeName(4, .bf16).?;
    pub const vec8xbf16 = vectorTypeName(8, .bf16).?;
    pub const vec16xbf16 = vectorTypeName(16, .bf16).?;
    pub const vec2xf32 = vectorTypeName(2, .f32).?;
    pub const vec4xf32 = vectorTypeName(4, .f32).?;
    pub const vec8xf32 = vectorTypeName(8, .f32).?;
    pub const vec16xf32 = vectorTypeName(16, .f32).?;
    pub const vec2xf64 = vectorTypeName(2, .f64).?;
    pub const vec4xf64 = vectorTypeName(4, .f64).?;
    pub const vec8xf64 = vectorTypeName(8, .f64).?;
    pub const vec2xindex = vectorTypeName(2, .index).?;
    pub const vec4xindex = vectorTypeName(4, .index).?;
    pub const vec8xindex = vectorTypeName(8, .index).?;
    pub const vec16xindex = vectorTypeName(16, .index).?;
};

pub const VectorTypeInfo = struct {
    width: u32,
    elem_type_name: []const u8,
};

pub fn parseVectorTypeName(type_name: []const u8) ?VectorTypeInfo {
    const prefix = "arith.vec";
    if (!std.mem.startsWith(u8, type_name, prefix)) return null;
    const rest = type_name[prefix.len..];
    const x_index = std.mem.indexOfScalar(u8, rest, 'x') orelse return null;
    const width_str = rest[0..x_index];
    if (width_str.len == 0) return null;
    const width = std.fmt.parseInt(u32, width_str, 10) catch return null;
    if (width == 0) return null;

    const elem_suffix = rest[x_index + 1 ..];
    const kind = scalarKindFromSuffix(elem_suffix) orelse return null;
    if (vectorTypeName(width, kind)) |canonical| {
        if (!std.mem.eql(u8, type_name, canonical)) return null;
    } else {
        return null;
    }

    return .{ .width = width, .elem_type_name = scalarTypeName(kind) };
}
