const common = @import("common.zig");
const scalar = @import("scalar.zig");

const builder = common.builder;
const DType = common.DType;
const TypedValue = common.TypedValue;

pub fn globalIdValue(owner: anytype, comptime dtype: DType, dim: builder.Dimension) !TypedValue(dtype) {
    return scalar.castValue(owner, try owner.globalId(dim), dtype);
}

pub fn threadIdValue(owner: anytype, comptime dtype: DType, dim: builder.Dimension) !TypedValue(dtype) {
    return scalar.castValue(owner, try owner.threadId(dim), dtype);
}

pub fn blockIdValue(owner: anytype, comptime dtype: DType, dim: builder.Dimension) !TypedValue(dtype) {
    return scalar.castValue(owner, try owner.blockId(dim), dtype);
}

pub fn blockDimValue(owner: anytype, comptime dtype: DType, dim: builder.Dimension) !TypedValue(dtype) {
    return scalar.castValue(owner, try owner.blockDim(dim), dtype);
}

pub fn gridDimValue(owner: anytype, comptime dtype: DType, dim: builder.Dimension) !TypedValue(dtype) {
    return scalar.castValue(owner, try owner.gridDim(dim), dtype);
}

pub fn laneIdValue(owner: anytype, comptime dtype: DType) !TypedValue(dtype) {
    return scalar.castValue(owner, try owner.laneId(), dtype);
}

pub fn warpIdValue(owner: anytype, comptime dtype: DType) !TypedValue(dtype) {
    return scalar.castValue(owner, try owner.warpId(), dtype);
}
