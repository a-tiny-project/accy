const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const catalog = @import("root.zig");

const accy_artifact = @import("../../../artifact/root.zig");
const library = @import("../root.zig");

const attention = library.attention;
const compaction = library.compaction;
const elementwise = library.elementwise;
const entry = library.entry;
const factor_mod = library.factor;
const fused = library.fused;
const histogram_mod = library.histogram;
const image = library.image;
const indexing = library.indexing;
const layout = library.layout;
const normalization = library.normalization;
const random = library.random;
const reduction = library.reduction;
const scan_mod = library.scan;
const segmented = library.segmented;
const sort_mod = library.sort;
const sparse_mod = library.sparse;
const spatial_mod = library.spatial;
const tuning = library.tuning;

const Descriptor = catalog.Descriptor;
const OwnedDescriptor = catalog.OwnedDescriptor;
const OwnedKernelCallPipelinePackage = catalog.OwnedKernelCallPipelinePackage;
const Query = catalog.Query;
const ReductionOperand = catalog.ReductionOperand;
const MatrixProductSchedule = catalog.MatrixProductSchedule;
const MatrixProductCandidateDescriptors = catalog.MatrixProductCandidateDescriptors;
const entries = catalog.entries;
const descriptors = catalog.descriptors;
const findEntry = catalog.findEntry;
const createKernelCallArtifact = catalog.createKernelCallArtifact;
const createOwnedKernelCallArtifact = catalog.createOwnedKernelCallArtifact;
const createOwnedKernelCallPipelinePackage = catalog.createOwnedKernelCallPipelinePackage;
const createOwnedKernelCallArtifactRegistry = catalog.createOwnedKernelCallArtifactRegistry;
const select = catalog.select;
const selectOwned = catalog.selectOwned;
const selectOwnedMatrixProductCandidates = catalog.selectOwnedMatrixProductCandidates;
const selectOwnedStencilWindowCandidates = catalog.selectOwnedStencilWindowCandidates;
const selectOwnedGatherCandidates = catalog.selectOwnedGatherCandidates;
const selectOwnedScatterCandidates = catalog.selectOwnedScatterCandidates;
const selectOwnedScatterAddCandidates = catalog.selectOwnedScatterAddCandidates;
const selectOwnedHistogramCandidates = catalog.selectOwnedHistogramCandidates;
const selectOwnedFactor = catalog.selectOwnedFactor;
const selectOwnedSparse = catalog.selectOwnedSparse;
const selectOwnedSparseCandidates = catalog.selectOwnedSparseCandidates;
const selectSparseWithTuning = catalog.selectSparseWithTuning;
const selectOwnedSpatial = catalog.selectOwnedSpatial;
const selectOwnedImageCandidates = catalog.selectOwnedImageCandidates;
const selectOwnedRandomCandidates = catalog.selectOwnedRandomCandidates;
const selectOwnedFilterCandidates = catalog.selectOwnedFilterCandidates;
const selectOwnedPrefixSumCandidates = catalog.selectOwnedPrefixSumCandidates;
const selectRadixSortWithTuning = catalog.selectRadixSortWithTuning;
const linalg = library.linalg;
const stencil = library.stencil;

const MatrixProductShape = struct {
    m: u64,
    n: u64,
    k: u64,
};

fn matrixProductDescriptorMatches(
    descriptor: Descriptor,
    shape: MatrixProductShape,
    schedule: ?MatrixProductSchedule,
    dtype: gpu_abi.DType,
) bool {
    if (descriptor.metadata.category != .linalg) return false;
    const specialization = descriptor.metadata.specialization;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .linalg = .matrix_product })) return false;
    if (specialization.dtype != dtype) return false;
    if (specialization.accumulation_dtype != linalg.matrixProductAccumulationDType(dtype)) {
        return false;
    }
    const equation = specialization.equation orelse return false;
    if (!std.mem.eql(u8, equation, "mk,kn->mn")) return false;
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 1) return false;
    return specialization.inputHasExtents(0, &.{ shape.m, shape.k }) and
        specialization.inputHasExtents(1, &.{ shape.k, shape.n }) and
        specialization.outputHasExtents(0, &.{ shape.m, shape.n }) and
        specialization.reductionMatches(0, .{
            .name = "dot",
            .operator = .dot_product,
            .extents = &.{shape.k},
        }) and matrixProductScheduleMatches(specialization, schedule);
}

fn stencilWindowDescriptorMatches(descriptor: Descriptor, query: catalog.StencilQuery) bool {
    if (descriptor.metadata.category != .stencil) return false;
    const specialization = descriptor.metadata.specialization;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (!specialization.operationIs(.{ .stencil = .window })) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.accumulation_dtype != stencil.windowAccumulationDType(query.dtype)) {
        return false;
    }
    if (specialization.inputs.len != 2 or specialization.outputs.len != 1) return false;
    if (specialization.reductions.len != 1) return false;
    if (!stencil.windowRadiusValid(query.radius)) return false;
    const side = 2 * @as(u64, query.radius) + 1;
    const taps = side * side;
    const padded_rows = query.rows + 2 * @as(u64, query.radius);
    const padded_cols = query.cols + 2 * @as(u64, query.radius);
    return specialization.inputHasExtents(0, &.{ padded_rows, padded_cols }) and
        specialization.inputHasExtents(1, &.{taps}) and
        specialization.outputHasExtents(0, &.{ query.rows, query.cols }) and
        specialization.reductionMatches(0, .{
            .name = "window",
            .operator = .weighted_sum,
            .extents = &.{taps},
        }) and stencilWindowScheduleMatches(specialization, query.schedule);
}

fn matrixProductScheduleMatches(
    specialization: entry.Specialization,
    schedule: ?MatrixProductSchedule,
) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| specializationThreadgroup2DMatches(specialization, threads),
    };
}

fn stencilWindowScheduleMatches(
    specialization: entry.Specialization,
    schedule: ?catalog.StencilSchedule,
) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .thread_blocks => |threads| specializationThreadgroup2DMatches(specialization, threads),
    };
}

fn specializationThreadgroup2DMatches(
    specialization: entry.Specialization,
    threads: entry.Threads2D,
) bool {
    const launch = specialization.launch orelse return false;
    return launch.threadgroup[0] == threads.x and
        launch.threadgroup[1] == threads.y;
}

const registry_tests = struct {
    test "kernel library catalog exposes concrete entry descriptors" {
        try std.testing.expectEqual(entries.len, descriptors.len);
        for (descriptors) |descriptor| {
            try std.testing.expect(
                descriptor.metadata.specialization.reductionDependenciesAreValid(),
            );
            try std.testing.expect(
                descriptor.metadata.specialization.reductionReuseScopesAreValid(),
            );
        }

        const sdpa = findEntry(
            attention.ScaledDotProductAttention2x2x3x2x2F32.target,
            attention.ScaledDotProductAttention2x2x3x2x2F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            attention.ScaledDotProductAttention2x2x3x2x2F32.name,
            sdpa.name,
        );
        try std.testing.expectEqual(entry.Category.attention, sdpa.metadata.category);
        try std.testing.expect(
            sdpa.metadata.specialization.operationIs(.{ .attention = .scaled_dot_product }),
        );

        const vector_add = findEntry(
            elementwise.VectorAdd8F32.target,
            elementwise.VectorAdd8F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(elementwise.VectorAdd8F32.name, vector_add.name);
        try std.testing.expectEqual(entry.Category.elementwise, vector_add.metadata.category);

        const gelu = findEntry(elementwise.Gelu8F32.target, elementwise.Gelu8F32.version) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(elementwise.Gelu8F32.name, gelu.name);
        try std.testing.expect(gelu.metadata.specialization.operationIs(.{ .activation = .gelu }));

        const relu = findEntry(elementwise.Relu8F32.target, elementwise.Relu8F32.version) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(elementwise.Relu8F32.name, relu.name);
        try std.testing.expect(relu.metadata.specialization.operationIs(.{ .activation = .relu }));

        const silu = findEntry(elementwise.Silu8F32.target, elementwise.Silu8F32.version) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(elementwise.Silu8F32.name, silu.name);
        try std.testing.expect(silu.metadata.specialization.operationIs(.{ .activation = .silu }));

        const bias_gelu = findEntry(fused.BiasGelu8F32.target, fused.BiasGelu8F32.version) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(fused.BiasGelu8F32.name, bias_gelu.name);
        try std.testing.expectEqual(entry.Category.fused, bias_gelu.metadata.category);
        try std.testing.expect(
            bias_gelu.metadata.specialization.operationIs(.{ .elementwise = .add }),
        );

        const bias_relu = findEntry(fused.BiasRelu8F32.target, fused.BiasRelu8F32.version) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(fused.BiasRelu8F32.name, bias_relu.name);
        try std.testing.expectEqual(entry.Category.fused, bias_relu.metadata.category);
        try std.testing.expect(bias_relu.metadata.specialization.epilogueMatches(
            0,
            .{ .operator = .{ .activation = .relu } },
        ));

        const bias_silu = findEntry(fused.BiasSilu8F32.target, fused.BiasSilu8F32.version) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(fused.BiasSilu8F32.name, bias_silu.name);
        try std.testing.expectEqual(entry.Category.fused, bias_silu.metadata.category);
        try std.testing.expect(bias_silu.metadata.specialization.epilogueMatches(
            0,
            .{ .operator = .{ .activation = .silu } },
        ));

        const geglu = findEntry(fused.GeGlu8F32.target, fused.GeGlu8F32.version) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(fused.GeGlu8F32.name, geglu.name);
        try std.testing.expectEqual(entry.Category.fused, geglu.metadata.category);
        try std.testing.expect(geglu.metadata.specialization.operationIs(.{ .elementwise = .mul }));

        const reglu = findEntry(fused.ReGlu8F32.target, fused.ReGlu8F32.version) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(fused.ReGlu8F32.name, reglu.name);
        try std.testing.expectEqual(entry.Category.fused, reglu.metadata.category);
        try std.testing.expect(reglu.metadata.specialization.operationIs(.{ .elementwise = .mul }));

        const swiglu = findEntry(fused.SwiGlu8F32.target, fused.SwiGlu8F32.version) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(fused.SwiGlu8F32.name, swiglu.name);
        try std.testing.expectEqual(entry.Category.fused, swiglu.metadata.category);
        try std.testing.expect(
            swiglu.metadata.specialization.operationIs(.{ .elementwise = .mul }),
        );

        const matmul_bias_gelu = findEntry(
            fused.MatrixProductBiasGelu2x3x4F32.target,
            fused.MatrixProductBiasGelu2x3x4F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            fused.MatrixProductBiasGelu2x3x4F32.name,
            matmul_bias_gelu.name,
        );
        try std.testing.expectEqual(entry.Category.fused, matmul_bias_gelu.metadata.category);
        try std.testing.expect(
            matmul_bias_gelu.metadata.specialization.operationIs(.{ .linalg = .matrix_product }),
        );

        const matmul_bias_gelu_thread_blocks = findEntry(
            fused.MatrixProductBiasGelu2x3x4ThreadBlocks1x2F32.target,
            fused.MatrixProductBiasGelu2x3x4ThreadBlocks1x2F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            fused.MatrixProductBiasGelu2x3x4ThreadBlocks1x2F32.name,
            matmul_bias_gelu_thread_blocks.name,
        );
        try std.testing.expectEqual(
            entry.Category.fused,
            matmul_bias_gelu_thread_blocks.metadata.category,
        );
        try std.testing.expect(matmul_bias_gelu_thread_blocks.metadata.specialization.operationIs(
            .{ .linalg = .matrix_product },
        ));

        const matmul_bias_relu = findEntry(
            fused.MatrixProductBiasRelu2x3x4F32.target,
            fused.MatrixProductBiasRelu2x3x4F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            fused.MatrixProductBiasRelu2x3x4F32.name,
            matmul_bias_relu.name,
        );
        try std.testing.expectEqual(entry.Category.fused, matmul_bias_relu.metadata.category);
        try std.testing.expect(matmul_bias_relu.metadata.specialization.epilogueMatches(
            1,
            .{ .operator = .{ .activation = .relu } },
        ));

        const matmul_bias_silu = findEntry(
            fused.MatrixProductBiasSilu2x3x4F32.target,
            fused.MatrixProductBiasSilu2x3x4F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            fused.MatrixProductBiasSilu2x3x4F32.name,
            matmul_bias_silu.name,
        );
        try std.testing.expectEqual(entry.Category.fused, matmul_bias_silu.metadata.category);
        try std.testing.expect(matmul_bias_silu.metadata.specialization.epilogueMatches(
            1,
            .{ .operator = .{ .activation = .silu } },
        ));

        const matvec_bias_gelu = findEntry(
            fused.MatrixVectorProductBiasGelu4x8F32.target,
            fused.MatrixVectorProductBiasGelu4x8F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            fused.MatrixVectorProductBiasGelu4x8F32.name,
            matvec_bias_gelu.name,
        );
        try std.testing.expectEqual(entry.Category.fused, matvec_bias_gelu.metadata.category);
        try std.testing.expect(matvec_bias_gelu.metadata.specialization.operationIs(
            .{ .linalg = .matrix_vector_product },
        ));

        const matvec_bias_relu = findEntry(
            fused.MatrixVectorProductBiasRelu4x8F32.target,
            fused.MatrixVectorProductBiasRelu4x8F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            fused.MatrixVectorProductBiasRelu4x8F32.name,
            matvec_bias_relu.name,
        );
        try std.testing.expectEqual(entry.Category.fused, matvec_bias_relu.metadata.category);
        try std.testing.expect(matvec_bias_relu.metadata.specialization.epilogueMatches(
            1,
            .{ .operator = .{ .activation = .relu } },
        ));

        const matvec_bias_silu = findEntry(
            fused.MatrixVectorProductBiasSilu4x8F32.target,
            fused.MatrixVectorProductBiasSilu4x8F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            fused.MatrixVectorProductBiasSilu4x8F32.name,
            matvec_bias_silu.name,
        );
        try std.testing.expectEqual(entry.Category.fused, matvec_bias_silu.metadata.category);
        try std.testing.expect(matvec_bias_silu.metadata.specialization.epilogueMatches(
            1,
            .{ .operator = .{ .activation = .silu } },
        ));

        const transpose = findEntry(
            layout.Transpose8x16F32.target,
            layout.Transpose8x16F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(layout.Transpose8x16F32.name, transpose.name);
        try std.testing.expectEqual(entry.Category.layout, transpose.metadata.category);
        try std.testing.expect(
            transpose.metadata.specialization.operationIs(.{ .layout = .transpose }),
        );

        const matrix_product = findEntry(
            linalg.MatrixProduct4x16x8F32.target,
            linalg.MatrixProduct4x16x8F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(linalg.MatrixProduct4x16x8F32.name, matrix_product.name);
        try std.testing.expectEqual(entry.Category.linalg, matrix_product.metadata.category);
        try std.testing.expect(
            matrix_product.metadata.specialization.operationIs(.{ .linalg = .matrix_product }),
        );

        const matrix_product_thread_blocks = findEntry(
            linalg.MatrixProduct4x16x8ThreadBlocks4x2F32.target,
            linalg.MatrixProduct4x16x8ThreadBlocks4x2F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            linalg.MatrixProduct4x16x8ThreadBlocks4x2F32.name,
            matrix_product_thread_blocks.name,
        );
        try std.testing.expectEqual(
            entry.Category.linalg,
            matrix_product_thread_blocks.metadata.category,
        );
        try std.testing.expect(matrix_product_thread_blocks.metadata.specialization.operationIs(
            .{ .linalg = .matrix_product },
        ));
        try std.testing.expect(findEntry(
            linalg.BatchedMatrixProduct2x2x3x4F32.target,
            linalg.BatchedMatrixProduct2x2x3x4F32.version,
        ) == null);
        try std.testing.expect(findEntry(
            linalg.MatrixProduct2x3x4F32.target,
            linalg.MatrixProduct2x3x4F32.version,
        ) == null);
        try std.testing.expect(findEntry(
            linalg.MatrixProduct8x12x16F32.target,
            linalg.MatrixProduct8x12x16F32.version,
        ) == null);
        try std.testing.expect(findEntry(
            linalg.MatrixVectorProduct4x8F32.target,
            linalg.MatrixVectorProduct4x8F32.version,
        ) == null);
        try std.testing.expect(
            findEntry(linalg.OuterProduct4x3F32.target, linalg.OuterProduct4x3F32.version) == null,
        );

        const sum = findEntry(reduction.Sum8F32.target, reduction.Sum8F32.version) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(reduction.Sum8F32.name, sum.name);
        try std.testing.expectEqual(entry.Category.reduction, sum.metadata.category);
        try std.testing.expect(sum.metadata.specialization.operationIs(.{ .reduction = .sum }));

        const dot = findEntry(reduction.Dot8F32.target, reduction.Dot8F32.version) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(reduction.Dot8F32.name, dot.name);
        try std.testing.expectEqual(entry.Category.reduction, dot.metadata.category);
        try std.testing.expect(
            dot.metadata.specialization.operationIs(.{ .reduction = .dot_product }),
        );

        const row_softmax = findEntry(
            normalization.RowSoftmax2x4F32.target,
            normalization.RowSoftmax2x4F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(normalization.RowSoftmax2x4F32.name, row_softmax.name);
        try std.testing.expectEqual(entry.Category.normalization, row_softmax.metadata.category);
        try std.testing.expect(
            row_softmax.metadata.specialization.operationIs(.{ .row_normalization = .softmax }),
        );

        const row_softmax_thread_blocks = findEntry(
            normalization.RowSoftmax2x4ThreadBlocks2x2F32.target,
            normalization.RowSoftmax2x4ThreadBlocks2x2F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            normalization.RowSoftmax2x4ThreadBlocks2x2F32.name,
            row_softmax_thread_blocks.name,
        );
        try std.testing.expectEqual(
            entry.Category.normalization,
            row_softmax_thread_blocks.metadata.category,
        );
        try std.testing.expect(row_softmax_thread_blocks.metadata.specialization.operationIs(
            .{ .row_normalization = .softmax },
        ));

        const row_log_softmax = findEntry(
            normalization.RowLogSoftmax2x4F32.target,
            normalization.RowLogSoftmax2x4F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            normalization.RowLogSoftmax2x4F32.name,
            row_log_softmax.name,
        );
        try std.testing.expectEqual(
            entry.Category.normalization,
            row_log_softmax.metadata.category,
        );
        try std.testing.expect(row_log_softmax.metadata.specialization.operationIs(
            .{ .row_normalization = .log_softmax },
        ));

        const row_rmsnorm = findEntry(
            normalization.RowRmsNorm2x4F32.target,
            normalization.RowRmsNorm2x4F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(normalization.RowRmsNorm2x4F32.name, row_rmsnorm.name);
        try std.testing.expectEqual(entry.Category.normalization, row_rmsnorm.metadata.category);
        try std.testing.expect(row_rmsnorm.metadata.specialization.operationIs(
            .{ .row_normalization = .{ .rmsnorm = .scale } },
        ));

        const row_residual_rmsnorm = findEntry(
            normalization.RowResidualRmsNorm2x4F32.target,
            normalization.RowResidualRmsNorm2x4F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            normalization.RowResidualRmsNorm2x4F32.name,
            row_residual_rmsnorm.name,
        );
        try std.testing.expectEqual(entry.Category.fused, row_residual_rmsnorm.metadata.category);
        try std.testing.expect(row_residual_rmsnorm.metadata.specialization.operationIs(
            .{ .row_normalization = .{ .rmsnorm = .scale } },
        ));
        try std.testing.expect(
            row_residual_rmsnorm.metadata.specialization.inputTransformMatches(0, .{
                .operator = .residual_add,
                .input_index = 1,
                .extents = &.{ 2, 4 },
            }),
        );

        const row_layernorm = findEntry(
            normalization.RowLayerNorm2x4F32.target,
            normalization.RowLayerNorm2x4F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            normalization.RowLayerNorm2x4F32.name,
            row_layernorm.name,
        );
        try std.testing.expectEqual(entry.Category.normalization, row_layernorm.metadata.category);
        try std.testing.expect(row_layernorm.metadata.specialization.operationIs(
            .{ .row_normalization = .{ .layernorm = .none } },
        ));

        const row_affine_layernorm = findEntry(
            normalization.RowAffineLayerNorm2x4F32.target,
            normalization.RowAffineLayerNorm2x4F32.version,
        ) orelse {
            return error.TestExpectedCatalogEntry;
        };
        try std.testing.expectEqualStrings(
            normalization.RowAffineLayerNorm2x4F32.name,
            row_affine_layernorm.name,
        );
        try std.testing.expectEqual(
            entry.Category.normalization,
            row_affine_layernorm.metadata.category,
        );
        try std.testing.expect(row_affine_layernorm.metadata.specialization.operationIs(
            .{ .row_normalization = .{ .layernorm = .scale_bias } },
        ));
    }
};

const artifact_tests = struct {
    test "kernel library catalog builds histogram scheduled artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        var candidates = try selectOwnedHistogramCandidates(allocator, .{
            .dtype = .f32,
            .bins = 128,
            .count = 8192,
            .schedule = .{ .thread_blocks = 256 },
        });
        defer candidates.deinit();
        try std.testing.expectEqual(@as(usize, 1), candidates.count);

        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            candidates.slice(),
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        try std.testing.expectEqual(candidates.count, registry.entries.len);

        for (candidates.slice()) |candidate| {
            const found = registry.find(
                candidate.descriptor.metadata.target,
                histogram_mod.histogram_family_version,
                .cuda_ptx,
            ) orelse return error.TestExpectedKernelCallArtifact;
            try std.testing.expectEqual(@as(u32, 4), found.runtime_scalar_argument_count);
            const launch = switch (found.launch) {
                .derived => |derived| derived,
                .fixed => return error.TestExpectedDerivedLaunch,
            };
            const specialization_launch = candidate.descriptor.metadata.specialization.launch orelse
                {
                    return error.TestExpectedSpecializationLaunch;
                };
            try std.testing.expectEqual(
                specialization_launch.threadgroup[0],
                launch.threadgroup[0],
            );
            const profile = found.shape_profile orelse return error.TestExpectedShapeProfile;
            try std.testing.expectEqual(@as(usize, 2), profile.dimensions.len);
        }
    }

    test "kernel library catalog builds image descriptor artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };

        var descriptors_owned: [2]OwnedDescriptor = undefined;
        descriptors_owned[0] = (try selectOwned(allocator, .{ .image = .{
            .dtype = .u32,
            .kind = .{ .blur_pass = .{ .radius = 2, .axis = .horizontal } },
            .width = 24,
            .height = 10,
            .schedule = .{ .thread_blocks = .{ .x = 8, .y = 4 } },
        } })) orelse return error.TestExpectedImageDescriptor;
        var owned_count: usize = 1;
        defer for (descriptors_owned[0..owned_count]) |*descriptor| descriptor.deinit();

        descriptors_owned[1] = (try selectOwned(allocator, .{ .image = .{
            .dtype = .u32,
            .kind = .{ .resize_bilinear = .{ .src_width = 20, .src_height = 12 } },
            .width = 11,
            .height = 7,
            .schedule = .{ .thread_blocks = .{ .x = 8, .y = 4 } },
        } })) orelse return error.TestExpectedImageDescriptor;
        owned_count = 2;

        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            descriptors_owned[0..owned_count],
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        try std.testing.expectEqual(@as(usize, 2), registry.entries.len);

        const blur_artifact = registry.find(
            "image_blur_pass_family_r2h_8x4_rgba8",
            image.blur_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };
        try std.testing.expectEqualStrings(
            "accy_image_blur_pass_r2h_rgba8",
            blur_artifact.entry_name,
        );
        try std.testing.expectEqual(@as(u32, 5), blur_artifact.argument_count);
        try std.testing.expectEqual(@as(u32, 2), blur_artifact.runtime_scalar_argument_count);
        try std.testing.expect(blur_artifact.required_dtypes.contains(.u32));
        try std.testing.expect(blur_artifact.required_dtypes.contains(.f32));
        try std.testing.expect(blur_artifact.required_dtypes.contains(.i32));
        const blur_launch = switch (blur_artifact.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        try std.testing.expectEqual(@as(u32, 8), blur_launch.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 4), blur_launch.threadgroup[1]);
        const blur_profile = blur_artifact.shape_profile orelse
            return error.TestExpectedShapeProfile;
        try std.testing.expectEqualStrings("image_blur_pass", blur_profile.name);
        try std.testing.expectEqual(@as(usize, 2), blur_profile.dimensions.len);
        try std.testing.expect(blur_profile.runtimeScalarDimension(0) != null);
        try std.testing.expect(blur_profile.runtimeScalarDimension(1) != null);

        const resize_artifact = registry.find(
            "image_resize_bilinear_family_8x4_rgba8",
            image.resize_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };
        try std.testing.expectEqualStrings(
            "accy_image_resize_bilinear_rgba8",
            resize_artifact.entry_name,
        );
        try std.testing.expectEqual(@as(u32, 9), resize_artifact.argument_count);
        try std.testing.expectEqual(@as(u32, 7), resize_artifact.runtime_scalar_argument_count);
        try std.testing.expect(resize_artifact.required_dtypes.contains(.u32));
        try std.testing.expect(resize_artifact.required_dtypes.contains(.f32));
        try std.testing.expect(resize_artifact.required_dtypes.contains(.i32));
        const resize_launch = switch (resize_artifact.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        try std.testing.expectEqual(@as(u32, 8), resize_launch.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 4), resize_launch.threadgroup[1]);
        const resize_profile = resize_artifact.shape_profile orelse
            return error.TestExpectedShapeProfile;
        try std.testing.expectEqualStrings("image_resize_bilinear", resize_profile.name);
        try std.testing.expectEqual(@as(usize, 3), resize_profile.dimensions.len);
        try std.testing.expect(resize_profile.runtimeScalarDimension(0) != null);
        try std.testing.expect(resize_profile.runtimeScalarDimension(1) != null);
        try std.testing.expect(resize_profile.runtimeScalarDimension(2) != null);
    }

    test "kernel library catalog builds factor descriptor artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };

        var descriptors_owned: [4]OwnedDescriptor = undefined;
        descriptors_owned[0] = (try selectOwnedFactor(allocator, .{
            .dtype = .f32,
            .kind = .{ .batched_cholesky = .{ .n = 3, .batch = 5000 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedFactorDescriptor;
        var owned_count: usize = 1;
        defer for (descriptors_owned[0..owned_count]) |*descriptor| descriptor.deinit();

        descriptors_owned[1] = (try selectOwnedFactor(allocator, .{
            .dtype = .f32,
            .kind = .{ .batched_cholesky_solve = .{ .n = 3, .batch = 5000 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedFactorDescriptor;
        owned_count = 2;

        descriptors_owned[2] = (try selectOwnedFactor(allocator, .{
            .dtype = .f32,
            .kind = .{ .batched_cholesky_solve = .{ .n = 3, .batch = 5000 } },
            .layout = .interleaved,
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedFactorDescriptor;
        owned_count = 3;
        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.batched_cholesky_solve_family_3_64_il_f32",
            descriptors_owned[2].descriptor.metadata.target,
        );
        try std.testing.expect(
            descriptors_owned[2].descriptor.metadata.specialization.layoutIs("interleaved"),
        );

        descriptors_owned[3] = (try selectOwnedFactor(allocator, .{
            .dtype = .f32,
            .kind = .{ .batched_inverse = .{ .n = 3, .batch = 5000 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedFactorDescriptor;
        owned_count = 4;

        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            descriptors_owned[0..owned_count],
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        try std.testing.expectEqual(@as(usize, 4), registry.entries.len);

        const versions = [_]u32{
            factor_mod.batched_cholesky_family_version,
            factor_mod.batched_cholesky_solve_family_version,
            factor_mod.batched_cholesky_solve_family_version,
            factor_mod.batched_inverse_family_version,
        };
        for (descriptors_owned[0..owned_count], versions) |descriptor, version| {
            const found = registry.find(
                descriptor.descriptor.metadata.target,
                version,
                .cuda_ptx,
            ) orelse return error.TestExpectedKernelCallArtifact;
            try std.testing.expectEqual(@as(u32, 1), found.runtime_scalar_argument_count);
            const launch = switch (found.launch) {
                .derived => |derived| derived,
                .fixed => return error.TestExpectedDerivedLaunch,
            };
            try std.testing.expectEqual(@as(u32, 64), launch.threadgroup[0]);
            const profile = found.shape_profile orelse return error.TestExpectedShapeProfile;
            try std.testing.expectEqual(@as(usize, 1), profile.dimensions.len);
        }
    }

    test "kernel library catalog rejects malformed factor descriptor artifacts" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };

        {
            var descriptor = (try selectOwnedFactor(allocator, .{
                .dtype = .f32,
                .kind = .{ .batched_cholesky = .{ .n = 3, .batch = 5000 } },
                .schedule = .{ .thread_blocks = 64 },
            })) orelse return error.TestExpectedFactorDescriptor;
            defer descriptor.deinit();

            if (descriptor.specialization) |*specialization| {
                const lifetime_allocator = specialization.allocator();
                specialization.value.inputs = &.{
                    try entry.runtimeShape3D(lifetime_allocator, "b", 4096, "i", 3, "j", 3),
                };
                descriptor.descriptor.metadata.specialization = specialization.value;
            } else return error.TestExpectedOwnedSpecialization;

            try std.testing.expectError(
                error.UnknownKernelLibraryEntry,
                createOwnedKernelCallArtifact(
                    allocator,
                    state.handle(),
                    descriptor,
                    .{ .limits = .testing },
                ),
            );
        }

        {
            var descriptor = (try selectOwnedFactor(allocator, .{
                .dtype = .f32,
                .kind = .{ .batched_cholesky_solve = .{ .n = 3, .batch = 5000 } },
                .schedule = .{ .thread_blocks = 64 },
            })) orelse return error.TestExpectedFactorDescriptor;
            defer descriptor.deinit();

            if (descriptor.specialization) |*specialization| {
                const lifetime_allocator = specialization.allocator();
                const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
                inputs[0] = specialization.value.inputs[0];
                inputs[1] = try entry.runtimeShape2D(lifetime_allocator, "b", 5000, "i", 4);
                specialization.value.inputs = inputs;
                descriptor.descriptor.metadata.specialization = specialization.value;
            } else return error.TestExpectedOwnedSpecialization;

            try std.testing.expectError(
                error.UnknownKernelLibraryEntry,
                createOwnedKernelCallArtifact(
                    allocator,
                    state.handle(),
                    descriptor,
                    .{ .limits = .testing },
                ),
            );
        }
    }

    test "kernel library catalog builds sparse descriptor artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };

        var descriptors_owned: [10]OwnedDescriptor = undefined;
        descriptors_owned[0] = (try selectOwnedSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        var owned_count: usize = 1;
        defer for (descriptors_owned[0..owned_count]) |*descriptor| descriptor.deinit();

        descriptors_owned[1] = (try selectOwnedSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 90, .x_extent = 40 } },
            .structure = .row_thread,
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        owned_count = 2;

        descriptors_owned[2] = (try selectOwnedSparse(allocator, .{
            .dtype = .f16,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        owned_count = 3;

        descriptors_owned[3] = (try selectOwnedSparse(allocator, .{
            .dtype = .f64,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        owned_count = 4;

        descriptors_owned[4] = (try selectOwnedSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        owned_count = 5;

        descriptors_owned[5] = (try selectOwnedSparse(allocator, .{
            .dtype = .f16,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        owned_count = 6;

        descriptors_owned[6] = (try selectOwnedSparse(allocator, .{
            .dtype = .f64,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        owned_count = 7;

        descriptors_owned[7] = (try selectOwnedSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmm = .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40 } },
            .schedule = .{ .thread_blocks_2d = .{ .x = 8, .y = 4 } },
        })) orelse return error.TestExpectedSparseDescriptor;
        owned_count = 8;

        descriptors_owned[8] = (try selectOwnedSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .ell_spmv = .{ .rows = 70, .slots = 8, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        owned_count = 9;

        descriptors_owned[9] = (try selectOwnedSparse(allocator, .{
            .dtype = .f32,
            .kind = .{
                .sell_spmv = .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40 },
            },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        owned_count = 10;

        const warp_instance = sparse_mod.spmvCsrInstanceFromSpecialization(
            descriptors_owned[0].descriptor.metadata.specialization,
        ) orelse return error.TestExpectedSparseInstance;
        try std.testing.expectEqual(@as(u64, 70), warp_instance.rows);
        try std.testing.expectEqual(@as(u64, 560), warp_instance.nnz);
        try std.testing.expectEqual(@as(u64, 40), warp_instance.x_extent);
        try std.testing.expectEqual(sparse_mod.SpmvCsrStructure.row_warp, warp_instance.structure);

        const thread_instance = sparse_mod.spmvCsrInstanceFromSpecialization(
            descriptors_owned[1].descriptor.metadata.specialization,
        ) orelse return error.TestExpectedSparseInstance;
        try std.testing.expectEqual(@as(u64, 70), thread_instance.rows);
        try std.testing.expectEqual(@as(u64, 90), thread_instance.nnz);
        try std.testing.expectEqual(@as(u64, 40), thread_instance.x_extent);
        try std.testing.expectEqual(
            sparse_mod.SpmvCsrStructure.row_thread,
            thread_instance.structure,
        );

        const half_instance = sparse_mod.spmvCsrInstanceFromSpecialization(
            descriptors_owned[2].descriptor.metadata.specialization,
        ) orelse return error.TestExpectedSparseInstance;
        try std.testing.expectEqual(gpu_abi.DType.f16, half_instance.dtype);
        try std.testing.expectEqual(gpu_abi.DType.f32, half_instance.accumulation_dtype);
        try std.testing.expectEqual(sparse_mod.SpmvCsrStructure.row_warp, half_instance.structure);

        const double_instance = sparse_mod.spmvCsrInstanceFromSpecialization(
            descriptors_owned[3].descriptor.metadata.specialization,
        ) orelse return error.TestExpectedSparseInstance;
        try std.testing.expectEqual(gpu_abi.DType.f64, double_instance.dtype);
        try std.testing.expectEqual(gpu_abi.DType.f64, double_instance.accumulation_dtype);
        try std.testing.expectEqual(
            sparse_mod.SpmvCsrStructure.row_warp,
            double_instance.structure,
        );

        const coo_instance = sparse_mod.spmvCooInstanceFromSpecialization(
            descriptors_owned[4].descriptor.metadata.specialization,
        ) orelse return error.TestExpectedSparseInstance;
        try std.testing.expectEqual(@as(u64, 70), coo_instance.rows);
        try std.testing.expectEqual(@as(u64, 560), coo_instance.nnz);
        try std.testing.expectEqual(@as(u64, 40), coo_instance.x_extent);
        try std.testing.expectEqual(
            sparse_mod.SpmvCooStructure.element_thread,
            coo_instance.structure,
        );

        const coo_half_instance = sparse_mod.spmvCooInstanceFromSpecialization(
            descriptors_owned[5].descriptor.metadata.specialization,
        ) orelse return error.TestExpectedSparseInstance;
        try std.testing.expectEqual(gpu_abi.DType.f16, coo_half_instance.dtype);
        try std.testing.expectEqual(gpu_abi.DType.f32, coo_half_instance.accumulation_dtype);
        try std.testing.expectEqual(
            sparse_mod.SpmvCooStructure.row_thread,
            coo_half_instance.structure,
        );

        const coo_double_instance = sparse_mod.spmvCooInstanceFromSpecialization(
            descriptors_owned[6].descriptor.metadata.specialization,
        ) orelse return error.TestExpectedSparseInstance;
        try std.testing.expectEqual(gpu_abi.DType.f64, coo_double_instance.dtype);
        try std.testing.expectEqual(gpu_abi.DType.f64, coo_double_instance.accumulation_dtype);
        try std.testing.expectEqual(
            sparse_mod.SpmvCooStructure.row_thread,
            coo_double_instance.structure,
        );

        const spmm_instance = sparse_mod.spmmCsrInstanceFromSpecialization(
            descriptors_owned[7].descriptor.metadata.specialization,
        ) orelse return error.TestExpectedSparseInstance;
        try std.testing.expectEqual(@as(u64, 70), spmm_instance.rows);
        try std.testing.expectEqual(@as(u64, 45), spmm_instance.columns);
        try std.testing.expectEqual(@as(u64, 512), spmm_instance.nnz);
        try std.testing.expectEqual(@as(u64, 40), spmm_instance.x_extent);
        try std.testing.expectEqual(
            sparse_mod.SpmmCsrStructure.row_column_thread,
            spmm_instance.structure,
        );

        const ell_instance = sparse_mod.spmvEllInstanceFromSpecialization(
            descriptors_owned[8].descriptor.metadata.specialization,
        ) orelse return error.TestExpectedSparseInstance;
        try std.testing.expectEqual(@as(u64, 70), ell_instance.rows);
        try std.testing.expectEqual(@as(u64, 8), ell_instance.slots);
        try std.testing.expectEqual(@as(u64, 40), ell_instance.x_extent);
        try std.testing.expectEqual(sparse_mod.SpmvEllStructure.row_thread, ell_instance.structure);

        const sell_instance = sparse_mod.spmvSellInstanceFromSpecialization(
            descriptors_owned[9].descriptor.metadata.specialization,
        ) orelse return error.TestExpectedSparseInstance;
        try std.testing.expectEqual(@as(u64, 70), sell_instance.rows);
        try std.testing.expectEqual(@as(u64, 8), sell_instance.slice_size);
        try std.testing.expectEqual(@as(u64, 400), sell_instance.values_size);
        try std.testing.expectEqual(@as(u64, 40), sell_instance.x_extent);
        try std.testing.expectEqual(
            sparse_mod.SpmvSellStructure.row_thread,
            sell_instance.structure,
        );
        try std.testing.expect(
            descriptors_owned[9].descriptor.metadata.specialization.staticParameterMatches(
                sparse_mod.spmv_sell_slice_size_parameter,
                8,
            ),
        );

        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            descriptors_owned[0..owned_count],
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        try std.testing.expectEqual(@as(usize, 10), registry.entries.len);

        for (descriptors_owned[0..4]) |descriptor| {
            const found = registry.find(
                descriptor.descriptor.metadata.target,
                sparse_mod.spmv_csr_family_version,
                .cuda_ptx,
            ) orelse return error.TestExpectedKernelCallArtifact;
            try std.testing.expectEqual(@as(u32, 3), found.runtime_scalar_argument_count);
            const launch = switch (found.launch) {
                .derived => |derived| derived,
                .fixed => return error.TestExpectedDerivedLaunch,
            };
            try std.testing.expectEqual(@as(u32, 64), launch.threadgroup[0]);
            const profile = found.shape_profile orelse return error.TestExpectedShapeProfile;
            try std.testing.expectEqual(@as(usize, 1), profile.dimensions.len);
        }

        for (descriptors_owned[4..7], 0..) |coo_descriptor, coo_index| {
            const coo_artifact = registry.find(
                coo_descriptor.descriptor.metadata.target,
                sparse_mod.spmv_coo_family_version,
                .cuda_ptx,
            ) orelse return error.TestExpectedKernelCallArtifact;
            try std.testing.expectEqual(@as(u32, 3), coo_artifact.runtime_scalar_argument_count);
            const coo_launch = switch (coo_artifact.launch) {
                .derived => |derived| derived,
                .fixed => return error.TestExpectedDerivedLaunch,
            };
            try std.testing.expectEqual(@as(u32, 64), coo_launch.threadgroup[0]);
            const coo_profile = coo_artifact.shape_profile orelse
                return error.TestExpectedShapeProfile;
            try std.testing.expectEqual(@as(usize, 2), coo_profile.dimensions.len);
            switch (coo_launch.grid[0]) {
                .runtime_u32_ceil_div => |ceil| {
                    try std.testing.expectEqual(@as(u32, if (coo_index == 0)
                        1
                    else
                        0), ceil.argument_index);
                    try std.testing.expectEqual(@as(u32, 64), ceil.divisor);
                },
                else => return error.TestExpectedDerivedGrid,
            }
        }

        const spmm_descriptor = descriptors_owned[7];
        const spmm_artifact = registry.find(
            spmm_descriptor.descriptor.metadata.target,
            sparse_mod.spmm_csr_family_version,
            .cuda_ptx,
        ) orelse return error.TestExpectedKernelCallArtifact;
        try std.testing.expectEqual(@as(u32, 4), spmm_artifact.runtime_scalar_argument_count);
        const spmm_launch = switch (spmm_artifact.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        try std.testing.expectEqual(@as(u32, 8), spmm_launch.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 4), spmm_launch.threadgroup[1]);
        const spmm_profile = spmm_artifact.shape_profile orelse
            return error.TestExpectedShapeProfile;
        try std.testing.expectEqual(@as(usize, 2), spmm_profile.dimensions.len);

        const ell_descriptor = descriptors_owned[8];
        const ell_artifact = registry.find(
            ell_descriptor.descriptor.metadata.target,
            sparse_mod.spmv_ell_family_version,
            .cuda_ptx,
        ) orelse return error.TestExpectedKernelCallArtifact;
        try std.testing.expectEqual(@as(u32, 3), ell_artifact.runtime_scalar_argument_count);
        const ell_launch = switch (ell_artifact.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        try std.testing.expectEqual(@as(u32, 64), ell_launch.threadgroup[0]);
        const ell_profile = ell_artifact.shape_profile orelse return error.TestExpectedShapeProfile;
        try std.testing.expectEqual(@as(usize, 1), ell_profile.dimensions.len);

        const sell_descriptor = descriptors_owned[9];
        const sell_artifact = registry.find(
            sell_descriptor.descriptor.metadata.target,
            sparse_mod.spmv_sell_family_version,
            .cuda_ptx,
        ) orelse return error.TestExpectedKernelCallArtifact;
        try std.testing.expectEqual(@as(u32, 3), sell_artifact.runtime_scalar_argument_count);
        const sell_launch = switch (sell_artifact.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        try std.testing.expectEqual(@as(u32, 64), sell_launch.threadgroup[0]);
        const sell_profile = sell_artifact.shape_profile orelse
            return error.TestExpectedShapeProfile;
        try std.testing.expectEqual(@as(usize, 1), sell_profile.dimensions.len);

        const warp_descriptor = descriptors_owned[0];
        const warp_artifact = registry.find(
            warp_descriptor.descriptor.metadata.target,
            sparse_mod.spmv_csr_family_version,
            .cuda_ptx,
        ) orelse return error.TestExpectedKernelCallArtifact;
        switch (warp_artifact.launch.derived.grid[0]) {
            .runtime_u32_ceil_div => |ceil| {
                try std.testing.expectEqual(@as(u32, 0), ceil.argument_index);
                try std.testing.expectEqual(@as(u32, 2), ceil.divisor);
            },
            else => return error.TestExpectedDerivedGrid,
        }
        switch (spmm_artifact.launch.derived.grid[0]) {
            .runtime_u32_ceil_div => |ceil| {
                try std.testing.expectEqual(@as(u32, 3), ceil.argument_index);
                try std.testing.expectEqual(@as(u32, 8), ceil.divisor);
            },
            else => return error.TestExpectedDerivedGrid,
        }
        switch (spmm_artifact.launch.derived.grid[1]) {
            .runtime_u32_ceil_div => |ceil| {
                try std.testing.expectEqual(@as(u32, 0), ceil.argument_index);
                try std.testing.expectEqual(@as(u32, 4), ceil.divisor);
            },
            else => return error.TestExpectedDerivedGrid,
        }
        switch (ell_artifact.launch.derived.grid[0]) {
            .runtime_u32_ceil_div => |ceil| {
                try std.testing.expectEqual(@as(u32, 0), ceil.argument_index);
                try std.testing.expectEqual(@as(u32, 64), ceil.divisor);
            },
            else => return error.TestExpectedDerivedGrid,
        }
        switch (sell_artifact.launch.derived.grid[0]) {
            .runtime_u32_ceil_div => |ceil| {
                try std.testing.expectEqual(@as(u32, 0), ceil.argument_index);
                try std.testing.expectEqual(@as(u32, 64), ceil.divisor);
            },
            else => return error.TestExpectedDerivedGrid,
        }
    }

    test "kernel library catalog builds tiny csr spmv candidate artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };

        var candidates = try selectOwnedSparseCandidates(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmv = .{ .rows = 8, .nnz = 64, .x_extent = 8 } },
        });
        defer candidates.deinit();
        try std.testing.expectEqual(@as(usize, 2), candidates.count);

        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            candidates.slice(),
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        try std.testing.expectEqual(candidates.count, registry.entries.len);

        for (candidates.slice()) |candidate| {
            const found = registry.find(
                candidate.descriptor.metadata.target,
                sparse_mod.spmv_csr_family_version,
                .cuda_ptx,
            ) orelse return error.TestExpectedKernelCallArtifact;
            try std.testing.expectEqual(@as(u32, 3), found.runtime_scalar_argument_count);
        }
    }

    test "kernel library catalog rejects malformed sparse descriptor artifacts" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };

        {
            var descriptor = (try selectOwnedSparse(allocator, .{
                .dtype = .f32,
                .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
                .schedule = .{ .thread_blocks = 64 },
            })) orelse return error.TestExpectedSparseDescriptor;
            defer descriptor.deinit();

            if (descriptor.specialization) |*specialization| {
                const lifetime_allocator = specialization.allocator();
                const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
                inputs[0] = specialization.value.inputs[0];
                inputs[1] = specialization.value.inputs[1];
                inputs[2] = specialization.value.inputs[2];
                inputs[3] = try entry.runtimeShape1D(lifetime_allocator, "bad_x", 40);
                specialization.value.inputs = inputs;
                descriptor.descriptor.metadata.specialization = specialization.value;
            } else return error.TestExpectedOwnedSpecialization;

            try std.testing.expectError(
                error.UnknownKernelLibraryEntry,
                createOwnedKernelCallArtifact(
                    allocator,
                    state.handle(),
                    descriptor,
                    .{ .limits = .testing },
                ),
            );
        }

        {
            var descriptor = (try selectOwnedSparse(allocator, .{
                .dtype = .f32,
                .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
                .structure = .row_warp,
                .schedule = .{ .thread_blocks = 64 },
            })) orelse return error.TestExpectedSparseDescriptor;
            defer descriptor.deinit();

            if (descriptor.specialization) |*specialization| {
                const lifetime_allocator = specialization.allocator();
                specialization.value.schedule = try entry.runtimeThreadBlocks1D(
                    lifetime_allocator,
                    "r",
                    70,
                    64,
                );
                specialization.value.launch = specialization.value.schedule.?.launch();
                descriptor.descriptor.metadata.specialization = specialization.value;
            } else return error.TestExpectedOwnedSpecialization;

            try std.testing.expectError(
                error.UnknownKernelLibraryEntry,
                createOwnedKernelCallArtifact(
                    allocator,
                    state.handle(),
                    descriptor,
                    .{ .limits = .testing },
                ),
            );
        }

        {
            var descriptor = (try selectOwnedSparse(allocator, .{
                .dtype = .f32,
                .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
                .schedule = .{ .thread_blocks = 64 },
            })) orelse return error.TestExpectedSparseDescriptor;
            defer descriptor.deinit();

            if (descriptor.specialization) |*specialization| {
                const lifetime_allocator = specialization.allocator();
                specialization.value.schedule = try entry.runtimeThreadBlocks1D(
                    lifetime_allocator,
                    "r",
                    70,
                    64,
                );
                specialization.value.launch = specialization.value.schedule.?.launch();
                descriptor.descriptor.metadata.specialization = specialization.value;
            } else return error.TestExpectedOwnedSpecialization;

            try std.testing.expectError(
                error.UnknownKernelLibraryEntry,
                createOwnedKernelCallArtifact(
                    allocator,
                    state.handle(),
                    descriptor,
                    .{ .limits = .testing },
                ),
            );
        }

        {
            var descriptor = (try selectOwnedSparse(allocator, .{
                .dtype = .f32,
                .kind = .{ .sell_spmv = .{
                    .rows = 70,
                    .slice_size = 8,
                    .values_size = 400,
                    .x_extent = 40,
                } },
                .schedule = .{ .thread_blocks = 64 },
            })) orelse return error.TestExpectedSparseDescriptor;
            defer descriptor.deinit();

            if (descriptor.specialization) |*specialization| {
                specialization.value.static_parameters = &.{};
                descriptor.descriptor.metadata.specialization = specialization.value;
            } else return error.TestExpectedOwnedSpecialization;

            try std.testing.expectError(
                error.UnknownKernelLibraryEntry,
                createOwnedKernelCallArtifact(
                    allocator,
                    state.handle(),
                    descriptor,
                    .{ .limits = .testing },
                ),
            );
        }
    }

    test "kernel library catalog builds spatial descriptor artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };

        var descriptors_owned: [3]OwnedDescriptor = undefined;
        descriptors_owned[0] = (try selectOwnedSpatial(allocator, .{
            .dtype = .f32,
            .kind = .grid_cells,
            .count = 5000,
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSpatialDescriptor;
        var owned_count: usize = 1;
        defer for (descriptors_owned[0..owned_count]) |*descriptor| descriptor.deinit();

        descriptors_owned[1] = (try selectOwnedSpatial(allocator, .{
            .dtype = .i32,
            .kind = .{ .grid_count = .{ .cells = 64 } },
            .count = 5000,
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSpatialDescriptor;
        owned_count = 2;

        descriptors_owned[2] = (try selectOwnedSpatial(allocator, .{
            .dtype = .f32,
            .kind = .{ .grid_neighbor_count = .{ .cells = 64, .stride = 79 } },
            .count = 5000,
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSpatialDescriptor;
        owned_count = 3;

        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            descriptors_owned[0..],
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        try std.testing.expectEqual(@as(usize, 3), registry.entries.len);

        const expected_scalars = [_]u32{ 6, 2, 8 };
        const versions = [_]u32{
            spatial_mod.grid_cells_family_version,
            spatial_mod.grid_count_family_version,
            spatial_mod.grid_neighbor_count_family_version,
        };
        for (descriptors_owned[0..], expected_scalars, versions) |descriptor, scalars, version| {
            const found = registry.find(
                descriptor.descriptor.metadata.target,
                version,
                .cuda_ptx,
            ) orelse return error.TestExpectedKernelCallArtifact;
            try std.testing.expectEqual(scalars, found.runtime_scalar_argument_count);
            const launch = switch (found.launch) {
                .derived => |derived| derived,
                .fixed => return error.TestExpectedDerivedLaunch,
            };
            try std.testing.expectEqual(@as(u32, 64), launch.threadgroup[0]);
            const profile = found.shape_profile orelse return error.TestExpectedShapeProfile;
            try std.testing.expect(profile.dimensions.len >= 1);
        }
    }

    test "kernel library catalog rejects malformed spatial descriptor artifacts" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };

        {
            var descriptor = (try selectOwnedSpatial(allocator, .{
                .dtype = .f32,
                .kind = .grid_cells,
                .count = 5000,
                .schedule = .{ .thread_blocks = 64 },
            })) orelse return error.TestExpectedSpatialDescriptor;
            defer descriptor.deinit();

            if (descriptor.specialization) |*specialization| {
                const lifetime_allocator = specialization.allocator();
                const inputs = try lifetime_allocator.alloc(entry.Shape, 2);
                inputs[0] = try entry.runtimeShape1D(lifetime_allocator, "bad_p", 5000);
                inputs[1] = specialization.value.inputs[1];
                specialization.value.inputs = inputs;
                descriptor.descriptor.metadata.specialization = specialization.value;
            } else return error.TestExpectedOwnedSpecialization;

            try std.testing.expectError(
                error.UnknownKernelLibraryEntry,
                createOwnedKernelCallArtifact(
                    allocator,
                    state.handle(),
                    descriptor,
                    .{ .limits = .testing },
                ),
            );
        }

        {
            var descriptor = (try selectOwnedSpatial(allocator, .{
                .dtype = .i32,
                .kind = .{ .grid_count = .{ .cells = 64 } },
                .count = 5000,
                .schedule = .{ .thread_blocks = 64 },
            })) orelse return error.TestExpectedSpatialDescriptor;
            defer descriptor.deinit();

            if (descriptor.specialization) |*specialization| {
                const lifetime_allocator = specialization.allocator();
                const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
                outputs[0] = try entry.runtimeShape2D(
                    lifetime_allocator,
                    spatial_mod.grid_count_cell_axis,
                    64,
                    "bad_b",
                    spatial_mod.gridCellsBlockCount(5000, 64),
                );
                specialization.value.outputs = outputs;
                descriptor.descriptor.metadata.specialization = specialization.value;
            } else return error.TestExpectedOwnedSpecialization;

            try std.testing.expectError(
                error.UnknownKernelLibraryEntry,
                createOwnedKernelCallArtifact(
                    allocator,
                    state.handle(),
                    descriptor,
                    .{ .limits = .testing },
                ),
            );
        }

        {
            var descriptor = (try selectOwnedSpatial(allocator, .{
                .dtype = .f32,
                .kind = .{ .grid_neighbor_count = .{ .cells = 64, .stride = 79 } },
                .count = 5000,
                .schedule = .{ .thread_blocks = 64 },
            })) orelse return error.TestExpectedSpatialDescriptor;
            defer descriptor.deinit();

            if (descriptor.specialization) |*specialization| {
                const lifetime_allocator = specialization.allocator();
                const inputs = try lifetime_allocator.alloc(entry.Shape, 4);
                inputs[0] = specialization.value.inputs[0];
                inputs[1] = specialization.value.inputs[1];
                inputs[2] = try entry.runtimeShape1D(lifetime_allocator, "p", 4999);
                inputs[3] = specialization.value.inputs[3];
                specialization.value.inputs = inputs;
                descriptor.descriptor.metadata.specialization = specialization.value;
            } else return error.TestExpectedOwnedSpecialization;

            try std.testing.expectError(
                error.UnknownKernelLibraryEntry,
                createOwnedKernelCallArtifact(
                    allocator,
                    state.handle(),
                    descriptor,
                    .{ .limits = .testing },
                ),
            );
        }
    }

    test "kernel library catalog builds static descriptor artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        const descriptor = findEntry(
            elementwise.VectorAdd8F32.target,
            elementwise.VectorAdd8F32.version,
        ) orelse {
            return error.TestExpectedCatalogDescriptor;
        };
        const owned = [_]OwnedDescriptor{.{ .descriptor = descriptor }};
        var registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            owned[0..],
            .{ .limits = .testing },
        );
        defer registry.deinit();
        const artifact_entry = registry.registry().find(
            elementwise.VectorAdd8F32.target,
            elementwise.VectorAdd8F32.version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };

        try std.testing.expectEqual(@as(usize, 1), registry.registry().entries.len);
        try std.testing.expectEqualStrings(elementwise.VectorAdd8F32.target, artifact_entry.target);
        try std.testing.expectEqualStrings(
            elementwise.VectorAdd8F32.name,
            artifact_entry.entry_name,
        );
    }
};

const variants_tests = struct {
    test "kernel library catalog matrix product candidates preserve explicit schedule" {
        const lhs_dims = [_]i64{ 5, 3 };
        const rhs_dims = [_]i64{ 3, 7 };
        const output_dims = [_]i64{ 5, 7 };
        const schedule = MatrixProductSchedule{ .thread_blocks = .{ .x = 4, .y = 2 } };
        var candidates = try selectOwnedMatrixProductCandidates(std.testing.allocator, .{
            .dtype = .f32,
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
            .schedule = schedule,
        });
        defer candidates.deinit();

        try std.testing.expectEqual(@as(usize, 1), candidates.count);
        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.matmul_family_4x2_f32",
            candidates.items[0].descriptor.metadata.target,
        );
        try std.testing.expect(matrixProductDescriptorMatches(
            candidates.items[0].descriptor,
            .{ .m = 5, .n = 7, .k = 3 },
            schedule,
            .f32,
        ));
    }

    test "kernel library catalog selects matrix product family schedule specialization" {
        const lhs_dims = [_]i64{ 5, 3 };
        const rhs_dims = [_]i64{ 3, 7 };
        const output_dims = [_]i64{ 5, 7 };
        const schedule = MatrixProductSchedule{ .thread_blocks = .{ .x = 4, .y = 2 } };
        var selected = (try selectOwned(std.testing.allocator, .{ .matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
            .schedule = schedule,
        } })) orelse return error.TestExpectedMatrixProductFamilyScheduleSelection;
        defer selected.deinit();
        const specialization = selected.descriptor.metadata.specialization;

        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.matmul_family_4x2_f32",
            selected.descriptor.metadata.target,
        );
        try std.testing.expect(matrixProductDescriptorMatches(
            selected.descriptor,
            .{ .m = 5, .n = 7, .k = 3 },
            schedule,
            .f32,
        ));
        try std.testing.expect(specialization.shape_family != null);
        try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.grid[0]);
        try std.testing.expectEqual(@as(u32, 3), specialization.launch.?.grid[1]);
        try std.testing.expectEqual(@as(u32, 4), specialization.launch.?.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[1]);
    }

    test "kernel library catalog rejects unavailable matrix product family variants" {
        const lhs_dims = [_]i64{ 5, 3 };
        const rhs_dims = [_]i64{ 3, 7 };
        const output_dims = [_]i64{ 5, 7 };
        const bad_output_dims = [_]i64{ 5, 8 };

        try std.testing.expect((try selectOwned(std.testing.allocator, .{ .matrix_product = .{
            .dtype = .bf16,
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } })) == null);
        try std.testing.expect((try selectOwned(std.testing.allocator, .{ .matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &bad_output_dims,
        } })) == null);
        try std.testing.expect((try selectOwned(std.testing.allocator, .{ .matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 0, .y = 2 } },
        } })) == null);
    }

    test "kernel library catalog selects batched matrix product family for fresh extents" {
        const lhs_dims = [_]i64{ 3, 5, 4 };
        const rhs_dims = [_]i64{ 3, 4, 6 };
        const output_dims = [_]i64{ 3, 5, 6 };
        var selected = (try selectOwned(std.testing.allocator, .{ .batched_matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "bmk",
            .rhs_indices = "bkn",
            .output_indices = "bmn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } })) orelse return error.TestExpectedBatchedMatrixProductFamilySelection;
        defer selected.deinit();
        const specialization = selected.descriptor.metadata.specialization;

        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.batched_matmul_family_6x5x3_f32",
            selected.descriptor.metadata.target,
        );
        try std.testing.expect(specialization.shape_family != null);
        try std.testing.expect(specialization.operationIs(.{ .linalg = .batched_matrix_product }));
        try std.testing.expect(specialization.inputHasExtents(0, &.{ 3, 5, 4 }));
        try std.testing.expect(specialization.inputHasExtents(1, &.{ 3, 4, 6 }));
        try std.testing.expect(specialization.outputHasExtents(0, &.{ 3, 5, 6 }));
        try std.testing.expect(specialization.reductionMatches(
            0,
            .{ .name = "dot", .operator = .dot_product, .extents = &.{4} },
        ));
        try std.testing.expectEqual(@as(u32, 6), specialization.launch.?.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 5), specialization.launch.?.threadgroup[1]);
        try std.testing.expectEqual(@as(u32, 3), specialization.launch.?.threadgroup[2]);
    }

    test "kernel library catalog creates batched matrix product family artifact from owned descriptor" {
        const lhs_dims = [_]i64{ 3, 5, 4 };
        const rhs_dims = [_]i64{ 3, 4, 6 };
        const output_dims = [_]i64{ 3, 5, 6 };
        var selected = (try selectOwned(std.testing.allocator, .{ .batched_matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "bmk",
            .rhs_indices = "bkn",
            .output_indices = "bmn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 4, .y = 2, .z = 2 } },
        } })) orelse return error.TestExpectedBatchedMatrixProductFamilyScheduleSelection;
        defer selected.deinit();

        var state = gpu.recording.BackendState{
            .allocator = std.testing.allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        var artifact = try createOwnedKernelCallArtifact(
            std.testing.allocator,
            state.handle(),
            selected,
            .{ .limits = .testing },
        );
        defer artifact.deinit();
        const entry_value = artifact.entry();

        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.batched_matmul_family_4x2x2_f32",
            selected.descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.batched_matmul_family_4x2x2_f32",
            entry_value.target,
        );
        try std.testing.expectEqual(@as(u32, 7), entry_value.argument_count);
        try std.testing.expectEqual(@as(u32, 4), entry_value.runtime_scalar_argument_count);
        switch (entry_value.launch) {
            .derived => |launch| {
                try std.testing.expectEqual(@as(u32, 4), launch.threadgroup[0]);
                try std.testing.expectEqual(@as(u32, 2), launch.threadgroup[1]);
                try std.testing.expectEqual(@as(u32, 2), launch.threadgroup[2]);
            },
            else => return error.TestExpectedDerivedLaunch,
        }
    }

    test "kernel library catalog selects matrix vector product family by canonical einsum roles" {
        const matrix_dims = [_]i64{ 4, 8 };
        const vector_dims = [_]i64{8};
        const output_dims = [_]i64{4};
        const query = Query{ .matrix_vector_product = .{
            .dtype = .f32,
            .matrix_indices = "mk",
            .vector_indices = "k",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &vector_dims,
            .output_dims = &output_dims,
        } };
        try std.testing.expect(select(query) == null);
        var selected = (try selectOwned(std.testing.allocator, query)) orelse
            return error.TestExpectedMatrixVectorProductSelection;
        defer selected.deinit();
        const specialization = selected.descriptor.metadata.specialization;

        try std.testing.expect(selected.specialization != null);
        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.matvec_family_4x_f32",
            selected.descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy_kernel_linalg_matvec_family_4x_f32",
            selected.descriptor.name,
        );
        try std.testing.expect(specialization.operationIs(.{ .linalg = .matrix_vector_product }));
        try std.testing.expect(specialization.shape_family != null);
        try std.testing.expectEqual(@as(u32, 4), specialization.launch.?.threadgroup[0]);
    }

    test "kernel library catalog selects outer product family by canonical einsum roles" {
        const lhs_dims = [_]i64{4};
        const rhs_dims = [_]i64{3};
        const output_dims = [_]i64{ 4, 3 };
        const query = Query{ .outer_product = .{
            .dtype = .f32,
            .lhs_indices = "m",
            .rhs_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } };
        try std.testing.expect(select(query) == null);
        var selected = (try selectOwned(std.testing.allocator, query)) orelse
            return error.TestExpectedOuterProductSelection;
        defer selected.deinit();
        const specialization = selected.descriptor.metadata.specialization;

        try std.testing.expect(selected.specialization != null);
        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.outer_family_3x4_f32",
            selected.descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy_kernel_linalg_outer_family_3x4_f32",
            selected.descriptor.name,
        );
        try std.testing.expect(specialization.operationIs(.{ .linalg = .outer_product }));
        try std.testing.expect(specialization.shape_family != null);
        try std.testing.expectEqual(@as(usize, 0), specialization.reductions.len);
        try std.testing.expectEqual(@as(u32, 3), specialization.launch.?.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 4), specialization.launch.?.threadgroup[1]);
    }

    test "kernel library catalog selects outer product family schedule specialization" {
        const lhs_dims = [_]i64{4};
        const rhs_dims = [_]i64{3};
        const output_dims = [_]i64{ 4, 3 };
        const query = Query{ .outer_product = .{
            .dtype = .f32,
            .lhs_indices = "m",
            .rhs_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 3, .y = 2 } },
        } };
        try std.testing.expect(select(query) == null);
        var selected = (try selectOwned(std.testing.allocator, query)) orelse
            return error.TestExpectedOuterProductScheduleSelection;
        defer selected.deinit();
        const specialization = selected.descriptor.metadata.specialization;

        try std.testing.expect(selected.specialization != null);
        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.outer_family_3x2_f32",
            selected.descriptor.metadata.target,
        );
        try std.testing.expectEqual(@as(u32, 3), specialization.launch.?.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[1]);
    }

    test "kernel library catalog selects outer product family for fresh extents" {
        const lhs_dims = [_]i64{5};
        const rhs_dims = [_]i64{6};
        const output_dims = [_]i64{ 5, 6 };
        var selected = (try selectOwned(std.testing.allocator, .{ .outer_product = .{
            .dtype = .f32,
            .lhs_indices = "m",
            .rhs_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } })) orelse return error.TestExpectedOuterProductFamilySelection;
        defer selected.deinit();
        const specialization = selected.descriptor.metadata.specialization;

        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.outer_family_6x5_f32",
            selected.descriptor.metadata.target,
        );
        try std.testing.expect(specialization.shape_family != null);
        try std.testing.expect(specialization.operationIs(.{ .linalg = .outer_product }));
        try std.testing.expectEqual(@as(usize, 0), specialization.reductions.len);
        try std.testing.expect(specialization.inputHasExtents(0, &.{5}));
        try std.testing.expect(specialization.inputHasExtents(1, &.{6}));
        try std.testing.expect(specialization.outputHasExtents(0, &.{ 5, 6 }));
        try std.testing.expectEqual(@as(u32, 6), specialization.launch.?.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 5), specialization.launch.?.threadgroup[1]);
    }

    test "kernel library catalog creates outer product family artifact from owned descriptor" {
        const lhs_dims = [_]i64{5};
        const rhs_dims = [_]i64{6};
        const output_dims = [_]i64{ 5, 6 };
        var selected = (try selectOwned(std.testing.allocator, .{ .outer_product = .{
            .dtype = .f32,
            .lhs_indices = "m",
            .rhs_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 4, .y = 2 } },
        } })) orelse return error.TestExpectedOuterProductFamilyScheduleSelection;
        defer selected.deinit();

        var state = gpu.recording.BackendState{
            .allocator = std.testing.allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        var artifact = try createOwnedKernelCallArtifact(
            std.testing.allocator,
            state.handle(),
            selected,
            .{ .limits = .testing },
        );
        defer artifact.deinit();
        const entry_value = artifact.entry();

        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.outer_family_4x2_f32",
            selected.descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.outer_family_4x2_f32",
            entry_value.target,
        );
        try std.testing.expectEqual(@as(u32, 5), entry_value.argument_count);
        try std.testing.expectEqual(@as(u32, 2), entry_value.runtime_scalar_argument_count);
        switch (entry_value.launch) {
            .derived => |launch| {
                try std.testing.expectEqual(@as(u32, 4), launch.threadgroup[0]);
                try std.testing.expectEqual(@as(u32, 2), launch.threadgroup[1]);
            },
            else => return error.TestExpectedDerivedLaunch,
        }
    }

    test "kernel library catalog selects transpose by canonical einsum roles" {
        const input_dims = [_]i64{ 8, 16 };
        const output_dims = [_]i64{ 16, 8 };
        const selected = select(.{ .layout = .{
            .dtype = .f32,
            .kind = .transpose,
            .input_indices = "ij",
            .output_indices = "ji",
            .input_dims = &input_dims,
            .output_dims = &output_dims,
        } }) orelse return error.TestExpectedTransposeSelection;

        try std.testing.expectEqualStrings(
            layout.Transpose8x16F32.target,
            selected.metadata.target,
        );
        try std.testing.expectEqualStrings(layout.Transpose8x16F32.name, selected.name);
    }
};

const fused_tests = struct {
    test "kernel library catalog selects activation by operation contract" {
        const gelu = select(.{ .activation = .{
            .dtype = .f32,
            .kind = .gelu,
            .extent = 8,
        } }) orelse return error.TestExpectedGeluSelection;
        const relu = select(.{ .activation = .{
            .dtype = .f32,
            .kind = .relu,
            .extent = 8,
        } }) orelse return error.TestExpectedReluSelection;
        const silu = select(.{ .activation = .{
            .dtype = .f32,
            .kind = .silu,
            .extent = 8,
        } }) orelse return error.TestExpectedSiluSelection;

        try std.testing.expectEqualStrings(elementwise.Gelu8F32.target, gelu.metadata.target);
        try std.testing.expectEqualStrings(elementwise.Gelu8F32.name, gelu.name);
        try std.testing.expectEqualStrings(elementwise.Relu8F32.target, relu.metadata.target);
        try std.testing.expectEqualStrings(elementwise.Relu8F32.name, relu.name);
        try std.testing.expectEqualStrings(elementwise.Silu8F32.target, silu.metadata.target);
        try std.testing.expectEqualStrings(elementwise.Silu8F32.name, silu.name);
    }

    test "kernel library catalog selects fused bias gelu by operation contract" {
        const selected = select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .bias_activation = .gelu },
            .extent = 8,
        } } }) orelse return error.TestExpectedBiasGeluSelection;

        try std.testing.expectEqualStrings(fused.BiasGelu8F32.target, selected.metadata.target);
        try std.testing.expectEqualStrings(fused.BiasGelu8F32.name, selected.name);
    }

    test "kernel library catalog selects fused bias relu and silu by operation contract" {
        const relu = select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .bias_activation = .relu },
            .extent = 8,
        } } }) orelse return error.TestExpectedBiasReluSelection;
        const silu = select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .bias_activation = .silu },
            .extent = 8,
        } } }) orelse return error.TestExpectedBiasSiluSelection;

        try std.testing.expectEqualStrings(fused.BiasRelu8F32.target, relu.metadata.target);
        try std.testing.expectEqualStrings(fused.BiasRelu8F32.name, relu.name);
        try std.testing.expectEqualStrings(fused.BiasSilu8F32.target, silu.metadata.target);
        try std.testing.expectEqualStrings(fused.BiasSilu8F32.name, silu.name);
    }

    test "kernel library catalog selects fused swiglu by operation contract" {
        const selected = select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .gated_activation = .silu },
            .extent = 8,
        } } }) orelse return error.TestExpectedSwiGluSelection;

        try std.testing.expectEqualStrings(fused.SwiGlu8F32.target, selected.metadata.target);
        try std.testing.expectEqualStrings(fused.SwiGlu8F32.name, selected.name);
    }

    test "kernel library catalog selects fused geglu by operation contract" {
        const selected = select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .gated_activation = .gelu },
            .extent = 8,
        } } }) orelse return error.TestExpectedGeGluSelection;

        try std.testing.expectEqualStrings(fused.GeGlu8F32.target, selected.metadata.target);
        try std.testing.expectEqualStrings(fused.GeGlu8F32.name, selected.name);
    }

    test "kernel library catalog selects fused reglu by operation contract" {
        const selected = select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .gated_activation = .relu },
            .extent = 8,
        } } }) orelse return error.TestExpectedReGluSelection;

        try std.testing.expectEqualStrings(fused.ReGlu8F32.target, selected.metadata.target);
        try std.testing.expectEqualStrings(fused.ReGlu8F32.name, selected.name);
    }

    test "kernel library catalog selects fused matrix product bias gelu by operation contract" {
        const lhs_dims = [_]i64{ 2, 4 };
        const rhs_dims = [_]i64{ 4, 3 };
        const bias_dims = [_]i64{3};
        const output_dims = [_]i64{ 2, 3 };
        const selected = select(.{ .fused = .{ .matrix_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .gelu },
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .bias_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
        } } }) orelse return error.TestExpectedMatrixProductBiasGeluSelection;

        try std.testing.expectEqualStrings(
            fused.MatrixProductBiasGelu2x3x4F32.target,
            selected.metadata.target,
        );
        try std.testing.expectEqualStrings(fused.MatrixProductBiasGelu2x3x4F32.name, selected.name);
    }

    test "kernel library catalog selects fused matrix product schedule specialization" {
        const lhs_dims = [_]i64{ 2, 4 };
        const rhs_dims = [_]i64{ 4, 3 };
        const bias_dims = [_]i64{3};
        const output_dims = [_]i64{ 2, 3 };
        const default_selected = select(.{ .fused = .{ .matrix_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .gelu },
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .bias_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
        } } }) orelse return error.TestExpectedMatrixProductBiasGeluSelection;
        const scheduled = select(.{ .fused = .{ .matrix_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .gelu },
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .bias_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 1, .y = 2 } },
        } } }) orelse return error.TestExpectedMatrixProductBiasGeluSelection;

        try std.testing.expectEqualStrings(
            fused.MatrixProductBiasGelu2x3x4F32.target,
            default_selected.metadata.target,
        );
        try std.testing.expectEqualStrings(
            fused.MatrixProductBiasGelu2x3x4ThreadBlocks1x2F32.target,
            scheduled.metadata.target,
        );
        try std.testing.expectEqual(
            @as(u32, 1),
            scheduled.metadata.specialization.launch.?.threadgroup[0],
        );
        try std.testing.expectEqual(
            @as(u32, 2),
            scheduled.metadata.specialization.launch.?.threadgroup[1],
        );
    }

    test "kernel library catalog selects fused matrix product bias relu and silu by operation contract" {
        const lhs_dims = [_]i64{ 2, 4 };
        const rhs_dims = [_]i64{ 4, 3 };
        const bias_dims = [_]i64{3};
        const output_dims = [_]i64{ 2, 3 };
        const relu = select(.{ .fused = .{ .matrix_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .relu },
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .bias_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
        } } }) orelse return error.TestExpectedMatrixProductBiasReluSelection;
        const silu = select(.{ .fused = .{ .matrix_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .silu },
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .bias_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
        } } }) orelse return error.TestExpectedMatrixProductBiasSiluSelection;

        try std.testing.expectEqualStrings(
            fused.MatrixProductBiasRelu2x3x4F32.target,
            relu.metadata.target,
        );
        try std.testing.expectEqualStrings(fused.MatrixProductBiasRelu2x3x4F32.name, relu.name);
        try std.testing.expectEqualStrings(
            fused.MatrixProductBiasSilu2x3x4F32.target,
            silu.metadata.target,
        );
        try std.testing.expectEqualStrings(fused.MatrixProductBiasSilu2x3x4F32.name, silu.name);
    }

    test "kernel library catalog selects fused matrix vector product bias gelu by operation contract" {
        const matrix_dims = [_]i64{ 4, 8 };
        const vector_dims = [_]i64{8};
        const bias_dims = [_]i64{4};
        const output_dims = [_]i64{4};
        const selected = select(.{ .fused = .{ .matrix_vector_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .gelu },
            .matrix_indices = "mk",
            .vector_indices = "k",
            .bias_indices = "m",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &vector_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
        } } }) orelse return error.TestExpectedMatrixVectorProductBiasGeluSelection;

        try std.testing.expectEqualStrings(
            fused.MatrixVectorProductBiasGelu4x8F32.target,
            selected.metadata.target,
        );
        try std.testing.expectEqualStrings(
            fused.MatrixVectorProductBiasGelu4x8F32.name,
            selected.name,
        );
    }

    test "kernel library catalog selects fused matrix vector product bias relu and silu by operation contract" {
        const matrix_dims = [_]i64{ 4, 8 };
        const vector_dims = [_]i64{8};
        const bias_dims = [_]i64{4};
        const output_dims = [_]i64{4};
        const relu = select(.{ .fused = .{ .matrix_vector_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .relu },
            .matrix_indices = "mk",
            .vector_indices = "k",
            .bias_indices = "m",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &vector_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
        } } }) orelse return error.TestExpectedMatrixVectorProductBiasReluSelection;
        const silu = select(.{ .fused = .{ .matrix_vector_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .silu },
            .matrix_indices = "mk",
            .vector_indices = "k",
            .bias_indices = "m",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &vector_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
        } } }) orelse return error.TestExpectedMatrixVectorProductBiasSiluSelection;

        try std.testing.expectEqualStrings(
            fused.MatrixVectorProductBiasRelu4x8F32.target,
            relu.metadata.target,
        );
        try std.testing.expectEqualStrings(fused.MatrixVectorProductBiasRelu4x8F32.name, relu.name);
        try std.testing.expectEqualStrings(
            fused.MatrixVectorProductBiasSilu4x8F32.target,
            silu.metadata.target,
        );
        try std.testing.expectEqualStrings(fused.MatrixVectorProductBiasSilu4x8F32.name, silu.name);
    }

    test "kernel library catalog selects fused row residual rmsnorm by operation contract" {
        const selected = select(.{ .fused = .{ .row_normalization = .{
            .dtype = .f32,
            .kind = .{ .residual = .{ .rmsnorm = .scale } },
            .rows = 2,
            .cols = 4,
        } } }) orelse return error.TestExpectedRowResidualRmsNormSelection;

        try std.testing.expectEqualStrings(
            normalization.RowResidualRmsNorm2x4F32.target,
            selected.metadata.target,
        );
        try std.testing.expectEqualStrings(
            normalization.RowResidualRmsNorm2x4F32.name,
            selected.name,
        );
    }
};

const reject_tests = struct {
    test "kernel library catalog rejects unavailable scalar reductions" {
        const input_dims = [_]i64{8};
        const wrong_dims = [_]i64{16};
        const output_dims = [_]i64{};
        const vector_output_dims = [_]i64{1};
        const sum_inputs = [_]ReductionOperand{.{ .indices = "i", .dims = &input_dims }};
        const dot_inputs = [_]ReductionOperand{
            .{ .indices = "i", .dims = &input_dims },
            .{ .indices = "i", .dims = &input_dims },
        };
        const mismatched_dot_inputs = [_]ReductionOperand{
            .{ .indices = "i", .dims = &input_dims },
            .{ .indices = "i", .dims = &wrong_dims },
        };
        const wrong_axis_dot_inputs = [_]ReductionOperand{
            .{ .indices = "i", .dims = &input_dims },
            .{ .indices = "j", .dims = &input_dims },
        };

        try std.testing.expect(select(.{ .reduction = .{
            .dtype = .i32,
            .kind = .sum,
            .inputs = &sum_inputs,
            .output_indices = "",
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .reduction = .{
            .dtype = .f32,
            .kind = .sum,
            .inputs = &sum_inputs,
            .output_indices = "",
            .output_dims = &vector_output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .reduction = .{
            .dtype = .f32,
            .kind = .sum,
            .inputs = &.{.{ .indices = "ij", .dims = &input_dims }},
            .output_indices = "",
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .reduction = .{
            .dtype = .f32,
            .kind = .dot_product,
            .inputs = &dot_inputs,
            .output_indices = "i",
            .output_dims = &input_dims,
        } }) == null);
        try std.testing.expect(select(.{ .reduction = .{
            .dtype = .f32,
            .kind = .dot_product,
            .inputs = &mismatched_dot_inputs,
            .output_indices = "",
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .reduction = .{
            .dtype = .f32,
            .kind = .dot_product,
            .inputs = &wrong_axis_dot_inputs,
            .output_indices = "",
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .reduction = .{
            .dtype = .f32,
            .kind = .dot_product,
            .inputs = &dot_inputs,
            .output_indices = "",
            .output_dims = &wrong_dims,
        } }) == null);
    }

    test "kernel library catalog rejects unavailable fused variants" {
        try std.testing.expect(select(.{ .fused = .{ .vector = .{
            .dtype = .i32,
            .kind = .{ .bias_activation = .gelu },
            .extent = 8,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .bias_activation = .gelu },
            .extent = 0,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .bias_activation = .gelu },
            .extent = 16,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .vector = .{
            .dtype = .i32,
            .kind = .{ .gated_activation = .gelu },
            .extent = 8,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .gated_activation = .gelu },
            .extent = 0,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .gated_activation = .gelu },
            .extent = 16,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .vector = .{
            .dtype = .i32,
            .kind = .{ .gated_activation = .relu },
            .extent = 8,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .gated_activation = .relu },
            .extent = 0,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .gated_activation = .relu },
            .extent = 16,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .vector = .{
            .dtype = .i32,
            .kind = .{ .gated_activation = .silu },
            .extent = 8,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .gated_activation = .silu },
            .extent = 0,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .vector = .{
            .dtype = .f32,
            .kind = .{ .gated_activation = .silu },
            .extent = 16,
        } } }) == null);
    }

    test "kernel library catalog rejects unavailable fused matrix product variants" {
        const lhs_dims = [_]i64{ 2, 4 };
        const rhs_dims = [_]i64{ 4, 3 };
        const bias_dims = [_]i64{3};
        const wrong_bias_dims = [_]i64{4};
        const unavailable_output_dims = [_]i64{ 3, 3 };
        const output_dims = [_]i64{ 2, 3 };

        try std.testing.expect(select(.{ .fused = .{ .matrix_product = .{
            .dtype = .i32,
            .epilogue = .{ .bias_activation = .gelu },
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .bias_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .matrix_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .gelu },
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .bias_indices = "m",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .matrix_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .gelu },
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .bias_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .bias_dims = &wrong_bias_dims,
            .output_dims = &output_dims,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .matrix_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .gelu },
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .bias_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .bias_dims = &bias_dims,
            .output_dims = &unavailable_output_dims,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .matrix_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .gelu },
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .bias_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 8, .y = 2 } },
        } } }) == null);
    }

    test "kernel library catalog rejects unavailable fused matrix vector product variants" {
        const matrix_dims = [_]i64{ 4, 8 };
        const vector_dims = [_]i64{8};
        const bias_dims = [_]i64{4};
        const wrong_bias_dims = [_]i64{5};
        const unavailable_matrix_dims = [_]i64{ 5, 8 };
        const unavailable_bias_dims = [_]i64{5};
        const unavailable_output_dims = [_]i64{5};
        const output_dims = [_]i64{4};

        try std.testing.expect(select(.{ .fused = .{ .matrix_vector_product = .{
            .dtype = .i32,
            .epilogue = .{ .bias_activation = .gelu },
            .matrix_indices = "mk",
            .vector_indices = "k",
            .bias_indices = "m",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &vector_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .matrix_vector_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .gelu },
            .matrix_indices = "mk",
            .vector_indices = "k",
            .bias_indices = "k",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &vector_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .matrix_vector_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .gelu },
            .matrix_indices = "mk",
            .vector_indices = "k",
            .bias_indices = "m",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &vector_dims,
            .bias_dims = &wrong_bias_dims,
            .output_dims = &output_dims,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .matrix_vector_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .gelu },
            .matrix_indices = "mk",
            .vector_indices = "k",
            .bias_indices = "m",
            .output_indices = "m",
            .matrix_dims = &unavailable_matrix_dims,
            .vector_dims = &vector_dims,
            .bias_dims = &unavailable_bias_dims,
            .output_dims = &unavailable_output_dims,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .matrix_vector_product = .{
            .dtype = .f32,
            .epilogue = .{ .bias_activation = .gelu },
            .matrix_indices = "mk",
            .vector_indices = "k",
            .bias_indices = "m",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &vector_dims,
            .bias_dims = &bias_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = 8 },
        } } }) == null);
    }

    test "kernel library catalog rejects unavailable fused row normalization variants" {
        try std.testing.expect(select(.{ .fused = .{ .row_normalization = .{
            .dtype = .i32,
            .kind = .{ .residual = .{ .rmsnorm = .scale } },
            .rows = 2,
            .cols = 4,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .row_normalization = .{
            .dtype = .f32,
            .kind = .{ .residual = .{ .rmsnorm = .none } },
            .rows = 2,
            .cols = 4,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .row_normalization = .{
            .dtype = .f32,
            .kind = .{ .residual = .softmax },
            .rows = 2,
            .cols = 4,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .row_normalization = .{
            .dtype = .f32,
            .kind = .{ .residual = .{ .rmsnorm = .scale } },
            .rows = 3,
            .cols = 4,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .row_normalization = .{
            .dtype = .f32,
            .kind = .{ .residual = .{ .rmsnorm = .scale } },
            .rows = 2,
            .cols = 5,
        } } }) == null);
        try std.testing.expect(select(.{ .fused = .{ .row_normalization = .{
            .dtype = .f32,
            .kind = .{ .residual = .{ .rmsnorm = .scale } },
            .rows = 2,
            .cols = 4,
            .schedule = .{ .thread_blocks = .{ .x = 8, .y = 2 } },
        } } }) == null);
    }

    test "kernel library catalog rejects unavailable activation variants" {
        try std.testing.expect(select(.{ .activation = .{
            .dtype = .i32,
            .kind = .gelu,
            .extent = 8,
        } }) == null);
        try std.testing.expect(select(.{ .activation = .{
            .dtype = .f32,
            .kind = .gelu,
            .extent = 0,
        } }) == null);
        try std.testing.expect(select(.{ .activation = .{
            .dtype = .f32,
            .kind = .gelu,
            .extent = 16,
        } }) == null);
        try std.testing.expect(select(.{ .activation = .{
            .dtype = .i32,
            .kind = .relu,
            .extent = 8,
        } }) == null);
        try std.testing.expect(select(.{ .activation = .{
            .dtype = .f32,
            .kind = .relu,
            .extent = 0,
        } }) == null);
        try std.testing.expect(select(.{ .activation = .{
            .dtype = .f32,
            .kind = .relu,
            .extent = 16,
        } }) == null);
        try std.testing.expect(select(.{ .activation = .{
            .dtype = .i32,
            .kind = .silu,
            .extent = 8,
        } }) == null);
        try std.testing.expect(select(.{ .activation = .{
            .dtype = .f32,
            .kind = .silu,
            .extent = 0,
        } }) == null);
        try std.testing.expect(select(.{ .activation = .{
            .dtype = .f32,
            .kind = .silu,
            .extent = 16,
        } }) == null);
    }

    test "kernel library catalog rejects unavailable transpose variants" {
        const input_dims = [_]i64{ 8, 16 };
        const output_dims = [_]i64{ 16, 8 };
        const wrong_output_dims = [_]i64{ 8, 16 };
        const unavailable_dims = [_]i64{ 16, 8 };
        const unavailable_output_dims = [_]i64{ 8, 16 };

        try std.testing.expect(select(.{ .layout = .{
            .dtype = .i32,
            .kind = .transpose,
            .input_indices = "ij",
            .output_indices = "ji",
            .input_dims = &input_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .layout = .{
            .dtype = .f32,
            .kind = .transpose,
            .input_indices = "ij",
            .output_indices = "ij",
            .input_dims = &input_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .layout = .{
            .dtype = .f32,
            .kind = .transpose,
            .input_indices = "ij",
            .output_indices = "ji",
            .input_dims = &input_dims,
            .output_dims = &wrong_output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .layout = .{
            .dtype = .f32,
            .kind = .transpose,
            .input_indices = "ij",
            .output_indices = "ji",
            .input_dims = &unavailable_dims,
            .output_dims = &unavailable_output_dims,
        } }) == null);
    }
};

const normalization_tests = struct {
    test "kernel library catalog selects row normalization by aggregate contract" {
        const softmax = select(.{ .row_normalization = .{
            .dtype = .f32,
            .kind = .softmax,
            .rows = 2,
            .cols = 4,
        } }) orelse return error.TestExpectedRowSoftmaxSelection;
        const log_softmax = select(.{ .row_normalization = .{
            .dtype = .f32,
            .kind = .log_softmax,
            .rows = 2,
            .cols = 4,
        } }) orelse return error.TestExpectedRowLogSoftmaxSelection;
        const rmsnorm = select(.{ .row_normalization = .{
            .dtype = .f32,
            .kind = .{ .rmsnorm = .scale },
            .rows = 2,
            .cols = 4,
        } }) orelse return error.TestExpectedRowRmsNormSelection;
        const layernorm = select(.{ .row_normalization = .{
            .dtype = .f32,
            .kind = .{ .layernorm = .none },
            .rows = 2,
            .cols = 4,
        } }) orelse return error.TestExpectedRowLayerNormSelection;
        const affine_layernorm = select(.{ .row_normalization = .{
            .dtype = .f32,
            .kind = .{ .layernorm = .scale_bias },
            .rows = 2,
            .cols = 4,
        } }) orelse return error.TestExpectedRowAffineLayerNormSelection;

        try std.testing.expectEqualStrings(
            normalization.RowSoftmax2x4F32.target,
            softmax.metadata.target,
        );
        try std.testing.expectEqualStrings(
            normalization.RowLogSoftmax2x4F32.target,
            log_softmax.metadata.target,
        );
        try std.testing.expectEqualStrings(
            normalization.RowRmsNorm2x4F32.target,
            rmsnorm.metadata.target,
        );
        try std.testing.expectEqualStrings(
            normalization.RowLayerNorm2x4F32.target,
            layernorm.metadata.target,
        );
        try std.testing.expectEqualStrings(
            normalization.RowAffineLayerNorm2x4F32.target,
            affine_layernorm.metadata.target,
        );
    }

    test "kernel library catalog selects row normalization schedule specialization" {
        const default_softmax = select(.{ .row_normalization = .{
            .dtype = .f32,
            .kind = .softmax,
            .rows = 2,
            .cols = 4,
        } }) orelse return error.TestExpectedRowSoftmaxSelection;
        const scheduled_softmax = select(.{ .row_normalization = .{
            .dtype = .f32,
            .kind = .softmax,
            .rows = 2,
            .cols = 4,
            .schedule = .{ .thread_blocks = .{ .x = 2, .y = 2 } },
        } }) orelse return error.TestExpectedRowSoftmaxScheduleSelection;

        try std.testing.expectEqualStrings(
            normalization.RowSoftmax2x4F32.target,
            default_softmax.metadata.target,
        );
        try std.testing.expectEqualStrings(
            normalization.RowSoftmax2x4ThreadBlocks2x2F32.target,
            scheduled_softmax.metadata.target,
        );
        try std.testing.expectEqualStrings(
            normalization.RowSoftmax2x4ThreadBlocks2x2F32.name,
            scheduled_softmax.name,
        );
        try std.testing.expectEqual(
            @as(u32, 2),
            scheduled_softmax.metadata.specialization.launch.?.threadgroup[0],
        );
        try std.testing.expectEqual(
            @as(u32, 2),
            scheduled_softmax.metadata.specialization.launch.?.threadgroup[1],
        );
    }

    test "kernel library catalog rejects unavailable row normalization variants" {
        try std.testing.expect(select(.{ .row_normalization = .{
            .dtype = .f32,
            .kind = .softmax,
            .rows = 3,
            .cols = 4,
        } }) == null);
        try std.testing.expect(select(.{ .row_normalization = .{
            .dtype = .f32,
            .kind = .log_softmax,
            .rows = 2,
            .cols = 5,
        } }) == null);
        try std.testing.expect(select(.{ .row_normalization = .{
            .dtype = .i32,
            .kind = .{ .rmsnorm = .scale },
            .rows = 2,
            .cols = 4,
        } }) == null);
        try std.testing.expect(select(.{ .row_normalization = .{
            .dtype = .f32,
            .kind = .{ .rmsnorm = .none },
            .rows = 2,
            .cols = 4,
        } }) == null);
        try std.testing.expect(select(.{ .row_normalization = .{
            .dtype = .f32,
            .kind = .{ .layernorm = .none },
            .rows = 2,
            .cols = 5,
        } }) == null);
        try std.testing.expect(select(.{ .row_normalization = .{
            .dtype = .f32,
            .kind = .{ .layernorm = .scale },
            .rows = 2,
            .cols = 4,
        } }) == null);
        try std.testing.expect(select(.{ .row_normalization = .{
            .dtype = .f32,
            .kind = .softmax,
            .rows = 2,
            .cols = 4,
            .schedule = .{ .thread_blocks = .{ .x = 8, .y = 2 } },
        } }) == null);
    }

    test "kernel library catalog rejects transposed matrix product layouts" {
        const lhs_dims = [_]i64{ 8, 4 };
        const rhs_dims = [_]i64{ 8, 16 };
        const output_dims = [_]i64{ 4, 16 };
        try std.testing.expect(select(.{ .matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "ki",
            .rhs_indices = "kj",
            .output_indices = "ij",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } }) == null);
    }

    test "kernel library catalog rejects unavailable attention variants" {
        const query_dims = [_]i64{ 2, 2, 2 };
        const key_dims = [_]i64{ 2, 3, 2 };
        const value_dims = [_]i64{ 2, 3, 2 };
        const output_dims = [_]i64{ 2, 2, 2 };
        const wrong_key_dims = [_]i64{ 2, 4, 2 };
        const unavailable_query_dims = [_]i64{ 3, 2, 2 };
        const unavailable_key_dims = [_]i64{ 3, 3, 2 };
        const unavailable_value_dims = [_]i64{ 3, 3, 2 };
        const unavailable_output_dims = [_]i64{ 3, 2, 2 };

        try std.testing.expect(select(.{ .attention = .{
            .dtype = .i32,
            .kind = .scaled_dot_product,
            .query_indices = "bqh",
            .key_indices = "bkh",
            .value_indices = "bkv",
            .output_indices = "bqv",
            .query_dims = &query_dims,
            .key_dims = &key_dims,
            .value_dims = &value_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .attention = .{
            .dtype = .f32,
            .kind = .scaled_dot_product,
            .query_indices = "bqh",
            .key_indices = "ckh",
            .value_indices = "bkv",
            .output_indices = "bqv",
            .query_dims = &query_dims,
            .key_dims = &key_dims,
            .value_dims = &value_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .attention = .{
            .dtype = .f32,
            .kind = .scaled_dot_product,
            .query_indices = "bqh",
            .key_indices = "bkh",
            .value_indices = "bsv",
            .output_indices = "bqv",
            .query_dims = &query_dims,
            .key_dims = &key_dims,
            .value_dims = &value_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .attention = .{
            .dtype = .f32,
            .kind = .scaled_dot_product,
            .query_indices = "bqh",
            .key_indices = "bkh",
            .value_indices = "bkv",
            .output_indices = "bqv",
            .query_dims = &query_dims,
            .key_dims = &wrong_key_dims,
            .value_dims = &value_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .attention = .{
            .dtype = .f32,
            .kind = .scaled_dot_product,
            .query_indices = "bqh",
            .key_indices = "bkh",
            .value_indices = "bkv",
            .output_indices = "bqv",
            .query_dims = &query_dims,
            .key_dims = &key_dims,
            .value_dims = &value_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 4, .y = 2, .z = 1 } },
        } }) == null);
        try std.testing.expect(select(.{ .attention = .{
            .dtype = .f32,
            .kind = .scaled_dot_product,
            .query_indices = "bqh",
            .key_indices = "bkh",
            .value_indices = "bkv",
            .output_indices = "bqv",
            .query_dims = &unavailable_query_dims,
            .key_dims = &unavailable_key_dims,
            .value_dims = &unavailable_value_dims,
            .output_dims = &unavailable_output_dims,
        } }) == null);
    }
};

const invalid_tests = struct {
    test "kernel library catalog rejects unavailable linalg schedules" {
        const lhs_dims = [_]i64{ 4, 8 };
        const rhs_dims = [_]i64{ 8, 16 };
        const matrix_output_dims = [_]i64{ 4, 16 };
        const batched_lhs_dims = [_]i64{ 2, 2, 4 };
        const batched_rhs_dims = [_]i64{ 2, 4, 3 };
        const batched_output_dims = [_]i64{ 2, 2, 3 };
        const vector_dims = [_]i64{8};
        const vector_output_dims = [_]i64{4};
        const outer_lhs_dims = [_]i64{4};
        const outer_rhs_dims = [_]i64{3};
        const outer_output_dims = [_]i64{ 4, 3 };

        try std.testing.expect(select(.{ .matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "ik",
            .rhs_indices = "kj",
            .output_indices = "ij",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &matrix_output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 16, .y = 8 } },
        } }) == null);

        try std.testing.expect(select(.{ .batched_matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "bmk",
            .rhs_indices = "bkn",
            .output_indices = "bmn",
            .lhs_dims = &batched_lhs_dims,
            .rhs_dims = &batched_rhs_dims,
            .output_dims = &batched_output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 4, .y = 2, .z = 2 } },
        } }) == null);

        try std.testing.expect(select(.{ .matrix_vector_product = .{
            .dtype = .f32,
            .matrix_indices = "mk",
            .vector_indices = "k",
            .output_indices = "m",
            .matrix_dims = &lhs_dims,
            .vector_dims = &vector_dims,
            .output_dims = &vector_output_dims,
            .schedule = .{ .thread_blocks = 8 },
        } }) == null);

        try std.testing.expect(select(.{ .outer_product = .{
            .dtype = .f32,
            .lhs_indices = "m",
            .rhs_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &outer_lhs_dims,
            .rhs_dims = &outer_rhs_dims,
            .output_dims = &outer_output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 4, .y = 2 } },
        } }) == null);
    }

    test "kernel library catalog rejects unavailable batched matrix product variants" {
        const lhs_dims = [_]i64{ 2, 2, 4 };
        const rhs_dims = [_]i64{ 2, 4, 3 };
        const output_dims = [_]i64{ 2, 2, 3 };
        const wrong_rhs_dims = [_]i64{ 3, 4, 3 };
        const unavailable_lhs_dims = [_]i64{ 3, 2, 4 };
        const unavailable_output_dims = [_]i64{ 3, 2, 3 };

        try std.testing.expect(select(.{ .batched_matrix_product = .{
            .dtype = .i32,
            .lhs_indices = "bmk",
            .rhs_indices = "bkn",
            .output_indices = "bmn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .batched_matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "mbk",
            .rhs_indices = "bkn",
            .output_indices = "bmn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .batched_matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "bmk",
            .rhs_indices = "ckn",
            .output_indices = "bmn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .batched_matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "bmk",
            .rhs_indices = "bkn",
            .output_indices = "bmn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &wrong_rhs_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .batched_matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "bmk",
            .rhs_indices = "bkn",
            .output_indices = "bmn",
            .lhs_dims = &unavailable_lhs_dims,
            .rhs_dims = &wrong_rhs_dims,
            .output_dims = &unavailable_output_dims,
        } }) == null);
    }

    test "kernel library catalog rejects unavailable matrix vector product variants" {
        const matrix_dims = [_]i64{ 4, 8 };
        const vector_dims = [_]i64{8};
        const output_dims = [_]i64{4};
        const wrong_vector_dims = [_]i64{7};
        const unavailable_matrix_dims = [_]i64{ 5, 8 };
        const unavailable_output_dims = [_]i64{5};

        try std.testing.expect(select(.{ .matrix_vector_product = .{
            .dtype = .i32,
            .matrix_indices = "mk",
            .vector_indices = "k",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &vector_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .matrix_vector_product = .{
            .dtype = .f32,
            .matrix_indices = "km",
            .vector_indices = "k",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &vector_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .matrix_vector_product = .{
            .dtype = .f32,
            .matrix_indices = "mk",
            .vector_indices = "n",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &vector_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .matrix_vector_product = .{
            .dtype = .f32,
            .matrix_indices = "mk",
            .vector_indices = "k",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &wrong_vector_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .matrix_vector_product = .{
            .dtype = .f32,
            .matrix_indices = "mk",
            .vector_indices = "k",
            .output_indices = "m",
            .matrix_dims = &unavailable_matrix_dims,
            .vector_dims = &vector_dims,
            .output_dims = &unavailable_output_dims,
        } }) == null);
    }

    test "kernel library catalog rejects unavailable outer product variants" {
        const lhs_dims = [_]i64{4};
        const rhs_dims = [_]i64{3};
        const output_dims = [_]i64{ 4, 3 };
        const wrong_rhs_dims = [_]i64{4};
        const unavailable_lhs_dims = [_]i64{5};
        const unavailable_output_dims = [_]i64{ 5, 3 };

        try std.testing.expect(select(.{ .outer_product = .{
            .dtype = .i32,
            .lhs_indices = "m",
            .rhs_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .outer_product = .{
            .dtype = .f32,
            .lhs_indices = "m",
            .rhs_indices = "m",
            .output_indices = "mm",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .outer_product = .{
            .dtype = .f32,
            .lhs_indices = "m",
            .rhs_indices = "n",
            .output_indices = "nm",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .outer_product = .{
            .dtype = .f32,
            .lhs_indices = "m",
            .rhs_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &wrong_rhs_dims,
            .output_dims = &output_dims,
        } }) == null);
        try std.testing.expect(select(.{ .outer_product = .{
            .dtype = .f32,
            .lhs_indices = "m",
            .rhs_indices = "n",
            .output_indices = "mn",
            .lhs_dims = &unavailable_lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &unavailable_output_dims,
        } }) == null);
    }
};

const family_tests = struct {
    test "kernel library catalog creates registry-ready artifact by target" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };

        var call_artifact = try createKernelCallArtifact(allocator, state.handle(), .{
            .target = linalg.MatrixProduct4x16x8F32.target,
            .options = .{ .limits = linalg.MatrixProduct4x16x8F32.Limits.testing },
        });
        defer call_artifact.deinit();

        const artifact = call_artifact.registry().find(
            linalg.MatrixProduct4x16x8F32.target,
            linalg.MatrixProduct4x16x8F32.version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };
        try std.testing.expectEqualStrings(linalg.MatrixProduct4x16x8F32.name, artifact.entry_name);
    }

    test "kernel library catalog selects stencil window descriptors" {
        const static_descriptor = select(.{ .stencil = .{
            .dtype = .f32,
            .kind = .window,
            .rows = 2,
            .cols = 3,
            .radius = 1,
        } }) orelse return error.TestExpectedCatalogDescriptor;
        try std.testing.expectEqualStrings(
            stencil.Window2x3R1F32.target,
            static_descriptor.metadata.target,
        );

        var owned = (try selectOwned(std.testing.allocator, .{ .stencil = .{
            .dtype = .f32,
            .kind = .window,
            .rows = 17,
            .cols = 17,
            .radius = 1,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer owned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.stencil.window_family_r1_17x9_f32",
            owned.descriptor.metadata.target,
        );
        try std.testing.expect(owned.descriptor.metadata.specialization.shape_family != null);

        var scheduled = (try selectOwned(std.testing.allocator, .{ .stencil = .{
            .dtype = .f32,
            .kind = .window,
            .rows = 17,
            .cols = 17,
            .radius = 1,
            .schedule = .{ .thread_blocks = .{ .x = 4, .y = 2 } },
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer scheduled.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.stencil.window_family_r1_4x2_f32",
            scheduled.descriptor.metadata.target,
        );

        try std.testing.expectEqual(
            @as(?Descriptor, null),
            select(.{
                .stencil = .{ .dtype = .f32, .kind = .window, .rows = 0, .cols = 3, .radius = 1 },
            }),
        );
        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{ .stencil = .{
                .dtype = .f32,
                .kind = .window,
                .rows = 4,
                .cols = 4,
                .radius = stencil.window_radius_max + 1,
            } }),
        );
    }

    test "kernel library catalog selects owned stencil window family candidates" {
        var candidates = try selectOwnedStencilWindowCandidates(std.testing.allocator, .{
            .dtype = .f32,
            .kind = .window,
            .rows = 17,
            .cols = 17,
            .radius = 1,
        });
        defer candidates.deinit();

        try std.testing.expect(candidates.count > 2);
        try std.testing.expectEqualStrings(
            "accy.kernel.stencil.window_family_r1_17x9_f32",
            candidates.items[0].descriptor.metadata.target,
        );
        for (candidates.slice(), 0..) |candidate, index| {
            try std.testing.expect(candidate.specialization != null);
            try std.testing.expect(
                candidate.descriptor.metadata.specialization.shape_family != null,
            );
            try std.testing.expect(stencilWindowDescriptorMatches(candidate.descriptor, .{
                .dtype = .f32,
                .kind = .window,
                .rows = 17,
                .cols = 17,
                .radius = 1,
            }));
            for (candidates.slice()[0..index]) |previous| {
                try std.testing.expect(!std.mem.eql(
                    u8,
                    previous.descriptor.metadata.target,
                    candidate.descriptor.metadata.target,
                ));
            }
        }
    }

    test "kernel library catalog selects image descriptors" {
        try std.testing.expectEqual(
            @as(?Descriptor, null),
            select(.{ .image = .{
                .dtype = .u32,
                .kind = .{ .blur_pass = .{ .radius = 2, .axis = .horizontal } },
                .width = 24,
                .height = 10,
            } }),
        );

        var blur = (try selectOwned(std.testing.allocator, .{ .image = .{
            .dtype = .u32,
            .kind = .{ .blur_pass = .{ .radius = 2, .axis = .horizontal } },
            .width = 24,
            .height = 10,
        } })) orelse return error.TestExpectedImageDescriptor;
        defer blur.deinit();
        try std.testing.expectEqualStrings(
            "image_blur_pass_family_r2h_24x10_rgba8",
            blur.descriptor.metadata.target,
        );
        try std.testing.expectEqual(entry.Category.image, blur.descriptor.metadata.category);
        try std.testing.expect(
            blur.descriptor.metadata.specialization.operationIs(.{ .image = .blur_pass }),
        );
        try std.testing.expect(blur.descriptor.metadata.specialization.shape_family != null);
        try std.testing.expect(
            blur.descriptor.metadata.specialization.staticParameterMatches("radius", 2),
        );
        try std.testing.expect(blur.descriptor.metadata.specialization.staticParameterMatches(
            "axis",
            image.blurPassAxisParameter(.horizontal),
        ));

        var scheduled_blur = (try selectOwned(std.testing.allocator, .{ .image = .{
            .dtype = .u32,
            .kind = .{ .blur_pass = .{ .radius = 2, .axis = .horizontal } },
            .width = 24,
            .height = 10,
            .schedule = .{ .thread_blocks = .{ .x = 8, .y = 4 } },
        } })) orelse return error.TestExpectedImageDescriptor;
        defer scheduled_blur.deinit();
        try std.testing.expectEqualStrings(
            "image_blur_pass_family_r2h_8x4_rgba8",
            scheduled_blur.descriptor.metadata.target,
        );

        var resize = (try selectOwned(std.testing.allocator, .{ .image = .{
            .dtype = .u32,
            .kind = .{ .resize_bilinear = .{ .src_width = 20, .src_height = 12 } },
            .width = 11,
            .height = 7,
        } })) orelse return error.TestExpectedImageDescriptor;
        defer resize.deinit();
        try std.testing.expectEqualStrings(
            "image_resize_bilinear_family_11x7_rgba8",
            resize.descriptor.metadata.target,
        );
        try std.testing.expectEqual(entry.Category.image, resize.descriptor.metadata.category);
        try std.testing.expect(
            resize.descriptor.metadata.specialization.operationIs(.{ .image = .resize_bilinear }),
        );
        try std.testing.expect(resize.descriptor.metadata.specialization.shape_family != null);

        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{ .image = .{
                .dtype = .f32,
                .kind = .{ .blur_pass = .{ .radius = 2, .axis = .horizontal } },
                .width = 24,
                .height = 10,
            } }),
        );
        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{ .image = .{
                .dtype = .u32,
                .kind = .{ .blur_pass = .{ .radius = 0, .axis = .horizontal } },
                .width = 24,
                .height = 10,
            } }),
        );
        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{ .image = .{
                .dtype = .u32,
                .kind = .{ .blur_pass = .{ .radius = 2, .axis = .horizontal } },
                .width = 0,
                .height = 10,
            } }),
        );
        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{ .image = .{
                .dtype = .u32,
                .kind = .{ .resize_bilinear = .{ .src_width = 20, .src_height = 0 } },
                .width = 11,
                .height = 7,
            } }),
        );
    }

    test "kernel library catalog selects owned image family candidates" {
        var candidates = try selectOwnedImageCandidates(std.testing.allocator, .{
            .dtype = .u32,
            .kind = .{ .blur_pass = .{ .radius = 2, .axis = .horizontal } },
            .width = 24,
            .height = 10,
        });
        defer candidates.deinit();

        try std.testing.expect(candidates.count > 1);
        try std.testing.expectEqualStrings(
            "image_blur_pass_family_r2h_24x10_rgba8",
            candidates.items[0].descriptor.metadata.target,
        );
        for (candidates.slice(), 0..) |candidate, index| {
            try std.testing.expect(candidate.specialization != null);
            try std.testing.expectEqual(
                entry.Category.image,
                candidate.descriptor.metadata.category,
            );
            try std.testing.expect(
                candidate.descriptor.metadata.specialization.shape_family != null,
            );
            try std.testing.expect(
                candidate.descriptor.metadata.specialization.operationIs(.{ .image = .blur_pass }),
            );
            for (candidates.slice()[0..index]) |previous| {
                try std.testing.expect(!std.mem.eql(
                    u8,
                    previous.descriptor.metadata.target,
                    candidate.descriptor.metadata.target,
                ));
            }
        }
    }

    test "kernel library catalog builds stencil window scheduled artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        var candidates = try selectOwnedStencilWindowCandidates(allocator, .{
            .dtype = .f32,
            .kind = .window,
            .rows = 17,
            .cols = 17,
            .radius = 1,
            .schedule = .{ .thread_blocks = .{ .x = 17, .y = 9 } },
        });
        defer candidates.deinit();

        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            candidates.slice(),
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        const selected = registry.find(
            "accy.kernel.stencil.window_family_r1_17x9_f32",
            stencil.window_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };
        const launch = switch (selected.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        const profile = selected.shape_profile orelse return error.TestExpectedShapeProfile;

        try std.testing.expectEqual(candidates.count, registry.entries.len);
        try std.testing.expectEqual(@as(u32, 5), selected.argument_count);
        try std.testing.expectEqual(@as(u32, 2), selected.runtime_scalar_argument_count);
        try std.testing.expectEqual(@as(u32, 17), launch.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 9), launch.threadgroup[1]);
        try std.testing.expectEqual(@as(usize, 2), profile.dimensions.len);
        try std.testing.expect(selected.required_dtypes.contains(.f32));
        try std.testing.expect(selected.required_dtypes.contains(.i32));
    }

    test "kernel library catalog selects gather descriptors" {
        const static_descriptor = select(.{ .gather = .{
            .dtype = .f32,
            .axis_size = 8,
            .gathered = 8,
        } }) orelse return error.TestExpectedCatalogDescriptor;
        try std.testing.expectEqualStrings(
            indexing.Gather8F32.target,
            static_descriptor.metadata.target,
        );

        var owned = (try selectOwned(std.testing.allocator, .{ .gather = .{
            .dtype = .f32,
            .outer = 2,
            .axis_size = 1024,
            .gathered = 500,
            .inner = 1,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer owned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.indexing.gather_family_256_f32",
            owned.descriptor.metadata.target,
        );
        try std.testing.expect(owned.descriptor.metadata.specialization.shape_family != null);

        var scheduled = (try selectOwned(std.testing.allocator, .{ .gather = .{
            .dtype = .f32,
            .outer = 2,
            .axis_size = 1024,
            .gathered = 500,
            .inner = 1,
            .schedule = .{ .thread_blocks = 64 },
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer scheduled.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.indexing.gather_family_64_f32",
            scheduled.descriptor.metadata.target,
        );

        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{
                .gather = .{ .dtype = .f32, .axis_size = 0, .gathered = 4 },
            }),
        );
    }

    test "kernel library catalog builds gather scheduled artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        var candidates = try selectOwnedGatherCandidates(allocator, .{
            .dtype = .f32,
            .outer = 2,
            .axis_size = 1024,
            .gathered = 500,
            .inner = 1,
            .schedule = .{ .thread_blocks = 256 },
        });
        defer candidates.deinit();

        try std.testing.expectEqual(@as(usize, 1), candidates.count);

        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            candidates.slice(),
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        const selected = registry.find(
            "accy.kernel.indexing.gather_family_256_f32",
            indexing.gather_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };

        try std.testing.expectEqual(candidates.count, registry.entries.len);
        try std.testing.expectEqual(@as(u32, 8), selected.argument_count);
        try std.testing.expectEqual(@as(u32, 5), selected.runtime_scalar_argument_count);
        try std.testing.expect(selected.required_dtypes.contains(.i32));
        const launch = switch (selected.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        try std.testing.expectEqual(@as(u32, 256), launch.threadgroup[0]);
    }
};

const random_tests = struct {
    test "kernel library catalog builds random scheduled artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        var candidates = try selectOwnedRandomCandidates(allocator, .{
            .dtype = .f32,
            .algorithm = .philox,
            .count = 1 << 20,
            .schedule = .{ .thread_blocks = 256 },
        });
        defer candidates.deinit();

        try std.testing.expectEqual(@as(usize, 1), candidates.count);

        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            candidates.slice(),
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        const selected = registry.find(
            "accy.kernel.random.philox_family_10r_256_f32",
            random.philox_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };

        try std.testing.expectEqual(candidates.count, registry.entries.len);
        try std.testing.expectEqual(@as(u32, 4), selected.argument_count);
        try std.testing.expectEqual(@as(u32, 3), selected.runtime_scalar_argument_count);
        const launch = switch (selected.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        try std.testing.expectEqual(@as(u32, 256), launch.threadgroup[0]);
    }

    test "kernel library catalog selects random descriptors across rounds" {
        const static_descriptor = select(.{ .random = .{
            .dtype = .f32,
            .algorithm = .philox,
            .count = 8,
            .schedule = .{ .thread_blocks = 2 },
        } }) orelse return error.TestExpectedCatalogDescriptor;
        try std.testing.expectEqualStrings(
            random.Philox8F32.target,
            static_descriptor.metadata.target,
        );

        var default_owned = (try selectOwned(std.testing.allocator, .{ .random = .{
            .dtype = .f32,
            .algorithm = .threefry,
            .count = 4096,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer default_owned.deinit();
        try std.testing.expect(std.mem.indexOf(
            u8,
            default_owned.descriptor.metadata.target,
            "threefry_family_20r_",
        ) != null);

        var reduced_owned = (try selectOwned(std.testing.allocator, .{ .random = .{
            .dtype = .i32,
            .algorithm = .philox,
            .count = 4096,
            .rounds = 7,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer reduced_owned.deinit();
        try std.testing.expect(std.mem.indexOf(
            u8,
            reduced_owned.descriptor.metadata.target,
            "philox_family_7r_",
        ) != null);

        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{ .random = .{ .dtype = .f32, .count = 0 } }),
        );
        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{ .random = .{ .dtype = .f16, .count = 64 } }),
        );
        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{
                .random = .{ .dtype = .f32, .count = 64, .rounds = 99 },
            }),
        );
    }

    test "kernel library catalog builds filter scheduled artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        var candidates = try selectOwnedFilterCandidates(allocator, .{
            .dtype = .f32,
            .extent = 1 << 20,
            .schedule = .{ .thread_blocks = 256 },
        });
        defer candidates.deinit();

        try std.testing.expectEqual(@as(usize, 1), candidates.count);

        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            candidates.slice(),
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        const selected = registry.find(
            "accy.kernel.compaction.filter_family_nonzero_256_f32",
            compaction.filter_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };

        try std.testing.expectEqual(candidates.count, registry.entries.len);
        try std.testing.expectEqual(@as(u32, 3), selected.argument_count);
        try std.testing.expectEqual(@as(u32, 1), selected.runtime_scalar_argument_count);
    }

    test "kernel library catalog builds greater filter scheduled artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        var candidates = try selectOwnedFilterCandidates(allocator, .{
            .dtype = .f32,
            .predicate = .greater_than,
            .extent = 1 << 20,
            .schedule = .{ .thread_blocks = 256 },
        });
        defer candidates.deinit();

        try std.testing.expectEqual(@as(usize, 1), candidates.count);
        for (candidates.slice()) |candidate| {
            const instance = compaction.filterInstanceFromSpecialization(
                candidate.specialization.?.value,
            ) orelse return error.TestExpectedFilterInstance;
            try std.testing.expectEqual(entry.CompactionPredicate.greater_than, instance.predicate);
        }

        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            candidates.slice(),
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        const selected = registry.find(
            "accy.kernel.compaction.filter_family_greater_256_f32",
            compaction.filter_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };

        try std.testing.expectEqual(@as(u32, 4), selected.argument_count);
        try std.testing.expectEqual(@as(u32, 2), selected.runtime_scalar_argument_count);
    }
};

const segment_tests = struct {
    test "kernel library catalog selects segment sum descriptors" {
        const static_descriptor = select(.{ .segmented = .{
            .dtype = .f32,
            .kind = .segment_sum,
            .segments = 4,
            .total = 16,
        } }) orelse return error.TestExpectedCatalogDescriptor;
        try std.testing.expectEqualStrings(
            segmented.SegmentSum4F32.target,
            static_descriptor.metadata.target,
        );

        var owned = (try selectOwned(std.testing.allocator, .{ .segmented = .{
            .dtype = .f32,
            .kind = .segment_sum,
            .segments = 1000,
            .total = 65536,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer owned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.segmented.segment_sum_family_thread_256_f32",
            owned.descriptor.metadata.target,
        );
        try std.testing.expect(owned.descriptor.metadata.specialization.shape_family != null);

        var scheduled = (try selectOwned(std.testing.allocator, .{ .segmented = .{
            .dtype = .f32,
            .kind = .segment_sum,
            .segments = 1000,
            .total = 65536,
            .schedule = .{ .thread_blocks = 64 },
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer scheduled.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.segmented.segment_sum_family_thread_64_f32",
            scheduled.descriptor.metadata.target,
        );

        var warp_scheduled = (try selectOwned(std.testing.allocator, .{ .segmented = .{
            .dtype = .f32,
            .kind = .segment_sum,
            .segments = 1000,
            .total = 65536,
            .schedule = .{ .warp_blocks = 64 },
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer warp_scheduled.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.segmented.segment_sum_family_warp_64_f32",
            warp_scheduled.descriptor.metadata.target,
        );

        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{ .segmented = .{
                .dtype = .f32,
                .kind = .segment_sum,
                .segments = 0,
                .total = 16,
            } }),
        );

        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{ .segmented = .{
                .dtype = .f32,
                .kind = .segment_sum,
                .segments = 8,
                .total = 64,
                .schedule = .{ .thread_blocks = 64 },
            } }),
        );

        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{ .segmented = .{
                .dtype = .f32,
                .kind = .segment_sum,
                .segments = 8,
                .total = 64,
                .schedule = .{ .warp_blocks = 48 },
            } }),
        );
    }

    test "kernel library catalog builds segment sum scheduled artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        var registry_descriptors: [2]OwnedDescriptor = undefined;
        var descriptor_count: usize = 0;
        defer for (registry_descriptors[0..descriptor_count]) |*descriptor| descriptor.deinit();
        registry_descriptors[0] = (try selectOwned(allocator, .{ .segmented = .{
            .dtype = .f32,
            .kind = .segment_sum,
            .segments = 1000,
            .total = 65536,
            .schedule = .{ .thread_blocks = 256 },
        } })) orelse return error.TestExpectedCatalogDescriptor;
        descriptor_count = 1;
        registry_descriptors[1] = (try selectOwned(allocator, .{ .segmented = .{
            .dtype = .f32,
            .kind = .segment_sum,
            .segments = 1000,
            .total = 65536,
            .schedule = .{ .warp_blocks = 256 },
        } })) orelse return error.TestExpectedCatalogDescriptor;
        descriptor_count = 2;

        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            registry_descriptors[0..],
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        const selected = registry.find(
            "accy.kernel.segmented.segment_sum_family_thread_256_f32",
            segmented.segment_sum_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };

        try std.testing.expectEqual(@as(usize, 2), registry.entries.len);
        try std.testing.expectEqual(@as(u32, 5), selected.argument_count);
        try std.testing.expectEqual(@as(u32, 2), selected.runtime_scalar_argument_count);
        try std.testing.expect(selected.required_dtypes.contains(.i32));
        const launch = switch (selected.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        try std.testing.expectEqual(@as(u32, 256), launch.threadgroup[0]);

        const warp_selected = registry.find(
            "accy.kernel.segmented.segment_sum_family_warp_256_f32",
            segmented.segment_sum_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };
        const warp_launch = switch (warp_selected.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        try std.testing.expectEqual(@as(u32, 256), warp_launch.threadgroup[0]);
        switch (warp_launch.grid[0]) {
            .runtime_u32_ceil_div => |term| try std.testing.expectEqual(@as(u32, 8), term.divisor),
            else => return error.TestExpectedDerivedLaunch,
        }
    }

    test "kernel library catalog selects scatter descriptors" {
        const static_descriptor = select(.{ .scatter = .{
            .dtype = .f32,
            .axis_size = 8,
            .updates = 4,
        } }) orelse return error.TestExpectedCatalogDescriptor;
        try std.testing.expectEqualStrings(
            indexing.Scatter8F32.target,
            static_descriptor.metadata.target,
        );

        var owned = (try selectOwned(std.testing.allocator, .{ .scatter = .{
            .dtype = .f32,
            .outer = 2,
            .axis_size = 1024,
            .updates = 500,
            .inner = 1,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer owned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.indexing.scatter_family_256_f32",
            owned.descriptor.metadata.target,
        );

        var scheduled = (try selectOwned(std.testing.allocator, .{ .scatter = .{
            .dtype = .f32,
            .outer = 2,
            .axis_size = 1024,
            .updates = 500,
            .inner = 1,
            .schedule = .{ .thread_blocks = 64 },
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer scheduled.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.indexing.scatter_family_64_f32",
            scheduled.descriptor.metadata.target,
        );

        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{
                .scatter = .{ .dtype = .f32, .axis_size = 0, .updates = 4 },
            }),
        );
    }

    test "kernel library catalog builds scatter scheduled artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        var candidates = try selectOwnedScatterCandidates(allocator, .{
            .dtype = .f32,
            .outer = 2,
            .axis_size = 1024,
            .updates = 500,
            .inner = 1,
            .schedule = .{ .thread_blocks = 256 },
        });
        defer candidates.deinit();

        try std.testing.expectEqual(@as(usize, 1), candidates.count);
        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            candidates.slice(),
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        const selected = registry.find(
            "accy.kernel.indexing.scatter_family_256_f32",
            indexing.scatter_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };

        try std.testing.expectEqual(candidates.count, registry.entries.len);
        try std.testing.expectEqual(@as(u32, 9), selected.argument_count);
        try std.testing.expectEqual(@as(u32, 5), selected.runtime_scalar_argument_count);
        const launch = switch (selected.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        try std.testing.expectEqual(@as(u32, 256), launch.threadgroup[0]);
    }

    test "kernel library catalog builds scatter add scheduled artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        var candidates = try selectOwnedScatterAddCandidates(allocator, .{
            .dtype = .i32,
            .axis_size = 1024,
            .updates = 4096,
            .schedule = .{ .thread_blocks = 128 },
        });
        defer candidates.deinit();

        try std.testing.expectEqual(@as(usize, 1), candidates.count);
        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            candidates.slice(),
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        const selected = registry.find(
            "accy.kernel.indexing.scatter_add_family_128_i32",
            indexing.scatter_add_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };
        const profile = selected.shape_profile orelse return error.TestExpectedShapeProfile;

        try std.testing.expectEqual(candidates.count, registry.entries.len);
        try std.testing.expectEqual(@as(u32, 9), selected.argument_count);
        try std.testing.expectEqual(@as(u32, 5), selected.runtime_scalar_argument_count);
        try std.testing.expectEqualStrings("scatter_add", profile.name);
        try std.testing.expect(selected.required_dtypes.contains(.i32));
        const launch = switch (selected.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        try std.testing.expectEqual(@as(u32, 128), launch.threadgroup[0]);
    }
};

const scan_tests = struct {
    test "kernel library catalog selects prefix sum descriptors" {
        const static_descriptor = select(.{ .scan = .{
            .dtype = .f32,
            .kind = .prefix_sum,
            .extent = 8,
            .schedule = .{ .thread_blocks = 32 },
        } }) orelse return error.TestExpectedCatalogDescriptor;
        try std.testing.expectEqualStrings(
            scan_mod.PrefixSum8F32.target,
            static_descriptor.metadata.target,
        );

        var owned = (try selectOwned(std.testing.allocator, .{ .scan = .{
            .dtype = .f32,
            .kind = .prefix_sum,
            .extent = 100,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer owned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.scan.prefix_sum_family_128_f32",
            owned.descriptor.metadata.target,
        );

        var scheduled = (try selectOwned(std.testing.allocator, .{ .scan = .{
            .dtype = .f32,
            .kind = .prefix_sum,
            .extent = 100,
            .schedule = .{ .thread_blocks = 256 },
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer scheduled.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.scan.prefix_sum_family_256_f32",
            scheduled.descriptor.metadata.target,
        );

        var u32_owned = (try selectOwned(std.testing.allocator, .{ .scan = .{
            .dtype = .u32,
            .kind = .prefix_sum,
            .extent = 100,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer u32_owned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.scan.prefix_sum_family_128_u32",
            u32_owned.descriptor.metadata.target,
        );

        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{ .scan = .{
                .dtype = .f32,
                .kind = .prefix_sum,
                .extent = 100,
                .schedule = .{ .thread_blocks = 64 },
            } }),
        );
    }

    test "kernel library catalog selects device scan pipeline descriptors past one block" {
        var owned = (try selectOwned(std.testing.allocator, .{ .scan = .{
            .dtype = .f32,
            .kind = .prefix_sum,
            .extent = 2000,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer owned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.scan.device_prefix_sum_family_32_f32",
            owned.descriptor.metadata.target,
        );
        try std.testing.expectEqual(
            scan_mod.device_scan_family_version,
            owned.descriptor.metadata.version,
        );

        var capped = (try selectOwned(std.testing.allocator, .{ .scan = .{
            .dtype = .f32,
            .kind = .prefix_sum,
            .extent = 1 << 20,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer capped.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.scan.device_prefix_sum_family_1024_f32",
            capped.descriptor.metadata.target,
        );

        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(std.testing.allocator, .{ .scan = .{
                .dtype = .f32,
                .kind = .prefix_sum,
                .extent = (1 << 20) + 1,
            } }),
        );

        var exclusive = (try selectOwned(std.testing.allocator, .{ .scan = .{
            .dtype = .f32,
            .kind = .prefix_sum_exclusive,
            .extent = 2000,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer exclusive.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.scan.device_prefix_sum_exclusive_family_32_f32",
            exclusive.descriptor.metadata.target,
        );

        var scheduled = (try selectOwned(std.testing.allocator, .{ .scan = .{
            .dtype = .f32,
            .kind = .prefix_sum,
            .extent = 2000,
            .schedule = .{ .thread_blocks = 128 },
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer scheduled.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.scan.device_prefix_sum_family_128_f32",
            scheduled.descriptor.metadata.target,
        );

        var f16_owned = (try selectOwned(std.testing.allocator, .{ .scan = .{
            .dtype = .f16,
            .kind = .prefix_sum,
            .extent = 2000,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer f16_owned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.scan.device_prefix_sum_family_32_f16",
            f16_owned.descriptor.metadata.target,
        );

        var u32_owned = (try selectOwned(std.testing.allocator, .{ .scan = .{
            .dtype = .u32,
            .kind = .prefix_sum,
            .extent = 2000,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer u32_owned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.scan.device_prefix_sum_family_32_u32",
            u32_owned.descriptor.metadata.target,
        );
    }

    test "kernel library catalog device scan pipeline descriptor declines artifact creation" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        var owned = (try selectOwned(allocator, .{ .scan = .{
            .dtype = .f32,
            .kind = .prefix_sum,
            .extent = 2000,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer owned.deinit();
        try std.testing.expectError(
            error.UnknownKernelLibraryEntry,
            createOwnedKernelCallArtifact(
                allocator,
                state.handle(),
                owned,
                .{ .limits = .testing },
            ),
        );
    }

    test "kernel library catalog selects exclusive prefix sum descriptors" {
        var owned = (try selectOwned(std.testing.allocator, .{ .scan = .{
            .dtype = .f32,
            .kind = .prefix_sum_exclusive,
            .extent = 100,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer owned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.scan.prefix_sum_exclusive_family_128_f32",
            owned.descriptor.metadata.target,
        );
    }

    test "kernel library catalog builds prefix sum scheduled artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        var candidates = try selectOwnedPrefixSumCandidates(allocator, .{
            .dtype = .f32,
            .kind = .prefix_sum,
            .extent = 100,
            .schedule = .{ .thread_blocks = 128 },
        });
        defer candidates.deinit();

        try std.testing.expectEqual(@as(usize, 1), candidates.count);
        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            candidates.slice(),
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        const selected = registry.find(
            "accy.kernel.scan.prefix_sum_family_128_f32",
            scan_mod.prefix_sum_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };

        try std.testing.expectEqual(candidates.count, registry.entries.len);
        try std.testing.expectEqual(@as(u32, 3), selected.argument_count);
        try std.testing.expectEqual(@as(u32, 1), selected.runtime_scalar_argument_count);
    }

    test "kernel library catalog dispatches selected device scan pipelines" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };

        var owned = (try selectOwned(allocator, .{ .scan = .{
            .dtype = .f32,
            .kind = .prefix_sum,
            .extent = 2000,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer owned.deinit();

        var package = (try createOwnedKernelCallPipelinePackage(
            allocator,
            state.handle(),
            owned,
            .{ .limits = .testing },
        )) orelse {
            return error.TestExpectedPipelinePackage;
        };
        defer package.deinit();

        try std.testing.expectEqual(@as(usize, 3), package.artifacts.len);
        try std.testing.expectEqualStrings(
            "accy.kernel.scan.device_prefix_sum_family_32_f32",
            package.pipeline.value.target,
        );
        try std.testing.expect(package.registry().find(
            "accy.kernel.scan.device_prefix_sum_block_scan_family_32_f32",
            scan_mod.device_scan_family_version,
            .cuda_ptx,
        ) != null);

        const encoded = try accy_artifact.wire.encode(
            allocator,
            package.entries,
            &.{package.pipeline.value},
        );
        defer allocator.free(encoded);
        var decoded = try accy_artifact.wire.decode(allocator, encoded);
        defer decoded.deinit();
        const found = accy_artifact.findPipeline(
            decoded.pipelines,
            package.pipeline.value.target,
            scan_mod.device_scan_family_version,
        ) orelse return error.TestExpectedPipeline;
        try found.validate(decoded.registry(), .cuda_ptx);

        var f16_owned = (try selectOwned(allocator, .{ .scan = .{
            .dtype = .f16,
            .kind = .prefix_sum,
            .extent = 2000,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer f16_owned.deinit();

        var f16_package = (try createOwnedKernelCallPipelinePackage(
            allocator,
            state.handle(),
            f16_owned,
            .{ .limits = .testing },
        )) orelse {
            return error.TestExpectedPipelinePackage;
        };
        defer f16_package.deinit();

        try std.testing.expectEqualStrings(
            "accy.kernel.scan.device_prefix_sum_family_32_f16",
            f16_package.pipeline.value.target,
        );
        try std.testing.expectEqual(@as(usize, 3), f16_package.pipeline.value.intermediates.len);
        try std.testing.expect(f16_package.registry().find(
            "accy.kernel.scan.device_prefix_sum_block_scan_family_32_f16",
            scan_mod.device_scan_family_version,
            .cuda_ptx,
        ) != null);
        try std.testing.expect(f16_package.registry().find(
            "accy.kernel.scan.device_add_base_family_32_f16",
            scan_mod.device_scan_family_version,
            .cuda_ptx,
        ) != null);

        const f16_encoded = try accy_artifact.wire.encode(
            allocator,
            f16_package.entries,
            &.{f16_package.pipeline.value},
        );
        defer allocator.free(f16_encoded);
        var f16_decoded = try accy_artifact.wire.decode(allocator, f16_encoded);
        defer f16_decoded.deinit();
        const f16_found = accy_artifact.findPipeline(
            f16_decoded.pipelines,
            f16_package.pipeline.value.target,
            scan_mod.device_scan_family_version,
        ) orelse return error.TestExpectedPipeline;
        try f16_found.validate(f16_decoded.registry(), .cuda_ptx);

        var u32_owned = (try selectOwned(allocator, .{ .scan = .{
            .dtype = .u32,
            .kind = .prefix_sum,
            .extent = 2000,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer u32_owned.deinit();

        var u32_package = (try createOwnedKernelCallPipelinePackage(
            allocator,
            state.handle(),
            u32_owned,
            .{ .limits = .testing },
        )) orelse {
            return error.TestExpectedPipelinePackage;
        };
        defer u32_package.deinit();

        try std.testing.expectEqualStrings(
            "accy.kernel.scan.device_prefix_sum_family_32_u32",
            u32_package.pipeline.value.target,
        );
        try std.testing.expectEqual(@as(usize, 2), u32_package.pipeline.value.intermediates.len);
        try std.testing.expectEqual(
            gpu_abi.DType.u32,
            u32_package.pipeline.value.intermediates[0].dtype,
        );
        try std.testing.expectEqual(
            gpu_abi.DType.u32,
            u32_package.pipeline.value.intermediates[1].dtype,
        );
        try std.testing.expect(u32_package.registry().find(
            "accy.kernel.scan.device_prefix_sum_block_scan_family_32_u32",
            scan_mod.device_scan_family_version,
            .cuda_ptx,
        ) != null);
        try std.testing.expect(u32_package.registry().find(
            "accy.kernel.scan.device_add_base_family_32_u32",
            scan_mod.device_scan_family_version,
            .cuda_ptx,
        ) != null);

        const u32_encoded = try accy_artifact.wire.encode(
            allocator,
            u32_package.entries,
            &.{u32_package.pipeline.value},
        );
        defer allocator.free(u32_encoded);
        var u32_decoded = try accy_artifact.wire.decode(allocator, u32_encoded);
        defer u32_decoded.deinit();
        const u32_found = accy_artifact.findPipeline(
            u32_decoded.pipelines,
            u32_package.pipeline.value.target,
            scan_mod.device_scan_family_version,
        ) orelse return error.TestExpectedPipeline;
        try u32_found.validate(u32_decoded.registry(), .cuda_ptx);

        var single_block = (try selectOwned(allocator, .{ .scan = .{
            .dtype = .f32,
            .kind = .prefix_sum,
            .extent = 100,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer single_block.deinit();
        try std.testing.expectEqual(
            @as(?OwnedKernelCallPipelinePackage, null),
            try createOwnedKernelCallPipelinePackage(
                allocator,
                state.handle(),
                single_block,
                .{ .limits = .testing },
            ),
        );
    }
};

const sparse_tests = struct {
    const tuning_mod = tuning;
    const SparseQuery = catalog.SparseQuery;
    const selectSparse = selectOwnedSparse;
    const selectSparseCandidates = selectOwnedSparseCandidates;

    test "catalog sparse selection resolves structures from density and overrides" {
        const allocator = std.testing.allocator;

        var dense = (try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
        })) orelse return error.TestExpectedSparseDescriptor;
        defer dense.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_csr_row_warp_family_256_f32",
            dense.descriptor.metadata.target,
        );

        var sparse_rows = (try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 90, .x_extent = 40 } },
        })) orelse return error.TestExpectedSparseDescriptor;
        defer sparse_rows.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_csr_row_thread_family_70_f32",
            sparse_rows.descriptor.metadata.target,
        );

        var overridden = (try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 90, .x_extent = 40 } },
            .structure = .row_warp,
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        defer overridden.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_csr_row_warp_family_64_f32",
            overridden.descriptor.metadata.target,
        );
        try std.testing.expect(
            overridden.descriptor.metadata.specialization.structureIs("row_warp"),
        );

        var half = (try selectSparse(allocator, .{
            .dtype = .f16,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        defer half.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_csr_row_warp_family_64_f16",
            half.descriptor.metadata.target,
        );
        try std.testing.expectEqual(
            @as(?gpu_abi.DType, .f16),
            half.descriptor.metadata.specialization.dtype,
        );
        try std.testing.expectEqual(
            @as(?gpu_abi.DType, .f32),
            half.descriptor.metadata.specialization.accumulation_dtype,
        );

        var double = (try selectSparse(allocator, .{
            .dtype = .f64,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        defer double.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_csr_row_warp_family_64_f64",
            double.descriptor.metadata.target,
        );
        try std.testing.expectEqual(
            @as(?gpu_abi.DType, .f64),
            double.descriptor.metadata.specialization.dtype,
        );
        try std.testing.expectEqual(
            @as(?gpu_abi.DType, .f64),
            double.descriptor.metadata.specialization.accumulation_dtype,
        );

        var coo = (try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        defer coo.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_coo_element_thread_family_64_f32",
            coo.descriptor.metadata.target,
        );
        try std.testing.expect(
            coo.descriptor.metadata.specialization.operationIs(.{ .sparse = .coo_spmv }),
        );
        try std.testing.expect(
            coo.descriptor.metadata.specialization.structureIs("element_thread"),
        );
        try std.testing.expectEqual(
            @as(?gpu_abi.DType, .f32),
            coo.descriptor.metadata.specialization.accumulation_dtype,
        );

        var coo_half = (try selectSparse(allocator, .{
            .dtype = .f16,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        defer coo_half.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_coo_row_thread_family_64_f16",
            coo_half.descriptor.metadata.target,
        );
        try std.testing.expect(
            coo_half.descriptor.metadata.specialization.structureIs("row_thread"),
        );
        try std.testing.expectEqual(
            @as(?gpu_abi.DType, .f16),
            coo_half.descriptor.metadata.specialization.dtype,
        );
        try std.testing.expectEqual(
            @as(?gpu_abi.DType, .f32),
            coo_half.descriptor.metadata.specialization.accumulation_dtype,
        );

        var coo_double = (try selectSparse(allocator, .{
            .dtype = .f64,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        defer coo_double.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_coo_row_thread_family_64_f64",
            coo_double.descriptor.metadata.target,
        );
        try std.testing.expect(
            coo_double.descriptor.metadata.specialization.structureIs("row_thread"),
        );
        try std.testing.expectEqual(
            @as(?gpu_abi.DType, .f64),
            coo_double.descriptor.metadata.specialization.dtype,
        );
        try std.testing.expectEqual(
            @as(?gpu_abi.DType, .f64),
            coo_double.descriptor.metadata.specialization.accumulation_dtype,
        );

        var coo_row_thread = (try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .structure = .row_thread,
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        defer coo_row_thread.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_coo_row_thread_family_64_f32",
            coo_row_thread.descriptor.metadata.target,
        );

        var spmm = (try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmm = .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40 } },
            .schedule = .{ .thread_blocks_2d = .{ .x = 8, .y = 4 } },
        })) orelse return error.TestExpectedSparseDescriptor;
        defer spmm.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmm_csr_row_column_thread_family_8x4_f32",
            spmm.descriptor.metadata.target,
        );
        try std.testing.expect(
            spmm.descriptor.metadata.specialization.operationIs(.{ .sparse = .csr_spmm }),
        );
        try std.testing.expect(
            spmm.descriptor.metadata.specialization.structureIs("row_column_thread"),
        );

        var ell = (try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .ell_spmv = .{ .rows = 70, .slots = 8, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        defer ell.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_ell_row_thread_family_64_f32",
            ell.descriptor.metadata.target,
        );
        try std.testing.expect(
            ell.descriptor.metadata.specialization.operationIs(.{ .sparse = .ell_spmv }),
        );
        try std.testing.expect(ell.descriptor.metadata.specialization.structureIs("row_thread"));

        var sell = (try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{
                .sell_spmv = .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40 },
            },
            .schedule = .{ .thread_blocks = 64 },
        })) orelse return error.TestExpectedSparseDescriptor;
        defer sell.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_sell_row_thread_slice8_family_64_f32",
            sell.descriptor.metadata.target,
        );
        try std.testing.expect(
            sell.descriptor.metadata.specialization.operationIs(.{ .sparse = .sell_spmv }),
        );
        try std.testing.expect(sell.descriptor.metadata.specialization.structureIs("row_thread"));
        try std.testing.expect(sell.descriptor.metadata.specialization.staticParameterMatches(
            sparse_mod.spmv_sell_slice_size_parameter,
            8,
        ));

        var spmm_double = (try selectSparse(allocator, .{
            .dtype = .f64,
            .kind = .{ .csr_spmm = .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40 } },
            .schedule = .{ .thread_blocks_2d = .{ .x = 8, .y = 4 } },
        })) orelse return error.TestExpectedSparseDescriptor;
        defer spmm_double.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmm_csr_row_column_thread_family_8x4_f64",
            spmm_double.descriptor.metadata.target,
        );
        try std.testing.expectEqual(
            @as(?gpu_abi.DType, .f64),
            spmm_double.descriptor.metadata.specialization.dtype,
        );
        try std.testing.expectEqual(
            @as(?gpu_abi.DType, .f64),
            spmm_double.descriptor.metadata.specialization.accumulation_dtype,
        );

        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .i32,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 0, .x_extent = 40 } },
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f64,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .structure = .element_thread,
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f16,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .structure = .element_thread,
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 0, .x_extent = 40 } },
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .schedule = .{ .thread_blocks_2d = .{ .x = 8, .y = 4 } },
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 90, .x_extent = 40 } },
            .structure = .row_warp,
            .schedule = .{ .thread_blocks = 48 },
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmm = .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40 } },
            .structure = .row_warp,
            .schedule = .{ .thread_blocks_2d = .{ .x = 8, .y = 4 } },
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmm = .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 64 },
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .ell_spmv = .{ .rows = 70, .slots = 0, .x_extent = 40 } },
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .ell_spmv = .{ .rows = 70, .slots = 8, .x_extent = 40 } },
            .structure = .row_warp,
            .schedule = .{ .thread_blocks = 64 },
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{ .ell_spmv = .{ .rows = 70, .slots = 8, .x_extent = 40 } },
            .schedule = .{ .thread_blocks_2d = .{ .x = 8, .y = 4 } },
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{
                .sell_spmv = .{ .rows = 70, .slice_size = 0, .values_size = 400, .x_extent = 40 },
            },
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{
                .sell_spmv = .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40 },
            },
            .structure = .row_warp,
            .schedule = .{ .thread_blocks = 64 },
        }));
        try std.testing.expectEqual(@as(?OwnedDescriptor, null), try selectSparse(allocator, .{
            .dtype = .f32,
            .kind = .{
                .sell_spmv = .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40 },
            },
            .schedule = .{ .thread_blocks_2d = .{ .x = 8, .y = 4 } },
        }));
    }

    test "catalog sparse selection consults csr family tuning for density override" {
        const allocator = std.testing.allocator;
        const device: u64 = 0xacc70001;
        const query = SparseQuery{
            .dtype = .f32,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
        };
        const probe = sparse_mod.SpmvCsr{
            .rows = 70,
            .nnz = 560,
            .x_extent = 40,
            .threads = 256,
            .structure = .row_warp,
        };
        var winner = probe;
        winner.structure = .row_thread;
        winner.threads = sparse_mod.spmvCsrRepresentableThreads(winner) orelse
            return error.TestExpectedSparseDescriptor;
        const winner_target = try sparse_mod.spmvCsrFamilyTarget(allocator, winner);
        defer allocator.free(winner_target);
        const records = [_]tuning_mod.FamilyTuningRecord{.{
            .key = try sparse_mod.spmvCsrFamilyTuningKey(allocator, device, probe),
            .target = winner_target,
            .winner_median_ns = 800,
            .runner_up_median_ns = 1100,
            .sample_count = 30,
        }};
        const reader = tuning_mod.FamilyTuningReader{
            .device_fingerprint = device,
            .table = .{ .records = records[0..] },
        };

        var tuned = (try selectSparseWithTuning(allocator, query, reader)) orelse
            return error.TestExpectedSparseDescriptor;
        defer tuned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_csr_row_thread_family_70_f32",
            tuned.descriptor.metadata.target,
        );
        try std.testing.expect(tuned.descriptor.metadata.specialization.structureIs("row_thread"));

        var miss = (try selectSparseWithTuning(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 561, .x_extent = 40 } },
        }, reader)) orelse return error.TestExpectedSparseDescriptor;
        defer miss.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_csr_row_warp_family_256_f32",
            miss.descriptor.metadata.target,
        );

        var explicit = (try selectSparseWithTuning(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .structure = .row_warp,
        }, reader)) orelse return error.TestExpectedSparseDescriptor;
        defer explicit.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_csr_row_warp_family_256_f32",
            explicit.descriptor.metadata.target,
        );
    }

    test "catalog sparse selection consults coo family tuning for structure override" {
        const allocator = std.testing.allocator;
        const device: u64 = 0xacc70002;
        const query = SparseQuery{
            .dtype = .f32,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
        };
        const probe = sparse_mod.SpmvCoo{
            .rows = 70,
            .nnz = 560,
            .x_extent = 40,
            .threads = 256,
            .structure = .element_thread,
        };
        var winner = probe;
        winner.structure = .row_thread;
        winner.threads = sparse_mod.spmvCooRepresentableThreads(winner) orelse
            return error.TestExpectedSparseDescriptor;
        const winner_target = try sparse_mod.spmvCooFamilyTarget(allocator, winner);
        defer allocator.free(winner_target);
        const records = [_]tuning_mod.FamilyTuningRecord{.{
            .key = try sparse_mod.spmvCooFamilyTuningKey(allocator, device, probe),
            .target = winner_target,
            .winner_median_ns = 900,
            .runner_up_median_ns = 1200,
            .sample_count = 30,
        }};
        const reader = tuning_mod.FamilyTuningReader{
            .device_fingerprint = device,
            .table = .{ .records = records[0..] },
        };

        var tuned = (try selectSparseWithTuning(allocator, query, reader)) orelse
            return error.TestExpectedSparseDescriptor;
        defer tuned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_coo_row_thread_family_70_f32",
            tuned.descriptor.metadata.target,
        );
        try std.testing.expect(tuned.descriptor.metadata.specialization.structureIs("row_thread"));

        var miss = (try selectSparseWithTuning(allocator, .{
            .dtype = .f32,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 561, .x_extent = 40 } },
        }, reader)) orelse return error.TestExpectedSparseDescriptor;
        defer miss.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_coo_element_thread_family_256_f32",
            miss.descriptor.metadata.target,
        );

        var explicit = (try selectSparseWithTuning(allocator, .{
            .dtype = .f32,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .structure = .element_thread,
        }, reader)) orelse return error.TestExpectedSparseDescriptor;
        defer explicit.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_coo_element_thread_family_256_f32",
            explicit.descriptor.metadata.target,
        );
    }

    test "catalog sparse selection consults ell family tuning for thread blocks" {
        const allocator = std.testing.allocator;
        const device: u64 = 0xacc70003;
        const query = SparseQuery{
            .dtype = .f32,
            .kind = .{ .ell_spmv = .{ .rows = 70, .slots = 8, .x_extent = 40 } },
        };
        const probe = sparse_mod.SpmvEll{
            .rows = 70,
            .slots = 8,
            .x_extent = 40,
            .threads = 70,
        };
        var winner = probe;
        winner.threads = 64;
        const winner_target = try sparse_mod.spmvEllFamilyTarget(allocator, winner);
        defer allocator.free(winner_target);
        const records = [_]tuning_mod.FamilyTuningRecord{.{
            .key = try sparse_mod.spmvEllFamilyTuningKey(allocator, device, probe),
            .target = winner_target,
            .winner_median_ns = 900,
            .runner_up_median_ns = 1200,
            .sample_count = 30,
        }};
        const reader = tuning_mod.FamilyTuningReader{
            .device_fingerprint = device,
            .table = .{ .records = records[0..] },
        };

        var tuned = (try selectSparseWithTuning(allocator, query, reader)) orelse
            return error.TestExpectedSparseDescriptor;
        defer tuned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_ell_row_thread_family_64_f32",
            tuned.descriptor.metadata.target,
        );
        try std.testing.expectEqual(
            @as(u32, 64),
            tuned.descriptor.metadata.specialization.launch.?.threadgroup[0],
        );

        var miss = (try selectSparseWithTuning(allocator, .{
            .dtype = .f32,
            .kind = .{ .ell_spmv = .{ .rows = 70, .slots = 16, .x_extent = 40 } },
        }, reader)) orelse return error.TestExpectedSparseDescriptor;
        defer miss.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_ell_row_thread_family_70_f32",
            miss.descriptor.metadata.target,
        );

        var explicit = (try selectSparseWithTuning(allocator, .{
            .dtype = .f32,
            .kind = .{ .ell_spmv = .{ .rows = 70, .slots = 8, .x_extent = 40 } },
            .schedule = .{ .thread_blocks = 32 },
        }, reader)) orelse return error.TestExpectedSparseDescriptor;
        defer explicit.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_ell_row_thread_family_32_f32",
            explicit.descriptor.metadata.target,
        );
    }

    test "catalog sparse selection consults sell family tuning for thread blocks" {
        const allocator = std.testing.allocator;
        const device: u64 = 0xacc70004;
        const query = SparseQuery{
            .dtype = .f32,
            .kind = .{
                .sell_spmv = .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40 },
            },
        };
        const probe = sparse_mod.SpmvSell{
            .rows = 70,
            .slice_size = 8,
            .values_size = 400,
            .x_extent = 40,
            .threads = 70,
        };
        var winner = probe;
        winner.threads = 64;
        const winner_target = try sparse_mod.spmvSellFamilyTarget(allocator, winner);
        defer allocator.free(winner_target);
        const records = [_]tuning_mod.FamilyTuningRecord{.{
            .key = try sparse_mod.spmvSellFamilyTuningKey(allocator, device, probe),
            .target = winner_target,
            .winner_median_ns = 900,
            .runner_up_median_ns = 1200,
            .sample_count = 30,
        }};
        const reader = tuning_mod.FamilyTuningReader{
            .device_fingerprint = device,
            .table = .{ .records = records[0..] },
        };

        var tuned = (try selectSparseWithTuning(allocator, query, reader)) orelse
            return error.TestExpectedSparseDescriptor;
        defer tuned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_sell_row_thread_slice8_family_64_f32",
            tuned.descriptor.metadata.target,
        );
        try std.testing.expectEqual(
            @as(u32, 64),
            tuned.descriptor.metadata.specialization.launch.?.threadgroup[0],
        );

        var miss = (try selectSparseWithTuning(allocator, .{
            .dtype = .f32,
            .kind = .{
                .sell_spmv = .{ .rows = 70, .slice_size = 16, .values_size = 400, .x_extent = 40 },
            },
        }, reader)) orelse return error.TestExpectedSparseDescriptor;
        defer miss.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_sell_row_thread_slice16_family_70_f32",
            miss.descriptor.metadata.target,
        );

        var explicit = (try selectSparseWithTuning(allocator, .{
            .dtype = .f32,
            .kind = .{
                .sell_spmv = .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40 },
            },
            .schedule = .{ .thread_blocks = 32 },
        }, reader)) orelse return error.TestExpectedSparseDescriptor;
        defer explicit.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_sell_row_thread_slice8_family_32_f32",
            explicit.descriptor.metadata.target,
        );
    }

    test "catalog sparse selection consults csr spmm family tuning for thread blocks" {
        const allocator = std.testing.allocator;
        const device: u64 = 0xacc70005;
        const query = SparseQuery{
            .dtype = .f32,
            .kind = .{ .csr_spmm = .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40 } },
        };
        const probe = sparse_mod.SpmmCsr{
            .rows = 70,
            .columns = 45,
            .nnz = 512,
            .x_extent = 40,
            .threads = sparse_mod.spmmCsrThreadsForExtents(70, 45),
        };
        const candidates = sparse_mod.spmmCsrThreadCandidatesForExtents(probe.rows, probe.columns);
        try std.testing.expect(candidates.count > 1);
        var winner = probe;
        winner.threads = candidates.items[1];
        winner.threads = sparse_mod.spmmCsrRepresentableThreads(winner) orelse
            return error.TestExpectedSparseDescriptor;
        const winner_target = try sparse_mod.spmmCsrFamilyTarget(allocator, winner);
        defer allocator.free(winner_target);
        const records = [_]tuning_mod.FamilyTuningRecord{.{
            .key = try sparse_mod.spmmCsrFamilyTuningKey(allocator, device, probe),
            .target = winner_target,
            .winner_median_ns = 900,
            .runner_up_median_ns = 1200,
            .sample_count = 30,
        }};
        const reader = tuning_mod.FamilyTuningReader{
            .device_fingerprint = device,
            .table = .{ .records = records[0..] },
        };

        var tuned = (try selectSparseWithTuning(allocator, query, reader)) orelse
            return error.TestExpectedSparseDescriptor;
        defer tuned.deinit();
        try std.testing.expectEqualStrings(winner_target, tuned.descriptor.metadata.target);
        try std.testing.expectEqual(
            winner.threads.x,
            tuned.descriptor.metadata.specialization.launch.?.threadgroup[0],
        );
        try std.testing.expectEqual(
            winner.threads.y,
            tuned.descriptor.metadata.specialization.launch.?.threadgroup[1],
        );

        var miss = (try selectSparseWithTuning(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmm = .{ .rows = 70, .columns = 46, .nnz = 512, .x_extent = 40 } },
        }, reader)) orelse return error.TestExpectedSparseDescriptor;
        defer miss.deinit();
        var fallback_instance = sparse_mod.SpmmCsr{
            .rows = 70,
            .columns = 46,
            .nnz = 512,
            .x_extent = 40,
            .threads = sparse_mod.spmmCsrThreadsForExtents(70, 46),
        };
        fallback_instance.threads = sparse_mod.spmmCsrRepresentableThreads(fallback_instance) orelse
            return error.TestExpectedSparseDescriptor;
        const fallback_target = try sparse_mod.spmmCsrFamilyTarget(allocator, fallback_instance);
        defer allocator.free(fallback_target);
        try std.testing.expectEqualStrings(fallback_target, miss.descriptor.metadata.target);

        var explicit = (try selectSparseWithTuning(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmm = .{ .rows = 70, .columns = 45, .nnz = 512, .x_extent = 40 } },
            .schedule = .{ .thread_blocks_2d = .{ .x = 8, .y = 4 } },
        }, reader)) orelse return error.TestExpectedSparseDescriptor;
        defer explicit.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmm_csr_row_column_thread_family_8x4_f32",
            explicit.descriptor.metadata.target,
        );
    }

    test "catalog sparse candidates enumerate sparse structures and schedules" {
        const allocator = std.testing.allocator;

        var csr_candidates = try selectSparseCandidates(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
        });
        defer csr_candidates.deinit();
        try std.testing.expectEqual(@as(usize, 2), csr_candidates.count);
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_csr_row_thread_family_70_f32",
            csr_candidates.items[0].descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_csr_row_warp_family_256_f32",
            csr_candidates.items[1].descriptor.metadata.target,
        );

        var coo_candidates = try selectSparseCandidates(allocator, .{
            .dtype = .f32,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
        });
        defer coo_candidates.deinit();
        try std.testing.expectEqual(@as(usize, 2), coo_candidates.count);
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_coo_element_thread_family_256_f32",
            coo_candidates.items[0].descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_coo_row_thread_family_70_f32",
            coo_candidates.items[1].descriptor.metadata.target,
        );

        var coo_half_candidates = try selectSparseCandidates(allocator, .{
            .dtype = .f16,
            .kind = .{ .coo_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
        });
        defer coo_half_candidates.deinit();
        try std.testing.expectEqual(@as(usize, 1), coo_half_candidates.count);
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_coo_row_thread_family_70_f16",
            coo_half_candidates.items[0].descriptor.metadata.target,
        );

        var ell_candidates = try selectSparseCandidates(allocator, .{
            .dtype = .f32,
            .kind = .{ .ell_spmv = .{ .rows = 70, .slots = 8, .x_extent = 40 } },
        });
        defer ell_candidates.deinit();
        try std.testing.expectEqual(@as(usize, 3), ell_candidates.count);
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_ell_row_thread_family_70_f32",
            ell_candidates.items[0].descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_ell_row_thread_family_32_f32",
            ell_candidates.items[1].descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_ell_row_thread_family_64_f32",
            ell_candidates.items[2].descriptor.metadata.target,
        );

        var sell_candidates = try selectSparseCandidates(allocator, .{
            .dtype = .f32,
            .kind = .{
                .sell_spmv = .{ .rows = 70, .slice_size = 8, .values_size = 400, .x_extent = 40 },
            },
        });
        defer sell_candidates.deinit();
        try std.testing.expectEqual(@as(usize, 3), sell_candidates.count);
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_sell_row_thread_slice8_family_70_f32",
            sell_candidates.items[0].descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_sell_row_thread_slice8_family_32_f32",
            sell_candidates.items[1].descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_sell_row_thread_slice8_family_64_f32",
            sell_candidates.items[2].descriptor.metadata.target,
        );

        var spmm_candidates = try selectSparseCandidates(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmm = .{ .rows = 70, .columns = 45, .nnz = 560, .x_extent = 40 } },
        });
        defer spmm_candidates.deinit();
        try std.testing.expect(spmm_candidates.count > 1);
        var spmm_default = sparse_mod.SpmmCsr{
            .rows = 70,
            .columns = 45,
            .nnz = 560,
            .x_extent = 40,
            .threads = sparse_mod.spmmCsrThreadsForExtents(70, 45),
        };
        spmm_default.threads = sparse_mod.spmmCsrRepresentableThreads(spmm_default) orelse
            return error.TestExpectedSparseDescriptor;
        const spmm_default_target = try sparse_mod.spmmCsrFamilyTarget(allocator, spmm_default);
        defer allocator.free(spmm_default_target);
        try std.testing.expectEqualStrings(
            spmm_default_target,
            spmm_candidates.items[0].descriptor.metadata.target,
        );

        var explicit = try selectSparseCandidates(allocator, .{
            .dtype = .f32,
            .kind = .{ .csr_spmv = .{ .rows = 70, .nnz = 560, .x_extent = 40 } },
            .structure = .row_warp,
            .schedule = .{ .thread_blocks = 64 },
        });
        defer explicit.deinit();
        try std.testing.expectEqual(@as(usize, 1), explicit.count);
        try std.testing.expectEqualStrings(
            "accy.kernel.sparse.spmv_csr_row_warp_family_64_f32",
            explicit.items[0].descriptor.metadata.target,
        );
    }
};

const sort_tests = struct {
    test "kernel library catalog selects and dispatches radix sort pipelines" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };

        var owned = (try selectOwned(allocator, .{ .sort = .{
            .dtype = .i32,
            .kind = .radix_ascending,
            .extent = 2000,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer owned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.radix_digit_family_32_i32",
            owned.descriptor.metadata.target,
        );
        try std.testing.expectEqual(entry.Category.sort, owned.descriptor.metadata.category);
        try std.testing.expect(owned.descriptor.metadata.specialization.structureIs("radix_digit"));

        var split = (try selectOwned(allocator, .{ .sort = .{
            .dtype = .i32,
            .kind = .radix_ascending,
            .extent = 2000,
            .structure = .radix_split,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer split.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.radix_split_family_32_i32",
            split.descriptor.metadata.target,
        );
        try std.testing.expect(split.descriptor.metadata.specialization.structureIs("radix_split"));

        var scheduled = (try selectOwned(allocator, .{ .sort = .{
            .dtype = .i32,
            .kind = .radix_ascending,
            .extent = 2000,
            .structure = .radix_split,
            .schedule = .{ .thread_blocks = 128 },
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer scheduled.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.radix_split_family_128_i32",
            scheduled.descriptor.metadata.target,
        );

        var bitonic = (try selectOwned(allocator, .{ .sort = .{
            .dtype = .i32,
            .kind = .radix_ascending,
            .extent = 45,
            .structure = .bitonic_block,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer bitonic.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.bitonic_block_family_64_i32",
            bitonic.descriptor.metadata.target,
        );
        try std.testing.expectEqual(
            sort_mod.bitonic_block_family_version,
            bitonic.descriptor.metadata.version,
        );
        try std.testing.expect(
            bitonic.descriptor.metadata.specialization.structureIs("bitonic_block"),
        );

        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(allocator, .{ .sort = .{
                .dtype = .i32,
                .kind = .radix_ascending,
                .extent = 1024 * 1024 + 1,
            } }),
        );
        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(allocator, .{
                .sort = .{ .dtype = .f32, .kind = .radix_ascending, .extent = 2000 },
            }),
        );
        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(allocator, .{ .sort = .{
                .dtype = .i32,
                .kind = .radix_ascending,
                .extent = 1025,
                .structure = .bitonic_block,
            } }),
        );

        var package = (try createOwnedKernelCallPipelinePackage(
            allocator,
            state.handle(),
            owned,
            .{ .limits = .testing },
        )) orelse {
            return error.TestExpectedPipelinePackage;
        };
        defer package.deinit();
        try std.testing.expectEqual(@as(usize, 5), package.artifacts.len);
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.radix_digit_family_32_i32",
            package.pipeline.value.target,
        );
        try std.testing.expect(package.registry().find(
            "accy.kernel.sort.radix_digit_histogram_family_32_i32",
            sort_mod.radix_split_family_version,
            .cuda_ptx,
        ) != null);

        var split_package = (try createOwnedKernelCallPipelinePackage(
            allocator,
            state.handle(),
            split,
            .{ .limits = .testing },
        )) orelse {
            return error.TestExpectedPipelinePackage;
        };
        defer split_package.deinit();
        try std.testing.expectEqual(@as(usize, 5), split_package.artifacts.len);
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.radix_split_family_32_i32",
            split_package.pipeline.value.target,
        );
        try std.testing.expect(split_package.registry().find(
            "accy.kernel.sort.radix_split_flags_family_32_i32",
            sort_mod.radix_split_family_version,
            .cuda_ptx,
        ) != null);

        var bitonic_artifact = try createOwnedKernelCallArtifact(
            allocator,
            state.handle(),
            bitonic,
            .{ .limits = .testing },
        );
        defer bitonic_artifact.deinit();
        const bitonic_entry = bitonic_artifact.entry();
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.bitonic_block_family_64_i32",
            bitonic_entry.target,
        );
        try std.testing.expectEqual(@as(u32, 1), bitonic_entry.runtime_scalar_argument_count);
        try std.testing.expect(try createOwnedKernelCallPipelinePackage(
            allocator,
            state.handle(),
            bitonic,
            .{ .limits = .testing },
        ) == null);
    }

    test "kernel library catalog consults tuning for sort structure" {
        const allocator = std.testing.allocator;
        const sort_lib = sort_mod;
        const device: u64 = 0xfeed_dead_beef_0002;
        const instance = sort_lib.RadixSplit{ .extent = 5000, .threads = 32 };

        var accumulator = tuning.FamilyMeasurementAccumulator.init(allocator);
        defer accumulator.deinit();
        const key = try sort_lib.radixSplitFamilyTuningKey(allocator, device, instance);
        const split_target = try sort_lib.radixSplitPipelineTarget(allocator, instance);
        defer allocator.free(split_target);
        const digit_target = try sort_lib.radixDigitPipelineTarget(allocator, instance);
        defer allocator.free(digit_target);
        try accumulator.append(key, digit_target, 4_953_684, 20);
        try accumulator.append(key, split_target, 897_993, 20);

        var winners = try accumulator.selectWinners(
            allocator,
            tuning.family_tuning_default_margin_percent,
        );
        defer winners.deinit();
        const encoded = try tuning.encodeFamilyTuningArtifact(allocator, winners.records);
        defer allocator.free(encoded);
        var decoded = try tuning.decodeFamilyTuningArtifact(allocator, encoded);
        defer decoded.deinit();
        const reader = tuning.FamilyTuningReader{
            .device_fingerprint = device,
            .table = decoded.table(),
        };

        var tuned = (try selectRadixSortWithTuning(allocator, .{
            .dtype = .i32,
            .kind = .radix_ascending,
            .extent = 5000,
        }, reader)) orelse return error.TestExpectedCatalogDescriptor;
        defer tuned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.radix_split_family_32_i32",
            tuned.descriptor.metadata.target,
        );
        try std.testing.expect(tuned.descriptor.metadata.specialization.structureIs("radix_split"));

        var missed = (try selectRadixSortWithTuning(allocator, .{
            .dtype = .i32,
            .kind = .radix_ascending,
            .extent = 9000,
        }, reader)) orelse return error.TestExpectedCatalogDescriptor;
        defer missed.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.radix_digit_family_32_i32",
            missed.descriptor.metadata.target,
        );

        var pinned = (try selectRadixSortWithTuning(allocator, .{
            .dtype = .i32,
            .kind = .radix_ascending,
            .extent = 5000,
            .structure = .radix_digit,
        }, reader)) orelse return error.TestExpectedCatalogDescriptor;
        defer pinned.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.radix_digit_family_32_i32",
            pinned.descriptor.metadata.target,
        );
    }

    test "kernel library catalog selects and dispatches block top-k families" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };

        var keys = (try selectOwned(allocator, .{ .sort = .{
            .dtype = .i32,
            .kind = .top_k_smallest,
            .extent = 45,
            .k = 8,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer keys.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.top_k_block_family_64x8_i32",
            keys.descriptor.metadata.target,
        );
        try std.testing.expectEqual(entry.Category.sort, keys.descriptor.metadata.category);
        try std.testing.expect(
            keys.descriptor.metadata.specialization.operationIs(.{ .sort = .top_k_smallest }),
        );
        try std.testing.expect(keys.descriptor.metadata.specialization.structureIs(
            sort_mod.top_k_block_structure_name,
        ));
        try std.testing.expect(keys.descriptor.metadata.specialization.inputHasExtents(0, &.{45}));
        try std.testing.expect(keys.descriptor.metadata.specialization.outputHasExtents(0, &.{8}));

        var scheduled = (try selectOwned(allocator, .{ .sort = .{
            .dtype = .i32,
            .kind = .top_k_smallest,
            .extent = 45,
            .k = 8,
            .schedule = .{ .thread_blocks = 128 },
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer scheduled.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.top_k_block_family_128x8_i32",
            scheduled.descriptor.metadata.target,
        );

        var pairs = (try selectOwned(allocator, .{ .sort = .{
            .dtype = .i32,
            .kind = .top_k_smallest,
            .extent = 45,
            .k = 8,
            .structure = .top_k_block_pairs,
        } })) orelse return error.TestExpectedCatalogDescriptor;
        defer pairs.deinit();
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.top_k_block_pairs_family_64x8_i32",
            pairs.descriptor.metadata.target,
        );
        try std.testing.expectEqual(
            sort_mod.top_k_block_pairs_family_version,
            pairs.descriptor.metadata.version,
        );
        try std.testing.expect(pairs.descriptor.metadata.specialization.structureIs(
            sort_mod.top_k_block_pairs_structure_name,
        ));
        try std.testing.expect(pairs.descriptor.metadata.specialization.inputHasExtents(0, &.{45}));
        try std.testing.expect(pairs.descriptor.metadata.specialization.inputHasExtents(1, &.{45}));
        try std.testing.expect(pairs.descriptor.metadata.specialization.outputHasExtents(0, &.{8}));
        try std.testing.expect(pairs.descriptor.metadata.specialization.outputHasExtents(1, &.{8}));

        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(allocator, .{ .sort = .{
                .dtype = .i32,
                .kind = .top_k_smallest,
                .extent = 45,
                .k = 0,
            } }),
        );
        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(allocator, .{ .sort = .{
                .dtype = .i32,
                .kind = .top_k_smallest,
                .extent = 45,
                .k = 46,
            } }),
        );
        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(allocator, .{ .sort = .{
                .dtype = .f32,
                .kind = .top_k_smallest,
                .extent = 45,
                .k = 8,
            } }),
        );
        try std.testing.expectEqual(
            @as(?OwnedDescriptor, null),
            try selectOwned(allocator, .{ .sort = .{
                .dtype = .i32,
                .kind = .top_k_smallest,
                .extent = 45,
                .k = 8,
                .structure = .radix_digit,
            } }),
        );

        var key_artifact = try createOwnedKernelCallArtifact(
            allocator,
            state.handle(),
            keys,
            .{ .limits = .testing },
        );
        defer key_artifact.deinit();
        const key_entry = key_artifact.entry();
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.top_k_block_family_64x8_i32",
            key_entry.target,
        );
        try std.testing.expectEqual(sort_mod.top_k_block_family_version, key_entry.version);
        try std.testing.expectEqual(@as(u32, 1), key_entry.runtime_scalar_argument_count);

        var pair_artifact = try createOwnedKernelCallArtifact(
            allocator,
            state.handle(),
            pairs,
            .{ .limits = .testing },
        );
        defer pair_artifact.deinit();
        const pair_entry = pair_artifact.entry();
        try std.testing.expectEqualStrings(
            "accy.kernel.sort.top_k_block_pairs_family_64x8_i32",
            pair_entry.target,
        );
        try std.testing.expectEqual(sort_mod.top_k_block_pairs_family_version, pair_entry.version);
        try std.testing.expectEqual(@as(u32, 1), pair_entry.runtime_scalar_argument_count);
        try std.testing.expect(try createOwnedKernelCallPipelinePackage(
            allocator,
            state.handle(),
            pairs,
            .{ .limits = .testing },
        ) == null);
    }
};

const selection_batched_matrix_product_tests = struct {
    test "kernel library catalog selects batched matrix product family by canonical einsum roles" {
        const lhs_dims = [_]i64{ 2, 2, 4 };
        const rhs_dims = [_]i64{ 2, 4, 3 };
        const output_dims = [_]i64{ 2, 2, 3 };
        const query = Query{ .batched_matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "bmk",
            .rhs_indices = "bkn",
            .output_indices = "bmn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } };
        try std.testing.expect(select(query) == null);
        var selected = (try selectOwned(std.testing.allocator, query)) orelse
            return error.TestExpectedBatchedMatrixProductFamilySelection;
        defer selected.deinit();
        const specialization = selected.descriptor.metadata.specialization;

        try std.testing.expect(selected.specialization != null);
        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.batched_matmul_family_3x2x2_f32",
            selected.descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy_kernel_linalg_batched_matmul_family_3x2x2_f32",
            selected.descriptor.name,
        );
        try std.testing.expect(specialization.operationIs(.{ .linalg = .batched_matrix_product }));
        try std.testing.expect(specialization.shape_family != null);
        try std.testing.expectEqual(@as(u32, 3), specialization.launch.?.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[1]);
        try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[2]);
    }

    test "kernel library catalog selects batched matrix product family schedule specialization" {
        const lhs_dims = [_]i64{ 2, 2, 4 };
        const rhs_dims = [_]i64{ 2, 4, 3 };
        const output_dims = [_]i64{ 2, 2, 3 };
        const query = Query{ .batched_matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "bmk",
            .rhs_indices = "bkn",
            .output_indices = "bmn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 3, .y = 2, .z = 2 } },
        } };
        try std.testing.expect(select(query) == null);
        var selected = (try selectOwned(std.testing.allocator, query)) orelse
            return error.TestExpectedBatchedMatrixProductScheduleSelection;
        defer selected.deinit();
        const specialization = selected.descriptor.metadata.specialization;

        try std.testing.expect(selected.specialization != null);
        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.batched_matmul_family_3x2x2_f32",
            selected.descriptor.metadata.target,
        );
        try std.testing.expectEqual(@as(u32, 3), specialization.launch.?.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[1]);
        try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[2]);
    }
};

const selection_matrix_product_tests = struct {
    test "kernel library catalog selects matrix product by canonical einsum roles" {
        const lhs_dims = [_]i64{ 4, 8 };
        const rhs_dims = [_]i64{ 8, 16 };
        const output_dims = [_]i64{ 4, 16 };
        const selected = select(.{ .matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "ik",
            .rhs_indices = "kj",
            .output_indices = "ij",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } }) orelse return error.TestExpectedMatrixProductSelection;

        try std.testing.expectEqualStrings(
            linalg.MatrixProduct4x16x8F32.target,
            selected.metadata.target,
        );
        try std.testing.expectEqualStrings(linalg.MatrixProduct4x16x8F32.name, selected.name);
    }

    test "kernel library catalog selects matrix product schedule specialization" {
        const lhs_dims = [_]i64{ 4, 8 };
        const rhs_dims = [_]i64{ 8, 16 };
        const output_dims = [_]i64{ 4, 16 };
        const selected = select(.{ .matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "ik",
            .rhs_indices = "kj",
            .output_indices = "ij",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 4, .y = 2 } },
        } }) orelse return error.TestExpectedMatrixProductScheduleSelection;

        try std.testing.expectEqualStrings(
            linalg.MatrixProduct4x16x8ThreadBlocks4x2F32.target,
            selected.metadata.target,
        );
        try std.testing.expectEqualStrings(
            linalg.MatrixProduct4x16x8ThreadBlocks4x2F32.name,
            selected.name,
        );
        try std.testing.expectEqual(
            @as(u32, 4),
            selected.metadata.specialization.launch.?.threadgroup[0],
        );
        try std.testing.expectEqual(
            @as(u32, 2),
            selected.metadata.specialization.launch.?.threadgroup[1],
        );
    }

    test "kernel library catalog owned selection preserves fixed matrix product descriptors" {
        const lhs_dims = [_]i64{ 4, 8 };
        const rhs_dims = [_]i64{ 8, 16 };
        const output_dims = [_]i64{ 4, 16 };
        var selected = (try selectOwned(std.testing.allocator, .{ .matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "ik",
            .rhs_indices = "kj",
            .output_indices = "ij",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } })) orelse return error.TestExpectedMatrixProductSelection;
        defer selected.deinit();

        try std.testing.expect(selected.specialization == null);
        try std.testing.expectEqualStrings(
            linalg.MatrixProduct4x16x8F32.target,
            selected.descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            linalg.MatrixProduct4x16x8F32.name,
            selected.descriptor.name,
        );
    }

    test "kernel library catalog selects matrix product family for runtime extents" {
        const lhs_dims = [_]i64{ 5, 3 };
        const rhs_dims = [_]i64{ 3, 7 };
        const output_dims = [_]i64{ 5, 7 };
        const query = Query{ .matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } };

        try std.testing.expect(select(query) == null);
        var selected = (try selectOwned(std.testing.allocator, query)) orelse
            return error.TestExpectedMatrixProductFamilySelection;
        defer selected.deinit();
        const specialization = selected.descriptor.metadata.specialization;

        try std.testing.expect(selected.specialization != null);
        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.matmul_family_7x5_f32",
            selected.descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy_kernel_linalg_matmul_family_7x5_f32",
            selected.descriptor.name,
        );
        try std.testing.expectEqual(
            linalg.matrix_product_family_version,
            selected.descriptor.metadata.version,
        );
        try std.testing.expect(specialization.operationIs(.{ .linalg = .matrix_product }));
        try std.testing.expect(specialization.shape_family != null);
        try std.testing.expect(specialization.scheduleMatchesLaunch());
        try std.testing.expect(matrixProductDescriptorMatches(
            selected.descriptor,
            .{ .m = 5, .n = 7, .k = 3 },
            null,
            .f32,
        ));
        try std.testing.expectEqual(@as(u32, 1), specialization.launch.?.grid[0]);
        try std.testing.expectEqual(@as(u32, 1), specialization.launch.?.grid[1]);
        try std.testing.expectEqual(@as(u32, 7), specialization.launch.?.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 5), specialization.launch.?.threadgroup[1]);
    }

    test "kernel library catalog selects f16 matrix product family for runtime extents" {
        const lhs_dims = [_]i64{ 5, 3 };
        const rhs_dims = [_]i64{ 3, 7 };
        const output_dims = [_]i64{ 5, 7 };
        const query = Query{ .matrix_product = .{
            .dtype = .f16,
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        } };

        try std.testing.expect(select(query) == null);
        var selected = (try selectOwned(std.testing.allocator, query)) orelse
            return error.TestExpectedMatrixProductFamilySelection;
        defer selected.deinit();
        const specialization = selected.descriptor.metadata.specialization;

        try std.testing.expect(selected.specialization != null);
        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.matmul_family_7x5_f16",
            selected.descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy_kernel_linalg_matmul_family_7x5_f16",
            selected.descriptor.name,
        );
        try std.testing.expectEqual(@as(?gpu_abi.DType, .f16), specialization.dtype);
        try std.testing.expectEqual(@as(?gpu_abi.DType, .f32), specialization.accumulation_dtype);
        try std.testing.expect(matrixProductDescriptorMatches(
            selected.descriptor,
            .{ .m = 5, .n = 7, .k = 3 },
            null,
            .f16,
        ));
    }

    fn expectMatrixProductCandidateTargetsContain(
        candidates: MatrixProductCandidateDescriptors,
        target: []const u8,
    ) !void {
        for (candidates.slice()) |candidate| {
            if (std.mem.eql(u8, candidate.descriptor.metadata.target, target)) return;
        }
        return error.TestExpectedMatrixProductCandidate;
    }

    test "kernel library catalog selects owned matrix product family candidates" {
        const lhs_dims = [_]i64{ 17, 13 };
        const rhs_dims = [_]i64{ 13, 17 };
        const output_dims = [_]i64{ 17, 17 };
        var candidates = try selectOwnedMatrixProductCandidates(std.testing.allocator, .{
            .dtype = .f32,
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
        });
        defer candidates.deinit();

        try std.testing.expect(candidates.count > 2);
        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.matmul_family_17x9_f32",
            candidates.items[0].descriptor.metadata.target,
        );
        try expectMatrixProductCandidateTargetsContain(
            candidates,
            "accy.kernel.linalg.matmul_family_16x16_f32",
        );
        for (candidates.slice(), 0..) |candidate, index| {
            try std.testing.expect(candidate.specialization != null);
            try std.testing.expect(
                candidate.descriptor.metadata.specialization.shape_family != null,
            );
            try std.testing.expect(matrixProductDescriptorMatches(
                candidate.descriptor,
                .{ .m = 17, .n = 17, .k = 13 },
                null,
                .f32,
            ));
            for (candidates.slice()[0..index]) |previous| {
                try std.testing.expect(!std.mem.eql(
                    u8,
                    previous.descriptor.metadata.target,
                    candidate.descriptor.metadata.target,
                ));
            }
        }
    }

    test "kernel library catalog builds matrix product scheduled artifact registry" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        const lhs_dims = [_]i64{ 17, 13 };
        const rhs_dims = [_]i64{ 13, 17 };
        const output_dims = [_]i64{ 17, 17 };
        var registry_descriptors: [2]OwnedDescriptor = undefined;
        var descriptor_count: usize = 0;
        defer for (registry_descriptors[0..descriptor_count]) |*descriptor| descriptor.deinit();
        registry_descriptors[0] = (try selectOwned(allocator, .{ .matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 17, .y = 9 } },
        } })) orelse return error.TestExpectedMatrixProductCandidate;
        descriptor_count = 1;
        registry_descriptors[1] = (try selectOwned(allocator, .{ .matrix_product = .{
            .dtype = .f32,
            .lhs_indices = "mk",
            .rhs_indices = "kn",
            .output_indices = "mn",
            .lhs_dims = &lhs_dims,
            .rhs_dims = &rhs_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = .{ .x = 16, .y = 16 } },
        } })) orelse return error.TestExpectedMatrixProductCandidate;
        descriptor_count = 2;

        var owned_registry = try createOwnedKernelCallArtifactRegistry(
            allocator,
            state.handle(),
            registry_descriptors[0..],
            .{ .limits = .testing },
        );
        defer owned_registry.deinit();
        const registry = owned_registry.registry();
        const selected = registry.find(
            "accy.kernel.linalg.matmul_family_17x9_f32",
            linalg.matrix_product_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };
        const baseline = registry.find(
            "accy.kernel.linalg.matmul_family_16x16_f32",
            linalg.matrix_product_family_version,
            .cuda_ptx,
        ) orelse {
            return error.TestExpectedKernelCallArtifact;
        };
        const launch = switch (selected.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        const profile = selected.shape_profile orelse return error.TestExpectedShapeProfile;

        try std.testing.expectEqual(@as(usize, 2), registry.entries.len);
        try std.testing.expectEqual(@as(u32, 6), selected.argument_count);
        try std.testing.expectEqual(@as(u32, 3), selected.runtime_scalar_argument_count);
        try std.testing.expectEqual(@as(u32, 17), launch.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 9), launch.threadgroup[1]);
        try std.testing.expectEqual(@as(usize, 3), profile.dimensions.len);
        try std.testing.expect(selected.required_dtypes.contains(.f32));
        try std.testing.expect(selected.required_dtypes.contains(.i32));
        try std.testing.expectEqual(@as(u32, 16), baseline.launch.derived.threadgroup[0]);
        try std.testing.expectEqual(@as(u32, 16), baseline.launch.derived.threadgroup[1]);
    }
};

const selection_matrix_vector_tests = struct {
    test "kernel library catalog selects matrix vector product family for runtime extents" {
        const matrix_dims = [_]i64{ 5, 3 };
        const vector_dims = [_]i64{3};
        const output_dims = [_]i64{5};
        const query = Query{ .matrix_vector_product = .{
            .dtype = .f32,
            .matrix_indices = "mk",
            .vector_indices = "k",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &vector_dims,
            .output_dims = &output_dims,
        } };

        try std.testing.expect(select(query) == null);
        var selected = (try selectOwned(std.testing.allocator, query)) orelse
            return error.TestExpectedMatrixVectorProductFamilySelection;
        defer selected.deinit();
        const specialization = selected.descriptor.metadata.specialization;

        try std.testing.expect(selected.specialization != null);
        try std.testing.expectEqualStrings(
            "accy.kernel.linalg.matvec_family_5x_f32",
            selected.descriptor.metadata.target,
        );
        try std.testing.expectEqualStrings(
            "accy_kernel_linalg_matvec_family_5x_f32",
            selected.descriptor.name,
        );
        try std.testing.expectEqual(
            linalg.matrix_vector_product_family_version,
            selected.descriptor.metadata.version,
        );
        try std.testing.expect(specialization.operationIs(.{ .linalg = .matrix_vector_product }));
        try std.testing.expect(specialization.shape_family != null);
        try std.testing.expect(specialization.scheduleMatchesLaunch());
        try std.testing.expectEqual(@as(u32, 1), specialization.launch.?.grid[0]);
        try std.testing.expectEqual(@as(u32, 5), specialization.launch.?.threadgroup[0]);
        try std.testing.expect(specialization.inputHasExtents(0, &.{ 5, 3 }));
        try std.testing.expect(specialization.inputHasExtents(1, &.{3}));
        try std.testing.expect(specialization.outputHasExtents(0, &.{5}));
        try std.testing.expect(specialization.reductionMatches(
            0,
            .{ .name = "dot", .operator = .dot_product, .extents = &.{3} },
        ));
    }

    test "kernel library catalog builds matrix vector product scheduled artifact" {
        const allocator = std.testing.allocator;
        var state = gpu.recording.BackendState{
            .allocator = allocator,
            .kind = .cuda,
            .format = .cuda_ptx,
        };
        const matrix_dims = [_]i64{ 5, 3 };
        const vector_dims = [_]i64{3};
        const output_dims = [_]i64{5};
        var selected = (try selectOwned(allocator, .{ .matrix_vector_product = .{
            .dtype = .f32,
            .matrix_indices = "mk",
            .vector_indices = "k",
            .output_indices = "m",
            .matrix_dims = &matrix_dims,
            .vector_dims = &vector_dims,
            .output_dims = &output_dims,
            .schedule = .{ .thread_blocks = 4 },
        } })) orelse return error.TestExpectedMatrixVectorProductFamilySelection;
        defer selected.deinit();

        var call_artifact = try createOwnedKernelCallArtifact(
            allocator,
            state.handle(),
            selected,
            .{ .limits = .testing },
        );
        defer call_artifact.deinit();

        const artifact = call_artifact.registry().find(
            "accy.kernel.linalg.matvec_family_4x_f32",
            linalg.matrix_vector_product_family_version,
            .cuda_ptx,
        ) orelse return error.TestExpectedKernelCallArtifact;
        const launch = switch (artifact.launch) {
            .derived => |derived| derived,
            .fixed => return error.TestExpectedDerivedLaunch,
        };
        const profile = artifact.shape_profile orelse return error.TestExpectedShapeProfile;

        try std.testing.expectEqual(@as(u32, 5), artifact.argument_count);
        try std.testing.expectEqual(@as(u32, 2), artifact.runtime_scalar_argument_count);
        try std.testing.expectEqual(@as(u32, 4), launch.threadgroup[0]);
        try std.testing.expectEqual(@as(usize, 2), profile.dimensions.len);
        try std.testing.expect(artifact.required_dtypes.contains(.f32));
        try std.testing.expect(artifact.required_dtypes.contains(.i32));
    }
};

test {
    _ = @import("artifact/test.zig");
    _ = @import("family/test.zig");
    _ = @import("match/test.zig");
    _ = @import("select/test.zig");
    @import("test_discovery").discover(registry_tests);
    @import("test_discovery").discover(artifact_tests);
    @import("test_discovery").discover(variants_tests);
    @import("test_discovery").discover(fused_tests);
    @import("test_discovery").discover(reject_tests);
    @import("test_discovery").discover(normalization_tests);
    @import("test_discovery").discover(invalid_tests);
    @import("test_discovery").discover(family_tests);
    @import("test_discovery").discover(random_tests);
    @import("test_discovery").discover(segment_tests);
    @import("test_discovery").discover(scan_tests);
    @import("test_discovery").discover(sparse_tests);
    @import("test_discovery").discover(sort_tests);
    @import("test_discovery").discover(selection_batched_matrix_product_tests);
    @import("test_discovery").discover(selection_matrix_product_tests);
    @import("test_discovery").discover(selection_matrix_vector_tests);
    @import("test_discovery").discover(catalog);
}

test "accy kernel library catalog declaration coverage" {
    std.testing.refAllDecls(registry_tests);
    std.testing.refAllDecls(artifact_tests);
    std.testing.refAllDecls(variants_tests);
    std.testing.refAllDecls(fused_tests);
    std.testing.refAllDecls(reject_tests);
    std.testing.refAllDecls(normalization_tests);
    std.testing.refAllDecls(invalid_tests);
    std.testing.refAllDecls(family_tests);
    std.testing.refAllDecls(random_tests);
    std.testing.refAllDecls(segment_tests);
    std.testing.refAllDecls(scan_tests);
    std.testing.refAllDecls(sparse_tests);
    std.testing.refAllDecls(sort_tests);
    std.testing.refAllDecls(selection_batched_matrix_product_tests);
    std.testing.refAllDecls(selection_matrix_product_tests);
    std.testing.refAllDecls(selection_matrix_vector_tests);
    std.testing.refAllDecls(catalog);
}
