const capacity = @import("capacity.zig");
pub const data = @import("data.zig");
pub const math = @import("math.zig");
pub const walk = @import("walk.zig");
const inspection_module = @import("inspection.zig");
const model = @import("model.zig");
const module = @import("module/root.zig");
const owner = @import("owner.zig");

pub const function = @import("function/root.zig");
pub const inspection = inspection_module;
pub const module_encoding = module;
pub const plan = @import("plan/root.zig");
pub const symbols = @import("symbols.zig");
pub const types = @import("types.zig");

pub const Capacity = capacity.Capacity;
pub const OutputCapacity = capacity.OutputCapacity;

pub const Error = model.Error;
pub const Facts = model.Facts;
pub const Limits = capacity.Limits;
pub const Module = owner.Module;
pub const ModuleEmitter = owner.ModuleEmitter;
pub const Options = model.Options;
pub const SectionSizes = model.SectionSizes;
pub const max_nesting_depth = model.max_nesting_depth;

pub const FunctionPlan = plan.FunctionPlan;
pub const Plan = plan.Plan;
pub const ValuePlan = plan.ValuePlan;
