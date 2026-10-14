const std = @import("std");

const library = @import("../../root.zig");
const model = @import("model.zig");
const shape = @import("shape.zig");

const entry = library.entry;
const Histogram = model.Histogram;
const HistogramBinningPolicy = model.HistogramBinningPolicy;
const HistogramVariant = model.HistogramVariant;

pub fn histogramFamilySpecialization(
    backing_allocator: std.mem.Allocator,
    instance: Histogram,
) !entry.OwnedSpecialization {
    var owned = entry.OwnedSpecialization.init(backing_allocator);
    errdefer owned.deinit();
    const lifetime_allocator = owned.allocator();

    const inputs = try lifetime_allocator.alloc(entry.Shape, 1);
    inputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.element_axis, instance.count);

    const outputs = try lifetime_allocator.alloc(entry.Shape, 1);
    outputs[0] = try entry.runtimeShape1D(lifetime_allocator, instance.bin_axis, instance.bins);

    const static_parameters = try lifetime_allocator.alloc(entry.StaticParameter, 1);
    static_parameters[0] = try entry.runtimeStaticParameter(
        lifetime_allocator,
        model.histogram_binning_policy_parameter,
        model.histogramBinningPolicyCode(instance.binning),
    );

    owned.value = .{
        .dtype = instance.dtype,
        .operation = .{ .indexing = .histogram },
        .inputs = inputs,
        .outputs = outputs,
        .static_parameters = static_parameters,
        .schedule = try entry.runtimeThreadBlocks1D(
            lifetime_allocator,
            instance.element_axis,
            instance.count,
            instance.threads,
        ),
        .structure = @tagName(instance.variant),
    };
    owned.value.launch = owned.value.schedule.?.launch();
    var family = try shape.histogramShapeFamily(backing_allocator, instance);
    errdefer family.deinit();
    try owned.takeShapeFamily(&family);
    return owned;
}

pub fn histogramInstanceFromSpecialization(specialization: entry.Specialization) ?Histogram {
    if (!specialization.scheduleMatchesLaunch()) return null;
    if (!specialization.operationIs(.{ .indexing = .histogram })) return null;
    const dtype = specialization.dtype orelse return null;
    if (!model.histogramDTypeSupported(dtype)) return null;
    if (specialization.inputs.len != 1 or specialization.outputs.len != 1) return null;
    if (specialization.reductions.len != 0) return null;
    if (specialization.static_parameters.len != 1) return null;
    const binning = model.histogramBinningPolicyFromCode(
        specialization.staticParameterValue(
            model.histogram_binning_policy_parameter,
        ) orelse return null,
    ) orelse return null;
    const data = specialization.inputs[0];
    const bins_shape = specialization.outputs[0];
    if (data.axes.len != 1 or bins_shape.axes.len != 1) return null;
    const launch = specialization.launch orelse return null;
    if (launch.threadgroup[0] == 0) return null;
    const structure = specialization.structure orelse return null;
    const variant = std.meta.stringToEnum(HistogramVariant, structure) orelse return null;
    const instance = Histogram{
        .bins = bins_shape.axes[0].extent,
        .count = data.axes[0].extent,
        .dtype = dtype,
        .binning = binning,
        .variant = variant,
        .threads = launch.threadgroup[0],
        .bin_axis = bins_shape.axes[0].name,
        .element_axis = data.axes[0].name,
    };
    if (!model.histogramInstanceValid(instance)) return null;
    return instance;
}
