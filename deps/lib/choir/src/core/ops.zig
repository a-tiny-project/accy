const Operation = @import("operation/root.zig").Operation;
const Value = @import("value.zig").Value;
const Type = @import("type.zig").Type;
const Location = @import("location.zig").Location;
const Context = @import("context/root.zig").Context;
const OperationBuilder = @import("builder.zig").OperationBuilder;

pub fn NoOperandOp(comptime name: []const u8) type {
    return struct {
        op: *Operation,
        pub const operation_name = name;

        pub fn create(ctx: *Context, loc: Location) !@This() {
            var builder = OperationBuilder.init(ctx);
            return createWithBuilder(&builder, loc);
        }

        pub fn createWithBuilder(builder: anytype, loc: Location) !@This() {
            const state = Operation.State.init(operation_name, loc);
            const op = try builder.create(state);
            return .{ .op = op };
        }
    };
}

pub fn UnaryNoResultOp(comptime name: []const u8) type {
    return struct {
        op: *Operation,
        pub const operation_name = name;

        pub fn create(ctx: *Context, loc: Location, operand: *Value) !@This() {
            var builder = OperationBuilder.init(ctx);
            return createWithBuilder(&builder, loc, operand);
        }

        pub fn createWithBuilder(builder: anytype, loc: Location, operand: *Value) !@This() {
            var state = Operation.State.init(operation_name, loc);
            state.addOperands(&.{operand});
            const op = try builder.create(state);
            return .{ .op = op };
        }
    };
}

pub fn VariadicNoResultOp(comptime name: []const u8) type {
    return struct {
        op: *Operation,
        pub const operation_name = name;

        pub fn create(ctx: *Context, loc: Location, operands: []const *Value) !@This() {
            var builder = OperationBuilder.init(ctx);
            return createWithBuilder(&builder, loc, operands);
        }

        pub fn createWithBuilder(builder: anytype, loc: Location, operands: []const *Value) !@This() {
            var state = Operation.State.init(operation_name, loc);
            state.addOperands(operands);
            const op = try builder.create(state);
            return .{ .op = op };
        }
    };
}

pub fn UnaryOpSameType(comptime name: []const u8) type {
    return struct {
        op: *Operation,
        pub const operation_name = name;

        pub fn create(ctx: *Context, loc: Location, operand: *Value) !@This() {
            var builder = OperationBuilder.init(ctx);
            return createWithBuilder(&builder, loc, operand);
        }

        pub fn createWithBuilder(builder: anytype, loc: Location, operand: *Value) !@This() {
            var state = Operation.State.init(operation_name, loc);
            state.addOperands(&.{operand});
            state.addTypes(&.{operand.type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const @This()) *Value {
            return self.op.getResult(0).?;
        }
    };
}

pub fn UnaryOpWithResultType(comptime name: []const u8) type {
    return struct {
        op: *Operation,
        pub const operation_name = name;

        pub fn create(ctx: *Context, loc: Location, operand: *Value, result_type: Type) !@This() {
            var builder = OperationBuilder.init(ctx);
            return createWithBuilder(&builder, loc, operand, result_type);
        }

        pub fn createWithBuilder(
            builder: anytype,
            loc: Location,
            operand: *Value,
            result_type: Type,
        ) !@This() {
            var state = Operation.State.init(operation_name, loc);
            state.addOperands(&.{operand});
            state.addTypes(&.{result_type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const @This()) *Value {
            return self.op.getResult(0).?;
        }
    };
}

pub fn BinaryNoResultOp(comptime name: []const u8) type {
    return struct {
        op: *Operation,
        pub const operation_name = name;

        pub fn create(ctx: *Context, loc: Location, lhs: *Value, rhs: *Value) !@This() {
            var builder = OperationBuilder.init(ctx);
            return createWithBuilder(&builder, loc, lhs, rhs);
        }

        pub fn createWithBuilder(
            builder: anytype,
            loc: Location,
            lhs: *Value,
            rhs: *Value,
        ) !@This() {
            var state = Operation.State.init(operation_name, loc);
            state.addOperands(&.{ lhs, rhs });
            const op = try builder.create(state);
            return .{ .op = op };
        }
    };
}

pub fn BinaryOpSameType(comptime name: []const u8) type {
    return struct {
        op: *Operation,
        pub const operation_name = name;

        pub fn create(ctx: *Context, loc: Location, lhs: *Value, rhs: *Value) !@This() {
            var builder = OperationBuilder.init(ctx);
            return createWithBuilder(&builder, loc, lhs, rhs);
        }

        pub fn createWithBuilder(
            builder: anytype,
            loc: Location,
            lhs: *Value,
            rhs: *Value,
        ) !@This() {
            var state = Operation.State.init(operation_name, loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{lhs.type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const @This()) *Value {
            return self.op.getResult(0).?;
        }
    };
}

pub fn BinaryOpWithResultType(comptime name: []const u8) type {
    return struct {
        op: *Operation,
        pub const operation_name = name;

        pub fn create(
            ctx: *Context,
            loc: Location,
            lhs: *Value,
            rhs: *Value,
            result_type: Type,
        ) !@This() {
            var builder = OperationBuilder.init(ctx);
            return createWithBuilder(&builder, loc, lhs, rhs, result_type);
        }

        pub fn createWithBuilder(
            builder: anytype,
            loc: Location,
            lhs: *Value,
            rhs: *Value,
            result_type: Type,
        ) !@This() {
            var state = Operation.State.init(operation_name, loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{result_type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const @This()) *Value {
            return self.op.getResult(0).?;
        }
    };
}
