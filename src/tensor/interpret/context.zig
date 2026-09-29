const program_mod = @import("../root.zig").program;
const trace = @import("../root.zig").trace;

fn pointerChild(comptime Pointer: type) type {
    return switch (@typeInfo(Pointer)) {
        .pointer => |info| info.child,
        else => @compileError("tensor interpreter layer handles must be pointers"),
    };
}

pub fn BindContext(comptime BoundValue: type, comptime Handle: type) type {
    return struct {
        next: Handle,
        op: *const program_mod.Operation,
        args: []const BoundValue,

        pub fn default(self: *@This()) !BoundValue {
            return self.next.bind(self.op, self.args);
        }

        pub fn arg(self: *@This(), index: usize) BoundValue {
            return self.args[index];
        }

        pub fn builderHandle(self: *@This()) *trace.Builder {
            return self.next.builderHandle();
        }
    };
}

pub fn FinishContext(comptime BoundValue: type, comptime Handle: type) type {
    return struct {
        next: Handle,

        pub fn default(self: *@This(), outputs: []const BoundValue) !pointerChild(Handle).Result {
            return self.next.finish(outputs);
        }

        pub fn builderHandle(self: *@This()) *trace.Builder {
            return self.next.builderHandle();
        }
    };
}

pub fn LeafBindContext(comptime BoundValue: type) type {
    return struct {
        op: *const program_mod.Operation,
        args: []const BoundValue,

        pub fn arg(self: *@This(), index: usize) BoundValue {
            return self.args[index];
        }
    };
}
