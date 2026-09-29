//! Memtrace records where a program's memory goes: which phase allocated it,
//! from which call site, and how much of it is still live.
//!
//! A recorder, the *tracer*, records each operation against the scope in force
//! and answers with summaries and events. It wraps the allocator the caller
//! hands it, the *backing allocator*, and forwards every operation to it.
//! Wrapping one allocator at a time scopes the record to the subsystem the
//! caller chose.
//!
//! An `enter` call opens a named region of execution, the *scope*, which names
//! the phase that later allocations are attributed to and closes when its span
//! exits. A bounded table of labeled byte counts a caller reports by hand, the
//! *census*, records memory beyond what the allocator names on its own.
//!
//! A subsystem passes down a handle holding an optional tracer, an optional
//! census, and an optional interval sink, the *participation context*. A
//! disabled context leaves every call through it inert, so a subsystem keeps
//! one code path whether an observer is present or absent.
//!
//! When recording an allocation fails, `rawAlloc` frees the memory it obtained
//! and answers null, which keeps live memory out of the program that the record
//! does not mention. For a resize, a remap, or a free, a recording failure
//! raises the tracer's failure flag and the memory operation stands, which
//! leaves the capture partial. A tracer writes a summary of live and high-water
//! bytes per scope, and a JSONL event stream, and its analysis reports capture
//! integrity beside those totals so a partial capture is visible in the output.

const event_mod = @import("event.zig");
const coverage_mod = @import("coverage.zig");
const tracer_mod = @import("tracer.zig");
const census_mod = @import("census/root.zig");
const context_mod = @import("context.zig");
const analysis_mod = @import("analysis.zig");
const causal_mod = @import("causal.zig");
const cli_mod = @import("cli.zig");
const ledger_mod = @import("ledger.zig");
const stack_mod = @import("stack/root.zig");

pub const event = event_mod;
pub const coverage = coverage_mod;
pub const census = census_mod;
pub const context = context_mod;
pub const analysis = analysis_mod;
pub const causal = causal_mod;
pub const cli = cli_mod;
pub const ledger = ledger_mod;
pub const stack = stack_mod;

pub const Analyzer = analysis_mod.Analyzer;
pub const AnalysisSummaryOptions = analysis_mod.SummaryOptions;
pub const AllocationLedger = ledger_mod.AllocationLedger;
pub const AllocationRecord = ledger_mod.Record;
pub const CaptureIntegrity = analysis_mod.CaptureIntegrity;
pub const Config = tracer_mod.Config;
pub const Context = context_mod.Context;
pub const IntervalSink = context_mod.IntervalSink;
pub const IntervalSpan = context_mod.IntervalSpan;
pub const Difference = tracer_mod.Difference;
pub const OwnedObservation = tracer_mod.OwnedObservation;
pub const Scope = tracer_mod.Scope;
pub const Span = context_mod.Span;
pub const Snapshot = tracer_mod.Snapshot;
pub const Retention = tracer_mod.Retention;
pub const SummaryOptions = tracer_mod.SummaryOptions;
pub const Tracer = tracer_mod.Tracer;
pub const TracingAllocator = tracer_mod.TracingAllocator;
pub const request_site_capacity_max = tracer_mod.request_site_capacity_max;
pub const AllocationAttribution = stack_mod.Attribution;

pub const Census = census_mod.Census;
pub const CensusCapacity = census_mod.Capacity;
pub const CensusCapacityError = census_mod.DeriveError;
pub const CensusEntry = census_mod.Entry;
pub const CensusExhaustion = census_mod.Exhaustion;
pub const CensusLimits = census_mod.Limits;
pub const CensusStatus = census_mod.Status;
pub const CensusStorage = census_mod.Storage;
pub const CensusStorageExhaustion = census_mod.StorageExhaustion;
pub const CensusStorageStatus = census_mod.StorageStatus;
pub const CensusSummaryOptions = census_mod.SummaryOptions;
pub const Event = event_mod.Event;
pub const EventKind = event_mod.Kind;
pub const EventLayer = event_mod.Layer;
