const base = @import("../root.zig").base;

const DType = base.DType;
const kernel = base.kernel;

const uniform_one_bits: u32 = 0x3F800000;
const uniform_mantissa_shift: u5 = 9;

pub fn uniformFromBits(bits: u32) f32 {
    const filled = (bits >> uniform_mantissa_shift) | uniform_one_bits;
    return @as(f32, @bitCast(filled)) - 1.0;
}

pub fn randomDTypeSupported(dtype: DType) bool {
    return switch (dtype) {
        .f32, .i32 => true,
        else => false,
    };
}

pub fn ceilDiv(numerator: u64, denominator: u64) u64 {
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

pub fn wordConstant(k: anytype, word: u32) !kernel.Value {
    return k.constantInt(.i32, @as(i32, @bitCast(word)));
}

pub fn outputWord(k: anytype, comptime dtype: DType, word: kernel.Value) !kernel.Value {
    return switch (dtype) {
        .i32 => word,
        .f32 => blk: {
            const shifted = try k.ushr(word, try k.constantInt(.i32, uniform_mantissa_shift));
            const filled = try k.or_(shifted, try wordConstant(k, uniform_one_bits));
            const unit = try k.bitcast(filled, .f32);
            break :blk try k.sub(unit, try k.constantFloat(.f32, 1.0));
        },
        else => @compileError("random kernels support dtype .i32 or .f32"),
    };
}

fn store_guarded_active(inner_builder: anytype, ctx: anytype) !void {
    try ctx.args.param(.dst).store(inner_builder, ctx.out, ctx.element);
}

pub fn storeGuarded(
    k: anytype,
    args: anytype,
    out: kernel.Value,
    element: kernel.Value,
    count: kernel.Value,
) !void {
    const active = try k.compare(.lt, element, count);
    try k.guardDo(active, .{ .args = args, .out = out, .element = element }, store_guarded_active);
}
