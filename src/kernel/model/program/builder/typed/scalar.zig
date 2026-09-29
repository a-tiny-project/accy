const common = @import("common.zig");

const builder = common.builder;
const DType = common.DType;
const TypedValue = common.TypedValue;
const BufferView = common.BufferView;
const typed = common.typed;

pub fn typedArgument(owner: anytype, comptime dtype: DType, index: usize) TypedValue(dtype) {
    return typedValue(owner, dtype, owner.argument(index));
}

pub fn typedValue(owner: anytype, comptime dtype: DType, value: builder.Value) TypedValue(dtype) {
    _ = owner;
    return TypedValue(dtype).init(value);
}

pub fn castValue(owner: anytype, input: anytype, comptime dtype: DType) !TypedValue(dtype) {
    return typedValue(owner, dtype, try owner.cast(typed.raw(input), dtype));
}

pub fn bufferArgument(owner: anytype, comptime dtype: DType, index: usize) BufferView(dtype) {
    return bufferView(owner, dtype, owner.argument(index));
}

pub fn bufferView(owner: anytype, comptime dtype: DType, value: builder.Value) BufferView(dtype) {
    _ = owner;
    return BufferView(dtype).init(value);
}
