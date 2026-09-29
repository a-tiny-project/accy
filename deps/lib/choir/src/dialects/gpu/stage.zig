//! The vertex and fragment vocabulary of the gpu dialect.
//!
//! A function runs as a stage when it holds a `stage` attribute where a
//! compute function holds `kernel`. Stage values stay scalar like every other
//! gpu value: an interface slot of up to four components reads as that many
//! results and writes as that many operands, and each emitter builds or splits
//! the vector at the interface.
//!
//! A texture and its sampler are one binding, because the render contract
//! binds a `sampled_texture` and names no separate sampler.
//!
//! A push constant or a uniform read names one block member by its byte
//! offset and reads it as up to four components of one 4-byte scalar type.
//! The op carries the layout; no emitter infers one. `Member` holds the rules
//! a member must meet, and an emitter refuses a member its target cannot place.

const std = @import("std");
const choir = @import("../../root.zig");
const tags = @import("tags.zig");

const ir = choir.ir;
const effects = ir.interfaces.effects;
const arith = choir.dialects.arith;

const Stage = tags.Stage;

/// The components one interface slot holds.
pub const max_components = 4;
/// Interface slots per direction. Vulkan guarantees 16 vertex inputs and 64
/// vertex output components, which are 16 slots of four.
pub const max_locations = 16;
/// The function attribute that holds a stage.
pub const stage_attr_key = "stage";
/// Bytes a push-constant block holds at most: Vulkan's guaranteed
/// `maxPushConstantsSize`.
pub const max_push_constant_bytes = 128;
/// Bytes a uniform block holds at most: Vulkan's guaranteed
/// `maxUniformBufferRange`.
pub const max_uniform_bytes = 16384;

/// Where a block member of `width` 4-byte components sits. Blocks follow
/// std140 for the scalars and vectors a stage reads, where std430 and WGSL's
/// host-shareable rules agree: a scalar has size 4 and alignment 4, a
/// two-component vector 8 and 8, a three-component vector 12 and 16, and a
/// four-component vector 16 and 16. A member so aligned never crosses a
/// 16-byte row, which lets an emitter read a uniform one row at a time.
pub const Member = struct {
    offset: u32,
    width: u32,

    pub fn size(self: Member) u32 {
        return 4 * self.width;
    }

    pub fn alignment(self: Member) u32 {
        return switch (self.width) {
            1 => 4,
            2 => 8,
            else => 16,
        };
    }

    pub fn end(self: Member) u32 {
        return self.offset + self.size();
    }

    /// Whether the member has a width a read may take, sits at an offset its
    /// alignment divides, and ends inside a block of `capacity` bytes.
    pub fn placed(self: Member, capacity: u32) bool {
        if (self.width < 1 or self.width > max_components) return false;
        if (self.offset % self.alignment() != 0) return false;
        return self.offset <= capacity and self.size() <= capacity - self.offset;
    }
};

const names = struct {
    pub const name = "gpu";
};
const op_specs = ir.dialects.opSpec.dialect(names);

fn loadSpec(ctx: *ir.Context) !void {
    try ir.dialects.loadDialectSpec(ctx, @import("dialect.zig").GpuDialect.spec);
}

pub fn getStageAttr(ctx: *ir.Context, stage: Stage) !ir.Attribute {
    return ctx.getDialectAttr(tags.attr_names.stage, stage.toString());
}

/// Marks `func_op` as `stage`. A function is a kernel or a stage, never both.
pub fn setStage(func_op: *ir.Operation, ctx: *ir.Context, stage: Stage) !void {
    std.debug.assert(func_op.getAttr("kernel") == null);
    try func_op.setAttr(stage_attr_key, try getStageAttr(ctx, stage));
}

/// The stage `func_op` runs as, or null for a kernel or a plain function.
pub fn stageOf(func_op: *const ir.Operation) ?Stage {
    const attr = func_op.getAttrAs(ir.Attribute.DialectAttr, stage_attr_key) orelse return null;
    return Stage.fromString(attr.payload);
}

pub fn getSampledTextureType(ctx: *ir.Context) !ir.Type {
    try loadSpec(ctx);
    return ctx.getDialectTypeFromName(tags.type_names.sampled_texture);
}

const StageSet = packed struct {
    vertex: bool = false,
    fragment: bool = false,

    fn has(self: StageSet, stage: Stage) bool {
        return switch (stage) {
            .vertex => self.vertex,
            .fragment => self.fragment,
        };
    }
};

const both: StageSet = .{ .vertex = true, .fragment = true };
const vertex_only: StageSet = .{ .vertex = true };
const fragment_only: StageSet = .{ .fragment = true };

fn stagesFor(op_name: []const u8) ?StageSet {
    const table = .{
        .{ StageInputOp, both },
        .{ StageOutputOp, both },
        .{ SampledTextureOp, both },
        .{ SampleLodOp, both },
        .{ PushConstantOp, both },
        .{ UniformOp, both },
        .{ PositionOp, vertex_only },
        .{ VertexIndexOp, vertex_only },
        .{ InstanceIndexOp, vertex_only },
        .{ FragCoordOp, fragment_only },
        .{ FrontFacingOp, fragment_only },
        .{ SampleOp, fragment_only },
        .{ DpdxOp, fragment_only },
        .{ DpdyOp, fragment_only },
        .{ FwidthOp, fragment_only },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, op_name, entry[0].operation_name)) return entry[1];
    }
    return null;
}

/// Whether a function of `stage` may hold an op named `op_name`, where a null
/// stage is a kernel. Stage ops run only in their stages, and every other gpu
/// op is compute vocabulary. Ops outside the gpu dialect are admitted here and
/// left to each target.
pub fn admits(stage: ?Stage, op_name: []const u8) bool {
    if (stagesFor(op_name)) |stages| {
        const current = stage orelse return false;
        return stages.has(current);
    }
    if (stage == null) return true;
    return !std.mem.startsWith(u8, op_name, names.name ++ ".");
}

/// The refusal every stage backend names when `admitsMemory` fails.
pub const MemoryError = error{UnsupportedStageMemory};

/// Whether a stage function, or a helper a stage calls, may hold `op`. A stage
/// touches only its own arrays: a `memref.alloca` in the local address space
/// with a size known when the module is built, from 1 to 2^32 - 1 elements, and
/// the loads and stores on local memrefs. Every other memref op is refused,
/// since no stage emitter expresses it and a fragment's helper lanes would repeat
/// its effect. An op outside the memref dialect is left to `admits`.
pub fn admitsMemory(op: *ir.Operation) bool {
    const memref = choir.dialects.memref;
    const Memref = memref.MemrefDialect;
    const name = op.name.name;
    if (!std.mem.startsWith(u8, name, Memref.name ++ ".")) return true;
    const target = if (std.mem.eql(u8, name, Memref.AllocaOp.operation_name)) {
        const alloca = Memref.AllocaOp{ .op = op };
        if (alloca.getDynamicSize() != null) return false;
        const params = memref.paramsOf(alloca.getResult().type) orelse return false;
        const size = params.size orelse return false;
        return params.addr_space == .local and size >= 1 and size <= std.math.maxInt(u32);
    } else if (std.mem.eql(u8, name, Memref.LoadOp.operation_name))
        (Memref.LoadOp{ .op = op }).getMemref()
    else if (std.mem.eql(u8, name, Memref.StoreOp.operation_name))
        (Memref.StoreOp{ .op = op }).getMemref()
    else
        return false;
    const params = memref.paramsOf(target.type) orelse return false;
    return params.addr_space == .local;
}

/// The bytes of the push-constant block `module`'s stages read: the end of the
/// farthest member a push-constant read names, or 0 when none reads. A pipeline
/// that draws the module must declare at least this many. Null when a read
/// names no member.
pub fn pushExtent(module: *ir.Operation) ?u32 {
    var extent: u32 = 0;
    if (std.mem.eql(u8, module.name.name, PushConstantOp.operation_name)) {
        const member = (PushConstantOp{ .op = module }).member() orelse return null;
        extent = member.end();
    }
    for (0..module.getNumRegions()) |index| {
        const region = module.getRegion(index) orelse continue;
        var blocks = region.getBlocks();
        while (blocks.next()) |block| {
            var ops = block.getOperations();
            while (ops.next()) |op| extent = @max(extent, pushExtent(op) orelse return null);
        }
    }
    return extent;
}

fn stageEffects(comptime kind: effects.EventKind) ir.interfaces.InterfaceEntry {
    const Declaration = struct {
        fn enumerate(op: *const ir.Operation, collector: *effects.Collector) void {
            collector.append(.{ .event = .{
                .kind = kind,
                .resource = .{ .state_key = "gpu.stage" },
                .ordered = true,
            } });
            collector.append(.{ .requirement = .{
                .kind = .execution_context,
                .subject = .operation,
            } });
            if (kind == .synchronize) collector.append(.{ .event = .{ .kind = .diverge } });
            for (0..op.getNumResults()) |index| {
                collector.append(.{ .result = .{ .index = index } });
            }
        }
    };
    return effects.EffectOpInterface.entryFor(.{
        .capacity = .{ .entries = 3, .per_result = 1 },
        .enumerate = Declaration.enumerate,
    });
}

fn setIndexAttr(op: *ir.Operation, ctx: *ir.Context, key: []const u8, value: u32) !void {
    try op.setAttr(key, try ctx.getI64Attr(@intCast(value)));
}

fn getIndexAttr(op: *const ir.Operation, key: []const u8) ?u32 {
    const int_attr = op.getAttrAs(ir.Attribute.IntegerAttr, key) orelse return null;
    const raw = int_attr.getUnsignedValue();
    if (raw > std.math.maxInt(u32)) return null;
    return @intCast(raw);
}

fn createLeaf(
    ctx: *ir.Context,
    loc: ir.Location,
    comptime name: []const u8,
    operands: []const *ir.Value,
    result_types: []const ir.Type,
) !*ir.Operation {
    try loadSpec(ctx);
    var builder = ir.OperationBuilder.init(ctx);
    var state = ir.Operation.State.init(name, loc);
    state.addOperands(operands);
    state.addTypes(result_types);
    return builder.create(state);
}

/// Reads interface slot `location` as `width` components of one scalar type.
pub const StageInputOp = struct {
    op: *ir.Operation,

    pub const operation_spec = op_specs.leaf(.{
        .mnemonic = "stage_input",
        .interfaces = &.{stageEffects(.state_observe)},
        .operands = 0,
        .results = ir.dialects.shape.between(1, max_components),
        .required_attrs = &.{"location"},
    });
    pub const operation_name = operation_spec.name;

    pub fn create(
        ctx: *ir.Context,
        loc: ir.Location,
        location: u32,
        element_type: ir.Type,
        width: u32,
    ) !StageInputOp {
        std.debug.assert(location < max_locations);
        std.debug.assert(width >= 1);
        std.debug.assert(width <= max_components);
        var types: [max_components]ir.Type = undefined;
        @memset(types[0..width], element_type);
        const op = try createLeaf(ctx, loc, operation_name, &.{}, types[0..width]);
        errdefer op.erase();
        try setIndexAttr(op, ctx, "location", location);
        return .{ .op = op };
    }

    pub fn getLocation(self: StageInputOp) ?u32 {
        return getIndexAttr(self.op, "location");
    }
};

/// Writes `width` components of one scalar type to interface slot `location`.
pub const StageOutputOp = struct {
    op: *ir.Operation,

    pub const operation_spec = op_specs.leaf(.{
        .mnemonic = "stage_output",
        .interfaces = &.{stageEffects(.state_update)},
        .operands = ir.dialects.shape.between(1, max_components),
        .results = 0,
        .required_attrs = &.{"location"},
    });
    pub const operation_name = operation_spec.name;

    pub fn create(
        ctx: *ir.Context,
        loc: ir.Location,
        location: u32,
        values: []const *ir.Value,
    ) !StageOutputOp {
        std.debug.assert(location < max_locations);
        std.debug.assert(values.len >= 1);
        std.debug.assert(values.len <= max_components);
        const op = try createLeaf(ctx, loc, operation_name, values, &.{});
        errdefer op.erase();
        try setIndexAttr(op, ctx, "location", location);
        return .{ .op = op };
    }

    pub fn getLocation(self: StageOutputOp) ?u32 {
        return getIndexAttr(self.op, "location");
    }
};

/// Writes the vertex's clip-space position from four f32 components.
pub const PositionOp = struct {
    op: *ir.Operation,

    pub const operation_spec = op_specs.leaf(.{
        .mnemonic = "position",
        .interfaces = &.{stageEffects(.state_update)},
        .operands = .{ "x", "y", "z", "w" },
        .results = 0,
    });
    pub const operation_name = operation_spec.name;

    pub fn create(ctx: *ir.Context, loc: ir.Location, xyzw: [4]*ir.Value) !PositionOp {
        const op = try createLeaf(ctx, loc, operation_name, &xyzw, &.{});
        return .{ .op = op };
    }
};

/// Reads the fragment's window position, depth and reciprocal clip w as four
/// f32 results.
pub const FragCoordOp = struct {
    op: *ir.Operation,

    pub const operation_spec = op_specs.leaf(.{
        .mnemonic = "frag_coord",
        .interfaces = &.{stageEffects(.state_observe)},
        .operands = 0,
        .results = .{ "x", "y", "z", "w" },
    });
    pub const operation_name = operation_spec.name;

    pub fn create(ctx: *ir.Context, loc: ir.Location) !FragCoordOp {
        const f32_type = try arith.ArithDialect.getScalarType(ctx, .f32);
        const types = [_]ir.Type{ f32_type, f32_type, f32_type, f32_type };
        const op = try createLeaf(ctx, loc, operation_name, &.{}, &types);
        return .{ .op = op };
    }
};

fn builtinOp(comptime mnemonic: []const u8, comptime kind: arith.ScalarKind) type {
    return struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = mnemonic,
            .interfaces = &.{stageEffects(.state_observe)},
            .operands = 0,
            .results = .{"result"},
        });
        pub const operation_name = operation_spec.name;

        pub fn create(ctx: *ir.Context, loc: ir.Location) !@This() {
            const result_type = try arith.ArithDialect.getScalarType(ctx, kind);
            const op = try createLeaf(ctx, loc, operation_name, &.{}, &.{result_type});
            return .{ .op = op };
        }

        pub fn getResult(self: @This()) *ir.Value {
            return self.op.getResult(0).?;
        }
    };
}

/// The vertex's index in the draw, counting from the draw's first vertex.
pub const VertexIndexOp = builtinOp("vertex_index", .u32);
/// The instance's index in the draw, counting from the draw's first instance.
pub const InstanceIndexOp = builtinOp("instance_index", .u32);
/// Whether the fragment's primitive faces the viewer.
pub const FrontFacingOp = builtinOp("front_facing", .bool);

/// Names the sampled texture at `group` and `binding`.
pub const SampledTextureOp = struct {
    op: *ir.Operation,

    pub const operation_spec = op_specs.leaf(.{
        .mnemonic = "sampled_texture",
        .interfaces = &.{stageEffects(.state_observe)},
        .operands = 0,
        .results = .{"texture"},
        .required_attrs = &.{ "group", "binding" },
    });
    pub const operation_name = operation_spec.name;

    pub fn create(ctx: *ir.Context, loc: ir.Location, group: u32, binding: u32) !SampledTextureOp {
        const texture_type = try getSampledTextureType(ctx);
        const op = try createLeaf(ctx, loc, operation_name, &.{}, &.{texture_type});
        errdefer op.erase();
        try setIndexAttr(op, ctx, "group", group);
        try setIndexAttr(op, ctx, "binding", binding);
        return .{ .op = op };
    }

    pub fn getGroup(self: SampledTextureOp) ?u32 {
        return getIndexAttr(self.op, "group");
    }

    pub fn getBinding(self: SampledTextureOp) ?u32 {
        return getIndexAttr(self.op, "binding");
    }

    pub fn getResult(self: SampledTextureOp) *ir.Value {
        return self.op.getResult(0).?;
    }
};

fn sampleOp(
    comptime mnemonic: []const u8,
    comptime kind: effects.EventKind,
    comptime operands: anytype,
) type {
    return struct {
        op: *ir.Operation,

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = mnemonic,
            .interfaces = &.{stageEffects(kind)},
            .operands = operands,
            .results = .{ "r", "g", "b", "a" },
        });
        pub const operation_name = operation_spec.name;

        /// `inputs` is the texture, then u and v, then the level when the op
        /// takes one.
        pub fn create(
            ctx: *ir.Context,
            loc: ir.Location,
            inputs: [operands.len]*ir.Value,
        ) !@This() {
            const f32_type = try arith.ArithDialect.getScalarType(ctx, .f32);
            const types = [_]ir.Type{ f32_type, f32_type, f32_type, f32_type };
            const op = try createLeaf(ctx, loc, operation_name, &inputs, &types);
            return .{ .op = op };
        }

        pub fn getTexture(self: @This()) *ir.Value {
            return self.op.operands.items[0].value;
        }
    };
}

/// Samples a texture at (u, v) with the level its derivatives select.
pub const SampleOp = sampleOp("sample", .synchronize, .{ "texture", "u", "v" });
/// Samples a texture at (u, v) at an explicit level of detail.
pub const SampleLodOp = sampleOp("sample_lod", .state_observe, .{ "texture", "u", "v", "lod" });

fn derivativeOp(comptime mnemonic: []const u8) type {
    return struct {
        op: *ir.Operation,

        pub const VerifyError = error{DerivativeOutsideFragmentStage};

        pub const operation_spec = op_specs.leaf(.{
            .mnemonic = mnemonic,
            .interfaces = &.{stageEffects(.synchronize)},
            .operands = .{"value"},
            .results = .{"result"},
        });
        pub const operation_name = operation_spec.name;

        pub fn verify(op_ptr: *const anyopaque) anyerror!void {
            const op: *const ir.Operation = @ptrCast(@alignCast(op_ptr));
            var parent = op.getParentOp();
            while (parent) |ancestor| : (parent = ancestor.getParentOp()) {
                if (!std.mem.eql(u8, ancestor.name.name, choir.dialects.FuncDialect.FuncOp.operation_name)) continue;
                if (stageOf(ancestor) != .fragment) return VerifyError.DerivativeOutsideFragmentStage;
                return;
            }
            return VerifyError.DerivativeOutsideFragmentStage;
        }

        pub fn create(ctx: *ir.Context, loc: ir.Location, value: *ir.Value) !@This() {
            const op = try createLeaf(ctx, loc, operation_name, &.{value}, &.{value.type});
            return .{ .op = op };
        }

        pub fn getResult(self: @This()) *ir.Value {
            return self.op.getResult(0).?;
        }
    };
}

fn blockReadResults(ctx: *ir.Context, loc: ir.Location, comptime name: []const u8, element_type: ir.Type, width: u32) !*ir.Operation {
    std.debug.assert(width >= 1);
    std.debug.assert(width <= max_components);
    var types: [max_components]ir.Type = undefined;
    @memset(types[0..width], element_type);
    return createLeaf(ctx, loc, name, &.{}, types[0..width]);
}

/// Reads the push-constant member at byte `offset` as `width` components of
/// one scalar type. Every stage of a pipeline reads the one block.
pub const PushConstantOp = struct {
    op: *ir.Operation,

    pub const operation_spec = op_specs.leaf(.{
        .mnemonic = "push_constant",
        .interfaces = &.{stageEffects(.state_observe)},
        .operands = 0,
        .results = ir.dialects.shape.between(1, max_components),
        .required_attrs = &.{"offset"},
    });
    pub const operation_name = operation_spec.name;

    pub fn create(ctx: *ir.Context, loc: ir.Location, offset: u32, element_type: ir.Type, width: u32) !PushConstantOp {
        const op = try blockReadResults(ctx, loc, operation_name, element_type, width);
        errdefer op.erase();
        try setIndexAttr(op, ctx, "offset", offset);
        return .{ .op = op };
    }

    pub fn member(self: PushConstantOp) ?Member {
        const offset = getIndexAttr(self.op, "offset") orelse return null;
        return .{ .offset = offset, .width = @intCast(self.op.getNumResults()) };
    }
};

/// Reads the member at byte `offset` of the uniform buffer at `group` and
/// `binding` as `width` components of one scalar type.
pub const UniformOp = struct {
    op: *ir.Operation,

    pub const operation_spec = op_specs.leaf(.{
        .mnemonic = "uniform",
        .interfaces = &.{stageEffects(.state_observe)},
        .operands = 0,
        .results = ir.dialects.shape.between(1, max_components),
        .required_attrs = &.{ "group", "binding", "offset" },
    });
    pub const operation_name = operation_spec.name;

    pub fn create(
        ctx: *ir.Context,
        loc: ir.Location,
        group: u32,
        binding: u32,
        offset: u32,
        element_type: ir.Type,
        width: u32,
    ) !UniformOp {
        const op = try blockReadResults(ctx, loc, operation_name, element_type, width);
        errdefer op.erase();
        try setIndexAttr(op, ctx, "group", group);
        try setIndexAttr(op, ctx, "binding", binding);
        try setIndexAttr(op, ctx, "offset", offset);
        return .{ .op = op };
    }

    pub fn getGroup(self: UniformOp) ?u32 {
        return getIndexAttr(self.op, "group");
    }

    pub fn getBinding(self: UniformOp) ?u32 {
        return getIndexAttr(self.op, "binding");
    }

    pub fn member(self: UniformOp) ?Member {
        const offset = getIndexAttr(self.op, "offset") orelse return null;
        return .{ .offset = offset, .width = @intCast(self.op.getNumResults()) };
    }
};

/// The fine rate `value` changes along window x: within the fragment's 2x2 quad, `value` at the
/// odd-x fragment of the fragment's own row minus `value` at the even-x fragment. Every backend
/// computes this flavour. SPIR-V emits OpDPdxFine. MSL's `dfdx` names no flavour, and the M4 Max
/// measured fine. The CPU twin recomputes `value` at the partner lane and subtracts in the same
/// order. The quad's four fragments must reach the op together; a derivative under control flow
/// that diverges within a quad is unproven on devices and refused by the CPU twin.
pub const DpdxOp = derivativeOp("dpdx");
/// The fine rate `value` changes along window y: `value` at the odd-y fragment of the fragment's
/// own column minus `value` at the even-y fragment, under the same terms as `DpdxOp`.
pub const DpdyOp = derivativeOp("dpdy");
/// The fine `|dpdx| + |dpdy|`, under the same terms as `DpdxOp`.
pub const FwidthOp = derivativeOp("fwidth");

test "stage admission keeps stage ops in their stages and compute ops in kernels" {
    try std.testing.expect(admits(.vertex, PositionOp.operation_name));
    try std.testing.expect(!admits(.fragment, PositionOp.operation_name));
    try std.testing.expect(!admits(null, PositionOp.operation_name));
    try std.testing.expect(admits(.fragment, SampleOp.operation_name));
    try std.testing.expect(!admits(.vertex, SampleOp.operation_name));
    try std.testing.expect(admits(.vertex, SampleLodOp.operation_name));
    try std.testing.expect(admits(.fragment, StageInputOp.operation_name));
    try std.testing.expect(!admits(.vertex, "gpu.thread_idx"));
    try std.testing.expect(admits(null, "gpu.thread_idx"));
    try std.testing.expect(admits(.fragment, "arith.add"));
}

test "block members follow the std140 rules for scalars and vectors" {
    try std.testing.expect((Member{ .offset = 12, .width = 1 }).placed(16));
    try std.testing.expect((Member{ .offset = 8, .width = 2 }).placed(16));
    try std.testing.expect(!(Member{ .offset = 4, .width = 2 }).placed(16));
    try std.testing.expect((Member{ .offset = 16, .width = 3 }).placed(28));
    try std.testing.expect(!(Member{ .offset = 4, .width = 3 }).placed(64));
    try std.testing.expect(!(Member{ .offset = 16, .width = 4 }).placed(28));
    try std.testing.expect(!(Member{ .offset = 0, .width = 5 }).placed(64));
    try std.testing.expectEqual(@as(u32, 28), (Member{ .offset = 16, .width = 3 }).end());
    try std.testing.expect(admits(.vertex, PushConstantOp.operation_name));
    try std.testing.expect(admits(.fragment, UniformOp.operation_name));
    try std.testing.expect(!admits(null, UniformOp.operation_name));
}

test "stage ops build with their shapes and attributes" {
    var ctx = try ir.Context.init(std.testing.allocator, ir.Context.Limits.testing);
    defer ctx.deinit(std.testing.allocator);
    const f32_type = try arith.ArithDialect.getScalarType(&ctx, .f32);
    const input = try StageInputOp.create(&ctx, .unknown, 3, f32_type, 2);
    defer input.op.erase();
    try std.testing.expectEqual(@as(?u32, 3), input.getLocation());
    try std.testing.expectEqual(@as(usize, 2), input.op.getNumResults());
    const texture = try SampledTextureOp.create(&ctx, .unknown, 1, 4);
    defer texture.op.erase();
    try std.testing.expectEqual(@as(?u32, 1), texture.getGroup());
    try std.testing.expectEqual(@as(?u32, 4), texture.getBinding());
    const coord = try FragCoordOp.create(&ctx, .unknown);
    defer coord.op.erase();
    const u = coord.op.getResult(0).?;
    const sample = try SampleLodOp.create(&ctx, .unknown, .{ texture.getResult(), u, u, u });
    defer sample.op.erase();
    try std.testing.expectEqual(@as(usize, 4), sample.op.getNumResults());
    try ir.verifyOperation(sample.op, .{ .recursive = false });
}
