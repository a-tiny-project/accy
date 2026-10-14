const std = @import("std");
const gpu = @import("gpu");
const choir = @import("choir");
const accy_choir = @import("../choir/root.zig");
const artifact_product = @import("../artifact/root.zig");
const preparation = @import("../preparation/root.zig");
const binding_mod = @import("binding.zig");

const ir = choir.ir;
const passes = choir.passes;
const semantic = accy_choir.semantic;

pub const OwnedSemanticChoirModule = struct {
    module: *semantic.SemanticModule,
    choir_module: *ir.Operation,
    ctx: *ir.Context,

    pub fn init(module: *semantic.SemanticModule) OwnedSemanticChoirModule {
        return .{
            .module = module,
            .choir_module = module.choir_module,
            .ctx = module.context(),
        };
    }

    pub fn deinit(self: *OwnedSemanticChoirModule) void {
        self.module.deinit();
        self.* = undefined;
    }
};

pub fn addChoirModule(allocator: std.mem.Allocator, name: []const u8) !OwnedSemanticChoirModule {
    return OwnedSemanticChoirModule.init(try addSemanticModule(allocator, name));
}

pub fn addU32ChoirModule(allocator: std.mem.Allocator, name: []const u8) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const u32_8 = try builder.tensor(.u32, &.{8});
    var fb = try builder.beginFunction(name, &.{ u32_8, u32_8 }, &.{u32_8});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    return OwnedSemanticChoirModule.init(try builder.finish());
}

pub fn addSemanticModule(allocator: std.mem.Allocator, name: []const u8) !*semantic.SemanticModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction(name, &.{ f32_8, f32_8 }, &.{f32_8});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    try fb.return_(&.{sum});
    try fb.finish();
    return try builder.finish();
}

pub fn fusedAddMulChoirModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction(name, &.{ f32_8, f32_8, f32_8 }, &.{f32_8});
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    const product = try fb.mul(sum, fb.parameter(2));
    try fb.return_(&.{product});
    try fb.finish();
    return OwnedSemanticChoirModule.init(try builder.finish());
}

pub fn kernelCallChoirModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction(name, &.{ f32_8, f32_8 }, &.{f32_8});
    const call = try fb.kernelCall(
        &.{ fb.parameter(0), fb.parameter(1) },
        &.{f32_8},
        .{
            .target = "accy.custom.scale",
            .operand_effects = &.{ .read, .write },
            .result_aliases = &.{null},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    return OwnedSemanticChoirModule.init(try builder.finish());
}

pub fn aliasedKernelCallChoirModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction(name, &.{f32_8}, &.{f32_8});
    const call = try fb.kernelCall(
        &.{fb.parameter(0)},
        &.{f32_8},
        .{
            .target = "accy.custom.update",
            .operand_effects = &.{.read_write},
            .result_aliases = &.{0},
        },
    );
    try fb.return_(&.{call.getFirstResult()});
    try fb.finish();
    return OwnedSemanticChoirModule.init(try builder.finish());
}

pub fn constantAddChoirModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction(name, &.{f32_8}, &.{f32_8});
    const values = @as([8]f32, @splat(2.0));
    const constant = try fb.constant(f32_8, std.mem.sliceAsBytes(values[0..]));
    const sum = try fb.add(fb.parameter(0), constant);
    try fb.return_(&.{sum});
    try fb.finish();
    return OwnedSemanticChoirModule.init(try builder.finish());
}

pub fn dotGeneralChoirModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_16x16 = try builder.tensor(.f32, &.{ 16, 16 });
    var fb = try builder.beginFunction(name, &.{ f32_16x16, f32_16x16 }, &.{f32_16x16});
    const product = try fb.dotGeneral(
        fb.parameter(0),
        fb.parameter(1),
        f32_16x16,
        &.{1},
        &.{0},
        &.{},
        &.{},
    );
    try fb.return_(&.{product});
    try fb.finish();
    return OwnedSemanticChoirModule.init(try builder.finish());
}

pub fn dotGeneralF16ChoirModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f16_16x16 = try builder.tensor(.f16, &.{ 16, 16 });
    const f32_16x16 = try builder.tensor(.f32, &.{ 16, 16 });
    var fb = try builder.beginFunction(name, &.{ f16_16x16, f16_16x16 }, &.{f32_16x16});
    const product = try fb.dotGeneral(
        fb.parameter(0),
        fb.parameter(1),
        f32_16x16,
        &.{1},
        &.{0},
        &.{},
        &.{},
    );
    try fb.return_(&.{product});
    try fb.finish();
    return OwnedSemanticChoirModule.init(try builder.finish());
}

pub fn reduceChoirModule(allocator: std.mem.Allocator, name: []const u8) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_256 = try builder.tensor(.f32, &.{256});
    const f32_scalar = try builder.tensor(.f32, &.{});
    var fb = try builder.beginFunction(name, &.{f32_256}, &.{f32_scalar});
    const zero = try fb.constant(f32_scalar, std.mem.asBytes(&@as(f32, 0.0)));
    const reduced = try fb.reduce(fb.parameter(0), zero, f32_scalar, "sum", &.{0});
    try fb.return_(&.{reduced});
    try fb.finish();
    return OwnedSemanticChoirModule.init(try builder.finish());
}

pub fn reduceI32ChoirModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const i32_256 = try builder.tensor(.i32, &.{256});
    const i32_scalar = try builder.tensor(.i32, &.{});
    var fb = try builder.beginFunction(name, &.{i32_256}, &.{i32_scalar});
    const zero = try fb.constant(i32_scalar, std.mem.asBytes(&@as(i32, 0)));
    const reduced = try fb.reduce(fb.parameter(0), zero, i32_scalar, "sum", &.{0});
    try fb.return_(&.{reduced});
    try fb.finish();
    return OwnedSemanticChoirModule.init(try builder.finish());
}

pub fn escapedTwoKernelChoirModule(
    allocator: std.mem.Allocator,
    name: []const u8,
) !OwnedSemanticChoirModule {
    var builder = try semantic.Builder.init(allocator, semantic.Builder.ContextLimits.standard);
    errdefer builder.deinit();
    const f32_8 = try builder.tensor(.f32, &.{8});
    var fb = try builder.beginFunction(name, &.{ f32_8, f32_8, f32_8 }, &.{ f32_8, f32_8 });
    const sum = try fb.add(fb.parameter(0), fb.parameter(1));
    const product = try fb.mul(sum, fb.parameter(2));
    try fb.return_(&.{ sum, product });
    try fb.finish();
    return OwnedSemanticChoirModule.init(try builder.finish());
}

pub fn createTestBackendArtifactPlan(
    allocator: std.mem.Allocator,
    handle: gpu.BackendHandle,
    pass_ctx: *passes.PassContext,
    choir_module: *ir.Operation,
    options: artifact_product.ArtifactPlanOptions,
) !artifact_product.BackendArtifactPlan {
    const lowered_kernels = try preparation.kernelization.getKernelizationAnalysis(
        pass_ctx,
        choir_module,
    );
    return try artifact_product.createBackendArtifactPlan(
        allocator,
        handle,
        .{
            .pass_ctx = pass_ctx,
            .choir_module = choir_module,
            .lowered_kernels = lowered_kernels,
        },
        options,
    );
}

pub fn bufferBinding(
    id: gpu.BackendObjectId,
    kind: gpu.BackendKind,
    bytes: usize,
) gpu.BufferBinding {
    return .{
        .handle = .{
            .id = id,
            .backend = kind,
            .byte_size = bytes,
            .ownership = .backend,
        },
        .access = .read_write,
        .ownership = .backend,
        .byte_size = bytes,
    };
}

pub fn slotBindingsForKernel(
    allocator: std.mem.Allocator,
    kernel: artifact_product.PlannedKernel,
    kind: gpu.BackendKind,
) ![]binding_mod.SlotBinding {
    const bindings = try allocator.alloc(binding_mod.SlotBinding, 1 + kernel.input_slot_ids.len);
    bindings[0] = .{
        .slot_id = kernel.output_slot_id,
        .binding = bufferBinding(100, kind, 32),
    };
    for (kernel.input_slot_ids, 0..) |slot_id, index| {
        bindings[1 + index] = .{
            .slot_id = slot_id,
            .binding = bufferBinding(@intCast(101 + index), kind, 32),
        };
    }
    return bindings;
}

pub fn slotBindingsForPlan(
    allocator: std.mem.Allocator,
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    kind: gpu.BackendKind,
) ![]binding_mod.SlotBinding {
    const bindings = try allocator.alloc(binding_mod.SlotBinding, artifact_plan.slots.len);
    for (artifact_plan.slots, 0..) |slot, index| {
        const bytes = std.math.cast(usize, slot.byte_size orelse
            32) orelse return error.InvalidArtifact;
        bindings[index] = .{
            .slot_id = slot.slot_id,
            .binding = bufferBinding(@intCast(100 + index), kind, bytes),
        };
    }
    return bindings;
}

pub fn elementCountBindingsForPlan(
    allocator: std.mem.Allocator,
    artifact_plan: *const artifact_product.BackendArtifactPlan,
    kind: gpu.BackendKind,
) ![]binding_mod.ElementCountBufferBinding {
    var bindings = std.ArrayListUnmanaged(binding_mod.ElementCountBufferBinding).empty;
    errdefer bindings.deinit(allocator);
    for (artifact_plan.kernels.items) |kernel| {
        if (kernel.element_count_argument != .device_buffer_u32) continue;
        try bindings.append(allocator, .{
            .kernel_id = kernel.kernel_id,
            .binding = bufferBinding(@intCast(900 + kernel.kernel_id), kind, 4),
        });
    }
    return try bindings.toOwnedSlice(allocator);
}

pub fn firstElementCountBinding(
    bindings: []const binding_mod.ElementCountBufferBinding,
) ?gpu.BufferBinding {
    if (bindings.len == 0) return null;
    return bindings[0].binding;
}
