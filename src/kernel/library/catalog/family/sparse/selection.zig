const std = @import("std");

const descriptor_mod = @import("../../root.zig");
const sparse_mod = @import("../../../root.zig").sparse;
const tuning_mod = @import("../../../root.zig").tuning;
const query_mod = descriptor_mod;

const candidate_mod = @import("candidate.zig");
const descriptor_build = @import("descriptor.zig");
const structure_mod = @import("structure/root.zig");
const thread_mod = @import("threads.zig");

const OwnedDescriptor = descriptor_mod.OwnedDescriptor;
const SparseQuery = query_mod.SparseQuery;
const SparseCandidateDescriptors = candidate_mod.SparseCandidateDescriptors;

pub fn selectSparse(backing_allocator: std.mem.Allocator, query: SparseQuery) !?OwnedDescriptor {
    if (!structure_mod.canonicalSparse(query)) return null;
    const accumulation_dtype = sparse_mod.sparseAccumulationDType(query.dtype) orelse return null;
    switch (query.kind) {
        .coo_spmv => |facts| {
            const structure = structure_mod.sparseResolvedCooStructure(query) orelse return null;
            const coo_accumulation_dtype = sparse_mod.spmvCooAccumulationDTypeForStructure(
                structure,
                query.dtype,
            ) orelse return null;
            const threads = thread_mod.sparseQueryCooThreads(
                query,
                facts.rows,
                facts.nnz,
                structure,
            ) orelse return null;
            return try descriptor_build.spmvCooDescriptorForInstance(backing_allocator, query, .{
                .rows = facts.rows,
                .nnz = facts.nnz,
                .x_extent = facts.x_extent,
                .dtype = query.dtype,
                .accumulation_dtype = coo_accumulation_dtype,
                .threads = threads,
                .structure = structure,
            });
        },
        .csr_spmv => |facts| {
            const structure = structure_mod.sparseResolvedSpmvStructure(query) orelse return null;
            const threads = thread_mod.sparseQuerySpmvThreads(query, facts.rows, structure) orelse
                return null;
            return try descriptor_build.spmvCsrDescriptorForInstance(backing_allocator, query, .{
                .rows = facts.rows,
                .nnz = facts.nnz,
                .x_extent = facts.x_extent,
                .dtype = query.dtype,
                .accumulation_dtype = accumulation_dtype,
                .threads = threads,
                .structure = structure,
            });
        },
        .ell_spmv => |facts| {
            const structure = structure_mod.sparseResolvedEllStructure(query) orelse return null;
            const threads = thread_mod.sparseQueryEllThreads(query, facts.rows) orelse return null;
            return try descriptor_build.spmvEllDescriptorForInstance(backing_allocator, query, .{
                .rows = facts.rows,
                .slots = facts.slots,
                .x_extent = facts.x_extent,
                .dtype = query.dtype,
                .accumulation_dtype = accumulation_dtype,
                .threads = threads,
                .structure = structure,
            });
        },
        .sell_spmv => |facts| {
            const structure = structure_mod.sparseResolvedSellStructure(query) orelse return null;
            const threads = thread_mod.sparseQuerySellThreads(query, facts.rows) orelse return null;
            return try descriptor_build.spmvSellDescriptorForInstance(backing_allocator, query, .{
                .rows = facts.rows,
                .slice_size = facts.slice_size,
                .values_size = facts.values_size,
                .x_extent = facts.x_extent,
                .dtype = query.dtype,
                .accumulation_dtype = accumulation_dtype,
                .threads = threads,
                .structure = structure,
            });
        },
        .csr_spmm => |facts| {
            const structure = structure_mod.sparseResolvedSpmmStructure(query) orelse return null;
            const threads = thread_mod.sparseQuerySpmmThreads(query, facts) orelse return null;
            return try descriptor_build.spmmCsrDescriptorForInstance(backing_allocator, query, .{
                .rows = facts.rows,
                .columns = facts.columns,
                .nnz = facts.nnz,
                .x_extent = facts.x_extent,
                .dtype = query.dtype,
                .accumulation_dtype = accumulation_dtype,
                .threads = threads,
                .structure = structure,
            });
        },
    }
}

pub fn selectSparseCandidates(
    backing_allocator: std.mem.Allocator,
    query: SparseQuery,
) !SparseCandidateDescriptors {
    var result = SparseCandidateDescriptors{};
    errdefer result.deinit();

    if (!structure_mod.canonicalSparse(query)) return result;
    switch (query.kind) {
        .coo_spmv => {
            if (query.structure != null) {
                if (try selectSparse(backing_allocator, query)) |descriptor| {
                    result.items[result.count] = descriptor;
                    result.count += 1;
                }
                return result;
            }
            const structures = [_]query_mod.SparseStructure{ .element_thread, .row_thread };
            for (structures) |structure| {
                var candidate = query;
                candidate.structure = structure;
                if (try selectSparse(backing_allocator, candidate)) |descriptor| {
                    result.items[result.count] = descriptor;
                    result.count += 1;
                }
            }
            return result;
        },
        .csr_spmv => {
            if (query.structure != null) {
                if (try selectSparse(backing_allocator, query)) |descriptor| {
                    result.items[result.count] = descriptor;
                    result.count += 1;
                }
                return result;
            }
            const structures = [_]query_mod.SparseStructure{ .row_thread, .row_warp };
            for (structures) |structure| {
                var candidate = query;
                candidate.structure = structure;
                if (try selectSparse(backing_allocator, candidate)) |descriptor| {
                    result.items[result.count] = descriptor;
                    result.count += 1;
                }
            }
            return result;
        },
        .ell_spmv => |facts| {
            if (query.structure != null or query.schedule != null) {
                if (try selectSparse(backing_allocator, query)) |descriptor| {
                    result.items[result.count] = descriptor;
                    result.count += 1;
                }
                return result;
            }
            if (try selectSparse(backing_allocator, query)) |descriptor| {
                result.items[result.count] = descriptor;
                result.count += 1;
            }
            const accumulation_dtype = sparse_mod.sparseAccumulationDType(query.dtype) orelse
                return result;
            const structure = structure_mod.sparseResolvedEllStructure(query) orelse return result;
            const thread_candidates = sparse_mod.spmvEllThreadCandidatesForRows(facts.rows);
            for (thread_candidates.slice()) |threads| {
                var candidate = sparse_mod.SpmvEll{
                    .rows = facts.rows,
                    .slots = facts.slots,
                    .x_extent = facts.x_extent,
                    .dtype = query.dtype,
                    .accumulation_dtype = accumulation_dtype,
                    .threads = threads,
                    .structure = structure,
                };
                candidate.threads = sparse_mod.spmvEllRepresentableThreads(candidate) orelse
                    continue;
                var scheduled = query;
                scheduled.schedule = .{ .thread_blocks = candidate.threads };
                if (try descriptor_build.spmvEllDescriptorForInstance(
                    backing_allocator,
                    scheduled,
                    candidate,
                )) |descriptor_owned| {
                    var descriptor = descriptor_owned;
                    if (candidate_mod.sparseCandidateTargetsContain(
                        result.slice(),
                        descriptor.descriptor.metadata.target,
                    )) {
                        descriptor.deinit();
                        continue;
                    }
                    result.items[result.count] = descriptor;
                    result.count += 1;
                }
            }
            return result;
        },
        .sell_spmv => |facts| {
            if (query.structure != null or query.schedule != null) {
                if (try selectSparse(backing_allocator, query)) |descriptor| {
                    result.items[result.count] = descriptor;
                    result.count += 1;
                }
                return result;
            }
            if (try selectSparse(backing_allocator, query)) |descriptor| {
                result.items[result.count] = descriptor;
                result.count += 1;
            }
            const accumulation_dtype = sparse_mod.sparseAccumulationDType(query.dtype) orelse
                return result;
            const structure = structure_mod.sparseResolvedSellStructure(query) orelse return result;
            const thread_candidates = sparse_mod.spmvSellThreadCandidatesForRows(facts.rows);
            for (thread_candidates.slice()) |threads| {
                var candidate = sparse_mod.SpmvSell{
                    .rows = facts.rows,
                    .slice_size = facts.slice_size,
                    .values_size = facts.values_size,
                    .x_extent = facts.x_extent,
                    .dtype = query.dtype,
                    .accumulation_dtype = accumulation_dtype,
                    .threads = threads,
                    .structure = structure,
                };
                candidate.threads = sparse_mod.spmvSellRepresentableThreads(candidate) orelse
                    continue;
                var scheduled = query;
                scheduled.schedule = .{ .thread_blocks = candidate.threads };
                if (try descriptor_build.spmvSellDescriptorForInstance(
                    backing_allocator,
                    scheduled,
                    candidate,
                )) |descriptor_owned| {
                    var descriptor = descriptor_owned;
                    if (candidate_mod.sparseCandidateTargetsContain(
                        result.slice(),
                        descriptor.descriptor.metadata.target,
                    )) {
                        descriptor.deinit();
                        continue;
                    }
                    result.items[result.count] = descriptor;
                    result.count += 1;
                }
            }
            return result;
        },
        .csr_spmm => |facts| {
            if (query.structure != null or query.schedule != null) {
                if (try selectSparse(backing_allocator, query)) |descriptor| {
                    result.items[result.count] = descriptor;
                    result.count += 1;
                }
                return result;
            }
            if (try selectSparse(backing_allocator, query)) |descriptor| {
                result.items[result.count] = descriptor;
                result.count += 1;
            }
            const accumulation_dtype = sparse_mod.sparseAccumulationDType(query.dtype) orelse
                return result;
            const structure = structure_mod.sparseResolvedSpmmStructure(query) orelse return result;
            const thread_candidates = sparse_mod.spmmCsrThreadCandidatesForExtents(
                facts.rows,
                facts.columns,
            );
            for (thread_candidates.slice()) |threads| {
                var candidate = sparse_mod.SpmmCsr{
                    .rows = facts.rows,
                    .columns = facts.columns,
                    .nnz = facts.nnz,
                    .x_extent = facts.x_extent,
                    .dtype = query.dtype,
                    .accumulation_dtype = accumulation_dtype,
                    .threads = threads,
                    .structure = structure,
                };
                candidate.threads = sparse_mod.spmmCsrRepresentableThreads(candidate) orelse
                    continue;
                var scheduled = query;
                scheduled.schedule = .{ .thread_blocks_2d = candidate.threads };
                if (try descriptor_build.spmmCsrDescriptorForInstance(
                    backing_allocator,
                    scheduled,
                    candidate,
                )) |descriptor_owned| {
                    var descriptor = descriptor_owned;
                    if (candidate_mod.sparseCandidateTargetsContain(
                        result.slice(),
                        descriptor.descriptor.metadata.target,
                    )) {
                        descriptor.deinit();
                        continue;
                    }
                    result.items[result.count] = descriptor;
                    result.count += 1;
                }
            }
            return result;
        },
    }
}

pub fn selectSparseWithTuning(
    backing_allocator: std.mem.Allocator,
    query: SparseQuery,
    reader: tuning_mod.FamilyTuningReader,
) !?OwnedDescriptor {
    if (!structure_mod.canonicalSparse(query)) return null;
    if (query.structure != null) return selectSparse(backing_allocator, query);
    switch (query.kind) {
        .coo_spmv => |facts| {
            const structure = structure_mod.sparseResolvedCooStructure(query) orelse return null;
            const accumulation_dtype = sparse_mod.spmvCooAccumulationDTypeForStructure(
                structure,
                query.dtype,
            ) orelse return null;
            const threads = thread_mod.sparseQueryCooThreads(
                query,
                facts.rows,
                facts.nnz,
                structure,
            ) orelse return null;
            const resolved = try sparse_mod.resolveSpmvCooStructure(backing_allocator, reader, .{
                .rows = facts.rows,
                .nnz = facts.nnz,
                .x_extent = facts.x_extent,
                .dtype = query.dtype,
                .accumulation_dtype = accumulation_dtype,
                .threads = threads,
                .structure = structure,
            });
            var tuned = query;
            tuned.structure = if (resolved) |resolved_structure| switch (resolved_structure) {
                .element_thread => .element_thread,
                .row_thread => .row_thread,
            } else return selectSparse(backing_allocator, query);
            return selectSparse(backing_allocator, tuned);
        },
        .csr_spmv => |facts| {
            const accumulation_dtype = sparse_mod.sparseAccumulationDType(query.dtype) orelse
                return null;
            const structure = structure_mod.sparseResolvedSpmvStructure(query) orelse return null;
            const threads = thread_mod.sparseQuerySpmvThreads(query, facts.rows, structure) orelse
                return null;
            const resolved = try sparse_mod.resolveSpmvCsrStructure(backing_allocator, reader, .{
                .rows = facts.rows,
                .nnz = facts.nnz,
                .x_extent = facts.x_extent,
                .dtype = query.dtype,
                .accumulation_dtype = accumulation_dtype,
                .threads = threads,
                .structure = structure,
            });
            var tuned = query;
            tuned.structure = if (resolved) |resolved_structure| switch (resolved_structure) {
                .row_thread => .row_thread,
                .row_warp => .row_warp,
            } else return selectSparse(backing_allocator, query);
            return selectSparse(backing_allocator, tuned);
        },
        .ell_spmv => |facts| {
            if (query.schedule != null) return selectSparse(backing_allocator, query);
            const accumulation_dtype = sparse_mod.sparseAccumulationDType(query.dtype) orelse
                return null;
            const structure = structure_mod.sparseResolvedEllStructure(query) orelse return null;
            const threads = thread_mod.sparseQueryEllThreads(query, facts.rows) orelse return null;
            const resolved = try sparse_mod.resolveSpmvEllThreads(backing_allocator, reader, .{
                .rows = facts.rows,
                .slots = facts.slots,
                .x_extent = facts.x_extent,
                .dtype = query.dtype,
                .accumulation_dtype = accumulation_dtype,
                .threads = threads,
                .structure = structure,
            });
            var tuned = query;
            tuned.schedule = if (resolved) |resolved_threads|
                .{ .thread_blocks = resolved_threads }
            else
                return selectSparse(backing_allocator, query);
            return selectSparse(backing_allocator, tuned);
        },
        .sell_spmv => |facts| {
            if (query.schedule != null) return selectSparse(backing_allocator, query);
            const accumulation_dtype = sparse_mod.sparseAccumulationDType(query.dtype) orelse
                return null;
            const structure = structure_mod.sparseResolvedSellStructure(query) orelse return null;
            const threads = thread_mod.sparseQuerySellThreads(query, facts.rows) orelse return null;
            const resolved = try sparse_mod.resolveSpmvSellThreads(backing_allocator, reader, .{
                .rows = facts.rows,
                .slice_size = facts.slice_size,
                .values_size = facts.values_size,
                .x_extent = facts.x_extent,
                .dtype = query.dtype,
                .accumulation_dtype = accumulation_dtype,
                .threads = threads,
                .structure = structure,
            });
            var tuned = query;
            tuned.schedule = if (resolved) |resolved_threads|
                .{ .thread_blocks = resolved_threads }
            else
                return selectSparse(backing_allocator, query);
            return selectSparse(backing_allocator, tuned);
        },
        .csr_spmm => |facts| {
            if (query.schedule != null) return selectSparse(backing_allocator, query);
            const accumulation_dtype = sparse_mod.sparseAccumulationDType(query.dtype) orelse
                return null;
            const structure = structure_mod.sparseResolvedSpmmStructure(query) orelse return null;
            const threads = thread_mod.sparseQuerySpmmThreads(query, facts) orelse return null;
            const resolved = try sparse_mod.resolveSpmmCsrThreads(backing_allocator, reader, .{
                .rows = facts.rows,
                .columns = facts.columns,
                .nnz = facts.nnz,
                .x_extent = facts.x_extent,
                .dtype = query.dtype,
                .accumulation_dtype = accumulation_dtype,
                .threads = threads,
                .structure = structure,
            });
            var tuned = query;
            tuned.schedule = if (resolved) |resolved_threads|
                .{ .thread_blocks_2d = resolved_threads }
            else
                return selectSparse(backing_allocator, query);
            return selectSparse(backing_allocator, tuned);
        },
    }
}
