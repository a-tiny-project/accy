//! What one function or module may hold for the Apple arm64 emitter, as the execution contract
//! states it.

const backend = @import("backend.zig");
const control = @import("control.zig");
const placement = @import("placement.zig");
const Bounds = @import("../execution/bounds.zig").Bounds;

/// Placement counts, per function, its operations (nested operations included, regions not
/// counted), the values it defines, and the frame bytes its spills, allocations and call
/// frame take; structured control counts its nesting and the values each construct carries
/// or yields; a function or call passes its arguments and results in registers; and one
/// module defines at most `max_call_functions` functions for its direct call graph.
/// `syscall_arguments` is null because admission refuses every `func.syscall` by name before
/// any count is taken; no argument count is ever refused.
pub const bounds: Bounds = .{
    .while_values = control.max_carried_values,
    .yielded_values = control.max_carried_values,
    .parameters = backend.max_arguments,
    .call_arguments = backend.max_arguments,
    .results = backend.max_results,
    .operations = placement.max_operations,
    .values = placement.max_values,
    .control_depth = control.max_depth,
    .frame_bytes = placement.max_frame_bytes,
    .syscall_arguments = null,
    .module_functions = backend.max_call_functions,
};
