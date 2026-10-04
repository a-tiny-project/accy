const std = @import("std");
const common = @import("common.zig");
const product_mod = @import("../model/root.zig");

const ElementwiseKernel = product_mod.ElementwiseKernel;
const ShapeKernel = product_mod.ShapeKernel;
const DotGeneralDescription = product_mod.DotGeneralDescription;
const ReductionDescription = product_mod.ReductionDescription;

/// The kernel stage charges this many bytes against its work bound for each symbol a generated
/// kernel is launched by, an entry name. That bound is the counts of visits, analyses and bytes a
/// pass declares before it runs, so compilation can refuse a pass that would exceed the caller's
/// limits. The value equals the name capacity of a standard generated-kernel builder, which owns
/// that storage. A name is written into a fixed buffer of this size, and a name that does not fit
/// returns `error.WorkExhausted`. The finished name is copied once at its exact length, so building
/// a name never allocates more than this bound.
pub const maximum_storage_bytes =
    common.kernel_root.Builder.Limits.borrowed_standard.kernel_name_bytes;

const NameBuffer = struct {
    bytes: [maximum_storage_bytes]u8 = undefined,
    len: usize = 0,

    fn print(self: *NameBuffer, comptime format: []const u8, args: anytype) !void {
        const written = std.fmt.bufPrint(self.bytes[self.len..], format, args) catch
            return error.WorkExhausted;
        self.len += written.len;
    }

    fn finish(self: *const NameBuffer, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, self.bytes[0..self.len]);
    }
};

fn formatName(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]u8 {
    var name: NameBuffer = .{};
    try name.print(format, args);
    return name.finish(allocator);
}

pub fn elementwiseVector(
    allocator: std.mem.Allocator,
    kinds: []const ElementwiseKernel,
    work_item_id: usize,
) common.LoweringError![]u8 {
    var name = try elementwiseName(kinds, work_item_id);
    try name.print("_v4", .{});
    return name.finish(allocator);
}

pub fn elementwise(
    allocator: std.mem.Allocator,
    kinds: []const ElementwiseKernel,
    work_item_id: usize,
) common.LoweringError![]u8 {
    const name = try elementwiseName(kinds, work_item_id);
    return name.finish(allocator);
}

fn elementwiseName(kinds: []const ElementwiseKernel, work_item_id: usize) !NameBuffer {
    if (kinds.len == 0) return error.UnsupportedOperation;
    var name: NameBuffer = .{};
    try name.print("accy_choir_elementwise", .{});
    for (kinds) |kind| try name.print("_{s}", .{@tagName(kind)});
    try name.print("_{d}", .{work_item_id});
    return name;
}

pub fn shape(
    allocator: std.mem.Allocator,
    kind: ShapeKernel,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_shape_{s}_{d}",
        .{ @tagName(kind), work_item_id },
    );
}

pub fn dotGeneral(
    allocator: std.mem.Allocator,
    desc: DotGeneralDescription,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_dot_general_{s}_{d}x{d}x{d}_{d}",
        .{ @tagName(desc.input_dtype), desc.dims.m, desc.dims.n, desc.dims.k, work_item_id },
    );
}

pub fn dotGeneralFused(
    allocator: std.mem.Allocator,
    desc: DotGeneralDescription,
    work: anytype,
    tile: ?product_mod.DotGeneralBlockTile,
    work_item_id: usize,
) common.LoweringError![]u8 {
    var name: NameBuffer = .{};
    if (tile) |value| {
        try name.print(
            "accy_choir_dot_general_tiled{d}x{d}x{d}",
            .{ value.bm, value.bn, value.bk },
        );
    } else {
        try name.print("accy_choir_dot_general", .{});
    }
    try appendFused(&name, desc, work, work_item_id);
    return name.finish(allocator);
}

fn appendFused(
    name: *NameBuffer,
    desc: DotGeneralDescription,
    work: anytype,
    work_item_id: usize,
) !void {
    for (work.ops[1..]) |op| {
        const mnemonic = op.name.name;
        const dot_index = std.mem.lastIndexOfScalar(u8, mnemonic, '.') orelse 0;
        try name.print("_{s}", .{mnemonic[dot_index + 1 ..]});
    }
    try name.print(
        "_{s}_{d}x{d}x{d}_{d}",
        .{ @tagName(desc.input_dtype), desc.dims.m, desc.dims.n, desc.dims.k, work_item_id },
    );
}

pub fn dotGeneralTiled(
    allocator: std.mem.Allocator,
    desc: DotGeneralDescription,
    tile: product_mod.DotGeneralBlockTile,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_dot_general_tiled{d}x{d}x{d}_{s}_{d}x{d}x{d}_{d}",
        .{
            tile.bm,
            tile.bn,
            tile.bk,
            @tagName(desc.input_dtype),
            desc.dims.m,
            desc.dims.n,
            desc.dims.k,
            work_item_id,
        },
    );
}

pub fn reductionFused(
    allocator: std.mem.Allocator,
    desc: anytype,
    prologue_ops: usize,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_reduction_{s}_fused{d}_rank{d}_axis{d}_{s}_{d}",
        .{
            @tagName(desc.kind),
            prologue_ops,
            desc.dims.input_rank,
            desc.dims.axis,
            @tagName(desc.input_dtype),
            work_item_id,
        },
    );
}

pub fn reductionWarpRows(
    allocator: std.mem.Allocator,
    desc: anytype,
    prologue_ops: usize,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_reduction_{s}_warprows_fused{d}_{s}_{d}",
        .{ @tagName(desc.kind), prologue_ops, @tagName(desc.input_dtype), work_item_id },
    );
}

pub fn iterate(
    allocator: std.mem.Allocator,
    carry_count: usize,
    max_iters: i64,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_iterate{d}_cap{d}_f32_{d}",
        .{ carry_count, max_iters, work_item_id },
    );
}

pub fn scanLookback(
    allocator: std.mem.Allocator,
    total: u64,
    blocks: u32,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_scan_lookback_{d}x{d}_f32_{d}",
        .{ total, blocks, work_item_id },
    );
}

pub fn scanSerial(
    allocator: std.mem.Allocator,
    total: u64,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_scan_serial_{d}_f32_{d}",
        .{ total, work_item_id },
    );
}

pub fn flashAttention(
    allocator: std.mem.Allocator,
    seq: u32,
    head_dim: u32,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_flash_attention_{d}x{d}_f32_{d}",
        .{ seq, head_dim, work_item_id },
    );
}

pub fn flashAttentionSerial(
    allocator: std.mem.Allocator,
    seq: u32,
    head_dim: u32,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_flash_attention_serial_{d}x{d}_f32_{d}",
        .{ seq, head_dim, work_item_id },
    );
}

pub fn rowPipeline(
    allocator: std.mem.Allocator,
    reduce_count: usize,
    threads: u32,
    op_count: usize,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_row_pipeline{d}_t{d}_ops{d}_f32_{d}",
        .{ reduce_count, threads, op_count, work_item_id },
    );
}

pub fn rowPipelineSerial(
    allocator: std.mem.Allocator,
    reduce_count: usize,
    op_count: usize,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_row_pipeline_serial{d}_ops{d}_f32_{d}",
        .{ reduce_count, op_count, work_item_id },
    );
}

pub fn reductionConcat(
    allocator: std.mem.Allocator,
    desc: anytype,
    group: usize,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_reduction_concat{d}_warprows_{s}_{d}",
        .{ group, @tagName(desc.input_dtype), work_item_id },
    );
}

pub fn dotGeneralMma(
    allocator: std.mem.Allocator,
    desc: DotGeneralDescription,
    tile: product_mod.DotGeneralMmaTile,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_dot_general_tf32mma{d}x{d}x{d}_{s}_{d}x{d}x{d}_{d}",
        .{
            tile.bm,
            tile.bn,
            tile.bk,
            @tagName(desc.input_dtype),
            desc.dims.m,
            desc.dims.n,
            desc.dims.k,
            work_item_id,
        },
    );
}

pub fn dotGeneralFusedMma(
    allocator: std.mem.Allocator,
    desc: DotGeneralDescription,
    work: anytype,
    tile: product_mod.DotGeneralMmaTile,
    work_item_id: usize,
) common.LoweringError![]u8 {
    var name: NameBuffer = .{};
    try name.print("accy_choir_dot_general_tf32mma{d}x{d}x{d}", .{ tile.bm, tile.bn, tile.bk });
    try appendFused(&name, desc, work, work_item_id);
    return name.finish(allocator);
}

pub fn reduction(
    allocator: std.mem.Allocator,
    desc: ReductionDescription,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_reduction_{s}_rank{d}_axis{d}_{s}_{d}",
        .{
            @tagName(desc.kind),
            desc.dims.input_rank,
            desc.dims.axis,
            @tagName(desc.input_dtype),
            work_item_id,
        },
    );
}

pub fn reductionSingleBlock(
    allocator: std.mem.Allocator,
    desc: ReductionDescription,
    threads: u32,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_reduction_block{d}_{s}_{d}_{s}_{d}",
        .{
            threads,
            @tagName(desc.kind),
            desc.dims.input_element_count,
            @tagName(desc.input_dtype),
            work_item_id,
        },
    );
}

pub fn reductionAtomic(
    allocator: std.mem.Allocator,
    desc: ReductionDescription,
    plan: product_mod.ReductionAtomicPlan,
    work_item_id: usize,
) common.LoweringError![]u8 {
    return formatName(
        allocator,
        "accy_choir_reduction_atomic{d}x{d}_{s}_{d}_{s}_{d}",
        .{
            plan.blocks,
            plan.threads,
            @tagName(desc.kind),
            desc.dims.input_element_count,
            @tagName(desc.input_dtype),
            work_item_id,
        },
    );
}

const testing = std.testing;
const test_dot: DotGeneralDescription = .{
    .input_dtype = .f32,
    .output_dtype = .f32,
    .dims = .{ .m = 4, .n = 8, .k = 16 },
};
const test_reduction: ReductionDescription = .{
    .kind = .sum,
    .input_dtype = .f32,
    .output_dtype = .f32,
    .dims = .{ .input_rank = 2, .axis = 1, .input_element_count = 32, .output_element_count = 4 },
    .init = .{ .constant = .{ .f32 = 0 } },
};
const TestOp = struct { name: struct { name: []const u8 } };

fn checkName(comptime make: anytype, args: anytype, expected: []const u8) !void {
    var counter = testing.FailingAllocator.init(testing.allocator, .{});
    const normal = try @call(.auto, make, .{counter.allocator()} ++ args);
    defer counter.allocator().free(normal);
    try testing.expectEqualStrings(expected, normal);
    try testing.expectEqual(@as(usize, 1), counter.allocations);
    try testing.expectEqual(expected.len, counter.allocated_bytes);

    var bytes: [maximum_storage_bytes]u8 = undefined;
    var buffer = std.heap.FixedBufferAllocator.init(bytes[0..expected.len]);
    const base = buffer.allocator();
    const vtable: std.mem.Allocator.VTable = .{
        .alloc = base.vtable.alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = std.mem.Allocator.noFree,
    };
    const allocator: std.mem.Allocator = .{ .ptr = base.ptr, .vtable = &vtable };
    const bounded = try @call(.auto, make, .{allocator} ++ args);
    try testing.expectEqualStrings(expected, bounded);
    try testing.expectEqual(expected.len, buffer.end_index);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, @call(.auto, make, .{failing.allocator()} ++ args));
}

fn checkFusedBoundary(
    comptime make: anytype,
    tile: anytype,
    prefix: []const u8,
    count: usize,
) !void {
    const limit = common.kernel_root.Builder.Limits.borrowed_standard.kernel_name_bytes;
    const suffix = "_f32_4x8x16_9";
    const payload_len = count - prefix.len - 1 - suffix.len;
    var mnemonic: [limit + 3]u8 = @splat('q');
    mnemonic[0] = 'x';
    mnemonic[1] = '.';
    const ops = [_]TestOp{
        .{ .name = .{ .name = "accy.dot_general" } },
        .{ .name = .{ .name = mnemonic[0 .. payload_len + 2] } },
    };
    const args = .{ test_dot, .{ .ops = &ops }, tile, 9 };
    if (count > limit) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        try testing.expectError(
            error.WorkExhausted,
            @call(.auto, make, .{failing.allocator()} ++ args),
        );
        try testing.expect(!failing.has_induced_failure);
    } else {
        var expected: [limit]u8 = undefined;
        const bytes = try std.fmt.bufPrint(
            &expected,
            "{s}_{s}{s}",
            .{ prefix, mnemonic[2 .. payload_len + 2], suffix },
        );
        try testing.expectEqual(count, bytes.len);
        try checkName(make, args, bytes);
    }
}

fn checkElementwiseBoundary(comptime vector: bool, extra: usize) !void {
    const make = if (vector) elementwiseVector else elementwise;
    const limit = common.kernel_root.Builder.Limits.borrowed_standard.kernel_name_bytes;
    var kinds: [121]ElementwiseKernel = @splat(.add);
    const count = kinds.len;
    const square_roots = extra + @as(usize, if (vector) 0 else 3);
    @memset(kinds[0..square_roots], .sqrt);
    const expected_len: usize = 511 + extra;
    var counter = testing.FailingAllocator.init(testing.allocator, .{});
    if (expected_len > limit) {
        try testing.expectError(error.WorkExhausted, make(counter.allocator(), kinds[0..count], 9));
        try testing.expectEqual(@as(usize, 0), counter.allocations);
    } else {
        const name = try make(counter.allocator(), kinds[0..count], 9);
        defer counter.allocator().free(name);
        try testing.expectEqual(expected_len, name.len);
        try testing.expectEqual(@as(usize, 1), counter.allocations);
        try testing.expectEqual(expected_len, counter.allocated_bytes);
    }
}
