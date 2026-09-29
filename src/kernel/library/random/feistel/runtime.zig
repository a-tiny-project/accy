const random = @import("../root.zig");
const model = @import("model.zig");

const shared = random.base;
const block = random.block;

const std = shared.std;
const DType = shared.DType;
const kernel = shared.kernel;

const Feistel = model.Feistel;
const philoxWords = block.philoxWords;
const philoxBlock = block.philoxBlock;
const wordConstant = block.wordConstant;

pub fn feistelPermuteReference(index: u32, rounds: u32, seed: u64, bits: u6) u32 {
    const half_bits: u5 = @intCast(bits / 2);
    const mask: u32 = (@as(u32, 1) << half_bits) - 1;
    var left: u32 = index >> half_bits;
    var right: u32 = index & mask;
    const seed_lo: u32 = @truncate(seed);
    const seed_hi: u32 = @truncate(seed >> 32);
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        const mixed = philoxBlock(2, .{ right, round, 0, 0 }, .{ seed_lo, seed_hi })[0] & mask;
        const next_right = left ^ mixed;
        left = right;
        right = next_right;
    }
    return (left << half_bits) | right;
}

fn feistelPermuteValue(k: anytype, spec: Feistel, value: kernel.Value, seed_lo: kernel.Value, seed_hi: kernel.Value) !kernel.Value {
    const bits = spec.domainBits().?;
    const half_bits: u5 = @intCast(bits / 2);
    const mask_value = (@as(u32, 1) << half_bits) - 1;
    const shift = try k.constantInt(.i32, half_bits);
    const mask = try wordConstant(k, mask_value);
    var left = try k.ushr(value, shift);
    var right = try k.and_(value, mask);
    var round: u32 = 0;
    while (round < spec.rounds) : (round += 1) {
        const round_value = try k.constantInt(.i32, @intCast(round));
        const words = try philoxWords(k, 2, right, round_value, seed_lo, seed_hi);
        const mixed = try k.and_(words[0], mask);
        const next_right = try k.xor(left, mixed);
        left = right;
        right = next_right;
    }
    return k.or_(try k.shl(left, shift), right);
}

fn feistel_runtime_body_active(inner_builder: anytype, ctx: anytype) !void {
    const source = try inner_builder.cast(ctx.element, .i32);
    const out = try feistelPermuteValue(
        inner_builder,
        ctx.spec,
        source,
        ctx.args.param(.seed_lo).raw(),
        ctx.args.param(.seed_hi).raw(),
    );
    try ctx.args.param(.dst).store(inner_builder, out, ctx.element);
}

fn feistelRuntimeBody(k: anytype, comptime dtype: DType, spec: Feistel, args: anytype) !void {
    if (comptime dtype != .i32) @compileError("feistel permutation supports dtype .i32");
    const element = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const active = try k.compare(.lt, element, count);
    try k.guardDo(active, .{ .args = args, .element = element, .spec = spec }, feistel_runtime_body_active);
}

fn feistelFamilySchedule(instance: Feistel) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn feistel_runtime_family_body_i32(k: anytype, spec: Feistel, args: anytype) !void {
    try feistelRuntimeBody(k, .i32, spec, args);
}

fn feistelRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint("accy_kernel_random_feistel_runtime_{s}", .{dtype.name()}),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .count = kernel.scalar(.i32),
            .seed_lo = kernel.scalar(.i32),
            .seed_hi = kernel.scalar(.i32),
        },
        .Instance = Feistel,
        .schedule = feistelFamilySchedule,
        .body = switch (dtype) {
            .i32 => feistel_runtime_family_body_i32,
            else => @compileError("feistel runtime supports dtype .i32"),
        },
    });
}

pub const FeistelRuntimeFamilyI32 = feistelRuntimeFamily(.i32);
