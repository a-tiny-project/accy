const program_mod = @import("../root.zig").program;
const trace = @import("../root.zig").trace;
const context = @import("context.zig");
const dispatch = @import("dispatch.zig");
const step_mod = @import("step.zig");

fn stateHandle(comptime StateType: type) type {
    return switch (@typeInfo(StateType)) {
        .pointer => StateType,
        else => *StateType,
    };
}

fn stateResult(comptime StateType: type) type {
    return switch (@typeInfo(StateType)) {
        .pointer => |info| info.child.Result,
        else => StateType.Result,
    };
}

fn LayerResult(comptime Next: type, comptime Impl: type) type {
    if (comptime @hasDecl(Impl, "finish") and @hasDecl(Impl, "Result")) return Impl.Result;
    return stateResult(Next);
}

pub fn Layer(comptime BoundValue: type, comptime Next: type, comptime Impl: type) type {
    return struct {
        next: Next,
        impl: Impl,

        const Self = @This();

        pub const Value: type = BoundValue;
        pub const Result: type = LayerResult(Next, Impl);

        fn nextHandle(self: *Self) stateHandle(Next) {
            return switch (@typeInfo(Next)) {
                .pointer => self.next,
                else => &self.next,
            };
        }

        pub fn operation(self: *Self, step: *step_mod.Step(Value)) !Value {
            var buffer: [program_mod.max_operation_operands]Value = undefined;
            return self.bind(step.op, step_mod.arguments(Value, step.op, step.values, &buffer));
        }

        pub fn bind(self: *Self, op: *const program_mod.Operation, args: []const Value) !Value {
            var ctx = context.BindContext(Value, stateHandle(Next)){
                .next = self.nextHandle(),
                .op = op,
                .args = args,
            };
            if (comptime @hasDecl(Impl, "bind")) {
                return self.impl.bind(&ctx);
            }
            if (try dispatch.primitive(Value, &self.impl, &ctx)) |value| return value;
            return ctx.default();
        }

        pub fn finish(self: *Self, outputs: []const Value) !Result {
            var ctx = context.FinishContext(Value, stateHandle(Next)){ .next = self.nextHandle() };
            if (comptime @hasDecl(Impl, "finish")) {
                return self.impl.finish(&ctx, outputs);
            }
            return ctx.default(outputs);
        }

        pub fn builderHandle(self: *Self) *trace.Builder {
            return self.nextHandle().builderHandle();
        }
    };
}
