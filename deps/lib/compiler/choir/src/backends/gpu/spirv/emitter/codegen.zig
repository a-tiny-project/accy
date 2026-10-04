const std = @import("std");
const abi = @import("gpu_abi");
const sys = @import("sys");
const choir = @import("../../../../root.zig");

const ir = choir.ir;
const dialects = choir.dialects;
const spirv_target = @import("../root.zig");
const calls = @import("../../calls.zig");
const gpu_target = @import("../../../../dialects/gpu/root.zig");
const binary = @import("module.zig");
const catalog = @import("catalog.zig");
const dialect_writer = @import("dialect.zig");
const gpu = @import("gpu.zig");
const memory = @import("memory.zig");
const scalar = @import("scalar.zig");
const spec = @import("spec.zig");
const stage_emit = @import("stage.zig");
const validation = @import("validation.zig");
const spirv_ops = @import("ops.zig");

const GpuDialect = gpu_target.GpuDialect;
const Stage = gpu_target.Stage;
const ArithDialect = dialects.arith.ArithDialect;
const arith = dialects.arith;
const MemrefDialect = dialects.memref.MemrefDialect;
const FuncDialect = dialects.func.FuncDialect;
const ScfDialect = dialects.scf.ScfDialect;
const SpirvDialect = spirv_target.SpirvDialect;
const BuiltinDialect = dialects.builtin.BuiltinDialect;
pub const SpirvOp = spirv_ops.SpirvOp;
const GLSLstd450 = scalar.GLSLstd450;
const ScalarKind = scalar.Kind;
const SpvAddressingModel = spec.AddressingModel;
const SpvCapability = spec.Capability;
const SpvDecoration = spec.Decoration;
const SpvExecutionMode = spec.ExecutionMode;
const SpvExecutionModel = spec.ExecutionModel;
const SpvMemoryModel = spec.MemoryModel;
const SpvStorageClass = spec.StorageClass;
const ModuleBuilder = binary.Builder;
const Section = binary.Section;
const SpirvHeader = binary.Header;
const SpirvVersion = binary.Version;

pub const SpirvCodegenError = error{
    OutOfMemory,
    InvalidModule,
    MissingFunctionName,
    MissingKernelAttribute,
    UnsupportedFunctionSignature,
    UnsupportedOperation,
    UnsupportedType,
    UnsupportedMask,
    UnsupportedAddressSpace,
    UnsupportedControlFlow,
    MissingValue,
    MissingAttribute,
    InvalidMemrefType,
    /// Shaped entries require LocalSize alone, while unshaped entries need
    /// the module-wide WorkgroupSize specialization constant.
    WorkgroupShapeMixed,
} || gpu_target.stage.MemoryError || gpu_target.kernel.ShapeError || calls.SignatureError || calls.DepthError;

pub const FloatWidths = struct {
    f16: bool = false,
    f32: bool = false,
    f64: bool = false,
};

/// Modes selected from the properties of the device that will run the module.
pub const FloatControls = struct {
    denorm_preserve: FloatWidths = .{},
    signed_zero_inf_nan_preserve: FloatWidths = .{},
    rounding_rte: FloatWidths = .{},
};

const VectorKey = struct {
    elem: ScalarKind,
    len: u32,
};

const PointerKey = struct {
    storage_class: u32,
    base_type: u32,
};

const RuntimeArrayKey = struct {
    elem_type: u32,
    stride: u32,
};

const ArrayKey = struct {
    elem_type: u32,
    length: u32,
};

const ConstKey = struct {
    type_id: u32,
    word0: u32,
    word1: u32,
    word_count: u32,
};

const ScalarArgument = struct {
    arg: *ir.Value,
    elem_type: u32,
    ptr_elem_type: u32,
    member_index: u32,
    byte_offset: u32,
};

const MemrefBinding = memory.Binding;
const KernelKind = enum { shaped, unshaped };

pub const SpirvCodegen = struct {
    allocator: std.mem.Allocator,
    builder: ModuleBuilder,
    value_ids: std.AutoHashMapUnmanaged(*ir.Value, u32),
    memref_bindings: std.AutoHashMapUnmanaged(*ir.Value, MemrefBinding),
    scalar_types: std.AutoHashMapUnmanaged(ScalarKind, u32),
    vector_types: std.AutoHashMapUnmanaged(VectorKey, u32),
    pointer_types: std.AutoHashMapUnmanaged(PointerKey, u32),
    array_types: std.AutoHashMapUnmanaged(ArrayKey, u32),
    runtime_array_types: std.AutoHashMapUnmanaged(RuntimeArrayKey, u32),
    struct_types: std.AutoHashMapUnmanaged(u32, u32),
    pair_struct_types: std.AutoHashMapUnmanaged(u32, u32),
    constants: std.AutoHashMapUnmanaged(ConstKey, u32),
    builtin_vars: std.AutoHashMapUnmanaged(gpu.BuiltinKind, u32),
    interface_vars: std.ArrayListUnmanaged(u32),
    interface_set: std.AutoHashMapUnmanaged(u32, void),
    capability_set: std.AutoHashMapUnmanaged(u32, void),
    extension_set: std.StringHashMapUnmanaged(void),
    void_function_type: ?u32,
    workgroup_size_constant: ?u32,
    /// The first kernel fixes whether the module uses declared shapes or
    /// a shared WorkgroupSize specialization constant.
    kernel_kind: ?KernelKind = null,
    /// Declared shape of the kernel whose body is being emitted.
    kernel_shape: ?gpu_target.kernel.Shape = null,
    /// The next buffer binding of the kernel being emitted. Each kernel
    /// numbers its buffers from 0, because a host builds one descriptor set
    /// layout per pipeline and binds a kernel's buffers from 0 in argument
    /// order (lib/compiler/gpu's compute layout), whatever else the module holds.
    binding_counter: u32,
    current_block: ?u32,
    /// Target bounds on the push-constant block.
    limits: abi.Limits = .{},
    float_controls: FloatControls = .{},
    /// Kernel whose push-constant layout the caller wants back.
    entry_name: ?[]const u8 = null,
    /// Layout of `entry_name`'s push-constant block once it is emitted.
    entry_push_constants: ?abi.PushConstants = null,
    /// Interface of the stage function being emitted.
    stage_interface: ?stage_emit.Interface = null,
    sampled_image_type: ?u32 = null,
    /// Combined image sampler variables by group and binding.
    texture_vars: std.AutoHashMapUnmanaged(stage_emit.ResourceKey, u32) = .{},
    /// Bytes of the push-constant block that stage functions read.
    push_extent: u32 = 0,
    push_var: ?u32 = null,
    /// Uniform blocks by group and binding.
    uniform_blocks: std.AutoHashMapUnmanaged(stage_emit.ResourceKey, stage_emit.UniformBlock) = .{},
    call_ids: std.StringHashMapUnmanaged(u32) = .{},

    pub fn init(allocator: std.mem.Allocator) SpirvCodegen {
        return .{
            .allocator = allocator,
            .builder = ModuleBuilder.init(allocator),
            .value_ids = .{},
            .memref_bindings = .{},
            .scalar_types = .{},
            .vector_types = .{},
            .pointer_types = .{},
            .array_types = .{},
            .runtime_array_types = .{},
            .struct_types = .{},
            .pair_struct_types = .{},
            .constants = .{},
            .builtin_vars = .{},
            .interface_vars = .empty,
            .interface_set = .{},
            .capability_set = .{},
            .extension_set = .{},
            .void_function_type = null,
            .workgroup_size_constant = null,
            .binding_counter = 0,
            .current_block = null,
        };
    }

    pub fn deinit(self: *SpirvCodegen) void {
        self.builder.deinit();
        self.value_ids.deinit(self.allocator);
        self.memref_bindings.deinit(self.allocator);
        self.scalar_types.deinit(self.allocator);
        self.vector_types.deinit(self.allocator);
        self.pointer_types.deinit(self.allocator);
        self.array_types.deinit(self.allocator);
        self.runtime_array_types.deinit(self.allocator);
        self.struct_types.deinit(self.allocator);
        self.pair_struct_types.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.builtin_vars.deinit(self.allocator);
        self.interface_vars.deinit(self.allocator);
        self.interface_set.deinit(self.allocator);
        self.capability_set.deinit(self.allocator);
        self.extension_set.deinit(self.allocator);
        self.texture_vars.deinit(self.allocator);
        self.uniform_blocks.deinit(self.allocator);
        self.call_ids.deinit(self.allocator);
    }

    pub fn getWorkgroupSizeConstant(self: *SpirvCodegen) SpirvCodegenError!u32 {
        std.debug.assert(self.kernel_kind == .unshaped);
        if (self.workgroup_size_constant) |id| return id;

        const shape = gpu_target.kernel.unit_shape;
        const u32_type = try self.getScalarType(.u32);
        const vec_type = try self.getVectorType(.u32, 3);
        var member_ids: [3]u32 = undefined;
        for (&member_ids, shape, 0..) |*member_id, extent, spec_index| {
            member_id.* = self.builder.newId();
            try self.builder.emit(&self.builder.types, SpirvOp.SpecConstant, &.{
                u32_type,
                member_id.*,
                extent,
            });
            try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
                member_id.*,
                SpvDecoration.SpecId,
                @intCast(spec_index),
            });
        }
        const composite_id = self.builder.newId();
        try self.builder.emit(&self.builder.types, SpirvOp.SpecConstantComposite, &.{
            vec_type,
            composite_id,
            member_ids[0],
            member_ids[1],
            member_ids[2],
        });
        try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
            composite_id,
            SpvDecoration.BuiltIn,
            gpu.SpvBuiltIn.WorkgroupSize,
        });

        self.workgroup_size_constant = composite_id;
        return composite_id;
    }

    pub fn requireCapability(self: *SpirvCodegen, capability: u32) !void {
        const entry = try self.capability_set.getOrPut(self.allocator, capability);
        if (entry.found_existing) return;
        try self.builder.emitCapability(capability);
    }

    pub fn requireExtension(self: *SpirvCodegen, extension: []const u8) !void {
        const entry = try self.extension_set.getOrPut(self.allocator, extension);
        if (entry.found_existing) return;
        try self.builder.emitExtension(extension);
    }

    pub fn emitFloatExecutionModes(self: *SpirvCodegen, func_id: u32) SpirvCodegenError!void {
        const widths = [_]u32{ 16, 32, 64 };
        const denorm = self.float_controls.denorm_preserve;
        const signed = self.float_controls.signed_zero_inf_nan_preserve;
        const rounding = self.float_controls.rounding_rte;
        const denorm_flags = [_]bool{ denorm.f16, denorm.f32, denorm.f64 };
        const signed_flags = [_]bool{ signed.f16, signed.f32, signed.f64 };
        const rounding_flags = [_]bool{ rounding.f16, rounding.f32, rounding.f64 };
        for (widths, 0..) |width, index| {
            if (!denorm_flags[index] and !signed_flags[index] and !rounding_flags[index]) continue;
            self.builder.requireVersion(SpirvVersion.v13);
            try self.requireExtension("SPV_KHR_float_controls");
            if (denorm_flags[index]) {
                try self.requireCapability(SpvCapability.DenormPreserve);
                try self.builder.emitFloatExecutionMode(func_id, SpvExecutionMode.DenormPreserve, width);
            }
            if (signed_flags[index]) {
                try self.requireCapability(SpvCapability.SignedZeroInfNanPreserve);
                try self.builder.emitFloatExecutionMode(func_id, SpvExecutionMode.SignedZeroInfNanPreserve, width);
            }
            if (rounding_flags[index]) {
                try self.requireCapability(SpvCapability.RoundingModeRTE);
                try self.builder.emitFloatExecutionMode(func_id, SpvExecutionMode.RoundingModeRTE, width);
            }
        }
    }

    pub fn emitModuleWords(self: *SpirvCodegen, module: *ir.Operation) SpirvCodegenError![]u32 {
        self.entry_push_constants = null;
        if (std.mem.eql(u8, module.name.name, SpirvDialect.ModuleOp.operation_name)) {
            return dialect_writer.emitModuleWords(self, module);
        }
        var call_plan = try calls.Plan.init(self.allocator, module, null);
        defer call_plan.deinit();
        try validation.validateModule(module);
        try stage_emit.scanBlocks(self, module);
        self.call_ids.clearRetainingCapacity();

        try self.requireCapability(SpvCapability.Shader);
        try self.builder.emitMemoryModel(SpvAddressingModel.Logical, SpvMemoryModel.GLSL450);

        const region = module.getRegion(0) orelse return error.InvalidModule;
        const block = region.getEntryBlock() orelse return error.InvalidModule;

        for (call_plan.helpers.items) |helper| try self.emitHelperFunction(helper);

        var op_iter = block.operations.head;
        while (op_iter) |op_ptr| {
            const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
            if (validation.isFunctionOp(op)) {
                if (op.getAttr("kernel") != null) {
                    try self.emitKernelFunction(op);
                } else if (gpu_target.stage.stageOf(op)) |stage| {
                    try self.emitStageFunction(op, stage);
                }
            } else {
                return error.UnsupportedOperation;
            }
            op_iter = op.next_op;
        }

        return self.builder.toWords(self.allocator);
    }

    pub fn emitModuleBytes(self: *SpirvCodegen, module: *ir.Operation) SpirvCodegenError![]u8 {
        const words = try self.emitModuleWords(module);
        defer self.allocator.free(words);

        const byte_len = words.len * @sizeOf(u32);
        const bytes = try self.allocator.alloc(u8, byte_len);
        var offset: usize = 0;
        for (words) |word| {
            std.mem.writeInt(u32, bytes[offset..][0..4], word, .little);
            offset += 4;
        }
        return bytes;
    }

    pub fn emitLabel(self: *SpirvCodegen, label_id: u32) SpirvCodegenError!void {
        try self.builder.emit(&self.builder.functions, SpirvOp.Label, &.{label_id});
        self.current_block = label_id;
    }

    fn emitKernelFunction(self: *SpirvCodegen, func_op: *ir.Operation) SpirvCodegenError!void {
        const name = dialect_writer.functionName(func_op) orelse return error.MissingFunctionName;

        self.value_ids.clearRetainingCapacity();
        self.memref_bindings.clearRetainingCapacity();
        self.interface_vars.clearRetainingCapacity();
        self.interface_set.clearRetainingCapacity();
        self.binding_counter = 0;

        const region = func_op.getRegion(0) orelse return error.InvalidModule;
        const entry = region.getEntryBlock() orelse return error.InvalidModule;
        const shape = try self.claimWorkgroupShape(func_op);
        std.debug.assert(self.kernel_shape == null);
        self.kernel_shape = if (self.kernel_kind == .shaped) shape else null;
        defer self.kernel_shape = null;

        var scalar_args = std.ArrayListUnmanaged(ScalarArgument).empty;
        defer scalar_args.deinit(self.allocator);
        var push_constants: abi.PushConstants = .{};

        for (entry.arguments.items) |arg| {
            if (memory.parseType(arg.type)) |memref| {
                const binding = self.binding_counter;
                self.binding_counter += 1;

                if (memref.addr_space == .shared) return error.UnsupportedAddressSpace;
                const storage_class = memory.storageClassForAddressSpace(memref.addr_space) orelse return error.UnsupportedAddressSpace;
                const elem_kind = scalar.kindFromName(memref.element_type_name) orelse return error.UnsupportedType;

                try self.requireBufferStorageCapability(memory.storageElementKind(elem_kind), storage_class);
                const elem_type_id = try self.getScalarType(elem_kind);
                const storage_elem_kind = memory.storageElementKind(elem_kind);
                const storage_elem_type_id = try self.getScalarType(storage_elem_kind);
                const layout = try memory.getBufferLayout(self, storage_elem_type_id, storage_elem_kind, storage_class);

                const var_id = self.builder.newId();
                try self.builder.emit(&self.builder.globals, SpirvOp.Variable, &.{
                    layout.ptr_struct_type,
                    var_id,
                    storage_class,
                });

                try memory.decorateBufferVariable(self, var_id, @intCast(binding), storage_class, memref.addr_space);
                try self.bindValue(arg, var_id);
                try self.memref_bindings.put(self.allocator, arg, .{
                    .storage_class = storage_class,
                    .elem_kind = elem_kind,
                    .elem_type = elem_type_id,
                    .storage_elem_kind = storage_elem_kind,
                    .storage_elem_type = storage_elem_type_id,
                    .ptr_elem_type = layout.ptr_elem_type,
                    .layout = .buffer,
                    .writable = memref.addr_space != .constant,
                });
                continue;
            }

            const scalar_kind = scalar.kindFromType(arg.type) orelse return error.UnsupportedType;
            const elem_type_id = try self.getScalarType(scalar_kind);
            const byte_size: u32 = @intCast(scalar.elementByteSize(scalar_kind) orelse return error.UnsupportedType);
            const byte_offset = push_constants.append(byte_size, self.limits) catch
                return error.UnsupportedFunctionSignature;
            const ptr_elem_type = try self.getPointerType(SpvStorageClass.PushConstant, elem_type_id);
            try scalar_args.append(self.allocator, .{
                .arg = arg,
                .elem_type = elem_type_id,
                .ptr_elem_type = ptr_elem_type,
                .member_index = @intCast(scalar_args.items.len),
                .byte_offset = byte_offset,
            });
        }

        if (self.entry_name) |entry_name| {
            if (std.mem.eql(u8, name, entry_name)) self.entry_push_constants = push_constants;
        }

        var push_var: u32 = 0;
        if (scalar_args.items.len > 0) {
            var struct_operands = std.ArrayListUnmanaged(u32).empty;
            defer struct_operands.deinit(self.allocator);
            const struct_id = self.builder.newId();
            try struct_operands.append(self.allocator, struct_id);
            for (scalar_args.items) |scalar_arg| {
                try struct_operands.append(self.allocator, scalar_arg.elem_type);
            }
            try self.builder.emit(&self.builder.types, SpirvOp.TypeStruct, struct_operands.items);
            try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
                struct_id,
                SpvDecoration.Block,
            });
            for (scalar_args.items) |scalar_arg| {
                try self.builder.emit(&self.builder.annotations, SpirvOp.MemberDecorate, &.{
                    struct_id,
                    scalar_arg.member_index,
                    SpvDecoration.Offset,
                    scalar_arg.byte_offset,
                });
            }
            const ptr_struct = try self.getPointerType(SpvStorageClass.PushConstant, struct_id);
            push_var = self.builder.newId();
            try self.builder.emit(&self.builder.globals, SpirvOp.Variable, &.{
                ptr_struct,
                push_var,
                SpvStorageClass.PushConstant,
            });
        }

        const void_type = try self.getScalarType(.void);
        const func_type = try self.getVoidFunctionType(void_type);
        const func_id = self.builder.newId();

        try self.builder.emit(&self.builder.functions, SpirvOp.Function, &.{
            void_type,
            func_id,
            0,
            func_type,
        });

        const label_id = self.builder.newId();
        try self.emitLabel(label_id);
        try self.declareFunctionAllocas(entry);

        if (scalar_args.items.len > 0) {
            const index_type = try self.getScalarType(.u32);
            for (scalar_args.items) |scalar_arg| {
                const member_index = try self.getIntConstant(index_type, .u32, scalar_arg.member_index);
                const access_id = self.builder.newId();
                try self.builder.emit(&self.builder.functions, SpirvOp.AccessChain, &.{
                    scalar_arg.ptr_elem_type,
                    access_id,
                    push_var,
                    member_index,
                });

                const load_id = self.builder.newId();
                try self.builder.emit(&self.builder.functions, SpirvOp.Load, &.{
                    scalar_arg.elem_type,
                    load_id,
                    access_id,
                });
                try self.bindValue(scalar_arg.arg, load_id);
            }
        }

        var op_iter = entry.operations.head;
        while (op_iter) |op_ptr| {
            const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
            try self.emitOperation(op);
            op_iter = op.next_op;
        }

        try self.builder.emit(&self.builder.functions, SpirvOp.FunctionEnd, &.{});
        self.current_block = null;

        try self.builder.emitEntryPoint(
            SpvExecutionModel.GLCompute,
            func_id,
            name,
            self.interface_vars.items,
        );

        try self.builder.emitExecutionModeLocalSize(func_id, shape[0], shape[1], shape[2]);
        try self.emitFloatExecutionModes(func_id);
        if (self.kernel_kind == .unshaped) _ = try self.getWorkgroupSizeConstant();
    }

    /// Each shaped entry declares its own LocalSize. An unshaped entry needs
    /// WorkgroupSize, which overrides every entry's LocalSize, so the two
    /// kinds cannot share one module.
    fn claimWorkgroupShape(self: *SpirvCodegen, func_op: *const ir.Operation) SpirvCodegenError!gpu_target.kernel.Shape {
        const declared = try gpu_target.kernel.shapeOf(func_op);
        const kind: KernelKind = if (declared != null) .shaped else .unshaped;
        if (self.kernel_kind) |module_kind| {
            if (module_kind != kind) return error.WorkgroupShapeMixed;
        } else {
            std.debug.assert(self.workgroup_size_constant == null);
            self.kernel_kind = kind;
        }
        return declared orelse gpu_target.kernel.unit_shape;
    }

    /// Emits a vertex or fragment entry. Its interface variables enter the
    /// entry point; a fragment entry takes an upper-left origin, as Vulkan
    /// requires.
    fn emitStageFunction(
        self: *SpirvCodegen,
        func_op: *ir.Operation,
        stage: Stage,
    ) SpirvCodegenError!void {
        const name = dialect_writer.functionName(func_op) orelse return error.MissingFunctionName;
        const region = func_op.getRegion(0) orelse return error.InvalidModule;
        const entry = region.getEntryBlock() orelse return error.InvalidModule;
        if (entry.arguments.items.len != 0) return error.UnsupportedFunctionSignature;

        self.value_ids.clearRetainingCapacity();
        self.interface_vars.clearRetainingCapacity();
        self.interface_set.clearRetainingCapacity();
        self.stage_interface = .{ .stage = stage };
        defer self.stage_interface = null;

        const void_type = try self.getScalarType(.void);
        const func_type = try self.getVoidFunctionType(void_type);
        const func_id = self.builder.newId();
        try self.builder.emit(&self.builder.functions, SpirvOp.Function, &.{
            void_type,
            func_id,
            0,
            func_type,
        });
        try self.emitLabel(self.builder.newId());
        self.memref_bindings.clearRetainingCapacity();
        try self.declareFunctionAllocas(entry);

        var op_iter = entry.operations.head;
        while (op_iter) |op_ptr| {
            const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
            try self.emitOperation(op);
            op_iter = op.next_op;
        }

        try self.builder.emit(&self.builder.functions, SpirvOp.FunctionEnd, &.{});
        self.current_block = null;

        try self.builder.emitEntryPoint(
            stage_emit.executionModel(stage),
            func_id,
            name,
            self.interface_vars.items,
        );
        if (stage == .fragment) {
            try self.builder.emitExecutionMode(func_id, SpvExecutionMode.OriginUpperLeft);
        }
        try self.emitFloatExecutionModes(func_id);
    }

    fn emitOperation(self: *SpirvCodegen, op: *ir.Operation) SpirvCodegenError!void {
        return catalog.emit(SpirvCodegenError, catalog_methods, self, op);
    }

    fn emitHelperFunction(self: *SpirvCodegen, func_op: *ir.Operation) SpirvCodegenError!void {
        try validation.validateHelperOp(func_op);
        const func = FuncDialect.FuncOp{ .op = func_op };
        const name = func.getName() orelse return error.MissingFunctionName;
        const results = func.getResultTypes();
        if (results.len > 1) return error.UnsupportedFunctionSignature;
        const return_type = if (results.len == 0)
            try self.getScalarType(.void)
        else
            try self.getScalarType(scalar.kindFromType(results[0]) orelse return error.UnsupportedType);
        var param_types = std.ArrayListUnmanaged(u32).empty;
        defer param_types.deinit(self.allocator);
        for (func.getArguments()) |arg| {
            const param_type = if (memory.parseType(arg.type) != null)
                (try memory.functionParameter(self, arg.type)).pointer_type
            else
                try self.getScalarType(scalar.kindFromType(arg.type) orelse return error.UnsupportedFunctionSignature);
            try param_types.append(self.allocator, param_type);
        }
        const func_type = try dialect_writer.emitFunctionType(self, return_type, param_types.items);
        const func_id = self.builder.newId();
        try self.call_ids.put(self.allocator, name, func_id);
        self.value_ids.clearRetainingCapacity();
        self.memref_bindings.clearRetainingCapacity();
        try self.builder.emit(&self.builder.functions, SpirvOp.Function, &.{ return_type, func_id, 0, func_type });
        for (func.getArguments(), param_types.items) |arg, param_type| {
            const param_id = self.builder.newId();
            try self.builder.emit(&self.builder.functions, SpirvOp.FunctionParameter, &.{ param_type, param_id });
            try self.bindValue(arg, param_id);
            if (memory.parseType(arg.type) != null) {
                const parameter = try memory.functionParameter(self, arg.type);
                try self.memref_bindings.put(self.allocator, arg, parameter.binding);
            }
        }
        try self.emitLabel(self.builder.newId());
        const entry = func.getEntryBlock();
        try self.declareFunctionAllocas(entry);
        var ops = entry.getOperations();
        while (ops.next()) |op| try self.emitOperation(op);
        try self.builder.emit(&self.builder.functions, SpirvOp.FunctionEnd, &.{});
        self.current_block = null;
    }

    fn emitCall(self: *SpirvCodegen, op: *ir.Operation) SpirvCodegenError!void {
        const call = FuncDialect.CallOp{ .op = op };
        const name = call.getCallee() orelse return error.MissingAttribute;
        const callee_id = self.call_ids.get(name) orelse return error.UnsupportedOperation;
        if (call.getNumResults() > 1) return error.UnsupportedFunctionSignature;
        const return_type = if (call.getNumResults() == 0)
            try self.getScalarType(.void)
        else
            try self.getScalarType(scalar.kindFromType(call.getResult(0).?.type) orelse return error.UnsupportedType);
        const result_id = self.builder.newId();
        var operands = std.ArrayListUnmanaged(u32).empty;
        defer operands.deinit(self.allocator);
        try operands.appendSlice(self.allocator, &.{ return_type, result_id, callee_id });
        for (call.getOperands()) |arg| try operands.append(self.allocator, try self.getValue(arg));
        try self.builder.emit(&self.builder.functions, SpirvOp.FunctionCall, operands.items);
        if (call.getResult(0)) |result| try self.bindValue(result, result_id);
    }

    fn declareFunctionAllocas(self: *SpirvCodegen, block: *ir.Block) SpirvCodegenError!void {
        var ops = block.getOperations();
        while (ops.next()) |op| {
            if (std.mem.eql(u8, op.name.name, MemrefDialect.AllocaOp.operation_name)) {
                try memory.declareAlloca(self, op);
            }
            for (0..op.getNumRegions()) |index| {
                const region = op.getRegion(index) orelse continue;
                var blocks = region.getBlocks();
                while (blocks.next()) |nested| try self.declareFunctionAllocas(nested);
            }
        }
    }

    fn emitReturn(self: *SpirvCodegen, op: *ir.Operation) SpirvCodegenError!void {
        if (op.operands.items.len == 0) {
            try self.builder.emit(&self.builder.functions, SpirvOp.Return, &.{});
            return;
        }
        if (op.operands.items.len == 1) {
            const value_id = try self.getValue(op.operands.items[0].value);
            try self.builder.emit(&self.builder.functions, SpirvOp.ReturnValue, &.{value_id});
            return;
        }
        return error.UnsupportedFunctionSignature;
    }

    fn emitBlockUntilYield(
        self: *SpirvCodegen,
        block: *ir.Block,
        yields: *std.ArrayListUnmanaged(u32),
    ) SpirvCodegenError!void {
        yields.clearRetainingCapacity();
        var op_iter = block.operations.head;
        while (op_iter) |op_ptr| {
            const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
            if (std.mem.eql(u8, op.name.name, ScfDialect.YieldOp.operation_name)) {
                if (op.next_op != null) return error.UnsupportedControlFlow;
                const yield_op = ScfDialect.YieldOp{ .op = op };
                for (yield_op.getOperands()) |operand| {
                    const value_id = try self.getValue(operand);
                    try yields.append(self.allocator, value_id);
                }
                return;
            }
            try self.emitOperation(op);
            op_iter = op.next_op;
        }
        return error.UnsupportedControlFlow;
    }

    fn emitBlockUntilCondition(
        self: *SpirvCodegen,
        block: *ir.Block,
        cond_id: *u32,
        args: *std.ArrayListUnmanaged(u32),
    ) SpirvCodegenError!void {
        args.clearRetainingCapacity();
        var op_iter = block.operations.head;
        while (op_iter) |op_ptr| {
            const op: *ir.Operation = @ptrCast(@alignCast(op_ptr));
            if (std.mem.eql(u8, op.name.name, ScfDialect.ConditionOp.operation_name)) {
                if (op.next_op != null) return error.UnsupportedControlFlow;
                const cond_op = ScfDialect.ConditionOp{ .op = op };
                cond_id.* = try self.getValue(cond_op.getCondition());
                for (cond_op.getArgs()) |operand| {
                    const value_id = try self.getValue(operand);
                    try args.append(self.allocator, value_id);
                }
                return;
            }
            try self.emitOperation(op);
            op_iter = op.next_op;
        }
        return error.UnsupportedControlFlow;
    }

    fn bindBlockArguments(self: *SpirvCodegen, block: *ir.Block, values: []const u32) SpirvCodegenError!void {
        if (block.arguments.items.len != values.len) return error.UnsupportedControlFlow;
        for (block.arguments.items, values) |arg, value_id| {
            try self.bindValue(arg, value_id);
        }
    }

    fn emitCompareLess(
        self: *SpirvCodegen,
        kind: ScalarKind,
        lhs_id: u32,
        rhs_id: u32,
    ) SpirvCodegenError!u32 {
        const bool_type_id = try self.getScalarType(.bool);
        const opcode: u16 = if (scalar.isFloat(kind))
            SpirvOp.FOrdLessThan
        else if (scalar.isSignedInt(kind))
            SpirvOp.SLessThan
        else
            SpirvOp.ULessThan;

        const result_id = self.builder.newId();
        try self.builder.emit(&self.builder.functions, opcode, &.{
            bool_type_id,
            result_id,
            lhs_id,
            rhs_id,
        });
        return result_id;
    }

    fn emitPhiWithPatch(
        self: *SpirvCodegen,
        result_type_id: u32,
        result_id: u32,
        init_value_id: u32,
        init_label: u32,
        backedge_label: u32,
    ) SpirvCodegenError!usize {
        const start_index = self.builder.functions.items.len;
        try self.builder.emit(&self.builder.functions, SpirvOp.Phi, &.{
            result_type_id,
            result_id,
            init_value_id,
            init_label,
            0,
            backedge_label,
        });
        return start_index + 1 + 4;
    }

    fn emitScfIf(self: *SpirvCodegen, op: *ir.Operation) SpirvCodegenError!void {
        const if_op = ScfDialect.IfOp{ .op = op };
        const cond_id = try self.getValue(if_op.getCondition());

        const then_block = if_op.getThenBlock();
        const else_block = if_op.getElseBlock();

        const merge_label = self.builder.newId();
        const then_label = self.builder.newId();
        const else_label = if (else_block != null) self.builder.newId() else merge_label;

        try self.builder.emit(&self.builder.functions, SpirvOp.SelectionMerge, &.{ merge_label, 0 });
        try self.builder.emit(&self.builder.functions, SpirvOp.BranchConditional, &.{ cond_id, then_label, else_label });

        var then_yields: std.ArrayListUnmanaged(u32) = .empty;
        defer then_yields.deinit(self.allocator);
        try self.emitLabel(then_label);
        try self.emitBlockUntilYield(then_block, &then_yields);
        try self.builder.emit(&self.builder.functions, SpirvOp.Branch, &.{merge_label});

        var else_yields: std.ArrayListUnmanaged(u32) = .empty;
        defer else_yields.deinit(self.allocator);
        if (else_block) |block| {
            try self.emitLabel(else_label);
            try self.emitBlockUntilYield(block, &else_yields);
            try self.builder.emit(&self.builder.functions, SpirvOp.Branch, &.{merge_label});
        }

        try self.emitLabel(merge_label);

        const result_count = if_op.getNumResults();
        if (result_count == 0) return;
        if (then_yields.items.len != result_count) return error.UnsupportedControlFlow;
        if (else_block == null) return error.UnsupportedControlFlow;
        if (else_yields.items.len != result_count) return error.UnsupportedControlFlow;

        for (0..result_count) |i| {
            const result_val = if_op.getResult(i) orelse return error.UnsupportedOperation;
            const result_type_id = try self.getTypeForValue(result_val);
            const result_id = self.builder.newId();
            try self.builder.emit(&self.builder.functions, SpirvOp.Phi, &.{
                result_type_id,
                result_id,
                then_yields.items[i],
                then_label,
                else_yields.items[i],
                else_label,
            });
            try self.bindValue(result_val, result_id);
        }
    }

    fn emitScfFor(self: *SpirvCodegen, op: *ir.Operation) SpirvCodegenError!void {
        const for_op = ScfDialect.ForOp{ .op = op };
        const preheader = self.current_block orelse return error.UnsupportedControlFlow;

        const header_label = self.builder.newId();
        const body_label = self.builder.newId();
        const merge_label = self.builder.newId();

        try self.builder.emit(&self.builder.functions, SpirvOp.Branch, &.{header_label});

        try self.emitLabel(header_label);

        const lower_id = try self.getValue(for_op.getLowerBound());
        const upper_id = try self.getValue(for_op.getUpperBound());
        const step_id = try self.getValue(for_op.getStep());
        const iv_kind = scalar.kindFromType(for_op.getLowerBound().type) orelse return error.UnsupportedType;
        const iv_type_id = try self.getScalarType(iv_kind);

        var phi_ids: std.ArrayListUnmanaged(u32) = .empty;
        defer phi_ids.deinit(self.allocator);
        var phi_patches: std.ArrayListUnmanaged(usize) = .empty;
        defer phi_patches.deinit(self.allocator);

        const iv_phi_id = self.builder.newId();
        const iv_patch = try self.emitPhiWithPatch(iv_type_id, iv_phi_id, lower_id, preheader, body_label);
        try phi_ids.append(self.allocator, iv_phi_id);
        try phi_patches.append(self.allocator, iv_patch);

        const init_args = for_op.getInitArgs();
        for (init_args) |init_arg| {
            const init_id = try self.getValue(init_arg);
            const init_type_id = try self.getTypeForValue(init_arg);
            const phi_id = self.builder.newId();
            const patch = try self.emitPhiWithPatch(init_type_id, phi_id, init_id, preheader, body_label);
            try phi_ids.append(self.allocator, phi_id);
            try phi_patches.append(self.allocator, patch);
        }

        const cond_id = try self.emitCompareLess(iv_kind, iv_phi_id, upper_id);
        try self.builder.emit(&self.builder.functions, SpirvOp.LoopMerge, &.{ merge_label, body_label, 0 });
        try self.builder.emit(&self.builder.functions, SpirvOp.BranchConditional, &.{ cond_id, body_label, merge_label });

        try self.emitLabel(body_label);

        var body_args: std.ArrayListUnmanaged(u32) = .empty;
        defer body_args.deinit(self.allocator);
        try body_args.append(self.allocator, iv_phi_id);
        for (phi_ids.items[1..]) |phi_id| {
            try body_args.append(self.allocator, phi_id);
        }
        try self.bindBlockArguments(for_op.getBodyBlock(), body_args.items);

        var yields: std.ArrayListUnmanaged(u32) = .empty;
        defer yields.deinit(self.allocator);
        try self.emitBlockUntilYield(for_op.getBodyBlock(), &yields);
        if (yields.items.len != init_args.len) return error.UnsupportedControlFlow;

        const next_iv_id = try scalar.emitBinaryArithIds(self, iv_kind, iv_phi_id, step_id, .add);
        try self.builder.emit(&self.builder.functions, SpirvOp.Branch, &.{header_label});

        self.builder.functions.items[phi_patches.items[0]] = next_iv_id;
        for (yields.items, 0..) |yield_id, idx| {
            const patch_index = phi_patches.items[idx + 1];
            self.builder.functions.items[patch_index] = yield_id;
        }

        try self.emitLabel(merge_label);

        for (0..init_args.len) |i| {
            const result_val = for_op.getResult(i) orelse return error.UnsupportedOperation;
            try self.bindValue(result_val, phi_ids.items[i + 1]);
        }
    }

    fn emitScfWhile(self: *SpirvCodegen, op: *ir.Operation) SpirvCodegenError!void {
        const while_op = ScfDialect.WhileOp{ .op = op };
        const preheader = self.current_block orelse return error.UnsupportedControlFlow;

        const header_label = self.builder.newId();
        const body_label = self.builder.newId();
        const merge_label = self.builder.newId();

        try self.builder.emit(&self.builder.functions, SpirvOp.Branch, &.{header_label});

        try self.emitLabel(header_label);

        var phi_ids: std.ArrayListUnmanaged(u32) = .empty;
        defer phi_ids.deinit(self.allocator);
        var phi_patches: std.ArrayListUnmanaged(usize) = .empty;
        defer phi_patches.deinit(self.allocator);

        for (op.operands.items) |operand| {
            const init_val = operand.value;
            const init_id = try self.getValue(init_val);
            const type_id = try self.getTypeForValue(init_val);
            const phi_id = self.builder.newId();
            const patch = try self.emitPhiWithPatch(type_id, phi_id, init_id, preheader, body_label);
            try phi_ids.append(self.allocator, phi_id);
            try phi_patches.append(self.allocator, patch);
        }

        try self.bindBlockArguments(while_op.getBeforeBlock(), phi_ids.items);

        var cond_args: std.ArrayListUnmanaged(u32) = .empty;
        defer cond_args.deinit(self.allocator);
        var cond_id: u32 = 0;
        try self.emitBlockUntilCondition(while_op.getBeforeBlock(), &cond_id, &cond_args);
        if (cond_args.items.len != phi_ids.items.len) return error.UnsupportedControlFlow;

        try self.builder.emit(&self.builder.functions, SpirvOp.LoopMerge, &.{ merge_label, body_label, 0 });
        try self.builder.emit(&self.builder.functions, SpirvOp.BranchConditional, &.{ cond_id, body_label, merge_label });

        try self.emitLabel(body_label);
        try self.bindBlockArguments(while_op.getAfterBlock(), cond_args.items);

        var yields: std.ArrayListUnmanaged(u32) = .empty;
        defer yields.deinit(self.allocator);
        try self.emitBlockUntilYield(while_op.getAfterBlock(), &yields);
        if (yields.items.len != phi_ids.items.len) return error.UnsupportedControlFlow;

        try self.builder.emit(&self.builder.functions, SpirvOp.Branch, &.{header_label});

        for (yields.items, 0..) |yield_id, idx| {
            const patch_index = phi_patches.items[idx];
            self.builder.functions.items[patch_index] = yield_id;
        }

        try self.emitLabel(merge_label);

        for (0..cond_args.items.len) |i| {
            const result_val = op.getResult(i) orelse return error.UnsupportedOperation;
            try self.bindValue(result_val, cond_args.items[i]);
        }
    }

    /// Lists `var_id` in the entry point being emitted. Only Input and Output
    /// variables belong there: the module stays below SPIR-V 1.4, where an
    /// entry's interface holds those two storage classes alone.
    pub fn addInterfaceVar(self: *SpirvCodegen, var_id: u32) SpirvCodegenError!void {
        const gop = try self.interface_set.getOrPut(self.allocator, var_id);
        if (!gop.found_existing) {
            try self.interface_vars.append(self.allocator, var_id);
        }
    }

    pub fn bindValue(self: *SpirvCodegen, value: *ir.Value, id: u32) SpirvCodegenError!void {
        try self.value_ids.put(self.allocator, value, id);
    }

    pub fn getValue(self: *SpirvCodegen, value: *ir.Value) SpirvCodegenError!u32 {
        return self.value_ids.get(value) orelse error.MissingValue;
    }

    pub fn getTypeForValue(self: *SpirvCodegen, value: *ir.Value) SpirvCodegenError!u32 {
        const kind = scalar.kindFromType(value.type) orelse return error.UnsupportedType;
        return self.getScalarType(kind);
    }

    pub fn getScalarType(self: *SpirvCodegen, kind: ScalarKind) SpirvCodegenError!u32 {
        if (self.scalar_types.get(kind)) |id| return id;

        try self.requireScalarCapability(kind);

        const id = self.builder.newId();
        switch (kind) {
            .void => try self.builder.emit(&self.builder.types, SpirvOp.TypeVoid, &.{id}),
            .bool => try self.builder.emit(&self.builder.types, SpirvOp.TypeBool, &.{id}),
            .i8 => try self.builder.emit(&self.builder.types, SpirvOp.TypeInt, &.{ id, 8, 1 }),
            .i16 => try self.builder.emit(&self.builder.types, SpirvOp.TypeInt, &.{ id, 16, 1 }),
            .i32 => try self.builder.emit(&self.builder.types, SpirvOp.TypeInt, &.{ id, 32, 1 }),
            .i64 => try self.builder.emit(&self.builder.types, SpirvOp.TypeInt, &.{ id, 64, 1 }),
            .u8 => try self.builder.emit(&self.builder.types, SpirvOp.TypeInt, &.{ id, 8, 0 }),
            .u16 => try self.builder.emit(&self.builder.types, SpirvOp.TypeInt, &.{ id, 16, 0 }),
            .u32 => try self.builder.emit(&self.builder.types, SpirvOp.TypeInt, &.{ id, 32, 0 }),
            .u64 => try self.builder.emit(&self.builder.types, SpirvOp.TypeInt, &.{ id, 64, 0 }),
            .f16 => try self.builder.emit(&self.builder.types, SpirvOp.TypeFloat, &.{ id, 16 }),
            .f32 => try self.builder.emit(&self.builder.types, SpirvOp.TypeFloat, &.{ id, 32 }),
            .f64 => try self.builder.emit(&self.builder.types, SpirvOp.TypeFloat, &.{ id, 64 }),
        }

        try self.scalar_types.put(self.allocator, kind, id);
        return id;
    }

    fn requireScalarCapability(self: *SpirvCodegen, kind: ScalarKind) SpirvCodegenError!void {
        const cap: ?u32 = switch (kind) {
            .i8, .u8 => SpvCapability.Int8,
            .i16, .u16 => SpvCapability.Int16,
            .i64, .u64 => SpvCapability.Int64,
            .f16 => SpvCapability.Float16,
            .f64 => SpvCapability.Float64,
            .void, .bool, .i32, .u32, .f32 => null,
        };
        if (cap) |c| try self.requireCapability(c);
    }

    fn requireBufferStorageCapability(self: *SpirvCodegen, kind: ScalarKind, storage_class: u32) SpirvCodegenError!void {
        if (storage_class == SpvStorageClass.StorageBuffer) {
            try self.requireExtension("SPV_KHR_storage_buffer_storage_class");
        }
        const width: ?u8 = switch (kind) {
            .i8, .u8 => 8,
            .i16, .u16, .f16 => 16,
            else => null,
        };
        const bits = width orelse return;
        const capability = switch (storage_class) {
            SpvStorageClass.StorageBuffer => if (bits == 8)
                SpvCapability.StorageBuffer8BitAccess
            else
                SpvCapability.StorageBuffer16BitAccess,
            SpvStorageClass.Uniform => if (bits == 8)
                SpvCapability.UniformAndStorageBuffer8BitAccess
            else
                SpvCapability.UniformAndStorageBuffer16BitAccess,
            else => return,
        };
        try self.requireCapability(capability);
        try self.requireExtension(if (bits == 8) "SPV_KHR_8bit_storage" else "SPV_KHR_16bit_storage");
    }

    pub fn getVectorType(self: *SpirvCodegen, elem: ScalarKind, len: u32) SpirvCodegenError!u32 {
        const key = VectorKey{ .elem = elem, .len = len };
        if (self.vector_types.get(key)) |id| return id;

        const elem_type = try self.getScalarType(elem);
        const id = self.builder.newId();
        try self.builder.emit(&self.builder.types, SpirvOp.TypeVector, &.{ id, elem_type, len });
        try self.vector_types.put(self.allocator, key, id);
        return id;
    }

    pub fn getPointerType(self: *SpirvCodegen, storage_class: u32, base_type: u32) SpirvCodegenError!u32 {
        const key = PointerKey{ .storage_class = storage_class, .base_type = base_type };
        if (self.pointer_types.get(key)) |id| return id;

        const id = self.builder.newId();
        try self.builder.emit(&self.builder.types, SpirvOp.TypePointer, &.{ id, storage_class, base_type });
        try self.pointer_types.put(self.allocator, key, id);
        return id;
    }

    pub fn getArrayType(self: *SpirvCodegen, elem_type: u32, length: u32) SpirvCodegenError!u32 {
        const key = ArrayKey{ .elem_type = elem_type, .length = length };
        if (self.array_types.get(key)) |id| return id;

        const length_const = try self.getIntConstant(
            try self.getScalarType(.u32),
            .u32,
            @intCast(length),
        );
        const id = self.builder.newId();
        try self.builder.emit(&self.builder.types, SpirvOp.TypeArray, &.{ id, elem_type, length_const });
        try self.array_types.put(self.allocator, key, id);
        return id;
    }

    pub fn getRuntimeArrayType(self: *SpirvCodegen, elem_type: u32, stride: u32) SpirvCodegenError!u32 {
        const key = RuntimeArrayKey{ .elem_type = elem_type, .stride = stride };
        if (self.runtime_array_types.get(key)) |id| return id;

        const id = self.builder.newId();
        try self.builder.emit(&self.builder.types, SpirvOp.TypeRuntimeArray, &.{ id, elem_type });
        try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
            id,
            SpvDecoration.ArrayStride,
            stride,
        });

        try self.runtime_array_types.put(self.allocator, key, id);
        return id;
    }

    pub fn getStructType(self: *SpirvCodegen, member_type: u32) SpirvCodegenError!u32 {
        if (self.struct_types.get(member_type)) |id| return id;

        const id = self.builder.newId();
        try self.builder.emit(&self.builder.types, SpirvOp.TypeStruct, &.{ id, member_type });
        try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
            id,
            SpvDecoration.Block,
        });
        try self.builder.emit(&self.builder.annotations, SpirvOp.MemberDecorate, &.{
            id,
            0,
            SpvDecoration.Offset,
            0,
        });

        try self.struct_types.put(self.allocator, member_type, id);
        return id;
    }

    pub fn getPairStructType(self: *SpirvCodegen, member_type: u32) SpirvCodegenError!u32 {
        if (self.pair_struct_types.get(member_type)) |id| return id;

        const id = self.builder.newId();
        try self.builder.emit(&self.builder.types, SpirvOp.TypeStruct, &.{ id, member_type, member_type });
        try self.pair_struct_types.put(self.allocator, member_type, id);
        return id;
    }

    fn getVoidFunctionType(self: *SpirvCodegen, void_type: u32) SpirvCodegenError!u32 {
        if (self.void_function_type) |id| return id;

        const id = self.builder.newId();
        try self.builder.emit(&self.builder.types, SpirvOp.TypeFunction, &.{ id, void_type });
        self.void_function_type = id;
        return id;
    }

    pub fn getIntConstant(
        self: *SpirvCodegen,
        type_id: u32,
        kind: ScalarKind,
        value: i64,
    ) SpirvCodegenError!u32 {
        const bits = scalar.integerConstantBits(kind, value) orelse return error.UnsupportedType;
        const key = ConstKey{
            .type_id = type_id,
            .word0 = bits.word0,
            .word1 = bits.word1,
            .word_count = bits.word_count,
        };
        if (self.constants.get(key)) |id| return id;

        const id = self.builder.newId();
        var operands = Section.empty;
        defer operands.deinit(self.allocator);
        try operands.append(self.allocator, type_id);
        try operands.append(self.allocator, id);
        try operands.append(self.allocator, bits.word0);
        if (bits.word_count == 2) {
            try operands.append(self.allocator, bits.word1);
        }

        try self.builder.emit(&self.builder.types, SpirvOp.Constant, operands.items);
        try self.constants.put(self.allocator, key, id);
        return id;
    }

    pub fn getFloatConstant(
        self: *SpirvCodegen,
        type_id: u32,
        kind: ScalarKind,
        value: f64,
    ) SpirvCodegenError!u32 {
        const bits = scalar.floatConstantBits(kind, value) orelse return error.UnsupportedType;
        const key = ConstKey{
            .type_id = type_id,
            .word0 = bits.word0,
            .word1 = bits.word1,
            .word_count = bits.word_count,
        };
        if (self.constants.get(key)) |id| return id;

        const id = self.builder.newId();
        var operands = Section.empty;
        defer operands.deinit(self.allocator);
        try operands.append(self.allocator, type_id);
        try operands.append(self.allocator, id);
        try operands.append(self.allocator, bits.word0);
        if (bits.word_count == 2) {
            try operands.append(self.allocator, bits.word1);
        }

        try self.builder.emit(&self.builder.types, SpirvOp.Constant, operands.items);
        try self.constants.put(self.allocator, key, id);
        return id;
    }

    pub fn getBoolConstant(self: *SpirvCodegen, value: bool) SpirvCodegenError!u32 {
        const type_id = try self.getScalarType(.bool);
        const key = ConstKey{
            .type_id = type_id,
            .word0 = if (value) 1 else 0,
            .word1 = 0,
            .word_count = 1,
        };
        if (self.constants.get(key)) |id| return id;

        const id = self.builder.newId();
        const opcode = if (value) SpirvOp.ConstantTrue else SpirvOp.ConstantFalse;
        try self.builder.emit(&self.builder.types, opcode, &.{ type_id, id });
        try self.constants.put(self.allocator, key, id);
        return id;
    }
};

const catalog_methods = .{
    .emitCall = SpirvCodegen.emitCall,
    .emitReturn = SpirvCodegen.emitReturn,
    .emitScfIf = SpirvCodegen.emitScfIf,
    .emitScfFor = SpirvCodegen.emitScfFor,
    .emitScfWhile = SpirvCodegen.emitScfWhile,
};

test "spirv catalog drives supported and unsupported emission" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);

    const loc = ir.Location.getUnknown();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const constant = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 7);

    var codegen = SpirvCodegen.init(std.testing.allocator);
    defer codegen.deinit();

    try codegen.emitOperation(constant.op);
    try std.testing.expect(codegen.builder.types.items.len > 0);

    const unsupported = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    try std.testing.expectError(error.UnsupportedOperation, codegen.emitOperation(unsupported.op));
}

test "spirv codegen emits minimal header and entry point" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    const memref_elem = try ArithDialect.getScalarType(&ctx, .f32);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, memref_elem, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{memref_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const idx_type = try ArithDialect.getIndexType(&ctx);
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);

    const load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), memref_elem);
    try entry.addOperation(load.op);

    const store = try MemrefDialect.StoreOp.create(&ctx, loc, load.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);

    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();

    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    try testing.expect(words.len > 5);
    try testing.expectEqual(SpirvHeader.magic, words[0]);
    try testing.expectEqual(SpirvHeader.version, words[1]);

    try testing.expect(containsOpcode(words, SpirvOp.EntryPoint));
    try testing.expect(containsOpcode(words, SpirvOp.ExecutionMode));
    try testing.expect(containsOpcode(words, SpirvOp.Variable));
    try testing.expect(containsOpcode(words, SpirvOp.Load));
    try testing.expect(containsOpcode(words, SpirvOp.Store));
    _ = idx_type;
}

test "spirv codegen stores bool memrefs as byte runtime arrays" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    const bool_type = try ArithDialect.getScalarType(&ctx, .bool);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, bool_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel_bool_copy", &.{memref_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), bool_type);
    try entry.addOperation(load.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, load.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();

    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    const bool_type_id = findTypeBool(words) orelse return error.TestExpectedBoolType;
    const u8_type_id = findTypeInt(words, 8, 0) orelse return error.TestExpectedU8Type;
    try testing.expect(containsCapability(words, SpvCapability.Int8));
    try testing.expect(containsCapability(words, SpvCapability.StorageBuffer8BitAccess));
    try testing.expect(containsExtension(words, "SPV_KHR_storage_buffer_storage_class"));
    try testing.expect(containsExtension(words, "SPV_KHR_8bit_storage"));
    try testing.expect(containsRuntimeArrayElement(words, u8_type_id));
    try testing.expect(!containsRuntimeArrayElement(words, bool_type_id));
    try testing.expect(containsOpcode(words, SpirvOp.Load));
    try testing.expect(containsOpcode(words, SpirvOp.INotEqual));
    try testing.expect(containsOpcode(words, SpirvOp.Select));
    try testing.expect(containsOpcode(words, SpirvOp.Store));
}

test "spirv codegen emits memref integer atomics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    const i32_type = try ArithDialect.getI32Type(&ctx);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, i32_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel_atomic", &.{memref_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);

    const one = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    try entry.addOperation(one.op);
    const two = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 2);
    try entry.addOperation(two.op);

    const add = try MemrefDialect.AtomicRmwOp.create(
        &ctx,
        loc,
        .add,
        one.getResult(),
        func.getArgument(0),
        gid.getResult(),
        i32_type,
    );
    try entry.addOperation(add.op);

    const cas = try MemrefDialect.AtomicCasOp.create(
        &ctx,
        loc,
        add.getResult(),
        two.getResult(),
        func.getArgument(0),
        gid.getResult(),
        i32_type,
    );
    try entry.addOperation(cas.op);

    const store = try MemrefDialect.StoreOp.create(&ctx, loc, cas.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);

    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();

    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    try testing.expect(containsOpcode(words, SpirvOp.AccessChain));
    try testing.expect(containsOpcode(words, SpirvOp.AtomicIAdd));
    try testing.expect(containsOpcode(words, SpirvOp.AtomicCompareExchange));
    try testing.expect(containsOpcode(words, SpirvOp.Store));

    const bytes = try wordsToBytes(allocator, words);
    defer allocator.free(bytes);
    try maybeRunSpirvVal(bytes);
}

test "spirv codegen emits shared integer atomic rmw" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    const i32_type = try ArithDialect.getI32Type(&ctx);
    const index_type = try ArithDialect.getIndexType(&ctx);
    const shared_type = try MemrefDialect.getMemrefType1D(&ctx, 4, i32_type, .shared);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel_shared_atomic", &.{});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const shared_alloc = try MemrefDialect.AllocOp.createStatic(&ctx, loc, shared_type);
    try entry.addOperation(shared_alloc.op);
    const zero = try ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 0);
    try entry.addOperation(zero.op);
    const one = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    try entry.addOperation(one.op);
    const max = try MemrefDialect.AtomicRmwOp.create(
        &ctx,
        loc,
        .max,
        one.getResult(),
        shared_alloc.getResult(),
        zero.getResult(),
        i32_type,
    );
    try entry.addOperation(max.op);

    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();

    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    try testing.expect(containsOpcode(words, SpirvOp.Variable));
    try testing.expect(containsOpcode(words, SpirvOp.AtomicSMax));

    const bytes = try wordsToBytes(allocator, words);
    defer allocator.free(bytes);
    try maybeRunSpirvVal(bytes);
}

test "spirv codegen rejects memref f32 atomic add without extension support" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, f32_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel_atomic_f32", &.{memref_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const one = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 1.0);
    try entry.addOperation(one.op);
    const add = try MemrefDialect.AtomicRmwOp.create(
        &ctx,
        loc,
        .add,
        one.getResult(),
        func.getArgument(0),
        gid.getResult(),
        f32_type,
    );
    try entry.addOperation(add.op);

    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();

    try testing.expectError(error.UnsupportedType, codegen.emitModuleWords(module.op));
}

test "spirv dialect serialization emits entry point and arithmetic ops" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try SpirvDialect.ModuleOp.create(
        &ctx,
        loc,
        .logical,
        .glsl450,
        .shader,
        "GLSL.std.450",
    );
    const module_block = module.getBodyBlock();

    const i32_type = try ArithDialect.getScalarType(&ctx, .i32);

    const global_var = try SpirvDialect.VariableOp.create(&ctx, loc, i32_type, .workgroup, null);
    try module_block.addOperation(global_var.op);

    var func = try SpirvDialect.FuncOp.create(&ctx, loc, "spirv_entry", &.{i32_type}, &.{});
    try func.setEntryPoint(&ctx, .gl_compute);
    try module_block.addOperation(func.op);

    const entry = func.getEntryBlock();
    const arg0 = entry.arguments.items[0];

    const const_op = try SpirvDialect.ConstantOp.createInt(&ctx, loc, i32_type, 7);
    try entry.addOperation(const_op.op);

    const add = try SpirvDialect.IAddOp.create(&ctx, loc, arg0, const_op.getResult());
    try entry.addOperation(add.op);

    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();

    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    try testing.expectEqual(SpirvHeader.magic, words[0]);
    try testing.expect(containsOpcode(words, SpirvOp.EntryPoint));
    try testing.expect(containsOpcode(words, SpirvOp.ExecutionMode));
    try testing.expect(containsOpcode(words, SpirvOp.TypeFunction));
    try testing.expect(containsOpcode(words, SpirvOp.FunctionParameter));
    try testing.expect(containsOpcode(words, SpirvOp.Variable));
    try testing.expect(containsOpcode(words, SpirvOp.Constant));
    try testing.expect(containsOpcode(words, SpirvOp.IAdd));
    try testing.expect(containsOpcode(words, SpirvOp.Return));
    try testing.expect(containsOpcode(words, SpirvOp.FunctionEnd));
}

test "spirv codegen handles control flow, shared alloc, and warp ops" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    const i32_type = try ArithDialect.getI32Type(&ctx);
    const index_type = try ArithDialect.getIndexType(&ctx);
    const memref_device = try MemrefDialect.getMemrefType1D(&ctx, 4, i32_type, .device);
    const memref_shared = try MemrefDialect.getMemrefType1D(&ctx, 4, i32_type, .shared);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel_cf", &.{ memref_device, i32_type });
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const buf_arg = func.getArgument(0);
    const scalar_arg = func.getArgument(1);

    const tid = try GpuDialect.ThreadIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(tid.op);

    const load = try MemrefDialect.LoadOp.create(&ctx, loc, buf_arg, tid.getResult(), i32_type);
    try entry.addOperation(load.op);

    const sum = try ArithDialect.AddOp.create(&ctx, loc, load.getResult(), scalar_arg);
    try entry.addOperation(sum.op);

    const shared_alloc = try MemrefDialect.AllocOp.createStatic(&ctx, loc, memref_shared);
    try entry.addOperation(shared_alloc.op);
    const store_shared = try MemrefDialect.StoreOp.create(&ctx, loc, sum.getResult(), shared_alloc.getResult(), tid.getResult());
    try entry.addOperation(store_shared.op);

    const barrier = try GpuDialect.BarrierOp.create(&ctx, loc, .block);
    try entry.addOperation(barrier.op);

    const mask_const = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, -1);
    try entry.addOperation(mask_const.op);
    const reduce = try GpuDialect.WarpReduceOp.create(&ctx, loc, .add, mask_const.getResult(), sum.getResult());
    try entry.addOperation(reduce.op);

    const zero = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 0);
    try entry.addOperation(zero.op);
    const cmp = try ArithDialect.CmpOp.create(&ctx, loc, .gt, reduce.getResult(), zero.getResult());
    try entry.addOperation(cmp.op);

    const all_sync = try GpuDialect.AllSyncOp.create(&ctx, loc, mask_const.getResult(), cmp.getResult());
    try entry.addOperation(all_sync.op);

    const ballot = try GpuDialect.BallotSyncOp.create(&ctx, loc, mask_const.getResult(), cmp.getResult());
    try entry.addOperation(ballot.op);

    const shfl_delta = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    try entry.addOperation(shfl_delta.op);
    const shfl_down = try GpuDialect.ShflSyncOp.create(&ctx, loc, .down, mask_const.getResult(), sum.getResult(), shfl_delta.getResult());
    try entry.addOperation(shfl_down.op);

    const shfl_xor = try GpuDialect.ShflSyncOp.create(&ctx, loc, .xor, mask_const.getResult(), sum.getResult(), shfl_delta.getResult());
    try entry.addOperation(shfl_xor.op);

    var if_op = try ScfDialect.IfOp.create(&ctx, loc, cmp.getResult(), &.{i32_type});
    try entry.addOperation(if_op.op);
    const then_block = if_op.getThenBlock();
    const one = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 1);
    try then_block.addOperation(one.op);
    const then_yield = try ScfDialect.YieldOp.create(&ctx, loc, &.{one.getResult()});
    try then_block.addOperation(then_yield.op);
    const else_block = if_op.getElseBlock().?;
    const two = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 2);
    try else_block.addOperation(two.op);
    const else_yield = try ScfDialect.YieldOp.create(&ctx, loc, &.{two.getResult()});
    try else_block.addOperation(else_yield.op);

    const if_result = if_op.getResult(0).?;
    const lo = try ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 0);
    try entry.addOperation(lo.op);
    const hi = try ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 4);
    try entry.addOperation(hi.op);
    const step = try ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 1);
    try entry.addOperation(step.op);

    var for_op = try ScfDialect.ForOp.create(
        &ctx,
        loc,
        lo.getResult(),
        hi.getResult(),
        step.getResult(),
        &.{if_result},
        &.{i32_type},
    );
    try entry.addOperation(for_op.op);

    const body = for_op.getBodyBlock();
    const iv = body.arguments.items[0];
    const acc = body.arguments.items[1];
    const iv_cast = try ArithDialect.CastOp.create(&ctx, loc, iv, i32_type);
    try body.addOperation(iv_cast.op);
    const acc_add = try ArithDialect.AddOp.create(&ctx, loc, acc, iv_cast.getResult());
    try body.addOperation(acc_add.op);
    const for_yield = try ScfDialect.YieldOp.create(&ctx, loc, &.{acc_add.getResult()});
    try body.addOperation(for_yield.op);

    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();

    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    try testing.expectEqual(SpirvVersion.v13, words[1]);
    try testing.expect(containsCapability(words, SpvCapability.GroupNonUniform));
    try testing.expect(containsCapability(words, SpvCapability.GroupNonUniformVote));
    try testing.expect(containsCapability(words, SpvCapability.GroupNonUniformBallot));
    try testing.expect(containsCapability(words, SpvCapability.GroupNonUniformShuffle));
    try testing.expect(containsCapability(words, SpvCapability.GroupNonUniformShuffleRelative));
    try testing.expect(containsCapability(words, SpvCapability.GroupNonUniformArithmetic));
    try testing.expect(containsOpcode(words, SpirvOp.LoopMerge));
    try testing.expect(loopMergesImmediatelyPrecedeBranches(words));
    try testing.expect(containsOpcode(words, SpirvOp.SelectionMerge));
    try testing.expect(containsOpcode(words, SpirvOp.ControlBarrier));
    try testing.expect(containsOpcode(words, SpirvOp.GroupNonUniformIAdd));
    try testing.expect(containsOpcode(words, SpirvOp.ULessThan));
}

test "spirv codegen emits arith comparison opcode families" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const bool_type = try ArithDialect.getScalarType(&ctx, .bool);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const i32_type = try ArithDialect.getScalarType(&ctx, .i32);
    const index_type = try ArithDialect.getScalarType(&ctx, .index);
    const bool_memref = try MemrefDialect.getMemrefTypeDynamic(&ctx, bool_type, .device);
    const f32_memref = try MemrefDialect.getMemrefTypeDynamic(&ctx, f32_type, .device);
    const i32_memref = try MemrefDialect.getMemrefTypeDynamic(&ctx, i32_type, .device);
    const index_memref = try MemrefDialect.getMemrefTypeDynamic(&ctx, index_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel_cmp", &.{ bool_memref, f32_memref, i32_memref, index_memref });
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);

    const f32_value = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(1), gid.getResult(), f32_type);
    try entry.addOperation(f32_value.op);
    const f32_limit = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 0.0);
    try entry.addOperation(f32_limit.op);
    const f32_cmp = try ArithDialect.CmpOp.create(&ctx, loc, .lt, f32_value.getResult(), f32_limit.getResult());
    try entry.addOperation(f32_cmp.op);
    const store_f32 = try MemrefDialect.StoreOp.create(&ctx, loc, f32_cmp.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store_f32.op);

    const i32_value = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(2), gid.getResult(), i32_type);
    try entry.addOperation(i32_value.op);
    const i32_limit = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 7);
    try entry.addOperation(i32_limit.op);
    const i32_cmp = try ArithDialect.CmpOp.create(&ctx, loc, .lt, i32_value.getResult(), i32_limit.getResult());
    try entry.addOperation(i32_cmp.op);
    const store_i32 = try MemrefDialect.StoreOp.create(&ctx, loc, i32_cmp.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store_i32.op);

    const index_value = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(3), gid.getResult(), index_type);
    try entry.addOperation(index_value.op);
    const index_limit = try ArithDialect.ConstantOp.createInt(&ctx, loc, index_type, 9);
    try entry.addOperation(index_limit.op);
    const index_cmp = try ArithDialect.CmpOp.create(&ctx, loc, .lt, index_value.getResult(), index_limit.getResult());
    try entry.addOperation(index_cmp.op);
    const store_index = try MemrefDialect.StoreOp.create(&ctx, loc, index_cmp.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store_index.op);

    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    try testing.expect(containsOpcode(words, SpirvOp.FOrdLessThan));
    try testing.expect(containsOpcode(words, SpirvOp.SLessThan));
    try testing.expect(containsOpcode(words, SpirvOp.ULessThan));
    try testing.expect(!containsOpcode(words, SpirvOp.LogicalOr));
    try testing.expect(!containsOpcode(words, SpirvOp.LogicalAnd));
}

test "spirv codegen emits float != and a float truth test unordered" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const bool_type = try ArithDialect.getScalarType(&ctx, .bool);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const i32_type = try ArithDialect.getScalarType(&ctx, .i32);
    const bool_memref = try MemrefDialect.getMemrefTypeDynamic(&ctx, bool_type, .device);
    const f32_memref = try MemrefDialect.getMemrefTypeDynamic(&ctx, f32_type, .device);
    const i32_memref = try MemrefDialect.getMemrefTypeDynamic(&ctx, i32_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel_unequal", &.{ bool_memref, f32_memref, i32_memref });
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);

    const f32_value = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(1), gid.getResult(), f32_type);
    try entry.addOperation(f32_value.op);
    const f32_cmp = try ArithDialect.CmpOp.create(&ctx, loc, .ne, f32_value.getResult(), f32_value.getResult());
    try entry.addOperation(f32_cmp.op);
    const store_cmp = try MemrefDialect.StoreOp.create(&ctx, loc, f32_cmp.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store_cmp.op);

    const truth = try ArithDialect.CastOp.create(&ctx, loc, f32_value.getResult(), bool_type);
    try entry.addOperation(truth.op);
    const store_truth = try MemrefDialect.StoreOp.create(&ctx, loc, truth.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store_truth.op);

    const i32_value = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(2), gid.getResult(), i32_type);
    try entry.addOperation(i32_value.op);
    const i32_zero = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 0);
    try entry.addOperation(i32_zero.op);
    const i32_cmp = try ArithDialect.CmpOp.create(&ctx, loc, .ne, i32_value.getResult(), i32_zero.getResult());
    try entry.addOperation(i32_cmp.op);
    const store_i32 = try MemrefDialect.StoreOp.create(&ctx, loc, i32_cmp.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store_i32.op);

    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    // A NaN is unequal to everything, itself included, and reads true, as
    // on a CPU. Only the integer comparison stays INotEqual.
    try testing.expectEqual(@as(usize, 2), countOpcode(words, SpirvOp.FUnordNotEqual));
    try testing.expect(!containsOpcode(words, SpirvOp.FOrdNotEqual));
    try testing.expect(containsOpcode(words, SpirvOp.INotEqual));
}

test "spirv codegen keeps subgroup barrier headers minimal" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "sync_warp_only", &.{});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const mask_const = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, -1);
    try entry.addOperation(mask_const.op);

    const sync = try GpuDialect.SyncWarpOp.create(&ctx, loc, mask_const.getResult());
    try entry.addOperation(sync.op);

    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();

    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    try testing.expectEqual(SpirvHeader.version, words[1]);
    try testing.expect(!containsCapability(words, SpvCapability.GroupNonUniform));
    try testing.expect(containsOpcode(words, SpirvOp.ControlBarrier));
}

test "spirv codegen decorates bindings for vector add kernel" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module = try buildVecAddKernelJob(&ctx);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();

    const words = try codegen.emitModuleWords(module);
    defer allocator.free(words);

    try testing.expectEqual(@as(usize, 3), countDecorations(words, SpvDecoration.Binding, null));
    try testing.expect(containsDecoration(words, SpvDecoration.Binding, 0));
    try testing.expect(containsDecoration(words, SpvDecoration.Binding, 1));
    try testing.expect(containsDecoration(words, SpvDecoration.Binding, 2));
    try testing.expectEqual(@as(usize, 3), countDecorations(words, SpvDecoration.DescriptorSet, 0));
    try testing.expect(containsOpcode(words, SpirvOp.IAdd));
    try testing.expect(containsOpcode(words, SpirvOp.Load));
    try testing.expect(containsOpcode(words, SpirvOp.Store));

    const bytes = try wordsToBytes(allocator, words);
    defer allocator.free(bytes);
    try maybeRunSpirvVal(bytes);
}

test "spirv codegen decorates bindings for reduction kernel" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const module = try buildReductionKernelJob(&ctx);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();

    const words = try codegen.emitModuleWords(module);
    defer allocator.free(words);

    try testing.expectEqual(SpirvVersion.v13, words[1]);
    try testing.expectEqual(@as(usize, 2), countDecorations(words, SpvDecoration.Binding, null));
    try testing.expect(containsDecoration(words, SpvDecoration.Binding, 0));
    try testing.expect(containsDecoration(words, SpvDecoration.Binding, 1));
    try testing.expectEqual(@as(usize, 2), countDecorations(words, SpvDecoration.DescriptorSet, 0));
    try testing.expect(containsOpcode(words, SpirvOp.GroupNonUniformIAdd));

    const bytes = try wordsToBytes(allocator, words);
    defer allocator.free(bytes);
    try maybeRunSpirvVal(bytes);
}

test "spirv codegen rejects non-full warp masks" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "mask_reject", &.{});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const i32_type = try ArithDialect.getI32Type(&ctx);
    const mask = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 0);
    try entry.addOperation(mask.op);
    const pred = try ArithDialect.ConstantOp.createBool(&ctx, loc, true);
    try entry.addOperation(pred.op);

    const all_sync = try GpuDialect.AllSyncOp.create(&ctx, loc, mask.getResult(), pred.getResult());
    try entry.addOperation(all_sync.op);

    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();

    try testing.expectError(error.UnsupportedMask, codegen.emitModuleWords(module.op));
}

const UnaryExtInstCase = struct {
    name: []const u8,
    opcode: u32,
    emit: *const fn (ctx: *ir.Context, entry: *ir.Block, x: *ir.Value) anyerror!*ir.Value,
};

const ScalarCapabilityCase = struct {
    elem: ArithDialect.ScalarTypeKind,
    cap: u32,
};

fn unary_test_body(comptime Op: type) type {
    return struct {
        fn emit(ctx: *ir.Context, entry: *ir.Block, x: *ir.Value) !*ir.Value {
            const loc = ir.Location.getUnknown();
            const op = try Op.create(ctx, loc, x);
            try entry.addOperation(op.op);
            return op.getResult();
        }
    };
}

fn integer_constant_test_body(comptime Op: type, comptime value: i64) type {
    return struct {
        fn emit(ctx: *ir.Context, entry: *ir.Block, x: *ir.Value) !*ir.Value {
            const loc = ir.Location.getUnknown();
            const i32_type = try ArithDialect.getScalarType(ctx, .i32);
            const constant = try ArithDialect.ConstantOp.createInt(ctx, loc, i32_type, value);
            try entry.addOperation(constant.op);
            const op = try Op.create(ctx, loc, x, constant.getResult());
            try entry.addOperation(op.op);
            return op.getResult();
        }
    };
}

fn emit_test_add(ctx: *ir.Context, entry: *ir.Block, x: *ir.Value) !*ir.Value {
    const loc = ir.Location.getUnknown();
    const add = try ArithDialect.AddOp.create(ctx, loc, x, x);
    try entry.addOperation(add.op);
    return add.getResult();
}

fn emit_test_fma_f32(ctx: *ir.Context, entry: *ir.Block, x: *ir.Value) !*ir.Value {
    const loc = ir.Location.getUnknown();
    const f32_type = try ArithDialect.getScalarType(ctx, .f32);
    const a = try ArithDialect.ConstantOp.createFloat(ctx, loc, f32_type, 2.0);
    try entry.addOperation(a.op);
    const b = try ArithDialect.ConstantOp.createFloat(ctx, loc, f32_type, 3.0);
    try entry.addOperation(b.op);
    const fma = try ArithDialect.FmaOp.create(ctx, loc, a.getResult(), b.getResult(), x);
    try entry.addOperation(fma.op);
    return fma.getResult();
}

fn emit_test_fma_f16(ctx: *ir.Context, entry: *ir.Block, x: *ir.Value) !*ir.Value {
    const loc = ir.Location.getUnknown();
    const fma = try ArithDialect.FmaOp.create(ctx, loc, x, x, x);
    try entry.addOperation(fma.op);
    return fma.getResult();
}

fn emit_test_fma_f64(ctx: *ir.Context, entry: *ir.Block, x: *ir.Value) !*ir.Value {
    const loc = ir.Location.getUnknown();
    const f64_type = try ArithDialect.getScalarType(ctx, .f64);
    const a = try ArithDialect.ConstantOp.createFloat(ctx, loc, f64_type, 1.0);
    try entry.addOperation(a.op);
    const b = try ArithDialect.ConstantOp.createFloat(ctx, loc, f64_type, 2.0);
    try entry.addOperation(b.op);
    const fma = try ArithDialect.FmaOp.create(ctx, loc, a.getResult(), b.getResult(), x);
    try entry.addOperation(fma.op);
    return fma.getResult();
}

fn emitArithKernelWords(
    allocator: std.mem.Allocator,
    elem_kind: ArithDialect.ScalarTypeKind,
    body: anytype,
) ![]u32 {
    return emitArithKernelWordsWithControls(allocator, elem_kind, body, .{});
}

fn emitArithKernelWordsWithControls(
    allocator: std.mem.Allocator,
    elem_kind: ArithDialect.ScalarTypeKind,
    body: anytype,
    controls: FloatControls,
) ![]u32 {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    const elem_type = try ArithDialect.getScalarType(&ctx, elem_kind);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, elem_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{memref_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);

    const load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), elem_type);
    try entry.addOperation(load.op);

    const stored = try body(&ctx, entry, load.getResult());

    const store = try MemrefDialect.StoreOp.create(&ctx, loc, stored, func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);

    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    codegen.float_controls = controls;
    return codegen.emitModuleWords(module.op);
}

fn isDecorated(words: []const u32, result_id: u32, decoration: u32) bool {
    var i: usize = 5;
    while (i < words.len) {
        const count: usize = @intCast(words[i] >> 16);
        if (count == 0 or i + count > words.len) return false;
        if (@as(u16, @truncate(words[i])) == SpirvOp.Decorate and count >= 3 and
            words[i + 1] == result_id and words[i + 2] == decoration) return true;
        i += count;
    }
    return false;
}

fn hasFloatExecutionMode(words: []const u32, mode: u32, width: u32) bool {
    var i: usize = 5;
    while (i < words.len) {
        const count: usize = @intCast(words[i] >> 16);
        if (count == 0 or i + count > words.len) return false;
        if (@as(u16, @truncate(words[i])) == SpirvOp.ExecutionMode and count == 4 and
            words[i + 2] == mode and words[i + 3] == width) return true;
        i += count;
    }
    return false;
}

test "spirv float arithmetic carries NoContraction and selected execution modes" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const controls = FloatControls{
        .denorm_preserve = .{ .f32 = true },
        .signed_zero_inf_nan_preserve = .{ .f32 = true },
    };
    const words = try emitArithKernelWordsWithControls(allocator, .f32, emit_test_add, controls);
    defer allocator.free(words);
    const add_at = firstOpcodeIndex(words, SpirvOp.FAdd) orelse return error.TestExpectedFloatAdd;
    try testing.expect(isDecorated(words, words[add_at + 2], SpvDecoration.NoContraction));
    try testing.expect(hasFloatExecutionMode(words, SpvExecutionMode.DenormPreserve, 32));
    try testing.expect(hasFloatExecutionMode(words, SpvExecutionMode.SignedZeroInfNanPreserve, 32));
    try testing.expect(!hasFloatExecutionMode(words, SpvExecutionMode.DenormPreserve, 16));
    try testing.expect(containsCapability(words, SpvCapability.DenormPreserve));
    try testing.expect(containsCapability(words, SpvCapability.SignedZeroInfNanPreserve));

    const fma = try emitArithKernelWords(allocator, .f32, emit_test_fma_f32);
    defer allocator.free(fma);
    const ext_at = firstOpcodeIndex(fma, SpirvOp.ExtInst) orelse return error.TestExpectedExtInst;
    try testing.expect(isDecorated(fma, fma[ext_at + 2], SpvDecoration.NoContraction));

    const ints = try emitArithKernelWords(allocator, .i32, emit_test_add);
    defer allocator.free(ints);
    const int_at = firstOpcodeIndex(ints, SpirvOp.IAdd) orelse return error.TestExpectedIntegerAdd;
    try testing.expect(!isDecorated(ints, ints[int_at + 2], SpvDecoration.NoContraction));
}

test "spirv round-to-nearest-even is declared for the widths asked and no others" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const words = try emitArithKernelWordsWithControls(allocator, .f32, emit_test_add, .{ .rounding_rte = .{ .f32 = true } });
    defer allocator.free(words);
    try testing.expect(hasFloatExecutionMode(words, SpvExecutionMode.RoundingModeRTE, 32));
    try testing.expect(!hasFloatExecutionMode(words, SpvExecutionMode.RoundingModeRTE, 16));
    try testing.expect(!hasFloatExecutionMode(words, SpvExecutionMode.RoundingModeRTE, 64));
    try testing.expect(!hasFloatExecutionMode(words, SpvExecutionMode.DenormPreserve, 32));
    try testing.expect(containsCapability(words, SpvCapability.RoundingModeRTE));

    const kept = FloatControls{
        .denorm_preserve = .{ .f32 = true },
        .signed_zero_inf_nan_preserve = .{ .f32 = true },
    };
    const without = try emitArithKernelWordsWithControls(allocator, .f32, emit_test_add, kept);
    defer allocator.free(without);
    try testing.expect(!hasFloatExecutionMode(without, SpvExecutionMode.RoundingModeRTE, 32));
    try testing.expect(!containsCapability(without, SpvCapability.RoundingModeRTE));
}

fn findExtInstImportId(words: []const u32, set_name: []const u8) ?u32 {
    if (words.len < 6) return null;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count: usize = @intCast(word >> 16);
        const op = @as(u16, @truncate(word));
        if (op == SpirvOp.ExtInstImport and word_count >= 3 and i + word_count <= words.len) {
            const id = words[i + 1];
            const string_words = word_count - 2;
            var matches = true;
            var name_idx: usize = 0;
            var w: usize = 0;
            outer: while (w < string_words) : (w += 1) {
                const word_value = words[i + 2 + w];
                var byte_idx: u5 = 0;
                while (byte_idx < 4) : (byte_idx += 1) {
                    const byte: u8 = @truncate(word_value >> (8 * @as(u5, byte_idx)));
                    if (byte == 0) {
                        if (name_idx != set_name.len) matches = false;
                        break :outer;
                    }
                    if (name_idx >= set_name.len or set_name[name_idx] != byte) {
                        matches = false;
                        break :outer;
                    }
                    name_idx += 1;
                }
            }
            if (matches) return id;
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return null;
}

fn containsExtInst(words: []const u32, set_id: u32, ext_opcode: u32) bool {
    if (words.len < 6) return false;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count: usize = @intCast(word >> 16);
        const op = @as(u16, @truncate(word));
        if (op == SpirvOp.ExtInst and word_count >= 5 and i + word_count <= words.len) {
            if (words[i + 3] == set_id and words[i + 4] == ext_opcode) return true;
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return false;
}

fn firstOpcodeIndex(words: []const u32, opcode: u16) ?usize {
    if (words.len < 5) return null;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op = @as(u16, @truncate(word));
        if (op == opcode) return i;
        if (word_count == 0) break;
        i += word_count;
    }
    return null;
}

test "spirv codegen emits arith.neg via core SNegate / FNegate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const f32_words = try emitArithKernelWords(allocator, .f32, unary_test_body(ArithDialect.NegOp).emit);
    defer allocator.free(f32_words);
    try testing.expect(containsOpcode(f32_words, SpirvOp.FNegate));

    const i32_words = try emitArithKernelWords(allocator, .i32, unary_test_body(ArithDialect.NegOp).emit);
    defer allocator.free(i32_words);
    try testing.expect(containsOpcode(i32_words, SpirvOp.SNegate));
}

test "spirv codegen emits arith.neg over unsigned integers as zero subtract" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const words = try emitArithKernelWords(allocator, .u32, unary_test_body(ArithDialect.NegOp).emit);
    defer allocator.free(words);
    try testing.expect(containsOpcode(words, SpirvOp.ISub));
    try testing.expect(!containsOpcode(words, SpirvOp.SNegate));
    try testing.expect(!containsOpcode(words, SpirvOp.FNegate));
}

test "spirv codegen emits arith.exp / log / tanh via GLSL.std.450" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cases: []const UnaryExtInstCase = &.{
        .{
            .name = "exp",
            .opcode = GLSLstd450.Exp,
            .emit = unary_test_body(ArithDialect.ExpOp).emit,
        },
        .{
            .name = "log",
            .opcode = GLSLstd450.Log,
            .emit = unary_test_body(ArithDialect.LogOp).emit,
        },
        .{
            .name = "tanh",
            .opcode = GLSLstd450.Tanh,
            .emit = unary_test_body(ArithDialect.TanhOp).emit,
        },
    };

    for (cases) |case| {
        const words = try emitArithKernelWords(allocator, .f32, case.emit);
        defer allocator.free(words);

        const set_id = findExtInstImportId(words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
        try testing.expect(containsExtInst(words, set_id, case.opcode));

        const import_idx = firstOpcodeIndex(words, SpirvOp.ExtInstImport) orelse return error.TestExpectedImport;
        const mem_model_idx = firstOpcodeIndex(words, SpirvOp.MemoryModel) orelse return error.TestExpectedMemoryModel;
        try testing.expect(import_idx < mem_model_idx);
    }
}

test "spirv codegen rejects arith.exp on f64 (GLSL.std.450 requires 16/32-bit)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    const f64_type = try ArithDialect.getScalarType(&ctx, .f64);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, f64_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{memref_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), f64_type);
    try entry.addOperation(load.op);
    const exp = try ArithDialect.ExpOp.create(&ctx, loc, load.getResult());
    try entry.addOperation(exp.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, exp.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    try testing.expectError(error.UnsupportedType, codegen.emitModuleWords(module.op));
}

test "spirv codegen emits arith.max / arith.min via GLSL.std.450" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const f32_max_words = try emitMinMaxKernel(allocator, .f32, .max);
    defer allocator.free(f32_max_words);
    {
        const set_id = findExtInstImportId(f32_max_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
        try testing.expect(containsExtInst(f32_max_words, set_id, GLSLstd450.NMax));
        try testing.expect(!containsExtInst(f32_max_words, set_id, GLSLstd450.FMax));
    }

    const f32_min_words = try emitMinMaxKernel(allocator, .f32, .min);
    defer allocator.free(f32_min_words);
    {
        const set_id = findExtInstImportId(f32_min_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
        try testing.expect(containsExtInst(f32_min_words, set_id, GLSLstd450.NMin));
        try testing.expect(!containsExtInst(f32_min_words, set_id, GLSLstd450.FMin));
    }

    const i32_max_words = try emitMinMaxKernel(allocator, .i32, .max);
    defer allocator.free(i32_max_words);
    {
        const set_id = findExtInstImportId(i32_max_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
        try testing.expect(containsExtInst(i32_max_words, set_id, GLSLstd450.SMax));
    }

    const idx_min_words = try emitMinMaxKernel(allocator, .index, .min);
    defer allocator.free(idx_min_words);
    {
        const set_id = findExtInstImportId(idx_min_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
        try testing.expect(containsExtInst(idx_min_words, set_id, GLSLstd450.UMin));
    }
}

test "spirv codegen does not import GLSL.std.450 unless an ext-inst op is used" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const words = try emitArithKernelWords(allocator, .f32, emit_test_add);
    defer allocator.free(words);

    try testing.expectEqual(@as(?usize, null), firstOpcodeIndex(words, SpirvOp.ExtInstImport));
    try testing.expectEqual(@as(?u32, null), findExtInstImportId(words, "GLSL.std.450"));
}

test "spirv codegen requires Float64 capability for f64 kernels" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const words = try emitArithKernelWords(allocator, .f64, emit_test_add);
    defer allocator.free(words);

    try testing.expect(containsCapability(words, SpvCapability.Float64));
    try testing.expect(!containsCapability(words, SpvCapability.Float16));
    try testing.expect(!containsCapability(words, SpvCapability.Int64));
}

test "spirv codegen requires Float16 capability for f16 kernels" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const words = try emitArithKernelWords(allocator, .f16, emit_test_add);
    defer allocator.free(words);

    try testing.expect(containsCapability(words, SpvCapability.Float16));
    try testing.expect(!containsCapability(words, SpvCapability.Float64));
}

test "spirv codegen requires Int8 / Int16 / Int64 capabilities" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cases: []const ScalarCapabilityCase = &.{
        .{ .elem = .i8, .cap = SpvCapability.Int8 },
        .{ .elem = .i16, .cap = SpvCapability.Int16 },
        .{ .elem = .i64, .cap = SpvCapability.Int64 },
    };

    for (cases) |case| {
        const words = try emitArithKernelWords(allocator, case.elem, emit_test_add);
        defer allocator.free(words);
        try testing.expect(containsCapability(words, case.cap));
    }
}

test "spirv codegen does not require non-32-bit capabilities for f32 / i32 / index kernels" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cases = [_]ArithDialect.ScalarTypeKind{ .f32, .i32, .index };
    for (cases) |elem| {
        const words = try emitArithKernelWords(allocator, elem, emit_test_add);
        defer allocator.free(words);
        try testing.expect(!containsCapability(words, SpvCapability.Float16));
        try testing.expect(!containsCapability(words, SpvCapability.Float64));
        try testing.expect(!containsCapability(words, SpvCapability.Int8));
        try testing.expect(!containsCapability(words, SpvCapability.Int16));
        try testing.expect(!containsCapability(words, SpvCapability.Int64));
    }
}

test "spirv codegen emits arith.sqrt over f32 / f64 via GLSL.std.450" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const f32_words = try emitArithKernelWords(allocator, .f32, unary_test_body(ArithDialect.SqrtOp).emit);
    defer allocator.free(f32_words);
    {
        const set_id = findExtInstImportId(f32_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
        try testing.expect(containsExtInst(f32_words, set_id, GLSLstd450.Sqrt));
    }

    const f64_words = try emitArithKernelWords(allocator, .f64, unary_test_body(ArithDialect.SqrtOp).emit);
    defer allocator.free(f64_words);
    {
        try testing.expect(containsCapability(f64_words, SpvCapability.Float64));
        const set_id = findExtInstImportId(f64_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
        try testing.expect(containsExtInst(f64_words, set_id, GLSLstd450.Sqrt));
    }
}

test "spirv codegen emits arith.abs as FAbs / SAbs and aliases unsigned" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const f32_words = try emitArithKernelWords(allocator, .f32, unary_test_body(ArithDialect.AbsOp).emit);
    defer allocator.free(f32_words);
    {
        const set_id = findExtInstImportId(f32_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
        try testing.expect(containsExtInst(f32_words, set_id, GLSLstd450.FAbs));
        try testing.expect(!containsExtInst(f32_words, set_id, GLSLstd450.SAbs));
    }

    const i32_words = try emitArithKernelWords(allocator, .i32, unary_test_body(ArithDialect.AbsOp).emit);
    defer allocator.free(i32_words);
    {
        const set_id = findExtInstImportId(i32_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
        try testing.expect(containsExtInst(i32_words, set_id, GLSLstd450.SAbs));
        try testing.expect(!containsExtInst(i32_words, set_id, GLSLstd450.FAbs));
    }

    const u32_words = try emitArithKernelWords(allocator, .u32, unary_test_body(ArithDialect.AbsOp).emit);
    defer allocator.free(u32_words);
    try testing.expect(!containsOpcode(u32_words, SpirvOp.ExtInst));
}

test "spirv codegen emits arith.exp over f16 (Float16 capability now wired)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const words = try emitArithKernelWords(allocator, .f16, unary_test_body(ArithDialect.ExpOp).emit);
    defer allocator.free(words);

    try testing.expect(containsCapability(words, SpvCapability.Float16));
    const set_id = findExtInstImportId(words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
    try testing.expect(containsExtInst(words, set_id, GLSLstd450.Exp));
}

test "spirv codegen emits arith.sin / cos / tan / floor / trunc via GLSL.std.450" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const cases: []const UnaryExtInstCase = &.{
        .{
            .opcode = GLSLstd450.Sin,
            .name = "sin",
            .emit = unary_test_body(ArithDialect.SinOp).emit,
        },
        .{
            .opcode = GLSLstd450.Cos,
            .name = "cos",
            .emit = unary_test_body(ArithDialect.CosOp).emit,
        },
        .{
            .opcode = GLSLstd450.Tan,
            .name = "tan",
            .emit = unary_test_body(ArithDialect.TanOp).emit,
        },
        .{
            .opcode = GLSLstd450.Floor,
            .name = "floor",
            .emit = unary_test_body(ArithDialect.FloorOp).emit,
        },
        .{
            .opcode = GLSLstd450.Trunc,
            .name = "trunc",
            .emit = unary_test_body(ArithDialect.TruncOp).emit,
        },
    };

    for (cases) |case| {
        const f32_words = try emitArithKernelWords(allocator, .f32, case.emit);
        defer allocator.free(f32_words);
        const set_id = findExtInstImportId(f32_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
        try testing.expect(containsExtInst(f32_words, set_id, case.opcode));

        const f16_words = try emitArithKernelWords(allocator, .f16, case.emit);
        defer allocator.free(f16_words);
        try testing.expect(containsCapability(f16_words, SpvCapability.Float16));
        const f16_set_id = findExtInstImportId(f16_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
        try testing.expect(containsExtInst(f16_words, f16_set_id, case.opcode));
    }
}

test "spirv codegen emits arith.round as sign-preserving floor composition" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const f32_words = try emitArithKernelWords(allocator, .f32, unary_test_body(ArithDialect.RoundOp).emit);
    defer allocator.free(f32_words);
    const set_id = findExtInstImportId(f32_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
    try testing.expect(containsExtInst(f32_words, set_id, GLSLstd450.FAbs));
    try testing.expect(containsExtInst(f32_words, set_id, GLSLstd450.Floor));
    try testing.expect(containsOpcode(f32_words, SpirvOp.BitwiseAnd));
    try testing.expect(containsOpcode(f32_words, SpirvOp.BitwiseOr));
    try testing.expect(containsOpcode(f32_words, SpirvOp.Bitcast));

    const f16_words = try emitArithKernelWords(allocator, .f16, unary_test_body(ArithDialect.RoundOp).emit);
    defer allocator.free(f16_words);
    try testing.expect(containsCapability(f16_words, SpvCapability.Float16));
    try testing.expect(containsCapability(f16_words, SpvCapability.Int16));
    const f16_set_id = findExtInstImportId(f16_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
    try testing.expect(containsExtInst(f16_words, f16_set_id, GLSLstd450.FAbs));
    try testing.expect(containsExtInst(f16_words, f16_set_id, GLSLstd450.Floor));
    try testing.expect(containsOpcode(f16_words, SpirvOp.BitwiseAnd));
    try testing.expect(containsOpcode(f16_words, SpirvOp.BitwiseOr));
    try testing.expect(containsOpcode(f16_words, SpirvOp.Bitcast));
}

test "spirv codegen rejects arith.sin on f64" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const f64_type = try ArithDialect.getScalarType(&ctx, .f64);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, f64_type, .device);
    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{memref_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), f64_type);
    try entry.addOperation(load.op);
    const sin = try ArithDialect.SinOp.create(&ctx, loc, load.getResult());
    try entry.addOperation(sin.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, sin.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    try testing.expectError(error.UnsupportedType, codegen.emitModuleWords(module.op));
}

test "spirv codegen emits arith.pow and arith.atan2 as binary OpExtInst" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, f32_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{ memref_type, memref_type });
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const base_load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), f32_type);
    try entry.addOperation(base_load.op);
    const exp_load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(1), gid.getResult(), f32_type);
    try entry.addOperation(exp_load.op);
    const pow = try ArithDialect.PowOp.create(&ctx, loc, base_load.getResult(), exp_load.getResult());
    try entry.addOperation(pow.op);
    const atan2 = try ArithDialect.Atan2Op.create(&ctx, loc, pow.getResult(), exp_load.getResult());
    try entry.addOperation(atan2.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, atan2.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    const set_id = findExtInstImportId(words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
    try testing.expect(containsExtInst(words, set_id, GLSLstd450.Pow));
    try testing.expect(containsExtInst(words, set_id, GLSLstd450.Atan2));

    const wc = extInstWordCount(words, set_id, GLSLstd450.Pow) orelse return error.TestExpectedExtInst;
    try testing.expectEqual(@as(u32, 7), wc);
    const atan2_wc = extInstWordCount(words, set_id, GLSLstd450.Atan2) orelse return error.TestExpectedExtInst;
    try testing.expectEqual(@as(u32, 7), atan2_wc);
}

test "spirv codegen rejects arith.pow on f64" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const f64_type = try ArithDialect.getScalarType(&ctx, .f64);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, f64_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{ memref_type, memref_type });
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const a = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), f64_type);
    try entry.addOperation(a.op);
    const b = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(1), gid.getResult(), f64_type);
    try entry.addOperation(b.op);
    const pow = try ArithDialect.PowOp.create(&ctx, loc, a.getResult(), b.getResult());
    try entry.addOperation(pow.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, pow.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    try testing.expectError(error.UnsupportedType, codegen.emitModuleWords(module.op));
}

test "spirv codegen emits arith.abs over f64 with Float64 capability" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const words = try emitArithKernelWords(allocator, .f64, unary_test_body(ArithDialect.AbsOp).emit);
    defer allocator.free(words);

    try testing.expect(containsCapability(words, SpvCapability.Float64));
    const set_id = findExtInstImportId(words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
    try testing.expect(containsExtInst(words, set_id, GLSLstd450.FAbs));
}

test "spirv codegen emits arith.and / or / xor via OpBitwise{And,Or,Xor}" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const and_words = try emitArithKernelWords(
        allocator,
        .i32,
        integer_constant_test_body(ArithDialect.AndOp, 1).emit,
    );
    defer allocator.free(and_words);
    try testing.expect(containsOpcode(and_words, SpirvOp.BitwiseAnd));

    const or_words = try emitArithKernelWords(
        allocator,
        .i32,
        integer_constant_test_body(ArithDialect.OrOp, 1).emit,
    );
    defer allocator.free(or_words);
    try testing.expect(containsOpcode(or_words, SpirvOp.BitwiseOr));

    const xor_words = try emitArithKernelWords(
        allocator,
        .i32,
        integer_constant_test_body(ArithDialect.XorOp, 1).emit,
    );
    defer allocator.free(xor_words);
    try testing.expect(containsOpcode(xor_words, SpirvOp.BitwiseXor));
}

test "spirv codegen emits arith.not as OpNot" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const words = try emitArithKernelWords(allocator, .i32, unary_test_body(ArithDialect.NotOp).emit);
    defer allocator.free(words);
    try testing.expect(containsOpcode(words, SpirvOp.Not));
}

test "spirv codegen emits arith.not over bool as OpLogicalNot" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const words = try emitArithKernelWords(allocator, .bool, unary_test_body(ArithDialect.NotOp).emit);
    defer allocator.free(words);
    try testing.expect(containsOpcode(words, SpirvOp.LogicalNot));
}

test "spirv codegen emits arith.shl / shr / ushr via OpShift{LeftLogical,RightArithmetic,RightLogical}" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const shl_words = try emitArithKernelWords(
        allocator,
        .i32,
        integer_constant_test_body(ArithDialect.ShlOp, 2).emit,
    );
    defer allocator.free(shl_words);
    try testing.expect(containsOpcode(shl_words, SpirvOp.ShiftLeftLogical));

    const shr_words = try emitArithKernelWords(
        allocator,
        .i32,
        integer_constant_test_body(ArithDialect.ShrOp, 2).emit,
    );
    defer allocator.free(shr_words);
    try testing.expect(containsOpcode(shr_words, SpirvOp.ShiftRightArithmetic));

    const ushr_words = try emitArithKernelWords(
        allocator,
        .i32,
        integer_constant_test_body(ArithDialect.UshrOp, 2).emit,
    );
    defer allocator.free(ushr_words);
    try testing.expect(containsOpcode(ushr_words, SpirvOp.ShiftRightLogical));
}

test "spirv codegen rejects arith.shr over arith.index (unsigned + arithmetic shift mismatch)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const idx_type = try ArithDialect.getIndexType(&ctx);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, idx_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{memref_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), idx_type);
    try entry.addOperation(load.op);
    const c = try ArithDialect.ConstantOp.createInt(&ctx, loc, idx_type, 2);
    try entry.addOperation(c.op);
    const shr = try ArithDialect.ShrOp.create(&ctx, loc, load.getResult(), c.getResult());
    try entry.addOperation(shr.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, shr.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    try testing.expectError(error.UnsupportedType, codegen.emitModuleWords(module.op));
}

test "spirv codegen rejects arith.and over float (bitwise needs arith.bitcast first)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, f32_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{memref_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), f32_type);
    try entry.addOperation(load.op);
    const c = try ArithDialect.ConstantOp.createFloat(&ctx, loc, f32_type, 1.0);
    try entry.addOperation(c.op);
    const op = try ArithDialect.AndOp.create(&ctx, loc, load.getResult(), c.getResult());
    try entry.addOperation(op.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, op.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    try testing.expectError(error.UnsupportedType, codegen.emitModuleWords(module.op));
}

test "spirv codegen rejects arith.shl with width-mismatched shift count (cross-backend strict-equality policy)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const i32_type = try ArithDialect.getScalarType(&ctx, .i32);
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, i32_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{memref_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), i32_type);
    try entry.addOperation(load.op);
    const c64 = try ArithDialect.ConstantOp.createInt(&ctx, loc, i64_type, 2);
    try entry.addOperation(c64.op);
    const shl = try ArithDialect.ShlOp.create(&ctx, loc, load.getResult(), c64.getResult());
    try entry.addOperation(shl.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, shl.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    try testing.expectError(error.UnsupportedType, codegen.emitModuleWords(module.op));
}

test "spirv codegen capability dedup: requireCapability emits at most once" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();

    try codegen.requireCapability(SpvCapability.Float64);
    try codegen.requireCapability(SpvCapability.Float64);

    const words = try codegen.builder.toWords(allocator);
    defer allocator.free(words);

    try testing.expectEqual(@as(usize, 1), countCapability(words, SpvCapability.Float64));
    try testing.expectEqual(@as(usize, 0), countCapability(words, SpvCapability.Float16));
}

test "spirv codegen emits OpConvertUToF for arith.cast index → f32 (iota lowering shape)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, f32_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{memref_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const cast = try ArithDialect.CastOp.create(&ctx, loc, gid.getResult(), f32_type);
    try entry.addOperation(cast.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, cast.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    try testing.expect(containsOpcode(words, SpirvOp.ConvertUToF));
}

test "spirv codegen emits OpBitcast for arith.bitcast i32 -> f32 (different kinds, same width)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const i32_type = try ArithDialect.getScalarType(&ctx, .i32);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const i32_memref = try MemrefDialect.getMemrefTypeDynamic(&ctx, i32_type, .device);
    const f32_memref = try MemrefDialect.getMemrefTypeDynamic(&ctx, f32_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{ i32_memref, f32_memref });
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), i32_type);
    try entry.addOperation(load.op);
    const bc = try ArithDialect.BitcastOp.create(&ctx, loc, load.getResult(), f32_type);
    try entry.addOperation(bc.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, bc.getResult(), func.getArgument(1), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    try testing.expect(containsOpcode(words, SpirvOp.Bitcast));
}

test "spirv codegen aliases same-kind arith.bitcast (no OpBitcast emission)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);
    const f32_memref = try MemrefDialect.getMemrefTypeDynamic(&ctx, f32_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{f32_memref});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), f32_type);
    try entry.addOperation(load.op);
    const bc = try ArithDialect.BitcastOp.create(&ctx, loc, load.getResult(), f32_type);
    try entry.addOperation(bc.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, bc.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    try testing.expect(!containsOpcode(words, SpirvOp.Bitcast));
}

test "spirv codegen rejects arith.bitcast over arith.bool" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const bool_type = try ArithDialect.getScalarType(&ctx, .bool);
    const i64_type = try ArithDialect.getScalarType(&ctx, .i64);
    const bool_memref = try MemrefDialect.getMemrefTypeDynamic(&ctx, bool_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{bool_memref});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), bool_type);
    try entry.addOperation(load.op);
    const bc = try ArithDialect.BitcastOp.create(&ctx, loc, load.getResult(), i64_type);
    try entry.addOperation(bc.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, bc.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    try testing.expectError(error.UnsupportedType, codegen.emitModuleWords(module.op));
}

test "spirv codegen emits OpExtInst Fma for arith.fma over f32" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const f32_words = try emitArithKernelWords(allocator, .f32, emit_test_fma_f32);
    defer allocator.free(f32_words);

    const set_id = findExtInstImportId(f32_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
    try testing.expect(containsExtInst(f32_words, set_id, GLSLstd450.Fma));
    const wc = extInstWordCount(f32_words, set_id, GLSLstd450.Fma) orelse return error.TestExpectedExtInst;
    try testing.expectEqual(@as(u32, 8), wc);
}

test "spirv codegen emits arith.fma over f16 with Float16 capability" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const f16_words = try emitArithKernelWords(allocator, .f16, emit_test_fma_f16);
    defer allocator.free(f16_words);

    try testing.expect(containsCapability(f16_words, SpvCapability.Float16));
    const set_id = findExtInstImportId(f16_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
    try testing.expect(containsExtInst(f16_words, set_id, GLSLstd450.Fma));
}

test "spirv codegen emits arith.fma over f64 with Float64 capability" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const f64_words = try emitArithKernelWords(allocator, .f64, emit_test_fma_f64);
    defer allocator.free(f64_words);

    try testing.expect(containsCapability(f64_words, SpvCapability.Float64));
    const set_id = findExtInstImportId(f64_words, "GLSL.std.450") orelse return error.TestExpectedGlslImport;
    try testing.expect(containsExtInst(f64_words, set_id, GLSLstd450.Fma));
}

test "spirv codegen rejects arith.fma over integer types" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const i32_type = try ArithDialect.getScalarType(&ctx, .i32);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, i32_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{memref_type});
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), i32_type);
    try entry.addOperation(load.op);
    const a = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 2);
    try entry.addOperation(a.op);
    const b = try ArithDialect.ConstantOp.createInt(&ctx, loc, i32_type, 3);
    try entry.addOperation(b.op);
    const fma = try ArithDialect.FmaOp.create(&ctx, loc, a.getResult(), b.getResult(), load.getResult());
    try entry.addOperation(fma.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, fma.getResult(), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    try testing.expectError(error.UnsupportedType, codegen.emitModuleWords(module.op));
}

test "spirv codegen rejects width-mismatched arith.bitcast (i32 -> f64)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    const i32_type = try ArithDialect.getScalarType(&ctx, .i32);
    const f64_type = try ArithDialect.getScalarType(&ctx, .f64);
    const i32_memref = try MemrefDialect.getMemrefTypeDynamic(&ctx, i32_type, .device);
    const f64_memref = try MemrefDialect.getMemrefTypeDynamic(&ctx, f64_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{ i32_memref, f64_memref });
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), i32_type);
    try entry.addOperation(load.op);
    const bc = try ArithDialect.BitcastOp.create(&ctx, loc, load.getResult(), f64_type);
    try entry.addOperation(bc.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, bc.getResult(), func.getArgument(1), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    try testing.expectError(error.UnsupportedType, codegen.emitModuleWords(module.op));
}

fn emitMinMaxKernel(
    allocator: std.mem.Allocator,
    elem_kind: ArithDialect.ScalarTypeKind,
    op_kind: enum { max, min },
) ![]u32 {
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    const elem_type = try ArithDialect.getScalarType(&ctx, elem_kind);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, elem_type, .device);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{ memref_type, memref_type });
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const lhs_load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(0), gid.getResult(), elem_type);
    try entry.addOperation(lhs_load.op);
    const rhs_load = try MemrefDialect.LoadOp.create(&ctx, loc, func.getArgument(1), gid.getResult(), elem_type);
    try entry.addOperation(rhs_load.op);

    const stored = switch (op_kind) {
        .max => blk: {
            const op = try ArithDialect.MaxOp.create(&ctx, loc, lhs_load.getResult(), rhs_load.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
        .min => blk: {
            const op = try ArithDialect.MinOp.create(&ctx, loc, lhs_load.getResult(), rhs_load.getResult());
            try entry.addOperation(op.op);
            break :blk op.getResult();
        },
    };

    const store = try MemrefDialect.StoreOp.create(&ctx, loc, stored, func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    return codegen.emitModuleWords(module.op);
}

test "spirv codegen lowers scalar arguments to one push constant block" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);

    const memref_elem = try ArithDialect.getScalarType(&ctx, .f32);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, memref_elem, .device);
    const u32_type = try ArithDialect.getScalarType(&ctx, .u32);
    const f32_type = try ArithDialect.getScalarType(&ctx, .f32);

    var func = try FuncDialect.FuncOp.createKernel(&ctx, loc, "kernel", &.{ memref_type, u32_type, f32_type });
    try module.getBodyBlock().addOperation(func.op);

    const entry = func.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);

    const store = try MemrefDialect.StoreOp.create(&ctx, loc, func.getArgument(2), func.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);

    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();

    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    try testing.expect(containsOpcode(words, SpirvOp.SpecConstant));
    try testing.expect(containsOpcode(words, SpirvOp.SpecConstantComposite));
    try testing.expect(containsVariableWithStorageClass(words, SpvStorageClass.PushConstant));
    try testing.expectEqual(@as(usize, 1), countBindingDecorations(words));
    try testing.expect(containsMemberOffset(words, 0));
    try testing.expect(containsMemberOffset(words, 4));
}

fn containsVariableWithStorageClass(words: []const u32, storage_class: u32) bool {
    if (words.len < 5) return false;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op = @as(u16, @truncate(word));
        if (op == SpirvOp.Variable and word_count >= 4 and words[i + 3] == storage_class) return true;
        if (word_count == 0) break;
        i += word_count;
    }
    return false;
}

fn countBindingDecorations(words: []const u32) usize {
    if (words.len < 5) return 0;
    var count: usize = 0;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op = @as(u16, @truncate(word));
        if (op == SpirvOp.Decorate and word_count == 4 and words[i + 2] == SpvDecoration.Binding) count += 1;
        if (word_count == 0) break;
        i += word_count;
    }
    return count;
}

fn containsMemberOffset(words: []const u32, offset: u32) bool {
    if (words.len < 5) return false;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op = @as(u16, @truncate(word));
        if (op == SpirvOp.MemberDecorate and word_count == 5 and words[i + 3] == SpvDecoration.Offset and words[i + 4] == offset) return true;
        if (word_count == 0) break;
        i += word_count;
    }
    return false;
}

fn containsOpcode(words: []const u32, opcode: u16) bool {
    if (words.len < 5) return false;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op = @as(u16, @truncate(word));
        if (op == opcode) return true;
        if (word_count == 0) break;
        i += word_count;
    }
    return false;
}

fn countOpcode(words: []const u32, opcode: u16) usize {
    if (words.len < 5) return 0;
    var count: usize = 0;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        if (@as(u16, @truncate(word)) == opcode) count += 1;
        if (word_count == 0) break;
        i += word_count;
    }
    return count;
}

fn loopMergesImmediatelyPrecedeBranches(words: []const u32) bool {
    if (words.len < 5) return false;
    var found = false;
    var i: usize = 5;
    while (i < words.len) {
        const word_count = words[i] >> 16;
        const op = @as(u16, @truncate(words[i]));
        if (op == SpirvOp.LoopMerge) {
            found = true;
            const next = i + word_count;
            if (next >= words.len) return false;
            const next_op = @as(u16, @truncate(words[next]));
            if (next_op != SpirvOp.Branch and next_op != SpirvOp.BranchConditional) return false;
        }
        if (word_count == 0) return false;
        i += word_count;
    }
    return found;
}

fn findTypeBool(words: []const u32) ?u32 {
    if (words.len < 5) return null;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op = @as(u16, @truncate(word));
        if (op == SpirvOp.TypeBool and word_count == 2 and i + 1 < words.len) return words[i + 1];
        if (word_count == 0) break;
        i += word_count;
    }
    return null;
}

fn findTypeInt(words: []const u32, width: u32, signedness: u32) ?u32 {
    if (words.len < 5) return null;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op = @as(u16, @truncate(word));
        if (op == SpirvOp.TypeInt and word_count == 4 and i + 3 < words.len and words[i + 2] == width and words[i + 3] == signedness) {
            return words[i + 1];
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return null;
}

fn containsRuntimeArrayElement(words: []const u32, elem_type_id: u32) bool {
    if (words.len < 5) return false;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op = @as(u16, @truncate(word));
        if (op == SpirvOp.TypeRuntimeArray and word_count == 3 and i + 2 < words.len and words[i + 2] == elem_type_id) {
            return true;
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return false;
}

fn containsCapability(words: []const u32, capability: u32) bool {
    if (words.len < 6) return false;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op = @as(u16, @truncate(word));
        if (op == SpirvOp.Capability and word_count >= 2 and i + 1 < words.len) {
            if (words[i + 1] == capability) return true;
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return false;
}

fn containsExtension(words: []const u32, extension: []const u8) bool {
    if (words.len < 6) return false;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op = @as(u16, @truncate(word));
        if (op == SpirvOp.Extension and word_count >= 2 and i + word_count <= words.len) {
            const bytes = std.mem.sliceAsBytes(words[i + 1 .. i + word_count]);
            const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
            if (std.mem.eql(u8, bytes[0..end], extension)) return true;
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return false;
}

fn countCapability(words: []const u32, capability: u32) usize {
    if (words.len < 6) return 0;
    var i: usize = 5;
    var count: usize = 0;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op = @as(u16, @truncate(word));
        if (op == SpirvOp.Capability and word_count >= 2 and i + 1 < words.len) {
            if (words[i + 1] == capability) count += 1;
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return count;
}

fn extInstWordCount(words: []const u32, set_id: u32, ext_opcode: u32) ?u32 {
    if (words.len < 6) return null;
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op = @as(u16, @truncate(word));
        if (op == SpirvOp.ExtInst and word_count >= 5 and i + word_count <= words.len) {
            if (words[i + 3] == set_id and words[i + 4] == ext_opcode) return word_count;
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return null;
}

fn countDecorations(words: []const u32, decoration: u32, literal: ?u32) usize {
    if (words.len < 6) return 0;
    var i: usize = 5;
    var count: usize = 0;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op = @as(u16, @truncate(word));
        if (op == SpirvOp.Decorate and word_count >= 3 and i + 2 < words.len) {
            if (words[i + 2] == decoration) {
                if (literal) |value| {
                    if (word_count >= 4 and i + 3 < words.len and words[i + 3] == value) {
                        count += 1;
                    }
                } else {
                    count += 1;
                }
            }
        }
        if (word_count == 0) break;
        i += word_count;
    }
    return count;
}

fn containsDecoration(words: []const u32, decoration: u32, literal: u32) bool {
    return countDecorations(words, decoration, literal) > 0;
}

fn wordsToBytes(allocator: std.mem.Allocator, words: []const u32) ![]u8 {
    const byte_len = words.len * @sizeOf(u32);
    const bytes = try allocator.alloc(u8, byte_len);
    var offset: usize = 0;
    for (words) |word| {
        std.mem.writeInt(u32, bytes[offset..][0..4], word, .little);
        offset += 4;
    }
    return bytes;
}

/// Validates `bytes` with the spirv-val on the test runner's PATH, under the
/// Vulkan environment the module's version needs. A runner without spirv-val
/// skips the test rather than passing it, since its check did not run. choir's
/// spirv-val gate validates the shared fixtures with the pinned validator.
fn maybeRunSpirvVal(bytes: []const u8) !void {
    const testing = std.testing;
    const allocator = testing.allocator;
    const version = std.mem.readInt(u32, bytes[4..8], .little);
    const environment = try gpu_fixture.stages.spirvValEnvironment(version);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(tmp_dir);
    const spirv_path = try std.fmt.allocPrint(allocator, "{s}/spirv-val.spv", .{tmp_dir});
    defer allocator.free(spirv_path);

    try sys.fs.writeFile(spirv_path, bytes);

    const result = sys.process.run(allocator, testing.io, .{
        .argv = &.{ "spirv-val", "--target-env", environment, spirv_path },
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (sys.process.exitCode(result.term) != 0) return error.SpirvValFailed;
}

fn buildVecAddKernelJob(ir_ctx: *ir.Context) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const elem_type = try ArithDialect.getI32Type(ir_ctx);
    const memref_type = try MemrefDialect.getMemrefType1D(ir_ctx, 4, elem_type, .device);

    var kernel = try FuncDialect.FuncOp.createKernel(
        ir_ctx,
        loc,
        "vec_add",
        &.{ memref_type, memref_type, memref_type },
    );
    try module_block.addOperation(kernel.op);

    const entry = kernel.getEntryBlock();
    const a_arg = entry.arguments.items[0];
    const b_arg = entry.arguments.items[1];
    const c_arg = entry.arguments.items[2];

    const gid = try GpuDialect.GlobalIdxOp.create(ir_ctx, loc, .x);
    try entry.addOperation(gid.op);

    const load_a = try MemrefDialect.LoadOp.create(ir_ctx, loc, a_arg, gid.getResult(), elem_type);
    try entry.addOperation(load_a.op);
    const load_b = try MemrefDialect.LoadOp.create(ir_ctx, loc, b_arg, gid.getResult(), elem_type);
    try entry.addOperation(load_b.op);

    const add = try ArithDialect.AddOp.create(ir_ctx, loc, load_a.getResult(), load_b.getResult());
    try entry.addOperation(add.op);

    const store = try MemrefDialect.StoreOp.create(ir_ctx, loc, add.getResult(), c_arg, gid.getResult());
    try entry.addOperation(store.op);

    const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{});
    try entry.addOperation(ret.op);

    return module.op;
}

fn buildReductionKernelJob(ir_ctx: *ir.Context) !*ir.Operation {
    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(ir_ctx, loc);
    const module_block = module.getBodyBlock();

    const elem_type = try ArithDialect.getI32Type(ir_ctx);
    const index_type = try ArithDialect.getIndexType(ir_ctx);
    const memref_in = try MemrefDialect.getMemrefType1D(ir_ctx, 32, elem_type, .device);
    const memref_out = try MemrefDialect.getMemrefType1D(ir_ctx, 1, elem_type, .device);

    var kernel = try FuncDialect.FuncOp.createKernel(
        ir_ctx,
        loc,
        "reduce_sum",
        &.{ memref_in, memref_out },
    );
    try module_block.addOperation(kernel.op);

    const entry = kernel.getEntryBlock();
    const input_arg = entry.arguments.items[0];
    const output_arg = entry.arguments.items[1];

    const tid = try GpuDialect.ThreadIdxOp.create(ir_ctx, loc, .x);
    try entry.addOperation(tid.op);

    const load_in = try MemrefDialect.LoadOp.create(ir_ctx, loc, input_arg, tid.getResult(), elem_type);
    try entry.addOperation(load_in.op);

    const mask = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, elem_type, -1);
    try entry.addOperation(mask.op);

    const reduce = try GpuDialect.WarpReduceOp.create(ir_ctx, loc, .add, mask.getResult(), load_in.getResult());
    try entry.addOperation(reduce.op);

    const zero_idx = try ArithDialect.ConstantOp.createInt(ir_ctx, loc, index_type, 0);
    try entry.addOperation(zero_idx.op);

    const store_out = try MemrefDialect.StoreOp.create(ir_ctx, loc, reduce.getResult(), output_arg, zero_idx.getResult());
    try entry.addOperation(store_out.op);

    const ret = try FuncDialect.ReturnOp.create(ir_ctx, loc, &.{});
    try entry.addOperation(ret.op);

    return module.op;
}

const gpu_fixture = @import("../../fixture/root.zig");
const gpu_registration = @import("../../registration.zig");

test "spirv codegen writes a declared shape as LocalSize alone" {
    const allocator = std.testing.allocator;
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try gpu_registration.prepareCompilationDialects(&ctx);
    const module = try gpu_fixture.lower(&ctx, gpu_fixture.shaped, .spirv);
    defer module.erase();

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    const words = try codegen.emitModuleWords(module);
    defer allocator.free(words);

    var sizes: [2][3]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), localSizes(words, &sizes));
    try std.testing.expectEqual([3]u32{ 8, 8, 1 }, sizes[0]);
    try std.testing.expectEqual(@as(usize, 0), countSizeDecorations(words));
}

test "spirv codegen keeps the unit shape for a kernel that declares none" {
    const allocator = std.testing.allocator;
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const module = try buildVecAddKernelJob(&ctx);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    const words = try codegen.emitModuleWords(module);
    defer allocator.free(words);

    var sizes: [2][3]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), localSizes(words, &sizes));
    try std.testing.expectEqual([3]u32{ 1, 1, 1 }, sizes[0]);
    try std.testing.expectEqual([3]u32{ 1, 1, 1 }, try workgroupSizeDefaults(words));
}

test "spirv codegen emits different declared shapes and refuses mixed kernels" {
    const allocator = std.testing.allocator;
    const Case = struct { first: ?gpu_target.kernel.Shape, second: ?gpu_target.kernel.Shape };
    const cases = [_]Case{
        .{ .first = .{ 16, 4, 1 }, .second = .{ 16, 4, 1 } },
        .{ .first = .{ 16, 4, 1 }, .second = .{ 4, 16, 1 } },
        .{ .first = .{ 1, 1, 1 }, .second = .{ 8, 8, 1 } },
        .{ .first = .{ 8, 8, 1 }, .second = null },
        .{ .first = null, .second = .{ 8, 8, 1 } },
    };
    for (cases) |case| {
        var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
        defer ctx.deinit(allocator);
        const module = try BuiltinDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
        defer module.op.erase();
        const first = try addCopyKernel(&ctx, module, "first", .device);
        if (case.first) |shape| try gpu_target.kernel.setShape(first.op, &ctx, shape);
        const second = try addCopyKernel(&ctx, module, "second", .device);
        if (case.second) |shape| try gpu_target.kernel.setShape(second.op, &ctx, shape);

        var codegen = SpirvCodegen.init(allocator);
        defer codegen.deinit();
        if ((case.first == null) != (case.second == null)) {
            try std.testing.expectError(error.WorkgroupShapeMixed, codegen.emitModuleWords(module.op));
            continue;
        }
        const words = try codegen.emitModuleWords(module.op);
        defer allocator.free(words);
        var sizes: [2][3]u32 = undefined;
        try std.testing.expectEqual(@as(usize, 2), localSizes(words, &sizes));
        try std.testing.expectEqual(case.first.?, sizes[0]);
        try std.testing.expectEqual(case.second.?, sizes[1]);
        try std.testing.expectEqual(@as(usize, 0), countSizeDecorations(words));
    }
}

test "spirv codegen reads declared block dimensions as u32 constants" {
    const allocator = std.testing.allocator;
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer module.op.erase();
    var kernel = try FuncDialect.FuncOp.createKernel(&ctx, loc, "dimensions", &.{});
    try gpu_target.kernel.setShape(kernel.op, &ctx, .{ 8, 8, 1 });
    try module.getBodyBlock().addOperation(kernel.op);
    var dimensions: [3]GpuDialect.BlockDimOp = undefined;
    for (&dimensions, [_]gpu_target.Dimension{ .x, .y, .z }) |*dimension, axis| {
        dimension.* = try GpuDialect.BlockDimOp.create(&ctx, loc, axis);
        try kernel.getEntryBlock().addOperation(dimension.op);
    }
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try kernel.getEntryBlock().addOperation(ret.op);
    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);
    const u32_type = try codegen.getScalarType(.u32);
    for (dimensions, [_]u32{ 8, 8, 1 }) |dimension, extent| {
        const id = codegen.value_ids.get(dimension.getResult()) orelse return error.TestExpectedConstant;
        var found = false;
        var i: usize = 5;
        while (i < words.len) {
            const count: usize = @intCast(words[i] >> 16);
            std.debug.assert(count > 0);
            std.debug.assert(i + count <= words.len);
            const opcode: u16 = @truncate(words[i]);
            try std.testing.expect(opcode != SpirvOp.Load and opcode != SpirvOp.CompositeExtract);
            if (opcode == SpirvOp.Constant and count == 4 and words[i + 2] == id) {
                try std.testing.expectEqual(u32_type, words[i + 1]);
                try std.testing.expectEqual(extent, words[i + 3]);
                found = true;
            }
            i += count;
        }
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(@as(usize, 0), countSizeDecorations(words));
}

test "spirv codegen refuses a malformed workgroup shape" {
    const allocator = std.testing.allocator;
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const module = try BuiltinDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    defer module.op.erase();
    const kernel = try addCopyKernel(&ctx, module, "malformed", .device);
    try kernel.op.setAttr(
        gpu_target.kernel.shape_attr_key,
        try ctx.getDialectAttr(gpu_target.attr_names.workgroup_size, "8x0x1"),
    );

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    try std.testing.expectError(error.InvalidWorkgroupShape, codegen.emitModuleWords(module.op));
}

test "spirv codegen binds a read-only argument as a NonWritable storage buffer" {
    const allocator = std.testing.allocator;
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const module = try BuiltinDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    defer module.op.erase();
    _ = try addCopyKernel(&ctx, module, "read_only", .constant);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    const input = boundVariable(words, 0) orelse return error.TestExpectedBinding;
    const output = boundVariable(words, 1) orelse return error.TestExpectedBinding;
    try std.testing.expectEqual(SpvStorageClass.StorageBuffer, variableStorageClass(words, input).?);
    try std.testing.expectEqual(SpvStorageClass.StorageBuffer, variableStorageClass(words, output).?);
    try std.testing.expect(isDecorated(words, input, SpvDecoration.NonWritable));
    try std.testing.expect(!isDecorated(words, output, SpvDecoration.NonWritable));
    try std.testing.expectEqual(@as(usize, 0), countVariables(words, SpvStorageClass.Uniform));
}

test "spirv codegen refuses a store into a read-only argument" {
    const allocator = std.testing.allocator;
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const loc = ir.Location.getUnknown();
    const module = try BuiltinDialect.ModuleOp.create(&ctx, loc);
    defer module.op.erase();
    const u32_type = try ArithDialect.getScalarType(&ctx, .u32);
    const memref_type = try MemrefDialect.getMemrefTypeDynamic(&ctx, u32_type, .constant);
    var kernel = try FuncDialect.FuncOp.createKernel(&ctx, loc, "store_read_only", &.{memref_type});
    try module.getBodyBlock().addOperation(kernel.op);
    const entry = kernel.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(&ctx, loc, .x);
    try entry.addOperation(gid.op);
    const value = try ArithDialect.ConstantOp.createInt(&ctx, loc, u32_type, 7);
    try entry.addOperation(value.op);
    const store = try MemrefDialect.StoreOp.create(&ctx, loc, value.getResult(), kernel.getArgument(0), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(&ctx, loc, &.{});
    try entry.addOperation(ret.op);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    try std.testing.expectError(error.UnsupportedAddressSpace, codegen.emitModuleWords(module.op));
}

test "spirv codegen numbers each kernel's buffers from binding 0" {
    const allocator = std.testing.allocator;
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    const module = try BuiltinDialect.ModuleOp.create(&ctx, ir.Location.getUnknown());
    defer module.op.erase();
    _ = try addCopyKernel(&ctx, module, "first", .device);
    _ = try addCopyKernel(&ctx, module, "second", .constant);

    var codegen = SpirvCodegen.init(allocator);
    defer codegen.deinit();
    const words = try codegen.emitModuleWords(module.op);
    defer allocator.free(words);

    // Two kernels of two buffers each: bindings 0 and 1 twice, and no 2 or 3.
    try std.testing.expectEqual(@as(usize, 2), countBindings(words, 0));
    try std.testing.expectEqual(@as(usize, 2), countBindings(words, 1));
    try std.testing.expectEqual(@as(usize, 0), countBindings(words, 2));
    try std.testing.expectEqual(@as(usize, 0), countBindings(words, 3));
}

/// Adds a kernel `name` that copies `input[global_idx.x]` from an argument in
/// `input_space` to a device argument.
fn addCopyKernel(
    ctx: *ir.Context,
    module: BuiltinDialect.ModuleOp,
    name: []const u8,
    input_space: dialects.AddressSpace,
) !FuncDialect.FuncOp {
    const loc = ir.Location.getUnknown();
    const u32_type = try ArithDialect.getScalarType(ctx, .u32);
    const input_type = try MemrefDialect.getMemrefTypeDynamic(ctx, u32_type, input_space);
    const output_type = try MemrefDialect.getMemrefTypeDynamic(ctx, u32_type, .device);
    var kernel = try FuncDialect.FuncOp.createKernel(ctx, loc, name, &.{ input_type, output_type });
    try module.getBodyBlock().addOperation(kernel.op);
    const entry = kernel.getEntryBlock();
    const gid = try GpuDialect.GlobalIdxOp.create(ctx, loc, .x);
    try entry.addOperation(gid.op);
    const load = try MemrefDialect.LoadOp.create(ctx, loc, kernel.getArgument(0), gid.getResult(), u32_type);
    try entry.addOperation(load.op);
    const store = try MemrefDialect.StoreOp.create(ctx, loc, load.getResult(), kernel.getArgument(1), gid.getResult());
    try entry.addOperation(store.op);
    const ret = try FuncDialect.ReturnOp.create(ctx, loc, &.{});
    try entry.addOperation(ret.op);
    return kernel;
}

/// Writes each `LocalSize` execution mode's extents into `sizes` in module
/// order and returns how many the module holds.
fn localSizes(words: []const u32, sizes: [][3]u32) usize {
    var found: usize = 0;
    var i: usize = 5;
    while (i < words.len) {
        const count: usize = @intCast(words[i] >> 16);
        if (count == 0 or i + count > words.len) break;
        if (@as(u16, @truncate(words[i])) == SpirvOp.ExecutionMode and count == 6 and
            words[i + 2] == SpvExecutionMode.LocalSize)
        {
            if (found < sizes.len) sizes[found] = .{ words[i + 3], words[i + 4], words[i + 5] };
            found += 1;
        }
        i += count;
    }
    return found;
}

/// Counts WorkgroupSize and SpecId decorations, both absent in shaped modules.
fn countSizeDecorations(words: []const u32) usize {
    var found: usize = 0;
    var i: usize = 5;
    while (i < words.len) {
        const count: usize = @intCast(words[i] >> 16);
        std.debug.assert(count > 0);
        std.debug.assert(i + count <= words.len);
        if (@as(u16, @truncate(words[i])) == SpirvOp.Decorate and count == 4) {
            const size = words[i + 2] == SpvDecoration.BuiltIn and
                words[i + 3] == gpu.SpvBuiltIn.WorkgroupSize;
            if (size or words[i + 2] == SpvDecoration.SpecId) found += 1;
        }
        i += count;
    }
    return found;
}

/// The defaults of the specialization constants with SpecId 0, 1 and 2.
fn workgroupSizeDefaults(words: []const u32) ![3]u32 {
    var ids: [3]?u32 = .{ null, null, null };
    var i: usize = 5;
    while (i < words.len) {
        const count: usize = @intCast(words[i] >> 16);
        if (count == 0 or i + count > words.len) break;
        if (@as(u16, @truncate(words[i])) == SpirvOp.Decorate and count == 4 and
            words[i + 2] == SpvDecoration.SpecId and words[i + 3] < 3)
        {
            ids[words[i + 3]] = words[i + 1];
        }
        i += count;
    }
    var defaults: [3]u32 = undefined;
    for (&defaults, ids) |*default, maybe_id| {
        const id = maybe_id orelse return error.TestExpectedSpecId;
        default.* = specConstantDefault(words, id) orelse return error.TestExpectedSpecConstant;
    }
    return defaults;
}

fn specConstantDefault(words: []const u32, id: u32) ?u32 {
    var i: usize = 5;
    while (i < words.len) {
        const count: usize = @intCast(words[i] >> 16);
        if (count == 0 or i + count > words.len) break;
        if (@as(u16, @truncate(words[i])) == SpirvOp.SpecConstant and count == 4 and
            words[i + 2] == id) return words[i + 3];
        i += count;
    }
    return null;
}

/// The variable decorated with `binding` in descriptor set 0.
fn boundVariable(words: []const u32, binding: u32) ?u32 {
    var i: usize = 5;
    while (i < words.len) {
        const count: usize = @intCast(words[i] >> 16);
        if (count == 0 or i + count > words.len) break;
        if (@as(u16, @truncate(words[i])) == SpirvOp.Decorate and count == 4 and
            words[i + 2] == SpvDecoration.Binding and words[i + 3] == binding) return words[i + 1];
        i += count;
    }
    return null;
}

/// Counts the variables decorated `Binding binding`, across every kernel.
fn countBindings(words: []const u32, binding: u32) usize {
    var found: usize = 0;
    var i: usize = 5;
    while (i < words.len) {
        const count: usize = @intCast(words[i] >> 16);
        if (count == 0 or i + count > words.len) break;
        if (@as(u16, @truncate(words[i])) == SpirvOp.Decorate and count == 4 and
            words[i + 2] == SpvDecoration.Binding and words[i + 3] == binding) found += 1;
        i += count;
    }
    return found;
}

fn variableStorageClass(words: []const u32, id: u32) ?u32 {
    var i: usize = 5;
    while (i < words.len) {
        const count: usize = @intCast(words[i] >> 16);
        if (count == 0 or i + count > words.len) break;
        if (@as(u16, @truncate(words[i])) == SpirvOp.Variable and count >= 4 and
            words[i + 2] == id) return words[i + 3];
        i += count;
    }
    return null;
}

fn countVariables(words: []const u32, storage_class: u32) usize {
    var found: usize = 0;
    var i: usize = 5;
    while (i < words.len) {
        const count: usize = @intCast(words[i] >> 16);
        if (count == 0 or i + count > words.len) break;
        if (@as(u16, @truncate(words[i])) == SpirvOp.Variable and count >= 4 and
            words[i + 3] == storage_class) found += 1;
        i += count;
    }
    return found;
}
