const std = @import("std");
const source = @import("../root.zig");
const verification = @import("root.zig");

pub fn verifySpec(module: *const source.PartitionedModule, spec: source.PartitionSpec) verification.Error!void {
    if (spec.name.len == 0) return error.EmptyPartition;
    if (spec.product.stage.len == 0) return error.EmptyProductRef;
    if (spec.provenance.path.len == 0 or spec.provenance.symbol.len == 0) return error.EmptyProvenance;
    try verifyBoundaryRoles(module, spec.inputs, spec.outputs);
    for (module.partitions.items) |partition_value| {
        if (partition_value.product.eql(spec.product)) return error.DuplicateProductRef;
    }
}

pub fn verifyValue(module: *const source.PartitionedModule, partition_value: source.Partition) verification.Error!void {
    if (partition_value.name.len == 0) return error.EmptyPartition;
    if (partition_value.product.stage.len == 0) return error.EmptyProductRef;
    if (partition_value.provenance.path.len == 0 or partition_value.provenance.symbol.len == 0) return error.EmptyProvenance;
    try verifyBoundaryRoles(module, partition_value.inputs, partition_value.outputs);
}

pub fn verifyBoundaryRoles(
    module: *const source.PartitionedModule,
    inputs: []const source.BoundaryId,
    outputs: []const source.BoundaryId,
) verification.Error!void {
    for (inputs) |id| {
        const boundary_value = module.boundary(id) orelse return error.MissingBoundary;
        if (boundary_value.access == .write) return error.AccessMismatch;
        if (boundary_value.ownership == .produced) return error.OwnershipMismatch;
    }
    for (outputs) |id| {
        const boundary_value = module.boundary(id) orelse return error.MissingBoundary;
        if (boundary_value.access == .read) return error.AccessMismatch;
    }
}

fn mutableBoundary(module: *source.PartitionedModule, id: source.BoundaryId) ?*source.Boundary {
    for (module.boundaries.items) |*boundary_value| {
        if (boundary_value.id.value == id.value) return boundary_value;
    }
    return null;
}

fn mutablePartition(module: *source.PartitionedModule, id: source.PartitionId) ?*source.Partition {
    for (module.partitions.items) |*partition_value| {
        if (partition_value.id.value == id.value) return partition_value;
    }
    return null;
}
