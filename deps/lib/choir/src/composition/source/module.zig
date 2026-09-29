const fixture = @import("../fixture/root.zig");
const std = @import("std");
const source = @import("root.zig");
const verification = @import("verification/root.zig");

const Allocator = std.mem.Allocator;

pub const VerificationError = verification.Error;

/// Owns verified semantic partitions, logical boundaries, call sites, and provenance.
/// Physical placement and runtime state are deliberately absent from this product.
pub const PartitionedModule = struct {
    allocator: Allocator,
    name: []const u8,
    boundaries: std.ArrayList(source.Boundary) = .empty,
    partitions: std.ArrayList(source.Partition) = .empty,
    call_sites: std.ArrayList(source.SemanticCallSite) = .empty,

    pub fn init(allocator: Allocator, name: []const u8) Allocator.Error!PartitionedModule {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
        };
    }

    pub fn clone(self: *const PartitionedModule, allocator: Allocator) Allocator.Error!PartitionedModule {
        var copy = try PartitionedModule.init(allocator, self.name);
        errdefer copy.deinit();
        try copy.boundaries.ensureTotalCapacity(allocator, self.boundaries.items.len);
        for (self.boundaries.items) |boundary_value| copy.boundaries.appendAssumeCapacity(try boundary_value.clone(allocator));
        try copy.partitions.ensureTotalCapacity(allocator, self.partitions.items.len);
        for (self.partitions.items) |partition_value| copy.partitions.appendAssumeCapacity(try partition_value.clone(allocator));
        try copy.call_sites.ensureTotalCapacity(allocator, self.call_sites.items.len);
        for (self.call_sites.items) |call_site| copy.call_sites.appendAssumeCapacity(try call_site.clone(allocator));
        return copy;
    }

    pub fn deinit(self: *PartitionedModule) void {
        var call_site_index = self.call_sites.items.len;
        while (call_site_index != 0) {
            call_site_index -= 1;
            self.call_sites.items[call_site_index].deinit(self.allocator);
        }
        self.call_sites.deinit(self.allocator);
        var partition_index = self.partitions.items.len;
        while (partition_index != 0) {
            partition_index -= 1;
            self.partitions.items[partition_index].deinit(self.allocator);
        }
        self.partitions.deinit(self.allocator);
        var boundary_index = self.boundaries.items.len;
        while (boundary_index != 0) {
            boundary_index -= 1;
            self.boundaries.items[boundary_index].deinit(self.allocator);
        }
        self.boundaries.deinit(self.allocator);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn addBoundary(self: *PartitionedModule, spec: source.BoundarySpec) (Allocator.Error || VerificationError)!void {
        try verification.verifyBoundarySpec(spec);
        if (self.boundary(spec.id) != null) return error.DuplicateBoundary;
        try verification.boundary.verifyAliasSpec(self, spec);
        var boundary_value = try source.Boundary.init(self.allocator, spec);
        errdefer boundary_value.deinit(self.allocator);
        try self.boundaries.append(self.allocator, boundary_value);
    }

    pub fn addPartition(self: *PartitionedModule, spec: source.PartitionSpec) (Allocator.Error || VerificationError)!void {
        if (self.partition(spec.id) != null) return error.DuplicatePartition;
        for (spec.inputs) |id| if (self.boundary(id) == null) return error.MissingBoundary;
        for (spec.outputs) |id| if (self.boundary(id) == null) return error.MissingBoundary;
        try verification.verifyPartitionSpec(self, spec);
        var partition_value = try source.Partition.init(self.allocator, spec);
        errdefer partition_value.deinit(self.allocator);
        try self.partitions.append(self.allocator, partition_value);
    }

    pub fn addCallSite(self: *PartitionedModule, spec: source.SemanticCallSiteSpec) (Allocator.Error || VerificationError)!void {
        try verification.verifyCallSiteSpec(self, spec);
        var call_site = try source.SemanticCallSite.init(self.allocator, spec);
        errdefer call_site.deinit(self.allocator);
        try self.call_sites.append(self.allocator, call_site);
    }

    pub fn verify(self: *const PartitionedModule) VerificationError!void {
        try verification.verifyModule(self);
    }

    pub fn boundary(self: *const PartitionedModule, id: source.BoundaryId) ?*const source.Boundary {
        for (self.boundaries.items) |*boundary_value| {
            if (boundary_value.id.value == id.value) return boundary_value;
        }
        return null;
    }

    pub fn partition(self: *const PartitionedModule, id: source.PartitionId) ?*const source.Partition {
        for (self.partitions.items) |*partition_value| {
            if (partition_value.id.value == id.value) return partition_value;
        }
        return null;
    }

    pub fn callSite(self: *const PartitionedModule, id: source.CallSiteId) ?*const source.SemanticCallSite {
        for (self.call_sites.items) |*call_site| {
            if (call_site.id.value == id.value) return call_site;
        }
        return null;
    }
};

test "partitioned module owns and verifies static boundary descriptors" {
    var module = try PartitionedModule.init(std.testing.allocator, "typed_boundaries");
    defer module.deinit();

    try std.testing.expectError(error.BoundarySizeMismatch, module.addBoundary(.{
        .id = .{ .value = 1 },
        .name = "wrong_size",
        .element_type = .f32,
        .dimensions = &.{8},
        .byte_size = 31,
        .access = .read,
        .ownership = .borrowed,
        .alias = .disjoint,
        .provenance = .{ .path = "typed.chic", .symbol = "wrong_size" },
    }));
    try std.testing.expectError(error.InvalidBoundaryShape, module.addBoundary(.{
        .id = .{ .value = 1 },
        .name = "zero_extent",
        .element_type = .f32,
        .dimensions = &.{0},
        .byte_size = 4,
        .access = .read,
        .ownership = .borrowed,
        .alias = .disjoint,
        .provenance = .{ .path = "typed.chic", .symbol = "zero_extent" },
    }));
    try std.testing.expectError(error.InvalidBoundaryShape, module.addBoundary(.{
        .id = .{ .value = 1 },
        .name = "overflow",
        .element_type = .f64,
        .dimensions = &.{std.math.maxInt(u64)},
        .byte_size = 8,
        .access = .read,
        .ownership = .borrowed,
        .alias = .disjoint,
        .provenance = .{ .path = "typed.chic", .symbol = "overflow" },
    }));

    var dimensions = [_]u64{8};
    try module.addBoundary(.{
        .id = .{ .value = 1 },
        .name = "input",
        .element_type = .f32,
        .dimensions = &dimensions,
        .byte_size = 32,
        .access = .read,
        .ownership = .borrowed,
        .alias = .disjoint,
        .provenance = .{ .path = "typed.chic", .symbol = "input" },
    });
    dimensions[0] = 4;
    try std.testing.expectEqualSlices(u64, &.{8}, module.boundary(.{ .value = 1 }).?.dimensions);
    try module.addBoundary(.{
        .id = .{ .value = 2 },
        .name = "scalar",
        .element_type = .f64,
        .dimensions = &.{},
        .byte_size = 8,
        .access = .write,
        .ownership = .produced,
        .alias = .disjoint,
        .provenance = .{ .path = "typed.chic", .symbol = "scalar" },
    });
    try module.verify();
}

test "partitioned module rejects incomplete and contradictory alias contracts" {
    var module = try PartitionedModule.init(std.testing.allocator, "aliases");
    defer module.deinit();

    try std.testing.expectError(error.EmptyProvenance, module.addBoundary(.{
        .id = .{ .value = 1 },
        .name = "empty_provenance",
        .element_type = .f32,
        .dimensions = &.{2},
        .byte_size = 8,
        .access = .read,
        .ownership = .borrowed,
        .alias = .disjoint,
        .provenance = .{ .path = "", .symbol = "" },
    }));
    try std.testing.expectError(error.SelfBoundaryAlias, module.addBoundary(.{
        .id = .{ .value = 1 },
        .name = "self_alias",
        .element_type = .f32,
        .dimensions = &.{2},
        .byte_size = 8,
        .access = .read,
        .ownership = .borrowed,
        .alias = .{ .boundary = .{ .value = 1 } },
        .provenance = .{ .path = "aliases.chic", .symbol = "self_alias" },
    }));
    try std.testing.expectError(error.ProducedBoundaryAlias, module.addBoundary(.{
        .id = .{ .value = 2 },
        .name = "produced_alias",
        .element_type = .f32,
        .dimensions = &.{2},
        .byte_size = 8,
        .access = .write,
        .ownership = .produced,
        .alias = .{ .boundary = .{ .value = 1 } },
        .provenance = .{ .path = "aliases.chic", .symbol = "produced_alias" },
    }));

    try module.addBoundary(.{
        .id = .{ .value = 1 },
        .name = "base",
        .element_type = .f32,
        .dimensions = &.{2},
        .byte_size = 8,
        .access = .read,
        .ownership = .borrowed,
        .alias = .disjoint,
        .provenance = .{ .path = "aliases.chic", .symbol = "base", .line = 1 },
    });
    try module.addBoundary(.{
        .id = .{ .value = 2 },
        .name = "missing",
        .element_type = .f32,
        .dimensions = &.{2},
        .byte_size = 8,
        .access = .read_write,
        .ownership = .borrowed,
        .alias = .{ .boundary = .{ .value = 99 } },
        .provenance = .{ .path = "aliases.chic", .symbol = "missing", .line = 2 },
    });
    try std.testing.expectError(error.MissingAliasBoundary, module.verify());
    module.boundaries.items[1].alias = .{ .boundary = .{ .value = 1 } };
    try module.verify();
    module.boundaries.items[1].ownership = .retained;
    try std.testing.expectError(error.OwnershipMismatch, module.verify());
    module.boundaries.items[1].ownership = .borrowed;
    module.boundaries.items[0].ownership = .produced;
    try std.testing.expectError(error.ProducedAliasTarget, module.verify());
    module.boundaries.items[0].ownership = .borrowed;
    module.boundaries.items[0].alias = .{ .boundary = .{ .value = 2 } };
    try std.testing.expectError(error.NonCanonicalBoundaryAlias, module.verify());
    module.boundaries.items[0].alias = .disjoint;
    module.boundaries.items[1].element_type = .i32;
    try std.testing.expectError(error.BoundaryAliasMismatch, module.verify());
    module.boundaries.items[1].element_type = .f32;
    try std.testing.expectError(error.OwnershipMismatch, module.addBoundary(.{
        .id = .{ .value = 3 },
        .name = "ownership_mismatch",
        .element_type = .f32,
        .dimensions = &.{2},
        .byte_size = 8,
        .access = .read,
        .ownership = .retained,
        .alias = .{ .boundary = .{ .value = 1 } },
        .provenance = .{ .path = "aliases.chic", .symbol = "ownership_mismatch", .line = 3 },
    }));
    try std.testing.expectError(error.NonCanonicalBoundaryAlias, module.addBoundary(.{
        .id = .{ .value = 3 },
        .name = "chain",
        .element_type = .f32,
        .dimensions = &.{2},
        .byte_size = 8,
        .access = .read,
        .ownership = .borrowed,
        .alias = .{ .boundary = .{ .value = 2 } },
        .provenance = .{ .path = "aliases.chic", .symbol = "chain", .line = 3 },
    }));
    try module.verify();
}

test "partitioned module owns unique semantic product contracts" {
    const records = try fixture.Records.init(std.testing.allocator);
    defer records.deinit();
    var module = try PartitionedModule.init(std.testing.allocator, "products");
    defer module.deinit();

    try std.testing.expectError(error.EmptyPartition, module.addPartition(.{
        .id = .{ .value = 1 },
        .name = "",
        .pipeline = .choir,
        .product = .{ .producer = "composition-fixture", .source = "1", .stage = "product", .variant = "default" },
        .effect = .unknown,
        .provenance = .{ .path = "products.chic", .symbol = "empty_name" },
    }));
    try std.testing.expectError(error.EmptyProvenance, module.addPartition(.{
        .id = .{ .value = 1 },
        .name = "empty_provenance",
        .pipeline = .choir,
        .product = .{ .producer = "composition-fixture", .source = "1", .stage = "product", .variant = "default" },
        .effect = .unknown,
        .provenance = .{ .path = "", .symbol = "" },
    }));
    try std.testing.expectError(error.EmptyProductRef, module.addPartition(.{
        .id = .{ .value = 1 },
        .name = "empty",
        .pipeline = .choir,
        .product = .{ .producer = "composition-fixture", .source = "1", .stage = "", .variant = "default" },
        .effect = .none,
        .provenance = .{ .path = "products.chic", .symbol = "empty" },
    }));
    var product_name = [_]u8{ 'p', 'r', 'o', 'd', 'u', 'c', 't' };
    try module.addPartition(.{
        .id = .{ .value = 1 },
        .name = "first",
        .pipeline = .choir,
        .product = .{ .producer = "composition-fixture", .source = "7", .stage = &product_name, .variant = "default" },
        .effect = .read,
        .provenance = .{ .path = "products.chic", .symbol = "first" },
    });
    product_name[0] = 'x';
    try std.testing.expectEqualStrings("product", module.partitions.items[0].product.stage);
    try std.testing.expectError(error.DuplicateProductRef, module.addPartition(.{
        .id = .{ .value = 2 },
        .name = "duplicate",
        .pipeline = .accy,
        .product = .{ .producer = "composition-fixture", .source = "7", .stage = "product", .variant = "default" },
        .effect = .none,
        .provenance = .{ .path = "products.chic", .symbol = "duplicate" },
    }));
    try std.testing.expectError(error.ProductIdentityMismatch, source.PipelineInput.init(
        &module,
        .{ .value = 1 },
        .choir,
        try records.key("other", "7", "11"),
    ));
    const input = try source.PipelineInput.init(
        &module,
        .{ .value = 1 },
        .choir,
        try records.key("product", "7", "11"),
    );
    try std.testing.expectEqual(source.Effect.read, module.partitions.items[0].effect);
    try std.testing.expectEqualStrings("11", input.product.record.view().image);
}
