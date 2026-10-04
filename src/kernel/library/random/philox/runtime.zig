const random = @import("../root.zig");

const shared = random.base;
const block = random.block;
const model = @import("model.zig");

const std = shared.std;
const DType = shared.DType;
const kernel = shared.kernel;

const Philox = model.Philox;
const philox_lanes = block.philox_lanes;
const philoxWords = block.philoxWords;
const outputWord = block.outputWord;
const storeGuarded = block.storeGuarded;

fn philoxRuntimeBody(k: anytype, comptime dtype: DType, spec: Philox, args: anytype) !void {
    const generator = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const lanes_extent = try k.constantIndex(philox_lanes);
    const base = try k.mul(generator, lanes_extent);
    const words = try philoxWords(
        k,
        spec.rounds,
        try k.cast(generator, .i32),
        try k.constantInt(.i32, 0),
        args.param(.seed_lo).raw(),
        args.param(.seed_hi).raw(),
    );
    for (words, 0..) |word, lane| {
        const element = try k.add(base, try k.constantIndex(@intCast(lane)));
        const out = try outputWord(k, dtype, word);
        try storeGuarded(k, args, out, element, count);
    }
}
fn philoxFamilySchedule(instance: Philox) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}
fn philox_runtime_family_body_f32(k: anytype, spec: Philox, args: anytype) !void {
    try philoxRuntimeBody(k, .f32, spec, args);
}
fn philox_runtime_family_body_i32(k: anytype, spec: Philox, args: anytype) !void {
    try philoxRuntimeBody(k, .i32, spec, args);
}

fn philoxRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_random_philox_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .count = kernel.scalar(.i32),
            .seed_lo = kernel.scalar(.i32),
            .seed_hi = kernel.scalar(.i32),
        },
        .Instance = Philox,
        .schedule = philoxFamilySchedule,
        .body = switch (dtype) {
            .f32 => philox_runtime_family_body_f32,
            .i32 => philox_runtime_family_body_i32,
            else => @compileError("Philox runtime supports dtype .f32 or .i32"),
        },
    });
}

pub const PhiloxRuntimeFamilyF32 = philoxRuntimeFamily(.f32);
pub const PhiloxRuntimeFamilyI32 = philoxRuntimeFamily(.i32);
