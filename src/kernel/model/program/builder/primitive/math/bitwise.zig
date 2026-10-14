const common = @import("common.zig");

const builder = common.builder;

pub fn and_(owner: anytype, lhs: builder.Value, rhs: builder.Value) !builder.Value {
    return owner.body.and_(lhs, rhs);
}

pub fn or_(owner: anytype, lhs: builder.Value, rhs: builder.Value) !builder.Value {
    return owner.body.or_(lhs, rhs);
}

pub fn xor(owner: anytype, lhs: builder.Value, rhs: builder.Value) !builder.Value {
    return owner.body.xor(lhs, rhs);
}

pub fn not(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.not(input);
}

pub fn popcount(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.popcount(input);
}

pub fn shl(owner: anytype, value: builder.Value, shift: builder.Value) !builder.Value {
    return owner.body.shl(value, shift);
}

pub fn shr(owner: anytype, value: builder.Value, shift: builder.Value) !builder.Value {
    return owner.body.shr(value, shift);
}

pub fn ushr(owner: anytype, value: builder.Value, shift: builder.Value) !builder.Value {
    return owner.body.ushr(value, shift);
}
