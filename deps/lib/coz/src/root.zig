//! A caller with a profile full of hot lines still has to guess which line is
//! worth optimizing. The package answers that question by measuring what a
//! speedup of one code region would do to the whole program's rate of progress,
//! called *causal profiling*.
//!
//! A program marks where its useful work completes using either one counter or
//! a pair of counters. Bumping a named counter records a *progress point*. A
//! named pair of begin and end counters whose difference gives the work in
//! flight between them forms a *latency scope*.
//!
//! To test a line, the runtime conducts one run of a drawn speedup for a fixed
//! duration, called an *experiment*. The runtime samples which line each thread
//! is running through the performance counters and matches each sample against
//! the line the current experiment selected. The experiment draws a speedup for
//! that selected line, from zero to the whole sample period. The runtime
//! applies this speedup by holding the rest of the program back. The
//! nanoseconds a thread is held back so that the selected line runs relatively
//! faster form the *delay*. A thread whose sample lands on the selected line is
//! credited with that delay, and every other thread waits until it has caught
//! up to the global delay. The runtime measures the gap between the credited
//! line and the delayed remainder. The fraction of the sample period the
//! selected line is credited with, from zero to one, is the *virtual speedup*
//! the experiment reports. Each experiment runs for a duration that doubles or
//! halves toward a target number of progress-point deltas, followed by a
//! cool-off period.
//!
//! The runtime writes the run as a stream of JSON lines carrying startup,
//! experiment, throughput, latency, and sampling records. Analysis reads that
//! stream and reports, for each selected line and progress point, the program
//! speedup measured at each virtual speedup, the slope through those points,
//! and a support status saying how much of the curve the run covered.
//!
//! The marker calls do nothing while no runtime is installed, so a program can
//! keep them in place for builds that run without the profiler.

pub const analysis = @import("analysis.zig");
pub const abi = @import("abi.zig");
pub const debug_info = @import("debug.zig");
pub const delay = @import("delay.zig");
pub const experiment = @import("experiment.zig");
pub const loaded_files = @import("files.zig");
pub const path_filter = @import("filter.zig");
pub const profile = @import("profile.zig");
pub const profile_file = @import("file.zig");
pub const profiler = @import("profiler.zig");
pub const progress_point = @import("point.zig");
pub const registry = @import("registry.zig");
pub const sampler = @import("sampler.zig");
pub const signals = @import("signals.zig");
pub const source_map = @import("map.zig");
pub const thread = @import("thread.zig");

const runtime = @import("runtime.zig");

pub const CounterKind = abi.CounterKind;
pub const Counter = abi.Counter;
pub const ExperimentRunOptions = profiler.ExperimentRunOptions;
pub const ExperimentStepOptions = profiler.ExperimentStepOptions;
pub const ExperimentStepResult = profiler.ExperimentStepResult;
pub const Profiler = profiler.Profiler;
pub const ProfileFile = profile_file.Writer;
pub const Registry = registry.Registry;
pub const Sampler = sampler.Sampler;
pub const Thread = thread.Thread;

pub const RuntimeOptions = runtime.RuntimeOptions;
pub const Runtime = runtime.Runtime;

pub const runtimeUnavailable = runtime.runtimeUnavailable;
pub const profilerPresent = runtime.profilerPresent;
pub const installSamplingHandler = runtime.installSamplingHandler;
pub const installProfiler = runtime.installProfiler;
pub const uninstallProfiler = runtime.uninstallProfiler;
pub const progress = runtime.progress;
pub const progressNamed = runtime.progressNamed;
pub const begin = runtime.begin;
pub const end = runtime.end;
pub const Scope = runtime.Scope;
pub const scope = runtime.scope;
pub const preBlock = runtime.preBlock;
pub const catchUp = runtime.catchUp;
pub const postBlock = runtime.postBlock;
