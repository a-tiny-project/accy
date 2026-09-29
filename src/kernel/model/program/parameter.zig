const std = @import("std");
const kernel = @import("../core/root.zig");

pub fn Standard(comptime parameters: anytype) type {
    return struct {
        pub const count = arity(parameters);

        pub fn index(comptime name_value: anytype) usize {
            return parameterIndex(parameters, name_value);
        }
    };
}

pub fn Args(comptime parameters: anytype, comptime Builder: type) type {
    return struct {
        builder: *Builder,

        pub fn param(self: @This(), comptime name_value: anytype) Value(parameterSpec(parameters, name_value)) {
            return argument(self.builder, parameterSpec(parameters, name_value), parameterIndex(parameters, name_value));
        }
    };
}

pub fn Value(comptime param: kernel.Param) type {
    return switch (param) {
        .scalar => |dtype| kernel.TypedValue(dtype),
        .buffer => |buffer| kernel.BufferView(buffer.dtype),
    };
}

pub fn schema(comptime parameters: anytype) *const [arity(parameters)]kernel.Param {
    const count = comptime arity(parameters);
    comptime var result: [count]kernel.Param = undefined;
    if (comptime named(parameters)) {
        inline for (@typeInfo(@TypeOf(parameters)).@"struct".field_names, 0..) |field_name, index_value| {
            result[index_value] = @field(parameters, field_name);
        }
    } else {
        inline for (0..count) |index_value| {
            result[index_value] = parameters[index_value];
        }
    }
    const final = result;
    return &final;
}

pub fn named(comptime parameters: anytype) bool {
    return switch (@typeInfo(@TypeOf(parameters))) {
        .@"struct" => |info| !info.is_tuple,
        else => false,
    };
}

pub fn arity(comptime parameters: anytype) usize {
    return if (comptime named(parameters))
        @typeInfo(@TypeOf(parameters)).@"struct".field_names.len
    else
        parameters.len;
}

fn argument(builder: anytype, comptime param: kernel.Param, comptime index_value: usize) Value(param) {
    return switch (param) {
        .scalar => |dtype| builder.typedArgument(dtype, index_value),
        .buffer => |buffer| builder.bufferArgument(buffer.dtype, index_value),
    };
}

fn parameterSpec(comptime parameters: anytype, comptime name_value: anytype) kernel.Param {
    if (comptime !named(parameters)) {
        @compileError("named kernel parameter lookup requires named Program parameters");
    }
    const parameter_name = comptime name(name_value);
    inline for (@typeInfo(@TypeOf(parameters)).@"struct".field_names) |field_name| {
        if (comptime std.mem.eql(u8, field_name, parameter_name)) {
            return @field(parameters, field_name);
        }
    }
    @compileError("unknown kernel parameter: " ++ parameter_name);
}

fn parameterIndex(comptime parameters: anytype, comptime name_value: anytype) usize {
    if (comptime !named(parameters)) {
        @compileError("named kernel parameter lookup requires named Program parameters");
    }
    const parameter_name = comptime name(name_value);
    comptime var found: ?usize = null;
    inline for (@typeInfo(@TypeOf(parameters)).@"struct".field_names, 0..) |field_name, index_value| {
        if (comptime std.mem.eql(u8, field_name, parameter_name)) {
            found = index_value;
        }
    }
    return found orelse @compileError("unknown kernel parameter: " ++ parameter_name);
}

fn name(comptime name_value: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(name_value))) {
        .enum_literal => @tagName(name_value),
        else => @compileError("kernel parameter names must be enum literals"),
    };
}
