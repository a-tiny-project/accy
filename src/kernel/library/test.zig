const std = @import("std");
const gpu = @import("gpu");
const library = @import("root.zig");

const artifact = @import("../../artifact/root.zig");
const entry = library.entry;
const linalg = library.linalg;
const createKernelCallArtifact = library.createKernelCallArtifact;

test {
    _ = @import("catalog/test.zig");
    _ = @import("histogram/test.zig");
    _ = @import("random/test.zig");
    @import("test_discovery").discover(library);
}

test "kernel library family artifacts round-trip through the wire registry" {
    const allocator = std.testing.allocator;
    var state = gpu.recording.BackendState{
        .allocator = allocator,
        .kind = .cuda,
        .format = .cuda_ptx,
    };

    const instance = linalg.MatrixProduct{ .m = 5, .n = 7, .k = 3, .threads = .{ .x = 4, .y = 2 } };
    var family_artifact = try linalg.createMatrixProductFamilyArtifact(
        allocator,
        state.handle(),
        instance,
        .{ .limits = .testing },
    );
    defer family_artifact.deinit();
    var fixed_artifact = try linalg.MatrixProduct2x3x4F32.createKernelCallArtifact(
        allocator,
        state.handle(),
        .{ .limits = linalg.MatrixProduct2x3x4F32.Limits.testing },
    );
    defer fixed_artifact.deinit();

    const entries = [_]artifact.KernelCallArtifact{
        family_artifact.entry(),
        fixed_artifact.entry(),
    };
    const encoded = try artifact.wire.encode(allocator, entries[0..], &.{});
    defer allocator.free(encoded);

    var decoded = try artifact.wire.decode(allocator, encoded);
    defer decoded.deinit();

    const family_entry = decoded.registry().find(
        "accy.kernel.linalg.matmul_family_4x2_f32",
        linalg.matrix_product_family_version,
        .cuda_ptx,
    ) orelse return error.TestExpectedFamilyArtifact;
    try std.testing.expectEqualDeep(family_artifact.entry(), family_entry);

    const fixed_entry = decoded.registry().find(
        linalg.MatrixProduct2x3x4F32.target,
        linalg.MatrixProduct2x3x4F32.version,
        .cuda_ptx,
    ) orelse return error.TestExpectedFixedArtifact;
    try std.testing.expectEqualDeep(fixed_artifact.entry(), fixed_entry);
}

test "accy kernel library declaration coverage" {
    std.testing.refAllDecls(library);
}
