const std = @import("std");
const gpu_abi = @import("gpu_abi");

const library = @import("../../library/root.zig");

const DType = gpu_abi.DType;

pub const EinsumOperand = struct {
    indices: []const u8,
    dims: []const i64,
};

pub const EinsumSchedule = union(enum) {
    batched_matrix_product: library.BatchedMatrixProductSchedule,
    matrix_product: library.MatrixProductSchedule,
    matrix_vector_product: library.MatrixVectorProductSchedule,
    outer_product: library.OuterProductSchedule,
};

pub const EinsumSelectionRequest = struct {
    dtype: DType,
    inputs: []const EinsumOperand,
    output_indices: []const u8,
    output_dims: []const i64,
    schedule: ?EinsumSchedule = null,
};

pub const EinsumKernelKind = enum {
    batched_matrix_product,
    dot_product,
    matrix_product,
    matrix_vector_product,
    outer_product,
    sum_reduction,
    transpose,
};

pub const SelectedEinsumKernel = struct {
    kind: EinsumKernelKind,
    descriptor: library.CatalogDescriptor,
};

pub const OwnedSelectedEinsumKernel = struct {
    kind: EinsumKernelKind,
    descriptor: library.OwnedCatalogDescriptor,

    pub fn deinit(self: *OwnedSelectedEinsumKernel) void {
        self.descriptor.deinit();
        self.* = undefined;
    }
};

pub fn selectCatalog(request: EinsumSelectionRequest) ?SelectedEinsumKernel {
    if (selectReduction(request)) |selected| return selected;
    if (selectBatchedMatrixProduct(request)) |selected| return selected;
    if (selectMatrixProduct(request)) |selected| return selected;
    if (selectMatrixVectorProduct(request)) |selected| return selected;
    if (selectOuterProduct(request)) |selected| return selected;
    if (selectTranspose(request)) |selected| return selected;
    return null;
}

pub fn selectOwnedCatalog(backing_allocator: std.mem.Allocator, request: EinsumSelectionRequest) !?OwnedSelectedEinsumKernel {
    if (selectCatalog(request)) |selected| return ownedSelectedStatic(selected);
    if (try selectOwnedBatchedMatrixProduct(backing_allocator, request)) |selected| return selected;
    if (try selectOwnedMatrixProduct(backing_allocator, request)) |selected| return selected;
    if (try selectOwnedMatrixVectorProduct(backing_allocator, request)) |selected| return selected;
    if (try selectOwnedOuterProduct(backing_allocator, request)) |selected| return selected;
    return null;
}

fn ownedSelectedStatic(selected: SelectedEinsumKernel) OwnedSelectedEinsumKernel {
    return .{
        .kind = selected.kind,
        .descriptor = .{ .descriptor = selected.descriptor },
    };
}

fn selectReduction(request: EinsumSelectionRequest) ?SelectedEinsumKernel {
    if (request.schedule != null) return null;
    const kind = reductionKind(request) orelse return null;
    var inputs: [2]library.ReductionOperand = undefined;
    for (request.inputs, 0..) |input, index| {
        inputs[index] = .{
            .indices = input.indices,
            .dims = input.dims,
        };
    }
    const descriptor = library.select(.{ .reduction = .{
        .dtype = request.dtype,
        .kind = kind,
        .inputs = inputs[0..request.inputs.len],
        .output_indices = request.output_indices,
        .output_dims = request.output_dims,
    } }) orelse return null;
    return .{
        .kind = reductionKernelKind(kind) orelse return null,
        .descriptor = descriptor,
    };
}

fn reductionKind(request: EinsumSelectionRequest) ?library.ReductionKind {
    if (request.output_indices.len != 0 or request.output_dims.len != 0) return null;
    return switch (request.inputs.len) {
        1 => if (request.inputs[0].indices.len == 1) .sum else null,
        2 => if (request.inputs[0].indices.len == 1 and
            request.inputs[1].indices.len == 1 and
            request.inputs[0].indices[0] == request.inputs[1].indices[0])
            .dot_product
        else
            null,
        else => null,
    };
}

fn reductionKernelKind(kind: library.ReductionKind) ?EinsumKernelKind {
    return switch (kind) {
        .sum => .sum_reduction,
        .dot_product => .dot_product,
        else => null,
    };
}

fn selectBatchedMatrixProduct(request: EinsumSelectionRequest) ?SelectedEinsumKernel {
    if (request.inputs.len != 2) return null;
    if (!scheduleAllowsBatchedMatrixProduct(request.schedule)) return null;
    const descriptor = library.select(.{ .batched_matrix_product = .{
        .dtype = request.dtype,
        .lhs_indices = request.inputs[0].indices,
        .rhs_indices = request.inputs[1].indices,
        .output_indices = request.output_indices,
        .lhs_dims = request.inputs[0].dims,
        .rhs_dims = request.inputs[1].dims,
        .output_dims = request.output_dims,
        .schedule = batchedMatrixProductSchedule(request.schedule),
    } }) orelse return null;
    return .{
        .kind = .batched_matrix_product,
        .descriptor = descriptor,
    };
}

fn selectOwnedBatchedMatrixProduct(backing_allocator: std.mem.Allocator, request: EinsumSelectionRequest) !?OwnedSelectedEinsumKernel {
    if (request.inputs.len != 2) return null;
    if (!scheduleAllowsBatchedMatrixProduct(request.schedule)) return null;
    var descriptor = (try library.selectOwned(backing_allocator, .{ .batched_matrix_product = .{
        .dtype = request.dtype,
        .lhs_indices = request.inputs[0].indices,
        .rhs_indices = request.inputs[1].indices,
        .output_indices = request.output_indices,
        .lhs_dims = request.inputs[0].dims,
        .rhs_dims = request.inputs[1].dims,
        .output_dims = request.output_dims,
        .schedule = batchedMatrixProductSchedule(request.schedule),
    } })) orelse return null;
    errdefer descriptor.deinit();
    return .{
        .kind = .batched_matrix_product,
        .descriptor = descriptor,
    };
}

fn selectMatrixProduct(request: EinsumSelectionRequest) ?SelectedEinsumKernel {
    if (request.inputs.len != 2) return null;
    if (!scheduleAllowsMatrixProduct(request.schedule)) return null;
    const descriptor = library.select(.{ .matrix_product = .{
        .dtype = request.dtype,
        .lhs_indices = request.inputs[0].indices,
        .rhs_indices = request.inputs[1].indices,
        .output_indices = request.output_indices,
        .lhs_dims = request.inputs[0].dims,
        .rhs_dims = request.inputs[1].dims,
        .output_dims = request.output_dims,
        .schedule = matrixProductSchedule(request.schedule),
    } }) orelse return null;
    return .{
        .kind = .matrix_product,
        .descriptor = descriptor,
    };
}

fn selectOwnedMatrixProduct(backing_allocator: std.mem.Allocator, request: EinsumSelectionRequest) !?OwnedSelectedEinsumKernel {
    if (request.inputs.len != 2) return null;
    if (!scheduleAllowsMatrixProduct(request.schedule)) return null;
    var descriptor = (try library.selectOwned(backing_allocator, .{ .matrix_product = .{
        .dtype = request.dtype,
        .lhs_indices = request.inputs[0].indices,
        .rhs_indices = request.inputs[1].indices,
        .output_indices = request.output_indices,
        .lhs_dims = request.inputs[0].dims,
        .rhs_dims = request.inputs[1].dims,
        .output_dims = request.output_dims,
        .schedule = matrixProductSchedule(request.schedule),
    } })) orelse return null;
    errdefer descriptor.deinit();
    return .{
        .kind = .matrix_product,
        .descriptor = descriptor,
    };
}

fn selectMatrixVectorProduct(request: EinsumSelectionRequest) ?SelectedEinsumKernel {
    if (request.inputs.len != 2) return null;
    if (!scheduleAllowsMatrixVectorProduct(request.schedule)) return null;
    const descriptor = library.select(.{ .matrix_vector_product = .{
        .dtype = request.dtype,
        .matrix_indices = request.inputs[0].indices,
        .vector_indices = request.inputs[1].indices,
        .output_indices = request.output_indices,
        .matrix_dims = request.inputs[0].dims,
        .vector_dims = request.inputs[1].dims,
        .output_dims = request.output_dims,
        .schedule = matrixVectorProductSchedule(request.schedule),
    } }) orelse return null;
    return .{
        .kind = .matrix_vector_product,
        .descriptor = descriptor,
    };
}

fn selectOwnedMatrixVectorProduct(backing_allocator: std.mem.Allocator, request: EinsumSelectionRequest) !?OwnedSelectedEinsumKernel {
    if (request.inputs.len != 2) return null;
    if (!scheduleAllowsMatrixVectorProduct(request.schedule)) return null;
    var descriptor = (try library.selectOwned(backing_allocator, .{ .matrix_vector_product = .{
        .dtype = request.dtype,
        .matrix_indices = request.inputs[0].indices,
        .vector_indices = request.inputs[1].indices,
        .output_indices = request.output_indices,
        .matrix_dims = request.inputs[0].dims,
        .vector_dims = request.inputs[1].dims,
        .output_dims = request.output_dims,
        .schedule = matrixVectorProductSchedule(request.schedule),
    } })) orelse return null;
    errdefer descriptor.deinit();
    return .{
        .kind = .matrix_vector_product,
        .descriptor = descriptor,
    };
}

fn selectOuterProduct(request: EinsumSelectionRequest) ?SelectedEinsumKernel {
    if (request.inputs.len != 2) return null;
    if (!scheduleAllowsOuterProduct(request.schedule)) return null;
    const descriptor = library.select(.{ .outer_product = .{
        .dtype = request.dtype,
        .lhs_indices = request.inputs[0].indices,
        .rhs_indices = request.inputs[1].indices,
        .output_indices = request.output_indices,
        .lhs_dims = request.inputs[0].dims,
        .rhs_dims = request.inputs[1].dims,
        .output_dims = request.output_dims,
        .schedule = outerProductSchedule(request.schedule),
    } }) orelse return null;
    return .{
        .kind = .outer_product,
        .descriptor = descriptor,
    };
}

fn selectOwnedOuterProduct(backing_allocator: std.mem.Allocator, request: EinsumSelectionRequest) !?OwnedSelectedEinsumKernel {
    if (request.inputs.len != 2) return null;
    if (!scheduleAllowsOuterProduct(request.schedule)) return null;
    var descriptor = (try library.selectOwned(backing_allocator, .{ .outer_product = .{
        .dtype = request.dtype,
        .lhs_indices = request.inputs[0].indices,
        .rhs_indices = request.inputs[1].indices,
        .output_indices = request.output_indices,
        .lhs_dims = request.inputs[0].dims,
        .rhs_dims = request.inputs[1].dims,
        .output_dims = request.output_dims,
        .schedule = outerProductSchedule(request.schedule),
    } })) orelse return null;
    errdefer descriptor.deinit();
    return .{
        .kind = .outer_product,
        .descriptor = descriptor,
    };
}

fn scheduleAllowsMatrixProduct(schedule: ?EinsumSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .batched_matrix_product => false,
        .matrix_product => true,
        .matrix_vector_product => false,
        .outer_product => false,
    };
}

fn scheduleAllowsMatrixVectorProduct(schedule: ?EinsumSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .batched_matrix_product => false,
        .matrix_product => false,
        .matrix_vector_product => true,
        .outer_product => false,
    };
}

fn scheduleAllowsBatchedMatrixProduct(schedule: ?EinsumSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .batched_matrix_product => true,
        .matrix_product => false,
        .matrix_vector_product => false,
        .outer_product => false,
    };
}

fn scheduleAllowsOuterProduct(schedule: ?EinsumSchedule) bool {
    const requested = schedule orelse return true;
    return switch (requested) {
        .batched_matrix_product => false,
        .matrix_product => false,
        .matrix_vector_product => false,
        .outer_product => true,
    };
}

fn batchedMatrixProductSchedule(schedule: ?EinsumSchedule) ?library.BatchedMatrixProductSchedule {
    const requested = schedule orelse return null;
    return switch (requested) {
        .batched_matrix_product => |batched_matrix_product| batched_matrix_product,
        .matrix_product => null,
        .matrix_vector_product => null,
        .outer_product => null,
    };
}

fn matrixProductSchedule(schedule: ?EinsumSchedule) ?library.MatrixProductSchedule {
    const requested = schedule orelse return null;
    return switch (requested) {
        .batched_matrix_product => null,
        .matrix_product => |matrix_product| matrix_product,
        .matrix_vector_product => null,
        .outer_product => null,
    };
}

fn matrixVectorProductSchedule(schedule: ?EinsumSchedule) ?library.MatrixVectorProductSchedule {
    const requested = schedule orelse return null;
    return switch (requested) {
        .batched_matrix_product => null,
        .matrix_product => null,
        .matrix_vector_product => |matrix_vector_product| matrix_vector_product,
        .outer_product => null,
    };
}

fn outerProductSchedule(schedule: ?EinsumSchedule) ?library.OuterProductSchedule {
    const requested = schedule orelse return null;
    return switch (requested) {
        .batched_matrix_product => null,
        .matrix_product => null,
        .matrix_vector_product => null,
        .outer_product => |outer_product| outer_product,
    };
}

fn selectTranspose(request: EinsumSelectionRequest) ?SelectedEinsumKernel {
    if (request.inputs.len != 1) return null;
    if (request.schedule != null) return null;
    const descriptor = library.select(.{ .layout = .{
        .dtype = request.dtype,
        .kind = .transpose,
        .input_indices = request.inputs[0].indices,
        .output_indices = request.output_indices,
        .input_dims = request.inputs[0].dims,
        .output_dims = request.output_dims,
    } }) orelse return null;
    return .{
        .kind = .transpose,
        .descriptor = descriptor,
    };
}

test "logical einsum selection chooses scalar sum reduction catalog entry" {
    const input_dims = [_]i64{8};
    const output_dims = [_]i64{};
    const inputs = [_]EinsumOperand{
        .{ .indices = "i", .dims = &input_dims },
    };

    const selected = selectCatalog(.{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "",
        .output_dims = &output_dims,
    }) orelse return error.TestExpectedReductionSelection;

    try std.testing.expectEqual(EinsumKernelKind.sum_reduction, selected.kind);
    try std.testing.expectEqualStrings(library.reduction.Sum8F32.target, selected.descriptor.metadata.target);
}

test "logical einsum selection chooses scalar dot product catalog entry" {
    const input_dims = [_]i64{8};
    const output_dims = [_]i64{};
    const inputs = [_]EinsumOperand{
        .{ .indices = "i", .dims = &input_dims },
        .{ .indices = "i", .dims = &input_dims },
    };

    const selected = selectCatalog(.{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "",
        .output_dims = &output_dims,
    }) orelse return error.TestExpectedDotProductSelection;

    try std.testing.expectEqual(EinsumKernelKind.dot_product, selected.kind);
    try std.testing.expectEqualStrings(library.reduction.Dot8F32.target, selected.descriptor.metadata.target);
}

test "logical einsum selection chooses matrix product catalog entry" {
    const lhs_dims = [_]i64{ 4, 8 };
    const rhs_dims = [_]i64{ 8, 16 };
    const output_dims = [_]i64{ 4, 16 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "ik", .dims = &lhs_dims },
        .{ .indices = "kj", .dims = &rhs_dims },
    };

    const selected = selectCatalog(.{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "ij",
        .output_dims = &output_dims,
    }) orelse return error.TestExpectedMatrixProductSelection;

    try std.testing.expectEqual(EinsumKernelKind.matrix_product, selected.kind);
    try std.testing.expectEqualStrings(library.linalg.MatrixProduct4x16x8F32.target, selected.descriptor.metadata.target);
}

test "logical einsum owned selection chooses batched matrix product family at catalog smoke extents" {
    const lhs_dims = [_]i64{ 2, 2, 4 };
    const rhs_dims = [_]i64{ 2, 4, 3 };
    const output_dims = [_]i64{ 2, 2, 3 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "bmk", .dims = &lhs_dims },
        .{ .indices = "bkn", .dims = &rhs_dims },
    };
    const request = EinsumSelectionRequest{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "bmn",
        .output_dims = &output_dims,
    };

    try std.testing.expect(selectCatalog(request) == null);
    var selected = (try selectOwnedCatalog(std.testing.allocator, request)) orelse return error.TestExpectedBatchedMatrixProductSelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.batched_matrix_product, selected.kind);
    try std.testing.expect(selected.descriptor.specialization != null);
    try std.testing.expectEqualStrings("accy.kernel.linalg.batched_matmul_family_3x2x2_f32", selected.descriptor.descriptor.metadata.target);
    try std.testing.expect(specialization.shape_family != null);
}

test "logical einsum owned selection chooses batched matrix product family schedule at catalog smoke extents" {
    const lhs_dims = [_]i64{ 2, 2, 4 };
    const rhs_dims = [_]i64{ 2, 4, 3 };
    const output_dims = [_]i64{ 2, 2, 3 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "bmk", .dims = &lhs_dims },
        .{ .indices = "bkn", .dims = &rhs_dims },
    };
    const request = EinsumSelectionRequest{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "bmn",
        .output_dims = &output_dims,
        .schedule = .{ .batched_matrix_product = .{ .thread_blocks = .{ .x = 3, .y = 2, .z = 2 } } },
    };

    try std.testing.expect(selectCatalog(request) == null);
    var selected = (try selectOwnedCatalog(std.testing.allocator, request)) orelse return error.TestExpectedBatchedMatrixProductScheduleSelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.batched_matrix_product, selected.kind);
    try std.testing.expect(selected.descriptor.specialization != null);
    try std.testing.expectEqualStrings("accy.kernel.linalg.batched_matmul_family_3x2x2_f32", selected.descriptor.descriptor.metadata.target);
    try std.testing.expectEqual(@as(u32, 3), specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[1]);
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[2]);
}

test "logical einsum owned selection chooses batched matrix product family" {
    const lhs_dims = [_]i64{ 3, 5, 4 };
    const rhs_dims = [_]i64{ 3, 4, 6 };
    const output_dims = [_]i64{ 3, 5, 6 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "bmk", .dims = &lhs_dims },
        .{ .indices = "bkn", .dims = &rhs_dims },
    };

    var selected = (try selectOwnedCatalog(std.testing.allocator, .{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "bmn",
        .output_dims = &output_dims,
    })) orelse return error.TestExpectedBatchedMatrixProductFamilySelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.batched_matrix_product, selected.kind);
    try std.testing.expectEqualStrings("accy.kernel.linalg.batched_matmul_family_6x5x3_f32", selected.descriptor.descriptor.metadata.target);
    try std.testing.expect(specialization.shape_family != null);
    try std.testing.expectEqual(@as(u32, 6), specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 5), specialization.launch.?.threadgroup[1]);
    try std.testing.expectEqual(@as(u32, 3), specialization.launch.?.threadgroup[2]);
}

test "logical einsum owned selection chooses batched matrix product family schedule" {
    const lhs_dims = [_]i64{ 3, 5, 4 };
    const rhs_dims = [_]i64{ 3, 4, 6 };
    const output_dims = [_]i64{ 3, 5, 6 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "bmk", .dims = &lhs_dims },
        .{ .indices = "bkn", .dims = &rhs_dims },
    };

    var selected = (try selectOwnedCatalog(std.testing.allocator, .{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "bmn",
        .output_dims = &output_dims,
        .schedule = .{ .batched_matrix_product = .{ .thread_blocks = .{ .x = 4, .y = 2, .z = 2 } } },
    })) orelse return error.TestExpectedBatchedMatrixProductFamilyScheduleSelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.batched_matrix_product, selected.kind);
    try std.testing.expectEqualStrings("accy.kernel.linalg.batched_matmul_family_4x2x2_f32", selected.descriptor.descriptor.metadata.target);
    try std.testing.expectEqual(@as(u32, 4), specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[1]);
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[2]);
}

test "logical einsum selection keeps attention-shaped pure einsum generic" {
    const query_dims = [_]i64{ 2, 2, 2 };
    const key_dims = [_]i64{ 2, 3, 2 };
    const value_dims = [_]i64{ 2, 3, 2 };
    const output_dims = [_]i64{ 2, 2, 2 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "bqh", .dims = &query_dims },
        .{ .indices = "bkh", .dims = &key_dims },
        .{ .indices = "bkv", .dims = &value_dims },
    };

    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "bqv",
        .output_dims = &output_dims,
    }) == null);
}

test "logical einsum selection chooses matrix product schedule specialization" {
    const lhs_dims = [_]i64{ 4, 8 };
    const rhs_dims = [_]i64{ 8, 16 };
    const output_dims = [_]i64{ 4, 16 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "ik", .dims = &lhs_dims },
        .{ .indices = "kj", .dims = &rhs_dims },
    };

    const selected = selectCatalog(.{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "ij",
        .output_dims = &output_dims,
        .schedule = .{ .matrix_product = .{ .thread_blocks = .{ .x = 4, .y = 2 } } },
    }) orelse return error.TestExpectedMatrixProductScheduleSelection;

    try std.testing.expectEqual(EinsumKernelKind.matrix_product, selected.kind);
    try std.testing.expectEqualStrings(library.linalg.MatrixProduct4x16x8ThreadBlocks4x2F32.target, selected.descriptor.metadata.target);
}

test "logical einsum owned selection preserves fixed matrix product descriptor" {
    const lhs_dims = [_]i64{ 4, 8 };
    const rhs_dims = [_]i64{ 8, 16 };
    const output_dims = [_]i64{ 4, 16 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "ik", .dims = &lhs_dims },
        .{ .indices = "kj", .dims = &rhs_dims },
    };

    var selected = (try selectOwnedCatalog(std.testing.allocator, .{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "ij",
        .output_dims = &output_dims,
    })) orelse return error.TestExpectedMatrixProductSelection;
    defer selected.deinit();

    try std.testing.expectEqual(EinsumKernelKind.matrix_product, selected.kind);
    try std.testing.expect(selected.descriptor.specialization == null);
    try std.testing.expectEqualStrings(library.linalg.MatrixProduct4x16x8F32.target, selected.descriptor.descriptor.metadata.target);
}

test "logical einsum owned selection chooses matrix product family descriptor" {
    const lhs_dims = [_]i64{ 5, 3 };
    const rhs_dims = [_]i64{ 3, 7 };
    const output_dims = [_]i64{ 5, 7 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "mk", .dims = &lhs_dims },
        .{ .indices = "kn", .dims = &rhs_dims },
    };
    const request = EinsumSelectionRequest{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "mn",
        .output_dims = &output_dims,
    };

    try std.testing.expect(selectCatalog(request) == null);
    var selected = (try selectOwnedCatalog(std.testing.allocator, request)) orelse return error.TestExpectedMatrixProductFamilySelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.matrix_product, selected.kind);
    try std.testing.expect(selected.descriptor.specialization != null);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matmul_family_7x5_f32", selected.descriptor.descriptor.metadata.target);
    try std.testing.expect(specialization.scheduleMatchesLaunch());
    try std.testing.expectEqual(@as(u32, 7), specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 5), specialization.launch.?.threadgroup[1]);
}

test "logical einsum owned selection chooses f16 matrix product family descriptor" {
    const lhs_dims = [_]i64{ 5, 3 };
    const rhs_dims = [_]i64{ 3, 7 };
    const output_dims = [_]i64{ 5, 7 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "mk", .dims = &lhs_dims },
        .{ .indices = "kn", .dims = &rhs_dims },
    };
    const request = EinsumSelectionRequest{
        .dtype = .f16,
        .inputs = &inputs,
        .output_indices = "mn",
        .output_dims = &output_dims,
    };

    try std.testing.expect(selectCatalog(request) == null);
    var selected = (try selectOwnedCatalog(std.testing.allocator, request)) orelse return error.TestExpectedMatrixProductFamilySelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.matrix_product, selected.kind);
    try std.testing.expect(selected.descriptor.specialization != null);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matmul_family_7x5_f16", selected.descriptor.descriptor.metadata.target);
    try std.testing.expectEqual(@as(?DType, .f16), specialization.dtype);
    try std.testing.expectEqual(@as(?DType, .f32), specialization.accumulation_dtype);
    try std.testing.expect(specialization.scheduleMatchesLaunch());
}

test "logical einsum owned selection chooses matrix product family schedule" {
    const lhs_dims = [_]i64{ 5, 3 };
    const rhs_dims = [_]i64{ 3, 7 };
    const output_dims = [_]i64{ 5, 7 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "mk", .dims = &lhs_dims },
        .{ .indices = "kn", .dims = &rhs_dims },
    };

    var selected = (try selectOwnedCatalog(std.testing.allocator, .{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "mn",
        .output_dims = &output_dims,
        .schedule = .{ .matrix_product = .{ .thread_blocks = .{ .x = 4, .y = 2 } } },
    })) orelse return error.TestExpectedMatrixProductFamilyScheduleSelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.matrix_product, selected.kind);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matmul_family_4x2_f32", selected.descriptor.descriptor.metadata.target);
    try std.testing.expectEqual(@as(u32, 4), specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[1]);
}

test "logical einsum owned selection chooses matrix vector product family at catalog smoke extents" {
    const matrix_dims = [_]i64{ 4, 8 };
    const vector_dims = [_]i64{8};
    const output_dims = [_]i64{4};
    const inputs = [_]EinsumOperand{
        .{ .indices = "mk", .dims = &matrix_dims },
        .{ .indices = "k", .dims = &vector_dims },
    };
    const request = EinsumSelectionRequest{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "m",
        .output_dims = &output_dims,
    };

    try std.testing.expect(selectCatalog(request) == null);
    var selected = (try selectOwnedCatalog(std.testing.allocator, request)) orelse return error.TestExpectedMatrixVectorProductSelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.matrix_vector_product, selected.kind);
    try std.testing.expect(selected.descriptor.specialization != null);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matvec_family_4x_f32", selected.descriptor.descriptor.metadata.target);
    try std.testing.expect(specialization.shape_family != null);
}

test "logical einsum owned selection chooses matrix vector product family descriptor" {
    const matrix_dims = [_]i64{ 5, 3 };
    const vector_dims = [_]i64{3};
    const output_dims = [_]i64{5};
    const inputs = [_]EinsumOperand{
        .{ .indices = "mk", .dims = &matrix_dims },
        .{ .indices = "k", .dims = &vector_dims },
    };
    const request = EinsumSelectionRequest{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "m",
        .output_dims = &output_dims,
    };

    try std.testing.expect(selectCatalog(request) == null);
    var selected = (try selectOwnedCatalog(std.testing.allocator, request)) orelse return error.TestExpectedMatrixVectorProductFamilySelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.matrix_vector_product, selected.kind);
    try std.testing.expect(selected.descriptor.specialization != null);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matvec_family_5x_f32", selected.descriptor.descriptor.metadata.target);
    try std.testing.expect(specialization.operationIs(.{ .linalg = .matrix_vector_product }));
    try std.testing.expect(specialization.scheduleMatchesLaunch());
    try std.testing.expectEqual(@as(u32, 5), specialization.launch.?.threadgroup[0]);
}

test "logical einsum owned selection chooses matrix vector product family schedule" {
    const matrix_dims = [_]i64{ 5, 3 };
    const vector_dims = [_]i64{3};
    const output_dims = [_]i64{5};
    const inputs = [_]EinsumOperand{
        .{ .indices = "mk", .dims = &matrix_dims },
        .{ .indices = "k", .dims = &vector_dims },
    };

    var selected = (try selectOwnedCatalog(std.testing.allocator, .{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "m",
        .output_dims = &output_dims,
        .schedule = .{ .matrix_vector_product = .{ .thread_blocks = 4 } },
    })) orelse return error.TestExpectedMatrixVectorProductFamilyScheduleSelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.matrix_vector_product, selected.kind);
    try std.testing.expectEqualStrings("accy.kernel.linalg.matvec_family_4x_f32", selected.descriptor.descriptor.metadata.target);
    try std.testing.expectEqual(@as(u32, 4), specialization.launch.?.threadgroup[0]);
}

test "logical einsum owned selection chooses outer product family at catalog smoke extents" {
    const lhs_dims = [_]i64{4};
    const rhs_dims = [_]i64{3};
    const output_dims = [_]i64{ 4, 3 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "m", .dims = &lhs_dims },
        .{ .indices = "n", .dims = &rhs_dims },
    };
    const request = EinsumSelectionRequest{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "mn",
        .output_dims = &output_dims,
    };

    try std.testing.expect(selectCatalog(request) == null);
    var selected = (try selectOwnedCatalog(std.testing.allocator, request)) orelse return error.TestExpectedOuterProductSelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.outer_product, selected.kind);
    try std.testing.expect(selected.descriptor.specialization != null);
    try std.testing.expectEqualStrings("accy.kernel.linalg.outer_family_3x4_f32", selected.descriptor.descriptor.metadata.target);
    try std.testing.expect(specialization.shape_family != null);
}

test "logical einsum owned selection chooses outer product family schedule at catalog smoke extents" {
    const lhs_dims = [_]i64{4};
    const rhs_dims = [_]i64{3};
    const output_dims = [_]i64{ 4, 3 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "m", .dims = &lhs_dims },
        .{ .indices = "n", .dims = &rhs_dims },
    };
    const request = EinsumSelectionRequest{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "mn",
        .output_dims = &output_dims,
        .schedule = .{ .outer_product = .{ .thread_blocks = .{ .x = 3, .y = 2 } } },
    };

    try std.testing.expect(selectCatalog(request) == null);
    var selected = (try selectOwnedCatalog(std.testing.allocator, request)) orelse return error.TestExpectedOuterProductScheduleSelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.outer_product, selected.kind);
    try std.testing.expect(selected.descriptor.specialization != null);
    try std.testing.expectEqualStrings("accy.kernel.linalg.outer_family_3x2_f32", selected.descriptor.descriptor.metadata.target);
    try std.testing.expectEqual(@as(u32, 3), specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[1]);
}

test "logical einsum owned selection chooses outer product family" {
    const lhs_dims = [_]i64{5};
    const rhs_dims = [_]i64{6};
    const output_dims = [_]i64{ 5, 6 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "m", .dims = &lhs_dims },
        .{ .indices = "n", .dims = &rhs_dims },
    };

    var selected = (try selectOwnedCatalog(std.testing.allocator, .{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "mn",
        .output_dims = &output_dims,
    })) orelse return error.TestExpectedOuterProductFamilySelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.outer_product, selected.kind);
    try std.testing.expectEqualStrings("accy.kernel.linalg.outer_family_6x5_f32", selected.descriptor.descriptor.metadata.target);
    try std.testing.expect(specialization.shape_family != null);
    try std.testing.expectEqual(@as(u32, 6), specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 5), specialization.launch.?.threadgroup[1]);
}

test "logical einsum owned selection chooses outer product family schedule" {
    const lhs_dims = [_]i64{5};
    const rhs_dims = [_]i64{6};
    const output_dims = [_]i64{ 5, 6 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "m", .dims = &lhs_dims },
        .{ .indices = "n", .dims = &rhs_dims },
    };

    var selected = (try selectOwnedCatalog(std.testing.allocator, .{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "mn",
        .output_dims = &output_dims,
        .schedule = .{ .outer_product = .{ .thread_blocks = .{ .x = 4, .y = 2 } } },
    })) orelse return error.TestExpectedOuterProductFamilyScheduleSelection;
    defer selected.deinit();
    const specialization = selected.descriptor.descriptor.metadata.specialization;

    try std.testing.expectEqual(EinsumKernelKind.outer_product, selected.kind);
    try std.testing.expectEqualStrings("accy.kernel.linalg.outer_family_4x2_f32", selected.descriptor.descriptor.metadata.target);
    try std.testing.expectEqual(@as(u32, 4), specialization.launch.?.threadgroup[0]);
    try std.testing.expectEqual(@as(u32, 2), specialization.launch.?.threadgroup[1]);
}

test "logical einsum selection chooses transpose catalog entry" {
    const input_dims = [_]i64{ 8, 16 };
    const output_dims = [_]i64{ 16, 8 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "ij", .dims = &input_dims },
    };

    const selected = selectCatalog(.{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "ji",
        .output_dims = &output_dims,
    }) orelse return error.TestExpectedTransposeSelection;

    try std.testing.expectEqual(EinsumKernelKind.transpose, selected.kind);
    try std.testing.expectEqualStrings(library.layout.Transpose8x16F32.target, selected.descriptor.metadata.target);
}

test "logical einsum selection rejects unknown catalog shape" {
    const lhs_dims = [_]i64{ 5, 8 };
    const rhs_dims = [_]i64{ 8, 16 };
    const output_dims = [_]i64{ 5, 16 };
    const inputs = [_]EinsumOperand{
        .{ .indices = "ik", .dims = &lhs_dims },
        .{ .indices = "kj", .dims = &rhs_dims },
    };

    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .inputs = &inputs,
        .output_indices = "ij",
        .output_dims = &output_dims,
    }) == null);

    const scalar_dims = [_]i64{};
    const mismatch_lhs_dims = [_]i64{8};
    const mismatch_rhs_dims = [_]i64{8};
    const mismatched_dot_inputs = [_]EinsumOperand{
        .{ .indices = "i", .dims = &mismatch_lhs_dims },
        .{ .indices = "j", .dims = &mismatch_rhs_dims },
    };
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .inputs = &mismatched_dot_inputs,
        .output_indices = "",
        .output_dims = &scalar_dims,
    }) == null);
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .inputs = mismatched_dot_inputs[0..1],
        .output_indices = "",
        .output_dims = &scalar_dims,
        .schedule = .{ .matrix_product = .{ .thread_blocks = .{ .x = 4, .y = 2 } } },
    }) == null);

    const matrix_product_lhs_dims = [_]i64{ 4, 8 };
    const matrix_product_rhs_dims = [_]i64{ 8, 16 };
    const matrix_product_output_dims = [_]i64{ 4, 16 };
    const matrix_product_inputs = [_]EinsumOperand{
        .{ .indices = "ik", .dims = &matrix_product_lhs_dims },
        .{ .indices = "kj", .dims = &matrix_product_rhs_dims },
    };
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .inputs = &matrix_product_inputs,
        .output_indices = "ij",
        .output_dims = &matrix_product_output_dims,
        .schedule = .{ .matrix_product = .{ .thread_blocks = .{ .x = 16, .y = 8 } } },
    }) == null);
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .inputs = &matrix_product_inputs,
        .output_indices = "ij",
        .output_dims = &matrix_product_output_dims,
        .schedule = .{ .matrix_vector_product = .{ .thread_blocks = 4 } },
    }) == null);

    const batched_lhs_dims = [_]i64{ 2, 2, 4 };
    const batched_rhs_dims = [_]i64{ 2, 4, 3 };
    const batched_output_dims = [_]i64{ 2, 2, 3 };
    const batched_inputs = [_]EinsumOperand{
        .{ .indices = "bmk", .dims = &batched_lhs_dims },
        .{ .indices = "bkn", .dims = &batched_rhs_dims },
    };
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .inputs = &batched_inputs,
        .output_indices = "bmn",
        .output_dims = &batched_output_dims,
        .schedule = .{ .batched_matrix_product = .{ .thread_blocks = .{ .x = 4, .y = 2, .z = 2 } } },
    }) == null);
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .inputs = &batched_inputs,
        .output_indices = "bmn",
        .output_dims = &batched_output_dims,
        .schedule = .{ .matrix_product = .{ .thread_blocks = .{ .x = 4, .y = 2 } } },
    }) == null);

    const outer_lhs_dims = [_]i64{4};
    const outer_rhs_dims = [_]i64{3};
    const outer_output_dims = [_]i64{ 4, 3 };
    const outer_inputs = [_]EinsumOperand{
        .{ .indices = "m", .dims = &outer_lhs_dims },
        .{ .indices = "n", .dims = &outer_rhs_dims },
    };
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .inputs = &outer_inputs,
        .output_indices = "mn",
        .output_dims = &outer_output_dims,
        .schedule = .{ .outer_product = .{ .thread_blocks = .{ .x = 4, .y = 2 } } },
    }) == null);
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .inputs = &outer_inputs,
        .output_indices = "mn",
        .output_dims = &outer_output_dims,
        .schedule = .{ .matrix_product = .{ .thread_blocks = .{ .x = 4, .y = 2 } } },
    }) == null);

    const transpose_input_dims = [_]i64{ 8, 16 };
    const transpose_output_dims = [_]i64{ 16, 8 };
    const transpose_inputs = [_]EinsumOperand{
        .{ .indices = "ij", .dims = &transpose_input_dims },
    };
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .inputs = &transpose_inputs,
        .output_indices = "ji",
        .output_dims = &transpose_output_dims,
        .schedule = .{ .matrix_vector_product = .{ .thread_blocks = 4 } },
    }) == null);

    const attention_query_dims = [_]i64{ 2, 2, 2 };
    const attention_key_dims = [_]i64{ 2, 3, 2 };
    const attention_value_dims = [_]i64{ 2, 3, 2 };
    const attention_output_dims = [_]i64{ 2, 2, 2 };
    const attention_inputs = [_]EinsumOperand{
        .{ .indices = "bqh", .dims = &attention_query_dims },
        .{ .indices = "bkh", .dims = &attention_key_dims },
        .{ .indices = "bkv", .dims = &attention_value_dims },
    };
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .inputs = &attention_inputs,
        .output_indices = "bqv",
        .output_dims = &attention_output_dims,
        .schedule = .{ .matrix_product = .{ .thread_blocks = .{ .x = 4, .y = 2 } } },
    }) == null);
}
