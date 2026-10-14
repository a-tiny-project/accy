const model = @import("../root.zig");
const source = @import("../../source/root.zig");
const verification = @import("root.zig");

pub fn verifySpec(
    module: *const model.CompositionModule,
    spec: model.CompositionVariantSpec,
) verification.Error!void {
    if (spec.choice.target.stage.len == 0) return error.EmptyTargetIdentity;
    if (spec.choice.policy.stage.len == 0) return error.EmptyPolicyIdentity;
    if (module.variant(spec.id) != null) return error.DuplicateCompositionVariant;
    if (module.selectVariant(spec.choice) != null) return error.DuplicateTargetChoice;
    if (spec.fragments.len != module.source_module.partitions.items.len) return error.MissingPartitionFragment;
    for (spec.fragments, 0..) |fragment_id, index| {
        const fragment_value = module.fragment(fragment_id) orelse return error.MissingFragment;
        for (spec.fragments[0..index]) |previous_id| {
            if (previous_id.value == fragment_id.value) return error.DuplicateFragment;
            const previous = module.fragment(previous_id) orelse return error.MissingFragment;
            if (previous.partition.value == fragment_value.partition.value) return error.DuplicatePartitionFragment;
        }
    }
    if (spec.call_sites.len != module.source_module.call_sites.items.len) return error.MissingSemanticCallSite;
    for (spec.call_sites, 0..) |call_spec, index| {
        for (spec.call_sites[0..index]) |previous| {
            if (previous.id.value == call_spec.id.value) return error.DuplicateCallSite;
        }
        if (!containsFragment(spec.fragments, call_spec.caller) or
            !containsFragment(spec.fragments, call_spec.callee))
        {
            return error.FragmentOutsideVariant;
        }
        try verification.call.verifySpec(module, call_spec);
    }
}

pub fn verifyValue(
    module: *const model.CompositionModule,
    variant_value: *const model.CompositionVariant,
) verification.Error!void {
    if (variant_value.choice.target.stage.len == 0) return error.EmptyTargetIdentity;
    if (variant_value.choice.policy.stage.len == 0) return error.EmptyPolicyIdentity;
    if (variant_value.fragments.len != module.source_module.partitions.items.len) return error.MissingPartitionFragment;
    for (variant_value.fragments, 0..) |fragment_id, index| {
        const fragment_value = module.fragment(fragment_id) orelse return error.MissingFragment;
        for (variant_value.fragments[0..index]) |previous_id| {
            if (previous_id.value == fragment_id.value) return error.DuplicateFragment;
            const previous = module.fragment(previous_id) orelse return error.MissingFragment;
            if (previous.partition.value == fragment_value.partition.value) return error.DuplicatePartitionFragment;
        }
    }
    if (variant_value.call_sites.len != module.source_module.call_sites.items.len) return error.MissingSemanticCallSite;
    for (variant_value.call_sites, 0..) |*call_site, index| {
        for (variant_value.call_sites[0..index]) |previous| {
            if (previous.id.value == call_site.id.value) return error.DuplicateCallSite;
        }
        if (!variant_value.containsFragment(call_site.caller) or
            !variant_value.containsFragment(call_site.callee))
        {
            return error.FragmentOutsideVariant;
        }
        try verification.call.verifySpec(module, .{
            .id = call_site.id,
            .name = call_site.name,
            .caller = call_site.caller,
            .caller_export = call_site.caller_export,
            .runtime_import = call_site.runtime_import,
            .callee = call_site.callee,
            .callee_export = call_site.callee_export,
            .inputs = call_site.inputs,
            .outputs = call_site.outputs,
            .abi_version = call_site.abi_version,
            .provenance = .{
                .path = call_site.provenance.path,
                .symbol = call_site.provenance.symbol,
                .line = call_site.provenance.line,
                .column = call_site.provenance.column,
            },
        });
    }
}

fn containsFragment(fragments: []const source.FragmentId, id: source.FragmentId) bool {
    for (fragments) |fragment_id| {
        if (fragment_id.value == id.value) return true;
    }
    return false;
}
