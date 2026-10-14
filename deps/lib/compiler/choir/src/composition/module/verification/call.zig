const std = @import("std");
const composition = @import("../../root.zig");
const model = @import("../root.zig");
const verification = @import("root.zig");

const abi = composition.abi;
const source = composition.source;

pub fn verifySpec(module: *const model.CompositionModule, spec: model.CallSiteSpec) verification.Error!void {
    const resource_count = std.math.add(usize, spec.inputs.len, spec.outputs.len) catch return error.TooManyResources;
    if (resource_count > abi.max_resources) return error.TooManyResources;
    const caller = module.fragment(spec.caller) orelse return error.MissingFragment;
    const callee = module.fragment(spec.callee) orelse return error.MissingFragment;
    const semantic = module.source_module.callSite(spec.id) orelse return error.MissingSemanticCallSite;
    if (caller.partition.value != semantic.caller.value or callee.partition.value != semantic.callee.value or
        !std.mem.eql(u8, spec.name, semantic.name)) return error.SemanticCallSiteMismatch;
    if (!std.mem.eql(u8, spec.provenance.path, semantic.provenance.path) or
        !std.mem.eql(u8, spec.provenance.symbol, semantic.provenance.symbol) or
        spec.provenance.line != semantic.provenance.line or spec.provenance.column != semantic.provenance.column)
    {
        return error.SemanticCallSiteMismatch;
    }
    if (!source.boundaryIdsEqual(spec.inputs, semantic.inputs) or !source.boundaryIdsEqual(spec.outputs, semantic.outputs)) {
        return error.BoundaryContractMismatch;
    }
    const caller_export = caller.exportByName(spec.caller_export) orelse return error.MissingExport;
    const runtime_import = caller.importByName(spec.runtime_import) orelse return error.MissingImport;
    const callee_export = callee.exportByName(spec.callee_export) orelse return error.MissingExport;
    if (runtime_import.kind != .runtime) return error.MissingImport;
    if (!std.mem.eql(u8, runtime_import.symbol, abi.invoke_symbol)) return error.RuntimeSymbolMismatch;
    if (spec.abi_version != abi.version or caller_export.abi_version != spec.abi_version or
        runtime_import.abi_version != spec.abi_version or callee_export.abi_version != spec.abi_version)
    {
        return error.AbiMismatch;
    }
}
