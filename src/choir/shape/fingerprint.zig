const choir = @import("choir");

const expression = @import("expression.zig");
const fact = @import("fact.zig");
const family_mod = @import("family.zig");
const tensor = @import("tensor.zig");

pub fn family(value: family_mod.Family) choir.product.incremental.Fingerprint {
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes("accy.choir.shape.family");
    builder.updateBytes(value.name);
    builder.updateUsize(value.symbols.len);
    for (value.symbols) |symbol| builder.updateBytes(symbol.name);
    builder.updateUsize(value.tensors.len);
    for (value.tensors) |tensor_value| hashTensor(&builder, tensor_value);
    builder.updateUsize(value.facts.len);
    for (value.facts) |fact_value| hashFact(&builder, fact_value);
    return builder.finish();
}

fn hashTensor(builder: *choir.product.incremental.FingerprintBuilder, value: tensor.Tensor) void {
    builder.updateBytes(value.name);
    builder.updateUsize(value.extents.len);
    for (value.extents) |extent| hashExpression(builder, extent);
}

fn hashFact(builder: *choir.product.incremental.FingerprintBuilder, value: fact.Fact) void {
    builder.updateEnumTag(value.mode);
    builder.updateEnumTag(value.predicate);
    switch (value.predicate) {
        .equal => |equal| {
            hashExpression(builder, equal.lhs);
            hashExpression(builder, equal.rhs);
        },
        .bound => |bound| {
            hashExpression(builder, bound.value);
            hashBounds(builder, bound.bounds);
        },
        .divisible => |divisible| {
            hashExpression(builder, divisible.value);
            builder.updateU64(divisible.divisor);
        },
    }
}

fn hashExpression(builder: *choir.product.incremental.FingerprintBuilder, value: expression.Expression) void {
    builder.updateI64(value.constant);
    builder.updateUsize(value.terms.len);
    for (value.terms) |term| {
        builder.updateU32(term.symbol);
        builder.updateI64(term.coefficient);
    }
}

fn hashBounds(builder: *choir.product.incremental.FingerprintBuilder, value: fact.Bounds) void {
    builder.updateOptionalU64(value.min);
    builder.updateOptionalU64(value.opt);
    builder.updateOptionalU64(value.max);
}
