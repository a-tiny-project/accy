const common = @import("common.zig");

const builder = common.builder;
const DType = common.DType;
const Vec2 = common.Vec2;
const Vec3 = common.Vec3;
const TypedValue = common.TypedValue;
const TypedVec2 = common.TypedVec2;
const TypedVec3 = common.TypedVec3;

pub fn vec2(owner: anytype, x: builder.Value, y: builder.Value) Vec2 {
    _ = owner;
    return Vec2.init(x, y);
}

pub fn typedVec2(owner: anytype, comptime dtype: DType, x: anytype, y: anytype) !TypedVec2(dtype) {
    return TypedVec2(dtype).init(try TypedValue(dtype).from(owner, x), try TypedValue(dtype).from(owner, y));
}

pub fn vec3(owner: anytype, x: builder.Value, y: builder.Value, z: builder.Value) Vec3 {
    _ = owner;
    return Vec3.init(x, y, z);
}

pub fn typedVec3(owner: anytype, comptime dtype: DType, x: anytype, y: anytype, z: anytype) !TypedVec3(dtype) {
    return TypedVec3(dtype).init(try TypedValue(dtype).from(owner, x), try TypedValue(dtype).from(owner, y), try TypedValue(dtype).from(owner, z));
}

pub fn splat2(owner: anytype, value: builder.Value) Vec2 {
    _ = owner;
    return Vec2.splat(value);
}

pub fn typedSplat2(owner: anytype, comptime dtype: DType, value: anytype) !TypedVec2(dtype) {
    return TypedVec2(dtype).splat(try TypedValue(dtype).from(owner, value));
}

pub fn splat3(owner: anytype, value: builder.Value) Vec3 {
    _ = owner;
    return Vec3.splat(value);
}

pub fn typedSplat3(owner: anytype, comptime dtype: DType, value: anytype) !TypedVec3(dtype) {
    return TypedVec3(dtype).splat(try TypedValue(dtype).from(owner, value));
}
