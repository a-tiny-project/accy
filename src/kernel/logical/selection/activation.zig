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

test "logical activation selection chooses catalog entries" {
    const gelu = selectCatalog(.{
        .dtype = .f32,
        .kind = .gelu,
        .extent = 8,
    }) orelse return error.TestExpectedGeluSelection;
    const relu = selectCatalog(.{
        .dtype = .f32,
        .kind = .relu,
        .extent = 8,
    }) orelse return error.TestExpectedReluSelection;
    const silu = selectCatalog(.{
        .dtype = .f32,
        .kind = .silu,
        .extent = 8,
    }) orelse return error.TestExpectedSiluSelection;

    try std.testing.expectEqual(ActivationKind.gelu, gelu.kind);
    try std.testing.expectEqualStrings(
        library.elementwise.Gelu8F32.target,
        gelu.descriptor.metadata.target,
    );
    try std.testing.expectEqual(ActivationKind.relu, relu.kind);
    try std.testing.expectEqualStrings(
        library.elementwise.Relu8F32.target,
        relu.descriptor.metadata.target,
    );
    try std.testing.expectEqual(ActivationKind.silu, silu.kind);
    try std.testing.expectEqualStrings(
        library.elementwise.Silu8F32.target,
        silu.descriptor.metadata.target,
    );
}

test "logical activation selection rejects unavailable catalog entry" {
    try std.testing.expect(selectCatalog(.{
        .dtype = .i32,
        .kind = .silu,
        .extent = 8,
    }) == null);
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .kind = .gelu,
        .extent = 16,
    }) == null);
    try std.testing.expect(selectCatalog(.{
        .dtype = .i32,
        .kind = .relu,
        .extent = 8,
    }) == null);
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .kind = .relu,
        .extent = 0,
    }) == null);
    try std.testing.expect(selectCatalog(.{
        .dtype = .f32,
        .kind = .silu,
        .extent = 0,
    }) == null);
}
