//! Functions that reduce three plans of one compile to a 64-bit number each: how operations are
//! grouped into launches and scheduled, how buffers are placed in memory, and how the functions a
//! device runs across many threads at once are outlined and generated.
//!
//! A person comparing two compiles wants to see at a glance whether a middle stage planned the same
//! thing, without reading the plans. A short number that looks like an identity invites code to use
//! it as one, and a summary that depends on function names or on where values sit in memory changes
//! between two compiles of the same plan.
//!
//! Each summary is written into the per-stage display record of one compile, built for people
//! reading it (*run stamp*). No product key, reuse check, receipt identity or other decision reads
//! a summary, because the sealed record of each stage (its *stage record*) holds the exact plan.
//! Values are numbered by a stable order within the module, and operations are summarized by the
//! shape of the tree beneath them, so equal plans inside functions with different names give equal
//! summaries. A planned buffer (a *buffer slot*) records only whether it has an enclosing function,
//! because the value it holds already identifies that function. Every field of every plan is either
//! summarized or listed as administrative, and a compile-time check stops the build when a new
//! field is neither.

const std = @import("std");
const choir = @import("choir");

const accy_choir = @import("../choir/root.zig");
const bufferization = @import("bufferization/root.zig");
const fusion = @import("fusion/root.zig");
const kernelization = @import("kernelization/root.zig");
const layout = @import("layout.zig");
const memory_space = @import("memory.zig");
const outlining = @import("outlining/root.zig");
const schedule_planning = @import("schedule/root.zig");

const ir = choir.ir;
const outline_model = kernelization.product;
const Builder = choir.product.incremental.FingerprintBuilder;
const Numbering = choir.StableValueNumbering;

/// Returns one 64-bit summary of the fusion plan and the schedule plan of `module`, taken after the
/// dispatch pipeline, for the run record. The summary also covers the product name and
/// `pipeline_name`. The allocator backs only scratch for value numbering, which is freed before the
/// call returns.
pub fn dispatch(
    allocator: std.mem.Allocator,
    module: *accy_choir.tensor.TensorJob,
    pipeline_name: []const u8,
) !u64 {
    comptime dispatchCoverage();
    var pass_ctx = module.passContext();
    defer pass_ctx.deinit();
    const root = module.choir_module;
    const fusion_plan = try fusion.getFusionPlanAnalysis(&pass_ctx, root);
    const schedule_plan = try schedule_planning.getSchedulePlanAnalysis(&pass_ctx, root);

    const limits = try Numbering.Limits.inspect(root);
    var numbering = try Numbering.init(allocator, limits);
    defer numbering.deinit(allocator);
    try numbering.activate();

    var builder = Builder{};
    builder.updateBytes(accy_choir.dispatch.product_name);
    builder.updateBytes(pipeline_name);
    updateFusionPlan(&builder, fusion_plan, &numbering);
    updateSchedulePlan(&builder, schedule_plan, &numbering);
    return builder.finish();
}

/// Returns one 64-bit summary of the buffer plan, the memory-space plan and the layout plan of
/// `module`, taken after the memory pipeline, for the run record. The summary also covers the
/// product name and `pipeline_name`. The allocator backs only scratch for value numbering and the
/// buffer plan walk, which is freed before the call returns.
pub fn memory(
    allocator: std.mem.Allocator,
    module: *accy_choir.dispatch.DispatchJob,
    pipeline_name: []const u8,
) !u64 {
    comptime memoryCoverage();
    var pass_ctx = module.passContext();
    defer pass_ctx.deinit();
    const root = module.choir_module;
    const buffer_plan = try bufferization.getBufferPlanAnalysis(&pass_ctx, root);
    const space_plan = try memory_space.getMemorySpacePlanAnalysis(&pass_ctx, root);
    const layout_plan = try layout.getLayoutPlanAnalysis(&pass_ctx, root);

    const limits = try Numbering.Limits.inspect(root);
    var numbering = try Numbering.init(allocator, limits);
    defer numbering.deinit(allocator);
    try numbering.activate();

    var builder = Builder{};
    builder.updateBytes(accy_choir.memory.product_name);
    builder.updateBytes(pipeline_name);
    try updateBufferPlan(allocator, &builder, buffer_plan, &numbering);
    updateSpacePlan(&builder, space_plan, &numbering);
    updateLayoutPlan(&builder, layout_plan, &numbering);
    return builder.finish();
}

/// Returns one 64-bit summary of the kernel outline plan and the generated kernels of `module`,
/// taken after the kernel pipeline, for the run record. The summary also covers the product name
/// and `pipeline_name`. The names of the generated kernels leave the summary unchanged.
pub fn kernel(
    allocator: std.mem.Allocator,
    module: *accy_choir.memory.MemoryJob,
    pipeline_name: []const u8,
) !u64 {
    comptime kernelCoverage();
    var pass_ctx = module.passContext();
    defer pass_ctx.deinit();
    const root = module.choir_module;
    const outline_plan = try outlining.getKernelOutlinePlanAnalysis(&pass_ctx, root);
    const kernel_plan = try kernelization.getKernelizationAnalysis(&pass_ctx, root);

    const limits = try Numbering.Limits.inspect(root);
    var numbering = try Numbering.init(allocator, limits);
    defer numbering.deinit(allocator);
    try numbering.activate();

    var builder = Builder{};
    builder.updateBytes(accy_choir.gpu.product_name);
    builder.updateBytes(pipeline_name);
    updateOutlinePlan(&builder, outline_plan, &numbering);
    try updateKernelPlan(allocator, &builder, kernel_plan);
    return builder.finish();
}

fn updateFusionPlan(
    builder: *Builder,
    plan: *const fusion.FusionPlanAnalysis,
    numbering: *Numbering,
) void {
    builder.updateBytes(fusion.fusion_plan_analysis_name);
    builder.updateUsize(plan.clusters.items.len);
    builder.updateUsize(plan.fused_op_count);
    builder.updateUsize(plan.max_cluster_len);
    for (plan.clusters.items) |cluster| {
        builder.updateEnumTag(cluster.kind);
        updateOperations(builder, numbering, cluster.ops);
    }
    updateOperations(builder, numbering, plan.elided.items);
}

fn updateSchedulePlan(
    builder: *Builder,
    plan: *const schedule_planning.SchedulePlanAnalysis,
    numbering: *Numbering,
) void {
    builder.updateBytes(schedule_planning.schedule_plan_analysis_name);
    builder.updateUsize(plan.work_items.items.len);
    builder.updateUsize(plan.single_work_count);
    builder.updateUsize(plan.fusion_work_count);
    builder.updateUsize(plan.kernel_call_work_count);
    builder.updateUsize(plan.scheduled_op_count);
    builder.updateU64(plan.total_static_elements);
    for (plan.work_items.items) |work| {
        builder.updateUsize(work.id);
        builder.updateEnumTag(work.kind);
        numbering.updateSubtreeFingerprint(builder, work.root);
        updateOperations(builder, numbering, work.ops);
        updateValue(builder, numbering, work.output_value);
        builder.updateU64(@backingInt(work.dtype));
        builder.updateUsize(work.rank);
        builder.updateU64(work.element_count);
        updateResources(builder, work.resources);
    }
}

fn updateResources(
    builder: *Builder,
    resources: schedule_planning.ScheduleResourceEstimate,
) void {
    builder.updateU64(resources.element_count);
    builder.updateU64(resources.element_size);
    builder.updateUsize(resources.op_count);
    builder.updateUsize(resources.external_input_value_count);
    builder.updateUsize(resources.external_operand_count);
    builder.updateUsize(resources.chain_operand_count);
    builder.updateU64(resources.static_read_bytes);
    builder.updateU64(resources.static_write_bytes);
    builder.updateU64(resources.static_total_bytes);
    builder.updateU64(resources.estimated_element_ops);
    builder.updateBool(resources.static_bytes_complete);
}

fn updateBufferPlan(
    allocator: std.mem.Allocator,
    builder: *Builder,
    plan: *const bufferization.BufferPlanAnalysis,
    numbering: *Numbering,
) !void {
    builder.updateBytes(bufferization.buffer_plan_analysis_name);
    builder.updateUsize(plan.slots.items.len);
    builder.updateUsize(plan.elisions.items.len);
    builder.updateUsize(plan.input_slot_count);
    builder.updateUsize(plan.output_slot_count);
    builder.updateUsize(plan.temporary_slot_count);
    builder.updateUsize(plan.constant_slot_count);
    builder.updateUsize(plan.dynamic_slot_count);
    builder.updateU64(plan.total_static_bytes);
    for (plan.slots.items) |slot| {
        builder.updateUsize(slot.id);
        updateValue(builder, numbering, slot.value);
        updateOptionalOperation(builder, numbering, slot.producer);
        builder.updateBool(slot.function != null);
        updateRole(builder, slot.role);
        builder.updateU64(@backingInt(slot.dtype));
        builder.updateI64Slice(slot.dims);
        builder.updateOptionalU64(slot.element_count);
        builder.updateOptionalU64Slice(slot.row_major_strides);
        builder.updateOptionalU64(slot.byte_size);
    }
    for (plan.elisions.items) |elision| {
        updateValue(builder, numbering, elision.value);
        numbering.updateSubtreeFingerprint(builder, elision.producer);
        numbering.updateSubtreeFingerprint(builder, elision.root);
        builder.updateUsize(elision.cluster_index);
    }
    try updateBindings(allocator, builder, plan, numbering);
}

const Binding = struct {
    value: u64,
    slot_id: usize,

    fn lessThan(_: void, lhs: Binding, rhs: Binding) bool {
        if (lhs.value != rhs.value) return lhs.value < rhs.value;
        return lhs.slot_id < rhs.slot_id;
    }
};

fn updateBindings(
    allocator: std.mem.Allocator,
    builder: *Builder,
    plan: *const bufferization.BufferPlanAnalysis,
    numbering: *const Numbering,
) !void {
    const bindings = try allocator.alloc(Binding, plan.value_to_slot.count());
    defer allocator.free(bindings);
    var entries = plan.value_to_slot.iterator();
    var count: usize = 0;
    while (entries.next()) |entry| : (count += 1) {
        bindings[count] = .{
            .value = numbering.valueId(entry.key_ptr.*) orelse std.math.maxInt(u64),
            .slot_id = entry.value_ptr.*,
        };
    }
    std.debug.assert(count == bindings.len);
    std.mem.sort(Binding, bindings, {}, Binding.lessThan);
    builder.updateUsize(bindings.len);
    for (bindings) |binding| {
        builder.updateU64(binding.value);
        builder.updateUsize(binding.slot_id);
    }
}

fn updateSpacePlan(
    builder: *Builder,
    plan: *const memory_space.MemorySpacePlanAnalysis,
    numbering: *Numbering,
) void {
    builder.updateBytes(memory_space.memory_space_plan_analysis_name);
    builder.updateUsize(plan.assignments.items.len);
    builder.updateUsize(plan.host_slot_count);
    builder.updateUsize(plan.device_global_slot_count);
    builder.updateUsize(plan.device_constant_slot_count);
    builder.updateUsize(plan.device_shared_slot_count);
    builder.updateUsize(plan.unified_slot_count);
    builder.updateUsize(plan.host_input_transfer_count);
    builder.updateUsize(plan.host_output_transfer_count);
    builder.updateUsize(plan.dynamic_slot_count);
    builder.updateUsize(plan.elided_value_count);
    builder.updateU64(plan.total_static_bytes);
    for (plan.assignments.items) |assignment| {
        builder.updateUsize(assignment.slot_id);
        updateValue(builder, numbering, assignment.value);
        updateOptionalOperation(builder, numbering, assignment.producer);
        updateRole(builder, assignment.role);
        builder.updateEnumTag(assignment.space);
        builder.updateEnumTag(assignment.access);
        builder.updateEnumTag(assignment.transfer);
        builder.updateOptionalU64(assignment.byte_size);
        updateOutputSource(builder, assignment.output_source);
    }
}

fn updateOutputSource(builder: *Builder, source: ?memory_space.OutputSource) void {
    if (source) |value| {
        builder.updateBool(true);
        builder.updateEnumTag(std.meta.activeTag(value));
        switch (value) {
            inline else => |index| builder.updateUsize(index),
        }
    } else {
        builder.updateBool(false);
    }
}

fn updateLayoutPlan(
    builder: *Builder,
    plan: *const layout.LayoutPlanAnalysis,
    numbering: *Numbering,
) void {
    builder.updateBytes(layout.layout_plan_analysis_name);
    builder.updateUsize(plan.assignments.items.len);
    builder.updateUsize(plan.scalar_layout_count);
    builder.updateUsize(plan.row_major_layout_count);
    builder.updateUsize(plan.dynamic_row_major_layout_count);
    builder.updateUsize(plan.host_slot_count);
    builder.updateUsize(plan.device_global_slot_count);
    builder.updateUsize(plan.device_constant_slot_count);
    builder.updateUsize(plan.device_shared_slot_count);
    builder.updateUsize(plan.unified_slot_count);
    builder.updateUsize(plan.dynamic_slot_count);
    builder.updateUsize(plan.elided_value_count);
    builder.updateU64(plan.total_static_bytes);
    for (plan.assignments.items) |assignment| {
        updateLayout(builder, assignment, numbering);
    }
}

fn updateLayout(
    builder: *Builder,
    assignment: layout.LayoutAssignment,
    numbering: *Numbering,
) void {
    builder.updateUsize(assignment.slot_id);
    updateValue(builder, numbering, assignment.value);
    updateOptionalOperation(builder, numbering, assignment.producer);
    updateRole(builder, assignment.role);
    builder.updateU64(@backingInt(assignment.dtype));
    builder.updateEnumTag(assignment.memory_space);
    builder.updateEnumTag(assignment.kind);
    builder.updateUsize(assignment.rank);
    builder.updateI64Slice(assignment.dims);
    builder.updateOptionalU64Slice(assignment.element_strides);
    builder.updateUsizeSlice(assignment.minor_to_major);
    builder.updateOptionalU64(assignment.element_count);
    builder.updateOptionalU64(assignment.byte_size);
    builder.updateU64(assignment.element_size);
    builder.updateU64(assignment.alignment);
    builder.updateBool(assignment.contiguous);
    builder.updateBool(assignment.static_layout);
}

fn updateOutlinePlan(
    builder: *Builder,
    plan: *const outline_model.KernelOutlinePlanAnalysis,
    numbering: *Numbering,
) void {
    builder.updateBytes(outline_model.kernel_outline_plan_analysis_name);
    builder.updateUsize(plan.kernels.items.len);
    builder.updateUsize(plan.total_input_slots);
    builder.updateUsize(plan.total_scheduled_ops);
    for (plan.kernels.items) |outline| {
        builder.updateUsize(outline.id);
        builder.updateBytes(outline.name);
        builder.updateEnumTag(outline.kind);
        builder.updateUsize(outline.work_item_id);
        numbering.updateSubtreeFingerprint(builder, outline.root);
        builder.updateUsizeSlice(outline.input_slot_ids);
        builder.updateUsize(outline.output_slot_id);
        builder.updateU64(outline.element_count);
        builder.updateUsize(outline.op_count);
    }
}

fn updateKernelPlan(
    allocator: std.mem.Allocator,
    builder: *Builder,
    plan: *const kernelization.KernelizationAnalysis,
) !void {
    builder.updateBytes(kernelization.kernelization_analysis_name);
    builder.updateUsize(plan.kernels.items.len);
    for (plan.kernels.items) |*lowered| {
        builder.updateUsize(lowered.work_item_id);
        builder.updateBytes(lowered.entry_name);
        builder.updateU64(try lowered.program.fingerprint(allocator));
        builder.updateU32(lowered.argument_count);
        builder.updateU64(lowered.body_fingerprint);
        builder.updateU32(lowered.dynamic_shared_memory_bytes);
        builder.updateEnumTag(lowered.schedule.kind);
        builder.updateU32(lowered.schedule.threads.x);
        builder.updateU32(lowered.schedule.threads.y);
        builder.updateU32(lowered.schedule.threads.z);
        if (lowered.launch) |launch| {
            builder.updateBool(true);
            for (launch.grid) |extent| builder.updateU32(extent);
            for (launch.block) |extent| builder.updateU32(extent);
        } else {
            builder.updateBool(false);
        }
        builder.updateOptionalU32(lowered.output_fill_pattern);
        builder.updateOptionalU32(lowered.scratch_fill_pattern);
        updateBody(builder, lowered.body);
    }
}

fn updateBody(builder: *Builder, body: kernelization.LoweredKernelBody) void {
    builder.updateEnumTag(std.meta.activeTag(body));
    switch (body) {
        .generic => {},
        inline else => |payload| updateScalars(builder, payload),
    }
}

fn updateScalars(builder: *Builder, value: anytype) void {
    const Value = @TypeOf(value);
    switch (@typeInfo(Value)) {
        .int => builder.updateU64(value),
        .@"struct" => |info| inline for (info.field_names) |name| {
            builder.updateU64(@field(value, name));
        },
        else => @compileError("unsummarized kernel body payload: " ++ @typeName(Value)),
    }
}

fn updateOperations(
    builder: *Builder,
    numbering: *Numbering,
    operations: []const *ir.Operation,
) void {
    builder.updateUsize(operations.len);
    for (operations) |operation| numbering.updateSubtreeFingerprint(builder, operation);
}

fn updateOptionalOperation(
    builder: *Builder,
    numbering: *Numbering,
    operation: ?*ir.Operation,
) void {
    if (operation) |value| {
        builder.updateBool(true);
        numbering.updateSubtreeFingerprint(builder, value);
    } else {
        builder.updateBool(false);
    }
}

fn updateValue(builder: *Builder, numbering: *const Numbering, value: *const ir.Value) void {
    if (numbering.valueId(value)) |id| {
        builder.updateBool(true);
        builder.updateU64(id);
    } else {
        builder.updateBool(false);
        builder.updateU64(std.math.maxInt(u64));
    }
}

fn updateRole(builder: *Builder, role: bufferization.BufferRole) void {
    builder.updateBool(role.input);
    builder.updateBool(role.output);
    builder.updateBool(role.temporary);
    builder.updateBool(role.constant);
}

fn dispatchCoverage() void {
    coverage(fusion.FusionCluster, &.{ "ops", "kind" }, &.{});
    coverage(fusion.FusionPlanAnalysis, &.{
        "clusters", "elided", "fused_op_count", "max_cluster_len",
    }, &.{"allocator"});
    coverage(schedule_planning.ScheduleWorkItem, &.{
        "id",    "kind", "root",          "ops",       "output_value",
        "dtype", "rank", "element_count", "resources",
    }, &.{});
    coverage(schedule_planning.ScheduleResourceEstimate, &.{
        "element_count",              "element_size",           "op_count",
        "external_input_value_count", "external_operand_count", "chain_operand_count",
        "static_read_bytes",          "static_write_bytes",     "static_total_bytes",
        "estimated_element_ops",      "static_bytes_complete",
    }, &.{});
    coverage(schedule_planning.SchedulePlanAnalysis, &.{
        "work_items",             "single_work_count",  "fusion_work_count",
        "kernel_call_work_count", "scheduled_op_count", "total_static_elements",
    }, &.{ "allocator", "root_to_item" });
}

fn memoryCoverage() void {
    coverage(bufferization.BufferRole, &.{ "input", "output", "temporary", "constant" }, &.{});
    coverage(bufferization.BufferSlot, &.{
        "id",    "value", "producer",      "function",          "role",
        "dtype", "dims",  "element_count", "row_major_strides", "byte_size",
    }, &.{});
    coverage(bufferization.FusionElision, &.{
        "value", "producer", "root", "cluster_index",
    }, &.{});
    coverage(bufferization.BufferPlanAnalysis, &.{
        "slots",               "elisions",           "value_to_slot",
        "input_slot_count",    "output_slot_count",  "temporary_slot_count",
        "constant_slot_count", "dynamic_slot_count", "total_static_bytes",
    }, &.{ "allocator", "value_to_elision" });
    coverage(memory_space.MemorySpaceAssignment, &.{
        "slot_id", "value",    "producer",  "role",          "space",
        "access",  "transfer", "byte_size", "output_source",
    }, &.{});
    coverage(memory_space.MemorySpacePlanAnalysis, &.{
        "assignments",                "host_slot_count",            "device_global_slot_count",
        "device_constant_slot_count", "device_shared_slot_count",   "unified_slot_count",
        "host_input_transfer_count",  "host_output_transfer_count", "dynamic_slot_count",
        "elided_value_count",         "total_static_bytes",
    }, &.{ "allocator", "slot_to_assignment" });
    coverage(layout.LayoutAssignment, &.{
        "slot_id",        "value",         "producer",  "role",         "dtype",
        "memory_space",   "kind",          "rank",      "dims",         "element_strides",
        "minor_to_major", "element_count", "byte_size", "element_size", "alignment",
        "contiguous",     "static_layout",
    }, &.{});
    coverage(layout.LayoutPlanAnalysis, &.{
        "assignments",                    "scalar_layout_count",      "row_major_layout_count",
        "dynamic_row_major_layout_count", "host_slot_count",          "device_global_slot_count",
        "device_constant_slot_count",     "device_shared_slot_count", "unified_slot_count",
        "dynamic_slot_count",             "elided_value_count",       "total_static_bytes",
    }, &.{ "allocator", "slot_to_assignment" });
}

fn kernelCoverage() void {
    coverage(outline_model.KernelOutline, &.{
        "id",             "name",           "kind",          "work_item_id", "root",
        "input_slot_ids", "output_slot_id", "element_count", "op_count",
    }, &.{});
    coverage(outline_model.KernelOutlinePlanAnalysis, &.{
        "kernels", "total_input_slots", "total_scheduled_ops",
    }, &.{ "allocator", "work_to_kernel" });
    coverage(kernelization.LoweredKernel, &.{
        "work_item_id",         "entry_name",       "program",
        "argument_count",       "body_fingerprint", "dynamic_shared_memory_bytes",
        "schedule",             "launch",           "output_fill_pattern",
        "scratch_fill_pattern", "body",
    }, &.{});
    coverage(kernelization.GeneratedSchedule, &.{ "kind", "threads" }, &.{});
    coverage(@FieldType(kernelization.GeneratedSchedule, "threads"), &.{ "x", "y", "z" }, &.{});
    const Launch = @typeInfo(@FieldType(kernelization.LoweredKernel, "launch")).optional.child;
    coverage(Launch, &.{ "grid", "block" }, &.{});
    coverage(kernelization.KernelizationAnalysis, &.{"kernels"}, &.{
        "allocator", "context", "work_to_kernel",
    });
}

fn coverage(
    comptime Plan: type,
    comptime summarized: []const []const u8,
    comptime administrative: []const []const u8,
) void {
    @setEvalBranchQuota(100_000);
    const names = @typeInfo(Plan).@"struct".field_names;
    if (names.len != summarized.len + administrative.len) {
        @compileError("stale plan summary field list: " ++ @typeName(Plan));
    }
    inline for (names) |name| {
        if (!listed(summarized, name) and !listed(administrative, name)) {
            @compileError("unsummarized plan field: " ++ @typeName(Plan) ++ "." ++ name);
        }
    }
}

fn listed(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}
