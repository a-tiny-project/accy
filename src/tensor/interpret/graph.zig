const program_mod = @import("../root.zig").program;
const trace = @import("../root.zig").trace;
const step_mod = @import("step.zig");

pub const Graph = struct {
    builder: *trace.Builder,

    pub const Value: type = trace.Value;
    pub const Result: type = program_mod.Program;

    pub fn operation(self: *@This(), step: *step_mod.Step(Value)) !Value {
        var buffer: [program_mod.max_operation_operands]Value = undefined;
        return self.bind(step.op, step_mod.arguments(Value, step.op, step.values, &buffer));
    }

    pub fn bind(self: *@This(), op: *const program_mod.Operation, args: []const Value) !Value {
        return self.builder.operation(op, args);
    }

    pub fn finish(self: *@This(), outputs: []const Value) !Result {
        return self.builder.finish(outputs);
    }

    pub fn builderHandle(self: *@This()) *trace.Builder {
        return self.builder;
    }
};
