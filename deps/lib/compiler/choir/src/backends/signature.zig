//! Boundary signatures of IR function definitions and of Zig function pointer types.

const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../core/root.zig");
const dialects = @import("../dialects/root.zig");
const artifact = @import("artifact/root.zig");

const Signature = artifact.Signature;
const ScalarType = artifact.ScalarType;
const ValueType = artifact.ValueType;

pub const Error = error{ TooManyParameters, TooManyResults, UnsupportedType };

/// Records the parameter and result types of the function definition `func`.
/// Fails with `error.TooManyParameters` or `error.TooManyResults` when `func` has more parameters
/// or results than a `Signature` records, and with `error.UnsupportedType` when a type has no
/// boundary equivalent, such as `arith.f16`.
pub fn ofFunction(func: *ir.Operation) Error!Signature {
    std.debug.assert(std.mem.eql(u8, func.name.name, dialects.FuncDialect.FuncOp.operation_name));
    const arguments = func.getRegion(0).?.getEntryBlock().?.arguments.items;
    const results = func.results.items;
    if (arguments.len > Signature.max_parameters) return error.TooManyParameters;
    if (results.len > Signature.max_results) return error.TooManyResults;
    var parameter_types: [Signature.max_parameters]ValueType = undefined;
    for (arguments, parameter_types[0..arguments.len]) |argument, *value_type| {
        value_type.* = try valueTypeOf(argument.type);
    }
    var result_types: [Signature.max_results]ValueType = undefined;
    for (results, result_types[0..results.len]) |result, *value_type| {
        value_type.* = try valueTypeOf(result.type);
    }
    const signature = Signature.init(
        parameter_types[0..arguments.len],
        result_types[0..results.len],
    ) catch unreachable;
    std.debug.assert(signature.parameters().len == arguments.len);
    std.debug.assert(signature.results().len == results.len);
    return signature;
}

/// Maps the IR type `ty` to its boundary type.
/// Fails with `error.UnsupportedType` when `ty` has none.
pub fn valueTypeOf(ty: ir.Type) error{UnsupportedType}!ValueType {
    const name = ty.getDialectTypeName() orelse return error.UnsupportedType;
    if (std.mem.eql(u8, name, dialects.MemrefDialect.name)) return .memref;
    if (dialects.arith.parseVectorTypeName(name)) |vector| {
        const kind = dialects.arith.scalarKindFromTypeName(vector.elem_type_name).?;
        const lanes = std.math.cast(u8, vector.width) orelse return error.UnsupportedType;
        const element = try scalarOf(kind);
        const value_type = ValueType{ .vector = .{ .element = element, .lanes = lanes } };
        if (!value_type.isValid()) return error.UnsupportedType;
        return value_type;
    }
    const kind = dialects.arith.scalarKindFromTypeName(name) orelse return error.UnsupportedType;
    return .{ .scalar = try scalarOf(kind) };
}

fn scalarOf(kind: dialects.arith.ScalarKind) error{UnsupportedType}!ScalarType {
    return switch (kind) {
        .f16, .bf16 => error.UnsupportedType,
        inline else => |tag| @field(ScalarType, @tagName(tag)),
    };
}

/// Derives the signature of the C calling-convention function that `FunctionPointer` points to.
/// Each parameter, and a result other than `void` or a struct, maps to one boundary type.
/// `i8`, `i16`, `i32`, `i64`, and their unsigned forms map to the arith integer of the same name.
/// `usize` maps to `arith.index`. `bool`, `f32`, and `f64` map to the arith type of the same name.
/// A pointer that is not a slice, optional or not, maps to `memref`.
/// A `void` result maps to no results.
/// An extern struct result of `n` fields maps to `n` results. Field `i` starts at byte `8 * i`,
/// and the struct spans `8 * n` bytes.
/// Any other type, `isize` included, is a compile error.
pub fn ofZigFunction(comptime FunctionPointer: type) Signature {
    return comptime derive(FunctionPointer);
}

fn derive(comptime FunctionPointer: type) Signature {
    const name = @typeName(FunctionPointer);
    const function = switch (@typeInfo(FunctionPointer)) {
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |function| function,
            else => @compileError(name ++ " does not point to a function"),
        },
        else => @compileError(name ++ " is not a function pointer"),
    };
    if (!function.attrs.@"callconv".eql(.c)) @compileError(name ++ " is not callconv(.c)");
    if (function.attrs.varargs) @compileError(name ++ " is variadic");
    if (function.is_generic) @compileError(name ++ " is generic");
    var parameter_types: [function.param_types.len]ValueType = undefined;
    for (function.param_types, &parameter_types) |parameter_type, *value_type| {
        value_type.* = zigValueType(parameter_type.?);
    }
    const Return = function.return_type.?;
    const result_types: []const ValueType = switch (@typeInfo(Return)) {
        .void => &.{},
        .@"struct" => &zigProductTypes(Return),
        else => &.{zigValueType(Return)},
    };
    return Signature.init(&parameter_types, result_types) catch |err| {
        @compileError(name ++ ": " ++ @errorName(err));
    };
}

fn zigValueType(comptime T: type) ValueType {
    const missing = @typeName(T) ++ " has no boundary type";
    if (T == usize) return .{ .scalar = .index };
    if (T == isize) @compileError(missing ++ "; use i64");
    return switch (@typeInfo(T)) {
        .bool => .{ .scalar = .bool },
        .int => |int| .{ .scalar = switch (int.bits) {
            8 => if (int.signedness == .signed) .i8 else .u8,
            16 => if (int.signedness == .signed) .i16 else .u16,
            32 => if (int.signedness == .signed) .i32 else .u32,
            64 => if (int.signedness == .signed) .i64 else .u64,
            else => @compileError(missing),
        } },
        .float => |float| .{ .scalar = switch (float.bits) {
            32 => .f32,
            64 => .f64,
            else => @compileError(missing),
        } },
        .pointer => |pointer| if (pointer.size == .slice) @compileError(missing) else .memref,
        .optional => |optional| switch (@typeInfo(optional.child)) {
            .pointer => |pointer| if (pointer.size == .slice) @compileError(missing) else .memref,
            else => @compileError(missing),
        },
        else => @compileError(missing),
    };
}

fn zigProductTypes(
    comptime Product: type,
) [@typeInfo(Product).@"struct".field_names.len]ValueType {
    if (comptime productLayoutError(Product)) |message| @compileError(message);
    const product = @typeInfo(Product).@"struct";
    var types: [product.field_names.len]ValueType = undefined;
    inline for (product.field_types, &types) |Field, *slot| slot.* = zigValueType(Field);
    return types;
}

fn productLayoutError(comptime Product: type) ?[]const u8 {
    const product = @typeInfo(Product).@"struct";
    const name = @typeName(Product);
    if (product.layout != .@"extern") return name ++ " is not extern";
    inline for (product.field_names, 0..) |field, index| {
        const offset = @offsetOf(Product, field);
        if (offset != 8 * index) return std.fmt.comptimePrint(
            "{s}.{s} starts at byte {d}, not {d}",
            .{ name, field, offset, 8 * index },
        );
    }
    const size = 8 * product.field_names.len;
    if (@sizeOf(Product) == size) return null;
    return std.fmt.comptimePrint("{s} spans {d} bytes, not {d}", .{ name, @sizeOf(Product), size });
}

const SampleProduct = extern struct {
    sum: i64,
    scale: f64,
    narrow: i32 align(8),
    below: bool align(8),
};

const OverAlignedProduct = extern struct {
    value: i64 align(32),
};
