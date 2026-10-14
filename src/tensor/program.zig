const std = @import("std");
const choir = @import("choir");
const type_mod = @import("type/root.zig");

pub const Type = type_mod.Type;
pub const product_name = "accy.tensor_program";

pub const Id = struct {
    index: u32,
};

pub const synthetic_id = Id{ .index = std.math.maxInt(u32) };

pub const Unary = enum {
    neg,
    abs,
    exp,
    log,
    sqrt,
    tanh,
    sin,
    cos,
    tan,
};

pub const Binary = enum {
    add,
    sub,
    mul,
    div,
    max,
    min,
    pow,
};

pub const Reducer = enum {
    sum,
    max,
    min,

    pub fn name(self: Reducer) []const u8 {
        return switch (self) {
            .sum => "sum",
            .max => "max",
            .min => "min",
        };
    }
};

pub const Parameter = struct {
    index: usize,
};

pub const Constant = struct {
    payload: []const u8,
};

pub const UnaryOp = struct {
    op: Unary,
    input: Id,
};

pub const BinaryOp = struct {
    op: Binary,
    lhs: Id,
    rhs: Id,
};

pub const Iota = struct {
    axis: i64,
};

pub const Broadcast = struct {
    input: Id,
    sizes: []const i64,
};

pub const BroadcastInDim = struct {
    input: Id,
    broadcast_dims: []const i64,
};

pub const Reshape = struct {
    input: Id,
    new_shape: []const i64,
};

pub const Transpose = struct {
    input: Id,
    permutation: []const i64,
};

pub const Reduce = struct {
    input: Id,
    init: Id,
    reducer: Reducer,
    dimensions: []const i64,
};

pub const Gather = struct {
    input: Id,
    indices: Id,
    axis: i64,
};

pub const ScatterAdd = struct {
    input: Id,
    indices: Id,
    updates: Id,
    axis: i64,
};

pub const SparseCrossEntropy = struct {
    logits: Id,
    targets: Id,
    axis: i64,
};

pub const CompareDirection = enum {
    lt,
    le,
    gt,
    ge,
    eq,
    ne,
};

pub const Compare = struct {
    lhs: Id,
    rhs: Id,
    direction: CompareDirection,
};

pub const Select = struct {
    pred: Id,
    on_true: Id,
    on_false: Id,
};

pub const max_custom_call_operands: usize = 4;
pub const max_operation_operands: usize = 8;
pub const max_scan_carries: usize = 8;

pub const CustomCall = struct {
    target: []const u8,
    version: u32 = 1,
    operands: []const Id,
};

pub const Subgraph = struct {
    values: []const Type,
    operations: []const Operation,
    parameters: []const Id,
    outputs: []const Id,

    pub fn typeOf(self: Subgraph, id: Id) Type {
        return self.values[id.index];
    }

    pub fn operation(self: Subgraph, id: Id) Operation {
        return self.operations[id.index];
    }
};

pub const Scan = struct {
    length: i64,
    inits: []const Id,
    body: *const Subgraph,
};

pub const Projection = struct {
    source: Id,
    index: usize,
};

pub const DotGeneral = struct {
    lhs: Id,
    rhs: Id,
    lhs_contract: []const i64,
    rhs_contract: []const i64,
    lhs_batch: []const i64,
    rhs_batch: []const i64,
};

pub const Kind = union(enum) {
    parameter: Parameter,
    constant: Constant,
    unary: UnaryOp,
    binary: BinaryOp,
    iota: Iota,
    broadcast: Broadcast,
    broadcast_in_dim: BroadcastInDim,
    reshape: Reshape,
    transpose: Transpose,
    reduce: Reduce,
    gather: Gather,
    scatter_add: ScatterAdd,
    sparse_cross_entropy: SparseCrossEntropy,
    dot_general: DotGeneral,
    compare: Compare,
    select: Select,
    custom_call: CustomCall,
    scan: Scan,
    projection: Projection,
};

pub const Operation = struct {
    id: Id,
    result: Type,
    kind: Kind,
};

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    values: []const Type,
    operations: []const Operation,
    parameters: []const Id,
    outputs: []const Id,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
    }

    pub fn fingerprint(self: Program) choir.product.incremental.Fingerprint {
        var builder = choir.product.incremental.FingerprintBuilder{};
        builder.updateBytes(product_name);
        builder.updateBytes(self.name);
        builder.updateUsize(self.values.len);
        for (self.values) |value| updateTypeFingerprint(&builder, value);
        builder.updateUsize(self.operations.len);
        for (self.operations) |op| updateOperationFingerprint(&builder, op);
        builder.updateUsize(self.parameters.len);
        for (self.parameters) |id| updateIdFingerprint(&builder, id);
        builder.updateUsize(self.outputs.len);
        for (self.outputs) |id| updateIdFingerprint(&builder, id);
        return builder.finish();
    }

    pub fn productStamp(self: Program) choir.product.incremental.ProductStamp {
        return choir.product.incremental.productStamp(product_name, self.fingerprint());
    }

    pub fn valueCount(self: Program) usize {
        return self.values.len;
    }

    pub fn containsScan(self: Program) bool {
        for (self.operations) |op| {
            if (op.kind == .scan) return true;
        }
        return false;
    }

    pub fn operationCount(self: Program) usize {
        return self.operations.len;
    }

    pub fn typeOf(self: Program, id: Id) Type {
        return self.values[id.index];
    }

    pub fn operation(self: Program, id: Id) Operation {
        return self.operations[id.index];
    }

    pub fn isZeroConstant(self: Program, id: Id) bool {
        const op = self.operation(id);
        return switch (op.kind) {
            .constant => |constant| isZeroPayload(constant.payload),
            else => false,
        };
    }

    pub fn constantPayload(self: Program, id: Id) ?[]const u8 {
        const op = self.operation(id);
        return switch (op.kind) {
            .constant => |constant| constant.payload,
            else => null,
        };
    }
};

pub fn isZeroPayload(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn updateIdFingerprint(builder: *choir.product.incremental.FingerprintBuilder, id: Id) void {
    builder.updateU32(id.index);
}

fn updateTypeFingerprint(builder: *choir.product.incremental.FingerprintBuilder, ty: Type) void {
    builder.updateEnumTag(ty.dtype);
    builder.updateUsize(ty.dims.len);
    for (ty.dims) |dim| {
        builder.updateBytes(dim.name);
        builder.updateI64(dim.extent);
    }
}

fn updateOperationFingerprint(
    builder: *choir.product.incremental.FingerprintBuilder,
    op: Operation,
) void {
    updateIdFingerprint(builder, op.id);
    updateTypeFingerprint(builder, op.result);
    builder.updateEnumTag(std.meta.activeTag(op.kind));
    switch (op.kind) {
        .parameter => |parameter| builder.updateUsize(parameter.index),
        .constant => |constant| builder.updateBytes(constant.payload),
        .unary => |unary| {
            builder.updateEnumTag(unary.op);
            updateIdFingerprint(builder, unary.input);
        },
        .binary => |binary| {
            builder.updateEnumTag(binary.op);
            updateIdFingerprint(builder, binary.lhs);
            updateIdFingerprint(builder, binary.rhs);
        },
        .compare => |compare| {
            builder.updateEnumTag(compare.direction);
            updateIdFingerprint(builder, compare.lhs);
            updateIdFingerprint(builder, compare.rhs);
        },
        .select => |select| {
            updateIdFingerprint(builder, select.pred);
            updateIdFingerprint(builder, select.on_true);
            updateIdFingerprint(builder, select.on_false);
        },
        .custom_call => |custom| {
            builder.updateBytes(custom.target);
            builder.updateUsize(custom.version);
            for (custom.operands) |operand| updateIdFingerprint(builder, operand);
        },
        .iota => |iota| builder.updateI64(iota.axis),
        .broadcast => |broadcast| {
            updateIdFingerprint(builder, broadcast.input);
            builder.updateI64Slice(broadcast.sizes);
        },
        .broadcast_in_dim => |broadcast| {
            updateIdFingerprint(builder, broadcast.input);
            builder.updateI64Slice(broadcast.broadcast_dims);
        },
        .reshape => |reshape| {
            updateIdFingerprint(builder, reshape.input);
            builder.updateI64Slice(reshape.new_shape);
        },
        .transpose => |transpose| {
            updateIdFingerprint(builder, transpose.input);
            builder.updateI64Slice(transpose.permutation);
        },
        .reduce => |reduce| {
            updateIdFingerprint(builder, reduce.input);
            updateIdFingerprint(builder, reduce.init);
            builder.updateEnumTag(reduce.reducer);
            builder.updateI64Slice(reduce.dimensions);
        },
        .gather => |gather| {
            updateIdFingerprint(builder, gather.input);
            updateIdFingerprint(builder, gather.indices);
            builder.updateI64(gather.axis);
        },
        .scatter_add => |scatter_add| {
            updateIdFingerprint(builder, scatter_add.input);
            updateIdFingerprint(builder, scatter_add.indices);
            updateIdFingerprint(builder, scatter_add.updates);
            builder.updateI64(scatter_add.axis);
        },
        .sparse_cross_entropy => |sparse_cross_entropy| {
            updateIdFingerprint(builder, sparse_cross_entropy.logits);
            updateIdFingerprint(builder, sparse_cross_entropy.targets);
            builder.updateI64(sparse_cross_entropy.axis);
        },
        .dot_general => |dot| {
            updateIdFingerprint(builder, dot.lhs);
            updateIdFingerprint(builder, dot.rhs);
            builder.updateI64Slice(dot.lhs_contract);
            builder.updateI64Slice(dot.rhs_contract);
            builder.updateI64Slice(dot.lhs_batch);
            builder.updateI64Slice(dot.rhs_batch);
        },
        .scan => |scan| {
            builder.updateI64(scan.length);
            builder.updateUsize(scan.inits.len);
            for (scan.inits) |id| updateIdFingerprint(builder, id);
            builder.updateUsize(scan.body.values.len);
            for (scan.body.values) |value| updateTypeFingerprint(builder, value);
            builder.updateUsize(scan.body.operations.len);
            for (scan.body.operations) |body_op| updateOperationFingerprint(builder, body_op);
            builder.updateUsize(scan.body.parameters.len);
            for (scan.body.parameters) |id| updateIdFingerprint(builder, id);
            builder.updateUsize(scan.body.outputs.len);
            for (scan.body.outputs) |id| updateIdFingerprint(builder, id);
        },
        .projection => |projection| {
            updateIdFingerprint(builder, projection.source);
            builder.updateUsize(projection.index);
        },
    }
}

pub const CloneError = std.mem.Allocator.Error ||
    error{ InvalidDimension, DuplicateAxis, AxisNameEmpty };

pub fn cloneSubgraph(
    allocator: std.mem.Allocator,
    body: *const Subgraph,
) CloneError!*const Subgraph {
    const clone = try allocator.create(Subgraph);
    const values = try allocator.alloc(Type, body.values.len);
    for (body.values, values) |ty, *slot| slot.* = try cloneType(allocator, ty);
    const operations = try allocator.alloc(Operation, body.operations.len);
    for (body.operations, operations) |op, *slot| {
        slot.* = .{
            .id = op.id,
            .result = try cloneType(allocator, op.result),
            .kind = switch (op.kind) {
                .parameter, .iota, .projection => op.kind,
                .constant => |constant| .{
                    .constant = .{ .payload = try allocator.dupe(u8, constant.payload) },
                },
                .unary, .binary, .compare, .select => op.kind,
                .custom_call => |custom| .{ .custom_call = .{
                    .target = try allocator.dupe(u8, custom.target),
                    .version = custom.version,
                    .operands = try allocator.dupe(Id, custom.operands),
                } },
                .broadcast => |broadcast| .{ .broadcast = .{
                    .input = broadcast.input,
                    .sizes = try allocator.dupe(i64, broadcast.sizes),
                } },
                .broadcast_in_dim => |broadcast| .{ .broadcast_in_dim = .{
                    .input = broadcast.input,
                    .broadcast_dims = try allocator.dupe(i64, broadcast.broadcast_dims),
                } },
                .reshape => |reshape| .{ .reshape = .{
                    .input = reshape.input,
                    .new_shape = try allocator.dupe(i64, reshape.new_shape),
                } },
                .transpose => |transpose| .{ .transpose = .{
                    .input = transpose.input,
                    .permutation = try allocator.dupe(i64, transpose.permutation),
                } },
                .reduce => |reduce| .{ .reduce = .{
                    .input = reduce.input,
                    .init = reduce.init,
                    .reducer = reduce.reducer,
                    .dimensions = try allocator.dupe(i64, reduce.dimensions),
                } },
                .gather, .scatter_add, .sparse_cross_entropy => op.kind,
                .dot_general => |dot| .{ .dot_general = .{
                    .lhs = dot.lhs,
                    .rhs = dot.rhs,
                    .lhs_contract = try allocator.dupe(i64, dot.lhs_contract),
                    .rhs_contract = try allocator.dupe(i64, dot.rhs_contract),
                    .lhs_batch = try allocator.dupe(i64, dot.lhs_batch),
                    .rhs_batch = try allocator.dupe(i64, dot.rhs_batch),
                } },
                .scan => |scan| .{ .scan = .{
                    .length = scan.length,
                    .inits = try allocator.dupe(Id, scan.inits),
                    .body = try cloneSubgraph(allocator, scan.body),
                } },
            },
        };
    }
    clone.* = .{
        .values = values,
        .operations = operations,
        .parameters = try allocator.dupe(Id, body.parameters),
        .outputs = try allocator.dupe(Id, body.outputs),
    };
    return clone;
}

fn cloneType(allocator: std.mem.Allocator, ty: Type) !Type {
    return Type.init(allocator, ty.dtype, ty.dims);
}

fn singleConstantProgram(
    allocator: std.mem.Allocator,
    name: []const u8,
    payload: []const u8,
) !Program {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const owned_name = try arena_allocator.dupe(u8, name);
    const ty = try Type.init(arena_allocator, .f32, &.{});
    const owned_payload = try arena_allocator.dupe(u8, payload);
    const values = try arena_allocator.dupe(Type, &.{ty});
    const operations = try arena_allocator.dupe(Operation, &.{
        .{
            .id = .{ .index = 0 },
            .result = ty,
            .kind = .{ .constant = .{ .payload = owned_payload } },
        },
    });
    const outputs = try arena_allocator.dupe(Id, &.{.{ .index = 0 }});

    return .{
        .arena = arena,
        .name = owned_name,
        .values = values,
        .operations = operations,
        .parameters = &.{},
        .outputs = outputs,
    };
}
