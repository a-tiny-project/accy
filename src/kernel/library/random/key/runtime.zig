const random = @import("../root.zig");
const types = @import("types.zig");

const base = random.base;
const block = random.block;

const std = base.std;
const DType = base.DType;
const kernel = base.kernel;
const PhiloxKeySplit = types.PhiloxKeySplit;
const PhiloxKeyUniform = types.PhiloxKeyUniform;
const PhiloxKeyCounterUniform = types.PhiloxKeyCounterUniform;
const philoxWords = block.philoxWords;
const outputWord = block.outputWord;
const storeGuarded = block.storeGuarded;

fn philox_key_split_body_active(inner_builder: anytype, ctx: anytype) !void {
    try ctx.args.param(.dst).store(inner_builder, ctx.out, ctx.element);
}

fn philoxKeySplitBody(k: anytype, spec: PhiloxKeySplit, args: anytype) !void {
    const element = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const seed = try args.param(.key).load(k, try k.constantIndex(0));
    const words = try philoxWords(
        k,
        spec.rounds,
        try k.cast(element, .i32),
        try k.constantInt(.i32, 0),
        seed.lo,
        seed.hi,
    );
    const out = kernel.KeyValue{ .lo = words[0], .hi = words[1] };
    const active = try k.compare(.lt, element, count);
    try k.guardDo(
        active,
        .{ .args = args, .out = out, .element = element },
        philox_key_split_body_active,
    );
}

fn philoxKeyUniformBody(
    k: anytype,
    comptime dtype: DType,
    spec: PhiloxKeyUniform,
    args: anytype,
) !void {
    const element = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const key = try args.param(.keys).load(k, element);
    const words = try philoxWords(
        k,
        spec.rounds,
        try k.constantInt(.i32, 0),
        try k.constantInt(.i32, 0),
        key.lo,
        key.hi,
    );
    const out = try outputWord(k, dtype, words[0]);
    try storeGuarded(k, args, out, element, count);
}

fn philoxKeyCounterUniformBody(
    k: anytype,
    comptime dtype: DType,
    spec: PhiloxKeyCounterUniform,
    args: anytype,
) !void {
    const element = try k.globalId(.x);
    const count = try k.castIndex(args.param(.count).raw());
    const seed = try args.param(.key).load(k, try k.constantIndex(0));
    const counter_value = try args.param(.counter).load(k, try k.constantIndex(0));
    const words = try philoxWords(
        k,
        spec.rounds,
        try k.cast(element, .i32),
        counter_value.raw(),
        seed.lo,
        seed.hi,
    );
    const out = try outputWord(k, dtype, words[0]);
    try storeGuarded(k, args, out, element, count);
}

fn philoxKeySplitSchedule(instance: PhiloxKeySplit) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn philoxKeyUniformSchedule(instance: PhiloxKeyUniform) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn philoxKeyCounterUniformSchedule(
    instance: PhiloxKeyCounterUniform,
) kernel.logical.schedule.ThreadBlocks {
    return kernel.logical.schedule.threadBlocks(.{ .x = instance.threads });
}

fn philox_key_split_runtime_family_body(k: anytype, spec: PhiloxKeySplit, args: anytype) !void {
    try philoxKeySplitBody(k, spec, args);
}

pub const PhiloxKeySplitRuntimeFamily = kernel.logical.Family(.{
    .name = "accy_kernel_random_philox_key_split_runtime_key",
    .parameters = .{
        .dst = kernel.dynamicBuffer(.key),
        .key = kernel.dynamicBuffer(.key),
        .count = kernel.scalar(.i32),
    },
    .Instance = PhiloxKeySplit,
    .schedule = philoxKeySplitSchedule,
    .body = philox_key_split_runtime_family_body,
});

fn philox_key_uniform_runtime_family_body_f32(
    k: anytype,
    spec: PhiloxKeyUniform,
    args: anytype,
) !void {
    try philoxKeyUniformBody(k, .f32, spec, args);
}

fn philox_key_uniform_runtime_family_body_i32(
    k: anytype,
    spec: PhiloxKeyUniform,
    args: anytype,
) !void {
    try philoxKeyUniformBody(k, .i32, spec, args);
}

fn philoxKeyUniformRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_random_philox_key_uniform_runtime_{s}",
            .{dtype.name()},
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .keys = kernel.dynamicBuffer(.key),
            .count = kernel.scalar(.i32),
        },
        .Instance = PhiloxKeyUniform,
        .schedule = philoxKeyUniformSchedule,
        .body = switch (dtype) {
            .f32 => philox_key_uniform_runtime_family_body_f32,
            .i32 => philox_key_uniform_runtime_family_body_i32,
            else => @compileError("Philox key uniform runtime supports dtype .f32 or .i32"),
        },
    });
}

pub const PhiloxKeyUniformRuntimeFamilyF32 = philoxKeyUniformRuntimeFamily(.f32);
pub const PhiloxKeyUniformRuntimeFamilyI32 = philoxKeyUniformRuntimeFamily(.i32);

fn philox_key_counter_uniform_runtime_family_body_f32(
    k: anytype,
    spec: PhiloxKeyCounterUniform,
    args: anytype,
) !void {
    try philoxKeyCounterUniformBody(k, .f32, spec, args);
}

fn philox_key_counter_uniform_runtime_family_body_i32(
    k: anytype,
    spec: PhiloxKeyCounterUniform,
    args: anytype,
) !void {
    try philoxKeyCounterUniformBody(k, .i32, spec, args);
}

fn philoxKeyCounterUniformRuntimeFamily(comptime dtype: DType) type {
    return kernel.logical.Family(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_random_philox_key_counter_uniform_runtime_{s}",
            .{dtype.name()},
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(dtype),
            .key = kernel.dynamicBuffer(.key),
            .counter = kernel.dynamicBuffer(.i32),
            .count = kernel.scalar(.i32),
        },
        .Instance = PhiloxKeyCounterUniform,
        .schedule = philoxKeyCounterUniformSchedule,
        .body = switch (dtype) {
            .f32 => philox_key_counter_uniform_runtime_family_body_f32,
            .i32 => philox_key_counter_uniform_runtime_family_body_i32,
            else => @compileError("Philox key counter runtime supports dtype .f32 or .i32"),
        },
    });
}

pub const PhiloxKeyCounterUniformRuntimeFamilyF32 = philoxKeyCounterUniformRuntimeFamily(.f32);
pub const PhiloxKeyCounterUniformRuntimeFamilyI32 = philoxKeyCounterUniformRuntimeFamily(.i32);
