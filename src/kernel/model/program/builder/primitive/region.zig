const common = @import("common.zig");

const builder = common.builder;

pub fn if_(owner: anytype, condition: builder.Value, result_types: []const builder.Type) !builder.If {
    return owner.body.if_(condition, result_types);
}

pub fn for_(owner: anytype, lower: builder.Value, upper: builder.Value, step: builder.Value, init_args: []const builder.Value, result_types: []const builder.Type) !builder.For {
    return owner.body.for_(lower, upper, step, init_args, result_types);
}

pub fn forScope(owner: anytype, lower: builder.Value, upper: builder.Value, step: builder.Value, init_args: []const builder.Value, result_types: []const builder.Type) !builder.ForScope {
    return owner.body.forScope(lower, upper, step, init_args, result_types);
}

pub fn while_(owner: anytype, init_args: []const builder.Value, result_types: []const builder.Type) !builder.While {
    return owner.body.while_(init_args, result_types);
}

pub fn whileScope(owner: anytype, init_args: []const builder.Value, result_types: []const builder.Type) !builder.WhileScope {
    return owner.body.whileScope(init_args, result_types);
}

pub fn condition_(owner: anytype, cond: builder.Value, args: []const builder.Value) !void {
    try owner.body.condition_(cond, args);
}

pub fn yield_(owner: anytype, values: []const builder.Value) !void {
    try owner.body.yield_(values);
}

pub fn return_(owner: anytype) !void {
    try owner.body.return_();
}
