const std = @import("std");
const ir = @import("../../core/root.zig");
const dialects = @import("../../dialects/root.zig");
const scf = dialects.ScfDialect;

pub const max_depth: usize = 32;
pub const max_carried_values: usize = 16;
pub const max_transfers: usize = max_carried_values + 1;
pub const Kind = enum { conditional, counted, repeated };
pub const Error = error{ ControlShape, ControlType, CarriedCapacity, DepthCapacity };

pub fn kind(op: *const ir.Operation) ?Kind {
    if (is(op, scf.IfOp.operation_name)) return .conditional;
    if (is(op, scf.ForOp.operation_name)) return .counted;
    if (is(op, scf.WhileOp.operation_name)) return .repeated;
    return null;
}

pub fn scalar(typ: ir.Type) bool {
    const name = typ.getDialectTypeName() orelse return false;
    const scalar_kind = dialects.arith.scalarKindFromTypeName(name) orelse return false;
    return switch (scalar_kind) {
        .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .index, .bool, .f32, .f64 => true,
        else => false,
    };
}

fn named(typ: ir.Type, name: []const u8) bool {
    return std.mem.eql(u8, typ.getDialectTypeName() orelse "", name);
}

/// Admission establishes all region/edge shapes before placement or emission.
pub fn validate(op: *ir.Operation, construct: Kind) Error!void {
    const count = op.results.items.len;
    if (count > max_carried_values) return error.CarriedCapacity;
    for (op.results.items) |result| if (!scalar(result.type)) return error.ControlType;
    const regions = op.regions.items;
    const expected_regions: usize = if (construct == .counted) 1 else 2;
    if (regions.len != expected_regions) {
        if (!(construct == .conditional and count == 0 and regions.len == 1)) return error.ControlShape;
    }
    for (regions) |*region| {
        if (region.blocks.size != 1) return error.ControlShape;
        const block = region.getEntryBlock() orelse return error.ControlShape;
        if (block.operations.tail == null) return error.ControlShape;
        for (block.arguments.items) |arg| if (!scalar(arg.type)) return error.ControlType;
    }
    switch (construct) {
        .conditional => {
            if (op.operands.items.len != 1) return error.ControlShape;
            if (!named(op.operands.items[0].value.type, "arith.bool")) return error.ControlType;
            for (regions) |*region| {
                const block = region.getEntryBlock().?;
                if (block.arguments.items.len != 0) return error.ControlShape;
                try yieldTypes(last(block), op.results.items);
            }
        },
        .counted => {
            if (op.operands.items.len != count + 3) return error.ControlShape;
            for (op.operands.items[0..3]) |operand| if (!named(operand.value.type, "arith.index")) return error.ControlType;
            const block = regions[0].getEntryBlock().?;
            if (block.arguments.items.len != count + 1) return error.ControlShape;
            if (!named(block.arguments.items[0].type, "arith.index")) return error.ControlType;
            for (op.results.items, op.operands.items[3..], block.arguments.items[1..]) |result, init, arg| {
                if (!result.type.eql(init.value.type) or !result.type.eql(arg.type)) return error.ControlType;
            }
            try yieldTypes(last(block), op.results.items);
        },
        .repeated => {
            if (op.operands.items.len != count) return error.ControlShape;
            for (regions) |*region| if (region.getEntryBlock().?.arguments.items.len != count) return error.ControlShape;
            const before = regions[0].getEntryBlock().?;
            const after = regions[1].getEntryBlock().?;
            for (op.results.items, op.operands.items, before.arguments.items, after.arguments.items) |result, init, lhs, rhs| {
                if (!result.type.eql(init.value.type) or !result.type.eql(lhs.type) or !result.type.eql(rhs.type)) return error.ControlType;
            }
            const condition = last(before);
            if (!is(condition, scf.ConditionOp.operation_name) or condition.operands.items.len != count + 1) return error.ControlShape;
            if (!named(condition.operands.items[0].value.type, "arith.bool")) return error.ControlType;
            for (op.results.items, condition.operands.items[1..]) |result, forwarded| if (!result.type.eql(forwarded.value.type)) return error.ControlType;
            try yieldTypes(last(after), op.results.items);
        },
    }
}

fn yieldTypes(op: *ir.Operation, results: []const ir.Value) Error!void {
    if (!is(op, scf.YieldOp.operation_name) or op.operands.items.len != results.len) return error.ControlShape;
    for (results, op.operands.items) |result, yielded| if (!result.type.eql(yielded.value.type)) return error.ControlType;
}

/// Compare an operation's registered spelling without requiring registration.
pub fn is(op: *const ir.Operation, name: []const u8) bool {
    return std.mem.eql(u8, op.name.name, name);
}

pub fn last(block: *ir.Block) *ir.Operation {
    return @ptrCast(@alignCast(block.operations.tail.?));
}
