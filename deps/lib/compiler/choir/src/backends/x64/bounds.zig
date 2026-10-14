//! What one function, call, or module may hold for the x86_64 emitter, as the execution
//! contract states it. It describes emitted code on every host, so a consumer that only emits
//! reads it as well as one that executes.

const artifact = @import("../root.zig").artifact;
const abi = @import("abi.zig");
const emit = @import("emit.zig");
const Bounds = @import("../execution/bounds.zig").Bounds;

/// The emitter counts, per construct, the values a while carries, the results a function,
/// call, or return carries, the arguments a call or syscall passes, and the parameters a
/// function takes; legality counts the parameters of a function it defines and the arguments a
/// call passes; the `func.syscall` verifier refuses past the same six argument registers before
/// either runs; and the frame is bounded in bytes by the 32-bit displacements that address it.
/// Everything else it holds in memory the runtime's limits bound.
///
/// A call passes at most the parameters a signature records, which bounds its outgoing frame
/// statically; legality refuses a wider call as it lowers, and the emitter refuses one before
/// anything sizes its arguments.
pub const bounds: Bounds = .{
    .while_values = emit.max_while_carried_values,
    .yielded_values = null,
    .parameters = artifact.Signature.max_parameters,
    .call_arguments = abi.max_call_arguments,
    .results = abi.max_result_count,
    .operations = null,
    .values = null,
    .control_depth = null,
    .frame_bytes = abi.max_frame_bytes,
    .syscall_arguments = emit.max_syscall_arguments,
    .module_functions = null,
};
