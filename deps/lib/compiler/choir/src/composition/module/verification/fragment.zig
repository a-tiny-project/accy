const std = @import("std");
const artifact = @import("../../../backends/root.zig").artifact;
const model = @import("../root.zig");
const verification = @import("root.zig");

pub fn verifySpec(spec: model.FragmentSpec) verification.Error!void {
    try spec.pipeline_input.validate();
    if (spec.artifacts.len == 0) return error.MissingArtifact;
    if (spec.exports.len == 0) return error.MissingExport;
    for (spec.artifacts) |artifact_value| if (artifact.resource.count(artifact_value) == 0) return error.EmptyArtifact;
    for (spec.exports, 0..) |export_value, index| {
        if (export_value.name.len == 0 or export_value.symbol.len == 0) return error.EmptyExport;
        for (spec.exports[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, export_value.name)) return error.DuplicateExport;
        }
    }
    for (spec.imports, 0..) |import_value, index| {
        if (import_value.name.len == 0 or import_value.symbol.len == 0) return error.EmptyImport;
        for (spec.imports[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, import_value.name)) return error.DuplicateImport;
        }
    }
}

pub fn verifyValue(fragment_value: *const model.Fragment) verification.Error!void {
    try fragment_value.pipeline_input.validate();
    if (fragment_value.artifacts.len == 0) return error.MissingArtifact;
    if (fragment_value.exports.len == 0) return error.MissingExport;
    for (fragment_value.artifacts) |artifact_value| if (artifact.resource.count(artifact_value) == 0) return error.EmptyArtifact;
    for (fragment_value.exports, 0..) |export_value, index| {
        if (export_value.name.len == 0 or export_value.symbol.len == 0) return error.EmptyExport;
        for (fragment_value.exports[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, export_value.name)) return error.DuplicateExport;
        }
        if (!fragment_value.providesSymbol(export_value.symbol)) return error.MissingProvidedSymbol;
    }
    for (fragment_value.imports, 0..) |import_value, index| {
        if (import_value.name.len == 0 or import_value.symbol.len == 0) return error.EmptyImport;
        for (fragment_value.imports[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, import_value.name)) return error.DuplicateImport;
        }
        if (!fragment_value.requiresSymbol(import_value.symbol)) return error.MissingRequiredSymbol;
    }
}
