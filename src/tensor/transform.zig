const std = @import("std");
const interpret = @import("interpret/root.zig");
const program_mod = @import("program.zig");
const trace = @import("trace/root.zig");
const types = @import("type/root.zig");

pub const Operand = struct {
    id: program_mod.Id,
    value: trace.Value,
    ty: trace.Type,
};

pub const Context = struct {
    source: *const program_mod.Program,
    builder: *trace.Builder,
    op: *const program_mod.Operation,
    args: []const trace.Value,

    pub fn arg(self: Context, index: usize) trace.Value {
        return self.args[index];
    }

    pub fn operand(self: Context, index: usize) Operand {
        const id = self.operandId(index).?;
        const value = self.arg(index);
        return .{
            .id = id,
            .value = value,
            .ty = value.ty,
        };
    }

    pub fn isZero(self: Context, index: usize) bool {
        const id = self.operandId(index) orelse return false;
        if (id.index >= self.source.valueCount()) return false;
        return self.source.isZeroConstant(id);
    }

    pub fn constantPayload(self: Context, index: usize) ?[]const u8 {
        const id = self.operandId(index) orelse return null;
        if (id.index >= self.source.valueCount()) return null;
        return self.source.constantPayload(id);
    }

    fn operandId(self: Context, index: usize) ?program_mod.Id {
        return switch (self.op.kind) {
            .parameter, .constant, .iota => null,
            .unary => |unary| if (index == 0) unary.input else null,
            .binary => |binary| switch (index) {
                0 => binary.lhs,
                1 => binary.rhs,
                else => null,
            },
            .broadcast => |broadcast| if (index == 0) broadcast.input else null,
            .broadcast_in_dim => |broadcast| if (index == 0) broadcast.input else null,
            .reshape => |reshape| if (index == 0) reshape.input else null,
            .transpose => |transpose| if (index == 0) transpose.input else null,
            .reduce => |reduce| switch (index) {
                0 => reduce.input,
                1 => reduce.init,
                else => null,
            },
            .gather => |gather| switch (index) {
                0 => gather.input,
                1 => gather.indices,
                else => null,
            },
            .scatter_add => |scatter_add| switch (index) {
                0 => scatter_add.input,
                1 => scatter_add.indices,
                2 => scatter_add.updates,
                else => null,
            },
            .sparse_cross_entropy => |sparse_cross_entropy| switch (index) {
                0 => sparse_cross_entropy.logits,
                1 => sparse_cross_entropy.targets,
                else => null,
            },
            .dot_general => |dot| switch (index) {
                0 => dot.lhs,
                1 => dot.rhs,
                else => null,
            },
            .compare => |compare| switch (index) {
                0 => compare.lhs,
                1 => compare.rhs,
                else => null,
            },
            .select => |select| switch (index) {
                0 => select.pred,
                1 => select.on_true,
                2 => select.on_false,
                else => null,
            },
            .custom_call => |custom| if (index < custom.operands.len) custom.operands[index] else null,
            .scan => |scan| if (index < scan.inits.len) scan.inits[index] else null,
            .projection => |projection| if (index == 0) projection.source else null,
        };
    }
};

pub fn apply(
    allocator: std.mem.Allocator,
    source: *const program_mod.Program,
    pass: anytype,
) !program_mod.Program {
    var builder = try trace.Builder.init(allocator, source.name);
    errdefer builder.deinit();

    const graph = interpret.Graph{ .builder = &builder };
    return try interpret.run(allocator, source, semantics(source, graph, pass));
}

pub fn semantics(
    source: *const program_mod.Program,
    next: anytype,
    pass: anytype,
) interpret.Layer(trace.Value, @TypeOf(next), Rewrite(@TypeOf(pass))) {
    return interpret.layer(trace.Value, next, Rewrite(@TypeOf(pass)){
        .source = source,
        .pass = pass,
    });
}

pub fn Rewrite(comptime Pass: type) type {
    return struct {
        source: *const program_mod.Program,
        pass: Pass,

        pub fn bind(self: *@This(), layer: anytype) !trace.Value {
            var ctx = Context{
                .source = self.source,
                .builder = layer.builderHandle(),
                .op = layer.op,
                .args = layer.args,
            };
            return (try dispatch(&self.pass, &ctx, layer.op)) orelse layer.default();
        }
    };
}

fn dispatch(pass: anytype, ctx: *Context, op: *const program_mod.Operation) !?trace.Value {
    const Pass = @TypeOf(pass.*);
    return switch (op.kind) {
        .binary => |binary| switch (binary.op) {
            .add => if (comptime @hasDecl(Pass, "add"))
                pass.add(ctx)
            else
                null,
            .sub => if (comptime @hasDecl(Pass, "sub"))
                pass.sub(ctx)
            else
                null,
            .mul => if (comptime @hasDecl(Pass, "mul"))
                pass.mul(ctx)
            else
                null,
            .div => if (comptime @hasDecl(Pass, "div"))
                pass.div(ctx)
            else
                null,
            .max => if (comptime @hasDecl(Pass, "max"))
                pass.max(ctx)
            else
                null,
            .min => if (comptime @hasDecl(Pass, "min"))
                pass.min(ctx)
            else
                null,
            .pow => if (comptime @hasDecl(Pass, "pow"))
                pass.pow(ctx)
            else
                null,
        },
        .unary => |unary| switch (unary.op) {
            .neg => if (comptime @hasDecl(Pass, "neg"))
                pass.neg(ctx)
            else
                null,
            .abs => if (comptime @hasDecl(Pass, "abs"))
                pass.abs(ctx)
            else
                null,
            .exp => if (comptime @hasDecl(Pass, "exp"))
                pass.exp(ctx)
            else
                null,
            .log => if (comptime @hasDecl(Pass, "log"))
                pass.log(ctx)
            else
                null,
            .sqrt => if (comptime @hasDecl(Pass, "sqrt"))
                pass.sqrt(ctx)
            else
                null,
            .tanh => if (comptime @hasDecl(Pass, "tanh"))
                pass.tanh(ctx)
            else
                null,
            .sin => if (comptime @hasDecl(Pass, "sin"))
                pass.sin(ctx)
            else
                null,
            .cos => if (comptime @hasDecl(Pass, "cos"))
                pass.cos(ctx)
            else
                null,
            .tan => if (comptime @hasDecl(Pass, "tan"))
                pass.tan(ctx)
            else
                null,
        },
        .reduce => if (comptime @hasDecl(Pass, "reduce"))
            pass.reduce(ctx)
        else
            null,
        .gather => if (comptime @hasDecl(Pass, "gather"))
            pass.gather(ctx)
        else
            null,
        .scatter_add => if (comptime @hasDecl(Pass, "scatterAdd"))
            pass.scatterAdd(ctx)
        else
            null,
        .sparse_cross_entropy => if (comptime @hasDecl(Pass, "sparseCrossEntropy"))
            pass.sparseCrossEntropy(ctx)
        else
            null,
        .dot_general => if (comptime @hasDecl(Pass, "dotGeneral"))
            pass.dotGeneral(ctx)
        else
            null,
        .compare => if (comptime @hasDecl(Pass, "compare"))
            pass.compare(ctx)
        else
            null,
        .select => if (comptime @hasDecl(Pass, "select"))
            pass.select(ctx)
        else
            null,
        .custom_call => if (comptime @hasDecl(Pass, "customCall"))
            pass.customCall(ctx)
        else
            null,
        .broadcast => if (comptime @hasDecl(Pass, "broadcast"))
            pass.broadcast(ctx)
        else
            null,
        .broadcast_in_dim => if (comptime @hasDecl(Pass, "broadcastInDim"))
            pass.broadcastInDim(ctx)
        else
            null,
        .reshape => if (comptime @hasDecl(Pass, "reshape"))
            pass.reshape(ctx)
        else
            null,
        .transpose => if (comptime @hasDecl(Pass, "transpose"))
            pass.transpose(ctx)
        else
            null,
        .iota => if (comptime @hasDecl(Pass, "iota"))
            pass.iota(ctx)
        else
            null,
        .parameter => if (comptime @hasDecl(Pass, "parameter"))
            pass.parameter(ctx)
        else
            null,
        .scan => if (comptime @hasDecl(Pass, "scan"))
            pass.scan(ctx)
        else
            null,
        .projection => if (comptime @hasDecl(Pass, "projection"))
            pass.projection(ctx)
        else
            null,
        .constant => null,
    };
}

test "tensor transform defaults to structural copy" {
    var builder = try trace.Builder.init(std.testing.allocator, "copy");
    defer builder.deinit();

    const x = try builder.input(.f32, .{ .lane = 4 });
    const y = try builder.input(.f32, .{ .lane = 4 });
    const out = try (try x.add(y)).tanh();
    var source = try builder.finish(&.{out});
    defer source.deinit();

    var rewritten = try apply(std.testing.allocator, &source, struct {}{});
    defer rewritten.deinit();

    try std.testing.expectEqual(source.valueCount(), rewritten.valueCount());
    try std.testing.expectEqual(source.operationCount(), rewritten.operationCount());
    try std.testing.expect(types.sameDims(
        source.typeOf(source.outputs[0]).dims,
        rewritten.typeOf(rewritten.outputs[0]).dims,
    ));
}

const DropAddZero = struct {
    pub fn add(_: *@This(), ctx: *Context) !?trace.Value {
        const lhs = ctx.operand(0);
        const rhs = ctx.operand(1);
        if (ctx.isZero(1)) return lhs.value;
        if (ctx.isZero(0)) return rhs.value;
        return null;
    }
};

test "tensor transform lets users rewrite one primitive" {
    var builder = try trace.Builder.init(std.testing.allocator, "drop_add_zero");
    defer builder.deinit();

    const x = try builder.input(.f32, .{ .lane = 4 });
    const zero = try builder.full(.f32, .{ .lane = 4 }, 0.0);
    const out = try x.add(zero);
    var source = try builder.finish(&.{out});
    defer source.deinit();

    var rewritten = try apply(std.testing.allocator, &source, DropAddZero{});
    defer rewritten.deinit();

    try std.testing.expectEqual(@as(usize, 2), rewritten.valueCount());
    try std.testing.expectEqual(@as(u32, 0), rewritten.outputs[0].index);
}

const BindSecondParameter = struct {
    pub fn parameter(_: *@This(), ctx: *Context) !?trace.Value {
        const parameter_info = ctx.op.kind.parameter;
        if (parameter_info.index == 1) return try ctx.builder.fullFloat(ctx.op.result, 1.0);
        return null;
    }
};

test "tensor transform lets users bind parameters" {
    var builder = try trace.Builder.init(std.testing.allocator, "bind_parameter");
    defer builder.deinit();

    const x = try builder.input(.f32, .{ .lane = 4 });
    const scale = try builder.input(.f32, .{ .lane = 4 });
    const out = try x.mul(scale);
    var source = try builder.finish(&.{out});
    defer source.deinit();

    var rewritten = try apply(std.testing.allocator, &source, BindSecondParameter{});
    defer rewritten.deinit();

    try std.testing.expectEqual(@as(usize, 1), rewritten.parameters.len);
    try types.expectExtents(&.{4}, rewritten.typeOf(rewritten.outputs[0]));
}
