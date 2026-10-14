const std = @import("std");
const fixed = @import("alloc_fixed");
const choir = @import("choir");
const preparation = @import("../preparation/root.zig");
const records = @import("../choir/root.zig").record;
const publication = @import("../choir/root.zig").publication;
const plan = @import("root.zig").plan;
const ir = choir.ir;
const Configuration = choir.product.operation.Configuration;
const Prepared = preparation.pipeline.BackendPreparedModule;

/// Short-lived compile state rebuilt from the dispatch, memory, kernel, and
/// target results of one finished preparation: the schedule plan, the buffer,
/// memory-space and layout plans, the kernel outlines, the generated kernel
/// programs, and the target settings. A compiler of device code uses this to
/// recover the plans of a finished compile inside memory the caller provides.
/// `create` allocates the job and all of its contents inside the caller's
/// `workspace`, and a workspace that runs out gives `error.WorkExhausted`. The
/// job requires each stage record to match: the target record must hold exactly
/// one program root (`error.InvalidStageRoots`), and the dispatch, memory, and
/// kernel records must decode to that same program
/// (`error.IncompatibleStageImages`). The job keeps no pointer to the prepared
/// module, no stage-record key, and no mutable semantic module. The job works
/// out each kernel's legality for the target again from the restored plans and
/// keeps that result with the rest. `destroy` releases the job's contents, and
/// the workspace itself stays with the caller.
pub const InputJob = struct {
    fixed: fixed.Tracked,
    context: ?*ir.Context = null,
    decoded: ?choir.bytecode.DecodedModule = null,
    target: ?records.codec.Decoded(records.target.Record) = null,
    schedule: ?preparation.schedule.SchedulePlanAnalysis = null,
    buffers: ?preparation.bufferization.BufferPlanAnalysis = null,
    spaces: ?preparation.memory.MemorySpacePlanAnalysis = null,
    layouts: ?preparation.layout.LayoutPlanAnalysis = null,
    outlines: ?preparation.kernelization.product.KernelOutlinePlanAnalysis = null,
    generated: ?preparation.kernelization.KernelizationAnalysis = null,
    legal: ?preparation.backend.BackendLegalizationAnalysis = null,

    pub fn create(
        workspace: []u8,
        prepared: *const Prepared,
        comptime configuration: Configuration,
    ) !*InputJob {
        return initialize(workspace, prepared, configuration) catch |err| {
            return if (err == error.OutOfMemory) error.WorkExhausted else err;
        };
    }

    fn initialize(
        workspace: []u8,
        prepared: *const Prepared,
        comptime configuration: Configuration,
    ) !*InputJob {
        var initial = fixed.Tracked.init(workspace);
        const self = try initial.allocator().create(InputJob);
        self.* = .{ .fixed = initial };
        errdefer self.destroy();
        const allocator = self.fixed.allocator();
        self.context = try ir.Context.create(allocator, configuration.context);
        const context = self.context.?;
        (try choir.product.recipe.decode(prepared.stage(.target).inputs().policy)).restore(context);
        try configuration.register(context);
        const image = try open(prepared, allocator, .target, configuration);
        defer image.destroy();
        const root = image.root(0) orelse return error.InvalidStageRoots;
        if (image.root(1) != null) return error.InvalidStageRoots;
        self.decoded = try choir.bytecode.decodeModule(allocator, context, root.bytes);
        self.target = try records.codec.decode(
            allocator,
            records.target.Record,
            .target,
            image.stage(),
        );
        clearTargetAttributes(self.decoded.?.module);
        inline for (.{ .dispatch, .memory, .kernel }) |stage| {
            try self.requireSameProgram(prepared, stage, configuration);
        }
        var references = try References.init(
            allocator,
            self.decoded.?.module,
            configuration.image.entities,
        );
        defer references.deinit();
        try self.restoreDispatch(prepared, &references, configuration);
        try self.restoreMemory(prepared, &references, configuration);
        try self.restoreKernel(prepared, &references, configuration);
        try self.restoreTarget(configuration);
        return self;
    }

    pub fn destroy(self: *InputJob) void {
        const allocator = self.fixed.allocator();
        if (self.legal) |*value| value.deinit();
        if (self.generated) |*value| value.deinit();
        if (self.outlines) |*value| value.deinit();
        if (self.layouts) |*value| value.deinit();
        if (self.spaces) |*value| value.deinit();
        if (self.buffers) |*value| value.deinit();
        if (self.schedule) |*value| value.deinit();
        if (self.target) |*value| value.deinit();
        if (self.decoded) |*value| value.deinit();
        if (self.context) |context| {
            context.deinit(allocator);
            allocator.destroy(context);
        }
    }

    /// Returns pointers into this job's own fields: the program root, the
    /// target profile, and each restored plan. A caller passes the returned
    /// plans to the artifact compiler. The pointers stay valid until `destroy`
    /// runs or the caller writes over the workspace.
    pub fn plans(self: *const InputJob) plan.PlanInputs {
        return .{
            .root = self.decoded.?.module,
            .profile = self.target.?.value.profile,
            .schedule = &self.schedule.?,
            .buffers = &self.buffers.?,
            .spaces = &self.spaces.?,
            .layouts = &self.layouts.?,
            .outlines = &self.outlines.?,
            .generated = &self.generated.?,
            .legal = &self.legal.?,
            .target = &self.target.?.value,
        };
    }

    fn requireSameProgram(
        self: *InputJob,
        prepared: *const Prepared,
        comptime stage: publication.Stage,
        comptime configuration: Configuration,
    ) !void {
        const allocator = self.fixed.allocator();
        const image = try open(prepared, allocator, stage, configuration);
        defer image.destroy();
        if (image.root(1) != null) return error.InvalidStageRoots;
        var context = try ir.Context.init(allocator, configuration.context);
        defer context.deinit(allocator);
        (try choir.product.recipe.decode(prepared.stage(stage).inputs().policy)).restore(&context);
        try configuration.register(&context);
        const root = image.root(0) orelse return error.InvalidStageRoots;
        var decoded = try choir.bytecode.decodeModule(allocator, &context, root.bytes);
        defer decoded.deinit();
        clearTargetAttributes(decoded.module);
        choir.bytecode.qualification.compare(
            allocator,
            decoded.module,
            self.decoded.?.module,
            decoded.resources,
            self.decoded.?.resources,
            configuration.codec,
        ) catch |err| {
            return if (err == error.UnencodableProduct) error.IncompatibleStageImages else err;
        };
    }

    fn restoreDispatch(
        self: *InputJob,
        prepared: *const Prepared,
        refs: *const References,
        comptime configuration: Configuration,
    ) !void {
        const allocator = self.fixed.allocator();
        const image = try open(prepared, allocator, .dispatch, configuration);
        defer image.destroy();
        var record = try records.codec.decode(
            allocator,
            records.dispatch.Record,
            .dispatch,
            image.stage(),
        );
        defer record.deinit();
        self.schedule = preparation.schedule.SchedulePlanAnalysis.init(allocator);
        const output = &self.schedule.?;
        copyCounters(output, record.value.schedule);
        for (record.value.schedule.work_items, 0..) |item, index| {
            const value = try project(preparation.schedule.ScheduleWorkItem, allocator, item, refs);
            try output.work_items.append(allocator, value);
            try output.root_to_item.putNoClobber(value.root, index);
        }
    }

    fn restoreMemory(
        self: *InputJob,
        prepared: *const Prepared,
        refs: *const References,
        comptime configuration: Configuration,
    ) !void {
        const allocator = self.fixed.allocator();
        const image = try open(prepared, allocator, .memory, configuration);
        defer image.destroy();
        var record = try records.codec.decode(
            allocator,
            records.memory.Record,
            .memory,
            image.stage(),
        );
        defer record.deinit();
        self.buffers = preparation.bufferization.BufferPlanAnalysis.init(allocator);
        self.spaces = preparation.memory.MemorySpacePlanAnalysis.init(allocator);
        self.layouts = preparation.layout.LayoutPlanAnalysis.init(allocator);
        const buffers = &self.buffers.?;
        const spaces = &self.spaces.?;
        const layouts = &self.layouts.?;
        copyCounters(buffers, record.value.buffers);
        copyCounters(spaces, record.value.spaces);
        copyCounters(layouts, record.value.layouts);
        for (record.value.buffers.slots) |item| {
            const value = try project(preparation.bufferization.BufferSlot, allocator, item, refs);
            try buffers.slots.append(allocator, value);
        }
        for (record.value.bindings) |binding| {
            const value = try refs.value(binding.value);
            try buffers.value_to_slot.putNoClobber(value, binding.slot_id);
        }
        for (record.value.buffers.elisions, 0..) |item, index| {
            const value = try project(
                preparation.bufferization.FusionElision,
                allocator,
                item,
                refs,
            );
            try buffers.elisions.append(allocator, value);
            try buffers.value_to_elision.putNoClobber(value.value, index);
        }
        for (record.value.spaces.assignments, 0..) |item, index| {
            const value = try project(
                preparation.memory.MemorySpaceAssignment,
                allocator,
                item,
                refs,
            );
            try spaces.assignments.append(allocator, value);
            try spaces.slot_to_assignment.putNoClobber(value.slot_id, index);
        }
        for (record.value.layouts.assignments, 0..) |item, index| {
            const value = try project(preparation.layout.LayoutAssignment, allocator, item, refs);
            try layouts.assignments.append(allocator, value);
            try layouts.slot_to_assignment.putNoClobber(value.slot_id, index);
        }
    }

    fn restoreKernel(
        self: *InputJob,
        prepared: *const Prepared,
        refs: *const References,
        comptime configuration: Configuration,
    ) !void {
        const allocator = self.fixed.allocator();
        const image = try open(prepared, allocator, .kernel, configuration);
        defer image.destroy();
        var record = try records.codec.decode(
            allocator,
            records.kernel.Record,
            .kernel,
            image.stage(),
        );
        defer record.deinit();
        self.outlines = preparation.kernelization.product.KernelOutlinePlanAnalysis.init(allocator);
        const output = &self.outlines.?;
        copyCounters(output, record.value.outlines);
        for (record.value.outlines.kernels) |item| {
            const value = try project(
                preparation.kernelization.product.KernelOutline,
                allocator,
                item,
                refs,
            );
            try output.kernels.append(allocator, value);
            try output.work_to_kernel.putNoClobber(value.work_item_id, value.id);
        }
    }

    fn restoreTarget(self: *InputJob, comptime configuration: Configuration) !void {
        const allocator = self.fixed.allocator();
        const source = self.target.?.value;
        const context = self.context.?;
        const root = self.decoded.?.module;
        if (source.profile) |profile| {
            try preparation.setBackendTargetProfile(context, root, profile);
        }
        if (source.generated_scan_schedules) |value| {
            try root.setAttr(
                preparation.target.generated_scan_schedule_attr_name,
                try context.getStringAttr(value),
            );
        }
        if (source.generated_row_pipeline_schedules) |value| {
            try root.setAttr(
                preparation.target.generated_row_pipeline_schedule_attr_name,
                try context.getStringAttr(value),
            );
        }
        self.generated = try preparation.kernelization.KernelizationAnalysis.init(
            allocator,
            configuration.context,
        );
        const output = &self.generated.?;
        try output.reserveKernelCapacity(source.kernels.len);
        for (source.kernels, 0..) |item, index| {
            var value = try preparation.publication.restoreKernel(
                allocator,
                item.lowered,
                compilationConfiguration(configuration),
            );
            errdefer value.deinit(allocator);
            try output.work_to_kernel.putNoClobber(value.work_item_id, index);
            output.kernels.appendAssumeCapacity(value);
        }
        self.legal = preparation.backend.BackendLegalizationAnalysis.init(
            allocator,
            source.profile,
        );
        const legal = &self.legal.?;
        for (self.outlines.?.kernels.items) |outline| {
            const result = try preparation.backend.legalizeKernel(
                outline,
                &self.buffers.?,
                source.profile,
            );
            try legal.kernels.append(allocator, result);
            if (result.isLegal()) {
                legal.legal_kernel_count += 1;
                legal.total_static_bytes = try std.math.add(
                    u64,
                    legal.total_static_bytes,
                    result.static_bytes,
                );
            } else legal.illegal_kernel_count += 1;
        }
    }
};

fn open(
    prepared: *const Prepared,
    allocator: std.mem.Allocator,
    comptime stage: publication.Stage,
    comptime configuration: Configuration,
) !*choir.product.entity.Image {
    return (choir.product.operation.Product{
        .revision = prepared.stage(stage),
    }).open(allocator, configuration.image);
}

fn clearTargetAttributes(root: *ir.Operation) void {
    inline for (.{
        preparation.target.backend_kind_attr_name,
        preparation.target.artifact_format_attr_name,
        preparation.target.math_tier_attr_name,
        preparation.target.dtype_bits_attr_name,
        preparation.target.feature_bits_attr_name,
        preparation.target.generated_scan_schedule_attr_name,
        preparation.target.generated_row_pipeline_schedule_attr_name,
    }) |name| {
        _ = root.removeAttr(name);
    }
}

fn copyCounters(output: anytype, source: anytype) void {
    inline for (@typeInfo(@TypeOf(source)).@"struct".field_names) |name| {
        const T = @TypeOf(@field(source, name));
        if (@typeInfo(T) == .int) @field(output.*, name) = @field(source, name);
    }
}

const References = struct {
    allocator: std.mem.Allocator,
    operations: []*ir.Operation,

    fn init(allocator: std.mem.Allocator, root: *ir.Operation, limit: u32) !References {
        var index = try records.reference.Index.init(allocator, root, limit);
        defer index.deinit();
        const operations = try allocator.alloc(*ir.Operation, index.operations.count());
        var entries = index.operations.iterator();
        while (entries.next()) |entry| operations[entry.value_ptr.ordinal] = entry.key_ptr.*;
        return .{ .allocator = allocator, .operations = operations };
    }

    fn deinit(self: *References) void {
        self.allocator.free(self.operations);
    }

    fn operation(self: *const References, ref: records.reference.Operation) !*ir.Operation {
        if (ref.ordinal >= self.operations.len) return error.UnboundProductInput;
        return self.operations[ref.ordinal];
    }

    fn value(self: *const References, ref: records.reference.Value) !*ir.Value {
        switch (ref) {
            .result => |item| {
                const op = try self.operation(item.operation);
                if (item.position >= op.results.items.len) return error.UnboundProductInput;
                return &op.results.items[item.position];
            },
            .argument => |item| {
                const op = try self.operation(item.operation);
                if (item.region >= op.regions.items.len) return error.UnboundProductInput;
                var blocks = op.regions.items[item.region].getBlocks();
                var position: u32 = 0;
                while (blocks.next()) |block| : (position += 1) {
                    if (position != item.block) continue;
                    if (item.position >= block.arguments.items.len) {
                        return error.UnboundProductInput;
                    }
                    return block.arguments.items[item.position];
                }
                return error.UnboundProductInput;
            },
        }
    }
};

fn project(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: anytype,
    refs: *const References,
) anyerror!T {
    if (T == *ir.Operation) return refs.operation(source);
    if (T == *ir.Value) return refs.value(source);
    switch (@typeInfo(T)) {
        .optional => |info| return if (source) |value|
            try project(info.child, allocator, value, refs)
        else
            null,
        .pointer => |info| {
            if (info.size != .slice) @compileError("uncaptured artifact pointer");
            const values = try allocator.alloc(info.child, source.len);
            for (values, source) |*out, value| {
                out.* = try project(info.child, allocator, value, refs);
            }
            return values;
        },
        .@"struct" => |info| {
            var value: T = undefined;
            inline for (info.field_names, info.field_types) |name, Field| {
                @field(value, name) = try project(Field, allocator, @field(source, name), refs);
            }
            return value;
        },
        else => return source,
    }
}

fn compilationConfiguration(comptime original: Configuration) Configuration {
    var result = original;
    result.register = struct {
        fn register(context: *ir.Context) !void {
            try original.register(context);
            try choir.backends.gpu.prepareCompilationDialects(context);
        }
    }.register;
    return result;
}
