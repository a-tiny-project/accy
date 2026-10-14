const std = @import("std");
const alloc_arena = @import("alloc_arena");
const ir = @import("../../core/root.zig");
const interfaces = @import("../../core/root.zig").interfaces;

const effects = ir.interfaces.effects;

const test_dialect_name = "test";
const test_unit_attr_name = "test.unit";
const test_bool_attr_name = "test.bool";
const test_int_attr_name = "test.int";
const test_string_attr_name = "test.string";
const test_type_attr_name = "test.type";

const test_i32_type_name = "test.i32";
const test_i64_type_name = "test.i64";
const test_f64_type_name = "test.f64";

fn attrPayload(attr: ir.Attribute, name: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, attr.abstract.name, name)) return null;
    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return null;
    return dialect_attr.payload;
}

pub const TestDialect = struct {
    pub const name = test_dialect_name;
    const op_specs = ir.dialects.opSpec.dialect(@This());
    pub const spec = ir.dialects.dialectSpec(@This(), .{
        .types = &.{
            ir.dialects.typeName(test_i32_type_name),
            ir.dialects.typeName(test_i64_type_name),
            ir.dialects.typeName(test_f64_type_name),
        },
    });

    const func_symbol_vtable = interfaces.SymbolOpInterface.VTable{
        .getSymbolName = getFuncSymbolName,
        .setSymbolName = setFuncSymbolName,
        .isDeclaration = isFuncDeclaration,
    };

    pub const ModuleOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "module",
            .operands = 0,
            .results = 0,
            .regions = 1,
            .successors = 0,
            .dynamic_traits = .{ ir.traits.SymbolTable, ir.traits.IsolatedFromAbove, ir.traits.NoTerminator, ir.traits.SingleBlock },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !ModuleOp {
            try registerTestDialect(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            var body = ir.context.initRegion(ctx);
            defer body.deinit();
            var body_builder = ir.OperationBuilder.init(ctx);
            _ = try body_builder.createBlock(&body, &.{}, &.{});
            var regions = [_]*ir.Region{&body};
            state.addRegionBodies(&regions);

            const op = try builder.create(state);

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
            .results = 0,
            .regions = 1,
            .successors = 0,
            .attrs = &.{ir.SymbolTable.symbol_attr_names.sym_visibility},
            .required_attrs = &.{"sym_name"},
            .interfaces = &.{
                interfaces.SymbolOpInterface.entry(&func_symbol_vtable),
                effects.EffectOpInterface.entryFor(.{
                    .facts = &.{.{ .region = .{
                        .index = 0,
                        .execution = .latent,
                        .may_diverge = false,
                        .captures = false,
                    } }},
                }),
            },
            .dynamic_traits = .{ir.traits.IsolatedFromAbove},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            func_name: []const u8,
            input_types: []const ir.Type,
        ) !FuncOp {
            try registerTestDialect(ctx);
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            var body = ir.context.initRegion(ctx);
            defer body.deinit();
            var body_builder = ir.OperationBuilder.init(ctx);
            _ = try body_builder.createBlockWithLoc(&body, input_types, loc);
            var regions = [_]*ir.Region{&body};
            state.addRegionBodies(&regions);

            const op = try builder.create(state);

            const name_attr = try getStringAttr(ctx, func_name);
            try op.setAttr("sym_name", name_attr);

            return .{ .op = op };
        }

        pub fn getName(self: FuncOp) ?[]const u8 {
            return ir.SymbolTable.getSymbolName(self.op);
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
    };

    pub const ConstantOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "constant",
            .interfaces = &.{effects.EffectOpInterface.entryFor(.{
                .capacity = .{ .per_result = 1 },
                .enumerate = constantEffects,
            })},
            .operands = 0,
            .results = .{"result"},
            .required_attrs = &.{"value"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            result_type: ir.Type,
            int_value: i64,
        ) !ConstantOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addTypes(&.{result_type});

            const op = try builder.create(state);
            const value_attr = try getIntegerAttr(ctx, int_value);
            try op.setAttr("value", value_attr);

            return .{ .op = op };
        }

        pub fn getResult(self: *const ConstantOp) *ir.Value {
            return ir.dialects.result(operation_spec, self.op, "result");
        }

        pub fn getValue(self: ConstantOp) ?i64 {
            if (self.op.getAttr("value")) |attr| {
                return getIntegerValue(attr);
            }
            return null;
        }
    };

    /// Consumes the next value of a global counter; every execution is distinct.
    pub const DrawOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "draw",
            .operands = 0,
            .results = 1,
            .interfaces = &.{effects.EffectOpInterface.entryFor(.{
                .complete = true,
                .facts = &.{
                    .{ .event = .{ .kind = .state_draw, .resource = .{
                        .subject = .{ .global = "fixture.draws" },
                        .state_key = "next",
                    } } },
                    .{ .result = .{ .index = 0, .ownership = .none } },
                },
            })},
        });
        pub const operation_name = operation_spec.name;
    };

    /// Consumes the next counter value at its explicit address.
    pub const AddressedDrawOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "addressed_draw",
            .operands = 1,
            .results = 1,
            .interfaces = &.{effects.EffectOpInterface.entryFor(.{
                .complete = true,
                .facts = &.{
                    .{ .event = .{ .kind = .state_draw, .resource = .{
                        .subject = .{ .operand = 0 },
                        .state_key = "next",
                    } } },
                    .{ .result = .{ .index = 0, .ownership = .none } },
                },
            })},
        });
        pub const operation_name = operation_spec.name;
    };

    /// Reads a permanent initialized i64 cell. The fixture cell contains seven;
    /// reading it cannot fail, consume state, acquire ownership or allocate.
    pub const SafeReadOp = struct {
        op: *ir.Operation,
        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "safe_read",
            .operands = 0,
            .results = 1,
            .result_types = &.{ir.dialects.typeConstraint.exact(0, test_i64_type_name)},
            .interfaces = &.{effects.EffectOpInterface.entryFor(.{
                .complete = true,
                .facts = &.{
                    .{ .event = .{ .kind = .read, .resource = .{
                        .subject = .{ .global = "fixture.permanent_cell" },
                        .lifetime = .{ .named = "process" },
                    } } },
                    .{ .result = .{ .index = 0, .ownership = .none } },
                },
            })},
        });
        pub const operation_name = operation_spec.name;
    };

    pub const IdentityOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "identity",
            .operands = .{"input"},
            .results = .{"result"},
        });
        pub const operation_name = operation_spec.name;
    };

    pub const UserOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "user",
            .operands = .{"input"},
            .results = 0,
        });
        pub const operation_name = operation_spec.name;
    };

    pub const BinaryOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "binary",
            .operands = .{ "lhs", "rhs" },
            .results = .{"result"},
            .interfaces = &.{
                interfaces.InferTypeOpInterface.entryFor(inferBinaryResultTypes),
            },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            lhs: *ir.Value,
            rhs: *ir.Value,
        ) !BinaryOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ lhs, rhs });
            state.addTypes(&.{lhs.type});

            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getResult(self: *const BinaryOp) *ir.Value {
            return ir.dialects.result(operation_spec, self.op, "result");
        }

        pub fn getLhs(self: BinaryOp) *ir.Value {
            return ir.dialects.operand(operation_spec, self.op, "lhs");
        }

        pub fn getRhs(self: BinaryOp) *ir.Value {
            return ir.dialects.operand(operation_spec, self.op, "rhs");
        }
    };

    pub const BranchOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.define(.{
            .mnemonic = "br",
            .operands = 0,
            .results = 0,
            .regions = 0,
            .successors = .{"target"},
            .interfaces = &.{
                interfaces.ControlFlowInterface.entryFor(getBranchSuccessorCount, getBranchSuccessor),
            },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, target: *ir.Block) !BranchOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addSuccessors(&.{target});
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getTarget(self: BranchOp) *ir.Block {
            return ir.dialects.successor(operation_spec, self.op, "target");
        }
    };

    pub const StoreOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "store",
            .operands = .{ "target", "value" },
            .results = 0,
            .interfaces = &.{
                effects.EffectOpInterface.entryFor(.{ .facts = &.{.{ .event = .{
                    .kind = .write,
                    .resource = .{ .subject = .{ .operand = 1 } },
                } }} }),
            },
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location, target: *ir.Value, value: *ir.Value) !StoreOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(&.{ target, value });
            const op = try builder.create(state);
            return .{ .op = op };
        }

        pub fn getTarget(self: StoreOp) *ir.Value {
            return ir.dialects.operand(operation_spec, self.op, "target");
        }

        pub fn getValue(self: StoreOp) *ir.Value {
            return ir.dialects.operand(operation_spec, self.op, "value");
        }
    };

    pub const ReturnOp = struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = "return",
            .results = 0,
        });
        pub const operation_name = operation_spec.name;

        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            operands: []const *ir.Value,
        ) !ReturnOp {
            var builder = ir.OperationBuilder.init(ctx);
            var state = op_specs.state(@This(), loc);
            state.addOperands(operands);
            const op = try builder.create(state);
            return .{ .op = op };
        }
    };

    pub fn getI32Type(ctx: *ir.Context) !ir.Type {
        try registerTestDialect(ctx);
        return ctx.getDialectTypeFromName(test_i32_type_name);
    }

    pub fn getI64Type(ctx: *ir.Context) !ir.Type {
        try registerTestDialect(ctx);
        return ctx.getDialectTypeFromName(test_i64_type_name);
    }

    pub fn getF64Type(ctx: *ir.Context) !ir.Type {
        try registerTestDialect(ctx);
        return ctx.getDialectTypeFromName(test_f64_type_name);
    }

    pub fn getUnitAttr(ctx: *ir.Context) !ir.Attribute {
        return ctx.getDialectAttr(test_unit_attr_name, "");
    }

    pub fn getBoolAttr(ctx: *ir.Context, value: bool) !ir.Attribute {
        const payload = [_]u8{if (value) 1 else 0};
        return ctx.getDialectAttr(test_bool_attr_name, &payload);
    }

    pub fn getBoolValue(attr: ir.Attribute) ?bool {
        const payload = attrPayload(attr, test_bool_attr_name) orelse return null;
        if (payload.len != 1) return null;
        return payload[0] != 0;
    }

    pub fn getIntegerAttr(ctx: *ir.Context, value: i64) !ir.Attribute {
        var buf: [32]u8 = undefined;
        const payload = try ir.format.intPayload(buf[0..], value);
        return ctx.getDialectAttr(test_int_attr_name, payload);
    }

    pub fn getIntegerValue(attr: ir.Attribute) ?i64 {
        const payload = attrPayload(attr, test_int_attr_name) orelse return null;
        return std.fmt.parseInt(i64, payload, 10) catch null;
    }

    pub fn getStringAttr(ctx: *ir.Context, value: []const u8) !ir.Attribute {
        return ctx.getDialectAttr(test_string_attr_name, value);
    }

    pub fn getStringValue(attr: ir.Attribute) ?[]const u8 {
        return attrPayload(attr, test_string_attr_name);
    }

    pub fn getTypeAttr(ctx: *ir.Context, typ: ir.Type) !ir.Attribute {
        var buf: [128]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, "{f}", .{typ});
        return ctx.getDialectAttr(test_type_attr_name, payload);
    }

    fn getFuncSymbolName(op_ptr: *const anyopaque) ?[]const u8 {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (op.getAttr("sym_name")) |attr| {
            return getStringValue(attr);
        }
        return null;
    }

    fn setFuncSymbolName(op_ptr: *const anyopaque, symbol_name: []const u8) anyerror!void {
        const op: *ir.Operation = @ptrCast(@alignCast(@constCast(op_ptr)));
        try op.setAttr("sym_name", try getStringAttr(op.getContext(), symbol_name));
    }

    fn isFuncDeclaration(_: *const anyopaque) bool {
        return false;
    }

    fn getBranchSuccessorCount(op_ptr: *const anyopaque) usize {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        return op.getNumSuccessors();
    }

    fn getBranchSuccessor(op_ptr: *const anyopaque, index: usize) ?*ir.Block {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        return op.getSuccessor(index);
    }

    fn inferBinaryResultTypes(
        op_ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        out_types: *std.ArrayListUnmanaged(ir.Type),
    ) anyerror!void {
        const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
        if (op.operands.items.len != 2) return error.InvalidOperandCount;
        const lhs_type = op.operands.items[0].value.type;
        const rhs_type = op.operands.items[1].value.type;
        if (!lhs_type.eql(rhs_type)) return error.OperandTypeMismatch;
        try out_types.append(allocator, lhs_type);
    }
};

fn loadTestDialect(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, TestDialect.spec);
}

pub fn registerTestDialect(ctx: *ir.Context) !void {
    ctx.registerDialectLoader(TestDialect.name, loadTestDialect) catch |err| switch (err) {
        error.DuplicateDialectLoader => {},
        else => return err,
    };
    _ = try ctx.getOrLoadDialect(TestDialect.name);
}

fn constantEffects(subject: effects.EffectSubject, collector: *effects.Collector) void {
    collector.valueResults(subject);
    if (subject.resultCount() != 1 or subject.operandCount() != 0) return;
    const value = subject.attr("value") orelse return;
    collector.complete = TestDialect.getIntegerValue(value) != null;
}
