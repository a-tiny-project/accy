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

test "math symbol names remain host-linker names" {
    const expected = [_][]const u8{
        "sinf",
        "cosf",
        "tanf",
        "expf",
        "logf",
        "tanhf",
        "floorf",
        "powf",
        "fmaf",
        "sin",
        "cos",
        "tan",
        "exp",
        "log",
        "tanh",
        "floor",
        "pow",
        "fma",
    };

    try std.testing.expectEqual(expected.len, symbols.len);
    for (symbols, expected) |symbol, name| {
        try std.testing.expectEqualStrings(name, symbol.name());
    }
}

test "math symbol addresses call sys implementations" {
    const Unary32 = *const fn (f32) callconv(.c) f32;
    const Unary64 = *const fn (f64) callconv(.c) f64;
    const Binary32 = *const fn (f32, f32) callconv(.c) f32;
    const Binary64 = *const fn (f64, f64) callconv(.c) f64;
    const Ternary32 = *const fn (f32, f32, f32) callconv(.c) f32;
    const Ternary64 = *const fn (f64, f64, f64) callconv(.c) f64;

    const x32: f32 = 0.5;
    const y32: f32 = 3.0;
    const z32: f32 = 0.25;
    const x64: f64 = 0.5;
    const y64: f64 = 3.0;
    const z64: f64 = 0.25;

    const sinf_ptr: Unary32 = @ptrFromInt(MathSymbol.sinf.address());
    const cosf_ptr: Unary32 = @ptrFromInt(MathSymbol.cosf.address());
    const tanf_ptr: Unary32 = @ptrFromInt(MathSymbol.tanf.address());
    const expf_ptr: Unary32 = @ptrFromInt(MathSymbol.expf.address());
    const logf_ptr: Unary32 = @ptrFromInt(MathSymbol.logf.address());
    const tanhf_ptr: Unary32 = @ptrFromInt(MathSymbol.tanhf.address());
    const floorf_ptr: Unary32 = @ptrFromInt(MathSymbol.floorf.address());
    const powf_ptr: Binary32 = @ptrFromInt(MathSymbol.powf.address());
    const fmaf_ptr: Ternary32 = @ptrFromInt(MathSymbol.fmaf.address());
    const sin_ptr: Unary64 = @ptrFromInt(MathSymbol.sin.address());
    const cos_ptr: Unary64 = @ptrFromInt(MathSymbol.cos.address());
    const tan_ptr: Unary64 = @ptrFromInt(MathSymbol.tan.address());
    const exp_ptr: Unary64 = @ptrFromInt(MathSymbol.exp.address());
    const log_ptr: Unary64 = @ptrFromInt(MathSymbol.log.address());
    const tanh_ptr: Unary64 = @ptrFromInt(MathSymbol.tanh.address());
    const floor_ptr: Unary64 = @ptrFromInt(MathSymbol.floor.address());
    const pow_ptr: Binary64 = @ptrFromInt(MathSymbol.pow.address());
    const fma_ptr: Ternary64 = @ptrFromInt(MathSymbol.fma.address());

    try std.testing.expectApproxEqAbs(@sin(x32), sinf_ptr(x32), 0.000001);
    try std.testing.expectApproxEqAbs(@cos(x32), cosf_ptr(x32), 0.000001);
    try std.testing.expectApproxEqAbs(@tan(x32), tanf_ptr(x32), 0.000001);
    try std.testing.expectApproxEqAbs(@exp(x32), expf_ptr(x32), 0.000001);
    try std.testing.expectApproxEqAbs(@log(x32), logf_ptr(x32), 0.000001);
    try std.testing.expectApproxEqAbs(std.math.tanh(x32), tanhf_ptr(x32), 0.000001);
    try std.testing.expectApproxEqAbs(@floor(x32), floorf_ptr(x32), 0.000001);
    try std.testing.expectApproxEqAbs(std.math.pow(f32, x32, y32), powf_ptr(x32, y32), 0.000001);
    try std.testing.expectApproxEqAbs(@mulAdd(f32, x32, y32, z32), fmaf_ptr(x32, y32, z32), 0.000001);
    try std.testing.expectApproxEqAbs(@sin(x64), sin_ptr(x64), 0.000000000001);
    try std.testing.expectApproxEqAbs(@cos(x64), cos_ptr(x64), 0.000000000001);
    try std.testing.expectApproxEqAbs(@tan(x64), tan_ptr(x64), 0.000000000001);
    try std.testing.expectApproxEqAbs(@exp(x64), exp_ptr(x64), 0.000000000001);
    try std.testing.expectApproxEqAbs(@log(x64), log_ptr(x64), 0.000000000001);
    try std.testing.expectApproxEqAbs(std.math.tanh(x64), tanh_ptr(x64), 0.000000000001);
    try std.testing.expectApproxEqAbs(@floor(x64), floor_ptr(x64), 0.000000000001);
    try std.testing.expectApproxEqAbs(std.math.pow(f64, x64, y64), pow_ptr(x64, y64), 0.000000000001);
    try std.testing.expectApproxEqAbs(@mulAdd(f64, x64, y64, z64), fma_ptr(x64, y64, z64), 0.000000000001);
}
