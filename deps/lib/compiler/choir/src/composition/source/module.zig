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
