const std = @import("std");
const gpu_abi = @import("gpu_abi");

const descriptor_mod = @import("../../root.zig");
const geometry = @import("../../../root.zig").geometry;
const linalg = @import("../../../root.zig").linalg;
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const MatrixProductQuery = query_mod.MatrixProductQuery;
const MatrixProductSchedule = query_mod.MatrixProductSchedule;

pub const MatrixProductCandidateDescriptors = struct {
    count: usize = 0,
    items: [geometry.max_thread_candidates]OwnedDescriptor = undefined,

    pub fn slice(self: *const MatrixProductCandidateDescriptors) []const OwnedDescriptor {
        return self.items[0..self.count];
    }

    pub fn deinit(self: *MatrixProductCandidateDescriptors) void {
        for (self.items[0..self.count]) |*descriptor| descriptor.deinit();
        self.* = undefined;
    }
};

pub fn selectMatrixProduct(
    backing_allocator: std.mem.Allocator,
    query: MatrixProductQuery,
) !?OwnedDescriptor {
    const accumulation_dtype = linalg.matrixProductAccumulationDType(query.dtype) orelse
        return null;
    if (!match_mod.canonicalMatrixProduct(query)) return null;
    const shape = match_mod.matrixProductShape(
        query.lhs_dims,
        query.rhs_dims,
        query.output_dims,
    ) orelse return null;
    const instance = matrixProductFamilyInstance(
        shape,
        query.schedule,
        query.dtype,
        accumulation_dtype,
    ) orelse return null;
    return try matrixProductDescriptorForInstance(
        backing_allocator,
        instance,
        shape,
        query.schedule,
        query.dtype,
    );
}

pub fn selectMatrixProductCandidates(
    backing_allocator: std.mem.Allocator,
    query: MatrixProductQuery,
) !MatrixProductCandidateDescriptors {
    var result = MatrixProductCandidateDescriptors{};
    errdefer result.deinit();

    const accumulation_dtype = linalg.matrixProductAccumulationDType(query.dtype) orelse
        return result;
    if (!match_mod.canonicalMatrixProduct(query)) return result;
    const shape = match_mod.matrixProductShape(
        query.lhs_dims,
        query.rhs_dims,
        query.output_dims,
    ) orelse return result;
    if (query.schedule != null) {
        if (try selectMatrixProduct(backing_allocator, query)) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
        return result;
    }

    const thread_candidates = linalg.matrixProductThreadCandidatesForExtents(shape.m, shape.n);
    for (thread_candidates.slice()) |threads| {
        const instance = linalg.MatrixProduct{
            .m = shape.m,
            .n = shape.n,
            .k = shape.k,
            .dtype = query.dtype,
            .accumulation_dtype = accumulation_dtype,
            .threads = threads,
        };
        if (try matrixProductDescriptorForInstance(
            backing_allocator,
            instance,
            shape,
            null,
            query.dtype,
        )) |descriptor| {
            result.items[result.count] = descriptor;
            result.count += 1;
        }
    }
    return result;
}

fn matrixProductDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: linalg.MatrixProduct,
    shape: match_mod.MatrixProductShape,
    schedule: ?MatrixProductSchedule,
    dtype: gpu_abi.DType,
) !?OwnedDescriptor {
    var specialization = try linalg.matrixProductFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try linalg.matrixProductFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try linalg.matrixProductFamilyTarget(lifetime_allocator, instance),
            .version = linalg.matrix_product_family_version,
            .layer = .logical,
            .category = .linalg,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.matrixProductDescriptorMatches(descriptor, shape, schedule, dtype)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn matrixProductFamilyInstance(
    shape: match_mod.MatrixProductShape,
    schedule: ?MatrixProductSchedule,
    dtype: gpu_abi.DType,
    accumulation_dtype: gpu_abi.DType,
) ?linalg.MatrixProduct {
    var instance = linalg.MatrixProduct{
        .m = shape.m,
        .n = shape.n,
        .k = shape.k,
        .dtype = dtype,
        .accumulation_dtype = accumulation_dtype,
        .threads = linalg.matrixProductThreadsForExtents(shape.m, shape.n),
    };
    if (schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads.x == 0 or threads.y == 0) return null;
                instance.threads = threads;
            },
        }
    }
    return instance;
}
