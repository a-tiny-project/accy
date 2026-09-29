const program_mod = @import("../root.zig").program;
const trace = @import("../root.zig").trace;
const context = @import("context.zig");
const dispatch = @import("dispatch.zig");
const step_mod = @import("step.zig");

pub fn semantics(comptime BoundValue: type, impl: anytype) Semantics(BoundValue, @TypeOf(impl)) {
    return .{ .impl = impl };
}

pub fn Semantics(comptime BoundValue: type, comptime Impl: type) type {
    return struct {
        impl: Impl,

        pub const Value: type = BoundValue;
        pub const Result: type = Impl.Result;

        pub fn operation(self: *@This(), step: *step_mod.Step(Value)) !Value {
            var buffer: [program_mod.max_operation_operands]Value = undefined;
            return self.bind(step.op, step_mod.arguments(Value, step.op, step.values, &buffer));
        }

        pub fn bind(self: *@This(), op: *const program_mod.Operation, args: []const Value) !Value {
            if (comptime @hasDecl(Impl, "bind")) {
                return self.impl.bind(op, args);
            }

            var ctx = context.LeafBindContext(Value){
                .op = op,
                .args = args,
            };
            if (try dispatch.primitive(Value, &self.impl, &ctx)) |value| return value;
            if (comptime @hasDecl(Impl, "default")) return self.impl.default(&ctx);
            @compileError("tensor leaf semantics without bind must provide primitive handlers and default");
        }

        pub fn finish(self: *@This(), outputs: []const Value) !Result {
            return self.impl.finish(outputs);
        }

        pub fn builderHandle(self: *@This()) *trace.Builder {
            return self.impl.builderHandle();
        }
    };
}
