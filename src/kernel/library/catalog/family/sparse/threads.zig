const entry = @import("../../../root.zig").entry;
const sparse_mod = @import("../../../root.zig").sparse;
const query_mod = @import("../../root.zig");

const SparseQuery = query_mod.SparseQuery;

pub fn sparseQuerySpmvThreads(
    query: SparseQuery,
    rows: u64,
    structure: sparse_mod.SpmvCsrStructure,
) ?u32 {
    const requested_threads: u32 = if (query.schedule) |requested| blk: {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                break :blk threads;
            },
            .thread_blocks_2d => return null,
        }
    } else switch (structure) {
        .row_thread => 256,
        .row_warp => 256,
    };
    return sparse_mod.spmvCsrRepresentableThreads(.{
        .rows = rows,
        .threads = requested_threads,
        .structure = structure,
    });
}

pub fn sparseQueryCooThreads(
    query: SparseQuery,
    rows: u64,
    nnz: u64,
    structure: sparse_mod.SpmvCooStructure,
) ?u32 {
    const requested_threads: u32 = if (query.schedule) |requested| blk: {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                break :blk threads;
            },
            .thread_blocks_2d => return null,
        }
    } else 256;
    return sparse_mod.spmvCooRepresentableThreads(.{
        .rows = rows,
        .nnz = nnz,
        .threads = requested_threads,
        .structure = structure,
    });
}

pub fn sparseQueryEllThreads(query: SparseQuery, rows: u64) ?u32 {
    const requested_threads: u32 = if (query.schedule) |requested| blk: {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                break :blk threads;
            },
            .thread_blocks_2d => return null,
        }
    } else 256;
    return sparse_mod.spmvEllRepresentableThreads(.{
        .rows = rows,
        .threads = requested_threads,
    });
}

pub fn sparseQuerySellThreads(query: SparseQuery, rows: u64) ?u32 {
    const requested_threads: u32 = if (query.schedule) |requested| blk: {
        switch (requested) {
            .thread_blocks => |threads| {
                if (threads == 0) return null;
                break :blk threads;
            },
            .thread_blocks_2d => return null,
        }
    } else 256;
    return sparse_mod.spmvSellRepresentableThreads(.{
        .rows = rows,
        .threads = requested_threads,
    });
}

pub fn sparseQuerySpmmThreads(query: SparseQuery, facts: anytype) ?entry.Threads2D {
    if (query.schedule) |requested| {
        switch (requested) {
            .thread_blocks => return null,
            .thread_blocks_2d => |threads| {
                if (threads.x == 0 or threads.y == 0) return null;
                return threads;
            },
        }
    }
    return sparse_mod.spmmCsrThreadsForExtents(facts.rows, facts.columns);
}
