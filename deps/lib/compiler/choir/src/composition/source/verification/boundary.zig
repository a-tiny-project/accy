const std = @import("std");
const source = @import("../root.zig");
const verification = @import("root.zig");

pub fn verifySpec(spec: source.BoundarySpec) verification.Error!void {
    if (spec.byte_size == 0 or spec.name.len == 0) return error.EmptyBoundary;
    if (spec.provenance.path.len == 0 or spec.provenance.symbol.len == 0) return error.EmptyProvenance;
    switch (spec.alias) {
        .disjoint => {},
        .boundary => |id| {
            if (id.value == spec.id.value) return error.SelfBoundaryAlias;
            if (spec.ownership == .produced) return error.ProducedBoundaryAlias;
        },
    }
    const byte_size = source.boundary.staticByteSize(spec.element_type, spec.dimensions) orelse return error.InvalidBoundaryShape;
    if (byte_size != spec.byte_size) return error.BoundarySizeMismatch;
}

pub fn verifyValue(boundary_value: source.Boundary) verification.Error!void {
    if (boundary_value.name.len == 0 or boundary_value.byte_size == 0) return error.EmptyBoundary;
    if (boundary_value.provenance.path.len == 0 or boundary_value.provenance.symbol.len == 0) return error.EmptyProvenance;
    switch (boundary_value.alias) {
        .disjoint => {},
        .boundary => |id| {
            if (id.value == boundary_value.id.value) return error.SelfBoundaryAlias;
            if (boundary_value.ownership == .produced) return error.ProducedBoundaryAlias;
        },
    }
    const byte_size = source.boundary.staticByteSize(boundary_value.element_type, boundary_value.dimensions) orelse return error.InvalidBoundaryShape;
    if (byte_size != boundary_value.byte_size) return error.BoundarySizeMismatch;
}

pub fn verifyAliasSpec(module: *const source.PartitionedModule, spec: source.BoundarySpec) verification.Error!void {
    const alias_id = switch (spec.alias) {
        .disjoint => return,
        .boundary => |id| id,
    };
    const aliased = module.boundary(alias_id) orelse return;
    try verifyAliasTarget(aliased, spec.element_type, spec.dimensions, spec.byte_size, spec.ownership);
}

pub fn verifyAlias(module: *const source.PartitionedModule, boundary_value: source.Boundary) verification.Error!void {
    const alias_id = switch (boundary_value.alias) {
        .disjoint => return,
        .boundary => |id| id,
    };
    const aliased = module.boundary(alias_id) orelse return error.MissingAliasBoundary;
    try verifyAliasTarget(
        aliased,
        boundary_value.element_type,
        boundary_value.dimensions,
        boundary_value.byte_size,
        boundary_value.ownership,
    );
}

fn verifyAliasTarget(
    aliased: *const source.Boundary,
    element_type: source.ElementType,
    dimensions: []const u64,
    byte_size: u64,
    ownership: source.Ownership,
) verification.Error!void {
    switch (aliased.alias) {
        .disjoint => {},
        .boundary => return error.NonCanonicalBoundaryAlias,
    }
    if (aliased.ownership == .produced) return error.ProducedAliasTarget;
    if (aliased.ownership != ownership) return error.OwnershipMismatch;
    if (aliased.element_type != element_type or
        aliased.byte_size != byte_size or
        !std.mem.eql(u64, aliased.dimensions, dimensions))
    {
        return error.BoundaryAliasMismatch;
    }
}
