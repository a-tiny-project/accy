const binary = @import("../../binary/root.zig");
const ir = @import("../../../../core/root.zig");
const emission = @import("../root.zig");

pub const index = @import("index.zig");
pub const planning = @import("planning.zig");

pub const FunctionPlan = struct {
    name: []const u8,
    value_start: u32,
    value_count: u32,
    param_count: u32,
    local_count: u32,
    function_index: u32,
    body_bytes: usize,
};

pub const ValuePlan = struct {
    value: *ir.Value,
    local_index: u32,
    value_type: binary.ValueType,
};

pub const Plan = struct {
    functions: []FunctionPlan,
    function_index: []u32,
    values: []ValuePlan,
    value_index: []u32,
    import_count: usize,
    definition_count: usize,
    needs_memory: bool,
    sections: emission.SectionSizes,

    pub fn functionIndex(self: *const Plan, name: []const u8) ?u32 {
        return index.findFunction(self.function_index, self.functions, name);
    }

    pub fn localFor(self: *const Plan, function_ordinal: usize, value: *ir.Value) ?u32 {
        if (function_ordinal >= self.functions.len) return null;
        return index.findLocal(
            self.value_index,
            self.values,
            self.functions[function_ordinal],
            value,
        );
    }

    pub fn localPlans(self: *const Plan, function_ordinal: usize) []const ValuePlan {
        const function_plan = self.functions[function_ordinal];
        const start: usize = function_plan.value_start + function_plan.param_count;
        const end = start + function_plan.local_count;
        return self.values[start..end];
    }

    pub fn functionCount(self: *const Plan) usize {
        return self.functions.len;
    }

    pub fn importCount(self: *const Plan) usize {
        return self.import_count;
    }

    pub fn definitionCount(self: *const Plan) usize {
        return self.definition_count;
    }

    pub fn localCount(self: *const Plan, function_ordinal: usize) usize {
        return self.functions[function_ordinal].local_count;
    }

    pub fn bodyBytes(self: *const Plan, function_ordinal: usize) usize {
        return self.functions[function_ordinal].body_bytes;
    }

    pub fn needsMemory(self: *const Plan) bool {
        return self.needs_memory;
    }
};
