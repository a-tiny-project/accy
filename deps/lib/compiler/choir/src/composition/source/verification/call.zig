const source = @import("../root.zig");
const verification = @import("root.zig");

pub fn verifySpec(module: *const source.PartitionedModule, spec: source.SemanticCallSiteSpec) verification.Error!void {
    if (spec.name.len == 0) return error.EmptyCallSite;
    if (module.callSite(spec.id) != null) return error.DuplicateCallSite;
    if (module.partition(spec.caller) == null or module.partition(spec.callee) == null) return error.MissingPartition;
    for (spec.inputs) |id| if (module.boundary(id) == null) return error.MissingBoundary;
    for (spec.outputs) |id| if (module.boundary(id) == null) return error.MissingBoundary;
    const callee = module.partition(spec.callee).?;
    if (!source.boundaryIdsEqual(spec.inputs, callee.inputs) or !source.boundaryIdsEqual(spec.outputs, callee.outputs)) {
        return error.BoundaryContractMismatch;
    }
    try verification.partition.verifyBoundaryRoles(module, spec.inputs, spec.outputs);
}

pub fn verifyValue(module: *const source.PartitionedModule, call_site: source.SemanticCallSite) verification.Error!void {
    if (call_site.name.len == 0) return error.EmptyCallSite;
    if (module.partition(call_site.caller) == null) return error.MissingPartition;
    const callee = module.partition(call_site.callee) orelse return error.MissingPartition;
    for (call_site.inputs) |id| if (module.boundary(id) == null) return error.MissingBoundary;
    for (call_site.outputs) |id| if (module.boundary(id) == null) return error.MissingBoundary;
    if (!source.boundaryIdsEqual(call_site.inputs, callee.inputs) or !source.boundaryIdsEqual(call_site.outputs, callee.outputs)) {
        return error.BoundaryContractMismatch;
    }
    try verification.partition.verifyBoundaryRoles(module, call_site.inputs, call_site.outputs);
}
