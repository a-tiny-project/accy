const std = @import("std");
const ir = @import("../../../core/root.zig");
const emission = @import("root.zig");

pub const Limits = struct {
    module: *ir.Operation,
    options: emission.Options,
    facts: emission.Facts,
    /// The caller binds the `math` imports, so the f64 math operations become calls to them.
    math_imports: bool = false,

    pub fn inspect(module: *ir.Operation, options: emission.Options) emission.Error!Limits {
        return .{
            .module = module,
            .options = options,
            .facts = try emission.inspection.inspect(module, options),
        };
    }
};

pub const Capacity = struct {
    facts: emission.Facts,
    frame_count: usize,
    function_index_slots: usize,
    value_index_slots: usize,
    function_plan_bytes: usize,
    function_index_bytes: usize,
    value_plan_bytes: usize,
    value_index_bytes: usize,
    frame_bytes: usize,
    working_bytes: usize,

    pub fn derive(limits: Limits) error{CapacityOverflow}!Capacity {
        const frame_count = if (limits.facts.definition_count == 0)
            0
        else frame_count: {
            const controls = std.math.mul(
                usize,
                limits.facts.nesting_depth,
                2,
            ) catch return error.CapacityOverflow;
            break :frame_count std.math.add(usize, controls, 1) catch
                return error.CapacityOverflow;
        };
        const function_plan_bytes = try bytesFor(
            emission.FunctionPlan,
            limits.facts.function_count,
        );
        const function_index_slots = try emission.plan.index.slotsFor(
            limits.facts.function_count,
        );
        const function_index_bytes = try bytesFor(u32, function_index_slots);
        const value_plan_bytes = try bytesFor(emission.ValuePlan, limits.facts.value_count);
        const value_index_slots = try emission.plan.index.slotsFor(limits.facts.value_count);
        const value_index_bytes = try bytesFor(u32, value_index_slots);
        const frame_bytes = try bytesFor(emission.function.Frame, frame_count);
        var working_bytes = try add(function_plan_bytes, function_index_bytes);
        working_bytes = try add(working_bytes, value_plan_bytes);
        working_bytes = try add(working_bytes, value_index_bytes);
        working_bytes = try add(working_bytes, frame_bytes);
        var facts = limits.facts;
        if (!limits.math_imports) facts.math = .{};
        return .{
            .facts = facts,
            .frame_count = frame_count,
            .function_index_slots = function_index_slots,
            .value_index_slots = value_index_slots,
            .function_plan_bytes = function_plan_bytes,
            .function_index_bytes = function_index_bytes,
            .value_plan_bytes = value_plan_bytes,
            .value_index_bytes = value_index_bytes,
            .frame_bytes = frame_bytes,
            .working_bytes = working_bytes,
        };
    }
};

pub const OutputCapacity = struct {
    output_bytes: usize,
    initialization_bytes: usize,
    steady_bytes: usize,

    pub fn derive(
        capacity: Capacity,
        output_bytes: usize,
    ) error{CapacityOverflow}!OutputCapacity {
        return .{
            .output_bytes = output_bytes,
            .initialization_bytes = try add(capacity.working_bytes, output_bytes),
            .steady_bytes = output_bytes,
        };
    }
};

fn bytesFor(comptime T: type, count: usize) error{CapacityOverflow}!usize {
    return std.math.mul(usize, @sizeOf(T), count) catch error.CapacityOverflow;
}

fn add(lhs: usize, rhs: usize) error{CapacityOverflow}!usize {
    return std.math.add(usize, lhs, rhs) catch error.CapacityOverflow;
}

fn testLimits(facts: emission.Facts) Limits {
    return .{ .module = undefined, .options = .{}, .facts = facts };
}

fn testFacts() emission.Facts {
    return .{
        .function_count = 0,
        .import_count = 0,
        .definition_count = 0,
        .value_count = 0,
        .local_count = 0,
        .nesting_depth = 0,
        .needs_memory = false,
    };
}
