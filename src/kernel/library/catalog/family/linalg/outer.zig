const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const linalg = @import("../../../root.zig").linalg;
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const OuterProductQuery = query_mod.OuterProductQuery;
const OuterProductSchedule = query_mod.OuterProductSchedule;

pub fn selectOuterProduct(backing_allocator: std.mem.Allocator, query: OuterProductQuery) !?OwnedDescriptor {
    if (query.dtype != .f32) return null;
    if (!match_mod.canonicalOuterProduct(query)) return null;
    const shape = match_mod.outerProductShape(query.lhs_dims, query.rhs_dims, query.output_dims) orelse return null;
    const instance = outerProductFamilyInstance(shape, query.schedule) orelse return null;
    return try outerProductDescriptorForInstance(backing_allocator, instance, shape, query.schedule);
}

fn outerProductDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    instance: linalg.OuterProduct,
    shape: match_mod.OuterProductShape,
    schedule: ?OuterProductSchedule,
) !?OwnedDescriptor {
    var specialization = try linalg.outerProductFamilySpecialization(backing_allocator, instance);
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try linalg.outerProductFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try linalg.outerProductFamilyTarget(lifetime_allocator, instance),
            .version = linalg.outer_product_family_version,
            .layer = .logical,
            .category = .linalg,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.outerProductDescriptorMatches(descriptor, shape, schedule)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

fn outerProductFamilyInstance(
    shape: match_mod.OuterProductShape,
    schedule: ?OuterProductSchedule,
) ?linalg.OuterProduct {
    var instance = linalg.OuterProduct{
        .m = shape.m,
        .n = shape.n,
        .threads = linalg.outerProductThreadsForExtents(shape.m, shape.n),
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
