const common = @import("common.zig");

const builder = common.builder;
const DType = common.DType;

pub fn constantInt(owner: anytype, dtype: DType, value: i64) !builder.Value {
    return owner.body.constantInt(dtype, value);
}

pub fn constantIndex(owner: anytype, value: i64) !builder.Value {
    return owner.body.constantIndex(value);
}

pub fn constantFloat(owner: anytype, dtype: DType, value: f64) !builder.Value {
    return owner.body.constantFloat(dtype, value);
}

pub fn constantBool(owner: anytype, value: bool) !builder.Value {
    return owner.body.constantBool(value);
}
