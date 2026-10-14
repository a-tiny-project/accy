const std = @import("std");
const tensor = @import("../root.zig");
const trace = tensor.trace;
const parameter = @import("parameter.zig");

pub fn buildInputs(builder: *trace.Builder, comptime parameters: anytype) ![]trace.Value {
    const input_count = comptime parameter.arity(parameters);
    const args = try builder.arena.allocator().alloc(trace.Value, input_count);
    if (comptime parameter.named(parameters)) {
        inline for (@typeInfo(
            @TypeOf(parameters),
        ).@"struct".field_names, 0..) |field_name, index_value| {
            args[index_value] = try builder.inputSpec(@field(parameters, field_name));
        }
    } else {
        inline for (0..input_count) |index_value| {
            args[index_value] = try builder.inputSpec(parameters[index_value]);
        }
    }
    return args;
}

pub fn call(
    comptime definition: anytype,
    builder: *trace.Builder,
    args: []const trace.Value,
) ![]const trace.Value {
    const result = if (comptime parameter.named(definition.parameters))
        try definition.body(builder, parameter.Args(definition.parameters){ .values = args })
    else
        try definition.body(builder, args);
    return collectOutputs(builder, result);
}

fn collectOutputs(builder: *trace.Builder, result: anytype) ![]const trace.Value {
    const Result = @TypeOf(result);
    if (comptime Result == trace.Value) {
        const outputs = try builder.arena.allocator().alloc(trace.Value, 1);
        outputs[0] = result;
        return outputs;
    }

    return switch (@typeInfo(Result)) {
        .array => |array| blk: {
            if (array.child != trace.Value) {
                @compileError("tensor Program array outputs must contain tensor Values");
            }
            const outputs = try builder.arena.allocator().alloc(trace.Value, array.len);
            for (result, 0..) |output, index_value| {
                outputs[index_value] = output;
            }
            break :blk outputs;
        },
        .pointer => |pointer| collectPointerOutputs(builder, result, pointer),
        .@"struct" => |info| blk: {
            if (info.field_names.len == 0) {
                @compileError("tensor Program bodies must return at least one output");
            }
            const outputs = try builder.arena.allocator().alloc(trace.Value, info.field_names.len);
            inline for (info.field_names, info.field_types, 0..) |field_name, field_type, index_value| {
                if (field_type != trace.Value) {
                    @compileError("tensor Program struct outputs must contain tensor Values");
                }
                outputs[index_value] = @field(result, field_name);
            }
            break :blk outputs;
        },
        else => @compileError(
            "tensor Program bodies must return a Value, array, slice, or struct of Values",
        ),
    };
}

fn collectPointerOutputs(
    builder: *trace.Builder,
    result: anytype,
    comptime pointer: std.builtin.Type.Pointer,
) ![]const trace.Value {
    switch (pointer.size) {
        .slice => {
            if (pointer.child != trace.Value) {
                @compileError("tensor Program slice outputs must contain tensor Values");
            }
            const outputs = try builder.arena.allocator().alloc(trace.Value, result.len);
            for (result, 0..) |output, index_value| {
                outputs[index_value] = output;
            }
            return outputs;
        },
        .one => {
            return switch (@typeInfo(pointer.child)) {
                .array => |array| blk: {
                    if (array.child != trace.Value) {
                        @compileError("tensor Program array outputs must contain tensor Values");
                    }
                    const outputs = try builder.arena.allocator().alloc(trace.Value, array.len);
                    for (result.*, 0..) |output, index_value| {
                        outputs[index_value] = output;
                    }
                    break :blk outputs;
                },
                else => @compileError("tensor Program pointer outputs must point at arrays or " ++
                    "slices of tensor Values"),
            };
        },
        else => @compileError(
            "tensor Program pointer outputs must point at arrays or slices of tensor Values",
        ),
    }
}
