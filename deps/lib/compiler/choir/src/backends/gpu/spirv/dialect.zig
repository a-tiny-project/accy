const std = @import("std");
const choir = @import("../../../root.zig");

const ir = choir.ir;
const arith = choir.dialects.arith;
const gpu = @import("../../../dialects/gpu/root.zig");

const Dimension = gpu.Dimension;
const Scope = gpu.Scope;
const ShuffleMode = gpu.ShuffleMode;
const WarpOpKind = gpu.WarpOpKind;

pub const Capability = enum {
    shader,

    pub fn toString(self: Capability) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?Capability {
        if (std.mem.eql(u8, s, "shader")) return .shader;
        return null;
    }
};

pub const AddressingModel = enum {
    logical,

    pub fn toString(self: AddressingModel) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?AddressingModel {
        if (std.mem.eql(u8, s, "logical")) return .logical;
        return null;
    }
};

pub const MemoryModel = enum {
    glsl450,

    pub fn toString(self: MemoryModel) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?MemoryModel {
        if (std.mem.eql(u8, s, "glsl450")) return .glsl450;
        return null;
    }
};

pub const ExecutionModel = enum {
    vertex,
    fragment,
    gl_compute,

    pub fn toString(self: ExecutionModel) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?ExecutionModel {
        if (std.mem.eql(u8, s, "vertex")) return .vertex;
        if (std.mem.eql(u8, s, "fragment")) return .fragment;
        if (std.mem.eql(u8, s, "gl_compute")) return .gl_compute;
        return null;
    }
};

pub const StorageClass = enum {
    function,
    private,
    workgroup,
    uniform,
    storage_buffer,
    input,
    output,

    pub fn toString(self: StorageClass) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?StorageClass {
        inline for (
            @typeInfo(StorageClass).@"enum".field_names,
            @typeInfo(StorageClass).@"enum".field_values,
        ) |field_name, field_name_value| {
            const field = .{ .name = field_name, .value = field_name_value };
            if (std.mem.eql(u8, s, field.name)) {
                return @fromBackingInt(@intCast(field.value));
            }
        }
        return null;
    }
};

pub const SpirvDialect = struct {
    pub const name = "spirv";
    const symbol_table_trait = ir.dialects.trait(ir.traits.SymbolTable);
    const op_specs = ir.dialects.opSpec.dialect(@This());
    pub const spec = ir.dialects.dialectSpec(@This(), .{
        .dialect_attributes = &.{
            "choir.string",       "spirv.capability",      "spirv.addressing_model",
            "spirv.memory_model", "spirv.execution_model", "spirv.storage_class",
            "spirv.ext_inst",     "spirv.dim",             "spirv.scope",
            "spirv.warp_op",      "spirv.shuffle_mode",
        },
    });

    const func_symbol_vtable = ir.interfaces.SymbolOpInterface.VTable{
        .getSymbolName = getFuncSymbolName,
        .setSymbolName = setFuncSymbolName,
        .isDeclaration = isFuncDeclaration,
    };

    pub const ModuleOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "module",
            .required_attrs = &.{ "addressing_model", "capability", "ext_inst", "memory_model" },
            .dynamic_traits = &.{symbol_table_trait},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            addressing_model: AddressingModel,
            memory_model: MemoryModel,
            capability: Capability,
            ext_inst: []const u8,
        ) !ModuleOp {
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

            try setAddressingModelAttr(op, ctx, addressing_model);
            try setMemoryModelAttr(op, ctx, memory_model);
            try setCapabilityAttr(op, ctx, capability);
            try setExtInstAttr(op, ctx, ext_inst);

            return .{ .op = op };
        }

        pub fn getBody(self: ModuleOp) *ir.Region {
            return self.op.getRegion(0).?;
        }

        pub fn getBodyBlock(self: ModuleOp) *ir.Block {
            return self.getBody().getEntryBlock().?;
        }

        pub fn getAddressingModel(self: ModuleOp) ?AddressingModel {
            return getAddressingModelAttr(self.op);
        }

        pub fn getMemoryModel(self: ModuleOp) ?MemoryModel {
            return getMemoryModelAttr(self.op);
        }

        pub fn getCapability(self: ModuleOp) ?Capability {
            return getCapabilityAttr(self.op);
        }

        pub fn getExtInst(self: ModuleOp) ?[]const u8 {
            return getExtInstAttr(self.op);
        }
    };

    pub const FuncOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "func",
            .attrs = &.{ "entry_point", "execution_model", "sym_name", ir.SymbolTable.symbol_attr_names.sym_visibility },
            .required_attrs = &.{"sym_name"},
            .interfaces = &.{
                ir.interfaces.SymbolOpInterface.entry(&func_symbol_vtable),
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

            const name_attr = try ctx.getDialectAttr("choir.string", func_name);
            try op.setAttr("sym_name", name_attr);

            return .{ .op = op };
        }

        pub fn setEntryPoint(self: *FuncOp, ctx: *ir.Context, model: ExecutionModel) !void {
            const entry_attr = try ctx.getBoolAttr(true);
            try self.op.setAttr("entry_point", entry_attr);
            try setExecutionModelAttr(self.op, ctx, model);
        }

        pub fn isEntryPoint(self: *const FuncOp) bool {
            const bool_attr = self.op.getAttrAs(ir.Attribute.BoolAttr, "entry_point") orelse return false;
            return bool_attr.getValue();
        }

        pub fn getExecutionModel(self: *const FuncOp) ?ExecutionModel {
            return getExecutionModelAttr(self.op);
        }

        pub fn getBody(self: FuncOp) *ir.Region {
            return self.op.getRegion(0).?;
        }

        pub fn getEntryBlock(self: FuncOp) *ir.Block {
            return self.getBody().getEntryBlock().?;
        }
    };

    pub const ConstantOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "constant",
            .required_attrs = &.{"value"},
        });
        pub const operation_name = operation_spec.name;

        pub fn createInt(ctx: *ir.Context, loc: ir.Location, result_type: ir.Type, value: i64) !ConstantOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            const value_attr = try ctx.getI64Attr(value);
            try op.setAttr("value", value_attr);

            return .{ .op = op };
        }

        pub fn createFloat(ctx: *ir.Context, loc: ir.Location, result_type: ir.Type, value: f64) !ConstantOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            const value_attr = try ctx.getF64Attr(value);
            try op.setAttr("value", value_attr);

            return .{ .op = op };
        }

        pub fn createBool(ctx: *ir.Context, loc: ir.Location, result_type: ir.Type, value: bool) !ConstantOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            const value_attr = try ctx.getBoolAttr(value);
            try op.setAttr("value", value_attr);

            return .{ .op = op };
        }

        pub fn getResult(self: *const ConstantOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getIntValue(self: ConstantOp) ?i64 {
            const int_attr = self.op.getAttrAs(ir.Attribute.IntegerAttr, "value") orelse return null;
            return int_attr.getValue();
        }

        pub fn getFloatValue(self: ConstantOp) ?f64 {
            const float_attr = self.op.getAttrAs(ir.Attribute.FloatAttr, "value") orelse return null;
            return float_attr.getValue();
        }

        pub fn getBoolValue(self: ConstantOp) ?bool {
            const bool_attr = self.op.getAttrAs(ir.Attribute.BoolAttr, "value") orelse return null;
            return bool_attr.getValue();
        }
    };

    pub const VariableOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "variable",
            .required_attrs = &.{"storage_class"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            result_type: ir.Type,
            storage_class: StorageClass,
            initializer: ?*ir.Value,
        ) !VariableOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
            if (initializer) |init| {
                state.addOperands(&.{init});
            }
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            try setStorageClassAttr(op, ctx, storage_class);
            return .{ .op = op };
        }

        pub fn getResult(self: *const VariableOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getInitializer(self: *const VariableOp) ?*ir.Value {
            if (self.op.operands.items.len > 0) {
                return self.op.operands.items[0].value;
            }
            return null;
        }

        pub fn getStorageClass(self: *const VariableOp) ?StorageClass {
            return getStorageClassAttr(self.op);
        }
    };

    pub const LocalInvocationIdOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "local_invocation_id",
            .required_attrs = &.{"dim"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !LocalInvocationIdOp {
            const op = try createIndexOp(ctx, loc, dim, operation_name);
            return .{ .op = op };
        }

        pub fn getResult(self: *const LocalInvocationIdOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getDimension(self: LocalInvocationIdOp) ?Dimension {
            return getDimensionAttr(self.op);
        }
    };

    pub const WorkgroupIdOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "workgroup_id",
            .required_attrs = &.{"dim"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !WorkgroupIdOp {
            const op = try createIndexOp(ctx, loc, dim, operation_name);
            return .{ .op = op };
        }

        pub fn getResult(self: *const WorkgroupIdOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getDimension(self: WorkgroupIdOp) ?Dimension {
            return getDimensionAttr(self.op);
        }
    };

    pub const WorkgroupSizeOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "workgroup_size",
            .required_attrs = &.{"dim"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !WorkgroupSizeOp {
            const op = try createIndexOp(ctx, loc, dim, operation_name);
            return .{ .op = op };
        }

        pub fn getResult(self: *const WorkgroupSizeOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getDimension(self: WorkgroupSizeOp) ?Dimension {
            return getDimensionAttr(self.op);
        }
    };

    pub const NumWorkgroupsOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "num_workgroups",
            .required_attrs = &.{"dim"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !NumWorkgroupsOp {
            const op = try createIndexOp(ctx, loc, dim, operation_name);
            return .{ .op = op };
        }

        pub fn getResult(self: *const NumWorkgroupsOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getDimension(self: NumWorkgroupsOp) ?Dimension {
            return getDimensionAttr(self.op);
        }
    };

    pub const GlobalInvocationIdOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "global_invocation_id",
            .required_attrs = &.{"dim"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, dim: Dimension) !GlobalInvocationIdOp {
            const op = try createIndexOp(ctx, loc, dim, operation_name);
            return .{ .op = op };
        }

        pub fn getResult(self: *const GlobalInvocationIdOp) *ir.Value {
            return self.op.getResult(0).?;
        }

        pub fn getDimension(self: GlobalInvocationIdOp) ?Dimension {
            return getDimensionAttr(self.op);
        }
    };

    pub const BarrierOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "control_barrier",
            .required_attrs = &.{"scope"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, scope: Scope) !BarrierOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const state = ir.Operation.State.initStatic(operation_name, loc);

            const op = try builder.create(state);
            try setScopeAttr(op, ctx, scope);

            return .{ .op = op };
        }

        pub fn getScope(self: BarrierOp) ?Scope {
            return getScopeAttr(self.op);
        }
    };

    pub const SyncWarpOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{ .mnemonic = "sync_warp" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, mask: *ir.Value) !SyncWarpOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
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

        pub const operation_spec = op_specs.define(.{ .mnemonic = "active_mask" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !ActiveMaskOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const i32_type = try arith.ArithDialect.getI32Type(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
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

        pub const operation_spec = op_specs.define(.{ .mnemonic = "all_sync" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, mask: *ir.Value, pred: *ir.Value) !AllSyncOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const bool_type = try arith.ArithDialect.getScalarType(ctx, .bool);
            var state = ir.Operation.State.initStatic(operation_name, loc);
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

        pub const operation_spec = op_specs.define(.{ .mnemonic = "any_sync" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, mask: *ir.Value, pred: *ir.Value) !AnySyncOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const bool_type = try arith.ArithDialect.getScalarType(ctx, .bool);
            var state = ir.Operation.State.initStatic(operation_name, loc);
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

        pub const operation_spec = op_specs.define(.{ .mnemonic = "ballot_sync" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, mask: *ir.Value, pred: *ir.Value) !BallotSyncOp {
            try loadSpec(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            const i32_type = try arith.ArithDialect.getI32Type(ctx);
            var state = ir.Operation.State.initStatic(operation_name, loc);
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

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "shfl_sync",
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

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "warp_reduce",
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

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "warp_scan",
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

    pub const IAddOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{ .mnemonic = "iadd" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value) !IAddOp {
            const op = try createBinary(ctx, loc, lhs, rhs, operation_name);
            return .{ .op = op };
        }
    };

    pub const FAddOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{ .mnemonic = "fadd" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value) !FAddOp {
            const op = try createBinary(ctx, loc, lhs, rhs, operation_name);
            return .{ .op = op };
        }
    };

    pub const ISubOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{ .mnemonic = "isub" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value) !ISubOp {
            const op = try createBinary(ctx, loc, lhs, rhs, operation_name);
            return .{ .op = op };
        }
    };

    pub const FSubOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{ .mnemonic = "fsub" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value) !FSubOp {
            const op = try createBinary(ctx, loc, lhs, rhs, operation_name);
            return .{ .op = op };
        }
    };

    pub const IMulOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{ .mnemonic = "imul" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value) !IMulOp {
            const op = try createBinary(ctx, loc, lhs, rhs, operation_name);
            return .{ .op = op };
        }
    };

    pub const FMulOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{ .mnemonic = "fmul" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value) !FMulOp {
            const op = try createBinary(ctx, loc, lhs, rhs, operation_name);
            return .{ .op = op };
        }
    };

    pub const UDivOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{ .mnemonic = "udiv" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value) !UDivOp {
            const op = try createBinary(ctx, loc, lhs, rhs, operation_name);
            return .{ .op = op };
        }
    };

    pub const SDivOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{ .mnemonic = "sdiv" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value) !SDivOp {
            const op = try createBinary(ctx, loc, lhs, rhs, operation_name);
            return .{ .op = op };
        }
    };

    pub const FDivOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{ .mnemonic = "fdiv" });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, lhs: *ir.Value, rhs: *ir.Value) !FDivOp {
            const op = try createBinary(ctx, loc, lhs, rhs, operation_name);
            return .{ .op = op };
        }
    };

    fn loadSpec(ctx: *ir.Context) !void {
        ir.dialects.loadDialectSpec(ctx, spec) catch |err| switch (err) {
            error.ContextFrozen => {},
            else => return err,
        };
    }

    fn getFuncSymbolName(op_ptr: *const anyopaque) ?[]const u8 {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (op.getAttrAs(ir.Attribute.StringAttr, "sym_name")) |string_attr| {
            return string_attr.getValue();
        }
        const attr = op.getAttr("sym_name") orelse return null;
        if (std.mem.eql(u8, attr.abstract.name, "choir.string")) {
            const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
            return dialect_attr.payload;
        }
        return null;
    }

    fn setFuncSymbolName(op_ptr: *const anyopaque, symbol_name: []const u8) anyerror!void {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        try op.setAttr("sym_name", try op.getContext().getDialectAttr("choir.string", symbol_name));
    }

    fn isFuncDeclaration(_: *const anyopaque) bool {
        return false;
    }

    fn setCapabilityAttr(op: *ir.Operation, ctx: *ir.Context, capability: Capability) !void {
        const cap_attr = try ctx.getDialectAttr("spirv.capability", capability.toString());
        try op.setAttr("capability", cap_attr);
    }

    fn getCapabilityAttr(op: *const ir.Operation) ?Capability {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "capability") orelse return null;
        return Capability.fromString(dialect_attr.payload);
    }

    fn setAddressingModelAttr(op: *ir.Operation, ctx: *ir.Context, model: AddressingModel) !void {
        const model_attr = try ctx.getDialectAttr("spirv.addressing_model", model.toString());
        try op.setAttr("addressing_model", model_attr);
    }

    fn getAddressingModelAttr(op: *const ir.Operation) ?AddressingModel {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "addressing_model") orelse return null;
        return AddressingModel.fromString(dialect_attr.payload);
    }

    fn setMemoryModelAttr(op: *ir.Operation, ctx: *ir.Context, model: MemoryModel) !void {
        const model_attr = try ctx.getDialectAttr("spirv.memory_model", model.toString());
        try op.setAttr("memory_model", model_attr);
    }

    fn getMemoryModelAttr(op: *const ir.Operation) ?MemoryModel {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "memory_model") orelse return null;
        return MemoryModel.fromString(dialect_attr.payload);
    }

    fn setExecutionModelAttr(op: *ir.Operation, ctx: *ir.Context, model: ExecutionModel) !void {
        const model_attr = try ctx.getDialectAttr("spirv.execution_model", model.toString());
        try op.setAttr("execution_model", model_attr);
    }

    fn getExecutionModelAttr(op: *const ir.Operation) ?ExecutionModel {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "execution_model") orelse return null;
        return ExecutionModel.fromString(dialect_attr.payload);
    }

    fn setStorageClassAttr(op: *ir.Operation, ctx: *ir.Context, storage: StorageClass) !void {
        const storage_attr = try ctx.getDialectAttr("spirv.storage_class", storage.toString());
        try op.setAttr("storage_class", storage_attr);
    }

    fn getStorageClassAttr(op: *const ir.Operation) ?StorageClass {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "storage_class") orelse return null;
        return StorageClass.fromString(dialect_attr.payload);
    }

    fn setExtInstAttr(op: *ir.Operation, ctx: *ir.Context, ext_inst_name: []const u8) !void {
        const ext_attr = try ctx.getDialectAttr("spirv.ext_inst", ext_inst_name);
        try op.setAttr("ext_inst", ext_attr);
    }

    fn getExtInstAttr(op: *const ir.Operation) ?[]const u8 {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "ext_inst") orelse return null;
        return dialect_attr.payload;
    }

    fn setDimensionAttr(op: *ir.Operation, ctx: *ir.Context, dim: Dimension) !void {
        const dim_attr = try ctx.getDialectAttr("spirv.dim", dim.toString());
        try op.setAttr("dim", dim_attr);
    }

    fn getDimensionAttr(op: *const ir.Operation) ?Dimension {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "dim") orelse return null;
        return Dimension.fromString(dialect_attr.payload);
    }

    fn setScopeAttr(op: *ir.Operation, ctx: *ir.Context, scope: Scope) !void {
        const scope_attr = try ctx.getDialectAttr("spirv.scope", scope.toString());
        try op.setAttr("scope", scope_attr);
    }

    fn getScopeAttr(op: *const ir.Operation) ?Scope {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "scope") orelse return null;
        return Scope.fromString(dialect_attr.payload);
    }

    fn setWarpOpAttr(op: *ir.Operation, ctx: *ir.Context, op_kind: WarpOpKind) !void {
        const op_attr = try ctx.getDialectAttr("spirv.warp_op", op_kind.toString());
        try op.setAttr("op", op_attr);
    }

    fn getWarpOpAttr(op: *const ir.Operation) ?WarpOpKind {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "op") orelse return null;
        return WarpOpKind.fromString(dialect_attr.payload);
    }

    fn setShuffleModeAttr(op: *ir.Operation, ctx: *ir.Context, mode: ShuffleMode) !void {
        const mode_attr = try ctx.getDialectAttr("spirv.shuffle_mode", mode.toString());
        try op.setAttr("mode", mode_attr);
    }

    fn getShuffleModeAttr(op: *const ir.Operation) ?ShuffleMode {
        const dialect_attr = op.getAttrAs(ir.Attribute.DialectAttr, "mode") orelse return null;
        return ShuffleMode.fromString(dialect_attr.payload);
    }

    fn setBoolAttr(op: *ir.Operation, ctx: *ir.Context, attr_name: []const u8, value: bool) !void {
        const bool_attr = try ctx.getBoolAttr(value);
        try op.setAttr(attr_name, bool_attr);
    }

    fn getBoolAttrValue(op: *const ir.Operation, attr_name: []const u8) bool {
        const bool_attr = op.getAttrAs(ir.Attribute.BoolAttr, attr_name) orelse return false;
        return bool_attr.getValue();
    }

    fn createIndexOp(
        ctx: *ir.Context,
        loc: ir.Location,
        dim: Dimension,
        comptime op_name: []const u8,
    ) !*ir.Operation {
        try loadSpec(ctx);
        var builder = ir.OperationBuilder.init(ctx);
        const index_type = try arith.ArithDialect.getIndexType(ctx);
        var state = ir.Operation.State.init(op_name, loc);
        state.addTypes(&.{index_type});
        const op = try builder.create(state);
        try setDimensionAttr(op, ctx, dim);
        return op;
    }

    fn createBinary(
        ctx: *ir.Context,
        loc: ir.Location,
        lhs: *ir.Value,
        rhs: *ir.Value,
        comptime op_name: []const u8,
    ) !*ir.Operation {
        try loadSpec(ctx);
        var builder = ir.OperationBuilder.init(ctx);
        var state = ir.Operation.State.init(op_name, loc);
        state.addOperands(&.{ lhs, rhs });
        state.addTypes(&.{lhs.type});
        return builder.create(state);
    }
};
