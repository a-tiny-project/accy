const common = @import("common.zig");

const builder = common.builder;

pub fn sqrt(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.sqrt(input);
}

pub fn exp(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.exp(input);
}

pub fn log(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.log(input);
}

pub fn tanh(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.tanh(input);
}

pub fn sin(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.sin(input);
}

pub fn cos(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.cos(input);
}

pub fn tan(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.tan(input);
}

pub fn floor(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.floor(input);
}

pub fn round(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.round(input);
}

pub fn trunc(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.trunc(input);
}

pub fn tf32Round(owner: anytype, input: builder.Value) !builder.Value {
    return owner.body.tf32Round(input);
}

pub fn pow(owner: anytype, base: builder.Value, exponent: builder.Value) !builder.Value {
    return owner.body.pow(base, exponent);
}

pub fn atan2(owner: anytype, y: builder.Value, x: builder.Value) !builder.Value {
    return owner.body.atan2(y, x);
}

pub fn fma(owner: anytype, a: builder.Value, b: builder.Value, c: builder.Value) !builder.Value {
    return owner.body.fma(a, b, c);
}
