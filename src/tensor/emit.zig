const std = @import("std");
const program_mod = @import("program.zig");
const trace = @import("trace/root.zig");
const types = @import("type/root.zig");

pub fn zeros(layer: anytype, ty: trace.Type) !trace.Value {
    const payload = try layer.builderHandle().arena.allocator().alloc(u8, try ty.byteCount());
    @memset(payload, 0);
    return constantBytes(layer, ty, payload);
}

pub fn fullFloat(layer: anytype, ty: trace.Type, fill_value: f64) !trace.Value {
    const owned = try trace.Type.init(layer.builderHandle().arena.allocator(), ty.dtype, ty.dims);
    const count = try owned.elementCount();
    return switch (owned.dtype) {
        .f16 => blk: {
            const payload = try layer.builderHandle().arena.allocator().alloc(f16, count);
            const value: f16 = @floatCast(fill_value);
            for (payload) |*slot| slot.* = value;
            break :blk constantBytes(layer, owned, std.mem.sliceAsBytes(payload));
        },
        .bf16 => blk: {
            const Bf16 = trace.DType.bf16.ZigType();
            const payload = try layer.builderHandle().arena.allocator().alloc(Bf16, count);
            const value = Bf16.fromF32(@floatCast(fill_value));
            for (payload) |*slot| slot.* = value;
            break :blk constantBytes(layer, owned, std.mem.sliceAsBytes(payload));
        },
        .f32 => blk: {
            const payload = try layer.builderHandle().arena.allocator().alloc(f32, count);
            const value: f32 = @floatCast(fill_value);
            for (payload) |*slot| slot.* = value;
            break :blk constantBytes(layer, owned, std.mem.sliceAsBytes(payload));
        },
        .f64 => blk: {
            const payload = try layer.builderHandle().arena.allocator().alloc(f64, count);
            for (payload) |*slot| slot.* = fill_value;
            break :blk constantBytes(layer, owned, std.mem.sliceAsBytes(payload));
        },
        else => error.NonFloatDType,
    };
}

pub fn constantBytes(layer: anytype, ty: trace.Type, payload: []const u8) !trace.Value {
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = ty,
        .kind = .{ .constant = .{ .payload = payload } },
    };
    return layer.next.bind(&op, &.{});
}

pub fn unary(layer: anytype, op_kind: program_mod.Unary, input: trace.Value) !trace.Value {
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = input.ty,
        .kind = .{ .unary = .{ .op = op_kind, .input = program_mod.synthetic_id } },
    };
    return layer.next.bind(&op, &.{input});
}

pub fn binary(
    layer: anytype,
    op_kind: program_mod.Binary,
    lhs: trace.Value,
    rhs: trace.Value,
) !trace.Value {
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = lhs.ty,
        .kind = .{ .binary = .{
            .op = op_kind,
            .lhs = program_mod.synthetic_id,
            .rhs = program_mod.synthetic_id,
        } },
    };
    return layer.next.bind(&op, &.{ lhs, rhs });
}

pub fn compare(
    layer: anytype,
    direction: program_mod.CompareDirection,
    lhs: trace.Value,
    rhs: trace.Value,
) !trace.Value {
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = .{ .dtype = .i1, .dims = lhs.ty.dims },
        .kind = .{ .compare = .{
            .lhs = program_mod.synthetic_id,
            .rhs = program_mod.synthetic_id,
            .direction = direction,
        } },
    };
    return layer.next.bind(&op, &.{ lhs, rhs });
}

pub fn select(
    layer: anytype,
    pred: trace.Value,
    on_true: trace.Value,
    on_false: trace.Value,
) !trace.Value {
    const ty = try types.select(
        layer.builderHandle().arena.allocator(),
        pred.ty,
        on_true.ty,
        on_false.ty,
    );
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = ty,
        .kind = .{ .select = .{
            .pred = program_mod.synthetic_id,
            .on_true = program_mod.synthetic_id,
            .on_false = program_mod.synthetic_id,
        } },
    };
    return layer.next.bind(&op, &.{ pred, on_true, on_false });
}

test "tensor emit select rejects non-boolean predicates before binding" {
    var builder = try trace.Builder.init(std.testing.allocator, "emit_select_predicate");
    defer builder.deinit();

    const pred = try builder.input(.f32, .{ .lane = 4 });
    const on_true = try builder.input(.f32, .{ .lane = 4 });
    const on_false = try builder.input(.f32, .{ .lane = 4 });
    var layer = struct {
        builder: *trace.Builder,
        next: struct {
            pub fn bind(
                _: *@This(),
                _: *const program_mod.Operation,
                _: []const trace.Value,
            ) !trace.Value {
                return error.UnexpectedBind;
            }
        } = .{},

        pub fn builderHandle(self: *@This()) *trace.Builder {
            return self.builder;
        }
    }{ .builder = &builder };

    try std.testing.expectError(error.DTypeMismatch, select(&layer, pred, on_true, on_false));
}

pub fn broadcast(layer: anytype, input: trace.Value, result_dims: []const trace.Dim) !trace.Value {
    const ty = trace.Type{ .dtype = input.ty.dtype, .dims = result_dims };
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = ty,
        .kind = .{ .broadcast = .{
            .input = program_mod.synthetic_id,
            .sizes = try types.extents(layer.builderHandle().arena.allocator(), result_dims),
        } },
    };
    return layer.next.bind(&op, &.{input});
}

pub fn broadcastInDim(
    layer: anytype,
    input: trace.Value,
    result_dims: []const trace.Dim,
    broadcast_dims: []const i64,
) !trace.Value {
    const ty = trace.Type{ .dtype = input.ty.dtype, .dims = result_dims };
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = ty,
        .kind = .{ .broadcast_in_dim = .{
            .input = program_mod.synthetic_id,
            .broadcast_dims = broadcast_dims,
        } },
    };
    return layer.next.bind(&op, &.{input});
}

pub fn reshape(layer: anytype, input: trace.Value, new_dims: []const trace.Dim) !trace.Value {
    const allocator = layer.builderHandle().arena.allocator();
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = try types.reshaped(allocator, input.ty, new_dims),
        .kind = .{ .reshape = .{
            .input = program_mod.synthetic_id,
            .new_shape = try types.extents(allocator, new_dims),
        } },
    };
    return layer.next.bind(&op, &.{input});
}

pub fn transpose(layer: anytype, input: trace.Value, permutation: []const i64) !trace.Value {
    const result_dims = try types.permuted(
        layer.builderHandle().arena.allocator(),
        input.ty.dims,
        permutation,
    );
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = .{ .dtype = input.ty.dtype, .dims = result_dims },
        .kind = .{
            .transpose = .{ .input = program_mod.synthetic_id, .permutation = permutation },
        },
    };
    return layer.next.bind(&op, &.{input});
}

pub fn reduce(
    layer: anytype,
    input: trace.Value,
    init: trace.Value,
    reducer: program_mod.Reducer,
    dimensions: []const i64,
) !trace.Value {
    const result_dims = try types.removeAxes(
        layer.builderHandle().arena.allocator(),
        input.ty.dims,
        dimensions,
    );
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = .{ .dtype = input.ty.dtype, .dims = result_dims },
        .kind = .{ .reduce = .{
            .input = program_mod.synthetic_id,
            .init = program_mod.synthetic_id,
            .reducer = reducer,
            .dimensions = dimensions,
        } },
    };
    return layer.next.bind(&op, &.{ input, init });
}

pub fn iota(
    layer: anytype,
    dtype: trace.DType,
    result_dims: []const trace.Dim,
    axis: i64,
) !trace.Value {
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = .{ .dtype = dtype, .dims = result_dims },
        .kind = .{ .iota = .{ .axis = axis } },
    };
    return layer.next.bind(&op, &.{});
}

pub fn gather(layer: anytype, input: trace.Value, indices: trace.Value, axis: i64) !trace.Value {
    const ty = try types.gather(
        layer.builderHandle().arena.allocator(),
        input.ty,
        indices.ty,
        axis,
    );
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = ty,
        .kind = .{ .gather = .{
            .input = program_mod.synthetic_id,
            .indices = program_mod.synthetic_id,
            .axis = axis,
        } },
    };
    return layer.next.bind(&op, &.{ input, indices });
}

pub fn scatterAdd(
    layer: anytype,
    input: trace.Value,
    indices: trace.Value,
    updates: trace.Value,
    axis: i64,
) !trace.Value {
    const ty = try types.scatterAdd(
        layer.builderHandle().arena.allocator(),
        input.ty,
        indices.ty,
        updates.ty,
        axis,
    );
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = ty,
        .kind = .{ .scatter_add = .{
            .input = program_mod.synthetic_id,
            .indices = program_mod.synthetic_id,
            .updates = program_mod.synthetic_id,
            .axis = axis,
        } },
    };
    return layer.next.bind(&op, &.{ input, indices, updates });
}

pub fn sparseCrossEntropy(
    layer: anytype,
    logits: trace.Value,
    targets: trace.Value,
    axis: i64,
) !trace.Value {
    const ty = try types.sparseCrossEntropy(
        layer.builderHandle().arena.allocator(),
        logits.ty,
        targets.ty,
        axis,
    );
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = ty,
        .kind = .{ .sparse_cross_entropy = .{
            .logits = program_mod.synthetic_id,
            .targets = program_mod.synthetic_id,
            .axis = axis,
        } },
    };
    return layer.next.bind(&op, &.{ logits, targets });
}

pub fn dotGeneral(
    layer: anytype,
    lhs: trace.Value,
    rhs: trace.Value,
    lhs_contract: []const i64,
    rhs_contract: []const i64,
    lhs_batch: []const i64,
    rhs_batch: []const i64,
) !trace.Value {
    const result_dims = try types.dotGeneralDims(
        layer.builderHandle().arena.allocator(),
        lhs.ty.dims,
        rhs.ty.dims,
        lhs_contract,
        rhs_contract,
        lhs_batch,
        rhs_batch,
    );
    var op = program_mod.Operation{
        .id = program_mod.synthetic_id,
        .result = .{ .dtype = lhs.ty.dtype, .dims = result_dims },
        .kind = .{
            .dot_general = .{
                .lhs = program_mod.synthetic_id,
                .rhs = program_mod.synthetic_id,
                .lhs_contract = lhs_contract,
                .rhs_contract = rhs_contract,
                .lhs_batch = lhs_batch,
                .rhs_batch = rhs_batch,
            },
        },
    };
    return layer.next.bind(&op, &.{ lhs, rhs });
}
