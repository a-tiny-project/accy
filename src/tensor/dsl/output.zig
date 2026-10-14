const std = @import("std");
const tensor = @import("../root.zig");
const gradient = tensor.gradient;
const trace = tensor.trace;
const parameter = @import("parameter.zig");

pub fn Source(comptime body: anytype) type {
    return OutputLayout(bodyReturnPayload(body));
}

pub fn Derived(
    comptime SourceProgram: type,
    comptime derivation: anytype,
    comptime options: anytype,
) type {
    if (comptime derivation == .jvp) return Jvp(SourceProgram.Outputs);
    if (comptime derivation == .jvp_with) return Jvp(SourceProgram.Outputs);
    if (comptime derivation == .grad) return Grad(SourceProgram.Layout, options);
    if (comptime derivation == .grad_with) return Grad(SourceProgram.Layout, options.grad);
    return SourceProgram.Outputs;
}

fn OutputLayout(comptime Result: type) type {
    if (comptime Result == trace.Value) return Positional(1);

    return switch (@typeInfo(Result)) {
        .array => |array| Positional(array.len),
        .pointer => |pointer| Pointer(pointer),
        .@"struct" => |info| if (info.is_tuple) Positional(info.field_names.len) else Named(Result),
        else => @compileError(
            "tensor Program bodies must return a Value, array, slice, or struct of Values",
        ),
    };
}

fn Pointer(comptime pointer: std.builtin.Type.Pointer) type {
    return switch (pointer.size) {
        .slice => Dynamic,
        .one => switch (@typeInfo(pointer.child)) {
            .array => |array| Positional(array.len),
            else => @compileError(
                "tensor Program pointer outputs must point at arrays or slices of tensor Values",
            ),
        },
        else => @compileError(
            "tensor Program pointer outputs must point at arrays or slices of tensor Values",
        ),
    };
}

fn Positional(comptime output_count: usize) type {
    return struct {
        pub const count: ?usize = output_count;

        pub fn index(comptime _: anytype) usize {
            @compileError("tensor Program outputs are positional");
        }
    };
}

const Dynamic = struct {
    pub const count: ?usize = null;

    pub fn index(comptime _: anytype) usize {
        @compileError("tensor Program slice outputs are dynamic and positional");
    }
};

fn Named(comptime Result: type) type {
    const info = @typeInfo(Result).@"struct";
    return struct {
        pub const count: ?usize = info.field_names.len;

        pub fn index(comptime spec: anytype) usize {
            return fieldIndex(info.field_names, name(spec));
        }
    };
}

fn Jvp(comptime SourceOutputLayout: type) type {
    return struct {
        pub const count: ?usize = if (SourceOutputLayout.count) |source_count|
            source_count * 2
        else
            null;

        pub fn index(comptime spec: anytype) usize {
            const source_count = SourceOutputLayout.count orelse @compileError(
                "tensor jvp output lookup requires statically known source outputs",
            );
            return switch (@typeInfo(@TypeOf(spec))) {
                .@"struct" => |info| blk: {
                    if (info.is_tuple or info.field_names.len != 1) {
                        @compileError("tensor jvp output lookup requires .primals or .tangents");
                    }
                    const field_name = info.field_names[0];
                    if (comptime std.mem.eql(u8, field_name, "primals")) {
                        break :blk SourceOutputLayout.index(@field(spec, field_name));
                    }
                    if (comptime std.mem.eql(u8, field_name, "tangents")) {
                        break :blk source_count +
                            SourceOutputLayout.index(@field(spec, field_name));
                    }
                    @compileError("tensor jvp output lookup requires .primals or .tangents");
                },
                .enum_literal => blk: {
                    const output_name = @tagName(spec);
                    if (comptime std.mem.eql(u8, output_name, "primal")) {
                        if (source_count != 1) @compileError(
                            "tensor jvp .primal output lookup requires one source output",
                        );
                        break :blk 0;
                    }
                    if (comptime std.mem.eql(u8, output_name, "tangent")) {
                        if (source_count != 1) @compileError(
                            "tensor jvp .tangent output lookup requires one source output",
                        );
                        break :blk source_count;
                    }
                    @compileError("tensor jvp output lookup requires .primal, .tangent, " ++
                        ".primals, or .tangents");
                },
                else => @compileError(
                    "tensor jvp output lookup requires .primal, .tangent, .primals, or .tangents",
                ),
            };
        }
    };
}

fn Grad(comptime SourceLayout: type, comptime options: gradient.Options) type {
    return struct {
        pub const count: ?usize = options.wrt.len;

        pub fn index(comptime spec: anytype) usize {
            const parameter_index = comptime SourceLayout.index(spec);
            return parameter.wrtOffset(options.wrt, parameter_index);
        }
    };
}

fn bodyReturnPayload(comptime body: anytype) type {
    const return_type = @typeInfo(@TypeOf(body)).@"fn".return_type orelse @compileError(
        "tensor Program body must return values",
    );
    return switch (@typeInfo(return_type)) {
        .error_union => |info| info.payload,
        else => return_type,
    };
}

fn fieldIndex(comptime field_names: []const [:0]const u8, comptime output_name: []const u8) usize {
    inline for (field_names, 0..) |field_name, index_value| {
        if (comptime std.mem.eql(u8, field_name, output_name)) return index_value;
    }
    @compileError("unknown tensor output: " ++ output_name);
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
            @compileError("tensor output name pointers must point at string literals");
        },
        .array => |array| blk: {
            if (array.child == u8) break :blk name_value[0..];
            @compileError("tensor output name arrays must contain bytes");
        },
        else => @compileError("tensor output names must be enum literals or string literals"),
    };
}
