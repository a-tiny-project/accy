const ir = @import("../../core/root.zig");
const rewrite = ir.rewrite;
const egraph = @import("../../egraph/root.zig");

pub const types = @import("types.zig");
pub const folds = @import("folds.zig");
pub const patterns = @import("patterns.zig");
pub const rules = @import("rules.zig");
pub const scalar = @import("scalar.zig");
pub const eval = @import("eval.zig");
pub const effects = @import("effects.zig");
pub const predicate = @import("predicate.zig");
const ops = @import("ops.zig");

pub const ScalarKind = types.ScalarKind;
pub const ScalarClass = types.ScalarClass;
pub const ScalarDescriptor = types.ScalarDescriptor;
pub const ScalarSet = types.ScalarSet;
pub const VectorTypeInfo = types.VectorTypeInfo;
pub const type_names = types.type_names;
pub const scalarDescriptor = types.scalarDescriptor;
pub const scalarTypeName = types.scalarTypeName;
pub const scalarTypeSuffix = types.scalarTypeSuffix;
pub const scalarKindFromTypeName = types.scalarKindFromTypeName;
pub const scalarKindFromType = types.scalarKindFromType;
pub const scalarKindFromSuffix = types.scalarKindFromSuffix;
pub const scalarKindIsInteger = types.scalarKindIsInteger;
pub const scalarKindIsSignedInteger = types.scalarKindIsSignedInteger;
pub const scalarKindIsUnsignedInteger = types.scalarKindIsUnsignedInteger;
pub const scalarKindIsFloat = types.scalarKindIsFloat;
pub const scalarBitWidth = types.scalarBitWidth;
pub const vectorTypeName = types.vectorTypeName;
pub const vectorTypeNameForElement = types.vectorTypeNameForElement;
pub const parseVectorTypeName = types.parseVectorTypeName;
pub const CmpPredicate = predicate.CmpPredicate;
pub const ArithDialect = ops.ArithDialect;

const pattern_set = patterns.Patterns(ArithDialect);
const rule_set = rules.Rules(ArithDialect);
pub const canonicalization_patterns = pattern_set.canonicalization_patterns;

pub const spec = ir.dialects.dialectSpec(ArithDialect, .{
    .types = types.registeredTypeSpecs(),
    .interfaces = &.{
        rewrite.DialectCanonicalizationInterface.entryFor(
            ArithDialect.name,
            &canonicalization_patterns,
        ),
    },
    .op_interface_fallbacks = &.{
        .{ .id = ir.interfaces.Evaluatable.id, .fallback = eval.fallback },
    },
});

pub fn populateEGraphRules(rewrite_set: *egraph.RewriteSet) anyerror!void {
    try rule_set.populateEGraphRules(rewrite_set);
}
