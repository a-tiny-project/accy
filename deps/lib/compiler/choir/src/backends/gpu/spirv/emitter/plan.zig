const std = @import("std");
const abi = @import("gpu_abi");
const choir = @import("../../../../root.zig");

const codegen = @import("codegen.zig");

const ir = choir.ir;

/// SPIR-V words for one module, and the push-constant layout the emitter gave
/// the requested entry.
pub const Emission = struct {
    words: []u32,
    push_constants: abi.PushConstants,
};

/// Emits `module` and returns the layout of `entry_name`'s push-constant
/// block. A hand-written `spirv.module` declares no block, so its layout is
/// empty. `controls` contains only float modes the selected device reports.
pub fn emitPlanWords(
    result_allocator: std.mem.Allocator,
    module: *ir.Operation,
    entry_name: []const u8,
    limits: abi.Limits,
    controls: codegen.FloatControls,
) abi.Error!Emission {
    std.debug.assert(entry_name.len > 0);
    std.debug.assert(limits.valid());
    var emitter = codegen.SpirvCodegen.init(result_allocator);
    defer emitter.deinit();
    emitter.limits = limits;
    emitter.entry_name = entry_name;
    emitter.float_controls = controls;
    const words = emitter.emitModuleWords(module) catch |err| return mapCodegenError(err);
    return .{ .words = words, .push_constants = emitter.entry_push_constants orelse .{} };
}

fn mapCodegenError(err: codegen.SpirvCodegenError) abi.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedOperation, error.UnsupportedStageMemory, error.UnsupportedHelperSignature, error.CallChainTooDeep => error.UnsupportedOperation,
        error.UnsupportedFunctionSignature,
        error.UnsupportedType,
        error.UnsupportedMask,
        error.UnsupportedAddressSpace,
        error.UnsupportedControlFlow,
        => error.CapabilityMismatch,
        else => error.InvalidArtifact,
    };
}
