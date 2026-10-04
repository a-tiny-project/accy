const std = @import("std");
const tensor = @import("../root.zig");
const autodiff = tensor.autodiff;
const batch = tensor.batch;
const trace = tensor.trace;

pub fn Standard(comptime parameters: anytype) type {
    return struct {
        pub const count = arity(parameters);

        pub fn index(comptime name_value: anytype) usize {
            return parameterIndex(parameters, name_value);
        }

        pub fn indices(comptime names: anytype) *const [nameCount(names)]usize {
            return parameterIndices(parameters, names);
        }

        pub fn axes(comptime axis_spec: anytype) *const [count]batch.Axis {
            return parameterAxes(parameters, axis_spec);
        }
    };
}

pub fn Jvp(
    comptime SourceLayout: type,
    comptime parameters: anytype,
    comptime options: autodiff.JvpOptions,
) type {
    return struct {
        pub const count = SourceLayout.count + options.wrt.len;

        pub fn index(comptime name_value: anytype) usize {
            return SourceLayout.index(name_value);
        }

        pub fn indices(comptime names: anytype) *const [nameCount(names)]usize {
            return SourceLayout.indices(names);
        }

        pub fn axes(comptime axis_spec: anytype) *const [count]batch.Axis {
            return jvpParameterAxes(SourceLayout, parameters, options, axis_spec);
        }
    };
}

pub fn Args(comptime parameters: anytype) type {
    return struct {
        values: []const trace.Value,

        pub fn param(self: @This(), comptime name_value: anytype) trace.Value {
            return self.values[parameterIndex(parameters, name_value)];
        }
    };
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

pub fn nameCount(comptime names: anytype) usize {
    return switch (@typeInfo(@TypeOf(names))) {
        .@"struct" => |info| info.field_names.len,
        .enum_literal => 1,
        else => @compileError(
            "tensor parameter names must be enum literals or a tuple of enum literals",
        ),
    };
}

pub fn wrtOffset(comptime wrt: []const usize, comptime parameter_index: usize) usize {
    inline for (wrt, 0..) |item, index_value| {
        if (item == parameter_index) return index_value;
    }
    @compileError("tensor jvp tangent axis references a parameter outside wrt");
}

fn parameterIndices(
    comptime parameters: anytype,
    comptime names: anytype,
) *const [nameCount(names)]usize {
    comptime var indices_result: [nameCount(names)]usize = undefined;
    switch (@typeInfo(@TypeOf(names))) {
        .@"struct" => |info| {
            inline for (info.field_names, 0..) |field_name, index_value| {
                indices_result[index_value] = parameterIndex(parameters, @field(names, field_name));
            }
        },
        .enum_literal => indices_result[0] = parameterIndex(parameters, names),
        else => unreachable,
    }
    const final = indices_result;
    return &final;
}

fn parameterAxes(
    comptime parameters: anytype,
    comptime axes: anytype,
) *const [arity(parameters)]batch.Axis {
    comptime var result = @as([arity(parameters)]batch.Axis, @splat(.none));
    const info = @typeInfo(@TypeOf(axes));
    if (info != .@"struct" or info.@"struct".is_tuple) {
        @compileError("tensor named axes must be a struct keyed by parameter name");
    }
    inline for (info.@"struct".field_names) |field_name| {
        result[parameterIndex(parameters, field_name)] = @field(axes, field_name);
    }
    const final = result;
    return &final;
}

fn jvpParameterAxes(
    comptime SourceLayout: type,
    comptime parameters: anytype,
    comptime options: autodiff.JvpOptions,
    comptime axes: anytype,
) *const [SourceLayout.count + options.wrt.len]batch.Axis {
    comptime var result = @as([(SourceLayout.count + options.wrt.len)]batch.Axis, @splat(.none));
    const Axes = @TypeOf(axes);
    const info = @typeInfo(Axes);
    if (info != .@"struct" or info.@"struct".is_tuple) {
        @compileError("tensor jvp axes must be a struct with primals and tangents fields");
    }

    if (comptime @hasField(Axes, "primals")) {
        const primal_axes = SourceLayout.axes(axes.primals);
        inline for (0..SourceLayout.count) |index_value| {
            result[index_value] = primal_axes[index_value];
        }
    }

    if (comptime @hasField(Axes, "tangents")) {
        const tangent_axes = jvpTangentAxes(parameters, options, axes.tangents);
        inline for (0..options.wrt.len) |index_value| {
            result[SourceLayout.count + index_value] = tangent_axes[index_value];
        }
    }

    const final = result;
    return &final;
}

fn jvpTangentAxes(
    comptime parameters: anytype,
    comptime options: autodiff.JvpOptions,
    comptime axes: anytype,
) *const [options.wrt.len]batch.Axis {
    if (comptime !named(parameters)) {
        @compileError("tensor jvp tangent axes require named Program parameters");
    }
    comptime var result = @as([options.wrt.len]batch.Axis, @splat(.none));
    const Axes = @TypeOf(axes);
    const info = @typeInfo(Axes);
    if (info != .@"struct" or info.@"struct".is_tuple) {
        @compileError(
            "tensor jvp tangent axes must be a struct keyed by differentiated parameter name",
        );
    }
    inline for (info.@"struct".field_names) |field_name| {
        const parameter_index = parameterIndex(parameters, field_name);
        const tangent_index = wrtOffset(options.wrt, parameter_index);
        result[tangent_index] = @field(axes, field_name);
    }
    const final = result;
    return &final;
}

fn parameterIndex(comptime parameters: anytype, comptime name_value: anytype) usize {
    if (comptime !named(parameters)) {
        @compileError("named tensor parameter lookup requires named Program parameters");
    }
    const parameter_name = comptime name(name_value);
    comptime var found: ?usize = null;
    inline for (@typeInfo(
        @TypeOf(parameters),
    ).@"struct".field_names, 0..) |field_name, index_value| {
        if (comptime std.mem.eql(u8, field_name, parameter_name)) {
            found = index_value;
        }
    }
    return found orelse @compileError("unknown tensor parameter: " ++ parameter_name);
}

fn name(comptime name_value: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(name_value))) {
        .enum_literal => @tagName(name_value),
        .pointer => |pointer| blk: {
            if (pointer.child == u8) break :blk name_value[0..];
            if (@typeInfo(pointer.child) == .array) {
                const array = @typeInfo(pointer.child).array;
                if (array.child == u8) break :blk name_value[0..array.len];
            }
            @compileError("tensor parameter name pointers must point at string literals");
        },
        .array => |array| blk: {
            if (array.child == u8) break :blk name_value[0..];
            @compileError("tensor parameter name arrays must contain bytes");
        },
        else => @compileError("tensor parameter names must be enum literals or string literals"),
    };
}
