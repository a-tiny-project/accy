const std = @import("std");
const math = @import("math.zig");

pub fn fastTan(comptime D: type, value: D.Vector) D.Vector {
    return math.tan(D, value);
}

pub fn fastAtan(comptime D: type, value: D.Vector) D.Vector {
    return math.atan(D, value);
}

pub fn fastAtanPositive(comptime D: type, value: D.Vector) D.Vector {
    return math.atan(D, value);
}

pub fn fastAtan2(comptime D: type, y: D.Vector, x: D.Vector) D.Vector {
    return math.atan2(D, y, x);
}

pub fn fastTanh(comptime D: type, value: D.Vector) D.Vector {
    return math.tanh(D, value);
}

pub fn fastLog(comptime D: type, value: D.Vector) D.Vector {
    return math.log(D, value);
}

pub fn fastExp(comptime D: type, value: D.Vector) D.Vector {
    return math.exp(D, value);
}

pub fn fastExp2(comptime D: type, value: D.Vector) D.Vector {
    return math.exp2(D, value);
}

pub fn fastExpMinusOrZero(comptime D: type, value: D.Vector) D.Vector {
    return flushSubnormals(D, math.exp(D, value));
}

pub fn fastLog2(comptime D: type, value: D.Vector) D.Vector {
    return math.log2(D, value);
}

pub fn fastLog10(comptime D: type, value: D.Vector) D.Vector {
    return math.log10(D, value);
}

pub fn fastLog1p(comptime D: type, value: D.Vector) D.Vector {
    return math.log1p(D, value);
}

pub fn fastPow(comptime D: type, base: D.Vector, exponent: D.Vector) D.Vector {
    return math.pow(D, base, exponent);
}

pub fn fastExpNormal(comptime D: type, value: D.Vector) D.Vector {
    return flushSubnormals(D, math.exp(D, value));
}

pub fn fastExp2Normal(comptime D: type, value: D.Vector) D.Vector {
    return flushSubnormals(D, math.exp2(D, value));
}

pub fn fastLogPositiveNormal(comptime D: type, value: D.Vector) D.Vector {
    return math.log(D, value);
}

pub fn fastLog2PositiveNormal(comptime D: type, value: D.Vector) D.Vector {
    return math.log2(D, value);
}

pub fn fastLog10PositiveNormal(comptime D: type, value: D.Vector) D.Vector {
    return math.log10(D, value);
}

pub fn fastLog1pPositiveNormal(comptime D: type, value: D.Vector) D.Vector {
    return math.log1p(D, value);
}

pub fn fastPowNormal(comptime D: type, base: D.Vector, exponent: D.Vector) D.Vector {
    return flushSubnormals(D, math.pow(D, base, exponent));
}

fn flushSubnormals(comptime D: type, value: D.Vector) D.Vector {
    var result = value;
    inline for (0..D.lane_count) |index| {
        if (@abs(result[index]) < std.math.floatMin(D.Lane)) {
            result[index] = std.math.copysign(@as(D.Lane, 0), result[index]);
        }
    }
    return result;
}
