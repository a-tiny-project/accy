const random = @import("../root.zig");

const shared = random.base;
const block = random.block;
const model = @import("model.zig");

const std = shared.std;
const DType = shared.DType;
const entry = shared.entry;
const kernel = shared.kernel;
const indexExtent = shared.indexExtent;
const ceilDivComptime = shared.ceilDivComptime;

const Threefry = model.Threefry;
const threefry_lanes = block.threefry_lanes;
const threefryWords = block.threefryWords;
const outputWord = block.outputWord;
const storeGuarded = block.storeGuarded;

fn threefry_body_each(inner_builder: anytype, index: kernel.Index1D, ctx: anytype) !void {
    const words = try threefryWords(
        inner_builder,
        ctx.spec.rounds,
        try inner_builder.cast(index.index, .i32),
        try inner_builder.constantInt(.i32, 0),
        ctx.args.param(.seed_lo).raw(),
        ctx.args.param(.seed_hi).raw(),
    );
    const lanes_extent = try inner_builder.constantIndex(threefry_lanes);
    const base = try inner_builder.mul(index.index, lanes_extent);
    const count = try inner_builder.constantIndex(try indexExtent(ctx.spec.count));
    const aligned = ctx.spec.count % threefry_lanes == 0;
    for (words, 0..) |word, lane| {
        const element = try inner_builder.add(
            base,
            try inner_builder.constantIndex(@intCast(lane)),
        );
        const out = try outputWord(inner_builder, ctx.dtype, word);
        if (aligned) {
            try ctx.args.param(.dst).store(inner_builder, out, element);
        } else {
            try storeGuarded(inner_builder, ctx.args, out, element, count);
        }
    }
}

pub fn threefryBody(k: anytype, comptime dtype: DType, spec: Threefry, args: anytype) !void {
    _ = try k.forEach1D(spec.count_axis, spec.generators(), .{
        .spec = spec,
        .args = args,
        .dtype = dtype,
    }, threefry_body_each);
}
fn threefrySpecialization(comptime spec: Threefry) entry.Specialization {
    return .{
        .dtype = spec.dtype,
        .operation = .{ .random = .{ .threefry = spec.rounds } },
        .inputs = &.{},
        .outputs = &.{entry.shape1D(spec.count_axis, spec.count)},
        .launch = entry.launch1D(ceilDivComptime(spec.generators(), spec.threads), spec.threads),
        .schedule = entry.threadBlocks1D("e", spec.generators(), spec.threads),
    };
}
fn threefryProgram(comptime spec: Threefry) type {
    const Body = struct {
        fn run(k: anytype, args: anytype) !void {
            try threefryBody(k, spec.dtype, spec, args);
        }
    };

    return kernel.logical.Program(.{
        .name = std.fmt.comptimePrint(
            "accy_kernel_random_threefry{}_{}r_{}_{s}",
            .{ spec.count, spec.rounds, spec.threads, spec.dtype.name() },
        ),
        .parameters = .{
            .dst = kernel.dynamicBuffer(spec.dtype),
            .seed_lo = kernel.scalar(.i32),
            .seed_hi = kernel.scalar(.i32),
        },
        .body = Body.run,
    }).withSchedule(kernel.logical.schedule.threadBlocks(.{ .x = spec.threads }));
}
pub fn threefryEntry(comptime spec: Threefry) type {
    return entry.Entry(threefryProgram(spec), .{
        .target = std.fmt.comptimePrint(
            "accy.kernel.random.threefry{}_{}r_{}_{s}",
            .{ spec.count, spec.rounds, spec.threads, spec.dtype.name() },
        ),
        .layer = .logical,
        .category = .random,
        .specialization = threefrySpecialization(spec),
    });
}
pub const Threefry8F32 = threefryEntry(.{ .count = 8, .threads = 4 });
