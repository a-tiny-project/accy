const model = @import("../root.zig");
const product = @import("../../../product/root.zig");
const verification = @import("root.zig");

pub fn verify(module: *const model.CompositionModule) verification.Error!void {
    try module.source_module.verify();
    for (module.fragments.items, 0..) |*fragment_value, index| {
        for (module.fragments.items[0..index]) |previous| {
            if (previous.id.value == fragment_value.id.value) return error.DuplicateFragment;
            try verifyCompatibleProductKeys(previous.pipeline_input, fragment_value.pipeline_input);
        }
        const partition_value = module.source_module.partition(fragment_value.partition) orelse return error.MissingPartition;
        if (partition_value.pipeline != fragment_value.pipeline) return error.PipelineMismatch;
        if (!partition_value.product.eql(fragment_value.pipeline_input.ref)) return error.ProductIdentityMismatch;
        fragment_value.pipeline_input.validate() catch return error.ProductIdentityMismatch;
        try verification.fragment.verifyValue(fragment_value);
    }
    if (module.variants.items.len == 0) return error.MissingCompositionVariant;
    for (module.variants.items, 0..) |*variant_value, index| {
        for (module.variants.items[0..index]) |previous| {
            if (previous.id.value == variant_value.id.value) return error.DuplicateCompositionVariant;
            if (previous.choice.asSpec().eql(variant_value.choice.asSpec())) return error.DuplicateTargetChoice;
        }
        try verification.variant.verifyValue(module, variant_value);
    }
    for (module.fragments.items) |fragment_value| {
        var referenced = false;
        for (module.variants.items) |variant_value| {
            if (variant_value.containsFragment(fragment_value.id)) {
                referenced = true;
                break;
            }
        }
        if (!referenced) return error.UnreferencedFragment;
    }
}

fn verifyCompatibleProductKeys(left: product.ProductKey, right: product.ProductKey) verification.Error!void {
    if (left.ref.eql(right.ref) and !left.eql(right)) return error.ConflictingProductKey;
}
