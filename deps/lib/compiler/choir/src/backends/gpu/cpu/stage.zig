//! Lowers the vertex and fragment functions of a gpu-dialect module to host functions, so a CPU
//! rasterizer runs the same stage code a GPU does. Each stage function `name` becomes a host
//! function `name(inputs, outputs, context)` over the words `gpu_abi.stage` lays out:
//! - an interface read loads its words, and a write stores them;
//! - a builtin loads its word;
//! - a sample stores its coordinates to the sample words, calls `tiny_gpu_sample`, and loads the
//!   texel it left there, because the sampler a texture is read through is chosen when the
//!   texture is bound, after the code exists;
//! - a push-constant or uniform read loads its member's words from the context. A uniform read
//!   outside group 0, at a binding past `uniform_bindings`, or beyond `uniform_window_bytes` is
//!   refused, as is a member the std140 rules of `gpu.stage.Member` do not place;
//! - a uniform element read checks its index against the array's count, and loads its member's
//!   words from element `index` when the index is below it, or from element 0 when it is not, and
//!   then gives zero in place of each word. A read always stays inside the context, and an array
//!   whose last element leaves the window is refused like a member that does.
//!
//! A vertex function also stores, on entry, which smooth and flat words it writes.
//!
//! A fragment function that takes a derivative (`dpdx`, `dpdy`, `fwidth`) reads its quad, as
//! `gpu_abi.stage.quad_suffix` states. It recomputes the derivative's operand at the partner lane
//! along each axis it differentiates: each op the operand depends on is lowered once more per
//! axis over the partner's input block, when a stage input or `frag_coord` reaches it, and shared
//! otherwise, however many derivatives read it. A fine derivative is then the odd lane's value
//! minus the even lane's, chosen by two selects on the lane's parity, so it keeps the sign of zero
//! a device's subtraction gives.
//!
//! The recomputation must not observe or change memory, so a derivative's operand may not depend
//! on a memref op or on a call that passes or returns anything but scalars. A call on scalars is
//! made again with the partner's operands, into the same helper. A derivative inside a region is
//! refused, which keeps the quad's four lanes in step, as is a derivative whose operand depends on
//! another derivative.

const std = @import("std");
const abi = @import("gpu_abi");
const choir = @import("../../../root.zig");
const gpu = @import("../../../dialects/gpu/root.zig");
const calls = @import("../calls.zig");

const ir = choir.ir;
const dialects = choir.dialects;
const ArithDialect = dialects.ArithDialect;
const BuiltinDialect = dialects.BuiltinDialect;
const FuncDialect = dialects.FuncDialect;
const GpuDialect = gpu.GpuDialect;
const MemrefDialect = dialects.MemrefDialect;
const Stage = gpu.Stage;
const layout = abi.stage;

pub const Error = abi.Error || gpu.stage.MemoryError || calls.SignatureError || calls.DepthError;

/// Where a lowering stopped, for a caller that reports why.
pub const Refusal = struct {
    operation: []const u8 = "",
    helper: []const u8 = "",
};

/// Lowers every stage function and its reachable ordinary callees into a host module the caller
/// owns and erases. Kernels and unreachable functions are left out. A refused op names itself.
pub fn lowerStagesToHost(
    allocator: std.mem.Allocator,
    module: *ir.Operation,
    refusal: ?*Refusal,
) Error!*ir.Operation {
    const ctx = module.getContext();
    const host_module = BuiltinDialect.ModuleOp.create(ctx, module.location) catch |err| return loweringError(err);
    errdefer host_module.op.erase();
    const body = ir.inspection.moduleBodyBlock(module) orelse return error.InvalidArtifact;
    var plan_refused: []const u8 = "";
    var call_plan = calls.Plan.init(allocator, module, &plan_refused) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedStageMemory => {
            if (refusal) |why| why.operation = plan_refused;
            return error.UnsupportedStageMemory;
        },
        error.UnsupportedHelperSignature => {
            if (refusal) |why| {
                why.operation = FuncDialect.FuncOp.operation_name;
                why.helper = plan_refused;
            }
            return error.UnsupportedHelperSignature;
        },
        error.CallChainTooDeep => {
            if (refusal) |why| {
                why.operation = FuncDialect.CallOp.operation_name;
                why.helper = plan_refused;
            }
            return error.CallChainTooDeep;
        },
        error.UnsupportedOperation => {
            if (refusal) |why| why.operation = FuncDialect.CallOp.operation_name;
            return error.UnsupportedOperation;
        },
    };
    defer call_plan.deinit();

    var lowerer = Lowerer{
        .allocator = allocator,
        .ctx = ctx,
        .host_body = host_module.getBodyBlock(),
        .refusal = refusal,
        .f32_type = ArithDialect.getScalarType(ctx, .f32) catch |err| return loweringError(err),
        .io_type = undefined,
        .context_type = undefined,
    };
    lowerer.io_type = MemrefDialect.getMemrefTypeDynamic(ctx, lowerer.f32_type, .host) catch |err| return loweringError(err);
    lowerer.context_type = lowerer.io_type;

    for (call_plan.helpers.items) |helper| try lowerer.lowerHelperFunction(FuncDialect.FuncOp{ .op = helper });

    var stages: u32 = 0;
    var ops = body.getOperations();
    while (ops.next()) |op| {
        if (!std.mem.eql(u8, op.name.name, FuncDialect.FuncOp.operation_name)) continue;
        const stage = gpu.stage.stageOf(op) orelse continue;
        try lowerer.lowerFunction(FuncDialect.FuncOp{ .op = op }, stage);
        stages += 1;
    }
    if (stages == 0) return error.InvalidArtifact;
    ir.verifyOperation(host_module.op, ir.verify.default_options) catch return error.CompilationFailed;
    return host_module.op;
}

const Lowerer = struct {
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    host_body: *ir.Block,
    refusal: ?*Refusal,
    f32_type: ir.Type,
    io_type: ir.Type,
    context_type: ir.Type,
    sample_declared: bool = false,
    /// The current function's buffers and context.
    inputs: *ir.Value = undefined,
    outputs: *ir.Value = undefined,
    context: *ir.Value = undefined,
    stage: Stage = .vertex,
    helper_body: bool = false,
    loc: ir.Location = .unknown,
    /// For a quad function, the word of `inputs` its input reads start at: the lane's own block,
    /// or a partner's while an op is lowered again over it.
    base: ?*ir.Value = null,
    /// The axis whose partner the lowering reads, while it lowers an op again.
    partner: ?Axis = null,
    /// Per axis of a quad function: the partner block's first word, whether the lane is odd along
    /// the axis, and each needed value as the partner computes it.
    partners: [2]Partner = undefined,
    /// Ops lowered again for a partner, per axis, across every function.
    partner_ops: [2]u32 = .{ 0, 0 },

    fn lowerFunction(self: *Lowerer, source: FuncDialect.FuncOp, stage: Stage) Error!void {
        if (source.getArguments().len != 0 or source.getNumResults() != 0) return self.refuse(source.op);
        const name = source.getName() orelse return error.InvalidArtifact;
        const body = source.getEntryBlock();
        var needs = Needs.init(self.allocator);
        defer needs.deinit();
        if (stage == .fragment) try needs.collect(body);
        if (needs.axes != 0) return self.lowerQuadFunction(source, name, &needs);

        const host = FuncDialect.FuncOp.create(
            self.ctx,
            source.op.location,
            name,
            &.{ self.io_type, self.io_type, self.context_type },
            &.{},
        ) catch |err| return loweringError(err);
        self.host_body.addOperation(host.op) catch |err| return loweringError(err);
        const arguments = host.getArguments();
        self.inputs = arguments[0];
        self.outputs = arguments[1];
        self.context = arguments[2];
        self.stage = stage;
        self.helper_body = false;
        self.loc = source.op.location;
        self.base = null;

        const entry = host.getEntryBlock();
        if (stage == .vertex) try self.storeMasks(entry, body);
        var mapping = ir.Mapping.init(self.allocator);
        defer mapping.deinit();
        try self.cloneBlock(body, entry, &mapping, true);
    }

    /// Lowers a fragment function that takes derivatives to `name ++ quad_suffix` over its quad.
    /// After each op it needs for an axis, it lowers the op again over that axis's partner block
    /// when the op varies across the quad, and maps it to its own values otherwise.
    fn lowerQuadFunction(self: *Lowerer, source: FuncDialect.FuncOp, name: []const u8, needs: *const Needs) Error!void {
        var name_buffer: [max_symbol_bytes]u8 = undefined;
        const symbol = std.fmt.bufPrint(&name_buffer, "{s}{s}", .{ name, layout.quad_suffix }) catch return self.refuse(source.op);
        const index_type = ArithDialect.getIndexType(self.ctx) catch |err| return loweringError(err);
        const host = FuncDialect.FuncOp.create(
            self.ctx,
            source.op.location,
            symbol,
            &.{ self.io_type, index_type, self.io_type, self.context_type },
            &.{},
        ) catch |err| return loweringError(err);
        self.host_body.addOperation(host.op) catch |err| return loweringError(err);
        const arguments = host.getArguments();
        self.inputs = arguments[0];
        self.outputs = arguments[2];
        self.context = arguments[3];
        self.stage = .fragment;
        self.helper_body = false;
        self.loc = source.op.location;

        const entry = host.getEntryBlock();
        const lane = arguments[1];
        const block_words = try self.indexConstant(entry, layout.io_words);
        self.base = try self.binary(entry, ArithDialect.MulOp, lane, block_words);
        var mappings: [2]ir.Mapping = .{ ir.Mapping.init(self.allocator), ir.Mapping.init(self.allocator) };
        defer for (&mappings) |*partner_mapping| partner_mapping.deinit();
        for (&self.partners, &mappings, [_]Axis{ .x, .y }) |*partner, *partner_mapping, axis| {
            partner.mapping = partner_mapping;
            if (needs.axes & Needs.bit(axis) == 0) continue;
            const bit = try self.indexConstant(entry, Needs.bit(axis));
            const zero = try self.indexConstant(entry, 0);
            const along = try self.binary(entry, ArithDialect.AndOp, lane, bit);
            const odd = ArithDialect.CmpOp.create(self.ctx, self.loc, .ne, along, zero) catch |err| return loweringError(err);
            try add(entry, odd.op);
            partner.odd = odd.getResult();
            const partner_lane = try self.binary(entry, ArithDialect.XorOp, lane, bit);
            partner.base = try self.binary(entry, ArithDialect.MulOp, partner_lane, block_words);
        }

        var mapping = ir.Mapping.init(self.allocator);
        defer mapping.deinit();
        var ops = source.getEntryBlock().getOperations();
        while (ops.next()) |op| {
            try self.lowerOperation(op, entry, &mapping, true);
            const axes = needs.of(op);
            for ([_]Axis{ .x, .y }) |axis| {
                if (axes & Needs.bit(axis) != 0) try self.lowerForPartner(op, entry, &mapping, axis);
            }
        }
    }

    /// Maps `op`'s results in the partner mapping of `axis`: lowered again over the partner's
    /// block when a stage input or `frag_coord` reaches it, or its own lowering otherwise.
    fn lowerForPartner(self: *Lowerer, op: *ir.Operation, dest: *ir.Block, mapping: *ir.Mapping, axis: Axis) Error!void {
        const partner = &self.partners[@backingInt(axis)];
        if (isDerivative(op.name.name) or touchesMemory(op)) return self.refuse(op);
        if (!self.varies(op, mapping, partner.mapping)) {
            for (0..op.getNumResults()) |index| {
                const result = op.getResult(index) orelse return error.InvalidArtifact;
                try mapValue(partner.mapping, result, mapping.lookupValue(result) orelse return error.InvalidArtifact);
            }
            return;
        }
        const own_base = self.base;
        self.base = partner.base;
        self.partner = axis;
        defer {
            self.base = own_base;
            self.partner = null;
        }
        try self.lowerOperation(op, dest, partner.mapping, false);
        self.partner_ops[@backingInt(axis)] += 1;
    }

    /// Whether `op` computes a different value at a partner lane: it reads a stage input or
    /// `frag_coord`, holds regions, or takes an operand the partner computes differently.
    fn varies(self: *Lowerer, op: *ir.Operation, mapping: *ir.Mapping, partner_mapping: *ir.Mapping) bool {
        _ = self;
        const name = op.name.name;
        if (std.mem.eql(u8, name, GpuDialect.StageInputOp.operation_name)) return true;
        if (std.mem.eql(u8, name, GpuDialect.FragCoordOp.operation_name)) return true;
        if (op.regions.items.len != 0) return true;
        for (op.operand_values) |operand| {
            if (partner_mapping.lookupValue(operand) != mapping.lookupValue(operand)) return true;
        }
        return false;
    }

    fn lowerDerivative(self: *Lowerer, op: *ir.Operation, dest: *ir.Block, mapping: *ir.Mapping) Error!void {
        const value = op.operand_values[0];
        const name = op.name.name;
        const result = if (std.mem.eql(u8, name, GpuDialect.DpdxOp.operation_name))
            try self.difference(dest, mapping, value, .x)
        else if (std.mem.eql(u8, name, GpuDialect.DpdyOp.operation_name))
            try self.difference(dest, mapping, value, .y)
        else blk: {
            const along_x = try self.unary(dest, ArithDialect.AbsOp, try self.difference(dest, mapping, value, .x));
            const along_y = try self.unary(dest, ArithDialect.AbsOp, try self.difference(dest, mapping, value, .y));
            break :blk try self.binary(dest, ArithDialect.AddOp, along_x, along_y);
        };
        try mapValue(mapping, op.getResult(0) orelse return error.InvalidArtifact, result);
    }

    /// The fine derivative of `value` along `axis`: the odd lane's value minus the even lane's.
    fn difference(self: *Lowerer, dest: *ir.Block, mapping: *ir.Mapping, value: *ir.Value, axis: Axis) Error!*ir.Value {
        const partner = &self.partners[@backingInt(axis)];
        const own = mapping.lookupValue(value) orelse return error.InvalidArtifact;
        const theirs = partner.mapping.lookupValue(value) orelse return error.InvalidArtifact;
        const odd = try self.select(dest, partner.odd, own, theirs);
        const even = try self.select(dest, partner.odd, theirs, own);
        return self.binary(dest, ArithDialect.SubOp, odd, even);
    }

    fn select(self: *Lowerer, dest: *ir.Block, condition: *ir.Value, if_true: *ir.Value, if_false: *ir.Value) Error!*ir.Value {
        const op = ArithDialect.SelectOp.create(self.ctx, self.loc, condition, if_true, if_false) catch |err| return loweringError(err);
        try add(dest, op.op);
        return op.getResult();
    }

    fn binary(self: *Lowerer, dest: *ir.Block, comptime Op: type, lhs: *ir.Value, rhs: *ir.Value) Error!*ir.Value {
        const op = Op.create(self.ctx, self.loc, lhs, rhs) catch |err| return loweringError(err);
        try add(dest, op.op);
        return op.getResult();
    }

    fn unary(self: *Lowerer, dest: *ir.Block, comptime Op: type, operand: *ir.Value) Error!*ir.Value {
        const op = Op.create(self.ctx, self.loc, operand) catch |err| return loweringError(err);
        try add(dest, op.op);
        return op.getResult();
    }

    fn lowerHelperFunction(self: *Lowerer, source: FuncDialect.FuncOp) Error!void {
        const name = source.getName() orelse return error.InvalidArtifact;
        const source_args = source.getArguments();
        const inputs = self.allocator.alloc(ir.Type, source_args.len) catch return error.OutOfMemory;
        defer self.allocator.free(inputs);
        for (source_args, inputs) |arg, *input| {
            input.* = if (std.mem.eql(u8, arg.type.getDialectTypeName() orelse "", MemrefDialect.name))
                try self.hostMemrefType(arg.type)
            else
                arg.type;
        }
        const host = FuncDialect.FuncOp.create(
            self.ctx,
            source.op.location,
            name,
            inputs,
            source.getResultTypes(),
        ) catch |err| return loweringError(err);
        self.host_body.addOperation(host.op) catch |err| return loweringError(err);
        self.helper_body = true;
        self.base = null;
        self.loc = source.op.location;
        var mapping = ir.Mapping.init(self.allocator);
        defer mapping.deinit();
        for (source.getArguments(), host.getArguments()) |arg, mapped| try mapValue(&mapping, arg, mapped);
        try self.cloneBlock(source.getEntryBlock(), host.getEntryBlock(), &mapping, true);
    }

    fn hostMemrefType(self: *Lowerer, source_type: ir.Type) Error!ir.Type {
        const params = MemrefDialect.parseMemrefParams(source_type.getDialectParamKey() orelse return error.InvalidArtifact) orelse return error.InvalidArtifact;
        if (params.addr_space != .local) return error.UnsupportedOperation;
        const size = params.size orelse return error.UnsupportedOperation;
        if (size == 0) return error.UnsupportedOperation;
        const elem = self.ctx.getDialectTypeFromName(params.element_type_name) catch return error.UnsupportedOperation;
        return MemrefDialect.getMemrefType1DWithAttrs(self.ctx, size, elem, .host, .{
            .alignment = params.alignment,
            .exclusive = params.exclusive,
            .indexing = params.indexing,
        }) catch |err| return loweringError(err);
    }

    /// Stores the masks of smooth and flat words the function's interface writes reach.
    fn storeMasks(self: *Lowerer, dest: *ir.Block, source: *ir.Block) Error!void {
        var masks = Masks{};
        try masks.collect(source);
        try self.storeBits(dest, @truncate(masks.smooth), layout.smooth_mask_low);
        try self.storeBits(dest, @truncate(masks.smooth >> 32), layout.smooth_mask_high);
        try self.storeBits(dest, @truncate(masks.flat), layout.flat_mask_low);
        try self.storeBits(dest, @truncate(masks.flat >> 32), layout.flat_mask_high);
    }

    fn storeBits(self: *Lowerer, dest: *ir.Block, bits: u32, word: u32) Error!void {
        const u32_type = ArithDialect.getScalarType(self.ctx, .u32) catch |err| return loweringError(err);
        const constant = ArithDialect.ConstantOp.createInt(self.ctx, self.loc, u32_type, bits) catch |err| return loweringError(err);
        try add(dest, constant.op);
        try self.storeWord(dest, constant.getResult(), self.outputs, word);
    }

    fn cloneBlock(self: *Lowerer, source: *ir.Block, dest: *ir.Block, mapping: *ir.Mapping, function_body: bool) Error!void {
        var ops = source.getOperations();
        while (ops.next()) |op| try self.lowerOperation(op, dest, mapping, function_body);
    }

    fn lowerOperation(self: *Lowerer, op: *ir.Operation, dest: *ir.Block, mapping: *ir.Mapping, function_body: bool) Error!void {
        const name = op.name.name;
        if (self.partner != null and touchesMemory(op)) return self.refuse(op);
        if (isDerivative(name)) {
            if (!function_body or self.partner != null or self.base == null) return self.refuse(op);
            try self.lowerDerivative(op, dest, mapping);
        } else if (std.mem.eql(u8, name, FuncDialect.ReturnOp.operation_name)) {
            if (!function_body or (!self.helper_body and op.operand_values.len != 0)) return self.refuse(op);
            const operands = self.allocator.alloc(*ir.Value, op.operand_values.len) catch return error.OutOfMemory;
            defer self.allocator.free(operands);
            for (op.operand_values, operands) |operand, *mapped| mapped.* = mapping.lookupOrDefaultValue(operand);
            const ret = FuncDialect.ReturnOp.create(self.ctx, op.location, operands) catch |err| return loweringError(err);
            try add(dest, ret.op);
        } else if (std.mem.eql(u8, name, GpuDialect.StageInputOp.operation_name)) {
            try self.lowerInput(op, dest, mapping);
        } else if (std.mem.eql(u8, name, GpuDialect.StageOutputOp.operation_name)) {
            try self.lowerOutput(op, dest, mapping);
        } else if (std.mem.eql(u8, name, GpuDialect.PositionOp.operation_name)) {
            for (op.operand_values, 0..) |operand, component| {
                try self.storeWord(dest, mapping.lookupOrDefaultValue(operand), self.outputs, layout.position + @as(u32, @intCast(component)));
            }
        } else if (std.mem.eql(u8, name, GpuDialect.FragCoordOp.operation_name)) {
            for (0..4) |component| {
                const result = op.getResult(component) orelse return error.InvalidArtifact;
                const value = try self.loadInput(dest, layout.frag_coord + @as(u32, @intCast(component)), result.type);
                try mapValue(mapping, result, value);
            }
        } else if (std.mem.eql(u8, name, GpuDialect.VertexIndexOp.operation_name)) {
            try self.lowerBuiltin(op, dest, mapping, layout.vertex_index);
        } else if (std.mem.eql(u8, name, GpuDialect.InstanceIndexOp.operation_name)) {
            try self.lowerBuiltin(op, dest, mapping, layout.instance_index);
        } else if (std.mem.eql(u8, name, GpuDialect.FrontFacingOp.operation_name)) {
            try self.lowerFrontFacing(op, dest, mapping);
        } else if (std.mem.eql(u8, name, GpuDialect.SampledTextureOp.operation_name)) {
            try self.lowerTexture(op, dest, mapping);
        } else if (std.mem.eql(u8, name, MemrefDialect.AllocaOp.operation_name)) {
            const source_alloca = MemrefDialect.AllocaOp{ .op = op };
            if (source_alloca.getDynamicSize() != null) return self.refuse(op);
            const host_type = try self.hostMemrefType(source_alloca.getResult().type);
            const host_alloca = MemrefDialect.AllocaOp.createStatic(self.ctx, op.location, host_type) catch |err| return loweringError(err);
            try add(dest, host_alloca.op);
            try mapValue(mapping, source_alloca.getResult(), host_alloca.getResult());
        } else if (std.mem.eql(u8, name, GpuDialect.PushConstantOp.operation_name)) {
            const member = (GpuDialect.PushConstantOp{ .op = op }).member() orelse return error.InvalidArtifact;
            if (!member.placed(layout.push_words * 4)) return self.refuse(op);
            try self.lowerBlockRead(op, dest, mapping, layout.push + member.offset / 4);
        } else if (std.mem.eql(u8, name, GpuDialect.UniformOp.operation_name)) {
            const uniform = GpuDialect.UniformOp{ .op = op };
            const member = uniform.member() orelse return error.InvalidArtifact;
            const group = uniform.getGroup() orelse return error.InvalidArtifact;
            const binding = uniform.getBinding() orelse return error.InvalidArtifact;
            if (group != 0 or binding >= layout.uniform_bindings) return self.refuse(op);
            if (!member.placed(layout.uniform_window_bytes)) return self.refuse(op);
            try self.lowerBlockRead(op, dest, mapping, layout.uniformWord(binding, member.offset));
        } else if (std.mem.eql(u8, name, GpuDialect.UniformElementOp.operation_name)) {
            const uniform = GpuDialect.UniformElementOp{ .op = op };
            const elements = uniform.elements() orelse return error.InvalidArtifact;
            const group = uniform.getGroup() orelse return error.InvalidArtifact;
            const binding = uniform.getBinding() orelse return error.InvalidArtifact;
            if (group != 0 or binding >= layout.uniform_bindings) return self.refuse(op);
            if (!elements.placed(layout.uniform_window_bytes)) return self.refuse(op);
            try self.lowerElementRead(uniform, dest, mapping, layout.uniformWord(binding, elements.member.offset), elements);
        } else if (std.mem.eql(u8, name, GpuDialect.SampleOp.operation_name) or
            std.mem.eql(u8, name, GpuDialect.SampleLodOp.operation_name))
        {
            try self.lowerSample(op, dest, mapping);
        } else if (std.mem.eql(u8, op.name.getDialectNamespace(), GpuDialect.name) or op.successors.items.len != 0) {
            return self.refuse(op);
        } else {
            try self.cloneOperation(op, dest, mapping);
        }
    }

    fn cloneOperation(self: *Lowerer, op: *ir.Operation, dest: *ir.Block, mapping: *ir.Mapping) Error!void {
        const has_regions = op.regions.items.len != 0;
        const cloned = op.cloneWithoutRegionsMapped(mapping, .{ .clone_operands = !has_regions }) catch |err| return loweringError(err);
        errdefer cloned.erase();
        try add(dest, cloned);
        for (op.regions.items, 0..) |*source_region, region_index| {
            const dest_region = &cloned.regions.items[region_index];
            var source_block = source_region.blocks.head;
            while (source_block) |block| : (source_block = block.next) {
                const cloned_block = dest_region.addBlock() catch |err| return loweringError(err);
                mapping.mapBlock(block, cloned_block) catch return error.OutOfMemory;
                for (block.arguments.items) |argument| {
                    const cloned_argument = cloned_block.addArgument(argument.type, .unknown) catch |err| return loweringError(err);
                    try mapValue(mapping, argument, cloned_argument);
                }
            }
            source_block = source_region.blocks.head;
            while (source_block) |block| : (source_block = block.next) {
                const cloned_block = mapping.lookupBlock(block) orelse return error.InvalidArtifact;
                try self.cloneBlock(block, cloned_block, mapping, false);
            }
        }
        if (has_regions) {
            var operands: [max_region_operands]*ir.Value = undefined;
            if (op.operand_values.len > operands.len) return self.refuse(op);
            for (op.operand_values, operands[0..op.operand_values.len]) |operand, *mapped| {
                mapped.* = mapping.lookupOrDefaultValue(operand);
            }
            cloned.replaceOperands(operands[0..op.operand_values.len]) catch |err| return loweringError(err);
        }
    }

    fn lowerInput(self: *Lowerer, op: *ir.Operation, dest: *ir.Block, mapping: *ir.Mapping) Error!void {
        const location = (GpuDialect.StageInputOp{ .op = op }).getLocation() orelse return error.InvalidArtifact;
        for (0..op.getNumResults()) |component| {
            const result = op.getResult(component) orelse return error.InvalidArtifact;
            const region = switch (self.stage) {
                .vertex => layout.smooth,
                .fragment => try self.regionOf(op, result.type),
            };
            const word = layout.slot(region, location, @intCast(component));
            try mapValue(mapping, result, try self.loadInput(dest, word, result.type));
        }
    }

    fn lowerOutput(self: *Lowerer, op: *ir.Operation, dest: *ir.Block, mapping: *ir.Mapping) Error!void {
        const location = (GpuDialect.StageOutputOp{ .op = op }).getLocation() orelse return error.InvalidArtifact;
        for (op.operand_values, 0..) |operand, component| {
            const region = switch (self.stage) {
                .vertex => try self.regionOf(op, operand.type),
                .fragment => layout.smooth,
            };
            const word = layout.slot(region, location, @intCast(component));
            try self.storeWord(dest, mapping.lookupOrDefaultValue(operand), self.outputs, word);
        }
    }

    /// Loads each result of a block read from consecutive context words from `first` on. Every
    /// result must share one 4-byte scalar type.
    fn lowerBlockRead(self: *Lowerer, op: *ir.Operation, dest: *ir.Block, mapping: *ir.Mapping, first: u32) Error!void {
        const kind = scalarKind(op.getResult(0).?.type) orelse return self.refuse(op);
        switch (kind) {
            .f32, .u32, .i32 => {},
            else => return self.refuse(op),
        }
        for (0..op.getNumResults()) |component| {
            const result = op.getResult(component) orelse return error.InvalidArtifact;
            if (scalarKind(result.type) != kind) return self.refuse(op);
            const word = first + @as(u32, @intCast(component));
            std.debug.assert(word < layout.context_words);
            try mapValue(mapping, result, try self.loadFrom(dest, self.context, word, result.type));
        }
    }

    /// Loads each word of the member of element `index` from the words that start at `first`, the
    /// member's in element 0, `elements.stride` bytes apart. An index at or past the count loads
    /// element 0 and gives zero.
    fn lowerElementRead(
        self: *Lowerer,
        uniform: GpuDialect.UniformElementOp,
        dest: *ir.Block,
        mapping: *ir.Mapping,
        first: u32,
        elements: gpu.stage.Elements,
    ) Error!void {
        const op = uniform.op;
        const kind = scalarKind(op.getResult(0).?.type) orelse return self.refuse(op);
        switch (kind) {
            .f32, .u32, .i32 => {},
            else => return self.refuse(op),
        }
        const index = mapping.lookupOrDefaultValue(uniform.getIndex());
        if (scalarKind(index.type) != .u32) return self.refuse(op);
        std.debug.assert(elements.stride % 4 == 0);
        const u32_type = index.type;
        const count = ArithDialect.ConstantOp.createInt(self.ctx, self.loc, u32_type, elements.count) catch |err| return loweringError(err);
        try add(dest, count.op);
        const inside = ArithDialect.CmpOp.create(self.ctx, self.loc, .ult, index, count.getResult()) catch |err| return loweringError(err);
        try add(dest, inside.op);
        const zero_index = ArithDialect.ConstantOp.createInt(self.ctx, self.loc, u32_type, 0) catch |err| return loweringError(err);
        try add(dest, zero_index.op);
        const element = try self.select(dest, inside.getResult(), index, zero_index.getResult());
        const index_type = ArithDialect.getIndexType(self.ctx) catch |err| return loweringError(err);
        const widened = ArithDialect.CastOp.create(self.ctx, self.loc, element, index_type) catch |err| return loweringError(err);
        try add(dest, widened.op);
        const scaled = try self.binary(dest, ArithDialect.MulOp, widened.getResult(), try self.indexConstant(dest, elements.stride / 4));
        for (0..op.getNumResults()) |component| {
            const result = op.getResult(component) orelse return error.InvalidArtifact;
            if (scalarKind(result.type) != kind) return self.refuse(op);
            const word = first + @as(u32, @intCast(component));
            std.debug.assert(word < layout.context_words);
            const at = try self.binary(dest, ArithDialect.AddOp, scaled, try self.indexConstant(dest, word));
            const loaded = try self.loadAt(dest, self.context, at, result.type);
            const zero = if (kind == .f32)
                ArithDialect.ConstantOp.createFloat(self.ctx, self.loc, result.type, 0) catch |err| return loweringError(err)
            else
                ArithDialect.ConstantOp.createInt(self.ctx, self.loc, result.type, 0) catch |err| return loweringError(err);
            try add(dest, zero.op);
            try mapValue(mapping, result, try self.select(dest, inside.getResult(), loaded, zero.getResult()));
        }
    }

    fn lowerBuiltin(self: *Lowerer, op: *ir.Operation, dest: *ir.Block, mapping: *ir.Mapping, word: u32) Error!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        try mapValue(mapping, result, try self.loadInput(dest, word, result.type));
    }

    fn lowerFrontFacing(self: *Lowerer, op: *ir.Operation, dest: *ir.Block, mapping: *ir.Mapping) Error!void {
        const result = op.getResult(0) orelse return error.InvalidArtifact;
        const u32_type = ArithDialect.getScalarType(self.ctx, .u32) catch |err| return loweringError(err);
        const bits = try self.loadInput(dest, layout.front_facing, u32_type);
        const zero = ArithDialect.ConstantOp.createInt(self.ctx, op.location, u32_type, 0) catch |err| return loweringError(err);
        try add(dest, zero.op);
        const facing = ArithDialect.CmpOp.create(self.ctx, op.location, .ne, bits, zero.getResult()) catch |err| return loweringError(err);
        try add(dest, facing.op);
        try mapValue(mapping, result, facing.getResult());
    }

    /// A texture becomes the key a sample passes, since the host resolves the binding.
    fn lowerTexture(self: *Lowerer, op: *ir.Operation, dest: *ir.Block, mapping: *ir.Mapping) Error!void {
        const texture = GpuDialect.SampledTextureOp{ .op = op };
        const group = texture.getGroup() orelse return error.InvalidArtifact;
        const binding = texture.getBinding() orelse return error.InvalidArtifact;
        if (group > 0xff or binding > 0xffff) return self.refuse(op);
        const i32_type = ArithDialect.getScalarType(self.ctx, .i32) catch |err| return loweringError(err);
        const key = ArithDialect.ConstantOp.createInt(self.ctx, op.location, i32_type, layout.textureKey(group, binding)) catch |err| return loweringError(err);
        try add(dest, key.op);
        try mapValue(mapping, texture.getResult(), key.getResult());
    }

    fn lowerSample(self: *Lowerer, op: *ir.Operation, dest: *ir.Block, mapping: *ir.Mapping) Error!void {
        const operands = op.operand_values;
        if (operands.len != 3 and operands.len != 4) return error.InvalidArtifact;
        const key = mapping.lookupValue(operands[0]) orelse return self.refuse(op);
        try self.storeWord(dest, mapping.lookupOrDefaultValue(operands[1]), self.outputs, layout.sample);
        try self.storeWord(dest, mapping.lookupOrDefaultValue(operands[2]), self.outputs, layout.sample + 1);
        const lod = if (operands.len == 4) mapping.lookupOrDefaultValue(operands[3]) else blk: {
            const zero = ArithDialect.ConstantOp.createFloat(self.ctx, op.location, self.f32_type, 0) catch |err| return loweringError(err);
            try add(dest, zero.op);
            break :blk zero.getResult();
        };
        try self.storeWord(dest, lod, self.outputs, layout.sample + 2);
        try self.declareSample(key.type);
        const call = FuncDialect.CallOp.create(self.ctx, op.location, layout.sample_symbol, &.{ self.context, key, self.outputs }, &.{}) catch |err| return loweringError(err);
        try add(dest, call.op);
        for (0..4) |component| {
            const result = op.getResult(component) orelse return error.InvalidArtifact;
            try mapValue(mapping, result, try self.loadWord(dest, self.outputs, layout.sample + @as(u32, @intCast(component)), result.type));
        }
    }

    fn declareSample(self: *Lowerer, key_type: ir.Type) Error!void {
        if (self.sample_declared) return;
        const declaration = FuncDialect.FuncOp.createDeclaration(
            self.ctx,
            self.loc,
            layout.sample_symbol,
            &.{ self.context_type, key_type, self.io_type },
            &.{},
        ) catch |err| return loweringError(err);
        try add(self.host_body, declaration.op);
        self.sample_declared = true;
    }

    /// The region an interface value travels in between the stages: smooth for a float, flat for
    /// an integer.
    fn regionOf(self: *Lowerer, op: *ir.Operation, typ: ir.Type) Error!u32 {
        return switch (scalarKind(typ) orelse return self.refuse(op)) {
            .f32 => layout.smooth,
            .u32, .i32 => layout.flat,
            else => self.refuse(op),
        };
    }

    fn loadWord(self: *Lowerer, dest: *ir.Block, buffer: *ir.Value, word: u32, result_type: ir.Type) Error!*ir.Value {
        std.debug.assert(word < layout.io_words);
        return self.loadFrom(dest, buffer, word, result_type);
    }

    /// Loads `word` of the input block the lowering reads: the only one, or a lane's of a quad.
    fn loadInput(self: *Lowerer, dest: *ir.Block, word: u32, result_type: ir.Type) Error!*ir.Value {
        std.debug.assert(word < layout.io_words);
        const base = self.base orelse return self.loadFrom(dest, self.inputs, word, result_type);
        const index = try self.binary(dest, ArithDialect.AddOp, base, try self.indexConstant(dest, word));
        return self.loadAt(dest, self.inputs, index, result_type);
    }

    /// Loads `word` of `buffer` as `result_type`, bitcasting a word that holds an integer.
    fn loadFrom(self: *Lowerer, dest: *ir.Block, buffer: *ir.Value, word: u32, result_type: ir.Type) Error!*ir.Value {
        return self.loadAt(dest, buffer, try self.indexConstant(dest, word), result_type);
    }

    fn loadAt(self: *Lowerer, dest: *ir.Block, buffer: *ir.Value, index: *ir.Value, result_type: ir.Type) Error!*ir.Value {
        const load = MemrefDialect.LoadOp.create(self.ctx, self.loc, buffer, index, self.f32_type) catch |err| return loweringError(err);
        try add(dest, load.op);
        const loaded = load.op.getResult(0) orelse return error.CompilationFailed;
        if (scalarKind(result_type) == .f32) return loaded;
        const cast = ArithDialect.BitcastOp.create(self.ctx, self.loc, loaded, result_type) catch |err| return loweringError(err);
        try add(dest, cast.op);
        return cast.getResult();
    }

    fn storeWord(self: *Lowerer, dest: *ir.Block, value: *ir.Value, buffer: *ir.Value, word: u32) Error!void {
        std.debug.assert(word < layout.io_words);
        const stored = switch (scalarKind(value.type) orelse return error.UnsupportedOperation) {
            .f32 => value,
            .u32, .i32 => blk: {
                const cast = ArithDialect.BitcastOp.create(self.ctx, self.loc, value, self.f32_type) catch |err| return loweringError(err);
                try add(dest, cast.op);
                break :blk cast.getResult();
            },
            else => return error.UnsupportedOperation,
        };
        const index = try self.indexConstant(dest, word);
        const store = MemrefDialect.StoreOp.create(self.ctx, self.loc, stored, buffer, index) catch |err| return loweringError(err);
        try add(dest, store.op);
    }

    fn indexConstant(self: *Lowerer, dest: *ir.Block, value: u32) Error!*ir.Value {
        const index_type = ArithDialect.getIndexType(self.ctx) catch |err| return loweringError(err);
        const constant = ArithDialect.ConstantOp.createInt(self.ctx, self.loc, index_type, value) catch |err| return loweringError(err);
        try add(dest, constant.op);
        return constant.getResult();
    }

    fn refuse(self: *Lowerer, op: *ir.Operation) Error {
        if (self.refusal) |refusal| refusal.operation = op.name.name;
        return error.UnsupportedOperation;
    }
};

/// Operands an op with regions may carry, such as the condition of an `scf.if`.
const max_region_operands = 16;
/// Bytes a quad function's symbol may take.
const max_symbol_bytes = 256;

const Axis = enum(u1) { x, y };

const Partner = struct {
    base: *ir.Value = undefined,
    odd: *ir.Value = undefined,
    mapping: *ir.Mapping = undefined,
};

/// Whether `op` may read or write memory whose contents its operands do not carry: a memref op,
/// or a call that passes or returns anything but scalars. `calls.Plan` admits a helper only when it
/// reads no stage state and touches only its own local arrays, which live for one call, so a
/// partner may call one again on its own scalars.
fn touchesMemory(op: *ir.Operation) bool {
    if (std.mem.eql(u8, op.name.getDialectNamespace(), MemrefDialect.name)) return true;
    if (!std.mem.eql(u8, op.name.name, FuncDialect.CallOp.operation_name)) return false;
    for (op.operand_values) |operand| {
        if (scalarKind(operand.type) == null) return true;
    }
    for (0..op.getNumResults()) |index| {
        const result = op.getResult(index) orelse return true;
        if (scalarKind(result.type) == null) return true;
    }
    return false;
}

fn isDerivative(name: []const u8) bool {
    return std.mem.eql(u8, name, GpuDialect.DpdxOp.operation_name) or
        std.mem.eql(u8, name, GpuDialect.DpdyOp.operation_name) or
        std.mem.eql(u8, name, GpuDialect.FwidthOp.operation_name);
}

/// The axes along which some derivative of a fragment body reads each op of the body's block:
/// the op computes the derivative's operand, or a value that operand depends on.
const Needs = struct {
    allocator: std.mem.Allocator,
    axes_of: std.AutoHashMapUnmanaged(*ir.Operation, u2) = .empty,
    /// Every axis some derivative takes.
    axes: u2 = 0,

    fn init(allocator: std.mem.Allocator) Needs {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Needs) void {
        self.axes_of.deinit(self.allocator);
    }

    fn bit(axis: Axis) u2 {
        return @as(u2, 1) << @backingInt(axis);
    }

    fn of(self: *const Needs, op: *ir.Operation) u2 {
        return self.axes_of.get(op) orelse 0;
    }

    /// Walks `block` from its last op to its first, so an op's marks are complete before it
    /// passes them to the ops it reads. Only derivatives in `block` itself seed marks; one in a
    /// region is refused when it is lowered.
    fn collect(self: *Needs, block: *ir.Block) Error!void {
        var cursor = block.operations.tail;
        while (cursor) |pointer| {
            const op: *ir.Operation = @ptrCast(@alignCast(pointer));
            cursor = op.prev_op;
            const name = op.name.name;
            const seed: u2 = if (std.mem.eql(u8, name, GpuDialect.DpdxOp.operation_name))
                bit(.x)
            else if (std.mem.eql(u8, name, GpuDialect.DpdyOp.operation_name))
                bit(.y)
            else if (std.mem.eql(u8, name, GpuDialect.FwidthOp.operation_name))
                bit(.x) | bit(.y)
            else
                0;
            self.axes |= seed;
            const axes = self.of(op) | seed;
            if (axes == 0) continue;
            for (op.operand_values) |operand| try self.mark(operand, block, axes);
            if (op.regions.items.len == 0) continue;
            var reads = Reads{ .needs = self, .block = block, .axes = axes };
            _ = op.walk(.{ .order = .pre_order }, &reads, Reads.visit) catch |err| return loweringError(err);
        }
    }

    /// Marks the op of `block` that defines `value`, if any, with `axes`.
    fn mark(self: *Needs, value: *ir.Value, block: *ir.Block, axes: u2) Error!void {
        const pointer = value.getDefiningOp() orelse return;
        const op: *ir.Operation = @ptrCast(@alignCast(pointer));
        if (op.parent_block != block) return;
        const entry = self.axes_of.getOrPut(self.allocator, op) catch return error.OutOfMemory;
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* |= axes;
    }

    /// Marks the values of the outer block that ops inside a region read.
    const Reads = struct {
        needs: *Needs,
        block: *ir.Block,
        axes: u2,

        fn visit(reads: *Reads, op: *ir.Operation) !ir.Operation.WalkResult {
            for (op.operand_values) |operand| try reads.needs.mark(operand, reads.block, reads.axes);
            return .advance;
        }
    };
};

/// The smooth and flat words a vertex function's outputs reach, one bit per word.
const Masks = struct {
    smooth: u64 = 0,
    flat: u64 = 0,

    fn collect(self: *Masks, block: *ir.Block) Error!void {
        var ops = block.getOperations();
        while (ops.next()) |op| {
            if (std.mem.eql(u8, op.name.name, GpuDialect.StageOutputOp.operation_name)) {
                const location = (GpuDialect.StageOutputOp{ .op = op }).getLocation() orelse return error.InvalidArtifact;
                for (op.operand_values, 0..) |operand, component| {
                    const bit = @as(u64, 1) << @intCast(location * layout.location_components + component);
                    switch (scalarKind(operand.type) orelse return error.UnsupportedOperation) {
                        .f32 => self.smooth |= bit,
                        .u32, .i32 => self.flat |= bit,
                        else => return error.UnsupportedOperation,
                    }
                }
            }
            for (op.regions.items) |*region| {
                var nested = region.blocks.head;
                while (nested) |inner| : (nested = inner.next) try self.collect(inner);
            }
        }
    }
};

fn scalarKind(typ: ir.Type) ?dialects.arith.ScalarKind {
    const type_name = typ.getDialectTypeName() orelse return null;
    return dialects.arith.scalarKindFromTypeName(type_name);
}

fn mapValue(mapping: *ir.Mapping, from: *ir.Value, to: *ir.Value) Error!void {
    mapping.mapValue(from, to) catch return error.OutOfMemory;
}

fn add(block: *ir.Block, op: *ir.Operation) Error!void {
    block.addOperation(op) catch |err| return loweringError(err);
}

fn loweringError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CompilationFailed,
    };
}
