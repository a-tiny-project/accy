const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const linalg = @import("../../../root.zig").linalg;
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const BatchedMatrixProductQuery = query_mod.BatchedMatrixProductQuery;
const BatchedMatrixProductSchedule = query_mod.BatchedMatrixProductSchedule;

pub fn selectBatchedMatrixProduct(backing_allocator: std.mem.Allocator, query: BatchedMatrixProductQuery) !?OwnedDescriptor {
    if (query.dtype != .f32) return null;
    if (!match_mod.canonicalBatchedMatrixProduct(query)) return null;
    const shape = match_mod.batchedMatrixProductShape(query.lhs_dims, query.rhs_dims, query.output_dims) orelse return null;
    const instance = batchedMatrixProductFamilyInstance(shape, query.schedule) orelse return null;
    return try batchedMatrixProductDescriptorForInstance(backing_allocator, instance, shape, query.schedule);
}

fn batchedMatrixProductDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: linalg.BatchedMatrixProduct,
    shape: match_mod.BatchedMatrixProductShape,
    schedule: ?BatchedMatrixProductSchedule,
) !?OwnedDescriptor {
    var specialization = try linalg.batchedMatrixProductFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try linalg.batchedMatrixProductFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try linalg.batchedMatrixProductFamilyTarget(lifetime_allocator, instance),
            .version = linalg.batched_matrix_product_family_version,
            .layer = .logical,
            .category = .linalg,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.batchedMatrixProductDescriptorMatches(descriptor, shape, schedule)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn batchedMatrixProductFamilyInstance(
    shape: match_mod.BatchedMatrixProductShape,
    schedule: ?BatchedMatrixProductSchedule,
) ?linalg.BatchedMatrixProduct {
    var instance = linalg.BatchedMatrixProduct{
        .batch = shape.batch,
        .m = shape.m,
        .n = shape.n,
        .k = shape.k,
        .threads = linalg.batchedMatrixProductThreadsForExtents(shape.batch, shape.m, shape.n),
    };
    if (schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads.x == 0 or threads.y == 0 or threads.z == 0) return null;
                instance.threads = threads;
            },
        }
    }
    return instance;
}
