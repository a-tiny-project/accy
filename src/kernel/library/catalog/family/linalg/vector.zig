const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const linalg = @import("../../../root.zig").linalg;
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const MatrixVectorProductQuery = query_mod.MatrixVectorProductQuery;
const MatrixVectorProductSchedule = query_mod.MatrixVectorProductSchedule;

pub fn selectMatrixVectorProduct(
    backing_allocator: std.mem.Allocator,
    query: MatrixVectorProductQuery,
) !?OwnedDescriptor {
    if (query.dtype != .f32) return null;
    if (!match_mod.canonicalMatrixVectorProduct(query)) return null;
    const shape = match_mod.matrixVectorProductShape(
        query.matrix_dims,
        query.vector_dims,
        query.output_dims,
    ) orelse return null;
    const instance = matrixVectorProductFamilyInstance(shape, query.schedule) orelse return null;
    return try matrixVectorProductDescriptorForInstance(
        backing_allocator,
        instance,
        shape,
        query.schedule,
    );
}

fn matrixVectorProductDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: linalg.MatrixVectorProduct,
    shape: match_mod.MatrixVectorProductShape,
    schedule: ?MatrixVectorProductSchedule,
) !?OwnedDescriptor {
    var specialization = try linalg.matrixVectorProductFamilySpecialization(
        backing_allocator,
        instance,
    );
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try linalg.matrixVectorProductFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try linalg.matrixVectorProductFamilyTarget(lifetime_allocator, instance),
            .version = linalg.matrix_vector_product_family_version,
            .layer = .logical,
            .category = .linalg,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.matrixVectorProductDescriptorMatches(descriptor, shape, schedule)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn matrixVectorProductFamilyInstance(
    shape: match_mod.MatrixVectorProductShape,
    schedule: ?MatrixVectorProductSchedule,
) ?linalg.MatrixVectorProduct {
    var instance = linalg.MatrixVectorProduct{
        .m = shape.m,
        .k = shape.k,
        .threads = linalg.matrixVectorProductThreadsForExtents(shape.m),
    };
    if (schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                instance.threads = threads;
            },
        }
    }
    return instance;
}
