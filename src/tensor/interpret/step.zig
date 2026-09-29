const program_mod = @import("../root.zig").program;

pub fn Step(comptime Value: type) type {
    return struct {
        source: *const program_mod.Program,
        values: []const Value,
        op: *const program_mod.Operation,

        pub fn read(self: @This(), id: program_mod.Id) Value {
            return self.values[id.index];
        }

        pub fn typeOf(self: @This(), id: program_mod.Id) program_mod.Type {
            return self.source.typeOf(id);
        }
    };
}

pub fn arguments(comptime Value: type, op: *const program_mod.Operation, values: []const Value, buffer: *[program_mod.max_operation_operands]Value) []const Value {
    return switch (op.kind) {
        .parameter, .constant, .iota => buffer[0..0],
        .unary => |unary| blk: {
            buffer[0] = values[unary.input.index];
            break :blk buffer[0..1];
        },
        .binary => |binary| blk: {
            buffer[0] = values[binary.lhs.index];
            buffer[1] = values[binary.rhs.index];
            break :blk buffer[0..2];
        },
        .broadcast => |broadcast| blk: {
            buffer[0] = values[broadcast.input.index];
            break :blk buffer[0..1];
        },
        .broadcast_in_dim => |broadcast| blk: {
            buffer[0] = values[broadcast.input.index];
            break :blk buffer[0..1];
        },
        .reshape => |reshape| blk: {
            buffer[0] = values[reshape.input.index];
            break :blk buffer[0..1];
        },
        .transpose => |transpose| blk: {
            buffer[0] = values[transpose.input.index];
            break :blk buffer[0..1];
        },
        .reduce => |reduce| blk: {
            buffer[0] = values[reduce.input.index];
            buffer[1] = values[reduce.init.index];
            break :blk buffer[0..2];
        },
        .gather => |gather| blk: {
            buffer[0] = values[gather.input.index];
            buffer[1] = values[gather.indices.index];
            break :blk buffer[0..2];
        },
        .scatter_add => |scatter_add| blk: {
            buffer[0] = values[scatter_add.input.index];
            buffer[1] = values[scatter_add.indices.index];
            buffer[2] = values[scatter_add.updates.index];
            break :blk buffer[0..3];
        },
        .sparse_cross_entropy => |sparse_cross_entropy| blk: {
            buffer[0] = values[sparse_cross_entropy.logits.index];
            buffer[1] = values[sparse_cross_entropy.targets.index];
            break :blk buffer[0..2];
        },
        .dot_general => |dot| blk: {
            buffer[0] = values[dot.lhs.index];
            buffer[1] = values[dot.rhs.index];
            break :blk buffer[0..2];
        },
        .compare => |compare| blk: {
            buffer[0] = values[compare.lhs.index];
            buffer[1] = values[compare.rhs.index];
            break :blk buffer[0..2];
        },
        .select => |select| blk: {
            buffer[0] = values[select.pred.index];
            buffer[1] = values[select.on_true.index];
            buffer[2] = values[select.on_false.index];
            break :blk buffer[0..3];
        },
        .custom_call => |custom| blk: {
            for (custom.operands, 0..) |operand, index| buffer[index] = values[operand.index];
            break :blk buffer[0..custom.operands.len];
        },
        .scan => |scan| blk: {
            for (scan.inits, 0..) |init, index| buffer[index] = values[init.index];
            break :blk buffer[0..scan.inits.len];
        },
        .projection => |projection| blk: {
            buffer[0] = values[projection.source.index];
            break :blk buffer[0..1];
        },
    };
}
