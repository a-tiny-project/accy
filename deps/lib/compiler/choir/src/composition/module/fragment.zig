const std = @import("std");
const choir = @import("../../root.zig");
const composition = @import("../root.zig");
const model = @import("root.zig");

const Allocator = std.mem.Allocator;
const Artifact = choir.backends.artifact.Artifact;
const product = choir.product;
const source = composition.source;

/// Borrowed serializable inputs for one compiled partition.
pub const FragmentSpec = struct {
    id: source.FragmentId,
    partition: source.PartitionId,
    pipeline: source.Pipeline,
    pipeline_input: product.ProductKey,
    artifacts: []const Artifact,
    exports: []const model.ExportSpec,
    imports: []const model.ImportSpec = &.{},
    provenance: source.ProvenanceSpec,
};

/// Owns artifact transport data and an exact input record; it grants no native reuse entitlement.
/// Process-local compiled and loaded objects remain in materialization jobs.
pub const Fragment = struct {
    id: source.FragmentId,
    partition: source.PartitionId,
    pipeline: source.Pipeline,
    pipeline_input: product.ProductKey,
    artifacts: []Artifact,
    exports: []model.Export,
    imports: []model.Import,
    provenance: source.Provenance,

    pub fn init(allocator: Allocator, spec: FragmentSpec) product.ProductMetadataError!Fragment {
        const pipeline_input = try product.cloneProductKey(allocator, spec.pipeline_input);
        errdefer product.deinitProductKey(allocator, pipeline_input);

        const artifacts = try allocator.alloc(Artifact, spec.artifacts.len);
        var artifact_count: usize = 0;
        errdefer {
            var index = artifact_count;
            while (index != 0) {
                index -= 1;
                artifacts[index].deinit();
            }
            allocator.free(artifacts);
        }
        for (spec.artifacts, 0..) |artifact_value, index| {
            artifacts[index] = try artifact_value.clone(allocator);
            artifact_count += 1;
        }

        const exports = try allocator.alloc(model.Export, spec.exports.len);
        var export_count: usize = 0;
        errdefer {
            var index = export_count;
            while (index != 0) {
                index -= 1;
                exports[index].deinit(allocator);
            }
            allocator.free(exports);
        }
        for (spec.exports, 0..) |export_spec, index| {
            exports[index] = try model.Export.init(allocator, export_spec);
            export_count += 1;
        }

        const imports: []model.Import = if (spec.imports.len == 0) &.{} else try allocator.alloc(model.Import, spec.imports.len);
        var import_count: usize = 0;
        errdefer {
            var index = import_count;
            while (index != 0) {
                index -= 1;
                imports[index].deinit(allocator);
            }
            if (imports.len != 0) allocator.free(imports);
        }
        for (spec.imports, 0..) |import_spec, index| {
            imports[index] = try model.Import.init(allocator, import_spec);
            import_count += 1;
        }

        return .{
            .id = spec.id,
            .partition = spec.partition,
            .pipeline = spec.pipeline,
            .pipeline_input = pipeline_input,
            .artifacts = artifacts,
            .exports = exports,
            .imports = imports,
            .provenance = try source.Provenance.init(allocator, spec.provenance),
        };
    }

    pub fn deinit(self: *Fragment, allocator: Allocator) void {
        self.provenance.deinit(allocator);
        var import_index = self.imports.len;
        while (import_index != 0) {
            import_index -= 1;
            self.imports[import_index].deinit(allocator);
        }
        if (self.imports.len != 0) allocator.free(self.imports);
        var export_index = self.exports.len;
        while (export_index != 0) {
            export_index -= 1;
            self.exports[export_index].deinit(allocator);
        }
        allocator.free(self.exports);
        var artifact_index = self.artifacts.len;
        while (artifact_index != 0) {
            artifact_index -= 1;
            self.artifacts[artifact_index].deinit();
        }
        allocator.free(self.artifacts);
        product.deinitProductKey(allocator, self.pipeline_input);
        self.* = undefined;
    }

    pub fn exportByName(self: *const Fragment, name: []const u8) ?*const model.Export {
        for (self.exports) |*export_value| {
            if (std.mem.eql(u8, export_value.name, name)) return export_value;
        }
        return null;
    }

    pub fn importByName(self: *const Fragment, name: []const u8) ?*const model.Import {
        for (self.imports) |*import_value| {
            if (std.mem.eql(u8, import_value.name, name)) return import_value;
        }
        return null;
    }

    pub fn providesSymbol(self: *const Fragment, symbol: []const u8) bool {
        for (self.artifacts) |artifact_value| {
            if (artifact_value.linkage.hasProvided(symbol)) return true;
        }
        return false;
    }

    pub fn requiresSymbol(self: *const Fragment, symbol: []const u8) bool {
        for (self.artifacts) |artifact_value| {
            if (artifact_value.linkage.hasRequired(symbol)) return true;
        }
        return false;
    }
};
