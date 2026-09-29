const random = @import("../../root.zig");

const base = random.base;
const block = random.block;
const fold = @import("../root.zig");
const common = fold.common;
const types = @import("types.zig");

const std = base.std;
const DType = base.DType;
const kernel = base.kernel;

const PhiloxFold = types.PhiloxFold;
const philoxWords = block.philoxWords;
const foldInitial = common.foldInitial;
const foldCombine = common.foldCombine;

fn philox_fold_runtime_body_active(inner_builder: anytype, ctx: anytype) !void {
    const zero = try inner_builder.constantIndex(0);
    const one = try inner_builder.constantIndex(1);
    const initial = try foldInitial(inner_builder, ctx.dtype);
    const counter = try inner_builder.cast(ctx.output, .i32);
    const folded = try inner_builder.fold(zero, ctx.samples, one, initial, .{
        .spec = ctx.spec,
        .args = ctx.args,
        .counter = counter,
        .dtype = ctx.dtype,
    }, philox_fold_runtime_body_apply);
    try ctx.args.param(.dst).store(inner_builder, folded, ctx.output);
}

fn philox_fold_runtime_body_apply(fold_builder: anytype, sample: kernel.Value, current: kernel.Value, fold_ctx: anytype) !kernel.Value {
    const words = try philoxWords(
        fold_builder,
        fold_ctx.spec.rounds,
        fold_ctx.counter,
        try fold_builder.cast(sample, .i32),
        fold_ctx.args.param(.seed_lo).raw(),
        fold_ctx.args.param(.seed_hi).raw(),
    );
    var accumulator = current;
    for (words) |word| accumulator = try foldCombine(fold_builder, fold_ctx.dtype, accumulator, word);
    return accumulator;
}

fn philoxFoldRuntimeBody(k: anytype, comptime dtype: DType, spec: PhiloxFold, args: anytype) !void {
    const output = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const samples = try k.castIndex(args.param(.samples).raw());
    const active = try k.compare(.lt, output, count);
    try k.guardDo(active, .{ .spec = spec, .args = args, .output = output, .samples = samples, .dtype = dtype }, philox_fold_runtime_body_active);
}

fn philoxFoldFamilySchedule(instance: PhiloxFold) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn philox_fold_runtime_family_body_f32(k: anytype, spec: PhiloxFold, args: anytype) !void {
    try philoxFoldRuntimeBody(k, .f32, spec, args);
}

fn philox_fold_runtime_family_body_i32(k: anytype, spec: PhiloxFold, args: anytype) !void {
    try philoxFoldRuntimeBody(k, .i32, spec, args);
}

fn philoxFoldRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_random_philox_fold_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .count = kernel.scalar(.i32),
            .samples = kernel.scalar(.i32),
            .seed_lo = kernel.scalar(.i32),
            .seed_hi = kernel.scalar(.i32),
        },
        .Instance = PhiloxFold,
        .schedule = philoxFoldFamilySchedule,
        .body = switch (dtype) {
            .f32 => philox_fold_runtime_family_body_f32,
            .i32 => philox_fold_runtime_family_body_i32,
            else => @compileError("Philox fold runtime supports dtype .f32 or .i32"),
        },
    });
}

pub const PhiloxFoldRuntimeFamilyF32 = philoxFoldRuntimeFamily(.f32);
pub const PhiloxFoldRuntimeFamilyI32 = philoxFoldRuntimeFamily(.i32);
