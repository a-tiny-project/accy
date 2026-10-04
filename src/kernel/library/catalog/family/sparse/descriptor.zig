const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const sparse_mod = @import("../../../root.zig").sparse;
const match_mod = @import("../../match/root.zig");
const query_mod = descriptor_mod;

const Descriptor = descriptor_mod.Descriptor;
const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const SparseQuery = query_mod.SparseQuery;

pub fn spmvCooDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    query: SparseQuery,
    instance: sparse_mod.SpmvCoo,
) !?OwnedDescriptor {
    if (!sparse_mod.spmvCooInstanceValid(instance)) return null;
    var specialization = try sparse_mod.spmvCooFamilySpecialization(
        backing_allocator,
        instance,
    );
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try sparse_mod.spmvCooFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try sparse_mod.spmvCooFamilyTarget(lifetime_allocator, instance),
            .version = sparse_mod.spmv_coo_family_version,
            .layer = .logical,
            .category = .sparse,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.sparseDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

pub fn spmvCsrDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    query: SparseQuery,
    instance: sparse_mod.SpmvCsr,
) !?OwnedDescriptor {
    if (!sparse_mod.spmvCsrInstanceValid(instance)) return null;
    var specialization = try sparse_mod.spmvCsrFamilySpecialization(
        backing_allocator,
        instance,
    );
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try sparse_mod.spmvCsrFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try sparse_mod.spmvCsrFamilyTarget(lifetime_allocator, instance),
            .version = sparse_mod.spmv_csr_family_version,
            .layer = .logical,
            .category = .sparse,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.sparseDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

pub fn spmvEllDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    query: SparseQuery,
    instance: sparse_mod.SpmvEll,
) !?OwnedDescriptor {
    if (!sparse_mod.spmvEllInstanceValid(instance)) return null;
    var specialization = try sparse_mod.spmvEllFamilySpecialization(
        backing_allocator,
        instance,
    );
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try sparse_mod.spmvEllFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try sparse_mod.spmvEllFamilyTarget(lifetime_allocator, instance),
            .version = sparse_mod.spmv_ell_family_version,
            .layer = .logical,
            .category = .sparse,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.sparseDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

pub fn spmvSellDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    query: SparseQuery,
    instance: sparse_mod.SpmvSell,
) !?OwnedDescriptor {
    if (!sparse_mod.spmvSellInstanceValid(instance)) return null;
    var specialization = try sparse_mod.spmvSellFamilySpecialization(
        backing_allocator,
        instance,
    );
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try sparse_mod.spmvSellFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try sparse_mod.spmvSellFamilyTarget(lifetime_allocator, instance),
            .version = sparse_mod.spmv_sell_family_version,
            .layer = .logical,
            .category = .sparse,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.sparseDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}

pub fn spmmCsrDescriptorForInstance(
    backing_allocator: std.mem.Allocator,
    query: SparseQuery,
    instance: sparse_mod.SpmmCsr,
) !?OwnedDescriptor {
    if (!sparse_mod.spmmCsrInstanceValid(instance)) return null;
    var specialization = try sparse_mod.spmmCsrFamilySpecialization(
        backing_allocator,
        instance,
    );
    errdefer specialization.deinit();
    const lifetime_allocator = specialization.allocator();
    const descriptor = Descriptor{
        .name = try sparse_mod.spmmCsrFamilyEntryName(lifetime_allocator, instance),
        .metadata = .{
            .target = try sparse_mod.spmmCsrFamilyTarget(lifetime_allocator, instance),
            .version = sparse_mod.spmm_csr_family_version,
            .layer = .logical,
            .category = .sparse,
            .specialization = specialization.value,
        },
    };
    if (!match_mod.sparseDescriptorMatches(descriptor, query)) {
        specialization.deinit();
        return null;
    }
    return .{ .descriptor = descriptor, .specialization = specialization };
}
