const std = @import("std");
const choir = @import("../../../../root.zig");

const ir = choir.ir;
const dialects = choir.dialects;
const scalar = @import("scalar.zig");
const spec = @import("spec.zig");
const spirv_ops = @import("ops.zig");

const MemrefDialect = dialects.memref.MemrefDialect;
const MemrefAddressSpace = dialects.AddressSpace;
const AtomicRmwKind = dialects.memref.AtomicRmwKind;
const SpirvOp = spirv_ops.SpirvOp;

pub const Layout = enum { buffer, array };

pub const Binding = struct {
    storage_class: u32,
    elem_kind: scalar.Kind,
    elem_type: u32,
    storage_elem_kind: scalar.Kind,
    storage_elem_type: u32,
    ptr_elem_type: u32,
    layout: Layout,
    /// False for a variable decorated NonWritable, which takes no store.
    writable: bool = true,
};

pub const FunctionParameter = struct {
    pointer_type: u32,
    binding: Binding,
};

/// The parameter has the same Function array pointer and element layout as a whole local alloca.
pub fn functionParameter(self: anytype, typ: ir.Type) !FunctionParameter {
    const memref = parseType(typ) orelse return error.InvalidMemrefType;
    if (memref.addr_space != .local) return error.UnsupportedAddressSpace;
    const size = memref.size orelse return error.UnsupportedOperation;
    if (size == 0 or size > std.math.maxInt(u32)) return error.UnsupportedOperation;
    const elem_kind = scalar.kindFromName(memref.element_type_name) orelse return error.UnsupportedType;
    const elem_type = try self.getScalarType(elem_kind);
    const storage_kind = storageElementKind(elem_kind);
    const storage_type = try self.getScalarType(storage_kind);
    const array_type = try self.getArrayType(storage_type, @intCast(size));
    return .{
        .pointer_type = try self.getPointerType(spec.StorageClass.Function, array_type),
        .binding = .{
            .storage_class = spec.StorageClass.Function,
            .elem_kind = elem_kind,
            .elem_type = elem_type,
            .storage_elem_kind = storage_kind,
            .storage_elem_type = storage_type,
            .ptr_elem_type = try self.getPointerType(spec.StorageClass.Function, storage_type),
            .layout = .array,
        },
    };
}

pub fn emitLoad(self: anytype, op: *ir.Operation) !void {
    const load = MemrefDialect.LoadOp{ .op = op };
    const result = load.getResult();

    const memref = load.getMemref();
    const index = load.getIndex();

    const binding = self.memref_bindings.get(memref) orelse return error.InvalidMemrefType;
    const result_type_id = try self.getTypeForValue(result);
    if (result_type_id != binding.elem_type) return error.UnsupportedType;
    const access_id = try emitElementAccess(self, binding, memref, index);

    const loaded_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Load, &.{
        binding.storage_elem_type,
        loaded_id,
        access_id,
    });

    const result_id = try emitLoadResult(self, binding, loaded_id);
    try self.bindValue(result, result_id);
}

pub fn emitStore(self: anytype, op: *ir.Operation) !void {
    const store = MemrefDialect.StoreOp{ .op = op };
    const value = store.getValue();
    const memref = store.getMemref();
    const index = store.getIndex();

    const binding = self.memref_bindings.get(memref) orelse return error.InvalidMemrefType;
    if (!binding.writable) return error.UnsupportedAddressSpace;
    const value_type_id = try self.getTypeForValue(value);
    if (value_type_id != binding.elem_type) return error.UnsupportedType;
    const value_id = try self.getValue(value);
    const access_id = try emitElementAccess(self, binding, memref, index);
    const storage_value_id = try emitStoreValue(self, binding, value_id);

    try self.builder.emit(&self.builder.functions, SpirvOp.Store, &.{
        access_id,
        storage_value_id,
    });
}

pub fn emitAtomicRmw(self: anytype, op: *ir.Operation) !void {
    const atomic = MemrefDialect.AtomicRmwOp{ .op = op };
    const result = atomic.getResult();
    const value = atomic.getValue();
    const memref = atomic.getMemref();
    const index = atomic.getIndex();

    const binding = self.memref_bindings.get(memref) orelse return error.InvalidMemrefType;
    if (!binding.writable) return error.UnsupportedAddressSpace;
    const result_type_id = try self.getTypeForValue(result);
    const value_type_id = try self.getTypeForValue(value);
    if (result_type_id != binding.elem_type or value_type_id != binding.elem_type) {
        return error.UnsupportedType;
    }
    if (binding.storage_elem_type != binding.elem_type) return error.UnsupportedType;

    const kind = scalar.kindFromType(result.type) orelse return error.UnsupportedType;
    const opcode = atomicRmwOpcode(atomic.getKind() orelse return error.MissingAttribute, kind) orelse return error.UnsupportedType;
    const memory_operands = atomicMemoryOperands(binding.storage_class) orelse return error.UnsupportedAddressSpace;
    const u32_type = try self.getScalarType(.u32);
    const scope_id = try self.getIntConstant(u32_type, .u32, memory_operands.scope);
    const semantics_id = try self.getIntConstant(
        u32_type,
        .u32,
        spec.MemorySemanticsMask.AcquireRelease | memory_operands.semantics,
    );
    const access_id = try emitElementAccess(self, binding, memref, index);
    const value_id = try self.getValue(value);

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, opcode, &.{
        result_type_id,
        result_id,
        access_id,
        scope_id,
        semantics_id,
        value_id,
    });
    try self.bindValue(result, result_id);
}

pub fn emitAtomicCas(self: anytype, op: *ir.Operation) !void {
    const atomic = MemrefDialect.AtomicCasOp{ .op = op };
    const result = atomic.getResult();
    const expected = atomic.getExpected();
    const desired = atomic.getDesired();
    const memref = atomic.getMemref();
    const index = atomic.getIndex();

    const binding = self.memref_bindings.get(memref) orelse return error.InvalidMemrefType;
    if (!binding.writable) return error.UnsupportedAddressSpace;
    const result_type_id = try self.getTypeForValue(result);
    const expected_type_id = try self.getTypeForValue(expected);
    const desired_type_id = try self.getTypeForValue(desired);
    if (result_type_id != binding.elem_type or
        expected_type_id != binding.elem_type or
        desired_type_id != binding.elem_type)
    {
        return error.UnsupportedType;
    }
    if (binding.storage_elem_type != binding.elem_type) return error.UnsupportedType;

    const kind = scalar.kindFromType(result.type) orelse return error.UnsupportedType;
    if (!atomicScalarSupported(kind)) return error.UnsupportedType;

    const memory_operands = atomicMemoryOperands(binding.storage_class) orelse return error.UnsupportedAddressSpace;
    const u32_type = try self.getScalarType(.u32);
    const scope_id = try self.getIntConstant(u32_type, .u32, memory_operands.scope);
    const equal_semantics_id = try self.getIntConstant(
        u32_type,
        .u32,
        spec.MemorySemanticsMask.AcquireRelease | memory_operands.semantics,
    );
    const unequal_semantics_id = try self.getIntConstant(
        u32_type,
        .u32,
        spec.MemorySemanticsMask.Acquire | memory_operands.semantics,
    );
    const access_id = try emitElementAccess(self, binding, memref, index);
    const expected_id = try self.getValue(expected);
    const desired_id = try self.getValue(desired);

    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.AtomicCompareExchange, &.{
        result_type_id,
        result_id,
        access_id,
        scope_id,
        equal_semantics_id,
        unequal_semantics_id,
        desired_id,
        expected_id,
    });
    try self.bindValue(result, result_id);
}

pub fn emitAlloc(self: anytype, op: *ir.Operation) !void {
    const alloc = MemrefDialect.AllocOp{ .op = op };
    const result = alloc.getResult();
    const memref = parseType(result.type) orelse return error.InvalidMemrefType;

    if (memref.addr_space != .shared) return error.UnsupportedAddressSpace;
    const size = memref.size orelse return error.InvalidMemrefType;

    const elem_kind = scalar.kindFromName(memref.element_type_name) orelse return error.UnsupportedType;
    const elem_type_id = try self.getScalarType(elem_kind);
    const storage_elem_kind = storageElementKind(elem_kind);
    const storage_elem_type_id = try self.getScalarType(storage_elem_kind);
    const array_type = try self.getArrayType(storage_elem_type_id, @intCast(size));
    const ptr_array = try self.getPointerType(spec.StorageClass.Workgroup, array_type);
    const ptr_elem = try self.getPointerType(spec.StorageClass.Workgroup, storage_elem_type_id);

    const var_id = self.builder.newId();
    try self.builder.emit(&self.builder.globals, SpirvOp.Variable, &.{
        ptr_array,
        var_id,
        spec.StorageClass.Workgroup,
    });

    try self.bindValue(result, var_id);
    try self.memref_bindings.put(self.allocator, result, .{
        .storage_class = spec.StorageClass.Workgroup,
        .elem_kind = elem_kind,
        .elem_type = elem_type_id,
        .storage_elem_kind = storage_elem_kind,
        .storage_elem_type = storage_elem_type_id,
        .ptr_elem_type = ptr_elem,
        .layout = .array,
    });
}

/// Function variables must precede every ordinary instruction in the entry
/// block, including instructions that appear before an alloca in the IR.
pub fn declareAlloca(self: anytype, op: *ir.Operation) !void {
    const alloca = MemrefDialect.AllocaOp{ .op = op };
    const result = alloca.getResult();
    const memref = parseType(result.type) orelse return error.InvalidMemrefType;
    if (memref.addr_space != .local) return error.UnsupportedAddressSpace;
    if (alloca.getDynamicSize() != null) return error.UnsupportedOperation;
    const size = memref.size orelse return error.UnsupportedOperation;
    if (size == 0 or size > std.math.maxInt(u32)) return error.UnsupportedOperation;

    const elem_kind = scalar.kindFromName(memref.element_type_name) orelse return error.UnsupportedType;
    const elem_type = try self.getScalarType(elem_kind);
    const storage_kind = storageElementKind(elem_kind);
    const storage_type = try self.getScalarType(storage_kind);
    const array_type = try self.getArrayType(storage_type, @intCast(size));
    const ptr_array = try self.getPointerType(spec.StorageClass.Function, array_type);
    const ptr_elem = try self.getPointerType(spec.StorageClass.Function, storage_type);
    const var_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Variable, &.{
        ptr_array,
        var_id,
        spec.StorageClass.Function,
    });
    try self.bindValue(result, var_id);
    try self.memref_bindings.put(self.allocator, result, .{
        .storage_class = spec.StorageClass.Function,
        .elem_kind = elem_kind,
        .elem_type = elem_type,
        .storage_elem_kind = storage_kind,
        .storage_elem_type = storage_type,
        .ptr_elem_type = ptr_elem,
        .layout = .array,
    });
}

pub fn emitDeclaredAlloca(self: anytype, op: *ir.Operation) !void {
    const result = (MemrefDialect.AllocaOp{ .op = op }).getResult();
    if (self.memref_bindings.get(result) == null) return error.InvalidMemrefType;
}

fn emitLoadResult(self: anytype, binding: Binding, loaded_id: u32) !u32 {
    if (binding.storage_elem_type == binding.elem_type) return loaded_id;
    if (binding.elem_kind != .bool or binding.storage_elem_kind != .u8) return error.UnsupportedType;

    const zero_id = try self.getIntConstant(binding.storage_elem_type, binding.storage_elem_kind, 0);
    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.INotEqual, &.{
        binding.elem_type,
        result_id,
        loaded_id,
        zero_id,
    });
    return result_id;
}

fn emitStoreValue(self: anytype, binding: Binding, value_id: u32) !u32 {
    if (binding.storage_elem_type == binding.elem_type) return value_id;
    if (binding.elem_kind != .bool or binding.storage_elem_kind != .u8) return error.UnsupportedType;

    const zero_id = try self.getIntConstant(binding.storage_elem_type, binding.storage_elem_kind, 0);
    const one_id = try self.getIntConstant(binding.storage_elem_type, binding.storage_elem_kind, 1);
    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Select, &.{
        binding.storage_elem_type,
        result_id,
        value_id,
        one_id,
        zero_id,
    });
    return result_id;
}

fn emitElementAccess(
    self: anytype,
    binding: Binding,
    memref: *ir.Value,
    index: *ir.Value,
) !u32 {
    const memref_id = try self.getValue(memref);
    const index_id = try self.getValue(index);
    const access_id = self.builder.newId();
    switch (binding.layout) {
        .buffer => {
            const const_zero = try self.getIntConstant(
                try self.getScalarType(.u32),
                .u32,
                0,
            );
            try self.builder.emit(&self.builder.functions, SpirvOp.AccessChain, &.{
                binding.ptr_elem_type,
                access_id,
                memref_id,
                const_zero,
                index_id,
            });
        },
        .array => {
            try self.builder.emit(&self.builder.functions, SpirvOp.AccessChain, &.{
                binding.ptr_elem_type,
                access_id,
                memref_id,
                index_id,
            });
        },
    }
    return access_id;
}

pub fn decorateBufferVariable(
    self: anytype,
    var_id: u32,
    binding: u32,
    storage_class: u32,
    addr_space: MemrefAddressSpace,
) !void {
    _ = storage_class;
    try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
        var_id,
        spec.Decoration.DescriptorSet,
        0,
    });
    try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
        var_id,
        spec.Decoration.Binding,
        binding,
    });

    if (addr_space == .constant) {
        try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
            var_id,
            spec.Decoration.NonWritable,
        });
    }
}

pub fn getBufferLayout(
    self: anytype,
    storage_elem_type: u32,
    storage_elem_kind: scalar.Kind,
    storage_class: u32,
) !struct {
    ptr_struct_type: u32,
    ptr_elem_type: u32,
} {
    const stride = scalar.elementByteSize(storage_elem_kind) orelse return error.UnsupportedType;
    const runtime_array = try self.getRuntimeArrayType(storage_elem_type, @intCast(stride));
    const struct_type = try self.getStructType(runtime_array);

    const ptr_struct = try self.getPointerType(storage_class, struct_type);
    const ptr_elem = try self.getPointerType(storage_class, storage_elem_type);
    return .{ .ptr_struct_type = ptr_struct, .ptr_elem_type = ptr_elem };
}

pub fn storageElementKind(elem_kind: scalar.Kind) scalar.Kind {
    return switch (elem_kind) {
        .bool => .u8,
        else => elem_kind,
    };
}

pub fn parseType(ty: ir.Type) ?MemrefDialect.MemrefParams {
    const name = ty.getDialectTypeName() orelse return null;
    if (!std.mem.eql(u8, name, MemrefDialect.name)) return null;
    const key = ty.getDialectParamKey() orelse return null;
    return MemrefDialect.parseMemrefParams(key);
}

/// The storage class of a buffer argument in `addr_space`. A `.constant`
/// argument is read-only storage: a StorageBuffer that
/// `decorateBufferVariable` marks NonWritable. A Uniform block would bound it
/// by the guaranteed `maxUniformBufferRange` of 16,384 bytes, where a storage
/// buffer's guaranteed range is 2^27 bytes.
pub fn storageClassForAddressSpace(addr_space: MemrefAddressSpace) ?u32 {
    return switch (addr_space) {
        .device, .host, .unified, .constant => spec.StorageClass.StorageBuffer,
        .shared => spec.StorageClass.Workgroup,
        .local => null,
    };
}

fn atomicRmwOpcode(kind: AtomicRmwKind, elem_kind: scalar.Kind) ?u16 {
    if (!atomicScalarSupported(elem_kind)) return null;
    return switch (kind) {
        .add => SpirvOp.AtomicIAdd,
        .min => if (scalar.isSignedInt(elem_kind)) SpirvOp.AtomicSMin else SpirvOp.AtomicUMin,
        .max => if (scalar.isSignedInt(elem_kind)) SpirvOp.AtomicSMax else SpirvOp.AtomicUMax,
        .bit_and => SpirvOp.AtomicAnd,
        .bit_or => SpirvOp.AtomicOr,
        .bit_xor => SpirvOp.AtomicXor,
        .exchange => SpirvOp.AtomicExchange,
    };
}

fn atomicScalarSupported(kind: scalar.Kind) bool {
    return switch (kind) {
        .i32, .u32 => true,
        else => false,
    };
}

fn atomicMemoryOperands(storage_class: u32) ?struct {
    scope: u32,
    semantics: u32,
} {
    if (storage_class == spec.StorageClass.Workgroup) {
        return .{
            .scope = spec.Scope.Workgroup,
            .semantics = spec.MemorySemanticsMask.WorkgroupMemory,
        };
    }
    if (storage_class == spec.StorageClass.StorageBuffer) {
        return .{
            .scope = spec.Scope.Device,
            .semantics = spec.MemorySemanticsMask.UniformMemory,
        };
    }
    return null;
}
