const std = @import("std");
const product = @import("../../product/root.zig");
const source = @import("root.zig");

const Allocator = std.mem.Allocator;

/// Borrowed facts for one closed semantic region selected by the source compiler.
/// Captures, results, effects, and cross-partition boundaries must already be explicit.
pub const PartitionSpec = struct {
    id: source.PartitionId,
    name: []const u8,
    pipeline: source.Pipeline,
    inputs: []const source.BoundaryId = &.{},
    outputs: []const source.BoundaryId = &.{},
    product: product.ProductRef,
    effect: Effect,
    provenance: source.ProvenanceSpec,
};

pub const Effect = enum(u8) {
    none,
    read,
    write,
    read_write,
    unknown,
};

/// An owned semantic region with a frontend-stable identity and source provenance.
pub const Partition = struct {
    id: source.PartitionId,
    name: []const u8,
    pipeline: source.Pipeline,
    inputs: []const source.BoundaryId,
    outputs: []const source.BoundaryId,
    product: product.ProductRef,
    effect: Effect,
    provenance: source.Provenance,

    pub fn init(allocator: Allocator, spec: PartitionSpec) Allocator.Error!Partition {
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        const inputs = try source.slice.dupeOrEmpty(source.BoundaryId, allocator, spec.inputs);
        errdefer source.slice.freeOrEmpty(source.BoundaryId, allocator, inputs);
        const outputs = try source.slice.dupeOrEmpty(source.BoundaryId, allocator, spec.outputs);
        errdefer source.slice.freeOrEmpty(source.BoundaryId, allocator, outputs);
        const product_ref = try product.cloneProductRef(allocator, spec.product);
        errdefer product.deinitProductRef(allocator, product_ref);
        return .{
            .id = spec.id,
            .name = name,
            .pipeline = spec.pipeline,
            .inputs = inputs,
            .outputs = outputs,
            .product = product_ref,
            .effect = spec.effect,
            .provenance = try source.Provenance.init(allocator, spec.provenance),
        };
    }

    pub fn clone(self: Partition, allocator: Allocator) Allocator.Error!Partition {
        return try init(allocator, .{
            .id = self.id,
            .name = self.name,
            .pipeline = self.pipeline,
            .inputs = self.inputs,
            .outputs = self.outputs,
            .product = self.product,
            .effect = self.effect,
            .provenance = .{
                .path = self.provenance.path,
                .symbol = self.provenance.symbol,
                .line = self.provenance.line,
                .column = self.provenance.column,
            },
        });
    }

    pub fn deinit(self: *Partition, allocator: Allocator) void {
        self.provenance.deinit(allocator);
        product.deinitProductRef(allocator, self.product);
        source.slice.freeOrEmpty(source.BoundaryId, allocator, self.outputs);
        source.slice.freeOrEmpty(source.BoundaryId, allocator, self.inputs);
        allocator.free(self.name);
        self.* = undefined;
    }
};
