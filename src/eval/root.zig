//! An evaluator takes the functions a device runs across many threads at once (*kernels*), runs
//! them on the host step by step, and produces the result a device should produce.
//!
//! A number that comes back from a GPU needs an independent reference, computed with no device,
//! before a test can accept it. Devices and languages disagree at the edges of arithmetic: what an
//! integer does when it overflows, how division rounds, whether a multiply and an add are rounded
//! once or twice, and how half-precision numbers are computed, so a reference that leaves these
//! open accepts wrong results.
//!
//! The package runs kernel programs on the host with an evaluator that needs no device (the
//! *oracle*), and that result is the reference for every backend. Integer add, subtract and
//! multiply wrap around at the declared bit width, and integer division rounds toward zero. Integer
//! division or remainder by zero is an error, and arithmetic on index values reports overflow as an
//! error. The 16-bit float formats, f16 and bf16, are computed in f32 and rounded back to 16 bits
//! after each operation. A multiply followed by an add is rounded once in two places, the explicit
//! fused multiply-add operation and each accumulation step of the warp matrix multiply-accumulate
//! (`MmaSyncOp`), and every other multiply and every other add rounds after each operation. A
//! device passes a conformance row when its largest error is at most the error the row allows (its
//! *tolerance*), so a comparison is exact only when the row declares a tolerance of zero.

const evaluator = @import("evaluator.zig");

pub const EvalError = evaluator.EvalError;
pub const shared_alloc_sentinel = evaluator.shared_alloc_sentinel;
pub const Diagnostic = evaluator.Diagnostic;
pub const Machine = evaluator.Machine;
pub const ScalarKind = evaluator.ScalarKind;
pub const Scalar = evaluator.Scalar;
pub const KernelArgument = evaluator.KernelArgument;
pub const executeKernelFunction = evaluator.executeKernelFunction;
pub const executeKernelFunctionWithDiagnostic = evaluator.executeKernelFunctionWithDiagnostic;
pub const tf32RoundF32 = evaluator.tf32RoundF32;
