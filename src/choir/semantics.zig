const std = @import("std");
const gpu_abi = @import("gpu_abi");
const testing = std.testing;
const axis_roles = @import("../axis/root.zig").roles;
const activation = @import("activation.zig");
const einsum = @import("einsum/root.zig");

pub const Allocator = std.mem.Allocator;
pub const DType = gpu_abi.DType;

pub const Type = struct {
    dtype: DType,
    dims: []const i64,

    pub fn eql(a: Type, b: Type) bool {
        return a.dtype == b.dtype and std.mem.eql(i64, a.dims, b.dims);
    }
};

pub const OpKind = enum(u8) {
    constant,
    parameter,
    iota,
    add,
    sub,
    mul,
    div,
    max,
    min,
    pow,
    compare,
    neg,
    exp,
    log,
    tanh,
    sqrt,
    activation,
    abs,
    sin,
    cos,
    tan,
    floor,
    round,
    trunc,
    atan2,
    convert,
    reduce,
    dot_general,
    einsum,
    broadcast,
    broadcast_in_dim,
    reshape,
    transpose,
    slice,
    gather,
    scatter,
    scatter_add,
    sparse_cross_entropy,
    pad,
    concatenate,
    select,
    cumsum,
    scratch,
    kernel_call,
    iterate,
    iterate_yield,
    @"return",
};

pub const CompareDirection = enum { eq, ne, lt, le, gt, ge };

pub const ActivationKind = activation.Kind;

pub const ReducerKind = enum { sum, max, min };

pub const KernelOperandEffect = enum(u8) {
    none,
    read,
    write,
    read_write,
    unknown,

    pub fn fromByte(value: u8) ?KernelOperandEffect {
        return switch (value) {
            @backingInt(KernelOperandEffect.none) => .none,
            @backingInt(KernelOperandEffect.read) => .read,
            @backingInt(KernelOperandEffect.write) => .write,
            @backingInt(KernelOperandEffect.read_write) => .read_write,
            @backingInt(KernelOperandEffect.unknown) => .unknown,
            else => null,
        };
    }

    pub fn writes(self: KernelOperandEffect) bool {
        return switch (self) {
            .write, .read_write, .unknown => true,
            .none, .read => false,
        };
    }
};

pub const KernelCallContract = struct {
    target: []const u8,
    version: u32,
    has_side_effects: bool,
    operand_effects: []const KernelOperandEffect,
    result_aliases: []const ?usize,
    results: []const Type,
};

pub const Attribute = union(enum) {
    i64: i64,
    i64_list: []const i64,
    dtype: DType,
    compare_direction: CompareDirection,
    activation_kind: ActivationKind,
    reducer_kind: ReducerKind,
    kernel_call: KernelCallContract,
    bytes: []const u8,
    einsum: []const u8,
};

pub const InferError = error{
    ArityMismatch,
    DTypeMismatch,
    ShapeMismatch,
    RankMismatch,
    AttributeMissing,
    AttributeKindMismatch,
    InvalidDimension,
    ElementCountMismatch,
    InvalidPermutation,
    DimMismatch,
    ContractionMismatch,
    InvalidEinsum,
    InvalidKernelContract,
} || Allocator.Error;

pub const InferFn = *const fn (
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type;

pub const SupportedDTypes = enum {
    any,
    arithmetic,
    float_only,

    pub fn allows(self: SupportedDTypes, dt: DType) bool {
        return switch (self) {
            .any => true,
            .arithmetic => dt.isNumeric(),
            .float_only => dt.isFloat(),
        };
    }
};

pub const OpInfo = struct {
    kind: OpKind,
    name: []const u8,
    supported_dtypes: SupportedDTypes,
    infer: InferFn,
};

pub fn info(kind: OpKind) OpInfo {
    return switch (kind) {
        .constant => .{
            .kind = .constant,
            .name = "constant",
            .supported_dtypes = .any,
            .infer = inferConstant,
        },
        .parameter => .{
            .kind = .parameter,
            .name = "parameter",
            .supported_dtypes = .any,
            .infer = inferParameter,
        },
        .iota => .{ .kind = .iota, .name = "iota", .supported_dtypes = .any, .infer = inferIota },
        .add => .{
            .kind = .add,
            .name = "add",
            .supported_dtypes = .arithmetic,
            .infer = inferElementwiseBinary,
        },
        .sub => .{
            .kind = .sub,
            .name = "sub",
            .supported_dtypes = .arithmetic,
            .infer = inferElementwiseBinary,
        },
        .mul => .{
            .kind = .mul,
            .name = "mul",
            .supported_dtypes = .arithmetic,
            .infer = inferElementwiseBinary,
        },
        .div => .{
            .kind = .div,
            .name = "div",
            .supported_dtypes = .arithmetic,
            .infer = inferElementwiseBinary,
        },
        .max => .{
            .kind = .max,
            .name = "max",
            .supported_dtypes = .arithmetic,
            .infer = inferElementwiseBinary,
        },
        .min => .{
            .kind = .min,
            .name = "min",
            .supported_dtypes = .arithmetic,
            .infer = inferElementwiseBinary,
        },
        .pow => .{
            .kind = .pow,
            .name = "pow",
            .supported_dtypes = .float_only,
            .infer = inferElementwiseBinary,
        },
        .compare => .{
            .kind = .compare,
            .name = "compare",
            .supported_dtypes = .any,
            .infer = inferCompare,
        },
        .neg => .{
            .kind = .neg,
            .name = "neg",
            .supported_dtypes = .arithmetic,
            .infer = inferElementwiseUnary,
        },
        .exp => .{
            .kind = .exp,
            .name = "exp",
            .supported_dtypes = .float_only,
            .infer = inferElementwiseUnary,
        },
        .log => .{
            .kind = .log,
            .name = "log",
            .supported_dtypes = .float_only,
            .infer = inferElementwiseUnary,
        },
        .tanh => .{
            .kind = .tanh,
            .name = "tanh",
            .supported_dtypes = .float_only,
            .infer = inferElementwiseUnary,
        },
        .sqrt => .{
            .kind = .sqrt,
            .name = "sqrt",
            .supported_dtypes = .float_only,
            .infer = inferElementwiseUnary,
        },
        .activation => .{
            .kind = .activation,
            .name = "activation",
            .supported_dtypes = .float_only,
            .infer = inferActivation,
        },
        .abs => .{
            .kind = .abs,
            .name = "abs",
            .supported_dtypes = .arithmetic,
            .infer = inferElementwiseUnary,
        },
        .sin => .{
            .kind = .sin,
            .name = "sin",
            .supported_dtypes = .float_only,
            .infer = inferElementwiseUnary,
        },
        .cos => .{
            .kind = .cos,
            .name = "cos",
            .supported_dtypes = .float_only,
            .infer = inferElementwiseUnary,
        },
        .tan => .{
            .kind = .tan,
            .name = "tan",
            .supported_dtypes = .float_only,
            .infer = inferElementwiseUnary,
        },
        .floor => .{
            .kind = .floor,
            .name = "floor",
            .supported_dtypes = .float_only,
            .infer = inferElementwiseUnary,
        },
        .round => .{
            .kind = .round,
            .name = "round",
            .supported_dtypes = .float_only,
            .infer = inferElementwiseUnary,
        },
        .trunc => .{
            .kind = .trunc,
            .name = "trunc",
            .supported_dtypes = .float_only,
            .infer = inferElementwiseUnary,
        },
        .atan2 => .{
            .kind = .atan2,
            .name = "atan2",
            .supported_dtypes = .float_only,
            .infer = inferElementwiseBinary,
        },
        .convert => .{
            .kind = .convert,
            .name = "convert",
            .supported_dtypes = .any,
            .infer = inferConvert,
        },
        .reduce => .{
            .kind = .reduce,
            .name = "reduce",
            .supported_dtypes = .any,
            .infer = inferReduce,
        },
        .dot_general => .{
            .kind = .dot_general,
            .name = "dot_general",
            .supported_dtypes = .arithmetic,
            .infer = inferDotGeneral,
        },
        .einsum => .{
            .kind = .einsum,
            .name = "einsum",
            .supported_dtypes = .arithmetic,
            .infer = inferEinsum,
        },
        .broadcast => .{
            .kind = .broadcast,
            .name = "broadcast",
            .supported_dtypes = .any,
            .infer = inferBroadcast,
        },
        .broadcast_in_dim => .{
            .kind = .broadcast_in_dim,
            .name = "broadcast_in_dim",
            .supported_dtypes = .any,
            .infer = inferBroadcastInDim,
        },
        .reshape => .{
            .kind = .reshape,
            .name = "reshape",
            .supported_dtypes = .any,
            .infer = inferReshape,
        },
        .transpose => .{
            .kind = .transpose,
            .name = "transpose",
            .supported_dtypes = .any,
            .infer = inferTranspose,
        },
        .slice => .{
            .kind = .slice,
            .name = "slice",
            .supported_dtypes = .any,
            .infer = inferSlice,
        },
        .gather => .{
            .kind = .gather,
            .name = "gather",
            .supported_dtypes = .any,
            .infer = inferGather,
        },
        .scatter => .{
            .kind = .scatter,
            .name = "scatter",
            .supported_dtypes = .any,
            .infer = inferScatter,
        },
        .scatter_add => .{
            .kind = .scatter_add,
            .name = "scatter_add",
            .supported_dtypes = .any,
            .infer = inferScatter,
        },
        .sparse_cross_entropy => .{
            .kind = .sparse_cross_entropy,
            .name = "sparse_cross_entropy",
            .supported_dtypes = .any,
            .infer = inferSparseCrossEntropy,
        },
        .pad => .{ .kind = .pad, .name = "pad", .supported_dtypes = .any, .infer = inferPad },
        .concatenate => .{
            .kind = .concatenate,
            .name = "concatenate",
            .supported_dtypes = .any,
            .infer = inferConcatenate,
        },
        .select => .{
            .kind = .select,
            .name = "select",
            .supported_dtypes = .any,
            .infer = inferSelect,
        },
        .cumsum => .{
            .kind = .cumsum,
            .name = "cumsum",
            .supported_dtypes = .arithmetic,
            .infer = inferCumsum,
        },
        .scratch => .{
            .kind = .scratch,
            .name = "scratch",
            .supported_dtypes = .any,
            .infer = inferScratch,
        },
        .kernel_call => .{
            .kind = .kernel_call,
            .name = "kernel_call",
            .supported_dtypes = .any,
            .infer = inferKernelCall,
        },
        .iterate => .{
            .kind = .iterate,
            .name = "iterate",
            .supported_dtypes = .any,
            .infer = inferIterate,
        },
        .iterate_yield => .{
            .kind = .iterate_yield,
            .name = "iterate_yield",
            .supported_dtypes = .any,
            .infer = inferIterateYield,
        },
        .@"return" => .{
            .kind = .@"return",
            .name = "return",
            .supported_dtypes = .any,
            .infer = inferReturn,
        },
    };
}

pub fn inferShape(
    kind: OpKind,
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    return try info(kind).infer(arena, inputs, attrs);
}

fn inferAttrI64(attrs: []const Attribute, idx: usize) InferError!i64 {
    if (idx >= attrs.len) return error.AttributeMissing;
    return switch (attrs[idx]) {
        .i64 => |v| v,
        else => error.AttributeKindMismatch,
    };
}

fn inferAttrI64List(attrs: []const Attribute, idx: usize) InferError![]const i64 {
    if (idx >= attrs.len) return error.AttributeMissing;
    return switch (attrs[idx]) {
        .i64_list => |v| v,
        else => error.AttributeKindMismatch,
    };
}

fn inferAttrDType(attrs: []const Attribute, idx: usize) InferError!DType {
    if (idx >= attrs.len) return error.AttributeMissing;
    return switch (attrs[idx]) {
        .dtype => |v| v,
        else => error.AttributeKindMismatch,
    };
}

fn inferAttrCompareDirection(attrs: []const Attribute, idx: usize) InferError!CompareDirection {
    if (idx >= attrs.len) return error.AttributeMissing;
    return switch (attrs[idx]) {
        .compare_direction => |v| v,
        else => error.AttributeKindMismatch,
    };
}

fn inferAttrActivationKind(attrs: []const Attribute, idx: usize) InferError!ActivationKind {
    if (idx >= attrs.len) return error.AttributeMissing;
    return switch (attrs[idx]) {
        .activation_kind => |v| v,
        else => error.AttributeKindMismatch,
    };
}

fn inferAttrReducerKind(attrs: []const Attribute, idx: usize) InferError!ReducerKind {
    if (idx >= attrs.len) return error.AttributeMissing;
    return switch (attrs[idx]) {
        .reducer_kind => |v| v,
        else => error.AttributeKindMismatch,
    };
}

fn inferAttrBytes(attrs: []const Attribute, idx: usize) InferError![]const u8 {
    if (idx >= attrs.len) return error.AttributeMissing;
    return switch (attrs[idx]) {
        .bytes => |v| v,
        else => error.AttributeKindMismatch,
    };
}

fn inferAttrEinsum(attrs: []const Attribute, idx: usize) InferError![]const u8 {
    if (idx >= attrs.len) return error.AttributeMissing;
    return switch (attrs[idx]) {
        .einsum => |v| v,
        else => error.AttributeKindMismatch,
    };
}

fn inferAttrKernelCall(attrs: []const Attribute, idx: usize) InferError!KernelCallContract {
    if (idx >= attrs.len) return error.AttributeMissing;
    return switch (attrs[idx]) {
        .kernel_call => |v| v,
        else => error.AttributeKindMismatch,
    };
}

fn singletonType(arena: Allocator, t: Type) InferError![]const Type {
    const out = try arena.alloc(Type, 1);
    out[0] = t;
    return out;
}

fn duplicateDims(arena: Allocator, dims: []const i64) InferError![]const i64 {
    return arena.dupe(i64, dims);
}

fn duplicateTypes(arena: Allocator, types: []const Type) InferError![]const Type {
    const out = try arena.alloc(Type, types.len);
    for (types, 0..) |typ, i| {
        for (typ.dims) |d| if (d < 0) return error.InvalidDimension;
        out[i] = .{
            .dtype = typ.dtype,
            .dims = try duplicateDims(arena, typ.dims),
        };
    }
    return out;
}

pub fn inferConstant(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 0) return error.ArityMismatch;
    _ = try inferAttrBytes(attrs, 0);
    const dt = try inferAttrDType(attrs, 1);
    const dims = try inferAttrI64List(attrs, 2);
    return singletonType(arena, .{
        .dtype = dt,
        .dims = try duplicateDims(arena, dims),
    });
}

pub fn inferParameter(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 0) return error.ArityMismatch;
    const idx = try inferAttrI64(attrs, 0);
    if (idx < 0) return error.InvalidDimension;
    const dt = try inferAttrDType(attrs, 1);
    const dims = try inferAttrI64List(attrs, 2);
    return singletonType(arena, .{
        .dtype = dt,
        .dims = try duplicateDims(arena, dims),
    });
}

pub fn inferIota(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 0) return error.ArityMismatch;
    const dim = try inferAttrI64(attrs, 0);
    const dt = try inferAttrDType(attrs, 1);
    const dims = try inferAttrI64List(attrs, 2);
    if (dim < 0 or dim >= @as(i64, @intCast(dims.len))) return error.InvalidDimension;
    return singletonType(arena, .{
        .dtype = dt,
        .dims = try duplicateDims(arena, dims),
    });
}

pub fn inferElementwiseBinary(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    _ = attrs;
    if (inputs.len != 2) return error.ArityMismatch;
    if (inputs[0].dtype != inputs[1].dtype) return error.DTypeMismatch;
    if (!std.mem.eql(i64, inputs[0].dims, inputs[1].dims)) return error.ShapeMismatch;
    return singletonType(arena, .{
        .dtype = inputs[0].dtype,
        .dims = try duplicateDims(arena, inputs[0].dims),
    });
}

pub fn inferCompare(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    _ = try inferAttrCompareDirection(attrs, 0);
    if (inputs.len != 2) return error.ArityMismatch;
    if (inputs[0].dtype != inputs[1].dtype) return error.DTypeMismatch;
    if (!std.mem.eql(i64, inputs[0].dims, inputs[1].dims)) return error.ShapeMismatch;
    return singletonType(arena, .{
        .dtype = .i1,
        .dims = try duplicateDims(arena, inputs[0].dims),
    });
}

pub fn inferElementwiseUnary(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    _ = attrs;
    if (inputs.len != 1) return error.ArityMismatch;
    return singletonType(arena, .{
        .dtype = inputs[0].dtype,
        .dims = try duplicateDims(arena, inputs[0].dims),
    });
}

pub fn inferActivation(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    _ = try inferAttrActivationKind(attrs, 0);
    return inferElementwiseUnary(arena, inputs, attrs);
}

pub fn inferConvert(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 1) return error.ArityMismatch;
    const target = try inferAttrDType(attrs, 0);
    return singletonType(arena, .{
        .dtype = target,
        .dims = try duplicateDims(arena, inputs[0].dims),
    });
}

pub fn inferReduce(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 2) return error.ArityMismatch;
    _ = try inferAttrReducerKind(attrs, 0);
    const dims = try inferAttrI64List(attrs, 1);
    const operand = inputs[0];
    const init = inputs[1];
    if (operand.dtype != init.dtype) return error.DTypeMismatch;
    if (init.dims.len != 0) return error.RankMismatch;
    const rank: i64 = @intCast(operand.dims.len);
    for (dims, 0..) |d, i| {
        if (d < 0 or d >= rank) return error.InvalidDimension;
        for (dims[0..i]) |e| if (e == d) return error.InvalidDimension;
    }
    const out_rank = operand.dims.len - dims.len;
    const out_dims = try arena.alloc(i64, out_rank);
    var j: usize = 0;
    outer: for (operand.dims, 0..) |size, idx_u| {
        const idx: i64 = @intCast(idx_u);
        for (dims) |d| if (d == idx) continue :outer;
        out_dims[j] = size;
        j += 1;
    }
    std.debug.assert(j == out_rank);
    return singletonType(arena, .{ .dtype = operand.dtype, .dims = out_dims });
}

pub fn inferDotGeneral(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 2) return error.ArityMismatch;
    const lhs = inputs[0];
    const rhs = inputs[1];
    if (lhs.dtype != rhs.dtype) return error.DTypeMismatch;
    const lhs_batch = try inferAttrI64List(attrs, 0);
    const rhs_batch = try inferAttrI64List(attrs, 1);
    const lhs_contract = try inferAttrI64List(attrs, 2);
    const rhs_contract = try inferAttrI64List(attrs, 3);
    const result_dtype = try inferDotGeneralResultDType(lhs.dtype, attrs);
    if (lhs_batch.len != rhs_batch.len) return error.ContractionMismatch;
    if (lhs_contract.len != rhs_contract.len) return error.ContractionMismatch;

    if (axis_roles.check(lhs.dims.len, &.{ lhs_batch, lhs_contract }) != null) {
        return error.InvalidDimension;
    }
    if (axis_roles.check(rhs.dims.len, &.{ rhs_batch, rhs_contract }) != null) {
        return error.InvalidDimension;
    }

    for (lhs_batch, rhs_batch) |ld, rd| {
        if (lhs.dims[@intCast(ld)] != rhs.dims[@intCast(rd)]) return error.ContractionMismatch;
    }
    for (lhs_contract, rhs_contract) |ld, rd| {
        if (lhs.dims[@intCast(ld)] != rhs.dims[@intCast(rd)]) return error.ContractionMismatch;
    }

    const out_rank = lhs_batch.len +
        (lhs.dims.len - lhs_batch.len - lhs_contract.len) +
        (rhs.dims.len - rhs_batch.len - rhs_contract.len);
    const out_dims = try arena.alloc(i64, out_rank);
    var w: usize = 0;
    for (lhs_batch) |d| {
        out_dims[w] = lhs.dims[@intCast(d)];
        w += 1;
    }
    for (lhs.dims, 0..) |size, idx_u| {
        const idx: i64 = @intCast(idx_u);
        if (containsDim(lhs_batch, idx)) continue;
        if (containsDim(lhs_contract, idx)) continue;
        out_dims[w] = size;
        w += 1;
    }
    for (rhs.dims, 0..) |size, idx_u| {
        const idx: i64 = @intCast(idx_u);
        if (containsDim(rhs_batch, idx)) continue;
        if (containsDim(rhs_contract, idx)) continue;
        out_dims[w] = size;
        w += 1;
    }
    std.debug.assert(w == out_rank);
    return singletonType(arena, .{ .dtype = result_dtype, .dims = out_dims });
}

pub fn inferEinsum(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len == 0) return error.ArityMismatch;
    const equation_text = try inferAttrEinsum(attrs, 0);
    const dtype = inputs[0].dtype;
    const shapes = try arena.alloc([]const u64, inputs.len);
    for (inputs, 0..) |input, input_index| {
        if (input.dtype != dtype) return error.DTypeMismatch;
        const dims = try arena.alloc(u64, input.dims.len);
        for (input.dims, 0..) |dim, dim_index| {
            if (dim < 0) return error.InvalidDimension;
            dims[dim_index] = @intCast(dim);
        }
        shapes[input_index] = dims;
    }

    var parsed = einsum.parse(arena, equation_text, shapes) catch return error.InvalidEinsum;
    defer parsed.deinit();

    const out_dims = try arena.alloc(i64, parsed.output.len);
    for (parsed.output, 0..) |index, i| {
        const dim = parsed.dimension(index);
        if (dim > @as(u64, @intCast(std.math.maxInt(i64)))) return error.InvalidDimension;
        out_dims[i] = @intCast(dim);
    }
    return singletonType(arena, .{ .dtype = dtype, .dims = out_dims });
}

fn inferDotGeneralResultDType(input_dtype: DType, attrs: []const Attribute) InferError!DType {
    if (attrs.len == 4) return input_dtype;
    if (attrs.len != 5) return error.AttributeKindMismatch;
    const result_dtype = try inferAttrDType(attrs, 4);
    if (!dotGeneralResultDTypeAllowed(input_dtype, result_dtype)) return error.DTypeMismatch;
    return result_dtype;
}

fn dotGeneralResultDTypeAllowed(input_dtype: DType, result_dtype: DType) bool {
    return input_dtype == result_dtype or (input_dtype == .f16 and result_dtype == .f32);
}

fn containsDim(list: []const i64, d: i64) bool {
    for (list) |e| if (e == d) return true;
    return false;
}

pub fn inferBroadcast(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 1) return error.ArityMismatch;
    const sizes = try inferAttrI64List(attrs, 0);
    for (sizes) |s| if (s < 0) return error.InvalidDimension;
    const out_dims = try arena.alloc(i64, sizes.len + inputs[0].dims.len);
    @memcpy(out_dims[0..sizes.len], sizes);
    @memcpy(out_dims[sizes.len..], inputs[0].dims);
    return singletonType(arena, .{ .dtype = inputs[0].dtype, .dims = out_dims });
}

pub fn inferBroadcastInDim(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 1) return error.ArityMismatch;
    const broadcast_dims = try inferAttrI64List(attrs, 0);
    const result_shape = try inferAttrI64List(attrs, 1);
    const operand = inputs[0];

    if (broadcast_dims.len != operand.dims.len) return error.ArityMismatch;
    const result_rank: i64 = @intCast(result_shape.len);
    for (broadcast_dims, 0..) |d, i| {
        if (d < 0 or d >= result_rank) return error.InvalidDimension;
        for (broadcast_dims[0..i]) |e| if (e == d) return error.InvalidDimension;
    }
    for (broadcast_dims, operand.dims) |target, operand_dim| {
        const out_dim = result_shape[@intCast(target)];
        if (operand_dim != 1 and operand_dim != out_dim) return error.ShapeMismatch;
    }
    for (result_shape) |s| if (s < 0) return error.InvalidDimension;
    return singletonType(arena, .{
        .dtype = operand.dtype,
        .dims = try duplicateDims(arena, result_shape),
    });
}

pub fn inferReshape(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 1) return error.ArityMismatch;
    const new_shape = try inferAttrI64List(attrs, 0);
    for (new_shape) |s| if (s < 0) return error.InvalidDimension;
    const old_count = productI64(inputs[0].dims);
    const new_count = productI64(new_shape);
    if (old_count != new_count) return error.ElementCountMismatch;
    return singletonType(arena, .{
        .dtype = inputs[0].dtype,
        .dims = try duplicateDims(arena, new_shape),
    });
}

fn productI64(dims: []const i64) i64 {
    var p: i64 = 1;
    for (dims) |d| p *= d;
    return p;
}

pub fn inferTranspose(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 1) return error.ArityMismatch;
    const perm = try inferAttrI64List(attrs, 0);
    const operand = inputs[0];
    if (perm.len != operand.dims.len) return error.InvalidPermutation;
    const rank: i64 = @intCast(operand.dims.len);
    for (perm, 0..) |d, i| {
        if (d < 0 or d >= rank) return error.InvalidPermutation;
        for (perm[0..i]) |e| if (e == d) return error.InvalidPermutation;
    }
    const out_dims = try arena.alloc(i64, operand.dims.len);
    for (perm, 0..) |d, i| out_dims[i] = operand.dims[@intCast(d)];
    return singletonType(arena, .{ .dtype = operand.dtype, .dims = out_dims });
}

pub fn inferSlice(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 1) return error.ArityMismatch;
    const start = try inferAttrI64List(attrs, 0);
    const limit = try inferAttrI64List(attrs, 1);
    const stride = try inferAttrI64List(attrs, 2);
    const operand = inputs[0];
    if (start.len != operand.dims.len or
        limit.len != operand.dims.len or
        stride.len != operand.dims.len) return error.InvalidDimension;
    const out_dims = try arena.alloc(i64, operand.dims.len);
    for (start, limit, stride, operand.dims, 0..) |s, l, st, full, i| {
        if (st <= 0) return error.InvalidDimension;
        if (s < 0 or l < s or l > full) return error.InvalidDimension;
        const span = l - s;
        out_dims[i] = @divTrunc(span + st - 1, st);
    }
    return singletonType(arena, .{ .dtype = operand.dtype, .dims = out_dims });
}

pub fn inferGather(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 2) return error.ArityMismatch;
    const axis_i64 = try inferAttrI64(attrs, 0);
    const operand = inputs[0];
    const indices = inputs[1];
    if (!isIndexDType(indices.dtype)) return error.DTypeMismatch;
    const rank: i64 = @intCast(operand.dims.len);
    if (axis_i64 < 0 or axis_i64 >= rank) return error.InvalidDimension;
    const axis: usize = @intCast(axis_i64);

    const out_rank = operand.dims.len - 1 + indices.dims.len;
    const out_dims = try arena.alloc(i64, out_rank);
    var out_i: usize = 0;
    for (operand.dims[0..axis]) |dim| {
        out_dims[out_i] = dim;
        out_i += 1;
    }
    for (indices.dims) |dim| {
        if (dim < 0) return error.InvalidDimension;
        out_dims[out_i] = dim;
        out_i += 1;
    }
    for (operand.dims[axis + 1 ..]) |dim| {
        out_dims[out_i] = dim;
        out_i += 1;
    }
    return singletonType(arena, .{ .dtype = operand.dtype, .dims = out_dims });
}

pub fn inferScatter(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 3) return error.ArityMismatch;
    const axis_i64 = try inferAttrI64(attrs, 0);
    const operand = inputs[0];
    const indices = inputs[1];
    const updates = inputs[2];
    if (!isIndexDType(indices.dtype)) return error.DTypeMismatch;
    if (updates.dtype != operand.dtype) return error.DTypeMismatch;
    const rank: i64 = @intCast(operand.dims.len);
    if (axis_i64 < 0 or axis_i64 >= rank) return error.InvalidDimension;
    const axis: usize = @intCast(axis_i64);

    const expected_rank = operand.dims.len - 1 + indices.dims.len;
    if (updates.dims.len != expected_rank) return error.RankMismatch;

    var update_axis: usize = 0;
    for (operand.dims[0..axis]) |dim| {
        if (updates.dims[update_axis] != dim) return error.ShapeMismatch;
        update_axis += 1;
    }
    for (indices.dims) |dim| {
        if (dim < 0) return error.InvalidDimension;
        if (updates.dims[update_axis] != dim) return error.ShapeMismatch;
        update_axis += 1;
    }
    for (operand.dims[axis + 1 ..]) |dim| {
        if (updates.dims[update_axis] != dim) return error.ShapeMismatch;
        update_axis += 1;
    }

    const out_dims = try arena.dupe(i64, operand.dims);
    return singletonType(arena, .{ .dtype = operand.dtype, .dims = out_dims });
}

pub fn inferSparseCrossEntropy(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    _ = attrs;
    if (inputs.len != 2) return error.ArityMismatch;
    const logits = inputs[0];
    const targets = inputs[1];
    if (!logits.dtype.isFloat()) return error.DTypeMismatch;
    if (!isIndexDType(targets.dtype)) return error.DTypeMismatch;
    if (logits.dims.len != 2 or targets.dims.len != 1) return error.RankMismatch;
    if (logits.dims[0] < 0 or logits.dims[1] < 0) return error.InvalidDimension;
    if (targets.dims[0] != logits.dims[0]) return error.ShapeMismatch;

    const out_dims = try arena.dupe(i64, logits.dims[0..1]);
    return singletonType(arena, .{ .dtype = logits.dtype, .dims = out_dims });
}

pub fn inferPad(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len != 2) return error.ArityMismatch;
    const low = try inferAttrI64List(attrs, 0);
    const high = try inferAttrI64List(attrs, 1);
    const interior = try inferAttrI64List(attrs, 2);
    const operand = inputs[0];
    const padding_value = inputs[1];
    if (padding_value.dtype != operand.dtype) return error.DTypeMismatch;
    if (padding_value.dims.len != 0) return error.RankMismatch;
    if (low.len != operand.dims.len or
        high.len != operand.dims.len or interior.len != operand.dims.len)
    {
        return error.InvalidDimension;
    }

    const out_dims = try arena.alloc(i64, operand.dims.len);
    for (operand.dims, low, high, interior, 0..) |input_dim, lo, hi, inner, i| {
        if (input_dim < 0 or inner < 0) return error.InvalidDimension;
        const gap_count = if (input_dim > 0) input_dim - 1 else 0;
        const interior_total = std.math.mul(
            i64,
            gap_count,
            inner,
        ) catch return error.InvalidDimension;
        const with_low = std.math.add(i64, input_dim, lo) catch return error.InvalidDimension;
        const with_high = std.math.add(i64, with_low, hi) catch return error.InvalidDimension;
        const result_dim = std.math.add(
            i64,
            with_high,
            interior_total,
        ) catch return error.InvalidDimension;
        if (result_dim < 0) return error.InvalidDimension;
        out_dims[i] = result_dim;
    }
    return singletonType(arena, .{ .dtype = operand.dtype, .dims = out_dims });
}

fn isIndexDType(dtype: DType) bool {
    return dtype.isSignedInt() or dtype.isUnsignedInt();
}

pub fn inferConcatenate(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    if (inputs.len == 0) return error.ArityMismatch;
    const dim = try inferAttrI64(attrs, 0);
    const first = inputs[0];
    const rank: i64 = @intCast(first.dims.len);
    if (dim < 0 or dim >= rank) return error.InvalidDimension;
    const concat_axis: usize = @intCast(dim);

    var summed = first.dims[concat_axis];
    for (inputs[1..]) |t| {
        if (t.dtype != first.dtype) return error.DTypeMismatch;
        if (t.dims.len != first.dims.len) return error.RankMismatch;
        for (t.dims, first.dims, 0..) |a, b, i| {
            if (i == concat_axis) continue;
            if (a != b) return error.DimMismatch;
        }
        summed += t.dims[concat_axis];
    }
    const out_dims = try arena.alloc(i64, first.dims.len);
    @memcpy(out_dims, first.dims);
    out_dims[concat_axis] = summed;
    return singletonType(arena, .{ .dtype = first.dtype, .dims = out_dims });
}

pub fn inferScratch(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    const words = try inferAttrI64(attrs, 0);
    if (inputs.len != 0) return error.ArityMismatch;
    if (words < 1) return error.InvalidDimension;
    const dims = try arena.alloc(i64, 1);
    dims[0] = words;
    return singletonType(arena, .{ .dtype = .u32, .dims = dims });
}

pub fn inferCumsum(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    const axis = try inferAttrI64(attrs, 0);
    if (inputs.len < 1 or inputs.len > 2) return error.ArityMismatch;
    if (axis < 0 or axis >= @as(i64, @intCast(inputs[0].dims.len))) return error.InvalidDimension;
    return singletonType(arena, .{
        .dtype = inputs[0].dtype,
        .dims = try duplicateDims(arena, inputs[0].dims),
    });
}

pub fn inferIterate(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    const max_iters = try inferAttrI64(attrs, 0);
    if (max_iters < 1) return error.InvalidDimension;
    if (inputs.len == 0) return error.ArityMismatch;
    try verifySingleElementDomain(inputs);
    const results = try arena.alloc(Type, inputs.len);
    for (results, inputs) |*result, input| {
        result.* = .{ .dtype = input.dtype, .dims = try duplicateDims(arena, input.dims) };
    }
    return results;
}

pub fn inferIterateYield(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    _ = attrs;
    if (inputs.len < 2) return error.ArityMismatch;
    if (inputs[0].dtype != .i1) return error.DTypeMismatch;
    if (typeElementCount(inputs[0]) != 1) {
        for (inputs[1..]) |carry| {
            if (typeElementCount(carry) == 1) continue;
            if (!std.mem.eql(i64, carry.dims, inputs[0].dims)) return error.ShapeMismatch;
        }
    }
    try verifySingleElementDomain(inputs[1..]);
    return try arena.alloc(Type, 0);
}

fn verifySingleElementDomain(inputs: []const Type) InferError!void {
    var domain: ?u64 = null;
    for (inputs) |input| {
        const count = typeElementCount(input);
        if (count == 1) continue;
        if (domain) |existing| {
            if (count != existing) return error.ShapeMismatch;
        } else {
            domain = count;
        }
    }
}

fn typeElementCount(input: Type) u64 {
    var count: u64 = 1;
    for (input.dims) |dim| {
        if (dim <= 0) return 0;
        count *= @intCast(dim);
    }
    return count;
}

pub fn inferSelect(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    _ = attrs;
    if (inputs.len != 3) return error.ArityMismatch;
    const pred = inputs[0];
    const ot = inputs[1];
    const of = inputs[2];
    if (pred.dtype != .i1) return error.DTypeMismatch;
    if (ot.dtype != of.dtype) return error.DTypeMismatch;
    if (!std.mem.eql(i64, ot.dims, of.dims)) return error.ShapeMismatch;
    if (pred.dims.len != 0 and !std.mem.eql(i64, pred.dims, ot.dims)) {
        return error.ShapeMismatch;
    }
    return singletonType(arena, .{
        .dtype = ot.dtype,
        .dims = try duplicateDims(arena, ot.dims),
    });
}

pub fn inferKernelCall(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    const contract = try inferAttrKernelCall(attrs, 0);
    if (contract.target.len == 0) return error.InvalidKernelContract;
    if (contract.version == 0) return error.InvalidKernelContract;
    if (contract.results.len == 0) return error.InvalidKernelContract;
    if (contract.operand_effects.len != inputs.len) return error.InvalidKernelContract;
    if (contract.result_aliases.len != contract.results.len) return error.InvalidKernelContract;
    const aliased_operands = try arena.alloc(bool, inputs.len);
    @memset(aliased_operands, false);
    for (contract.result_aliases, 0..) |alias, result_index| {
        const operand_index = alias orelse continue;
        if (operand_index >= inputs.len) return error.InvalidKernelContract;
        if (aliased_operands[operand_index]) return error.InvalidKernelContract;
        aliased_operands[operand_index] = true;
        if (!contract.operand_effects[operand_index].writes()) return error.InvalidKernelContract;
        if (!contract.results[result_index].eql(inputs[operand_index])) {
            return error.InvalidKernelContract;
        }
    }
    return try duplicateTypes(arena, contract.results);
}

pub fn inferReturn(
    arena: Allocator,
    inputs: []const Type,
    attrs: []const Attribute,
) InferError![]const Type {
    _ = inputs;
    _ = attrs;
    return try arena.alloc(Type, 0);
}

const testArena = if (@import("builtin").is_test)
    struct {
        fn init(backing: std.mem.Allocator) std.heap.ArenaAllocator {
            return std.heap.ArenaAllocator.init(backing);
        }
    }.init
else {};

test "add infers result type from matching operands" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const dims = [_]i64{ 4, 8 };
    const t: Type = .{ .dtype = .f32, .dims = &dims };
    const out = try inferShape(.add, a.allocator(), &.{ t, t }, &.{});
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(out[0].eql(t));
}

test "add rejects dtype mismatch" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const dims = [_]i64{ 2, 3 };
    const t0: Type = .{ .dtype = .f32, .dims = &dims };
    const t1: Type = .{ .dtype = .i32, .dims = &dims };
    try testing.expectError(
        error.DTypeMismatch,
        inferShape(.add, a.allocator(), &.{ t0, t1 }, &.{}),
    );
}

test "add rejects shape mismatch" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const d0 = [_]i64{ 2, 3 };
    const d1 = [_]i64{ 2, 4 };
    const t0: Type = .{ .dtype = .f32, .dims = &d0 };
    const t1: Type = .{ .dtype = .f32, .dims = &d1 };
    try testing.expectError(
        error.ShapeMismatch,
        inferShape(.add, a.allocator(), &.{ t0, t1 }, &.{}),
    );
}

test "elementwise binary rejects wrong arity" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const d = [_]i64{3};
    const t: Type = .{ .dtype = .f32, .dims = &d };
    try testing.expectError(error.ArityMismatch, inferShape(.mul, a.allocator(), &.{t}, &.{}));
}

test "compare emits i1 with operand shape" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const dims = [_]i64{ 4, 8 };
    const t: Type = .{ .dtype = .f32, .dims = &dims };
    const attrs = [_]Attribute{.{ .compare_direction = .lt }};
    const out = try inferShape(.compare, a.allocator(), &.{ t, t }, &attrs);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(DType, .i1), out[0].dtype);
    try testing.expectEqualSlices(i64, &dims, out[0].dims);
}

test "compare requires a compare_direction attribute" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const dims = [_]i64{2};
    const t: Type = .{ .dtype = .f32, .dims = &dims };
    try testing.expectError(
        error.AttributeMissing,
        inferShape(.compare, a.allocator(), &.{ t, t }, &.{}),
    );
}

test "neg preserves type" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const dims = [_]i64{6};
    const t: Type = .{ .dtype = .f32, .dims = &dims };
    const out = try inferShape(.neg, a.allocator(), &.{t}, &.{});
    try testing.expect(out[0].eql(t));
}

test "activation preserves type and requires activation kind" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const dims = [_]i64{8};
    const t: Type = .{ .dtype = .f32, .dims = &dims };
    const attrs = [_]Attribute{.{ .activation_kind = .gelu }};
    const out = try inferShape(.activation, a.allocator(), &.{t}, &attrs);
    try testing.expect(out[0].eql(t));
    try testing.expectError(
        error.AttributeMissing,
        inferShape(.activation, a.allocator(), &.{t}, &.{}),
    );
}

test "convert changes dtype, keeps shape" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const dims = [_]i64{ 3, 4 };
    const t: Type = .{ .dtype = .i32, .dims = &dims };
    const attrs = [_]Attribute{.{ .dtype = .f32 }};
    const out = try inferShape(.convert, a.allocator(), &.{t}, &attrs);
    try testing.expectEqual(@as(DType, .f32), out[0].dtype);
    try testing.expectEqualSlices(i64, &dims, out[0].dims);
}

test "constant reads dtype + dims from attributes" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    var payload: [16]u8 = @splat(0);
    const dims = [_]i64{ 2, 2 };
    const attrs = [_]Attribute{
        .{ .bytes = &payload },
        .{ .dtype = .f32 },
        .{ .i64_list = &dims },
    };
    const out = try inferShape(.constant, a.allocator(), &.{}, &attrs);
    try testing.expectEqual(@as(DType, .f32), out[0].dtype);
    try testing.expectEqualSlices(i64, &dims, out[0].dims);
}

test "iota rejects out-of-range iota_dimension" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const dims = [_]i64{ 3, 4 };
    const attrs = [_]Attribute{
        .{ .i64 = 2 },
        .{ .dtype = .i32 },
        .{ .i64_list = &dims },
    };
    try testing.expectError(error.InvalidDimension, inferShape(.iota, a.allocator(), &.{}, &attrs));
}

test "parameter carries dtype + dims" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const dims = [_]i64{ 4, 8 };
    const attrs = [_]Attribute{
        .{ .i64 = 0 },
        .{ .dtype = .f32 },
        .{ .i64_list = &dims },
    };
    const out = try inferShape(.parameter, a.allocator(), &.{}, &attrs);
    try testing.expectEqualSlices(i64, &dims, out[0].dims);
}

test "reduce drops reduction dims" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const in_dims = [_]i64{ 2, 3, 4 };
    const init_dims = [_]i64{};
    const red_dims = [_]i64{1};
    const input: Type = .{ .dtype = .f32, .dims = &in_dims };
    const init_v: Type = .{ .dtype = .f32, .dims = &init_dims };
    const attrs = [_]Attribute{
        .{ .reducer_kind = .sum },
        .{ .i64_list = &red_dims },
    };
    const out = try inferShape(.reduce, a.allocator(), &.{ input, init_v }, &attrs);
    try testing.expectEqualSlices(i64, &[_]i64{ 2, 4 }, out[0].dims);
}

test "reduce rejects non-scalar init value" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const in_dims = [_]i64{ 2, 3 };
    const init_dims = [_]i64{1};
    const red_dims = [_]i64{0};
    const input: Type = .{ .dtype = .f32, .dims = &in_dims };
    const init_v: Type = .{ .dtype = .f32, .dims = &init_dims };
    const attrs = [_]Attribute{
        .{ .reducer_kind = .sum },
        .{ .i64_list = &red_dims },
    };
    try testing.expectError(
        error.RankMismatch,
        inferShape(.reduce, a.allocator(), &.{ input, init_v }, &attrs),
    );
}

test "dot_general matmul: [M,K] x [K,N] -> [M,N]" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const lhs_d = [_]i64{ 4, 8 };
    const rhs_d = [_]i64{ 8, 16 };
    const lhs: Type = .{ .dtype = .f32, .dims = &lhs_d };
    const rhs: Type = .{ .dtype = .f32, .dims = &rhs_d };
    const empty = [_]i64{};
    const lhs_c = [_]i64{1};
    const rhs_c = [_]i64{0};
    const attrs = [_]Attribute{
        .{ .i64_list = &empty },
        .{ .i64_list = &empty },
        .{ .i64_list = &lhs_c },
        .{ .i64_list = &rhs_c },
    };
    const out = try inferShape(.dot_general, a.allocator(), &.{ lhs, rhs }, &attrs);
    try testing.expectEqualSlices(i64, &[_]i64{ 4, 16 }, out[0].dims);
}

test "dot_general batched: [B,M,K] x [B,K,N] -> [B,M,N]" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const lhs_d = [_]i64{ 2, 3, 5 };
    const rhs_d = [_]i64{ 2, 5, 7 };
    const lhs: Type = .{ .dtype = .f32, .dims = &lhs_d };
    const rhs: Type = .{ .dtype = .f32, .dims = &rhs_d };
    const b_dims = [_]i64{0};
    const lhs_c = [_]i64{2};
    const rhs_c = [_]i64{1};
    const attrs = [_]Attribute{
        .{ .i64_list = &b_dims },
        .{ .i64_list = &b_dims },
        .{ .i64_list = &lhs_c },
        .{ .i64_list = &rhs_c },
    };
    const out = try inferShape(.dot_general, a.allocator(), &.{ lhs, rhs }, &attrs);
    try testing.expectEqualSlices(i64, &[_]i64{ 2, 3, 7 }, out[0].dims);
}

test "dot_general rejects mismatched contracting dims" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const lhs_d = [_]i64{ 4, 8 };
    const rhs_d = [_]i64{ 9, 16 };
    const lhs: Type = .{ .dtype = .f32, .dims = &lhs_d };
    const rhs: Type = .{ .dtype = .f32, .dims = &rhs_d };
    const empty = [_]i64{};
    const lhs_c = [_]i64{1};
    const rhs_c = [_]i64{0};
    const attrs = [_]Attribute{
        .{ .i64_list = &empty },
        .{ .i64_list = &empty },
        .{ .i64_list = &lhs_c },
        .{ .i64_list = &rhs_c },
    };
    try testing.expectError(
        error.ContractionMismatch,
        inferShape(.dot_general, a.allocator(), &.{ lhs, rhs }, &attrs),
    );
}

test "einsum infers matrix product output shape" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const lhs_d = [_]i64{ 4, 8 };
    const rhs_d = [_]i64{ 8, 16 };
    const lhs: Type = .{ .dtype = .f32, .dims = &lhs_d };
    const rhs: Type = .{ .dtype = .f32, .dims = &rhs_d };
    const attrs = [_]Attribute{.{ .einsum = "ik,kj->ij" }};
    const out = try inferShape(.einsum, a.allocator(), &.{ lhs, rhs }, &attrs);
    try testing.expectEqualSlices(i64, &[_]i64{ 4, 16 }, out[0].dims);
}

test "einsum infers scalar reduction output shape" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const dims = [_]i64{ 4, 8 };
    const typ: Type = .{ .dtype = .f32, .dims = &dims };
    const attrs = [_]Attribute{.{ .einsum = "ij->" }};
    const out = try inferShape(.einsum, a.allocator(), &.{typ}, &attrs);
    try testing.expectEqual(@as(usize, 0), out[0].dims.len);
}

test "einsum rejects inconsistent shared dimensions" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const lhs_d = [_]i64{ 4, 8 };
    const rhs_d = [_]i64{ 9, 16 };
    const lhs: Type = .{ .dtype = .f32, .dims = &lhs_d };
    const rhs: Type = .{ .dtype = .f32, .dims = &rhs_d };
    const attrs = [_]Attribute{.{ .einsum = "ik,kj->ij" }};
    try testing.expectError(
        error.InvalidEinsum,
        inferShape(.einsum, a.allocator(), &.{ lhs, rhs }, &attrs),
    );
}

test "broadcast prepends leading dims" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const in_d = [_]i64{ 3, 4 };
    const t: Type = .{ .dtype = .f32, .dims = &in_d };
    const sizes = [_]i64{2};
    const attrs = [_]Attribute{.{ .i64_list = &sizes }};
    const out = try inferShape(.broadcast, a.allocator(), &.{t}, &attrs);
    try testing.expectEqualSlices(i64, &[_]i64{ 2, 3, 4 }, out[0].dims);
}

test "broadcast_in_dim matches StableHLO 1x3 -> 2x3x2 example" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const in_d = [_]i64{ 1, 3 };
    const t: Type = .{ .dtype = .i32, .dims = &in_d };
    const bcast = [_]i64{ 2, 1 };
    const result = [_]i64{ 2, 3, 2 };
    const attrs = [_]Attribute{
        .{ .i64_list = &bcast },
        .{ .i64_list = &result },
    };
    const out = try inferShape(.broadcast_in_dim, a.allocator(), &.{t}, &attrs);
    try testing.expectEqualSlices(i64, &result, out[0].dims);
}

test "broadcast_in_dim rejects incompatible source dim" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const in_d = [_]i64{ 2, 3 };
    const t: Type = .{ .dtype = .i32, .dims = &in_d };
    const bcast = [_]i64{ 0, 1 };
    const result = [_]i64{ 4, 3 };
    const attrs = [_]Attribute{
        .{ .i64_list = &bcast },
        .{ .i64_list = &result },
    };
    try testing.expectError(
        error.ShapeMismatch,
        inferShape(.broadcast_in_dim, a.allocator(), &.{t}, &attrs),
    );
}

test "reshape changes rank, preserves element count" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const in_d = [_]i64{ 2, 3 };
    const t: Type = .{ .dtype = .i32, .dims = &in_d };
    const new = [_]i64{ 3, 2 };
    const attrs = [_]Attribute{.{ .i64_list = &new }};
    const out = try inferShape(.reshape, a.allocator(), &.{t}, &attrs);
    try testing.expectEqualSlices(i64, &new, out[0].dims);
}

test "reshape rejects element-count mismatch" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const in_d = [_]i64{ 2, 3 };
    const t: Type = .{ .dtype = .i32, .dims = &in_d };
    const new = [_]i64{ 4, 2 };
    const attrs = [_]Attribute{.{ .i64_list = &new }};
    try testing.expectError(
        error.ElementCountMismatch,
        inferShape(.reshape, a.allocator(), &.{t}, &attrs),
    );
}

test "transpose permutes dims" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const in_d = [_]i64{ 2, 3, 4 };
    const t: Type = .{ .dtype = .f32, .dims = &in_d };
    const perm = [_]i64{ 2, 0, 1 };
    const attrs = [_]Attribute{.{ .i64_list = &perm }};
    const out = try inferShape(.transpose, a.allocator(), &.{t}, &attrs);
    try testing.expectEqualSlices(i64, &[_]i64{ 4, 2, 3 }, out[0].dims);
}

test "transpose rejects non-permutation" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const in_d = [_]i64{ 2, 3, 4 };
    const t: Type = .{ .dtype = .f32, .dims = &in_d };
    const perm = [_]i64{ 0, 0, 1 };
    const attrs = [_]Attribute{.{ .i64_list = &perm }};
    try testing.expectError(
        error.InvalidPermutation,
        inferShape(.transpose, a.allocator(), &.{t}, &attrs),
    );
}

test "slice computes ceil((limit - start) / stride)" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const in_d = [_]i64{ 10, 10 };
    const t: Type = .{ .dtype = .i32, .dims = &in_d };
    const start = [_]i64{ 1, 2 };
    const limit = [_]i64{ 9, 8 };
    const stride = [_]i64{ 2, 3 };
    const attrs = [_]Attribute{
        .{ .i64_list = &start },
        .{ .i64_list = &limit },
        .{ .i64_list = &stride },
    };
    const out = try inferShape(.slice, a.allocator(), &.{t}, &attrs);
    try testing.expectEqualSlices(i64, &[_]i64{ 4, 2 }, out[0].dims);
}

test "gather inserts index shape at the selected axis" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const operand_dims = [_]i64{ 2, 3, 4 };
    const index_dims = [_]i64{ 5, 6 };
    const operand: Type = .{ .dtype = .f32, .dims = &operand_dims };
    const indices: Type = .{ .dtype = .i32, .dims = &index_dims };
    const attrs = [_]Attribute{.{ .i64 = 1 }};
    const out = try inferShape(.gather, a.allocator(), &.{ operand, indices }, &attrs);
    try testing.expectEqualSlices(i64, &[_]i64{ 2, 5, 6, 4 }, out[0].dims);
}

test "gather rejects invalid axis and non-integer indices" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const operand_dims = [_]i64{ 2, 3 };
    const index_dims = [_]i64{4};
    const operand: Type = .{ .dtype = .f32, .dims = &operand_dims };
    const indices: Type = .{ .dtype = .i32, .dims = &index_dims };
    const bad_indices: Type = .{ .dtype = .f32, .dims = &index_dims };
    try testing.expectError(
        error.InvalidDimension,
        inferShape(.gather, a.allocator(), &.{ operand, indices }, &.{.{ .i64 = 2 }}),
    );
    try testing.expectError(
        error.DTypeMismatch,
        inferShape(.gather, a.allocator(), &.{ operand, bad_indices }, &.{.{ .i64 = 0 }}),
    );
}

test "scatter returns operand shape and checks update shape" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const operand_dims = [_]i64{ 2, 3, 4 };
    const index_dims = [_]i64{ 5, 6 };
    const update_dims = [_]i64{ 2, 5, 6, 4 };
    const bad_update_dims = [_]i64{ 2, 5, 4 };
    const operand: Type = .{ .dtype = .f32, .dims = &operand_dims };
    const indices: Type = .{ .dtype = .i32, .dims = &index_dims };
    const updates: Type = .{ .dtype = .f32, .dims = &update_dims };
    const bad_updates: Type = .{ .dtype = .f32, .dims = &bad_update_dims };
    const attrs = [_]Attribute{.{ .i64 = 1 }};
    const out = try inferShape(.scatter, a.allocator(), &.{ operand, indices, updates }, &attrs);
    try testing.expectEqualSlices(i64, &operand_dims, out[0].dims);
    try testing.expectError(
        error.RankMismatch,
        inferShape(.scatter, a.allocator(), &.{ operand, indices, bad_updates }, &attrs),
    );
}

test "scatter rejects invalid axis and non-integer indices" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const operand_dims = [_]i64{ 2, 3 };
    const index_dims = [_]i64{4};
    const update_dims = [_]i64{ 4, 3 };
    const operand: Type = .{ .dtype = .i32, .dims = &operand_dims };
    const indices: Type = .{ .dtype = .i32, .dims = &index_dims };
    const bad_indices: Type = .{ .dtype = .f32, .dims = &index_dims };
    const updates: Type = .{ .dtype = .i32, .dims = &update_dims };
    try testing.expectError(
        error.InvalidDimension,
        inferShape(.scatter, a.allocator(), &.{ operand, indices, updates }, &.{.{ .i64 = 2 }}),
    );
    try testing.expectError(
        error.DTypeMismatch,
        inferShape(.scatter, a.allocator(), &.{ operand, bad_indices, updates }, &.{.{ .i64 = 0 }}),
    );
}

test "pad infers positive edge and interior padding" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const in_d = [_]i64{ 2, 3 };
    const scalar_d = [_]i64{};
    const input: Type = .{ .dtype = .i32, .dims = &in_d };
    const padding_value: Type = .{ .dtype = .i32, .dims = &scalar_d };
    const low = [_]i64{ 1, 0 };
    const high = [_]i64{ 0, 2 };
    const interior = [_]i64{ 0, 1 };
    const attrs = [_]Attribute{
        .{ .i64_list = &low },
        .{ .i64_list = &high },
        .{ .i64_list = &interior },
    };
    const out = try inferShape(.pad, a.allocator(), &.{ input, padding_value }, &attrs);
    try testing.expectEqualSlices(i64, &[_]i64{ 3, 7 }, out[0].dims);
}

test "pad allows negative edge padding when result shape remains valid" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const in_d = [_]i64{4};
    const scalar_d = [_]i64{};
    const input: Type = .{ .dtype = .f32, .dims = &in_d };
    const padding_value: Type = .{ .dtype = .f32, .dims = &scalar_d };
    const low = [_]i64{-1};
    const high = [_]i64{2};
    const interior = [_]i64{0};
    const attrs = [_]Attribute{
        .{ .i64_list = &low },
        .{ .i64_list = &high },
        .{ .i64_list = &interior },
    };
    const out = try inferShape(.pad, a.allocator(), &.{ input, padding_value }, &attrs);
    try testing.expectEqualSlices(i64, &[_]i64{5}, out[0].dims);
}

test "pad rejects non-scalar padding value and invalid interior padding" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const in_d = [_]i64{ 2, 3 };
    const scalar_d = [_]i64{};
    const vector_d = [_]i64{1};
    const input: Type = .{ .dtype = .i32, .dims = &in_d };
    const scalar_padding: Type = .{ .dtype = .i32, .dims = &scalar_d };
    const vector_padding: Type = .{ .dtype = .i32, .dims = &vector_d };
    const low = [_]i64{ 0, 0 };
    const high = [_]i64{ 0, 0 };
    const interior = [_]i64{ 0, -1 };
    const attrs = [_]Attribute{
        .{ .i64_list = &low },
        .{ .i64_list = &high },
        .{ .i64_list = &low },
    };
    try testing.expectError(
        error.RankMismatch,
        inferShape(.pad, a.allocator(), &.{ input, vector_padding }, &attrs),
    );

    const bad_attrs = [_]Attribute{
        .{ .i64_list = &low },
        .{ .i64_list = &high },
        .{ .i64_list = &interior },
    };
    try testing.expectError(
        error.InvalidDimension,
        inferShape(.pad, a.allocator(), &.{ input, scalar_padding }, &bad_attrs),
    );
}

test "concatenate sums along the concat dim" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const d0 = [_]i64{ 3, 2 };
    const d1 = [_]i64{ 1, 2 };
    const t0: Type = .{ .dtype = .i64, .dims = &d0 };
    const t1: Type = .{ .dtype = .i64, .dims = &d1 };
    const attrs = [_]Attribute{.{ .i64 = 0 }};
    const out = try inferShape(.concatenate, a.allocator(), &.{ t0, t1 }, &attrs);
    try testing.expectEqualSlices(i64, &[_]i64{ 4, 2 }, out[0].dims);
}

test "concatenate rejects non-concat-dim mismatch" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const d0 = [_]i64{ 3, 2 };
    const d1 = [_]i64{ 1, 3 };
    const t0: Type = .{ .dtype = .i64, .dims = &d0 };
    const t1: Type = .{ .dtype = .i64, .dims = &d1 };
    const attrs = [_]Attribute{.{ .i64 = 0 }};
    try testing.expectError(
        error.DimMismatch,
        inferShape(.concatenate, a.allocator(), &.{ t0, t1 }, &attrs),
    );
}

test "select requires i1 predicate and matching branches" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const d = [_]i64{ 2, 2 };
    const pred: Type = .{ .dtype = .i1, .dims = &d };
    const on_true: Type = .{ .dtype = .i32, .dims = &d };
    const on_false: Type = .{ .dtype = .i32, .dims = &d };
    const out = try inferShape(.select, a.allocator(), &.{ pred, on_true, on_false }, &.{});
    try testing.expect(out[0].eql(on_true));

    const bad_pred: Type = .{ .dtype = .i32, .dims = &d };
    try testing.expectError(
        error.DTypeMismatch,
        inferShape(.select, a.allocator(), &.{ bad_pred, on_true, on_false }, &.{}),
    );
}

test "kernel_call returns explicit contract result types" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const input_dims = [_]i64{ 4, 8 };
    const result_dims = [_]i64{ 4, 8 };
    const input: Type = .{ .dtype = .f32, .dims = &input_dims };
    const result: Type = .{ .dtype = .f32, .dims = &result_dims };
    const contract = KernelCallContract{
        .target = "scale_f32",
        .version = 1,
        .has_side_effects = false,
        .operand_effects = &.{.none},
        .result_aliases = &.{null},
        .results = &.{result},
    };
    const out = try inferShape(
        .kernel_call,
        a.allocator(),
        &.{input},
        &.{.{ .kernel_call = contract }},
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(out[0].eql(result));
}

test "kernel_call accepts explicit result aliases for writable operands" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const dims = [_]i64{4};
    const input: Type = .{ .dtype = .f32, .dims = &dims };
    const contract = KernelCallContract{
        .target = "update_f32",
        .version = 1,
        .has_side_effects = false,
        .operand_effects = &.{.read_write},
        .result_aliases = &.{0},
        .results = &.{input},
    };
    const out = try inferShape(
        .kernel_call,
        a.allocator(),
        &.{input},
        &.{.{ .kernel_call = contract }},
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expect(out[0].eql(input));
}

test "kernel_call rejects malformed contracts" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const dims = [_]i64{4};
    const input: Type = .{ .dtype = .f32, .dims = &dims };
    const result: Type = .{ .dtype = .f32, .dims = &dims };
    try testing.expectError(
        error.InvalidKernelContract,
        inferShape(.kernel_call, a.allocator(), &.{}, &.{.{ .kernel_call = .{
            .target = "",
            .version = 1,
            .has_side_effects = false,
            .operand_effects = &.{},
            .result_aliases = &.{null},
            .results = &.{result},
        } }}),
    );
    try testing.expectError(
        error.InvalidKernelContract,
        inferShape(.kernel_call, a.allocator(), &.{}, &.{.{ .kernel_call = .{
            .target = "scale_f32",
            .version = 0,
            .has_side_effects = false,
            .operand_effects = &.{},
            .result_aliases = &.{null},
            .results = &.{result},
        } }}),
    );
    try testing.expectError(
        error.InvalidKernelContract,
        inferShape(.kernel_call, a.allocator(), &.{input}, &.{.{ .kernel_call = .{
            .target = "scale_f32",
            .version = 1,
            .has_side_effects = false,
            .operand_effects = &.{},
            .result_aliases = &.{null},
            .results = &.{result},
        } }}),
    );
    try testing.expectError(
        error.InvalidKernelContract,
        inferShape(.kernel_call, a.allocator(), &.{input}, &.{.{ .kernel_call = .{
            .target = "update_f32",
            .version = 1,
            .has_side_effects = false,
            .operand_effects = &.{.read},
            .result_aliases = &.{0},
            .results = &.{result},
        } }}),
    );
    try testing.expectError(
        error.InvalidKernelContract,
        inferShape(.kernel_call, a.allocator(), &.{input}, &.{.{ .kernel_call = .{
            .target = "update_f32",
            .version = 1,
            .has_side_effects = false,
            .operand_effects = &.{.read_write},
            .result_aliases = &.{ 0, 0 },
            .results = &.{ result, result },
        } }}),
    );
}

test "return has zero outputs" {
    var a = testArena(testing.allocator);
    defer a.deinit();
    const d = [_]i64{3};
    const t: Type = .{ .dtype = .f32, .dims = &d };
    const out = try inferShape(.@"return", a.allocator(), &.{t}, &.{});
    try testing.expectEqual(@as(usize, 0), out.len);
}
