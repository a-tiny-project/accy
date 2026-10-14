const random = @import("../root.zig");

const shared = random.base;
const block = random.block;
const model = @import("model.zig");

const std = shared.std;
const DType = shared.DType;
const kernel = shared.kernel;

const Threefry = model.Threefry;
const threefry_lanes = block.threefry_lanes;
const threefryWords = block.threefryWords;
const outputWord = block.outputWord;
const storeGuarded = block.storeGuarded;

fn threefryRuntimeBody(k: anytype, comptime dtype: DType, spec: Threefry, args: anytype) !void {
    const generator = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const lanes_extent = try k.constantIndex(threefry_lanes);
    const base = try k.mul(generator, lanes_extent);
    const words = try threefryWords(
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
fn threefryFamilySchedule(instance: Threefry) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}
fn threefry_runtime_family_body_f32(k: anytype, spec: Threefry, args: anytype) !void {
    try threefryRuntimeBody(k, .f32, spec, args);
}
fn threefry_runtime_family_body_i32(k: anytype, spec: Threefry, args: anytype) !void {
    try threefryRuntimeBody(k, .i32, spec, args);
}

fn threefryRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_random_threefry_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .count = kernel.scalar(.i32),
            .seed_lo = kernel.scalar(.i32),
            .seed_hi = kernel.scalar(.i32),
        },
        .Instance = Threefry,
        .schedule = threefryFamilySchedule,
        .body = switch (dtype) {
            .f32 => threefry_runtime_family_body_f32,
            .i32 => threefry_runtime_family_body_i32,
            else => @compileError("Threefry runtime supports dtype .f32 or .i32"),
        },
    });
}

pub const ThreefryRuntimeFamilyF32 = threefryRuntimeFamily(.f32);
pub const ThreefryRuntimeFamilyI32 = threefryRuntimeFamily(.i32);
