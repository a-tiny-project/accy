const kernel = @import("../root.zig");
const parameter = @import("../program/root.zig").parameter;

pub fn call(comptime definition: anytype, builder: anytype) !void {
    if (comptime parameter.named(definition.parameters)) {
        try definition.body(builder, parameter.Args(
            definition.parameters,
            PointerChild(@TypeOf(builder)),
        ){ .builder = builder });
    } else {
        const count = comptime parameter.arity(definition.parameters);
        var args: [count]kernel.Value = undefined;
        inline for (0..count) |index_value| {
            args[index_value] = builder.argument(index_value);
        }
        try definition.body(builder, args[0..]);
    }
}

pub fn callInstance(comptime definition: anytype, instance: anytype, builder: anytype) !void {
    if (comptime parameter.named(definition.parameters)) {
        try definition.body(builder, instance, parameter.Args(
            definition.parameters,
            PointerChild(@TypeOf(builder)),
        ){ .builder = builder });
    } else {
        const count = comptime parameter.arity(definition.parameters);
        var args: [count]kernel.Value = undefined;
        inline for (0..count) |index_value| {
            args[index_value] = builder.argument(index_value);
        }
        try definition.body(builder, instance, args[0..]);
    }
}

fn PointerChild(comptime Pointer: type) type {
    return switch (@typeInfo(Pointer)) {
        .pointer => |info| info.child,
        else => @compileError("kernel Program bodies receive builder pointers"),
    };
}
