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

test "partition verification owns boundary role validity" {
    var module = try source.PartitionedModule.init(std.testing.allocator, "roles");
    defer module.deinit();

    try module.addBoundary(.{ .id = .{ .value = 1 }, .name = "write_input", .element_type = .f32, .dimensions = &.{2}, .byte_size = 8, .access = .write, .ownership = .borrowed, .alias = .disjoint, .provenance = .{ .path = "roles.chic", .symbol = "write_input" } });
    try module.addBoundary(.{ .id = .{ .value = 2 }, .name = "produced_input", .element_type = .f32, .dimensions = &.{2}, .byte_size = 8, .access = .read, .ownership = .produced, .alias = .disjoint, .provenance = .{ .path = "roles.chic", .symbol = "produced_input" } });
    try module.addBoundary(.{ .id = .{ .value = 3 }, .name = "read_output", .element_type = .f32, .dimensions = &.{2}, .byte_size = 8, .access = .read, .ownership = .produced, .alias = .disjoint, .provenance = .{ .path = "roles.chic", .symbol = "read_output" } });
    try module.addBoundary(.{ .id = .{ .value = 4 }, .name = "input", .element_type = .f32, .dimensions = &.{2}, .byte_size = 8, .access = .read, .ownership = .borrowed, .alias = .disjoint, .provenance = .{ .path = "roles.chic", .symbol = "input" } });
    try module.addBoundary(.{ .id = .{ .value = 5 }, .name = "output", .element_type = .f32, .dimensions = &.{2}, .byte_size = 8, .access = .write, .ownership = .produced, .alias = .disjoint, .provenance = .{ .path = "roles.chic", .symbol = "output" } });

    const base = source.PartitionSpec{
        .id = .{ .value = 1 },
        .name = "region",
        .pipeline = .accy,
        .product = .{ .producer = "composition-fixture", .source = "1", .stage = "roles.product", .variant = "default" },
        .effect = .none,
        .provenance = .{ .path = "roles.chic", .symbol = "region" },
    };
    var spec = base;
    spec.inputs = &.{.{ .value = 1 }};
    try std.testing.expectError(error.AccessMismatch, module.addPartition(spec));
    spec.inputs = &.{.{ .value = 2 }};
    try std.testing.expectError(error.OwnershipMismatch, module.addPartition(spec));
    spec.inputs = &.{.{ .value = 4 }};
    spec.outputs = &.{.{ .value = 3 }};
    try std.testing.expectError(error.AccessMismatch, module.addPartition(spec));
    spec.outputs = &.{.{ .value = 5 }};
    try module.addPartition(spec);
    try module.verify();

    const partition = mutablePartition(&module, .{ .value = 1 }) orelse return error.TestExpectedResult;
    const original_name = partition.name;
    partition.name = "";
    try std.testing.expectError(error.EmptyPartition, module.verify());
    partition.name = original_name;

    const input = mutableBoundary(&module, .{ .value = 4 }) orelse return error.TestExpectedResult;
    input.access = .write;
    try std.testing.expectError(error.AccessMismatch, module.verify());
    input.access = .read;
    input.ownership = .produced;
    try std.testing.expectError(error.OwnershipMismatch, module.verify());
    input.ownership = .borrowed;
    const output = mutableBoundary(&module, .{ .value = 5 }) orelse return error.TestExpectedResult;
    output.access = .read;
    try std.testing.expectError(error.AccessMismatch, module.verify());
    output.access = .write;
    try module.verify();
}
