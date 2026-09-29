const std = @import("std");
const abi = @import("gpu_abi");
const choir_pkg = @import("../../../root.zig");

const gpu = @import("../../../dialects/gpu/root.zig");
const calls = @import("../calls.zig");

const ir = choir_pkg.ir;
const dialects = choir_pkg.dialects;

const Allocator = std.mem.Allocator;
const ArithDialect = dialects.ArithDialect;
const AtomicRmwKind = dialects.AtomicRmwKind;
const CmpPredicate = dialects.arith.CmpPredicate;
const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;
const GpuDialect = gpu.GpuDialect;
const MemrefDialect = dialects.MemrefDialect;
const ScfDialect = dialects.ScfDialect;
const Stage = gpu.Stage;
const max_locations = gpu.stage.max_locations;

const EmitError = RenderError || std.Io.Writer.Error;

/// The render path's failures: the ABI's, and the stage memory `calls.Plan` refuses by name.
pub const RenderError = abi.Error || gpu.stage.MemoryError || calls.SignatureError || calls.DepthError;

const ScalarKind = dialects.arith.ScalarKind;
const scalar_kinds = dialects.arith.ScalarSet.init(&.{
    .bool,
    .index,
    .i8,
    .i16,
    .i32,
    .u32,
    .i64,
    .f16,
    .f32,
    .f64,
});

const YieldTarget = struct {
    names: []const []const u8,
};

pub const max_texture_bindings = abi.metal.max_texture_bindings;
pub const max_uniform_bindings = abi.metal.max_uniform_bindings;
pub const uniform_buffer_base = abi.metal.uniform_buffer_base;
pub const push_buffer = abi.metal.push_buffer;

pub const RenderEntries = struct {
    vertex: []const u8,
    fragment: []const u8,
};

/// Emits one source holding `entries.vertex` as a vertex function and
/// `entries.fragment` as a fragment function.
///
/// Interface slot n is `[[attribute(n)]]` for a vertex input, `[[user(locnN)]]`
/// between the stages, and `[[color(n)]]` for a fragment output. Metal binds
/// resources by one flat index per stage, so a sampled texture takes group 0,
/// and its binding is the index of both its texture and its sampler.
///
/// A stage's clip space puts y = -1 at the target's top edge, as the gpu
/// contract and Vulkan do, and Metal's puts y = +1 there. So the vertex
/// function negates the y it writes to `[[position]]`, which is exact, and the
/// host's viewport is Metal's own, origin at the top left.
///
/// Block reads index 32-bit words, as the SPIR-V blocks do. The push-constant
/// words are `constant uint*` at `[[buffer(push_buffer)]]`, which a host sets
/// with `setVertexBytes` and `setFragmentBytes`. Uniform binding `b` of group
/// 0 is `constant uint4*` at `[[buffer(uniform_buffer_base + b)]]`, rows of
/// 16 bytes as std140 lays them. A read reinterprets its word with `as_type`.
pub fn emitMslRender(
    result_allocator: Allocator,
    module: *ir.Operation,
    entries: RenderEntries,
) RenderError![]u8 {
    var out = std.Io.Writer.Allocating.init(result_allocator);
    errdefer out.deinit();
    const stages = [_]struct { name: []const u8, stage: Stage }{
        .{ .name = entries.vertex, .stage = .vertex },
        .{ .name = entries.fragment, .stage = .fragment },
    };
    writeHeader(&out.writer) catch return error.OutOfMemory;
    writeHelpers(&out.writer, result_allocator, module) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
    for (stages, 0..) |entry, index| {
        if (index > 0) out.writer.writeByte('\n') catch return error.OutOfMemory;
        var emitter = Emitter.init(result_allocator, entry.name, module);
        defer emitter.deinit();
        emitter.emitStage(&out.writer, entry.stage) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |other| return other,
        };
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeHelpers(writer: *std.Io.Writer, allocator: Allocator, module: *ir.Operation) EmitError!void {
    var plan = try calls.Plan.init(allocator, module, null);
    defer plan.deinit();
    for (plan.helpers.items) |func| {
        const name = (FuncDialect.FuncOp{ .op = func }).getName() orelse return error.InvalidArtifact;
        var emitter = Emitter.init(allocator, name, module);
        defer emitter.deinit();
        try emitter.emitHelperSource(writer, FuncDialect.FuncOp{ .op = func });
        try writer.writeByte('\n');
    }
}

const Direction = enum { input, output };

const Slot = struct {
    kind: ScalarKind,
    width: u32,
};

/// What a stage function reads and writes, gathered while its body is
/// emitted and written into its structs and signature afterwards.
const StageInterface = struct {
    inputs: [max_locations]?Slot = @splat(null),
    outputs: [max_locations]?Slot = @splat(null),
    frag_coord: bool = false,
    vertex_id: bool = false,
    instance_id: bool = false,
    front_facing: bool = false,
    textures: std.StaticBitSet(max_texture_bindings) = .empty,
    push: bool = false,
    uniforms: std.StaticBitSet(max_uniform_bindings) = .empty,

    fn record(
        self: *StageInterface,
        direction: Direction,
        location: u32,
        slot: Slot,
    ) abi.Error!void {
        if (location >= max_locations) return error.InvalidArtifact;
        const slots = switch (direction) {
            .input => &self.inputs,
            .output => &self.outputs,
        };
        if (slots[location]) |existing| {
            if (existing.kind != slot.kind) return error.InvalidArtifact;
            if (existing.width != slot.width) return error.InvalidArtifact;
        }
        slots[location] = slot;
    }

    fn count(slots: []const ?Slot) usize {
        var total: usize = 0;
        for (slots) |slot| total += @intFromBool(slot != null);
        return total;
    }

    fn hasInput(self: *const StageInterface) bool {
        return count(&self.inputs) > 0 or self.frag_coord;
    }
};

/// The struct member prefix of a slot: attributes feed the vertex stage,
/// locations join the stages, and colors leave the fragment stage.
fn memberPrefix(stage: Stage, direction: Direction) []const u8 {
    return switch (stage) {
        .vertex => if (direction == .input) "a" else "l",
        .fragment => if (direction == .input) "l" else "c",
    };
}

fn widthSuffix(width: u32) []const u8 {
    return switch (width) {
        1 => "",
        2 => "2",
        3 => "3",
        4 => "4",
        else => unreachable,
    };
}

const components = [_][]const u8{ "x", "y", "z", "w" };

fn interfaceKind(typ: ir.Type) abi.Error!ScalarKind {
    const kind = try scalarKind(typ);
    return switch (kind) {
        .f32, .i32, .u32 => kind,
        else => error.UnsupportedOperation,
    };
}

/// The kind every result of a block read shares.
fn blockReadKind(op: *ir.Operation) abi.Error!ScalarKind {
    const kind = try interfaceKind(op.getResult(0).?.type);
    for (0..op.getNumResults()) |index| {
        if (try interfaceKind(op.getResult(index).?.type) != kind) return error.InvalidArtifact;
    }
    return kind;
}

pub fn emitMsl(
    result_allocator: Allocator,
    entry_name: []const u8,
    module: *ir.Operation,
) abi.Error![]u8 {
    var emitter = Emitter.init(result_allocator, entry_name, module);
    defer emitter.deinit();
    return emitter.emit() catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        error.UnsupportedStageMemory, error.UnsupportedHelperSignature, error.CallChainTooDeep => error.UnsupportedOperation,
        else => |other| other,
    };
}

const Emitter = struct {
    allocator: Allocator,
    entry_name: []const u8,
    module: *ir.Operation,
    body: std.Io.Writer.Allocating,
    values: std.AutoHashMapUnmanaged(*const ir.Value, []const u8) = .{},
    names: std.ArrayListUnmanaged([]u8) = .empty,
    next_value: u32 = 0,
    next_loop: u32 = 0,
    next_shared: u32 = 0,
    indent: u32 = 1,
    stage: ?Stage = null,
    interface: StageInterface = .{},
    return_statement: []const u8 = "return;",

    fn init(allocator: Allocator, entry_name: []const u8, module: *ir.Operation) Emitter {
        return .{
            .allocator = allocator,
            .entry_name = entry_name,
            .module = module,
            .body = std.Io.Writer.Allocating.init(allocator),
        };
    }

    fn deinit(self: *Emitter) void {
        self.values.deinit(self.allocator);
        for (self.names.items) |name| self.allocator.free(name);
        self.names.deinit(self.allocator);
        self.body.deinit();
    }

    fn emit(self: *Emitter) EmitError![]u8 {
        const func = try self.findKernelFunction();
        try self.emitParameterBindings(func);
        try self.emitBlock(func.getEntryBlock(), null);

        var out = std.Io.Writer.Allocating.init(self.allocator);
        errdefer out.deinit();
        try writeHeader(&out.writer);
        try writeHelpers(&out.writer, self.allocator, self.module);
        try self.emitFunctionHeader(&out.writer, func);
        try out.writer.writeAll(self.body.written());
        try out.writer.writeAll("}\n");
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn emitStage(self: *Emitter, writer: *std.Io.Writer, stage: Stage) EmitError!void {
        const func = try self.findStageFunction(stage);
        if (func.getNumArguments() != 0) return error.InvalidArtifact;
        self.stage = stage;
        self.return_statement = "return choir_out;";
        try self.line("{s}_out choir_out = {{}};", .{self.entry_name});
        try self.emitBlock(func.getEntryBlock(), null);
        if (stage == .fragment and StageInterface.count(&self.interface.outputs) == 0) {
            return error.InvalidArtifact;
        }
        try self.writeStageStructs(writer, stage);
        try self.writeStageSignature(writer, stage);
        try writer.writeAll(self.body.written());
        try writer.writeAll("}\n");
    }

    fn emitHelperSource(self: *Emitter, writer: *std.Io.Writer, func: FuncDialect.FuncOp) EmitError!void {
        const results = func.getResultTypes();
        if (results.len > 1) return error.UnsupportedOperation;
        const return_type = if (results.len == 0) "void" else try mslScalarType(try scalarKind(results[0]));
        try writer.print("{s} {s}(", .{ return_type, self.entry_name });
        for (func.getArguments(), 0..) |arg, index| {
            if (index != 0) try writer.writeAll(", ");
            const name = try self.freshValueName();
            if (memrefInfo(arg.type)) |memref| {
                if (memref.addr_space != .local) return error.UnsupportedOperation;
                try writer.print("thread {s}* {s}", .{ try mslScalarType(memref.element), name });
            } else {
                try writer.print("{s} {s}", .{ try mslScalarType(try scalarKind(arg.type)), name });
            }
            try self.bind(arg, name);
        }
        try writer.writeAll(") {\n");
        try self.emitBlock(func.getEntryBlock(), null);
        try writer.writeAll(self.body.written());
        try writer.writeAll("}\n");
    }

    fn findStageFunction(self: *Emitter, stage: Stage) abi.Error!FuncDialect.FuncOp {
        if (!std.mem.eql(u8, self.module.name.name, BuiltinDialect.ModuleOp.operation_name)) {
            return error.InvalidArtifact;
        }
        const region = self.module.getRegion(0).?;
        const block = region.getEntryBlock() orelse return error.InvalidArtifact;
        var ops = block.getOperations();
        while (ops.next()) |op| {
            if (!std.mem.eql(u8, op.name.name, FuncDialect.FuncOp.operation_name)) continue;
            const func = FuncDialect.FuncOp{ .op = op };
            const name = func.getName() orelse continue;
            if (!std.mem.eql(u8, name, self.entry_name)) continue;
            if (gpu.stage.stageOf(op) != stage) return error.InvalidArtifact;
            return func;
        }
        return error.InvalidArtifact;
    }

    fn writeStageStructs(self: *Emitter, writer: *std.Io.Writer, stage: Stage) EmitError!void {
        const interface = &self.interface;
        if (interface.hasInput()) {
            try writer.print("struct {s}_in {{\n", .{self.entry_name});
            if (interface.frag_coord) try writer.writeAll("    float4 position [[position]];\n");
            for (interface.inputs, 0..) |maybe_slot, location| {
                const slot = maybe_slot orelse continue;
                try writeMember(writer, stage, .input, location, slot);
            }
            try writer.writeAll("};\n\n");
        }
        try writer.print("struct {s}_out {{\n", .{self.entry_name});
        if (stage == .vertex) try writer.writeAll("    float4 position [[position]];\n");
        for (interface.outputs, 0..) |maybe_slot, location| {
            const slot = maybe_slot orelse continue;
            try writeMember(writer, stage, .output, location, slot);
        }
        try writer.writeAll("};\n\n");
    }

    fn writeStageSignature(self: *Emitter, writer: *std.Io.Writer, stage: Stage) EmitError!void {
        const interface = &self.interface;
        const total = @as(usize, @intFromBool(interface.hasInput())) +
            @intFromBool(interface.vertex_id) +
            @intFromBool(interface.instance_id) +
            @intFromBool(interface.front_facing) +
            2 * interface.textures.count() +
            @intFromBool(interface.push) +
            interface.uniforms.count();
        const name = self.entry_name;
        try writer.print("{s} {s}_out {s}(", .{ @tagName(stage), name, name });
        if (total == 0) return writer.writeAll(") {\n");
        try writer.writeByte('\n');
        var list: ParameterList = .{ .writer = writer, .total = total };
        if (interface.hasInput()) try list.add("{s}_in choir_in [[stage_in]]", .{name});
        if (interface.vertex_id) try list.add("uint choir_vertex_id [[vertex_id]]", .{});
        if (interface.instance_id) try list.add("uint choir_instance_id [[instance_id]]", .{});
        if (interface.front_facing) try list.add("bool choir_front_facing [[front_facing]]", .{});
        var textures = interface.textures.iterator(.{});
        while (textures.next()) |binding| {
            const texture = "texture2d<float> choir_texture{d} [[texture({d})]]";
            try list.add(texture, .{ binding, binding });
            try list.add("sampler choir_sampler{d} [[sampler({d})]]", .{ binding, binding });
        }
        var uniforms = interface.uniforms.iterator(.{});
        while (uniforms.next()) |binding| {
            const uniform = "constant uint4* choir_uniform{d} [[buffer({d})]]";
            try list.add(uniform, .{ binding, uniform_buffer_base + binding });
        }
        if (interface.push) try list.add("constant uint* choir_push [[buffer({d})]]", .{push_buffer});
        std.debug.assert(list.index == total);
        try writer.writeAll(") {\n");
    }

    /// Emits `op` when it belongs to the stage vocabulary and reports whether
    /// it did.
    fn emitStageOperation(self: *Emitter, op: *ir.Operation) EmitError!bool {
        const name = op.name.name;
        if (std.mem.eql(u8, name, GpuDialect.StageInputOp.operation_name)) {
            try self.emitStageInput(GpuDialect.StageInputOp{ .op = op });
        } else if (std.mem.eql(u8, name, GpuDialect.StageOutputOp.operation_name)) {
            try self.emitStageOutput(GpuDialect.StageOutputOp{ .op = op });
        } else if (std.mem.eql(u8, name, GpuDialect.PositionOp.operation_name)) {
            const value = try self.composite(.f32, op.getOperandValues());
            try self.line("choir_out.position = {s};", .{value});
            try self.line("choir_out.position.y = -choir_out.position.y;", .{});
        } else if (std.mem.eql(u8, name, GpuDialect.FragCoordOp.operation_name)) {
            self.interface.frag_coord = true;
            try self.bindComponents(op, "choir_in.position");
        } else if (std.mem.eql(u8, name, GpuDialect.VertexIndexOp.operation_name)) {
            self.interface.vertex_id = true;
            try self.bind(op.getResult(0).?, "choir_vertex_id");
        } else if (std.mem.eql(u8, name, GpuDialect.InstanceIndexOp.operation_name)) {
            self.interface.instance_id = true;
            try self.bind(op.getResult(0).?, "choir_instance_id");
        } else if (std.mem.eql(u8, name, GpuDialect.FrontFacingOp.operation_name)) {
            self.interface.front_facing = true;
            try self.bind(op.getResult(0).?, "choir_front_facing");
        } else if (std.mem.eql(u8, name, GpuDialect.SampledTextureOp.operation_name)) {
            try self.recordTexture(GpuDialect.SampledTextureOp{ .op = op });
        } else if (std.mem.eql(u8, name, GpuDialect.SampleOp.operation_name)) {
            try self.emitSample(op, false);
        } else if (std.mem.eql(u8, name, GpuDialect.SampleLodOp.operation_name)) {
            try self.emitSample(op, true);
        } else if (std.mem.eql(u8, name, GpuDialect.PushConstantOp.operation_name)) {
            try self.emitPushConstant(GpuDialect.PushConstantOp{ .op = op });
        } else if (std.mem.eql(u8, name, GpuDialect.UniformOp.operation_name)) {
            try self.emitUniform(GpuDialect.UniformOp{ .op = op });
        } else if (std.mem.eql(u8, name, GpuDialect.DpdxOp.operation_name)) {
            try self.emitCall1(op, "dfdx");
        } else if (std.mem.eql(u8, name, GpuDialect.DpdyOp.operation_name)) {
            try self.emitCall1(op, "dfdy");
        } else if (std.mem.eql(u8, name, GpuDialect.FwidthOp.operation_name)) {
            try self.emitCall1(op, "fwidth");
        } else {
            return false;
        }
        return true;
    }

    fn emitStageInput(self: *Emitter, op: GpuDialect.StageInputOp) EmitError!void {
        const location = op.getLocation() orelse return error.InvalidArtifact;
        const width: u32 = @intCast(op.op.getNumResults());
        const kind = try interfaceKind(op.op.getResult(0).?.type);
        for (0..width) |index| {
            const component_kind = try interfaceKind(op.op.getResult(index).?.type);
            if (component_kind != kind) return error.InvalidArtifact;
        }
        try self.interface.record(.input, location, .{ .kind = kind, .width = width });
        const member = std.fmt.allocPrint(self.allocator, "choir_in.{s}{d}", .{
            memberPrefix(self.stage.?, .input),
            location,
        }) catch return error.OutOfMemory;
        try self.bindComponents(op.op, try self.rememberName(member));
    }

    fn emitStageOutput(self: *Emitter, op: GpuDialect.StageOutputOp) EmitError!void {
        const location = op.getLocation() orelse return error.InvalidArtifact;
        const values = op.op.getOperandValues();
        const kind = try interfaceKind(values[0].type);
        const slot: Slot = .{ .kind = kind, .width = @intCast(values.len) };
        try self.interface.record(.output, location, slot);
        const value = try self.composite(kind, values);
        const member = memberPrefix(self.stage.?, .output);
        try self.line("choir_out.{s}{d} = {s};", .{ member, location, value });
    }

    fn recordTexture(self: *Emitter, op: GpuDialect.SampledTextureOp) EmitError!void {
        const group = op.getGroup() orelse return error.InvalidArtifact;
        const binding = op.getBinding() orelse return error.InvalidArtifact;
        if (group != 0 or binding >= max_texture_bindings) return error.CapabilityMismatch;
        self.interface.textures.set(binding);
        const name = std.fmt.allocPrint(self.allocator, "choir_texture{d}", .{binding}) catch
            return error.OutOfMemory;
        try self.rememberAndBind(op.getResult(), name);
    }

    fn emitPushConstant(self: *Emitter, op: GpuDialect.PushConstantOp) EmitError!void {
        const member = op.member() orelse return error.InvalidArtifact;
        if (!member.placed(gpu.stage.max_push_constant_bytes)) return error.CapabilityMismatch;
        const kind = try blockReadKind(op.op);
        self.interface.push = true;
        for (0..member.width) |component| {
            const word = member.offset / 4 + component;
            const name = if (kind == .u32)
                std.fmt.allocPrint(self.allocator, "choir_push[{d}]", .{word})
            else
                std.fmt.allocPrint(self.allocator, "as_type<{s}>(choir_push[{d}])", .{
                    try mslScalarType(kind),
                    word,
                });
            try self.rememberAndBind(op.op.getResult(component).?, name catch return error.OutOfMemory);
        }
    }

    fn emitUniform(self: *Emitter, op: GpuDialect.UniformOp) EmitError!void {
        const member = op.member() orelse return error.InvalidArtifact;
        const group = op.getGroup() orelse return error.InvalidArtifact;
        const binding = op.getBinding() orelse return error.InvalidArtifact;
        if (group != 0 or binding >= max_uniform_bindings) return error.CapabilityMismatch;
        if (!member.placed(gpu.stage.max_uniform_bytes)) return error.CapabilityMismatch;
        const kind = try blockReadKind(op.op);
        self.interface.uniforms.set(binding);
        const row = member.offset / 16;
        const first = member.offset % 16 / 4;
        std.debug.assert(first + member.width <= 4);
        for (0..member.width) |component| {
            const column = components[first + component];
            const name = if (kind == .u32)
                std.fmt.allocPrint(self.allocator, "choir_uniform{d}[{d}].{s}", .{ binding, row, column })
            else
                std.fmt.allocPrint(self.allocator, "as_type<{s}>(choir_uniform{d}[{d}].{s})", .{
                    try mslScalarType(kind),
                    binding,
                    row,
                    column,
                });
            try self.rememberAndBind(op.op.getResult(component).?, name catch return error.OutOfMemory);
        }
    }

    fn emitSample(self: *Emitter, op: *ir.Operation, explicit_lod: bool) EmitError!void {
        const operands = op.getOperandValues();
        const texture_ptr = operands[0].getDefiningOp() orelse return error.InvalidArtifact;
        const texture_op: *ir.Operation = @ptrCast(@alignCast(texture_ptr));
        if (!std.mem.eql(u8, texture_op.name.name, GpuDialect.SampledTextureOp.operation_name)) {
            return error.InvalidArtifact;
        }
        const binding = (GpuDialect.SampledTextureOp{ .op = texture_op }).getBinding() orelse
            return error.InvalidArtifact;
        for (operands[1..]) |coordinate| {
            if (try scalarKind(coordinate.type) != .f32) return error.UnsupportedOperation;
        }
        const out = try self.freshValueName();
        const u = try self.require(operands[1]);
        const v = try self.require(operands[2]);
        const sample = "const float4 {s} = " ++
            "choir_texture{d}.sample(choir_sampler{d}, float2({s}, {s})";
        if (explicit_lod) {
            const lod = try self.require(operands[3]);
            try self.line(sample ++ ", level({s}));", .{ out, binding, binding, u, v, lod });
        } else {
            try self.line(sample ++ ");", .{ out, binding, binding, u, v });
        }
        try self.bindComponents(op, out);
    }

    /// Binds each result of `op` to one component of `vector`, or its single
    /// result to `vector` whole.
    fn bindComponents(self: *Emitter, op: *ir.Operation, vector: []const u8) abi.Error!void {
        const count = op.getNumResults();
        if (count == 1) return self.bind(op.getResult(0).?, vector);
        for (0..count) |index| {
            const component = components[index];
            const name = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ vector, component }) catch
                return error.OutOfMemory;
            try self.rememberAndBind(op.getResult(index).?, name);
        }
    }

    /// The expression that builds `values` into one value of `kind`.
    fn composite(self: *Emitter, kind: ScalarKind, values: []const *ir.Value) EmitError![]const u8 {
        for (values) |value| {
            if (try interfaceKind(value.type) != kind) return error.InvalidArtifact;
        }
        if (values.len == 1) return self.require(values[0]);
        var text = std.Io.Writer.Allocating.init(self.allocator);
        defer text.deinit();
        const width: u32 = @intCast(values.len);
        try text.writer.print("{s}{s}(", .{ try mslScalarType(kind), widthSuffix(width) });
        for (values, 0..) |value, index| {
            if (index > 0) try text.writer.writeAll(", ");
            try text.writer.writeAll(try self.require(value));
        }
        try text.writer.writeByte(')');
        return self.rememberName(text.toOwnedSlice() catch return error.OutOfMemory);
    }

    fn findKernelFunction(self: *Emitter) abi.Error!FuncDialect.FuncOp {
        if (!std.mem.eql(u8, self.module.name.name, BuiltinDialect.ModuleOp.operation_name)) {
            return error.InvalidArtifact;
        }
        const block = self.module.getRegion(0).?.getEntryBlock() orelse return error.InvalidArtifact;
        var ops = block.getOperations();
        while (ops.next()) |op| {
            if (!std.mem.eql(u8, op.name.name, FuncDialect.FuncOp.operation_name)) continue;
            const func = FuncDialect.FuncOp{ .op = op };
            if (!func.isKernel()) continue;
            const name = func.getName() orelse return error.InvalidArtifact;
            if (std.mem.eql(u8, name, self.entry_name)) return func;
        }
        return error.InvalidArtifact;
    }

    fn emitParameterBindings(self: *Emitter, func: FuncDialect.FuncOp) abi.Error!void {
        const args = func.getArguments();
        for (args, 0..) |arg, index| {
            if (memrefElementKind(arg.type) != null) {
                const name = std.fmt.allocPrint(self.allocator, "arg{d}", .{index}) catch return error.OutOfMemory;
                try self.rememberAndBind(arg, name);
                continue;
            }
            _ = try scalarKind(arg.type);
            const expr = std.fmt.allocPrint(self.allocator, "(*arg{d})", .{index}) catch return error.OutOfMemory;
            try self.rememberAndBind(arg, expr);
        }
    }

    fn emitFunctionHeader(self: *Emitter, writer: *std.Io.Writer, func: FuncDialect.FuncOp) EmitError!void {
        try writer.print("kernel void {s}(\n", .{self.entry_name});
        const args = func.getArguments();
        const total = args.len + 7;
        var index: usize = 0;
        for (args) |arg| {
            const suffix = if (index + 1 == total) "" else ",";
            if (memrefElementKind(arg.type)) |kind| {
                try writer.print("    device {s}* arg{d} [[buffer({d})]]{s}\n", .{ try mslScalarType(kind), index, index, suffix });
            } else {
                try writer.print("    constant {s}* arg{d} [[buffer({d})]]{s}\n", .{ try mslScalarType(try scalarKind(arg.type)), index, index, suffix });
            }
            index += 1;
        }
        try writeBuiltinParameter(writer, &index, total, "choir_thread_position_in_grid", "thread_position_in_grid");
        try writeBuiltinParameter(writer, &index, total, "choir_thread_position_in_threadgroup", "thread_position_in_threadgroup");
        try writeBuiltinParameter(writer, &index, total, "choir_threadgroup_position_in_grid", "threadgroup_position_in_grid");
        try writeBuiltinParameter(writer, &index, total, "choir_threads_per_threadgroup", "threads_per_threadgroup");
        try writeBuiltinParameter(writer, &index, total, "choir_threads_per_grid", "threads_per_grid");
        try writeScalarBuiltinParameter(writer, &index, total, "choir_thread_index_in_simdgroup", "thread_index_in_simdgroup");
        try writeScalarBuiltinParameter(writer, &index, total, "choir_simdgroup_index_in_threadgroup", "simdgroup_index_in_threadgroup");
        try writer.writeAll(") {\n");
    }

    fn emitBlock(self: *Emitter, block: *ir.Block, yield_target: ?YieldTarget) EmitError!void {
        var ops = block.getOperations();
        while (ops.next()) |op| {
            try self.emitOperation(op, yield_target);
        }
    }

    fn emitOperation(self: *Emitter, op: *ir.Operation, yield_target: ?YieldTarget) EmitError!void {
        const name = op.name.name;
        if (!gpu.stage.admits(self.stage, name)) return error.UnsupportedOperation;
        if (self.stage != null) {
            const memref_prefix = MemrefDialect.name ++ ".";
            if (std.mem.startsWith(u8, name, memref_prefix) and
                !std.mem.eql(u8, name, MemrefDialect.AllocaOp.operation_name) and
                !std.mem.eql(u8, name, MemrefDialect.LoadOp.operation_name) and
                !std.mem.eql(u8, name, MemrefDialect.StoreOp.operation_name)) return error.UnsupportedOperation;
            if (try self.emitStageOperation(op)) return;
        }
        if (std.mem.eql(u8, name, FuncDialect.ReturnOp.operation_name)) {
            if (self.stage != null) {
                try self.line("{s}", .{self.return_statement});
            } else if (op.getNumOperands() == 0) {
                try self.line("return;", .{});
            } else if (op.getNumOperands() == 1) {
                try self.line("return {s};", .{try self.require(op.getOperandValues()[0])});
            } else return error.UnsupportedOperation;
        } else if (std.mem.eql(u8, name, FuncDialect.CallOp.operation_name)) {
            try self.emitCall(FuncDialect.CallOp{ .op = op });
        } else if (std.mem.eql(u8, name, ScfDialect.YieldOp.operation_name)) {
            try self.emitYield(ScfDialect.YieldOp{ .op = op }, yield_target);
        } else if (std.mem.eql(u8, name, ScfDialect.IfOp.operation_name)) {
            try self.emitIf(ScfDialect.IfOp{ .op = op });
        } else if (std.mem.eql(u8, name, ScfDialect.ForOp.operation_name)) {
            try self.emitFor(ScfDialect.ForOp{ .op = op });
        } else if (std.mem.eql(u8, name, ScfDialect.WhileOp.operation_name)) {
            try self.emitWhile(ScfDialect.WhileOp{ .op = op });
        } else if (std.mem.eql(u8, name, GpuDialect.GlobalIdxOp.operation_name)) {
            const wrapped = GpuDialect.GlobalIdxOp{ .op = op };
            try self.emitGpuRegister(op, wrapped.getDimension() orelse return error.InvalidArtifact, "choir_thread_position_in_grid");
        } else if (std.mem.eql(u8, name, GpuDialect.ThreadIdxOp.operation_name)) {
            const wrapped = GpuDialect.ThreadIdxOp{ .op = op };
            try self.emitGpuRegister(op, wrapped.getDimension() orelse return error.InvalidArtifact, "choir_thread_position_in_threadgroup");
        } else if (std.mem.eql(u8, name, GpuDialect.BlockIdxOp.operation_name)) {
            const wrapped = GpuDialect.BlockIdxOp{ .op = op };
            try self.emitGpuRegister(op, wrapped.getDimension() orelse return error.InvalidArtifact, "choir_threadgroup_position_in_grid");
        } else if (std.mem.eql(u8, name, GpuDialect.BlockDimOp.operation_name)) {
            const wrapped = GpuDialect.BlockDimOp{ .op = op };
            try self.emitGpuRegister(op, wrapped.getDimension() orelse return error.InvalidArtifact, "choir_threads_per_threadgroup");
        } else if (std.mem.eql(u8, name, GpuDialect.GridDimOp.operation_name)) {
            const wrapped = GpuDialect.GridDimOp{ .op = op };
            try self.emitGridDimRegister(op, wrapped.getDimension() orelse return error.InvalidArtifact);
        } else if (std.mem.eql(u8, name, GpuDialect.LaneIdOp.operation_name)) {
            try self.emitGpuScalarRegister(op, "choir_thread_index_in_simdgroup");
        } else if (std.mem.eql(u8, name, GpuDialect.WarpIdOp.operation_name)) {
            try self.emitGpuScalarRegister(op, "choir_simdgroup_index_in_threadgroup");
        } else if (std.mem.eql(u8, name, GpuDialect.BarrierOp.operation_name)) {
            try self.emitBarrier(GpuDialect.BarrierOp{ .op = op });
        } else if (std.mem.eql(u8, name, GpuDialect.WarpReduceOp.operation_name)) {
            try self.emitWarpReduce(GpuDialect.WarpReduceOp{ .op = op });
        } else if (std.mem.eql(u8, name, GpuDialect.WarpScanOp.operation_name)) {
            try self.emitWarpScan(GpuDialect.WarpScanOp{ .op = op });
        } else if (std.mem.eql(u8, name, MemrefDialect.AllocOp.operation_name)) {
            try self.emitAlloc(MemrefDialect.AllocOp{ .op = op });
        } else if (std.mem.eql(u8, name, MemrefDialect.AllocaOp.operation_name)) {
            try self.emitAlloca(MemrefDialect.AllocaOp{ .op = op });
        } else if (std.mem.eql(u8, name, MemrefDialect.LoadOp.operation_name)) {
            try self.emitLoad(MemrefDialect.LoadOp{ .op = op });
        } else if (std.mem.eql(u8, name, MemrefDialect.StoreOp.operation_name)) {
            try self.emitStore(MemrefDialect.StoreOp{ .op = op });
        } else if (std.mem.eql(u8, name, MemrefDialect.AtomicRmwOp.operation_name)) {
            try self.emitAtomicRmw(MemrefDialect.AtomicRmwOp{ .op = op });
        } else if (std.mem.eql(u8, name, MemrefDialect.AtomicCasOp.operation_name)) {
            try self.emitAtomicCas(MemrefDialect.AtomicCasOp{ .op = op });
        } else if (std.mem.eql(u8, name, ArithDialect.ConstantOp.operation_name)) {
            try self.emitConstant(ArithDialect.ConstantOp{ .op = op });
        } else if (std.mem.eql(u8, name, ArithDialect.AddOp.operation_name)) {
            try self.emitBinary(op, "+");
        } else if (std.mem.eql(u8, name, ArithDialect.SubOp.operation_name)) {
            try self.emitBinary(op, "-");
        } else if (std.mem.eql(u8, name, ArithDialect.MulOp.operation_name)) {
            try self.emitBinary(op, "*");
        } else if (std.mem.eql(u8, name, ArithDialect.UmulhiOp.operation_name)) {
            try self.emitUmulhi(op);
        } else if (std.mem.eql(u8, name, ArithDialect.DivOp.operation_name)) {
            try self.emitBinary(op, "/");
        } else if (std.mem.eql(u8, name, ArithDialect.RemOp.operation_name)) {
            try self.emitRemainder(op);
        } else if (std.mem.eql(u8, name, ArithDialect.MaxOp.operation_name)) {
            try self.emitCall2(op, "max");
        } else if (std.mem.eql(u8, name, ArithDialect.MinOp.operation_name)) {
            try self.emitCall2(op, "min");
        } else if (std.mem.eql(u8, name, ArithDialect.AndOp.operation_name)) {
            try self.emitBinary(op, "&");
        } else if (std.mem.eql(u8, name, ArithDialect.OrOp.operation_name)) {
            try self.emitBinary(op, "|");
        } else if (std.mem.eql(u8, name, ArithDialect.XorOp.operation_name)) {
            try self.emitBinary(op, "^");
        } else if (std.mem.eql(u8, name, ArithDialect.ShlOp.operation_name)) {
            try self.emitBinary(op, "<<");
        } else if (std.mem.eql(u8, name, ArithDialect.ShrOp.operation_name)) {
            try self.emitBinary(op, ">>");
        } else if (std.mem.eql(u8, name, ArithDialect.UshrOp.operation_name)) {
            try self.emitUnsignedShiftRight(op);
        } else if (std.mem.eql(u8, name, ArithDialect.NegOp.operation_name)) {
            try self.emitUnary(op, "-");
        } else if (std.mem.eql(u8, name, ArithDialect.NotOp.operation_name)) {
            try self.emitNot(op);
        } else if (std.mem.eql(u8, name, ArithDialect.AbsOp.operation_name)) {
            try self.emitCall1(op, "abs");
        } else if (std.mem.eql(u8, name, ArithDialect.SqrtOp.operation_name)) {
            try self.emitCall1(op, "sqrt");
        } else if (std.mem.eql(u8, name, ArithDialect.ExpOp.operation_name)) {
            try self.emitCall1(op, "exp");
        } else if (std.mem.eql(u8, name, ArithDialect.LogOp.operation_name)) {
            try self.emitCall1(op, "log");
        } else if (std.mem.eql(u8, name, ArithDialect.TanhOp.operation_name)) {
            try self.emitCall1(op, "tanh");
        } else if (std.mem.eql(u8, name, ArithDialect.SinOp.operation_name)) {
            try self.emitCall1(op, "sin");
        } else if (std.mem.eql(u8, name, ArithDialect.CosOp.operation_name)) {
            try self.emitCall1(op, "cos");
        } else if (std.mem.eql(u8, name, ArithDialect.TanOp.operation_name)) {
            try self.emitCall1(op, "tan");
        } else if (std.mem.eql(u8, name, ArithDialect.FloorOp.operation_name)) {
            try self.emitCall1(op, "floor");
        } else if (std.mem.eql(u8, name, ArithDialect.RoundOp.operation_name)) {
            try self.emitRound(op);
        } else if (std.mem.eql(u8, name, ArithDialect.TruncOp.operation_name)) {
            try self.emitCall1(op, "trunc");
        } else if (std.mem.eql(u8, name, ArithDialect.PowOp.operation_name)) {
            try self.emitCall2(op, "pow");
        } else if (std.mem.eql(u8, name, ArithDialect.Atan2Op.operation_name)) {
            try self.emitCall2(op, "atan2");
        } else if (std.mem.eql(u8, name, ArithDialect.FmaOp.operation_name)) {
            try self.emitFma(ArithDialect.FmaOp{ .op = op });
        } else if (std.mem.eql(u8, name, ArithDialect.CmpOp.operation_name)) {
            try self.emitCompare(ArithDialect.CmpOp{ .op = op });
        } else if (std.mem.eql(u8, name, ArithDialect.SelectOp.operation_name)) {
            try self.emitSelect(ArithDialect.SelectOp{ .op = op });
        } else if (std.mem.eql(u8, name, ArithDialect.CastOp.operation_name)) {
            try self.emitCast(ArithDialect.CastOp{ .op = op });
        } else if (std.mem.eql(u8, name, ArithDialect.BitcastOp.operation_name)) {
            try self.emitBitcast(ArithDialect.BitcastOp{ .op = op });
        } else {
            return error.UnsupportedOperation;
        }
    }

    fn emitGpuRegister(self: *Emitter, op: *ir.Operation, dim: gpu.Dimension, builtin_name: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const out = try self.freshValueName();
        try self.line("const int {s} = int({s}.{s});", .{ out, builtin_name, dimName(dim) });
        try self.bind(result, out);
    }

    fn emitGridDimRegister(self: *Emitter, op: *ir.Operation, dim: gpu.Dimension) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const out = try self.freshValueName();
        try self.line("const int {s} = int(choir_threads_per_grid.{s} / choir_threads_per_threadgroup.{s});", .{ out, dimName(dim), dimName(dim) });
        try self.bind(result, out);
    }

    fn emitGpuScalarRegister(self: *Emitter, op: *ir.Operation, builtin_name: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const out = try self.freshValueName();
        try self.line("const int {s} = int({s});", .{ out, builtin_name });
        try self.bind(result, out);
    }

    fn emitBarrier(self: *Emitter, op: GpuDialect.BarrierOp) EmitError!void {
        const scope = op.getScope() orelse return error.InvalidArtifact;
        switch (scope) {
            .block => try self.line("threadgroup_barrier(mem_flags::mem_threadgroup);", .{}),
            else => return error.UnsupportedOperation,
        }
    }

    fn emitWarpReduce(self: *Emitter, op: GpuDialect.WarpReduceOp) EmitError!void {
        try self.requireFullWarpMask(op.getMask());
        const result = op.getResult();
        const kind = try scalarKind(result.type);
        const out = try self.freshValueName();
        try self.line("const {s} {s} = {s}({s});", .{
            try mslScalarType(kind),
            out,
            try mslWarpReduceFunction(op.getOpKind() orelse return error.InvalidArtifact, kind),
            try self.require(op.getValue()),
        });
        try self.bind(result, out);
    }

    fn emitWarpScan(self: *Emitter, op: GpuDialect.WarpScanOp) EmitError!void {
        try self.requireFullWarpMask(op.getMask());
        const result = op.getResult();
        const kind = try scalarKind(result.type);
        const out = try self.freshValueName();
        try self.line("const {s} {s} = {s}({s});", .{
            try mslScalarType(kind),
            out,
            try mslWarpScanFunction(op.getOpKind() orelse return error.InvalidArtifact, op.isInclusive(), kind),
            try self.require(op.getValue()),
        });
        try self.bind(result, out);
    }

    fn requireFullWarpMask(_: *Emitter, mask: *ir.Value) abi.Error!void {
        const defining = mask.getDefiningOp() orelse return error.UnsupportedOperation;
        const op: *ir.Operation = @ptrCast(@alignCast(defining));
        if (!std.mem.eql(u8, op.name.name, ArithDialect.ConstantOp.operation_name)) return error.UnsupportedOperation;
        const constant = ArithDialect.ConstantOp{ .op = op };
        const int_value = constant.getIntValue() orelse return error.UnsupportedOperation;
        if (int_value != -1) return error.UnsupportedOperation;
    }

    fn emitAlloc(self: *Emitter, op: MemrefDialect.AllocOp) EmitError!void {
        if (op.getDynamicSize() != null) return error.UnsupportedOperation;
        const result = op.getResult();
        const info = memrefInfo(result.type) orelse return error.InvalidArtifact;
        if (info.addr_space != .shared) return error.UnsupportedOperation;
        const size = info.size orelse return error.InvalidArtifact;
        if (size == 0) return error.InvalidArtifact;
        const out = try self.freshSharedName();
        try self.line("threadgroup {s} {s}[{d}];", .{ try mslScalarType(info.element), out, size });
        try self.bind(result, out);
    }

    fn emitAlloca(self: *Emitter, op: MemrefDialect.AllocaOp) EmitError!void {
        if (op.getDynamicSize() != null) return error.UnsupportedOperation;
        const result = op.getResult();
        const info = memrefInfo(result.type) orelse return error.InvalidArtifact;
        if (info.addr_space != .local) return error.UnsupportedOperation;
        const size = info.size orelse return error.UnsupportedOperation;
        if (size == 0 or size > std.math.maxInt(u32)) return error.UnsupportedOperation;
        const out = try self.freshValueName();
        try self.line("thread {s} {s}[{d}];", .{ try mslScalarType(info.element), out, size });
        try self.bind(result, out);
    }

    fn emitCall(self: *Emitter, call: FuncDialect.CallOp) EmitError!void {
        const name = call.getCallee() orelse return error.InvalidArtifact;
        if (call.getNumResults() > 1) return error.UnsupportedOperation;
        var arguments = std.Io.Writer.Allocating.init(self.allocator);
        defer arguments.deinit();
        for (call.getOperands(), 0..) |arg, index| {
            if (index != 0) try arguments.writer.writeAll(", ");
            try arguments.writer.writeAll(try self.require(arg));
        }
        if (call.getResult(0)) |result| {
            const out = try self.freshValueName();
            try self.line("const {s} {s} = {s}({s});", .{
                try mslScalarType(try scalarKind(result.type)), out, name, arguments.written(),
            });
            try self.bind(result, out);
        } else {
            try self.line("{s}({s});", .{ name, arguments.written() });
        }
    }

    fn emitLoad(self: *Emitter, op: MemrefDialect.LoadOp) EmitError!void {
        if (self.stage != null and (memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact).addr_space != .local) return error.UnsupportedOperation;
        const result = op.getResult();
        const kind = try scalarKind(result.type);
        const out = try self.freshValueName();
        try self.line("const {s} {s} = {s}[{s}];", .{
            try mslScalarType(kind),
            out,
            try self.require(op.getMemref()),
            try self.require(op.getIndex()),
        });
        try self.bind(result, out);
    }

    fn emitStore(self: *Emitter, op: MemrefDialect.StoreOp) EmitError!void {
        if (self.stage != null and (memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact).addr_space != .local) return error.UnsupportedOperation;
        try self.line("{s}[{s}] = {s};", .{
            try self.require(op.getMemref()),
            try self.require(op.getIndex()),
            try self.require(op.getValue()),
        });
    }

    fn emitAtomicRmw(self: *Emitter, op: MemrefDialect.AtomicRmwOp) EmitError!void {
        const result = op.getResult();
        const info = memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact;
        if (try scalarKind(result.type) != info.element) return error.InvalidArtifact;

        const atomic_kind = op.getKind() orelse return error.InvalidArtifact;
        const atomic_function = try mslAtomicFunction(atomic_kind);
        const atomic_type = try mslAtomicScalarType(atomic_kind, info.element, info.addr_space);
        const address_space = try mslAtomicAddressSpace(info.addr_space);
        const value_type = try mslScalarType(info.element);
        const out = try self.freshValueName();
        try self.line("const {s} {s} = {s}_explicit(({s} {s}*)(&{s}[{s}]), {s}, memory_order_relaxed);", .{
            value_type,
            out,
            atomic_function,
            address_space,
            atomic_type,
            try self.require(op.getMemref()),
            try self.require(op.getIndex()),
            try self.require(op.getValue()),
        });
        try self.bind(result, out);
    }

    fn emitAtomicCas(self: *Emitter, op: MemrefDialect.AtomicCasOp) EmitError!void {
        const result = op.getResult();
        const info = memrefInfo(op.getMemref().type) orelse return error.InvalidArtifact;
        const kind = try scalarKind(result.type);
        if (kind != info.element) return error.InvalidArtifact;

        const atomic_type = try mslAtomicCasScalarType(info.element);
        const address_space = try mslAtomicAddressSpace(info.addr_space);
        const value_type = try mslScalarType(info.element);
        const old_value = try self.freshValueName();
        const changed = try self.freshValueName();
        try self.line("{s} {s} = {s};", .{
            value_type,
            old_value,
            try self.require(op.getExpected()),
        });
        try self.line("bool {s};", .{changed});
        try self.line("do {{", .{});
        self.indent += 1;
        try self.line("{s} = atomic_compare_exchange_weak_explicit(({s} {s}*)(&{s}[{s}]), &{s}, {s}, memory_order_relaxed, memory_order_relaxed);", .{
            changed,
            address_space,
            atomic_type,
            try self.require(op.getMemref()),
            try self.require(op.getIndex()),
            old_value,
            try self.require(op.getDesired()),
        });
        self.indent -= 1;
        try self.line("}} while (!{s} && {s} == {s});", .{
            changed,
            old_value,
            try self.require(op.getExpected()),
        });
        try self.bind(result, old_value);
    }

    fn emitConstant(self: *Emitter, op: ArithDialect.ConstantOp) EmitError!void {
        const result = op.getResult();
        const kind = try scalarKind(result.type);
        const out = try self.freshValueName();
        switch (kind) {
            .bool => {
                const bool_attr = op.op.getAttrAs(ir.Attribute.BoolAttr, "value") orelse return error.InvalidArtifact;
                try self.line("const bool {s} = {s};", .{ out, if (bool_attr.getValue()) "true" else "false" });
            },
            .index => {
                const value = op.getIntValue() orelse return error.InvalidArtifact;
                if (value < 0) return error.UnsupportedOperation;
                try self.line("const int {s} = int({d});", .{ out, value });
            },
            .u32 => {
                const value = op.getIntValue() orelse return error.InvalidArtifact;
                if (value < 0) return error.UnsupportedOperation;
                try self.line("const uint {s} = uint({d});", .{ out, value });
            },
            .i8, .i16, .i32, .i64 => {
                const value = op.getIntValue() orelse return error.InvalidArtifact;
                try self.line("const {s} {s} = {s}({d});", .{ try mslScalarType(kind), out, try mslScalarType(kind), value });
            },
            .f16 => {
                const value = op.getFloatValue() orelse return error.InvalidArtifact;
                try self.line("const half {s} = half(as_type<float>(0x{X:0>8}u));", .{ out, floatBits(value) });
            },
            .f32 => {
                const value = op.getFloatValue() orelse return error.InvalidArtifact;
                try self.line("const float {s} = as_type<float>(0x{X:0>8}u);", .{ out, floatBits(value) });
            },
            .u8, .u16, .u64, .bf16, .f64 => return error.UnsupportedOperation,
        }
        try self.bind(result, out);
    }

    fn emitBinary(self: *Emitter, op: *ir.Operation, operator: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const out = try self.freshValueName();
        try self.line("const {s} {s} = {s} {s} {s};", .{
            try mslScalarType(try scalarKind(result.type)),
            out,
            try self.require(op.operands.items[0].value),
            operator,
            try self.require(op.operands.items[1].value),
        });
        try self.bind(result, out);
    }

    /// Writes arith.rem, which truncates toward zero. MSL leaves `%` undefined
    /// when an operand is negative, so a signed remainder is written as
    /// `a - (a / b) * b`, which equals the truncated remainder once the quotient
    /// is defined. `uint` keeps `%`. `index` is ordered unsigned in arith but
    /// typed `int` here, so it takes `%` through `uint`, as OpUMod does on
    /// SPIR-V. The divisor obligation (nonzero, and not MIN / -1 when signed)
    /// belongs to the front end, and this emitter assumes it discharged.
    fn emitRemainder(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const kind = try scalarKind(result.type);
        const out = try self.freshValueName();
        const lhs = try self.require(op.operands.items[0].value);
        const rhs = try self.require(op.operands.items[1].value);
        switch (kind) {
            .i8, .i16, .i32, .i64 => try self.line("const {s} {s} = {s} - ({s} / {s}) * {s};", .{
                try mslScalarType(kind), out, lhs, lhs, rhs, rhs,
            }),
            .u32 => try self.line("const uint {s} = {s} % {s};", .{ out, lhs, rhs }),
            .index => try self.line("const int {s} = as_type<int>(as_type<uint>({s}) % as_type<uint>({s}));", .{ out, lhs, rhs }),
            else => return error.UnsupportedOperation,
        }
        try self.bind(result, out);
    }

    fn emitUnary(self: *Emitter, op: *ir.Operation, operator: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const out = try self.freshValueName();
        try self.line("const {s} {s} = {s}{s};", .{
            try mslScalarType(try scalarKind(result.type)),
            out,
            operator,
            try self.require(op.operands.items[0].value),
        });
        try self.bind(result, out);
    }

    fn emitUnsignedShiftRight(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const kind = try scalarKind(result.type);
        const signed_type = try mslScalarType(kind);
        const unsigned_type = try mslUnsignedScalarType(kind);
        const out = try self.freshValueName();
        try self.line("const {s} {s} = as_type<{s}>({s}(as_type<{s}>({s}) >> as_type<{s}>({s})));", .{
            signed_type,
            out,
            signed_type,
            unsigned_type,
            unsigned_type,
            try self.require(op.operands.items[0].value),
            unsigned_type,
            try self.require(op.operands.items[1].value),
        });
        try self.bind(result, out);
    }

    fn emitNot(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const out = try self.freshValueName();
        const kind = try scalarKind(result.type);
        const operator = switch (kind) {
            .bool => "!",
            .index, .i8, .i16, .i32, .u32, .i64 => "~",
            else => return error.UnsupportedOperation,
        };
        try self.line("const {s} {s} = {s}{s};", .{
            try mslScalarType(kind),
            out,
            operator,
            try self.require(op.operands.items[0].value),
        });
        try self.bind(result, out);
    }

    fn emitCall1(self: *Emitter, op: *ir.Operation, function_name: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const out = try self.freshValueName();
        try self.line("const {s} {s} = {s}({s});", .{
            try mslScalarType(try scalarKind(result.type)),
            out,
            function_name,
            try self.require(op.operands.items[0].value),
        });
        try self.bind(result, out);
    }

    fn emitCall2(self: *Emitter, op: *ir.Operation, function_name: []const u8) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const out = try self.freshValueName();
        try self.line("const {s} {s} = {s}({s}, {s});", .{
            try mslScalarType(try scalarKind(result.type)),
            out,
            function_name,
            try self.require(op.operands.items[0].value),
            try self.require(op.operands.items[1].value),
        });
        try self.bind(result, out);
    }

    fn emitUmulhi(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const kind = try scalarKind(result.type);
        const signed_type = try mslScalarType(kind);
        const unsigned_type: []const u8 = switch (kind) {
            .index => "uint",
            .i32 => "uint",
            .u32 => "uint",
            .i64 => "ulong",
            else => return error.UnsupportedOperation,
        };
        const out = try self.freshValueName();
        try self.line("const {s} {s} = as_type<{s}>(mulhi(as_type<{s}>({s}), as_type<{s}>({s})));", .{
            signed_type,
            out,
            signed_type,
            unsigned_type,
            try self.require(op.operands.items[0].value),
            unsigned_type,
            try self.require(op.operands.items[1].value),
        });
        try self.bind(result, out);
    }

    fn emitFma(self: *Emitter, op: ArithDialect.FmaOp) EmitError!void {
        const result = op.getResult();
        const out = try self.freshValueName();
        try self.line("const {s} {s} = fma({s}, {s}, {s});", .{
            try mslScalarType(try scalarKind(result.type)),
            out,
            try self.require(op.getA()),
            try self.require(op.getB()),
            try self.require(op.getC()),
        });
        try self.bind(result, out);
    }

    fn emitCompare(self: *Emitter, op: ArithDialect.CmpOp) EmitError!void {
        const out = try self.freshValueName();
        try self.line("const bool {s} = {s} {s} {s};", .{
            out,
            try self.require(op.op.operands.items[0].value),
            comparisonOperator(op.getPredicate() orelse return error.InvalidArtifact),
            try self.require(op.op.operands.items[1].value),
        });
        try self.bind(op.getResult(), out);
    }

    fn emitSelect(self: *Emitter, op: ArithDialect.SelectOp) EmitError!void {
        const result = op.getResult();
        const out = try self.freshValueName();
        try self.line("const {s} {s} = {s} ? {s} : {s};", .{
            try mslScalarType(try scalarKind(result.type)),
            out,
            try self.require(op.getCondition()),
            try self.require(op.getTrueValue()),
            try self.require(op.getFalseValue()),
        });
        try self.bind(result, out);
    }

    fn emitCast(self: *Emitter, op: ArithDialect.CastOp) EmitError!void {
        const result = op.getResult();
        const out = try self.freshValueName();
        const ty = try mslScalarType(try scalarKind(result.type));
        try self.line("const {s} {s} = {s}({s});", .{
            ty,
            out,
            ty,
            try self.require(op.getInput()),
        });
        try self.bind(result, out);
    }

    fn emitBitcast(self: *Emitter, op: ArithDialect.BitcastOp) EmitError!void {
        const result = op.getResult();
        const out = try self.freshValueName();
        const ty = try mslScalarType(try scalarKind(result.type));
        try self.line("const {s} {s} = as_type<{s}>({s});", .{
            ty,
            out,
            ty,
            try self.require(op.getInput()),
        });
        try self.bind(result, out);
    }

    fn emitRound(self: *Emitter, op: *ir.Operation) EmitError!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const input = try self.require(op.operands.items[0].value);
        const kind = try scalarKind(result.type);
        const out = try self.freshValueName();
        const magnitude = try self.freshValueName();
        const sign = try self.freshValueName();
        const bits = try self.freshValueName();
        switch (kind) {
            .f16 => {
                try self.line("const half {s} = floor(abs({s}) + half(0.5));", .{ magnitude, input });
                try self.line("const ushort {s} = as_type<ushort>({s}) & ushort(0x8000);", .{ sign, input });
                try self.line("const ushort {s} = (as_type<ushort>({s}) & ushort(0x7fff)) | {s};", .{ bits, magnitude, sign });
                try self.line("const half {s} = as_type<half>({s});", .{ out, bits });
            },
            .f32 => {
                try self.line("const float {s} = floor(abs({s}) + float(0.5));", .{ magnitude, input });
                try self.line("const uint {s} = as_type<uint>({s}) & 0x80000000u;", .{ sign, input });
                try self.line("const uint {s} = (as_type<uint>({s}) & 0x7fffffffu) | {s};", .{ bits, magnitude, sign });
                try self.line("const float {s} = as_type<float>({s});", .{ out, bits });
            },
            else => return error.UnsupportedOperation,
        }
        try self.bind(result, out);
    }

    fn emitIf(self: *Emitter, op: ScfDialect.IfOp) EmitError!void {
        if (op.getNumResults() != 0) return error.UnsupportedOperation;
        try self.line("if ({s}) {{", .{try self.require(op.getCondition())});
        self.indent += 1;
        try self.emitBlock(op.getThenBlock(), null);
        self.indent -= 1;
        if (op.getElseBlock()) |else_block| {
            try self.line("}} else {{", .{});
            self.indent += 1;
            try self.emitBlock(else_block, null);
            self.indent -= 1;
        }
        try self.line("}}", .{});
    }

    fn emitWhile(self: *Emitter, op: ScfDialect.WhileOp) EmitError!void {
        const before = op.getBeforeBlock();
        const after = op.getAfterBlock();
        const carry_count = op.op.operands.items.len;
        if (op.op.results.items.len != carry_count) return error.InvalidArtifact;
        if (before.arguments.items.len != carry_count) return error.InvalidArtifact;
        if (after.arguments.items.len != carry_count) return error.InvalidArtifact;

        const carry_names = self.allocator.alloc([]const u8, carry_count) catch return error.OutOfMemory;
        defer self.allocator.free(carry_names);
        const exit_names = self.allocator.alloc([]const u8, carry_count) catch return error.OutOfMemory;
        defer self.allocator.free(exit_names);

        for (0..carry_count) |index| {
            const operand = op.op.operands.items[index].value;
            const carry_type = try mslScalarType(try scalarKind(operand.type));
            carry_names[index] = try self.freshLoopName();
            try self.line("{s} {s} = {s};", .{ carry_type, carry_names[index], try self.require(operand) });
            exit_names[index] = try self.freshLoopName();
            try self.line("{s} {s};", .{ carry_type, exit_names[index] });
            try self.bind(before.arguments.items[index], carry_names[index]);
        }

        try self.line("while (true) {{", .{});
        self.indent += 1;

        var before_ops = before.getOperations();
        var saw_condition = false;
        while (before_ops.next()) |before_op| {
            if (std.mem.eql(u8, before_op.name.name, ScfDialect.ConditionOp.operation_name)) {
                const condition = ScfDialect.ConditionOp{ .op = before_op };
                const args = condition.getArgs();
                if (args.len != carry_count) return error.InvalidArtifact;
                try self.line("if (!({s})) {{", .{try self.require(condition.getCondition())});
                self.indent += 1;
                for (args, exit_names) |arg, exit_name| {
                    try self.line("{s} = {s};", .{ exit_name, try self.require(arg) });
                }
                try self.line("break;", .{});
                self.indent -= 1;
                try self.line("}}", .{});
                for (args, 0..) |arg, index| {
                    try self.bind(after.arguments.items[index], try self.require(arg));
                }
                saw_condition = true;
                break;
            }
            try self.emitOperation(before_op, null);
        }
        if (!saw_condition) return error.InvalidArtifact;

        try self.emitBlock(after, .{ .names = carry_names });
        self.indent -= 1;
        try self.line("}}", .{});

        for (op.op.results.items, exit_names) |*result, exit_name| {
            try self.bind(result, exit_name);
        }
    }

    fn emitFor(self: *Emitter, op: ScfDialect.ForOp) EmitError!void {
        const init_args = op.getInitArgs();
        if (op.op.results.items.len != init_args.len) return error.InvalidArtifact;

        const accumulator_names = self.allocator.alloc([]const u8, init_args.len) catch return error.OutOfMemory;
        defer self.allocator.free(accumulator_names);

        const iter_args = op.getIterArgs();
        for (init_args, 0..) |initial, index| {
            const name = try self.freshLoopName();
            accumulator_names[index] = name;
            try self.line("{s} {s} = {s};", .{
                try mslScalarType(try scalarKind(initial.type)),
                name,
                try self.require(initial),
            });
            try self.bind(iter_args[index], name);
        }

        const iv_name = try self.freshLoopName();
        try self.bind(op.getInductionVar(), iv_name);
        const lower = try self.require(op.getLowerBound());
        const upper = try self.require(op.getUpperBound());
        const step = try self.require(op.getStep());
        try self.line("for (int {s} = {s}; {s} < {s}; {s} += {s}) {{", .{ iv_name, lower, iv_name, upper, iv_name, step });
        self.indent += 1;
        try self.emitBlock(op.getBodyBlock(), .{ .names = accumulator_names });
        self.indent -= 1;
        try self.line("}}", .{});

        for (op.op.results.items, 0..) |*result, index| {
            try self.bind(result, accumulator_names[index]);
        }
    }

    fn emitYield(self: *Emitter, op: ScfDialect.YieldOp, yield_target: ?YieldTarget) EmitError!void {
        const operands = op.getOperands();
        const target_names = if (yield_target) |target_binding| target_binding.names else {
            if (operands.len != 0) return error.UnsupportedOperation;
            return;
        };
        if (operands.len != target_names.len) return error.InvalidArtifact;
        for (operands, target_names) |operand, target_name| {
            try self.line("{s} = {s};", .{ target_name, try self.require(operand) });
        }
    }

    fn freshValueName(self: *Emitter) abi.Error![]const u8 {
        const index = self.next_value;
        self.next_value += 1;
        const name = std.fmt.allocPrint(self.allocator, "v{d}", .{index}) catch return error.OutOfMemory;
        return try self.rememberName(name);
    }

    fn freshLoopName(self: *Emitter) abi.Error![]const u8 {
        const index = self.next_loop;
        self.next_loop += 1;
        const name = std.fmt.allocPrint(self.allocator, "l{d}", .{index}) catch return error.OutOfMemory;
        return try self.rememberName(name);
    }

    fn freshSharedName(self: *Emitter) abi.Error![]const u8 {
        const index = self.next_shared;
        self.next_shared += 1;
        const name = std.fmt.allocPrint(self.allocator, "shared{d}", .{index}) catch return error.OutOfMemory;
        return try self.rememberName(name);
    }

    fn rememberAndBind(self: *Emitter, value: *const ir.Value, name: []u8) abi.Error!void {
        const owned = try self.rememberName(name);
        try self.bind(value, owned);
    }

    fn rememberName(self: *Emitter, name: []u8) abi.Error![]const u8 {
        self.names.append(self.allocator, name) catch {
            self.allocator.free(name);
            return error.OutOfMemory;
        };
        return name;
    }

    fn bind(self: *Emitter, value: *const ir.Value, name: []const u8) abi.Error!void {
        self.values.put(self.allocator, value, name) catch return error.OutOfMemory;
    }

    fn require(self: *Emitter, value: *const ir.Value) abi.Error![]const u8 {
        return self.values.get(value) orelse error.InvalidArtifact;
    }

    fn line(self: *Emitter, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
        for (0..self.indent) |_| try self.body.writer.writeAll("    ");
        try self.body.writer.print(fmt, args);
        try self.body.writer.writeByte('\n');
    }
};

fn writeHeader(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("#include <metal_stdlib>\nusing namespace metal;\n\n");
}

fn writeMember(
    writer: *std.Io.Writer,
    stage: Stage,
    direction: Direction,
    location: usize,
    slot: Slot,
) EmitError!void {
    try writer.print("    {s}{s} {s}{d} ", .{
        try mslScalarType(slot.kind),
        widthSuffix(slot.width),
        memberPrefix(stage, direction),
        location,
    });
    const flat = slot.kind != .f32;
    switch (stage) {
        .vertex => switch (direction) {
            .input => try writer.print("[[attribute({d})]];\n", .{location}),
            .output => try writer.print("[[user(locn{d})]];\n", .{location}),
        },
        .fragment => switch (direction) {
            .input => if (flat)
                try writer.print("[[user(locn{d}), flat]];\n", .{location})
            else
                try writer.print("[[user(locn{d})]];\n", .{location}),
            .output => try writer.print("[[color({d})]];\n", .{location}),
        },
    }
}

/// Writes a signature's parameters one per line, with a comma after each but
/// the last.
const ParameterList = struct {
    writer: *std.Io.Writer,
    total: usize,
    index: usize = 0,

    fn add(self: *ParameterList, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
        std.debug.assert(self.index < self.total);
        try self.writer.writeAll("    ");
        try self.writer.print(fmt, args);
        try self.writer.writeAll(if (self.index + 1 == self.total) "\n" else ",\n");
        self.index += 1;
    }
};

fn writeBuiltinParameter(
    writer: *std.Io.Writer,
    index: *usize,
    total: usize,
    name: []const u8,
    attribute: []const u8,
) std.Io.Writer.Error!void {
    const suffix = if (index.* + 1 == total) "" else ",";
    try writer.print("    uint3 {s} [[{s}]]{s}\n", .{ name, attribute, suffix });
    index.* += 1;
}

fn writeScalarBuiltinParameter(
    writer: *std.Io.Writer,
    index: *usize,
    total: usize,
    name: []const u8,
    attribute: []const u8,
) std.Io.Writer.Error!void {
    const suffix = if (index.* + 1 == total) "" else ",";
    try writer.print("    uint {s} [[{s}]]{s}\n", .{ name, attribute, suffix });
    index.* += 1;
}

fn scalarKind(typ: ir.Type) abi.Error!ScalarKind {
    return scalar_kinds.kindFromType(typ) orelse error.UnsupportedOperation;
}

fn memrefElementKind(typ: ir.Type) ?ScalarKind {
    return if (memrefInfo(typ)) |info| info.element else null;
}

const MemrefInfo = struct {
    size: ?u64,
    element: ScalarKind,
    addr_space: dialects.AddressSpace,
};

fn memrefInfo(typ: ir.Type) ?MemrefInfo {
    const name = typ.getDialectTypeName() orelse return null;
    if (!std.mem.eql(u8, name, MemrefDialect.name)) return null;
    const params = MemrefDialect.parseMemrefParams(typ.getDialectParamKey() orelse return null) orelse return null;
    return .{
        .size = params.size,
        .element = scalar_kinds.kindFromTypeName(params.element_type_name) orelse return null,
        .addr_space = params.addr_space,
    };
}

fn mslScalarType(kind: ScalarKind) abi.Error![]const u8 {
    return switch (kind) {
        .bool => "bool",
        .index => "int",
        .i8 => "char",
        .i16 => "short",
        .i32 => "int",
        .u32 => "uint",
        .i64 => "long",
        .f16 => "half",
        .f32 => "float",
        .u8, .u16, .u64, .bf16, .f64 => error.UnsupportedOperation,
    };
}

fn mslUnsignedScalarType(kind: ScalarKind) abi.Error![]const u8 {
    return switch (kind) {
        .index => "uint",
        .i8 => "uchar",
        .i16 => "ushort",
        .i32 => "uint",
        .u32 => "uint",
        .i64 => "ulong",
        else => error.UnsupportedOperation,
    };
}

fn mslAtomicScalarType(kind: AtomicRmwKind, scalar: ScalarKind, addr_space: dialects.AddressSpace) abi.Error![]const u8 {
    return switch (scalar) {
        .index, .i32 => "atomic_int",
        .u32 => "atomic_uint",
        .f32 => switch (kind) {
            .add => switch (addr_space) {
                .host, .device, .unified => "atomic_float",
                .shared, .constant, .local => error.UnsupportedOperation,
            },
            .min, .max, .bit_and, .bit_or, .bit_xor, .exchange => error.UnsupportedOperation,
        },
        else => error.UnsupportedOperation,
    };
}

fn mslAtomicCasScalarType(kind: ScalarKind) abi.Error![]const u8 {
    return switch (kind) {
        .index, .i32 => "atomic_int",
        .u32 => "atomic_uint",
        else => error.UnsupportedOperation,
    };
}

fn mslAtomicAddressSpace(addr_space: dialects.AddressSpace) abi.Error![]const u8 {
    return switch (addr_space) {
        .host, .device, .unified => "device",
        .shared => "threadgroup",
        .constant, .local => error.UnsupportedOperation,
    };
}

fn mslAtomicFunction(kind: AtomicRmwKind) abi.Error![]const u8 {
    return switch (kind) {
        .add => "atomic_fetch_add",
        .min => "atomic_fetch_min",
        .max => "atomic_fetch_max",
        .bit_and => "atomic_fetch_and",
        .bit_or => "atomic_fetch_or",
        .bit_xor => "atomic_fetch_xor",
        .exchange => "atomic_exchange",
    };
}

fn mslWarpReduceFunction(kind: gpu.WarpOpKind, scalar: ScalarKind) abi.Error![]const u8 {
    switch (scalar) {
        .index, .i32, .u32, .f32 => {},
        else => return error.UnsupportedOperation,
    }
    return switch (kind) {
        .add => "simd_sum",
        else => error.UnsupportedOperation,
    };
}

fn mslWarpScanFunction(kind: gpu.WarpOpKind, inclusive: bool, scalar: ScalarKind) abi.Error![]const u8 {
    switch (scalar) {
        .index, .i32, .u32, .f32 => {},
        else => return error.UnsupportedOperation,
    }
    switch (kind) {
        .add => {},
        else => return error.UnsupportedOperation,
    }
    return if (inclusive) "simd_prefix_inclusive_sum" else "simd_prefix_exclusive_sum";
}

fn dimName(dim: gpu.Dimension) []const u8 {
    return switch (dim) {
        .x => "x",
        .y => "y",
        .z => "z",
    };
}

fn comparisonOperator(pred: CmpPredicate) []const u8 {
    return switch (pred) {
        .eq => "==",
        .ne => "!=",
        .lt, .slt, .ult => "<",
        .le, .sle, .ule => "<=",
        .gt, .sgt, .ugt => ">",
        .ge, .sge, .uge => ">=",
    };
}

fn floatBits(value: f64) u32 {
    const narrowed: f32 = @floatCast(value);
    return @bitCast(narrowed);
}

test "metal scalar support mask follows Choir scalar spellings" {
    inline for (std.meta.tags(ScalarKind)) |kind| {
        const expected: ?ScalarKind = if (scalar_kinds.contains(kind)) kind else null;
        try std.testing.expectEqual(
            expected,
            scalar_kinds.kindFromTypeName(dialects.arith.scalarTypeName(kind)),
        );
    }
    try std.testing.expectEqual(@as(?ScalarKind, null), scalar_kinds.kindFromTypeName("arith.unknown"));
}
