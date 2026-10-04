const std = @import("std");
const composition = @import("../root.zig");

const Allocator = std.mem.Allocator;
const source = composition.source;

pub const CallSiteSpec = struct {
    id: source.CallSiteId,
    name: []const u8,
    caller: source.FragmentId,
    caller_export: []const u8,
    runtime_import: []const u8,
    callee: source.FragmentId,
    callee_export: []const u8,
    inputs: []const source.BoundaryId,
    outputs: []const source.BoundaryId,
    abi_version: u32,
    provenance: source.ProvenanceSpec,
};

pub const CallSite = struct {
    id: source.CallSiteId,
    name: []const u8,
    caller: source.FragmentId,
    caller_export: []const u8,
    runtime_import: []const u8,
    callee: source.FragmentId,
    callee_export: []const u8,
    inputs: []const source.BoundaryId,
    outputs: []const source.BoundaryId,
    abi_version: u32,
    provenance: source.Provenance,

    pub fn init(allocator: Allocator, spec: CallSiteSpec) Allocator.Error!CallSite {
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        const caller_export = try allocator.dupe(u8, spec.caller_export);
        errdefer allocator.free(caller_export);
        const runtime_import = try allocator.dupe(u8, spec.runtime_import);
        errdefer allocator.free(runtime_import);
        const callee_export = try allocator.dupe(u8, spec.callee_export);
        errdefer allocator.free(callee_export);
        const inputs = try source.slice.dupeOrEmpty(source.BoundaryId, allocator, spec.inputs);
        errdefer source.slice.freeOrEmpty(source.BoundaryId, allocator, inputs);
        const outputs = try source.slice.dupeOrEmpty(source.BoundaryId, allocator, spec.outputs);
        errdefer source.slice.freeOrEmpty(source.BoundaryId, allocator, outputs);
        return .{
            .id = spec.id,
            .name = name,
            .caller = spec.caller,
            .caller_export = caller_export,
            .runtime_import = runtime_import,
            .callee = spec.callee,
            .callee_export = callee_export,
            .inputs = inputs,
            .outputs = outputs,
            .abi_version = spec.abi_version,
            .provenance = try source.Provenance.init(allocator, spec.provenance),
        };
    }

    pub fn deinit(self: *CallSite, allocator: Allocator) void {
        self.provenance.deinit(allocator);
        source.slice.freeOrEmpty(source.BoundaryId, allocator, self.outputs);
        source.slice.freeOrEmpty(source.BoundaryId, allocator, self.inputs);
        allocator.free(self.callee_export);
        allocator.free(self.runtime_import);
        allocator.free(self.caller_export);
        allocator.free(self.name);
        self.* = undefined;
    }
};
