//! The workgroup shape of a compute kernel.
//!
//! A kernel declares its shape in a `workgroup_size` attribute beside
//! `kernel`, written `XxYxZ`, as `#attr<gpu.workgroup_size>("8x8x1")`. A
//! kernel without one has the unit shape. The shape is the size a host runs
//! when it creates the pipeline without choosing another: the SPIR-V emitter
//! writes it as `LocalSize` and as the defaults of the specialization
//! constants that size the workgroup, so a host that specializes them runs
//! its own size instead. A shape is a declaration, not a device fact, so no
//! device limit is checked here.

const std = @import("std");
const ir = @import("../../core/root.zig");
const dialects = @import("../root.zig");
const tags = @import("tags.zig");

/// Invocations along x, y and z.
pub const Shape = [3]u32;
/// The shape of a kernel that declares none.
pub const unit_shape: Shape = .{ 1, 1, 1 };
/// The function attribute that holds a shape.
pub const shape_attr_key = "workgroup_size";
/// Bytes of the longest payload: three u32s in decimal and two separators.
pub const max_payload_bytes = 3 * 10 + 2;

pub const ShapeError = error{InvalidWorkgroupShape};

pub fn getShapeAttr(ctx: *ir.Context, shape: Shape) !ir.Attribute {
    var buffer: [max_payload_bytes]u8 = undefined;
    return ctx.getDialectAttr(tags.attr_names.workgroup_size, payload(&buffer, shape));
}

/// Declares `shape` for the kernel `func_op`. Every dimension is at least 1.
pub fn setShape(func_op: *ir.Operation, ctx: *ir.Context, shape: Shape) !void {
    std.debug.assert(func_op.getAttr("kernel") != null);
    for (shape) |extent| std.debug.assert(extent >= 1);
    try func_op.setAttr(shape_attr_key, try getShapeAttr(ctx, shape));
}

/// The shape `func_op` declares, or null when it declares none. A payload
/// that is not three positive decimal extents refuses.
pub fn shapeOf(func_op: *const ir.Operation) ShapeError!?Shape {
    const attr = func_op.getAttrAs(ir.Attribute.DialectAttr, shape_attr_key) orelse return null;
    return parse(attr.payload) orelse error.InvalidWorkgroupShape;
}

fn payload(buffer: *[max_payload_bytes]u8, shape: Shape) []const u8 {
    const extents = .{ shape[0], shape[1], shape[2] };
    return std.fmt.bufPrint(buffer, "{d}x{d}x{d}", extents) catch unreachable;
}

fn parse(text: []const u8) ?Shape {
    var shape: Shape = undefined;
    var parts = std.mem.splitScalar(u8, text, 'x');
    for (&shape) |*extent| {
        const part = parts.next() orelse return null;
        if (part.len == 0 or part[0] == '+') return null;
        extent.* = std.fmt.parseInt(u32, part, 10) catch return null;
        if (extent.* == 0) return null;
    }
    if (parts.next() != null) return null;
    return shape;
}

const FuncOp = dialects.func.FuncDialect.FuncOp;
