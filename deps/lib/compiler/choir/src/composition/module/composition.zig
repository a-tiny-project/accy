const std = @import("std");
const choir = @import("../../root.zig");
const composition = @import("../root.zig");
const model = @import("root.zig");
const verification = @import("verification/root.zig");

const Allocator = std.mem.Allocator;
const Artifact = choir.backends.artifact.Artifact;
const backends = choir.backends;
const bytecode = choir.bytecode;
const product = choir.product;
const source = composition.source;

pub const VerificationError = verification.Error;

pub const DiagnosticPath = struct {
    source: *const source.Provenance,
    variant: *const model.CompositionVariant,
    partition: *const source.Partition,
    pipeline_input: product.ProductKey,
    fragment: *const model.Fragment,
    fragment_export: *const model.Export,
    call_site: *const model.CallSite,
    artifact: *const Artifact,
};

/// Owns the serializable whole-program product: source contracts, fragments, and variants.
/// `init` clones its source module so the result has one independent lifetime.
pub const CompositionModule = struct {
    allocator: Allocator,
    source_module: source.PartitionedModule,
    fragments: std.ArrayList(model.Fragment) = .empty,
    variants: std.ArrayList(model.CompositionVariant) = .empty,

    pub fn init(allocator: Allocator, partitioned: *const source.PartitionedModule) Allocator.Error!CompositionModule {
        return .{
            .allocator = allocator,
            .source_module = try partitioned.clone(allocator),
        };
    }

    pub fn deinit(self: *CompositionModule) void {
        var variant_index = self.variants.items.len;
        while (variant_index != 0) {
            variant_index -= 1;
            self.variants.items[variant_index].deinit(self.allocator);
        }
        self.variants.deinit(self.allocator);
        var fragment_index = self.fragments.items.len;
        while (fragment_index != 0) {
            fragment_index -= 1;
            self.fragments.items[fragment_index].deinit(self.allocator);
        }
        self.fragments.deinit(self.allocator);
        self.source_module.deinit();
        self.* = undefined;
    }

    pub fn addFragment(self: *CompositionModule, spec: model.FragmentSpec) (Allocator.Error || VerificationError)!void {
        if (self.fragment(spec.id) != null) return error.DuplicateFragment;
        const partition_value = self.source_module.partition(spec.partition) orelse return error.MissingPartition;
        if (partition_value.pipeline != spec.pipeline) return error.PipelineMismatch;
        if (!partition_value.product.eql(spec.pipeline_input.ref)) return error.ProductIdentityMismatch;
        try verification.verifyFragmentSpec(spec);
        var fragment_value = try model.Fragment.init(self.allocator, spec);
        errdefer fragment_value.deinit(self.allocator);
        try self.fragments.append(self.allocator, fragment_value);
    }

    pub fn addVariant(self: *CompositionModule, spec: model.CompositionVariantSpec) (Allocator.Error || VerificationError)!void {
        try verification.verifyCompositionVariantSpec(self, spec);
        var variant_value = try model.CompositionVariant.init(self.allocator, spec);
        errdefer variant_value.deinit(self.allocator);
        try self.variants.append(self.allocator, variant_value);
    }

    pub fn verify(self: *const CompositionModule) VerificationError!void {
        try verification.verifyModule(self);
    }

    pub fn fragment(self: *const CompositionModule, id: source.FragmentId) ?*const model.Fragment {
        for (self.fragments.items) |*fragment_value| {
            if (fragment_value.id.value == id.value) return fragment_value;
        }
        return null;
    }

    pub fn variant(self: *const CompositionModule, id: model.CompositionVariantId) ?*const model.CompositionVariant {
        for (self.variants.items) |*variant_value| {
            if (variant_value.id.value == id.value) return variant_value;
        }
        return null;
    }

    pub fn selectVariant(self: *const CompositionModule, choice: model.TargetChoiceSpec) ?*const model.CompositionVariant {
        for (self.variants.items) |*variant_value| {
            if (variant_value.choice.eql(choice)) return variant_value;
        }
        return null;
    }

    pub fn diagnosticPath(
        self: *const CompositionModule,
        variant_id: model.CompositionVariantId,
        id: source.CallSiteId,
    ) VerificationError!DiagnosticPath {
        const variant_value = self.variant(variant_id) orelse return error.MissingCompositionVariant;
        const call_site = variant_value.callSite(id) orelse return error.MissingSemanticCallSite;
        const fragment_value = self.fragment(call_site.callee) orelse return error.MissingFragment;
        const partition_value = self.source_module.partition(fragment_value.partition) orelse return error.MissingPartition;
        const semantic = self.source_module.callSite(id) orelse return error.MissingSemanticCallSite;
        const export_value = fragment_value.exportByName(call_site.callee_export) orelse return error.MissingExport;
        const artifact_value = artifactProviding(fragment_value, export_value.symbol) orelse return error.MissingProvidedSymbol;
        return .{
            .source = &semantic.provenance,
            .variant = variant_value,
            .partition = partition_value,
            .pipeline_input = fragment_value.pipeline_input,
            .fragment = fragment_value,
            .fragment_export = export_value,
            .call_site = call_site,
            .artifact = artifact_value,
        };
    }

    pub fn bytecodeResourceCount(self: *const CompositionModule) usize {
        var count: usize = 0;
        for (self.fragments.items) |fragment_value| {
            for (fragment_value.artifacts) |artifact_value| count += backends.artifact.resource.count(artifact_value);
        }
        return count;
    }

    pub fn writeBytecodeResources(
        self: *const CompositionModule,
        out: []bytecode.Resource,
    ) backends.artifact.resource.Error![]const bytecode.Resource {
        const required = self.bytecodeResourceCount();
        if (out.len < required) return error.NoSpaceLeft;
        var offset: usize = 0;
        for (self.fragments.items) |fragment_value| {
            for (fragment_value.artifacts) |artifact_value| {
                const resources = try backends.artifact.resource.write(artifact_value, out[offset..]);
                offset += resources.len;
            }
        }
        return out[0..offset];
    }
};

fn artifactProviding(fragment_value: *const model.Fragment, symbol: []const u8) ?*const Artifact {
    for (fragment_value.artifacts) |*artifact_value| {
        if (artifact_value.linkage.hasProvided(symbol)) return artifact_value;
    }
    return null;
}
