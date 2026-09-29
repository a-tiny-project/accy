const std = @import("std");
const choir = @import("../../../../root.zig");

const ir = choir.ir;
const dialects = choir.dialects;
const spirv_target = @import("../root.zig");
const gpu = @import("gpu.zig");
const binary = @import("module.zig");
const scalar = @import("scalar.zig");
const spec = @import("spec.zig");
const spirv_ops = @import("ops.zig");

const FuncDialect = dialects.func.FuncDialect;
const SpirvDialect = spirv_target.SpirvDialect;
const SpirvExecutionModel = spirv_target.ExecutionModel;
const SpirvStorageClass = spirv_target.StorageClass;
const Section = binary.Section;
const SpirvOp = spirv_ops.SpirvOp;

pub fn functionName(op: *ir.Operation) ?[]const u8 {
    return ir.SymbolTable.getSymbolName(op);
}

fn storageClassToSpv(storage: SpirvStorageClass) u32 {
    return switch (storage) {
        .function => spec.StorageClass.Function,
        .private => spec.StorageClass.Private,
        .workgroup => spec.StorageClass.Workgroup,
        .uniform => spec.StorageClass.Uniform,
        .storage_buffer => spec.StorageClass.StorageBuffer,
        .input => spec.StorageClass.Input,
        .output => spec.StorageClass.Output,
    };
}

pub fn emitModuleWords(self: anytype, module: *ir.Operation) ![]u32 {
    if (!std.mem.eql(u8, module.name.name, SpirvDialect.ModuleOp.operation_name)) {
        return error.InvalidModule;
    }

    const spirv_module = SpirvDialect.ModuleOp{ .op = module };
    const addressing_model = spirv_module.getAddressingModel() orelse return error.MissingAttribute;
    const memory_model = spirv_module.getMemoryModel() orelse return error.MissingAttribute;
    const capability = spirv_module.getCapability() orelse return error.MissingAttribute;

    try self.requireCapability(switch (capability) {
        .shader => spec.Capability.Shader,
    });
    try self.builder.emitMemoryModel(
        switch (addressing_model) {
            .logical => spec.AddressingModel.Logical,
        },
        switch (memory_model) {
            .glsl450 => spec.MemoryModel.GLSL450,
        },
    );

    const region = module.getRegion(0) orelse return error.InvalidModule;
    const block = region.getEntryBlock() orelse return error.InvalidModule;

    var funcs: std.ArrayListUnmanaged(*ir.Operation) = .empty;
    var vars: std.ArrayListUnmanaged(*ir.Operation) = .empty;
    var consts: std.ArrayListUnmanaged(*ir.Operation) = .empty;
    defer funcs.deinit(self.allocator);
    defer vars.deinit(self.allocator);
    defer consts.deinit(self.allocator);

    var op_iter = block.operations.head;
    while (op_iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        const name = op.name.name;
        if (std.mem.eql(u8, name, SpirvDialect.FuncOp.operation_name)) {
            try funcs.append(self.allocator, op);
        } else if (std.mem.eql(u8, name, SpirvDialect.VariableOp.operation_name)) {
            try vars.append(self.allocator, op);
        } else if (std.mem.eql(u8, name, SpirvDialect.ConstantOp.operation_name)) {
            try consts.append(self.allocator, op);
        } else {
            return error.UnsupportedOperation;
        }
        op_iter = op.next_op;
    }

    for (consts.items) |const_op| {
        try emitConstant(self, const_op);
    }

    for (vars.items) |var_op| {
        try emitVariable(self, var_op, true);
    }

    for (funcs.items) |func_op| {
        try emitFunction(self, func_op);
    }

    return self.builder.toWords(self.allocator);
}

fn emitTopLevel(self: anytype, op: *ir.Operation) !void {
    const name = op.name.name;
    if (std.mem.eql(u8, name, SpirvDialect.FuncOp.operation_name)) {
        return emitFunction(self, op);
    }
    if (std.mem.eql(u8, name, SpirvDialect.VariableOp.operation_name)) {
        return emitVariable(self, op, true);
    }
    if (std.mem.eql(u8, name, SpirvDialect.ConstantOp.operation_name)) {
        return emitConstant(self, op);
    }
    return error.UnsupportedOperation;
}

fn emitFunction(self: anytype, func_op: *ir.Operation) !void {
    const name = functionName(func_op) orelse return error.MissingFunctionName;

    const region = func_op.getRegion(0) orelse return error.InvalidModule;
    if (!region.hasOneBlock()) return error.UnsupportedControlFlow;
    const entry = region.getEntryBlock() orelse return error.InvalidModule;

    const result_types = func_op.getResultTypes();
    if (result_types.len > 1) return error.UnsupportedFunctionSignature;

    const returns_void = result_types.len == 0;
    const return_kind: scalar.Kind = if (returns_void)
        .void
    else
        (scalar.kindFromType(result_types[0]) orelse return error.UnsupportedType);
    const return_type_id = try self.getScalarType(return_kind);

    var param_type_ids = std.ArrayListUnmanaged(u32).empty;
    defer param_type_ids.deinit(self.allocator);
    for (entry.arguments.items) |arg| {
        const kind = scalar.kindFromType(arg.type) orelse return error.UnsupportedType;
        const type_id = try self.getScalarType(kind);
        try param_type_ids.append(self.allocator, type_id);
    }

    const func_type_id = try emitFunctionType(self, return_type_id, param_type_ids.items);
    const func_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Function, &.{
        return_type_id,
        func_id,
        0,
        func_type_id,
    });

    for (entry.arguments.items, 0..) |arg, idx| {
        const param_id = self.builder.newId();
        try self.builder.emit(&self.builder.functions, SpirvOp.FunctionParameter, &.{
            param_type_ids.items[idx],
            param_id,
        });
        try self.bindValue(arg, param_id);
    }

    const label_id = self.builder.newId();
    try self.emitLabel(label_id);

    var op_iter = entry.operations.head;
    while (op_iter) |op_ptr| {
        const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
        try emitOp(self, op, returns_void);
        op_iter = op.next_op;
    }

    try self.builder.emit(&self.builder.functions, SpirvOp.FunctionEnd, &.{});
    self.current_block = null;

    const spirv_func = SpirvDialect.FuncOp{ .op = func_op };
    if (spirv_func.isEntryPoint()) {
        const exec_model = spirv_func.getExecutionModel() orelse return error.MissingAttribute;
        try self.builder.emitEntryPoint(
            switch (exec_model) {
                SpirvExecutionModel.vertex => spec.ExecutionModel.Vertex,
                SpirvExecutionModel.fragment => spec.ExecutionModel.Fragment,
                SpirvExecutionModel.gl_compute => spec.ExecutionModel.GLCompute,
            },
            func_id,
            name,
            self.interface_vars.items,
        );
        switch (exec_model) {
            SpirvExecutionModel.vertex => {},
            SpirvExecutionModel.fragment => try self.builder.emitExecutionMode(
                func_id,
                spec.ExecutionMode.OriginUpperLeft,
            ),
            SpirvExecutionModel.gl_compute => {
                try self.builder.emitExecutionModeLocalSize(func_id, 1, 1, 1);
            },
        }
        try self.emitFloatExecutionModes(func_id);
    }
}

fn emitOp(self: anytype, op: *ir.Operation, returns_void: bool) !void {
    const name = op.name.name;
    if (std.mem.eql(u8, name, SpirvDialect.ConstantOp.operation_name)) {
        return emitConstant(self, op);
    }
    if (std.mem.eql(u8, name, SpirvDialect.VariableOp.operation_name)) {
        return emitVariable(self, op, false);
    }
    if (std.mem.eql(u8, name, SpirvDialect.IAddOp.operation_name)) {
        return emitBinary(self, op, SpirvOp.IAdd, .int_any);
    }
    if (std.mem.eql(u8, name, SpirvDialect.FAddOp.operation_name)) {
        return emitBinary(self, op, SpirvOp.FAdd, .float);
    }
    if (std.mem.eql(u8, name, SpirvDialect.ISubOp.operation_name)) {
        return emitBinary(self, op, SpirvOp.ISub, .int_any);
    }
    if (std.mem.eql(u8, name, SpirvDialect.FSubOp.operation_name)) {
        return emitBinary(self, op, SpirvOp.FSub, .float);
    }
    if (std.mem.eql(u8, name, SpirvDialect.IMulOp.operation_name)) {
        return emitBinary(self, op, SpirvOp.IMul, .int_any);
    }
    if (std.mem.eql(u8, name, SpirvDialect.FMulOp.operation_name)) {
        return emitBinary(self, op, SpirvOp.FMul, .float);
    }
    if (std.mem.eql(u8, name, SpirvDialect.UDivOp.operation_name)) {
        return emitBinary(self, op, SpirvOp.UDiv, .int_unsigned);
    }
    if (std.mem.eql(u8, name, SpirvDialect.SDivOp.operation_name)) {
        return emitBinary(self, op, SpirvOp.SDiv, .int_signed);
    }
    if (std.mem.eql(u8, name, SpirvDialect.FDivOp.operation_name)) {
        return emitBinary(self, op, SpirvOp.FDiv, .float);
    }
    if (std.mem.eql(u8, name, SpirvDialect.LocalInvocationIdOp.operation_name)) {
        return gpu.emitIndex(self, op, .local_invocation_id);
    }
    if (std.mem.eql(u8, name, SpirvDialect.WorkgroupIdOp.operation_name)) {
        return gpu.emitIndex(self, op, .workgroup_id);
    }
    if (std.mem.eql(u8, name, SpirvDialect.WorkgroupSizeOp.operation_name)) {
        return gpu.emitIndex(self, op, .workgroup_size);
    }
    if (std.mem.eql(u8, name, SpirvDialect.NumWorkgroupsOp.operation_name)) {
        return gpu.emitIndex(self, op, .num_workgroups);
    }
    if (std.mem.eql(u8, name, SpirvDialect.GlobalInvocationIdOp.operation_name)) {
        return gpu.emitIndex(self, op, .global_invocation_id);
    }
    if (std.mem.eql(u8, name, SpirvDialect.BarrierOp.operation_name)) {
        return gpu.emitBarrier(self, op);
    }
    if (std.mem.eql(u8, name, SpirvDialect.SyncWarpOp.operation_name)) {
        return gpu.emitSyncWarp(self, op);
    }
    if (std.mem.eql(u8, name, SpirvDialect.ActiveMaskOp.operation_name)) {
        return gpu.emitActiveMask(self, op);
    }
    if (std.mem.eql(u8, name, SpirvDialect.AllSyncOp.operation_name)) {
        return gpu.emitAllAny(self, op, .all);
    }
    if (std.mem.eql(u8, name, SpirvDialect.AnySyncOp.operation_name)) {
        return gpu.emitAllAny(self, op, .any);
    }
    if (std.mem.eql(u8, name, SpirvDialect.BallotSyncOp.operation_name)) {
        return gpu.emitBallot(self, op);
    }
    if (std.mem.eql(u8, name, SpirvDialect.ShflSyncOp.operation_name)) {
        return gpu.emitShuffle(self, op);
    }
    if (std.mem.eql(u8, name, SpirvDialect.WarpReduceOp.operation_name)) {
        return gpu.emitWarpReduce(self, op);
    }
    if (std.mem.eql(u8, name, SpirvDialect.WarpScanOp.operation_name)) {
        return gpu.emitWarpScan(self, op);
    }
    if (std.mem.eql(u8, name, FuncDialect.ReturnOp.operation_name)) {
        return emitReturn(self, op, returns_void);
    }
    return error.UnsupportedOperation;
}

pub fn emitConstant(self: anytype, op: *ir.Operation) !void {
    const result = op.getResult(0) orelse return error.UnsupportedOperation;
    const type_id = try self.getTypeForValue(result);

    const constant = SpirvDialect.ConstantOp{ .op = op };
    if (constant.getIntValue()) |int_value| {
        const kind = scalar.kindFromType(result.type) orelse return error.UnsupportedType;
        const const_id = try self.getIntConstant(type_id, kind, int_value);
        try self.bindValue(result, const_id);
        return;
    }

    if (constant.getFloatValue()) |float_value| {
        const kind = scalar.kindFromType(result.type) orelse return error.UnsupportedType;
        const const_id = try self.getFloatConstant(type_id, kind, float_value);
        try self.bindValue(result, const_id);
        return;
    }

    if (op.getAttrAs(ir.Attribute.BoolAttr, "value")) |bool_attr| {
        const kind = scalar.kindFromType(result.type) orelse return error.UnsupportedType;
        if (kind != .bool) return error.UnsupportedType;
        const const_id = try self.getBoolConstant(bool_attr.getValue());
        try self.bindValue(result, const_id);
        return;
    }

    return error.UnsupportedOperation;
}

pub const SpirvBinaryExpectation = enum {
    int_any,
    int_signed,
    int_unsigned,
    float,
};

pub fn emitBinary(
    self: anytype,
    op: *ir.Operation,
    opcode: u16,
    expectation: SpirvBinaryExpectation,
) !void {
    if (op.operands.items.len != 2) return error.UnsupportedOperation;
    const lhs = op.operands.items[0].value;
    const rhs = op.operands.items[1].value;
    const result = op.getResult(0) orelse return error.UnsupportedOperation;

    const kind = scalar.kindFromType(result.type) orelse return error.UnsupportedType;
    switch (expectation) {
        .float => if (!scalar.isFloat(kind)) return error.UnsupportedType,
        .int_any => if (!scalar.isInt(kind)) return error.UnsupportedType,
        .int_signed => if (!scalar.isSignedInt(kind)) return error.UnsupportedType,
        .int_unsigned => if (!scalar.isUnsignedInt(kind)) return error.UnsupportedType,
    }

    const lhs_id = try self.getValue(lhs);
    const rhs_id = try self.getValue(rhs);
    const result_type_id = try self.getScalarType(kind);

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, opcode, &.{
        result_type_id,
        result_id,
        lhs_id,
        rhs_id,
    });
    try self.bindValue(result, result_id);
}

fn emitVariable(
    self: anytype,
    op: *ir.Operation,
    module_scope: bool,
) !void {
    const var_op = SpirvDialect.VariableOp{ .op = op };
    const result = op.getResult(0) orelse return error.UnsupportedOperation;
    const storage = var_op.getStorageClass() orelse return error.MissingAttribute;
    const storage_class = storageClassToSpv(storage);

    const elem_kind = scalar.kindFromType(result.type) orelse return error.UnsupportedType;
    const elem_type = try self.getScalarType(elem_kind);
    const ptr_type = try self.getPointerType(storage_class, elem_type);

    const var_id = self.builder.newId();
    const initializer = var_op.getInitializer();

    const section = if (module_scope) &self.builder.globals else &self.builder.functions;
    if (initializer) |init_val| {
        const init_id = try self.getValue(init_val);
        try self.builder.emit(section, SpirvOp.Variable, &.{
            ptr_type,
            var_id,
            storage_class,
            init_id,
        });
    } else {
        try self.builder.emit(section, SpirvOp.Variable, &.{
            ptr_type,
            var_id,
            storage_class,
        });
    }

    try self.bindValue(result, var_id);
    if (module_scope) {
        try self.addInterfaceVar(var_id);
    }
}

fn emitReturn(self: anytype, op: *ir.Operation, returns_void: bool) !void {
    if (returns_void) {
        if (op.operands.items.len != 0) return error.UnsupportedFunctionSignature;
        try self.builder.emit(&self.builder.functions, SpirvOp.Return, &.{});
        return;
    }

    if (op.operands.items.len != 1) return error.UnsupportedFunctionSignature;
    const value_id = try self.getValue(op.operands.items[0].value);
    try self.builder.emit(&self.builder.functions, SpirvOp.ReturnValue, &.{value_id});
}

/// The function type of a signature, declared once per module as SPIR-V
/// requires of a non-aggregate type.
pub fn emitFunctionType(
    self: anytype,
    return_type: u32,
    param_types: []const u32,
) !u32 {
    const types = self.builder.types.items;
    if (findFunctionType(types, return_type, param_types)) |existing| return existing;
    const id = self.builder.newId();
    var operands = Section.empty;
    defer operands.deinit(self.allocator);

    try operands.append(self.allocator, id);
    try operands.append(self.allocator, return_type);
    if (param_types.len > 0) {
        try operands.appendSlice(self.allocator, param_types);
    }

    try self.builder.emit(&self.builder.types, SpirvOp.TypeFunction, operands.items);
    return id;
}

fn findFunctionType(types: []const u32, return_type: u32, param_types: []const u32) ?u32 {
    var index: usize = 0;
    while (index < types.len) {
        const count = types[index] >> 16;
        std.debug.assert(count > 0);
        const opcode: u16 = @truncate(types[index]);
        if (opcode == SpirvOp.TypeFunction and count == 3 + param_types.len and
            types[index + 2] == return_type and
            std.mem.eql(u32, types[index + 3 ..][0..param_types.len], param_types))
        {
            return types[index + 1];
        }
        index += count;
    }
    return null;
}

test "spirv dialect writer maps storage classes" {
    try std.testing.expectEqual(@as(u32, spec.StorageClass.Workgroup), storageClassToSpv(.workgroup));
    try std.testing.expectEqual(@as(u32, spec.StorageClass.StorageBuffer), storageClassToSpv(.storage_buffer));
}
