const std = @import("std");
const gpu_abi = @import("gpu_abi");

const activation = @import("../../../choir/root.zig").activation;
const library = @import("../../library/root.zig");

const DType = gpu_abi.DType;

pub const ActivationKind = activation.Kind;

pub const ActivationSelectionRequest = struct {
    dtype: DType,
    kind: ActivationKind,
    extent: u64,
};

pub const SelectedActivationKernel = struct {
    kind: ActivationKind,
    descriptor: library.CatalogDescriptor,
};

pub fn selectCatalog(request: ActivationSelectionRequest) ?SelectedActivationKernel {
    const descriptor = library.select(.{ .activation = .{
        .dtype = request.dtype,
        .kind = request.kind,
        .extent = request.extent,
    } }) orelse return null;
    return .{
        .kind = request.kind,
        .descriptor = descriptor,
    };
}
