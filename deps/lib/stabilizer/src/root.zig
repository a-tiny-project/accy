//! Randomizes a program's memory layout by choosing heap addresses, stack frame
//! padding, and code addresses at random (*layout randomization*), so that a
//! benchmark can run over many layouts. A single build fixes the addresses of
//! its code, its stack frames, and its heap blocks, and those addresses decide
//! which cache lines and branch predictor entries collide. A caller comparing
//! two builds of a benchmark wants the difference to come from the code, while
//! the addresses the linker and the allocator happened to choose vary from run
//! to run.
//!
//! The heap that keeps a pool of slots per size class and serves each request
//! from a slot drawn at random is the *shuffle allocator*. The shuffle
//! allocator fills every slot ahead of time and shuffles the pool, then puts a
//! fresh block in the drawn slot's place. A request larger than the configured
//! maximum bypasses the shuffling and goes to the allocator the caller supplied
//! at init, the *backing allocator*.
//!
//! Each call takes a per-call padding size drawn from a refillable table
//! (*stack pad*), so a frame sits at a different offset each time.
//!
//! The state that relocates registered functions to fresh addresses and
//! rewrites their entry traps is the *code randomizer*. Those entry traps catch
//! the next call, and the code randomizer moves the layout again every 500
//! milliseconds.
//!
//! One seed drives the heap, the stack pads, and the code layout together, so a
//! run repeats when the seed repeats. The defaults follow the published
//! Stabilizer runtime: 256 shuffle slots, 32 MiB regions, 32-byte code
//! alignment, 16-byte stack alignment, and a 500 millisecond interval.

const code_mod = @import("code.zig");
const config_mod = @import("config.zig");
const heap_mod = @import("heap.zig");
const intrinsics_mod = @import("intrinsics.zig");
const rng_mod = @import("rng.zig");
const runtime_mod = @import("runtime.zig");
const stack_mod = @import("stack.zig");

pub const default_seed = config_mod.default_seed;
pub const default_shuffle_slots = config_mod.default_shuffle_slots;
pub const default_region_size = config_mod.default_region_size;
pub const code_alignment = config_mod.code_alignment;
pub const stack_alignment = config_mod.stack_alignment;
pub const rerandomize_interval_ms = config_mod.rerandomize_interval_ms;
pub const max_stack_pad_unit = config_mod.max_stack_pad_unit;

pub const Config = config_mod.Config;
pub const HeapConfig = config_mod.HeapConfig;
pub const StackConfig = config_mod.StackConfig;
pub const CodeConfig = config_mod.CodeConfig;
pub const Reference = config_mod.Reference;

pub const Marsaglia = rng_mod.Marsaglia;
pub const StackPad = stack_mod.StackPad;
pub const StackPads = stack_mod.StackPads;
pub const ShuffleAllocator = heap_mod.ShuffleAllocator;
pub const sizeClass = heap_mod.sizeClass;
pub const powif = intrinsics_mod.powif;
pub const memset_i8 = intrinsics_mod.memset_i8;
pub const memset_i16 = intrinsics_mod.memset_i16;
pub const memset_i32 = intrinsics_mod.memset_i32;
pub const memset_i64 = intrinsics_mod.memset_i64;
pub const FunctionId = code_mod.FunctionId;
pub const LocationId = code_mod.LocationId;
pub const FunctionOptions = code_mod.FunctionOptions;
pub const FunctionImageOptions = code_mod.FunctionImageOptions;
pub const FunctionRangeOptions = code_mod.FunctionRangeOptions;
pub const FunctionEntryState = code_mod.FunctionEntryState;
pub const FunctionStackPad = code_mod.FunctionStackPad;
pub const FunctionLocation = code_mod.FunctionLocation;
pub const CodeRandomizer = code_mod.CodeRandomizer;
pub const ConstructorFn = runtime_mod.ConstructorFn;
pub const Runtime = runtime_mod.Runtime;
