const source = @import("../root.zig");
const verification = @import("root.zig");

pub fn verify(module: *const source.PartitionedModule) verification.Error!void {
    for (module.boundaries.items, 0..) |boundary_value, index| {
        try verification.boundary.verifyValue(boundary_value);
        try verification.boundary.verifyAlias(module, boundary_value);
        for (module.boundaries.items[0..index]) |previous| {
            if (previous.id.value == boundary_value.id.value) return error.DuplicateBoundary;
        }
    }
    for (module.partitions.items, 0..) |partition_value, index| {
        try verification.partition.verifyValue(module, partition_value);
        for (module.partitions.items[0..index]) |previous| {
            if (previous.id.value == partition_value.id.value) return error.DuplicatePartition;
            if (previous.product.eql(partition_value.product)) return error.DuplicateProductRef;
        }
        for (partition_value.inputs) |id| if (module.boundary(id) == null) return error.MissingBoundary;
        for (partition_value.outputs) |id| if (module.boundary(id) == null) return error.MissingBoundary;
    }
    for (module.call_sites.items, 0..) |call_site, index| {
        for (module.call_sites.items[0..index]) |previous| {
            if (previous.id.value == call_site.id.value) return error.DuplicateCallSite;
        }
        try verification.call.verifyValue(module, call_site);
    }
}
