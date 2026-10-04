//! Code that runs compiled functions that an NVIDIA GPU runs across many threads at once
//! (*kernels*): it loads NVIDIA's driver library at run time, loads compiled kernel modules, moves
//! memory and launches work. A machine that only runs kernels should need as little NVIDIA software
//! installed as possible. NVIDIA ships compilers and helper libraries such as `nvcc`, `nvrtc` and
//! `nvJitLink` in the CUDA Toolkit, and the Runtime API headers there too, while the display driver
//! alone already carries a compiler for its own text format.
//!
//! The runtime reaches the GPU through NVIDIA's lowest-level interface, which ships inside the
//! display driver (the *CUDA Driver API*), and opens it as a shared library when first used.
//! Kernels travel to the driver as text in NVIDIA's virtual instruction set (*PTX*), which the
//! driver compiles on load, so running kernels needs the NVIDIA driver and none of the CUDA
//! Toolkit, the Runtime API headers, `nvcc`, `nvrtc` or `nvJitLink`. An optional check assembles
//! the text with the toolkit's assembler (*ptxas*) during validation, and that check skips when the
//! assembler is missing. The parts are the driver entry points (`driver`), the runtime that owns
//! contexts, modules and launches (`runtime`), and shared support code (`support`).

pub const runtime = @import("runtime.zig");
pub const support = @import("support.zig");
