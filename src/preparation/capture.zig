const std = @import("std");
const choir = @import("choir");
const gpu = choir.backends.gpu;
const preparation = @import("root.zig");
const records = @import("../choir/root.zig").record;
const codec = records.codec;
const dispatch_record = records.dispatch;
const memory_record = records.memory;

pub fn dispatch(
    allocator: std.mem.Allocator,
    root: *choir.ir.Operation,
    fusion: *const preparation.fusion.FusionPlanAnalysis,
    schedule: *const preparation.schedule.SchedulePlanAnalysis,
    entity_limit: u32,
) ![]u8 {
    comptime {
        codec.coverage(preparation.fusion.FusionCluster, dispatch_record.Cluster, &.{});
        codec.coverage(
            preparation.fusion.FusionPlanAnalysis,
            dispatch_record.Fusion,
            &.{"allocator"},
        );
        codec.coverage(preparation.schedule.ScheduleWorkItem, dispatch_record.WorkItem, &.{});
        codec.coverage(preparation.schedule.SchedulePlanAnalysis, dispatch_record.Schedule, &.{
            "allocator", "root_to_item",
        });
    }
    if (schedule.root_to_item.count() != schedule.work_items.items.len) {
        return error.UnencodableProduct;
    }
    for (schedule.work_items.items, 0..) |item, index| {
        if (schedule.root_to_item.get(item.root) != index) return error.UnencodableProduct;
    }
    var references = try records.reference.Index.init(allocator, root, entity_limit);
    defer references.deinit();
    return qualified(allocator, dispatch_record.Record, .dispatch, .{
        .fusion = fusion,
        .schedule = schedule,
    }, &references);
}

pub fn memory(
    allocator: std.mem.Allocator,
    root: *choir.ir.Operation,
    buffers: *const preparation.bufferization.BufferPlanAnalysis,
    spaces: *const preparation.memory.MemorySpacePlanAnalysis,
    layouts: *const preparation.layout.LayoutPlanAnalysis,
    entity_limit: u32,
) ![]u8 {
    comptime memoryCoverage();
    if (buffers.value_to_slot.count() < buffers.slots.items.len or
        buffers.value_to_elision.count() != buffers.elisions.items.len or
        spaces.slot_to_assignment.count() != spaces.assignments.items.len or
        layouts.slot_to_assignment.count() != layouts.assignments.items.len)
    {
        return error.UnencodableProduct;
    }
    for (buffers.slots.items, 0..) |slot, index| {
        if (buffers.value_to_slot.get(slot.value) != index) return error.UnencodableProduct;
    }
    for (buffers.elisions.items, 0..) |elision, index| {
        if (buffers.value_to_elision.get(elision.value) != index) return error.UnencodableProduct;
    }
    for (spaces.assignments.items, 0..) |assignment, index| {
        if (spaces.slot_to_assignment.get(assignment.slot_id) != index) {
            return error.UnencodableProduct;
        }
    }
    for (layouts.assignments.items, 0..) |assignment, index| {
        if (layouts.slot_to_assignment.get(assignment.slot_id) != index) {
            return error.UnencodableProduct;
        }
    }
    var references = try records.reference.Index.init(allocator, root, entity_limit);
    defer references.deinit();
    const bindings = try memoryBindings(allocator, buffers, &references);
    defer allocator.free(bindings);
    const bytes = try qualified(allocator, memory_record.Record, .memory, .{
        .buffers = buffers,
        .bindings = bindings,
        .spaces = spaces,
        .layouts = layouts,
    }, &references);
    errdefer allocator.free(bytes);
    try compareMemoryBindings(allocator, bytes, buffers, &references);
    return bytes;
}

fn compareMemoryBindings(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    buffers: *const preparation.bufferization.BufferPlanAnalysis,
    references: *const records.reference.Index,
) !void {
    var decoded = try codec.decode(allocator, memory_record.Record, .memory, bytes);
    defer decoded.deinit();
    if (decoded.value.bindings.len != buffers.value_to_slot.count()) {
        return error.UnencodableProduct;
    }
    var entries = buffers.value_to_slot.iterator();
    while (entries.next()) |entry| {
        const expected = try references.value(entry.key_ptr.*);
        const found = for (decoded.value.bindings) |binding| {
            if (std.meta.eql(expected, binding.value)) break binding.slot_id;
        } else return error.UnencodableProduct;
        if (found != entry.value_ptr.*) return error.UnencodableProduct;
    }
}

fn memoryBindings(
    allocator: std.mem.Allocator,
    buffers: *const preparation.bufferization.BufferPlanAnalysis,
    references: *const records.reference.Index,
) ![]memory_record.Binding {
    const bindings = try allocator.alloc(memory_record.Binding, buffers.value_to_slot.count());
    errdefer allocator.free(bindings);
    var entries = buffers.value_to_slot.iterator();
    var count: usize = 0;
    while (entries.next()) |entry| {
        if (entry.value_ptr.* >= buffers.slots.items.len) return error.UnencodableProduct;
        bindings[count] = .{
            .value = try references.value(entry.key_ptr.*),
            .slot_id = entry.value_ptr.*,
        };
        count += 1;
    }
    std.debug.assert(count == bindings.len);
    std.mem.sort(memory_record.Binding, bindings, {}, memory_record.Binding.lessThan);
    return bindings;
}

fn memoryCoverage() void {
    codec.coverage(preparation.bufferization.BufferSlot, memory_record.Slot, &.{});
    codec.coverage(preparation.bufferization.FusionElision, memory_record.Elision, &.{});
    codec.coverage(preparation.bufferization.BufferPlanAnalysis, memory_record.Buffers, &.{
        "allocator", "value_to_slot", "value_to_elision",
    });
    codec.coverage(preparation.memory.MemorySpaceAssignment, memory_record.Assignment, &.{});
    codec.coverage(preparation.memory.MemorySpacePlanAnalysis, memory_record.Spaces, &.{
        "allocator", "slot_to_assignment",
    });
    codec.coverage(preparation.layout.LayoutAssignment, memory_record.Layout, &.{});
    codec.coverage(preparation.layout.LayoutPlanAnalysis, memory_record.Layouts, &.{
        "allocator", "slot_to_assignment",
    });
}

pub fn kernel(
    allocator: std.mem.Allocator,
    root: *choir.ir.Operation,
    outlines: *const preparation.kernelization.product.KernelOutlinePlanAnalysis,
    generated: *const preparation.kernelization.KernelizationAnalysis,
    comptime configuration: choir.product.operation.Configuration,
) ![]u8 {
    comptime kernelCoverage();
    try requireWorkMap(outlines);
    try requireWorkMap(generated);
    var programs = try Generated.init(allocator, generated.kernels.items, configuration);
    defer programs.deinit();
    var references = try records.reference.Index.init(
        allocator,
        root,
        configuration.image.entities,
    );
    defer references.deinit();
    return qualified(allocator, records.kernel.Record, .kernel, .{
        .outlines = outlines,
        .generated = .{ .kernels = programs.lowered },
    }, &references);
}

const Generated = struct {
    allocator: std.mem.Allocator,
    programs: []codec.Decoded(records.program.Record),
    lowered: []records.kernel.Lowered,

    fn init(
        allocator: std.mem.Allocator,
        source: []const preparation.kernelization.LoweredKernel,
        comptime configuration: choir.product.operation.Configuration,
    ) !Generated {
        comptime kernelCoverage();
        if (source.len > configuration.codec.fields) return error.RecordLimit;
        const programs = try allocator.alloc(
            codec.Decoded(records.program.Record),
            source.len,
        );
        errdefer allocator.free(programs);
        var initialized: usize = 0;
        errdefer for (programs[0..initialized]) |*program| program.deinit();
        const lowered = try allocator.alloc(records.kernel.Lowered, programs.len);
        errdefer allocator.free(lowered);
        for (source, 0..) |*kernel_value, index| {
            programs[index] = try records.program.capture(
                allocator,
                &kernel_value.program,
                configuration,
            );
            initialized += 1;
            inline for (@typeInfo(records.kernel.Lowered).@"struct".field_names) |name| {
                @field(lowered[index], name) = if (comptime std.mem.eql(u8, name, "program"))
                    programs[index].value
                else
                    @field(kernel_value, name);
            }
        }
        return .{ .allocator = allocator, .programs = programs, .lowered = lowered };
    }

    fn deinit(self: *Generated) void {
        for (self.programs) |*program| program.deinit();
        self.allocator.free(self.programs);
        self.allocator.free(self.lowered);
    }
};

pub fn target(
    allocator: std.mem.Allocator,
    root: *choir.ir.Operation,
    schedule: *const preparation.schedule.SchedulePlanAnalysis,
    generated: []const preparation.kernelization.LoweredKernel,
    comptime configuration: choir.product.operation.Configuration,
) ![]u8 {
    var programs = try Generated.init(allocator, generated, configuration);
    defer programs.deinit();
    const profile = preparation.readBackendTargetProfile(root);
    const kernels = try allocator.alloc(records.target.Kernel, programs.lowered.len);
    defer allocator.free(kernels);
    var initialized: usize = 0;
    defer for (kernels[0..initialized]) |kernel_value| {
        if (kernel_value.abi) |abi| allocator.free(abi.static_arguments);
    };
    for (programs.lowered, generated, 0..) |lowered, *source, index| {
        const work = for (schedule.work_items.items) |item| {
            if (item.id == lowered.work_item_id) break item;
        } else return error.UnencodableProduct;
        kernels[index] = try targetKernel(allocator, lowered, source, work, profile);
        initialized += 1;
    }
    var references = records.reference.Index{ .allocator = allocator, .limit = 0 };
    defer references.deinit();
    const row_schedules = preparation.target.readGeneratedRowPipelineSchedules(root);
    return qualified(allocator, records.target.Record, .target, records.target.Record{
        .profile = profile,
        .math_tier = if (profile) |value| value.math_tier else .exact,
        .generated_scan_schedules = preparation.target.readGeneratedScanSchedules(root),
        .generated_row_pipeline_schedules = row_schedules,
        .kernels = kernels,
    }, &references);
}

fn targetKernel(
    allocator: std.mem.Allocator,
    lowered: records.kernel.Lowered,
    source: *const preparation.kernelization.LoweredKernel,
    work: preparation.schedule.ScheduleWorkItem,
    profile: ?preparation.BackendTargetProfile,
) !records.target.Kernel {
    var dtypes = source.requiredDTypes();
    dtypes.insert(work.dtype);
    return .{
        .lowered = lowered,
        .work_dtype = work.dtype,
        .element_count = work.element_count,
        .required_dtype_bits = dtypes.bits,
        .required_features = gpu.featureRequirementsForModule(source.program.kernelModule()),
        .required_subgroup = gpu.subgroupRequirementsForModule(source.program.kernelModule()),
        .runtime_scalar_argument_count = source.runtimeScalarArgumentCount(),
        .abi = if (profile) |value| try targetAbi(allocator, source, work, value) else null,
    };
}

fn targetAbi(
    allocator: std.mem.Allocator,
    source: *const preparation.kernelization.LoweredKernel,
    work: preparation.schedule.ScheduleWorkItem,
    profile: preparation.BackendTargetProfile,
) !records.target.Abi {
    const owner = @import("../target/root.zig");
    const format = profile.artifact_format;
    const count = try owner.abi.argumentCount(format, source.argument_count);
    const launch = try owner.abi.launchGeometry(
        format,
        work.element_count,
        source.launchGeometry(),
    );
    return .{
        .argument_count = count,
        .static_arguments = try owner.abi.staticArguments(
            allocator,
            format,
            work.element_count,
            launch,
        ),
        .launch = launch,
        .compile_options = owner.compileOptionsForArtifactFormat(format, work.element_count),
    };
}

fn requireWorkMap(analysis: anytype) !void {
    if (analysis.work_to_kernel.count() != analysis.kernels.items.len) {
        return error.UnencodableProduct;
    }
    for (analysis.kernels.items, 0..) |item, index| {
        if (analysis.work_to_kernel.get(item.work_item_id) != index) {
            return error.UnencodableProduct;
        }
    }
}

fn kernelCoverage() void {
    const product = preparation.kernelization.product;
    codec.coverage(product.KernelOutline, records.kernel.Outline, &.{});
    codec.coverage(product.KernelOutlinePlanAnalysis, records.kernel.Outlines, &.{
        "allocator", "work_to_kernel",
    });
    codec.coverage(product.LoweredKernel, records.kernel.Lowered, &.{});
    codec.coverage(product.KernelizationAnalysis, records.kernel.Generated, &.{
        "allocator", "context", "work_to_kernel",
    });
}

fn qualified(
    allocator: std.mem.Allocator,
    comptime T: type,
    stage: @import("../choir/root.zig").publication.Stage,
    source: anytype,
    references: *const records.reference.Index,
) ![]u8 {
    const bytes = try codec.encode(allocator, T, stage, source, references);
    errdefer allocator.free(bytes);
    var decoded = try codec.decode(allocator, T, stage, bytes);
    defer decoded.deinit();
    try codec.compare(decoded.value, source, references);
    const compared = try codec.encode(allocator, T, stage, decoded.value, references);
    defer allocator.free(compared);
    if (!std.mem.eql(u8, bytes, compared)) return error.UnencodableProduct;
    return bytes;
}
