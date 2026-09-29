const catalog = @import("../../root.zig");
const library = @import("../../../root.zig");

const common = @import("../root.zig");
const operation = @import("operation.zig");
const schedule = @import("schedule.zig");
const structure = @import("structure.zig");

const Descriptor = catalog.Descriptor;
const SparseQuery = catalog.SparseQuery;
const sparse_library = library.sparse;
const selectableSpecialization = common.selectableSpecialization;

pub fn sparseDescriptorMatches(descriptor: Descriptor, query: SparseQuery) bool {
    const metadata = descriptor.metadata;
    if (metadata.category != .sparse) return false;
    const specialization = metadata.specialization;
    if (!selectableSpecialization(specialization)) return false;
    if (!specialization.scheduleMatchesLaunch()) return false;
    if (specialization.dtype != query.dtype) return false;
    if (specialization.accumulation_dtype != sparse_library.sparseAccumulationDType(query.dtype)) return false;
    if (specialization.reductions.len != 0) return false;
    if (!schedule.sparseScheduleMatches(specialization, query)) return false;
    if (!structure.sparseStructureMatches(specialization, query.structure)) return false;
    return operation.sparseOperationMatches(specialization, query);
}
