//! The f64 functions a module imports from its host's `math` module, under the names `sys.math`
//! and the native `Runtime.Math` give them. A caller opts in with `Backend.importMath` and
//! promises to bind each to the same correctly rounded routines as native. Without it these
//! operations stay refused, as wasm has no library to fall back to.

const std = @import("std");
const ir = @import("../../../core/root.zig");
const dialects = @import("../../../dialects/root.zig");
const emission = @import("root.zig");

const Arith = dialects.ArithDialect;

pub const module_name = "math";

pub const Function = enum(u3) { exp, log, log1p, expm1, sin, cos };

/// The functions a module uses, each imported once in this order.
pub const Set = struct {
    bits: u6 = 0,

    pub fn add(self: *Set, function: Function) void {
        self.bits |= bit(function);
    }

    pub fn count(self: Set) u32 {
        return @popCount(self.bits);
    }

    /// The import's position among the set's imports, or null when the set lacks it.
    pub fn rank(self: Set, function: Function) ?u32 {
        if (self.bits & bit(function) == 0) return null;
        return @popCount(self.bits & (bit(function) - 1));
    }

    fn bit(function: Function) u6 {
        return @as(u6, 1) << @backingInt(function);
    }
};

/// The import `operation` calls: one of the six at f64. Any other width is left to the
/// writer, which refuses it as before.
pub fn classify(operation: *const ir.Operation) ?Function {
    const name = operation.name.name;
    const function: Function = inline for (.{
        .{ Arith.ExpOp, .exp },     .{ Arith.LogOp, .log },
        .{ Arith.Log1pOp, .log1p }, .{ Arith.Expm1Op, .expm1 },
        .{ Arith.SinOp, .sin },     .{ Arith.CosOp, .cos },
    }) |entry| {
        if (std.mem.eql(u8, name, entry[0].operation_name)) break entry[1];
    } else return null;
    if (operation.results.items.len != 1) return null;
    const kind = emission.types.scalarKindForType(operation.results.items[0].type) orelse return null;
    return if (kind == .f64) function else null;
}
