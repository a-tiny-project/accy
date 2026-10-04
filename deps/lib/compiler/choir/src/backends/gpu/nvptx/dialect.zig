const std = @import("std");
const choir = @import("../../../root.zig");

const ir = choir.ir;
const arith = choir.dialects.arith;
const gpu = @import("../../../dialects/gpu/root.zig");

const Dimension = gpu.Dimension;
const MmaShape = gpu.MmaShape;
const ShuffleMode = gpu.ShuffleMode;
const WarpOpKind = gpu.WarpOpKind;

pub const NvptxDialect = struct {
    pub const name = "nvptx";
    const op_specs = ir.dialects.opSpec.dialect(@This());
    pub const spec = ir.dialects.dialectSpec(@This(), .{
        .dialect_attributes = &.{
            "nvptx.dim",       "nvptx.shuffle_mode", "nvptx.warp_op",
            "nvptx.mma_shape", "nvptx.atomic_kind",
        },
    });

    pub const ThreadIdxOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "tid",
            .operands = 0,
            .results = 1,
            .required_attrs = &.{"dim"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !ThreadIdxOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const index_type = try arith.ArithDialect.getIndexType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{index_type});

            const op = try builder.create(state);
            try setDimensionAttr(op, ctx, dim);
            return .{ .op = op };
        }

        pub fn getResult(self: *const ThreadIdxOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getDimension(self: ThreadIdxOp) ?Dimension {
            return getDimensionAttr(self.op);
        }
    };

    pub const BlockIdxOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "ctaid",
            .operands = 0,
            .results = 1,
            .required_attrs = &.{"dim"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !BlockIdxOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const index_type = try arith.ArithDialect.getIndexType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{index_type});

            const op = try builder.create(state);
            try setDimensionAttr(op, ctx, dim);
            return .{ .op = op };
        }

        pub fn getResult(self: *const BlockIdxOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getDimension(self: BlockIdxOp) ?Dimension {
            return getDimensionAttr(self.op);
        }
    };

    pub const BlockDimOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "ntid",
            .operands = 0,
            .results = 1,
            .required_attrs = &.{"dim"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !BlockDimOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const index_type = try arith.ArithDialect.getIndexType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{index_type});

            const op = try builder.create(state);
            try setDimensionAttr(op, ctx, dim);
            return .{ .op = op };
        }

        pub fn getResult(self: *const BlockDimOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getDimension(self: BlockDimOp) ?Dimension {
            return getDimensionAttr(self.op);
        }
    };

    pub const GridDimOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "nctaid",
            .operands = 0,
            .results = 1,
            .required_attrs = &.{"dim"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !GridDimOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const index_type = try arith.ArithDialect.getIndexType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{index_type});

            const op = try builder.create(state);
            try setDimensionAttr(op, ctx, dim);
            return .{ .op = op };
        }

        pub fn getResult(self: *const GridDimOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getDimension(self: GridDimOp) ?Dimension {
            return getDimensionAttr(self.op);
        }
    };

    pub const Barrier0Op = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "barrier0",
            .operands = 0,
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !Barrier0Op {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const state = op_specs.state(@This(), loc);
            const op = try builder.create(state);
            return .{ .op = op };
        }
    };

    pub const WarpBarrierAllOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "bar.warp.sync.all",
            .operands = 0,
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !WarpBarrierAllOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const state = op_specs.state(@This(), loc);
            const op = try builder.create(state);
            return .{ .op = op };
        }
    };

    pub const LaneIdOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "laneid",
            .operands = 0,
            .results = 1,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !LaneIdOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const index_type = try arith.ArithDialect.getIndexType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{index_type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const LaneIdOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const WarpIdOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "warpid",
            .operands = 0,
            .results = 1,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !WarpIdOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const index_type = try arith.ArithDialect.getIndexType(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{index_type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const WarpIdOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const BarrierSyncOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "bar.sync",
            .operands = 1,
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, barrier_id: *ir.Value) !BarrierSyncOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{barrier_id});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getBarrierId(self: BarrierSyncOp) *ir.Value {
            return self.op.operands.items[0].value;
        }
    };

    pub const SyncWarpOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "bar.warp.sync",
            .operands = 1,
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, mask: *ir.Value) !SyncWarpOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{mask});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getMask(self: SyncWarpOp) *ir.Value {
            return self.op.operands.items[0].value;
        }
    };

    pub const ActiveMaskOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "activemask",
            .operands = 0,
            .results = 1,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !ActiveMaskOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const i32_type = try arith.ArithDialect.getI32Type(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{i32_type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const ActiveMaskOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const AllSyncOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "vote.sync.all",
            .operands = .{ "mask", "predicate" },
            .results = .{"result"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, mask: *ir.Value, pred: *ir.Value) !AllSyncOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const bool_type = try arith.ArithDialect.getScalarType(ctx, .bool);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ mask, pred });
            state.addTypes(&.{bool_type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const AllSyncOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getMask(self: AllSyncOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getPredicate(self: AllSyncOp) *ir.Value {
            return self.op.operands.items[1].value;
        }
    };

    pub const AnySyncOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "vote.sync.any",
            .operands = .{ "mask", "predicate" },
            .results = .{"result"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, mask: *ir.Value, pred: *ir.Value) !AnySyncOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const bool_type = try arith.ArithDialect.getScalarType(ctx, .bool);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ mask, pred });
            state.addTypes(&.{bool_type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const AnySyncOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getMask(self: AnySyncOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getPredicate(self: AnySyncOp) *ir.Value {
            return self.op.operands.items[1].value;
        }
    };

    pub const BallotSyncOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "vote.sync.ballot",
            .operands = .{ "mask", "predicate" },
            .results = .{"result"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, mask: *ir.Value, pred: *ir.Value) !BallotSyncOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const i32_type = try arith.ArithDialect.getI32Type(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ mask, pred });
            state.addTypes(&.{i32_type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const BallotSyncOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getMask(self: BallotSyncOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getPredicate(self: BallotSyncOp) *ir.Value {
            return self.op.operands.items[1].value;
        }
    };

    pub const ShflSyncOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "shfl.sync",
            .operands = .{ "mask", "src", "lane_or_delta" },
            .results = .{"result"},
            .required_attrs = &.{"mode"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            mode: ShuffleMode,
            mask: *ir.Value,
            src: *ir.Value,
            lane_or_delta: *ir.Value,
        ) !ShflSyncOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ mask, src, lane_or_delta });
            state.addTypes(&.{src.type});
            const op = try builder.create(state);
            try setShuffleModeAttr(op, ctx, mode);
            return .{ .op = op };
        }

        pub fn getResult(self: *const ShflSyncOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getMask(self: ShflSyncOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getSrc(self: ShflSyncOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getLaneOrDelta(self: ShflSyncOp) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getMode(self: ShflSyncOp) ?ShuffleMode {
            return getShuffleModeAttr(self.op);
        }
    };

    pub const WarpReduceOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "warp.reduce",
            .operands = .{ "mask", "value" },
            .results = .{"result"},
            .required_attrs = &.{"op"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            op_kind: WarpOpKind,
            mask: *ir.Value,
            value: *ir.Value,
        ) !WarpReduceOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ mask, value });
            state.addTypes(&.{value.type});
            const op = try builder.create(state);
            try setWarpOpAttr(op, ctx, op_kind);
            return .{ .op = op };
        }

        pub fn getResult(self: *const WarpReduceOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getMask(self: WarpReduceOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getValue(self: WarpReduceOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getOpKind(self: WarpReduceOp) ?WarpOpKind {
            return getWarpOpAttr(self.op);
        }
    };

    pub const MmaSyncOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "mma.sync",
            .operands = .{ "a0", "a1", "a2", "a3", "b0", "b1", "c0", "c1", "c2", "c3" },
            .results = .{ "d0", "d1", "d2", "d3" },
            .required_attrs = &.{"shape"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            operands: [10]*ir.Value,
            shape: MmaShape,
        ) !MmaSyncOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&operands);
            state.addTypes(&.{ operands[6].type, operands[7].type, operands[8].type, operands[9].type });
            const op = try builder.create(state);
            try setMmaShapeAttr(op, ctx, shape);
            return .{ .op = op };
        }

        pub fn getOperandValue(self: MmaSyncOp, index: usize) *ir.Value {
            return self.op.operands.items[index].value;
        }

        pub fn getD(self: *const MmaSyncOp, index: usize) *ir.Value {
            return self.op.getResult(index).?;
        }

        pub fn getShape(self: MmaSyncOp) ?MmaShape {
            return getMmaShapeAttr(self.op);
        }
    };

    pub const CpAsyncSharedOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "cp.async.shared",
            .operands = .{ "dst", "dst_index", "src", "src_index" },
            .results = 0,
            .required_attrs = &.{"bytes"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            dst: *ir.Value,
            dst_index: *ir.Value,
            src: *ir.Value,
            src_index: *ir.Value,
            bytes: u32,
        ) !CpAsyncSharedOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ dst, dst_index, src, src_index });
            const op = try builder.create(state);
            const bytes_attr = try ctx.getI64Attr(@intCast(bytes));
            try op.setAttr("bytes", bytes_attr);
            return .{ .op = op };
        }

        pub fn getDst(self: CpAsyncSharedOp) *ir.Value {
            return ir.dialects.operand(operation_spec, self.op, "dst");
        }

        pub fn getDstIndex(self: CpAsyncSharedOp) *ir.Value {
            return ir.dialects.operand(operation_spec, self.op, "dst_index");
        }

        pub fn getSrc(self: CpAsyncSharedOp) *ir.Value {
            return ir.dialects.operand(operation_spec, self.op, "src");
        }

        pub fn getSrcIndex(self: CpAsyncSharedOp) *ir.Value {
            return ir.dialects.operand(operation_spec, self.op, "src_index");
        }

        pub fn getBytes(self: CpAsyncSharedOp) ?u32 {
            const int_attr = self.op.getAttrAs(ir.Attribute.IntegerAttr, "bytes") orelse return null;
            const raw = int_attr.getUnsignedValue();
            if (raw > std.math.maxInt(u32)) return null;
            return @intCast(raw);
        }
    };

    pub const FenceDeviceOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "membar.gl",
            .operands = 0,
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !FenceDeviceOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const state = op_specs.state(@This(), loc);
            const op = try builder.create(state);
            return .{ .op = op };
        }
    };

    pub const CpAsyncCommitOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "cp.async.commit",
            .operands = 0,
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !CpAsyncCommitOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const state = op_specs.state(@This(), loc);
            const op = try builder.create(state);
            return .{ .op = op };
        }
    };

    pub const CpAsyncWaitOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "cp.async.wait",
            .operands = 0,
            .results = 0,
            .required_attrs = &.{"groups"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, groups: u32) !CpAsyncWaitOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const state = op_specs.state(@This(), loc);
            const op = try builder.create(state);
            const groups_attr = try ctx.getI64Attr(@intCast(groups));
            try op.setAttr("groups", groups_attr);
            return .{ .op = op };
        }

        pub fn getGroups(self: CpAsyncWaitOp) ?u32 {
            const int_attr = self.op.getAttrAs(ir.Attribute.IntegerAttr, "groups") orelse return null;
            const raw = int_attr.getUnsignedValue();
            if (raw > std.math.maxInt(u32)) return null;
            return @intCast(raw);
        }
    };

    pub const WarpScanOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "warp.scan",
            .operands = .{ "mask", "value" },
            .results = .{"result"},
            .required_attrs = &.{ "inclusive", "op" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            op_kind: WarpOpKind,
            inclusive: bool,
            mask: *ir.Value,
            value: *ir.Value,
        ) !WarpScanOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ mask, value });
            state.addTypes(&.{value.type});
            const op = try builder.create(state);
            try setWarpOpAttr(op, ctx, op_kind);
            try setBoolAttr(op, ctx, "inclusive", inclusive);
            return .{ .op = op };
        }

        pub fn getResult(self: *const WarpScanOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getMask(self: WarpScanOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getValue(self: WarpScanOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getOpKind(self: WarpScanOp) ?WarpOpKind {
            return getWarpOpAttr(self.op);
        }

        pub fn isInclusive(self: WarpScanOp) bool {
            return getBoolAttrValue(self.op, "inclusive");
        }
    };

    pub const LoadLocalOp: type = loadOp("local");
    pub const StoreLocalOp: type = storeOp("local");

    pub const LoadGlobalOp: type = loadOp("global");

    pub const StoreGlobalOp: type = storeOp("global");

    pub const AtomicGlobalOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "atom.global",
            .operands = 3,
            .results = 1,
            .attrs = &.{"kind"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            kind: choir.dialects.AtomicRmwKind,
            value: *ir.Value,
            memref: *ir.Value,
            index: *ir.Value,
            result_type: ir.Type,
        ) !AtomicGlobalOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ value, memref, index });
            state.addTypes(&.{result_type});
            const op = try builder.create(state);
            const kind_attr = try ctx.getDialectAttr("nvptx.atomic_kind", kind.toString());
            try op.setAttr("kind", kind_attr);
            return .{ .op = op };
        }

        pub fn getKind(self: AtomicGlobalOp) ?choir.dialects.AtomicRmwKind {
            const dialect_attr = self.op.getAttrAs(ir.Attribute.DialectAttr, "kind") orelse return null;
            return choir.dialects.AtomicRmwKind.fromString(dialect_attr.payload);
        }

        pub fn getValue(self: AtomicGlobalOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getMemref(self: AtomicGlobalOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getIndex(self: AtomicGlobalOp) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getResult(self: *const AtomicGlobalOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const AtomicSharedOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "atom.shared",
            .operands = 3,
            .results = 1,
            .attrs = &.{"kind"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            kind: choir.dialects.AtomicRmwKind,
            value: *ir.Value,
            memref: *ir.Value,
            index: *ir.Value,
            result_type: ir.Type,
        ) !AtomicSharedOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ value, memref, index });
            state.addTypes(&.{result_type});
            const op = try builder.create(state);
            const kind_attr = try ctx.getDialectAttr("nvptx.atomic_kind", kind.toString());
            try op.setAttr("kind", kind_attr);
            return .{ .op = op };
        }

        pub fn getKind(self: AtomicSharedOp) ?choir.dialects.AtomicRmwKind {
            const dialect_attr = self.op.getAttrAs(ir.Attribute.DialectAttr, "kind") orelse return null;
            return choir.dialects.AtomicRmwKind.fromString(dialect_attr.payload);
        }

        pub fn getValue(self: AtomicSharedOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getMemref(self: AtomicSharedOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getIndex(self: AtomicSharedOp) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getResult(self: *const AtomicSharedOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const AtomicCasGlobalOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "atom.global.cas",
            .operands = 4,
            .results = 1,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            expected: *ir.Value,
            desired: *ir.Value,
            memref: *ir.Value,
            index: *ir.Value,
            result_type: ir.Type,
        ) !AtomicCasGlobalOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ expected, desired, memref, index });
            state.addTypes(&.{result_type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getExpected(self: AtomicCasGlobalOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getDesired(self: AtomicCasGlobalOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getMemref(self: AtomicCasGlobalOp) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getIndex(self: AtomicCasGlobalOp) *ir.Value {
            return self.op.operands.items[3].value;
        }

        pub fn getResult(self: *const AtomicCasGlobalOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const AtomicCasSharedOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "atom.shared.cas",
            .operands = 4,
            .results = 1,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            expected: *ir.Value,
            desired: *ir.Value,
            memref: *ir.Value,
            index: *ir.Value,
            result_type: ir.Type,
        ) !AtomicCasSharedOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ expected, desired, memref, index });
            state.addTypes(&.{result_type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getExpected(self: AtomicCasSharedOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getDesired(self: AtomicCasSharedOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getMemref(self: AtomicCasSharedOp) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getIndex(self: AtomicCasSharedOp) *ir.Value {
            return self.op.operands.items[3].value;
        }

        pub fn getResult(self: *const AtomicCasSharedOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const LoadSharedOp: type = loadOp("shared");

    pub const StoreSharedOp: type = storeOp("shared");

    pub const SinApproxF32Op = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "sin.approx.f32",
            .operands = 1,
            .results = 1,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, value: *ir.Value) !SinApproxF32Op {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{value});
            state.addTypes(&.{value.type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getValue(self: SinApproxF32Op) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getResult(self: *const SinApproxF32Op) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const CosApproxF32Op = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "cos.approx.f32",
            .operands = 1,
            .results = 1,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, value: *ir.Value) !CosApproxF32Op {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{value});
            state.addTypes(&.{value.type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getValue(self: CosApproxF32Op) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getResult(self: *const CosApproxF32Op) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const FmaRnF32Op = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "fma.rn.f32",
            .operands = 3,
            .results = 1,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, a: *ir.Value, b: *ir.Value, c: *ir.Value) !FmaRnF32Op {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ a, b, c });
            state.addTypes(&.{a.type});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getA(self: FmaRnF32Op) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getB(self: FmaRnF32Op) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getC(self: FmaRnF32Op) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getResult(self: *const FmaRnF32Op) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    fn loadOp(comptime space: []const u8) type {
        return struct {
            op: *ir.Operation,
            pub const operation_spec = op_specs.leaf(.{
                .mnemonic = "ld." ++ space,
                .operands = 2,
                .results = 1,
            });
            pub const operation_name = operation_spec.name;

            pub fn create(
                ctx: *ir.Context,
                loc: ir.Location,
                memref: *ir.Value,
                index: *ir.Value,
                result_type: ir.Type,
            ) !@This() {
                try loadSpec(ctx);
                var builder = ir.OperationBuilder.init(ctx);
                var state = op_specs.state(@This(), loc);
                state.addOperands(&.{ memref, index });
                state.addTypes(&.{result_type});
                const op = try builder.create(state);
                return .{ .op = op };
            }

            pub fn getResult(self: *const @This()) *ir.Value {
                return self.op.getResult(0).?;
            }

            pub fn getMemref(self: @This()) *ir.Value {
                return self.op.operands.items[0].value;
            }

            pub fn getIndex(self: @This()) *ir.Value {
                return self.op.operands.items[1].value;
            }
        };
    }

    fn storeOp(comptime space: []const u8) type {
        return struct {
            op: *ir.Operation,
            pub const operation_spec = op_specs.leaf(.{
                .mnemonic = "st." ++ space,
                .operands = 3,
                .results = 0,
            });
            pub const operation_name = operation_spec.name;

            pub fn create(
                ctx: *ir.Context,
                loc: ir.Location,
                value: *ir.Value,
                memref: *ir.Value,
                index: *ir.Value,
            ) !@This() {
                try loadSpec(ctx);
                var builder = ir.OperationBuilder.init(ctx);
                var state = op_specs.state(@This(), loc);
                state.addOperands(&.{ value, memref, index });
                const op = try builder.create(state);
                return .{ .op = op };
            }

            pub fn getValue(self: @This()) *ir.Value {
                return self.op.operands.items[0].value;
            }

            pub fn getMemref(self: @This()) *ir.Value {
                return self.op.operands.items[1].value;
            }

            pub fn getIndex(self: @This()) *ir.Value {
                return self.op.operands.items[2].value;
            }
        };
    }

    fn loadSpec(ctx: *ir.Context) !void {
        try ir.dialects.loadDialectSpec(ctx, spec);
    }

    fn setDimensionAttr(op: *ir.Operation, ctx: *ir.Context, dim: Dimension) !void {
        const attr = try ctx.getDialectAttr("nvptx.dim", dim.toString());
        try op.setAttr("dim", attr);
    }

    fn getDimensionAttr(op: *const ir.Operation) ?Dimension {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "dim") orelse return null;
        return Dimension.fromString(dialect_attr.payload);
    }

    fn setShuffleModeAttr(op: *ir.Operation, ctx: *ir.Context, mode: ShuffleMode) !void {
        const attr = try ctx.getDialectAttr("nvptx.shuffle_mode", mode.toString());
        try op.setAttr("mode", attr);
    }

    fn getShuffleModeAttr(op: *const ir.Operation) ?ShuffleMode {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "mode") orelse return null;
        return ShuffleMode.fromString(dialect_attr.payload);
    }

    fn setWarpOpAttr(op: *ir.Operation, ctx: *ir.Context, op_kind: WarpOpKind) !void {
        const attr = try ctx.getDialectAttr("nvptx.warp_op", op_kind.toString());
        try op.setAttr("op", attr);
    }

    fn getWarpOpAttr(op: *const ir.Operation) ?WarpOpKind {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "op") orelse return null;
        return WarpOpKind.fromString(dialect_attr.payload);
    }

    fn setMmaShapeAttr(op: *ir.Operation, ctx: *ir.Context, shape: MmaShape) !void {
        var buf: [32]u8 = undefined;
        const shape_str = try shape.toString(buf[0..]);
        const shape_attr = try ctx.getDialectAttr("nvptx.mma_shape", shape_str);
        try op.setAttr("shape", shape_attr);
    }

    fn getMmaShapeAttr(op: *const ir.Operation) ?MmaShape {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "shape") orelse return null;
        return MmaShape.parse(dialect_attr.payload);
    }

    fn setBoolAttr(op: *ir.Operation, ctx: *ir.Context, attr_name: []const u8, value: bool) !void {
        const bool_attr = try ctx.getBoolAttr(value);
        try op.setAttr(attr_name, bool_attr);
    }

    fn getBoolAttrValue(op: *const ir.Operation, attr_name: []const u8) bool {
        const bool_attr = op.getAttrAs(ir.Attribute.BoolAttr, attr_name) orelse return false;
        return bool_attr.getValue();
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "NvptxDialect operation specs register shapes and attributes" {
    const testing = std.testing;

    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    try ir.dialects.loadDialectSpec(&ctx, NvptxDialect.spec);

    const tid_info = ctx.lookupOperation(NvptxDialect.ThreadIdxOp.operation_name) orelse return error.TestExpectedOperation;
    try testing.expect(tid_info.shape.operands.allows(0));
    try testing.expect(!tid_info.shape.operands.allows(1));
    try testing.expect(tid_info.shape.results.allows(1));
    try testing.expect(!tid_info.shape.results.allows(0));
    try testing.expect(tid_info.shape.regions.allows(0));
    try testing.expect(!tid_info.shape.regions.allows(1));
    try testing.expect(tid_info.shape.successors.allows(0));
    try testing.expect(!tid_info.shape.successors.allows(1));
    try testing.expect(tid_info.hasInherentAttributeName("dim"));

    const load_info = ctx.lookupOperation(NvptxDialect.LoadGlobalOp.operation_name) orelse return error.TestExpectedOperation;
    try testing.expect(load_info.shape.operands.allows(2));
    try testing.expect(!load_info.shape.operands.allows(1));
    try testing.expect(load_info.shape.results.allows(1));
    try testing.expect(!load_info.shape.results.allows(0));

    const store_info = ctx.lookupOperation(NvptxDialect.StoreGlobalOp.operation_name) orelse return error.TestExpectedOperation;
    try testing.expect(store_info.shape.operands.allows(3));
    try testing.expect(!store_info.shape.operands.allows(2));
    try testing.expect(store_info.shape.results.allows(0));
    try testing.expect(!store_info.shape.results.allows(1));

    const cas_info = ctx.lookupOperation(NvptxDialect.AtomicCasGlobalOp.operation_name) orelse return error.TestExpectedOperation;
    try testing.expect(cas_info.shape.operands.allows(4));
    try testing.expect(!cas_info.shape.operands.allows(3));
    try testing.expect(cas_info.shape.results.allows(1));
    try testing.expect(!cas_info.shape.results.allows(0));
}

test "NvptxDialect op-spec state supports strict contexts and verifier shape checks" {
    const testing = std.testing;

    var ctx = try ir.Context.init(testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(testing.allocator);

    try ctx.requireRegistered();
    try ir.dialects.loadDialectSpec(&ctx, choir.dialects.arith.spec);
    try ir.dialects.loadDialectSpec(&ctx, NvptxDialect.spec);

    const loc = ir.Location.getUnknown();
    const tid = try NvptxDialect.ThreadIdxOp.create(&ctx, loc, .x);
    try testing.expectEqual(Dimension.x, tid.getDimension().?);
    try ir.verifyOperation(tid.op, .{ .recursive = false });

    const index_type = try choir.dialects.arith.ArithDialect.getIndexType(&ctx);
    var bad_load_state = ir.Operation.State.init(NvptxDialect.LoadGlobalOp.operation_name, loc);
    bad_load_state.addTypes(&.{index_type});
    const bad_load = try ctx.createOperation(bad_load_state);
    try testing.expectError(error.OperandCountMismatch, ir.verifyOperation(bad_load, .{ .recursive = false }));
}
