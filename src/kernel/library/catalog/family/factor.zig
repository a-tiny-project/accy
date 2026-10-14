const std = @import("std");

const descriptor_mod = @import("../root.zig");
const factor_mod = @import("../../root.zig").factor;
const match_mod = @import("../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const FactorQuery = query_mod.FactorQuery;

pub fn selectFactor(backing_allocator: std.mem.Allocator, query: FactorQuery) !?OwnedDescriptor {
    if (query.dtype != .f32) return null;
    const threads = factorQueryThreads(query) orelse return null;
    switch (query.kind) {
        .batched_cholesky => |facts| {
            const instance = factor_mod.BatchedCholesky{
                .batch = facts.batch,
                .n = facts.n,
                .threads = threads,
                .layout = factorInstanceLayout(query.layout),
            };
            if (!factor_mod.batchedCholeskyInstanceValid(instance)) return null;
            var specialization = try factor_mod.batchedCholeskyFamilySpecialization(
                backing_allocator,
                instance,
            );
            errdefer specialization.deinit();
            const lifetime_allocator = specialization.allocator();
            const descriptor = Descriptor{
                .name = try factor_mod.batchedCholeskyFamilyEntryName(lifetime_allocator, instance),
                .metadata = .{
                    .target = try factor_mod.batchedCholeskyFamilyTarget(
                        lifetime_allocator,
                        instance,
                    ),
                    .version = factor_mod.batched_cholesky_family_version,
                    .layer = .logical,
                    .category = .linalg,
                    .specialization = specialization.value,
                },
            };
            if (!match_mod.factorDescriptorMatches(descriptor, query)) {
                specialization.deinit();
                return null;
            }
            return .{ .descriptor = descriptor, .specialization = specialization };
        },
        .batched_cholesky_solve => |facts| {
            const instance = factor_mod.BatchedCholeskySolve{
                .batch = facts.batch,
                .n = facts.n,
                .threads = threads,
                .layout = factorInstanceLayout(query.layout),
            };
            if (!factor_mod.batchedCholeskySolveInstanceValid(instance)) return null;
            var specialization = try factor_mod.batchedCholeskySolveFamilySpecialization(
                backing_allocator,
                instance,
            );
            errdefer specialization.deinit();
            const lifetime_allocator = specialization.allocator();
            const descriptor = Descriptor{
                .name = try factor_mod.batchedCholeskySolveFamilyEntryName(
                    lifetime_allocator,
                    instance,
                ),
                .metadata = .{
                    .target = try factor_mod.batchedCholeskySolveFamilyTarget(
                        lifetime_allocator,
                        instance,
                    ),
                    .version = factor_mod.batched_cholesky_solve_family_version,
                    .layer = .logical,
                    .category = .linalg,
                    .specialization = specialization.value,
                },
            };
            if (!match_mod.factorDescriptorMatches(descriptor, query)) {
                specialization.deinit();
                return null;
            }
            return .{ .descriptor = descriptor, .specialization = specialization };
        },
        .batched_inverse => |facts| {
            const instance = factor_mod.BatchedInverse{
                .batch = facts.batch,
                .n = facts.n,
                .threads = threads,
                .layout = factorInstanceLayout(query.layout),
            };
            if (!factor_mod.batchedInverseInstanceValid(instance)) return null;
            var specialization = try factor_mod.batchedInverseFamilySpecialization(
                backing_allocator,
                instance,
            );
            errdefer specialization.deinit();
            const lifetime_allocator = specialization.allocator();
            const descriptor = Descriptor{
                .name = try factor_mod.batchedInverseFamilyEntryName(lifetime_allocator, instance),
                .metadata = .{
                    .target = try factor_mod.batchedInverseFamilyTarget(
                        lifetime_allocator,
                        instance,
                    ),
                    .version = factor_mod.batched_inverse_family_version,
                    .layer = .logical,
                    .category = .linalg,
                    .specialization = specialization.value,
                },
            };
            if (!match_mod.factorDescriptorMatches(descriptor, query)) {
                specialization.deinit();
                return null;
            }
            return .{ .descriptor = descriptor, .specialization = specialization };
        },
    }
}

fn factorInstanceLayout(layout: query_mod.FactorTileLayout) factor_mod.TileLayout {
    return switch (layout) {
        .row_major => .row_major,
        .interleaved => .interleaved,
    };
}

fn factorQueryThreads(query: FactorQuery) ?u32 {
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                return threads;
            },
        }
    }
    return 256;
}
