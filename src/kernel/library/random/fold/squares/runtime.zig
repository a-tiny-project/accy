const random = @import("../../root.zig");

const base = random.base;
const block = random.block;
const fold = @import("../root.zig");
const common = fold.common;
const types = @import("types.zig");

const std = base.std;
const DType = base.DType;
const kernel = base.kernel;

const SquaresFold = types.SquaresFold;
const zeroExtendWord = block.zeroExtendWord;
const squaresWord = block.squaresWord;
const squaresKeyValue = block.squaresKeyValue;
const foldInitial = common.foldInitial;
const foldCombine = common.foldCombine;

fn squares_fold_runtime_body_active(inner_builder: anytype, ctx: anytype) !void {
    const zero = try inner_builder.constantIndex(0);
    const one = try inner_builder.constantIndex(1);
    const initial = try foldInitial(inner_builder, ctx.dtype);
    const key = try squaresKeyValue(
        inner_builder,
        ctx.args.param(.key_lo).raw(),
        ctx.args.param(.key_hi).raw(),
    );
    const counter_low = try zeroExtendWord(inner_builder, try inner_builder.cast(ctx.output, .i32));
    const folded = try inner_builder.fold(zero, ctx.samples, one, initial, .{
        .args = ctx.args,
        .counter_low = counter_low,
        .key = key,
        .dtype = ctx.dtype,
    }, squares_fold_runtime_body_apply);
    try ctx.args.param(.dst).store(inner_builder, folded, ctx.output);
}

fn squares_fold_runtime_body_apply(fold_builder: anytype, sample: kernel.Value, current: kernel.Value, fold_ctx: anytype) !kernel.Value {
    const half = try fold_builder.constantInt(.i64, 32);
    const sample_wide = try zeroExtendWord(fold_builder, try fold_builder.cast(sample, .i32));
    const counter = try fold_builder.or_(fold_ctx.counter_low, try fold_builder.shl(sample_wide, half));
    const word = try squaresWord(fold_builder, counter, fold_ctx.key);
    return foldCombine(fold_builder, fold_ctx.dtype, current, word);
}

fn squaresFoldRuntimeBody(k: anytype, comptime dtype: DType, spec: SquaresFold, args: anytype) !void {
    _ = spec;
    const output = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const samples = try k.castIndex(args.param(.samples).raw());
    const active = try k.compare(.lt, output, count);
    try k.guardDo(active, .{ .args = args, .output = output, .samples = samples, .dtype = dtype }, squares_fold_runtime_body_active);
}

fn squaresFoldFamilySchedule(instance: SquaresFold) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn squares_fold_runtime_family_body_f32(k: anytype, spec: SquaresFold, args: anytype) !void {
    try squaresFoldRuntimeBody(k, .f32, spec, args);
}

fn squares_fold_runtime_family_body_i32(k: anytype, spec: SquaresFold, args: anytype) !void {
    try squaresFoldRuntimeBody(k, .i32, spec, args);
}

fn squaresFoldRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_random_squares_fold_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .count = kernel.scalar(.i32),
            .samples = kernel.scalar(.i32),
            .key_lo = kernel.scalar(.i32),
            .key_hi = kernel.scalar(.i32),
        },
        .Instance = SquaresFold,
        .schedule = squaresFoldFamilySchedule,
        .body = switch (dtype) {
            .f32 => squares_fold_runtime_family_body_f32,
            .i32 => squares_fold_runtime_family_body_i32,
            else => @compileError("Squares fold runtime supports dtype .f32 or .i32"),
        },
    });
}

pub const SquaresFoldRuntimeFamilyF32 = squaresFoldRuntimeFamily(.f32);
pub const SquaresFoldRuntimeFamilyI32 = squaresFoldRuntimeFamily(.i32);
