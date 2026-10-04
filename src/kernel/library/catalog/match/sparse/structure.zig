const catalog = @import("../../root.zig");
const library = @import("../../../root.zig");

const entry = library.entry;
const SparseStructure = catalog.SparseStructure;

pub fn sparseStructureMatches(
    specialization: entry.Specialization,
    structure: ?SparseStructure,
) bool {
    const requested = structure orelse return true;
    return specialization.structureIs(@tagName(requested));
}
