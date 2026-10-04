//! Vertex and fragment emission. A stage function's interface slots become
//! Input and Output variables with Location decorations, made the first time
//! an op names them, so emission stays one pass over the function. A sampled
//! texture becomes one UniformConstant combined image sampler per group and
//! binding, shared by every stage function in the module.
//!
//! Block reads name a member by byte offset, so each block is declared as an
//! array of 32-bit words and a read indexes the words its member covers. The
//! push-constant block is `{ uint words[n] }` with stride 4. A uniform block
//! is `{ uvec4 rows[m] }` with stride 16, which std140 requires of arrays; an
//! aligned member never crosses a row, so each word is one row and one
//! component. A scan before emission sizes each array to the furthest member
//! the module reads, which the variable's type needs before its first read.

const std = @import("std");
const choir = @import("../../../../root.zig");
const gpu_target = @import("../../../../dialects/gpu/root.zig");
const gpu = @import("gpu.zig");
const scalar = @import("scalar.zig");
const spec = @import("spec.zig");
const SpirvOp = @import("ops.zig").SpirvOp;

const ir = choir.ir;
const GpuDialect = gpu_target.GpuDialect;
const Stage = gpu_target.Stage;
const ScalarKind = scalar.Kind;
const max_locations = gpu_target.stage.max_locations;

pub const Direction = enum { input, output };

pub const Slot = struct {
    var_id: u32,
    kind: ScalarKind,
    width: u32,
};

/// The interface of the stage function being emitted.
pub const Interface = struct {
    stage: Stage,
    inputs: [max_locations]?Slot = @splat(null),
    outputs: [max_locations]?Slot = @splat(null),
};

/// A descriptor's group and binding.
pub const ResourceKey = struct {
    group: u32,
    binding: u32,
};

pub const Lod = enum { implicit, explicit };

/// A uniform block: the bytes its reads reach, and its variable once made.
pub const UniformBlock = struct {
    extent: u32,
    var_id: ?u32 = null,
};

const stage_dialect = gpu_target.stage;
const push_stride = 4;
const uniform_stride = 16;

pub fn executionModel(stage: Stage) u32 {
    return switch (stage) {
        .vertex => spec.ExecutionModel.Vertex,
        .fragment => spec.ExecutionModel.Fragment,
    };
}

/// Integer varyings do not interpolate: a vertex writes them and a fragment
/// reads them Flat. Vulkan forbids the decoration on vertex inputs.
fn isFlat(stage: Stage, direction: Direction, kind: ScalarKind) bool {
    if (scalar.isFloat(kind)) return false;
    return switch (stage) {
        .vertex => direction == .output,
        .fragment => direction == .input,
    };
}

fn interfaceKind(value_type: ir.Type) !ScalarKind {
    const kind = scalar.kindFromType(value_type) orelse return error.UnsupportedType;
    return switch (kind) {
        .f32, .i32, .u32 => kind,
        else => error.UnsupportedType,
    };
}

fn slotType(self: anytype, kind: ScalarKind, width: u32) !u32 {
    std.debug.assert(width >= 1);
    std.debug.assert(width <= gpu_target.stage.max_components);
    if (width == 1) return self.getScalarType(kind);
    return self.getVectorType(kind, width);
}

fn interfaceSlot(
    self: anytype,
    direction: Direction,
    location: u32,
    kind: ScalarKind,
    width: u32,
) !Slot {
    const interface = if (self.stage_interface) |*current|
        current
    else
        return error.UnsupportedOperation;
    if (location >= max_locations) return error.UnsupportedOperation;
    const slots = switch (direction) {
        .input => &interface.inputs,
        .output => &interface.outputs,
    };
    if (slots[location]) |slot| {
        if (slot.kind != kind or slot.width != width) return error.UnsupportedType;
        return slot;
    }
    const storage_class = switch (direction) {
        .input => spec.StorageClass.Input,
        .output => spec.StorageClass.Output,
    };
    const ptr_type = try self.getPointerType(storage_class, try slotType(self, kind, width));
    const var_id = self.builder.newId();
    try self.builder.emit(&self.builder.globals, SpirvOp.Variable, &.{
        ptr_type,
        var_id,
        storage_class,
    });
    try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
        var_id,
        spec.Decoration.Location,
        location,
    });
    if (isFlat(interface.stage, direction, kind)) {
        try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
            var_id,
            spec.Decoration.Flat,
        });
    }
    try self.addInterfaceVar(var_id);
    const slot: Slot = .{ .var_id = var_id, .kind = kind, .width = width };
    slots[location] = slot;
    return slot;
}

/// Binds each result of `op` to one component of `composite_id`, or the
/// single result to the whole value.
fn bindComponents(self: anytype, op: *ir.Operation, composite_id: u32, kind: ScalarKind) !void {
    const count = op.getNumResults();
    if (count == 1) return self.bindValue(op.getResult(0).?, composite_id);
    const component_type = try self.getScalarType(kind);
    for (0..count) |index| {
        const result_id = self.builder.newId();
        try self.builder.emit(&self.builder.functions, SpirvOp.CompositeExtract, &.{
            component_type,
            result_id,
            composite_id,
            @as(u32, @intCast(index)),
        });
        try self.bindValue(op.getResult(index).?, result_id);
    }
}

/// Builds the value that `operands` spell, one component each, after checking
/// that every component has `kind`.
fn composeComponents(self: anytype, operands: []const *ir.Value, kind: ScalarKind) !u32 {
    var ids: [gpu_target.stage.max_components]u32 = undefined;
    for (operands, 0..) |operand, index| {
        if (try interfaceKind(operand.type) != kind) return error.UnsupportedType;
        ids[index] = try self.getValue(operand);
    }
    if (operands.len == 1) return ids[0];
    const vector_type = try self.getVectorType(kind, @intCast(operands.len));
    const result_id = self.builder.newId();
    var words: [2 + gpu_target.stage.max_components]u32 = undefined;
    words[0] = vector_type;
    words[1] = result_id;
    @memcpy(words[2..][0..operands.len], ids[0..operands.len]);
    const construct = words[0 .. 2 + operands.len];
    try self.builder.emit(&self.builder.functions, SpirvOp.CompositeConstruct, construct);
    return result_id;
}

pub fn emitStageInput(self: anytype, op: *ir.Operation) !void {
    const input = GpuDialect.StageInputOp{ .op = op };
    const location = input.getLocation() orelse return error.MissingAttribute;
    const width: u32 = @intCast(op.getNumResults());
    const kind = try interfaceKind(op.getResult(0).?.type);
    for (0..width) |index| {
        if (try interfaceKind(op.getResult(index).?.type) != kind) return error.UnsupportedType;
    }
    const slot = try interfaceSlot(self, .input, location, kind, width);
    const load_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Load, &.{
        try slotType(self, kind, width),
        load_id,
        slot.var_id,
    });
    try bindComponents(self, op, load_id, kind);
}

pub fn emitStageOutput(self: anytype, op: *ir.Operation) !void {
    const output = GpuDialect.StageOutputOp{ .op = op };
    const location = output.getLocation() orelse return error.MissingAttribute;
    const operands = op.getOperandValues();
    const kind = try interfaceKind(operands[0].type);
    const slot = try interfaceSlot(self, .output, location, kind, @intCast(operands.len));
    const value_id = try composeComponents(self, operands, kind);
    try self.builder.emit(&self.builder.functions, SpirvOp.Store, &.{ slot.var_id, value_id });
}

pub fn emitPosition(self: anytype, op: *ir.Operation) !void {
    std.debug.assert(op.getNumOperands() == 4);
    const value_id = try composeComponents(self, op.getOperandValues(), .f32);
    const var_id = try gpu.getBuiltinVar(self, .position);
    try self.builder.emit(&self.builder.functions, SpirvOp.Store, &.{ var_id, value_id });
}

pub fn emitBuiltinLoad(self: anytype, op: *ir.Operation, builtin: gpu.BuiltinKind) !void {
    const var_id = try gpu.getBuiltinVar(self, builtin);
    const load_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Load, &.{
        try gpu.builtinType(self, builtin),
        load_id,
        var_id,
    });
    const kind = scalar.kindFromType(op.getResult(0).?.type) orelse return error.UnsupportedType;
    try bindComponents(self, op, load_id, kind);
}

fn sampledImageType(self: anytype) !u32 {
    if (self.sampled_image_type) |id| return id;
    const f32_type = try self.getScalarType(.f32);
    const image_type = self.builder.newId();
    try self.builder.emit(&self.builder.types, SpirvOp.TypeImage, &.{
        image_type,
        f32_type,
        spec.Dim.@"2D",
        0,
        0,
        0,
        1,
        spec.ImageFormat.Unknown,
    });
    const id = self.builder.newId();
    try self.builder.emit(&self.builder.types, SpirvOp.TypeSampledImage, &.{ id, image_type });
    self.sampled_image_type = id;
    return id;
}

/// Binds a sampled texture to the variable for its group and binding. The
/// map gains a key only once its variable exists, so a failed emit leaves no
/// entry naming an id that was never written.
pub fn emitSampledTexture(self: anytype, op: *ir.Operation) !void {
    const texture = GpuDialect.SampledTextureOp{ .op = op };
    const key: ResourceKey = .{
        .group = texture.getGroup() orelse return error.MissingAttribute,
        .binding = texture.getBinding() orelse return error.MissingAttribute,
    };
    if (self.texture_vars.get(key)) |var_id| return self.bindValue(texture.getResult(), var_id);
    const storage_class = spec.StorageClass.UniformConstant;
    const ptr_type = try self.getPointerType(storage_class, try sampledImageType(self));
    const var_id = self.builder.newId();
    try self.builder.emit(&self.builder.globals, SpirvOp.Variable, &.{
        ptr_type,
        var_id,
        storage_class,
    });
    try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
        var_id,
        spec.Decoration.DescriptorSet,
        key.group,
    });
    try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
        var_id,
        spec.Decoration.Binding,
        key.binding,
    });
    try self.texture_vars.put(self.allocator, key, var_id);
    try self.bindValue(texture.getResult(), var_id);
}

fn floatOperand(self: anytype, value: *ir.Value) !u32 {
    if (scalar.kindFromType(value.type) != .f32) return error.UnsupportedType;
    return self.getValue(value);
}

pub fn emitSample(self: anytype, op: *ir.Operation, lod: Lod) !void {
    const operands = op.getOperandValues();
    const sampled_image_type = try sampledImageType(self);
    const sampled_image = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Load, &.{
        sampled_image_type,
        sampled_image,
        try self.getValue(operands[0]),
    });
    const coord = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.CompositeConstruct, &.{
        try self.getVectorType(.f32, 2),
        coord,
        try floatOperand(self, operands[1]),
        try floatOperand(self, operands[2]),
    });
    const texel_type = try self.getVectorType(.f32, 4);
    const texel = self.builder.newId();
    const functions = &self.builder.functions;
    switch (lod) {
        .implicit => try self.builder.emit(functions, SpirvOp.ImageSampleImplicitLod, &.{
            texel_type,
            texel,
            sampled_image,
            coord,
        }),
        .explicit => try self.builder.emit(functions, SpirvOp.ImageSampleExplicitLod, &.{
            texel_type,
            texel,
            sampled_image,
            coord,
            spec.ImageOperands.Lod,
            try floatOperand(self, operands[3]),
        }),
    }
    try bindComponents(self, op, texel, .f32);
}

/// Emits a fine derivative. A plain OpDPdx lets the device pick the flavour: lavapipe, the RTX 4090
/// and Metal take fine, and RADV coarse, so only the explicit op draws one frame on all of them.
pub fn emitDerivative(self: anytype, op: *ir.Operation, opcode: u16) !void {
    try self.requireCapability(spec.Capability.DerivativeControl);
    const value_id = try floatOperand(self, op.getOperandValues()[0]);
    const result_id = self.builder.newId();
    try self.builder.emit(&self.builder.functions, opcode, &.{
        try self.getScalarType(.f32),
        result_id,
        value_id,
    });
    try self.bindValue(op.getResult(0).?, result_id);
}

/// Records how far into each block the module reads, refusing a member the
/// block cannot place.
pub fn scanBlocks(self: anytype, module: *ir.Operation) !void {
    self.push_extent = 0;
    self.push_var = null;
    self.uniform_blocks.clearRetainingCapacity();
    const Scan = struct {
        codegen: @TypeOf(self),
        refused: bool = false,

        fn visit(scan: *@This(), op: *ir.Operation) !ir.Operation.WalkResult {
            if (std.mem.eql(u8, op.name.name, GpuDialect.PushConstantOp.operation_name)) {
                const member = (GpuDialect.PushConstantOp{ .op = op }).member() orelse
                    return scan.refuse();
                if (!member.placed(stage_dialect.max_push_constant_bytes)) return scan.refuse();
                scan.codegen.push_extent = @max(scan.codegen.push_extent, member.end());
            } else if (std.mem.eql(u8, op.name.name, GpuDialect.UniformOp.operation_name)) {
                const uniform = GpuDialect.UniformOp{ .op = op };
                const member = uniform.member() orelse return scan.refuse();
                if (!member.placed(stage_dialect.max_uniform_bytes)) return scan.refuse();
                const key: ResourceKey = .{
                    .group = uniform.getGroup() orelse return scan.refuse(),
                    .binding = uniform.getBinding() orelse return scan.refuse(),
                };
                const entry = try scan.codegen.uniform_blocks.getOrPut(scan.codegen.allocator, key);
                if (!entry.found_existing) entry.value_ptr.* = .{ .extent = 0 };
                entry.value_ptr.extent = @max(entry.value_ptr.extent, member.end());
            }
            return .advance;
        }

        fn refuse(scan: *@This()) ir.Operation.WalkResult {
            scan.refused = true;
            return .interrupt;
        }
    };
    var scan: Scan = .{ .codegen = self };
    _ = module.walk(.{ .order = .pre_order }, &scan, Scan.visit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    if (scan.refused) return error.UnsupportedOperation;
}

/// Declares a Block struct whose one member is an array of `length`
/// elements of `element_type` at `stride` bytes, and a variable of it in
/// `storage_class`. The array type is not shared with the cache, since its
/// ArrayStride belongs only in explicitly laid out storage.
fn blockVariable(
    self: anytype,
    storage_class: u32,
    element_type: u32,
    length: u32,
    stride: u32,
) !u32 {
    std.debug.assert(length >= 1);
    const length_id = try self.getIntConstant(try self.getScalarType(.u32), .u32, length);
    const array_type = self.builder.newId();
    try self.builder.emit(&self.builder.types, SpirvOp.TypeArray, &.{
        array_type,
        element_type,
        length_id,
    });
    try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
        array_type,
        spec.Decoration.ArrayStride,
        stride,
    });
    const struct_type = self.builder.newId();
    try self.builder.emit(&self.builder.types, SpirvOp.TypeStruct, &.{ struct_type, array_type });
    try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
        struct_type,
        spec.Decoration.Block,
    });
    try self.builder.emit(&self.builder.annotations, SpirvOp.MemberDecorate, &.{
        struct_type,
        0,
        spec.Decoration.Offset,
        0,
    });
    const var_id = self.builder.newId();
    try self.builder.emit(&self.builder.globals, SpirvOp.Variable, &.{
        try self.getPointerType(storage_class, struct_type),
        var_id,
        storage_class,
    });
    return var_id;
}

fn pushVariable(self: anytype) !u32 {
    if (self.push_var) |id| return id;
    std.debug.assert(self.push_extent > 0);
    std.debug.assert(self.push_extent % push_stride == 0);
    const u32_type = try self.getScalarType(.u32);
    const id = try blockVariable(
        self,
        spec.StorageClass.PushConstant,
        u32_type,
        self.push_extent / push_stride,
        push_stride,
    );
    self.push_var = id;
    return id;
}

fn uniformVariable(self: anytype, key: ResourceKey) !u32 {
    const block = self.uniform_blocks.getPtr(key) orelse return error.UnsupportedOperation;
    if (block.var_id) |id| return id;
    std.debug.assert(block.extent > 0);
    const row_type = try self.getVectorType(.u32, 4);
    const rows = std.math.divCeil(u32, block.extent, uniform_stride) catch unreachable;
    const id = try blockVariable(self, spec.StorageClass.Uniform, row_type, rows, uniform_stride);
    try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
        id,
        spec.Decoration.DescriptorSet,
        key.group,
    });
    try self.builder.emit(&self.builder.annotations, SpirvOp.Decorate, &.{
        id,
        spec.Decoration.Binding,
        key.binding,
    });
    block.var_id = id;
    return id;
}

/// The kind every result of a block read shares.
fn blockReadKind(op: *ir.Operation) !ScalarKind {
    const kind = try interfaceKind(op.getResult(0).?.type);
    for (0..op.getNumResults()) |index| {
        if (try interfaceKind(op.getResult(index).?.type) != kind) return error.UnsupportedType;
    }
    return kind;
}

/// Loads the word that `indices` reach from `var_id` and binds it, as
/// `kind`, to `result`.
fn loadBlockWord(
    self: anytype,
    result: *ir.Value,
    kind: ScalarKind,
    storage_class: u32,
    var_id: u32,
    indices: []const u32,
) !void {
    const u32_type = try self.getScalarType(.u32);
    var words: [3 + 3]u32 = undefined;
    std.debug.assert(indices.len <= 3);
    const pointer = self.builder.newId();
    words[0] = try self.getPointerType(storage_class, u32_type);
    words[1] = pointer;
    words[2] = var_id;
    for (indices, 0..) |index, slot| {
        words[3 + slot] = try self.getIntConstant(u32_type, .u32, index);
    }
    try self.builder.emit(&self.builder.functions, SpirvOp.AccessChain, words[0 .. 3 + indices.len]);
    const bits = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Load, &.{ u32_type, bits, pointer });
    if (kind == .u32) return self.bindValue(result, bits);
    const value = self.builder.newId();
    try self.builder.emit(&self.builder.functions, SpirvOp.Bitcast, &.{
        try self.getScalarType(kind),
        value,
        bits,
    });
    try self.bindValue(result, value);
}

pub fn emitPushConstant(self: anytype, op: *ir.Operation) !void {
    const member = (GpuDialect.PushConstantOp{ .op = op }).member() orelse
        return error.MissingAttribute;
    std.debug.assert(member.end() <= self.push_extent);
    const kind = try blockReadKind(op);
    const var_id = try pushVariable(self);
    const first = member.offset / push_stride;
    for (0..member.width) |component| {
        const word: u32 = first + @as(u32, @intCast(component));
        try loadBlockWord(self, op.getResult(component).?, kind, spec.StorageClass.PushConstant, var_id, &.{
            0,
            word,
        });
    }
}

pub fn emitUniform(self: anytype, op: *ir.Operation) !void {
    const uniform = GpuDialect.UniformOp{ .op = op };
    const member = uniform.member() orelse return error.MissingAttribute;
    const key: ResourceKey = .{
        .group = uniform.getGroup() orelse return error.MissingAttribute,
        .binding = uniform.getBinding() orelse return error.MissingAttribute,
    };
    const kind = try blockReadKind(op);
    const var_id = try uniformVariable(self, key);
    const row = member.offset / uniform_stride;
    const first = member.offset % uniform_stride / 4;
    std.debug.assert(first + member.width <= 4);
    for (0..member.width) |component| {
        const column: u32 = first + @as(u32, @intCast(component));
        try loadBlockWord(self, op.getResult(component).?, kind, spec.StorageClass.Uniform, var_id, &.{
            0,
            row,
            column,
        });
    }
}

test "integer varyings are flat only where Vulkan allows the decoration" {
    try std.testing.expect(isFlat(.vertex, .output, .u32));
    try std.testing.expect(isFlat(.fragment, .input, .i32));
    try std.testing.expect(!isFlat(.vertex, .input, .u32));
    try std.testing.expect(!isFlat(.fragment, .output, .u32));
    try std.testing.expect(!isFlat(.fragment, .input, .f32));
}
