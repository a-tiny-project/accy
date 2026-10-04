const std = @import("std");

const kernel = @import("../../../../root.zig");
const entry = @import("../../../root.zig").entry;
const sparse_mod = @import("../../../root.zig").sparse;

pub fn create(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    return switch (metadata.specialization.operation orelse
        return error.UnknownKernelLibraryEntry) {
        .sparse => |sparse_operation| switch (sparse_operation) {
            .coo_spmv => createSpmvCoo(allocator, handle, metadata, options),
            .csr_spmv => createSpmvCsr(allocator, handle, metadata, options),
            .csr_spmm => createSpmmCsr(allocator, handle, metadata, options),
            .ell_spmv => createSpmvEll(allocator, handle, metadata, options),
            .sell_spmv => createSpmvSell(allocator, handle, metadata, options),
        },
        else => error.UnknownKernelLibraryEntry,
    };
}

fn createSpmvCoo(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != sparse_mod.spmv_coo_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = sparse_mod.spmvCooInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try sparse_mod.spmvCooFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try sparse_mod.createSpmvCooFamilyArtifact(allocator, handle, instance, options);
}

fn createSpmvCsr(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != sparse_mod.spmv_csr_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = sparse_mod.spmvCsrInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try sparse_mod.spmvCsrFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try sparse_mod.createSpmvCsrFamilyArtifact(allocator, handle, instance, options);
}

fn createSpmmCsr(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != sparse_mod.spmm_csr_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = sparse_mod.spmmCsrInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try sparse_mod.spmmCsrFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try sparse_mod.createSpmmCsrFamilyArtifact(allocator, handle, instance, options);
}

fn createSpmvEll(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != sparse_mod.spmv_ell_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = sparse_mod.spmvEllInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try sparse_mod.spmvEllFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try sparse_mod.createSpmvEllFamilyArtifact(allocator, handle, instance, options);
}

fn createSpmvSell(
    allocator: std.mem.Allocator,
    handle: kernel.BackendHandle,
    metadata: entry.Metadata,
    options: entry.ArtifactOptions,
) !kernel.OwnedKernelCallArtifact {
    if (metadata.version != sparse_mod.spmv_sell_family_version) {
        return error.UnknownKernelLibraryEntry;
    }
    const instance = sparse_mod.spmvSellInstanceFromSpecialization(metadata.specialization) orelse {
        return error.UnknownKernelLibraryEntry;
    };
    const target = try sparse_mod.spmvSellFamilyTarget(allocator, instance);
    defer allocator.free(target);
    if (!std.mem.eql(u8, metadata.target, target)) return error.UnknownKernelLibraryEntry;
    return try sparse_mod.createSpmvSellFamilyArtifact(allocator, handle, instance, options);
}
