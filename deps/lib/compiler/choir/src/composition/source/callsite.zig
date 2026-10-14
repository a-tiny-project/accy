const std = @import("std");
const source = @import("root.zig");

const Allocator = std.mem.Allocator;

pub const SemanticCallSiteSpec = struct {
    id: source.CallSiteId,
    name: []const u8,
    caller: source.PartitionId,
    callee: source.PartitionId,
    inputs: []const source.BoundaryId,
    outputs: []const source.BoundaryId,
    provenance: source.ProvenanceSpec,
};

pub const SemanticCallSite = struct {
    id: source.CallSiteId,
    name: []const u8,
    caller: source.PartitionId,
    callee: source.PartitionId,
    inputs: []const source.BoundaryId,
    outputs: []const source.BoundaryId,
    provenance: source.Provenance,

    pub fn init(allocator: Allocator, spec: SemanticCallSiteSpec) Allocator.Error!SemanticCallSite {
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        const inputs = try source.slice.dupeOrEmpty(source.BoundaryId, allocator, spec.inputs);
        errdefer source.slice.freeOrEmpty(source.BoundaryId, allocator, inputs);
        const outputs = try source.slice.dupeOrEmpty(source.BoundaryId, allocator, spec.outputs);
        errdefer source.slice.freeOrEmpty(source.BoundaryId, allocator, outputs);
        return .{
            .id = spec.id,
            .name = name,
            .caller = spec.caller,
            .callee = spec.callee,
            .inputs = inputs,
            .outputs = outputs,
            .provenance = try source.Provenance.init(allocator, spec.provenance),
        };
    }

    pub fn clone(self: SemanticCallSite, allocator: Allocator) Allocator.Error!SemanticCallSite {
        return try init(allocator, .{
            .id = self.id,
            .name = self.name,
            .caller = self.caller,
            .callee = self.callee,
            .inputs = self.inputs,
            .outputs = self.outputs,
            .provenance = .{
                .path = self.provenance.path,
                .symbol = self.provenance.symbol,
                .line = self.provenance.line,
                .column = self.provenance.column,
            },
        });
    }

    pub fn deinit(self: *SemanticCallSite, allocator: Allocator) void {
        self.provenance.deinit(allocator);
        source.slice.freeOrEmpty(source.BoundaryId, allocator, self.outputs);
        source.slice.freeOrEmpty(source.BoundaryId, allocator, self.inputs);
        allocator.free(self.name);
        self.* = undefined;
    }
};
