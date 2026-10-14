const std = @import("std");
const ir = @import("../../core/root.zig");
const dialects = @import("../root.zig");

const interfaces = ir.interfaces;
const effects = interfaces.effects;
const func = dialects.func;
const tags = @import("tags.zig");
const stage = @import("stage.zig");

pub const type_names = tags.type_names;
pub const Dimension = tags.Dimension;
pub const Scope = tags.Scope;
pub const MemoryOrder = tags.MemoryOrder;
pub const ShuffleMode = tags.ShuffleMode;
pub const WarpOpKind = tags.WarpOpKind;
pub const MmaShape = tags.MmaShape;
pub const Stage = tags.Stage;

pub const GpuDialect = struct {
    pub const name = "gpu";
    const op_specs = ir.dialects.opSpec.dialect(@This());
    pub const spec = ir.dialects.dialectSpec(@This(), .{
        .types = ir.dialects.typeNames(type_specs),
    });
    const symbol_table_trait = ir.dialects.trait(ir.traits.SymbolTable);

    const func_symbol_vtable = interfaces.SymbolOpInterface.VTable{
        .getSymbolName = getFuncSymbolName,
        .setSymbolName = setFuncSymbolName,
        .isDeclaration = isFuncDeclaration,
    };

    const type_specs = struct {
        pub const tma_desc = type_names.tma_desc;
        pub const mbarrier = type_names.mbarrier;
        pub const sampled_texture = type_names.sampled_texture;
    };

    pub const StageInputOp = stage.StageInputOp;
    pub const StageOutputOp = stage.StageOutputOp;
    pub const PositionOp = stage.PositionOp;
    pub const FragCoordOp = stage.FragCoordOp;
    pub const VertexIndexOp = stage.VertexIndexOp;
    pub const InstanceIndexOp = stage.InstanceIndexOp;
    pub const FrontFacingOp = stage.FrontFacingOp;
    pub const SampledTextureOp = stage.SampledTextureOp;
    pub const SampleOp = stage.SampleOp;
    pub const SampleLodOp = stage.SampleLodOp;
    pub const DpdxOp = stage.DpdxOp;
    pub const DpdyOp = stage.DpdyOp;
    pub const FwidthOp = stage.FwidthOp;
    pub const PushConstantOp = stage.PushConstantOp;
    pub const UniformOp = stage.UniformOp;
    pub const UniformElementOp = stage.UniformElementOp;

    pub const ModuleOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "module",
            .operands = 0,
            .results = 0,
            .regions = .{"body"},
            .successors = 0,
            .dynamic_traits = .{symbol_table_trait},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !ModuleOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            var body = ir.context.initRegion(ctx);
            defer body.deinit();
            var body_builder = ir.OperationBuilder.init(ctx);
            _ = try body_builder.createBlock(&body, &.{}, &.{});
            var regions = [_]*ir.Region{&body};
            state.addRegionBodies(&regions);

            const op = try builder.create(state);
            errdefer op.erase();

            return .{ .op = op };
        }

        pub fn getBody(self: ModuleOp) *ir.Region {
            return self.op.getRegion(0).?;
        }

        pub fn getBodyBlock(self: ModuleOp) *ir.Block {
            return self.getBody().getEntryBlock().?;
        }
    };

    pub const FuncOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "func",
            .operands = 0,
            .regions = .{"body"},
            .successors = 0,
            .attrs = &.{ "kernel", ir.SymbolTable.symbol_attr_names.sym_visibility },
            .required_attrs = &.{"sym_name"},
            .interfaces = &.{
                interfaces.SymbolOpInterface.entry(&func_symbol_vtable),
                effects.EffectOpInterface.entryFor(.{ .facts = &.{.{ .region = .{
                    .index = 0,
                    .execution = .latent,
                    .may_diverge = false,
                    .captures = false,
                } }} }),
            },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            func_name: []const u8,
            input_types: []const ir.Type,
            result_types: []const ir.Type,
        ) !FuncOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addTypes(result_types);
            var body = ir.context.initRegion(ctx);
            defer body.deinit();
            var body_builder = ir.OperationBuilder.init(ctx);
            _ = try body_builder.createBlockWithLoc(&body, input_types, loc);
            var regions = [_]*ir.Region{&body};
            state.addRegionBodies(&regions);

            const op = try builder.create(state);
            errdefer op.erase();

            const name_attr = try func.FuncDialect.getSymNameAttr(ctx, func_name);
            try op.setAttr("sym_name", name_attr);

            return .{ .op = op };
        }

        pub fn createKernel(
            ctx: *ir.Context,
            loc: ir.Location,
            kernel_name: []const u8,
            input_types: []const ir.Type,
        ) !FuncOp {
            var func_op = try create(ctx, loc, kernel_name, input_types, &.{});
            errdefer func_op.op.erase();
            const kernel_attr = try func.FuncDialect.getKernelAttr(ctx);
            try func_op.op.setAttr("kernel", kernel_attr);
            return func_op;
        }

        pub fn getName(self: FuncOp) ?[]const u8 {
            return ir.SymbolTable.getSymbolName(self.op);
        }

        pub fn isKernel(self: FuncOp) bool {
            return self.op.getAttr("kernel") != null;
        }

        pub fn getBody(self: FuncOp) *ir.Region {
            return self.op.getRegion(0).?;
        }

        pub fn getEntryBlock(self: FuncOp) *ir.Block {
            return self.getBody().getEntryBlock().?;
        }

        pub fn getArguments(self: FuncOp) []*ir.Value {
            return self.getEntryBlock().arguments.items;
        }

        pub fn getNumArguments(self: FuncOp) usize {
            return self.getEntryBlock().arguments.items.len;
        }

        pub fn getArgument(self: FuncOp, index: usize) *ir.Value {
            return self.getEntryBlock().arguments.items[index];
        }

        pub fn getResultTypes(self: FuncOp) []const ir.Type {
            return self.op.getResultTypes();
        }

        pub fn getNumResults(self: FuncOp) usize {
            return self.op.results.items.len;
        }
    };

    pub const YieldOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.terminator(.{ .mnemonic = "yield" });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            operands: []const *ir.Value,
        ) !YieldOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(operands);
            const op = try builder.create(state);
            errdefer op.erase();
            return .{ .op = op };
        }

        pub fn getOperands(self: YieldOp) []const *ir.Value {
            return self.op.getOperandValues();
        }
    };

    pub const LaunchOp = struct {
        op: *ir.Operation,

        const dim_attr_keys = struct {
            pub const grid_x = "grid_x";
            pub const grid_y = "grid_y";
            pub const grid_z = "grid_z";
            pub const block_x = "block_x";
            pub const block_y = "block_y";
            pub const block_z = "block_z";
        };

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "launch",
            .interfaces = &.{gpuEffects(.launch, &.{}, &.{})},
            .operands = ir.dialects.shape.any(),
            .results = 0,
            .required_attrs = &.{
                dim_attr_keys.block_x,
                dim_attr_keys.block_y,
                dim_attr_keys.block_z,
                dim_attr_keys.grid_x,
                dim_attr_keys.grid_y,
                dim_attr_keys.grid_z,
                "kernel",
                "num_kernel_args",
            },
        });
        pub const operation_name = operation_spec.name;

        fn setDimAttr(op: *ir.Operation, ctx: *ir.Context, key: []const u8, value: u32) !void {
            const attr = try ctx.getI64Attr(@intCast(value));
            try op.setAttr(key, attr);
        }

        fn getDimAttr(op: *const ir.Operation, key: []const u8) ?u32 {
            const int_attr = op.getAttrAs(ir.Attribute.IntegerAttr, key) orelse return null;
            const raw = int_attr.getUnsignedValue();
            if (raw > std.math.maxInt(u32)) return null;
            return @intCast(raw);
        }

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            kernel_name: []const u8,
            kernel_args: []const *ir.Value,
            grid_dim: [3]u32,
            block_dim: [3]u32,
        ) !LaunchOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);

            var all_operands: std.ArrayList(*ir.Value) = .empty;
            const allocator = ir.context.transientAllocator(ctx);
            defer all_operands.deinit(allocator);
            for (kernel_args) |arg| {
                try all_operands.append(allocator, arg);
            }
            state.addOperands(all_operands.items);

            const op = try builder.create(state);
            errdefer op.erase();

            const kernel_attr = try func.FuncDialect.getSymNameAttr(ctx, kernel_name);
            try op.setAttr("kernel", kernel_attr);

            var buf: [16]u8 = undefined;
            const num_args_str = try ir.format.intPayload(buf[0..], kernel_args.len);
            const num_args_attr = try ctx.getDialectAttr("gpu.num_kernel_args", num_args_str);
            try op.setAttr("num_kernel_args", num_args_attr);

            try setDimAttr(op, ctx, dim_attr_keys.grid_x, grid_dim[0]);
            try setDimAttr(op, ctx, dim_attr_keys.grid_y, grid_dim[1]);
            try setDimAttr(op, ctx, dim_attr_keys.grid_z, grid_dim[2]);
            try setDimAttr(op, ctx, dim_attr_keys.block_x, block_dim[0]);
            try setDimAttr(op, ctx, dim_attr_keys.block_y, block_dim[1]);
            try setDimAttr(op, ctx, dim_attr_keys.block_z, block_dim[2]);

            return .{ .op = op };
        }

        pub fn getKernelName(self: LaunchOp) ?[]const u8 {
            if (self.op.getAttr("kernel")) |attr| {
                return func.FuncDialect.getSymNameValue(attr);
            }
            return null;
        }

        pub fn getNumKernelArgs(self: LaunchOp) usize {
            const dialect_attr = self.op.getAttrAs(ir.Attribute.DialectAttr, "num_kernel_args") orelse return 0;
            return std.fmt.parseInt(usize, dialect_attr.payload, 10) catch 0;
        }

        pub fn getKernelArgs(self: LaunchOp) []const *ir.Value {
            const num_args = self.getNumKernelArgs();
            return self.op.getOperandValues()[0..num_args];
        }

        pub fn getGridDim(self: LaunchOp) ?[3]u32 {
            const gx = getDimAttr(self.op, dim_attr_keys.grid_x) orelse return null;
            const gy = getDimAttr(self.op, dim_attr_keys.grid_y) orelse return null;
            const gz = getDimAttr(self.op, dim_attr_keys.grid_z) orelse return null;
            return .{ gx, gy, gz };
        }

        pub fn getBlockDim(self: LaunchOp) ?[3]u32 {
            const bx = getDimAttr(self.op, dim_attr_keys.block_x) orelse return null;
            const by = getDimAttr(self.op, dim_attr_keys.block_y) orelse return null;
            const bz = getDimAttr(self.op, dim_attr_keys.block_z) orelse return null;
            return .{ bx, by, bz };
        }
    };

    pub const ThreadIdxOp = struct {
        op: *ir.Operation,

        pub const operation_spec = dimIndexSpec("thread_idx");
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !ThreadIdxOp {
            const arith = dialects.arith;
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const index_type = try arith.ArithDialect.getIndexType(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addTypes(&.{index_type});

            const op = try builder.create(state);
            errdefer op.erase();
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

        pub const operation_spec = dimIndexSpec("block_idx");
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !BlockIdxOp {
            const arith = dialects.arith;
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const index_type = try arith.ArithDialect.getIndexType(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addTypes(&.{index_type});

            const op = try builder.create(state);
            errdefer op.erase();
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

        pub const operation_spec = dimIndexSpec("block_dim");
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !BlockDimOp {
            const arith = dialects.arith;
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const index_type = try arith.ArithDialect.getIndexType(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addTypes(&.{index_type});

            const op = try builder.create(state);
            errdefer op.erase();
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

        pub const operation_spec = dimIndexSpec("grid_dim");
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !GridDimOp {
            const arith = dialects.arith;
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const index_type = try arith.ArithDialect.getIndexType(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addTypes(&.{index_type});

            const op = try builder.create(state);
            errdefer op.erase();
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

    pub const GlobalIdxOp = struct {
        op: *ir.Operation,

        pub const operation_spec = dimIndexSpec("global_idx");
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !GlobalIdxOp {
            const arith = dialects.arith;
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const index_type = try arith.ArithDialect.getIndexType(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addTypes(&.{index_type});

            const op = try builder.create(state);
            errdefer op.erase();
            try setDimensionAttr(op, ctx, dim);

            return .{ .op = op };
        }

        pub fn getResult(self: *const GlobalIdxOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getDimension(self: GlobalIdxOp) ?Dimension {
            return getDimensionAttr(self.op);
        }
    };

    pub const LaneIdOp = struct {
        op: *ir.Operation,

        pub const operation_spec = indexSpec("lane_id");
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !LaneIdOp {
            const arith = dialects.arith;
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const index_type = try arith.ArithDialect.getIndexType(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addTypes(&.{index_type});

            const op = try builder.create(state);
            errdefer op.erase();
            return .{ .op = op };
        }

        pub fn getResult(self: *const LaneIdOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const WarpIdOp = struct {
        op: *ir.Operation,

        pub const operation_spec = indexSpec("warp_id");
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !WarpIdOp {
            const arith = dialects.arith;
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const index_type = try arith.ArithDialect.getIndexType(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addTypes(&.{index_type});

            const op = try builder.create(state);
            errdefer op.erase();
            return .{ .op = op };
        }

        pub fn getResult(self: *const WarpIdOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const BarrierOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "barrier",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
            .operands = 0,
            .results = 0,
            .required_attrs = &.{"scope"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, scope: Scope) !BarrierOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const state = ir.Operation.State.initStatic(operation_name, loc);

            const op = try builder.create(state);
            errdefer op.erase();
            try setScopeAttr(op, ctx, scope);

            return .{ .op = op };
        }

        pub fn getScope(self: BarrierOp) ?Scope {
            return getScopeAttr(self.op);
        }
    };

    pub const FenceOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "fence",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
            .operands = 0,
            .results = 0,
            .required_attrs = &.{ "ordering", "scope" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, scope: Scope, ordering: MemoryOrder) !FenceOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const state = ir.Operation.State.initStatic(operation_name, loc);

            const op = try builder.create(state);
            errdefer op.erase();
            try setScopeAttr(op, ctx, scope);
            try setOrderingAttr(op, ctx, ordering);

            return .{ .op = op };
        }

        pub fn getScope(self: FenceOp) ?Scope {
            return getScopeAttr(self.op);
        }

        pub fn getOrdering(self: FenceOp) ?MemoryOrder {
            return getOrderingAttr(self.op);
        }
    };

    pub const MemcpyAsyncOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "memcpy_async",
            .interfaces = &.{gpuEffects(.launch, &.{0}, &.{1})},
            .operands = ir.dialects.shape.between(3, 5),
            .operand_names = .{ "src", "dst", "num_bytes", "stream", "event" },
            .results = 0,
            .operand_segments = ir.dialects.segments.operands(.{
                1,
                1,
                1,
                ir.dialects.shape.atMost(1),
                ir.dialects.shape.atMost(1),
            }),
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            src: *ir.Value,
            dst: *ir.Value,
            num_bytes: *ir.Value,
            stream: ?*ir.Value,
            event: ?*ir.Value,
        ) !MemcpyAsyncOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);

            var operands: [5]*ir.Value = undefined;
            var operand_count: usize = 0;
            operands[operand_count] = src;
            operand_count += 1;
            operands[operand_count] = dst;
            operand_count += 1;
            operands[operand_count] = num_bytes;
            operand_count += 1;

            if (stream) |stream_val| {
                operands[operand_count] = stream_val;
                operand_count += 1;
            }

            if (event) |event_val| {
                operands[operand_count] = event_val;
                operand_count += 1;
            }

            state.addOperands(operands[0..operand_count]);
            const op = try builder.create(state);
            errdefer op.erase();
            const segment_sizes = [_]usize{
                1,
                1,
                1,
                if (stream != null) 1 else 0,
                if (event != null) 1 else 0,
            };
            try ir.dialects.setOperandSegmentSizes(operation_spec, op, &segment_sizes);

            return .{ .op = op };
        }

        pub fn getSrc(self: MemcpyAsyncOp) *ir.Value {
            return ir.dialects.operand(operation_spec, self.op, "src");
        }

        pub fn getDst(self: MemcpyAsyncOp) *ir.Value {
            return ir.dialects.operand(operation_spec, self.op, "dst");
        }

        pub fn getNumBytes(self: MemcpyAsyncOp) *ir.Value {
            return ir.dialects.operand(operation_spec, self.op, "num_bytes");
        }

        pub fn getStream(self: MemcpyAsyncOp) ?*ir.Value {
            return ir.dialects.operandSegmentValue(operation_spec, self.op, "stream");
        }

        pub fn getEvent(self: MemcpyAsyncOp) ?*ir.Value {
            return ir.dialects.operandSegmentValue(operation_spec, self.op, "event");
        }
    };

    pub const TmaCreateDescriptorOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "tma.create_descriptor",
            .operands = .{ "tensor", "box_shape" },
            .results = .{"descriptor"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            tensor: *ir.Value,
            box_shape: *ir.Value,
        ) !TmaCreateDescriptorOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ tensor, box_shape });

            const desc_type = try getTmaDescriptorType(ctx);
            state.addTypes(&.{desc_type});

            const op = try builder.create(state);
            errdefer op.erase();
            return .{ .op = op };
        }

        pub fn getResult(self: *const TmaCreateDescriptorOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getTensor(self: TmaCreateDescriptorOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getBoxShape(self: TmaCreateDescriptorOp) *ir.Value {
            return self.op.operands.items[1].value;
        }
    };

    pub const TmaLoadOp = struct {
        op: *ir.Operation,

        pub const operation_spec = noResultSpec("tma.load", .{ "descriptor", "shared_mem", "barrier", "coords" });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            desc: *ir.Value,
            shmem: *ir.Value,
            mbarrier: *ir.Value,
            coords: *ir.Value,
        ) !TmaLoadOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ desc, shmem, mbarrier, coords });

            const op = try builder.create(state);
            errdefer op.erase();
            return .{ .op = op };
        }

        pub fn getDescriptor(self: TmaLoadOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getSharedMem(self: TmaLoadOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getBarrier(self: TmaLoadOp) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getCoords(self: TmaLoadOp) *ir.Value {
            return self.op.operands.items[3].value;
        }
    };

    pub const TmaCommitGroupOp = struct {
        op: *ir.Operation,

        pub const operation_spec = noResultSpec("tma.commit_group", 0);
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !TmaCommitGroupOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const state = ir.Operation.State.initStatic(operation_name, loc);

            const op = try builder.create(state);
            errdefer op.erase();
            return .{ .op = op };
        }
    };

    pub const TmaWaitGroupOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "tma.wait_group",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
            .operands = 0,
            .results = 0,
            .required_attrs = &.{"count"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, count: i64) !TmaWaitGroupOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const state = ir.Operation.State.initStatic(operation_name, loc);

            const op = try builder.create(state);
            errdefer op.erase();
            try setI64Attr(op, ctx, "count", count);
            return .{ .op = op };
        }

        pub fn getCount(self: TmaWaitGroupOp) ?i64 {
            return getI64AttrValue(self.op, "count");
        }
    };

    pub const ShflSyncOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "shfl_sync",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
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
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ mask, src, lane_or_delta });
            state.addTypes(&.{src.type});

            const op = try builder.create(state);
            errdefer op.erase();

            const mode_attr = try ctx.getDialectAttr("gpu.shuffle_mode", mode.toString());
            try op.setAttr("mode", mode_attr);

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
            const dialect_attr = self.op.getAttrAs(ir.Attribute.DialectAttr, "mode") orelse return null;
            return ShuffleMode.fromString(dialect_attr.payload);
        }
    };

    pub const AllSyncOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "all_sync",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
            .operands = .{ "mask", "predicate" },
            .results = .{"result"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, mask: *ir.Value, pred: *ir.Value) !AllSyncOp {
            const arith = dialects.arith;
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const bool_type = try arith.ArithDialect.getScalarType(ctx, .bool);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ mask, pred });
            state.addTypes(&.{bool_type});

            const op = try builder.create(state);
            errdefer op.erase();
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
            .mnemonic = "any_sync",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
            .operands = .{ "mask", "predicate" },
            .results = .{"result"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, mask: *ir.Value, pred: *ir.Value) !AnySyncOp {
            const arith = dialects.arith;
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const bool_type = try arith.ArithDialect.getScalarType(ctx, .bool);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ mask, pred });
            state.addTypes(&.{bool_type});

            const op = try builder.create(state);
            errdefer op.erase();
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
            .mnemonic = "ballot_sync",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
            .operands = .{ "mask", "predicate" },
            .results = .{"result"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, mask: *ir.Value, pred: *ir.Value) !BallotSyncOp {
            const arith = dialects.arith;
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const i32_type = try arith.ArithDialect.getI32Type(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ mask, pred });
            state.addTypes(&.{i32_type});

            const op = try builder.create(state);
            errdefer op.erase();
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

    pub const WarpReduceOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "warp_reduce",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
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
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ mask, value });
            state.addTypes(&.{value.type});

            const op = try builder.create(state);
            errdefer op.erase();
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

    pub const WarpScanOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "warp_scan",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
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
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ mask, value });
            state.addTypes(&.{value.type});

            const op = try builder.create(state);
            errdefer op.erase();
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

    pub const MatchAnyOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "match_any",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
            .operands = .{"value"},
            .results = .{"mask"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, value: *ir.Value) !MatchAnyOp {
            const arith = dialects.arith;
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const i32_type = try arith.ArithDialect.getI32Type(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{value});
            state.addTypes(&.{i32_type});

            const op = try builder.create(state);
            errdefer op.erase();
            return .{ .op = op };
        }

        pub fn getResult(self: *const MatchAnyOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getValue(self: MatchAnyOp) *ir.Value {
            return self.op.operands.items[0].value;
        }
    };

    pub const MatchAllOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "match_all",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
            .operands = .{"value"},
            .results = .{ "mask", "all_equal" },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, value: *ir.Value) !MatchAllOp {
            const arith = dialects.arith;
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const i32_type = try arith.ArithDialect.getI32Type(ctx);
            const bool_type = try arith.ArithDialect.getScalarType(ctx, .bool);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{value});
            state.addTypes(&.{ i32_type, bool_type });

            const op = try builder.create(state);
            errdefer op.erase();
            return .{ .op = op };
        }

        pub fn getMaskResult(self: *const MatchAllOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getAllEqualResult(self: *const MatchAllOp) *ir.Value {
            return self.op.getResult(1).?;
        }

        pub fn getValue(self: MatchAllOp) *ir.Value {
            return self.op.operands.items[0].value;
        }
    };

    pub const ActiveMaskOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "active_mask",
            .interfaces = &.{gpuEffects(.state_observe, &.{}, &.{})},
            .operands = 0,
            .results = .{"mask"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !ActiveMaskOp {
            const arith = dialects.arith;
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const i32_type = try arith.ArithDialect.getI32Type(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addTypes(&.{i32_type});

            const op = try builder.create(state);
            errdefer op.erase();
            return .{ .op = op };
        }

        pub fn getResult(self: *const ActiveMaskOp) *ir.Value {
            return self.op.getResult(0).?;
        }
    };

    pub const SyncWarpOp = struct {
        op: *ir.Operation,

        pub const operation_spec = noResultSpec("sync_warp", .{"mask"});
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, mask: *ir.Value) !SyncWarpOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{mask});

            const op = try builder.create(state);
            errdefer op.erase();
            return .{ .op = op };
        }

        pub fn getMask(self: SyncWarpOp) *ir.Value {
            return self.op.operands.items[0].value;
        }
    };

    pub const mma_sync_a_count = 4;
    pub const mma_sync_b_count = 2;
    pub const mma_sync_acc_count = 4;

    pub const MmaSyncOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "mma_sync",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
            .operands = .{ "a0", "a1", "a2", "a3", "b0", "b1", "c0", "c1", "c2", "c3" },
            .results = .{ "d0", "d1", "d2", "d3" },
            .required_attrs = &.{"shape"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            a: [mma_sync_a_count]*ir.Value,
            b: [mma_sync_b_count]*ir.Value,
            c: [mma_sync_acc_count]*ir.Value,
            shape: MmaShape,
        ) !MmaSyncOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ a[0], a[1], a[2], a[3], b[0], b[1], c[0], c[1], c[2], c[3] });
            state.addTypes(&.{ c[0].type, c[1].type, c[2].type, c[3].type });

            const op = try builder.create(state);
            errdefer op.erase();
            try setMmaShapeAttr(op, ctx, shape);
            return .{ .op = op };
        }

        pub fn getA(self: MmaSyncOp, index: usize) *ir.Value {
            return self.op.operands.items[index].value;
        }

        pub fn getB(self: MmaSyncOp, index: usize) *ir.Value {
            return self.op.operands.items[mma_sync_a_count + index].value;
        }

        pub fn getC(self: MmaSyncOp, index: usize) *ir.Value {
            return self.op.operands.items[mma_sync_a_count + mma_sync_b_count + index].value;
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
            .mnemonic = "cp_async_shared",
            .interfaces = &.{gpuEffects(.launch, &.{2}, &.{0})},
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
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ dst, dst_index, src, src_index });
            const op = try builder.create(state);
            errdefer op.erase();
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

    pub const CpAsyncCommitOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "cp_async_commit",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
            .operands = 0,
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !CpAsyncCommitOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const state = ir.Operation.State.initStatic(operation_name, loc);
            const op = try builder.create(state);
            errdefer op.erase();
            return .{ .op = op };
        }
    };

    pub const CpAsyncWaitOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "cp_async_wait",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
            .operands = 0,
            .results = 0,
            .required_attrs = &.{"groups"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, groups: u32) !CpAsyncWaitOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const state = ir.Operation.State.initStatic(operation_name, loc);
            const op = try builder.create(state);
            errdefer op.erase();
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

    pub const AtomicLoadOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "atomic_load",
            .interfaces = &.{gpuEffects(.synchronize, &.{0}, &.{})},
            .operands = .{ "memref", "index" },
            .results = .{"value"},
            .required_attrs = &.{"ordering"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            memref: *ir.Value,
            index: *ir.Value,
            result_type: ir.Type,
            ordering: MemoryOrder,
        ) !AtomicLoadOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ memref, index });
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            errdefer op.erase();
            try setOrderingAttr(op, ctx, ordering);
            return .{ .op = op };
        }

        pub fn getResult(self: *const AtomicLoadOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getMemref(self: AtomicLoadOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getIndex(self: AtomicLoadOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getOrdering(self: AtomicLoadOp) ?MemoryOrder {
            return getOrderingAttr(self.op);
        }
    };

    pub const AtomicStoreOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "atomic_store",
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{1})},
            .operands = .{ "value", "memref", "index" },
            .results = 0,
            .required_attrs = &.{"ordering"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            value: *ir.Value,
            memref: *ir.Value,
            index: *ir.Value,
            ordering: MemoryOrder,
        ) !AtomicStoreOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ value, memref, index });

            const op = try builder.create(state);
            errdefer op.erase();
            try setOrderingAttr(op, ctx, ordering);
            return .{ .op = op };
        }

        pub fn getValue(self: AtomicStoreOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getMemref(self: AtomicStoreOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getIndex(self: AtomicStoreOp) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getOrdering(self: AtomicStoreOp) ?MemoryOrder {
            return getOrderingAttr(self.op);
        }
    };

    pub const AtomicAddOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "atomic_add",
            .interfaces = &.{gpuEffects(.synchronize, &.{0}, &.{0})},
            .operands = .{ "memref", "index", "value" },
            .results = .{"old_value"},
            .attrs = &.{"scope"},
            .required_attrs = &.{"ordering"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            memref: *ir.Value,
            index: *ir.Value,
            val: *ir.Value,
            ordering: MemoryOrder,
            scope: ?Scope,
        ) !AtomicAddOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ memref, index, val });
            state.addTypes(&.{val.type});

            const op = try builder.create(state);
            errdefer op.erase();
            try setOrderingAttr(op, ctx, ordering);
            if (scope) |scope_value| {
                try setScopeAttr(op, ctx, scope_value);
            }
            return .{ .op = op };
        }

        pub fn getResult(self: *const AtomicAddOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getMemref(self: AtomicAddOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getIndex(self: AtomicAddOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getVal(self: AtomicAddOp) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getOrdering(self: AtomicAddOp) ?MemoryOrder {
            return getOrderingAttr(self.op);
        }

        pub fn getScope(self: AtomicAddOp) ?Scope {
            return getScopeAttr(self.op);
        }
    };

    pub const AtomicMaxOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "atomic_max",
            .interfaces = &.{gpuEffects(.synchronize, &.{0}, &.{0})},
            .operands = .{ "memref", "index", "value" },
            .results = .{"old_value"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            memref: *ir.Value,
            index: *ir.Value,
            val: *ir.Value,
        ) !AtomicMaxOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ memref, index, val });
            state.addTypes(&.{val.type});

            const op = try builder.create(state);
            errdefer op.erase();
            return .{ .op = op };
        }

        pub fn getResult(self: *const AtomicMaxOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getMemref(self: AtomicMaxOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getIndex(self: AtomicMaxOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getVal(self: AtomicMaxOp) *ir.Value {
            return self.op.operands.items[2].value;
        }
    };

    pub const AtomicCasOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "atomic_cas",
            .interfaces = &.{gpuEffects(.synchronize, &.{0}, &.{0})},
            .operands = .{ "memref", "index", "expected", "desired" },
            .results = .{"old_value"},
            .attrs = &.{"scope"},
            .required_attrs = &.{"ordering"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            memref: *ir.Value,
            index: *ir.Value,
            expected: *ir.Value,
            desired: *ir.Value,
            ordering: MemoryOrder,
            scope: ?Scope,
        ) !AtomicCasOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addOperands(&.{ memref, index, expected, desired });
            state.addTypes(&.{expected.type});

            const op = try builder.create(state);
            errdefer op.erase();
            try setOrderingAttr(op, ctx, ordering);
            if (scope) |scope_value| {
                try setScopeAttr(op, ctx, scope_value);
            }
            return .{ .op = op };
        }

        pub fn getResult(self: *const AtomicCasOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getMemref(self: AtomicCasOp) *ir.Value {
            return self.op.operands.items[0].value;
        }

        pub fn getIndex(self: AtomicCasOp) *ir.Value {
            return self.op.operands.items[1].value;
        }

        pub fn getExpected(self: AtomicCasOp) *ir.Value {
            return self.op.operands.items[2].value;
        }

        pub fn getDesired(self: AtomicCasOp) *ir.Value {
            return self.op.operands.items[3].value;
        }

        pub fn getOrdering(self: AtomicCasOp) ?MemoryOrder {
            return getOrderingAttr(self.op);
        }

        pub fn getScope(self: AtomicCasOp) ?Scope {
            return getScopeAttr(self.op);
        }
    };

    fn loadSpec(ctx: *ir.Context) !void {
        try ir.dialects.loadDialectSpec(ctx, spec);
    }

    fn dimIndexSpec(comptime mnemonic: []const u8) ir.dialects.OperationSpec {
        return op_specs.leaf(.{
            .mnemonic = mnemonic,
            .interfaces = &.{gpuEffects(.state_observe, &.{}, &.{})},
            .operands = 0,
            .results = .{"index"},
            .required_attrs = &.{"dim"},
        });
    }

    fn indexSpec(comptime mnemonic: []const u8) ir.dialects.OperationSpec {
        return op_specs.leaf(.{
            .mnemonic = mnemonic,
            .interfaces = &.{gpuEffects(.state_observe, &.{}, &.{})},
            .operands = 0,
            .results = .{"index"},
        });
    }

    fn noResultSpec(comptime mnemonic: []const u8, comptime operands: anytype) ir.dialects.OperationSpec {
        return op_specs.leaf(.{
            .mnemonic = mnemonic,
            .interfaces = &.{gpuEffects(.synchronize, &.{}, &.{})},
            .operands = operands,
            .results = 0,
        });
    }

    fn getFuncSymbolName(op_ptr: *const anyopaque) ?[]const u8 {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (op.getAttr("sym_name")) |attr| {
            return func.FuncDialect.getSymNameValue(attr);
        }
        return null;
    }

    fn setFuncSymbolName(op_ptr: *const anyopaque, symbol_name: []const u8) anyerror!void {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        try op.setAttr("sym_name", try func.FuncDialect.getSymNameAttr(op.getContext(), symbol_name));
    }

    fn isFuncDeclaration(_: *const anyopaque) bool {
        return false;
    }

    pub fn getTmaDescriptorType(ctx: *ir.Context) !ir.Type {
        try loadSpec(ctx);
        return ctx.getDialectTypeFromName(type_names.tma_desc);
    }

    pub fn getMBarrierType(ctx: *ir.Context) !ir.Type {
        try loadSpec(ctx);
        return ctx.getDialectTypeFromName(type_names.mbarrier);
    }

    fn setDimensionAttr(op: *ir.Operation, ctx: *ir.Context, dim: Dimension) !void {
        const dim_attr = try ctx.getDialectAttr("gpu.dim", dim.toString());
        try op.setAttr("dim", dim_attr);
    }

    fn getDimensionAttr(op: *const ir.Operation) ?Dimension {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "dim") orelse return null;
        return Dimension.fromString(dialect_attr.payload);
    }

    fn setScopeAttr(op: *ir.Operation, ctx: *ir.Context, scope: Scope) !void {
        const scope_attr = try ctx.getDialectAttr("gpu.scope", scope.toString());
        try op.setAttr("scope", scope_attr);
    }

    fn getScopeAttr(op: *const ir.Operation) ?Scope {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "scope") orelse return null;
        return Scope.fromString(dialect_attr.payload);
    }

    fn setOrderingAttr(op: *ir.Operation, ctx: *ir.Context, ordering: MemoryOrder) !void {
        const order_attr = try ctx.getDialectAttr("gpu.ordering", ordering.toString());
        try op.setAttr("ordering", order_attr);
    }

    fn getOrderingAttr(op: *const ir.Operation) ?MemoryOrder {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "ordering") orelse return null;
        return MemoryOrder.fromString(dialect_attr.payload);
    }

    fn setBoolAttr(op: *ir.Operation, ctx: *ir.Context, attr_name: []const u8, value: bool) !void {
        const bool_attr = try ctx.getBoolAttr(value);
        try op.setAttr(attr_name, bool_attr);
    }

    fn getBoolAttrValue(op: *const ir.Operation, attr_name: []const u8) bool {
        const bool_attr = op.getAttrAs(ir.Attribute.BoolAttr, attr_name) orelse return false;
        return bool_attr.getValue();
    }

    fn setI64Attr(op: *ir.Operation, ctx: *ir.Context, attr_name: []const u8, value: i64) !void {
        const int_attr = try ctx.getI64Attr(value);
        try op.setAttr(attr_name, int_attr);
    }

    fn getI64AttrValue(op: *const ir.Operation, attr_name: []const u8) ?i64 {
        const int_attr = op.getAttrAs(ir.Attribute.IntegerAttr, attr_name) orelse return null;
        return int_attr.getValue();
    }

    fn setWarpOpAttr(op: *ir.Operation, ctx: *ir.Context, op_kind: WarpOpKind) !void {
        const op_attr = try ctx.getDialectAttr("gpu.warp_op", op_kind.toString());
        try op.setAttr("op", op_attr);
    }

    fn getWarpOpAttr(op: *const ir.Operation) ?WarpOpKind {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "op") orelse return null;
        return WarpOpKind.fromString(dialect_attr.payload);
    }

    fn setMmaShapeAttr(op: *ir.Operation, ctx: *ir.Context, shape: MmaShape) !void {
        var buf: [32]u8 = undefined;
        const shape_str = try shape.toString(buf[0..]);
        const shape_attr = try ctx.getDialectAttr("gpu.mma_shape", shape_str);
        try op.setAttr("shape", shape_attr);
    }

    fn getMmaShapeAttr(op: *const ir.Operation) ?MmaShape {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "shape") orelse return null;
        return MmaShape.parse(dialect_attr.payload);
    }
};

const GpuFactoryResourceCounts = struct {
    operations: usize,

    fn capture(ctx: *const ir.Context) GpuFactoryResourceCounts {
        return .{
            .operations = ctx.operationCount(),
        };
    }

    fn expectEqual(self: GpuFactoryResourceCounts, ctx: *const ir.Context) !void {
        try std.testing.expectEqual(self.operations, ctx.operationCount());
    }
};

fn checkGpuFactoryAllocationFailures(allocator: std.mem.Allocator) !void {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const arith = dialects.arith.ArithDialect;
    const loc = ir.Location.getUnknown();
    const i32_type = try arith.getScalarType(&ctx, .i32);
    const f32_type = try arith.getScalarType(&ctx, .f32);
    const index_type = try arith.getIndexType(&ctx);
    var source_builder = ir.OperationBuilder.init(&ctx);
    var source_state = ir.Operation.State.init("test.gpu_factory_source", loc);
    source_state.addTypes(&.{
        i32_type,
        f32_type,
        index_type,
        f32_type,
        f32_type,
        f32_type,
        f32_type,
        f32_type,
        f32_type,
        f32_type,
        f32_type,
        f32_type,
        f32_type,
    });
    const source = try source_builder.create(source_state);
    defer source.erase();
    const baseline = GpuFactoryResourceCounts.capture(&ctx);
    defer baseline.expectEqual(&ctx) catch unreachable;

    const module = try GpuDialect.ModuleOp.create(&ctx, loc);
    defer module.op.erase();
    const function = try GpuDialect.FuncOp.createKernel(&ctx, loc, "gpu_factory_kernel", &.{f32_type});
    defer function.op.erase();
    const launch = try GpuDialect.LaunchOp.create(
        &ctx,
        loc,
        "gpu_factory_kernel",
        &.{source.getResult(1).?},
        .{ 1, 1, 1 },
        .{ 32, 1, 1 },
    );
    defer launch.op.erase();
    const thread = try GpuDialect.ThreadIdxOp.create(&ctx, loc, .x);
    defer thread.op.erase();
    const block = try GpuDialect.BlockIdxOp.create(&ctx, loc, .y);
    defer block.op.erase();
    const block_dim = try GpuDialect.BlockDimOp.create(&ctx, loc, .z);
    defer block_dim.op.erase();
    const grid_dim = try GpuDialect.GridDimOp.create(&ctx, loc, .x);
    defer grid_dim.op.erase();
    const global = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .y);
    defer global.op.erase();
    const barrier = try GpuDialect.BarrierOp.create(&ctx, loc, .block);
    defer barrier.op.erase();
    const fence = try GpuDialect.FenceOp.create(&ctx, loc, .device, .seq_cst);
    defer fence.op.erase();
    const memcpy = try GpuDialect.MemcpyAsyncOp.create(
        &ctx,
        loc,
        source.getResult(1).?,
        source.getResult(3).?,
        source.getResult(2).?,
        null,
        null,
    );
    defer memcpy.op.erase();
    const tma_wait = try GpuDialect.TmaWaitGroupOp.create(&ctx, loc, 2);
    defer tma_wait.op.erase();
    const shuffle = try GpuDialect.ShflSyncOp.create(
        &ctx,
        loc,
        .down,
        source.getResult(0).?,
        source.getResult(1).?,
        source.getResult(2).?,
    );
    defer shuffle.op.erase();
    const warp_reduce = try GpuDialect.WarpReduceOp.create(
        &ctx,
        loc,
        .add,
        source.getResult(0).?,
        source.getResult(1).?,
    );
    defer warp_reduce.op.erase();
    const warp_scan = try GpuDialect.WarpScanOp.create(
        &ctx,
        loc,
        .add,
        true,
        source.getResult(0).?,
        source.getResult(1).?,
    );
    defer warp_scan.op.erase();
    const mma = try GpuDialect.MmaSyncOp.create(&ctx, loc, .{
        source.getResult(3).?,
        source.getResult(4).?,
        source.getResult(5).?,
        source.getResult(6).?,
    }, .{
        source.getResult(7).?,
        source.getResult(8).?,
    }, .{
        source.getResult(9).?,
        source.getResult(10).?,
        source.getResult(11).?,
        source.getResult(12).?,
    }, .{ .m = 16, .n = 8, .k = 8 });
    defer mma.op.erase();
    const async_copy = try GpuDialect.CpAsyncSharedOp.create(
        &ctx,
        loc,
        source.getResult(1).?,
        source.getResult(2).?,
        source.getResult(3).?,
        source.getResult(2).?,
        16,
    );
    defer async_copy.op.erase();
    const async_wait = try GpuDialect.CpAsyncWaitOp.create(&ctx, loc, 1);
    defer async_wait.op.erase();
    const atomic_load = try GpuDialect.AtomicLoadOp.create(
        &ctx,
        loc,
        source.getResult(1).?,
        source.getResult(2).?,
        f32_type,
        .acquire,
    );
    defer atomic_load.op.erase();
    const atomic_store = try GpuDialect.AtomicStoreOp.create(
        &ctx,
        loc,
        source.getResult(3).?,
        source.getResult(1).?,
        source.getResult(2).?,
        .release,
    );
    defer atomic_store.op.erase();
    const atomic_add = try GpuDialect.AtomicAddOp.create(
        &ctx,
        loc,
        source.getResult(1).?,
        source.getResult(2).?,
        source.getResult(3).?,
        .relaxed,
        .block,
    );
    defer atomic_add.op.erase();
    const atomic_cas = try GpuDialect.AtomicCasOp.create(
        &ctx,
        loc,
        source.getResult(1).?,
        source.getResult(2).?,
        source.getResult(3).?,
        source.getResult(4).?,
        .seq_cst,
        .device,
    );
    defer atomic_cas.op.erase();
}

fn gpuEffects(
    comptime kind: effects.EventKind,
    comptime reads: []const usize,
    comptime writes: []const usize,
) interfaces.InterfaceEntry {
    const Declaration = struct {
        fn enumerate(subject: effects.EffectSubject, collector: *effects.Collector) void {
            var resource = effects.Resource{};
            if (subject.attrAs(ir.Attribute.DialectAttr, "scope")) |scope| {
                if (scope.payload.len > 0) resource.ordering_scope = .{ .named = scope.payload };
            }
            if (kind == .state_observe) resource.state_key = "gpu.participants";
            collector.append(.{ .event = .{
                .kind = kind,
                .resource = resource,
                .ordered = true,
            } });
            collector.append(.{ .requirement = .{
                .kind = .execution_context,
                .subject = .operation,
            } });
            if (kind == .synchronize) collector.append(.{ .event = .{ .kind = .diverge } });
            for (reads) |index| {
                if (index >= subject.operandCount()) continue;
                var access = resource;
                access.subject = .{ .operand = index };
                collector.append(.{ .event = .{
                    .kind = .read,
                    .resource = access,
                    .ordered = true,
                } });
            }
            for (writes) |index| {
                if (index >= subject.operandCount()) continue;
                var access = resource;
                access.subject = .{ .operand = index };
                collector.append(.{ .event = .{
                    .kind = .write,
                    .resource = access,
                    .ordered = true,
                } });
            }
            for (0..subject.resultCount()) |index| {
                collector.append(.{ .result = .{ .index = index } });
            }
        }
    };
    return effects.EffectOpInterface.entryFor(.{
        .capacity = .{ .entries = 3 + reads.len + writes.len, .per_result = 1 },
        .enumerate = Declaration.enumerate,
    });
}
