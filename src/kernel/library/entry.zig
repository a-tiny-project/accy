const std = @import("std");
const gpu = @import("gpu");
const gpu_abi = @import("gpu_abi");
const alloc_arena = @import("alloc_arena");
const choir = @import("choir");

const activation_mod = @import("../../choir/root.zig").activation;
const artifact = @import("../../artifact/model/root.zig");
const shape_mod = @import("../../choir/shape/root.zig");
const kernel = @import("../root.zig");

pub const Layer = enum {
    logical,
    authored,
};

pub const Category = enum {
    attention,
    elementwise,
    reduction,
    normalization,
    loss,
    layout,
    linalg,
    stencil,
    indexing,
    segmented,
    scan,
    sort,
    sparse,
    spatial,
    image,
    random,
    compaction,
    fused,
    model,
};

pub const ElementwiseOperator = enum {
    add,
    axpy,
    mul,
    scale,
};

pub const ReductionOperator = enum {
    sum,
    maximum,
    dot_product,
    sum_squares,
    sum_exp_shifted,
    sum_squared_difference,
    weighted_sum,
};

pub const RowNormalizationParameterization = enum {
    none,
    scale,
    scale_bias,
};

pub const RowNormalizationOperator = union(enum) {
    softmax,
    log_softmax,
    rmsnorm: RowNormalizationParameterization,
    layernorm: RowNormalizationParameterization,
};

pub const LayoutOperator = enum {
    transpose,
};

pub const LinalgOperator = enum {
    batched_matrix_product,
    matrix_product,
    matrix_vector_product,
    outer_product,
    batched_cholesky,
    batched_cholesky_solve,
    batched_inverse,
};

pub const StencilOperator = enum {
    window,
};

pub const IndexingOperator = enum {
    gather,
    scatter,
    scatter_add,
    histogram,
};

pub const SegmentedOperator = enum {
    segment_sum,
};

pub const SortOperator = enum {
    radix_ascending,
    top_k_smallest,
};

pub const SparseOperator = enum {
    coo_spmv,
    csr_spmv,
    csr_spmm,
    ell_spmv,
    sell_spmv,
};

pub const SpatialOperator = enum {
    grid_cells,
    grid_count,
    grid_neighbor_count,
};

pub const ImageOperator = enum {
    blur_pass,
    resize_bilinear,
};

pub const ScanOperator = enum {
    prefix_sum,
    prefix_sum_exclusive,
};

pub const RandomOperator = union(enum) {
    philox: u32,
    threefry: u32,
    squares,
    philox_key_split: u32,
    philox_key_uniform: u32,
    philox_key_counter_uniform: u32,
    philox_fold: u32,
    threefry_fold: u32,
    squares_fold,
};

pub const CompactionPredicate = enum {
    nonzero,
    greater_than,
};

pub const CompactionOperator = union(enum) {
    blocks: CompactionPredicate,
};

pub const AttentionOperator = enum {
    scaled_dot_product,
};

pub const LossOperator = enum {
    row_sparse_cross_entropy,
};

pub const Operation = union(enum) {
    attention: AttentionOperator,
    elementwise: ElementwiseOperator,
    activation: activation_mod.Kind,
    reduction: ReductionOperator,
    row_normalization: RowNormalizationOperator,
    loss: LossOperator,
    layout: LayoutOperator,
    linalg: LinalgOperator,
    stencil: StencilOperator,
    indexing: IndexingOperator,
    segmented: SegmentedOperator,
    scan: ScanOperator,
    sort: SortOperator,
    sparse: SparseOperator,
    spatial: SpatialOperator,
    image: ImageOperator,
    random: RandomOperator,
    compaction: CompactionOperator,
};

pub fn operationFingerprint(operation: Operation) u64 {
    var builder = choir.product.incremental.FingerprintBuilder{};
    builder.updateBytes("accy.kernel.library.operation");
    hashTagged(&builder, operation);
    return builder.finish();
}

fn hashTagged(builder: *choir.product.incremental.FingerprintBuilder, value: anytype) void {
    const Value = @TypeOf(value);
    switch (@typeInfo(Value)) {
        .@"union" => {
            builder.updateEnumTag(std.meta.activeTag(value));
            switch (value) {
                inline else => |payload| hashTagged(builder, payload),
            }
        },
        .@"enum" => builder.updateEnumTag(value),
        .int => builder.updateU64(value),
        .void => {},
        else => @compileError(
            "operation payload kind has no fingerprint rule: " ++ @typeName(Value),
        ),
    }
}

pub const Matrix2D = struct {
    rows: u64,
    cols: u64,
    threads: Threads2D = .{},
    row_axis: []const u8 = "i",
    col_axis: []const u8 = "j",
};

pub const Threads2D = struct {
    x: u32 = 16,
    y: u32 = 16,
};

pub const Threads3D = struct {
    x: u32 = 8,
    y: u32 = 4,
    z: u32 = 1,
};

pub const Axis = struct {
    name: []const u8,
    extent: u64,
};

pub const Vector1D = struct {
    extent: u64,
    threads: u32,
    axis: []const u8 = "i",
};

pub const Shape = struct {
    axes: []const Axis = &.{},

    pub fn rank(self: Shape) usize {
        return self.axes.len;
    }

    pub fn axis(self: Shape, name: []const u8) ?Axis {
        for (self.axes) |candidate| {
            if (std.mem.eql(u8, candidate.name, name)) return candidate;
        }
        return null;
    }

    pub fn elementCount(self: Shape) ?u64 {
        var count: u64 = 1;
        for (self.axes) |axis_value| {
            count = std.math.mul(u64, count, axis_value.extent) catch return null;
        }
        return count;
    }

    pub fn matchesExtents(self: Shape, extents: []const u64) bool {
        if (self.axes.len != extents.len) return false;
        for (extents, 0..) |extent, index| {
            if (self.axes[index].extent != extent) return false;
        }
        return true;
    }
};

pub const Launch = struct {
    grid: [3]u32 = .{ 1, 1, 1 },
    threadgroup: [3]u32 = .{ 1, 1, 1 },
};

pub const ScheduleBinding = struct {
    axis: []const u8,
    target: kernel.BindTarget,
    extent: u64,
};

pub const Schedule = struct {
    bindings: []const ScheduleBinding = &.{},

    pub fn launch(self: Schedule) Launch {
        var result = Launch{};
        for (self.bindings) |binding| {
            const extent: u32 = @intCast(binding.extent);
            switch (binding.target) {
                .block_x => result.grid[0] = extent,
                .block_y => result.grid[1] = extent,
                .block_z => result.grid[2] = extent,
                .thread_x => result.threadgroup[0] = extent,
                .thread_y => result.threadgroup[1] = extent,
                .thread_z => result.threadgroup[2] = extent,
            }
        }
        return result;
    }

    pub fn matchesSnapshot(self: Schedule, snapshot: *const kernel.ScheduleSnapshot) bool {
        const axes = snapshot.allAxes();
        if (self.bindings.len != axes.len) return false;
        for (self.bindings, axes) |binding, axis_value| {
            if (!std.mem.eql(u8, binding.axis, axis_value.name)) return false;
            if (axis_value.bind != binding.target) return false;
            if (axis_value.extent != binding.extent) return false;
        }
        return true;
    }
};

pub const ReductionContract = struct {
    name: []const u8,
    operator: ReductionOperator,
    extents: []const u64,
    dependencies: []const []const u8 = &.{},
};

pub const Reduction = struct {
    name: []const u8,
    operator: ReductionOperator,
    shape: Shape,
    dependencies: []const []const u8 = &.{},

    pub fn matches(self: Reduction, contract: ReductionContract) bool {
        if (!std.mem.eql(u8, self.name, contract.name)) return false;
        if (self.operator != contract.operator) return false;
        if (!self.shape.matchesExtents(contract.extents)) return false;
        if (self.dependencies.len != contract.dependencies.len) return false;
        for (contract.dependencies, 0..) |dependency, index| {
            if (!std.mem.eql(u8, self.dependencies[index], dependency)) return false;
        }
        return true;
    }
};

pub const ReductionReuseContract = struct {
    reduction: []const u8,
    extents: []const u64,
};

pub const ReductionReuse = struct {
    reduction: []const u8,
    shape: Shape,

    pub fn matches(self: ReductionReuse, contract: ReductionReuseContract) bool {
        if (!std.mem.eql(u8, self.reduction, contract.reduction)) return false;
        return self.shape.matchesExtents(contract.extents);
    }
};

pub const StaticParameter = struct {
    name: []const u8,
    value: u64,

    pub fn matches(self: StaticParameter, name: []const u8, value: u64) bool {
        return std.mem.eql(u8, self.name, name) and self.value == value;
    }
};

pub const EpilogueOperator = union(enum) {
    bias_add,
    activation: activation_mod.Kind,
};

pub const EpilogueContract = struct {
    operator: EpilogueOperator,
    input_index: ?usize = null,
    extents: []const u64 = &.{},
};

pub const EpilogueStep = struct {
    operator: EpilogueOperator,
    input_index: ?usize = null,
    shape: ?Shape = null,

    pub fn matches(self: EpilogueStep, contract: EpilogueContract) bool {
        if (!std.meta.eql(self.operator, contract.operator)) return false;
        if (self.input_index != contract.input_index) return false;
        if (contract.extents.len == 0) return true;
        const shape = self.shape orelse return false;
        return shape.matchesExtents(contract.extents);
    }
};

pub const InputTransformOperator = union(enum) {
    activation: activation_mod.Kind,
    residual_add,
};

pub const InputTransformContract = struct {
    operator: InputTransformOperator,
    input_index: usize,
    extents: []const u64 = &.{},
};

pub const InputTransform = struct {
    operator: InputTransformOperator,
    input_index: usize,
    shape: ?Shape = null,

    pub fn matches(self: InputTransform, contract: InputTransformContract) bool {
        if (!std.meta.eql(self.operator, contract.operator)) return false;
        if (self.input_index != contract.input_index) return false;
        if (contract.extents.len == 0) return true;
        const shape = self.shape orelse return false;
        return shape.matchesExtents(contract.extents);
    }
};

pub const Specialization = struct {
    dtype: ?gpu_abi.DType = null,
    accumulation_dtype: ?gpu_abi.DType = null,
    operation: ?Operation = null,
    equation: ?[]const u8 = null,
    inputs: []const Shape = &.{},
    outputs: []const Shape = &.{},
    reductions: []const Reduction = &.{},
    reduction_reuse: []const ReductionReuse = &.{},
    input_transforms: []const InputTransform = &.{},
    epilogues: []const EpilogueStep = &.{},
    static_parameters: []const StaticParameter = &.{},
    launch: ?Launch = null,
    schedule: ?Schedule = null,
    structure: ?[]const u8 = null,
    layout: ?[]const u8 = null,
    shape_family: ?*const shape_mod.Family = null,

    pub fn shapeFamilyFingerprint(self: Specialization) ?u64 {
        const family = self.shape_family orelse return null;
        return shape_mod.fingerprint(family.*);
    }

    pub fn operationIs(self: Specialization, operation: Operation) bool {
        const value = self.operation orelse return false;
        return std.meta.eql(value, operation);
    }

    pub fn structureIs(self: Specialization, structure: []const u8) bool {
        const value = self.structure orelse return false;
        return std.mem.eql(u8, value, structure);
    }

    pub fn layoutIs(self: Specialization, layout: []const u8) bool {
        const value = self.layout orelse return false;
        return std.mem.eql(u8, value, layout);
    }

    pub fn staticParameterValue(self: Specialization, name: []const u8) ?u64 {
        for (self.static_parameters) |parameter| {
            if (std.mem.eql(u8, parameter.name, name)) return parameter.value;
        }
        return null;
    }

    pub fn staticParameterMatches(self: Specialization, name: []const u8, value: u64) bool {
        const actual = self.staticParameterValue(name) orelse return false;
        return actual == value;
    }

    pub fn scheduleMatchesLaunch(self: Specialization) bool {
        const schedule = self.schedule orelse return false;
        const launch = self.launch orelse return false;
        return std.meta.eql(launch, schedule.launch());
    }

    pub fn inputHasExtents(self: Specialization, index: usize, extents: []const u64) bool {
        if (index >= self.inputs.len) return false;
        return self.inputs[index].matchesExtents(extents);
    }

    pub fn outputHasExtents(self: Specialization, index: usize, extents: []const u64) bool {
        if (index >= self.outputs.len) return false;
        return self.outputs[index].matchesExtents(extents);
    }

    pub fn reductionMatches(self: Specialization, index: usize, contract: ReductionContract) bool {
        if (index >= self.reductions.len) return false;
        return self.reductions[index].matches(contract);
    }

    pub fn reductionReuseMatches(
        self: Specialization,
        index: usize,
        contract: ReductionReuseContract,
    ) bool {
        if (index >= self.reduction_reuse.len) return false;
        return self.reduction_reuse[index].matches(contract);
    }

    pub fn reductionDependenciesAreValid(self: Specialization) bool {
        for (self.reductions, 0..) |reduction_value, index| {
            if (reduction_value.name.len == 0) return false;
            if (reductionNameExists(self.reductions[0..index], reduction_value.name)) return false;
            for (reduction_value.dependencies) |dependency| {
                if (dependency.len == 0) return false;
                if (!reductionNameExists(self.reductions[0..index], dependency)) return false;
            }
        }
        return true;
    }

    pub fn reductionReuseScopesAreValid(self: Specialization) bool {
        for (self.reduction_reuse, 0..) |reuse, index| {
            if (reuse.reduction.len == 0) return false;
            if (!reductionNameExists(self.reductions, reuse.reduction)) return false;
            if (reductionReuseExists(self.reduction_reuse[0..index], reuse.reduction)) return false;
            if (reuse.shape.elementCount() == null) return false;
        }
        return true;
    }

    pub fn staticParametersAreValid(self: Specialization) bool {
        for (self.static_parameters, 0..) |parameter, index| {
            if (parameter.name.len == 0) return false;
            if (staticParameterNameExists(self.static_parameters[0..index], parameter.name)) {
                return false;
            }
        }
        return true;
    }

    pub fn inputTransformMatches(
        self: Specialization,
        index: usize,
        contract: InputTransformContract,
    ) bool {
        if (index >= self.input_transforms.len) return false;
        return self.input_transforms[index].matches(contract);
    }

    pub fn epilogueMatches(self: Specialization, index: usize, contract: EpilogueContract) bool {
        if (index >= self.epilogues.len) return false;
        return self.epilogues[index].matches(contract);
    }

    pub fn outputElementCount(self: Specialization) ?u64 {
        if (self.outputs.len == 0) return null;
        var count: u64 = 0;
        for (self.outputs) |shape| {
            count = saturatedAdd(count, shape.elementCount() orelse return null);
        }
        return count;
    }

    pub fn estimatedElementOps(self: Specialization) ?u64 {
        const output_count = self.outputElementCount() orelse return null;
        if (self.reductions.len == 0) return output_count;
        var total: u64 = 0;
        for (self.reductions) |reduction_value| {
            const reduction_count = reduction_value.shape.elementCount() orelse return null;
            const result_count = self.reductionResultCount(
                reduction_value.name,
                output_count,
            ) orelse return null;
            total = saturatedAdd(
                total,
                saturatedMul(
                    saturatedMul(result_count, reduction_count),
                    reductionOperatorWeight(reduction_value.operator),
                ),
            );
        }
        return total;
    }

    fn reductionResultCount(self: Specialization, name: []const u8, default_count: u64) ?u64 {
        for (self.reduction_reuse) |reuse| {
            if (std.mem.eql(u8, reuse.reduction, name)) return reuse.shape.elementCount();
        }
        return default_count;
    }
};

fn reductionNameExists(reductions: []const Reduction, name: []const u8) bool {
    for (reductions) |reduction_value| {
        if (std.mem.eql(u8, reduction_value.name, name)) return true;
    }
    return false;
}

fn reductionReuseExists(reuses: []const ReductionReuse, reduction_name: []const u8) bool {
    for (reuses) |reuse| {
        if (std.mem.eql(u8, reuse.reduction, reduction_name)) return true;
    }
    return false;
}

fn staticParameterNameExists(parameters: []const StaticParameter, name: []const u8) bool {
    for (parameters) |parameter| {
        if (std.mem.eql(u8, parameter.name, name)) return true;
    }
    return false;
}

fn reductionOperatorWeight(operator: ReductionOperator) u64 {
    return switch (operator) {
        .dot_product => 2,
        .sum,
        .maximum,
        .sum_squares,
        .sum_exp_shifted,
        .sum_squared_difference,
        => 1,
        .weighted_sum => 2,
    };
}

fn saturatedAdd(lhs: u64, rhs: u64) u64 {
    return std.math.add(u64, lhs, rhs) catch std.math.maxInt(u64);
}

fn saturatedMul(lhs: u64, rhs: u64) u64 {
    return std.math.mul(u64, lhs, rhs) catch std.math.maxInt(u64);
}

pub const Metadata = struct {
    target: []const u8,
    version: u32 = 1,
    layer: Layer,
    category: Category,
    specialization: Specialization = .{},
};

pub const OwnedSpecialization = struct {
    backing_allocator: std.mem.Allocator,
    arena: alloc_arena.Arena,
    value: Specialization = .{},
    shape_family: ?*shape_mod.Family = null,

    pub fn init(backing_allocator: std.mem.Allocator) OwnedSpecialization {
        return .{
            .backing_allocator = backing_allocator,
            .arena = alloc_arena.Arena.init(backing_allocator),
        };
    }

    pub fn allocator(self: *OwnedSpecialization) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *OwnedSpecialization) void {
        self.clearShapeFamily();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn takeShapeFamily(self: *OwnedSpecialization, family: *shape_mod.Family) !void {
        const owned = try self.backing_allocator.create(shape_mod.Family);
        owned.* = family.*;
        family.* = undefined;
        self.clearShapeFamily();
        self.shape_family = owned;
        self.value.shape_family = owned;
    }

    fn clearShapeFamily(self: *OwnedSpecialization) void {
        if (self.shape_family) |family| {
            var mutable = family;
            mutable.deinit();
            self.backing_allocator.destroy(mutable);
            self.shape_family = null;
            self.value.shape_family = null;
        }
    }
};

pub fn shape1D(comptime axis_name: []const u8, comptime extent: u64) Shape {
    if (extent == 0) @compileError("kernel library 1D shape extent must be nonzero");
    return .{ .axes = &.{.{ .name = axis_name, .extent = extent }} };
}

pub fn runtimeShape1D(
    lifetime_allocator: std.mem.Allocator,
    axis_name: []const u8,
    extent: u64,
) !Shape {
    if (extent == 0) return error.KernelLibraryShapeExtentMustBeNonzero;
    const axes = try lifetime_allocator.alloc(Axis, 1);
    axes[0] = try runtimeAxis(lifetime_allocator, axis_name, extent);
    return .{ .axes = axes };
}

pub fn shapeScalar() Shape {
    return .{ .axes = &.{} };
}

pub fn runtimeShapeScalar() Shape {
    return .{ .axes = &.{} };
}

pub fn shape2D(
    comptime outer_name: []const u8,
    comptime outer_extent: u64,
    comptime inner_name: []const u8,
    comptime inner_extent: u64,
) Shape {
    if (outer_extent == 0) @compileError("kernel library 2D outer extent must be nonzero");
    if (inner_extent == 0) @compileError("kernel library 2D inner extent must be nonzero");
    return .{ .axes = &.{
        .{ .name = outer_name, .extent = outer_extent },
        .{ .name = inner_name, .extent = inner_extent },
    } };
}

pub fn runtimeShape2D(
    lifetime_allocator: std.mem.Allocator,
    outer_name: []const u8,
    outer_extent: u64,
    inner_name: []const u8,
    inner_extent: u64,
) !Shape {
    if (outer_extent == 0 or inner_extent == 0) return error.KernelLibraryShapeExtentMustBeNonzero;
    const axes = try lifetime_allocator.alloc(Axis, 2);
    axes[0] = try runtimeAxis(lifetime_allocator, outer_name, outer_extent);
    axes[1] = try runtimeAxis(lifetime_allocator, inner_name, inner_extent);
    return .{ .axes = axes };
}

pub fn shape3D(
    comptime outer_name: []const u8,
    comptime outer_extent: u64,
    comptime middle_name: []const u8,
    comptime middle_extent: u64,
    comptime inner_name: []const u8,
    comptime inner_extent: u64,
) Shape {
    if (outer_extent == 0) @compileError("kernel library 3D outer extent must be nonzero");
    if (middle_extent == 0) @compileError("kernel library 3D middle extent must be nonzero");
    if (inner_extent == 0) @compileError("kernel library 3D inner extent must be nonzero");
    return .{ .axes = &.{
        .{ .name = outer_name, .extent = outer_extent },
        .{ .name = middle_name, .extent = middle_extent },
        .{ .name = inner_name, .extent = inner_extent },
    } };
}

pub fn runtimeShape3D(
    lifetime_allocator: std.mem.Allocator,
    outer_name: []const u8,
    outer_extent: u64,
    middle_name: []const u8,
    middle_extent: u64,
    inner_name: []const u8,
    inner_extent: u64,
) !Shape {
    if (outer_extent == 0 or middle_extent == 0 or inner_extent == 0) {
        return error.KernelLibraryShapeExtentMustBeNonzero;
    }
    const axes = try lifetime_allocator.alloc(Axis, 3);
    axes[0] = try runtimeAxis(lifetime_allocator, outer_name, outer_extent);
    axes[1] = try runtimeAxis(lifetime_allocator, middle_name, middle_extent);
    axes[2] = try runtimeAxis(lifetime_allocator, inner_name, inner_extent);
    return .{ .axes = axes };
}

fn runtimeAxis(lifetime_allocator: std.mem.Allocator, name: []const u8, extent: u64) !Axis {
    if (name.len == 0) return error.KernelLibraryAxisNameMustBeNonempty;
    return .{
        .name = try lifetime_allocator.dupe(u8, name),
        .extent = extent,
    };
}

pub fn reduction(
    comptime name: []const u8,
    comptime operator: ReductionOperator,
    shape: Shape,
) Reduction {
    return .{
        .name = name,
        .operator = operator,
        .shape = shape,
    };
}

pub fn runtimeReduction(
    lifetime_allocator: std.mem.Allocator,
    name: []const u8,
    operator: ReductionOperator,
    shape: Shape,
) !Reduction {
    return runtimeDependentReduction(lifetime_allocator, name, operator, shape, &.{});
}

pub fn dependentReduction(
    comptime name: []const u8,
    comptime operator: ReductionOperator,
    shape: Shape,
    comptime dependencies: []const []const u8,
) Reduction {
    return .{
        .name = name,
        .operator = operator,
        .shape = shape,
        .dependencies = dependencies,
    };
}

pub fn runtimeDependentReduction(
    lifetime_allocator: std.mem.Allocator,
    name: []const u8,
    operator: ReductionOperator,
    shape: Shape,
    dependencies: []const []const u8,
) !Reduction {
    if (name.len == 0) return error.KernelLibraryReductionNameMustBeNonempty;
    const owned_dependencies = try lifetime_allocator.alloc([]const u8, dependencies.len);
    for (dependencies, 0..) |dependency, index| {
        if (dependency.len == 0) return error.KernelLibraryReductionDependencyMustBeNonempty;
        owned_dependencies[index] = try lifetime_allocator.dupe(u8, dependency);
    }
    return .{
        .name = try lifetime_allocator.dupe(u8, name),
        .operator = operator,
        .shape = shape,
        .dependencies = owned_dependencies,
    };
}

pub fn reductionReuse(comptime reduction_name: []const u8, shape: Shape) ReductionReuse {
    return .{
        .reduction = reduction_name,
        .shape = shape,
    };
}

pub fn runtimeReductionReuse(
    lifetime_allocator: std.mem.Allocator,
    reduction_name: []const u8,
    shape: Shape,
) !ReductionReuse {
    if (reduction_name.len == 0) return error.KernelLibraryReductionReuseReductionMustBeNonempty;
    return .{
        .reduction = try lifetime_allocator.dupe(u8, reduction_name),
        .shape = shape,
    };
}

pub fn staticParameter(comptime name: []const u8, comptime value: u64) StaticParameter {
    if (name.len == 0) @compileError("kernel library static parameter name must be nonempty");
    return .{ .name = name, .value = value };
}

pub fn runtimeStaticParameter(
    lifetime_allocator: std.mem.Allocator,
    name: []const u8,
    value: u64,
) !StaticParameter {
    if (name.len == 0) return error.KernelLibraryStaticParameterNameMustBeNonempty;
    return .{
        .name = try lifetime_allocator.dupe(u8, name),
        .value = value,
    };
}

pub fn epilogue(comptime operator: EpilogueOperator) EpilogueStep {
    return .{ .operator = operator };
}

pub fn inputEpilogue(
    comptime operator: EpilogueOperator,
    comptime input_index: usize,
    shape: Shape,
) EpilogueStep {
    return .{
        .operator = operator,
        .input_index = input_index,
        .shape = shape,
    };
}

pub fn inputTransform(
    comptime operator: InputTransformOperator,
    comptime input_index: usize,
    shape: Shape,
) InputTransform {
    return .{
        .operator = operator,
        .input_index = input_index,
        .shape = shape,
    };
}

pub fn grid1D(comptime extent: u64, comptime threads: u32) u32 {
    if (extent == 0) @compileError("kernel library 1D extent must be nonzero");
    if (threads == 0) @compileError("kernel library 1D threadgroup must be nonzero");
    const thread_count: u64 = threads;
    if (extent > std.math.maxInt(u64) - (thread_count - 1)) {
        @compileError("kernel library 1D launch extent overflow");
    }
    const biased = extent + thread_count - 1;
    const blocks = biased / thread_count;
    if (blocks > std.math.maxInt(u32)) {
        @compileError("kernel library 1D grid overflow");
    }
    return @intCast(blocks);
}

pub fn runtimeGrid1D(extent: u64, threads: u32) !u32 {
    if (extent == 0) return error.KernelLibraryLaunchExtentMustBeNonzero;
    if (threads == 0) return error.KernelLibraryLaunchThreadgroupMustBeNonzero;
    const thread_count: u64 = threads;
    const biased = std.math.add(u64, extent, thread_count -
        1) catch return error.KernelLibraryLaunchGridOverflow;
    const blocks = biased / thread_count;
    return std.math.cast(u32, blocks) orelse error.KernelLibraryLaunchGridOverflow;
}

pub fn launch1D(comptime extent: u64, comptime threads: u32) Launch {
    return .{
        .grid = .{ grid1D(extent, threads), 1, 1 },
        .threadgroup = .{ threads, 1, 1 },
    };
}

pub fn runtimeLaunch1D(extent: u64, threads: u32) !Launch {
    return .{
        .grid = .{ try runtimeGrid1D(extent, threads), 1, 1 },
        .threadgroup = .{ threads, 1, 1 },
    };
}

pub fn launch2D(
    comptime x_extent: u64,
    comptime y_extent: u64,
    comptime x_threads: u32,
    comptime y_threads: u32,
) Launch {
    return .{
        .grid = .{ grid1D(x_extent, x_threads), grid1D(y_extent, y_threads), 1 },
        .threadgroup = .{ x_threads, y_threads, 1 },
    };
}

pub fn runtimeLaunch2D(
    x_extent: u64,
    y_extent: u64,
    x_threads: u32,
    y_threads: u32,
) !Launch {
    return .{
        .grid = .{
            try runtimeGrid1D(x_extent, x_threads),
            try runtimeGrid1D(y_extent, y_threads),
            1,
        },
        .threadgroup = .{ x_threads, y_threads, 1 },
    };
}

pub fn launch3D(
    comptime x_extent: u64,
    comptime y_extent: u64,
    comptime z_extent: u64,
    comptime x_threads: u32,
    comptime y_threads: u32,
    comptime z_threads: u32,
) Launch {
    return .{
        .grid = .{
            grid1D(x_extent, x_threads),
            grid1D(y_extent, y_threads),
            grid1D(z_extent, z_threads),
        },
        .threadgroup = .{ x_threads, y_threads, z_threads },
    };
}

pub fn runtimeLaunch3D(
    x_extent: u64,
    y_extent: u64,
    z_extent: u64,
    x_threads: u32,
    y_threads: u32,
    z_threads: u32,
) !Launch {
    return .{
        .grid = .{
            try runtimeGrid1D(x_extent, x_threads),
            try runtimeGrid1D(y_extent, y_threads),
            try runtimeGrid1D(z_extent, z_threads),
        },
        .threadgroup = .{ x_threads, y_threads, z_threads },
    };
}

pub fn threadBlocks1D(
    comptime axis_name: []const u8,
    comptime extent: u64,
    comptime threads: u32,
) Schedule {
    if (extent == 0) @compileError("kernel library 1D schedule extent must be nonzero");
    if (threads == 0) @compileError("kernel library 1D schedule threadgroup must be nonzero");
    if (extent <= threads) {
        return .{ .bindings = &.{.{
            .axis = axis_name,
            .target = .thread_x,
            .extent = extent,
        }} };
    }
    return .{ .bindings = &.{
        .{
            .axis = std.fmt.comptimePrint("{s}_tile", .{axis_name}),
            .target = .block_x,
            .extent = @intCast(grid1D(extent, threads)),
        },
        .{
            .axis = std.fmt.comptimePrint("{s}_lane", .{axis_name}),
            .target = .thread_x,
            .extent = threads,
        },
    } };
}

pub fn runtimeThreadBlocks1D(
    lifetime_allocator: std.mem.Allocator,
    axis_name: []const u8,
    extent: u64,
    threads: u32,
) !Schedule {
    if (extent == 0) return error.KernelLibraryScheduleExtentMustBeNonzero;
    if (threads == 0) return error.KernelLibraryScheduleThreadgroupMustBeNonzero;
    const bindings = try lifetime_allocator.alloc(ScheduleBinding, if (extent <= threads) 1 else 2);
    if (extent <= threads) {
        bindings[0] = try runtimeThreadBlockAxisBinding(
            lifetime_allocator,
            axis_name,
            .thread_x,
            extent,
        );
    } else {
        bindings[0] = try runtimeThreadBlockTileBinding(
            lifetime_allocator,
            axis_name,
            extent,
            threads,
            .block_x,
        );
        bindings[1] = try runtimeThreadBlockLaneBinding(
            lifetime_allocator,
            axis_name,
            threads,
            .thread_x,
        );
    }
    return .{ .bindings = bindings };
}

pub fn threadBlocks2D(
    comptime x_axis: []const u8,
    comptime x_extent: u64,
    comptime y_axis: []const u8,
    comptime y_extent: u64,
    comptime x_threads: u32,
    comptime y_threads: u32,
) Schedule {
    if (x_extent == 0 or y_extent == 0) {
        @compileError("kernel library 2D schedule extents must be nonzero");
    }
    if (x_threads == 0 or y_threads == 0) {
        @compileError("kernel library 2D schedule threadgroups must be nonzero");
    }

    const x_tiled = x_extent > x_threads;
    const y_tiled = y_extent > y_threads;
    if (x_tiled and y_tiled) {
        return .{ .bindings = &.{
            threadBlockTileBinding(x_axis, x_extent, x_threads, .block_x),
            threadBlockLaneBinding(x_axis, x_threads, .thread_x),
            threadBlockTileBinding(y_axis, y_extent, y_threads, .block_y),
            threadBlockLaneBinding(y_axis, y_threads, .thread_y),
        } };
    }
    if (x_tiled) {
        return .{ .bindings = &.{
            threadBlockTileBinding(x_axis, x_extent, x_threads, .block_x),
            threadBlockLaneBinding(x_axis, x_threads, .thread_x),
            .{ .axis = y_axis, .target = .thread_y, .extent = y_extent },
        } };
    }
    if (y_tiled) {
        return .{ .bindings = &.{
            .{ .axis = x_axis, .target = .thread_x, .extent = x_extent },
            threadBlockTileBinding(y_axis, y_extent, y_threads, .block_y),
            threadBlockLaneBinding(y_axis, y_threads, .thread_y),
        } };
    }
    return .{ .bindings = &.{
        .{ .axis = x_axis, .target = .thread_x, .extent = x_extent },
        .{ .axis = y_axis, .target = .thread_y, .extent = y_extent },
    } };
}

pub fn runtimeThreadBlocks2D(
    lifetime_allocator: std.mem.Allocator,
    x_axis: []const u8,
    x_extent: u64,
    y_axis: []const u8,
    y_extent: u64,
    x_threads: u32,
    y_threads: u32,
) !Schedule {
    if (x_extent == 0 or y_extent == 0) return error.KernelLibraryScheduleExtentMustBeNonzero;
    if (x_threads == 0 or y_threads == 0) {
        return error.KernelLibraryScheduleThreadgroupMustBeNonzero;
    }

    const x_tiled = x_extent > x_threads;
    const y_tiled = y_extent > y_threads;
    const count: usize = @as(usize, if (x_tiled) 2 else 1) + @as(usize, if (y_tiled) 2 else 1);
    const bindings = try lifetime_allocator.alloc(ScheduleBinding, count);
    var index: usize = 0;
    if (x_tiled) {
        bindings[index] = try runtimeThreadBlockTileBinding(
            lifetime_allocator,
            x_axis,
            x_extent,
            x_threads,
            .block_x,
        );
        index += 1;
        bindings[index] = try runtimeThreadBlockLaneBinding(
            lifetime_allocator,
            x_axis,
            x_threads,
            .thread_x,
        );
        index += 1;
    } else {
        bindings[index] = try runtimeThreadBlockAxisBinding(
            lifetime_allocator,
            x_axis,
            .thread_x,
            x_extent,
        );
        index += 1;
    }
    if (y_tiled) {
        bindings[index] = try runtimeThreadBlockTileBinding(
            lifetime_allocator,
            y_axis,
            y_extent,
            y_threads,
            .block_y,
        );
        index += 1;
        bindings[index] = try runtimeThreadBlockLaneBinding(
            lifetime_allocator,
            y_axis,
            y_threads,
            .thread_y,
        );
    } else {
        bindings[index] = try runtimeThreadBlockAxisBinding(
            lifetime_allocator,
            y_axis,
            .thread_y,
            y_extent,
        );
    }
    return .{ .bindings = bindings };
}

pub fn threadBlocks3D(
    comptime x_axis: []const u8,
    comptime x_extent: u64,
    comptime y_axis: []const u8,
    comptime y_extent: u64,
    comptime z_axis: []const u8,
    comptime z_extent: u64,
    comptime x_threads: u32,
    comptime y_threads: u32,
    comptime z_threads: u32,
) Schedule {
    if (x_extent == 0 or y_extent == 0 or z_extent == 0) {
        @compileError("kernel library 3D schedule extents must be nonzero");
    }
    if (x_threads == 0 or y_threads == 0 or z_threads == 0) {
        @compileError("kernel library 3D schedule threadgroups must be nonzero");
    }

    const x_tiled = x_extent > x_threads;
    const y_tiled = y_extent > y_threads;
    const z_tiled = z_extent > z_threads;
    if (x_tiled and y_tiled and z_tiled) {
        return .{ .bindings = &.{
            threadBlockTileBinding(x_axis, x_extent, x_threads, .block_x),
            threadBlockLaneBinding(x_axis, x_threads, .thread_x),
            threadBlockTileBinding(y_axis, y_extent, y_threads, .block_y),
            threadBlockLaneBinding(y_axis, y_threads, .thread_y),
            threadBlockTileBinding(z_axis, z_extent, z_threads, .block_z),
            threadBlockLaneBinding(z_axis, z_threads, .thread_z),
        } };
    }
    if (x_tiled and y_tiled) {
        return .{ .bindings = &.{
            threadBlockTileBinding(x_axis, x_extent, x_threads, .block_x),
            threadBlockLaneBinding(x_axis, x_threads, .thread_x),
            threadBlockTileBinding(y_axis, y_extent, y_threads, .block_y),
            threadBlockLaneBinding(y_axis, y_threads, .thread_y),
            .{ .axis = z_axis, .target = .thread_z, .extent = z_extent },
        } };
    }
    if (x_tiled and z_tiled) {
        return .{ .bindings = &.{
            threadBlockTileBinding(x_axis, x_extent, x_threads, .block_x),
            threadBlockLaneBinding(x_axis, x_threads, .thread_x),
            .{ .axis = y_axis, .target = .thread_y, .extent = y_extent },
            threadBlockTileBinding(z_axis, z_extent, z_threads, .block_z),
            threadBlockLaneBinding(z_axis, z_threads, .thread_z),
        } };
    }
    if (y_tiled and z_tiled) {
        return .{ .bindings = &.{
            .{ .axis = x_axis, .target = .thread_x, .extent = x_extent },
            threadBlockTileBinding(y_axis, y_extent, y_threads, .block_y),
            threadBlockLaneBinding(y_axis, y_threads, .thread_y),
            threadBlockTileBinding(z_axis, z_extent, z_threads, .block_z),
            threadBlockLaneBinding(z_axis, z_threads, .thread_z),
        } };
    }
    if (x_tiled) {
        return .{ .bindings = &.{
            threadBlockTileBinding(x_axis, x_extent, x_threads, .block_x),
            threadBlockLaneBinding(x_axis, x_threads, .thread_x),
            .{ .axis = y_axis, .target = .thread_y, .extent = y_extent },
            .{ .axis = z_axis, .target = .thread_z, .extent = z_extent },
        } };
    }
    if (y_tiled) {
        return .{ .bindings = &.{
            .{ .axis = x_axis, .target = .thread_x, .extent = x_extent },
            threadBlockTileBinding(y_axis, y_extent, y_threads, .block_y),
            threadBlockLaneBinding(y_axis, y_threads, .thread_y),
            .{ .axis = z_axis, .target = .thread_z, .extent = z_extent },
        } };
    }
    if (z_tiled) {
        return .{ .bindings = &.{
            .{ .axis = x_axis, .target = .thread_x, .extent = x_extent },
            .{ .axis = y_axis, .target = .thread_y, .extent = y_extent },
            threadBlockTileBinding(z_axis, z_extent, z_threads, .block_z),
            threadBlockLaneBinding(z_axis, z_threads, .thread_z),
        } };
    }
    return .{ .bindings = &.{
        .{ .axis = x_axis, .target = .thread_x, .extent = x_extent },
        .{ .axis = y_axis, .target = .thread_y, .extent = y_extent },
        .{ .axis = z_axis, .target = .thread_z, .extent = z_extent },
    } };
}

pub fn runtimeThreadBlocks3D(
    lifetime_allocator: std.mem.Allocator,
    x_axis: []const u8,
    x_extent: u64,
    y_axis: []const u8,
    y_extent: u64,
    z_axis: []const u8,
    z_extent: u64,
    x_threads: u32,
    y_threads: u32,
    z_threads: u32,
) !Schedule {
    if (x_extent == 0 or y_extent == 0 or z_extent == 0) {
        return error.KernelLibraryScheduleExtentMustBeNonzero;
    }
    if (x_threads == 0 or y_threads == 0 or z_threads == 0) {
        return error.KernelLibraryScheduleThreadgroupMustBeNonzero;
    }

    const x_tiled = x_extent > x_threads;
    const y_tiled = y_extent > y_threads;
    const z_tiled = z_extent > z_threads;
    const count: usize = @as(usize, if (x_tiled)
        2
    else
        1) + @as(usize, if (y_tiled) 2 else 1) + @as(usize, if (z_tiled) 2 else 1);
    const bindings = try lifetime_allocator.alloc(ScheduleBinding, count);
    var index: usize = 0;
    if (x_tiled) {
        bindings[index] = try runtimeThreadBlockTileBinding(
            lifetime_allocator,
            x_axis,
            x_extent,
            x_threads,
            .block_x,
        );
        index += 1;
        bindings[index] = try runtimeThreadBlockLaneBinding(
            lifetime_allocator,
            x_axis,
            x_threads,
            .thread_x,
        );
        index += 1;
    } else {
        bindings[index] = try runtimeThreadBlockAxisBinding(
            lifetime_allocator,
            x_axis,
            .thread_x,
            x_extent,
        );
        index += 1;
    }
    if (y_tiled) {
        bindings[index] = try runtimeThreadBlockTileBinding(
            lifetime_allocator,
            y_axis,
            y_extent,
            y_threads,
            .block_y,
        );
        index += 1;
        bindings[index] = try runtimeThreadBlockLaneBinding(
            lifetime_allocator,
            y_axis,
            y_threads,
            .thread_y,
        );
        index += 1;
    } else {
        bindings[index] = try runtimeThreadBlockAxisBinding(
            lifetime_allocator,
            y_axis,
            .thread_y,
            y_extent,
        );
        index += 1;
    }
    if (z_tiled) {
        bindings[index] = try runtimeThreadBlockTileBinding(
            lifetime_allocator,
            z_axis,
            z_extent,
            z_threads,
            .block_z,
        );
        index += 1;
        bindings[index] = try runtimeThreadBlockLaneBinding(
            lifetime_allocator,
            z_axis,
            z_threads,
            .thread_z,
        );
    } else {
        bindings[index] = try runtimeThreadBlockAxisBinding(
            lifetime_allocator,
            z_axis,
            .thread_z,
            z_extent,
        );
    }
    return .{ .bindings = bindings };
}

fn threadBlockTileBinding(
    comptime axis_name: []const u8,
    comptime extent: u64,
    comptime threads: u32,
    comptime target: kernel.BindTarget,
) ScheduleBinding {
    return .{
        .axis = std.fmt.comptimePrint("{s}_tile", .{axis_name}),
        .target = target,
        .extent = @intCast(grid1D(extent, threads)),
    };
}

fn runtimeThreadBlockAxisBinding(
    lifetime_allocator: std.mem.Allocator,
    axis_name: []const u8,
    target: kernel.BindTarget,
    extent: u64,
) !ScheduleBinding {
    if (axis_name.len == 0) return error.KernelLibraryAxisNameMustBeNonempty;
    return .{
        .axis = try lifetime_allocator.dupe(u8, axis_name),
        .target = target,
        .extent = extent,
    };
}

fn runtimeThreadBlockTileBinding(
    lifetime_allocator: std.mem.Allocator,
    axis_name: []const u8,
    extent: u64,
    threads: u32,
    target: kernel.BindTarget,
) !ScheduleBinding {
    if (axis_name.len == 0) return error.KernelLibraryAxisNameMustBeNonempty;
    return .{
        .axis = try std.fmt.allocPrint(lifetime_allocator, "{s}_tile", .{axis_name}),
        .target = target,
        .extent = try runtimeGrid1D(extent, threads),
    };
}

fn threadBlockLaneBinding(
    comptime axis_name: []const u8,
    comptime threads: u32,
    comptime target: kernel.BindTarget,
) ScheduleBinding {
    return .{
        .axis = std.fmt.comptimePrint("{s}_lane", .{axis_name}),
        .target = target,
        .extent = threads,
    };
}

fn runtimeThreadBlockLaneBinding(
    lifetime_allocator: std.mem.Allocator,
    axis_name: []const u8,
    threads: u32,
    target: kernel.BindTarget,
) !ScheduleBinding {
    if (axis_name.len == 0) return error.KernelLibraryAxisNameMustBeNonempty;
    return .{
        .axis = try std.fmt.allocPrint(lifetime_allocator, "{s}_lane", .{axis_name}),
        .target = target,
        .extent = threads,
    };
}

pub const ArtifactOptions = struct {
    limits: kernel.Limits,
    format: ?gpu.ArtifactFormat = null,
    kernel_plan: kernel.PlanOptions = .{},
    element_count_argument: artifact.ElementCountArgument = .none,
    shape_family_fingerprint: ?u64 = null,
    shape_profile: ?artifact.KernelCallShapeProfile = null,
    launch: ?artifact.KernelCallLaunch = null,
    runtime_scalar_argument_count: u32 = 0,
    static_arguments: []const gpu_abi.ScalarArgument = &.{},
};

pub fn Entry(comptime ProgramType: type, comptime entry_metadata: Metadata) type {
    return struct {
        pub const Program: type = ProgramType;
        pub const metadata = entry_metadata;
        pub const name = ProgramType.name;
        pub const target = entry_metadata.target;
        pub const version = entry_metadata.version;
        pub const layer = entry_metadata.layer;
        pub const category = entry_metadata.category;
        pub const specialization = entry_metadata.specialization;
        pub const Limits: type = ProgramType.Limits;
        pub const arg = ProgramType.arg;
        pub const schema = ProgramType.schema;
        pub const build = ProgramType.build;
        pub const interpret = ProgramType.interpret;
        pub const launch = ProgramType.launch;
        pub const scheduleSnapshot = ProgramType.scheduleSnapshot;
        pub const createPlan = ProgramType.createPlan;
        pub const createCheckedPlan = ProgramType.createCheckedPlan;
        pub const compileFragment = ProgramType.compileFragment;
        pub const createKernelArtifact = ProgramType.createKernelArtifact;
        pub const runCpu = ProgramType.runCpu;
        pub const runCpuWithDiagnostic = ProgramType.runCpuWithDiagnostic;
        pub const verify = ProgramType.verify;

        pub fn createKernelCallArtifact(
            allocator: std.mem.Allocator,
            handle: kernel.BackendHandle,
            options: ArtifactOptions,
        ) !kernel.OwnedKernelCallArtifact {
            return ProgramType.createKernelCallArtifact(allocator, options.limits, handle, .{
                .target = entry_metadata.target,
                .version = entry_metadata.version,
                .format = options.format,
                .kernel_plan = options.kernel_plan,
                .element_count_argument = options.element_count_argument,
                .shape_family_fingerprint = options.shape_family_fingerprint orelse
                    entry_metadata.specialization.shapeFamilyFingerprint(),
                .shape_profile = options.shape_profile,
                .launch = options.launch,
                .runtime_scalar_argument_count = options.runtime_scalar_argument_count,
                .static_arguments = options.static_arguments,
            });
        }
    };
}

fn entry_test_copy_body_each(inner: anytype, index: kernel.Index1D, each_args: anytype) !void {
    const value = try each_args.param(.src).load(inner, index);
    try each_args.param(.dst).store(inner, value, index);
}

fn entryTestCopyBody(k: anytype, args: anytype) !void {
    _ = try k.forEach1D("i", 2, args, entry_test_copy_body_each);
}
