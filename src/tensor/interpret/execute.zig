const std = @import("std");

const graph_mod = @import("graph.zig");
const leaf = @import("leaf.zig");
const program_mod = @import("../root.zig").program;
const step_mod = @import("step.zig");

pub fn run(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    initial: anytype,
) !result(@TypeOf(initial)) {
    var state = normalize(initial);
    const State = @TypeOf(state);
    const Value = State.Value;

    const values = try allocator.alloc(Value, source.valueCount());
    defer allocator.free(values);

    for (source.operations) |*op| {
        var step = step_mod.Step(Value){
            .source = source,
            .values = values,
            .op = op,
        };
        values[op.id.index] = try state.operation(&step);
    }

    const outputs = try allocator.alloc(Value, source.outputs.len);
    defer allocator.free(outputs);
    for (source.outputs, 0..) |id, index| {
        outputs[index] = values[id.index];
    }

    return try state.finish(outputs);
}

pub fn result(comptime Initial: type) type {
    if (comptime @hasDecl(Initial, "attach")) return @TypeOf(@as(Initial, undefined).attach(@as(graph_mod.Graph, undefined))).Result;
    return Normalized(Initial).Result;
}

fn normalize(initial: anytype) Normalized(@TypeOf(initial)) {
    const Initial = @TypeOf(initial);
    if (comptime @hasDecl(Initial, "operation")) return initial;
    if (comptime @hasDecl(Initial, "Value")) return leaf.semantics(Initial.Value, initial);
    @compileError("tensor leaf semantics must provide Value or use tensor.interpret.semantics(Value, impl)");
}

fn Normalized(comptime Initial: type) type {
    if (comptime @hasDecl(Initial, "operation")) return Initial;
    if (comptime @hasDecl(Initial, "Value")) return leaf.Semantics(Initial.Value, Initial);
    @compileError("tensor leaf semantics must provide Value or use tensor.interpret.semantics(Value, impl)");
}
