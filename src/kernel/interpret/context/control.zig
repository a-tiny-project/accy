const builder = @import("../../root.zig").builder;
const program = @import("../../program/root.zig");
const typed = @import("../../root.zig").typed;

fn pointerChild(comptime Pointer: type) type {
    return switch (@typeInfo(Pointer)) {
        .pointer => |info| info.child,
        else => @compileError("kernel interpreter layers attach to a builder pointer"),
    };
}

pub fn FinishContext(comptime Handle: type) type {
    return struct {
        next: Handle,

        pub fn default(self: *@This()) !pointerChild(Handle).Result {
            return self.next.finish();
        }
    };
}

pub fn ReturnContext(comptime Handle: type) type {
    return struct {
        next: Handle,

        pub fn default(self: *@This()) !void {
            try self.next.return_();
        }
    };
}

pub fn IfContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        condition: builder.Value,
        result_types: []const builder.Type,

        pub fn default(self: *@This()) !builder.If {
            return self.next.if_(self.condition, self.result_types);
        }
    };
}

pub fn ForContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        lower: builder.Value,
        upper: builder.Value,
        step: builder.Value,
        init_args: []const builder.Value,
        result_types: []const builder.Type,

        pub fn default(self: *@This()) !builder.For {
            return self.next.for_(
                self.lower,
                self.upper,
                self.step,
                self.init_args,
                self.result_types,
            );
        }
    };
}

pub fn ForScopeContext(comptime Handle: type, comptime Scope: type) type {
    return struct {
        next: Handle,
        lower: builder.Value,
        upper: builder.Value,
        step: builder.Value,
        init_args: []const builder.Value,
        result_types: []const builder.Type,

        pub const ScopeType: type = Scope;

        pub fn default(self: *@This()) !Scope {
            return self.next.forScope(
                self.lower,
                self.upper,
                self.step,
                self.init_args,
                self.result_types,
            );
        }
    };
}

pub fn ForScopeInductionVarContext(comptime Handle: type, comptime Scope: type) type {
    return struct {
        next: Handle,
        scope: *Scope,

        pub fn default(self: *@This()) builder.Value {
            _ = self.next;
            return self.scope.inductionVar();
        }
    };
}

pub fn ForScopeIterArgContext(comptime Handle: type, comptime Scope: type) type {
    return struct {
        next: Handle,
        scope: *Scope,
        index: usize,

        pub fn default(self: *@This()) ?builder.Value {
            _ = self.next;
            return self.scope.iterArg(self.index);
        }
    };
}

pub fn ForScopeResultContext(comptime Handle: type, comptime Scope: type) type {
    return struct {
        next: Handle,
        scope: *const Scope,
        index: usize,

        pub fn default(self: *@This()) ?builder.Value {
            _ = self.next;
            return self.scope.result(self.index);
        }
    };
}

pub fn ForScopeLeaveContext(comptime Handle: type, comptime Scope: type) type {
    return struct {
        next: Handle,
        scope: *Scope,
        values: []const builder.Value,

        pub fn default(self: *@This()) !void {
            _ = self.next;
            try self.scope.leave(self.values);
        }
    };
}

pub fn ForScopeAbortContext(comptime Handle: type, comptime Scope: type) type {
    return struct {
        next: Handle,
        scope: *Scope,

        pub fn default(self: *@This()) void {
            _ = self.next;
            self.scope.abort();
        }
    };
}

pub fn WhileContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        init_args: []const builder.Value,
        result_types: []const builder.Type,

        pub fn default(self: *@This()) !builder.While {
            return self.next.while_(self.init_args, self.result_types);
        }
    };
}

pub fn WhileScopeContext(comptime Handle: type, comptime Scope: type) type {
    return struct {
        next: Handle,
        init_args: []const builder.Value,
        result_types: []const builder.Type,

        pub const ScopeType: type = Scope;

        pub fn default(self: *@This()) !Scope {
            return self.next.whileScope(self.init_args, self.result_types);
        }
    };
}

pub fn WhileScopeBeforeArgContext(comptime Handle: type, comptime Scope: type) type {
    return struct {
        next: Handle,
        scope: *const Scope,
        index: usize,

        pub fn default(self: *@This()) ?builder.Value {
            _ = self.next;
            return self.scope.beforeArg(self.index);
        }
    };
}

pub fn WhileScopeAfterArgContext(comptime Handle: type, comptime Scope: type) type {
    return struct {
        next: Handle,
        scope: *const Scope,
        index: usize,

        pub fn default(self: *@This()) ?builder.Value {
            _ = self.next;
            return self.scope.afterArg(self.index);
        }
    };
}

pub fn WhileScopeResultContext(comptime Handle: type, comptime Scope: type) type {
    return struct {
        next: Handle,
        scope: *const Scope,
        index: usize,

        pub fn default(self: *@This()) ?builder.Value {
            _ = self.next;
            return self.scope.result(self.index);
        }
    };
}

pub fn WhileScopeConditionContext(comptime Handle: type, comptime Scope: type) type {
    return struct {
        next: Handle,
        scope: *Scope,
        condition: builder.Value,
        args: []const builder.Value,

        pub fn default(self: *@This()) !void {
            _ = self.next;
            try self.scope.condition(self.condition, self.args);
        }
    };
}

pub fn WhileScopeLeaveContext(comptime Handle: type, comptime Scope: type) type {
    return struct {
        next: Handle,
        scope: *Scope,
        values: []const builder.Value,

        pub fn default(self: *@This()) !void {
            _ = self.next;
            try self.scope.leave(self.values);
        }
    };
}

pub fn WhileScopeAbortContext(comptime Handle: type, comptime Scope: type) type {
    return struct {
        next: Handle,
        scope: *Scope,

        pub fn default(self: *@This()) void {
            _ = self.next;
            self.scope.abort();
        }
    };
}

pub fn FoldContext(
    comptime Owner: type,
    comptime Handle: type,
    comptime Initial: type,
    comptime BodyContext: type,
    comptime body: anytype,
) type {
    return struct {
        owner: *Owner,
        next: Handle,
        lower: builder.Value,
        upper: builder.Value,
        step: builder.Value,
        initial: Initial,
        context: BodyContext,

        pub fn default(self: *@This()) !Initial {
            return self.next.fold(self.lower, self.upper, self.step, self.initial, .{
                .owner = self.owner,
                .context = self.context,
            }, struct {
                fn each(
                    _: anytype,
                    iteration: anytype,
                    acc: anytype,
                    fold_ctx: anytype,
                ) !@TypeOf(acc) {
                    return body(fold_ctx.owner, iteration, acc, fold_ctx.context);
                }
            }.each);
        }
    };
}

pub fn WhileLoopContext(
    comptime Owner: type,
    comptime Handle: type,
    comptime Initial: type,
    comptime BodyContext: type,
    comptime condition: anytype,
    comptime body: anytype,
) type {
    return struct {
        owner: *Owner,
        next: Handle,
        initial: Initial,
        context: BodyContext,

        pub fn default(self: *@This()) !Initial {
            return self.next.whileLoop(self.initial, .{
                .owner = self.owner,
                .context = self.context,
            }, struct {
                fn keepGoing(_: anytype, carry: anytype, loop_ctx: anytype) !builder.Value {
                    return typed.raw(try condition(loop_ctx.owner, carry, loop_ctx.context));
                }
            }.keepGoing, struct {
                fn each(_: anytype, carry: anytype, loop_ctx: anytype) !@TypeOf(carry) {
                    return body(loop_ctx.owner, carry, loop_ctx.context);
                }
            }.each);
        }
    };
}

pub fn GuardDoContext(
    comptime Owner: type,
    comptime Handle: type,
    comptime Condition: type,
    comptime BodyContext: type,
    comptime body: anytype,
) type {
    return struct {
        owner: *Owner,
        next: Handle,
        condition: Condition,
        context: BodyContext,

        pub fn default(self: *@This()) !void {
            var active_guard = try self.guard(self.condition);
            errdefer active_guard.abort();
            try self.runBody();
            try active_guard.leave();
        }

        pub fn guard(self: *@This(), condition: anytype) !program.Guard {
            return self.owner.guard(condition);
        }

        pub fn runBody(self: *@This()) !void {
            try body(self.owner, self.context);
        }
    };
}

pub fn GuardIndexDoContext(
    comptime Owner: type,
    comptime Handle: type,
    comptime BodyContext: type,
    comptime body: anytype,
) type {
    return struct {
        owner: *Owner,
        next: Handle,
        index: program.Index1D,
        context: BodyContext,

        pub fn default(self: *@This()) !void {
            var active_guard = try self.guardIndex(self.index);
            errdefer active_guard.abort();
            try self.runBody();
            try active_guard.leave();
        }

        pub fn guardIndex(self: *@This(), index: program.Index1D) !program.Guard {
            return self.owner.guardIndex(index);
        }

        pub fn runBody(self: *@This()) !void {
            try body(self.owner, self.index, self.context);
        }
    };
}

pub fn YieldContext(comptime Handle: type) type {
    return struct {
        next: Handle,
        values: []const builder.Value,

        pub fn default(self: *@This()) !void {
            try self.next.yield_(self.values);
        }
    };
}

pub fn GuardIndex2DDoContext(
    comptime Owner: type,
    comptime Handle: type,
    comptime BodyContext: type,
    comptime body: anytype,
) type {
    return struct {
        owner: *Owner,
        next: Handle,
        index: program.Index2D,
        context: BodyContext,

        pub fn default(self: *@This()) !void {
            var x_guard = try self.guardIndex(self.index.x);
            errdefer x_guard.abort();
            var y_guard = try self.guardIndex(self.index.y);
            errdefer y_guard.abort();
            try self.runBody();
            try y_guard.leave();
            try x_guard.leave();
        }

        pub fn guardIndex(self: *@This(), index: program.Index1D) !program.Guard {
            return self.owner.guardIndex(index);
        }

        pub fn runBody(self: *@This()) !void {
            try body(self.owner, self.index, self.context);
        }
    };
}

pub fn GuardIndex3DDoContext(
    comptime Owner: type,
    comptime Handle: type,
    comptime BodyContext: type,
    comptime body: anytype,
) type {
    return struct {
        owner: *Owner,
        next: Handle,
        index: program.Index3D,
        context: BodyContext,

        pub fn default(self: *@This()) !void {
            var x_guard = try self.guardIndex(self.index.x);
            errdefer x_guard.abort();
            var y_guard = try self.guardIndex(self.index.y);
            errdefer y_guard.abort();
            var z_guard = try self.guardIndex(self.index.z);
            errdefer z_guard.abort();
            try self.runBody();
            try z_guard.leave();
            try y_guard.leave();
            try x_guard.leave();
        }

        pub fn guardIndex(self: *@This(), index: program.Index1D) !program.Guard {
            return self.owner.guardIndex(index);
        }

        pub fn runBody(self: *@This()) !void {
            try body(self.owner, self.index, self.context);
        }
    };
}
