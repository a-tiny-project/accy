const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const choir = @import("../choir/root.zig");

const gating = @import("accy_validation_gating");
const artifact = @import("../artifact/root.zig");
const executable = @import("../executable/root.zig");
const kernel = @import("../kernel/root.zig");
const preparation = @import("../preparation/root.zig");
const target = @import("../target/root.zig");
const ir = choir.ir;
const activation = choir.activation;
const tensor = choir.tensor;
const einsum = choir.einsum;
const SemanticBuilder = choir.SemanticBuilder;
const SemanticModule = choir.SemanticModule;
const LoadedFragment = executable.LoadedFragment;
const ArtifactKernelSource = artifact.KernelSource;
const FragmentCompilerOptions = executable.FragmentCompilerOptions;
const prepareInvocation = executable.prepareInvocation;
const loadFragment = executable.loadFragment;
const prepareFragmentFromSemanticModule = executable.prepareFragmentFromSemanticModule;
const compileFragmentFromSemanticModule = executable.compileFragmentFromSemanticModule;
const GeneratedScheduleKind = preparation.GeneratedScheduleKind;
const GeneratedScanSchedule = preparation.target.GeneratedScanSchedule;
const generated_scan_schedule_version = preparation.kernelization.generated_scan_schedule_version;
const max_scan_schedule_candidates = preparation.kernelization.max_scan_schedule_candidates;
const scanScheduleCandidates = preparation.kernelization.scanScheduleCandidates;
const GeneratedRowPipelineSchedule = preparation.target.GeneratedRowPipelineSchedule;
const generated_row_pipeline_schedule_version = preparation.kernelization.generated_row_pipeline_schedule_version;
const max_row_pipeline_schedule_candidates = preparation.kernelization.max_row_pipeline_schedule_candidates;
const rowPipelineScheduleCandidates = preparation.kernelization.rowPipelineScheduleCandidates;

test {
    _ = @import("../artifact/test.zig");
    _ = @import("../eval/test.zig");
    _ = @import("../executable/test.zig");
    _ = @import("../choir/einsum/test.zig");
    _ = @import("../kernel/root.zig");
    _ = @import("../preparation/test.zig");
    _ = @import("../choir/shape/test.zig");
    _ = @import("../target/root.zig");
    @import("test_discovery").discover(choir);
}

fn compileAndLoadSemanticModule(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    module: *SemanticModule,
    options: FragmentCompilerOptions,
) !*LoadedFragment {
    const compiled = try compileFragmentFromSemanticModule(allocator, handle, module, options);
    return try loadFragment(allocator, handle, compiled, options);
}
const KernelCallAdd = kernel.library.elementwise.VectorAdd8F32;
const KernelCallGelu = kernel.library.elementwise.Gelu8F32;
const KernelCallRelu = kernel.library.elementwise.Relu8F32;
const KernelCallMatrixProduct = kernel.library.linalg.MatrixProduct4x16x8F32;
const KernelCallTranspose = kernel.library.layout.Transpose8x16F32;
const KernelCallDot = kernel.library.reduction.Dot8F32;

fn semanticKernelCallAddModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("semantic_kernel_call_add", &.{ f32_8, f32_8 }, &.{f32_8});
    const call = try fb.kernelCall(
        &.{ fb.parameter(0), fb.parameter(1) },
        &.{f32_8},
        .{
            .target = KernelCallAdd.target,
            .operand_effects = &.{ .read, .read },
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    return try builder.finish();
}

fn semanticEinsumMatrixProductModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 4, 8 });
    const rhs_ty = try builder.tensor(.f32, &.{ 8, 16 });
    const out_ty = try builder.tensor(.f32, &.{ 4, 16 });
    var fb = try builder.beginFunction("semantic_einsum_kernel_call_matmul", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "ik,kj->ij");
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn semanticEinsumMatrixProductFamilyModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 5, 3 });
    const rhs_ty = try builder.tensor(.f32, &.{ 3, 7 });
    const out_ty = try builder.tensor(.f32, &.{ 5, 7 });
    var fb = try builder.beginFunction("semantic_einsum_kernel_call_matmul_family", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "ik,kj->ij");
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn semanticSegmentSumFamilyModule(allocator: std.mem.Allocator, family_target: []const u8) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const data_ty = try builder.tensor(.f32, &.{12});
    const offsets_ty = try builder.tensor(.i32, &.{4});
    const out_ty = try builder.tensor(.f32, &.{3});
    var fb = try builder.beginFunction("semantic_segment_sum_kernel_call_family", &.{ data_ty, offsets_ty }, &.{out_ty});
    const call = try fb.kernelCall(
        &.{ fb.parameter(0), fb.parameter(1) },
        &.{out_ty},
        .{
            .target = family_target,
            .version = kernel.library.segmented.segment_sum_family_version,
            .operand_effects = &.{ .read, .read },
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    return try builder.finish();
}

fn semanticGatherFamilyModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const data_ty = try builder.tensor(.f32, &.{ 2, 8, 3 });
    const indices_ty = try builder.tensor(.i32, &.{5});
    const out_ty = try builder.tensor(.f32, &.{ 2, 5, 3 });
    var fb = try builder.beginFunction("semantic_gather_kernel_call_family", &.{ data_ty, indices_ty }, &.{out_ty});
    const out = try fb.gather(fb.parameter(0), fb.parameter(1), out_ty, 1);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn semanticRank2IotaGatherFusionModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const flat_ty = try builder.tensor(.f32, &.{256});
    const img_ty = try builder.tensor(.f32, &.{ 8, 32 });
    const idx_ty = try builder.tensor(.i32, &.{ 8, 32 });
    const scalar_ty = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("semantic_rank2_iota_gather_fusion", &.{flat_ty}, &.{img_ty});
    const indices = try fb.iota(idx_ty, 1);
    const gathered = try fb.gather(fb.parameter(0), indices, img_ty, 0);
    const zero: f32 = 0;
    const scalar = try fb.constant(scalar_ty, std.mem.asBytes(&zero));
    const zeros = try fb.broadcast(scalar, img_ty, &.{ 8, 32 });
    const out = try fb.add(gathered, zeros);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn semanticRowPipelineModule(allocator: std.mem.Allocator, rows: i64, cols: i64) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const x_ty = try builder.tensor(.f32, &.{ rows, cols });
    const row_ty = try builder.tensor(.f32, &.{rows});
    const scalar_ty = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("semantic_row_pipeline_schedule", &.{x_ty}, &.{x_ty});
    const x = fb.parameter(0);
    const lowest = try fb.constant(scalar_ty, std.mem.asBytes(&@as(f32, -std.math.floatMax(f32))));
    const row_max = try fb.reduce(x, lowest, row_ty, "max", &.{1});
    const shifted = try fb.sub(x, try fb.broadcastInDim(row_max, x_ty, &.{ rows, cols }, &.{0}));
    const exps = try fb.exp(shifted);
    const zero = try fb.constant(scalar_ty, std.mem.asBytes(&@as(f32, 0.0)));
    const row_sum = try fb.reduce(exps, zero, row_ty, "sum", &.{1});
    const out = try fb.div(exps, try fb.broadcastInDim(row_sum, x_ty, &.{ rows, cols }, &.{0}));
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn semanticCumsumModule(allocator: std.mem.Allocator, total: i64) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{total});
    var fb = try builder.beginFunction("semantic_cumsum_schedule", &.{vec_ty}, &.{vec_ty});
    const out = try fb.cumsum(fb.parameter(0), vec_ty, 0);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn semanticRank2ClampedGatherFusionModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const rows: i64 = 8;
    const cols: i64 = 8;
    const flat_ty = try builder.tensor(.f32, &.{rows * cols});
    const img_ty = try builder.tensor(.f32, &.{ rows, cols });
    const idx_ty = try builder.tensor(.i32, &.{ rows, cols });
    const scalar_ty = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("semantic_rank2_clamped_gather_fusion", &.{flat_ty}, &.{img_ty});

    const Consts = struct {
        fb: *@TypeOf(fb),
        img_ty: ir.Type,
        scalar_ty: ir.Type,
        rows: i64,
        cols: i64,

        fn splat(self: *@This(), value: f32) !*ir.Value {
            const scalar = try self.fb.constant(self.scalar_ty, std.mem.asBytes(&value));
            return self.fb.broadcast(scalar, self.img_ty, &.{ self.rows, self.cols });
        }
    };
    var consts = Consts{ .fb = &fb, .img_ty = img_ty, .scalar_ty = scalar_ty, .rows = rows, .cols = cols };
    const ix = try fb.iota(img_ty, 1);
    const iy = try fb.iota(img_ty, 0);
    const zero = try consts.splat(0);
    const warped_x = try fb.add(try fb.mul(ix, try consts.splat(0.35)), try consts.splat(0.75));
    const warped_y = try fb.sub(try fb.mul(iy, try consts.splat(1.15)), try consts.splat(0.25));
    const cxx = try fb.min(try fb.max(warped_x, zero), try consts.splat(@floatFromInt(cols - 1)));
    const cyy = try fb.min(try fb.max(warped_y, zero), try consts.splat(@floatFromInt(rows - 1)));
    const x0 = try fb.min(try fb.floor(cxx), try consts.splat(@floatFromInt(cols - 2)));
    const y0 = try fb.min(try fb.floor(cyy), try consts.splat(@floatFromInt(rows - 2)));
    const width = try consts.splat(@floatFromInt(cols));
    const one = try consts.splat(1);
    const base = try fb.add(try fb.mul(y0, width), x0);
    const idx = try fb.convert(try fb.add(try fb.add(base, width), one), idx_ty, .i32);
    const gathered = try fb.gather(fb.parameter(0), idx, img_ty, 0);
    const out = try fb.add(gathered, zero);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn semanticRandomFamilyModule(
    allocator: std.mem.Allocator,
    family_target: []const u8,
    version: u32,
    dtype: gpu_abi.DType,
    count: u64,
) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const out_ty = try builder.tensor(dtype, &.{@intCast(count)});
    var fb = try builder.beginFunction("semantic_random_kernel_call_family", &.{}, &.{out_ty});
    const call = try fb.kernelCall(
        &.{},
        &.{out_ty},
        .{
            .target = family_target,
            .version = version,
            .operand_effects = &.{},
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    return try builder.finish();
}

test "compaction filter family AOT registry executes on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    const compaction_library = kernel.library.compaction;
    const instance = compaction_library.Filter{
        .extent = 1000,
        .threads = 64,
    };
    var call_artifact = try compaction_library.createFilterFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const family_target = try compaction_library.filterFamilyTarget(allocator, instance);
    defer allocator.free(family_target);

    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    var builder_owned = true;
    errdefer if (builder_owned) builder.deinit();
    const data_ty = try builder.tensor(.f32, &.{1000});
    const packed_ty = try builder.tensor(.f32, &.{1016});
    var fb = try builder.beginFunction("semantic_filter_kernel_call_family", &.{data_ty}, &.{packed_ty});
    const call = try fb.kernelCall(
        &.{fb.parameter(0)},
        &.{packed_ty},
        .{
            .target = family_target,
            .version = compaction_library.filter_family_version,
            .operand_effects = &.{.none},
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getResult(0).?});
    try fb.finish();
    builder_owned = false;
    const module = try builder.finish();

    const registry = decoded.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    var data: [1000]f32 = undefined;
    var seed: u32 = 0x9e3779b9;
    for (&data, 0..) |*value, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        value.* = if (seed % 4 == 0) 0.0 else @floatFromInt(index + 1);
    }

    const input_bytes = [_][]const u8{std.mem.sliceAsBytes(data[0..])};
    const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
    defer bindings.deinit();

    const runtime_args = try compaction_library.filterRuntimeArguments(instance);
    try bindings.launchWithOptions(allocator, .{
        .runtime_scalar_arguments = runtime_args[0..],
    });

    var actual_dst = @as([1016]f32, @splat(-1.0));
    try bindings.readOutput(0, std.mem.sliceAsBytes(actual_dst[0..]));

    var expected_dst = @as([1016]f32, @splat(-1.0));
    compaction_library.filterBlocksExpectedF32(data[0..], instance.threads, expected_dst[0..]);

    try std.testing.expectEqualSlices(f32, expected_dst[1000..], actual_dst[1000..]);
    for (0..16) |segment| {
        const begin = segment * 64;
        const survivors: usize = @intFromFloat(expected_dst[1000 + segment]);
        try std.testing.expectEqualSlices(
            f32,
            expected_dst[begin .. begin + survivors],
            actual_dst[begin .. begin + survivors],
        );
    }
}

test "compaction greater filter family AOT registry executes on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    const compaction_library = kernel.library.compaction;
    const instance = compaction_library.Filter{
        .extent = 1000,
        .predicate = .greater_than,
        .threads = 64,
    };
    var call_artifact = try compaction_library.createFilterFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const family_target = try compaction_library.filterFamilyTarget(allocator, instance);
    defer allocator.free(family_target);

    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    var builder_owned = true;
    errdefer if (builder_owned) builder.deinit();
    const data_ty = try builder.tensor(.f32, &.{1000});
    const packed_ty = try builder.tensor(.f32, &.{1016});
    var fb = try builder.beginFunction("semantic_greater_filter_kernel_call_family", &.{data_ty}, &.{packed_ty});
    const call = try fb.kernelCall(
        &.{fb.parameter(0)},
        &.{packed_ty},
        .{
            .target = family_target,
            .version = compaction_library.filter_family_version,
            .operand_effects = &.{.none},
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getResult(0).?});
    try fb.finish();
    builder_owned = false;
    const module = try builder.finish();

    const registry = decoded.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    var data: [1000]f32 = undefined;
    var seed: u32 = 0x6c078965;
    for (&data, 0..) |*value, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const magnitude: f32 = @floatFromInt(index + 1);
        value.* = if (seed % 2 == 0) -magnitude else magnitude;
    }

    const input_bytes = [_][]const u8{std.mem.sliceAsBytes(data[0..])};
    const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
    defer bindings.deinit();

    const threshold: f32 = 500.0;
    const runtime_args = try compaction_library.filterGreaterRuntimeArguments(instance, .{ .f32 = threshold });
    try bindings.launchWithOptions(allocator, .{
        .runtime_scalar_arguments = runtime_args[0..],
    });

    var actual_dst = @as([1016]f32, @splat(-1.0));
    try bindings.readOutput(0, std.mem.sliceAsBytes(actual_dst[0..]));

    var expected_dst = @as([1016]f32, @splat(-1.0));
    compaction_library.filterBlocksGreaterExpectedF32(data[0..], instance.threads, threshold, expected_dst[0..]);

    try std.testing.expectEqualSlices(f32, expected_dst[1000..], actual_dst[1000..]);
    for (0..16) |segment| {
        const begin = segment * 64;
        const survivors: usize = @intFromFloat(expected_dst[1000 + segment]);
        for (actual_dst[begin .. begin + survivors]) |value| try std.testing.expect(value > threshold);
        try std.testing.expectEqualSlices(
            f32,
            expected_dst[begin .. begin + survivors],
            actual_dst[begin .. begin + survivors],
        );
    }
}

test "compaction composes filter prefix sum and gather into dense output on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    const compaction_library = kernel.library.compaction;
    const scan_library = kernel.library.scan;
    const indexing_library = kernel.library.indexing;

    const extent: usize = 1000;
    const threads: usize = 64;
    const segment_count: usize = 16;
    const padded: usize = extent + segment_count;

    var data: [extent]f32 = undefined;
    var seed: u32 = 0x9e3779b9;
    for (&data, 0..) |*value, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        value.* = if (seed % 4 == 0) 0.0 else @floatFromInt(index + 1);
    }

    const filter_instance = compaction_library.Filter{ .extent = extent, .threads = threads };
    var packed_dst = @as([padded]f32, @splat(-1.0));
    {
        var call_artifact = try compaction_library.createFilterFamilyArtifact(
            allocator,
            state.handle(),
            filter_instance,
            .{ .limits = .testing },
        );
        defer call_artifact.deinit();
        const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
        const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
        defer allocator.free(encoded);
        var decoded = try artifact.wire.decode(allocator, encoded);
        defer decoded.deinit();

        const family_target = try compaction_library.filterFamilyTarget(allocator, filter_instance);
        defer allocator.free(family_target);

        var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
        var builder_owned = true;
        errdefer if (builder_owned) builder.deinit();
        const data_ty = try builder.tensor(.f32, &.{extent});
        const packed_ty = try builder.tensor(.f32, &.{padded});
        var fb = try builder.beginFunction("composition_filter_stage", &.{data_ty}, &.{packed_ty});
        const call = try fb.kernelCall(&.{fb.parameter(0)}, &.{packed_ty}, .{
            .target = family_target,
            .version = compaction_library.filter_family_version,
            .operand_effects = &.{.none},
            .result_aliases = &.{null},
        });
        try fb.return_(&.{call.getFirstResult()});
        try fb.finish();
        builder_owned = false;
        const module = try builder.finish();

        const registry = decoded.registry();
        var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), module, .{
            .kernel_call_registry = &registry,
        });
        defer fragment.deinit();

        const input_bytes = [_][]const u8{std.mem.sliceAsBytes(data[0..])};
        const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
        defer bindings.deinit();
        const runtime_args = try compaction_library.filterRuntimeArguments(filter_instance);
        try bindings.launchWithOptions(allocator, .{
            .runtime_scalar_arguments = runtime_args[0..],
        });
        try bindings.readOutput(0, std.mem.sliceAsBytes(packed_dst[0..]));
    }

    const prefix_instance = scan_library.PrefixSum{ .extent = segment_count, .mode = .exclusive, .threads = 32 };
    var prefix = @as([segment_count]f32, @splat(-1.0));
    {
        var call_artifact = try scan_library.createPrefixSumFamilyArtifact(
            allocator,
            state.handle(),
            prefix_instance,
            .{ .limits = .testing },
        );
        defer call_artifact.deinit();
        const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
        const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
        defer allocator.free(encoded);
        var decoded = try artifact.wire.decode(allocator, encoded);
        defer decoded.deinit();

        const family_target = try scan_library.prefixSumFamilyTarget(allocator, prefix_instance);
        defer allocator.free(family_target);
        const module = try semanticPrefixSumFamilyModule(allocator, family_target, segment_count);

        const registry = decoded.registry();
        var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), module, .{
            .kernel_call_registry = &registry,
        });
        defer fragment.deinit();

        const input_bytes = [_][]const u8{std.mem.sliceAsBytes(packed_dst[extent..])};
        const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
        defer bindings.deinit();
        const runtime_args = try scan_library.prefixSumRuntimeArguments(prefix_instance);
        try bindings.launchWithOptions(allocator, .{
            .runtime_scalar_arguments = runtime_args[0..],
        });
        try bindings.readOutput(0, std.mem.sliceAsBytes(prefix[0..]));
    }

    var indices: [extent]i32 = undefined;
    var total: usize = 0;
    for (0..segment_count) |segment| {
        const begin: usize = @intFromFloat(prefix[segment]);
        const survivors: usize = @intFromFloat(packed_dst[extent + segment]);
        for (0..survivors) |offset| {
            indices[begin + offset] = @intCast(segment * threads + offset);
        }
        total = begin + survivors;
    }

    var expected_dense: [extent]f32 = undefined;
    var expected_total: usize = 0;
    for (data) |value| {
        if (value != 0.0) {
            expected_dense[expected_total] = value;
            expected_total += 1;
        }
    }
    try std.testing.expectEqual(expected_total, total);

    const gather_instance = indexing_library.Gather{
        .axis_size = padded,
        .gathered = total,
        .threads = 64,
    };
    const dense = try allocator.alloc(f32, total);
    defer allocator.free(dense);
    {
        var call_artifact = try indexing_library.createGatherFamilyArtifact(
            allocator,
            state.handle(),
            gather_instance,
            .{ .limits = .testing },
        );
        defer call_artifact.deinit();
        const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
        const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
        defer allocator.free(encoded);
        var decoded = try artifact.wire.decode(allocator, encoded);
        defer decoded.deinit();

        var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
        var builder_owned = true;
        errdefer if (builder_owned) builder.deinit();
        const source_ty = try builder.tensor(.f32, &.{padded});
        const indices_ty = try builder.tensor(.i32, &.{@intCast(total)});
        const out_ty = try builder.tensor(.f32, &.{@intCast(total)});
        var fb = try builder.beginFunction("composition_gather_stage", &.{ source_ty, indices_ty }, &.{out_ty});
        const out = try fb.gather(fb.parameter(0), fb.parameter(1), out_ty, 0);
        try fb.return_(&.{out});
        try fb.finish();
        builder_owned = false;
        const module = try builder.finish();

        const registry = decoded.registry();
        var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), module, .{
            .kernel_call_registry = &registry,
            .gather_schedule = .{ .thread_blocks = 64 },
        });
        defer fragment.deinit();

        const input_bytes = [_][]const u8{
            std.mem.sliceAsBytes(packed_dst[0..]),
            std.mem.sliceAsBytes(indices[0..total]),
        };
        const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
        defer bindings.deinit();
        const runtime_args = try indexing_library.gatherRuntimeArguments(gather_instance);
        try bindings.launchWithOptions(allocator, .{
            .runtime_scalar_arguments = runtime_args[0..],
        });
        try bindings.readOutput(0, std.mem.sliceAsBytes(dense));
    }

    try std.testing.expectEqualSlices(f32, expected_dense[0..expected_total], dense);
}

test "squares family AOT registry executes on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    const random_library = kernel.library.random;
    const instance = random_library.Squares{
        .count = 777,
        .threads = 64,
        .dtype = .i32,
    };
    var call_artifact = try random_library.createSquaresFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const family_target = try random_library.squaresFamilyTarget(allocator, instance);
    defer allocator.free(family_target);
    const module = try semanticRandomFamilyModule(
        allocator,
        family_target,
        random_library.squares_family_version,
        .i32,
        instance.count,
    );

    const registry = decoded.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    const input_bytes = [_][]const u8{};
    const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
    defer bindings.deinit();

    const runtime_args = try random_library.squaresRuntimeArguments(instance);
    try bindings.launchWithOptions(allocator, .{
        .runtime_scalar_arguments = runtime_args[0..],
    });

    var actual = @as([777]i32, @splat(0));
    try bindings.readOutput(0, std.mem.sliceAsBytes(actual[0..]));

    for (0..777) |element| {
        const expected = random_library.squaresBlock(@intCast(element), instance.key);
        try std.testing.expectEqual(@as(i32, @bitCast(expected)), actual[element]);
    }
}

test "philox family AOT registry executes on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    const random_library = kernel.library.random;
    const instance = random_library.Philox{
        .count = 1000,
        .threads = 64,
        .seed = 0xdecafbad00c0ffee,
    };
    var call_artifact = try random_library.createPhiloxFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const family_target = try random_library.philoxFamilyTarget(allocator, instance);
    defer allocator.free(family_target);
    const module = try semanticRandomFamilyModule(
        allocator,
        family_target,
        random_library.philox_family_version,
        .f32,
        instance.count,
    );

    const registry = decoded.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    const input_bytes = [_][]const u8{};
    const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
    defer bindings.deinit();

    const runtime_args = try random_library.philoxRuntimeArguments(instance);
    try bindings.launchWithOptions(allocator, .{
        .runtime_scalar_arguments = runtime_args[0..],
    });

    var actual = @as([1000]f32, @splat(-1.0));
    try bindings.readOutput(0, std.mem.sliceAsBytes(actual[0..]));

    for (0..250) |generator| {
        const words = random_library.philoxBlock(
            random_library.philox_default_rounds,
            .{ @intCast(generator), 0, 0, 0 },
            .{ instance.seedLo(), instance.seedHi() },
        );
        for (words, 0..) |word, lane| {
            try std.testing.expectEqual(random_library.uniformFromBits(word), actual[generator * 4 + lane]);
        }
    }
}

test "threefry family AOT registry executes on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    const random_library = kernel.library.random;
    const instance = random_library.Threefry{
        .count = 999,
        .threads = 128,
        .seed = 0x0123456789abcdef,
        .dtype = .i32,
    };
    var call_artifact = try random_library.createThreefryFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const family_target = try random_library.threefryFamilyTarget(allocator, instance);
    defer allocator.free(family_target);
    const module = try semanticRandomFamilyModule(
        allocator,
        family_target,
        random_library.threefry_family_version,
        .i32,
        instance.count,
    );

    const registry = decoded.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    const input_bytes = [_][]const u8{};
    const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
    defer bindings.deinit();

    const runtime_args = try random_library.threefryRuntimeArguments(instance);
    try bindings.launchWithOptions(allocator, .{
        .runtime_scalar_arguments = runtime_args[0..],
    });

    var actual = @as([999]i32, @splat(0));
    try bindings.readOutput(0, std.mem.sliceAsBytes(actual[0..]));

    for (0..500) |generator| {
        const words = random_library.threefryBlock(
            random_library.threefry_default_rounds,
            .{ @intCast(generator), 0 },
            .{ instance.seedLo(), instance.seedHi() },
        );
        for (words, 0..) |word, lane| {
            const element = generator * 2 + lane;
            if (element >= instance.count) continue;
            try std.testing.expectEqual(@as(i32, @bitCast(word)), actual[element]);
        }
    }
}

fn semanticEinsumMatrixVectorProductModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const matrix_ty = try builder.tensor(.f32, &.{ 4, 8 });
    const vector_ty = try builder.tensor(.f32, &.{8});
    const out_ty = try builder.tensor(.f32, &.{4});
    var fb = try builder.beginFunction("semantic_einsum_kernel_call_matvec", &.{ matrix_ty, vector_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "mk,k->m");
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn semanticReluModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const input_ty = try builder.tensor(.f32, &.{8});
    const zeros = @as([8]f32, @splat(0.0));
    var fb = try builder.beginFunction("semantic_relu_kernel_call", &.{input_ty}, &.{input_ty});
    const zero = try fb.constant(input_ty, std.mem.sliceAsBytes(zeros[0..]));
    const out = try fb.max(fb.parameter(0), zero);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn semanticGeluActivationModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const input_ty = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("semantic_gelu_activation_kernel_call", &.{input_ty}, &.{input_ty});
    const out = try fb.activation(fb.parameter(0), .gelu);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn semanticEinsumTransposeModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const input_ty = try builder.tensor(.f32, &.{ 8, 16 });
    const out_ty = try builder.tensor(.f32, &.{ 16, 8 });
    var fb = try builder.beginFunction("semantic_einsum_kernel_call_transpose", &.{input_ty}, &.{out_ty});
    const out = try fb.einsum(&.{fb.parameter(0)}, out_ty, "ij->ji");
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn semanticEinsumDotModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const input_ty = try builder.tensor(.f32, &.{8});
    const out_ty = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("semantic_einsum_kernel_call_dot", &.{ input_ty, input_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "i,i->");
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

fn semanticKernelCallRowSoftmaxModule(
    allocator: std.mem.Allocator,
    descriptor: kernel.library.CatalogDescriptor,
) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_2x4 = try builder.tensor(.f32, &.{ 2, 4 });
    var fb = try builder.beginFunction("semantic_kernel_call_row_softmax", &.{f32_2x4}, &.{f32_2x4});
    const call = try fb.kernelCall(
        &.{fb.parameter(0)},
        &.{f32_2x4},
        .{
            .target = descriptor.metadata.target,
            .version = descriptor.metadata.version,
            .operand_effects = &.{.read},
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    return try builder.finish();
}

test "semantic kernel_call resolves through kernel library registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try KernelCallAdd.createKernelCallArtifact(
        allocator,
        state.handle(),
        .{ .limits = KernelCallAdd.Limits.testing },
    );
    defer call_artifact.deinit();

    const module = try semanticKernelCallAddModule(allocator);

    const registry = call_artifact.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.kernel_call, summary.source);
    try std.testing.expectEqualStrings(KernelCallAdd.name, summary.entry_name);
    try std.testing.expectEqual(@as(u32, 3), summary.compile_argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, summary.compile_required_dtype_bits);
    try std.testing.expect(summary.fixed_threadgroup);
    try std.testing.expectEqual(@as(u32, 2), summary.launch_geometry.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), summary.launch_geometry.threadgroup[0]);
}

test "semantic einsum matrix product lowers through kernel library registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try kernel.library.createKernelCallArtifact(allocator, state.handle(), .{
        .target = KernelCallMatrixProduct.target,
        .version = KernelCallMatrixProduct.version,
        .options = .{ .limits = KernelCallMatrixProduct.Limits.testing },
    });
    defer call_artifact.deinit();

    const module = try semanticEinsumMatrixProductModule(allocator);

    const registry = call_artifact.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.kernel_call, summary.source);
    try std.testing.expectEqualStrings(KernelCallMatrixProduct.name, summary.entry_name);
    try std.testing.expectEqual(@as(u32, 3), summary.compile_argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, summary.compile_required_dtype_bits);
    try std.testing.expect(summary.fixed_threadgroup);
    try std.testing.expectEqual(@as(u32, 2), summary.launch_geometry.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), summary.launch_geometry.grid[1]);
    try std.testing.expectEqual(@as(u32, 8), summary.launch_geometry.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 4), summary.launch_geometry.threadgroup[1]);
}

test "semantic einsum matrix product family lowers through AOT wire registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const instance = kernel.library.linalg.MatrixProduct{
        .m = 5,
        .n = 7,
        .k = 3,
        .threads = kernel.library.linalg.matrixProductThreadsForExtents(5, 7),
    };
    var call_artifact = try kernel.library.linalg.createMatrixProductFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const module = try semanticEinsumMatrixProductFamilyModule(allocator);

    const registry = decoded.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.kernel_call, summary.source);
    try std.testing.expectEqualStrings("accy_kernel_linalg_matmul_family_7x5_f32", summary.entry_name);
    try std.testing.expectEqual(@as(u32, 6), summary.compile_argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{ .f32, .i32 }).bits, summary.compile_required_dtype_bits);
    try std.testing.expectEqual(@as(u32, 3), summary.runtime_scalar_argument_count);
    try std.testing.expect(summary.fixed_threadgroup);
    try std.testing.expectEqual(@as(usize, 1), summary.launch_candidate_count);
    try std.testing.expectEqual(@as(u32, 7), summary.launch_geometry.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 5), summary.launch_geometry.threadgroup[1]);
}

test "semantic einsum matrix product family lowers explicit schedule through registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const schedule = kernel.library.MatrixProductSchedule{ .thread_blocks = .{ .x = 4, .y = 2 } };
    const lhs_dims = [_]i64{ 5, 3 };
    const rhs_dims = [_]i64{ 3, 7 };
    const output_dims = [_]i64{ 5, 7 };
    var selected = (try kernel.library.selectOwned(allocator, .{ .matrix_product = .{
        .dtype = .f32,
        .lhs_indices = "mk",
        .rhs_indices = "kn",
        .output_indices = "mn",
        .lhs_dims = &lhs_dims,
        .rhs_dims = &rhs_dims,
        .output_dims = &output_dims,
        .schedule = schedule,
    } })) orelse return error.TestExpectedCatalogDescriptor;
    defer selected.deinit();

    var call_artifact = try kernel.library.createOwnedKernelCallArtifact(
        allocator,
        state.handle(),
        selected,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();
    try std.testing.expectEqual(@as(u32, 4), call_artifact.entry().launch.derived.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), call_artifact.entry().launch.derived.threadgroup[1]);

    const module = try semanticEinsumMatrixProductFamilyModule(allocator);
    const registry = call_artifact.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{
            .kernel_call_registry = &registry,
            .matrix_product_schedule = schedule,
        },
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.kernel_call, summary.source);
    try std.testing.expectEqualStrings("accy_kernel_linalg_matmul_family_4x2_f32", summary.entry_name);
    try std.testing.expectEqual(artifact.PlannedKernelCompileLaunch.kernel_call, summary.compile_launch);
    try std.testing.expectEqual(@as(u32, 3), summary.runtime_scalar_argument_count);
}

test "semantic einsum matrix product family AOT registry executes on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    const instance = kernel.library.linalg.MatrixProduct{
        .m = 5,
        .n = 7,
        .k = 3,
        .threads = kernel.library.linalg.matrixProductThreadsForExtents(5, 7),
    };
    var call_artifact = try kernel.library.linalg.createMatrixProductFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const module = try semanticEinsumMatrixProductFamilyModule(allocator);

    const registry = decoded.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    var lhs: [15]f32 = undefined;
    for (&lhs, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    var rhs: [21]f32 = undefined;
    for (&rhs, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index)) * 0.5 - 2.0;
    var expected: [35]f32 = undefined;
    fillMatrixProductExpected(expected[0..], lhs[0..], rhs[0..], instance.m, instance.n, instance.k);

    const input_bytes = [_][]const u8{
        std.mem.sliceAsBytes(lhs[0..]),
        std.mem.sliceAsBytes(rhs[0..]),
    };
    const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
    defer bindings.deinit();

    const runtime_args = try kernel.library.linalg.matrixProductRuntimeArguments(instance);
    try bindings.launchWithOptions(allocator, .{
        .runtime_scalar_arguments = runtime_args[0..],
    });

    var actual = @as([35]f32, @splat(0.0));
    try bindings.readOutput(0, std.mem.sliceAsBytes(actual[0..]));

    for (expected, actual) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.0001);
    }
}

test "semantic gather family lowers through AOT wire registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const instance = kernel.library.indexing.Gather{
        .outer = 2,
        .axis_size = 8,
        .gathered = 5,
        .inner = 3,
        .threads = 16,
    };
    var call_artifact = try kernel.library.indexing.createGatherFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const module = try semanticGatherFamilyModule(allocator);

    const registry = decoded.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{
            .kernel_call_registry = &registry,
            .gather_schedule = .{ .thread_blocks = 16 },
        },
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.kernel_call, summary.source);
    try std.testing.expectEqualStrings("accy_kernel_indexing_gather_family_16_f32", summary.entry_name);
    try std.testing.expectEqual(@as(u32, 8), summary.compile_argument_count);
    try std.testing.expectEqual(@as(u32, 5), summary.runtime_scalar_argument_count);
    try std.testing.expect(summary.fixed_threadgroup);
    try std.testing.expectEqual(@as(usize, 1), summary.launch_candidate_count);
    try std.testing.expectEqual(@as(u32, 16), summary.launch_geometry.threadgroup[0]);
}

test "rank-2 iota gather fusion uses 2D generated launch geometry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const module = try semanticRank2IotaGatherFusionModule(allocator);
    var prepared = try prepareFragmentFromSemanticModule(allocator, state.handle(), module, .{});
    defer prepared.deinit();

    try std.testing.expectEqual(@as(usize, 1), try prepared.generatedKernelCount());
    const summary = try prepared.generatedKernelSummary(0);
    try std.testing.expectEqual(GeneratedScheduleKind.matrix, summary.schedule.kind);
    const geometry = summary.launch_geometry orelse return error.TestExpectedLaunchGeometry;
    try std.testing.expectEqual(@as(u32, 1), geometry.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), geometry.grid[1]);
    try std.testing.expectEqual(@as(u32, 32), geometry.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 8), geometry.threadgroup[1]);

    const artifact_module = try semanticRank2IotaGatherFusionModule(allocator);
    var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), artifact_module, .{});
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const artifact_summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.tensor, artifact_summary.source);
    try std.testing.expect(!artifact_summary.fixed_threadgroup);
    try std.testing.expect(artifact_summary.launch_candidate_count > 1);
    try std.testing.expectEqual(@as(u32, 1), artifact_summary.launch_geometry.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), artifact_summary.launch_geometry.grid[1]);
    try std.testing.expectEqual(@as(u32, 32), artifact_summary.launch_geometry.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 8), artifact_summary.launch_geometry.threadgroup[1]);

    var kernel_artifact = try fragment.copyKernelArtifact(allocator, 0);
    defer kernel_artifact.deinit();
    const ptx = switch (kernel_artifact.payload) {
        .text => |text| text,
        else => return error.TestExpectedTextPayload,
    };
    try std.testing.expect(std.mem.indexOf(u8, ptx, "max.s32") == null);
    try std.testing.expect(std.mem.indexOf(u8, ptx, "min.s32") == null);
}

test "generated row pipeline schedule honors explicit and tuned selections" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const rows: u64 = 8;
    const cols: u64 = 2048;

    {
        const module = try semanticRowPipelineModule(allocator, @intCast(rows), @intCast(cols));
        var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), module, .{});
        defer fragment.deinit();
        const summary = try rowPipelineKernelSummary(fragment);
        try std.testing.expectEqual(@as(u32, 8), summary.launch_geometry.grid[0]);
        try std.testing.expectEqual(@as(u32, 256), summary.launch_geometry.threadgroup[0]);
    }

    {
        const module = try semanticRowPipelineModule(allocator, @intCast(rows), @intCast(cols));
        var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), module, .{
            .generated_row_pipeline_schedule = .{ .threads = 512 },
        });
        defer fragment.deinit();
        const summary = try rowPipelineKernelSummary(fragment);
        try std.testing.expectEqual(@as(u32, 8), summary.launch_geometry.grid[0]);
        try std.testing.expectEqual(@as(u32, 512), summary.launch_geometry.threadgroup[0]);
    }

    const caps = try state.handle().queryCapabilities();
    var candidate_buffer: [max_row_pipeline_schedule_candidates]GeneratedRowPipelineSchedule = undefined;
    const candidates = rowPipelineScheduleCandidates(cols, .cuda_ptx, &candidate_buffer);
    try std.testing.expectEqual(@as(usize, 3), candidates.len);
    const problem = executable.GeneratedRowPipelineScheduleTuningProblem{
        .format = .cuda_ptx,
        .rows = rows,
        .cols = cols,
        .dtype = .f32,
        .schedule_version = generated_row_pipeline_schedule_version,
        .candidates = candidates,
    };
    const tuned_record = executable.GeneratedRowPipelineScheduleTuningRecord{
        .key = try executable.GeneratedRowPipelineScheduleTuningKey.init(caps, problem),
        .selection = .{
            .schedule = .{ .threads = 128 },
            .winner_median_ns = 100,
            .runner_up_median_ns = 120,
            .sample_count = 10,
        },
    };
    const artifact_bytes = try executable.encodeGeneratedRowPipelineScheduleTuningArtifact(allocator, &.{tuned_record});
    defer allocator.free(artifact_bytes);

    {
        const module = try semanticRowPipelineModule(allocator, @intCast(rows), @intCast(cols));
        var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), module, .{
            .generated_row_pipeline_schedule_tuning_artifact = artifact_bytes,
        });
        defer fragment.deinit();
        const summary = try rowPipelineKernelSummary(fragment);
        try std.testing.expectEqual(@as(u32, 8), summary.launch_geometry.grid[0]);
        try std.testing.expectEqual(@as(u32, 128), summary.launch_geometry.threadgroup[0]);
    }
}

fn rowPipelineKernelSummary(fragment: *LoadedFragment) !artifact.KernelSummary {
    var kernel_index: usize = 0;
    while (kernel_index < fragment.kernelCount()) : (kernel_index += 1) {
        const summary = try fragment.kernelSummary(kernel_index);
        if (std.mem.indexOf(u8, summary.entry_name, "row_pipeline") != null) return summary;
    }
    return error.TestExpectedRowPipelineKernel;
}

test "generated row pipeline schedules compute softmax on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    const rows: usize = 8;
    const cols: usize = 2048;

    const input = try allocator.alloc(f32, rows * cols);
    defer allocator.free(input);
    var seed: u32 = 0x243f6a88;
    for (input) |*value| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        value.* = @as(f32, @floatFromInt(seed % 4096)) / 512.0 - 4.0;
    }

    const expected = try allocator.alloc(f32, rows * cols);
    defer allocator.free(expected);
    for (0..rows) |row| {
        const row_values = input[row * cols .. (row + 1) * cols];
        var row_max = -std.math.floatMax(f32);
        for (row_values) |value| row_max = @max(row_max, value);
        var row_sum: f32 = 0.0;
        const expected_row = expected[row * cols .. (row + 1) * cols];
        for (row_values, expected_row) |value, *out| {
            out.* = @exp(value - row_max);
            row_sum += out.*;
        }
        for (expected_row) |*out| out.* /= row_sum;
    }

    const schedules = [_]GeneratedRowPipelineSchedule{
        .{ .threads = 512 },
        .{ .threads = 256 },
        .{ .threads = 128 },
    };
    for (schedules) |schedule| {
        const module = try semanticRowPipelineModule(allocator, @intCast(rows), @intCast(cols));
        var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), module, .{
            .generated_row_pipeline_schedule = schedule,
        });
        defer fragment.deinit();

        const summary = try rowPipelineKernelSummary(fragment);
        try std.testing.expectEqual(schedule.threads, summary.launch_geometry.threadgroup[0]);

        const input_bytes = [_][]const u8{std.mem.sliceAsBytes(input)};
        const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
        defer bindings.deinit();

        try bindings.launch(allocator);

        const actual = try allocator.alloc(f32, rows * cols);
        defer allocator.free(actual);
        try bindings.readOutput(0, std.mem.sliceAsBytes(actual));

        for (expected, actual) |want, got| {
            try std.testing.expectApproxEqAbs(want, got, 0.00001);
        }
    }
}

test "generated scan schedule honors explicit and tuned selections" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const total: u64 = 16384;

    {
        const module = try semanticCumsumModule(allocator, @intCast(total));
        var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), module, .{});
        defer fragment.deinit();
        const summary = try scanKernelSummary(fragment);
        try std.testing.expectEqual(@as(u32, 2), summary.launch_geometry.grid[0]);
        try std.testing.expectEqual(@as(u32, 512), summary.launch_geometry.threadgroup[0]);
    }

    {
        const module = try semanticCumsumModule(allocator, @intCast(total));
        var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), module, .{
            .generated_scan_schedule = .{ .threads = 256, .items = 16 },
        });
        defer fragment.deinit();
        const summary = try scanKernelSummary(fragment);
        try std.testing.expectEqual(@as(u32, 4), summary.launch_geometry.grid[0]);
        try std.testing.expectEqual(@as(u32, 256), summary.launch_geometry.threadgroup[0]);
    }

    const caps = try state.handle().queryCapabilities();
    var candidate_buffer: [max_scan_schedule_candidates]GeneratedScanSchedule = undefined;
    const candidates = scanScheduleCandidates(total, .cuda_ptx, &candidate_buffer);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    const problem = executable.GeneratedScanScheduleTuningProblem{
        .format = .cuda_ptx,
        .total = total,
        .dtype = .f32,
        .schedule_version = generated_scan_schedule_version,
        .candidates = candidates,
    };
    const tuned_record = executable.GeneratedScanScheduleTuningRecord{
        .key = try executable.GeneratedScanScheduleTuningKey.init(caps, problem),
        .selection = .{
            .schedule = .{ .threads = 256, .items = 16 },
            .winner_median_ns = 100,
            .runner_up_median_ns = 120,
            .sample_count = 10,
        },
    };
    var foreign_key = tuned_record.key;
    foreign_key.total = total * 2;
    const foreign_record = executable.GeneratedScanScheduleTuningRecord{
        .key = foreign_key,
        .selection = .{
            .schedule = .{ .threads = 512, .items = 16 },
            .winner_median_ns = 90,
            .runner_up_median_ns = 110,
            .sample_count = 10,
        },
    };
    const artifact_bytes = try executable.encodeGeneratedScanScheduleTuningArtifact(allocator, &.{ tuned_record, foreign_record });
    defer allocator.free(artifact_bytes);

    {
        const module = try semanticCumsumModule(allocator, @intCast(total));
        var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), module, .{
            .generated_scan_schedule_tuning_artifact = artifact_bytes,
        });
        defer fragment.deinit();
        const summary = try scanKernelSummary(fragment);
        try std.testing.expectEqual(@as(u32, 4), summary.launch_geometry.grid[0]);
        try std.testing.expectEqual(@as(u32, 256), summary.launch_geometry.threadgroup[0]);
    }
}

fn scanKernelSummary(fragment: *LoadedFragment) !artifact.KernelSummary {
    var kernel_index: usize = 0;
    while (kernel_index < fragment.kernelCount()) : (kernel_index += 1) {
        const summary = try fragment.kernelSummary(kernel_index);
        if (std.mem.indexOf(u8, summary.entry_name, "scan_lookback") != null) return summary;
    }
    return error.TestExpectedScanKernel;
}

test "rank-2 clamped gather fusion skips redundant signed gather clamp" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const module = try semanticRank2ClampedGatherFusionModule(allocator);
    var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), module, .{});
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    var kernel_artifact = try fragment.copyKernelArtifact(allocator, 0);
    defer kernel_artifact.deinit();
    const ptx = switch (kernel_artifact.payload) {
        .text => |text| text,
        else => return error.TestExpectedTextPayload,
    };
    try std.testing.expect(std.mem.indexOf(u8, ptx, "max.s32") == null);
    try std.testing.expect(std.mem.indexOf(u8, ptx, "min.s32") == null);
}

test "semantic gather family AOT registry executes on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    const instance = kernel.library.indexing.Gather{
        .outer = 2,
        .axis_size = 8,
        .gathered = 5,
        .inner = 3,
        .threads = 16,
    };
    var call_artifact = try kernel.library.indexing.createGatherFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const module = try semanticGatherFamilyModule(allocator);

    const registry = decoded.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{
            .kernel_call_registry = &registry,
            .gather_schedule = .{ .thread_blocks = 16 },
        },
    );
    defer fragment.deinit();

    var data: [48]f32 = undefined;
    for (&data, 0..) |*value, index| value.* = @floatFromInt(index);
    const indices = [_]i32{ 3, 0, 7, -1, 9 };
    var expected: [30]f32 = undefined;
    fillGatherExpected(expected[0..], data[0..], indices[0..], 2, 8, 3);

    const input_bytes = [_][]const u8{
        std.mem.sliceAsBytes(data[0..]),
        std.mem.sliceAsBytes(indices[0..]),
    };
    const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
    defer bindings.deinit();

    const runtime_args = try kernel.library.indexing.gatherRuntimeArguments(instance);
    try bindings.launchWithOptions(allocator, .{
        .runtime_scalar_arguments = runtime_args[0..],
    });

    var actual = @as([30]f32, @splat(0.0));
    try bindings.readOutput(0, std.mem.sliceAsBytes(actual[0..]));

    for (expected, actual) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.0001);
    }
}

fn runSegmentSumFamilyOnLiveCuda(instance: kernel.library.segmented.SegmentSum) !void {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    var call_artifact = try kernel.library.segmented.createSegmentSumFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const family_target = try kernel.library.segmented.segmentSumFamilyTarget(allocator, instance);
    defer allocator.free(family_target);
    const module = try semanticSegmentSumFamilyModule(allocator, family_target);

    const registry = decoded.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    var data: [12]f32 = undefined;
    for (&data, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    const offsets = [_]i32{ 0, 5, 5, 12 };
    var expected = [_]f32{ 0, 0, 0 };
    for (0..3) |segment| {
        const begin: usize = @intCast(offsets[segment]);
        const end: usize = @intCast(offsets[segment + 1]);
        for (begin..end) |element| expected[segment] += data[element];
    }

    const input_bytes = [_][]const u8{
        std.mem.sliceAsBytes(data[0..]),
        std.mem.sliceAsBytes(offsets[0..]),
    };
    const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
    defer bindings.deinit();

    const runtime_args = try kernel.library.segmented.segmentSumRuntimeArguments(instance);
    try bindings.launchWithOptions(allocator, .{
        .runtime_scalar_arguments = runtime_args[0..],
    });

    var actual = @as([3]f32, @splat(0.0));
    try bindings.readOutput(0, std.mem.sliceAsBytes(actual[0..]));

    for (expected, actual) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.0001);
    }
}

test "segment sum family AOT registry executes on live CUDA" {
    try runSegmentSumFamilyOnLiveCuda(.{
        .segments = 3,
        .total = 12,
        .threads = 4,
    });
}

test "segment sum warp family AOT registry executes on live CUDA" {
    try runSegmentSumFamilyOnLiveCuda(.{
        .segments = 3,
        .total = 12,
        .granularity = .warp,
        .threads = 32,
    });
}

fn semanticPrefixSumFamilyModule(allocator: std.mem.Allocator, family_target: []const u8, extent: i64) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const data_ty = try builder.tensor(.f32, &.{extent});
    var fb = try builder.beginFunction("semantic_prefix_sum_kernel_call_family", &.{data_ty}, &.{data_ty});
    const call = try fb.kernelCall(
        &.{fb.parameter(0)},
        &.{data_ty},
        .{
            .target = family_target,
            .version = kernel.library.scan.prefix_sum_family_version,
            .operand_effects = &.{.read},
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    return try builder.finish();
}

fn runPrefixSumFamilyOnLiveCuda(instance: kernel.library.scan.PrefixSum) !void {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    var call_artifact = try kernel.library.scan.createPrefixSumFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const family_target = try kernel.library.scan.prefixSumFamilyTarget(allocator, instance);
    defer allocator.free(family_target);
    const module = try semanticPrefixSumFamilyModule(allocator, family_target, 100);

    const registry = decoded.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    var data: [100]f32 = undefined;
    for (&data, 0..) |*value, index| value.* = @floatFromInt((index % 7) + 1);
    var expected: [100]f32 = undefined;
    var running: f32 = 0;
    for (data, 0..) |value, index| {
        switch (instance.mode) {
            .inclusive => {
                running += value;
                expected[index] = running;
            },
            .exclusive => {
                expected[index] = running;
                running += value;
            },
        }
    }

    const input_bytes = [_][]const u8{std.mem.sliceAsBytes(data[0..])};
    const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
    defer bindings.deinit();

    const runtime_args = try kernel.library.scan.prefixSumRuntimeArguments(instance);
    try bindings.launchWithOptions(allocator, .{
        .runtime_scalar_arguments = runtime_args[0..],
    });

    var actual = @as([100]f32, @splat(0.0));
    try bindings.readOutput(0, std.mem.sliceAsBytes(actual[0..]));

    for (expected, actual) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.001);
    }
}

fn semanticScatterRoutingModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const data_ty = try builder.tensor(.f32, &.{8});
    const indices_ty = try builder.tensor(.i32, &.{5});
    const updates_ty = try builder.tensor(.f32, &.{5});
    var fb = try builder.beginFunction("semantic_scatter_routing_family", &.{ data_ty, indices_ty, updates_ty }, &.{data_ty});
    const out = try fb.scatter(fb.parameter(0), fb.parameter(1), fb.parameter(2), data_ty, 0);
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

test "semantic scatter family routes and executes on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    const instance = kernel.library.indexing.Scatter{
        .axis_size = 8,
        .updates = 5,
        .threads = 8,
    };
    var call_artifact = try kernel.library.indexing.createScatterFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const module = try semanticScatterRoutingModule(allocator);

    const registry = decoded.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{
            .kernel_call_registry = &registry,
            .scatter_schedule = .{ .thread_blocks = 8 },
        },
    );
    defer fragment.deinit();

    const data = [_]f32{ 10, 11, 12, 13, 14, 15, 16, 17 };
    const indices = [_]i32{ 3, 0, 3, 9, 1 };
    const updates = [_]f32{ 100, 200, 300, 400, 500 };
    const expected = [_]f32{ 200, 500, 12, 300, 14, 15, 16, 17 };

    const input_bytes = [_][]const u8{
        std.mem.sliceAsBytes(data[0..]),
        std.mem.sliceAsBytes(indices[0..]),
        std.mem.sliceAsBytes(updates[0..]),
    };
    const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
    defer bindings.deinit();

    const runtime_args = try kernel.library.indexing.scatterRuntimeArguments(instance);
    try bindings.launchWithOptions(allocator, .{
        .runtime_scalar_arguments = runtime_args[0..],
    });

    var actual = @as([8]f32, @splat(0.0));
    try bindings.readOutput(0, std.mem.sliceAsBytes(actual[0..]));

    for (expected, actual) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.0001);
    }
}

fn semanticScatterFamilyModule(allocator: std.mem.Allocator, family_target: []const u8) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const data_ty = try builder.tensor(.f32, &.{8});
    const indices_ty = try builder.tensor(.i32, &.{4});
    const updates_ty = try builder.tensor(.f32, &.{4});
    const out_ty = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction("semantic_scatter_kernel_call_family", &.{ data_ty, indices_ty, updates_ty }, &.{out_ty});
    const call = try fb.kernelCall(
        &.{ fb.parameter(0), fb.parameter(1), fb.parameter(2) },
        &.{out_ty},
        .{
            .target = family_target,
            .version = kernel.library.indexing.scatter_family_version,
            .operand_effects = &.{ .read, .read, .read },
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    return try builder.finish();
}

test "scatter family AOT registry executes on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    const instance = kernel.library.indexing.Scatter{
        .axis_size = 8,
        .updates = 4,
        .threads = 8,
    };
    var call_artifact = try kernel.library.indexing.createScatterFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{call_artifact.entry()};
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const family_target = try kernel.library.indexing.scatterFamilyTarget(allocator, instance);
    defer allocator.free(family_target);
    const module = try semanticScatterFamilyModule(allocator, family_target);

    const registry = decoded.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    const data = [_]f32{ 10, 11, 12, 13, 14, 15, 16, 17 };
    const indices = [_]i32{ 3, 0, 3, 9 };
    const updates = [_]f32{ 100, 200, 300, 400 };
    const expected = [_]f32{ 200, 11, 12, 300, 14, 15, 16, 17 };

    const input_bytes = [_][]const u8{
        std.mem.sliceAsBytes(data[0..]),
        std.mem.sliceAsBytes(indices[0..]),
        std.mem.sliceAsBytes(updates[0..]),
    };
    const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
    defer bindings.deinit();

    const runtime_args = try kernel.library.indexing.scatterRuntimeArguments(instance);
    try bindings.launchWithOptions(allocator, .{
        .runtime_scalar_arguments = runtime_args[0..],
    });

    var actual = @as([8]f32, @splat(0.0));
    try bindings.readOutput(0, std.mem.sliceAsBytes(actual[0..]));

    for (expected, actual) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.0001);
    }
}

test "semantic einsum matrix vector product family lowers through kernel library registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const matrix_dims = [_]i64{ 4, 8 };
    const vector_dims = [_]i64{8};
    const output_dims = [_]i64{4};
    var selected = (try kernel.library.selectOwned(allocator, .{ .matrix_vector_product = .{
        .dtype = .f32,
        .matrix_indices = "mk",
        .vector_indices = "k",
        .output_indices = "m",
        .matrix_dims = &matrix_dims,
        .vector_dims = &vector_dims,
        .output_dims = &output_dims,
    } })) orelse return error.TestExpectedCatalogDescriptor;
    defer selected.deinit();

    var call_artifact = try kernel.library.createOwnedKernelCallArtifact(
        allocator,
        state.handle(),
        selected,
        .{ .limits = .testing },
    );
    defer call_artifact.deinit();

    const module = try semanticEinsumMatrixVectorProductModule(allocator);

    const registry = call_artifact.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.kernel_call, summary.source);
    try std.testing.expectEqualStrings(selected.descriptor.name, summary.entry_name);
    try std.testing.expectEqual(@as(u32, 5), summary.compile_argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{ .f32, .i32 }).bits, summary.compile_required_dtype_bits);
    try std.testing.expectEqual(@as(u32, 2), summary.runtime_scalar_argument_count);
    try std.testing.expect(summary.fixed_threadgroup);
    try std.testing.expectEqual(@as(usize, 1), summary.launch_candidate_count);
    try std.testing.expectEqual(@as(u32, 1), summary.launch_geometry.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), summary.launch_geometry.threadgroup[0]);
}

fn initCudaStateOrSkip(allocator: std.mem.Allocator) !gpu.cuda.State {
    try gating.skipIfBuildFlagDisabled(.cuda);
    if (!gpu.cuda.platformSupported()) return gating.skip(.cuda, .unsupported_platform);
    return gpu.cuda.State.initDevice(allocator, 0) catch |err| switch (err) {
        error.RuntimeUnavailable => return gating.skip(.cuda, .cuda_device_missing),
        else => return err,
    };
}

fn fillMatrixProductExpected(
    out: []f32,
    lhs: []const f32,
    rhs: []const f32,
    m: u64,
    n: u64,
    k: u64,
) void {
    const rows: usize = @intCast(m);
    const cols: usize = @intCast(n);
    const reduction: usize = @intCast(k);
    for (0..rows) |row| {
        for (0..cols) |col| {
            var sum: f32 = 0.0;
            for (0..reduction) |offset| {
                sum += lhs[row * reduction + offset] * rhs[offset * cols + col];
            }
            out[row * cols + col] = sum;
        }
    }
}

fn fillGatherExpected(
    out: []f32,
    data: []const f32,
    indices: []const i32,
    outer: usize,
    axis_size: usize,
    inner: usize,
) void {
    const gathered = indices.len;
    for (0..outer) |outer_index| {
        for (0..gathered) |gathered_index| {
            var index = indices[gathered_index];
            if (index < 0) index = 0;
            const limit: i32 = @intCast(axis_size - 1);
            if (index > limit) index = limit;
            const src_base = (outer_index * axis_size + @as(usize, @intCast(index))) * inner;
            const dst_base = (outer_index * gathered + gathered_index) * inner;
            for (0..inner) |inner_index| {
                out[dst_base + inner_index] = data[src_base + inner_index];
            }
        }
    }
}

test "semantic relu lowers through kernel library registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try kernel.library.createKernelCallArtifact(allocator, state.handle(), .{
        .target = KernelCallRelu.target,
        .version = KernelCallRelu.version,
        .options = .{ .limits = KernelCallRelu.Limits.testing },
    });
    defer call_artifact.deinit();

    const module = try semanticReluModule(allocator);

    const registry = call_artifact.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.kernel_call, summary.source);
    try std.testing.expectEqualStrings(KernelCallRelu.name, summary.entry_name);
    try std.testing.expectEqual(@as(u32, 2), summary.compile_argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, summary.compile_required_dtype_bits);
    try std.testing.expect(summary.fixed_threadgroup);
    try std.testing.expectEqual(@as(u32, 2), summary.launch_geometry.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), summary.launch_geometry.threadgroup[0]);
}

test "semantic relu prepares without kernel library registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const module = try semanticReluModule(allocator);

    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{},
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.tensor, summary.source);
}

test "semantic gelu activation lowers through kernel library registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try kernel.library.createKernelCallArtifact(allocator, state.handle(), .{
        .target = KernelCallGelu.target,
        .version = KernelCallGelu.version,
        .options = .{ .limits = KernelCallGelu.Limits.testing },
    });
    defer call_artifact.deinit();

    const module = try semanticGeluActivationModule(allocator);

    const registry = call_artifact.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.kernel_call, summary.source);
    try std.testing.expectEqualStrings(KernelCallGelu.name, summary.entry_name);
    try std.testing.expectEqual(@as(u32, 2), summary.compile_argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, summary.compile_required_dtype_bits);
    try std.testing.expect(summary.fixed_threadgroup);
    try std.testing.expectEqual(@as(u32, 2), summary.launch_geometry.grid[0]);
    try std.testing.expectEqual(@as(u32, 4), summary.launch_geometry.threadgroup[0]);
}

test "semantic gelu activation prepares without kernel library registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const module = try semanticGeluActivationModule(allocator);

    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{},
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.tensor, summary.source);
}

test "semantic einsum transpose lowers through kernel library registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try kernel.library.createKernelCallArtifact(allocator, state.handle(), .{
        .target = KernelCallTranspose.target,
        .version = KernelCallTranspose.version,
        .options = .{ .limits = KernelCallTranspose.Limits.testing },
    });
    defer call_artifact.deinit();

    const module = try semanticEinsumTransposeModule(allocator);

    const registry = call_artifact.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.kernel_call, summary.source);
    try std.testing.expectEqualStrings(KernelCallTranspose.name, summary.entry_name);
    try std.testing.expectEqual(@as(u32, 2), summary.compile_argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, summary.compile_required_dtype_bits);
    try std.testing.expect(summary.fixed_threadgroup);
    try std.testing.expectEqual(@as(u32, 2), summary.launch_geometry.grid[0]);
    try std.testing.expectEqual(@as(u32, 2), summary.launch_geometry.grid[1]);
    try std.testing.expectEqual(@as(u32, 8), summary.launch_geometry.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 4), summary.launch_geometry.threadgroup[1]);
}

test "semantic einsum dot product lowers through kernel library registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    var call_artifact = try kernel.library.createKernelCallArtifact(allocator, state.handle(), .{
        .target = KernelCallDot.target,
        .version = KernelCallDot.version,
        .options = .{ .limits = KernelCallDot.Limits.testing },
    });
    defer call_artifact.deinit();

    const module = try semanticEinsumDotModule(allocator);

    const registry = call_artifact.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.kernel_call, summary.source);
    try std.testing.expectEqualStrings(KernelCallDot.name, summary.entry_name);
    try std.testing.expectEqual(@as(u32, 3), summary.compile_argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, summary.compile_required_dtype_bits);
    try std.testing.expect(summary.fixed_threadgroup);
    try std.testing.expectEqual(@as(u32, 1), summary.launch_geometry.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), summary.launch_geometry.threadgroup[0]);
}

test "semantic einsum transpose prepares without kernel library registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const module = try semanticEinsumTransposeModule(allocator);

    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{},
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.tensor, summary.source);
}

test "semantic row normalization selection resolves through kernel library registry" {
    const allocator = std.testing.allocator;

    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const selected = kernel.logical.selectRowNormalizationCatalog(.{
        .dtype = .f32,
        .kind = .softmax,
        .rows = 2,
        .cols = 4,
    }) orelse return error.TestExpectedRowNormalizationSelection;

    var call_artifact = try kernel.library.createKernelCallArtifact(allocator, state.handle(), .{
        .target = selected.descriptor.metadata.target,
        .version = selected.descriptor.metadata.version,
        .options = .{ .limits = kernel.Limits.testing },
    });
    defer call_artifact.deinit();

    const module = try semanticKernelCallRowSoftmaxModule(allocator, selected.descriptor);

    const registry = call_artifact.registry();
    var fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        module,
        .{ .kernel_call_registry = &registry },
    );
    defer fragment.deinit();

    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
    const summary = try fragment.kernelSummary(0);
    try std.testing.expectEqual(ArtifactKernelSource.kernel_call, summary.source);
    try std.testing.expectEqualStrings(selected.descriptor.name, summary.entry_name);
    try std.testing.expectEqual(@as(u32, 2), summary.compile_argument_count);
    try std.testing.expectEqual(gpu.DTypeSet.init(&.{.f32}).bits, summary.compile_required_dtype_bits);
    try std.testing.expect(summary.fixed_threadgroup);
    try std.testing.expectEqual(@as(u32, 1), summary.launch_geometry.grid[0]);
    try std.testing.expectEqual(@as(u32, 1), summary.launch_geometry.grid[1]);
    try std.testing.expectEqual(@as(u32, 4), summary.launch_geometry.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), summary.launch_geometry.threadgroup[1]);
}

fn semanticShiftPadModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const vec_ty = try builder.tensor(.f32, &.{8});
    const scalar_ty = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction("semantic_shift_pad", &.{vec_ty}, &.{vec_ty});
    const zero: f32 = 0;
    const pad_value = try fb.constant(scalar_ty, std.mem.asBytes(&zero));
    const out = try fb.pad(fb.parameter(0), pad_value, vec_ty, &.{1}, &.{-1}, &.{0});
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

test "negative edge pad lowers through the cuda executable path" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const module = try semanticShiftPadModule(allocator);
    var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), module, .{});
    defer fragment.deinit();
    try std.testing.expectEqual(@as(usize, 1), fragment.kernelCount());
}

test "negative edge pad shifts elements on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    const module = try semanticShiftPadModule(allocator);
    var fragment = try compileAndLoadSemanticModule(allocator, state.handle(), module, .{});
    defer fragment.deinit();

    var data: [8]f32 = undefined;
    for (&data, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    const expected = [_]f32{ 0, 1, 2, 3, 4, 5, 6, 7 };

    const input_bytes = [_][]const u8{std.mem.sliceAsBytes(data[0..])};
    const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
    defer bindings.deinit();

    try bindings.launchWithOptions(allocator, .{});

    var actual = @as([8]f32, @splat(0.0));
    try bindings.readOutput(0, std.mem.sliceAsBytes(actual[0..]));

    for (expected, actual) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.0001);
    }
}

fn semanticEinsumTunedMatmulModule(allocator: std.mem.Allocator) !*SemanticModule {
    var builder = try SemanticBuilder.init(allocator, SemanticBuilder.ContextLimits.standard);
    errdefer builder.deinit();
    const lhs_ty = try builder.tensor(.f32, &.{ 64, 32 });
    const rhs_ty = try builder.tensor(.f32, &.{ 32, 64 });
    const out_ty = try builder.tensor(.f32, &.{ 64, 64 });
    var fb = try builder.beginFunction("semantic_einsum_family_tuning_round_trip", &.{ lhs_ty, rhs_ty }, &.{out_ty});
    const out = try fb.einsum(&.{ fb.parameter(0), fb.parameter(1) }, out_ty, "mk,kn->mn");
    try fb.return_(&.{out});
    try fb.finish();
    return try builder.finish();
}

test "family tuning round trip selects the measured winner on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();

    const linalg = kernel.library.linalg;
    const tuning = kernel.library.tuning;
    const probe = linalg.MatrixProduct{ .m = 64, .n = 64, .k = 32 };
    const caps = try state.handle().queryCapabilities();
    const device = tuning.deviceFingerprint(caps);

    const thread_candidates = linalg.matrixProductThreadCandidatesForExtents(probe.m, probe.n);
    try std.testing.expect(thread_candidates.slice().len >= 2);

    var artifacts = std.ArrayListUnmanaged(kernel.OwnedKernelCallArtifact).empty;
    defer {
        for (artifacts.items) |*owned| owned.deinit();
        artifacts.deinit(allocator);
    }
    for (thread_candidates.slice()) |threads| {
        var instance = probe;
        instance.threads = threads;
        const call_artifact = try linalg.createMatrixProductFamilyArtifact(
            allocator,
            state.handle(),
            instance,
            .{ .limits = .testing },
        );
        try artifacts.append(allocator, call_artifact);
    }

    var entries = std.ArrayListUnmanaged(artifact.KernelCallArtifact).empty;
    defer entries.deinit(allocator);
    for (artifacts.items) |*owned| {
        try entries.append(allocator, owned.entry());
    }
    const encoded = try artifact.wire.encode(allocator, entries.items, &.{});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();
    const registry = decoded.registry();

    var lhs: [64 * 32]f32 = undefined;
    for (lhs[0..], 0..) |*value, index| value.* = @floatFromInt((index % 13) + 1);
    var rhs: [32 * 64]f32 = undefined;
    for (rhs[0..], 0..) |*value, index| value.* = @floatFromInt((index % 7) + 2);
    const input_bytes = [_][]const u8{
        std.mem.sliceAsBytes(lhs[0..]),
        std.mem.sliceAsBytes(rhs[0..]),
    };

    var accumulator = tuning.FamilyMeasurementAccumulator.init(allocator);
    defer accumulator.deinit();

    for (thread_candidates.slice()) |threads| {
        var instance = probe;
        instance.threads = threads;
        const measured_target = try linalg.matrixProductFamilyTarget(allocator, instance);
        defer allocator.free(measured_target);
        const entry_name = try linalg.matrixProductFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);

        const module = try semanticEinsumTunedMatmulModule(allocator);
        var fragment = try compileAndLoadSemanticModule(
            allocator,
            state.handle(),
            module,
            .{
                .kernel_call_registry = &registry,
                .matrix_product_schedule = .{ .thread_blocks = threads },
            },
        );
        defer fragment.deinit();

        const bindings = try prepareInvocation(fragment, allocator, input_bytes[0..]);
        defer bindings.deinit();

        var kernel_index: usize = 0;
        var family_kernel_index: ?usize = null;
        while (kernel_index < fragment.kernelCount()) : (kernel_index += 1) {
            const summary = try fragment.kernelSummary(kernel_index);
            if (std.mem.eql(u8, summary.entry_name, entry_name)) {
                family_kernel_index = kernel_index;
                break;
            }
        }
        const measured_index = family_kernel_index orelse return error.TestExpectedFamilyKernel;

        const runtime_arguments = try linalg.matrixProductRuntimeArguments(instance);
        const records = try bindings.measureLaunchCandidateRecords(
            allocator,
            allocator,
            measured_index,
            .{
                .warmup = 2,
                .samples = 8,
                .base_options = .{ .runtime_scalar_arguments = runtime_arguments[0..] },
                .synchronize = .device,
            },
        );
        defer allocator.free(records);
        try std.testing.expect(records.len >= 1);

        var best = records[0];
        for (records[1..]) |record| {
            if (record.median_ns < best.median_ns) best = record;
        }
        const key = try kernel.library.linalg.matrixProductFamilyTuningKey(allocator, device, instance);
        try accumulator.append(key, measured_target, best.median_ns, best.sample_count);
    }

    var winners = try accumulator.selectWinners(allocator, 0);
    defer winners.deinit();
    try std.testing.expectEqual(@as(usize, 1), winners.records.len);
    const winner = winners.records[0];

    const reader = tuning.FamilyTuningReader.init(caps, winners.table());
    const tuned_module = try semanticEinsumTunedMatmulModule(allocator);
    var tuned_fragment = try compileAndLoadSemanticModule(
        allocator,
        state.handle(),
        tuned_module,
        .{
            .kernel_call_registry = &registry,
            .family_tuning = &reader,
        },
    );
    defer tuned_fragment.deinit();

    var winner_entry_seen = false;
    var kernel_index: usize = 0;
    while (kernel_index < tuned_fragment.kernelCount()) : (kernel_index += 1) {
        const summary = try tuned_fragment.kernelSummary(kernel_index);
        for (thread_candidates.slice()) |threads| {
            var instance = probe;
            instance.threads = threads;
            const candidate_entry = try linalg.matrixProductFamilyEntryName(allocator, instance);
            defer allocator.free(candidate_entry);
            if (!std.mem.eql(u8, summary.entry_name, candidate_entry)) continue;
            const candidate_target = try linalg.matrixProductFamilyTarget(allocator, instance);
            defer allocator.free(candidate_target);
            try std.testing.expectEqualStrings(winner.target, candidate_target);
            winner_entry_seen = true;
        }
    }
    try std.testing.expect(winner_entry_seen);

    const tuned_bindings = try prepareInvocation(tuned_fragment, allocator, input_bytes[0..]);
    defer tuned_bindings.deinit();
    const tuned_runtime_arguments = try linalg.matrixProductRuntimeArguments(probe);
    try tuned_bindings.launchWithOptions(allocator, .{
        .runtime_scalar_arguments = tuned_runtime_arguments[0..],
    });

    var actual = @as([(64 * 64)]f32, @splat(0));
    try tuned_bindings.readOutput(0, std.mem.sliceAsBytes(actual[0..]));

    var expected = @as([(64 * 64)]f32, @splat(0));
    for (0..64) |row| {
        for (0..64) |col| {
            var accumulated: f32 = 0;
            for (0..32) |inner| {
                accumulated += lhs[row * 32 + inner] * rhs[inner * 64 + col];
            }
            expected[row * 64 + col] = accumulated;
        }
    }
    for (expected, actual) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.001);
    }
}

test "scatter add family kernel accumulates exactly on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    const indexing_library = kernel.library.indexing;
    const instance = indexing_library.ScatterAdd{ .axis_size = 8, .updates = 5, .threads = 32 };
    const entry_name = try indexing_library.scatterAddFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);

    var graph = try indexing_library.ScatterAddRuntimeFamilyI32.buildNamed(allocator, indexing_library.ScatterAddRuntimeFamilyI32.Limits.testing, entry_name, instance);
    defer graph.deinit();
    var kernel_artifact = try kernel.createKernelArtifact(allocator, handle, &graph, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "choir/kernel/scatter-add-live",
    });
    defer kernel_artifact.deinit();
    const loaded = try handle.loadArtifact(&kernel_artifact);

    var dst = [_]i32{ 5, 5, 5, 5, 5, 5, 5, 5 };
    var indices = [_]i32{ 3, 0, 3, 9, 1 };
    var updates = [_]i32{ 100, 200, 300, 400, 500 };
    const expected = [_]i32{ 205, 505, 5, 405, 5, 5, 5, 5 };

    const host_views = [_][]u8{
        std.mem.sliceAsBytes(dst[0..]),
        std.mem.sliceAsBytes(dst[0..]),
        std.mem.sliceAsBytes(indices[0..]),
        std.mem.sliceAsBytes(updates[0..]),
    };
    const accesses = [_]gpu.BufferAccess{ .read_write, .read_only, .read_only, .read_only };

    var bindings: [4]gpu.BufferBinding = undefined;
    for (host_views, accesses, 0..) |bytes, access, slot| {
        const buffer = try handle.allocateBuffer(.{
            .byte_size = bytes.len,
            .alignment = 256,
            .dtype = .i32,
            .element_count = bytes.len / @sizeOf(i32),
        });
        try handle.writeBuffer(.{ .handle = buffer, .bytes = bytes });
        bindings[slot] = .{
            .handle = buffer,
            .access = access,
            .ownership = buffer.ownership,
            .byte_size = buffer.byte_size,
        };
    }

    const runtime_arguments = try indexing_library.scatterAddRuntimeArguments(instance);
    try handle.launch(.{
        .artifact = &kernel_artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = runtime_arguments[0..],
        .geometry = .{
            .grid = .{ 1, 1, 1 },
            .threadgroup = .{ instance.threads, 1, 1 },
        },
    });
    try handle.synchronize(.{ .scope = .device });

    var actual = @as([8]i32, @splat(0));
    try handle.readBuffer(.{ .handle = bindings[0].handle, .bytes = std.mem.sliceAsBytes(actual[0..]) });
    try std.testing.expectEqualSlices(i32, expected[0..], actual[0..]);
}

test "scatter add f32 family kernel accumulates within tolerance on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    const indexing_library = kernel.library.indexing;
    const bin_count: usize = 16;
    const update_count: usize = 4096;
    const instance = indexing_library.ScatterAdd{
        .axis_size = bin_count,
        .updates = update_count,
        .dtype = .f32,
        .threads = 128,
    };
    const entry_name = try indexing_library.scatterAddFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);

    var graph = try indexing_library.ScatterAddRuntimeFamilyF32.buildNamed(allocator, indexing_library.ScatterAddRuntimeFamilyF32.Limits.testing, entry_name, instance);
    defer graph.deinit();
    var kernel_artifact = try kernel.createKernelArtifact(allocator, handle, &graph, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "choir/kernel/scatter-add-f32-live",
    });
    defer kernel_artifact.deinit();
    const loaded = try handle.loadArtifact(&kernel_artifact);

    var dst = @as([bin_count]f32, @splat(0));
    var indices: [update_count]i32 = undefined;
    var updates: [update_count]f32 = undefined;
    for (0..update_count) |u| {
        indices[u] = @intCast((u * 7 + 3) % bin_count);
        updates[u] = 0.5 + @as(f32, @floatFromInt((u * 13) % 100)) * 0.01;
    }

    var expected = @as([bin_count]f32, @splat(0));
    for (0..update_count) |u| {
        expected[@intCast(indices[u])] += updates[u];
    }

    const host_views = [_][]u8{
        std.mem.sliceAsBytes(dst[0..]),
        std.mem.sliceAsBytes(dst[0..]),
        std.mem.sliceAsBytes(indices[0..]),
        std.mem.sliceAsBytes(updates[0..]),
    };
    const dtypes = [_]gpu_abi.DType{ .f32, .f32, .i32, .f32 };
    const accesses = [_]gpu.BufferAccess{ .read_write, .read_only, .read_only, .read_only };

    var bindings: [4]gpu.BufferBinding = undefined;
    for (host_views, dtypes, accesses, 0..) |bytes, buffer_dtype, access, slot| {
        const buffer = try handle.allocateBuffer(.{
            .byte_size = bytes.len,
            .alignment = 256,
            .dtype = buffer_dtype,
            .element_count = bytes.len / 4,
        });
        try handle.writeBuffer(.{ .handle = buffer, .bytes = bytes });
        bindings[slot] = .{
            .handle = buffer,
            .access = access,
            .ownership = buffer.ownership,
            .byte_size = buffer.byte_size,
        };
    }

    const runtime_arguments = try indexing_library.scatterAddRuntimeArguments(instance);
    try handle.launch(.{
        .artifact = &kernel_artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = runtime_arguments[0..],
        .geometry = .{
            .grid = .{ @intCast((update_count + 127) / 128), 1, 1 },
            .threadgroup = .{ instance.threads, 1, 1 },
        },
    });
    try handle.synchronize(.{ .scope = .device });

    var actual = @as([bin_count]f32, @splat(0));
    try handle.readBuffer(.{ .handle = bindings[0].handle, .bytes = std.mem.sliceAsBytes(actual[0..]) });
    for (expected, actual) |want, got| {
        try std.testing.expectApproxEqAbs(want, got, 0.05);
    }
}

test "scatter add shared bins variant accumulates exactly on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    const indexing_library = kernel.library.indexing;
    const bin_count: usize = 64;
    const update_count: usize = 4096;
    const instance = indexing_library.ScatterAdd{
        .axis_size = bin_count,
        .updates = update_count,
        .variant = .shared_bins,
        .threads = 128,
    };
    const entry_name = try indexing_library.scatterAddFamilyEntryName(allocator, instance);
    defer allocator.free(entry_name);

    var graph = try indexing_library.ScatterAddRuntimeFamilyI32.buildNamed(allocator, indexing_library.ScatterAddRuntimeFamilyI32.Limits.testing, entry_name, instance);
    defer graph.deinit();
    var kernel_artifact = try kernel.createKernelArtifact(allocator, handle, &graph, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "choir/kernel/scatter-add-shared-live",
    });
    defer kernel_artifact.deinit();
    const loaded = try handle.loadArtifact(&kernel_artifact);

    var dst = @as([bin_count]i32, @splat(0));
    var indices: [update_count]i32 = undefined;
    var updates: [update_count]i32 = undefined;
    for (0..update_count) |u| {
        indices[u] = @intCast((u * 11 + 5) % bin_count);
        updates[u] = @intCast((u % 9) + 1);
    }

    var expected = @as([bin_count]i32, @splat(0));
    for (indices, updates) |index, update| {
        expected[@intCast(index)] += update;
    }

    const host_views = [_][]u8{
        std.mem.sliceAsBytes(dst[0..]),
        std.mem.sliceAsBytes(dst[0..]),
        std.mem.sliceAsBytes(indices[0..]),
        std.mem.sliceAsBytes(updates[0..]),
    };
    const accesses = [_]gpu.BufferAccess{ .read_write, .read_only, .read_only, .read_only };

    var bindings: [4]gpu.BufferBinding = undefined;
    for (host_views, accesses, 0..) |bytes, access, slot| {
        const buffer = try handle.allocateBuffer(.{
            .byte_size = bytes.len,
            .alignment = 256,
            .dtype = .i32,
            .element_count = bytes.len / @sizeOf(i32),
        });
        try handle.writeBuffer(.{ .handle = buffer, .bytes = bytes });
        bindings[slot] = .{
            .handle = buffer,
            .access = access,
            .ownership = buffer.ownership,
            .byte_size = buffer.byte_size,
        };
    }

    const runtime_arguments = try indexing_library.scatterAddRuntimeArguments(instance);
    try handle.launch(.{
        .artifact = &kernel_artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .scalar_arguments = runtime_arguments[0..],
        .geometry = .{
            .grid = .{ @intCast((update_count + 127) / 128), 1, 1 },
            .threadgroup = .{ instance.threads, 1, 1 },
        },
    });
    try handle.synchronize(.{ .scope = .device });

    var actual = @as([bin_count]i32, @splat(0));
    try handle.readBuffer(.{ .handle = bindings[0].handle, .bytes = std.mem.sliceAsBytes(actual[0..]) });
    try std.testing.expectEqualSlices(i32, expected[0..], actual[0..]);
}
fn expectDeviceScanPipelineOnLiveCuda(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    extent: usize,
    threads: u32,
    mode: kernel.library.scan.PrefixSumMode,
) !void {
    const scan_library = kernel.library.scan;
    const instance = scan_library.DeviceScan{ .extent = extent, .threads = threads, .mode = mode };
    const stages = try scan_library.deviceScanStages(instance);
    const expected_blocks: u32 = @intCast(scan_library.deviceScanBlockCount(extent, threads));
    try std.testing.expectEqual(expected_blocks, stages.block_count);

    var artifacts = try scan_library.createDeviceScanPipelineArtifacts(allocator, handle, instance, .{
        .limits = kernel.Limits.testing,
    });
    defer artifacts.deinit();
    const entries = artifacts.entries();

    var owned_pipeline = try scan_library.deviceScanPipeline(allocator, instance);
    defer owned_pipeline.deinit();

    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{owned_pipeline.value});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();
    const product_target = try scan_library.deviceScanFamilyTarget(allocator, instance);
    defer allocator.free(product_target);
    const found = artifact.findPipeline(
        decoded.pipelines,
        product_target,
        scan_library.device_scan_family_version,
    ) orelse return error.TestExpectedPipeline;

    const data = try allocator.alloc(f32, extent);
    defer allocator.free(data);
    for (data, 0..) |*value, index| value.* = @floatFromInt((index % 7) + 1);
    const zero_dst = try allocator.alloc(f32, extent);
    defer allocator.free(zero_dst);
    @memset(zero_dst, 0);

    const host_views = [_][]const u8{
        std.mem.sliceAsBytes(data),
        std.mem.sliceAsBytes(zero_dst),
    };
    var bindings: [2]gpu.BufferBinding = undefined;
    for (host_views, 0..) |bytes, slot| {
        const buffer = try handle.allocateBuffer(.{
            .byte_size = bytes.len,
            .alignment = 256,
            .dtype = .f32,
            .element_count = bytes.len / @sizeOf(f32),
        });
        try handle.writeBuffer(.{ .handle = buffer, .bytes = bytes });
        bindings[slot] = .{
            .handle = buffer,
            .access = if (slot == 0) .read_only else .read_write,
            .ownership = buffer.ownership,
            .byte_size = buffer.byte_size,
        };
    }

    try executable.launchPipeline(allocator, handle, .{
        .pipeline = found,
        .registry = decoded.registry(),
        .format = .cuda_ptx,
        .operands = bindings[0..1],
        .results = bindings[1..2],
        .runtime_scalar_arguments = &.{.{ .u32 = @intCast(extent) }},
    });

    const actual = try allocator.alloc(f32, extent);
    defer allocator.free(actual);
    try handle.readBuffer(.{ .handle = bindings[1].handle, .bytes = std.mem.sliceAsBytes(actual) });

    var running: f32 = 0;
    for (data, actual) |value, got| {
        switch (mode) {
            .inclusive => {
                running += value;
                try std.testing.expectEqual(running, got);
            },
            .exclusive => {
                try std.testing.expectEqual(running, got);
                running += value;
            },
        }
    }
}

test "scan device-wide pipeline launches three stages through the registry on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    try expectDeviceScanPipelineOnLiveCuda(allocator, handle, 5000, 64, .inclusive);
    try expectDeviceScanPipelineOnLiveCuda(allocator, handle, 5000, 64, .exclusive);
    try expectDeviceScanPipelineOnLiveCuda(allocator, handle, 33, 32, .inclusive);
}

test "scan device-wide pipeline reaches the million-element cap on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    try expectDeviceScanPipelineOnLiveCuda(allocator, handle, 1 << 20, 1024, .inclusive);
}

test "scan query selects dispatches and launches the device scan pipeline on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    const library = kernel.library;
    const extent: usize = 5000;

    var owned_descriptor = (try library.catalog.selectOwned(allocator, .{ .scan = .{
        .dtype = .f32,
        .kind = .prefix_sum,
        .extent = extent,
    } })) orelse return error.TestExpectedCatalogDescriptor;
    defer owned_descriptor.deinit();

    var package = (try library.createOwnedKernelCallPipelinePackage(allocator, handle, owned_descriptor, .{ .limits = .testing })) orelse {
        return error.TestExpectedPipelinePackage;
    };
    defer package.deinit();

    const encoded = try artifact.wire.encode(allocator, package.entries, &.{package.pipeline.value});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();
    const found = artifact.findPipeline(
        decoded.pipelines,
        package.pipeline.value.target,
        library.scan.device_scan_family_version,
    ) orelse return error.TestExpectedPipeline;

    const data = try allocator.alloc(f32, extent);
    defer allocator.free(data);
    for (data, 0..) |*value, index| value.* = @floatFromInt((index % 7) + 1);
    const zero_dst = try allocator.alloc(f32, extent);
    defer allocator.free(zero_dst);
    @memset(zero_dst, 0);

    const host_views = [_][]const u8{
        std.mem.sliceAsBytes(data),
        std.mem.sliceAsBytes(zero_dst),
    };
    var bindings: [2]gpu.BufferBinding = undefined;
    for (host_views, 0..) |bytes, slot| {
        const buffer = try handle.allocateBuffer(.{
            .byte_size = bytes.len,
            .alignment = 256,
            .dtype = .f32,
            .element_count = bytes.len / @sizeOf(f32),
        });
        try handle.writeBuffer(.{ .handle = buffer, .bytes = bytes });
        bindings[slot] = .{
            .handle = buffer,
            .access = if (slot == 0) .read_only else .read_write,
            .ownership = buffer.ownership,
            .byte_size = buffer.byte_size,
        };
    }

    try executable.launchPipeline(allocator, handle, .{
        .pipeline = found,
        .registry = decoded.registry(),
        .format = .cuda_ptx,
        .operands = bindings[0..1],
        .results = bindings[1..2],
        .runtime_scalar_arguments = &.{.{ .u32 = @intCast(extent) }},
    });

    const actual = try allocator.alloc(f32, extent);
    defer allocator.free(actual);
    try handle.readBuffer(.{ .handle = bindings[1].handle, .bytes = std.mem.sliceAsBytes(actual) });

    var running: f32 = 0;
    for (data, actual) |value, got| {
        running += value;
        try std.testing.expectEqual(running, got);
    }
}

test "sort radix split kernels partition stably on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    const sort_library = kernel.library.sort;
    const extent: usize = 5000;
    const bit: u32 = 3;
    const instance = sort_library.RadixSplit{ .extent = extent, .threads = 64 };
    const blocks: u32 = @intCast(sort_library.radixSplitBlockCount(extent, instance.threads));

    const keys = try allocator.alloc(i32, extent);
    defer allocator.free(keys);
    var seed: u32 = 0x2545f491;
    for (keys, 0..) |*key, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        key.* = @intCast((seed >> 8) % 100000 * 10 + index % 10);
    }

    const keys_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(i32),
        .alignment = 256,
        .dtype = .i32,
        .element_count = extent,
    });
    try handle.writeBuffer(.{ .handle = keys_buffer, .bytes = std.mem.sliceAsBytes(keys) });
    const flags_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(f32),
        .alignment = 256,
        .dtype = .f32,
        .element_count = extent,
    });
    const scanned_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(f32),
        .alignment = 256,
        .dtype = .f32,
        .element_count = extent,
    });
    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(i32),
        .alignment = 256,
        .dtype = .i32,
        .element_count = extent,
    });

    const keys_binding = gpu.BufferBinding{
        .handle = keys_buffer,
        .access = .read_only,
        .ownership = keys_buffer.ownership,
        .byte_size = keys_buffer.byte_size,
    };
    const flags_binding = gpu.BufferBinding{
        .handle = flags_buffer,
        .access = .read_write,
        .ownership = flags_buffer.ownership,
        .byte_size = flags_buffer.byte_size,
    };
    const scanned_binding = gpu.BufferBinding{
        .handle = scanned_buffer,
        .access = .read_only,
        .ownership = scanned_buffer.ownership,
        .byte_size = scanned_buffer.byte_size,
    };
    const dst_binding = gpu.BufferBinding{
        .handle = dst_buffer,
        .access = .read_write,
        .ownership = dst_buffer.ownership,
        .byte_size = dst_buffer.byte_size,
    };

    {
        const entry_name = try sort_library.radixSplitFlagsFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try sort_library.RadixSplitFlagsRuntimeFamilyI32.buildNamed(allocator, sort_library.RadixSplitFlagsRuntimeFamilyI32.Limits.testing, entry_name, instance);
        defer graph.deinit();
        var kernel_artifact = try kernel.createKernelArtifact(allocator, handle, &graph, .{
            .artifact_format = .cuda_ptx,
            .authored_kernel_diagnostic_id = "choir/kernel/radix-split-flags-live",
        });
        defer kernel_artifact.deinit();
        const loaded = try handle.loadArtifact(&kernel_artifact);
        var stage_bindings = [_]gpu.BufferBinding{ flags_binding, keys_binding };
        const runtime_arguments = try sort_library.radixSplitFlagsRuntimeArguments(instance, bit);
        try handle.launch(.{
            .artifact = &kernel_artifact,
            .loaded_artifact = loaded,
            .buffers = stage_bindings[0..],
            .scalar_arguments = runtime_arguments[0..],
            .geometry = .{
                .grid = .{ blocks, 1, 1 },
                .threadgroup = .{ instance.threads, 1, 1 },
            },
        });
        try handle.synchronize(.{ .scope = .device });
    }

    const flags = try allocator.alloc(f32, extent);
    defer allocator.free(flags);
    try handle.readBuffer(.{ .handle = flags_buffer, .bytes = std.mem.sliceAsBytes(flags) });

    const scanned = try allocator.alloc(f32, extent);
    defer allocator.free(scanned);
    var running: f32 = 0;
    for (flags, scanned) |flag, *value| {
        value.* = running;
        running += flag;
    }
    try handle.writeBuffer(.{ .handle = scanned_buffer, .bytes = std.mem.sliceAsBytes(scanned) });

    {
        const entry_name = try sort_library.radixSplitScatterFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try sort_library.RadixSplitScatterRuntimeFamilyI32.buildNamed(allocator, sort_library.RadixSplitScatterRuntimeFamilyI32.Limits.testing, entry_name, instance);
        defer graph.deinit();
        var kernel_artifact = try kernel.createKernelArtifact(allocator, handle, &graph, .{
            .artifact_format = .cuda_ptx,
            .authored_kernel_diagnostic_id = "choir/kernel/radix-split-scatter-live",
        });
        defer kernel_artifact.deinit();
        const loaded = try handle.loadArtifact(&kernel_artifact);
        var stage_bindings = [_]gpu.BufferBinding{ dst_binding, keys_binding, flags_binding, scanned_binding };
        const runtime_arguments = try sort_library.radixSplitScatterRuntimeArguments(instance);
        try handle.launch(.{
            .artifact = &kernel_artifact,
            .loaded_artifact = loaded,
            .buffers = stage_bindings[0..],
            .scalar_arguments = runtime_arguments[0..],
            .geometry = .{
                .grid = .{ blocks, 1, 1 },
                .threadgroup = .{ instance.threads, 1, 1 },
            },
        });
        try handle.synchronize(.{ .scope = .device });
    }

    const actual = try allocator.alloc(i32, extent);
    defer allocator.free(actual);
    try handle.readBuffer(.{ .handle = dst_buffer, .bytes = std.mem.sliceAsBytes(actual) });

    const expected = try allocator.alloc(i32, extent);
    defer allocator.free(expected);
    var count: usize = 0;
    const shift: u5 = @intCast(bit);
    for (keys) |key| {
        if ((key >> shift) & 1 == 0) {
            expected[count] = key;
            count += 1;
        }
    }
    for (keys) |key| {
        if ((key >> shift) & 1 == 1) {
            expected[count] = key;
            count += 1;
        }
    }
    try std.testing.expectEqualSlices(i32, expected, actual);
}

test "sort radix split pipeline sorts five thousand keys on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    const sort_library = kernel.library.sort;
    const extent: usize = 5000;
    const instance = sort_library.RadixSplit{ .extent = extent, .threads = 64 };

    var artifacts = try sort_library.createRadixSplitPipelineArtifacts(allocator, handle, instance, .{ .limits = .testing });
    defer artifacts.deinit();
    const entries = artifacts.entries();
    var owned_pipeline = try sort_library.radixSplitPipeline(allocator, instance);
    defer owned_pipeline.deinit();

    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{owned_pipeline.value});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();
    const pipeline_target = try sort_library.radixSplitPipelineTarget(allocator, instance);
    defer allocator.free(pipeline_target);
    const found = artifact.findPipeline(
        decoded.pipelines,
        pipeline_target,
        sort_library.radix_split_family_version,
    ) orelse return error.TestExpectedPipeline;

    const keys = try allocator.alloc(i32, extent);
    defer allocator.free(keys);
    var seed: u32 = 0x2545f491;
    for (keys) |*key| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const magnitude: i32 = @intCast(seed % 1000000);
        key.* = if (seed & 1 == 1) -magnitude else magnitude;
    }

    var buffers: [2]gpu.BufferHandle = undefined;
    for (&buffers) |*buffer| {
        buffer.* = try handle.allocateBuffer(.{
            .byte_size = extent * @sizeOf(i32),
            .alignment = 256,
            .dtype = .i32,
            .element_count = extent,
        });
    }
    try handle.writeBuffer(.{ .handle = buffers[0], .bytes = std.mem.sliceAsBytes(keys) });

    var bindings: [2]gpu.BufferBinding = undefined;
    for (buffers, 0..) |buffer, index| {
        bindings[index] = .{
            .handle = buffer,
            .access = .read_write,
            .ownership = buffer.ownership,
            .byte_size = buffer.byte_size,
        };
    }

    const pass_zero_arguments = try sort_library.radixSplitPipelineRuntimeArguments(instance, 0);
    const pooled = try executable.allocatePipelineIntermediates(allocator, handle, found, pass_zero_arguments[0..]);
    defer executable.deinitPipelineIntermediates(allocator, handle, pooled);
    var artifact_pool = try executable.loadPipelineArtifacts(allocator, handle, found, decoded.registry(), .cuda_ptx);
    defer artifact_pool.deinit();

    var source: usize = 0;
    var bit: u32 = 0;
    while (bit < sort_library.radix_split_key_bits) : (bit += 1) {
        const runtime_arguments = try sort_library.radixSplitPipelineRuntimeArguments(instance, bit);
        try executable.launchPipeline(allocator, handle, .{
            .pipeline = found,
            .registry = decoded.registry(),
            .format = .cuda_ptx,
            .operands = bindings[source .. source + 1],
            .results = bindings[1 - source .. 2 - source],
            .runtime_scalar_arguments = runtime_arguments[0..],
            .intermediates = pooled,
            .artifacts = &artifact_pool,
        });
        source = 1 - source;
    }
    try handle.synchronize(.{ .scope = .device });

    const actual = try allocator.alloc(i32, extent);
    defer allocator.free(actual);
    try handle.readBuffer(.{ .handle = bindings[source].handle, .bytes = std.mem.sliceAsBytes(actual) });

    const expected = try allocator.alloc(i32, extent);
    defer allocator.free(expected);
    @memcpy(expected, keys);
    std.mem.sort(i32, expected, {}, std.sort.asc(i32));
    try std.testing.expectEqualSlices(i32, expected, actual);
}

test "warp ballot rank counts same-predicate lower lanes on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    var b = try kernel.Builder.init(allocator, kernel.Builder.Limits.testing, "ballot_rank_live_i32", &.{
        kernel.dynamicBuffer(.i32),
        kernel.dynamicBuffer(.i32),
    });
    errdefer b.deinit();
    const out = b.argument(0);
    const keys = b.argument(1);
    const index = try b.globalId(.x);
    const key = try b.load(keys, index);
    const one = try b.constantInt(.i32, 1);
    const low_bit = try b.and_(key, one);
    const is_odd = try b.compare(.eq, low_bit, one);
    const mask = try b.ballotSync(is_odd);
    const lane = try b.laneId();
    const lane_i32 = try b.cast(lane, .i32);
    const lane_bit = try b.shl(one, lane_i32);
    const lower = try b.sub(lane_bit, one);
    const below = try b.and_(mask, lower);
    const rank = try b.popcount(below);
    try b.store(rank, out, index);
    try b.return_();
    var graph = try b.finish();
    defer graph.deinit();

    var kernel_artifact = try kernel.createKernelArtifact(allocator, handle, &graph, .{
        .artifact_format = .cuda_ptx,
        .authored_kernel_diagnostic_id = "choir/kernel/ballot-rank-live",
    });
    defer kernel_artifact.deinit();
    const loaded = try handle.loadArtifact(&kernel_artifact);

    var keys_data: [64]i32 = undefined;
    var seed: u32 = 0xdecafbad;
    for (&keys_data) |*value| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        value.* = @intCast(seed % 1000);
    }

    var zero_out = @as([64]i32, @splat(-1));
    const host_views = [_][]const u8{
        std.mem.sliceAsBytes(zero_out[0..]),
        std.mem.sliceAsBytes(keys_data[0..]),
    };
    var bindings: [2]gpu.BufferBinding = undefined;
    for (host_views, 0..) |bytes, slot| {
        const buffer = try handle.allocateBuffer(.{
            .byte_size = bytes.len,
            .alignment = 256,
            .dtype = .i32,
            .element_count = bytes.len / @sizeOf(i32),
        });
        try handle.writeBuffer(.{ .handle = buffer, .bytes = bytes });
        bindings[slot] = .{
            .handle = buffer,
            .access = if (slot == 0) .read_write else .read_only,
            .ownership = buffer.ownership,
            .byte_size = buffer.byte_size,
        };
    }

    try handle.launch(.{
        .artifact = &kernel_artifact,
        .loaded_artifact = loaded,
        .buffers = bindings[0..],
        .geometry = .{ .grid = .{ 2, 1, 1 }, .threadgroup = .{ 32, 1, 1 } },
    });
    try handle.synchronize(.{ .scope = .device });

    var actual = @as([64]i32, @splat(-1));
    try handle.readBuffer(.{ .handle = bindings[0].handle, .bytes = std.mem.sliceAsBytes(actual[0..]) });

    for (0..64) |element| {
        const warp_base = (element / 32) * 32;
        var expected: i32 = 0;
        for (warp_base..element) |prior| {
            if (@mod(keys_data[prior], 2) == 1) expected += 1;
        }
        try std.testing.expectEqual(expected, actual[element]);
    }
}

test "sort radix digit pass partitions stably on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    const sort_library = kernel.library.sort;
    const extent: usize = 5000;
    const shift: u32 = 4;
    const instance = sort_library.RadixSplit{ .extent = extent, .threads = 64 };
    const blocks: u32 = @intCast(sort_library.radixSplitBlockCount(extent, instance.threads));
    const cell_count: usize = sort_library.radix_digit_bins * blocks;

    const keys = try allocator.alloc(i32, extent);
    defer allocator.free(keys);
    var seed: u32 = 0x2545f491;
    for (keys, 0..) |*key, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        key.* = @intCast((seed >> 8) % 100000 * 10 + index % 10);
    }

    const keys_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(i32),
        .alignment = 256,
        .dtype = .i32,
        .element_count = extent,
    });
    try handle.writeBuffer(.{ .handle = keys_buffer, .bytes = std.mem.sliceAsBytes(keys) });
    const counts_buffer = try handle.allocateBuffer(.{
        .byte_size = cell_count * @sizeOf(f32),
        .alignment = 256,
        .dtype = .f32,
        .element_count = cell_count,
    });
    const scanned_buffer = try handle.allocateBuffer(.{
        .byte_size = cell_count * @sizeOf(f32),
        .alignment = 256,
        .dtype = .f32,
        .element_count = cell_count,
    });
    const dst_buffer = try handle.allocateBuffer(.{
        .byte_size = extent * @sizeOf(i32),
        .alignment = 256,
        .dtype = .i32,
        .element_count = extent,
    });

    const keys_binding = gpu.BufferBinding{
        .handle = keys_buffer,
        .access = .read_only,
        .ownership = keys_buffer.ownership,
        .byte_size = keys_buffer.byte_size,
    };
    const counts_binding = gpu.BufferBinding{
        .handle = counts_buffer,
        .access = .read_write,
        .ownership = counts_buffer.ownership,
        .byte_size = counts_buffer.byte_size,
    };
    const scanned_binding = gpu.BufferBinding{
        .handle = scanned_buffer,
        .access = .read_only,
        .ownership = scanned_buffer.ownership,
        .byte_size = scanned_buffer.byte_size,
    };
    const dst_binding = gpu.BufferBinding{
        .handle = dst_buffer,
        .access = .read_write,
        .ownership = dst_buffer.ownership,
        .byte_size = dst_buffer.byte_size,
    };

    {
        const entry_name = try sort_library.radixDigitHistogramFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try sort_library.RadixDigitHistogramRuntimeFamilyI32.buildNamed(allocator, sort_library.RadixDigitHistogramRuntimeFamilyI32.Limits.testing, entry_name, instance);
        defer graph.deinit();
        var kernel_artifact = try kernel.createKernelArtifact(allocator, handle, &graph, .{
            .artifact_format = .cuda_ptx,
            .authored_kernel_diagnostic_id = "choir/kernel/radix-digit-histogram-live",
        });
        defer kernel_artifact.deinit();
        const loaded = try handle.loadArtifact(&kernel_artifact);
        var stage_bindings = [_]gpu.BufferBinding{ counts_binding, keys_binding };
        const runtime_arguments = try sort_library.radixDigitHistogramRuntimeArguments(instance, shift);
        try handle.launch(.{
            .artifact = &kernel_artifact,
            .loaded_artifact = loaded,
            .buffers = stage_bindings[0..],
            .scalar_arguments = runtime_arguments[0..],
            .geometry = .{
                .grid = .{ blocks, 1, 1 },
                .threadgroup = .{ instance.threads, 1, 1 },
            },
        });
        try handle.synchronize(.{ .scope = .device });
    }

    const counts = try allocator.alloc(f32, cell_count);
    defer allocator.free(counts);
    try handle.readBuffer(.{ .handle = counts_buffer, .bytes = std.mem.sliceAsBytes(counts) });
    const scanned = try allocator.alloc(f32, cell_count);
    defer allocator.free(scanned);
    var running: f32 = 0;
    for (counts, scanned) |count, *value| {
        value.* = running;
        running += count;
    }
    try handle.writeBuffer(.{ .handle = scanned_buffer, .bytes = std.mem.sliceAsBytes(scanned) });

    {
        const entry_name = try sort_library.radixDigitRankScatterFamilyEntryName(allocator, instance);
        defer allocator.free(entry_name);
        var graph = try sort_library.RadixDigitRankScatterRuntimeFamilyI32.buildNamed(allocator, sort_library.RadixDigitRankScatterRuntimeFamilyI32.Limits.testing, entry_name, instance);
        defer graph.deinit();
        var kernel_artifact = try kernel.createKernelArtifact(allocator, handle, &graph, .{
            .artifact_format = .cuda_ptx,
            .authored_kernel_diagnostic_id = "choir/kernel/radix-digit-rank-scatter-live",
        });
        defer kernel_artifact.deinit();
        const loaded = try handle.loadArtifact(&kernel_artifact);
        var stage_bindings = [_]gpu.BufferBinding{ dst_binding, keys_binding, scanned_binding };
        const runtime_arguments = try sort_library.radixDigitHistogramRuntimeArguments(instance, shift);
        try handle.launch(.{
            .artifact = &kernel_artifact,
            .loaded_artifact = loaded,
            .buffers = stage_bindings[0..],
            .scalar_arguments = runtime_arguments[0..],
            .geometry = .{
                .grid = .{ blocks, 1, 1 },
                .threadgroup = .{ instance.threads, 1, 1 },
            },
        });
        try handle.synchronize(.{ .scope = .device });
    }

    const actual = try allocator.alloc(i32, extent);
    defer allocator.free(actual);
    try handle.readBuffer(.{ .handle = dst_buffer, .bytes = std.mem.sliceAsBytes(actual) });

    const expected = try allocator.alloc(i32, extent);
    defer allocator.free(expected);
    var count: usize = 0;
    const shift_amount: u5 = @intCast(shift);
    var digit: i32 = 0;
    while (digit < sort_library.radix_digit_bins) : (digit += 1) {
        for (keys) |key| {
            if ((key >> shift_amount) & (sort_library.radix_digit_bins - 1) == digit) {
                expected[count] = key;
                count += 1;
            }
        }
    }
    try std.testing.expectEqualSlices(i32, expected, actual);
}

test "sort radix digit pipeline sorts in eight passes on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    const sort_library = kernel.library.sort;
    const extent: usize = 5000;
    const instance = sort_library.RadixSplit{ .extent = extent, .threads = 64 };

    var artifacts = try sort_library.createRadixDigitPipelineArtifacts(allocator, handle, instance, .{ .limits = .testing });
    defer artifacts.deinit();
    const entries = artifacts.entries();
    var owned_pipeline = try sort_library.radixDigitPipeline(allocator, instance);
    defer owned_pipeline.deinit();

    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{owned_pipeline.value});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();
    const pipeline_target = try sort_library.radixDigitPipelineTarget(allocator, instance);
    defer allocator.free(pipeline_target);
    const found = artifact.findPipeline(
        decoded.pipelines,
        pipeline_target,
        sort_library.radix_split_family_version,
    ) orelse return error.TestExpectedPipeline;

    const keys = try allocator.alloc(i32, extent);
    defer allocator.free(keys);
    var seed: u32 = 0x2545f491;
    for (keys) |*key| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const magnitude: i32 = @intCast(seed % 1000000);
        key.* = if (seed & 1 == 1) -magnitude else magnitude;
    }

    var buffers: [2]gpu.BufferHandle = undefined;
    for (&buffers) |*buffer| {
        buffer.* = try handle.allocateBuffer(.{
            .byte_size = extent * @sizeOf(i32),
            .alignment = 256,
            .dtype = .i32,
            .element_count = extent,
        });
    }
    try handle.writeBuffer(.{ .handle = buffers[0], .bytes = std.mem.sliceAsBytes(keys) });

    var bindings: [2]gpu.BufferBinding = undefined;
    for (buffers, 0..) |buffer, index| {
        bindings[index] = .{
            .handle = buffer,
            .access = .read_write,
            .ownership = buffer.ownership,
            .byte_size = buffer.byte_size,
        };
    }

    const pass_zero = [_]gpu_abi.ScalarArgument{ .{ .u32 = @intCast(extent) }, .{ .u32 = 0 }, .{ .u32 = 0 } };
    const pooled = try executable.allocatePipelineIntermediates(allocator, handle, found, pass_zero[0..]);
    defer executable.deinitPipelineIntermediates(allocator, handle, pooled);
    var artifact_pool = try executable.loadPipelineArtifacts(allocator, handle, found, decoded.registry(), .cuda_ptx);
    defer artifact_pool.deinit();

    var source: usize = 0;
    var shift: u32 = 0;
    while (shift < sort_library.radix_split_key_bits) : (shift += sort_library.radix_digit_bits) {
        const runtime_arguments = try sort_library.radixDigitHistogramRuntimeArguments(instance, shift);
        try executable.launchPipeline(allocator, handle, .{
            .pipeline = found,
            .registry = decoded.registry(),
            .format = .cuda_ptx,
            .operands = bindings[source .. source + 1],
            .results = bindings[1 - source .. 2 - source],
            .runtime_scalar_arguments = runtime_arguments[0..],
            .intermediates = pooled,
            .artifacts = &artifact_pool,
        });
        source = 1 - source;
    }
    try handle.synchronize(.{ .scope = .device });

    const actual = try allocator.alloc(i32, extent);
    defer allocator.free(actual);
    try handle.readBuffer(.{ .handle = bindings[source].handle, .bytes = std.mem.sliceAsBytes(actual) });

    const expected = try allocator.alloc(i32, extent);
    defer allocator.free(expected);
    @memcpy(expected, keys);
    std.mem.sort(i32, expected, {}, std.sort.asc(i32));
    try std.testing.expectEqualSlices(i32, expected, actual);
}

test "sort radix digit pairs pipeline computes a stable argsort on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    const sort_library = kernel.library.sort;
    const extent: usize = 5000;
    const instance = sort_library.RadixSplit{ .extent = extent, .threads = 64 };

    var artifacts = try sort_library.createRadixDigitPairsPipelineArtifacts(allocator, handle, instance, .{ .limits = .testing });
    defer artifacts.deinit();
    const entries = artifacts.entries();
    var owned_pipeline = try sort_library.radixDigitPairsPipeline(allocator, instance);
    defer owned_pipeline.deinit();

    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{owned_pipeline.value});
    defer allocator.free(encoded);
    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();
    const pipeline_target = try sort_library.radixDigitPairsPipelineTarget(allocator, instance);
    defer allocator.free(pipeline_target);
    const found = artifact.findPipeline(
        decoded.pipelines,
        pipeline_target,
        sort_library.radix_split_family_version,
    ) orelse return error.TestExpectedPipeline;

    const keys = try allocator.alloc(i32, extent);
    defer allocator.free(keys);
    const iota = try allocator.alloc(i32, extent);
    defer allocator.free(iota);
    var seed: u32 = 0x2545f491;
    for (keys, iota, 0..) |*key, *value, index| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const magnitude: i32 = @intCast(seed % 1000);
        key.* = if (seed & 1 == 1) -magnitude else magnitude;
        value.* = @intCast(index);
    }

    var key_buffers: [2]gpu.BufferHandle = undefined;
    var value_buffers: [2]gpu.BufferHandle = undefined;
    for (&key_buffers, &value_buffers) |*key_buffer, *value_buffer| {
        key_buffer.* = try handle.allocateBuffer(.{
            .byte_size = extent * @sizeOf(i32),
            .alignment = 256,
            .dtype = .i32,
            .element_count = extent,
        });
        value_buffer.* = try handle.allocateBuffer(.{
            .byte_size = extent * @sizeOf(i32),
            .alignment = 256,
            .dtype = .i32,
            .element_count = extent,
        });
    }
    try handle.writeBuffer(.{ .handle = key_buffers[0], .bytes = std.mem.sliceAsBytes(keys) });
    try handle.writeBuffer(.{ .handle = value_buffers[0], .bytes = std.mem.sliceAsBytes(iota) });

    var key_bindings: [2]gpu.BufferBinding = undefined;
    var value_bindings: [2]gpu.BufferBinding = undefined;
    for (key_buffers, value_buffers, 0..) |key_buffer, value_buffer, index| {
        key_bindings[index] = .{
            .handle = key_buffer,
            .access = .read_write,
            .ownership = key_buffer.ownership,
            .byte_size = key_buffer.byte_size,
        };
        value_bindings[index] = .{
            .handle = value_buffer,
            .access = .read_write,
            .ownership = value_buffer.ownership,
            .byte_size = value_buffer.byte_size,
        };
    }

    const pass_zero = try sort_library.radixDigitHistogramRuntimeArguments(instance, 0);
    const pooled = try executable.allocatePipelineIntermediates(allocator, handle, found, pass_zero[0..]);
    defer executable.deinitPipelineIntermediates(allocator, handle, pooled);
    var artifact_pool = try executable.loadPipelineArtifacts(allocator, handle, found, decoded.registry(), .cuda_ptx);
    defer artifact_pool.deinit();

    var source: usize = 0;
    var shift: u32 = 0;
    while (shift < sort_library.radix_split_key_bits) : (shift += sort_library.radix_digit_bits) {
        const runtime_arguments = try sort_library.radixDigitHistogramRuntimeArguments(instance, shift);
        const operands = [_]gpu.BufferBinding{ key_bindings[source], value_bindings[source] };
        const results = [_]gpu.BufferBinding{ key_bindings[1 - source], value_bindings[1 - source] };
        try executable.launchPipeline(allocator, handle, .{
            .pipeline = found,
            .registry = decoded.registry(),
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = runtime_arguments[0..],
            .intermediates = pooled,
            .artifacts = &artifact_pool,
        });
        source = 1 - source;
    }
    try handle.synchronize(.{ .scope = .device });

    const sorted_keys = try allocator.alloc(i32, extent);
    defer allocator.free(sorted_keys);
    try handle.readBuffer(.{ .handle = key_bindings[source].handle, .bytes = std.mem.sliceAsBytes(sorted_keys) });
    const argsort = try allocator.alloc(i32, extent);
    defer allocator.free(argsort);
    try handle.readBuffer(.{ .handle = value_bindings[source].handle, .bytes = std.mem.sliceAsBytes(argsort) });

    const expected = try allocator.alloc(i32, extent);
    defer allocator.free(expected);
    @memcpy(expected, keys);
    std.mem.sort(i32, expected, {}, std.sort.asc(i32));
    try std.testing.expectEqualSlices(i32, expected, sorted_keys);

    var previous_index: i32 = -1;
    var previous_key: i32 = std.math.minInt(i32);
    for (sorted_keys, argsort) |key, original_index| {
        try std.testing.expectEqual(keys[@intCast(original_index)], key);
        if (key == previous_key) {
            try std.testing.expect(original_index > previous_index);
        }
        previous_index = original_index;
        previous_key = key;
    }
}

test "spatial uniform grid builds on live CUDA through composed pipelines" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    const spatial = kernel.library.spatial;
    const sort_library = kernel.library.sort;
    const scan_library = kernel.library.scan;

    const count: usize = 5000;
    const geometry = spatial.GridGeometry{
        .origin_x = -1.0,
        .origin_y = -1.0,
        .inv_cell_size = 4.0,
        .dims_x = 8,
        .dims_y = 8,
    };
    const plan = try spatial.gridBuildPlan(count, geometry, 64);
    const blocks: u32 = @intCast(spatial.gridCellsBlockCount(count, plan.cells_instance.threads));
    const cell_count: usize = plan.cells_total;
    const count_blocks: u32 = blocks;
    const counts_extent: usize = @intCast(plan.offsets_scan.extent);

    const xs = try allocator.alloc(f32, count);
    defer allocator.free(xs);
    const ys = try allocator.alloc(f32, count);
    defer allocator.free(ys);
    var seed: u32 = 0x2545f491;
    for (xs, ys) |*x, *y| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        x.* = @as(f32, @floatFromInt(seed % 1000)) / 250.0 - 2.0;
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        y.* = @as(f32, @floatFromInt(seed % 1000)) / 250.0 - 2.0;
    }

    const alloc_f32 = struct {
        fn run(h: gpu.BackendHandle, n: usize) !gpu.BufferHandle {
            return h.allocateBuffer(.{
                .byte_size = n * @sizeOf(f32),
                .alignment = 256,
                .dtype = .f32,
                .element_count = n,
            });
        }
    }.run;
    const alloc_i32 = struct {
        fn run(h: gpu.BackendHandle, n: usize) !gpu.BufferHandle {
            return h.allocateBuffer(.{
                .byte_size = n * @sizeOf(i32),
                .alignment = 256,
                .dtype = .i32,
                .element_count = n,
            });
        }
    }.run;
    const bind = struct {
        fn run(buffer: gpu.BufferHandle, access: gpu.BufferAccess) gpu.BufferBinding {
            return .{
                .handle = buffer,
                .access = access,
                .ownership = buffer.ownership,
                .byte_size = buffer.byte_size,
            };
        }
    }.run;

    const x_buffer = try alloc_f32(handle, count);
    const y_buffer = try alloc_f32(handle, count);
    try handle.writeBuffer(.{ .handle = x_buffer, .bytes = std.mem.sliceAsBytes(xs) });
    try handle.writeBuffer(.{ .handle = y_buffer, .bytes = std.mem.sliceAsBytes(ys) });

    var id_buffers: [2]gpu.BufferHandle = undefined;
    var payload_buffers: [2]gpu.BufferHandle = undefined;
    for (&id_buffers, &payload_buffers) |*ids, *payload| {
        ids.* = try alloc_i32(handle, count);
        payload.* = try alloc_i32(handle, count);
    }
    const counts_buffer = try alloc_f32(handle, counts_extent);
    const scanned_buffer = try alloc_f32(handle, counts_extent);

    {
        const entry_name = try spatial.gridCellsFamilyEntryName(allocator, plan.cells_instance);
        defer allocator.free(entry_name);
        var graph = try spatial.GridCellsRuntimeFamilyF32.buildNamed(allocator, spatial.GridCellsRuntimeFamilyF32.Limits.testing, entry_name, plan.cells_instance);
        defer graph.deinit();
        var kernel_artifact = try kernel.createKernelArtifact(allocator, handle, &graph, .{
            .artifact_format = .cuda_ptx,
            .authored_kernel_diagnostic_id = "choir/kernel/grid-cells-live",
        });
        defer kernel_artifact.deinit();
        const loaded = try handle.loadArtifact(&kernel_artifact);
        var stage_bindings = [_]gpu.BufferBinding{
            bind(id_buffers[0], .read_write),
            bind(x_buffer, .read_only),
            bind(y_buffer, .read_only),
        };
        const runtime_arguments = try spatial.gridCellsRuntimeArguments(plan.cells_instance, geometry);
        try handle.launch(.{
            .artifact = &kernel_artifact,
            .loaded_artifact = loaded,
            .buffers = stage_bindings[0..],
            .scalar_arguments = runtime_arguments[0..],
            .geometry = .{
                .grid = .{ blocks, 1, 1 },
                .threadgroup = .{ plan.cells_instance.threads, 1, 1 },
            },
        });
        try handle.synchronize(.{ .scope = .device });
    }

    const iota = try allocator.alloc(i32, count);
    defer allocator.free(iota);
    for (iota, 0..) |*value, index| value.* = @intCast(index);
    try handle.writeBuffer(.{ .handle = payload_buffers[0], .bytes = std.mem.sliceAsBytes(iota) });

    var sort_artifacts = try sort_library.createRadixDigitPairsPipelineArtifacts(allocator, handle, plan.sort_instance, .{ .limits = .testing });
    defer sort_artifacts.deinit();
    const sort_entries = sort_artifacts.entries();
    var sort_pipeline = try sort_library.radixDigitPairsPipeline(allocator, plan.sort_instance);
    defer sort_pipeline.deinit();
    const sort_registry = artifact.KernelCallRegistry{ .entries = sort_entries[0..] };

    const sort_args0 = try sort_library.radixDigitHistogramRuntimeArguments(plan.sort_instance, 0);
    const sort_pool = try executable.allocatePipelineIntermediates(allocator, handle, sort_pipeline.value, sort_args0[0..]);
    defer executable.deinitPipelineIntermediates(allocator, handle, sort_pool);
    var sort_artifact_pool = try executable.loadPipelineArtifacts(allocator, handle, sort_pipeline.value, sort_registry, .cuda_ptx);
    defer sort_artifact_pool.deinit();

    var source: usize = 0;
    var pass: u32 = 0;
    while (pass < plan.sort_passes) : (pass += 1) {
        const shift = pass * sort_library.radix_digit_bits;
        const runtime_arguments = try sort_library.radixDigitHistogramRuntimeArguments(plan.sort_instance, shift);
        const operands = [_]gpu.BufferBinding{
            bind(id_buffers[source], .read_write),
            bind(payload_buffers[source], .read_write),
        };
        const results = [_]gpu.BufferBinding{
            bind(id_buffers[1 - source], .read_write),
            bind(payload_buffers[1 - source], .read_write),
        };
        try executable.launchPipeline(allocator, handle, .{
            .pipeline = sort_pipeline.value,
            .registry = sort_registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = runtime_arguments[0..],
            .intermediates = sort_pool,
            .artifacts = &sort_artifact_pool,
        });
        source = 1 - source;
    }
    try handle.synchronize(.{ .scope = .device });

    {
        const entry_name = try spatial.gridCountFamilyEntryName(allocator, plan.count_instance);
        defer allocator.free(entry_name);
        var graph = try spatial.GridCountRuntimeFamilyI32.buildNamed(allocator, spatial.GridCountRuntimeFamilyI32.Limits.testing, entry_name, plan.count_instance);
        defer graph.deinit();
        var kernel_artifact = try kernel.createKernelArtifact(allocator, handle, &graph, .{
            .artifact_format = .cuda_ptx,
            .authored_kernel_diagnostic_id = "choir/kernel/grid-count-live",
        });
        defer kernel_artifact.deinit();
        const loaded = try handle.loadArtifact(&kernel_artifact);
        var stage_bindings = [_]gpu.BufferBinding{
            bind(counts_buffer, .read_write),
            bind(id_buffers[source], .read_only),
        };
        const runtime_arguments = try spatial.gridCountRuntimeArguments(plan.count_instance, plan.cells_total);
        try handle.launch(.{
            .artifact = &kernel_artifact,
            .loaded_artifact = loaded,
            .buffers = stage_bindings[0..],
            .scalar_arguments = runtime_arguments[0..],
            .geometry = .{
                .grid = .{ count_blocks, 1, 1 },
                .threadgroup = .{ plan.count_instance.threads, 1, 1 },
            },
        });
        try handle.synchronize(.{ .scope = .device });
    }

    var scan_artifacts = try scan_library.createDeviceScanPipelineArtifacts(allocator, handle, plan.offsets_scan, .{
        .limits = kernel.Limits.testing,
    });
    defer scan_artifacts.deinit();
    const scan_entries = scan_artifacts.entries();
    var scan_pipeline = try scan_library.deviceScanPipeline(allocator, plan.offsets_scan);
    defer scan_pipeline.deinit();
    const scan_registry = artifact.KernelCallRegistry{ .entries = scan_entries[0..] };
    {
        const operands = [_]gpu.BufferBinding{bind(counts_buffer, .read_only)};
        const results = [_]gpu.BufferBinding{bind(scanned_buffer, .read_write)};
        try executable.launchPipeline(allocator, handle, .{
            .pipeline = scan_pipeline.value,
            .registry = scan_registry,
            .format = .cuda_ptx,
            .operands = operands[0..],
            .results = results[0..],
            .runtime_scalar_arguments = &.{.{ .u32 = @intCast(counts_extent) }},
        });
    }

    const sorted_ids = try allocator.alloc(i32, count);
    defer allocator.free(sorted_ids);
    try handle.readBuffer(.{ .handle = id_buffers[source], .bytes = std.mem.sliceAsBytes(sorted_ids) });
    const permutation = try allocator.alloc(i32, count);
    defer allocator.free(permutation);
    try handle.readBuffer(.{ .handle = payload_buffers[source], .bytes = std.mem.sliceAsBytes(permutation) });
    const scanned = try allocator.alloc(f32, counts_extent);
    defer allocator.free(scanned);
    try handle.readBuffer(.{ .handle = scanned_buffer, .bytes = std.mem.sliceAsBytes(scanned) });

    const host_ids = try allocator.alloc(i32, count);
    defer allocator.free(host_ids);
    for (xs, ys, host_ids) |x, y, *id| {
        const fx = (x - geometry.origin_x) * geometry.inv_cell_size;
        const fy = (y - geometry.origin_y) * geometry.inv_cell_size;
        const cx = std.math.clamp(@as(i32, @intFromFloat(fx)), 0, @as(i32, @intCast(geometry.dims_x - 1)));
        const cy = std.math.clamp(@as(i32, @intFromFloat(fy)), 0, @as(i32, @intCast(geometry.dims_y - 1)));
        id.* = cy * @as(i32, @intCast(geometry.dims_x)) + cx;
    }

    var previous_id: i32 = -1;
    var previous_perm: i32 = -1;
    for (sorted_ids, permutation) |id, original| {
        try std.testing.expectEqual(host_ids[@intCast(original)], id);
        try std.testing.expect(id >= previous_id);
        if (id == previous_id) try std.testing.expect(original > previous_perm);
        previous_id = id;
        previous_perm = original;
    }

    const host_counts = try allocator.alloc(u32, cell_count);
    defer allocator.free(host_counts);
    @memset(host_counts, 0);
    for (host_ids) |id| host_counts[@intCast(id)] += 1;
    var running: u32 = 0;
    for (0..cell_count) |cell| {
        const offset: u32 = @intFromFloat(scanned[cell * count_blocks]);
        try std.testing.expectEqual(running, offset);
        running += host_counts[cell];
    }

    const radius: f32 = 0.2;
    const neighbors_buffer = try alloc_i32(handle, count);
    {
        const neighbor_instance = spatial.GridNeighborCount{
            .count = count,
            .threads = plan.cells_instance.threads,
        };
        const entry_name = try spatial.gridNeighborCountFamilyEntryName(allocator, neighbor_instance);
        defer allocator.free(entry_name);
        var graph = try spatial.GridNeighborCountRuntimeFamilyF32.buildNamed(allocator, spatial.GridNeighborCountRuntimeFamilyF32.Limits.testing, entry_name, neighbor_instance);
        defer graph.deinit();
        var kernel_artifact = try kernel.createKernelArtifact(allocator, handle, &graph, .{
            .artifact_format = .cuda_ptx,
            .authored_kernel_diagnostic_id = "choir/kernel/grid-neighbor-live",
        });
        defer kernel_artifact.deinit();
        const loaded = try handle.loadArtifact(&kernel_artifact);
        var stage_bindings = [_]gpu.BufferBinding{
            bind(neighbors_buffer, .read_write),
            bind(x_buffer, .read_only),
            bind(y_buffer, .read_only),
            bind(payload_buffers[source], .read_only),
            bind(scanned_buffer, .read_only),
        };
        const runtime_arguments = try spatial.gridNeighborCountRuntimeArguments(
            neighbor_instance,
            geometry,
            count_blocks,
            radius,
        );
        try handle.launch(.{
            .artifact = &kernel_artifact,
            .loaded_artifact = loaded,
            .buffers = stage_bindings[0..],
            .scalar_arguments = runtime_arguments[0..],
            .geometry = .{
                .grid = .{ blocks, 1, 1 },
                .threadgroup = .{ neighbor_instance.threads, 1, 1 },
            },
        });
        try handle.synchronize(.{ .scope = .device });
    }

    const device_neighbors = try allocator.alloc(i32, count);
    defer allocator.free(device_neighbors);
    try handle.readBuffer(.{ .handle = neighbors_buffer, .bytes = std.mem.sliceAsBytes(device_neighbors) });

    const radius2 = radius * radius;
    var any_neighbors = false;
    for (0..count) |a| {
        var expected_neighbors: i32 = 0;
        for (0..count) |b| {
            if (a == b) continue;
            const dx = xs[a] - xs[b];
            const dy = ys[a] - ys[b];
            if (dx * dx + dy * dy <= radius2) expected_neighbors += 1;
        }
        if (expected_neighbors > 0) any_neighbors = true;
        try std.testing.expectEqual(expected_neighbors, device_neighbors[a]);
    }
    try std.testing.expect(any_neighbors);
}

test "linalg batched cholesky factors and solves compose on live CUDA" {
    const allocator = std.testing.allocator;

    var state = try initCudaStateOrSkip(allocator);
    defer state.deinit();
    const handle = state.handle();

    const factor_library = kernel.library.factor;
    const n: usize = 3;
    const batch: usize = 64;
    const cholesky_instance = factor_library.BatchedCholesky{ .batch = batch, .n = n, .threads = 32 };
    const solve_instance = factor_library.BatchedCholeskySolve{ .batch = batch, .n = n, .threads = 32 };
    const blocks: u32 = @intCast(factor_library.batchedCholeskyBlockCount(batch, cholesky_instance.threads));

    const a = try allocator.alloc(f32, batch * n * n);
    defer allocator.free(a);
    const rhs = try allocator.alloc(f32, batch * n);
    defer allocator.free(rhs);
    var seed: u32 = 0x0c0de53d;
    for (0..batch) |b| {
        var mixed: [n * n]f32 = undefined;
        for (&mixed) |*value| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            value.* = @as(f32, @floatFromInt(seed % 1000)) / 1000.0;
        }
        for (0..n) |i| {
            for (0..n) |j| {
                var sum: f32 = 0;
                for (0..n) |c| {
                    sum += mixed[i * n + c] * mixed[j * n + c];
                }
                if (i == j) sum += @floatFromInt(n);
                a[b * n * n + i * n + j] = sum;
            }
        }
        for (rhs[b * n ..][0..n]) |*value| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            value.* = @as(f32, @floatFromInt(seed % 1000)) / 500.0 - 1.0;
        }
    }

    const alloc_f32 = struct {
        fn run(h: gpu.BackendHandle, count: usize) !gpu.BufferHandle {
            return h.allocateBuffer(.{
                .byte_size = count * @sizeOf(f32),
                .alignment = 256,
                .dtype = .f32,
                .element_count = count,
            });
        }
    }.run;
    const bind = struct {
        fn run(buffer: gpu.BufferHandle, access: gpu.BufferAccess) gpu.BufferBinding {
            return .{
                .handle = buffer,
                .access = access,
                .ownership = buffer.ownership,
                .byte_size = buffer.byte_size,
            };
        }
    }.run;

    const a_buffer = try alloc_f32(handle, batch * n * n);
    const l_buffer = try alloc_f32(handle, batch * n * n);
    const rhs_buffer = try alloc_f32(handle, batch * n);
    const x_buffer = try alloc_f32(handle, batch * n);
    try handle.writeBuffer(.{ .handle = a_buffer, .bytes = std.mem.sliceAsBytes(a) });
    try handle.writeBuffer(.{ .handle = rhs_buffer, .bytes = std.mem.sliceAsBytes(rhs) });

    {
        const entry_name = try factor_library.batchedCholeskyFamilyEntryName(allocator, cholesky_instance);
        defer allocator.free(entry_name);
        var graph = try factor_library.BatchedCholeskyRuntimeFamilyF32.buildNamed(allocator, factor_library.BatchedCholeskyRuntimeFamilyF32.Limits.testing, entry_name, cholesky_instance);
        defer graph.deinit();
        var kernel_artifact = try kernel.createKernelArtifact(allocator, handle, &graph, .{
            .artifact_format = .cuda_ptx,
            .authored_kernel_diagnostic_id = "choir/kernel/batched-cholesky-live",
        });
        defer kernel_artifact.deinit();
        const loaded = try handle.loadArtifact(&kernel_artifact);
        var stage_bindings = [_]gpu.BufferBinding{
            bind(l_buffer, .read_write),
            bind(a_buffer, .read_only),
        };
        const runtime_arguments = try factor_library.batchedCholeskyRuntimeArguments(cholesky_instance);
        try handle.launch(.{
            .artifact = &kernel_artifact,
            .loaded_artifact = loaded,
            .buffers = stage_bindings[0..],
            .scalar_arguments = runtime_arguments[0..],
            .geometry = .{
                .grid = .{ blocks, 1, 1 },
                .threadgroup = .{ cholesky_instance.threads, 1, 1 },
            },
        });
        try handle.synchronize(.{ .scope = .device });
    }

    {
        const entry_name = try factor_library.batchedCholeskySolveFamilyEntryName(allocator, solve_instance);
        defer allocator.free(entry_name);
        var graph = try factor_library.BatchedCholeskySolveRuntimeFamilyF32.buildNamed(allocator, factor_library.BatchedCholeskySolveRuntimeFamilyF32.Limits.testing, entry_name, solve_instance);
        defer graph.deinit();
        var kernel_artifact = try kernel.createKernelArtifact(allocator, handle, &graph, .{
            .artifact_format = .cuda_ptx,
            .authored_kernel_diagnostic_id = "choir/kernel/batched-cholesky-solve-live",
        });
        defer kernel_artifact.deinit();
        const loaded = try handle.loadArtifact(&kernel_artifact);
        var stage_bindings = [_]gpu.BufferBinding{
            bind(x_buffer, .read_write),
            bind(l_buffer, .read_only),
            bind(rhs_buffer, .read_only),
        };
        const runtime_arguments = try factor_library.batchedCholeskySolveRuntimeArguments(solve_instance);
        try handle.launch(.{
            .artifact = &kernel_artifact,
            .loaded_artifact = loaded,
            .buffers = stage_bindings[0..],
            .scalar_arguments = runtime_arguments[0..],
            .geometry = .{
                .grid = .{ blocks, 1, 1 },
                .threadgroup = .{ solve_instance.threads, 1, 1 },
            },
        });
        try handle.synchronize(.{ .scope = .device });
    }

    const x = try allocator.alloc(f32, batch * n);
    defer allocator.free(x);
    try handle.readBuffer(.{ .handle = x_buffer, .bytes = std.mem.sliceAsBytes(x) });

    for (0..batch) |b| {
        for (0..n) |i| {
            var residual: f32 = -rhs[b * n + i];
            for (0..n) |j| {
                residual += a[b * n * n + i * n + j] * x[b * n + j];
            }
            try std.testing.expect(@abs(residual) <= 0.0001);
        }
    }
}

test "accy integration declaration coverage" {
    std.testing.refAllDecls(choir);
}
