const common = @import("common.zig");

const builder = common.builder;
const DType = common.DType;

pub fn bitcast(owner: anytype, input: builder.Value, dtype: DType) !builder.Value {
    return owner.body.bitcast(input, dtype);
}

pub fn cast(owner: anytype, input: builder.Value, dtype: DType) !builder.Value {
    return owner.body.cast(input, dtype);
}

pub fn castIndex(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.castIndex(input);
}
