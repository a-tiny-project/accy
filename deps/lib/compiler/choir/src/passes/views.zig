const std = @import("std");
const ir = @import("../core/root.zig");
const dialects = @import("../dialects/root.zig");

const ArithDialect = dialects.arith.ArithDialect;
const MemrefDialect = dialects.memref.MemrefDialect;
const ScfDialect = dialects.scf.ScfDialect;

pub const LegalizeError = anyerror;

const ViewInfo = struct {
    source: *ir.Value,
    offset: u64,
    shape: []u64,
    stride: []u64,
};

const Insertion = struct {
    block: *ir.Block,
    before: ?*ir.Operation,

    fn insert(self: Insertion, op: *ir.Operation) !void {
        if (self.before) |before| {
            try self.block.insertBefore(op, before);
        } else {
            try self.block.addOperation(op);
        }
    }
};

const ResolvedIndex = struct {
    base: *ir.Value,
    index: *ir.Value,
};

pub fn legalizeMemrefViews(module: *ir.Operation, allocator: std.mem.Allocator) LegalizeError!void {
    const ctx = module.context;
    var legalizer = MemrefViewLegalizer.init(allocator, ctx);
    defer legalizer.deinit();
    try legalizer.run(module);
}

const MemrefViewLegalizer = struct {
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    view_map: std.AutoHashMap(*ir.Value, ViewInfo),

    const HandleResult = enum { kept, removed };

    fn init(allocator: std.mem.Allocator, ctx: *ir.Context) MemrefViewLegalizer {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .view_map = std.AutoHashMap(*ir.Value, ViewInfo).init(allocator),
        };
    }

    fn deinit(self: *MemrefViewLegalizer) void {
        var iter = self.view_map.valueIterator();
        while (iter.next()) |info| {
            self.allocator.free(info.shape);
            self.allocator.free(info.stride);
        }
        self.view_map.deinit();
    }

    fn run(self: *MemrefViewLegalizer, module: *ir.Operation) LegalizeError!void {
        try self.walkOp(module);
        try self.cleanupViews();
    }

    fn walkOp(self: *MemrefViewLegalizer, op: *ir.Operation) LegalizeError!void {
        const handled = try self.handleOp(op);
        if (handled == .removed) return;

        for (op.regions.items) |*region| {
            var block_iter = region.getBlocks();
            while (block_iter.next()) |block| {
                var current: ?*ir.Operation = @ptrCast(@alignCast(block.operations.head));
                while (current) |op_ptr| {
                    const next = op_ptr.next_op;
                    try self.walkOp(op_ptr);
                    current = next;
                }
            }
        }
    }

    fn handleOp(self: *MemrefViewLegalizer, op: *ir.Operation) LegalizeError!HandleResult {
        const name = op.name.name;
        if (std.mem.eql(u8, name, MemrefDialect.LoadOp.operation_name)) {
            try self.rewriteLoad(op);
            return .kept;
        }
        if (std.mem.eql(u8, name, MemrefDialect.StoreOp.operation_name)) {
            try self.rewriteStore(op);
            return .kept;
        }
        if (std.mem.eql(u8, name, MemrefDialect.CopyOp.operation_name)) {
            if (try self.rewriteCopy(op)) {
                return .removed;
            }
            return .kept;
        }
        if (std.mem.eql(u8, name, MemrefDialect.DeallocOp.operation_name)) {
            try self.rewriteDealloc(op);
            return .kept;
        }
        if (std.mem.eql(u8, name, MemrefDialect.SubviewOp.operation_name) or
            std.mem.eql(u8, name, MemrefDialect.TransposeOp.operation_name))
        {
            _ = try self.getViewInfo(op.getResult(0).?);
            return .kept;
        }

        if (try self.opUsesView(op)) {
            return error.UnsupportedViewUse;
        }

        return .kept;
    }

    fn opUsesView(self: *MemrefViewLegalizer, op: *ir.Operation) LegalizeError!bool {
        for (op.operands.items) |operand| {
            if (try self.getViewInfo(operand.value) != null) {
                return true;
            }
        }
        return false;
    }

    fn rewriteLoad(self: *MemrefViewLegalizer, op: *ir.Operation) LegalizeError!void {
        const load = MemrefDialect.LoadOp{ .op = op };
        const memref_val = load.getMemref();
        const index_val = load.getIndex();
        if (try self.getViewInfo(memref_val) == null) return;

        const block = op.getBlock() orelse return error.MissingBlock;
        const insertion = Insertion{ .block = block, .before = op };
        const resolved = try self.resolveViewIndex(insertion, op.getLoc(), memref_val, index_val);

        op.setOperandValue(0, resolved.base);
        op.setOperandValue(1, resolved.index);
    }

    fn rewriteStore(self: *MemrefViewLegalizer, op: *ir.Operation) LegalizeError!void {
        const store = MemrefDialect.StoreOp{ .op = op };
        const memref_val = store.getMemref();
        const index_val = store.getIndex();
        if (try self.getViewInfo(memref_val) == null) return;

        const block = op.getBlock() orelse return error.MissingBlock;
        const insertion = Insertion{ .block = block, .before = op };
        const resolved = try self.resolveViewIndex(insertion, op.getLoc(), memref_val, index_val);

        op.setOperandValue(1, resolved.base);
        op.setOperandValue(2, resolved.index);
    }

    fn rewriteDealloc(self: *MemrefViewLegalizer, op: *ir.Operation) LegalizeError!void {
        const dealloc = MemrefDialect.DeallocOp{ .op = op };
        const memref_val = dealloc.getMemref();
        if (try self.getViewInfo(memref_val) == null) return;
        const base = try self.resolveBaseMemref(memref_val);
        op.setOperandValue(0, base);
    }

    fn rewriteCopy(self: *MemrefViewLegalizer, op: *ir.Operation) LegalizeError!bool {
        const copy = MemrefDialect.CopyOp{ .op = op };
        const src = copy.getSrc();
        const dst = copy.getDst();
        const src_view = try self.getViewInfo(src);
        const dst_view = try self.getViewInfo(dst);
        if (src_view == null and dst_view == null) return false;

        const block = op.getBlock() orelse return error.MissingBlock;
        const loc = op.getLoc();
        const len = try self.getCopyLength(op, src, dst);

        const index_type = ArithDialect.getIndexType(self.ctx) catch return error.InvalidLayout;

        const insertion = Insertion{ .block = block, .before = op };
        const zero = try self.emitConstIndex(insertion, loc, index_type, 0);
        const len_val = try self.emitConstIndex(insertion, loc, index_type, len);
        const one = try self.emitConstIndex(insertion, loc, index_type, 1);

        var for_op = try ScfDialect.ForOp.create(self.ctx, loc, zero, len_val, one, &.{}, &.{});
        try block.insertBefore(for_op.op, op);

        const body_block = for_op.getBodyBlock();
        const iv = for_op.getInductionVar();
        var body_insert = Insertion{ .block = body_block, .before = null };

        const src_resolved = try self.resolveViewIndex(body_insert, loc, src, iv);
        const elem_type = try self.memrefElementType(src_resolved.base);
        const load_op = try MemrefDialect.LoadOp.create(self.ctx, loc, src_resolved.base, src_resolved.index, elem_type);
        try body_insert.insert(load_op.op);

        const dst_resolved = try self.resolveViewIndex(body_insert, loc, dst, iv);
        const store_op = try MemrefDialect.StoreOp.create(self.ctx, loc, load_op.getResult(), dst_resolved.base, dst_resolved.index);
        try body_insert.insert(store_op.op);

        const yield_op = try ScfDialect.YieldOp.create(self.ctx, loc, &.{});
        try body_insert.insert(yield_op.op);

        block.removeOperation(op);
        return true;
    }

    fn resolveBaseMemref(self: *MemrefViewLegalizer, memref: *ir.Value) LegalizeError!*ir.Value {
        var current = memref;
        while (true) {
            const info = try self.getViewInfo(current) orelse return current;
            current = info.source;
        }
    }

    fn resolveViewIndex(
        self: *MemrefViewLegalizer,
        insertion: Insertion,
        loc: ir.Location,
        memref: *ir.Value,
        index: *ir.Value,
    ) LegalizeError!ResolvedIndex {
        const info = try self.getViewInfo(memref) orelse return .{ .base = memref, .index = index };
        const parent_index = try self.emitLinearToOffset(insertion, loc, index, info.shape, info.stride, info.offset);
        return self.resolveViewIndex(insertion, loc, info.source, parent_index);
    }

    fn getViewInfo(self: *MemrefViewLegalizer, value: *ir.Value) LegalizeError!?*ViewInfo {
        if (self.view_map.getPtr(value)) |info| return info;

        const def_op_opaque = value.getDefiningOp() orelse return null;
        const def_op: *ir.Operation = @ptrCast(@alignCast(def_op_opaque));

        const is_subview = std.mem.eql(u8, def_op.name.name, MemrefDialect.SubviewOp.operation_name);
        const is_transpose = std.mem.eql(u8, def_op.name.name, MemrefDialect.TransposeOp.operation_name);
        if (!is_subview and !is_transpose) return null;

        if (is_subview) {
            const subview = MemrefDialect.SubviewOp{ .op = def_op };
            const shape_payload = subview.getShapePayload() orelse return error.MissingLayout;
            const stride_payload = subview.getStridePayload() orelse return error.MissingLayout;
            const offset_payload = subview.getOffsetPayload() orelse return error.MissingLayout;

            const shape = try parseDims(self.allocator, shape_payload);
            errdefer self.allocator.free(shape);
            const stride = try parseDims(self.allocator, stride_payload);
            errdefer self.allocator.free(stride);
            if (shape.len != stride.len) return error.InvalidLayout;

            const offset = try parseOffset(offset_payload);

            const info = ViewInfo{
                .source = subview.getSource(),
                .offset = offset,
                .shape = shape,
                .stride = stride,
            };
            try self.view_map.put(value, info);
            return self.view_map.getPtr(value).?;
        }

        const transpose = MemrefDialect.TransposeOp{ .op = def_op };
        const shape_payload = transpose.getShapePayload() orelse return error.MissingLayout;
        const stride_payload = transpose.getStridePayload() orelse return error.MissingLayout;

        const shape = try parseDims(self.allocator, shape_payload);
        errdefer self.allocator.free(shape);
        const stride = try parseDims(self.allocator, stride_payload);
        errdefer self.allocator.free(stride);
        if (shape.len != stride.len) return error.InvalidLayout;

        const info = ViewInfo{
            .source = transpose.getSource(),
            .offset = 0,
            .shape = shape,
            .stride = stride,
        };
        try self.view_map.put(value, info);
        return self.view_map.getPtr(value).?;
    }

    fn parseOffset(payload: []const u8) LegalizeError!u64 {
        if (payload.len == 0) return error.InvalidLayout;
        return std.fmt.parseInt(u64, payload, 10) catch return error.InvalidLayout;
    }

    fn parseDims(allocator: std.mem.Allocator, payload: []const u8) LegalizeError![]u64 {
        if (payload.len == 0) return allocator.alloc(u64, 0);
        var dims: std.ArrayListUnmanaged(u64) = .empty;
        errdefer dims.deinit(allocator);

        var it = std.mem.splitScalar(u8, payload, ',');
        while (it.next()) |part| {
            if (part.len == 0) return error.InvalidLayout;
            const dim = std.fmt.parseInt(u64, part, 10) catch return error.InvalidLayout;
            try dims.append(allocator, dim);
        }

        return dims.toOwnedSlice(allocator);
    }

    fn emitConstIndex(
        self: *MemrefViewLegalizer,
        insertion: Insertion,
        loc: ir.Location,
        index_type: ir.Type,
        value: u64,
    ) LegalizeError!*ir.Value {
        const int_value = std.math.cast(i64, value) orelse return error.LayoutOverflow;
        var const_op = ArithDialect.ConstantOp.createInt(self.ctx, loc, index_type, int_value) catch return error.InvalidLayout;
        try insertion.insert(const_op.op);
        return const_op.getResult();
    }

    fn emitLinearToOffset(
        self: *MemrefViewLegalizer,
        insertion: Insertion,
        loc: ir.Location,
        index: *ir.Value,
        shape: []const u64,
        stride: []const u64,
        offset: u64,
    ) LegalizeError!*ir.Value {
        if (shape.len != stride.len) return error.InvalidLayout;
        const index_type = index.type;

        if (shape.len == 0) {
            if (offset == 0) return index;
            const base = try self.emitConstIndex(insertion, loc, index_type, offset);
            var add_op = ArithDialect.AddOp.create(self.ctx, loc, base, index) catch return error.InvalidLayout;
            try insertion.insert(add_op.op);
            return add_op.getResult();
        }

        var accum = try self.emitConstIndex(insertion, loc, index_type, offset);
        var current = index;

        var i: usize = 0;
        while (i < shape.len) : (i += 1) {
            const stride_row = try product(shape[i + 1 ..]);
            if (stride_row == 0) return error.InvalidLayout;

            var idx_val: *ir.Value = undefined;
            if (stride_row == 1) {
                idx_val = current;
            } else {
                const stride_const = try self.emitConstIndex(insertion, loc, index_type, stride_row);
                var div_op = ArithDialect.DivOp.create(self.ctx, loc, current, stride_const) catch return error.InvalidLayout;
                try insertion.insert(div_op.op);
                idx_val = div_op.getResult();

                var rem_op = ArithDialect.RemOp.create(self.ctx, loc, current, stride_const) catch return error.InvalidLayout;
                try insertion.insert(rem_op.op);
                current = rem_op.getResult();
            }

            const stride_val = stride[i];
            if (stride_val != 0) {
                var term = idx_val;
                if (stride_val != 1) {
                    const stride_const2 = try self.emitConstIndex(insertion, loc, index_type, stride_val);
                    var mul_op = ArithDialect.MulOp.create(self.ctx, loc, idx_val, stride_const2) catch return error.InvalidLayout;
                    try insertion.insert(mul_op.op);
                    term = mul_op.getResult();
                }

                var add_op = ArithDialect.AddOp.create(self.ctx, loc, accum, term) catch return error.InvalidLayout;
                try insertion.insert(add_op.op);
                accum = add_op.getResult();
            }
        }

        return accum;
    }

    fn product(dims: []const u64) LegalizeError!u64 {
        var total: u64 = 1;
        for (dims) |dim| {
            total = std.math.mul(u64, total, dim) catch return error.LayoutOverflow;
        }
        return total;
    }

    fn getCopyLength(self: *MemrefViewLegalizer, op: *ir.Operation, src: *ir.Value, dst: *ir.Value) LegalizeError!u64 {
        if (op.getAttrAs(ir.Attribute.IntegerAttr, "len")) |len_attr| {
            const len_int = len_attr.getValue();
            if (len_int < 0) return error.InvalidLayout;
            return std.math.cast(u64, len_int) orelse return error.LayoutOverflow;
        }

        const src_size = try self.memrefSize(src);
        const dst_size = try self.memrefSize(dst);

        if (src_size) |s| {
            if (dst_size) |d| {
                if (s != d) return error.InvalidLayout;
            }
            return s;
        }
        if (dst_size) |d| return d;

        return error.UnsupportedCopyLength;
    }

    fn memrefSize(self: *MemrefViewLegalizer, memref: *ir.Value) LegalizeError!?u64 {
        _ = self;
        const params = memrefParams(memref.type) orelse return error.InvalidLayout;
        return params.size;
    }

    fn memrefElementType(self: *MemrefViewLegalizer, memref: *ir.Value) LegalizeError!ir.Type {
        const params = memrefParams(memref.type) orelse return error.InvalidLayout;
        return self.ctx.getDialectTypeFromName(params.element_type_name) catch return error.InvalidLayout;
    }

    fn memrefParams(memref_type: ir.Type) ?MemrefDialect.MemrefParams {
        const param_key = memref_type.getDialectParamKey() orelse return null;
        return MemrefDialect.parseMemrefParams(param_key);
    }

    fn cleanupViews(self: *MemrefViewLegalizer) LegalizeError!void {
        var iter = self.view_map.iterator();
        while (iter.next()) |entry| {
            const value = entry.key_ptr.*;
            if (!value.hasNoUses()) continue;
            const def_op_opaque = value.getDefiningOp() orelse continue;
            const def_op: *ir.Operation = @ptrCast(@alignCast(def_op_opaque));
            if (!std.mem.eql(u8, def_op.name.name, MemrefDialect.SubviewOp.operation_name) and
                !std.mem.eql(u8, def_op.name.name, MemrefDialect.TransposeOp.operation_name))
            {
                continue;
            }
            if (def_op.getBlock()) |block| {
                block.removeOperation(def_op);
            }
        }
    }
};
