//! A lower bound on the time the hardware needs for work the program must do,
//! compared against what the program measured.
//!
//! A *floor* adds disjoint pieces of required work into a lower bound. One
//! priced piece of required work is a *term*. The terms of a floor, how much of
//! the required work they cover, and the prose that says what the bound leaves
//! out define a *derivation*. Anything that derivation misses can only push the
//! real time up, so the bound holds and a partial derivation gives up only
//! tightness.
//!
//! A term priced in cycles converts at the core clock rate in kilohertz that
//! the measured run observed (the *clock*), and no nanosecond constant is
//! compiled into it. Firmware settles the core clock afresh on each run, so a
//! nanosecond floor shown without its clock is read at whatever clock the
//! author's run used. The DRAM line latency is the one exception, because
//! memory timing sets most of it, so its owner writes it in nanoseconds.
//!
//! Because the byte count by itself leaves the cost open, a bytes term has to
//! name its access pattern and where the working set lives, one of L1, L2, L3,
//! and DRAM (a cache *rung*). Across the rungs, streaming bandwidth covers
//! about a factor of five and the latency of a single random line about a
//! factor of a hundred. For example, on this host sequential and random access
//! over the same footprint came out about eleven times apart.
//!
//! Terms carry a role, because a timed region often takes in verification or
//! setup work that the benchmark's name says nothing about. Leaving that work
//! out of the bound produces measured time divided by the bound (the *ratio*),
//! which then describes a program nobody meant to measure.

const clock = @import("clock.zig");
const estimate = @import("estimate.zig");
const row = @import("row.zig");
const rung = @import("rung.zig");
const term = @import("term.zig");

pub const Clock = clock.Clock;

pub const Rung = rung.Rung;
pub const Pattern = rung.Pattern;
pub const Provenance = rung.Provenance;
pub const Coefficient = rung.Coefficient;
pub const Latency = rung.Latency;
pub const line_bytes = rung.line_bytes;
pub const streamingBytesPerNs = rung.streamingBytesPerNs;
pub const randomLineLatency = rung.randomLineLatency;
pub const lines = rung.lines;

pub const Contaminant = term.Contaminant;
pub const Throughput = term.Throughput;
pub const Bytes = term.Bytes;
pub const Serial = term.Serial;
pub const Parallel = term.Parallel;
pub const Declared = term.Declared;
pub const Term = term.Term;
pub const Entry = term.Entry;
pub const sha256Blocks = term.sha256Blocks;
pub const Sha256Path = term.Sha256Path;
pub const sha256BlockCycles = term.sha256BlockCycles;
pub const dependentOperationCycles = term.dependentOperationCycles;
pub const blake3_chunk_bytes = term.blake3_chunk_bytes;
pub const blake3ChunkBlocks = term.blake3ChunkBlocks;
pub const Blake3Path = term.Blake3Path;
pub const blake3BlockCycles = term.blake3BlockCycles;
pub const blake3StreamCenticycles = term.blake3StreamCenticycles;
pub const blake3Term = term.blake3Term;

pub const Coverage = estimate.Coverage;
pub const Estimate = estimate.Estimate;
pub const Derivation = estimate.Derivation;
pub const ceilingRatio = estimate.ceilingRatio;

pub const Gap = row.Gap;
pub const Gate = row.Gate;
pub const Row = row.Row;
pub const metric_schema = row.metric_schema;
pub const metric_aggregation = row.metric_aggregation;
