const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const required_capabilities = capabilities.pure();

pub const MathSymbol = enum {
    sinf,
    cosf,
    tanf,
    expf,
    logf,
    tanhf,
    floorf,
    powf,
    fmaf,
    sin,
    cos,
    tan,
    exp,
    log,
    tanh,
    floor,
    pow,
    fma,

    pub fn name(self: MathSymbol) []const u8 {
        return @tagName(self);
    }

    pub fn address(self: MathSymbol) usize {
        return switch (self) {
            .sinf => @intFromPtr(&mathSinf),
            .cosf => @intFromPtr(&mathCosf),
            .tanf => @intFromPtr(&mathTanf),
            .expf => @intFromPtr(&mathExpf),
            .logf => @intFromPtr(&mathLogf),
            .tanhf => @intFromPtr(&mathTanhf),
            .floorf => @intFromPtr(&mathFloorf),
            .powf => @intFromPtr(&mathPowf),
            .fmaf => @intFromPtr(&mathFmaf),
            .sin => @intFromPtr(&mathSin),
            .cos => @intFromPtr(&mathCos),
            .tan => @intFromPtr(&mathTan),
            .exp => @intFromPtr(&mathExp),
            .log => @intFromPtr(&mathLog),
            .tanh => @intFromPtr(&mathTanh),
            .floor => @intFromPtr(&mathFloor),
            .pow => @intFromPtr(&mathPow),
            .fma => @intFromPtr(&mathFma),
        };
    }
};

pub const symbols = [_]MathSymbol{
    .sinf,
    .cosf,
    .tanf,
    .expf,
    .logf,
    .tanhf,
    .floorf,
    .powf,
    .fmaf,
    .sin,
    .cos,
    .tan,
    .exp,
    .log,
    .tanh,
    .floor,
    .pow,
    .fma,
};

fn mathSinf(x: f32) callconv(.c) f32 {
    return @sin(x);
}

fn mathCosf(x: f32) callconv(.c) f32 {
    return @cos(x);
}

fn mathTanf(x: f32) callconv(.c) f32 {
    return @tan(x);
}

fn mathExpf(x: f32) callconv(.c) f32 {
    return @exp(x);
}

fn mathLogf(x: f32) callconv(.c) f32 {
    return @log(x);
}

fn mathTanhf(x: f32) callconv(.c) f32 {
    return std.math.tanh(x);
}

fn mathFloorf(x: f32) callconv(.c) f32 {
    return @floor(x);
}

fn mathPowf(x: f32, y: f32) callconv(.c) f32 {
    return std.math.pow(f32, x, y);
}

fn mathFmaf(x: f32, y: f32, z: f32) callconv(.c) f32 {
    return @mulAdd(f32, x, y, z);
}

fn mathSin(x: f64) callconv(.c) f64 {
    return @sin(x);
}

fn mathCos(x: f64) callconv(.c) f64 {
    return @cos(x);
}

fn mathTan(x: f64) callconv(.c) f64 {
    return @tan(x);
}

fn mathExp(x: f64) callconv(.c) f64 {
    return @exp(x);
}

fn mathLog(x: f64) callconv(.c) f64 {
    return @log(x);
}

fn mathTanh(x: f64) callconv(.c) f64 {
    return std.math.tanh(x);
}

fn mathFloor(x: f64) callconv(.c) f64 {
    return @floor(x);
}

fn mathPow(x: f64, y: f64) callconv(.c) f64 {
    return std.math.pow(f64, x, y);
}

fn mathFma(x: f64, y: f64, z: f64) callconv(.c) f64 {
    return @mulAdd(f64, x, y, z);
}
