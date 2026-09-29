const common = @import("common.zig");

const builder = common.builder;
const DType = common.DType;

pub fn add(owner: anytype, lhs: builder.Value, rhs: builder.Value) !builder.Value {
    return owner.body.add(lhs, rhs);
}

pub fn sub(owner: anytype, lhs: builder.Value, rhs: builder.Value) !builder.Value {
    return owner.body.sub(lhs, rhs);
}

pub fn mul(owner: anytype, lhs: builder.Value, rhs: builder.Value) !builder.Value {
    return owner.body.mul(lhs, rhs);
}

pub fn umulhi(owner: anytype, lhs: builder.Value, rhs: builder.Value) !builder.Value {
    return owner.body.umulhi(lhs, rhs);
}

pub fn div(owner: anytype, lhs: builder.Value, rhs: builder.Value) !builder.Value {
    return owner.body.div(lhs, rhs);
}

pub fn min(owner: anytype, lhs: builder.Value, rhs: builder.Value) !builder.Value {
    return owner.body.min(lhs, rhs);
}

pub fn max(owner: anytype, lhs: builder.Value, rhs: builder.Value) !builder.Value {
    return owner.body.max(lhs, rhs);
}

pub fn neg(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.neg(input);
}

pub fn abs(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.abs(input);
}

pub fn splatVector(owner: anytype, input: builder.Value, width: u32) !builder.Value {
    return owner.body.splatVector(input, width);
}

pub fn extractLane(owner: anytype, vector: builder.Value, lane: u32, dtype: DType) !builder.Value {
    return owner.body.extractLane(vector, lane, dtype);
}

pub fn insertLane(owner: anytype, vector: builder.Value, lane_value: builder.Value, lane: u32) !builder.Value {
    return owner.body.insertLane(vector, lane_value, lane);
}

pub fn packVector(owner: anytype, lanes: [4]builder.Value) !builder.Value {
    return owner.body.packVector(lanes);
}

pub fn shuffleVector(owner: anytype, input: builder.Value, indices: []const i64) !builder.Value {
    return owner.body.shuffleVector(input, indices);
}
