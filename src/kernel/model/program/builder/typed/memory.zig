const common = @import("common.zig");
const scalar = @import("scalar.zig");

const DType = common.DType;
const TypedValue = common.TypedValue;
const BufferView = common.BufferView;

pub fn linearIndexValue(owner: anytype, index: anytype, comptime dtype: DType) !TypedValue(dtype) {
    return scalar.castValue(owner, try owner.linearIndex(index), dtype);
}

pub fn sharedBufferView(owner: anytype, comptime dtype: DType, size: u64) !BufferView(dtype) {
    return scalar.bufferView(owner, dtype, try owner.sharedBuffer(dtype, size));
}
