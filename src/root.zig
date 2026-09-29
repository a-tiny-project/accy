//! A compiler and runtime for programs over multidimensional arrays, written in Zig: a caller
//! builds a program by calling array operations, and the package records each call and checks the
//! shapes of its values. The package compiles the program into functions a device runs across many
//! threads at once (*kernels*) and runs them on a CPU or a GPU.
//!
//! A shape mistake, such as adding two arrays whose axes line up by accident, has to fail when the
//! program is built, before any device time is spent. One program has to run on NVIDIA GPUs through
//! CUDA, on Vulkan, Metal and WebGPU devices, on the host CPU, and in WebAssembly. A long-running
//! process recompiles programs as they change, so a compile has to reuse the work that did not
//! change and stay inside a budget the caller sets. Matrix products, factorizations, sorts and
//! neighbor searches run fast only as hand-written kernels whose schedules are tuned for each
//! device. A number that comes back from a GPU needs an independent reference before anyone can
//! trust it.
//!
//! When axes are named by position, a matrix product lists its batch axes and its summed axes in
//! separate lists, and a check that reads each list alone accepts one axis in both, after which the
//! output rank computed by subtraction disagrees with a count of the axes that remain. The math of
//! a program and the loops that carry it out on a device change for different reasons: the first
//! when the model changes, the second when the device, the memory layout or the tiling changes.
//! Devices take different code formats, such as PTX or cubin for CUDA, SPIR-V for Vulkan, MSL or
//! metallib for Metal and WGSL for WebGPU, and faster arithmetic such as TF32 on tensor cores
//! exists on some NVIDIA devices only. The fastest schedule for a kernel depends on the device and
//! on the size of the problem, so no fixed choice wins everywhere.
//!
//! XLA, StableHLO and PJRT, from Google and the OpenXLA community, faced these problems before: XLA
//! compiles typed graphs of array operations (https://openxla.org/xla), StableHLO fixes the
//! operation set and its meaning (https://openxla.org/stablehlo), and PJRT is the runtime interface
//! a compiler uses to reach any device (https://github.com/openxla/xla/tree/main/xla/pjrt). From
//! them the package takes typed graphs of array operations, operation meanings that stay fixed, and
//! one runtime boundary for every device: its operations carry StableHLO's names and fields, for
//! example a matrix product with separate batch and contracting axis lists, a broadcast that maps
//! each input axis to an output axis, gather, reduce and select, and every device is reached
//! through one interface.
//!
//! Each array axis carries a name and a length (a *named axis*), so operands line up by name, and a
//! missing name or an unequal length is an error while the program is recorded, before anything
//! runs. An operation multiplies and sums two arrays (the *generalized matrix product*,
//! `dot_general`) after splitting the axes of each operand into three disjoint groups, batch,
//! contracted and free, and paired batch and contracted axes must have equal lengths, so the output
//! rank is always the batch count plus the two free counts. A Lean proof shows
//! that accepted role lists partition each operand, and that letting one axis sit in two groups
//! breaks the rank count.
//!
//! Array operations lower into the *Choir* compiler infrastructure, a Zig library
//! modeled on MLIR. That infrastructure groups its operations by level into named groups of
//! compiler operations (*dialects*), and lowering the array operations into its structured loop
//! groups keeps the array math apart from device-specific loop scheduling and memory tiling.
//!
//! Compiling runs as a fixed chain of seven stages that takes a recorded program to kernels legal
//! on one device (*preparation*): semantic, contract, tensor, dispatch, memory, kernel and target.
//! The result of each stage is sealed as an immutable record (a *stage record*), and a later
//! compile reuses a record only when an exact check admits it for the new request, with every stage
//! charged against work limits the caller sets.
//!
//! Hand-written kernels for matrix products, factorizations, spatial grids, sorts and other
//! families are chosen by a typed request from one library (the *kernel library*), and measured
//! tables keyed by device and problem size pick their schedules. Every device sits behind one
//! interface, a pointer and a table of functions (a *backend*), through which a caller creates
//! buffers, loads compiled code and launches kernels. Compiled code records the arithmetic it
//! follows as part of its identity (its *math tier*): exact by default, or TF32 on CUDA tensor
//! cores, which fails to compile on any other device and never falls back to exact arithmetic.
//!
//! An evaluator of kernel programs that needs no device (an *oracle*) gives every backend result an
//! independent reference, and conformance tests compare each device output against it within a
//! stated tolerance.
//!
//! Programs travel between processes as versioned bytes (their *wire form*), which the receiver
//! replays through the same checked step that records a program. A small table inside the host
//! process compiles those programs for the CPU and runs them on caller memory (a *session*).
//!
//! The package's parts are element types (`dtype`), axis roles (`axis`), device interfaces
//! (`backend`), compiled code and its identity (`artifact`), loaded programs ready to launch
//! (`executable`), the compile chain (`preparation`), device targets (`target`), recorded programs
//! with their wire form and session (`tensor`), kernels and the kernel library (`kernel`), the
//! rules that decide when a device test runs or skips (`validation`), and the compiler dialects
//! (`choir`). The device-free evaluator lives in `eval` and is reached through the kernel part, and
//! benchmarks such as `accy-choir-bench` and `accy-versus-bench` are separate build steps outside
//! the library.
//!
//! - *tuning table*: measured schedule winners keyed by device, operation and problem size.

pub const axis = @import("axis/root.zig");
pub const artifact = @import("artifact/root.zig");
pub const executable = @import("executable/root.zig");
pub const preparation = @import("preparation/root.zig");
pub const target = @import("target/root.zig");
pub const tensor = @import("tensor/root.zig");
pub const kernel = @import("kernel/root.zig");
pub const validation = struct {
    pub const gating = @import("accy_validation_gating");
};

pub const choir = @import("choir/root.zig");
