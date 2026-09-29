const common = @import("common.zig");

const builder = common.builder;

pub fn compare(owner: anytype, predicate: builder.Compare, lhs: builder.Value, rhs: builder.Value) !builder.Value {
    return owner.body.compare(predicate, lhs, rhs);
}

pub fn select(owner: anytype, condition: builder.Value, true_value: builder.Value, false_value: builder.Value) !builder.Value {
    return owner.body.select(condition, true_value, false_value);
}
