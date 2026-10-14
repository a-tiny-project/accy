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

pub fn selectOwnedCatalog(
    backing_allocator: std.mem.Allocator,
    request: EinsumSelectionRequest,
) !?OwnedSelectedEinsumKernel {
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

fn selectOwnedBatchedMatrixProduct(
    backing_allocator: std.mem.Allocator,
    request: EinsumSelectionRequest,
) !?OwnedSelectedEinsumKernel {
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

fn selectOwnedMatrixProduct(
    backing_allocator: std.mem.Allocator,
    request: EinsumSelectionRequest,
) !?OwnedSelectedEinsumKernel {
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

fn selectOwnedMatrixVectorProduct(
    backing_allocator: std.mem.Allocator,
    request: EinsumSelectionRequest,
) !?OwnedSelectedEinsumKernel {
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

fn selectOwnedOuterProduct(
    backing_allocator: std.mem.Allocator,
    request: EinsumSelectionRequest,
) !?OwnedSelectedEinsumKernel {
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
