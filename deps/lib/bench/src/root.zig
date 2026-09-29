//! A microbenchmark result moves with heap and stack layout, with the cache
//! state the run starts in, and with the resolution of the clock that times it.
//! Running the benchmark again as its own child process a set number of times
//! tells variance coming from the environment apart from variance coming from
//! the program itself. Each repetition is a *multi-process trial*. One timed
//! run of the batched benchmark body, recorded as nanoseconds per evaluation,
//! is a *sample*. Geometric batching bounds what timing quantization can do to
//! the result by growing the evaluations inside one sample by a factor between
//! two and ten, until a sample spans a thousand times the clock resolution.
//!
//! Resampling the collected samples gives a range for the median and for the
//! other reported statistics, called a *bootstrap confidence interval*. Those
//! intervals leave systematic shifts, correlation between neighboring samples,
//! and coverage errors uncorrected. Every later statistics run takes its
//! regions out of storage, the *analysis scratch*. The caller sizes the
//! analysis scratch and hands it over once, so computing statistics takes
//! nothing further from an allocator. The workload under measurement can still
//! move memory of its own.

pub const coz = @import("coz");
pub const floor = @import("bench_floor");
pub const memtrace = @import("memtrace");
pub const pretty = @import("pretty");
pub const stabilizer = @import("stabilizer");
pub const tracy = @import("tracy");
pub const recovery = @import("recovery.zig");
const instrumentation = @import("instrumentation.zig");
const timing = @import("timing.zig");
pub const statistics = @import("stats/root.zig");
const stats = statistics;
const event = @import("event.zig");
const evidence = @import("evidence.zig");
const output = @import("output.zig");
const suite = @import("suite.zig");
const allocation = @import("allocation.zig");
pub const parse = @import("parse.zig");
const jsonl_mod = @import("jsonl.zig");
const compare_mod = @import("compare/root.zig");
const metadata_mod = @import("metadata.zig");
const summary_mod = @import("summary.zig");

pub const CozSession = instrumentation.CozSession;
pub const Capability = instrumentation.Capability;
pub const CapabilityName = instrumentation.CapabilityName;
pub const CapabilityState = instrumentation.CapabilityState;
pub const Phase = instrumentation.Phase;
pub const ProfilingReport = instrumentation.ProfilingReport;
pub const ProfilingSession = instrumentation.ProfilingSession;
pub const ProfilingSessionOptions = instrumentation.ProfilingSessionOptions;
pub const callWithStackPad = instrumentation.callWithStackPad;
pub const phaseAt = instrumentation.phaseAt;
pub const rerandomizeLayout = instrumentation.rerandomizeLayout;
pub const touchStackPad = instrumentation.touchStackPad;
pub const writePerfCounterResult = instrumentation.writePerfCounterResult;
pub const writeProfilingReport = instrumentation.writeProfilingReport;

pub const nowNs = timing.nowNs;
pub const nowInstant = timing.nowInstant;
pub const readInstant = timing.readInstant;
pub const realNowNs = timing.realNowNs;
pub const probeClock = timing.probeClock;
pub const ClockProbe = timing.ClockProbe;
pub const elapsedNs = timing.elapsedNs;
pub const elapsedNsBetween = timing.elapsedNsBetween;
pub const nsOrZero = timing.nsOrZero;
pub const saturatingU64 = timing.saturatingU64;
pub const saturatingI64 = timing.saturatingI64;

pub const Config = suite.Config;
pub const AllocationAttribution = suite.AllocationAttribution;
pub const AutomaticEvaluation = suite.AutomaticEvaluation;
pub const Evaluation = suite.Evaluation;
pub const AutomaticSelection = suite.AutomaticSelection;
pub const EvaluationSelection = suite.EvaluationSelection;
pub const RunOptions = suite.RunOptions;
pub const Result = suite.Result;
pub const JsonlOptions = suite.JsonlOptions;
pub const AllocationCounts = allocation.Counts;
pub const CountingAllocator = allocation.CountingAllocator;
pub const BootstrapConfig = stats.BootstrapConfig;
pub const BootstrapConfidenceIntervals = stats.BootstrapConfidenceIntervals;
pub const ConfidenceInterval = stats.ConfidenceInterval;
pub const SampleStats = stats.SampleStats;
pub const StatisticsLimits = stats.Limits;
pub const StatisticsCapacity = stats.Capacity;
pub const StatisticsCapacityError = stats.CapacityError;
pub const StatisticsStorage = stats.Storage;
pub const StatisticsStorageStatus = stats.StorageStatus;
pub const StatisticsStorageExhaustion = stats.Exhaustion;
pub const ComparisonLimits = compare_mod.Limits;
pub const ComparisonCapacity = compare_mod.Capacity;
pub const ComparisonCapacityError = compare_mod.CapacityError;
pub const ComparisonStorage = compare_mod.Storage;
pub const ComparisonStorageStatus = compare_mod.StorageStatus;
pub const ComparisonStorageExhaustion = compare_mod.StorageExhaustion;
pub const ComparisonError = compare_mod.StorageError;
pub const IndexedDeltaTotals = stats.IndexedDeltaTotals;
pub const IndexedMemoryTotals = stats.IndexedMemoryTotals;
pub const SampleSetCursor = stats.SampleSetCursor;
pub const sampleSetValueCapacity = stats.sampleSetValueCapacity;
pub const sampleSets = stats.sampleSets;
pub const computeSampleStats = stats.computeSampleStats;
pub const computeSampleStatsWithBootstrap = stats.computeSampleStatsWithBootstrap;
pub const nsPerUnit = stats.nsPerUnit;
pub const valuePerUnit = stats.valuePerUnit;
pub const nsPerFloatUnit = stats.nsPerFloatUnit;
pub const valuePerFloatUnit = stats.valuePerFloatUnit;

pub const BuildMetadata = metadata_mod.BuildMetadata;
pub const RunStart = event.RunStart;
pub const RunEnd = event.RunEnd;
pub const writeRunStart = event.writeRunStart;
pub const writeBootstrapConfidenceIntervals = event.writeBootstrapConfidenceIntervals;
pub const writeBuildMetadata = metadata_mod.writeBuildMetadata;
pub const writeSampleEvent = event.writeSampleEvent;
pub const writeRunEnd = event.writeRunEnd;
pub const writeSampledResultFields = event.writeSampledResultFields;
pub const writeBenchmarkEvidence = evidence.writeBenchmarkEvidence;
pub const jsonl = jsonl_mod;
pub const currentBuildMetadata = metadata_mod.currentBuildMetadata;
pub const compare = compare_mod;
pub const summary = summary_mod;

pub const BenchFn = suite.BenchFn;
pub const TeardownFn = suite.TeardownFn;
pub const Suite = suite.Suite;
pub const time = suite.time;

pub const section = output.section;
pub const stdout = output.stdout;
pub const stderr = output.stderr;
pub const writeStdoutFmt = output.writeStdoutFmt;
pub const writeStderrFmt = output.writeStderrFmt;
pub const writeStdoutDoc = output.writeStdoutDoc;
pub const writeStderrDoc = output.writeStderrDoc;
