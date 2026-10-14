const random = @import("../root.zig");
const types = @import("types.zig");

const base = random.base;
const block = random.block;

const std = base.std;
const DType = base.DType;
const kernel = base.kernel;

const Squares = types.Squares;
const zeroExtendWord = block.zeroExtendWord;
const squaresWord = block.squaresWord;
const squaresKeyValue = block.squaresKeyValue;
const outputWord = block.outputWord;

fn squares_runtime_body_active(inner_builder: anytype, ctx: anytype) !void {
    const key = try squaresKeyValue(
        inner_builder,
        ctx.args.param(.key_lo).raw(),
        ctx.args.param(.key_hi).raw(),
    );
    const counter = try zeroExtendWord(inner_builder, try inner_builder.cast(ctx.element, .i32));
    const word = try squaresWord(inner_builder, counter, key);
    const out = try outputWord(inner_builder, ctx.dtype, word);
    try ctx.args.param(.dst).store(inner_builder, out, ctx.element);
}

fn squaresRuntimeBody(k: anytype, comptime dtype: DType, spec: Squares, args: anytype) !void {
    _ = spec;
    const element = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const active = try k.compare(.lt, element, count);
    try k.guardDo(
        active,
        .{ .args = args, .element = element, .dtype = dtype },
        squares_runtime_body_active,
    );
}

fn squaresFamilySchedule(instance: Squares) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn squares_runtime_family_body_f32(k: anytype, spec: Squares, args: anytype) !void {
    try squaresRuntimeBody(k, .f32, spec, args);
}

fn squares_runtime_family_body_i32(k: anytype, spec: Squares, args: anytype) !void {
    try squaresRuntimeBody(k, .i32, spec, args);
}

fn squaresRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_random_squares_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .count = kernel.scalar(.i32),
            .key_lo = kernel.scalar(.i32),
            .key_hi = kernel.scalar(.i32),
        },
        .Instance = Squares,
        .schedule = squaresFamilySchedule,
        .body = switch (dtype) {
            .f32 => squares_runtime_family_body_f32,
            .i32 => squares_runtime_family_body_i32,
            else => @compileError("Squares runtime supports dtype .f32 or .i32"),
        },
    });
}

pub const SquaresRuntimeFamilyF32 = squaresRuntimeFamily(.f32);
pub const SquaresRuntimeFamilyI32 = squaresRuntimeFamily(.i32);
